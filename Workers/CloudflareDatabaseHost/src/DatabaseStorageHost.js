import { DatabaseSQLiteStore } from "./DatabaseSQLiteStore.js";
import { DatabaseStorageHostCodec } from "./DatabaseStorageHostCodec.js";

export class DatabaseStorageHost {
  constructor(sql, transactionSync = null) {
    this.store = new DatabaseSQLiteStore(sql, transactionSync);
  }

  migrate() {
    this.store.migrate();
  }

  dispatchBytes(bytes) {
    try {
      const request = DatabaseStorageHostCodec.decodeRequest(bytes);
      const response = this.store.dispatch(request);
      return DatabaseStorageHostCodec.encodeResponse(response);
    } catch (error) {
      return DatabaseStorageHostCodec.encodeFailure(errorMessage(error));
    }
  }
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}
