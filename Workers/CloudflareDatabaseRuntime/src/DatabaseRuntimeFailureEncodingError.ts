export class DatabaseRuntimeFailureEncodingError extends Error {
  constructor() {
    super("Database runtime returned a malformed UTF-8 failure payload");
    this.name = "DatabaseRuntimeFailureEncodingError";
  }
}
