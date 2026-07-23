export class DatabaseInvocationTimeoutError extends Error {
  readonly timeoutMilliseconds: number;

  constructor(timeoutMilliseconds: number) {
    super(
      `Database runtime call did not complete within ${timeoutMilliseconds} milliseconds`
    );
    this.name = "DatabaseInvocationTimeoutError";
    this.timeoutMilliseconds = timeoutMilliseconds;
  }
}
