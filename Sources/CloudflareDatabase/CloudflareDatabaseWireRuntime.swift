import DatabaseEngine
import DatabaseWire

/// Executes DatabaseWire requests against Cloudflare Durable Object storage without protocol dispatch in WASM.
public struct CloudflareDatabaseWireRuntime: Sendable {
    private let queryScanBatchSize: Int
    private let storage: CloudflareDatabaseWireStorage<CloudflareDurableObjectHost>

    public init(
        storage: CloudflareDatabaseWireStorage<CloudflareDurableObjectHost> = CloudflareDatabaseWireStorage(),
        queryScanBatchSize: Int = 1024
    ) {
        self.storage = storage
        self.queryScanBatchSize = max(1, queryScanBatchSize)
    }

    public func handle(
        _ requestBytes: [UInt8]
    ) throws(DatabaseWireError) -> [UInt8] {
        let response: DatabaseWireResponse
        do {
            let request = try DatabaseWireCodec.decodeRequest(requestBytes)
            response = try execute(request)
        } catch let error as DatabaseWireError {
            response = .failure(status: .invalidRequest, message: message(for: error))
        } catch let error as DatabaseRuntimeError {
            response = .failure(status: .executionFailure, message: message(for: error))
        } catch {
            response = .failure(status: .executionFailure, message: "wire runtime execution failed")
        }
        return try DatabaseWireCodec.encode(response: response)
    }

    public func execute(
        _ request: DatabaseWireRequest
    ) throws(DatabaseRuntimeError) -> DatabaseWireResponse {
        switch request {
        case .applySchema(let schema):
            let operation: DatabaseWireKeyValueOperation
            do {
                operation = try DatabaseWireStorageBridge.schemaSetOperation(schema)
            } catch {
                throw .wire(error)
            }
            try apply(operation)
            return .empty
        case .putRecord(let record):
            let operation: DatabaseWireKeyValueOperation
            do {
                operation = try DatabaseWireStorageBridge.recordSetOperation(record)
            } catch {
                throw .wire(error)
            }
            try apply(operation)
            return .empty
        case .getRecord(let typeName, let id):
            let operation: DatabaseWireKeyValueOperation
            do {
                operation = try DatabaseWireStorageBridge.recordLookupOperation(entityName: typeName, id: id)
            } catch {
                throw .wire(error)
            }
            let value = try read(operation)
            if let value {
                return .record(try decodeRecord(value))
            }
            return .record(nil)
        case .query(let query):
            let plan: DatabaseWireQueryPlan
            let limit: Int
            do {
                plan = try DatabaseWireStorageBridge.queryPlan(query)
                limit = try limitValue(query.limit)
            } catch {
                throw .wire(error)
            }
            var records: [DatabaseWireRecord] = []
            if limit > 0 {
                records.reserveCapacity(limit)
            }
            try appendMatchingRecords(
                plan.operation,
                predicate: plan.postFilter,
                limit: limit,
                into: &records
            )
            return .records(records)
        case .vectorQuery(let query):
            return .scoredRecords(try executeVectorQuery(query))
        }
    }

    private func read(
        _ operation: DatabaseWireKeyValueOperation
    ) throws(DatabaseRuntimeError) -> [UInt8]? {
        switch operation {
        case .get(let key):
            return try storage.read(key: key)
        case .range, .set, .clear:
            throw DatabaseRuntimeError.unsupportedKeyValueOperation(operation)
        }
    }

    private func appendMatchingRecords(
        _ operation: DatabaseWireKeyValueOperation,
        predicate: DatabaseWirePredicate?,
        limit: Int,
        into records: inout [DatabaseWireRecord]
    ) throws(DatabaseRuntimeError) {
        switch operation {
        case .range(let begin, let end, let scanLimit, let reverse):
            if scanLimit > 0 || reverse {
                for row in try storage.scan(begin: begin, end: end, limit: scanLimit, reverse: reverse) {
                    if try append(row, predicate: predicate, limit: limit, into: &records) {
                        return
                    }
                }
                return
            }
            var nextBegin = begin
            while lexicographicCompare(nextBegin, end) < 0 {
                let rows = try storage.scan(
                    begin: nextBegin,
                    end: end,
                    limit: queryScanBatchSize,
                    reverse: false
                )
                guard !rows.isEmpty else {
                    return
                }
                for row in rows {
                    if try append(row, predicate: predicate, limit: limit, into: &records) {
                        return
                    }
                }
                guard rows.count >= queryScanBatchSize, let lastKey = rows.last?.key else {
                    return
                }
                nextBegin = keyAfter(lastKey)
            }
        case .get, .set, .clear:
            throw DatabaseRuntimeError.unsupportedKeyValueOperation(operation)
        }
    }

