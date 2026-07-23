#if arch(wasm32)
import Synchronization

final class CloudflareDatabaseScheduledWait: Sendable {
    struct Cancellation: Sendable {
        let continuation: CheckedContinuation<Void, any Error>
        let requiresPlatformCancellation: Bool
    }

    private enum Phase: Sendable {
        case idle(cancellationRequested: Bool)
        case waiting(CheckedContinuation<Void, any Error>)
        case scheduling(
            CheckedContinuation<Void, any Error>,
            cancellationRequested: Bool
        )
        case scheduled(CheckedContinuation<Void, any Error>)
        case finished
    }

    let waitID: UInt32
    private let phase = Mutex(Phase.idle(cancellationRequested: false))

    init(waitID: UInt32) {
        self.waitID = waitID
    }

    func install(
        _ continuation: CheckedContinuation<Void, any Error>
    ) -> Bool {
        phase.withLock { phase in
            switch phase {
            case .idle(cancellationRequested: false):
                phase = .waiting(continuation)
                return true
            case .idle(cancellationRequested: true):
                phase = .finished
                return false
            case .waiting, .scheduling, .scheduled, .finished:
                preconditionFailure("Database clock wait was installed twice")
            }
        }
    }

    func beginScheduling() -> Bool {
        phase.withLock { phase in
            switch phase {
            case .waiting(let continuation):
                phase = .scheduling(
                    continuation,
                    cancellationRequested: false
                )
                return true
            case .finished:
                return false
            case .idle, .scheduling, .scheduled:
                preconditionFailure(
                    "Database clock wait entered an invalid scheduling phase"
                )
            }
        }
    }

    func finishScheduling() -> Cancellation? {
        phase.withLock { phase in
            switch phase {
            case .scheduling(
                let continuation,
                cancellationRequested: false
            ):
                phase = .scheduled(continuation)
                return nil
            case .scheduling(
                let continuation,
                cancellationRequested: true
            ):
                phase = .finished
                return Cancellation(
                    continuation: continuation,
                    requiresPlatformCancellation: true
                )
            case .idle, .waiting, .scheduled, .finished:
                preconditionFailure(
                    "Database clock wait finished an invalid scheduling phase"
                )
            }
        }
    }

    func cancel() -> Cancellation? {
        phase.withLock { phase in
            switch phase {
            case .idle:
                phase = .idle(cancellationRequested: true)
                return nil
            case .waiting(let continuation):
                phase = .finished
                return Cancellation(
                    continuation: continuation,
                    requiresPlatformCancellation: false
                )
            case .scheduling(let continuation, _):
                phase = .scheduling(
                    continuation,
                    cancellationRequested: true
                )
                return nil
            case .scheduled(let continuation):
                phase = .finished
                return Cancellation(
                    continuation: continuation,
                    requiresPlatformCancellation: true
                )
            case .finished:
                return nil
            }
        }
    }

    func fire() -> CheckedContinuation<Void, any Error> {
        phase.withLock { phase in
            guard case .scheduled(let continuation) = phase else {
                preconditionFailure(
                    "Database clock fired a wait that was not scheduled"
                )
            }
            phase = .finished
            return continuation
        }
    }
}
#endif
