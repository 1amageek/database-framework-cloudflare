import DatabaseEngine
import DatabaseWire

/// Binary codec for the Swift WASM storage-host boundary.
public enum DatabaseStorageHostCodec {
    public static let protocolVersion: UInt8 = 1

    private enum Operation: UInt8 {
        case read = 1
        case scan = 2
        case commit = 3
    }

    private enum Status: UInt8 {
        case ok = 1
        case failure = 2
    }

    private enum WriteOperation: UInt8 {
        case set = 1
        case clear = 2
    }

    public static func encode(
        request: DatabaseStorageHostRequest
    ) throws(DatabaseRuntimeError) -> [UInt8] {
        try mapWireError {
            var writer = DatabaseWireBinaryWriter()
            writer.writeUInt8(protocolVersion)
            switch request {
            case .read(let key):
                writer.writeUInt8(Operation.read.rawValue)
                try writer.writeBytes(key)
            case .scan(let begin, let end, let limit, let reverse):
                writer.writeUInt8(Operation.scan.rawValue)
                try writer.writeBytes(begin)
                try writer.writeBytes(end)
                try writer.writeCount(limit)
                writer.writeBool(reverse)
            case .commit(let writes):
                writer.writeUInt8(Operation.commit.rawValue)
                try writer.writeCount(writes.count)
                for write in writes {
                    switch write {
                    case .set(let key, let value):
                        writer.writeUInt8(WriteOperation.set.rawValue)
                        try writer.writeBytes(key)
                        try writer.writeBytes(value)
                    case .clear(let key):
                        writer.writeUInt8(WriteOperation.clear.rawValue)
                        try writer.writeBytes(key)
                    }
                }
            }
            return writer.bytes
        }
    }

    public static func decodeRequest(
        _ bytes: [UInt8]
    ) throws(DatabaseRuntimeError) -> DatabaseStorageHostRequest {
        try mapWireError {
            var reader = DatabaseWireBinaryReader(bytes)
            try validateVersion(reader.readUInt8())
            let operation = try readOperation(&reader)
            let request: DatabaseStorageHostRequest
            switch operation {
            case .read:
                request = .read(key: try reader.readBytes())
            case .scan:
                request = .scan(
                    begin: try reader.readBytes(),
                    end: try reader.readBytes(),
                    limit: try reader.readCount(),
                    reverse: try reader.readBool()
                )
            case .commit:
                let count = try reader.readCount()
                var writes: [DatabaseWriteOperation] = []
                writes.reserveCapacity(count)
                for _ in 0..<count {
                    switch try readWriteOperation(&reader) {
                    case .set:
                        writes.append(.set(key: try reader.readBytes(), value: try reader.readBytes()))
                    case .clear:
                        writes.append(.clear(key: try reader.readBytes()))
                    }
                }
                request = .commit(writes)
            }
            try reader.ensureFullyRead()
            return request
        }
    }

    public static func encode(
        response: DatabaseStorageHostResponse
    ) throws(DatabaseRuntimeError) -> [UInt8] {
        try mapWireError {
            var writer = DatabaseWireBinaryWriter()
            writer.writeUInt8(protocolVersion)
            switch response {
            case .read(let value):
                writer.writeUInt8(Status.ok.rawValue)
                writer.writeUInt8(Operation.read.rawValue)
                writer.writeBool(value != nil)
                if let value {
                    try writer.writeBytes(value)
                }
            case .scan(let rows):
                writer.writeUInt8(Status.ok.rawValue)
                writer.writeUInt8(Operation.scan.rawValue)
                try writer.writeCount(rows.count)
                for row in rows {
                    try writer.writeBytes(row.key)
                    try writer.writeBytes(row.value)
                }
            case .committed:
                writer.writeUInt8(Status.ok.rawValue)
                writer.writeUInt8(Operation.commit.rawValue)
            case .failure(let message):
                writer.writeUInt8(Status.failure.rawValue)
                try writer.writeString(message)
            }
            return writer.bytes
        }
    }

    public static func decodeResponse(
        _ bytes: [UInt8]
    ) throws(DatabaseRuntimeError) -> DatabaseStorageHostResponse {
        try mapWireError {
            var reader = DatabaseWireBinaryReader(bytes)
            try validateVersion(reader.readUInt8())
            let status = try readStatus(&reader)
            guard status == .ok else {
                let response = DatabaseStorageHostResponse.failure(try reader.readString())
                try reader.ensureFullyRead()
                return response
            }

            let operation = try readOperation(&reader)
            let response: DatabaseStorageHostResponse
            switch operation {
            case .read:
                response = .read(try reader.readBool() ? reader.readBytes() : nil)
            case .scan:
                let count = try reader.readCount()
                var rows: [DatabaseKeyValue] = []
                rows.reserveCapacity(count)
                for _ in 0..<count {
                    rows.append(DatabaseKeyValue(key: try reader.readBytes(), value: try reader.readBytes()))
                }
                response = .scan(rows)
            case .commit:
                response = .committed
            }
            try reader.ensureFullyRead()
            return response
        }
    }

    private static func validateVersion(_ version: UInt8) throws(DatabaseWireError) {
        guard version == protocolVersion else {
            throw .unsupportedProtocolVersion(version)
        }
    }

    private static func readOperation(
        _ reader: inout DatabaseWireBinaryReader
    ) throws(DatabaseWireError) -> Operation {
        let rawValue = try reader.readUInt8()
        guard let operation = Operation(rawValue: rawValue) else {
            throw .unknownOperation(rawValue)
        }
        return operation
    }

    private static func readStatus(
        _ reader: inout DatabaseWireBinaryReader
    ) throws(DatabaseWireError) -> Status {
        let rawValue = try reader.readUInt8()
        guard let status = Status(rawValue: rawValue) else {
            throw .unknownResponseStatus(rawValue)
        }
        return status
    }

    private static func readWriteOperation(
        _ reader: inout DatabaseWireBinaryReader
    ) throws(DatabaseWireError) -> WriteOperation {
        let rawValue = try reader.readUInt8()
        guard let operation = WriteOperation(rawValue: rawValue) else {
            throw .unknownOperation(rawValue)
        }
        return operation
    }

    private static func mapWireError<T>(
        _ body: () throws -> T
    ) throws(DatabaseRuntimeError) -> T {
        do {
            return try body()
        } catch let error as DatabaseWireError {
            throw .wire(error)
        } catch {
            throw .invalidStorageResponse("Storage host codec failed")
        }
    }
}
