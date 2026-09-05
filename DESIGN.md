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

- DatabaseWire framing, decoding, or dispatch. The package contains no
  reference to `DatabaseWire`; an invocation carries opaque context and request
  bytes whose meaning belongs to the application.
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
`startupFailed` carrying its description.

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
| ABI v3 statuses and link shape are exactly as declared | `scripts/verify-reactor-abi.mjs` and `scripts/extract-reactor-link-arguments.mjs` against `Protocol/database-completion-status-v3.json` |
| the reactor graph excludes server and unselected features | reactor link verification with `DatabaseServerRuntime.o` and the server operation and host objects in the forbidden-object list |
| the reactor builds and runs on the pinned Embedded WASM SDK | `scripts/verify-runtime-feasibility.sh` with the matching `_wasm-embedded` SDK |
| lifecycle, admission, and payload ownership hold | native test graph run through `scripts/xcode-test-harness` per trait set, with no reuse of DerivedData across trait graphs |
| Cloudflare rejects unsupported index policies | the vector capability-admission contracts present only in the `AllRuntimeFeatures` graph |
| `MultiBase` topology and layout validation hold | the `MultiBase` trait graph, which adds the storage layout contracts |
| the host side upholds DO lifecycle, FIFO, and correlation | `npm test` in `Workers/CloudflareDatabaseRuntime` and `node scripts/verify-service-adapter.mjs` |

Change impact:

- A change to the reactor ABI, completion statuses, or payload ownership
  invalidates both the Swift and the TypeScript evidence and requires a
  coordinated host change.
- A change to the `database-framework` contract invalidates the resolved
  release. The requirement's lower bound moves only after the reactor graph and
  the trait matrices are re-verified against the new release.
- A change to the adapter boundary — for example depending on a server product,
  interpreting DatabaseWire, or adding a backend choice — contradicts ADR-0003
  and requires superseding that decision before implementation.
- A change to `storage-kit`'s Durable Object storage or host transport
  invalidates the storage limit validation and the feasibility run.
