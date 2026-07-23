# ADR-0001: Full Database Runtime Boundary

- Status: Accepted
- Date: 2026-07-18
- Protocol: Database reactor ABI v1

## Decision

Each application compiles its schema, migrations, commands, and full
`database-framework` service graph into one standard WASI reactor. The
Durable Object owns one reactor instance and invokes it through an opaque
binary `DatabaseWire` boundary.

TypeScript implements allocation transfer, completion delivery, task
scheduling, alarm persistence, and the synchronous StorageKit host ABI. It
does not interpret database operations, schemas, queries, indexes, jobs, or
transactions.

## Exports

| Export | Signature | Responsibility |
|---|---|---|
| `database_alloc` | `(u32) -> u32` | Allocate runtime address space |
| `database_dealloc` | `(u32, u32) -> void` | Release a runtime allocation |
| `database_start` | `(u32) -> void` | Bootstrap storage, migrations, container, and server runtime |
| `database_invoke` | `(u32, u32, u32) -> void` | Enqueue one DatabaseWire request |
| `database_alarm` | `(u32) -> void` | Run one bounded persistent-job wake-up from a Durable Object alarm |
| `database_executor_run` | `(u32) -> void` | Run one scheduled Swift task |
| `database_clock_resume` | `(u32) -> void` | Resume one currently registered monotonic wait |

The executor export is part of ABI v1. Swift async execution cannot make
progress in a persistent reactor without a host-driven executor wake-up.

## Imports

| Module and name | Signature | Responsibility |
|---|---|---|
| `storage_host.dispatch` | `(u32, u32) -> u32` | Execute one synchronous StorageKit host frame and return a length-prefixed frame |
| `database_host.complete` | `(u32, u32, u32, u32) -> void` | Complete a startup, invocation, or alarm call |
| `database_executor.schedule` | `(u32, f64) -> void` | Schedule a task immediately or after a monotonic delay |
| `database_alarm.schedule` | `(i64, u32) -> void` | Persist the next absolute UTC job wake-up as seconds and nanoseconds since the Unix epoch |
| `database_clock.schedule` | `(u32, f64) -> void` | Register one cancellable monotonic wait |
| `database_clock.cancel` | `(u32) -> void` | Cancel one registered monotonic wait |

All pointers are offsets into exported linear memory. Every byte count and
aggregate frame is checked against an independently configured limit before
copying or allocating.

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

Statuses that represent ownership, lifecycle, or runtime invariants terminate
the active reactor generation. Request-specific validation failures remain
nonterminal when the runtime can safely execute later calls.

## Byte ownership

Ownership is part of ABI v1 and is not inferred from pointer lifetime.

| Boundary | Ownership contract |
|---|---|
| `database_alloc` result before invocation | JavaScript owns the allocation and may release it with `database_dealloc` if storing the request fails |
| `database_invoke` request | Calling the export consumes the allocation; JavaScript must not access or deallocate it afterward |
| `database_host.complete` payload | Swift lends the bytes for the synchronous service call; JavaScript copies them once into its heap before returning |
| `storage_host.dispatch` request | Swift lends the bytes for the synchronous service call; JavaScript must not retain the view |
| Storage dispatcher result | JavaScript owns an independent view that does not alias the borrowed runtime request |
| `storage_host.dispatch` response frame | JavaScript allocates the frame through `database_alloc`; Swift adopts it and releases it through `database_dealloc` when the final response slice is destroyed |

Swift request and storage-response decoders retain immutable allocation owners
and create constant-time range views. They do not materialize field arrays.
The completion copy is required because JavaScript cannot retain a view whose
Swift owner may be destroyed immediately after the service call returns. The
StorageKit response copy into runtime address space is required because the source and
destination are different heaps. No additional whole-frame copy is permitted
on either path.

The HTTP reader reuses a sole body chunk directly. Multiple non-contiguous
stream chunks are consolidated exactly once because DatabaseWire execution
requires one contiguous frame. FIFO admission accounts for the entire backing
buffer retained by a typed-array view, so a small subarray cannot bypass the
aggregate memory limit.

## Lifecycle and failure semantics

1. The Durable Object migrates its SQLite host schema and instantiates the
   reactor inside constructor-time `blockConcurrencyWhile`.
2. `database_start` completes only after application migrations and the full
   server runtime are ready.
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
   not inspect job records or implement retry policy.

## Consequences

- A generic runtime artifact is not shipped by this package. The application
  owns the concrete executable target because schema and command registration
  are compile-time dependencies.
- `DatabaseWire` and the StorageKit host wire remain separate protocols with
  separate limits.
- ABI v1 has no negotiation or compatibility branch. Any ABI change requires
  a deliberate new contract.
- Fixed symbol spellings remain confined to boundary descriptors and ABI
  attributes. Swift and TypeScript declarations use runtime responsibility,
  ownership, event, and lifecycle names.
