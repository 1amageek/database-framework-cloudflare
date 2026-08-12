package struct CloudflareDatabasePendingQueue<Element: Sendable>: Sendable {
    private static var compactionThreshold: Int { 64 }

    private var storage: [Element?] = []
    private var headIndex = 0

    package var count: Int {
        storage.count - headIndex
    }

    package mutating func append(_ element: consuming Element) {
        storage.append(element)
    }

    package mutating func popFirst() -> Element? {
        guard headIndex < storage.count else { return nil }
        let element = storage[headIndex]
        // Release a processed request owner immediately; retaining the slot
        // until a busy FIFO drains can exceed the Worker memory budget.
        storage[headIndex] = nil
        headIndex += 1

        if headIndex == storage.count {
            storage.removeAll(keepingCapacity: true)
            headIndex = 0
        } else if headIndex >= Self.compactionThreshold,
                  headIndex >= storage.count - headIndex {
            // This moves only optional owner references, never payload bytes,
            // and runs at most once per compaction-threshold pops.
            storage.removeFirst(headIndex)
            headIndex = 0
        }
        return element
    }
}
