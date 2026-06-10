# Audit Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Every code task is TDD: write a failing test, confirm it fails, implement the minimal fix, confirm green, run `zig fmt`, then it is committed by the orchestrator.

**Goal:** Close every actionable finding from the 2026-06-10 full audit (codepros:audit) and appsec review (security:appsec-review) of the Zig graph-storage library — security, performance, quality, and feature gaps — with regression tests for each.

**Architecture:** Surgical, backward-compatible fixes layered onto the existing single-writer page-store engine. On-disk format changes (snapshot checksums, manifest HMAC) are additive and versioned. Each fix carries a failing-first regression test. Work is sequenced into waves by file ownership so independent files can be fixed in parallel without merge conflicts.

**Tech Stack:** Zig 0.16.0, `zig build` / `zig build test` / `zig build test-integration` / `zig build test-fuzz-regression` / `zig build test-cross-shard-recovery` / `zig build test-integration-sharded`, `zig fmt`.

**Canonical verification (run after every task):**

```bash
zig fmt --check src/ build.zig tests/ benchmarks/ examples/
zig build check
zig build test --summary all
```

Integration/sharded/fuzz suites run after any wave touching recovery, sharding, backup, or WAL.

**Build-mode note:** Production runs `ReleaseFast` (safety checks off). Untrusted-length parsing bugs are therefore memory-safety issues, not just panics — every disk-derived length/count/union access must be validated *before* use, and tests must pass under `-Doptimize=ReleaseSafe` as well as Debug.

---

## Wave 1 — Untrusted-input bounds & integrity (parallel; distinct files)

These are surgical "validate before use" fixes on the filesystem trust boundary. Each touches a distinct file set, safe to run concurrently.

### Task 1.1: SEC-0040 — var_store `data_len` OOB read (HIGH, #129)

**Files:** Modify `src/var_store.zig` (`read`, ~line 119-123); Test: same file's test block.

- [ ] Write failing test: build a `var_store` page directly (via buffer pool `pinNew(.var_store, pid)`) with `data_len` set to `dataCapacity()+1` (and another at `0xFFFFFFFF`), then call `read`; expect `error.DataCorruption`. Test must also pass under ReleaseSafe.
- [ ] Confirm it fails (currently slices OOB / panics).
- [ ] Fix: in `read`, after reading `data_len` (line 119), add `if (data_len > self.dataCapacity()) return error.DataCorruption;` before the slice at line 122. Ensure `result` is freed on the error path (errdefer already present).
- [ ] Confirm green; `zig fmt`.

### Task 1.2: SEC-0039 — prop_store `dir_count` underflow → OOB (HIGH, #128)

**Files:** Modify `src/prop_store.zig` (`getProperty` ~line 160; `readDirCount`/`readDirEntry` helpers ~line 56-72). Test: same file.

- [ ] Write failing test: craft a props page with `dir_count = 0xFFFF` (and a value that makes `(idx+1)*DIR_ENTRY_SIZE` exceed `data.len - DIR_COUNT_SIZE`); call `getProperty`; expect `error.DataCorruption` (not panic/OOB). Pass under ReleaseSafe.
- [ ] Confirm fail.
- [ ] Fix: before the dir-scan loop in `getProperty` (and any other reader of dir entries — `findAndRemoveKey`, `insertEntry`, `removeProperty` if they read `dir_count`), validate `dirOverhead(dir_count) + PROP_DATA_OFFSET <= data.len` i.e. `dir_count <= (data.len - DIR_COUNT_SIZE - PROP_DATA_OFFSET) / DIR_ENTRY_SIZE`; return `error.DataCorruption` otherwise. Mirror the existing `readEntryCountChecked` pattern; add a `readDirCountChecked(data) !u16` helper and route all callers through it.
- [ ] Confirm green; `zig fmt`.

### Task 1.3: SEC-0042 — adj_store + prop iterator missing hop/cycle guards (MEDIUM, #130)

