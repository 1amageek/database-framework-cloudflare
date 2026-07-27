import DatabaseTypes

/// Owns one runtime allocation after invocation payload transfer.
final class InvocationPayloadOwner: ByteStringOwner, Sendable {
    let count: Int

    private let address: UInt
    private let release: @Sendable (UInt, Int) -> Void

    init(
        address: UInt,
        count: Int,
        release: @escaping @Sendable (UInt, Int) -> Void
    ) {
        precondition(address != 0)
        precondition(count > 0)
        self.address = address
        self.count = count
        self.release = release
    }

    deinit {
        release(address, count)
    }

    func borrowBytes(
        _ body: (UnsafeRawBufferPointer) throws -> Void
    ) rethrows {
        guard let baseAddress = UnsafeRawPointer(bitPattern: address) else {
            preconditionFailure("Invocation payload owner has an invalid address")
        }
        try body(
            UnsafeRawBufferPointer(
                start: baseAddress,
                count: count
            )
        )
    }
}
