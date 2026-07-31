import DatabaseServer
import StorageKit

enum ScheduledWorkDiagnostic {
    static func message(for error: any Error) -> String {
        switch error {
        case let error as PersistentJobScheduledWorkError:
            return message(for: error)
        default:
            return "scheduled_work_failure.v1;stage=unclassified;cause=\(cause(for: error))"
        }
    }

    private static func message(
        for error: PersistentJobScheduledWorkError
    ) -> String {
        switch error {
        case .loadingDueJobs(let underlyingError):
            return
                "scheduled_work_failure.v1;stage=loading_due_jobs;cause=\(cause(for: underlyingError))"
        case .processingJob(let underlyingError):
            return
                "scheduled_work_failure.v1;stage=processing_job;cause=\(cause(for: underlyingError))"
        case .schedulingNextWakeUp(let underlyingError):
            return
                "scheduled_work_failure.v1;stage=scheduling_next_wake_up;cause=\(cause(for: underlyingError))"
        case .processingJobAndSchedulingNextWakeUp(
            let processingError,
            let schedulingError
        ):
            return
                "scheduled_work_failure.v1;stage=processing_job_and_scheduling_next_wake_up;processing_cause=\(cause(for: processingError));scheduling_cause=\(cause(for: schedulingError))"
        }
    }

    private static func cause(for error: any Error) -> String {
        if error is CancellationError {
            return "task.cancelled"
        }
        if let error = error as? DatabaseJobRuntimeError {
            return cause(for: error)
        }
        if let error = error as? DatabaseResumableOperationRegistryError {
            switch error {
            case .duplicateOperation:
                return "job.duplicate_operation_registration"
            case .unsupportedOperation:
                return "job.operation_not_registered"
            }
        }
        if error is DatabaseJobUnsuccessfulOutcomeCommitError {
            return "job.unsuccessful_outcome_commit_failed"
        }
        if error is PersistentJobPayloadError {
            return "job.invalid_payload"
        }
        if let error = error as? StorageError {
            return cause(for: error.code)
        }
        if error is StorageTransactionCleanupError {
            return "storage.transaction_cleanup_failed"
        }
        if error is StorageRangeCleanupError {
            return "storage.range_cleanup_failed"
        }
        if let error = error as? CloudflareDatabaseAlarmSchedulerError {
            switch error {
            case .invalidTimestamp:
                return "alarm.invalid_timestamp"
            }
        }
        return "unclassified"
    }

    private static func cause(
        for error: DatabaseJobRuntimeError
    ) -> String {
        switch error {
        case .invalidConfiguration:
            return "job.invalid_configuration"
        case .invalidRetryPolicy:
            return "job.invalid_retry_policy"
        case .requestPayloadTooLarge:
            return "job.request_payload_too_large"
        case .specificationTooLarge:
            return "job.specification_too_large"
        case .planTooLarge:
            return "job.plan_too_large"
        case .stateTooLarge:
            return "job.state_too_large"
        case .unsuccessfulOutcomeExceedsLimits:
            return "job.unsuccessful_outcome_exceeds_limits"
        case .jobNotFound:
            return "job.not_found"
        case .jobOperationMismatch:
            return "job.operation_mismatch"
        case .resultNotReady:
            return "job.result_not_ready"
        case .corruptedSpecification:
            return "job.corrupted_specification"
        case .corruptedPlan:
            return "job.corrupted_plan"
        case .corruptedState:
            return "job.corrupted_state"
        case .corruptedResult:
            return "job.corrupted_result"
        case .resultChunkMissing:
            return "job.result_chunk_missing"
        case .invalidResultContinuation:
            return "job.invalid_result_continuation"
        case .invalidStateTransition:
            return "job.invalid_state_transition"
        case .stateRevisionOverflow:
            return "job.state_revision_overflow"
        case .workUnitOverflow:
            return "job.work_unit_overflow"
        case .sliceExceededBudget:
            return "job.slice_exceeded_budget"
        case .responseTooLarge:
            return "job.response_too_large"
        case .duplicateJobIdentifier:
            return "job.duplicate_identifier"
        case .commitModelMismatch:
            return "job.commit_model_mismatch"
        }
    }

    private static func cause(for code: StorageError.Code) -> String {
        switch code {
        case .transactionConflict:
            return "storage.transaction_conflict"
        case .transactionTooOld:
            return "storage.transaction_too_old"
        case .transactionFutureVersion:
            return "storage.transaction_future_version"
        case .transactionTimedOut:
            return "storage.transaction_timed_out"
        case .transactionCancelled:
            return "storage.transaction_cancelled"
        case .transactionBusy:
            return "storage.transaction_busy"
        case .transactionTooLarge:
            return "storage.transaction_too_large"
        case .keyTooLarge:
            return "storage.key_too_large"
        case .valueTooLarge:
            return "storage.value_too_large"
        case .connectionFailure:
            return "storage.connection_failure"
        case .commitUnknownResult:
            return "storage.commit_unknown_result"
        case .keyNotFound:
            return "storage.key_not_found"
        case .invalidOperation:
            return "storage.invalid_operation"
        case .unsupportedOperation:
            return "storage.unsupported_operation"
        case .backendFailure:
            return "storage.backend_failure"
        case .backendContractViolation:
            return "storage.backend_contract_violation"
        case .dataCorruption:
            return "storage.data_corruption"
        case .resourceUnavailable:
            return "storage.resource_unavailable"
        }
    }
}
