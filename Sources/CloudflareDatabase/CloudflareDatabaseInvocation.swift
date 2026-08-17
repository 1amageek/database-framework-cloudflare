import DatabaseTypes

/// Opaque application input transferred across the private reactor boundary.
public struct CloudflareDatabaseInvocation: Sendable {
    public let context: ByteString
    public let request: ByteString

    public init(context: ByteString, request: ByteString) {
        self.context = context
        self.request = request
    }
}
