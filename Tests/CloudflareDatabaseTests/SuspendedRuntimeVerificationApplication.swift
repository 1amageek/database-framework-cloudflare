import CloudflareDatabase
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseTypes

final class SuspendedRuntimeVerificationApplication:
    CloudflareDatabaseApplication,
    Sendable
{
    fileprivate actor Gate {
        private var wasEntered = false
        private var isReleased = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func waitUntilEntered() async {
            guard !wasEntered else { return }
            await withCheckedContinuation { continuation in
                entryWaiters.append(continuation)
            }
        }

        func enterAndWait() async {
            wasEntered = true
            let waiters = entryWaiters
            entryWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
            guard !isReleased else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func release() {
            guard !isReleased else { return }
            isReleased = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    fileprivate actor Event {
        private var hasOccurred = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !hasOccurred else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func signal() {
            guard !hasOccurred else { return }
            hasOccurred = true
            let waiters = waiters
            self.waiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    actor Session: CloudflareDatabaseSession {
        private let wrapped: RuntimeVerificationSession
        private let invocationGate: Gate
        private let shutdownEvent: Event

        fileprivate init(
            wrapped: RuntimeVerificationSession,
            invocationGate: Gate,
            shutdownEvent: Event
        ) {
            self.wrapped = wrapped
            self.invocationGate = invocationGate
            self.shutdownEvent = shutdownEvent
        }

        func respond(
            to invocation: CloudflareDatabaseInvocation
        ) async throws -> ByteString {
            if Self.string(from: invocation.request) == "suspend" {
                await invocationGate.enterAndWait()
                return ByteString(utf8: "released")
            }
            return try await wrapped.respond(to: invocation)
        }

        func shutdown() async {
            await wrapped.shutdown()
            await shutdownEvent.signal()
        }

        private static func string(from bytes: ByteString) -> String {
            bytes.withUnsafeBytes { buffer in
                String(decoding: buffer, as: UTF8.self)
            }
        }
    }

    private let application: RuntimeVerificationApplication
    private let definitionGate = Gate()
    private let invocationGate = Gate()
    private let shutdownEvent = Event()

    init() throws {
        self.application = try RuntimeVerificationApplication()
    }

    func waitUntilDefinitionIsRequested() async {
        await definitionGate.waitUntilEntered()
    }

    func releaseDefinition() async {
        await definitionGate.release()
    }

    func waitUntilInvocationStarts() async {
        await invocationGate.waitUntilEntered()
    }

    func releaseInvocation() async {
        await invocationGate.release()
    }

    func waitUntilSessionShutdown() async {
        await shutdownEvent.wait()
    }

    func makeDefinition() async throws -> CloudflareDatabaseDefinition {
        await definitionGate.enterAndWait()
        return try await application.makeDefinition()
    }

    func makeSession(for container: DBContainer) async throws -> Session {
        Session(
            wrapped: try await application.makeSession(for: container),
            invocationGate: invocationGate,
            shutdownEvent: shutdownEvent
        )
    }
}
