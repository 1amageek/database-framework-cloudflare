@_spi(DatabaseExecution) import Database
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseRuntime
import DatabaseTypes
import DatabaseWire
import StorageKit

enum SQLApplicationInvocation {
    static func respond(to bytes: ByteString, in context: DatabaseContext,
        maximumFrameBytes: Int) async throws -> ByteString {
        let decoded = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
        let defaults = DatabaseWireLimits.default
        let limits = try DatabaseWireLimits(maximumFrameBytes: maximumFrameBytes,
            maximumStringBytes: defaults.maximumStringBytes,
            maximumByteStringBytes: defaults.maximumByteStringBytes,
            maximumCollectionCount: defaults.maximumCollectionCount,
            maximumNestingDepth: defaults.maximumNestingDepth,
            maximumObjectCount: defaults.maximumObjectCount)
        let wire = DatabaseWireEncoder(limits: limits)
        guard decoded.request.page == nil else { throw SQLBlockExecutionError.unsupportedPagedQuery }
        do {
            let result = try await context.executeQueryEncoded(decoded.request.input,
                parameters: decoded.request.parameters,
                options: QueryExecutionOptions(budget: decoded.request.budget,
                    graphPartitions: decoded.request.graphPartitions),
                requestID: decoded.requestID, limits: limits,
                checkpointCeiling: try TransactionCheckpointLimits(maximumEntries: 100,
                    maximumDepth: 32, maximumRetainedBytes: 8_000_000,
                    maximumWorkUnits: 1_000_000, maximumReadPageRows: 1000))
            return try result.promoteToOutput()
        } catch {
            return try failureResponse(for: error, requestID: decoded.requestID, encoder: wire)
        }
    }

    static func failureResponse(for error: any Error, requestID: UInt64,
        encoder: DatabaseWireEncoder) throws -> ByteString {
        if error is CancellationError { throw CancellationError() }
        if let failure = error as? SQLExecutionFailure,
           failure.underlyingError is CancellationError { throw CancellationError() }
        if error is QueryResponseEncodingError {
            return try encoder.encodeFailure(requestID: requestID,
                operation: DatabaseOperationCatalog.queryExecute.identifier,
                error: RemoteOperationError(category: .resourceLimit, code: "application.query.resourceLimit",
                    message: "Query response exceeds the configured Wire resource limits", retryability: .never))
        }
        let diagnostic = SQLDiagnostics.diagnostic(for: error)
        let category: OperationErrorCategory = diagnostic.category == .resource ? .resourceLimit : .invalidRequest
        let remote = try RemoteOperationError(category: category, code: "application.sql.failed",
            message: diagnostic.message, retryability: .never, sqlDiagnostic: diagnostic)
        return try encoder.encodeFailure(requestID: requestID,
            operation: DatabaseOperationCatalog.queryExecute.identifier, error: remote)
    }
}
