import { encodeBase64URL } from "./DatabaseBase64URL";

const namePrefix = "database-framework/cfdo/v1";

export type DatabaseScope = {
  databaseID: string;
  tenantID: string | null;
  workspaceID: string | null;
};

export function scopeFromRequest(request: Request): DatabaseScope {
  return {
    databaseID: requiredHeader(request, "x-database-id", "main"),
    tenantID: optionalHeader(request, "x-tenant-id"),
    workspaceID: optionalHeader(request, "x-workspace-id"),
  };
}

export function nameForScope(scope: DatabaseScope): string {
  const parts = [
    namePrefix,
    "database",
    encodeBase64URL(new TextEncoder().encode(scope.databaseID)),
  ];
  if (scope.tenantID !== null && scope.tenantID !== undefined) {
    parts.push("tenant", encodeBase64URL(new TextEncoder().encode(scope.tenantID)));
  }
  if (scope.workspaceID !== null && scope.workspaceID !== undefined) {
    parts.push("workspace", encodeBase64URL(new TextEncoder().encode(scope.workspaceID)));
  }
  return parts.join("/");
}

function requiredHeader(request: Request, name: string, fallback: string): string {
  const value = request.headers.get(name) ?? fallback;
  if (value.length === 0) {
    throw new Error(`${name} must not be empty`);
  }
  return value;
}

function optionalHeader(request: Request, name: string): string | null {
  const value = request.headers.get(name);
  if (value === null || value.length === 0) {
    return null;
  }
  return value;
}
