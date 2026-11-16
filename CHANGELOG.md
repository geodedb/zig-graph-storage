# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Crash recovery left the WAL tail it replayed on disk: it advanced
  `last_checkpoint_lsn` past every record in both manifests but never
  truncated the file, and the engine opens clean, so the tail stayed until
  the shard was next written and checkpointed (geode
  `test-sonny6595-wal-drain`). Recovery now fsyncs the graph directory
  after the manifest renames and then truncates the WAL to the advanced
  frontier; its clean path drains a log that only holds records at or below
  the frontier (a crash between those steps, or a store left by <= 0.4.21).
  The log is kept when it holds cross-shard 2PC records, which the sharded
  reconcile reads from LSN 0 after every shard has opened, or a record that
  does not decode. `Metrics.recovery_wal_truncated` reports it (SONNY-6599).
- Deleting an already-deleted node decremented `node_count` again
  (SONNY-6558).
- `removeEdgeTxn` removed only the co-located in-entry, so an edge added
  through the legacy `addEdgeTxn` kept its `adj_in` entry and
  `GraphEngine.expandIn` still returned it, also after a crash. The legacy
  entry is now removed, WAL-imaged and restored by an abort (SONNY-6558).
- `resolveTailAffectedNodeIds` returned null (a full external rebuild)
  whenever the WAL tail touched an edge-property slab chain. Edge chains
  are now recognised from the tail's adjacency pages and from the reverse
  map, which records edge chains too (snapshot `GSRVIX2`; version 1 files
  are still read, and older binaries reject version 2 and rebuild)
  (SONNY-6558).
- An abort failed closed (`AbortNotUndone`) after a property write that
  replaced or removed a value stored in an overflow chain. The chain is now
  freed when the transaction commits, so the abort restores the old stub
  with its value intact (SONNY-6558).
- The interface's iterator wrappers leaked the slice or concrete iterator
  they own, and left a page pinned, when boxing their state ran out of
  memory (SONNY-6558).
- `labels.dict` holding fewer names than the manifest recorded was reported
  only through `std.log`; it is now also counted in
  `Metrics.label_names_lost` and sent to `GraphConfig.log_fn` (SONNY-6558).

### Changed

- `TxnManager` documents its single-writer contract: `txn_id_mutex` guards
  only the id counter (SONNY-6558).
- `docs/operations.md`: the Transactions example uses the current API.
- `benchmarks/results/ci-baseline.json` regenerated (its `label_scan` median
  of 0.15 ns failed every comparison) (SONNY-6558).

## [0.4.21] - 2026-11-15

### Fixed

- Two flushes of one frame could land out of order: a frame dirtied again
  while a flush's write of it was in flight could be copied and written by
  a second flush (`flushDirty`, `flushDirtyPages`, a sequential `flushAll`)
  ahead of the first, which then landed the older copy: the page read clean
  with the older image on disk. A flush now waits for a frame's write in
  flight before it copies the frame (`writeFrameBytes`), and a parallel
  `flushAll` waits for every write in flight before it selects, so writes of
  a frame land in copy order (SONNY-6632).
- `flushAll` and `flushDirty` returned while another flush's write was
  still in flight: that frame was already clean, so they skipped it, and a
  checkpoint could truncate the WAL before the page's new image was on
  disk. They now wait for every write in flight
  (`BufferPool.writes_in_flight_total`): before selecting, and for the
  sequential paths again after the pass (SONNY-6632).

## [0.4.20] - 2026-11-15

### Security

- **Topology snapshots sealed under at-rest encryption (SONNY-6616).**
  `edges.idx` and `edges_exist.idx` hold one record per relationship (edge
  id, source, target, relationship-type id; `edges.idx` also the
  property-chain head and public id): the graph's complete topology, in
  plaintext next to the encrypted adjacency pages. Under a key they are now
  sealed (`side_file_crypto` kinds `edge_index`, `edge_exist_index`) and
  decrypted into memory at load instead of memory-mapped (O(file) at open,
  resident). A plaintext one (0.4.17 wrote them so) is emptied when read and
  rebuilt sealed; one that fails authentication is rebuilt. No manifest
  change: 0.4.17 rebuilds a sealed snapshot it cannot read.
- **A wrong key is `error.EncryptionKeyMismatch` (SONNY-6616).** When no
  manifest slot authenticates under the configured key and at least one
  failed its HMAC, the open fails with `EncryptionKeyMismatch` (another
  key, no key at write time, or modified manifests: the HMAC cannot tell
  them apart); it failed with `NoManifest`, which reads as a missing store.
  Absent manifests are still `NoManifest`. Callers matching `NoManifest`
  for these cases must match the new error. New `Manifest.readSelected`.
