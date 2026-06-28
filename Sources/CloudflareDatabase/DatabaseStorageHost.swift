import DatabaseEngine

/// Host boundary used by the Cloudflare database runtime to access durable storage.
public protocol DatabaseStorageHost: Sendable {
    func dispatch(
        _ request: DatabaseStorageHostRequest
    ) throws(DatabaseRuntimeError) -> DatabaseStorageHostResponse
}
