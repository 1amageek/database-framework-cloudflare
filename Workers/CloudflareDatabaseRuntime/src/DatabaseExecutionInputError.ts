export class DatabaseExecutionInputError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DatabaseExecutionInputError";
  }
}
