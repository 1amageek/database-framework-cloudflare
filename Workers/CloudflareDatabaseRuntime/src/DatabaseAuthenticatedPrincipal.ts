export type DatabaseAuthenticatedPrincipal = Readonly<{
  identifier: string;
  roles: readonly string[];
  /** Canonical DatabaseWire FieldObject bytes. */
  claims: Uint8Array;
}>;

export const databaseAuthorizationMaximumFrameBytes = 256 * 1024;
export const databaseAuthorizationMaximumIdentifierBytes = 1024;
export const databaseAuthorizationMaximumRoleCount = 256;
export const databaseAuthorizationMaximumRoleBytes = 1024;

const authorizationMagic = 0x5541_4244;
const authorizationVersion = 1;
const textEncoder = new TextEncoder();

/** Returns the canonical DatabaseWire representation of an empty FieldObject. */
export function emptyDatabaseAuthorizationClaims(): Uint8Array {
  return new Uint8Array(4);
}

/** Encodes one Worker-authenticated principal for the private reactor ABI. */
export function encodeDatabaseAuthenticatedPrincipal(
  principal: DatabaseAuthenticatedPrincipal
): Uint8Array {
  const identifier = encodeBoundedString(
    principal.identifier,
    "principal identifier",
    databaseAuthorizationMaximumIdentifierBytes
  );
  if (!(principal.claims instanceof Uint8Array)) {
    throw new TypeError("Database authorization claims must be Uint8Array");
  }
  const encodedRoles = [...new Set(principal.roles)].map((role) => ({
    value: role,
    bytes: encodeBoundedString(
      role,
      "principal role",
      databaseAuthorizationMaximumRoleBytes
    ),
  }));
  if (encodedRoles.length !== principal.roles.length) {
    throw new TypeError("Database authorization roles must be unique");
  }
  if (encodedRoles.length > databaseAuthorizationMaximumRoleCount) {
    throw new RangeError(
      `Database authorization role count exceeds ${databaseAuthorizationMaximumRoleCount}`
    );
  }
  encodedRoles.sort((lhs, rhs) => compareBytes(lhs.bytes, rhs.bytes));

  let byteCount = 4 + 2 + 4 + identifier.byteLength + 4
    + 4 + principal.claims.byteLength;
  for (const role of encodedRoles) {
    byteCount += 4 + role.bytes.byteLength;
  }
  if (!Number.isSafeInteger(byteCount)
      || byteCount > databaseAuthorizationMaximumFrameBytes) {
    throw new RangeError(
      `Database authorization frame exceeds ${databaseAuthorizationMaximumFrameBytes} bytes`
    );
  }

  const output = new Uint8Array(byteCount);
  const view = new DataView(output.buffer);
  let offset = 0;
  view.setUint32(offset, authorizationMagic, true);
  offset += 4;
  view.setUint16(offset, authorizationVersion, true);
  offset += 2;
  offset = writeBytes(output, view, offset, identifier);
  view.setUint32(offset, encodedRoles.length, true);
  offset += 4;
  for (const role of encodedRoles) {
    offset = writeBytes(output, view, offset, role.bytes);
  }
  offset = writeBytes(output, view, offset, principal.claims);
  if (offset !== output.byteLength) {
    throw new Error("Database authorization encoder length mismatch");
  }
  return output;
}

function encodeBoundedString(
  value: string,
  field: string,
  maximumByteCount: number
): Uint8Array {
  if (typeof value !== "string" || value.length === 0) {
    throw new TypeError(`Database authorization ${field} must be non-empty`);
  }
  assertWellFormedUnicode(value, field);
  const bytes = textEncoder.encode(value);
  if (bytes.byteLength > maximumByteCount) {
    throw new RangeError(
      `Database authorization ${field} exceeds ${maximumByteCount} bytes`
    );
  }
  return bytes;
}

function assertWellFormedUnicode(value: string, field: string): void {
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (Number.isNaN(next) || next < 0xdc00 || next > 0xdfff) {
        throw new TypeError(
          `Database authorization ${field} contains malformed Unicode`
        );
      }
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      throw new TypeError(
        `Database authorization ${field} contains malformed Unicode`
      );
    }
  }
}

function writeBytes(
  output: Uint8Array,
  view: DataView,
  offset: number,
  bytes: Uint8Array
): number {
  view.setUint32(offset, bytes.byteLength, true);
  const start = offset + 4;
  output.set(bytes, start);
  return start + bytes.byteLength;
}

function compareBytes(lhs: Uint8Array, rhs: Uint8Array): number {
  const count = Math.min(lhs.byteLength, rhs.byteLength);
  for (let index = 0; index < count; index += 1) {
    if (lhs[index] !== rhs[index]) {
      return lhs[index]! - rhs[index]!;
    }
  }
  return lhs.byteLength - rhs.byteLength;
}
