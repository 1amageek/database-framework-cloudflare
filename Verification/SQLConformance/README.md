# SQL Conformance Verification

This measurement package builds a Cloudflare reactor that carries the portable
SQL conformance fixtures for S05 through S17: parameter binding, selected
values, scalar text and pattern semantics, temporal values, collections,
relational and analytic queries, recursion and table functions, catalogs,
checkpoints, constraints and sequences, DML, DDL, request-local operations,
and the S17 projection through Engine, Wire and Client.

It resolves the enclosing `database-framework-cloudflare` working tree by path,
like `database-framework/Benchmarks`, so its testable imports, `QueryAST`, and
`DatabaseClient` never enter the release package graph or the Embedded release
gate reactor. Its other dependencies use the same revisions as the enclosing
manifest.

Run it from the repository root:

```sh
sh scripts/verify-sql-conformance.sh
```

The script builds standard and Embedded WASI debug reactors with the Swift
6.4.0 release and executes every group through
`Workers/CloudflareDatabaseRuntime/scripts/verify-sql-conformance-reactor.ts`,
including the reactor reopen checks for S11, S13, S15 and S16. Set
`DATABASE_SQL_CONFORMANCE_LANES` to `wasm` or `embedded` to run one lane.
