# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `GraphConfig.label_dict_divergence` (`LabelDictDivergencePolicy`:
  `.reject`, default, or `.adopt_shard0`), `GraphEngine.assignLabelId`,
  and `LabelDictionary.assignId` / `unassign` / `clone` (SONNY-6524).
- `zig build bench-label-assign [-- <dir>]` times `getOrAssignLabel` for
  new and existing names on a 16-shard store and a single engine
  (SONNY-6524).

### Changed

- `ShardedGraphEngine.getOrAssignLabel` with a new name writes shard 0's
  `labels.dict` first and then the other 15 shards' in parallel with shard
  0's id, instead of all 16 one after another (32 serial fsyncs since
  0.4.14). `bench-label-assign` on ext4/NVMe, same machine and load: 160 to
  31 ms median per new name, 4.86 to 0.92 s for 30 (a single `GraphEngine`
  is 10 ms). Existing names still write nothing. The calling thread waits
  for every shard, so the caller's existing serialization of label
  assignment covers the parallel writes; the injected allocator must be
  thread-safe, as `open` already requires (SONNY-6524).

### Fixed

- A failed durable write of a new label name left the name in memory: the
  call failed, but later calls found the name and never wrote it, and on a
  `ShardedGraphEngine` the shards after the failing one were never given
  it, so the next new name got a different id on them than on shard 0.
  `GraphEngine.getOrAssignLabel` now removes the name again when the write
  fails, and the sharded broadcast gives every shard shard 0's id
  explicitly; a shard that already holds the name or the id differently
  fails the call with `error.LabelDictionaryDiverged` (SONNY-6524).
- `ShardedGraphEngine.open` did not compare shard label dictionaries. It
  now rewrites a shard's `labels.dict` from shard 0's when the shard is
  missing names (a crash or failed write during a new name) or names an id
  that none of its records uses differently, and refuses with
  `error.LabelDictionaryDiverged` (warning names the shard, id, both names
  and record counts; nothing written) when one of the shard's nodes, edges
  or declared indexes carries an id the shard names differently, as stores
  split by geode's old ORDER BY path do. `.adopt_shard0` rewrites those
  too, for callers whose ids all come from shard 0. No on-disk format
  change. `test-label-dict-shards` (also under `test-integration`)
  (SONNY-6524).

## [0.4.14] - 2026-11-13

### Changed

- The WAL record checksum (CRC32C over the record header and payload,
  computed while a record is serialized and again when replay checks it)
  uses the CPU's CRC32C instruction through the new streaming
  `crc32c.Hasher` (`init` / `update` / `final`), with the table as fallback,
  as the page checksum does since 0.4.13. Values are unchanged.
  `zig build bench-checksum -Doptimize=ReleaseFast` on an x86_64 host:
  `WalRecord.serializeInto` of an 8 KiB page image 16000 to 770 ns
  (SONNY-6470).

### Fixed

- Crash recovery applies, for each page, only the committed page image with
  the highest LSN. A GAP-0900 WAL batch numbers its page images when they are
  made but writes them at its transaction's commit, so a second transaction
  on the same `TxnManager` that overlapped it logged a newer image of a shared
  page first, and recovery, which applied images in log order, overwrote it
  with the batched transaction's older one: committed writes were lost after
  a crash (geode SONNY-2978: 64 of 64 property removals came back). WAL logs
  of that shape written by 0.4.12 and 0.4.13 recover correctly with this
  release. The write path, the WAL format and batching are unchanged. A
  superseded image still feeds the id-counter heal (its ids were committed)
  but not the node/edge count heal. The GAP-0900 comments that said batching
  does not change durability are corrected (SONNY-6473).
- A crash during a checkpoint could lose data. The checkpoint wrote the
  manifest and truncated the WAL before saving `free.store`, so a crash in
  between left the new manifest next to the previous bitmap and the next
  open handed pages allocated since then to new writers (committed
  properties overwritten); the manifest rename itself was never
  directory-fsynced before the WAL truncate. `labels.dict` was saved only at
  checkpoint time, so a crash before that lost every label name assigned
  since the previous checkpoint. Now `free.store` is written and
  directory-fsynced inside the checkpoint before the manifest, the manifest
  rename is directory-fsynced before the WAL truncate, and
  `getOrAssignLabel` makes a new name durable before returning its id
  (checkpoints no longer write `labels.dict`; `create` writes the empty
  dictionary). `close()` uses the same
  sequence and now also records the per-store page counts in the manifest.
  Opening a store that crashed in that window under <= 0.4.13 detects a
  bitmap with fewer allocated pages than the manifest recorded, or an
  unallocated written node page below the highest issued node id, and
  rebuilds the bitmaps; lost label names are reported with a warning (they
  cannot be re-derived). `test-checkpoint-side-file-crash` crashes at every
  step of light, full and close checkpoints, plaintext and TDE, single and
  sharded. Per checkpoint the fsync count is unchanged (the manifest's new
  directory fsync replaces the dropped `labels.dict` write) and one rename
  fewer per engine; a new label name costs two fsyncs and one rename per
  engine once (strace of a 16-shard store: light 208 fsyncs both before and
  after, full 304 / 304, close 336 / 336) (SONNY-6491).
