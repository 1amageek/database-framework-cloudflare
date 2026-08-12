# AGENTS.md

## Responsibility

- This package hosts one application-specific full database-framework runtime as a persistent WASI reactor inside a Database Durable Object.
- TypeScript owns Durable Object lifecycle, FIFO admission, typed RPC byte transfer, completion correlation, limits, and the synchronous storage host ABI.
- Swift owns all database, schema, query, graph, transaction, index, migration, maintenance, and job semantics. TypeScript must not duplicate them.

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
- The private reactor boundary is ABI v2. Authorization and DatabaseWire remain separate owned frames.

## Verification

- Run the Native package tests with the pinned `org.swift.64202607231a`
  toolchain through `build-for-testing` and `test-without-building`. Inject the
  toolchain's `usr/lib/swift/macosx/testing` directory into every test target's
  `TestingEnvironmentVariables.DYLD_LIBRARY_PATH`. Require exactly 36 passed
  tests with zero failures, skips, expected failures, or runtime warnings.
- Run `npm test` in `Workers/CloudflareDatabaseRuntime` and require exactly 122
  passed TypeScript tests with zero failures, cancellations, skips, or todos.
- Run `scripts/verify-runtime-feasibility.sh` with the fixed
  `swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-23-a_wasm-embedded` SDK. The gate
  must compile and link every selected runtime product, reject forbidden host
  adapters, verify the reactor ABI, enforce artifact and address-space limits,
  instantiate the reactor, and complete the workerd restart-persistence smoke
  test.
- Release verification uses URL dependencies only. A local package path may
  diagnose a failure but is not release evidence.
