import DatabaseEngine

/// Application-owned composition root for one Cloudflare-hosted database.
public protocol CloudflareDatabaseApplication: Sendable {
    associatedtype Session: CloudflareDatabaseSession

    /// Describes the database before the adapter creates platform storage.
    func makeDefinition() async throws -> CloudflareDatabaseDefinition

    /// Creates the application protocol session after the container is open.
    func makeSession(
        for container: DBContainer
    ) async throws -> Session
}