- `free.store` stores the bitmap's `usize` words byte for byte and records
  no writer layout, so a big-endian or 32-bit host misread files from a
  64-bit little-endian host (and wrote files such a host would misread).
  Those hosts now refuse the layout (`error.UnsupportedHostLayout` from
  `FreeSpaceManager.serialize` / `deserializeBounded` and `FreeStore`), and
  the engine writes an empty `free.store` there and rebuilds the bitmaps at
  open. 64-bit little-endian hosts read and write the same bytes as before.
  `docs/format-spec.md` §10.3 documents the layout and the limitation; the
  stale NodeRec layout in §2.1 (40 bytes, `label_set`) is corrected to the
  48-byte record, and the unrecoverable `removeEdge` case of <= 0.4.11
  encrypted stores is documented (SONNY-6470).
- CI runs `test-leverb-clean-restart` (Lever B: derived indexes load on a
  clean restart, are reconciled or rebuilt after a crash) in its own job; it
  was in no CI job. The advisory `benchmark-regression` job compares against
  the last successful default-branch run's `current-ci.json` artifact
  instead of the committed `ci-baseline.json`, whose workstation numbers
  (1K `label_scan_ns` p50 0.146 ns, `mixed_ops_sec` 486) fail any CI build;
  that file is now only the fallback, and `benchmarks/results/README.md`
  says how to regenerate it (SONNY-6470).

## [0.4.13] - 2026-11-13

### Changed

- The plaintext page checksum (CRC32C, on every buffer-pool miss and flush)
  uses the CPU's CRC32C instruction: SSE4.2 `crc32` on x86_64, `crc32c*` on
  aarch64 with the CRC extension. It is chosen at compile time when the
  target CPU has it and otherwise after a run-time check (CPUID; AT_HWCAP on
  aarch64 Linux); Debug builds of a target without SSE4.2 (Zig's self-hosted
  x86_64 backend cannot assemble it) and other CPUs keep the table. Values
  are unchanged. `zig build bench-checksum -Doptimize=ReleaseFast` on an
  x86_64 host: 15583 to 751 ns per 8 KiB page; a cached plaintext
  `Pager.readPage` 16773 to 2020 ns (encrypted: about 4000 ns)
  (SONNY-6461).

### Added

- `GraphEngine.repairAdjTailEntries(allocator)` restores the adjacency
  entries that stores encrypted by graph_storage <= 0.4.11 lost to the
  AES-GCM tag tail (SONNY-6441): the last slot of every full chain block
  whose format reaches the tail at the store's page size. Each such entry is
  matched by edge id to the same edge in the other direction (`in_idx`, or
  the legacy `adj_in`), its lost fields are copied back and WAL-logged, and
  the derived edge indexes are rebuilt when outgoing entries change. It is
  idempotent, returns at once on a plaintext store, and lists every entry it
  cannot restore with the reason (`no_mirror`, `mirror_in_tail`,
  `prop_head_not_mirrored`, `wide_head_in_narrow_entry`). The layout
  knowledge is public as `edge.legacyTailLoss` (SONNY-6461).
- `free_space.FreeStore` reads a graph's `free.store` without an engine or
  buffer pool, so offline tools can skip freed pages, and
  `FreeSpaceManager.initDetached` builds a manager without a buffer pool
  (`FreeSpaceManager.buffer_pool` is now optional; it was never read).
  `docs/format-spec.md` §10.3 documents the file and that a node delete is
  recorded only in `NodeRec.flags` (SONNY-6461).

### Fixed