**Files:** Modify `src/adj_store.zig` (`removeEdge` ~120, `AdjEdgeIterator.next` ~163, `updateEdgePropHead` ~214, `edgeCount` ~248), `src/prop_store.zig` (`PropIterator.next` ~249). Test: both files.

- [ ] Write failing tests: build a self-referential `next_block` adjacency chain (A→A) and a circular prop-page chain; call each traversal entry point; expect `error.CircularChainDetected` rather than a hang. (Bound test runtime so a regression hangs the suite visibly, e.g. wrap with the same `max_hops` value being asserted.)
- [ ] Confirm fail (currently loops forever).
- [ ] Fix: add a `MAX_CHAIN_HOPS` constant (reuse the prop_store/var_store value, `100_000`; consider a shared `const MAX_CHAIN_HOPS` in a common module) and a hop counter to each unguarded `while (current_page != 0)` / `while (next_block != 0)` loop in adj_store and to `PropIterator.next`; return `error.CircularChainDetected` when exceeded.
- [ ] Confirm green; `zig fmt`.

### Task 1.4: SEC-0047 — shard manifest JSON unchecked union access (HIGH, #140)

**Files:** Modify `src/shard_manifest.zig` (`readFromDir`, lines 87-117). Test: same file.

- [ ] Write failing tests: write malformed `shard_manifest.json` files — non-object root (`"5"`, `"[]"`), missing `version`, string-typed `version`, negative integer, `>2^32` integer, non-array `per_shard_uuids`, non-string array element — and assert each returns a clean error (e.g. `error.InvalidShardManifest`), never a panic. Run under ReleaseSafe.
- [ ] Confirm fail (currently `parsed.value.object` / `.get(..).?.integer` panic).
- [ ] Fix: replace the dynamic `std.json.Value` accesses with tag-and-range guards (or parse into a typed struct). For each field: check `root_v == .object`; `root.get(key) orelse return error.InvalidShardManifest`; check the node tag is `.integer` and the value is in `[0, maxInt(u32)]` before `@intCast`; check `per_shard_uuids` is `.array`; check each element is `.string`. Keep the existing value checks (version/shard_count/algorithm_hash equality) after the type guards. Preserve the `number_string` fallback for `algorithm_hash`.
- [ ] Confirm green (existing round-trip + wrong-hash tests still pass); `zig fmt`.

### Task 1.5: SEC-0050 — labels.dict duplicate-key aliasing + verify-after-materialize (LOW→MED, #143)

**Files:** Modify `src/label_dict.zig` (`loadFromFile`, ~line 123-147; `deinit` ~23-31). Test: same file.

- [ ] Write failing tests: craft a `labels.dict` with (a) two identical names, (b) two distinct names sharing one id; assert `error.InvalidData` and no leak (std.testing.allocator catches leaks). Also a byte-flipped file asserting `error.ChecksumMismatch` with no retained partial state.
- [ ] Confirm fail (dup name leaks; dup id risks double-free).
- [ ] Fix: in the load loop use `getOrPut` on both maps; on `found_existing` for either name or id, free `owned` and return `error.InvalidData`. Keep the single-owner aliasing invariant (one buffer owned via `name_to_id` key) and document it. Optionally verify CRC over the raw bytes in a first pass before building maps.
- [ ] Confirm green; `zig fmt`.

### Task 1.6: SEC-0044 + SEC-0048 + SEC-0051 — index snapshot integrity & bounded counts (MEDIUM/LOW, #133/#142/#144)

**Files:** Modify `src/index_snapshot.zig` (header format + `loadHeader`/writers), `src/engine_index.zig` (edge index load ~241), `src/property_chain_index.zig` (~222-229), `src/label_index.zig` (~204-211). Test: each file.

