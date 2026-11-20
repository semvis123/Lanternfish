import Foundation
import Synchronization

// MARK: - Public types

public enum SpeedTestPhase: String, Sendable, CaseIterable {
    case latency, download, upload

    public var label: String {
        switch self {
        case .latency: "Latency"
        case .download: "Download"
        case .upload: "Upload"
        }
    }
}

/// Live state of a running test. Values become non-nil as they are measured; the download /
/// upload figures are the live (1 s window) rate during their phase and the final rate after.
public struct SpeedTestProgress: Sendable, Hashable {
    public var phase: SpeedTestPhase
    /// 0...1 across the whole test.
    public var fraction: Double
    public var latencyMs: Double?
    public var jitterMs: Double?
    public var downloadMbps: Double?
    public var uploadMbps: Double?

    public init(
        phase: SpeedTestPhase, fraction: Double, latencyMs: Double? = nil, jitterMs: Double? = nil,
        downloadMbps: Double? = nil, uploadMbps: Double? = nil
    ) {
        self.phase = phase
        self.fraction = fraction
        self.latencyMs = latencyMs
        self.jitterMs = jitterMs
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
    }
}

public struct SpeedTestResult: Sendable, Hashable {
    public var date: Date
    public var latencyMs: Double?
    public var jitterMs: Double?
    public var downloadMbps: Double?
    public var uploadMbps: Double?
    public var downloadedBytes: Int64
    public var uploadedBytes: Int64

    public init(
        date: Date, latencyMs: Double?, jitterMs: Double?, downloadMbps: Double?, uploadMbps: Double?,
        downloadedBytes: Int64 = 0, uploadedBytes: Int64 = 0
    ) {
        self.date = date
        self.latencyMs = latencyMs
        self.jitterMs = jitterMs
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.downloadedBytes = downloadedBytes
        self.uploadedBytes = uploadedBytes
    }
}

public enum SpeedTestEvent: Sendable {
    case progress(SpeedTestProgress)
    case finished(SpeedTestResult)
    case failed(String)
}

// MARK: - Math (pure)

public enum SpeedMath {
    /// Megabits per second for `bytes` transferred in `seconds` (decimal megabits).
    public static func mbps(bytes: Int64, seconds: Double) -> Double {
        guard seconds > 0, bytes > 0 else { return 0 }
        return Double(bytes) * 8 / seconds / 1_000_000
    }

    /// Mean absolute difference between consecutive samples (RFC 3550-style, unsmoothed).
    public static func jitter(_ samples: [Double]) -> Double? {
        guard samples.count >= 2 else { return nil }
        let diffs = zip(samples.dropFirst(), samples).map { abs($0 - $1) }
        return diffs.reduce(0, +) / Double(diffs.count)
    }

    public static func median(_ samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let s = samples.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }

    /// Throughput over cumulative `(seconds, bytes)` samples, ignoring the first `warmup`
    /// seconds (TCP slow start). Falls back to the whole span when too short.
    public static func throughput(samples: [(t: Double, bytes: Int64)], warmup: Double) -> Double? {
        guard let last = samples.last, last.t > 0 else { return nil }
        let base = samples.last(where: { $0.t <= warmup }) ?? (0, 0)
        if last.t - base.t >= 1, last.bytes > base.bytes {
            return mbps(bytes: last.bytes - base.bytes, seconds: last.t - base.t)
        }
        return last.bytes > 0 ? mbps(bytes: last.bytes, seconds: last.t) : nil
    }

    /// Rate over the trailing `window` seconds of cumulative samples.
    public static func windowRate(samples: [(t: Double, bytes: Int64)], window: Double) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let start = samples.last(where: { $0.t <= last.t - window }) ?? first
        guard last.t > start.t else { return nil }
        return mbps(bytes: last.bytes - start.bytes, seconds: last.t - start.t)
    }

    /// Server processing time (ms) from a `Server-Timing` header: the largest `dur=` value.
    public static func serverTimeMs(_ header: String?) -> Double? {
        guard let header else { return nil }
        var best: Double?
        for part in header.split(separator: ",") {
            for param in part.split(separator: ";") {
                let p = param.trimmingCharacters(in: .whitespaces)
                guard p.hasPrefix("dur="), let v = Double(p.dropFirst(4)) else { continue }
                best = max(best ?? 0, v)
            }
        }
        return best
    }

    /// Next request size for a worker: grows ×4 while requests finish quickly, capped.
    public static func nextSize(current: Int, lastDuration: Double, cap: Int) -> Int {
        lastDuration < 1.0 ? min(current * 4, cap) : current
    }
}

