# Cloudflare Database Framework Adapter

## Purpose and Scope

This package adapts `database-framework` to a Cloudflare Durable Object and
its Embedded Swift WASM runtime. It owns the platform runtime boundary,
StorageKit Durable Object storage composition, and the application-facing
configuration needed to open a database container.

The package is the package-level design root. Its direct implementation
children are the `CloudflareDatabase` Swift module, the
`CloudflareDatabaseTaskScheduling` support target, and the
`Workers/CloudflareDatabaseRuntime` TypeScript service adapter. The package
does not own application schemas, database-server, or SwiftWeb actor
semantics.

## Responsibilities and Boundaries

The adapter owns:

- Durable Object lifecycle, runtime admission, FIFO scheduling, completion,
  and shutdown;
- the private reactor ABI v3 and bounded payload ownership;
- Cloudflare capability validation and the StorageKit Durable Object engine;
- application configuration and session composition around `DBContainer`;
- the optional `MultiBase` storage topology adapter.

The framework owns database execution and storage-root behavior. The
application owns schema, migrations, session behavior, and application
meaning. The TypeScript service adapter owns Worker materialization and
deployment composition. This package never links or exposes `database-server`.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [ADR-0003](Docs/ADR-0003-framework-adapter-and-standalone-server-boundaries.md) | package authority | framework/server/platform ownership | Keeps this adapter independent from `database-server`. | Recheck dependency direction when framework products change. |
| [ADR-0004](Docs/ADR-0004-cohesive-cloudflare-database-runtime.md) | package authority | cohesive runtime, ABI, lifecycle, and service boundaries | Defines the single Cloudflare runtime boundary and explicit traits. | Preserve ABI v3, FIFO, exactly-once completion, and no implicit traits. |
| [database-framework DBConfiguration](https://github.com/1amageek/database-framework/blob/26.0905.0/Sources/DatabaseEngine/Core/DBConfiguration.swift) | depends on | database root configuration and `MultiBase` topology contracts | The selected framework version owns database root selection and Base placement. | Recheck the pinned tag before changing calls. |

## Architecture

```text
Cloudflare Durable Object
        |
        v
TypeScript host and reactor ABI v3
        |
        v
CloudflareDatabase runtime actor
        |
        +--> application configuration and session
        +--> DBContainer / DatabaseStorageTopology
        +--> Cloudflare Durable Object StorageEngine
```

For `MultiBase`, the topology is deliberately small and explicit:

```text
StoragePartitionIdentity
        |
        v
Cloudflare storage engine (one logical partition)
        |
        v
DatabaseStorageDomain(rootPath: domainNamespacePath)
        |
        v
DatabaseStoragePlacement(domainID)
        |
        v
Base address: bases/<Base.ID>
```

## Contracts and Invariants

`CloudflareDatabaseStorageLayout` exposes the domain identity and namespace
root required to construct a topology. `domainNamespacePath` maps directly to
the framework's `DatabaseStorageDomain.rootPath`. Base placement has no
adapter-selected path: the framework fixes each Base address at
`bases/<Base.ID>` below its domain root. Therefore the adapter must not retain
or forward a legacy base namespace field or obsolete placement-path
validation contract.

The package preserves these invariants:

- one active runtime and container per Durable Object instance;
- FIFO admission and exactly-once completion for accepted calls;
- ABI v3 ownership and bounded byte transfer;
- storage and runtime shutdown are authoritative and completed before failure
  is returned;
- HNSW/vector capability rejection occurs before storage opens;
- `MultiBase` is explicit and is not implied by `AllRuntimeFeatures`;
- no database-server dependency or server operation registry enters the
  package graph.

## Runtime Flows

1. The runtime obtains application configuration and validates Cloudflare
   capabilities.
2. It creates the partition-bound StorageKit engine and clocks.
3. In `MultiBase` mode it maps `domainNamespacePath` to one validated domain
   root and creates a placement identified only by its domain.
4. It opens `DBContainer`, creates the application session, and admits FIFO
   invocations.
5. Shutdown closes the session and container, then releases storage exactly
   once.

Topology construction failure retains engine ownership in the runtime, shuts
   it down, and rethrows the typed framework error.

## State, Ownership, and Lifecycle

The runtime actor owns the active container, session, lifecycle state, and
completion channel. The application may retain the container through its
session but does not own runtime shutdown. The StorageEngine is created for
the configured `StoragePartitionIdentity`; its partition binding is the
storage authority, while `DatabaseStorageDomain.rootPath` is the framework
directory root within that engine.

The `MultiBase` topology is immutable after validation. A placement names a
domain and does not duplicate the Base directory path. This prevents the
adapter from creating a second root authority or drifting from the framework
Base address contract.

## Failure, Concurrency, and Constraints

Configuration, topology, capability, storage, container, session, and
application failures remain typed failures. No failure is converted into a
successful completion. Runtime state transitions and queue order are actor
isolated; external callbacks and I/O occur outside critical sections.

The adapter uses the fixed Swift 6.4 toolchain and matching WASM SDK for
runtime feasibility. Native and Embedded targets must retain the same
ownership, completion, and synchronization contracts.

## Verification and Change Impact

The `CloudflareDatabase` tests and runtime-verification executable cover the
configuration, storage composition, lifecycle, FIFO/completion, capability
rejection, and ABI paths. The package gates are run serially for the default,
`MultiBase`, and `AllRuntimeFeatures` trait selections, followed by the
TypeScript service adapter and fixed-SDK runtime feasibility checks.

Any change to the public layout contract must recheck the direct
`CloudflareDatabaseStorageLayout` tests, all runtime-verification callsites,
the `MultiBase` native gate, and the embedded feasibility gate. Any change to
ABI, ownership, lifecycle, or completion requires the corresponding ADR
review before implementation.