- [ ] Write failing tests: (a) craft each `.idx`/snapshot with a tiny payload but huge `item_count`/`entry_count`/`node_count`; assert `error.InvalidFormat` and that no multi-GB reservation occurs (use a counting/failing test allocator capped well below the claimed size). (b) Round-trip a snapshot, flip one payload byte while keeping the checkpoint counter, assert the loader rejects it (checksum) and the caller rebuilds.
- [ ] Confirm fail.
- [ ] Fix part A (SEC-0048/0044): before every `ensureTotalCapacity(count)`, bound `count <= payload_remaining / min_record_size` and return `error.InvalidFormat` otherwise. Apply at engine_index edge load, property_chain_index per-chain `entry_count`, label_index `node_count`, and the root `loadHeader.item_count`.
- [ ] Fix part B (SEC-0051): extend the snapshot header to carry a CRC32C over the payload (additive, bump the snapshot magic/version); compute on write, verify on load; on mismatch return an error that the caller treats as "snapshot invalid → rebuild". Keep `checkpoint_counter` gating.
- [ ] Confirm green (existing load/rebuild tests pass; new corrupt-snapshot test rebuilds); `zig fmt`. Run `zig build test-integration`.

---

## Wave 2 — Crypto, backup, recovery integrity (sequential within file groups)

### Task 2.1: SEC-0037 — AES-GCM nonce reuse via stale in-memory write_count (CRITICAL, #115)

**Files:** Modify `src/buffer_pool.zig` (`flushFrame` ~446-451, `flushChunkFn` ~590), `src/pager.zig` (`writePage` ~79-85). Test: `src/pager.zig` / `src/buffer_pool.zig` / an integration test.

- [ ] Write failing test: flush the *same cached frame* twice across two checkpoints WITHOUT manually poking `write_count` (the current SEC-0015 test cheats by setting it). Capture the on-disk nonce/write_count both times; assert it strictly increases (distinct nonces). Add a recovery test: write page (wc=N), simulate crash before checkpoint, replay WAL, assert post-replay on-disk `write_count` ≥ N (no regression).
- [ ] Confirm fail (nonce repeats because the live frame's write_count is never advanced).
- [ ] Fix: make `write_count` a monotonic property of the persisted page advanced in the live frame on every flush. In the flush path, after `pager.writePage` computes `new_wc`, write `new_wc` back into the frame's buffer (`page_mod.writeWriteCount(frame.dataSlice(), new_wc)`) under the pool mutex — OR maintain a per-`(file_id,page_id)` monotonic counter independent of the zeroable buffer and source the nonce from it. Ensure the WAL-replay path (`recovery.zig:221` `pinNew` then copy) does not regress the counter (seed the frame's write_count from the on-disk page when higher).
- [ ] Confirm green; run full `zig build test`, `test-integration`, `test-cross-shard-recovery`. `zig fmt`.
- [ ] Add a note: this is a live correctness bug (ordinary checkpoint cycling), so the SECURITY_GAP_ANALYSIS immediate-action (key rotation / re-encrypt for affected data) stands — record in the issue, not code.

### Task 2.2: SEC-0038 + SEC-0049 — backup restore verify-before-extract + symlink-safe writes (HIGH/MEDIUM, #117/#141)

**Files:** Modify `src/backup.zig` (`restoreBackupResult` ~251-354, extract loop 291-320, integrity check 322-339). Test: same file + `tests/integration.zig`.

- [ ] Write failing tests: (a) a V2 archive whose HMAC is wrong but whose entries are well-formed; assert restore returns `error.HmacMismatch` AND the target directory is unchanged (no poisoned `nodes.store`). (b) Pre-plant a symlink at `target_dir/nodes.store` → outside path; assert restore errors and the link target is untouched.
- [ ] Confirm fail (files written before HMAC; symlink followed).
- [ ] Fix: restructure restore to verify-then-extract — either (preferred) two-pass: first pass authenticates the whole archive (CRC + HMAC) without writing; second pass extracts; or extract into a freshly-created staging temp dir, verify, then atomically rename into place. For extraction, create files relative to a held `target` `Dir` handle with `.exclusive = true` and `.resolve_beneath = true` (refuses pre-existing symlinks and path escape). Keep `isValidBackupFilename`.
- [ ] Confirm green; run `zig build test`, `test-integration`. `zig fmt`.