    private func append(
        _ row: DatabaseKeyValue,
        predicate: DatabaseWirePredicate?,
        limit: Int,
        into records: inout [DatabaseWireRecord]
    ) throws(DatabaseRuntimeError) -> Bool {
        let record = try decodeRecord(row.value)
        guard try DatabasePredicateEvaluator.matches(record, predicate: predicate) else {
            return false
        }
        records.append(record)
        return limit > 0 && records.count >= limit
    }

    private func executeVectorQuery(
        _ query: DatabaseWireVectorQueryRequest
    ) throws(DatabaseRuntimeError) -> [DatabaseWireScoredRecord] {
        let dimensions = try checkedPositiveInt(query.dimensions, name: "dimensions")
        let k = try checkedPositiveInt(query.k, name: "k")
        try validateQueryVector(query.queryVector, dimensions: dimensions)
        try validateVectorSchema(for: query, dimensions: dimensions)

        let operation: DatabaseWireKeyValueOperation
        do {
            operation = try DatabaseWireStorageBridge.entityScanOperation(
                entityName: query.typeName,
                limit: 0,
                reverse: false
            )
        } catch {
            throw .wire(error)
        }
        guard case .range(let begin, let end, _, _) = operation else {
            throw DatabaseRuntimeError.unsupportedKeyValueOperation(operation)
        }

        var results: [DatabaseWireScoredRecord] = []
        results.reserveCapacity(k)
        var nextBegin = begin
        while lexicographicCompare(nextBegin, end) < 0 {
            let rows = try storage.scan(
                begin: nextBegin,
                end: end,
                limit: queryScanBatchSize,
                reverse: false
            )
            guard !rows.isEmpty else {
                break
            }
            for row in rows {
                try appendVectorCandidate(row, query: query, dimensions: dimensions, k: k, into: &results)
            }
            guard rows.count >= queryScanBatchSize, let lastKey = rows.last?.key else {
                break
            }
            nextBegin = keyAfter(lastKey)
        }
        return results.sorted(by: isBetter)
    }

    private func appendVectorCandidate(
        _ row: DatabaseKeyValue,
        query: DatabaseWireVectorQueryRequest,
        dimensions: Int,
        k: Int,
        into results: inout [DatabaseWireScoredRecord]
    ) throws(DatabaseRuntimeError) {
        let record = try decodeRecord(row.value)
        guard try DatabasePredicateEvaluator.matches(record, predicate: query.predicate) else {
            return
        }
        guard let vector = try vectorValue(named: query.fieldName, in: record, dimensions: dimensions) else {
            return
        }
        let distance = distance(query.queryVector, vector, metric: query.metric)
        appendCandidate(
            DatabaseWireScoredRecord(record: record, distance: distance),
            k: k,
            into: &results
        )
    }

    private func validateVectorSchema(
        for query: DatabaseWireVectorQueryRequest,
        dimensions: Int
    ) throws(DatabaseRuntimeError) {
        guard let bytes = try storage.read(key: DatabaseWireStorageBridge.schemaKey()) else {
            throw .invalidVectorQuery("schema not applied")
        }
        let schema: DatabaseWireSchema
        do {
            schema = try DatabaseWireCodec.decodeSchema(bytes)
        } catch {
            throw .wire(error)
        }
        guard let entity = schema.entities.first(where: { $0.typeName == query.typeName }) else {
            throw .invalidVectorQuery("entity schema not found: \(query.typeName)")
        }
        guard let descriptor = entity.indexes.first(where: {
            $0.kind == .vector && $0.fields == [query.fieldName]
        }) else {
            throw .invalidVectorQuery("vector index not found: \(query.typeName).\(query.fieldName)")
        }
        try validateDimensionsParameter(descriptor, dimensions: dimensions)
        try validateMetricParameter(descriptor, metric: query.metric)
    }

