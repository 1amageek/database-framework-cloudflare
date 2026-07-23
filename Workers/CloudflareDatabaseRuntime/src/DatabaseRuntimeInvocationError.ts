export class DatabaseRuntimeInvocationError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.name = "DatabaseRuntimeInvocationError";
    this.status = status;
  }
}
