export class DatabaseRuntimeFailurePayloadLimitError extends Error {
  readonly limit: number;
  readonly received: number;

  constructor(limit: number, received: number) {
    super("Database runtime failure payload exceeds the connection limit");
    this.name = "DatabaseRuntimeFailurePayloadLimitError";
    this.limit = limit;
    this.received = received;
  }
}
