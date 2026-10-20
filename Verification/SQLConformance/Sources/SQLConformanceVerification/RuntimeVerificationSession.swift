import CloudflareDatabase
@_spi(DatabaseExecution) @testable import DatabaseEngine
import DatabaseRuntime

actor RuntimeVerificationSession: CloudflareDatabaseSession {
    static let principalIdentifier = "runtime-verification"

    private let container: DBContainer

    init(container: DBContainer) {
        self.container = container
    }

    func respond(
        to invocation: CloudflareDatabaseInvocation
    ) async throws -> ByteString {
        guard
            Self.string(from: invocation.context)
                == Self.principalIdentifier
        else {
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
        context = container.newContext(authorization: authorization)

        if request == "sql:s17-projection" {
            try await S17SQLProjectionVerification.verify(in: context, container: container)
            return Self.bytes("sql:s17-projection:verified:engine=2:wire=1:client=1")
        }

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
            let document =
                try await context
                .fetch(RuntimeVerificationDocument.self)
                .where(RuntimeVerificationDocument.fields.id == "document-1")
                .first()
            guard let document else {
                throw RuntimeVerificationError.documentNotFound
            }
            return ByteString(Array(document.title.utf8))
        }
        if request == "sql:operations" || request == "sql:operations-restored" || request == "sql:ddl" || request == "sql:ddl-restored" || request == "sql:dml" || request == "sql:checkpoints" || request == "sql:binding" || request == "sql:temporal" || request == "sql:collections" || request == "sql:relations" || request == "sql:analytics" || request == "sql:recursion-functions" || request == "sql:catalog" || request == "sql:catalog-restored" || request == "sql:constraints-sequences" || request == "sql:constraints-sequences-restored" {
            var phase = "binding9"
            do {
                if request == "sql:operations" {
                    phase = "s16operations8"
                    try await S16SQLOperationsVerification.verify(in: context, container: container)
                    return Self.bytes("sql:operations:verified:s16:8")
                }
                if request == "sql:operations-restored" {
                    phase = "s16operations-restored1"
                    try await S16SQLOperationsVerification.verifyRestored(in: context, container: container)
                    return Self.bytes("sql:operations-restored:verified:s16:1:source-kind=informationSchema")
                }
                if request == "sql:ddl" {
                    phase = "s15ddl8"
                    try await SQLDDLVerification.verify(in: context, container: container)
                    return Self.bytes("sql:ddl:verified:s15:8")
                }
                if request == "sql:ddl-restored" {
                    phase = "s15ddl-restored1"
                    try await SQLDDLVerification.verifyRestored(in: context, container: container)
                    return Self.bytes("sql:ddl-restored:verified:s15:1")
                }
                if request == "sql:dml" {
                    phase = "s14dml8"
                    try await SQLDMLVerification.verify(in: context, container: container)
                    return Self.bytes("sql:dml:verified:s14:8")
                }
                if request == "sql:constraints-sequences" {
                    phase = "s13constraints-sequences7"
                    try await SQLConstraintSequenceVerification.verify(in: context, container: container)
                    return Self.bytes("sql:constraints-sequences:verified:s13:7")
                }
                if request == "sql:constraints-sequences-restored" {
                    phase = "s13constraints-sequences-restored1"
                    try await SQLConstraintSequenceVerification.verifyRestored(in: context, container: container)
                    return Self.bytes("sql:constraints-sequences-restored:verified:s13:1:allocator=27")
                }
                if request == "sql:checkpoints" {
                    phase = "s12checkpoints7"
                    try await SQLCheckpointVerification.verify(in: context, container: container)
                    return Self.bytes("sql:checkpoints:verified:s12:7")
                }
                if request == "sql:catalog" {
                    phase = "s11catalog4"
                    try await SQLCatalogVerification.verify(in: context, container: container)
                    return Self.bytes("sql:catalog:verified:s11:4")
                }
                if request == "sql:catalog-restored" {
                    phase = "s11catalog-restored1"
                    try await SQLCatalogVerification.verifyRestored(in: context, container: container)
                    return Self.bytes("sql:catalog-restored:verified:s11:1")
                }
                if request == "sql:recursion-functions" {
                    phase = "s10recursion-functions4"
                    try await SQLRecursiveFunctionVerification.verify(in: context, container: container)
                    return Self.bytes("sql:recursion-functions:verified:s10:4")
                }
                if request == "sql:analytics" {
                    phase = "s09analytics4"
                    try await SQLAnalyticVerification.verify(in: context, container: container)
                    return Self.bytes("sql:analytics:verified:s09:4")
                }
                if request == "sql:relations" {
                    phase = "s08relations5"
                    try await SQLRelationalVerification.verify(in: context, container: container)
                    return Self.bytes("sql:relations:verified:s08:5")
                }
                if request == "sql:collections" {
                    phase = "s07collections6"
                    try await SQLCollectionVerification.verify(in: context, container: container)
                    return Self.bytes("sql:collections:verified:s07:6")
                }
                if request == "sql:temporal" {
                    phase = "s06temporal6"
                    try await SQLTemporalVerification.verify(in: context, container: container)
                    return Self.bytes("sql:temporal:verified:s06:6")
                }
                try await ParameterBindingVerification.verify(in: context, container: container)
                phase = "selected5"
                try await SelectedValueVerification.verify(in: context, container: container)
                phase = "s05scalar5"
                try await SQLTextPatternVerification.verify(in: context, container: container)
                return Self.bytes("sql:binding:verified:s05:5")
            } catch let failure as SQLTextPatternVerification.DiagnosticFailure {
                let detail: String
                if let cause = failure.cause as? DatabaseExpressionEvaluationError {
                    if case .timeZone(let zone) = cause { detail = "timeZone:" + zone.description }
                    else { detail = cause.description }
                } else if let cause = failure.cause as? DatabaseWorkLimitError {
                    detail = cause.description
                } else if let cause = failure.cause as? QueryValueError {
                    switch cause {
                    case .invalidNumeric(let offset, let reason): detail = "invalidNumeric:" + String(offset) + ":" + reason
                    case .invalidUUID(let offset, let reason): detail = "invalidUUID:" + String(offset) + ":" + reason
                    case .invalidBinary(let offset, let reason): detail = "invalidBinary:" + String(offset) + ":" + reason
                    case .elementTypeMismatch(let index): detail = "elementTypeMismatch:" + String(index)
                    case .elementCountMismatch(let expected, let actual): detail = "elementCountMismatch:" + String(expected) + ":" + String(actual)
                    case .incompatibleType: detail = "incompatibleType"
                    case .unknownRetainedByteCount: detail = "unknownRetainedByteCount"
                    default: detail = "QueryValueError"
                    }
                } else if let cause = failure.cause as? CanonicalSQLBindingFailure {
                    switch cause.cause {
                    case .expression(let expression): detail = "binding:" + expression.description
                    case .read: detail = "binding-read"
                    case .catalog: detail = "binding-catalog"
                    case .resolution: detail = "binding-resolution"
                    }
                } else if let cause = failure.cause as? ParameterBindingVerification.Failure,
                          case .assertion(let name) = cause {
                    detail = "assertion:" + name
                } else if let read = failure.cause as? CanonicalReadError,
                          case .expressionEvaluation(let cause, let occurrence) = read {
                    let location = occurrence.map { ":occurrence=" + String($0.rawValue) } ?? ""
                    if case .timeZone(let zone) = cause {
                        detail = "read-expression:timeZone:" + zone.description + location
                    } else { detail = "read-expression:" + cause.description + location }
                } else if let cause = failure.cause as? SQLConstraintError {
                    switch cause {
                    case .invalidDeclaration(let relation, let reason): detail = "constraint-declaration:" + relation + ":" + reason
                    case .violation(_, let relation, let constraint, _, _, _): detail = "constraint-violation:" + relation + ":" + (constraint ?? "unnamed")
                    case .unknownConstraint(let name): detail = "unknown-constraint:" + name
                    case .notDeferrable(let name): detail = "not-deferrable:" + name
                    case .generatedAssignment(let relation, let column): detail = "generated-assignment:" + relation + ":" + column
                    case .identityAssignment(let relation, let column): detail = "identity-assignment:" + relation + ":" + column
                    case .truncateReferenced(let relation, let constraint, _, _):
                        detail = "truncate-referenced:" + relation + ":" + (constraint ?? "unnamed")
                    }
                } else if let cause = failure.cause as? SQLDDLExecutionError {
                    switch cause {
                    case .missingObject(let name): detail = "ddl-missing:" + name
                    case .duplicateObject(let name): detail = "ddl-duplicate:" + name
                    case .dependentObject(let name): detail = "ddl-dependent:" + name
                    case .invalidDefinition(let reason): detail = "ddl-invalid:" + reason
                    case .protectedObject(let name): detail = "ddl-protected:" + name
                    }
                } else if let cause = failure.cause as? SQLViewExecutionError {
                    switch cause {
                    case .readOnly(let name): detail = "view-readonly:" + name
                    case .notPopulated(let name): detail = "view-not-populated:" + name
                    case .missingDependency(let name): detail = "view-missing-dependency:" + name
                    case .missingColumn(let relation, let column): detail = "view-missing-column:" + relation + ":" + column
                    case .incompatibleColumn(let relation, let column): detail = "view-incompatible-column:" + relation + ":" + column
                    case .cyclicDependency(let name): detail = "view-cycle:" + name
                    case .invalidDefinition(let reason): detail = "view-invalid:" + reason
                    case .incompatibleReplacement(let name): detail = "view-replacement:" + name
                    }
                } else if let cause = failure.cause as? DatabaseEntityMutationError {
                    detail = "entity-mutation:" + cause.description
                } else if let cause = failure.cause as? SchemaDrivenEntityRuntimeError {
                    detail = "schema-driven-runtime:" + cause.description
                } else if let cause = failure.cause as? SQLCatalogError {
                    switch cause {
                    case .invalidViewDefinition: detail = "sql-catalog:invalidViewDefinition"
                    case .invalidIndexDefinition: detail = "sql-catalog:invalidIndexDefinition"
                    case .duplicateCatalogObjectID: detail = "sql-catalog:duplicateCatalogObjectID"
                    case .invalidMaterializedViewBacking: detail = "sql-catalog:invalidMaterializedViewBacking"
                    case .invalidFieldNumberHighWaterMark: detail = "sql-catalog:invalidFieldNumberHighWaterMark"
                    case .unknownCatalogObjectID: detail = "sql-catalog:unknownCatalogObjectID"
                    case .emptyIdentifier: detail = "sql-catalog:emptyIdentifier"
                    case .nulInIdentifier: detail = "sql-catalog:nulInIdentifier"
                    case .invalidFieldNumber: detail = "sql-catalog:invalidFieldNumber"
                    case .duplicateNamespaceID: detail = "sql-catalog:duplicateNamespaceID"
                    case .duplicateNamespaceName: detail = "sql-catalog:duplicateNamespaceName"
                    case .duplicateRelationID: detail = "sql-catalog:duplicateRelationID"
                    case .duplicateRelationName: detail = "sql-catalog:duplicateRelationName"
                    case .unknownNamespaceID: detail = "sql-catalog:unknownNamespaceID"
                    case .duplicateEntityName: detail = "sql-catalog:duplicateEntityName"
                    case .duplicateColumnID: detail = "sql-catalog:duplicateColumnID"
                    case .duplicateColumnName: detail = "sql-catalog:duplicateColumnName"
                    case .duplicateFieldNumber: detail = "sql-catalog:duplicateFieldNumber"
                    case .emptyPrimaryKey: detail = "sql-catalog:emptyPrimaryKey"
                    case .duplicatePrimaryKeyColumnID: detail = "sql-catalog:duplicatePrimaryKeyColumnID"
                    case .unknownPrimaryKeyColumnID: detail = "sql-catalog:unknownPrimaryKeyColumnID"
                    case .emptyConstraintColumns: detail = "sql-catalog:emptyConstraintColumns"
                    case .duplicateConstraintColumnID: detail = "sql-catalog:duplicateConstraintColumnID"
                    case .unknownConstraintColumnID: detail = "sql-catalog:unknownConstraintColumnID"
                    case .duplicateConstraintID: detail = "sql-catalog:duplicateConstraintID"
                    case .duplicateConstraintName: detail = "sql-catalog:duplicateConstraintName"
                    case .invalidConstraintTiming: detail = "sql-catalog:invalidConstraintTiming"
                    case .primaryKeyAttributesWithoutKey: detail = "sql-catalog:primaryKeyAttributesWithoutKey"
                    case .invalidForeignKeyArity: detail = "sql-catalog:invalidForeignKeyArity"
                    case .invalidReferentialActionColumns: detail = "sql-catalog:invalidReferentialActionColumns"
                    case .unknownReferencedRelationID: detail = "sql-catalog:unknownReferencedRelationID"
                    case .unknownReferencedColumnID: detail = "sql-catalog:unknownReferencedColumnID"
                    case .invalidForeignKeyTarget: detail = "sql-catalog:invalidForeignKeyTarget"
                    case .invalidColumnPolicy: detail = "sql-catalog:invalidColumnPolicy"
                    case .invalidColumnType: detail = "sql-catalog:invalidColumnType"
                    case .duplicateSequenceID: detail = "sql-catalog:duplicateSequenceID"
                    case .duplicateSequenceName: detail = "sql-catalog:duplicateSequenceName"
                    case .invalidSequenceType: detail = "sql-catalog:invalidSequenceType"
                    case .invalidSequenceIncrement: detail = "sql-catalog:invalidSequenceIncrement"
                    case .invalidSequenceBounds: detail = "sql-catalog:invalidSequenceBounds"
                    case .invalidSequenceStart: detail = "sql-catalog:invalidSequenceStart"
                    case .unknownSequenceID: detail = "sql-catalog:unknownSequenceID"
                    case .unknownSequenceOwner: detail = "sql-catalog:unknownSequenceOwner"
                    case .conflictingSequenceOwner: detail = "sql-catalog:conflictingSequenceOwner"
                    case .invalidConstraintSelection: detail = "sql-catalog:invalidConstraintSelection"
                    }
                } else if let cause = failure.cause as? SQLBlockExecutionError {
                    switch cause {
                    case .unknownCheckpoint(let name): detail = "sql-block:unknownCheckpoint:" + name
                    case .invalidTransactionControl: detail = "sql-block:invalidTransactionControl"
                    case .invalidSettingValue(_): detail = "sql-block:invalidSettingValue"
                    case .statementTimeout: detail = "sql-block:statementTimeout"
                    case .unsupportedStatement: detail = "sql-block:unsupportedStatement"
                    case .mutationLimitOutOfRange(let limit): detail = "sql-block:mutationLimitOutOfRange:" + String(limit)
                    }
                } else if let cause = failure.cause as? SQLCatalogBindingError {
                    switch cause {
                    case .missingRelation(let namespace, let name):
                        detail = "SQLCatalogBindingError:missingRelation:" + (namespace ?? "<nil>") + ":" + name
                    case .missingNamespace(let name):
                        detail = "SQLCatalogBindingError:missingNamespace:" + name
                    case .missingField(let entity, let number):
                        detail = "SQLCatalogBindingError:missingField:" + entity + ":" + String(number)
                    default: detail = "SQLCatalogBindingError"
                    }
                } else if failure.cause is SQLReadResolutionError {
                    detail = "SQLReadResolutionError"
                } else if let cause = failure.cause as? DatabaseSchemaPublicationError {
                    detail = cause.description
                } else if failure.cause is StorageFrameError {
                    detail = "StorageFrameError"
                } else if failure.cause is DatabaseIntermediateFootprintError {
                    detail = "DatabaseIntermediateFootprintError"
                } else {
                    #if !hasFeature(Embedded)
                    detail = "unclassified:" + String(describing: failure.cause)
                    #else
                    detail = "unclassified"
                    #endif
                }
                return Self.bytes("sql:binding:failure:s05:" + failure.phase + ":" + detail)
            } catch let failure as CanonicalSQLBindingFailure {
                switch failure.cause {
                case .expression(let cause):
                    return Self.bytes("sql:binding:failure:located:" + phase + ":" + cause.description)
                case .read(.expressionEvaluation(let cause, _)):
                    return Self.bytes("sql:binding:failure:located-read:" + phase + ":" + cause.description)
                case .read:
                    return Self.bytes("sql:binding:failure:located-read:" + phase)
                case .catalog:
                    return Self.bytes("sql:binding:failure:located-catalog:" + phase)
                case .resolution:
                    return Self.bytes("sql:binding:failure:located-resolution:" + phase)
                }
            } catch ParameterBindingVerification.Failure.assertion(let name) {
                return Self.bytes("sql:binding:failure:assertion:" + name)
            } catch let error as DatabaseExpressionEvaluationError {
                return Self.bytes("sql:binding:failure:expression:" + error.description)
            } catch let error as DatabaseWorkLimitError {
                return Self.bytes("sql:binding:failure:budget:" + error.description)
            } catch CanonicalReadError.unsupportedSource(let reason) {
                return Self.bytes("sql:binding:failure:source:" + reason)
            } catch CanonicalReadError.unsupportedSelectQuery(let reason) {
                return Self.bytes("sql:binding:failure:select:" + reason)
            } catch CanonicalReadError.expressionEvaluation(let cause, _) {
                return Self.bytes("sql:binding:failure:read-expression:" + cause.description)
            } catch CanonicalReadError.aggregateEvaluation(let cause) {
                switch cause {
                case .numericOverflow(let function):
                    return Self.bytes("sql:binding:failure:aggregate:numericOverflow:" + function)
                case .resultNotRepresentable(let function):
                    return Self.bytes("sql:binding:failure:aggregate:resultNotRepresentable:" + function)
                case .incompatibleNumericKinds(let function):
                    return Self.bytes("sql:binding:failure:aggregate:incompatibleNumericKinds:" + function)
                case .nonNumericValue(let function):
                    return Self.bytes("sql:binding:failure:aggregate:nonNumericValue:" + function)
                default:
                    return Self.bytes("sql:binding:failure:aggregate:other")
                }
            } catch CanonicalReadError.incompatibleLiteralType {
                return Self.bytes("sql:binding:failure:incompatibleLiteralType")
            } catch CanonicalReadError.unsupportedExpression {
                return Self.bytes("sql:binding:failure:unsupportedExpression")
            } catch CanonicalReadError.invalidScalarSubquery {
                return Self.bytes("sql:binding:failure:invalidScalarSubquery")
            } catch CanonicalReadError.invalidMembershipSubquery {
                return Self.bytes("sql:binding:failure:invalidMembershipSubquery")
            } catch is CanonicalReadError {
                return Self.bytes("sql:binding:failure:read")
            } catch {
                return Self.bytes("sql:binding:failure:unclassified:" + phase)
            }
        }
        if request.hasPrefix("echo:") {
            return ByteString(Array(request.dropFirst(5).utf8))
        }
        throw RuntimeVerificationError.invalidApplicationRequest
    }

    #if arch(wasm32)
    func handleAlarm() async throws {
        try CloudflareDatabaseAlarmScheduler().ensureWakeUp(
            noLaterThan: Timestamp(secondsSinceUnixEpoch: 4_102_444_800)
        )
    }
    #endif

    func shutdown() async {}

    private static func string(from bytes: ByteString) -> String {
        bytes.withUnsafeBytes { buffer in
            String(decoding: buffer, as: UTF8.self)
        }
    }

    private static func bytes(_ value: String) -> ByteString {
        ByteString(Array(value.utf8))
    }

}
