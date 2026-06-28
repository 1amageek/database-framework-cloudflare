export class NodeSqlStorage {
  constructor() {
    this.rows = [];
    this.migrations = [];
  }

  exec(statement, ...bindings) {
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
      const row = this.rows.find((item) => equalBytes(item.key, bindings[0]));
      return row === undefined ? [] : [{ value: row.value }];
    }
    if (normalized.startsWith("SELECT key, value FROM database_kv WHERE key >= ? AND key < ?")) {
      const begin = bindings[0];
      const end = bindings[1];
      const limit = bindings[2] ?? null;
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
      const [key, value] = bindings;
      const index = this.rows.findIndex((row) => equalBytes(row.key, key));
      if (index >= 0) {
        this.rows[index] = { key, value };
      } else {
        this.rows.push({ key, value });
      }
      return [];
    }
    if (normalized === "DELETE FROM database_kv WHERE key = ?") {
      this.rows = this.rows.filter((row) => !equalBytes(row.key, bindings[0]));
      return [];
    }
    throw new Error(`Unsupported SQL statement: ${normalized}`);
  }
}

function equalBytes(lhs, rhs) {
  return compareBytes(lhs, rhs) === 0;
}

function compareBytes(lhs, rhs) {
  const count = Math.min(lhs.length, rhs.length);
  for (let index = 0; index < count; index += 1) {
    if (lhs[index] !== rhs[index]) {
      return lhs[index] < rhs[index] ? -1 : 1;
    }
  }
  if (lhs.length === rhs.length) {
    return 0;
  }
  return lhs.length < rhs.length ? -1 : 1;
}
