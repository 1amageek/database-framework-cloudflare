enum RuntimeVerificationError: Error {
    case documentNotFound
    case graphAssertion(String)
    case invalidApplicationRequest
    case unauthorizedContext
    case unexpectedVectorResult
}
