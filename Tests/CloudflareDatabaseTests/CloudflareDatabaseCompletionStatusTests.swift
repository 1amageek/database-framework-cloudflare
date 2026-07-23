import CloudflareDatabase
import Foundation
import Testing

@Suite("Cloudflare database completion status")
struct CloudflareDatabaseCompletionStatusTests {
    @Test("Swift statuses match the canonical ABI v1 vector")
    func matchesCanonicalVector() throws {
        let testDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let repositoryDirectory = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let vectorURL = repositoryDirectory
            .appending(path: "Protocol/database-completion-status-v1.json")
        let data = try Data(contentsOf: vectorURL)
        let decoded = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Int]
        )

        #expect(decoded == canonicalStatuses)
    }

    private var canonicalStatuses: [String: Int] {
        [
            "success": Int(CloudflareDatabaseCompletionStatus.success.rawValue),
            "invalidCallID": Int(CloudflareDatabaseCompletionStatus.invalidCallID.rawValue),
            "invalidPayload": Int(CloudflareDatabaseCompletionStatus.invalidPayload.rawValue),
            "requestTooLarge": Int(CloudflareDatabaseCompletionStatus.requestTooLarge.rawValue),
            "responseTooLarge": Int(CloudflareDatabaseCompletionStatus.responseTooLarge.rawValue),
            "queueCapacityExceeded": Int(CloudflareDatabaseCompletionStatus.queueCapacityExceeded.rawValue),
            "notStarted": Int(CloudflareDatabaseCompletionStatus.notStarted.rawValue),
            "alreadyStarted": Int(CloudflareDatabaseCompletionStatus.alreadyStarted.rawValue),
            "startupInProgress": Int(CloudflareDatabaseCompletionStatus.startupInProgress.rawValue),
            "startupFailed": Int(CloudflareDatabaseCompletionStatus.startupFailed.rawValue),
            "cancelled": Int(CloudflareDatabaseCompletionStatus.cancelled.rawValue),
            "runtimeFailed": Int(CloudflareDatabaseCompletionStatus.runtimeFailed.rawValue),
            "invalidRequestFrame": Int(CloudflareDatabaseCompletionStatus.invalidRequestFrame.rawValue),
        ]
    }
}
