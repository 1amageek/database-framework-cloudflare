#if arch(wasm32)
import DatabaseEngine
import DatabaseTypes

@_extern(wasm, module: "database_clock", name: "wall_time_milliseconds")
private func databaseWallTimeMilliseconds() -> Int64

/// Absolute time supplied by the Cloudflare runtime host.
public struct CloudflareDatabaseWallClock: WallClock {
    public init() {}

    public var now: Timestamp {
        let milliseconds = databaseWallTimeMilliseconds()
        let seconds = milliseconds / 1_000
        let remainder = milliseconds % 1_000
        let normalizedSeconds = remainder < 0 ? seconds - 1 : seconds
        let normalizedMilliseconds = remainder < 0
            ? remainder + 1_000
            : remainder
        do {
            return try Timestamp(
                secondsSinceUnixEpoch: normalizedSeconds,
                nanoseconds: UInt32(normalizedMilliseconds) * 1_000_000
            )
        } catch {
            preconditionFailure(
                "Cloudflare returned an invalid wall-clock timestamp"
            )
        }
    }
}
#endif
