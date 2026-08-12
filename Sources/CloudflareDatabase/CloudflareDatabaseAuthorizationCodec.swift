import DatabaseKit
import DatabaseTypes
@_spi(DatabaseOperations) import DatabaseWire

/// Canonical host-only encoding for an already authenticated principal.
///
/// Authentication remains in the application Worker. This frame carries the
/// resulting identity alongside, but never inside, the DatabaseWire request.
public enum CloudflareDatabaseAuthorizationCodec {
    public static let maximumFrameBytes = 256 * 1_024
    public static let maximumPrincipalIdentifierBytes = 1_024
    public static let maximumRoleCount = 256
    public static let maximumRoleBytes = 1_024

    private static let magic: UInt32 = 0x5541_4244
    private static let version: UInt16 = 1

    public static func encode(
        _ principal: Principal
    ) throws(CloudflareDatabaseAuthorizationError) -> ByteString {
        guard isValid(
            principal.identifier,
            maximumByteCount: maximumPrincipalIdentifierBytes
        ) else {
            throw .invalidPrincipalIdentifier
        }
        let roles = principal.roles.sorted(by: canonicalStringOrder)
        guard roles.count <= maximumRoleCount else {
            throw .tooManyRoles(
                actual: roles.count,
                maximum: maximumRoleCount
            )
        }
        guard roles.allSatisfy({
            isValid($0, maximumByteCount: maximumRoleBytes)
        }) else {
            throw .invalidRole
        }

        let encodedClaims: ByteString
        do {
            encodedClaims = try DatabaseWireWriter.encode {
                (writer: inout DatabaseWireWriter)
                    throws(DatabaseWireError) in
                try principal.claims.encode(into: &writer)
            }
        } catch {
            throw .malformedClaims
        }
        let encoded: ByteString
        do {
            encoded = try DatabaseWireWriter.encode {
                (writer: inout DatabaseWireWriter)
                    throws(DatabaseWireError) in
                writer.writeUInt32(magic)
                writer.writeUInt16(version)
                try writer.writeString(principal.identifier)
                try writer.writeCount(roles.count)
                for role in roles {
                    try writer.writeString(role)
                }
                try writer.writeBytes(encodedClaims)
            }
        } catch {
            throw .malformedClaims
        }
        guard encoded.count <= maximumFrameBytes else {
            throw .frameTooLarge(
                actual: encoded.count,
                maximum: maximumFrameBytes
            )
        }
        return encoded
    }

    public static func decode(
        _ bytes: ByteString
    ) throws(CloudflareDatabaseAuthorizationError) -> AuthorizationContext {
        guard bytes.count <= maximumFrameBytes else {
            throw .frameTooLarge(
                actual: bytes.count,
                maximum: maximumFrameBytes
            )
        }
        do {
            var reader = DatabaseWireReader(bytes)
            guard try reader.readUInt32() == magic else {
                throw CloudflareDatabaseAuthorizationError.invalidMagic
            }
            let decodedVersion = try reader.readUInt16()
            guard decodedVersion == version else {
                throw CloudflareDatabaseAuthorizationError
                    .unsupportedVersion(decodedVersion)
            }
            let identifier = try reader.readString()
            guard isValid(
                identifier,
                maximumByteCount: maximumPrincipalIdentifierBytes
            ) else {
                throw CloudflareDatabaseAuthorizationError
                    .invalidPrincipalIdentifier
            }
            let roleCount = try reader.readCount()
            guard roleCount <= maximumRoleCount else {
                throw CloudflareDatabaseAuthorizationError.tooManyRoles(
                    actual: roleCount,
                    maximum: maximumRoleCount
                )
            }
            var roles: [String] = []
            roles.reserveCapacity(roleCount)
            for _ in 0..<roleCount {
                let role = try reader.readString()
                guard isValid(
                    role,
                    maximumByteCount: maximumRoleBytes
                ) else {
                    throw CloudflareDatabaseAuthorizationError.invalidRole
                }
                if let previous = roles.last,
                   !canonicalStringOrder(previous, role) {
                    throw CloudflareDatabaseAuthorizationError
                        .nonCanonicalRoles
                }
                roles.append(role)
            }
            let encodedClaims = try reader.readBytes()
            guard reader.remainingCount == 0 else {
                throw CloudflareDatabaseAuthorizationError.trailingBytes
            }
            var claimsReader = DatabaseWireReader(encodedClaims)
            let claims = try FieldObject(from: &claimsReader)
            guard claimsReader.remainingCount == 0 else {
                throw CloudflareDatabaseAuthorizationError.trailingBytes
            }
            return .authenticated(
                Principal(
                    identifier: identifier,
                    roles: Set(roles),
                    claims: claims
                )
            )
        } catch let error as CloudflareDatabaseAuthorizationError {
            throw error
        } catch {
            throw .malformedClaims
        }
    }

    private static func isValid(
        _ value: String,
        maximumByteCount: Int
    ) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumByteCount
    }

    private static func canonicalStringOrder(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
