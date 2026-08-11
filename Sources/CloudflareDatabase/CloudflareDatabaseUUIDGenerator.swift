#if arch(wasm32)
import DatabaseEngine
import DatabaseTypes

@_extern(wasm, module: "database_random", name: "random_u64")
private func databaseRandomUInt64() -> UInt64

/// UUID generation backed by the Cloudflare runtime's cryptographic entropy.
public struct CloudflareDatabaseUUIDGenerator: DatabaseUUIDGenerator {
    public init() {}

    public func generate() -> DatabaseTypes.UUID {
        let high = (databaseRandomUInt64() & 0xffff_ffff_ffff_0fff) | 0x4000
        let low = (databaseRandomUInt64() & 0x3fff_ffff_ffff_ffff)
            | 0x8000_0000_0000_0000
        return DatabaseTypes.UUID(high: high, low: low)
    }
}
#endif
