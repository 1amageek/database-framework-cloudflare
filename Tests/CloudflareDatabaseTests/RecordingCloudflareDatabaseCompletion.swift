import CloudflareDatabase
import DatabaseTypes
import Synchronization

final class RecordingCloudflareDatabaseCompletion:
    CloudflareDatabaseCompletion,
    Sendable {
    struct CompletionRecord: Sendable, Equatable {
        let callID: UInt32
        let status: CloudflareDatabaseCompletionStatus
        let payload: ByteString
    }

    private let completions = Mutex<[CompletionRecord]>([])

    func complete(
        callID: UInt32,
        status: CloudflareDatabaseCompletionStatus,
        payload: ByteString
    ) {
        completions.withLock {
            $0.append(
                CompletionRecord(
                    callID: callID,
                    status: status,
                    payload: payload
                )
            )
        }
    }

    func completion(callID: UInt32) -> CompletionRecord? {
        completions.withLock { records in
            records.first { $0.callID == callID }
        }
    }

    func waitForCompletion(callID: UInt32) async throws -> CompletionRecord {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if let completion = completion(callID: callID) {
                return completion
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw WaitError.timedOut(callID)
    }

    private enum WaitError: Error {
        case timedOut(UInt32)
    }
}