### Task 2.3: SEC-0041 + PERF-0053 — 2PC recovery strict, streaming WAL read (HIGH/P2, #118/#113)

**Files:** Modify `src/sharded_recovery.zig` (~53, ~98 `readFrom`), `src/wal.zig` (add a strict streaming reader if needed alongside `forEachFromStrict`). Test: `tests/cross_shard_recovery.zig`.

- [ ] Write failing tests: (a) inject a WAL record with a bad checksum into a shard's WAL, run sharded recovery; assert it fails closed (not silently skipped). (b) Inject a crafted `cross_shard_prepare`+`cross_shard_commit` with a bad checksum; assert recovery does NOT forge the edge. (c) A large-tail recovery asserting bounded memory (no full `readFrom` materialization) — at minimum assert correctness with a large WAL.
- [ ] Confirm fail (current `readFrom` does `deserialize catch continue`, never verifies checksum).
- [ ] Fix: replace both `eng.wal.readFrom(0, allocator)` calls with a checksum-verifying streaming walk (route through `forEachFromStrict` or a new `readFromStrict` callback) that fails closed on deserialize/checksum errors and only retains the small prepare/commit/abort maps in memory.
- [ ] Confirm green; run `test-cross-shard-recovery`, `test-integration-sharded`. `zig fmt`.

### Task 2.4: SEC-0043 — manifest authentication under TDE (MEDIUM, #132)

**Files:** Modify `src/manifest.zig` (serialize/deserialize ~76-95), wiring in `src/recovery.zig` / `src/engine_persist.zig` to pass the key. Test: `src/manifest.zig` + a recovery test.

- [ ] Write failing test (TDE enabled): write a manifest with a key configured, tamper a field and recompute the CRC32, attempt open/recovery; assert it is rejected with an authentication error. Non-TDE behavior (CRC32 only) unchanged — assert a plaintext round-trip still works.
- [ ] Confirm fail (CRC32 is recomputable; tamper accepted).
- [ ] Fix: when an encryption key is configured, append an HMAC-SHA256 (keyed) over the serialized manifest body and verify it on load (in addition to/instead of CRC32). Keep CRC32 as the integrity check in no-key mode. Version the manifest format additively if needed. Thread the key from config through to manifest read/write.
- [ ] Confirm green; run `zig build test`, `test-integration`. `zig fmt`.

### Task 2.5: SEC-0045 + SEC-0052 — pager key wipe + resolve_beneath hardening (LOW, #134/#145)

**Files:** Modify `src/file_manager.zig` (`deinit` ~106-119; create paths ~67), `src/graph_dir.zig` (~39), `src/manifest.zig`/`src/registry.zig`/`src/label_dict.zig` tmp-file creates. Test: `src/file_manager.zig`.

- [ ] Write failing test for SEC-0045: after `FileManager.deinit`, assert each pager's embedded `PageEncryption` key was zeroed (test via a hook or by checking `deinit` calls). At minimum a test that `deinit` iterates pagers and invokes `PageEncryption.deinit`.
- [ ] Confirm fail.
- [ ] Fix SEC-0045: in `FileManager.deinit`, before nulling the pagers array, iterate and `if (p.encryption) |*e| e.deinit();` (secureZero each copy).
- [ ] Fix SEC-0052 (hardening, no behavior change): set `.resolve_beneath = true` on `createFile`/`createDirPath` under the graph dir where the platform supports it; prefer creating relative to a held `Dir` handle. Guard for platforms lacking the flag.
- [ ] Confirm green; `zig fmt`.

### Task 2.6: SEC-0046 — untracked npm files (LOW, #135)

**Files:** Delete `package.json`, `package-lock.json`, `node_modules/` from the worktree; Modify `.gitignore`.

- [ ] Remove the files from the working tree.
- [ ] Add `node_modules/`, `package.json`, `package-lock.json` to `.gitignore`.
- [ ] Confirm `git status` is clean of these paths.

