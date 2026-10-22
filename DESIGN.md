# CloudflareDatabase

## Purpose and Scope

This document is the package design authority for `database-framework-cloudflare`.
The package hosts one application-specific `database-framework` runtime inside a
Cloudflare Durable Object, as a persistent WASI reactor reached over a private
host ABI.

It is a *host adaptation* of Framework, not an alternative to the standalone
server product. The boundary decision is fixed by
[ADR-0003](Docs/ADR-0003-framework-adapter-and-standalone-server-boundaries.md):
each `database-framework-<platform>` package is a peer of the other platform
adapters, and none of them is a variant of, dependency of, or substitute for
`database-server`. The cohesion decision — why the reactor, admission, storage
transport, and lifecycle live in a single package rather than several — is fixed
by [ADR-0004](Docs/ADR-0004-cohesive-cloudflare-database-runtime.md).

- Parent: [Database workspace](../DESIGN.md).
- Children: none. This package declares no module-level design authority.
- Operating contract and verification expectations: [AGENTS.md](AGENTS.md).
- Reactor completion status contract:
  [Protocol/database-completion-status-v3.json](Protocol/database-completion-status-v3.json).

This document does not restate product architecture owned by the workspace
`SPEC.md`, database semantics owned by `database-framework` and `database-kit`,
storage protocol owned by `storage-kit`, the accepted decisions owned by the
ADRs above, or the exact verification counts owned by `AGENTS.md`.

## Responsibilities and Boundaries

The package produces exactly one product: the library `CloudflareDatabase`. It
is a library because the Durable Object host, not this package, owns the
process.

| Unit | Kind | Owns |
|---|---|---|
| `CloudflareDatabase` | Swift library target | reactor entrypoint and ABI v3 surface, invocation admission and payload ownership, runtime lifecycle actor, hosting capability validation, Cloudflare clocks and alarm scheduling, storage engine and container construction |
| `CloudflareDatabaseTaskScheduling` | C library target | the Swift concurrency delayed-enqueue hook symbol required to install a WASM serial executor |
| `CloudflareDatabaseRuntimeVerification` | executable target under `Tests/` | reactor link and feasibility evidence only; not a shipped product |
| `CloudflareDatabaseTests` | test target | behavioral evidence for the contracts below |

It owns:

- The private reactor boundary: call admission, ordering, payload reservation
  and release, and exactly-once typed completion.
- Cloudflare host adaptation: alarm wake-up requests, the Swift concurrency
  serial executor and its delayed-enqueue hook, monotonic and wall clocks.
- The lifecycle of one `DBContainer` and one application-owned session per
  Durable Object instance.
- A platform capability restriction that rejects index policies the host cannot
  support, before storage opens.

It does not own:

- DatabaseWire framing, decoding, or dispatch. Production host targets do not
  depend on `DatabaseWire`; an invocation carries opaque context and request
  bytes whose meaning belongs to the application. Application-owned test
  fixtures may select DatabaseWire without adding it to the host target.
- Authentication principals, remote operations, durable server jobs, or schema
  administration. Those belong to `database-server`.
- Query planning, index execution, graph traversal, transactions, or model
  materialization. Those belong to `database-framework`.
- Storage keys, ranges, retries, conflicts, or the backend protocol. Those
  belong to `storage-kit`.
- The backend choice. Cloudflare Durable Object storage is fixed by the
  platform, so the consumer selects runtime features but never a backend.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Database workspace](../DESIGN.md) | parent | system index and semantic plane assignment | Places this package as a host adaptation of the data plane. | It is not a control-and-publication owner and never appears as a peer of `database-server`. |
