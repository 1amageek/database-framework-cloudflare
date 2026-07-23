import type { DatabaseRuntimeEndpoints } from "./DatabaseRuntimeTypes";
import {
  databaseTaskScheduleErrorReason,
  DatabaseTaskScheduleError,
} from "./DatabaseTaskScheduleError";

const maximumTaskID = 0x7fff_ffff;
const maximumTimerDelayMilliseconds = 0x7fff_ffff;

type ImmediateTaskEnqueuer = (task: () => void) => void;
type TaskFailureHandler = (error: Error) => void;

const enqueueDatabaseTaskImmediately: ImmediateTaskEnqueuer = (task) => {
  globalThis.queueMicrotask(task);
};

type ScheduledTask = {
  token: symbol;
  timerHandle: unknown | null;
  timerToken: symbol | null;
};

export type DatabaseTaskTimer = {
  schedule(handleExpiration: () => void, delayMilliseconds: number): unknown;
  cancel(handle: unknown): void;
};

const databaseTaskTimer: DatabaseTaskTimer = {
  schedule: (handleExpiration, delayMilliseconds) =>
    setTimeout(handleExpiration, delayMilliseconds),
  cancel: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

/// Schedules database runtime tasks without interpreting database operations.
export class DatabaseTaskScheduler {
  private readonly runtimeEndpoints: () => DatabaseRuntimeEndpoints;
  private readonly handleTaskFailure: TaskFailureHandler;
  private readonly maximumScheduledTasks: number;
  private readonly enqueueImmediateTask: ImmediateTaskEnqueuer;
  private readonly timer: DatabaseTaskTimer;
  private readonly scheduledTasks = new Map<number, ScheduledTask>();

  private closed = false;

  constructor(
    runtimeEndpoints: () => DatabaseRuntimeEndpoints,
    handleTaskFailure: TaskFailureHandler,
    maximumScheduledTasks: number,
    enqueueImmediateTask: ImmediateTaskEnqueuer = enqueueDatabaseTaskImmediately,
    timer: DatabaseTaskTimer = databaseTaskTimer
  ) {
    this.runtimeEndpoints = runtimeEndpoints;
    this.handleTaskFailure = handleTaskFailure;
    this.maximumScheduledTasks = validateMaximumScheduledTasks(
      maximumScheduledTasks
    );
    this.enqueueImmediateTask = enqueueImmediateTask;
    this.timer = timer;
  }

  get scheduledTaskCount(): number {
    return this.scheduledTasks.size;
  }

  schedule(taskID: number, delayMilliseconds: number): void {
    validateTaskID(taskID);
    validateDelay(delayMilliseconds);
    if (this.closed) {
      throw new DatabaseTaskScheduleError({
        reason: databaseTaskScheduleErrorReason.closed,
        limit: this.maximumScheduledTasks,
        taskID,
      });
    }
    if (this.scheduledTasks.has(taskID)) {
      throw new DatabaseTaskScheduleError({
        reason: databaseTaskScheduleErrorReason.duplicateTaskID,
        limit: this.maximumScheduledTasks,
        taskID,
      });
    }
    if (this.scheduledTasks.size >= this.maximumScheduledTasks) {
      throw new DatabaseTaskScheduleError({
        reason: databaseTaskScheduleErrorReason.capacityExceeded,
        limit: this.maximumScheduledTasks,
        taskID,
      });
    }

    const scheduledTask: ScheduledTask = {
      token: Symbol("database-scheduled-task"),
      timerHandle: null,
      timerToken: null,
    };
    this.scheduledTasks.set(taskID, scheduledTask);
    const executeTask = () => this.run(taskID, scheduledTask.token);
    if (delayMilliseconds === 0) {
      try {
        this.enqueueImmediateTask(executeTask);
      } catch (error) {
        this.scheduledTasks.delete(taskID);
        throw error;
      }
      return;
    }
    try {
      this.scheduleTimerSegment(taskID, scheduledTask, delayMilliseconds);
    } catch (error) {
      this.scheduledTasks.delete(taskID);
      throw error;
    }
  }

  shutdown(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    const tasks = [...this.scheduledTasks.values()];
    this.scheduledTasks.clear();
    for (const task of tasks) {
      if (task.timerHandle !== null) {
        this.cancelTimer(task.timerHandle);
      }
    }
  }

  private run(taskID: number, token: symbol): void {
    const task = this.scheduledTasks.get(taskID);
    if (task === undefined || task.token !== token || this.closed) {
      return;
    }
    this.scheduledTasks.delete(taskID);
    try {
      this.runtimeEndpoints().runScheduledTask(taskID);
    } catch (error) {
      this.handleTaskFailure(asError(error));
    }
  }

  private scheduleTimerSegment(
    taskID: number,
    task: ScheduledTask,
    remainingDelayMilliseconds: number
  ): void {
    const segmentDelayMilliseconds = Math.min(
      remainingDelayMilliseconds,
      maximumTimerDelayMilliseconds
    );
    const remainingAfterSegment = Math.max(
      0,
      remainingDelayMilliseconds - segmentDelayMilliseconds
    );
    const timerToken = Symbol("database-task-timer");
    task.timerToken = timerToken;
    let timerHandle: unknown;
    try {
      timerHandle = this.timer.schedule(() => {
        if (this.closed
            || this.scheduledTasks.get(taskID) !== task
            || task.timerToken !== timerToken) {
          return;
        }
        task.timerHandle = null;
        task.timerToken = null;
        if (remainingAfterSegment === 0) {
          this.run(taskID, task.token);
          return;
        }
        try {
          this.scheduleTimerSegment(
            taskID,
            task,
            remainingAfterSegment
          );
        } catch (error) {
          this.scheduledTasks.delete(taskID);
          this.handleTaskFailure(asError(error));
        }
      }, segmentDelayMilliseconds);
    } catch (error) {
      if (task.timerToken === timerToken) {
        task.timerToken = null;
      }
      throw error;
    }
    if (this.scheduledTasks.get(taskID) === task
        && task.timerToken === timerToken) {
      task.timerHandle = timerHandle;
    } else {
      this.cancelTimer(timerHandle);
    }
  }

  private cancelTimer(handle: unknown): void {
    try {
      this.timer.cancel(handle);
    } catch {
      // Clearing the token prevents a canceled generation from re-entering
      // the runtime even when the platform timer cannot be canceled.
    }
  }
}

function asError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

function validateTaskID(taskID: number): void {
  if (!Number.isInteger(taskID) || taskID <= 0 || taskID > maximumTaskID) {
    throw new RangeError("Database task ID is invalid");
  }
}

function validateDelay(delayMilliseconds: number): void {
  if (!Number.isFinite(delayMilliseconds)
      || delayMilliseconds < 0) {
    throw new RangeError("Database task delay is invalid");
  }
}

function validateMaximumScheduledTasks(value: number): number {
  if (!Number.isInteger(value) || value <= 0 || value > maximumTaskID) {
    throw new RangeError("Maximum scheduled database tasks is invalid");
  }
  return value;
}
