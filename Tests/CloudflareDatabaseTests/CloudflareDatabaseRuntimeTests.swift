import CloudflareDatabase
import CloudflareDurableObjectStorageTesting
import DatabaseValue
import DatabaseWire
import Testing

@Suite("Cloudflare database runtime", .serialized)
struct CloudflareDatabaseRuntimeTests {
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

        let request = try DatabaseEnvelopeCodec.encodeRequest(
            CapabilitiesDescribeOperation.self,
            requestID: 42,
            metadata: DatabaseRequestMetadata(),
            request: DatabaseEmpty()
        )
        await runtime.invoke(callID: 2, requestBytes: request)

        let completionRecord = try #require(
            completion.completion(callID: 2)
        )
        #expect(completionRecord.status == .success)
        let envelope = try DatabaseEnvelopeCodec.decodeResponse(
            completionRecord.payload
        )
        let payload: DatabaseBytes
        switch envelope.payload {
        case .success(let value):
            payload = value
        case .failure(let error):
            throw error
        }
        let response = try DatabaseEnvelopeCodec.decode(
            CapabilitiesDescribeOperation.Response.self,
            from: payload
        )
        #expect(response.runtimeVersion == "cloudflare-runtime-verification")
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
            maximumErrorBytes: 64,
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

        let validRequest = try DatabaseEnvelopeCodec.encodeRequest(
            CapabilitiesDescribeOperation.self,
            requestID: 25,
            metadata: DatabaseRequestMetadata(),
            request: DatabaseEmpty()
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

        #expect(completion.completion(callID: 41)?.status == .runtimeFailed)
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

        let request = try DatabaseEnvelopeCodec.encodeRequest(
            CapabilitiesDescribeOperation.self,
            requestID: 52,
            metadata: DatabaseRequestMetadata(),
            request: DatabaseEmpty()
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
}
