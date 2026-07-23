public enum DatabaseInvocationPayloadError: Error, Sendable, Equatable {
    case unknownPayload(UInt32)
    case nonzeroEmptyPayloadAddress(UInt32)
    case lengthMismatch(expected: UInt32, actual: UInt32)
}
