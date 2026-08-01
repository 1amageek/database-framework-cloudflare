#if CLOUDFLARE_RUNTIME_VECTOR_INDEXES
enum RuntimeVerificationError: Error {
    case vectorExecutionMismatch
}
#endif
