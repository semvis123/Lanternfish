import AppKit
import LanternfishKit
import Observation

/// Drives one traceroute sheet: runs `Traceroute`, collects hops by TTL, exposes status.
@MainActor
@Observable
final class TracerouteModel {
    enum Status: Equatable {
        case idle
        case resolving
        case tracing
        case finished(reached: Bool)
        case stopped
        case failed(String)
    }

    static let maxHops = 30
    /// Probes per hop; also the number of RTT columns.
    static let probes = 3
    /// Generous per-probe timeout: hops on congested or mobile links often answer in ~1 s.
    private static let engine = Traceroute(maxHops: maxHops, probesPerHop: probes, timeout: .seconds(2))

    private(set) var host = ""
    private(set) var resolved: IPv4Address?
    private(set) var status: Status = .idle
    private var hopsByTTL: [Int: TracerouteHop] = [:]
    private var task: Task<Void, Never>?

    var isRunning: Bool { status == .resolving || status == .tracing }

    /// Hops in order, cut after the first one that is the destination. Once finished without
    /// reaching it, trailing silent hops are dropped (see `silentTail`).
    var hops: [TracerouteHop] {
        var out: [TracerouteHop] = []
        for ttl in hopsByTTL.keys.sorted() {
            let hop = hopsByTTL[ttl]!
            out.append(hop)
            if hop.address != nil, hop.address == resolved { break }
        }
        if case .finished(reached: false) = status, let last = out.lastIndex(where: { $0.address != nil }) {
            out.removeSubrange((last + 1)...)
        }
        return out
    }

    /// Number of hops reached, when the destination answered.
    var hopCount: Int? {
        guard case .finished(reached: true) = status else { return nil }
        return hops.last?.ttl
    }

    /// Largest average RTT, for scaling the latency bars.
    var maxAverage: Duration? { hops.compactMap(\.averageRTT).max() }

    func start(_ host: String) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        task?.cancel()
        self.host = host
        resolved = nil
        hopsByTTL = [:]
        status = .resolving
        let stream = Self.engine.trace(host)
        task = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                self.handle(event)
            }
        }
    }

    func stop() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        if isRunning { status = .stopped }
    }

    private func handle(_ event: TracerouteEvent) {
        switch event {
        case .resolved(let ip):
            resolved = ip
            status = .tracing
        case .hop(let hop):
            hopsByTTL[hop.ttl] = hop
        case .finished(let reached):
            status = .finished(reached: reached)
            task = nil
        case .failed(let message):
            status = .failed(message)
            task = nil
        }
    }

    // MARK: Copy

    /// Classic `traceroute` text for the pasteboard.
    var text: String {
        var lines = [
            "traceroute to \(host)" + (resolved.map { " (\($0))" } ?? "")
                + ", \(Self.probes) probes per hop"
        ]
        for hop in hops {
            var line = String(format: "%2d  ", hop.ttl)
            if let a = hop.address {
                line += hop.hostname.map { "\($0) (\(a))" } ?? a.description
            } else {
                line += "*"
            }
            let rtts = hop.rtts.map { $0.map(PingFormat.rtt) ?? "*" }
            if !rtts.isEmpty, hop.address != nil { line += "  " + rtts.joined(separator: "  ") }
            lines.append(line)
        }
        switch status {
        case .finished(reached: true): lines.append("Reached \(host) in \(hopCount ?? 0) hops")
        case .finished(reached: false): lines.append("\(host) did not respond")
        case .failed(let message): lines.append(message)
        case .stopped: lines.append("Stopped")
        default: break
        }
        return lines.joined(separator: "\n")
    }
}
