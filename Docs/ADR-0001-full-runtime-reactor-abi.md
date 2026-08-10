# ADR-0001: Full Database Runtime Boundary

- Status: Accepted
- Date: 2026-07-18
- Protocol: Database reactor ABI v2

## Decision

Each application compiles its schema, migrations, commands, and full
`database-framework` service graph into one Swift 6.4 Embedded WASM reactor. The
Durable Object owns one reactor instance and invokes it through an opaque
binary `DatabaseWire` boundary.

TypeScript implements allocation transfer, completion delivery, task
scheduling, alarm persistence, and the synchronous StorageKit host ABI. It
does not interpret database operations, schemas, queries, indexes, jobs, or
transactions.

The reactor is a full runtime because database semantics execute through
`DBContainer`, `DatabaseRuntime`, and `DatabaseServerRuntime`; it does not mean
that every optional index implementation must be linked into every
application. SwiftPM traits define the application feature closure at compile
time. `GraphIndexes` also selects `ScalarIndexes`, which graph storage requires.
The fixed ABI and TypeScript host are independent of that feature closure.

`VectorIndexes` remains one feature closure containing Flat, HNSW, IVF, and
PQ. Cloudflare hosting narrows execution capability without introducing an
HNSW-specific trait: Flat, IVF, and PQ are supported, while every effective
HNSW configuration is rejected before `DBContainer.open`. The runtime never
falls back to another vector algorithm. The detailed rationale and validation
contract are recorded in
[ADR-0002](ADR-0002-cloudflare-vector-capabilities.md).

## Exports

| Export | Signature | Responsibility |
|---|---|---|
| `database_alloc` | `(u32) -> u32` | Allocate runtime address space |
| `database_dealloc` | `(u32, u32) -> void` | Release a runtime allocation |
| `database_start` | `(u32) -> void` | Bootstrap storage topology, container, and server runtime |
| `database_invoke` | `(u32, u32, u32, u32, u32) -> void` | Consume an authorization frame and DatabaseWire request, then enqueue one authenticated invocation |
| `database_alarm` | `(u32) -> void` | Run one bounded persistent-job wake-up from a Durable Object alarm |
| `database_executor_run` | `(u32) -> void` | Run one scheduled Swift task |
| `database_clock_resume` | `(u32) -> void` | Resume one currently registered monotonic wait |

The executor export is part of ABI v2. Swift async execution cannot make
progress in a persistent reactor without a host-driven executor wake-up.

## Imports

| Module and name | Signature | Responsibility |
|---|---|---|
| `storage_host.dispatch` | `(u32, u32) -> u32` | Execute one synchronous StorageKit request, retain the host response, and return its exact byte count |
| `storage_host.receive` | `(u32, u32) -> void` | Copy the pending host response into final Swift-owned storage |
| `storage_host.discard` | `() -> void` | Release a pending response rejected before receipt |
| `database_host.complete` | `(u32, u32, u32, u32) -> void` | Complete a startup, invocation, or alarm call |
| `database_executor.schedule` | `(u32, f64) -> void` | Schedule a task immediately or after a monotonic delay |
| `database_alarm.schedule` | `(i64, u32) -> void` | Persist the next absolute UTC job wake-up as seconds and nanoseconds since the Unix epoch |
| `database_clock.monotonic_nanoseconds` | `() -> i64` | Read monotonic host time for storage deadlines |
| `database_clock.wall_time_milliseconds` | `() -> i64` | Read Unix wall time for persisted database timestamps |
| `database_clock.schedule` | `(u32, f64) -> void` | Register one cancellable monotonic wait |
| `database_clock.cancel` | `(u32) -> void` | Cancel one registered monotonic wait |
| `database_random.random_u64` | `() -> i64` | Supply cryptographically random UUID bits |

All pointers are offsets into exported linear memory. Every byte count and
aggregate frame is checked against an independently configured limit before
copying or allocating.

## Authentication boundary

The application Worker authenticates the external credential before Durable
Object RPC. It passes only an already authenticated principal to
`CloudflareDatabaseDurableObject.execute(requestBytes, principal)`. The private
ABI encodes that principal separately from DatabaseWire so the host cannot
rewrite request semantics and a client cannot place self-asserted roles in the
request envelope.

The canonical authorization frame contains:

```text
"DBAU" magic
  + little-endian version 1
  + principal identifier
  + canonical UTF-8 ordered unique roles
  + canonical DatabaseWire FieldObject claim bytes
```

The frame is limited to 256 KiB. Identifiers, role count, role byte length,
ordering, duplicate roles, trailing bytes, malformed claims, and the exact
frame version are validated before `AuthorizationContext` is constructed.
Raw bearer tokens, session cookies, and authentication secrets do not cross
this ABI.

## Completion statuses

`Protocol/database-completion-status-v1.json` is the canonical machine-readable
v1 status vector. Swift and TypeScript tests must both reject any divergence
from this vector.

| Status | Value | Runtime meaning |
|---|---:|---|
| `success` | 0 | The call completed and the payload is a successful result |
| `invalidCallID` | 1 | The runtime received an invalid or conflicting call identifier |
| `invalidPayload` | 2 | Runtime payload ownership or address validation failed |
| `requestTooLarge` | 3 | The request exceeded the configured request limit |
| `responseTooLarge` | 4 | The response exceeded the configured response limit |
| `queueCapacityExceeded` | 5 | The runtime invocation queue has no remaining capacity |
| `notStarted` | 6 | An invocation or alarm arrived before successful startup |
| `alreadyStarted` | 7 | Startup was requested after the runtime became ready |
| `startupInProgress` | 8 | Startup was requested while another startup call was active |
| `startupFailed` | 9 | Application bootstrap, migration, or readiness failed |
| `cancelled` | 10 | The runtime cancelled the call before completion |
| `runtimeFailed` | 11 | A runtime invariant or operation failed |
| `invalidRequestFrame` | 12 | DatabaseWire decoding rejected the request frame |
| `scheduledWorkFailed` | 13 | One scheduled-work delivery failed and may be retried by the host |

