import DatabaseEngine

/// Cloudflare WASM import implementation of the storage host boundary.
public struct CloudflareDurableObjectHost: DatabaseStorageHost {
    public init() {}

    public func dispatch(
        _ request: DatabaseStorageHostRequest
    ) throws(DatabaseRuntimeError) -> DatabaseStorageHostResponse {
        let requestBytes = try DatabaseStorageHostCodec.encode(request: request)
        guard UInt64(requestBytes.count) <= UInt64(UInt32.max) else {
            throw .wire(.byteCountOverflow)
        }

        let requestPointer = WasmMemory.allocate(byteCount: UInt32(requestBytes.count))
        WasmMemory.writeBytes(requestBytes, pointer: requestPointer)
        defer {
            WasmMemory.deallocate(pointer: requestPointer, byteCount: UInt32(requestBytes.count))
        }

        let framePointer = database_host_dispatch(requestPointer, UInt32(requestBytes.count))
        guard framePointer != 0 else {
            throw .storageFailure("Durable Object host returned no response")
        }
        guard let frame = WasmMemory.readFrame(pointer: framePointer) else {
            throw .invalidStorageResponse("Durable Object host returned an invalid response frame")
        }
        WasmMemory.deallocate(pointer: framePointer, byteCount: frame.byteCount)
        return try DatabaseStorageHostCodec.decodeResponse(frame.payload)
    }
}
