import DatabaseEngine

/// Storage response returned by the Durable Object host.
public enum DatabaseStorageHostResponse: Sendable, Hashable {
    case read([UInt8]?)
    case scan([DatabaseKeyValue])
    case committed
    case failure(String)
}
