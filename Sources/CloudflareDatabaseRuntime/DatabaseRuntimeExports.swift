import CloudflareDatabase

@_expose(wasm, "database_alloc")
@_cdecl("database_alloc")
public func database_alloc(_ byteCount: UInt32) -> UInt32 {
    WasmMemory.allocate(byteCount: byteCount)
}

@_expose(wasm, "database_dealloc")
@_cdecl("database_dealloc")
public func database_dealloc(_ pointer: UInt32, _ byteCount: UInt32) {
    WasmMemory.deallocate(pointer: pointer, byteCount: byteCount)
}

@_expose(wasm, "database_dispatch")
@_cdecl("database_dispatch")
public func database_dispatch(_ pointer: UInt32, _ length: UInt32) -> UInt32 {
    DatabaseRuntimeDispatcher.dispatch(pointer: pointer, length: length)
}
