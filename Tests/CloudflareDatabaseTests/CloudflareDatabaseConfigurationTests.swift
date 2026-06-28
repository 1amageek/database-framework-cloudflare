#if !os(WASI)
import CloudflareDatabase
import CloudflareDurableObjectStorage
import DatabaseEngine
import StorageKit
import Synchronization
import Testing

@Suite("Cloudflare database configuration")
struct CloudflareDatabaseConfigurationTests {
    @Test func configurationCreatesCustomStorageEngine() async throws {
        let client = MemoryCloudflareDurableObjectStorageClient()
        let configuration = try CloudflareDatabaseConfiguration(
            databaseID: "main",
            tenantID: "tenant-a",
            workspaceID: "workspace-a",
            client: client
        )

        let dbConfiguration = try await configuration.makeDBConfiguration(indexConfigurations: [])

        switch dbConfiguration.backend {
        case .custom(let engine):
            let engineName = String(describing: type(of: engine))
            #expect(engineName.contains("CloudflareDurableObjectStorageEngine"))
        #if FOUNDATION_DB
        case .fdb:
            Issue.record("Cloudflare configuration must create a custom StorageEngine backend")
        #endif
        }
    }

    @Test func configuredStorageEngineRoundTripsThroughDatabaseFrameworkCustomBackend() async throws {
        let client = MemoryCloudflareDurableObjectStorageClient()
        let configuration = try CloudflareDatabaseConfiguration(databaseID: "main", client: client)
        let dbConfiguration = try await configuration.makeDBConfiguration(indexConfigurations: [])

        guard case .custom(let engine) = dbConfiguration.backend else {
            Issue.record("Expected custom Cloudflare StorageEngine backend")
            return
        }

        try await engine.withTransaction { transaction in
            transaction.setValue([0x0A], for: [0x01])
        }

        let value = try await engine.withTransaction { transaction in
            try await transaction.getValue(for: [0x01])
        }
        #expect(value == [0x0A])
    }

    @Test func configuredStorageEnginesAreIsolatedByScope() async throws {
        let client = MemoryCloudflareDurableObjectStorageClient()
        let firstConfiguration = try CloudflareDatabaseConfiguration(
            databaseID: "main",
            tenantID: "tenant-a",
            workspaceID: "workspace-a",
            client: client
        )
        let secondConfiguration = try CloudflareDatabaseConfiguration(
            databaseID: "main",
            tenantID: "tenant-b",
            workspaceID: "workspace-a",
            client: client
        )

        let firstDBConfiguration = try await firstConfiguration.makeDBConfiguration(indexConfigurations: [])
        let secondDBConfiguration = try await secondConfiguration.makeDBConfiguration(indexConfigurations: [])

        guard case .custom(let firstEngine) = firstDBConfiguration.backend else {
            Issue.record("Expected first Cloudflare configuration to create a custom backend")
            return
        }
        guard case .custom(let secondEngine) = secondDBConfiguration.backend else {
            Issue.record("Expected second Cloudflare configuration to create a custom backend")
            return
        }

        try await firstEngine.withTransaction { transaction in
            transaction.setValue([0x0A], for: [0x01])
        }
        try await secondEngine.withTransaction { transaction in
            transaction.setValue([0x0B], for: [0x01])
        }

        let firstValue = try await firstEngine.withTransaction { transaction in
            try await transaction.getValue(for: [0x01])
        }
        let secondValue = try await secondEngine.withTransaction { transaction in
            try await transaction.getValue(for: [0x01])
        }

        #expect(firstValue == [0x0A])
        #expect(secondValue == [0x0B])
    }
}

private final class MemoryCloudflareDurableObjectStorageClient: CloudflareDurableObjectStorageClient {
    private struct State: Sendable {
        var rowsByScope: [CloudflareDurableObjectStorageScope: [[UInt8]: [UInt8]]] = [:]
        var versionsByScope: [CloudflareDurableObjectStorageScope: Int64] = [:]
    }

