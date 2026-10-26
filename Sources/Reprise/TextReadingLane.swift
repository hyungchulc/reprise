import Foundation

/// Vision text requests run here one at a time on a queue of their own, and a caller waits for its
/// request only so long. A request can hang inside Vision for good: after the macOS 27.2 update the
/// first one waited on the Neural Engine compiler and never returned, and capture, which waited for
/// it, saved no screen until Reprise was restarted (2026-10-26). Two requests at once deadlocked
/// inside Vision (0.8.1-alpha.1 and alpha.2), so a hung request is never run around: until it
/// returns, others are refused at once. A request that cannot be stopped ends only with the app.
final class TextReadingLane: @unchecked Sendable {
    static let shared = TextReadingLane()

    enum Failure: LocalizedError {
        /// The request before is still running after `hungAfter`.
        case hung
        /// The caller stopped waiting; its request is skipped, or its result dropped.
        case timedOut
        var errorDescription: String? {
            switch self {
            case .hung: "Text recognition is not responding."
            case .timedOut: "Text recognition took too long."
            }
        }
    }

    /// Reads that failed in a row, and when the first of them failed. A read that works clears it.
    struct Trouble {
        var since: Date
        var failures: Int
    }

    let hungAfter: TimeInterval
    private let queue = DispatchQueue(label: "local.aria.reprise.text-reading", autoreleaseFrequency: .workItem)
    private let lock = NSLock()
    private var started: Date?
    private var problem: Trouble?
    /// Used only on `queue`.
    private let reader = TextRecognizer()

    init(hungAfter: TimeInterval = 20) { self.hungAfter = hungAfter }

    var trouble: Trouble? { lock.withLock { problem } }

    /// Runs `work` with the lane's reader once the requests before it are done, waiting at most
    /// `limit` seconds in all. Requests take the caller's priority.
    func run<T: Sendable>(waitingAtMost limit: TimeInterval, _ work: @escaping @Sendable (TextRecognizer) throws -> T) async throws -> T {
        let hung = lock.withLock { started.map { Date().timeIntervalSince($0) >= hungAfter } ?? false }
        if hung { failed(); throw Failure.hung }
        let job = Job(work)
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    job.wait(continuation)
                    queue.async { [self] in
                        guard let work = job.begin() else { return }
                        lock.withLock { started = Date() }
                        let result = Result { try work(reader) }
                        lock.withLock {
                            started = nil
                            if case .success = result { problem = nil }
                        }
                        job.finish(result)
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + max(0, limit)) { job.finish(.failure(Failure.timedOut)) }
                }
            } onCancel: {
                job.finish(.failure(CancellationError()))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            failed()
            throw error
        }
    }

    private func failed() {
        lock.withLock {
            if problem == nil { problem = Trouble(since: Date(), failures: 0) }
            problem?.failures += 1
        }
    }
}

/// One request's answer, taken by whichever comes first: the request, the time limit or cancelling.
private final class Job<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    /// Let go once the caller stops waiting, with the screen it holds.
    private var work: (@Sendable (TextRecognizer) throws -> T)?
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?

    init(_ work: @escaping @Sendable (TextRecognizer) throws -> T) { self.work = work }

    func wait(_ continuation: CheckedContinuation<T, Error>) {
        let done: Result<T, Error>? = lock.withLock {
            if result == nil { self.continuation = continuation }
            return result
        }
        if let done { continuation.resume(with: done) }
    }

    /// Nil when the caller has stopped waiting, so the request is not started at all.
    func begin() -> (@Sendable (TextRecognizer) throws -> T)? { lock.withLock { result == nil ? work : nil } }

    func finish(_ value: Result<T, Error>) {
        let waiting: CheckedContinuation<T, Error>? = lock.withLock {
            guard result == nil else { return nil }
            result = value
            work = nil
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: value)
    }
}