| [database-framework](../database-framework/DESIGN.md) | depends on | `DatabaseEngine` container, session, schema, and runtime configuration | Supplies the only in-process data execution authority used here. | The dependency is pinned exactly; a Framework contract change requires re-verifying the reactor graph before the pin moves. |
| [database-kit](../database-kit/DESIGN.md) | depends on | model, schema, and Foundation-independent declarations | Supplies the declarations an application schema is written against. | The `MultiBase` trait is forwarded, never enabled here by default. |
| [database-types](../database-types/AGENTS.md) | depends on | `ByteString` and primitive value ownership | Supplies the byte ownership used for opaque payloads. | A borrowed WASM view must be copied once into an owned payload before it escapes the host call. |
| [storage-kit](../storage-kit/DESIGN.md) | depends on | `CloudflareDurableObjectStorage`, its wire encoding, and its synchronous host transport | Supplies the Durable Object storage engine and its host bridge. | Storage limits are validated here before use; storage semantics are not reinterpreted. |
| [database-server](../database-server/DESIGN.md) | peer consumer of Framework; no dependency | none | The full standalone server product with all runtime features and Wire dispatch. | This package must never depend on a `database-server` product. The reactor link verifier asserts the absence of its objects. |
| [ADR-0003](Docs/ADR-0003-framework-adapter-and-standalone-server-boundaries.md) | decision authority | adapter and server ownership boundaries | Fixes that platform adapters are peers, not server variants. | Changing the adapter boundary requires superseding this ADR, not editing this document. |
| [ADR-0004](Docs/ADR-0004-cohesive-cloudflare-database-runtime.md) | decision authority | single cohesive runtime boundary | Fixes why lifecycle, ordering, and memory ownership stay in one package. | Splitting the runtime would create additional public contracts and is rejected here. |
| [AGENTS.md](AGENTS.md) | operating authority | responsibility statement, lifecycle rules, and verification procedure | Owns the exact toolchain, harness, and expected test counts. | Expected counts and harness invocation are read from `AGENTS.md`; this document does not duplicate them. |

## Architecture

```text
Cloudflare Durable Object (TypeScript)
  owns DO lifecycle, FIFO admission, opaque RPC bytes, completion correlation
        |  private reactor ABI v3 (exports/imports)
        v
CloudflareDatabaseRuntimeEntrypoint            #if arch(wasm32)
  reserve/release payload -> start -> invoke/alarm -> shutdown
        |
        +-- CloudflareDatabaseCompletionChannel   exactly-once completion
        +-- CloudflareDatabasePendingQueue        bounded FIFO admission
        |
        v
   actor CloudflareDatabaseRuntime
        |  configuration -> validateHostingCapabilities()
        |  createStorageEngine -> open container -> makeSession
        v
   CloudflareDatabaseApplication / CloudflareDatabaseSession   (consumer)
        |  opaque CloudflareDatabaseInvocation { context, request }
        v
   DatabaseEngine (DBContainer)  ->  StorageKit  ->  CloudflareDurableObjectStorage

host imports:
  database_alarm.schedule           <- CloudflareDatabaseAlarmScheduler
  database_executor.schedule        <- CloudflareDatabaseTaskScheduler
  swift_task_enqueueGlobalWithDelay_hook <- CloudflareDatabaseTaskScheduling (C)

CloudflareDatabase -X-> database-server
CloudflareDatabase -X-> DatabaseWire dispatch
```

Trait composition is a consumer decision. The package declares the eleven
runtime feature traits, an `AllRuntimeFeatures` aggregate, and `MultiBase`, and
enables **none of them by default**. Each trait is forwarded conditionally to
`database-framework`, and `MultiBase` additionally to `database-kit`, so an
unused feature implementation never enters the reactor graph. This is the
concrete difference from `database-server`, which ships a fixed all-features
default and a backend choice.

## Contracts and Invariants

- The reactor ABI version is `3` and its completion statuses are a closed set.
  `Protocol/database-completion-status-v3.json` and
  `CloudflareDatabaseCompletionStatus` describe the same contract; neither may
  change without the other and without a host-side change.
- Context and request payloads are separate owned buffers. Host memory is
  borrowed only for the duration of a synchronous host call and copied exactly
  once into its final owner.
- Payload ownership is bounded before use: maximum payload byte count, maximum
  owned payload count, and maximum total owned bytes. A reservation that would
  exceed a bound fails with a typed status instead of allocating.
- Every accepted call resolves or rejects exactly once. No call produces a stale
  result, a synthetic success, or an empty success in place of a failure.
