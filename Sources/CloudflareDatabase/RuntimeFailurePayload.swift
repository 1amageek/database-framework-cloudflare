import DatabaseTypes

enum RuntimeFailurePayload {
    static let encodingFailure = "runtime.diagnostic_limit_violation"

    static func encode(
        _ message: String,
        maximumByteCount: Int
    ) -> ByteString {
        let selectedMessage =
            message.utf8.count <= maximumByteCount
            ? message
            : encodingFailure
        return ByteString.copyingUTF8(
            selectedMessage,
            maximumByteCount: maximumByteCount
        )
    }
}
