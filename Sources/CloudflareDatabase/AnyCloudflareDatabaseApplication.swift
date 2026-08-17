import DatabaseEngine

/// Type-erased application composition retained by the Cloudflare runtime.
public struct AnyCloudflareDatabaseApplication: Sendable {
    private let createDefinition: @Sendable () async throws
        -> CloudflareDatabaseDefinition
    private let createSession: @Sendable (DBContainer) async throws
        -> AnyCloudflareDatabaseSession

    public init<Application: CloudflareDatabaseApplication>(
        _ application: Application
    ) {
        self.createDefinition = {
            try await application.makeDefinition()
        }
        self.createSession = { container in
            AnyCloudflareDatabaseSession(
                try await application.makeSession(for: container)
            )
        }
    }

    public func makeDefinition() async throws -> CloudflareDatabaseDefinition {
        try await createDefinition()
    }

    public func makeSession(
        for container: DBContainer
    ) async throws -> AnyCloudflareDatabaseSession {
        try await createSession(container)
    }
}
