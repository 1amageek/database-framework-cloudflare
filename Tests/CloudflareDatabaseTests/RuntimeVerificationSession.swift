import CloudflareDatabase
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseTypes

actor RuntimeVerificationSession: CloudflareDatabaseSession {
    static let principalIdentifier = "runtime-verification"

    private let container: DBContainer
    #if CLOUDFLARE_TEST_MULTIPLE_BASES
    private let baseID: Base.ID
    #endif

    #if CLOUDFLARE_TEST_MULTIPLE_BASES
    init(container: DBContainer, baseID: Base.ID) {
        self.container = container
        self.baseID = baseID
    }
    #else
    init(container: DBContainer) {
        self.container = container
    }
    #endif

    func respond(
        to invocation: CloudflareDatabaseInvocation
    ) async throws -> ByteString {
        guard Self.string(from: invocation.context)
                == Self.principalIdentifier else {
            throw RuntimeVerificationError.unauthorizedContext
        }
        let request = Self.string(from: invocation.request)
        let authorization = AuthorizationContext.authenticated(
            Principal(
                identifier: Self.principalIdentifier,
                roles: ["admin"]
            )
        )
        let context: DatabaseContext
        #if CLOUDFLARE_TEST_MULTIPLE_BASES
        context = container.session(authorization: authorization)
            .base(baseID)
            .newContext()
        #else
        context = container.newContext(authorization: authorization)
        #endif

        if request.hasPrefix("put:") {
            let title = String(request.dropFirst(4))
            try context.upsert(
                RuntimeVerificationDocument(
                    id: "document-1",
                    title: title
                )
            )
            try await context.save()
            return ByteString(Array(title.utf8))
        }
        if request == "get" {
            let document = try await context
                .fetch(RuntimeVerificationDocument.self)
                .where(RuntimeVerificationDocument.fields.id == "document-1")
                .first()
            guard let document else {
                throw RuntimeVerificationError.documentNotFound
            }
            return ByteString(Array(document.title.utf8))
        }
        if request.hasPrefix("echo:") {
            return ByteString(Array(request.dropFirst(5).utf8))
        }
        if request == "cancel" {
            throw CancellationError()
        }
        throw RuntimeVerificationError.invalidApplicationRequest
    }

    func shutdown() async {}

    private static func string(from bytes: ByteString) -> String {
        bytes.withUnsafeBytes { buffer in
            String(decoding: buffer, as: UTF8.self)
        }
    }
}
