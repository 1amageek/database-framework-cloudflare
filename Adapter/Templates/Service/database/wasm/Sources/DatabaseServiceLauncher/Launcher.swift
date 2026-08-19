import CloudflareDatabase
import {{service.application.module}}

#if os(WASI)
private let databaseRuntime: CloudflareDatabaseRuntimeEntrypoint = {
    do {
        return try CloudflareDatabaseRuntimeEntrypoint(
            application: {{service.application.type}}()
        )
    } catch {
        preconditionFailure("Cloudflare database runtime creation failed")
    }
}()

@_expose(wasm, "database_abi_version")
@_cdecl("database_abi_version")
func reportDatabaseRuntimeABIVersion() -> UInt32 {
    CloudflareDatabaseRuntimeEntrypoint.abiVersion
}

@_expose(wasm, "database_alloc")
@_cdecl("database_alloc")
func reserveDatabaseInvocationPayload(byteCount: UInt32) -> UInt32 {
    databaseRuntime.reserveInvocationPayload(byteCount: byteCount)
}

@_expose(wasm, "database_dealloc")
@_cdecl("database_dealloc")
func releaseDatabaseInvocationPayload(
    payloadAddress: UInt32,
    byteCount: UInt32
) {
    databaseRuntime.releaseInvocationPayload(
        payloadAddress: payloadAddress,
        byteCount: byteCount
    )
}

@_expose(wasm, "database_start")
@_cdecl("database_start")
func startDatabaseRuntime(callID: UInt32) {
    databaseRuntime.start(callID: callID)
}

@_expose(wasm, "database_invoke")
@_cdecl("database_invoke")
func invokeDatabaseRuntime(
    callID: UInt32,
    contextAddress: UInt32,
    contextByteCount: UInt32,
    requestAddress: UInt32,
    requestByteCount: UInt32
) {
    databaseRuntime.invoke(
        callID: callID,
        contextAddress: contextAddress,
        contextByteCount: contextByteCount,
        requestAddress: requestAddress,
        requestByteCount: requestByteCount
    )
}

@_expose(wasm, "database_alarm")
@_cdecl("database_alarm")
func deliverDatabaseAlarm(callID: UInt32) {
    databaseRuntime.alarm(callID: callID)
}

@_expose(wasm, "database_shutdown")
@_cdecl("database_shutdown")
func shutdownDatabaseRuntime(callID: UInt32) {
    databaseRuntime.shutdown(callID: callID)
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
