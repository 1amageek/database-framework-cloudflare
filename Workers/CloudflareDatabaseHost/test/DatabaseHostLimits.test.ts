import assert from "node:assert/strict";
import test from "node:test";
import {
  InvalidContentLengthError,
  PayloadTooLargeError,
  readBoundedRequestBytes,
  rejectOversizedContentLength,
} from "../src/DatabaseHostLimits";

test("bounded request reader accepts payloads within the configured limit", async () => {
  const bytes = await readBoundedRequestBytes(new Request("https://database.local", {
    method: "POST",
    body: new Uint8Array([0x01, 0x02, 0x03]),
  }), 3);

  assert.deepEqual([...bytes], [0x01, 0x02, 0x03]);
});

test("bounded request reader rejects oversized payloads while streaming", async () => {
  await assert.rejects(
    readBoundedRequestBytes(new Request("https://database.local", {
      method: "POST",
      body: new Uint8Array([0x01, 0x02, 0x03, 0x04]),
    }), 3),
    PayloadTooLargeError
  );
});

test("bounded request reader cancels the stream after exceeding the limit", async () => {
  let canceled = false;
  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue(new Uint8Array([0x01, 0x02]));
      controller.enqueue(new Uint8Array([0x03, 0x04]));
    },
    cancel() {
      canceled = true;
    },
  });

  await assert.rejects(
    readBoundedRequestBytes(new Request("https://database.local", {
      method: "POST",
      body: stream,
      duplex: "half",
    } as RequestInit), 3),
    PayloadTooLargeError
  );
  assert.equal(canceled, true);
});

test("content length guard rejects invalid and oversized lengths", () => {
  const invalid = rejectOversizedContentLength(new Request("https://database.local", {
    method: "POST",
    headers: {
      "content-length": "invalid",
    },
  }), 3);
  const oversized = rejectOversizedContentLength(new Request("https://database.local", {
    method: "POST",
    headers: {
      "content-length": "4",
    },
  }), 3);

  assert.equal(invalid?.status, 400);
  assert.equal(oversized?.status, 413);
});

test("bounded request reader rejects invalid content length", async () => {
  await assert.rejects(
    readBoundedRequestBytes(new Request("https://database.local", {
      method: "POST",
      headers: {
        "content-length": "invalid",
      },
    }), 3),
    InvalidContentLengthError
  );
});