    private let state = Mutex(State())

    func readiness(
        _ request: CloudflareDurableObjectReadinessRequest
    ) async throws -> CloudflareDurableObjectReadinessResponse {
        state.withLock { state in
            CloudflareDurableObjectReadinessResponse(
                schemaVersion: 1,
                commitVersion: state.versionsByScope[request.scope] ?? 0,
                metadataInitialized: true
            )
        }
    }

    func read(
        _ request: CloudflareDurableObjectReadRequest
    ) async throws -> CloudflareDurableObjectReadResponse {
        state.withLock { state in
            CloudflareDurableObjectReadResponse(
                value: state.rowsByScope[request.scope]?[request.key.rawValue].map(CloudflareDurableObjectBytes.init),
                currentCommitVersion: state.versionsByScope[request.scope] ?? 0
            )
        }
    }

    func range(
        _ request: CloudflareDurableObjectRangeRequest
    ) async throws -> CloudflareDurableObjectRangeResponse {
        state.withLock { state in
            let beginKey = request.begin.storageKitSelector.key
            let endKey = request.end.storageKitSelector.key
            let scopedRows = state.rowsByScope[request.scope] ?? [:]
            let matchingRows = scopedRows.filter { key, _ in
                Self.compare(key, beginKey) >= 0 && Self.compare(key, endKey) < 0
            }
            let sortedRows = matchingRows.sorted { lhs, rhs in
                let comparison = Self.compare(lhs.key, rhs.key)
                return request.reverse ? comparison > 0 : comparison < 0
            }
            let limitedRows = sortedRows.prefix(request.limit > 0 ? request.limit : Int.max)
            let rows = limitedRows.map { key, value in
                CloudflareDurableObjectKeyValue(
                    key: CloudflareDurableObjectBytes(key),
                    value: CloudflareDurableObjectBytes(value)
                )
            }

            return CloudflareDurableObjectRangeResponse(
                rows: Array(rows),
                currentCommitVersion: state.versionsByScope[request.scope] ?? 0,
                conflictRange: CloudflareDurableObjectConflictRange(
                    begin: CloudflareDurableObjectBytes(request.begin.storageKitSelector.key),
                    end: CloudflareDurableObjectBytes(request.end.storageKitSelector.key)
                )
            )
        }
    }

    func commit(
        _ request: CloudflareDurableObjectCommitRequest
    ) async throws -> CloudflareDurableObjectCommitResponse {
        try state.withLock { state in
            var rows = state.rowsByScope[request.scope] ?? [:]
            for mutation in request.mutations {
                switch mutation {
                case .set(let key, let value):
                    rows[key.rawValue] = value.rawValue
                case .clear(let key):
                    rows.removeValue(forKey: key.rawValue)
                case .clearRange(let begin, let end):
                    for key in rows.keys where Self.compare(key, begin.rawValue) >= 0 && Self.compare(key, end.rawValue) < 0 {
                        rows.removeValue(forKey: key)
                    }
                case .atomic(let key, let param, let mutationType):
                    switch try mutationType.storageKitMutationType.apply(to: rows[key.rawValue], param: param.rawValue) {
                    case .set(let value):
                        rows[key.rawValue] = value
                    case .clear:
                        rows.removeValue(forKey: key.rawValue)
                    case .unchanged:
                        break
                    }
                }
            }
            let version = (state.versionsByScope[request.scope] ?? 0) + 1
            state.rowsByScope[request.scope] = rows
            state.versionsByScope[request.scope] = version
            return CloudflareDurableObjectCommitResponse(committedVersion: version)
        }
    }

    private static func compare(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        let count = min(lhs.count, rhs.count)
        for index in 0..<count {
            if lhs[index] != rhs[index] {
                return lhs[index] < rhs[index] ? -1 : 1
            }
        }
        if lhs.count == rhs.count {
            return 0
        }
        return lhs.count < rhs.count ? -1 : 1
    }
}
#endif