    private func validateDimensionsParameter(
        _ descriptor: DatabaseWireIndexDescriptor,
        dimensions: Int
    ) throws(DatabaseRuntimeError) {
        guard let value = parameter(named: "dimensions", in: descriptor) else {
            throw .invalidVectorQuery("vector index dimensions parameter missing")
        }
        guard case .int64(let declared) = value else {
            throw .invalidVectorQuery("vector index dimensions parameter must be int64")
        }
        guard declared == Int64(dimensions) else {
            throw .invalidVectorQuery("vector dimensions mismatch. Expected: \(declared), Got: \(dimensions)")
        }
    }

    private func validateMetricParameter(
        _ descriptor: DatabaseWireIndexDescriptor,
        metric: DatabaseWireVectorMetric
    ) throws(DatabaseRuntimeError) {
        guard let value = parameter(named: "metric", in: descriptor) else {
            throw .invalidVectorQuery("vector index metric parameter missing")
        }
        guard case .string(let declared) = value else {
            throw .invalidVectorQuery("vector index metric parameter must be string")
        }
        guard declared == metric.parameterValue else {
            throw .invalidVectorQuery("vector metric mismatch. Expected: \(declared), Got: \(metric.parameterValue)")
        }
    }

    private func parameter(
        named name: String,
        in descriptor: DatabaseWireIndexDescriptor
    ) -> DatabaseWireFieldValue? {
        descriptor.parameters.first(where: { $0.name == name })?.value
    }

    private func validateQueryVector(
        _ vector: [Double],
        dimensions: Int
    ) throws(DatabaseRuntimeError) {
        guard vector.count == dimensions else {
            throw .invalidVectorQuery("query vector dimension mismatch. Expected: \(dimensions), Got: \(vector.count)")
        }
        for value in vector {
            guard value.isFinite else {
                throw .invalidVectorQuery("query vector contains a non-finite value")
            }
        }
    }

    private func vectorValue(
        named fieldName: String,
        in record: DatabaseWireRecord,
        dimensions: Int
    ) throws(DatabaseRuntimeError) -> [Double]? {
        guard let value = record.fields.first(where: { $0.name == fieldName })?.value else {
            return nil
        }
        switch value {
        case .null:
            return nil
        case .array(let values):
            var vector: [Double] = []
            vector.reserveCapacity(values.count)
            for value in values {
                switch value {
                case .double(let scalar):
                    guard scalar.isFinite else {
                        throw .invalidVectorQuery("vector field contains a non-finite value: \(fieldName)")
                    }
                    vector.append(scalar)
                case .int64(let scalar):
                    vector.append(Double(scalar))
                default:
                    throw .invalidVectorQuery("vector field must contain only numeric values: \(fieldName)")
                }
            }
            guard vector.count == dimensions else {
                throw .invalidVectorQuery("vector field dimension mismatch. Expected: \(dimensions), Got: \(vector.count)")
            }
            return vector
        default:
            throw .invalidVectorQuery("vector field must be an array: \(fieldName)")
        }
    }

    private func apply(
        _ operation: DatabaseWireKeyValueOperation
    ) throws(DatabaseRuntimeError) {
        switch operation {
        case .set(let key, let value):
            try storage.commit([.set(key: key, value: value)])
        case .clear(let key):
            try storage.commit([.clear(key: key)])
        case .get, .range:
            throw DatabaseRuntimeError.unsupportedKeyValueOperation(operation)
        }
    }

    private func decodeRecord(_ value: [UInt8]) throws(DatabaseRuntimeError) -> DatabaseWireRecord {
        do {
            return try DatabaseWireStorageBridge.decodeRecordValue(value)
        } catch {
            throw .wire(error)
        }
    }

    private func limitValue(_ value: UInt32) throws(DatabaseWireError) -> Int {
        guard UInt64(value) <= UInt64(Int.max) else {
            throw DatabaseWireError.byteCountOverflow
        }
        return Int(value)
    }

