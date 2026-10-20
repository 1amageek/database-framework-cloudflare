@_spi(DatabaseExecution) @testable import DatabaseEngine
import DatabaseKit
import DatabaseTypes
import StorageKit

/// Exercises checkpoint execution on the persistent reactor's actual container.
enum SQLCheckpointVerification {
    static let markers = [
        "kit-block-admission", "checkpoint-nested-restore", "checkpoint-failure-recovery",
        "checkpoint-terminal-token", "checkpoint-operation-boundary", "checkpoint-schema-restore",
        "block-orchestrator"
    ]
    typealias Failure = ParameterBindingVerification.Failure

    static func require(_ condition: Bool, _ name: String) throws {
        try ParameterBindingVerification.require(condition, "s12-" + name)
    }

    static func verify(in context: DatabaseContext, container: DBContainer) async throws {
        let checks: [(String, @Sendable () async throws -> Void)] = [
            (markers[0], { try admission() }),
            (markers[1], { try await nestedRestore(context, container) }),
            (markers[2], { try await failureRecovery(context, container) }),
            (markers[3], { try await terminalToken(context, container) }),
            (markers[4], { try await operationBoundary(context, container) }),
            (markers[5], { try await schemaRestore(context, container) }),
            (markers[6], { try await SQLBlockOrchestratorVerification.verify(in: context) })
        ]
        for (name, check) in checks {
            do { try await check() }
            catch { throw SQLTextPatternVerification.DiagnosticFailure(phase: "s12-" + name, cause: error) }
            print("ENGINE_S12_CASE " + name + " PASS")
        }
        print("ENGINE_S12_PASS cases=" + String(markers.count))
    }

    private static func admission() throws {
        let statement = QueryStatement.select(SelectQuery(projection: [.wildcard()], source: .values([])))
        let steps: [SQLBlockStep] = [.statement(statement), .savepoint("point"), .rollbackTo("point"), .release("point")]
        let block = try SQLBlock(steps: steps)
        try require(block.steps == steps, "block-order")
        try require(SQLBlockStep.savepoint("\u{00e9}") != .savepoint("e\u{0301}"), "exact-name-spelling")
        do { _ = try SQLBlock(steps: []); throw Failure.assertion("s12-empty-block") }
        catch QueryStructuralValidationError.emptySQLBlock {}
        for name in ["", "before\0after"] {
            for step in [SQLBlockStep.savepoint(name), .rollbackTo(name), .release(name)] {
                do { _ = try SQLBlock(steps: [step]); throw Failure.assertion("s12-invalid-name") }
                catch QueryStructuralValidationError.invalidSQLCheckpointName {}
            }
        }
        let cumulative = try SQLBlock(steps: [.statement(statement), .statement(statement)])
        try QueryStructuralValidator.validate(cumulative, limits: .init(maximumTotalNodes: 9, maximumCollectionElements: 4))
        do {
            try QueryStructuralValidator.validate(cumulative, limits: .init(maximumCollectionElements: 3))
            throw Failure.assertion("s12-cumulative-collection")
        } catch QueryStructuralValidationError.resourceLimitExceeded(resource: .collectionElements, actual: 4, maximum: 3) {}
        do {
            try QueryStructuralValidator.validate(cumulative, limits: .init(maximumTotalNodes: 8))
            throw Failure.assertion("s12-cumulative-nodes")
        } catch QueryStructuralValidationError.resourceLimitExceeded(resource: .totalNodes, actual: 9, maximum: 8) {}
        let named = try SQLBlock(steps: [.savepoint("aa")])
        let parameters = [QueryParameter(position: 1, name: "b", value: .primitive(.null))]
        try QueryStructuralValidator.validate(named, parameters: parameters,
            limits: .init(maximumRetainedBytes: 3, maximumCollectionElements: 2))
        do {
            try QueryStructuralValidator.validate(named, parameters: parameters, limits: .init(maximumRetainedBytes: 2))
            throw Failure.assertion("s12-cumulative-parameters")
        } catch QueryStructuralValidationError.resourceLimitExceeded(resource: .retainedBytes, actual: 3, maximum: 2) {}
    }

    private static func nestedRestore(_ context: DatabaseContext, _ container: DBContainer) async throws {
        let meter = meter(container)
        try await context.withCheckpointTransaction(checkpointLimits: limits(), workMeter: meter) { transaction in
            try await transaction.save(RuntimeVerificationDocument(id: "s12-nested", title: "first"))
            let first = try await transaction.createCheckpoint()
            try await transaction.save(RuntimeVerificationDocument(id: "s12-nested", title: "second"))
            let second = try await transaction.createCheckpoint()
            try await transaction.delete(RuntimeVerificationDocument(id: "s12-nested", title: "second"))
            let consumed = meter.consumedWorkUnits
            try await transaction.rollback(to: second)
            let restoredSecond = try await transaction.fetch(RuntimeVerificationDocument.self, identifiedBy: "s12-nested")
            try require(restoredSecond?.title == "second", "nested-restore-second")
            try await transaction.rollback(to: first)
            let restoredFirst = try await transaction.fetch(RuntimeVerificationDocument.self, identifiedBy: "s12-nested")
            try require(restoredFirst?.title == "first", "nested-restore-first")
            try require(meter.consumedWorkUnits > consumed, "rollback-does-not-refund-work")
            let effects = try await transaction.persistedMutationEffects()
            try require(effects.count == 1 && effects.first?.kind == .insert, "restored-net-effects")
            try await transaction.rollback(to: first)
            try await transaction.release(first)
        }
        let committed = try await context.model(for: "s12-nested", as: RuntimeVerificationDocument.self)
        try require(committed?.title == "first", "independent-committed-readback")
        try released(meter)
    }

