import CloudflareDatabase
import DatabaseWire

enum DatabaseRuntimeDispatcher {
    static func dispatch(pointer: UInt32, length: UInt32) -> UInt32 {
        guard let requestBytes = WasmMemory.readBytes(pointer: pointer, length: length) else {
            return failureFrame(message: "Invalid request memory")
        }

        do {
            let runtime = CloudflareDatabaseWireRuntime()
            let responseBytes = try runtime.handle(requestBytes)
            return WasmMemory.makeFrame(payload: responseBytes)
        } catch {
            return failureFrame(message: "Database runtime dispatch failed")
        }
    }

    private static func failureFrame(message: String) -> UInt32 {
        do {
            let responseBytes = try DatabaseWireCodec.encode(
                response: .failure(status: .executionFailure, message: message)
            )
            return WasmMemory.makeFrame(payload: responseBytes)
        } catch {
            return 0
        }
    }
}
