import CloudflareDatabase
import DatabaseKit
import DatabaseTypes
import Testing

@Suite("Cloudflare database authorization codec")
struct CloudflareDatabaseAuthorizationCodecTests {
    @Test("Swift matches the canonical TypeScript principal frame")
    func canonicalFrame() throws {
        let principal = Principal(
            identifier: "runtime-verification",
            roles: ["admin"]
        )
        let encoded = try CloudflareDatabaseAuthorizationCodec.encode(
            principal
        )
        #expect(encoded == ByteString([
            68, 66, 65, 85, 1, 0,
            20, 0, 0, 0,
            114, 117, 110, 116, 105, 109, 101, 45, 118, 101,
            114, 105, 102, 105, 99, 97, 116, 105, 111, 110,
            1, 0, 0, 0,
            5, 0, 0, 0, 97, 100, 109, 105, 110,
            4, 0, 0, 0, 0, 0, 0, 0,
        ]))
        #expect(
            try CloudflareDatabaseAuthorizationCodec.decode(encoded)
                == .authenticated(principal)
        )
    }

    @Test("decoder rejects non-canonical duplicate roles")
    func rejectsDuplicateRoles() {
        let bytes = ByteString([
            68, 66, 65, 85, 1, 0,
            1, 0, 0, 0, 112,
            2, 0, 0, 0,
            1, 0, 0, 0, 114,
            1, 0, 0, 0, 114,
            4, 0, 0, 0, 0, 0, 0, 0,
        ])
        #expect(
            throws: CloudflareDatabaseAuthorizationError.nonCanonicalRoles
        ) {
            try CloudflareDatabaseAuthorizationCodec.decode(bytes)
        }
    }

    @Test("decoder rejects malformed claims")
    func rejectsMalformedClaims() {
        let bytes = ByteString([
            68, 66, 65, 85, 1, 0,
            1, 0, 0, 0, 112,
            0, 0, 0, 0,
            1, 0, 0, 0, 255,
        ])
        #expect(
            throws: CloudflareDatabaseAuthorizationError.malformedClaims
        ) {
            try CloudflareDatabaseAuthorizationCodec.decode(bytes)
        }
    }
}
