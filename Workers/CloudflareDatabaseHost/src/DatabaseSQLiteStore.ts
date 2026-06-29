import { compareBytes } from "./DatabaseByteOrdering";
import {
  type DatabaseKeyValueRow,
  type StorageCommitRequest,
  storageOperation,
  type StorageReadResponse,
  type StorageRequest,
  type StorageScanRequest,
  type StorageScanResponse,
  type StorageSuccessResponse,
  type StorageWrite,
  storageWriteOperation,
} from "./DatabaseStorageHostCodec";

const schemaVersion = 1;
const defaultScanBatchLimit = 1024;

export type SqlBinding = Uint8Array | string | number | null;
export type SqlRow = Record<string, unknown>;
export type SqlCursor = SqlRow[] | Iterable<SqlRow> | { toArray(): SqlRow[] } | null | undefined;
export type SqlExecutor = {
  exec(statement: string, ...bindings: SqlBinding[]): SqlCursor;
};
export type TransactionSync = <Result>(callback: () => Result) => Result;

export class DatabaseSQLiteStore {
  private readonly sql: SqlExecutor;
  private readonly transactionSync: TransactionSync;
  private initialized: boolean;

  constructor(sql: SqlExecutor, transactionSync: TransactionSync | null = null) {
    this.sql = sql;
    this.transactionSync = transactionSync ?? ((callback) => callback());
    this.initialized = false;
  }

  dispatch(request: StorageRequest): StorageSuccessResponse {
    switch (request.operation) {
      case storageOperation.read:
        return this.read(request.key);
      case storageOperation.scan:
        return this.scan(request);
      case storageOperation.commit:
        return this.commit(request.writes);
    }
  }

  read(key: Uint8Array): StorageReadResponse {
    this.requireInitialized();
    const row = this.first("SELECT value FROM database_kv WHERE key = ?", key);
    return {
      operation: storageOperation.read,
      value: row === null ? null : toBytes(row.value),
    };
  }

  scan(request: StorageScanRequest): StorageScanResponse {
    this.requireInitialized();
    if (compareBytes(request.begin, request.end) >= 0) {
      return {
        operation: storageOperation.scan,
        rows: [],
      };
    }

    const order = request.reverse ? "DESC" : "ASC";
    const limit = boundedLimit(request.limit);
    const statement = limit === null
      ? `SELECT key, value FROM database_kv WHERE key >= ? AND key < ? ORDER BY key ${order}`
      : `SELECT key, value FROM database_kv WHERE key >= ? AND key < ? ORDER BY key ${order} LIMIT ?`;
    const bindings = limit === null
      ? [request.begin, request.end]
      : [request.begin, request.end, limit];
    const rows: DatabaseKeyValueRow[] = this.all(statement, ...bindings).map((row) => ({
      key: toBytes(row.key),
      value: toBytes(row.value),
    }));

    return {
      operation: storageOperation.scan,
      rows,
    };
  }

  commit(writes: StorageCommitRequest["writes"]): StorageSuccessResponse {
    return this.transactionSync(() => {
      this.requireInitialized();
      for (const write of writes) {
        switch (write.tag) {
          case storageWriteOperation.set:
            this.exec("INSERT OR REPLACE INTO database_kv(key, value) VALUES (?, ?)", write.key, write.value);
            break;
          case storageWriteOperation.clear:
            this.exec("DELETE FROM database_kv WHERE key = ?", write.key);
            break;
        }
      }
      return {
        operation: storageOperation.commit,
      };
    });
  }

  migrate(): void {
    return this.transactionSync(() => {
      this.exec(
        "CREATE TABLE IF NOT EXISTS _sql_schema_migrations(id INTEGER PRIMARY KEY, applied_at TEXT NOT NULL DEFAULT (datetime('now')))"
      );
      const row = this.first(
        "SELECT COALESCE(MAX(id), 0) AS version FROM _sql_schema_migrations"
      );
      const currentVersion = row === null ? 0 : Number(row.version);
      if (!Number.isInteger(currentVersion) || currentVersion < 0) {
        throw new Error("Invalid database Durable Object schema version");
      }
      if (currentVersion > schemaVersion) {
        throw new Error("Unsupported database Durable Object schema version");
      }
      if (currentVersion < 1) {
        this.exec("CREATE TABLE IF NOT EXISTS database_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)");
        this.exec("CREATE TABLE IF NOT EXISTS database_kv(key BLOB PRIMARY KEY, value BLOB NOT NULL)");
        this.exec(
          "INSERT OR IGNORE INTO database_metadata(key, value) VALUES ('schemaVersion', ?)",
          String(schemaVersion)
        );
        this.exec("INSERT INTO _sql_schema_migrations(id) VALUES (1)");
      }
      this.initialized = true;
    });
  }

  requireInitialized(): void {
    if (!this.initialized) {
      throw new Error("Database Durable Object storage is not initialized");
    }
  }

  first(statement: string, ...bindings: SqlBinding[]): SqlRow | null {
    const rows = this.all(statement, ...bindings);
    return rows[0] ?? null;
  }

  all(statement: string, ...bindings: SqlBinding[]): SqlRow[] {
    const cursor = this.sql.exec(statement, ...bindings);
    if (Array.isArray(cursor)) {
      return cursor;
    }
    if (hasToArray(cursor)) {
      return cursor.toArray();
    }
    if (cursor === null || cursor === undefined) {
      return [];
    }
    return Array.from(cursor);
  }

  exec(statement: string, ...bindings: SqlBinding[]): void {
    this.sql.exec(statement, ...bindings);
  }
}

function hasToArray(cursor: SqlCursor): cursor is { toArray(): SqlRow[] } {
  return typeof cursor === "object" && cursor !== null && "toArray" in cursor
    && typeof cursor.toArray === "function";
}

function boundedLimit(limit: number): number | null {
  if (!Number.isInteger(limit)) {
    return defaultScanBatchLimit;
  }
  if (limit <= 0) {
    return null;
  }
  return Math.min(limit, defaultScanBatchLimit);
}

function toBytes(value: unknown): Uint8Array {
  if (value instanceof Uint8Array) {
    return new Uint8Array(value);
  }
  if (value instanceof ArrayBuffer) {
    return new Uint8Array(value);
  }
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  }
  throw new Error("SQLite returned a non-binary value");
}