- **The WAL is never truncated for being unreadable (SONNY-6622).** wal
  v0.1.24 refuses, and leaves untouched, a log it cannot decode instead of
  truncating it. `WalManager.init` maps `WalAuthFailed` and
  `WalEncryptionMismatch` (records of another key, or plaintext records in
  an encrypted store) to `EncryptionKeyMismatch`; `WalCorrupted` (a bad
  record with valid records after it) stays as itself. A checkpoint whose
  compaction wal refuses completes: the log keeps its records, stays
  usable, and the refusal is counted (`WalManager.compactions_refused`) and
  logged.
- **`VerifyTool` no longer wipes encrypted WALs (SONNY-6622).** It opened
  `wal/graph.wal` through `WalManager.init` on the store's directory,
  without the at-rest key it was given and through a modifying open; on
  wal <= 0.1.23 an encrypted log read as a torn tail and was truncated to
  nothing, so an integrity check deleted every un-checkpointed commit. It
  now opens the store's WAL read-only, copies it into a private temporary
  directory ($TMPDIR or /tmp, files 0600, removed afterwards) and validates
  the copy under the key.

### Changed

- wal v0.1.25 (fail-closed recovery, compaction and `truncateAfter`;
  v0.1.24 introduced the first two) and thread_pool v0.2.11 (the version
  wal pins). The thread_pool v0.2.9 copy that
  otel's chain brings is unchanged (pre-existing diamond).

### Added

- `side_file_crypto.Kind` is non-exhaustive: 1..127 graph-storage's,
  128..255 the consumer's (`Kind.consumer(n)`, `Kind.isLibrary`), so a
  consumer seals its own files without borrowing a library kind. Header
  byte unchanged (SONNY-6616).
- `GraphRegistry.saveToFileWith` / `loadFromFileWith` and
  `registry.SEAL_UUID`: the registry (graph names) sealed under a key;
  `loadFromFile` refuses a sealed registry with `SideFileEncrypted`
  (SONNY-6616).
- `sorted_index_snapshot.writeAtomicReplaceSealed`, `loadSealed`,
  `restampSealed` (SONNY-6616).
- `zig build test-tde-residuals` (also under `test-integration`)
  (SONNY-6616).
- `zig build test-wal-fail-closed` (also under `test-integration`)
  (SONNY-6622).

## [0.4.18] - 2026-11-15

### Added

- `BufferPool.pageNewerThanDisk(file_id, page_id)` and
  `PageFrame.newerThanDisk()` (caller holds the pool mutex): whether a
  page's bytes on disk may be older than the pool's copy, so a reader that
  reads pages straight from the pager must read this one through the pool.
  True while the frame is dirty and while a flush's write of it is in
  flight (`PageFrame.writes_in_flight`) (SONNY-6605).

### Fixed

- A flush (`flushAllParallel`, and `writeFrameBytes` under `flushAll`,
  `flushDirty`, `flushDirtyPages` and a dirty eviction) clears a frame's
  `dirty` flag when it copies the frame, then writes the copy with the pool
  mutex dropped; in a parallel flush the frames of later waves wait for
  their wave with the flag already clear. A reader that read pages straight
  from disk and asked the pool which pages were dirty read the older disk
  image in that window (geode's hydration scan quarantined a healthy graph
  as `DataCorruption`, and hydrated an old property value: SONNY-6597). The
  frame now counts the flushes whose write of it has not landed, from the
  copy until the write is done or has failed, and `newerThanDisk` reports
  it. `dirty` is cleared where it was, so flush selection and eviction are
  unchanged (SONNY-6605).

## [0.4.17] - 2026-11-15

### Security

- **On-disk format change.** Under at-rest encryption
  (`GraphConfig.encryption_key`) the side files that hold schema names or
  indexed values are sealed with AES-256-GCM (SONNY-6590): `labels.dict`
  (label and relationship-type names, every shard), `props.idx`
  (property-key names, value hashes), `ordered_propidx.snap` (property-key
  names and the indexed values), `props.catalog` (key names of declared
  indexes) and `propidx_*.btree`. They used to be written in plaintext next
  to the encrypted pages and WAL. Key: HKDF-SHA256 of the configured key;
  nonce: 96 random bits per write; associated data: envelope header, the
  graph's (shard's) uuid and the file name, so a file copied from another
  graph, shard or file fails authentication (`docs/format-spec.md` §1.6).
  A sealed side file that fails authentication refuses the open
  (`error.SideFileAuthFailed`) instead of being adopted — a foreign
  `labels.dict` used to remap every label id silently; derived snapshots
  that fail are rebuilt. Opening without the key fails with
  `error.SideFileEncrypted`.