- The 0.4.12 entry and its commit named only the v3 adjacency entry at
  4 KiB. A full v1 chain block at 8 KiB (geode's page size) also reached the
  tail: entry 338 lost `rel_type` and `prop_head`. At 32 KiB the v1 entry
  1362 lost the same and the v3 entry 817 lost `public_id` and the high half
  of `prop_head`; at 64 KiB the v3 entry 1636 lost the high half of
  `prop_head`. The 0.4.12 entry is corrected and `docs/format-spec.md` lists
  every store (SONNY-6461).
- `compare-bench` fails a gating median (p50) that has no baseline or no
  current value and prints "no baseline" / "no current" for it. A zero or
  missing baseline used to give a 0% delta and PASS, so any current value
  passed; a zero current value of a lower-is-better metric read as a gain.
  Informational metrics still never fail, and the benchmark CI jobs stay
  advisory (SONNY-6461).
- `docs/operations.md` documents the upgrade of an encrypted store written by
  <= 0.4.11: close the old binary cleanly first. Crash recovery under a newer
  binary replays the old binary's page images verbatim, tag bytes in their
  last 16 bytes included, and cannot tell them from images logged by 0.4.12+
  (no writer version in the page, the WAL record or the manifest), whose
  last 16 bytes may hold a committed record, so it does not zero them
  (SONNY-6461).

## [0.4.12] - 2026-11-12

### Changed

- wal v0.1.23 (compaction keeps the LSN anchor when it empties the log,
  SONNY-6424). On-disk note: encrypted (TDE) pages written by this version
  use a new page format; older binaries fail with `DecryptionFailed` on them
  (no downgrade for encrypted stores).

### Fixed

- Committed records are no longer lost on stores with at-rest encryption.
  The pager wrote the 16-byte AES-GCM tag over the last 16 bytes of every
  page body, and layouts that use the page end lost those bytes on every
  write and reload (eviction, reopen, crash recovery), silently because the
  page still authenticated: with the default 8 KiB page every node in slot
  169 of 170 read back missing or with tag bytes in its flags; the last two
  heads of every `adj_in_dir` page and the last entry of a full adjacency
  chain block were damaged too (v1 at 8 and 32 KiB, v3 at 4, 32 and 64 KiB;
  corrected by SONNY-6461, which first listed only v3 at 4 KiB). Encrypted pages are now written in a
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
  `AnnotateIgnoreReadsBegin/End`: the new TSan step reproduces the 49
  reports of that kind (geode's parallel-union step showed ~30) and now
  reports none. New steps `test-buffer-pool-concurrent-readers` (also under
  `test-integration`) and `test-buffer-pool-concurrent-readers-tsan`
  (SONNY-6438).
- `compare-bench` gates each measurement on its median (p50) and reports
  avg/p95/p99/stddev for information. With scale-bench's three samples per
  tier one slow sample failed identical code (HEAD against HEAD: 8-10
  failing rows). `benchmarks/results/ci-10k-baseline.json` is re-recorded at
  ff9d97f: the old one (2026-03-25) was recorded where fsync is free
  (2,012,554 mixed ops/s with a WAL fsync on 15% of them); its own code
  measures ~260 mixed ops/s on a real disk. The manual
  `benchmark-regression-10k` CI job is advisory (`allow_failure: true`, like
  `benchmark-regression`) and keeps its artifact on failure, so it no longer
  leaves default-branch pipelines blocked or skips the security and SBOM
  stages (SONNY-6438).

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

[Unreleased]: https://gitlab.com/devnw/zig/graph-storage/-/compare/v0.4.14...HEAD
[0.4.14]: https://gitlab.com/devnw/zig/graph-storage/-/compare/v0.4.13...v0.4.14
[0.4.13]: https://gitlab.com/devnw/zig/graph-storage/-/compare/v0.4.12...v0.4.13
[0.4.12]: https://gitlab.com/devnw/zig/graph-storage/-/compare/v0.4.11...v0.4.12
[0.4.11]: https://gitlab.com/devnw/zig/graph-storage/-/compare/v0.4.10...v0.4.11
[0.4.3]: https://gitlab.com/devnw/zig/graph-storage/-/compare/v0.4.2...v0.4.3
[0.4.2]: https://gitlab.com/devnw/zig/graph-storage/-/compare/v0.4.1...v0.4.2
[0.4.1]: https://gitlab.com/devnw/zig/graph-storage/-/compare/v0.4.0...v0.4.1
[0.2.1]: https://gitlab.com/devnw/zig/graph-storage/-/compare/v0.2.0...v0.2.1
[0.2.0]: https://gitlab.com/devnw/zig/graph-storage/-/releases/v0.2.0
[0.1.0]: https://gitlab.com/devnw/zig/graph-storage/-/releases/v0.1.0
