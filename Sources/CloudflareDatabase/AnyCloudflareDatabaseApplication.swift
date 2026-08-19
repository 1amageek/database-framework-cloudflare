import DatabaseEngine

/// Type-erased application composition retained by the Cloudflare runtime.
public struct AnyCloudflareDatabaseApplication: Sendable {
    private let readConfiguration:
        @Sendable () async throws
            -> CloudflareDatabaseConfiguration
    private let createSession:
        @Sendable (DBContainer) async throws
            -> AnyCloudflareDatabaseSession

    public init<Application: CloudflareDatabaseApplication>(
        _ application: Application
    ) {
        self.readConfiguration = {
            try await application.configuration
        }
        self.createSession = { database in
            AnyCloudflareDatabaseSession(
                try await application.makeSession(for: database)
            )
        }
    }

    public var configuration: CloudflareDatabaseConfiguration {
        get async throws {
            try await readConfiguration()
        }
    }

    public func makeSession(
        for database: DBContainer
    ) async throws -> AnyCloudflareDatabaseSession {
        try await createSession(database)
    }
}
