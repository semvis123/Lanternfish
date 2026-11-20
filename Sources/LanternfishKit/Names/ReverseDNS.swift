import Dispatch
import dnssd

/// Reverse DNS (PTR) lookups through mDNSResponder (`DNSServiceQueryRecord`): asynchronous, so no
/// thread blocks per lookup, cancellable, and available on iOS too. mDNSResponder uses the system's
/// resolver configuration (and multicast DNS for link-local reverse zones).
public enum ReverseDNS {
    /// Serial: every query's state and callbacks live here (nothing on it ever blocks).
    static let queue = DispatchQueue(label: "LanternfishKit.ReverseDNS", qos: .utility)

    /// Returns the host name for `ip` without a trailing dot, or nil on failure / timeout / cancellation.
    public static func lookup(_ ip: IPv4Address, timeout: Duration = .seconds(2)) async -> String? {
        if Task.isCancelled { return nil }
        let query = PTRQuery(ip: ip)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { query.start($0, timeout: timeout) }
        } onCancel: {
            query.cancel()
        }
    }

    /// Cleans a PTR target: trailing dots removed; empty or the address itself → nil.
    static func clean(_ raw: String, ip: IPv4Address) -> String? {
        var name = raw
        while name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name != ip.description else { return nil }
        return name
    }
}

/// One in-flight PTR query. Mutable state is confined to `ReverseDNS.queue`.
private final class PTRQuery: @unchecked Sendable {
    let ip: IPv4Address
    private var continuation: CheckedContinuation<String?, Never>?
    private var ref: DNSServiceRef?
    /// Keeps `self` alive while dns_sd holds the context pointer.
    private var retained: Unmanaged<PTRQuery>?
    private var done = false

    init(ip: IPv4Address) { self.ip = ip }

    func start(_ c: CheckedContinuation<String?, Never>, timeout: Duration) {
        ReverseDNS.queue.async { [self] in
            guard !done else {  // cancelled before we got here
                c.resume(returning: nil)
                return
            }
            continuation = c
            let context = Unmanaged.passRetained(self)
            retained = context
            var newRef: DNSServiceRef?
            // ReturnIntermediates: negative answers (NXDOMAIN) come back as errors right away
            // instead of running into the timeout.
            let err = DNSServiceQueryRecord(
                &newRef, DNSServiceFlags(kDNSServiceFlagsReturnIntermediates), 0,
                LocalDNS.reverseName(ip) + ".", UInt16(kDNSServiceType_PTR), UInt16(kDNSServiceClass_IN),
                { _, flags, _, err, _, rrtype, _, rdlen, rdata, _, raw in
                    guard let raw else { return }
                    let query = Unmanaged<PTRQuery>.fromOpaque(raw).takeUnretainedValue()
                    guard err == kDNSServiceErr_NoError else {
                        query.complete(nil)
                        return
                    }
                    guard flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, rrtype == UInt16(kDNSServiceType_PTR),
                        let rdata, rdlen > 0
                    else { return }  // skip CNAME intermediates
                    let bytes = [UInt8](UnsafeRawBufferPointer(start: rdata, count: Int(rdlen)))
                    guard let (target, _) = LocalDNS.readName(bytes, at: 0) else { return }
                    query.complete(ReverseDNS.clean(target, ip: query.ip))
                }, context.toOpaque())
            guard err == kDNSServiceErr_NoError, let newRef else {
                complete(nil)
                return
            }
            ref = newRef
            guard DNSServiceSetDispatchQueue(newRef, ReverseDNS.queue) == kDNSServiceErr_NoError else {
                complete(nil)
                return
            }
            ReverseDNS.queue.asyncAfter(deadline: .now() + timeout.dispatchInterval) { [self] in complete(nil) }
        }
    }

    func cancel() {
        ReverseDNS.queue.async { [self] in complete(nil) }
    }

    /// On `ReverseDNS.queue`. First call wins; tears the query down.
    private func complete(_ name: String?) {
        dispatchPrecondition(condition: .onQueue(ReverseDNS.queue))
        guard !done else { return }
        done = true
        if let ref { DNSServiceRefDeallocate(ref) }  // no callbacks after this
        ref = nil
        continuation?.resume(returning: name)
        continuation = nil
        retained?.release()
        retained = nil
    }
}