- **Manifest format_version 5** (same layout as 4) marks a store under a key
  whose side files are sealed; from then on a plaintext side file is refused
  (`error.SideFileNotSealed`). Stores without a key stay at 4. A store
  written by <= 0.4.16 under a key is upgraded at open (stale
  `labels.dict.tmp` removed, `labels.dict` / `ordered_propidx.snap` /
  `props.catalog` / `propidx_*.btree` rewritten sealed, plaintext
  `props.idx` emptied and rebuilt) and the next checkpoint or `close()`
  writes 5; a crash at any step reopens and resumes. graph_storage <= 0.4.16
  refuses a sealed store (`error.IncompatibleVersion` on the manifest,
  `error.InvalidData` on `labels.dict`). Plaintext copies in older backups
  and freed disk blocks are not scrubbed (`docs/operations.md`).

### Added

- `side_file_crypto` (`Cipher`, `ReadPolicy`, `Kind`, `isSealed`,
  `UpgradeStep` test fault points), `manifest.MANIFEST_VERSION_SEALED_SIDE_FILES`,
  `LabelDictionary.saveToFileWith` / `loadFromFileWith`,
  `PropertyChainIndex.saveToFileWith` / `loadFromFileWith`,
  `OrderedPropertyIndex.saveToFileWith` / `loadFromFileWith`,
  `IndexCatalog.saveToFileWith` / `loadFromFileWith`,
  `BPlusTree.saveToFileWith` / `loadFromFileWith`,
  `index_snapshot.loadPayloadWith` / `restampSealed` /
  `SnapshotWriter.finalizeWith` / `finish` (SONNY-6590).
- `zig build test-tde-schema-names` (also under `test-integration`): every
  file of single and sharded encrypted stores is scanned for schema names
  and indexed values after close, crash and reopen; upgrade with a crash at
  each step; tampered, foreign and keyless opens; sealed shard dictionary
  reconciliation (SONNY-6590).

### Changed

- `ordered_propidx.snap`, `props.catalog` and `propidx_*.btree` are written
  atomically (temp file, fsync, rename) with or without a key; they were
  truncated and rewritten in place without an fsync, so a crash mid-save
  could leave a torn file (an unreadable ordered snapshot drops every
  ordered-index registration at the next open) (SONNY-6590).
- `LabelDictionary.loadFromFile` reads the whole file and refuses an entry
  whose declared name length exceeds the bytes left before allocating it
  (a corrupt length used to allocate up to 4 GiB first) (SONNY-6590).
- Under a key, the checkpoint restamp of a clean `props.idx` re-seals the
  file (O(file)) instead of patching the stamp in place (SONNY-6590).

## [0.4.16] - 2026-11-14

### Added

- `GraphConfig.label_dict_report` (`LabelDictReport`: ctx + callback) and
  `LabelDictDiagnostic`: `ShardedGraphEngine.open` and `getOrAssignLabel`
  hand every shard label-dictionary finding to the caller as a structured
  value — kind (`id_in_use_diverged`, `rewritten`, `name_id_conflict`,
  `id_name_conflict`), action (`refused`, `renamed_from_shard0`,
  `rewritten`, `rewritten_in_memory`), shard, id, the shard's and shard 0's
  names, node/edge/index counts and name counts — so the detail survives a
  release build whose `log_level` drops `std.log.warn`. Default null; the
  warnings are unchanged (SONNY-6527).
