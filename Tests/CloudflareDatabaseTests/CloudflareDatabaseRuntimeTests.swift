import CloudflareDatabase
import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageTesting
import DatabaseTypes
import DatabaseWire
import Testing

@Suite("Cloudflare database runtime", .serialized)
struct CloudflareDatabaseRuntimeTests {
    #if CLOUDFLARE_TEST_VECTOR_INDEXES
    @Test("HNSW fails at bootstrap before storage access")
    func rejectsHNSWBeforeStorageAccess() async throws {
        let application = try CloudflareHNSWRejectionApplication()
        let definition = try await application.makeContainerDefinition()
        #expect(throws: CloudflareDatabaseConfigurationError.unsupportedHNSW(
            indexName: "CloudflareHNSWRejectionDocument_embedding"
        )) {
            try definition.validateCloudflareHostingCapabilities()
        }

        let storageClient = UnexpectedStorageAccessClient()
        let completion = RecordingCloudflareDatabaseCompletion()
        let runtime = CloudflareDatabaseRuntime(
            application: application,
            storageClient: storageClient,
            jobScheduler: DiscardingDatabaseJobScheduler(),
            completion: CloudflareDatabaseCompletionChannel(
                completion: completion
            )
        )

        await runtime.start(callID: 90)

        let result = try #require(completion.completion(callID: 90))
        #expect(result.status == .startupFailed)
        #expect(
            string(from: result.payload)
                == "Cloudflare hosting does not support HNSW for vector index 'CloudflareHNSWRejectionDocument_embedding'"
        )
        #expect(await storageClient.recordedAccessCount() == 0)
    }

    @Test("custom canonical HNSW configuration cannot bypass admission")
    func rejectsCustomHNSWConfiguration() async throws {
        let application = try CloudflareHNSWRejectionApplication(
            indexConfiguration: CustomHNSWRuntimeConfiguration()
        )
        let definition = try await application.makeContainerDefinition()

        #expect(throws: CloudflareDatabaseConfigurationError.unsupportedHNSW(
            indexName: "CloudflareHNSWRejectionDocument_embedding"
        )) {
            try definition.validateCloudflareHostingCapabilities()
        }
    }

    @Test("invalid vector configuration remains a typed bootstrap failure")
    func rejectsInvalidVectorConfiguration() async throws {
        let application = try CloudflareHNSWRejectionApplication(
            indexConfiguration: InvalidVectorRuntimeConfiguration()
        )
        let definition = try await application.makeContainerDefinition()

        #expect(
            throws: CloudflareDatabaseConfigurationError
                .invalidVectorConfiguration
        ) {
            try definition.validateCloudflareHostingCapabilities()
        }
    }
    #endif

    @Test("selected runtime traits satisfy the verification schema")
    func composesSelectedRuntimeFeatures() async throws {
        let application = try RuntimeVerificationApplication()
        let definition = try await application.makeContainerDefinition()
        try definition.validateCloudflareHostingCapabilities()
    }

    @Test("startup exposes the canonical capabilities operation")
    func startsFullServerRuntime() async throws {
        let completion = RecordingCloudflareDatabaseCompletion()
        let runtime = CloudflareDatabaseRuntime(
            application: try RuntimeVerificationApplication(),
            storageClient: InMemoryCloudflareDurableObjectStorageClient(),
            jobScheduler: DiscardingDatabaseJobScheduler(),
            completion: CloudflareDatabaseCompletionChannel(
                completion: completion
            )
        )

        await runtime.start(callID: 1)
        #expect(completion.completion(callID: 1)?.status == .success)

        let request = try DatabaseWireEncoder().encodeRequest(
            DatabaseOperations.capabilitiesDescribe,
            requestID: 42,
            metadata: OperationRequestMetadata(),
            request: EmptyOperationPayload()
        )
        await runtime.invoke(callID: 2, requestBytes: request)

        let completionRecord = try #require(
            completion.completion(callID: 2)
        )
        #expect(completionRecord.status == .success)
        let decoded = try DatabaseWireDecoder().decodeResponse(
            DatabaseOperations.capabilitiesDescribe,
            from: completionRecord.payload,
            matching: 42
        )
        let response: CapabilitiesDescribeOperation.Response
        switch decoded {
        case .success(let value):
            response = value
        case .failure(let error):
            throw error
        }
        #expect(response.runtimeVersion == "cloudflare-runtime-verification")
    }

    @Test("full runtime describes schema and persists canonical entities")
    func executesSchemaMutationAndQueryOperations() async throws {
        let completion = RecordingCloudflareDatabaseCompletion()
        let runtime = CloudflareDatabaseRuntime(
            application: try RuntimeVerificationApplication(),
            storageClient: InMemoryCloudflareDurableObjectStorageClient(),
            jobScheduler: DiscardingDatabaseJobScheduler(),
            completion: CloudflareDatabaseCompletionChannel(
                completion: completion
            )
        )
        await runtime.start(callID: 60)
        #expect(completion.completion(callID: 60)?.status == .success)

        let schema = try await invoke(
            DatabaseOperations.schemaDescribe,
            request: EmptyOperationPayload(),
            requestID: 61,
            callID: 61,
            runtime: runtime,
            completion: completion
        )
        let entity = try #require(
            schema.entities.first {
                $0.name == RuntimeVerificationDocument.persistableType
            }
        )
        #expect(entity.fields.map(\.name) == ["id", "title"])

        let identity = try EntityReference(
            entity: RuntimeVerificationDocument.persistableType,
            id: .string("document-1")
        )
        let mutation = try await invoke(
            DatabaseOperations.mutationExecute,
            request: MutationExecuteOperation.Request(
                input: .entities([
                    MutationExecuteOperation.Change(
                        kind: .insert,
                        identity: identity,
                        fields: try FieldObject([
                            (key: "id", value: .string("document-1")),
                            (key: "title", value: .string("Cloudflare runtime")),
                        ])
                    )
                ])
            ),
            requestID: 62,
            callID: 62,
            metadata: OperationRequestMetadata(
                idempotencyKey: "runtime-document-1"
            ),
            runtime: runtime,
            completion: completion
        )
        guard case .entities(let effects) = mutation.result else {
            Issue.record("Entity mutation returned an RDF result")
            return
        }
        #expect(effects.count == 1)
        #expect(effects[0].identity == identity)

        let query = try await invoke(
            DatabaseOperations.queryExecute,
            request: QueryExecuteOperation.Request(
                input: .text(
                    language: .sql,
                    statement:
                        "SELECT id, title FROM RuntimeVerificationDocument"
                )
            ),
            requestID: 63,
            callID: 63,
            runtime: runtime,
            completion: completion
        )
        guard case .rows(let page) = query else {
            Issue.record("Entity query returned a non-row result")
            return
        }
        #expect(page.rowCount == 1)
        let titleColumnIndex = try #require(
            page.columns.firstIndex { $0.name == "title" }
        )
        let rows = try page.materializedRows(maximumCount: 1)
        #expect(rows[0].values[titleColumnIndex] == .string("Cloudflare runtime"))
    }

    @Test("startup failures can be retried and successful startup is single-use")
    func retriesStartupFailure() async throws {
        let completion = RecordingCloudflareDatabaseCompletion()
        let runtime = CloudflareDatabaseRuntime(
            application: try RuntimeVerificationApplication(),
            storageClient: FailingOnceReadinessClient(),
            jobScheduler: DiscardingDatabaseJobScheduler(),
            completion: CloudflareDatabaseCompletionChannel(
                completion: completion
            )
        )

        await runtime.start(callID: 10)
        #expect(completion.completion(callID: 10)?.status == .startupFailed)

        await runtime.start(callID: 11)
        #expect(completion.completion(callID: 11)?.status == .success)

        await runtime.start(callID: 12)
        #expect(completion.completion(callID: 12)?.status == .alreadyStarted)
    }

    @Test("requests require startup and obey frame limits")
    func enforcesLifecycleAndRequestLimit() async throws {
        let completion = RecordingCloudflareDatabaseCompletion()
        let limits = try CloudflareDatabaseRuntimeLimits(
            maximumRequestBytes: 4,
            maximumResponseBytes: 4,
            maximumErrorBytes:
                CloudflareDatabaseRuntimeLimits.protocolMinimumErrorBytes,
            maximumPendingInvocations: 1
        )
        let runtime = CloudflareDatabaseRuntime(
            application: try RuntimeVerificationApplication(),
            storageClient: InMemoryCloudflareDurableObjectStorageClient(),
            jobScheduler: DiscardingDatabaseJobScheduler(),
            completion: CloudflareDatabaseCompletionChannel(
                completion: completion
            ),
            limits: limits
        )

        await runtime.invoke(callID: 20, requestBytes: [1])
        #expect(completion.completion(callID: 20)?.status == .notStarted)

        await runtime.start(callID: 21)
        #expect(completion.completion(callID: 21)?.status == .success)

        await runtime.invoke(callID: 22, requestBytes: [0, 1, 2, 3, 4])
        #expect(completion.completion(callID: 22)?.status == .requestTooLarge)
    }

    @Test("malformed DatabaseWire is rejected without poisoning the runtime")
    func rejectsMalformedRequestFrame() async throws {
        let completion = RecordingCloudflareDatabaseCompletion()
        let runtime = CloudflareDatabaseRuntime(
            application: try RuntimeVerificationApplication(),
            storageClient: InMemoryCloudflareDurableObjectStorageClient(),
            jobScheduler: DiscardingDatabaseJobScheduler(),
            completion: CloudflareDatabaseCompletionChannel(
                completion: completion
            )
        )

        await runtime.start(callID: 23)
        await runtime.invoke(callID: 24, requestBytes: [0])

        #expect(completion.completion(callID: 24)?.status == .invalidRequestFrame)

        let validRequest = try DatabaseWireEncoder().encodeRequest(
            DatabaseOperations.capabilitiesDescribe,
            requestID: 25,
            metadata: OperationRequestMetadata(),
            request: EmptyOperationPayload()
        )
        await runtime.invoke(callID: 25, requestBytes: validRequest)
        #expect(completion.completion(callID: 25)?.status == .success)
    }

    @Test("alarms enter the persistent job service through the runtime queue")
    func runsScheduledWork() async throws {
        let completion = RecordingCloudflareDatabaseCompletion()
        let jobService = RecordingCloudflareDatabaseJobService()
        let runtime = CloudflareDatabaseRuntime(
            application: try RuntimeVerificationApplication(
                jobService: jobService
            ),
            storageClient: InMemoryCloudflareDurableObjectStorageClient(),
            jobScheduler: DiscardingDatabaseJobScheduler(),
            completion: CloudflareDatabaseCompletionChannel(
                completion: completion
            )
        )

        await runtime.alarm(callID: 30)
        #expect(completion.completion(callID: 30)?.status == .notStarted)

        await runtime.start(callID: 31)
        await runtime.alarm(callID: 32)

        #expect(completion.completion(callID: 31)?.status == .success)
        #expect(completion.completion(callID: 32)?.status == .success)
        #expect(await jobService.runCount() == 1)
    }

    @Test("alarm failures remain failed so Durable Objects can retry them")
    func propagatesScheduledWorkFailure() async throws {
        let completion = RecordingCloudflareDatabaseCompletion()
        let runtime = CloudflareDatabaseRuntime(
            application: try RuntimeVerificationApplication(),
            storageClient: InMemoryCloudflareDurableObjectStorageClient(),
            jobScheduler: DiscardingDatabaseJobScheduler(),
            completion: CloudflareDatabaseCompletionChannel(
                completion: completion
            )
        )

        await runtime.start(callID: 40)
        await runtime.alarm(callID: 41)

        let completionRecord = try #require(
            completion.completion(callID: 41)
        )
        #expect(completionRecord.status == .scheduledWorkFailed)
        #expect(
            string(from: completionRecord.payload)
                == "scheduled_work_failure.v1;stage=unclassified;cause=unclassified"
        )
    }

    @Test("alarm failures retain typed job diagnostics")
    func preservesScheduledWorkDiagnostic() async throws {
        let completion = RecordingCloudflareDatabaseCompletion()
        let runtime = CloudflareDatabaseRuntime(
            application: try RuntimeVerificationApplication(
                jobService: ScheduledWorkFailureJobService(
                    failure: .corruptedState
                )
            ),
            storageClient: InMemoryCloudflareDurableObjectStorageClient(),
            jobScheduler: DiscardingDatabaseJobScheduler(),
            completion: CloudflareDatabaseCompletionChannel(
                completion: completion
            )
        )

        await runtime.start(callID: 42)
        await runtime.alarm(callID: 43)

        let completionRecord = try #require(
            completion.completion(callID: 43)
        )
        #expect(completionRecord.status == .scheduledWorkFailed)
        #expect(
            string(from: completionRecord.payload)
                == "scheduled_work_failure.v1;stage=processing_job;cause=job.corrupted_state"
        )
    }

    @Test("the pending-operation limit includes the active operation")
    func activeOperationConsumesQueueCapacity() async throws {
        let completion = RecordingCloudflareDatabaseCompletion()
        let jobService = SuspendedCloudflareDatabaseJobService()
        let runtime = CloudflareDatabaseRuntime(
            application: try RuntimeVerificationApplication(
                jobService: jobService
            ),
            storageClient: InMemoryCloudflareDurableObjectStorageClient(),
            jobScheduler: DiscardingDatabaseJobScheduler(),
            completion: CloudflareDatabaseCompletionChannel(
                completion: completion
            ),
            limits: try CloudflareDatabaseRuntimeLimits(
                maximumRequestBytes: 4 * 1_024,
                maximumResponseBytes: 4 * 1_024,
                maximumErrorBytes: 1_024,
                maximumPendingInvocations: 1
            )
        )

        await runtime.start(callID: 50)
        let activeAlarm = Task {
            await runtime.alarm(callID: 51)
        }
        await jobService.waitUntilScheduledWorkStarts()

        let request = try DatabaseWireEncoder().encodeRequest(
            DatabaseOperations.capabilitiesDescribe,
            requestID: 52,
            metadata: OperationRequestMetadata(),
            request: EmptyOperationPayload()
        )
        await runtime.invoke(callID: 52, requestBytes: request)

        #expect(
            completion.completion(callID: 52)?.status
                == .queueCapacityExceeded
        )
        await jobService.resume()
        await activeAlarm.value
        #expect(completion.completion(callID: 51)?.status == .success)
    }

    private func invoke<Request: Sendable, Response: Sendable>(
        _ operation: DatabaseOperation<Request, Response>,
        request: Request,
        requestID: UInt64,
        callID: UInt32,
        metadata: OperationRequestMetadata = OperationRequestMetadata(),
        runtime: CloudflareDatabaseRuntime,
        completion: RecordingCloudflareDatabaseCompletion
    ) async throws -> Response {
        let requestBytes = try DatabaseWireEncoder().encodeRequest(
            operation,
            requestID: requestID,
            metadata: metadata,
            request: request
        )
        await runtime.invoke(callID: callID, requestBytes: requestBytes)
        let completed = try #require(completion.completion(callID: callID))
        #expect(completed.status == .success)
        let decoded = try DatabaseWireDecoder().decodeResponse(
            operation,
            from: completed.payload,
            matching: requestID
        )
        switch decoded {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }

    private func string(from bytes: ByteString) -> String {
        bytes.withUnsafeBytes { buffer in
            String(decoding: buffer, as: UTF8.self)
        }
    }
}