    private static func failureRecovery(_ context: DatabaseContext, _ container: DBContainer) async throws {
        let meter = meter(container)
        let model = RuntimeVerificationDocument(id: "s12-nested", title: "first")
        try await context.withCheckpointTransaction(checkpointLimits: limits(), workMeter: meter) { transaction in
            let checkpoint = try await transaction.createCheckpoint()
            do {
                try await transaction.save(model, precondition: .notExists)
                throw Failure.assertion("s12-existing-create")
            } catch DatabaseContextError.preconditionFailed {}
            do {
                _ = try await transaction.fetch(RuntimeVerificationDocument.self, identifiedBy: model.id)
                throw Failure.assertion("s12-failed-attempt-read")
            } catch DatabaseTransactionCheckpointError.failed {}
            try await transaction.rollback(to: checkpoint)
            try await transaction.save(RuntimeVerificationDocument(id: model.id, title: "recovered"), precondition: .exists)
        }
        let committed = try await context.model(for: model.id, as: RuntimeVerificationDocument.self)
        try require(committed?.title == "recovered", "failure-recovered-write")
        try released(meter)
    }

    private static func terminalToken(_ context: DatabaseContext, _ container: DBContainer) async throws {
        let meter = meter(container)
        do {
            try await context.withCheckpointTransaction(checkpointLimits: limits(), workMeter: meter) { transaction in
                let token = try await transaction.createCheckpoint()
                try await transaction.save(RuntimeVerificationDocument(id: "s12-discarded", title: "discard"))
                try await transaction.release(token)
                try await transaction.rollback(to: token)
            }
            throw Failure.assertion("s12-released-token")
        } catch DatabaseTransactionCheckpointError.invalidToken {}
        let absent = try await context.model(for: "s12-discarded", as: RuntimeVerificationDocument.self)
        try require(absent == nil, "invalid-token-whole-request-rollback")
        try released(meter)
    }

    private static func operationBoundary(_ context: DatabaseContext, _ container: DBContainer) async throws {
        let meter = meter(container)
        try await context.withCheckpointTransaction(checkpointLimits: limits(), workMeter: meter) { transaction in
            try await transaction.withStatementScope {
                do {
                    _ = try await transaction.createCheckpoint()
                    throw Failure.assertion("s12-reentrant-barrier")
                } catch DatabaseTransactionCheckpointError.barrierInsideOperation {}
            }
            let marker = try await transaction.createCheckpoint()
            try await transaction.rollback(to: marker)
            try await transaction.release(marker)
        }
        try released(meter)
    }

    private static func schemaRestore(_ context: DatabaseContext, _ container: DBContainer) async throws {
        let original = container.acquirePublishedSchemaLease()
        guard let relation = original.sqlCatalog.catalog.relations.first else {
            throw Failure.assertion("s12-catalog-fixture-relation")
        }
        let replacement = try SQLRelation(id: relation.id, namespaceID: relation.namespaceID,
            name: "s12_candidate", entityName: relation.entityName, columns: relation.columns,
            primaryKeyColumnIDs: relation.primaryKeyColumnIDs,
            primaryKeyConstraint: relation.primaryKeyConstraint, constraints: relation.constraints)
        let candidate = try SQLCatalog(namespaces: original.sqlCatalog.catalog.namespaces,
            relations: original.sqlCatalog.catalog.relations.map { $0.id == relation.id ? replacement : $0 },
            sequences: original.sqlCatalog.catalog.sequences)
        let meter = meter(container)
        try await context.withCheckpointTransaction(checkpointLimits: limits(), workMeter: meter) { transaction in
            let marker = try await transaction.createCheckpoint()
            _ = try await transaction.stageSQLCatalog(candidate, expectedGeneration: original.generation,
                idempotencyKey: "s12-reusable")
            try require(container.acquirePublishedSchemaLease().sqlCatalog.catalog == original.sqlCatalog.catalog,
                "candidate-not-published")
            try await transaction.withStatementScope {
                try require(container.acquireActiveSchemaLease().sqlCatalog.catalog == candidate, "candidate-active")
            }
            try await transaction.rollback(to: marker)
            try await transaction.withStatementScope {
                try require(container.acquireActiveSchemaLease().sqlCatalog.catalog == original.sqlCatalog.catalog,
                    "candidate-restore")
            }
            _ = try await transaction.stageSQLCatalog(candidate, expectedGeneration: original.generation,
                idempotencyKey: "s12-reusable")
            try await transaction.rollback(to: marker)
        }
        try require(container.acquirePublishedSchemaLease().sqlCatalog.catalog == original.sqlCatalog.catalog
            && container.schemaGeneration == original.generation, "restored-generation-unpublished")
        try released(meter)
    }

    static func limits() throws -> TransactionCheckpointLimits {
        try TransactionCheckpointLimits(maximumEntries: 10_000, maximumDepth: 16,
            maximumRetainedBytes: 4 * 1_024 * 1_024, maximumWorkUnits: 100_000, maximumReadPageRows: 128)
    }

    private static func meter(_ container: DBContainer) -> DatabaseWorkMeter {
        DatabaseWorkMeter(budget: ExecutionBudget(maximumIntermediateBytes: 4 * 1_024 * 1_024),
            monotonicClock: container.monotonicClock)
    }

    private static func released(_ meter: DatabaseWorkMeter) throws {
        try require(meter.retainedIntermediateRows == 0 && meter.retainedIntermediateBytes == 0,
            "authoritative-retained-release")
    }
}
