import StorageKit

/// Cancellable monotonic clock for one Cloudflare database runtime.
public struct CloudflareDatabaseMonotonicClock: StorageMonotonicClock {
    public init() {}

    public var now: ContinuousClock.Instant {
        ContinuousClock().now
    }

    public func sleep(
        until deadline: ContinuousClock.Instant
    ) async throws {
        #if arch(wasm32)
        try await CloudflareDatabaseClockService.shared.sleep(
            until: deadline
        )
        #else
        try await ContinuousClock().sleep(until: deadline)
        #endif
    }

    static func resume(waitID: UInt32) {
        #if arch(wasm32)
        CloudflareDatabaseClockService.shared.resume(waitID: waitID)
        #else
        preconditionFailure(
            "Cloudflare database clock waits only resume in its runtime"
        )
        #endif
    }
}
