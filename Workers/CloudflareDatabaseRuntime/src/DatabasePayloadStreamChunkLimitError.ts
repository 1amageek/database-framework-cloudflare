export class DatabasePayloadStreamChunkLimitError extends Error {
  readonly limit: number;

  constructor(limit: number) {
    super(`Application payload exceeds ${limit} stream chunks`);
    this.name = "DatabasePayloadStreamChunkLimitError";
    this.limit = limit;
  }
}
