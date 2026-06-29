import { type SqlBinding, type SqlCursor, type SqlRow } from "../src/DatabaseSQLiteStore";

type StoredRow = {
  key: Uint8Array;
  value: Uint8Array;
};

export class NodeSqlStorage {
  private rows: StoredRow[];
  private migrations: number[];

  constructor() {
    this.rows = [];
    this.migrations = [];
  }

  exec(statement: string, ...bindings: SqlBinding[]): SqlCursor {
    const normalized = statement.replace(/\s+/g, " ").trim();
    if (normalized.startsWith("CREATE TABLE")) {
      return [];
    }
    if (normalized === "SELECT COALESCE(MAX(id), 0) AS version FROM _sql_schema_migrations") {
      const version = this.migrations.length === 0 ? 0 : Math.max(...this.migrations);
      return [{ version }];
    }
    if (normalized === "INSERT INTO _sql_schema_migrations(id) VALUES (1)") {
      this.migrations.push(1);
      return [];
    }
    if (normalized.startsWith("INSERT OR IGNORE INTO database_metadata")) {
      return [];
    }
    if (normalized === "SELECT value FROM database_metadata WHERE key = 'schemaVersion'") {
      return [{ value: "1" }];
    }
    if (normalized === "SELECT value FROM database_kv WHERE key = ?") {
      const key = requireBytes(bindings[0]);
      const row = this.rows.find((item) => equalBytes(item.key, key));
      return row === undefined ? [] : [{ value: row.value }];
    }
    if (normalized.startsWith("SELECT key, value FROM database_kv WHERE key >= ? AND key < ?")) {
      const begin = requireBytes(bindings[0]);
      const end = requireBytes(bindings[1]);
      const limit = typeof bindings[2] === "number" ? bindings[2] : null;
      const reverse = normalized.includes("ORDER BY key DESC");
      let rows = this.rows
        .filter((row) => compareBytes(row.key, begin) >= 0 && compareBytes(row.key, end) < 0)
        .sort((lhs, rhs) => compareBytes(lhs.key, rhs.key));
      if (reverse) {
        rows = rows.reverse();
      }
      const limitedRows = limit === null ? rows : rows.slice(0, limit);
      return limitedRows.map((row) => ({ key: row.key, value: row.value }));
    }
    if (normalized === "INSERT OR REPLACE INTO database_kv(key, value) VALUES (?, ?)") {
      const key = requireBytes(bindings[0]);
      const value = requireBytes(bindings[1]);
      const index = this.rows.findIndex((row) => equalBytes(row.key, key));
      if (index >= 0) {
        this.rows[index] = { key, value };
      } else {
        this.rows.push({ key, value });
      }
      return [];
    }
    if (normalized === "DELETE FROM database_kv WHERE key = ?") {
      const key = requireBytes(bindings[0]);
      this.rows = this.rows.filter((row) => !equalBytes(row.key, key));
      return [];
    }
    throw new Error(`Unsupported SQL statement: ${normalized}`);
  }
}

function equalBytes(lhs: Uint8Array, rhs: Uint8Array): boolean {
  return compareBytes(lhs, rhs) === 0;
}

function compareBytes(lhs: Uint8Array, rhs: Uint8Array): number {
  const count = Math.min(lhs.length, rhs.length);
  for (let index = 0; index < count; index += 1) {
    const lhsByte = lhs[index] ?? 0;
    const rhsByte = rhs[index] ?? 0;
    if (lhsByte !== rhsByte) {
      return lhsByte < rhsByte ? -1 : 1;
    }
  }
  if (lhs.length === rhs.length) {
    return 0;
  }
  return lhs.length < rhs.length ? -1 : 1;
}

function requireBytes(value: SqlBinding | undefined): Uint8Array {
  if (!(value instanceof Uint8Array)) {
    throw new Error("Expected binary SQL binding");
  }
  return value;
}
