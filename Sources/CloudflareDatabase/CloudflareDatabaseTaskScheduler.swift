#if arch(wasm32)
@_spi(ExperimentalCustomExecutors) @_spi(ExperimentalScheduling) import _Concurrency
import CloudflareDatabaseTaskScheduling
import Synchronization

@_extern(wasm, module: "database_executor", name: "schedule")
private func scheduleDatabaseTask(
    _ taskID: UInt32,
    _ delayMilliseconds: Double
)

@_silgen_name("swift_get_time")
private func readRuntimeClock(
    _ seconds: UnsafeMutablePointer<Int64>,
    _ nanoseconds: UnsafeMutablePointer<Int64>,
    _ clock: CInt
)

@_cdecl("cloudflare_database_enqueue_task_after_delay")
func enqueueDatabaseTaskAfterDelay(
    _ delayNanoseconds: UInt64,
    _ task: UnsafeMutableRawPointer
) {
    CloudflareDatabaseTaskScheduler.enqueueTask(
        unsafeBitCast(task, to: UnownedJob.self),
        delayMilliseconds: Double(delayNanoseconds) / 1_000_000
    )
}

@_cdecl("cloudflare_database_enqueue_task_at_deadline")
func enqueueDatabaseTaskAtDeadline(
    _ seconds: Int64,
    _ nanoseconds: Int64,
    _ clock: Int32,
    _ task: UnsafeMutableRawPointer
) {
    CloudflareDatabaseTaskScheduler.enqueueTask(
        unsafeBitCast(task, to: UnownedJob.self),
        delayMilliseconds: CloudflareDatabaseTaskScheduler
            .deadlineDelayMilliseconds(
                seconds: seconds,
                nanoseconds: nanoseconds,
                clock: clock
            )
    )
}

/// Cloudflare task scheduler for the database runtime's serial executor.
final class CloudflareDatabaseTaskScheduler: SerialExecutor, Sendable {
    private static let maximumTaskID: UInt32 = 0x7fff_ffff

    private struct State: Sendable {
        var nextTaskID: UInt32 = 1
        var tasks: [UInt32: UnownedJob] = [:]
    }

    private static let shared = CloudflareDatabaseTaskScheduler()
    private static let installationState = Mutex(false)

    private let state = Mutex(State())

    private init() {}

    static func install() {
        let shouldInstall = installationState.withLock { installed in
            guard !installed else {
                return false
            }
            installed = true
            return true
        }
        guard shouldInstall else {
            return
        }
        if #available(
            macOS 9999,
            iOS 9999,
            watchOS 9999,
            tvOS 9999,
            visionOS 9999,
            *
        ) {
            installCloudflareDatabaseTaskScheduler()
            _Concurrency._createExecutors(
                factory: CloudflareDatabaseTaskScheduler.self
            )
        }
    }

    static func run(taskID: UInt32) {
        precondition(taskID != 0, "Database task ID must be positive")
        let task = shared.state.withLock { state in
            state.tasks.removeValue(forKey: taskID)
        }
        guard let task else {
            preconditionFailure("Database scheduler received an unknown task ID")
        }
        task.runSynchronously(on: shared.asUnownedSerialExecutor())
    }

    func enqueue(_ task: consuming ExecutorJob) {
        schedule(UnownedJob(task), delayMilliseconds: 0)
    }

    func checkIsolated() {}

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    private func schedule(
        _ task: UnownedJob,
        delayMilliseconds: Double
    ) {
        let taskID = state.withLock { state in
            let taskID = Self.reserveTaskID(state: &state)
            state.tasks[taskID] = task
            return taskID
        }
        scheduleDatabaseTask(
            taskID,
            max(0, delayMilliseconds)
        )
    }

    fileprivate static func enqueueTask(
        _ task: UnownedJob,
        delayMilliseconds: Double
    ) {
        shared.schedule(task, delayMilliseconds: delayMilliseconds)
    }

    fileprivate static func deadlineDelayMilliseconds(
        seconds: Int64,
        nanoseconds: Int64,
        clock: Int32
    ) -> Double {
        var currentSeconds: Int64 = 0
        var currentNanoseconds: Int64 = 0
        readRuntimeClock(
            &currentSeconds,
            &currentNanoseconds,
            clock
        )
        let secondsDifference = Double(seconds) - Double(currentSeconds)
        let nanosecondsDifference = Double(nanoseconds)
            - Double(currentNanoseconds)
        return max(
            0,
            secondsDifference * 1_000
                + nanosecondsDifference / 1_000_000
        )
    }

    private static func reserveTaskID(state: inout State) -> UInt32 {
        while true {
            let candidate = state.nextTaskID
            state.nextTaskID = candidate == maximumTaskID
                ? 1
                : candidate + 1
            if state.tasks[candidate] == nil {
                return candidate
            }
        }
    }

}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension CloudflareDatabaseTaskScheduler: TaskExecutor {}

@available(
    macOS 9999,
    iOS 9999,
    watchOS 9999,
    tvOS 9999,
    visionOS 9999,
    *
)
@_spi(ExperimentalCustomExecutors)
extension CloudflareDatabaseTaskScheduler: MainExecutor {
    func run() throws {}

    func stop() {}
}

@available(
    macOS 9999,
    iOS 9999,
    watchOS 9999,
    tvOS 9999,
    visionOS 9999,
    *
)
@_spi(ExperimentalCustomExecutors)
extension CloudflareDatabaseTaskScheduler: ExecutorFactory {
    static var mainExecutor: any MainExecutor {
        shared
    }

    static var defaultExecutor: any TaskExecutor {
        shared
    }
}
#endif