// MARK: - Speed test

/// Speed test against speed.cloudflare.com: HTTP latency/jitter, parallel download, upload.
public struct SpeedTest: Sendable {
    public var latencySamples: Int
    public var downloadDuration: Duration
    public var uploadDuration: Duration
    public var parallelism: Int

    private static let host = "https://speed.cloudflare.com"
    private static let latencyURL = downloadURL(bytes: 0)
    private static let uploadURL = URL(string: "\(host)/__up")!
    private static let downloadCap = 50_000_000  // the endpoint rejects >= 100 MB
    private static let uploadCap = 16_000_000

    private static func downloadURL(bytes: Int) -> URL {
        URL(string: "\(host)/__down?bytes=\(bytes)")!
    }

    public init(
        latencySamples: Int = 12, downloadDuration: Duration = .seconds(9),
        uploadDuration: Duration = .seconds(8), parallelism: Int = 4
    ) {
        self.latencySamples = latencySamples
        self.downloadDuration = downloadDuration
        self.uploadDuration = uploadDuration
        self.parallelism = max(1, parallelism)
    }

    /// Runs the test; cancel by ending iteration or cancelling the consuming task.
    public func run() -> AsyncStream<SpeedTestEvent> {
        let (stream, continuation) = AsyncStream<SpeedTestEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let task = Task { [self] in
            await self.execute { continuation.yield($0) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// The slice of overall progress each phase covers.
    private static func span(of phase: SpeedTestPhase) -> (start: Double, end: Double) {
        switch phase {
        case .latency: (0, 0.1)
        case .download: (0.1, 0.55)
        case .upload: (0.55, 1.0)
        }
    }

    private func execute(_ emit: @Sendable (SpeedTestEvent) -> Void) async {
        let engine = TransferEngine(parallelism: parallelism)
        defer { engine.invalidate() }
        var state = SpeedTestProgress(phase: .latency, fraction: 0)
        func report(_ phase: SpeedTestPhase, _ local: Double) {
            let (a, b) = Self.span(of: phase)
            state.phase = phase
            state.fraction = a + (b - a) * min(max(local, 0), 1)
            emit(.progress(state))
        }

        report(.latency, 0)
        var rtts: [Double] = []
        for i in 0..<latencySamples {
            if Task.isCancelled { return }
            if let rtt = await engine.httpRTT(Self.latencyURL) {
                // The first request also pays for the connection; keep it only if it's all we have.
                if i > 0 || latencySamples == 1 { rtts.append(rtt) }
            }
            state.latencyMs = SpeedMath.median(rtts)
            state.jitterMs = SpeedMath.jitter(rtts)
            report(.latency, Double(i + 1) / Double(latencySamples))
        }
        if Task.isCancelled { return }
        if rtts.isEmpty {
            emit(.failed("Couldn't reach speed.cloudflare.com."))
            return
        }

        report(.download, 0)
        let down = await transferPhase(engine: engine, duration: downloadDuration, upload: false) { mbps, f in
            state.downloadMbps = mbps
            report(.download, f)
        }
        if Task.isCancelled { return }
        state.downloadMbps = down.mbps

        report(.upload, 0)
        let up = await transferPhase(engine: engine, duration: uploadDuration, upload: true) { mbps, f in
            state.uploadMbps = mbps
            report(.upload, f)
        }
        if Task.isCancelled { return }
        state.uploadMbps = up.mbps
        report(.upload, 1)

        if down.mbps == nil, up.mbps == nil {
            emit(.failed("The speed test transfers failed."))
            return
        }
        emit(
            .finished(
                SpeedTestResult(
                    date: Date(), latencyMs: state.latencyMs, jitterMs: state.jitterMs,
                    downloadMbps: down.mbps, uploadMbps: up.mbps,
                    downloadedBytes: down.bytes, uploadedBytes: up.bytes)))
    }

    private func transferPhase(
        engine: TransferEngine, duration: Duration, upload: Bool,
        onSample: (Double?, Double) -> Void
    ) async -> (mbps: Double?, bytes: Int64) {
        let clock = ContinuousClock()
        let start = clock.now
        let total = duration.seconds
        let baseline = upload ? engine.sentBytes : engine.receivedBytes
        let payload: Data? = upload ? Self.randomData(count: Self.uploadCap) : nil
        var samples: [(t: Double, bytes: Int64)] = [(0, 0)]

        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<parallelism {
                group.addTask {
                    // Stagger the starting sizes so the ramp isn't lock-step.
                    var size = (upload ? 250_000 : 1_000_000) * (worker % 2 + 1)
                    let cap = upload ? Self.uploadCap : Self.downloadCap
                    while !Task.isCancelled, clock.now - start < duration {
                        let t0 = clock.now
                        let ok: Bool
                        if upload, let payload {
                            var req = URLRequest(url: Self.uploadURL)
                            req.httpMethod = "POST"
                            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                            ok = await engine.upload(req, body: payload.prefix(size))
                        } else {
                            ok = await engine.download(URLRequest(url: Self.downloadURL(bytes: size)))
                        }
                        if Task.isCancelled { break }
                        if !ok {
                            try? await Task.sleep(for: .milliseconds(250))
                            continue
                        }
                        size = SpeedMath.nextSize(current: size, lastDuration: (clock.now - t0).seconds, cap: cap)
                    }
                }
            }
            // Sampler, on the group's own task.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                let t = (clock.now - start).seconds
                let bytes = (upload ? engine.sentBytes : engine.receivedBytes) - baseline
                samples.append((t, bytes))
                onSample(SpeedMath.windowRate(samples: samples, window: 1.0), t / total)
                if t >= total { break }
            }
            group.cancelAll()
        }
        let bytes = samples.last?.bytes ?? 0
        return (SpeedMath.throughput(samples: samples, warmup: 1.5), bytes)
    }

    private static func randomData(count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        return data
    }
}

// MARK: - Transfer engine

/// One URLSession whose delegate counts bytes as they move, so throughput can be sampled live.
private final class TransferEngine: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var received: Int64 = 0
        var sent: Int64 = 0
        var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]
        var metrics: [Int: URLSessionTaskMetrics] = [:]
    }
    private let state = Mutex(State())
    nonisolated(unsafe) private var session: URLSession!

    init(parallelism: Int) {
        super.init()
        let config = InternetInfoService.privateConfiguration()
        config.httpMaximumConnectionsPerHost = parallelism + 1
        config.timeoutIntervalForRequest = 15
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    func invalidate() { session.invalidateAndCancel() }

    var receivedBytes: Int64 { state.withLock { $0.received } }
    var sentBytes: Int64 { state.withLock { $0.sent } }

    func download(_ request: URLRequest) async -> Bool {
        await perform(session.dataTask(with: request))
    }

    func upload(_ request: URLRequest, body: Data) async -> Bool {
        await perform(session.uploadTask(with: request, from: body))
    }

    /// Request-to-first-byte minus the server's processing time, in ms.
    func httpRTT(_ url: URL) async -> Double? {
        let task = session.dataTask(with: URLRequest(url: url))
        guard await perform(task) else { return nil }
        let m = state.withLock { $0.metrics.removeValue(forKey: task.taskIdentifier) }
        guard let tx = m?.transactionMetrics.last,
            let reqStart = tx.requestStartDate, let respStart = tx.responseStartDate
        else { return nil }
        let ttfb = respStart.timeIntervalSince(reqStart) * 1000
        let server =
            SpeedMath.serverTimeMs(
                (task.response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Server-Timing")) ?? 0
        return max(ttfb - server, ttfb * 0.1)
    }

    private func perform(_ task: URLSessionTask) async -> Bool {
        let id = task.taskIdentifier
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                guard !Task.isCancelled else {
                    c.resume(returning: false)
                    return
                }
                state.withLock { $0.waiters[id] = c }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let n = Int64(data.count)
        state.withLock { $0.received += n }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        state.withLock { $0.sent += bytesSent }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        state.withLock { $0.metrics[task.taskIdentifier] = metrics }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let ok = error == nil && (200..<300).contains(status)
        let c = state.withLock { s -> CheckedContinuation<Bool, Never>? in
            if !ok { s.metrics[task.taskIdentifier] = nil }
            return s.waiters.removeValue(forKey: task.taskIdentifier)
        }
        c?.resume(returning: ok)
    }
}
