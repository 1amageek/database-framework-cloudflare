import { compareBytes } from "./DatabaseByteOrdering.js";
import {
  storageOperation,
  storageWriteOperation,
} from "./DatabaseStorageHostCodec.js";

const schemaVersion = 1;
const defaultScanBatchLimit = 1024;

export class DatabaseSQLiteStore {
  constructor(sql, transactionSync = null) {
    this.sql = sql;
    this.transactionSync = transactionSync ?? ((callback) => callback());
    this.initialized = false;
  }

  dispatch(request) {
    switch (request.operation) {
      case storageOperation.read:
        return this.read(request.key);
      case storageOperation.scan:
        return this.scan(request);
      case storageOperation.commit:
        return this.commit(request.writes);
      default:
        throw new Error(`Unknown storage operation ${request.operation}`);
    }
  }

  read(key) {
    this.requireInitialized();
    const row = this.first("SELECT value FROM database_kv WHERE key = ?", key);
    return {
      operation: storageOperation.read,
      value: row === null ? null : toBytes(row.value),
    };
  }

  scan(request) {
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
    const rows = this.all(statement, ...bindings).map((row) => ({
      key: toBytes(row.key),
      value: toBytes(row.value),
    }));

    return {
      operation: storageOperation.scan,
      rows,
    };
  }

  commit(writes) {
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
          default:
            throw new Error(`Unknown storage write operation ${write.tag}`);
        }
      }
      return {
        operation: storageOperation.commit,
      };
    });
  }

  migrate() {
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

  requireInitialized() {
    if (!this.initialized) {
      throw new Error("Database Durable Object storage is not initialized");
    }
  }

  first(statement, ...bindings) {
    const rows = this.all(statement, ...bindings);
    return rows.length === 0 ? null : rows[0];
  }

  all(statement, ...bindings) {
    const cursor = this.sql.exec(statement, ...bindings);
    if (Array.isArray(cursor)) {
      return cursor;
    }
    if (typeof cursor?.toArray === "function") {
      return cursor.toArray();
    }
    return Array.from(cursor ?? []);
  }

  exec(statement, ...bindings) {
    this.sql.exec(statement, ...bindings);
  }
}

function boundedLimit(limit) {
  if (!Number.isInteger(limit)) {
    return defaultScanBatchLimit;
  }
  if (limit <= 0) {
    return null;
  }
  return Math.min(limit, defaultScanBatchLimit);
}

function toBytes(value) {
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
