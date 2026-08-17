enum RuntimeVerificationError: Error {
    case documentNotFound
    case invalidApplicationRequest
    case unauthorizedContext
    case unexpectedVectorResult
}