    private func checkedPositiveInt(
        _ value: UInt32,
        name: String
    ) throws(DatabaseRuntimeError) -> Int {
        guard value > 0 else {
            throw .invalidVectorQuery("\(name) must be positive")
        }
        guard UInt64(value) <= UInt64(Int.max) else {
            throw .wire(.byteCountOverflow)
        }
        return Int(value)
    }

    private func distance(
        _ lhs: [Double],
        _ rhs: [Double],
        metric: DatabaseWireVectorMetric
    ) -> Double {
        switch metric {
        case .cosine:
            return cosineDistance(lhs, rhs)
        case .euclidean:
            return euclideanDistance(lhs, rhs)
        case .dotProduct:
            return dotProductDistance(lhs, rhs)
        }
    }

    private func cosineDistance(_ lhs: [Double], _ rhs: [Double]) -> Double {
        var dotProduct = 0.0
        var lhsNorm = 0.0
        var rhsNorm = 0.0
        for index in lhs.indices {
            dotProduct += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }
        let denominator = lhsNorm.squareRoot() * rhsNorm.squareRoot()
        guard denominator > 0 else {
            return 2.0
        }
        return 1.0 - (dotProduct / denominator)
    }

    private func euclideanDistance(_ lhs: [Double], _ rhs: [Double]) -> Double {
        var sum = 0.0
        for index in lhs.indices {
            let difference = lhs[index] - rhs[index]
            sum += difference * difference
        }
        return sum.squareRoot()
    }

    private func dotProductDistance(_ lhs: [Double], _ rhs: [Double]) -> Double {
        var dotProduct = 0.0
        for index in lhs.indices {
            dotProduct += lhs[index] * rhs[index]
        }
        return -dotProduct
    }

    private func appendCandidate(
        _ candidate: DatabaseWireScoredRecord,
        k: Int,
        into results: inout [DatabaseWireScoredRecord]
    ) {
        if results.count < k {
            results.append(candidate)
            return
        }
        guard let worstIndex = results.indices.max(by: { isBetter(results[$0], results[$1]) }) else {
            return
        }
        if isBetter(candidate, results[worstIndex]) {
            results[worstIndex] = candidate
        }
    }

    private func isBetter(
        _ lhs: DatabaseWireScoredRecord,
        _ rhs: DatabaseWireScoredRecord
    ) -> Bool {
        if lhs.distance == rhs.distance {
            return lhs.record.id < rhs.record.id
        }
        return lhs.distance < rhs.distance
    }

    private func message(for error: DatabaseWireError) -> String {
        switch error {
        case .truncated:
            return "truncated request"
        case .byteCountOverflow:
            return "byte count overflow"
        case .invalidBool:
            return "invalid boolean"
        case .invalidUTF8:
            return "invalid utf8"
        case .trailingBytes:
            return "trailing bytes"
        case .unsupportedProtocolVersion:
            return "unsupported protocol version"
        case .unknownOperation:
            return "unknown operation"
        case .unknownResponseStatus:
            return "unknown response status"
        case .unknownResponsePayload:
            return "unknown response payload"
        case .unknownFieldType:
            return "unknown field type"
        case .unknownFieldValue:
            return "unknown field value"
        case .unknownIndexKind:
            return "unknown index kind"
        case .unknownComparisonOperator:
            return "unknown comparison operator"
        case .unknownPredicate:
            return "unknown predicate"
        case .unknownVectorMetric:
            return "unknown vector metric"
        case .unsupportedPredicatePlan:
            return "unsupported predicate plan"
        }
    }

    private func message(for error: DatabaseRuntimeError) -> String {
        switch error {
        case .wire(let error):
            return message(for: error)
        case .unsupportedKeyValueOperation:
            return "unsupported key-value operation"
        case .unsupportedPredicateComparison:
            return "unsupported predicate comparison"
        case .invalidVectorQuery(let message):
            return message
        case .storageFailure(let message):
            return message
        case .invalidStorageResponse(let message):
            return message
        }
    }

    private func keyAfter(_ key: [UInt8]) -> [UInt8] {
        key + [0x00]
    }

    private func lexicographicCompare(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
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

private extension DatabaseWireVectorMetric {
    var parameterValue: String {
        switch self {
        case .cosine:
            return "cosine"
        case .euclidean:
            return "euclidean"
        case .dotProduct:
            return "dotProduct"
        }
    }
}
