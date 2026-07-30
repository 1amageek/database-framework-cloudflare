#if arch(wasm32)
import Synchronization

@_extern(wasm, module: "database_clock", name: "schedule")
private func scheduleDatabaseClockWait(
    _ waitID: UInt32,
    _ delayMilliseconds: Double
)

@_extern(wasm, module: "database_clock", name: "cancel")
private func cancelDatabaseClockWait(_ waitID: UInt32)

final class CloudflareDatabaseClockService: Sendable {
    static let shared = CloudflareDatabaseClockService(
        maximumWaitCount: 4_096
    )

    private struct State: Sendable {
        var nextWaitID: UInt32 = 1
        var waits: [UInt32: CloudflareDatabaseScheduledWait] = [:]
    }

    private static let maximumWaitID: UInt32 = 0x7fff_ffff

    private let maximumWaitCount: Int
    private let state = Mutex(State())

    init(maximumWaitCount: Int) {
        precondition(
            maximumWaitCount > 0,
            "Maximum database clock wait count must be positive"
        )
        self.maximumWaitCount = maximumWaitCount
    }

    func sleep(for duration: Duration) async throws {
        guard duration > .zero else {
            return
        }
        let delayMilliseconds = Self.milliseconds(
            duration
        )
        let wait = try reserveWait()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard wait.install(continuation) else {
                    remove(wait)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard wait.beginScheduling() else {
                    return
                }
                scheduleDatabaseClockWait(
                    wait.waitID,
                    delayMilliseconds
                )
                if let cancellation = wait.finishScheduling() {
                    finishCancellation(cancellation, for: wait)
                }
            }
        } onCancel: {
            cancel(wait)
        }
    }

    func resume(waitID: UInt32) {
        precondition(waitID != 0, "Database clock wait ID must be positive")
        let wait = state.withLock { state in
            state.waits.removeValue(forKey: waitID)
        }
        guard let wait else {
            preconditionFailure("Database clock received an unknown wait ID")
        }
        wait.fire().resume()
    }

    private func reserveWait() throws -> CloudflareDatabaseScheduledWait {
        try state.withLock { state in
            guard state.waits.count < maximumWaitCount else {
                throw CloudflareDatabaseClockError.capacityExceeded(
                    maximum: maximumWaitCount
                )
            }
            while true {
                let candidate = state.nextWaitID
                state.nextWaitID = candidate == Self.maximumWaitID
                    ? 1
                    : candidate + 1
                guard state.waits[candidate] == nil else {
                    continue
                }
                let wait = CloudflareDatabaseScheduledWait(waitID: candidate)
                state.waits[candidate] = wait
                return wait
            }
        }
    }

    private func cancel(_ wait: CloudflareDatabaseScheduledWait) {
        guard let cancellation = wait.cancel() else {
            return
        }
        finishCancellation(cancellation, for: wait)
    }

    private func finishCancellation(
        _ cancellation: CloudflareDatabaseScheduledWait.Cancellation,
        for wait: CloudflareDatabaseScheduledWait
    ) {
        remove(wait)
        if cancellation.requiresPlatformCancellation {
            cancelDatabaseClockWait(wait.waitID)
        }
        cancellation.continuation.resume(throwing: CancellationError())
    }

    private func remove(_ wait: CloudflareDatabaseScheduledWait) {
        state.withLock { state in
            guard state.waits[wait.waitID] === wait else {
                return
            }
            state.waits.removeValue(forKey: wait.waitID)
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return max(
            0,
            Double(components.seconds) * 1_000
                + Double(components.attoseconds)
                    / 1_000_000_000_000_000
        )
    }
}
#endif
