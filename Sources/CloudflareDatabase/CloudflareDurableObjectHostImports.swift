#if arch(wasm32)
@_extern(wasm, module: "database_host", name: "dispatch")
func database_host_dispatch(_ pointer: UInt32, _ length: UInt32) -> UInt32
#else
func database_host_dispatch(_ pointer: UInt32, _ length: UInt32) -> UInt32 {
    0
}
#endif
