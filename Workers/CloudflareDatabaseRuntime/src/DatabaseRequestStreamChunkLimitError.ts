export class DatabaseRequestStreamChunkLimitError extends Error {
  readonly limit: number;

  constructor(limit: number) {
    super(`DatabaseWire request exceeds ${limit} stream chunks`);
    this.name = "DatabaseRequestStreamChunkLimitError";
    this.limit = limit;
  }
}