- Admission is FIFO and bounded by `maximumPendingInvocations`. The reactor is
  never invoked concurrently; ordering is part of the contract, not an
  implementation detail.
- Startup is single-flight. A second `start` observes `alreadyStarted` or
  `startupInProgress`, and a failed startup is cleared so the host may retry.
- Hosting capabilities are validated before storage opens. A vector index whose
  policy is HNSW is rejected with `unsupportedHNSW(indexName:)`, and a policy
  set that cannot be resolved is rejected with `invalidVectorConfiguration`.
  This is the falsifiable statement that Cloudflare is a restricted host, not a
  full-feature deployment.
- The package links no `database-server` product, no Hummingbird, no native TLS
  or credential handling, and no process signal or process lifecycle code.
- An invocation is opaque. `CloudflareDatabaseInvocation` exposes only context
  and request bytes; the package performs no wire decoding of them.
- A database root is a Directory path, not a byte prefix. Without `MultiBase`
  the container opens at the store root Directory, which the dedicated Durable
  Object store owns exclusively. With `MultiBase`,
  `CloudflareDatabaseStorageLayout` carries the single domain's non-empty
  `domainRootPath` and validates it before any storage call.
- Application configuration carries an optional immutable `sqlDatabaseName` and
  forwards it unchanged to Framework `DBConfiguration` in compiled and migration
  startup, in both standard and `MultiBase` graphs. It is the explicit SQL
  identity consumed by `CURRENT_DATABASE`; the separate `databaseName` remains
  the existing diagnostic name. An absent SQL identity stays absent, and the
  selected Framework function owns its typed failure. This forwarding introduces
  no query, authorization, storage, lifecycle, or shared-state policy.
- A placement names a domain and nothing else. `database-framework` fixes a Base
  Partition at `bases/<Base.ID>` below its domain's database root, so this
  package neither accepts nor forwards a placement path.

## Runtime Flows

### Startup

```text
host start(callID)
  -> reject callID 0, shutting down, already started, or start in progress
  -> await application.configuration
  -> configuration.validateHostingCapabilities()
  -> create Cloudflare Durable Object storage engine
  -> MultiBase: build DatabaseStorageTopology (domain, placement, default)
     standard: open at the store root Directory (empty database root path)
  -> open DBContainer
  -> application.makeSession(for: container)
  -> re-check shutdown, then complete success
```

Ownership on the failure paths is explicit. If topology construction fails, the
storage engine has not transferred ownership, so this package requests its
shutdown and awaits completion. If session creation fails, the opened container
is shut down. Cancellation resolves as `cancelled`, a configuration error as
`startupFailed` carrying its description. Storage startup failures retain only
their closed `code`, `backend`, and `operation` identifiers in the private
`startupFailed` diagnostic. Arbitrary storage messages, underlying descriptions,
keys, and credentials never cross this boundary. Unknown errors retain the
generic startup diagnostic. The existing startup-failure test verifies this
classification and redaction; no completion status or retry policy changes.

### Invocation

```text
host reserveInvocationPayload(byteCount)  -> address or failure
host writes context and request bytes into the reserved buffers
host invoke(callID, contextBytes, requestBytes)
  -> bounds check against context/request limits
  -> take ownership of both payloads, or release them on rejection
  -> enqueue in FIFO order, or reject with queueCapacityExceeded
  -> session handles the opaque invocation
  -> complete exactly once with a fixed status
```

### Alarm and shutdown

```text
alarm(callID)   -> session alarm handling  -> exactly-once completion
shutdown(callID)-> drain pending, shut the container down, resolve pending starts
```

A wake-up is requested through the `database_alarm.schedule` host import with a
validated timestamp; a nanosecond field at or above one second is rejected as
`invalidTimestamp` rather than normalized.

## State, Ownership, and Lifecycle

