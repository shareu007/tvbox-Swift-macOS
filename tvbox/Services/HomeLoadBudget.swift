import Foundation

/// One deadline covers homepage, category previews and automatic source recovery.
/// Waiting ends even when a third-party loader does not cooperate with cancellation.
@MainActor
final class HomeLoadBudget {
    enum Failure: Error { case timedOut }
    private let deadline: ContinuousClock.Instant
    private let requestSeconds: Double
    private var pending: [UUID: () -> Void] = [:]
    private(set) var isCancelled = false
    var isExpired: Bool { ContinuousClock.now >= deadline }
    var isFinished: Bool { isCancelled || isExpired }

    init(seconds: Double = 20, requestSeconds: Double = 6) {
        deadline = .now.advanced(by: .seconds(seconds))
        self.requestSeconds = requestSeconds
    }

    func cancel() {
        isCancelled = true
        let cancellations = Array(pending.values)
        pending.removeAll()
        cancellations.forEach { $0() }
    }

    func run<Value>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard !isCancelled else { throw CancellationError() }
        guard !isExpired else { throw Failure.timedOut }
        let id = UUID()
        let race = HomeRequestRace<Value>()
        let remaining = ContinuousClock.now.duration(to: deadline)
        let duration = min(remaining, .seconds(requestSeconds))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.continuation = continuation
                race.onFinish = { [weak self] in self?.pending[id] = nil }
                pending[id] = { race.finish(.failure(CancellationError())) }
                race.work = Task { @MainActor in
                    do { race.finish(.success(try await operation())) }
                    catch { race.finish(.failure(error)) }
                }
                race.timer = Task { @MainActor in
                    do {
                        try await Task.sleep(for: duration)
                        race.finish(.failure(Failure.timedOut))
                    } catch { }
                }
            }
        } onCancel: {
            Task { @MainActor in race.finish(.failure(CancellationError())) }
        }
    }
}

@MainActor
private final class HomeRequestRace<Value> {
    var continuation: CheckedContinuation<Value, Error>?
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?
    var onFinish: (() -> Void)?

    func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        work?.cancel()
        timer?.cancel()
        work = nil
        timer = nil
        onFinish?()
        onFinish = nil
        continuation.resume(with: result)
    }
}
