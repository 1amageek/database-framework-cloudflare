import StorageKit

/// Cancellable monotonic clock for one Cloudflare database runtime.
public struct CloudflareDatabaseMonotonicClock: StorageMonotonicClock {
    private static let clock = ContinuousClock()
    private static let origin = clock.now

    public init() {}

    public var now: StorageInstant {
        StorageInstant(
            durationSinceReference: Self.origin.duration(to: Self.clock.now)
        )
    }

    public func sleep(
        until deadline: StorageInstant
    ) async throws {
        let remaining = now.duration(to: deadline)
        guard remaining > .zero else {
            return
        }
        #if arch(wasm32)
        try await CloudflareDatabaseClockService.shared.sleep(for: remaining)
        #else
        try await Self.clock.sleep(for: remaining)
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
