enum RuntimeVerificationError: Error {
    case documentNotFound
    case invalidApplicationRequest
    case simulatedReadinessFailure
    case simulatedSessionCreationFailure
    case simulatedStorageInitializationFailure
    case unauthorizedContext
    case unexpectedStorageAccess
}
