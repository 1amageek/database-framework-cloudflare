@testable import CloudflareDatabase
import Synchronization
import Testing

@Suite("Cloudflare database pending queue")
struct CloudflareDatabasePendingQueueTests {
    private final class Probe: Sendable, Equatable {
        let identifier: Int
        private let releaseRecorder: ReleaseRecorder

        init(identifier: Int, releaseRecorder: ReleaseRecorder) {
            self.identifier = identifier
            self.releaseRecorder = releaseRecorder
        }

        deinit {
            releaseRecorder.record(identifier)
        }

        static func == (lhs: Probe, rhs: Probe) -> Bool {
            lhs === rhs
        }
    }

    private final class ReleaseRecorder: Sendable {
        private let state = Mutex<[Int]>([])

        var identifiers: [Int] {
            state.withLock { $0 }
        }

        func record(_ identifier: Int) {
            state.withLock { $0.append(identifier) }
        }
    }

    @Test("FIFO pop releases processed payloads before the queue drains")
    func popReleasesProcessedPayloads() {
        let releaseRecorder = ReleaseRecorder()
        var queue = CloudflareDatabasePendingQueue<Probe>()
        for identifier in 0..<256 {
            queue.append(
                Probe(
                    identifier: identifier,
                    releaseRecorder: releaseRecorder
                )
            )
        }

        var first = queue.popFirst()
        #expect(first?.identifier == 0)
        #expect(queue.count == 255)
        #expect(releaseRecorder.identifiers.isEmpty)
        first = nil
        #expect(releaseRecorder.identifiers == [0])

        for expectedIdentifier in 1..<256 {
            var next = queue.popFirst()
            #expect(next?.identifier == expectedIdentifier)
            next = nil
        }
        #expect(queue.count == 0)
        #expect(queue.popFirst() == nil)
        #expect(releaseRecorder.identifiers == Array(0..<256))
    }
}