---

## Wave 3 — Quality bugs & contracts

### Task 3.1: QUAL-0042 — resource/FD leak on create/open error paths (HIGH, #124)

**Files:** Modify `src/engine.zig` (`create` ~209-220, `open` ~288-327), add a `cleanupSubsystems` helper. Test: `src/engine_test.zig` (fault injection).

- [ ] Write failing test: inject a failure after `initSubsystems` returns (e.g. force `label_dict.loadFromFile` or `rebuildDerivedIndexes` to error) and assert no leak under `std.testing.allocator` and no FD leak (`wal_dir_handle`).
- [ ] Confirm fail.
- [ ] Fix: add `errdefer self.cleanupSubsystems();` immediately after `initSubsystems` returns in both `create` and `open` (a partial of the existing cleanup excluding thread-pool/destroy), or reorder so fallible steps precede subsystem allocation. Verify deinit ordering.
- [ ] Confirm green; `zig fmt`.

### Task 3.2: QUAL-0041 — error-set coherence (HIGH, #121)

**Files:** Modify `src/errors.zig` (extend `StorageError`), `src/interface.zig` (vtable signatures), engine impl return types. Test: a compile-time/grep check + existing suite.

- [ ] Write failing test: a test that enumerates the ad-hoc errors returned across the codebase and asserts they are members of `StorageError` (or narrow a representative vtable method from `anyerror` to `StorageError!T` and confirm it compiles).
- [ ] Confirm fail.
- [ ] Fix: add the ~15 used-but-undeclared variants (`InvalidData`, `DataCorruption`, `UnexpectedEndOfInput`, `CircularChainDetected`, `BackupTooLarge`, `PageSizeMismatch`, `ReadOnlyMode`, `PropertyKeyTooLong`, `NoManifest`, `BufferTooSmall`, `FileTooLarge`, etc.) to `StorageError`, grouped/commented (contract vs corruption). Where low-risk, narrow vtable signatures from `anyerror` to `StorageError!T`. Do not over-reach — prioritize making the declared set complete and accurate.
- [ ] Confirm green (`zig build check`, full test); `zig fmt`.

### Task 3.3: QUAL-0040 / M1 — prop_store chain-traversal duplication (MEDIUM, #97)

**Files:** Modify `src/prop_store.zig` (extract a `PageChainCursor`; refactor `getProperty`/`findAndRemoveKey`/`insertEntry`/`removeProperty`). Test: same file (+ new overflow-chain test, see 3.5).

- [ ] Write the overflow-chain test FIRST (this also closes QUAL-0044 T1): force `next_page != 0` (fill a page so a property value spills to an overflow page), round-trip read/find/insert/remove; assert correctness and no pinned-frame leak.
- [ ] Confirm it passes against current code (behavior preserved) — this is the safety net before refactor.
- [ ] Refactor: introduce `PageChainCursor` owning pin/unpin/hop-guard/`DataCorruption` mapping; convert the 4 loops to use it. Reuse existing `EntryCursor`/`findEntrySpan` intra-page helpers.
- [ ] Confirm the overflow-chain test + full suite still green; `zig fmt`.

### Task 3.4: QUAL-0043 — ownership docs + iterator API in vtable (MEDIUM, #127)

**Files:** Modify `src/engine.zig` (doc comments on `expandOut`/`getProperty`/`scanLabel`/`getEdgeProperty`), `src/interface.zig` (promote `expandOutIter`/`expandInIter`/`scanLabelIter` to first-class vtable entries; reconcile `scanLabelIter` allocator signature). Test: `src/interface.zig`.

- [ ] Write failing test: a vtable consumer that calls `expandOutIter` through the vtable (currently only reachable via `@hasDecl` reflection) — assert it dispatches.
- [ ] Confirm fail.
- [ ] Fix: add the iterator methods to the `GraphStorage` vtable with consistent signatures; add `///` doc comments to the owned-slice/value read methods stating who frees the result ("Caller owns the returned slice; free with the same allocator").
- [ ] Confirm green; `zig fmt`.

