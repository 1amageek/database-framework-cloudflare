export class DatabaseStorageResponseOwnershipError extends Error {
  constructor() {
    super("Storage response must not alias the borrowed runtime request");
    this.name = "DatabaseStorageResponseOwnershipError";
  }
}
