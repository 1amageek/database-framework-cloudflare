import DatabaseEngine

/// Database wire storage backed by Cloudflare Durable Object SQLite.
public struct CloudflareDatabaseWireStorage<Host: DatabaseStorageHost>: DatabaseStorage {
    private let host: Host

    public init(host: Host) {
        self.host = host
    }

    public func read(key: [UInt8]) throws(DatabaseRuntimeError) -> [UInt8]? {
        switch try dispatch(.read(key: key)) {
        case .read(let value):
            return value
        case .failure(let message):
            throw .storageFailure(message)
        default:
            throw .invalidStorageResponse("Durable Object host returned a non-read response")
        }
    }

    public func scan(
        begin: [UInt8],
        end: [UInt8],
        limit: Int,
        reverse: Bool
    ) throws(DatabaseRuntimeError) -> [DatabaseKeyValue] {
        switch try dispatch(.scan(begin: begin, end: end, limit: limit, reverse: reverse)) {
        case .scan(let rows):
            return rows
        case .failure(let message):
            throw .storageFailure(message)
        default:
            throw .invalidStorageResponse("Durable Object host returned a non-scan response")
        }
    }

    public func commit(_ writes: [DatabaseWriteOperation]) throws(DatabaseRuntimeError) {
        switch try dispatch(.commit(writes)) {
        case .committed:
            return
        case .failure(let message):
            throw .storageFailure(message)
        default:
            throw .invalidStorageResponse("Durable Object host returned a non-commit response")
        }
    }

    private func dispatch(
        _ request: DatabaseStorageHostRequest
    ) throws(DatabaseRuntimeError) -> DatabaseStorageHostResponse {
        let response = try host.dispatch(request)
        if case .failure(let message) = response {
            throw .storageFailure(message)
        }
        return response
    }
}

public extension CloudflareDatabaseWireStorage where Host == CloudflareDurableObjectHost {
    init() {
        self.init(host: CloudflareDurableObjectHost())
    }
}
