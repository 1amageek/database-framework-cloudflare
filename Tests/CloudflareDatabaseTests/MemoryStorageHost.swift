import CloudflareDatabase
import DatabaseEngine
import Synchronization

final class MemoryStorageHost: DatabaseStorageHost {
    private let rows = Mutex<[DatabaseKeyValue]>([])

    func dispatch(
        _ request: DatabaseStorageHostRequest
    ) throws(DatabaseRuntimeError) -> DatabaseStorageHostResponse {
        rows.withLock { rows in
            switch request {
            case .read(let key):
                return .read(rows.first(where: { $0.key == key })?.value)
            case .scan(let begin, let end, let limit, let reverse):
                var result = rows.filter {
                    compareBytes($0.key, begin) >= 0 && compareBytes($0.key, end) < 0
                }
                result.sort { compareBytes($0.key, $1.key) < 0 }
                if reverse {
                    result.reverse()
                }
                if limit > 0 && result.count > limit {
                    result = Array(result.prefix(limit))
                }
                return .scan(result)
            case .commit(let writes):
                for write in writes {
                    switch write {
                    case .set(let key, let value):
                        upsert(DatabaseKeyValue(key: key, value: value), into: &rows)
                    case .clear(let key):
                        rows.removeAll { $0.key == key }
                    }
                }
                return .committed
            }
        }
    }

    private func upsert(_ row: DatabaseKeyValue, into rows: inout [DatabaseKeyValue]) {
        if let index = rows.firstIndex(where: { $0.key == row.key }) {
            rows[index] = row
        } else {
            rows.append(row)
        }
    }

    private func compareBytes(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
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
