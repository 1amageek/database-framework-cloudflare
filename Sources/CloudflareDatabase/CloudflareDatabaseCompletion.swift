import DatabaseValue

/// Synchronous completion boundary from the runtime to its Durable Object owner.
public protocol CloudflareDatabaseCompletion: AnyObject, Sendable {
    /// The receiver must copy `payload` before this method returns.
    func complete(
        callID: UInt32,
        status: CloudflareDatabaseCompletionStatus,
        payload: DatabaseBytes
    )
}
