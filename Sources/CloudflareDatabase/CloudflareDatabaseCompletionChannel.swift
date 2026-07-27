import DatabaseTypes

#if arch(wasm32)
@_extern(wasm, module: "database_host", name: "complete")
private func deliverDatabaseCompletion(
    _ callID: UInt32,
    _ status: UInt32,
    _ payloadAddress: UInt32,
    _ byteCount: UInt32
)
#endif

/// Concrete completion channel shared by the runtime and its owner boundary.
public final class CloudflareDatabaseCompletionChannel: Sendable {
#if !arch(wasm32)
    private let completion: any CloudflareDatabaseCompletion

    public init(completion: any CloudflareDatabaseCompletion) {
        self.completion = completion
    }
#else
    public init() {}
#endif

    public func complete(
        callID: UInt32,
        status: CloudflareDatabaseCompletionStatus,
        payload: ByteString
    ) {
#if arch(wasm32)
        guard let byteCount = UInt32(exactly: payload.count) else {
            deliverDatabaseCompletion(callID, status.rawValue, 0, 0)
            return
        }
        payload.withUnsafeBytes { buffer in
            let payloadAddress = buffer.baseAddress.map {
                UInt32(truncatingIfNeeded: UInt(bitPattern: $0))
            } ?? 0
            deliverDatabaseCompletion(
                callID,
                status.rawValue,
                payloadAddress,
                byteCount
            )
        }
#else
        completion.complete(
            callID: callID,
            status: status,
            payload: payload
        )
#endif
    }
}
