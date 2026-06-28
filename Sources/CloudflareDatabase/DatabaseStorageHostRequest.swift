import DatabaseEngine

/// Storage request sent from Swift WASM to the Durable Object host.
public enum DatabaseStorageHostRequest: Sendable, Hashable {
    case read(key: [UInt8])
    case scan(begin: [UInt8], end: [UInt8], limit: Int, reverse: Bool)
    case commit([DatabaseWriteOperation])
}
