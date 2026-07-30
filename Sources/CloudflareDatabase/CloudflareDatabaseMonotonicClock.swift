import StorageKit

#if arch(wasm32)
@_extern(wasm, module: "database_clock", name: "monotonic_nanoseconds")
private func databaseMonotonicNanoseconds() -> Int64
#endif

/// Cancellable monotonic clock for one Cloudflare database runtime.
public struct CloudflareDatabaseMonotonicClock: StorageMonotonicClock {
    #if !arch(wasm32)
    private static let clock = ContinuousClock()
    private static let origin = clock.now
    #endif

    public init() {}

    public var now: StorageInstant {
        #if arch(wasm32)
        return StorageInstant(
            durationSinceReference: .nanoseconds(
                databaseMonotonicNanoseconds()
            )
        )
        #else
        StorageInstant(
            durationSinceReference: Self.origin.duration(to: Self.clock.now)
        )
        #endif
    }

    public func sleep(
        until deadline: StorageInstant
    ) async throws(StorageClockError) {
        let remaining = now.duration(to: deadline)
        guard remaining > .zero else {
            return
        }
        #if arch(wasm32)
        do {
            try await CloudflareDatabaseClockService.shared.sleep(for: remaining)
        } catch is CancellationError {
            throw .cancelled
        } catch let error as CloudflareDatabaseClockError {
            switch error {
            case .capacityExceeded(let maximum):
                throw .capacityExceeded(maximumWaitCount: maximum)
            }
        } catch {
            throw .unavailable
        }
        #else
        do {
            try await Self.clock.sleep(for: remaining)
        } catch {
            throw .cancelled
        }
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