### Task 3.5: QUAL-0044 — test gaps (MEDIUM, #131)

**Files:** Modify `src/prop_store.zig` (dir-disable-on-overlap, max-size key, page-boundary — overflow-chain already in 3.3), `tests/fuzz_regression.zig` (add real fuzz targets for `property.decode`/`encodedSizeFromBytes`, WAL record parsing, page directory reader). Test: those files.

- [ ] Add the directory-disable-on-overlap test and a max-size key (`maxInt(u16)`) test asserting `PropertyKeyTooLong`/overlap branch.
- [ ] Add `std.testing.fuzz` targets (or iterated random-input regression cases) for the on-disk format decoders; ensure they pass under ReleaseSafe.
- [ ] Confirm green; `zig fmt`.

### Task 3.6: QUAL-0045 — doc drift (MEDIUM, #136)

**Files:** Modify `build.zig.zon` (version), `src/root.zig` (version constant + its test), `README.md` (version, Zig version 0.16.0, "single-writer" wording), `docs/format-spec.md` (AES-GCM `tail_reserve` in §3.5.1 property-page layout).

- [ ] Reconcile the version sources to one value (decide whether the package is 0.1.x or 0.2.0; align `build.zig.zon`, `root.zig` const + test, README pins).
- [ ] Update README Zig version to 0.16.0; change "single-threaded GraphEngine" → "single-writer".
- [ ] Add the `tail_reserve` row/note to format-spec §3.5.1 (encrypted-mode directory offset).
- [ ] Confirm `zig build test` still green (root.zig version test matches); reference QUAL-0034 (#56).

### Task 3.7: QUAL-0046 + QUAL-0047 + QUAL-0048 — cleanups (LOW, #137/#138/#139)

**Files:** Modify `src/sharded_engine.zig` (~404,420), `src/engine.zig` (span boilerplate helper; pager-registration helper; `engine_integrity.zig` guard clauses), `build.zig.zon` (ref/version labels).

- [ ] QUAL-0046: replace `@TypeOf(... catch unreachable)` return-type hacks with explicit concrete types.
- [ ] QUAL-0047: extract the ~25× observability span boilerplate into a helper; extract the 3× pager-registration block into `registerDataPagers()`; fix `engine_integrity.zig` to not swallow IO errors as counts (use `while (iter.next() catch |e| return e) |entry|`).
- [ ] QUAL-0048: align `build.zig.zon` `ref=` tags with the declared content versions for `wal` and `otel` (or document the mismatch); ties to QUAL diamond-sync tooling.
- [ ] Confirm green after each; `zig fmt`.

---

## Wave 4 — Performance

### Task 4.1: PERF-0055 — redundant per-write encode/alloc (P2, #116)

**Files:** Modify `src/engine.zig` (`putPropertyTxn` ~911-912 vs `putProperty` stack-buffer encode). Test: alloc-counting test.

- [ ] Write failing test: count allocations across one `putProperty` write; assert the redundant `property_indexEncodedValue` ArrayList alloc is gone.
- [ ] Fix: reuse the already-encoded stack buffer instead of re-encoding into a heap ArrayList in the txn path.
- [ ] Confirm green; `zig fmt`.

### Task 4.2: PERF-0052 — buffered snapshot I/O (P1, #112)

**Files:** Modify `src/engine_index.zig` (save/load ~214-268), `src/label_index.zig` (~167-179), and `src/index_snapshot.zig`. Test: round-trip + a syscall-count assertion if feasible.

- [ ] Write failing/perf test: round-trip a large index snapshot; assert correctness. (Optionally instrument to assert syscall count dropped — at minimum keep correctness.)
- [ ] Fix: replace per-field/per-entry `writePositionalAll`/`readBounded` loops with a single buffered `std.Io` writer/reader serializing the whole payload at once. Keep the SEC-0051 checksum.
- [ ] Confirm green; run `test-integration`. `zig fmt`.

### Task 4.3: PERF-0054 — LabelIndex O(N) insert/remove (P2, #114)

**Files:** Modify `src/label_index.zig` (`addNode` ~94-95, `removeNode` ~113). Test: same file.

- [ ] Write failing/behavior test: large posting list add/remove still correct; choose a data structure that avoids O(N) shifts (e.g. hash set for membership + lazily-sorted slice for scans, or `swapRemove` where order is not required by `scanLabel`).
- [ ] Fix: replace `orderedRemove`/`insert` with the chosen approach; ensure `scanLabel` output ordering contract is preserved or documented.
- [ ] Confirm green; `zig fmt`.

### Task 4.4: PERF-0060 — checkIntegrity double full-scan (P3, #125)

**Files:** Modify `src/engine_integrity.zig` (~76-113). Test: integrity test.

- [ ] Write/keep an integrity test asserting same result.
- [ ] Fix: merge the two per-node `getNode` scans into a single `scanNodes` batch callback (as `rebuildEdgeIndex` does); stop double-pinning.
- [ ] Confirm green; `zig fmt`.

### Task 4.5: PERF-0051 — buffer-pool sizing & pollution (P1, #111)

**Files:** Modify `src/config.zig` (defaults/auto-size), `src/engine.zig` (`create` auto-size ~197), `src/engine_persist.zig` (per-FileId frame reservation, shared-pool registration ~201-205). Test: behavior + a thrash metric.

- [ ] Write a test/bench harness assertion: with a working set larger than the pool, hot node-page lookups should not be evicted by cold prop-page scans (reserve frames for node pages). At minimum: `create()` auto-sizes the pool from expected counts like `open()` does.
- [ ] Fix: (a) make `create()` auto-size (or raise default) like `open()`; (b) add per-FileId frame reservation so node pages are protected from prop-page pollution; (c) surface `buffer_misses`/`page_reads` in `scale_bench` JSON (PERF-0061, #126).
- [ ] Confirm green; run `zig build scale-bench -- 1K` sanity. `zig fmt`.

### Task 4.6: PERF-0056 + PERF-0057 — checkpoint copy/fsync (P2, #119/#120)

**Files:** Modify `src/buffer_pool.zig` (`flushFrame` copy ~446-448, `flushAllParallel` transient buffer ~294-303), `src/checkpoint.zig` (`syncAll` ~67), `src/file_manager.zig` (`syncAll` ~122-127). Test: checkpoint test.

- [ ] PERF-0057: only fsync store files that were actually written this checkpoint (track dirtiness per file). Keep durability ordering (data fsync before manifest).
- [ ] PERF-0056: avoid the `dirty_count * page_size` transient allocation per checkpoint (stream chunks / reuse a bounded buffer).
- [ ] Confirm green; run `test-integration`, durability/recovery tests. `zig fmt`.

### Task 4.7: PERF-0058 + PERF-0059 (P3, #122/#123)

**Files:** Modify `src/sharded_engine.zig`/`sharded_engine_2pc.zig` (parallelize the two prepare fsyncs ~328-371), `src/buffer_pool.zig` (reduce mutex scope on pin/unpin hits ~129,200,235). Test: sharded + concurrency tests.

- [ ] PERF-0058: issue the two independent shard prepares concurrently via the thread pool rather than serially.
- [ ] PERF-0059: reduce/relax the pool mutex on cache-hit pin/unpin (e.g. finer-grained or atomic hit path) without breaking single-writer invariants. Be conservative — correctness first.
- [ ] Confirm green; run `test-cross-shard-recovery`, `test-integration-sharded`. `zig fmt`.

### Task 4.8: PERF-0045 — group commit (P1, #98)

**Files:** Modify `src/txn.zig` (`commit` ~82 — batch fsync), `src/engine.zig` (auto-commit wrappers), `src/config.zig` (commit/sync policy). Test: durability + throughput.

- [ ] Write durability tests: acknowledged commits survive crash with group-commit (no weakening of NFR-SEC-003). Single-op auto-commit still durable.
- [ ] Fix: implement group-commit / batched fsync — coalesce fsyncs across concurrent or batched commits while preserving the "acknowledged ⇒ durable" contract. Provide a config knob; default must keep current durability semantics.
- [ ] Confirm green; run full recovery/durability + `scale-bench` sanity. `zig fmt`.
- [ ] NOTE: this is the largest perf lever and the highest-risk change. If durability cannot be preserved cleanly within scope, leave the issue open with findings rather than ship a weaker guarantee.

---

## Wave 5 — Features

### Task 5.1: #36 — StorageEvent lifecycle events (LOW)

**Files:** Modify `src/config.zig` (`StorageEvent` enum ~10), emit sites in `src/migration.zig`/`src/verify.zig`/`src/engine_index.zig`. Test: event tests.

- [ ] Write failing tests asserting `migration_start/end`, `verify_start/end`, `index_build_start/end` fire during those operations.
- [ ] Fix: add the enum members and emit them via the existing `emitEvent`/`log_fn` seam.
- [ ] Confirm green; `zig fmt`.

### Task 5.2: GAP-0027 / FR-016 / FR-017 — wire B+tree property indexes + index catalog into the engine (HIGH, #45/#16/#17)

**Files:** Modify `src/engine.zig`/`src/engine_persist.zig`/`src/engine_index.zig` (instantiate `IndexCatalog`, load on open, save on checkpoint, back property indexes with `btree.zig`/`property_index.zig`). Test: engine-level integration test.

- [ ] Write failing integration test: create an engine, declare a B+tree property index via the catalog, insert nodes/properties, checkpoint, reopen, assert the index survives and serves equality/range queries.
- [ ] Fix: wire `IndexCatalog` into `open()` (load) and `checkpoint()` (save); route property index build/rebuild through `property_index.zig`/`btree.zig`; persist via the catalog.
- [ ] Confirm green; run `test-integration`. `zig fmt`.
- [ ] NOTE: large feature. If it cannot land completely in scope, deliver the catalog wiring (load/save) first and leave query routing as a tracked follow-up.

### Task 5.3: FR-021 — index extension points (MEDIUM, #21)

**Files:** Modify `src/index_catalog.zig` (`IndexType` + a registration interface). Test: catalog test.

- [ ] Write failing test: register a custom index type through the extension API; catalog round-trips it.
- [ ] Fix: add an index-kind registration interface (vtable or comptime registry) so new index types can be added without editing the core enum.
- [ ] Confirm green; `zig fmt`.

---

## Blocked / Out-of-scope (document, do not force)

- **GAP-0002 / FR-018 migration bulk-load (#40/#18):** blocked on the external Geode binary-format reader. Leave `migrate()` stub with the documented blocker; do not fabricate a reader.
- **GAP-0017 / NFR-OBS-001 OTel export (#41/#35):** blocked on the upstream Zig 0.16 module-dedup diamond bug. Keep `observability.zig` disabled with the documented rationale; re-enable when upstream fixes land.
- **#91/#94 Windows CI:** requires CI infra (a Windows runner) not available in this environment. Either add the job if a runner exists, or document Windows as explicitly unsupported and scope the README claim accordingly.
- **QUAL-0027 module decomposition (#72) / QUAL-0033 (#83):** large refactors; QUAL-0033 is "Won't Do" (CI is the authoritative gate). Engine decomposition is desirable but lower priority than correctness — leave open with the delegation-pattern recommendation unless time permits.

---

## Self-Review notes

- Spec coverage: every SEC-0037..0052, PERF-0045/0051..0061, QUAL-0040..0048, and feature gaps #36/#16/#17/#21 map to a task; blocked items are explicitly listed.
- Each code task is failing-test-first, builds, and runs `zig fmt`.
- File ownership is disjoint within each wave's parallel set; structural changes (snapshot format, manifest HMAC, group commit) are sequenced and versioned additively.
