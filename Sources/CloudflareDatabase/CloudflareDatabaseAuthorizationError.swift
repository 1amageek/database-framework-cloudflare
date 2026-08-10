/// Malformed host authorization supplied across the Cloudflare reactor boundary.
public enum CloudflareDatabaseAuthorizationError:
    Error,
    Sendable,
    Equatable {
    case frameTooLarge(actual: Int, maximum: Int)
    case invalidMagic
    case unsupportedVersion(UInt16)
    case invalidPrincipalIdentifier
    case tooManyRoles(actual: Int, maximum: Int)
    case invalidRole
    case nonCanonicalRoles
    case malformedClaims
    case trailingBytes
}
