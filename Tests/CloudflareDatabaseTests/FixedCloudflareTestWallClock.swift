import DatabaseEngine
import DatabaseTypes

struct FixedCloudflareTestWallClock: WallClock, Sendable {
    let now = Timestamp(secondsSinceUnixEpoch: 1_787_000_000)
}
