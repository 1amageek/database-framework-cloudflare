import DatabaseServerRuntime
import DatabaseTypes
import StorageKit
import Testing

@testable import CloudflareDatabase

@Suite("Scheduled work diagnostics")
struct ScheduledWorkDiagnosticTests {
    @Test("diagnostics preserve the failure stage and stable cause")
    func preservesStageAndCause() {
        #expect(
            ScheduledWorkDiagnostic.message(
                for: PersistentJobScheduledWorkError.processingJob(
                    DatabaseJobRuntimeError.corruptedState
                )
            )
                == "scheduled_work_failure.v1;stage=processing_job;cause=job.corrupted_state"
        )
        #expect(
            ScheduledWorkDiagnostic.message(
                for:
                    PersistentJobScheduledWorkError
                    .processingJobAndSchedulingNextWakeUp(
                        processingError:
                            DatabaseJobRuntimeError.corruptedPlan,
                        schedulingError: StorageError(
                            code: .backendFailure,
                            message: "private backend detail"
                        )
                    )
            )
                == "scheduled_work_failure.v1;stage=processing_job_and_scheduling_next_wake_up;processing_cause=job.corrupted_plan;scheduling_cause=storage.backend_failure"
        )
    }

    @Test("arbitrary error descriptions never cross the runtime boundary")
    func excludesPrivateDescriptions() {
        let diagnostic = ScheduledWorkDiagnostic.message(
            for: PrivateDiagnosticError()
        )

        #expect(
            diagnostic
                == "scheduled_work_failure.v1;stage=unclassified;cause=unclassified"
        )
        #expect(!diagnostic.contains("private"))
    }

    @Test("oversized diagnostics become one complete bounded code")
    func rejectsPartialDiagnostics() {
        let payload = RuntimeFailurePayload.encode(
            String(repeating: "x", count: 257),
            maximumByteCount:
                CloudflareDatabaseOperationLimits.protocolMinimumErrorBytes
        )

        #expect(string(from: payload) == RuntimeFailurePayload.encodingFailure)
    }

    private struct PrivateDiagnosticError: Error, CustomStringConvertible {
        var description: String { "private diagnostic detail" }
    }

    private func string(from bytes: ByteString) -> String {
        bytes.withUnsafeBytes { buffer in
            String(decoding: buffer, as: UTF8.self)
        }
    }
}