| State | Owner | Allowed transition |
|---|---|---|
| not started | `CloudflareDatabaseRuntime` | `start` only; every other call fails `notStarted` |
| starting | `CloudflareDatabaseRuntime` | single-flight; concurrent `start` fails `startupInProgress` |
| started | `CloudflareDatabaseRuntime` | `invoke`, `alarm`, `shutdown`; further `start` fails `alreadyStarted` |
| failed startup | `CloudflareDatabaseRuntime` | cleared so the host may retry; pending shutdowns are resolved |
| shutting down / shut down | `CloudflareDatabaseRuntime` | new work is refused; accepted work resolves before completion |
| reserved payload | `DatabaseInvocationPayloadOwnership` | consumed by `invoke`, or released exactly once |
| storage engine | this package until topology or container takes it | on failure before transfer, shut down here |
| `DBContainer` and session | `CloudflareDatabaseRuntime` | one per Durable Object instance; shut down on failure and on host shutdown |

The runtime is an `actor` because it owns an ordered asynchronous lifecycle with
suspension points. The entrypoint, command channel, and executor installation
state use `Mutex` because they are short non-suspending memory transitions
reached from synchronous host calls. No host callback or I/O runs inside a
critical section.

## Failure, Concurrency, and Constraints

- Every host-visible failure is one of the fixed ABI v3 statuses. Typed Swift
  errors (`CloudflareDatabaseConfigurationError`,
  `CloudflareDatabaseAlarmSchedulerError`,
  `CloudflareDatabaseRuntimeLimitsError`,
  `CloudflareDatabaseStorageTransportLimitsError`,
  `DatabaseInvocationPayloadError`) are mapped at that boundary and are not
  flattened into a generic failure earlier.
- All limits — context, request, response, error, pending invocations, storage
  request and response — are validated at construction, before any of them is
  used to size or accept a buffer.
- Swift concurrency on `wasm32` requires an installed serial executor and a
  delayed-enqueue hook. That requirement is satisfied inside this package and
  must not leak into consumer code.
- WASM-specific code is compiled under `#if arch(wasm32)`; `MultiBase` and
  `VectorIndexes` behavior is compiled under package-defined flags derived from
  the consumer's traits. Conditional compilation changes available API surface
  only; it never changes a synchronization or ownership contract.
- The reactor executable is linked with the WASI reactor execution model and a
  fixed stack and initial memory size. Those link arguments are extracted and
  asserted rather than restated by hand.

## Verification and Change Impact

Expected counts, the pinned toolchain, and the exact harness invocation are
owned by [AGENTS.md](AGENTS.md). This table maps each invariant to the gate that
falsifies it.

| Invariant | Required evidence |
|---|---|
| Explicit SQL database identity reaches the actual opened container, independently of its diagnostic name, through compiled and migration startup | `CloudflareDatabaseRuntimeTests.persistsAndReadsThroughApplicationSession` configuration-opening assertions in standard and MultiBase graphs |
| ABI v3 statuses and link shape are exactly as declared | `scripts/verify-reactor-abi.mjs` and `scripts/extract-reactor-link-arguments.mjs` against `Protocol/database-completion-status-v3.json` |
| the reactor graph excludes server and unselected features | reactor link verification with `DatabaseServerRuntime.o` and the server operation and host objects in the forbidden-object list |
| the reactor builds and runs on the pinned Embedded WASM SDK | `scripts/verify-runtime-feasibility.sh` with the matching `_wasm-embedded` SDK |
| portable SQL semantics S05 through S17 hold in standard and Embedded reactors, including reopen restoration | `scripts/verify-sql-conformance.sh` over the `Verification/SQLConformance` measurement package, which stays outside the release package graph |
| SQL preparation remains bounded without per-expression scheduling workarounds; lexical names, ordering authority, one budget and atomic failure remain intact | The versioned `SQLPreparationVerification` and `SQLExecutionOptimizationVerification` fixtures run through `sql:preparation` and `sql:optimization` in both reactor instantiation gates, with unchanged stack settings. Fixtures require exact values, typed failures, rollback and subsequent successful work before returning their verified responses. |
| graph-enabled SQL `SPARQL()` rewriting, direct SPARQL, typed producer positions, structural-limit rejection and post-failure reuse hold in the reactor | `scripts/verify-standard-wasm-graph.sh` (standard WASI, Swift 6.4.0 release) and `scripts/verify-runtime-feasibility.sh` (Embedded WASI without debug information, Swift 6.4.0 release), both through the `sql:graph` invocation; graph-enabled Embedded debug builds do not terminate before a 6.4.x release containing swiftlang/swift#93133 |
| lifecycle, admission, and payload ownership hold | native test graph run through `scripts/xcode-test-harness` per trait set, with no reuse of DerivedData across trait graphs |
| Cloudflare rejects unsupported index policies | the vector capability-admission contracts present only in the `AllRuntimeFeatures` graph |
| `MultiBase` topology and layout validation hold | the `MultiBase` trait graph, which adds the storage layout contracts |
| the host side upholds DO lifecycle, FIFO, and correlation | `npm test` in `Workers/CloudflareDatabaseRuntime` and `node scripts/verify-service-adapter.mjs` |

