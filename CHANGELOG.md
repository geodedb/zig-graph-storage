# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — Sharded Graph Engine

- `ShardedGraphEngine` facade owning N=16 independent per-shard
  `GraphEngine` instances per logical graph. Enables N-way writer
  concurrency per graph while preserving each engine's single-threaded
  correctness argument. The existing `GraphStorage` vtable shape is
  preserved exactly; callers use `eng.storage()` for vtable dispatch or
  `eng.*` methods directly.
- Top-level `<graph_uuid>/shard_manifest.json` records shard-count,
  routing-algorithm fingerprint, and per-shard UUIDs (derived via
  BLAKE3 from the parent uuid + `"shard_NN"` tag).
- WAL record types `cross_shard_prepare`, `cross_shard_commit`,
  `cross_shard_abort` — support for cross-shard edge-create 2PC.
- Striped id allocation (`GraphConfig.base_shard_index`) so
  `shardOfNode(id) == shard_index` for every allocated id. Shard 0's
  initial id is bumped to `SHARD_COUNT` so the sentinel `0` is never
  returned.
- `shard_count`, `shard_uuid`, `shard_manifest`, `sharded_engine`,
  `sharded_engine_2pc`, `sharded_recovery` modules published from
  `graph_storage.*`.
- `tests/integration_sharded.zig` — full CRUD + cross-shard edges +
  reopen + concurrent-writer smoke.
- `tests/cross_shard_recovery.zig` — crash-after-both-prepares aborts;
  crash-after-source-commit completes on reopen.
- `benchmarks/sharded_throughput.zig` + `zig build
  bench-sharded-throughput` — ShardedGraphEngine vs single-engine
  throughput microbench (target: ≥4× on 16 cores).

### Breaking

- On-disk layout for sharded graphs is incompatible with the
  pre-sharded single-engine layout. Upgrade requires wiping the data
  directory; see
  `docs/superpowers/specs/2026-04-24-sharded-graph-engine-design.md`.

## [0.2.0] - 2026-04-23

### Added

- `sharded_store` module — an N-way sharded `std.AutoHashMap` wrapper
  published as a reusable primitive for consumers that need to serve
  concurrent writers on disjoint key ranges without stacking every
  mutation behind a single `HashMap` rehash critical section. Key
  routing uses splitmix64 for full-avalanche distribution across 16
  shards.  API mirrors `std.AutoHashMap` (`put`, `get`, `getPtr`,
  `remove`, `fetchRemove`, `contains`, `getOrPut`, `count`,
  `ensureTotalCapacity`, `ensureUnusedCapacity`,
  `clearRetainingCapacity`, `iterator`, `keyIterator`).  Concurrency
  is intentionally the consumer's responsibility — the type holds no
  locks; consumers pair one `std.Io.RwLock` per shard in their own
  struct.
- `bench-sharded-store` benchmark target — measures shard distribution
  evenness on sequential u64 IDs (N = 10k/100k/1M) and put/get
  throughput vs `std.AutoHashMap` baseline.  See
  `benchmarks/sharded_store_bench.zig`.
- `docs/sharded-store.md` — purpose, API, concurrency model, lock
  ordering, performance characteristics, and guidance on when to use
  vs when not to.
- 13 unit tests inline in `src/sharded_store.zig` covering round-trip
  behaviour, every method on the API, and a distribution-uniformity
  assertion on sequential ID inputs.

### Notes

`ShardedStore` is **not** used by the engine itself — `graph-storage`
is single-graph and single-threaded by charter.  The type is
published for consumers (e.g. graph databases with in-memory node/
edge caches, materialised views, or bulk-ingest staging maps) that
build concurrent structures on top of the engine.

## [0.1.0] - 2026-03-15

### Added

- Initial release of the disk-resident graph storage engine
- Per-graph page store with buffer pool and incremental checkpointing
- Transactional WAL with crash-safe recovery
- Locality-friendly adjacency storage (adj_store)
- Property chain storage with overflow pages
- Label dictionary and label index
- Property indexes (exact + chain)
- Page-level encryption support
- Integrity verification and repair
- Migration tooling
- Backup/restore primitives

[Unreleased]: https://gitlab.com/devnw/zig/graph-storage/-/compare/v0.2.0...HEAD
[0.2.0]: https://gitlab.com/devnw/zig/graph-storage/-/releases/v0.2.0
[0.1.0]: https://gitlab.com/devnw/zig/graph-storage/-/releases/v0.1.0
