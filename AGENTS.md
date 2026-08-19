# AGENTS.md

## Responsibility

- This package hosts one application-specific database-framework runtime as a
  persistent WASI reactor inside a Database Durable Object.
- TypeScript owns Durable Object lifecycle, FIFO admission, opaque RPC byte
  transfer, completion correlation, limits, and the synchronous storage host
  ABI.
- Swift opens `DBContainer` with the application-selected framework features
  and delegates opaque context and request bytes to an application-owned
  session. It does not interpret DatabaseWire, authentication principals,
  remote operations, persistent server jobs, or server administration.
- This package depends on `database-framework` and `storage-kit`. It must not
  depend on any `database-server` product or link Hummingbird, native TLS,
  credential files, signals, or process lifecycle.

## Naming

- Name declarations for their runtime-host responsibility, observable behavior, event, ownership, or lifecycle contract.
- Follow language API conventions at every access level, including tests and generated host support.
- Do not encode implementation language, calling convention, module identity, binary format, toolchain, build mode, or memory-layout strategy in ordinary names.
- Keep fixed import and export spellings only in ABI constants or attributes. Give Swift and TypeScript wrappers semantic names.
- Name callbacks for the call completion or lifecycle transition they deliver. Names such as `regular`, `legacy`, `impl`, `helper`, `manager`, or a bare `callback` are invalid.
- Distinguish owned host frames from borrowed WebAssembly memory ranges.

## Lifecycle, Data, and Error Contracts

- Bootstrap only SQLite migration, reactor instantiation, and DBContainer initialization under blockConcurrencyWhile.
- Retain one reactor and DBContainer for the Durable Object instance. Serialize entry through the explicit FIFO queue and do not permit concurrent reactor invocation.
- Clear a failed cached initialization so a later request can retry bootstrap.
- Validate request, response, host frame, key, value, aggregate mutation, memory, startup, and execution limits before use.
- Borrow WebAssembly memory only synchronously. Copy once into the final owner whenever data must outlive that borrow; never retain an escaped pointer.
- Every accepted call must resolve or reject exactly once with a typed error. Do not return stale or synthetic success.
- The private reactor boundary is ABI v3. Application context and request are
  separate opaque owned buffers.

## Verification

- Run the Native package tests with the pinned `org.swift.64202608141a`
  toolchain through `build-for-testing` and `test-without-building`. Inject the
  toolchain's `usr/lib/swift/macosx/testing` directory into every test target's
  `TestingEnvironmentVariables.DYLD_LIBRARY_PATH`. The standard graph requires
  exactly 18 passed tests. An isolated `MultiBase` graph is selected with
  `DATABASE_CLOUDFLARE_TEST_TRAITS=MultiBase` and requires exactly 20 passed
  tests. `DATABASE_CLOUDFLARE_TEST_TRAITS=AllRuntimeFeatures` requires exactly
  21 passed tests, including the three VectorIndexes capability-admission
  contracts. The harness derives the expected count from the selected traits
  unless it is explicitly overridden. Every run requires zero failures, skips,
  expected failures, or runtime warnings. Never reuse DerivedData across trait
  graphs.
- Run `npm test` in `Workers/CloudflareDatabaseRuntime` and require exactly 120
  passed TypeScript tests with zero failures, cancellations, skips, or todos.
- Run `node scripts/verify-service-adapter.mjs` and require generated Wrangler
  binding types, TypeScript checking, and the complete dry-run deployment-size
  gate to pass from a rendered isolated service workspace.
- Run `scripts/verify-runtime-feasibility.sh` with the fixed
  `swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-08-14-a_wasm-embedded` SDK. The gate
  must compile and link every selected runtime product, reject forbidden host
  adapters, verify the reactor ABI, enforce artifact and address-space limits,
  instantiate the reactor, and complete the workerd restart-persistence smoke
  test.
- Release verification uses URL dependencies only. A local package path may
  diagnose a failure but is not release evidence.
