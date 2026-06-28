import { encodeBase64URL } from "./DatabaseBase64URL.js";

const namePrefix = "database-framework/cfdo/v1";

export function scopeFromRequest(request) {
  return {
    databaseID: requiredHeader(request, "x-database-id", "main"),
    tenantID: optionalHeader(request, "x-tenant-id"),
    workspaceID: optionalHeader(request, "x-workspace-id"),
  };
}

export function nameForScope(scope) {
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

function requiredHeader(request, name, fallback) {
  const value = request.headers.get(name) ?? fallback;
  if (value.length === 0) {
    throw new Error(`${name} must not be empty`);
  }
  return value;
}

function optionalHeader(request, name) {
  const value = request.headers.get(name);
  if (value === null || value.length === 0) {
    return null;
  }
  return value;
}