Statuses that represent ownership, lifecycle, or runtime invariants terminate
the active reactor generation. Request-specific validation failures remain
nonterminal when the runtime can safely execute later calls. A
`scheduledWorkFailed` completion is also nonterminal: the Durable Object keeps
the recovery alarm and reports the alarm failure to the platform without
discarding an otherwise valid runtime generation.

## Byte ownership

Ownership is part of ABI v2 and is not inferred from pointer lifetime.

| Boundary | Ownership contract |
|---|---|
| `database_alloc` result before invocation | JavaScript owns the allocation and may release it with `database_dealloc` if storing the request fails |
| `database_invoke` authorization and request | Calling the export consumes both allocations, including when either payload is invalid; JavaScript must not access or deallocate either afterward |
| `database_host.complete` payload | Swift lends the bytes for the synchronous service call; JavaScript copies them once into its heap before returning |
| `storage_host.dispatch` request | Swift lends the bytes for the synchronous service call; JavaScript must not retain the view |
| Storage dispatcher result | JavaScript owns an independent view that does not alias the borrowed runtime request |
| `storage_host.dispatch` response | JavaScript retains the independent response after returning its exact length |
| `storage_host.receive` destination | Swift lends its final `ByteString` allocation for one synchronous, exact-length copy; JavaScript releases the pending response before returning |
| `storage_host.discard` | JavaScript releases the pending response without copying after Swift rejects its length |

Swift request and storage-response decoders retain immutable allocation owners
and create constant-time range views. They do not materialize field arrays.
The completion copy is required because JavaScript cannot retain a view whose
Swift owner may be destroyed immediately after the service call returns. The
StorageKit response copy into runtime address space is required because the
source and destination are different heaps. Swift allocates the final response
storage only after `dispatch` returns; JavaScript never re-enters a reactor
export from a host import. No additional whole-frame copy is permitted on
either path.

The HTTP reader reuses a sole body chunk directly. Multiple non-contiguous
stream chunks are consolidated exactly once because DatabaseWire execution
requires one contiguous frame. FIFO admission accounts for the entire backing
buffer retained by a typed-array view, so a small subarray cannot bypass the
aggregate memory limit.

## Lifecycle and failure semantics

1. The Durable Object migrates its SQLite host schema and instantiates the
   reactor inside constructor-time `blockConcurrencyWhile`.
2. `database_start` completes only after the single Cloudflare storage topology,
   container, and full server runtime are ready. Base creation and Base-local
   schema migration remain explicit persistent operations.
3. Database invocations and alarms enter one explicit FIFO queue. The Swift
   runtime also serializes both entry types as a defense-in-depth invariant.
4. A completion timeout makes the runtime generation unusable. The Durable Object
   rejects every pending call and aborts the Durable Object so a later request
   receives a newly instantiated generation. A timed-out runtime is never
   reused.
5. Ordinary startup failures terminate constructor initialization. A later
   Durable Object generation may retry from durable SQLite state.
6. An alarm schedule service call is attached to the active runtime call. JavaScript
   resolves that call only after Durable Object `setAlarm` persistence succeeds.
   A schedule failure poisons the reactor and aborts the Durable Object so
   startup recovery can derive the next alarm from persistent job state.
7. The Durable Object `alarm()` handler awaits `database_alarm` through the
   same FIFO queue. Infrastructure failures escape the handler so Cloudflare's
   alarm retry mechanism can invoke a later runtime generation. TypeScript does
   not inspect persisted job state or implement retry policy.

The release gate executes the same optimized reactor in Node and workerd. The
workerd path must cross Worker routing, Durable Object RPC, the FIFO runtime
owner, the authenticated ABI, the synchronous StorageKit host ABI, and Durable
Object SQLite. It first creates and provisions a Base, then executes a
DatabaseWire mutation for an OWL-class entity and verifies the
generated RDF projection through a SPARQL ASK request. After restarting workerd
with the same persisted state, both the document query and SPARQL ASK request
must observe the prior mutation. When `VectorIndexes` is selected, startup
exercises Flat, IVF, and PQ through their actual write, maintenance, query, and
delete paths. A separate negative fixture proves that HNSW fails at bootstrap
before container opening. The gate requires `VectorIndex.o` and `SwiftHNSW.o`
in that composition because the framework feature remains cohesive, but it
does not mistake link presence for supported Cloudflare execution.

## Consequences

- A generic runtime artifact is not shipped by this package. The application
  owns the concrete executable target because schema and command registration
  are compile-time dependencies.
- Foundation adapters and native SQLite, PostgreSQL, and FoundationDB backends
  are excluded from the Embedded reactor. Canonical primitive, database, and
  storage contracts remain linked; platform conversion and native backend
  products remain outside the runtime graph. Native verification composition
  may select those host adapters without changing the Embedded dependency
  graph.
- `DatabaseWire` and the StorageKit host wire remain separate protocols with
  separate limits.
- ABI v2 has no negotiation or compatibility branch. Any ABI change requires
  a deliberate new contract.
- Fixed symbol spellings remain confined to boundary descriptors and ABI
  attributes. Swift and TypeScript declarations use runtime responsibility,
  ownership, event, and lifecycle names.
