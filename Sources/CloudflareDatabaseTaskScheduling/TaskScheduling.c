#include "CloudflareDatabaseTaskScheduling.h"

#include <stdint.h>

#if defined(__wasm32__)

typedef struct CloudflareDatabaseScheduledTask CloudflareDatabaseScheduledTask;

typedef __attribute__((swiftcall)) void
    (*CloudflareDatabaseDelayedTaskEnqueuer)(
        uint64_t delayNanoseconds,
        CloudflareDatabaseScheduledTask *_Nonnull task
    );

typedef __attribute__((swiftcall)) void
    (*CloudflareDatabaseDeadlineTaskEnqueuer)(
        int64_t seconds,
        int64_t nanoseconds,
        int64_t toleranceSeconds,
        int64_t toleranceNanoseconds,
        int32_t clock,
        CloudflareDatabaseScheduledTask *_Nonnull task
    );

__attribute__((__visibility__("default")))
extern void *_Nullable delayedTaskEnqueuer
    __asm__("swift_task_enqueueGlobalWithDelay_hook")
    __attribute__((swift_attr("nonisolated(unsafe)")));

__attribute__((__visibility__("default")))
extern void *_Nullable deadlineTaskEnqueuer
    __asm__("swift_task_enqueueGlobalWithDeadline_hook")
    __attribute__((swift_attr("nonisolated(unsafe)")));

extern void schedule_database_task_after_delay(
    uint64_t delayNanoseconds,
    CloudflareDatabaseScheduledTask *_Nonnull task
) __asm__("cloudflare_database_enqueue_task_after_delay");

extern void schedule_database_task_at_deadline(
    int64_t seconds,
    int64_t nanoseconds,
    int32_t clock,
    CloudflareDatabaseScheduledTask *_Nonnull task
) __asm__("cloudflare_database_enqueue_task_at_deadline");

static __attribute__((swiftcall)) void enqueue_database_task_after_delay(
    uint64_t delayNanoseconds,
    CloudflareDatabaseScheduledTask *_Nonnull task,
    CloudflareDatabaseDelayedTaskEnqueuer _Nonnull systemEnqueuer
) {
    (void)systemEnqueuer;
    schedule_database_task_after_delay(delayNanoseconds, task);
}

static __attribute__((swiftcall)) void enqueue_database_task_at_deadline(
    int64_t seconds,
    int64_t nanoseconds,
    int64_t toleranceSeconds,
    int64_t toleranceNanoseconds,
    int32_t clock,
    CloudflareDatabaseScheduledTask *_Nonnull task,
    CloudflareDatabaseDeadlineTaskEnqueuer _Nonnull systemEnqueuer
) {
    (void)toleranceSeconds;
    (void)toleranceNanoseconds;
    (void)systemEnqueuer;
    schedule_database_task_at_deadline(
        seconds,
        nanoseconds,
        clock,
        task
    );
}

void cloudflare_database_install_task_scheduler(void) {
    delayedTaskEnqueuer =
        (void *_Nonnull)enqueue_database_task_after_delay;
    deadlineTaskEnqueuer =
        (void *_Nonnull)enqueue_database_task_at_deadline;
}

#endif