- `GraphEngine.setEdgePropertyTxn` (an edge property write inside the
  caller's transaction, undone by `abortTxn`), `GraphConfig.abort_undo`
  (`AbortUndoPolicy`: `.fail_closed`, default, or `.keep_writes`),
  `error.AbortNotUndone`, `Metrics.txn_aborts_undone` /
  `txn_aborts_not_undone`, `GraphEngine.idStride`, `TxnManager.journal` /
  `takeJournal`, `PropStore.slabBlobCopy` / `restoreSlabBlob` /
  `retireSlabChain`, and `GraphEngine.logPage` / `logTouchedAdj` /
  `nodePageId` / `markDirty` made public for the engine's sibling modules
  (consumers keep using `logPagePublic`) (SONNY-6529).
- `AdjStore.forEachEdgeIdOnPage` and `zig build bench-edge-prop-set
  [-- <dir>]` (ns and WAL bytes per head-moving edge property set)
  (SONNY-6529).

### Changed

- `GraphEngine.abortTxn` undoes the transaction's writes (SONNY-6529). It
  used to drop the transaction's WAL records only: the pages it had written
  stayed modified and the slots, counts and ids it had taken stayed taken,
  so readers saw the aborted writes and the next checkpoint made them
  durable. Every engine write now records its inverse (node create, node
  update of `prop_head`/`flags`/`txn_stamp`, node delete, label add/remove,
  properties on new or transaction-created chains, property put/remove on
  an existing slab chain (its bytes are copied first and written back),
  edge add/remove, first edge property); the abort applies them in reverse
  through the engine,
  logs their images in the aborting transaction and ends it with COMMIT, so
  it is crash-safe (a crash before that record recovers the pre-transaction
  state). The auto-commit wrappers undo a failed write the same way, in
  memory only (allocation-free for property writes, so it completes under
  the out-of-memory that failed the write). A transaction the engine cannot
  undo exactly (a property change on a pre-existing legacy chain or one
  that freed an overflow value, a chain pointer of an existing node changed
  through
  `putNodeTxn`, a page imaged with `logPagePublic`/`zeroPageLogged`, more
  than 1,048,576 writes) fails closed by default: `abortTxn` returns
  `error.AbortNotUndone` and every later write, commit and checkpoint on
  that engine fails the same way until it is reopened (`close` syncs the WAL
  and skips its checkpoint). `abort_undo = .keep_writes` keeps the old
  behaviour for those. No on-disk format change. `test-txn-abort-undo`
  (also under `test-integration`). See "Transactions" in
  docs/operations.md.
- `GraphEngine.persistence_dirty` is a `std.atomic.Value(bool)` (was
  `bool`); read it with the new `GraphEngine.isPersistenceDirty()`. A
  checkpoint now takes the flag when it starts and puts it back when it
  fails, so a write that lands during a checkpoint is persisted by the next
  one instead of being forgotten (SONNY-6527).
- `GraphEngine.setEdgeProperty` no longer WAL-images the source's node
  page (it does not change). A head-moving set logs the property, `.adj_out`
  and `.in_idx` pages only: 24,826 instead of 33,068 WAL bytes and 72 instead
  of 122 µs per set at the default 8 KiB page in deferred sync
  (`bench-edge-prop-set`, median of 7 x 2,000 sets on ext4/NVMe, same
  binary). Consumers that rewrite `prop_head` in place themselves (geode's
  `publishEdgePropHead`) may drop that image too; see "Pages a consumer
  must image" in docs/operations.md (SONNY-6529).

### Fixed

- Data race: `ShardedGraphEngine.getOrAssignLabel` records a new name on
  shards 1..N-1 from worker threads, and each shard set its plain-`bool`
  `persistence_dirty` there while the caller's writers could be setting it
  on the same shard under per-shard locks (TSan:
  `markDirty` from `assignLabelId` vs `putNodeTxn`). The flag is atomic
  now; `test-label-dict-shards-tsan` covers it (SONNY-6527).
- The first-access WAL-tail reconcile of the derived indexes ignored
  `.adj_out` pages: an edge whose `prop_head` was rewritten in place in a
  transaction that imaged the adjacency page but not the source's node
  page kept its checkpoint-era `prop_head` in the edge index after a crash,
  and its committed property was unreachable. The reconcile now resolves
  every entry of a tail `.adj_out` page to its source node through the
  loaded edge index and re-derives that node; the result is key-for-key
  what a full rebuild gives. `test-edge-prop-crash` (also under
  `test-integration`) (SONNY-6529).
- `LabelDictionary.getOrAssign` computed `next_id = id + 1` without a
  bound: at `maxInt(u32)` a safe build panicked and a release build wrapped
  to 0 and handed out ids already in use. A new name now fails with
  `error.LabelIdSpaceExhausted` once ids 0..maxInt(u32)-1 are used (the
  range `assignId` already enforced) and the dictionary is unchanged; it
  reaches callers through `GraphEngine.getOrAssignLabel` and
  `ShardedGraphEngine.getOrAssignLabel`. `loadFromFile` overflowed the same
  way on a stored id of `maxInt(u32)`; it now loads such a file and assigns
  no further ids (SONNY-6527).

## [0.4.15] - 2026-11-13

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

[Unreleased]: https://gitlab.com/devnw/zig/graph-storage/-/compare/v0.4.21...HEAD
[0.4.21]: https://gitlab.com/devnw/zig/graph-storage/-/compare/v0.4.20...v0.4.21
[0.4.20]: https://gitlab.com/devnw/zig/graph-storage/-/compare/v0.4.18...v0.4.20
[0.4.18]: https://gitlab.com/devnw/zig/graph-storage/-/compare/v0.4.17...v0.4.18
[0.4.17]: https://gitlab.com/devnw/zig/graph-storage/-/compare/v0.4.16...v0.4.17
[0.4.16]: https://gitlab.com/devnw/zig/graph-storage/-/compare/v0.4.15...v0.4.16
[0.4.15]: https://gitlab.com/devnw/zig/graph-storage/-/compare/v0.4.14...v0.4.15
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
