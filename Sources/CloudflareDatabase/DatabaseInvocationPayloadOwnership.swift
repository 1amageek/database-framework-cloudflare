import DatabaseTypes
import Synchronization

/// Owns invocation payloads until the database runtime adopts them.
public final class DatabaseInvocationPayloadOwnership: Sendable {
    private struct PayloadReservation: Sendable {
        let address: UInt
        let byteCount: UInt32
    }

    private struct OwnershipState: Sendable {
        var reservations: [UInt32: PayloadReservation] = [:]
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
            guard let nextOwnedPayloadBytes = Self.admittedOwnedPayloadByteCount(
                currentByteCount: state.ownedPayloadBytes,
                requestedByteCount: requestedBytes,
                maximumByteCount: maximumOwnedPayloadBytes
            ) else {
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
            precondition(
                state.reservations[payloadAddress] == nil,
                "Runtime allocator returned an address that is already owned"
            )
            state.reservations[payloadAddress] = PayloadReservation(
                address: address,
                byteCount: byteCount
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
    ) throws(DatabaseInvocationPayloadError) -> ByteString {
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
        return ByteString(
            retaining: InvocationPayloadOwner(
                address: reservation.address,
                count: Int(reservation.byteCount),
                release: { address, count in
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
            state.reservations.removeValue(forKey: payloadAddress)
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

    private static func deallocate(address: UInt) {
        guard let payload = UnsafeMutableRawPointer(bitPattern: address) else {
            return
        }
        payload.deallocate()
    }

    static func admittedOwnedPayloadByteCount(
        currentByteCount: Int,
        requestedByteCount: Int,
        maximumByteCount: Int
    ) -> Int? {
        let (result, overflow) = currentByteCount.addingReportingOverflow(
            requestedByteCount
        )
        guard !overflow, result <= maximumByteCount else {
            return nil
        }
        return result
    }
}
