import DatabaseValue
import Synchronization

/// Owns invocation payloads until the database runtime adopts them.
public final class DatabaseInvocationPayloadOwnership: Sendable {
    private struct PayloadReservation: Sendable {
        let payloadAddress: UInt32
        let address: UInt
        let byteCount: UInt32
    }

    private struct OwnershipState: Sendable {
        var reservations: [PayloadReservation] = []
        var ownedPayloadCount = 0
        var ownedPayloadBytes = 0
    }

    private let maximumPayloadBytes: Int
    private let maximumOwnedPayloadCount: Int
    private let maximumOwnedPayloadBytes: Int
    private let ownershipState = Mutex(OwnershipState())

    public init(
        maximumPayloadBytes: Int,
        maximumOwnedPayloadCount: Int,
        maximumOwnedPayloadBytes: Int
    ) {
        precondition(maximumPayloadBytes > 0)
        precondition(maximumOwnedPayloadCount > 0)
        precondition(maximumOwnedPayloadBytes >= maximumPayloadBytes)
        self.maximumPayloadBytes = maximumPayloadBytes
        self.maximumOwnedPayloadCount = maximumOwnedPayloadCount
        self.maximumOwnedPayloadBytes = maximumOwnedPayloadBytes
    }

    public func reservePayload(byteCount: UInt32) -> UInt32 {
        guard byteCount > 0 else {
            return 0
        }
#if arch(wasm32)
        guard let requestedBytes = Int(exactly: byteCount),
              requestedBytes <= maximumPayloadBytes else {
            return 0
        }
        return ownershipState.withLock { state in
            guard state.ownedPayloadCount < maximumOwnedPayloadCount else {
                return 0
            }
            let nextOwnedPayloadBytes = state.ownedPayloadBytes + requestedBytes
            guard nextOwnedPayloadBytes >= state.ownedPayloadBytes,
                  nextOwnedPayloadBytes <= maximumOwnedPayloadBytes else {
                return 0
            }
            let reservedPayload = UnsafeMutableRawPointer.allocate(
                byteCount: requestedBytes,
                alignment: MemoryLayout<UInt8>.alignment
            )
            let address = UInt(bitPattern: reservedPayload)
            guard let payloadAddress = UInt32(exactly: address) else {
                reservedPayload.deallocate()
                return 0
            }
            let insertionIndex = Self.insertionIndex(
                for: payloadAddress,
                in: state.reservations
            )
            state.reservations.insert(
                PayloadReservation(
                    payloadAddress: payloadAddress,
                    address: address,
                    byteCount: byteCount
                ),
                at: insertionIndex
            )
            state.ownedPayloadCount += 1
            state.ownedPayloadBytes = nextOwnedPayloadBytes
            return payloadAddress
        }
#else
        return 0
#endif
    }

    /// Releases a payload that has not transferred into runtime ownership.
    public func releasePayload(payloadAddress: UInt32, byteCount: UInt32) {
        if payloadAddress == 0 {
            precondition(
                byteCount == 0,
                "A zero payload address must have zero length"
            )
            return
        }
        guard let reservation = remove(payloadAddress: payloadAddress) else {
            preconditionFailure("Runtime owner released an unknown payload")
        }
        guard reservation.byteCount == byteCount else {
            release(reservation)
            preconditionFailure(
                "Runtime owner released a payload with the wrong length"
            )
        }
        release(reservation)
    }

    /// Transfers one reserved payload into an immutable async-safe owner.
    public func consumePayload(
        payloadAddress: UInt32,
        byteCount: UInt32
    ) throws(DatabaseInvocationPayloadError) -> DatabaseBytes {
        guard byteCount > 0 else {
            guard payloadAddress == 0 else {
                if let reservation = remove(payloadAddress: payloadAddress) {
                    release(reservation)
                }
                throw .nonzeroEmptyPayloadAddress(payloadAddress)
            }
            return []
        }
        guard payloadAddress != 0,
              let reservation = remove(payloadAddress: payloadAddress) else {
            throw .unknownPayload(payloadAddress)
        }
        guard reservation.byteCount == byteCount else {
            release(reservation)
            throw .lengthMismatch(
                expected: reservation.byteCount,
                actual: byteCount
            )
        }
        return DatabaseBytes(
            allocation: DatabaseByteAllocation(
                unsafeAddress: reservation.address,
                count: Int(reservation.byteCount),
                deallocator: { address, count in
                    self.releaseConsumedPayload(
                        address: address,
                        byteCount: count
                    )
                }
            )
        )
    }

    private func remove(payloadAddress: UInt32) -> PayloadReservation? {
        ownershipState.withLock { state in
            guard let index = state.reservations.firstIndex(
                where: { $0.payloadAddress == payloadAddress }
            ) else {
                return nil
            }
            return state.reservations.remove(at: index)
        }
    }

    private func release(_ reservation: PayloadReservation) {
        recordDeallocation(byteCount: Int(reservation.byteCount))
        Self.deallocate(address: reservation.address)
    }

    private func releaseConsumedPayload(address: UInt, byteCount: Int) {
        precondition(byteCount > 0)
        recordDeallocation(byteCount: byteCount)
        Self.deallocate(address: address)
    }

    private func recordDeallocation(byteCount: Int) {
        ownershipState.withLock { state in
            precondition(state.ownedPayloadCount > 0)
            precondition(state.ownedPayloadBytes >= byteCount)
            state.ownedPayloadCount -= 1
            state.ownedPayloadBytes -= byteCount
        }
    }

    private static func insertionIndex(
        for payloadAddress: UInt32,
        in reservations: [PayloadReservation]
    ) -> Int {
        var lowerBound = reservations.startIndex
        var upperBound = reservations.endIndex
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if reservations[middle].payloadAddress >= payloadAddress {
                upperBound = middle
            } else {
                lowerBound = middle + 1
            }
        }
        return lowerBound
    }

    private static func deallocate(address: UInt) {
        guard let payload = UnsafeMutableRawPointer(bitPattern: address) else {
            return
        }
        payload.deallocate()
    }
}
