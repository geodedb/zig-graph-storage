# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Committed records are no longer lost on stores with at-rest encryption.
  The pager wrote the 16-byte AES-GCM tag over the last 16 bytes of every
  page body, and layouts that use the page end lost those bytes on every
  write and reload (eviction, reopen, crash recovery), silently because the
  page still authenticated: with the default 8 KiB page every node in slot
  169 of 170 read back missing or with tag bytes in its flags; the last two
  heads of every `adj_in_dir` page and, at 4 KiB, the last v3 adjacency entry
  of a full block were damaged too. Encrypted pages are now written in a
  header-tag envelope: the tag goes into header bytes 0..16 (`page_id`/`lsn`,
  unused by every store), the rest of the header is the additional
  authenticated data, `PageFlags.encrypted` marks the page, and the whole
  body is the stores'. Pages written in the old envelope stay readable and
  move to the new one on their next write; their last 16 body bytes, which
  never reached the disk, read as zero. A binary without this fix cannot
  read pages written in the new envelope (it fails with
  `error.DecryptionFailed`, never with wrong data) (SONNY-6441).
- An encrypted page with a zeroed header is an authentication error
  (`error.DecryptionFailed`), and a plaintext page with a zeroed header must
  pass its CRC32C. Both were taken for never-written pages, so damage read
  back as missing nodes (SONNY-6441).
- `test-prop-store-slab`, `test-edge-inline-public-id` and
  `test-ordered-index-recovery` pass again and run under `test-integration`.
  The first two still asserted pre-GAP-0060 behaviour (edge properties never
  slab-packed, v2 adjacency blocks, the GSEIDX5 40-byte edge snapshot); they
  now pin `edge_prop_slab_packing = false` where they test the legacy writer
  and expect GSEIDX6 44-byte records. Ordered-index Test B and B2 expected a
  committed post-checkpoint node to be lost in a crash; they now require it
  to survive (SONNY-6438).
- `BufferPool` publishes and releases `pin_count` with atomic operations
  only. Eviction released a frame with a plain `pin_count = 0` and the slow
  path republished it with a plain `pin_count = 1`; a lock-free reader that
  had looked the frame up under its old identity could pin it in between,
  lose its increment to the plain store, and its undo then removed the
  loader's pin, leaving an in-use frame evictable. The lock-free lookup's
  intentionally racy reads are now confined to `speculativeLookup`, ordered
  before the seqlock re-check, and hidden from ThreadSanitizer with
  `AnnotateIgnoreReadsBegin/End`; geode's parallel-union TSan reports in
  `pin` are gone. New steps `test-buffer-pool-concurrent-readers` (also under
  `test-integration`) and `test-buffer-pool-concurrent-readers-tsan`
  (SONNY-6438).

## [0.4.11] - 2026-11-12

### Changed

- Converge thread_pool v0.2.10, which fixes data races in the pool's
  work-stealing queues (SONNY-6375).

### Fixed

- `GraphEngine.getProperty` and `getPropertyNoDerived` count property reads
  atomically. Concurrent readers raced on `metrics.properties_read` and lost
  counts (SONNY-6375).
- `test-engine-early-ready-tsan` and `test-parallel-shard-open-tsan` now build
  with the LLVM backend. Zig 0.16's self-hosted x86_64 backend ignores
  `sanitize_thread`, so both steps previously ran uninstrumented (SONNY-6375).
- Committed writes are no longer lost after a checkpoint that empties the
  WAL, a process exit without `close`, a reopen and a crash. The inner WAL
  restarted its numbering at 0 below `last_checkpoint_lsn` and recovery
  skipped every record numbered at or below it. `WalManager.init` now writes
  a durable `checkpoint_marker` anchor at the checkpoint LSN when the reopened
  log is behind it, and recovery replays a record when either its WAL LSN or
  its own LSN is after the checkpoint. Stores already written in that state
  are recovered on first open (SONNY-6424).

## [0.4.3] - 2026-09-15

### Changed

- Converge grpc_zig v0.1.10 (GAP-0838 diamond sync).

## [0.4.2] - 2026-09-12

### Changed

- Converge thread_pool v0.2.7, fips v0.1.1, protobuf v0.1.5, config v0.1.13 (GAP-0838 diamond sync).

## [0.4.1] - 2026-09-12

### Changed

- Converge thread_pool v0.2.7, fips v0.1.1, protobuf v0.1.5 (GAP-0838 diamond sync).

## [0.2.1] - 2026-06-11

### Security — 2026-06-10 audit remediation

- AES-GCM page nonce reuse fixed: flush now advances the live frame's
  `write_count` and recovery seeds it to `max(on-disk, logged)` so the
  per-page nonce is strictly monotonic (SEC-0037).
- Backup restore authenticates the whole archive (CRC + HMAC) before any
  bytes are written and defends every path component against symlink
  traversal (per-component `O_NOFOLLOW`; `resolve_beneath` is a no-op on
  Linux) with tamper-evident extraction (SEC-0038, SEC-0049).
- Cross-shard 2PC recovery now verifies WAL checksums via a streaming
  strict reader and fails closed on forged/malformed records (SEC-0041).
- Manifest is authenticated with HMAC-SHA256 when encryption is enabled,
  and the `verify` tool checks it under TDE (SEC-0043).
- Untrusted on-disk inputs are bounds/shape validated before use:
  `var_store` data_len, `prop_store` dir_count, adjacency/property chain
  cycle guards, `shard_manifest.json` JSON shape, `labels.dict`
  duplicate-key handling, and index-snapshot counts plus a CRC32 over
  each snapshot payload (SEC-0039/0040/0042/0044/0047/0048/0050/0051).
- Per-pager encryption keys are securely zeroed on teardown and file
  creation is hardened (SEC-0045, SEC-0052). Untracked npm artifacts
  removed and gitignored (SEC-0046).

### Added

- Opt-in B+tree property indexes and per-graph index catalog wired into
  the engine lifecycle (declare → build → persist → reopen → equality /
  range query), with index-kind extension points (GAP-0027, FR-016,
  FR-017, FR-021).
- Structured lifecycle events for migration, verify, and index build
  (NFR-OBS-002).
- Opt-in `GraphConfig.sync_mode` (default `sync_each_commit` preserves
  per-commit durability; `deferred` trades durability for throughput).

### Performance

- Buffer pool auto-sizes on `create()` and reserves frames for hot node
  pages, fixing the at-scale point-lookup degradation (PERF-0051).
- Buffered single-pass index-snapshot I/O, O(1) label-index posting
  lists, dirty-aware checkpoint fsync, parallel cross-shard 2PC, and
  single-pass integrity scan (PERF-0052/0054/0057/0058/0060).

### Fixed

- Resource/FD leak on `create`/`open` error paths (QUAL-0042).
- Integrity scan no longer swallows I/O errors as a clean result.
- Property-store out-of-bounds write on oversized keys and a directory
  rebuild corruption (found via new fuzz coverage).

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

[Unreleased]: https://gitlab.com/devnw/zig/graph-storage/-/compare/v0.2.1...HEAD
[0.2.1]: https://gitlab.com/devnw/zig/graph-storage/-/compare/v0.2.0...v0.2.1
[0.2.0]: https://gitlab.com/devnw/zig/graph-storage/-/releases/v0.2.0
[0.1.0]: https://gitlab.com/devnw/zig/graph-storage/-/releases/v0.1.0
