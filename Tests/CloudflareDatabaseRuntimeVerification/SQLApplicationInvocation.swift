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
        let decoded = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.sqlExecute, from: bytes)
        let defaults = DatabaseWireLimits.default
        let limits = try DatabaseWireLimits(maximumFrameBytes: maximumFrameBytes,
            maximumStringBytes: defaults.maximumStringBytes,
            maximumByteStringBytes: defaults.maximumByteStringBytes,
            maximumCollectionCount: defaults.maximumCollectionCount,
            maximumNestingDepth: defaults.maximumNestingDepth,
            maximumObjectCount: defaults.maximumObjectCount)
        let wire = DatabaseWireEncoder(limits: limits)
        let projection = SQLApplicationResponseEncoder(requestID: decoded.requestID, encoder: wire)
        let options = SQLBlockExecutionOptions(checkpointLimits: try TransactionCheckpointLimits(
            maximumEntries: 100, maximumDepth: 32, maximumRetainedBytes: 8_000_000,
            maximumWorkUnits: 1_000_000, maximumReadPageRows: 1000), budget: decoded.request.budget)
        do {
            let result: SQLEncodedResponse
            switch decoded.request.input {
            case .text(let text):
                result = try await context.executeEncodedSQLBlock(text, parameters: decoded.request.parameters,
                    options: options, encoder: projection)
            case .statement(let statement):
                result = try await context.executeEncodedStatement(statement, parameters: decoded.request.parameters,
                    options: options, encoder: projection)
            case .block(let block):
                result = try await context.executeEncodedSQLBlock(block, parameters: decoded.request.parameters,
                    options: options, encoder: projection)
            }
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
        let diagnostic = SQLDiagnostics.diagnostic(for: error)
        let category: OperationErrorCategory = diagnostic.category == .resource ? .resourceLimit : .invalidRequest
        let remote = try RemoteOperationError(category: category, code: "application.sql.failed",
            message: diagnostic.message, retryability: .never, sqlDiagnostic: diagnostic)
        return try encoder.encodeFailure(requestID: requestID,
            operation: DatabaseOperationCatalog.sqlExecute.identifier, error: remote)
    }
}
