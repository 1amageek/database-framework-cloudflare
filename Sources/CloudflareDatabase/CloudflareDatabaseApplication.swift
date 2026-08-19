import DatabaseEngine

/// Application-owned composition root for one Cloudflare-hosted database.
public protocol CloudflareDatabaseApplication: Sendable {
    associatedtype Session: CloudflareDatabaseSession

    /// Describes the database before the adapter creates platform storage.
    var configuration: CloudflareDatabaseConfiguration { get async throws }

    /// Performs application-owned bootstrap and creates the protocol session
    /// after the container is open. When the configuration attaches a
    /// migration plan, ordinary data operations remain unavailable until the
    /// application completes that migration through the container's
    /// administrative API.
    func makeSession(
        for database: DBContainer
    ) async throws -> Session
}
