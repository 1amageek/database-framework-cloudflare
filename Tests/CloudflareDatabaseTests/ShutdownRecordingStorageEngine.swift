import StorageKit
import Synchronization

final class ShutdownRecordingStorageEngine: StorageEngine, Sendable {
    struct Configuration: Sendable {
        let probe: Probe
        let rejectsTransactionCreation: Bool
    }

    struct ShutdownState: Sendable, Equatable {
        var wasRequested = false
        var didComplete = false
    }

    final class Probe: Sendable {
        private let state = Mutex(ShutdownState())

        var shutdownState: ShutdownState {
            state.withLock { $0 }
        }

        fileprivate func recordRequest() {
            state.withLock { state in
                state.wasRequested = true
            }
        }

        fileprivate func recordCompletion() {
            state.withLock { state in
                state.didComplete = true
            }
        }
    }

    typealias TransactionType = InMemoryTransaction

    private let backing: InMemoryEngine
    private let probe: Probe
    private let rejectsTransactionCreation: Bool

    init(configuration: Configuration) async throws {
        self.backing = try await InMemoryEngine(configuration: .init())
        self.probe = configuration.probe
        self.rejectsTransactionCreation =
            configuration.rejectsTransactionCreation
    }

    func createTransaction() throws -> InMemoryTransaction {
        guard !rejectsTransactionCreation else {
            throw RuntimeVerificationError.simulatedStorageInitializationFailure
        }
        return try backing.createTransaction()
    }

    func requestShutdown() {
        probe.recordRequest()
        backing.requestShutdown()
    }

    func waitUntilShutdown() async {
        requestShutdown()
        await backing.waitUntilShutdown()
        probe.recordCompletion()
    }
}
