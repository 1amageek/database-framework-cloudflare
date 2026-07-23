import CloudflareDatabase

#if os(WASI)
private let runtimeEntrypoint: CloudflareDatabaseRuntimeEntrypoint = {
    do {
        return try CloudflareDatabaseRuntimeEntrypoint(
            application: RuntimeVerificationApplication()
        )
    } catch {
        preconditionFailure(
            "Runtime verification entrypoint creation failed: \(error)"
        )
    }
}()

@_expose(wasm, "database_alloc")
@_cdecl("database_alloc")
func reserveInvocationPayload(byteCount: UInt32) -> UInt32 {
    runtimeEntrypoint.reserveInvocationPayload(byteCount: byteCount)
}

@_expose(wasm, "database_dealloc")
@_cdecl("database_dealloc")
func releaseInvocationPayload(
    payloadAddress: UInt32,
    byteCount: UInt32
) {
    runtimeEntrypoint.releaseInvocationPayload(
        payloadAddress: payloadAddress,
        byteCount: byteCount
    )
}

@_expose(wasm, "database_start")
@_cdecl("database_start")
func startDatabaseRuntime(callID: UInt32) {
    runtimeEntrypoint.start(callID: callID)
}

@_expose(wasm, "database_invoke")
@_cdecl("database_invoke")
func invokeDatabaseRuntime(
    callID: UInt32,
    requestAddress: UInt32,
    requestByteCount: UInt32
) {
    runtimeEntrypoint.invoke(
        callID: callID,
        requestAddress: requestAddress,
        requestByteCount: requestByteCount
    )
}

@_expose(wasm, "database_alarm")
@_cdecl("database_alarm")
func runDatabaseAlarm(callID: UInt32) {
    runtimeEntrypoint.alarm(callID: callID)
}

@_expose(wasm, "database_executor_run")
@_cdecl("database_executor_run")
func runScheduledDatabaseTask(taskID: UInt32) {
    CloudflareDatabaseRuntimeEntrypoint.runScheduledTask(taskID: taskID)
}

@_expose(wasm, "database_clock_resume")
@_cdecl("database_clock_resume")
func resumeDatabaseClockWait(waitID: UInt32) {
    CloudflareDatabaseRuntimeEntrypoint.resumeScheduledWait(waitID: waitID)
}
#endif
