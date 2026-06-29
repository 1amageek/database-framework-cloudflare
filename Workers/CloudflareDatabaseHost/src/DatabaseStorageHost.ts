import {
  DatabaseSQLiteStore,
  type SqlExecutor,
  type TransactionSync,
} from "./DatabaseSQLiteStore";
import { DatabaseStorageHostCodec } from "./DatabaseStorageHostCodec";

export class DatabaseStorageHost {
  private readonly store: DatabaseSQLiteStore;

  constructor(sql: SqlExecutor, transactionSync: TransactionSync | null = null) {
    this.store = new DatabaseSQLiteStore(sql, transactionSync);
  }

  migrate(): void {
    this.store.migrate();
  }

  dispatchBytes(bytes: ArrayBuffer | ArrayBufferView): Uint8Array {
    try {
      const request = DatabaseStorageHostCodec.decodeRequest(bytes);
      const response = this.store.dispatch(request);
      return DatabaseStorageHostCodec.encodeResponse(response);
    } catch (error) {
      return DatabaseStorageHostCodec.encodeFailure(errorMessage(error));
    }
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
