import assert from "node:assert/strict";
import test from "node:test";
import { RequestAuthorizer } from "../src/RequestAuthorizer.js";

test("request authorizer fails closed without a configured token", async () => {
  const result = await new RequestAuthorizer(null).authorize(request("secret"));

  assert.equal(result.allowed, false);
  assert.equal(result.response.status, 503);
});

test("request authorizer accepts matching bearer token", async () => {
  const result = await new RequestAuthorizer("secret").authorize(request("secret"));

  assert.equal(result.allowed, true);
});

test("request authorizer rejects missing or mismatched bearer token", async () => {
  const missing = await new RequestAuthorizer("secret").authorize(new Request("https://database.local"));
  const mismatched = await new RequestAuthorizer("secret").authorize(request("other"));

  assert.equal(missing.allowed, false);
  assert.equal(missing.response.status, 401);
  assert.equal(mismatched.allowed, false);
  assert.equal(mismatched.response.status, 401);
});

function request(token) {
  return new Request("https://database.local", {
    headers: {
      authorization: `Bearer ${token}`,
    },
  });
}
