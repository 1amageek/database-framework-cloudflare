export class DatabaseRuntimeConnectionShutdownError extends Error {
  constructor() {
    super("Database runtime connection is shut down");
    this.name = "DatabaseRuntimeConnectionShutdownError";
  }
}
