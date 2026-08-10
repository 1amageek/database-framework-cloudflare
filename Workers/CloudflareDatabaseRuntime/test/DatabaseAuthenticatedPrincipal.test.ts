import assert from "node:assert/strict";
import test from "node:test";
import {
  emptyDatabaseAuthorizationClaims,
  encodeDatabaseAuthenticatedPrincipal,
} from "../src/DatabaseAuthenticatedPrincipal";

const canonicalRuntimePrincipal = [
  68, 66, 65, 85, 1, 0,
  20, 0, 0, 0,
  114, 117, 110, 116, 105, 109, 101, 45, 118, 101,
  114, 105, 102, 105, 99, 97, 116, 105, 111, 110,
  1, 0, 0, 0,
  5, 0, 0, 0, 97, 100, 109, 105, 110,
  4, 0, 0, 0, 0, 0, 0, 0,
];

test("authorization encoder matches the canonical Swift frame", () => {
  const encoded = encodeDatabaseAuthenticatedPrincipal({
    identifier: "runtime-verification",
    roles: ["admin"],
    claims: emptyDatabaseAuthorizationClaims(),
  });
  assert.deepEqual([...encoded], canonicalRuntimePrincipal);
});

test("authorization roles use canonical UTF-8 byte order", () => {
  const encoded = encodeDatabaseAuthenticatedPrincipal({
    identifier: "principal",
    roles: ["writer", "admin"],
    claims: emptyDatabaseAuthorizationClaims(),
  });
  const decoder = new TextDecoder("utf-8", { fatal: true });
  const view = new DataView(encoded.buffer);
  let offset = 6;
  const identifierCount = view.getUint32(offset, true);
  offset += 4 + identifierCount;
  assert.equal(view.getUint32(offset, true), 2);
  offset += 4;
  const firstRoleCount = view.getUint32(offset, true);
  offset += 4;
  assert.equal(
    decoder.decode(encoded.subarray(offset, offset + firstRoleCount)),
    "admin"
  );
});

test("authorization encoder rejects duplicate roles", () => {
  assert.throws(
    () => encodeDatabaseAuthenticatedPrincipal({
      identifier: "principal",
      roles: ["reader", "reader"],
      claims: emptyDatabaseAuthorizationClaims(),
    }),
    /unique/
  );
});

test("authorization encoder rejects malformed Unicode", () => {
  assert.throws(
    () => encodeDatabaseAuthenticatedPrincipal({
      identifier: "principal\ud800",
      roles: [],
      claims: emptyDatabaseAuthorizationClaims(),
    }),
    /malformed Unicode/
  );
});
