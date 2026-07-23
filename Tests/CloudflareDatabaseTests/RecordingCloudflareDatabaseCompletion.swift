import CloudflareDatabase
import DatabaseValue
import Synchronization

final class RecordingCloudflareDatabaseCompletion:
    CloudflareDatabaseCompletion,
    Sendable {
    struct CompletionRecord: Sendable, Equatable {
        let callID: UInt32
        let status: CloudflareDatabaseCompletionStatus
        let payload: DatabaseBytes
    }

    private let completions = Mutex<[CompletionRecord]>([])

    func complete(
        callID: UInt32,
        status: CloudflareDatabaseCompletionStatus,
        payload: DatabaseBytes
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
}
