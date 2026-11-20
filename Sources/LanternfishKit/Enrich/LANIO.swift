import Foundation
import Network

/// Small one-shot network exchanges (read a TCP greeting, send one UDP datagram and read the reply)
/// built on `NWConnection`, so no thread blocks while waiting.
enum LANIO {
    static let queue = DispatchQueue(label: "LanternfishKit.LANIO", attributes: .concurrent)

    /// Connects over TCP and returns the first bytes the server sends (e.g. an SSH greeting).
    static func readGreeting(
        _ ip: IPv4Address, port: UInt16, maxLength: Int = 512,
        timeout: Duration
    ) async -> Data? {
        await exchange(ip, port: port, using: .tcp, send: nil, maxLength: maxLength, timeout: timeout)
    }

    /// Sends one UDP datagram and returns the first reply.
    static func udpQuery(_ ip: IPv4Address, port: UInt16, payload: Data, timeout: Duration) async -> Data? {
        await exchange(ip, port: port, using: .udp, send: payload, maxLength: 2048, timeout: timeout)
    }

    private static func exchange(
        _ ip: IPv4Address, port: UInt16, using params: NWParameters, send: Data?,
        maxLength: Int, timeout: Duration
    ) async -> Data? {
        if Task.isCancelled { return nil }
        guard let nwPort = NWEndpoint.Port(rawValue: port), let host = ip.nwAddress else { return nil }
        let conn = NWConnection(host: .ipv4(host), port: nwPort, using: params)
        let shot = OneShot<Data?>()
        // `start` only runs if we weren't already cancelled, so a cancelled exchange never
        // installs handlers on, or starts, the connection.
        let data = await shot.wait(timeout: timeout, timeoutValue: nil, cancelValue: nil) {
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let send {
                        conn.send(
                            content: send,
                            completion: .contentProcessed { error in
                                if error != nil { shot.finish(nil) }
                            })
                    }
                    conn.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, _, error in
                        shot.finish(error == nil ? data : nil)
                    }
                case .failed, .cancelled, .waiting:
                    // `.waiting` means unreachable or refused: don't wait for the path to change.
                    shot.finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
        conn.stateUpdateHandler = nil
        conn.cancel()
        return data
    }
}

extension IPv4Address {
    /// The same address as a Network.framework value, for `NWConnection` endpoints.
    var nwAddress: Network.IPv4Address? {
        withUnsafeBytes(of: value.bigEndian) { Network.IPv4Address(Data($0)) }
    }
}