The verification executable owns its application schema and policies. Its
`deny-title-order` principal may read document payloads but cannot order by
`title`; public local function columns must remain usable. SQL-created fixture
tables admit only the verification principal through the explicit schema
policy factory. Neither policy is part of the shipped adapter product, and
the persisted document fields, directory and identity remain unchanged.

Change impact:

- A change to the reactor ABI, completion statuses, or payload ownership
  invalidates both the Swift and the TypeScript evidence and requires a
  coordinated host change.
- A change to the `database-framework` contract invalidates the resolved
  dependency evidence. A revision requirement may select an unreleased fix;
  it must pass the selected reactor and native trait graphs using URL
  dependencies before the adapter change is complete.
- A change to the adapter boundary — for example depending on a server product,
  interpreting DatabaseWire, or adding a backend choice — contradicts ADR-0003
  and requires superseding that decision before implementation.
- A change to `storage-kit`'s Durable Object storage or host transport
  invalidates the storage limit validation and the feasibility run.

## Planned SQL Runtime Hosting

S01 is a dependency and application-session mapping change, not a reactor ABI
change. The application may consume the [Kit query values and typed columns](../database-kit/Sources/DatabaseKit/Query/DESIGN.md#s01-public-query-boundary)
produced by Framework, while CloudflareDatabaseInvocation and TypeScript host
continue to carry opaque bounded bytes. QueryColumn's move to DatabaseKit does
not introduce DatabaseWire, server dispatch, rich-value JSON codecs or SQL
meaning into this package. ABI v3 completion statuses and payload ownership are
unchanged; this ABI version is independent of Wire v3/v5.

Application model declarations for rich query fields use Kit's admitted
queryType and existing generated persistence traversal. S01 changes this design
only: the host has no direct row-codec caller to migrate. S18 verifies the final
pinned URL dependency graph, real Embedded reactor and local Durable Object
persist/reload path with declared rich fields, ordered duplicate columns,
zero-row metadata and payload/resource rejection. Native tests alone do not
prove this path; TypeScript mocks do not prove lossless persistence. The same
Sendable, Mutex/actor and retained-owner contract applies on every target.
Exact counts/toolchains remain owned by the existing harness and operating
authority. Missing pinned SDK/runtime support remains an explicit unresolved
gate rather than evidence from a substituted toolchain or synthetic backend.

The application's session may consume the Framework statement/block entry
contract described by the
[SQL profile](../database-kit/Sources/DatabaseKit/Query/SQL/DESIGN.md). This host
continues to carry opaque request/context bytes. It does not add DatabaseWire
dispatch, SQL parsing, schema interpretation, or a dependency on Server.

FIFO admission and one persistent reactor/container own invocation lifetime.
A SQL block must finish its data transaction, checkpoint/schema state,
sequence completion, and resource cleanup before completion bytes cross the
reactor boundary. The Durable Object storage adapter owns the same checkpoint
and read-overlay contract as native adapters; Embedded never substitutes raw
mutable state or a no-op lock for shared synchronization.

Timezone data and other selected host capabilities are injected explicitly.
Unavailable capabilities are typed failures; there is no silent UTC, regex,
backend, or CPU fallback. Rich result bytes remain bounded and owned through
completion correlation.

Change verification executes the exact WASM/Embedded reactor, real local
Durable Object persistence/restart, checkpoint rollback, ordered/empty result
metadata, resource limits, cancellation, and shutdown. Compile/link and
TypeScript mocks alone are not this host's behavioral evidence.

### S17 Application-Owned SQL Invocation

The application-owned native and reactor fixtures consume
[SQLExecuteOperation](../database-kit/Sources/DatabaseWire/DESIGN.md#s17-sql-operation-contract-draft)
through a test-only `DatabaseWire` dependency and the
[Database facade](../database-framework/Sources/Database/DESIGN.md)
through a test-only `Database` product dependency. The facade supplies SQL text
parsing and source diagnostics; the fixture does not reproduce them. These
dependencies belong to the two existing test fixture targets only. They decode one complete
request, create the existing authorized Framework context, and invoke the
Framework SQL block boundary once. Request interpretation, principal selection,
SQL parsing, result projection, and diagnostic encoding stay outside
`CloudflareDatabase` and its TypeScript host. No fixture depends on Server's
internal targets or products.

```text
opaque host invocation
    -> application: decode SQLExecuteOperation, choose frame limit
    -> Framework: execute one text, statement, or block request
    -> application: borrow provisional outcomes; measure, reserve, frame
         failure -> Framework rollback and authoritative cleanup
         success -> Framework commit, cleanup, cancellation check
    -> application: consume Ready frame owner
    -> opaque host completion
```

The application selects a complete Wire frame cap no greater than the host's
`maximumResponseBytes`. The frame is measured, reserved, and encoded while
Framework still owns the provisional result. Borrowed rows, values, and views
do not escape that synchronous projection. The prepared response owner escapes
only after Framework establishes Ready; the application then returns its owned
bytes without re-execution or re-encoding. Failure during projection aborts the
whole request before commit. The host's existing post-response byte check is
an independent transport guard and cannot establish SQL rollback.

Ordered rows retain positional typed columns, duplicate labels, and zero-row
metadata. COPY bytes and command outcomes retain their order and affected-row
counts. A failed SQL request returns a complete typed remote failure carrying
Kit's strict SQLDiagnostic after rollback and cleanup; it returns no earlier
successful outcomes. The application supplies no continuation or automatic
retry. Existing FIFO, limits, cancellation, shutdown, and retained-byte
ownership remain host contracts and use their existing behavioral coverage.
Direct cancellation, including a direct `SQLExecutionFailure.underlyingError`,
is rethrown to the host; a cleanup composite containing cancellation remains a
typed failure. The application projection classifies the same closed known
Wire resource-limit cases as Server before Framework attaches source locations,
preserving the native cause and SQLSTATE 54000. Other Wire failures retain
their original classification.

| S17 application evidence | Scope and falsifiable behavior |
|---|---|
| `SQLApplicationSessionTests.orderedResultsThroughOpaqueInvocation` | One invocation returns ordered rows, COPY and commands with duplicate and empty result metadata preserved |
| `SQLApplicationSessionTests.typedDiagnosticAndRollback` | Syntax and execution diagnostics survive as SQLDiagnostic; an earlier mutation in the failed block is absent |
| `SQLApplicationSessionTests.frameRejectionRollsBackMutation` | A frame cap smaller than the complete result rejects projection and leaves its preceding mutation absent |
| `SQLApplicationSessionTests.referenceReopenAfterShutdown` | Authoritative shutdown followed by a new runtime over the same reference storage reads the committed value |

The native restart fixture uses the owned InMemory Durable Object client and
proves reference reopen behavior only. S18 owns exact Swift 6.4.0 release and
matching SDK reactor execution, a distinct reactor address space, and real
workerd persistence/restart evidence. The application fixtures are reused
there; native or mock success does not substitute for that gate. Historical
feasibility scripts retain their recorded toolchain provenance and are not
evidence for a different toolchain. Native host tests retain the existing
pinned native toolchain. Exact native counts remain with the operating and
harness owners.
