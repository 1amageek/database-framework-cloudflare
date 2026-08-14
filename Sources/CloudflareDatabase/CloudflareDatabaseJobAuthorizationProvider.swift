import DatabaseKit
import DatabaseServerRuntime

/// Application-owned authentication authority used by durable database jobs.
///
/// A job persists only the opaque reference returned here. The provider must
/// resolve current roles, claims, and revocation state again for every slice.
public protocol CloudflareDatabaseJobAuthorizationProviding:
    DatabaseJobAuthorizationValidating,
    Sendable {
    func reference(
        for authorization: AuthorizationContext
    ) throws -> DatabaseJobAuthorizationReference
}

/// Type-erased Cloudflare job authorization authority.
public final class AnyCloudflareDatabaseJobAuthorizationProvider:
    DatabaseJobAuthorizationValidating,
    Sendable {
    private let makeReference: @Sendable (
        AuthorizationContext
    ) throws -> DatabaseJobAuthorizationReference
    private let revalidateReference: @Sendable (
        DatabaseJobAuthorizationReference
    ) async throws -> AuthorizationContext

    public init<Provider: CloudflareDatabaseJobAuthorizationProviding>(
        _ provider: Provider
    ) {
        self.makeReference = provider.reference
        self.revalidateReference = provider.revalidate
    }

    public func reference(
        for authorization: AuthorizationContext
    ) throws -> DatabaseJobAuthorizationReference {
        try makeReference(authorization)
    }

    public func revalidate(
        _ reference: DatabaseJobAuthorizationReference
    ) async throws -> AuthorizationContext {
        try await revalidateReference(reference)
    }
}
