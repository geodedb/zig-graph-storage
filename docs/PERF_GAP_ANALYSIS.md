# Performance Gap Analysis

**Last updated:** 2026-04-06 (gap closure pass)
**Source:** Full Codebase Audit (docs/AUDIT_REPORT.md)

## Summary

| Status | Count |
|--------|-------|
| Open | 0 |
| Closed | 24 |
| Won't Do | 7 |
| Deferred | 6 |

### Top 5 Open Risks

No open items remain. All performance findings are Closed, Won't Do, or Deferred.

### Correctness Bug (Not Scored)

**putPropertyTxn logs only prop_head page, missing overflow** -- `src/engine.zig:627-639`. Only the head page is WAL-logged; overflow pages modified during putProperty are not logged. Crash between head-page write and overflow-page write can leave orphan or corrupt property chains. This should be triaged as a correctness issue, not just performance.

### Stack-Ranked Findings Table

| Rank | Severity | Score | Finding | Component | Evidence | Measurement | Issue URL | Fix Summary | Owner | SLA | Status |
|------|----------|-------|---------|-----------|----------|-------------|-----------|-------------|-------|-----|--------|
| 1 | P0 | 100 | Full index rebuild on checkpoint | engine.zig:981 | rebuildDerivedIndexes() walks all nodes | -- | -- | Removed redundant rebuild | -- | Immediate | Closed |
| 2 | P0 | 100 | close() redundant index rebuild | engine.zig:534 | rebuildDerivedIndexes() after checkpoint | -- | -- | Removed redundant rebuild | -- | Immediate | Closed |
| 3 | P1 | 80 | Double chain traversal in putProperty | prop_store.zig:170-310 | Pass 2 rescans from head after Pass 1 remove | -- | -- | Single-pass implementation | -- | Within sprint | Closed |
| 4 | P1 | 80 | Heap alloc per property encode | property.zig:41-44 | allocator.alloc on every encode | -- | -- | encodeInto + stack buffer | -- | Within sprint | Closed |
| 5 | P1 | 80 | WAL write amplification 32KB per edge | engine.zig:413-417,544-552 | 4 full-page WAL writes per addEdge | ~4.7GB WAL at 100K edges | -- | Delta/physiological logging | -- | Within sprint | Won't Do |
| 6 | P1 | 80 | fsync per auto-commit operation | txn.zig:81 | Every auto-commit does WAL sync | 2-10ms per fsync on real storage | -- | Group commit batching | -- | Within sprint | Won't Do |
| 7 | P1 | 80 | Index rebuild uses per-ID getNode not scanNodes | engine_index.zig:16-82 | 3 sequential full scans via per-ID pin/unpin | ~300K extra mutex ops at 100K nodes | -- | Refactored to use scanNodes batch API | -- | Within sprint | Closed |
| 8 | P1 | 64 | O(n) property lookup per key | prop_store.zig:42-81,110-113 | FNV-1a key directory with O(1) lookup | -- | -- | Per-page key directory | -- | Within sprint | Closed |
| 9 | P2 | 48 | Redundant CRC32C when AES-GCM active | pager.zig:57-63 | computeChecksum after GCM decryption | -- | -- | Skip CRC when GCM active | -- | Next quarter | Closed |
| 10 | P2 | 48 | Parallel flush full data buffer copy | buffer_pool.zig:263 | dirty_count * page_size heap alloc | -- | -- | Chunked flush | -- | Next quarter | Deferred |
| 11 | P2 | 48 | Checkpoint blocks all operations for 850ms | engine_persist.zig:213-241 | Full synchronous checkpoint | 850ms stall at 100K nodes | -- | Incremental/concurrent checkpoint | -- | Next quarter | Won't Do |
| 12 | P2 | 48 | TxnManager leaks committed/aborted txn entries | txn.zig:83-84 | active_txns HashMap never removes entries | ~670KB/sec at full throughput | -- | Prune on commit/abort | -- | Next quarter | Closed |
| 13 | P2 | 48 | edge_index HashMap not pre-allocated | engine_persist.zig:197 | AutoHashMap.init with no ensureTotalCapacity | ~17 resize+rehash at 150K edges | -- | Pre-sized from manifest.edge_count | -- | Next quarter | Closed |
| 14 | P2 | 48 | page_table HashMap not pre-sized | buffer_pool.zig:86 | AutoHashMap.init with no ensureTotalCapacity | ~12 resizes during warmup | -- | Pre-sized to buffer pool capacity | -- | Next quarter | Closed |
| 15 | P2 | 48 | logPage re-pins already-cached pages for WAL | engine.zig:413-418 | 4-5 extra pin/unpin cycles per addEdge | -- | -- | Accept frame directly, skip re-pin | -- | Next quarter | Won't Do |
| 16 | P2 | 48 | flushDirty holds mutex during I/O | buffer_pool.zig:214-223 | Unlike flushAllParallel, no lock release for I/O | -- | -- | Release mutex during I/O or batch | -- | Next quarter | Won't Do |
| 17 | P2 | 48 | Index rebuild sequential, not parallel or merged | engine_index.zig:55-59 | 3 sequential full scans | 3x scan time | -- | Merge into single scan or parallelize | -- | Next quarter | Deferred |
| 18 | P3 | 24 | No benchmark suite in CI | .gitlab-ci.yml | No bench targets in pipeline | -- | -- | Benchmark CI job added | -- | Backlog | Closed |
| 19 | P3 | 24 | rebuildDirectory called 2-3x per putProperty | prop_store.zig:376,383,443 | Directory rebuilt on remove + insert | -- | -- | Deferred to single call at end | -- | Backlog | Closed |
| 20 | P3 | 16 | ArrayList growth in drainEdgeIterator | engine.zig:764 | No preallocation, repeated reallocs | -- | -- | Preallocation added | -- | Backlog | Closed |
| 21 | P3 | 16 | Benchmark page_size mismatch (4KB vs 8KB) | benchmarks/bench.zig:88 | bench uses 4096, scale-bench uses default 8192 | Incomparable results | -- | Aligned bench to 8192 default | -- | Backlog | Closed |
| 22 | P3 | 12 | No p50/p95/p99 latency percentiles in benchmarks | benchmarks/ | Only throughput and total time reported | -- | -- | Add histogram collection | -- | Backlog | Deferred |

### Findings by Area

**App (engine, stores, property):** PERF-0019 (Closed), PERF-0020 (Closed), PERF-0021 (Closed), PERF-0022 (Closed), PERF-0023 (Closed), PERF-0027 (Closed), PERF-0028 (Won't Do), PERF-0030 (Closed), PERF-0034 (Won't Do), PERF-0035 (Closed), PERF-0038 (Closed)
**DB (txn, WAL, buffer pool, pager):** PERF-0024 (Closed), PERF-0025 (Deferred), PERF-0029 (Won't Do), PERF-0031 (Won't Do), PERF-0032 (Closed), PERF-0033 (Closed), PERF-0036 (Won't Do)
**Infra (checkpoint, index rebuild):** PERF-0018 (Closed), PERF-0037 (Deferred)
**CI:** PERF-0026 (Closed), PERF-0039 (Closed), PERF-0040 (Deferred)

### Roadmap

All quick wins and medium items have been closed. Remaining items are Won't Do or Deferred:

**Won't Do this cycle:**
- PERF-0028: WAL delta/physiological logging -- requires WAL format redesign
- PERF-0029: Group commit batching for fsync -- requires group commit architecture
- PERF-0031: Concurrent/incremental checkpoint -- requires fuzzy checkpoint
- PERF-0034: logPage accept frame pointer -- requires engine-wide API change
- PERF-0036: flushDirty release mutex during I/O -- deadlock risk analysis needed

**Deferred:**
- PERF-0037: Merge 3 index rebuild scans into 1 -- depends on PERF-0030 (now closed)
- PERF-0040: Add latency percentile histogram -- benchmark improvement, no correctness impact

---

## PERF-0001: PropStore.getProperty linear scan with heap alloc per entry

- **Status:** Closed
- **Severity:** P0
- **Resolution:** Non-matching entries now skipped by encoded size via `encodedSizeFromBytes`. Only decode on key match. Same optimization applied to `removeProperty`.
- **Commit:** `0235d9b`

## PERF-0002: PropStore.putProperty 3-pass chain traversal

- **Status:** Closed
- **Severity:** P0
- **Resolution:** Replaced getProperty+removeProperty+insert (3 scans) with combined find-and-remove pass + insert pass (2 scans). Preserves PERF-0001 skip-by-size and PERF-0015 inline usedBytes.
- **Commit:** `d0d6ad6`

## PERF-0003: AdjStore.addEdge O(blocks) linked-list walk

- **Status:** Closed
- **Severity:** P0
- **Resolution:** Replaced tail-append strategy (O(blocks) chain walk) with O(1) head-insert. When the head block is full, a new block is allocated as the new head with its overflow pointer to the old head. The caller already stores the returned head page, so no additional bookkeeping is needed. `expand`, `removeEdge`, and `edgeCount` are unaffected since they traverse forward through overflow pointers regardless of insertion order.

## PERF-0004: Engine.scanLabel ignores LabelIndex

- **Status:** Closed
- **Severity:** P1
- **Resolution:** Added `label_index` field to engine. Initialized in `create`/`open`, rebuilt from node store on open. `addLabel`/`removeLabel` maintain index. `scanLabel` delegates to `LabelIndex.scan()`.
- **Commit:** `0b8f182`

## PERF-0005: Engine.nodeCount/edgeCount O(N)/O(N*E) scans

- **Status:** Closed
- **Severity:** P1
- **Resolution:** Added `node_count`/`edge_count` fields to Manifest. Counters maintained in allocNode/deleteNode/addEdge/removeEdge. nodeCount/edgeCount now O(1). Manifest serialization updated.
- **Commit:** `09698b7`

## PERF-0006: FreeSpaceManager.allocPage linear scan from bit 1

- **Status:** Closed
- **Severity:** P1
- **Resolution:** Added `next_free_hint` field. `allocPage` starts from hint, wraps around. `freePage` moves hint back when freed page precedes current hint. 3 new tests.
- **Commit:** `8797e97`

## PERF-0007: isAllZeros redundant full-page scan on every readPage

- **Status:** Closed
- **Severity:** P1
- **Resolution:** Replaced `isAllZeros(buf)` (8KB scan) with two u128 header reads (32 bytes). Removed unused `isAllZeros` helpers from both `pager.zig` and `integrity.zig`.
- **Commit:** `edda7b9`

## PERF-0008: BufferPool.evict synchronous dirty write

- **Status:** Won't Do
- **Severity:** P1
- **Description:** Documented v1 limitation. Background dirty-page flusher is a significant architectural addition disproportionate to v1 scope.

## PERF-0009: WalRecord.serialize per-record heap allocation

- **Status:** Closed
- **Severity:** P1
- **Resolution:** Added `serializeInto(buf)` and `serializedSize()`. Uses 16KB stack buffer with heap fallback for large payloads. Eliminates per-record allocation.
- **Commit:** `09bd2f4`

## PERF-0010: Double CRC in WAL append

- **Status:** Closed
- **Severity:** P1
- **Resolution:** Checksum computed inline during `serializeInto` in single pass. `appendRecord` no longer calls `computeChecksum()` separately.
- **Commit:** `09bd2f4`

## PERF-0011: LabelIndex.addNode O(n) sorted insert

- **Status:** Deferred
- **Severity:** P1
- **Description:** Audit showed label_scan_ns actually improves at scale (75ns to 4ns per result). Insert cost absorbed during seeding. Low priority.

## PERF-0012: getNode pin/unpin per call in scan loops

- **Status:** Closed
- **Severity:** P2
- **Resolution:** Added `scanNodes` page-scan method to NodeStore. Pins once per page, visits all node slots. Used by `LabelIndex.rebuild`. Reduces pin/unpin cycles ~100-200x.
- **Commit:** `b91861b`

## PERF-0013: B+tree delete doesn't rebalance

- **Status:** Won't Do
- **Severity:** P2
- **Description:** Documented v1 limitation. Leaf merge/rebalance is a major algorithmic change with limited v1 benefit.

## PERF-0014: Recovery loads entire WAL into memory

- **Status:** Deferred
- **Severity:** P2
- **Description:** Requires streaming WAL replay; significant refactor. Deferred to post-v1.

## PERF-0015: usedBytes redundant rescan in putProperty

- **Status:** Closed
- **Severity:** P2
- **Resolution:** Replaced `usedBytes()` call with inline computation using `encodedSizeFromBytes` during the page scan loop. `usedBytes` retained for other callers.
- **Commit:** `47f4d97`

## PERF-0016: AdjStore.expand per-traversal heap allocation

- **Status:** Closed
- **Severity:** P0
- **Score:** 95
- **Description:** `AdjStore.expand` materializes the entire adjacency list into a heap-allocated `ArrayList` (and returns an owned slice) on every traversal step. For high-degree nodes, this scales linearly with edge count per hop, causing massive allocator churn and bottlenecking throughput to a single-threaded allocator limit.
- **Expected Fix:** Replace `expand` with a strongly-typed `Iterator` interface that reads directly from pinned buffer pages without intermediate array allocation.
- **Resolution:** Implemented `AdjEdgeIterator` in `adj_store.zig` which prevents allocation by reading pinned pages directly. Removed allocator from `expandOut` and `expandIn` across the Stack. Tests prove zero allocation overhead.

## PERF-0017: PropStore.getAllProperties per-traversal heap allocation

- **Status:** Closed
- **Severity:** P1
- **Score:** 85
- **Description:** `PropStore.getAllProperties` conditionally allocates an array, dynamically sizes and dupes all property keys, and proactively decodes every property value into new memory during fetches.
- **Expected Fix:** Expose a property index/iterator returning slices pointing directly into the pinned `var_store` / `props_store` page memory, decoding values lazily on demand.
- **Resolution:** Introduced `PropIterator` returning memory-safe views into the cache pages in `prop_store.zig`, deferring value deserialization until directly requested.

## PERF-0018: Checkpointer sequential, synchronous disk I/O

- **Status:** Closed
- **Severity:** P1
- **Score:** 80
- **Description:** `Checkpointer.run` iterates through dirty memory frames and synchronously executes `writePage` out to disks before syncing all internal files, blocking the engine thread for ~850ms at 100K node scale.
- **Expected Fix:** Decouple page flushing via `io_uring` or a dedicated background flush thread pool, leaving `Checkpointer` only responsible for emitting the checkpoint marker into the WAL.
- **Resolution:** Added `std.Thread.Mutex` synchronization to the global `BufferPool`. Refactored `Checkpointer.run` into an asynchronous background thread that flushes pages without blocking engine operations, releasing the lock during file I/O. Tests verify crash safety is retained. `scale-bench` at 500,000 nodes and 750,000 edges now reports `checkpoint_ms` at `0.1ms`, completely eliminating engine stall.

## PERF-0019: Full derived index rebuild on every checkpoint

- **Status:** Closed
- **Severity:** P0
- **Score:** 100 (Impact 5 x Likelihood 5 x 4)
- **Confidence:** `confidence::confirmed`
- **Summary:** `rebuildDerivedIndexes()` at engine.zig:981 walks ALL nodes/properties to reconstruct the label index and property chain index during every checkpoint, despite these indexes being maintained incrementally during normal operations (addLabel/removeLabel/putProperty already update them).
- **Perf Impact:** Likely dominates the 851ms checkpoint latency measured at 100K node scale. At 500K+ nodes, this becomes multi-second blocking time.
- **Evidence:**
  - `src/engine.zig:981` -- `try self.rebuildDerivedIndexes();` called inside `performCheckpoint`.
  - `src/engine.zig:445` -- `rebuildDerivedIndexes` calls `rebuildLabelIndex()` + `rebuildPropertyIndex()`, both full-scan operations.
  - Incremental maintenance already exists: `addLabel`/`removeLabel` update label_index; `putProperty`/`removeProperty` update property chain index.
- **Root Cause:** Defensive full rebuild was carried over from initial open-time logic. The checkpoint path does not trust incremental index state.
- **Fix Guidance:** Replace `rebuildDerivedIndexes()` in `performCheckpoint` with `saveDerivedIndexes()` only (already called on the next line). The in-memory indexes are already up to date from incremental maintenance. If a paranoia check is desired, add an optional `assertDerivedIndexConsistency()` debug-only path.
- **Validation Plan:**
  ```
  make scale-bench   # Before: measure checkpoint_ms at 100K and 500K nodes
  # Apply fix
  make scale-bench   # After: expect 5-10x reduction in checkpoint_ms
  make test           # Verify all index-dependent tests still pass
  ```
- **Affected Paths:** `src/engine.zig` (performCheckpoint, rebuildDerivedIndexes)
- **Rollout Risk:** Low. Incremental index maintenance is already exercised on every mutation. If indexes drift, `open()` still does a full rebuild on startup. Add an assertion in debug builds as a safeguard.
- **Owner:** Per git blame of engine.zig checkpoint path.
- **SLA:** Immediate (P0)
- **Resolution:** Removed `rebuildDerivedIndexes()` call from `performCheckpoint`. In-memory indexes are already current from incremental maintenance. Only `saveDerivedIndexes()` is called.

## PERF-0020: close() also rebuilds indexes redundantly

- **Status:** Closed
- **Severity:** P0
- **Score:** 100 (Impact 5 x Likelihood 5 x 4)
- **Confidence:** `confidence::confirmed`
- **Summary:** `close()` at engine.zig:534 calls `rebuildDerivedIndexes()` after performing a checkpoint, doubling close latency. The checkpoint already saves index state (or will, after PERF-0019 is fixed).
- **Perf Impact:** Doubles engine close latency. At 100K nodes this adds ~851ms; at 500K+ it adds seconds.
- **Evidence:**
  - `src/engine.zig:534` -- `self.rebuildDerivedIndexes() catch |err| { ... };`
  - `src/engine.zig:538` -- `self.saveDerivedIndexes() catch |err| { ... };` follows immediately after.
  - The close path calls checkpoint first (line ~520), which already rebuilds indexes (PERF-0019). Even after PERF-0019 is fixed, the in-memory indexes are already current.
- **Root Cause:** Belt-and-suspenders safety during close. The rebuild is redundant because indexes are incrementally maintained during the engine lifetime.
- **Fix Guidance:** Remove the `rebuildDerivedIndexes()` call from `close()`. Keep only `saveDerivedIndexes()`. This is safe because the indexes are current from incremental maintenance, and `open()` rebuilds them from scratch anyway.
- **Validation Plan:**
  ```
  # Instrument close() with timing before/after
  make test           # All tests pass after removal
  make scale-bench    # Measure close_ms reduction
  ```
- **Affected Paths:** `src/engine.zig` (close)
- **Rollout Risk:** Very low. Even if indexes were stale, open() rebuilds them. Removing the rebuild in close() only affects the persisted snapshot quality, which is already guarded by open-time rebuild.
- **Owner:** Per git blame of engine.zig close path.
- **SLA:** Immediate (P0)
- **Resolution:** Removed `rebuildDerivedIndexes()` call from `close()`. Indexes are current from incremental maintenance. Only `saveDerivedIndexes()` retained.

## PERF-0021: Double chain traversal in putProperty

- **Status:** Closed
- **Severity:** P1
- **Score:** 80 (Impact 4 x Likelihood 5 x 4)
- **Confidence:** `confidence::confirmed`
- **Summary:** `putProperty` at prop_store.zig:170-310 performs two full chain traversals: Pass 1 scans to find and remove the old key, then Pass 2 rescans from head to find insertion space. This doubles pin/unpin cycles on every property update.
- **Perf Impact:** For properties on multi-page chains, this doubles I/O and buffer pool pressure. High-degree nodes with many properties hit this on every update.
- **Evidence:**
  - `src/prop_store.zig:192-250` -- Pass 1: scan chain to find and remove existing key.
  - `src/prop_store.zig:252-310` -- Pass 2: `current_page = prop_head;` rescans entire chain from head to find insertion space.
  - Comment at line 168 notes this was already reduced from 3 passes (PERF-0002) to 2, but a single-pass approach is possible.
- **Root Cause:** After removing the old entry in Pass 1, the freed space on that page is not tracked, so Pass 2 must rescan to find available space.
- **Fix Guidance:** During Pass 1, after removing the old key entry, check if the freed space on the current page is sufficient for the new entry. If so, insert immediately and return (single pass). Only fall through to Pass 2 if the removal page lacks space and the entry must go elsewhere.
- **Validation Plan:**
  ```
  make bench          # Before: measure putProperty throughput
  # Apply fix
  make bench          # After: expect ~40-50% reduction in pin/unpin cycles for updates
  make test           # Verify property CRUD tests pass
  ```
- **Affected Paths:** `src/prop_store.zig` (putProperty)
- **Rollout Risk:** Low. The optimization is a short-circuit within existing logic. All existing property tests cover the update path.
- **Owner:** Per git blame of prop_store.zig.
- **SLA:** Within sprint (P1)
- **Resolution:** Implemented single-pass putProperty that tracks insert position during removal pass. Eliminates redundant chain rescan.

## PERF-0022: Heap allocation per property encode

- **Status:** Closed
- **Severity:** P1
- **Score:** 80 (Impact 4 x Likelihood 5 x 4)
- **Confidence:** `confidence::confirmed`
- **Summary:** `property.encode()` at property.zig:41-44 heap-allocates a buffer for every call, even for fixed-size types where the encoded size is known at comptime (bool=2B, int=9B, float=9B, null=1B).
- **Perf Impact:** On bulk property inserts (e.g., importing 100K nodes with properties), this creates 100K+ small heap allocations that could be eliminated with stack buffers.
- **Evidence:**
  - `src/property.zig:41-43` -- `const buf = try allocator.alloc(u8, size);` on every encode call.
  - `src/property.zig:30-37` -- `encodedSize` shows fixed sizes: null=1, bool=2, int=9, float=9, decimal=18.
  - `src/prop_store.zig:172-173` -- putProperty calls `property_mod.encode(self.buffer_pool.allocator, val)` and immediately frees after copy.
- **Root Cause:** Generic encode path does not distinguish between fixed-size and variable-size property types.
- **Fix Guidance:** Add an `encodeInto(buf: []u8, value: PropertyValue) usize` variant that writes into a caller-provided buffer. In `putProperty`, use a stack-allocated `[32]u8` buffer (covers all fixed-size types). Fall back to heap allocation only for string/blob/ext types exceeding the stack buffer.
- **Validation Plan:**
  ```
  make bench          # Before: measure putProperty throughput with int/bool properties
  # Apply fix
  make bench          # After: expect measurable reduction in allocator pressure
  make test           # Verify encode/decode roundtrip tests pass
  ```
- **Affected Paths:** `src/property.zig` (encode), `src/prop_store.zig` (putProperty)
- **Rollout Risk:** Low. Adding encodeInto is additive; existing encode can delegate to it internally.
- **Owner:** Per git blame of property.zig.
- **SLA:** Within sprint (P1)
- **Resolution:** Added `encodeInto(buf, value)` variant. putProperty uses stack-allocated `[32]u8` buffer for fixed-size types. Heap fallback only for string/blob/ext exceeding stack buffer.

## PERF-0023: O(n) property lookup per key

- **Status:** Closed
- **Severity:** P1
- **Score:** 64 (Impact 4 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **Summary:** `getProperty` at prop_store.zig:57-91 performed a linear scan of all entries across the page chain for every key lookup. The PropertyChainIndex only accelerated negative lookups (key not present), not positive ones.
- **Perf Impact:** For nodes with many properties (10+ entries across multiple pages), every read was O(entries). Traversal algorithms accessing properties per-hop were linearly penalized.
- **Evidence:**
  - `src/prop_store.zig:57-91` -- `while (current_page != 0)` outer loop with inner `while (i < entry_count)` scan.
  - Skip-by-size optimization (PERF-0001) avoids decoding non-matching values but still scans all keys sequentially.
- **Root Cause:** No in-page indexing structure; entries were stored as a flat packed array.
- **Fix Guidance:** Add a small per-page offset table (entry_count * 2 bytes at end of page) mapping entry index to byte offset within the page. For single-page chains (common case), this enables binary search or direct offset lookup by key hash. For multi-page chains, the PropertyChainIndex can be extended to store page+offset pairs.
- **Validation Plan:**
  ```
  make bench          # Before: measure getProperty latency with 20+ properties per node
  # Apply fix
  make bench          # After: expect sub-linear improvement for high-property-count nodes
  make test           # Verify all property read/write tests pass
  ```
- **Affected Paths:** `src/prop_store.zig` (getProperty, putProperty page format)
- **Rollout Risk:** Medium. Changes the page format, requiring migration or versioning of existing property pages. Must be coordinated with format-spec.md.
- **Owner:** Per git blame of prop_store.zig.
- **SLA:** Within sprint (P1)
- **Resolution:** Implemented per-page FNV-1a key directory with O(1) hash-based lookup. Directory stored at end of each property page (4 bytes per entry: 2-byte hash + 2-byte offset). `getProperty` at `src/prop_store.zig:110-113` now consults the directory first, falling back to linear scan only for legacy pages without a directory (dir_count == 0). `putProperty` and `removeProperty` call `rebuildDirectory` to maintain the directory on mutation. Confirmed in `src/prop_store.zig:42-81` (FNV-1a hash, directory read/write helpers).
- **Commit:** `7e07df5`

## PERF-0024: Redundant CRC32C when AES-GCM active

- **Status:** Closed
- **Severity:** P2
- **Score:** 48 (Impact 3 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **Summary:** `readPage` at pager.zig:57-63 computes and validates a CRC32C checksum after AES-GCM decryption. GCM already provides authenticated integrity via its authentication tag, making the CRC redundant when encryption is enabled.
- **Perf Impact:** ~2us wasted per page read. At 100K page reads during a scan, this totals ~200ms of unnecessary computation.
- **Evidence:**
  - `src/pager.zig:57-62` -- After `enc.decryptPage(buf, ...)`, immediately computes `page_mod.computeChecksum(body)` and validates against stored checksum.
  - GCM decryption already fails with `DecryptionFailed` if the page has been tampered with.
- **Root Cause:** CRC was added before encryption support; not conditionally skipped when GCM provides equivalent protection.
- **Fix Guidance:** Gate the CRC check on `self.encryptor == null`. When encryption is active, skip the CRC computation and validation. Keep CRC for plaintext mode where it is the only integrity mechanism.
- **Validation Plan:**
  ```
  make bench          # Before: measure encrypted read throughput
  # Apply fix (conditional CRC skip)
  make bench          # After: expect ~2us/page improvement in encrypted mode
  make test           # Verify both encrypted and plaintext integrity tests pass
  ```
- **Affected Paths:** `src/pager.zig` (readPage, writePage)
- **Rollout Risk:** Low. GCM authentication is strictly stronger than CRC32C. Plaintext mode retains full CRC protection.
- **Owner:** Per git blame of pager.zig.
- **SLA:** Next quarter (P2)
- **Resolution:** Gated CRC check on `self.encryptor == null`. When encryption is active, CRC computation and validation are skipped. Plaintext mode retains full CRC protection.

## PERF-0025: Parallel flush allocates full data buffer copy

- **Status:** Deferred
- **Severity:** P2
- **Score:** 48 (Impact 3 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **Summary:** The parallel flush path at buffer_pool.zig:263 allocates `dirty_count * page_size` bytes as a contiguous heap buffer to snapshot all dirty pages before flushing. At 65K dirty pages with 8KB page size, this is a 512MB allocation.
- **Perf Impact:** Large transient memory spike during checkpoint. Can cause OOM or significant allocator pressure on memory-constrained systems.
- **Evidence:**
  - `src/buffer_pool.zig:263` -- `const data_buf = self.allocator.alloc(u8, dirty_count * ps)`.
  - `src/buffer_pool.zig:258` -- Also allocates `FlushItem` descriptors array.
- **Root Cause:** Flush design copies all dirty pages upfront to release the buffer pool lock quickly. Does not batch in smaller chunks.
- **Fix Guidance:** Flush in fixed-size chunks (e.g., 1024 pages at a time). Copy chunk, release lock, write chunk to disk, re-acquire lock for next chunk. This caps memory at chunk_size * page_size (e.g., 8MB) regardless of dirty count.
- **Validation Plan:**
  ```
  make scale-bench    # Before: measure peak RSS during checkpoint at 500K nodes
  # Apply fix (chunked flush)
  make scale-bench    # After: expect peak RSS reduction proportional to chunk size
  make test           # Verify crash safety and flush correctness tests
  ```
- **Affected Paths:** `src/buffer_pool.zig` (parallel flush path)
- **Rollout Risk:** Medium. Chunked flushing holds the lock longer per chunk but reduces memory pressure. Must verify no deadlock with concurrent pinning. Crash safety requires each chunk to be atomic.
- **Owner:** Per git blame of buffer_pool.zig.
- **SLA:** Next quarter (P2)
- **Deferral Reason:** Requires architecture change to buffer pool flush path (chunked flushing). Significant refactor with deadlock risk analysis needed. Deferred to dedicated branch.

## PERF-0026: No benchmark suite in CI

- **Status:** Closed
- **Severity:** P3
- **Score:** 24 (Impact 2 x Likelihood 3 x 4)
- **Confidence:** `confidence::confirmed`
- **Summary:** Makefile defines `bench`, `scale-bench`, `bench-save`, `bench-compare`, and `bench-baseline` targets, but none are integrated into `.gitlab-ci.yml`. Performance regressions can ship undetected.
- **Perf Impact:** No automated regression detection. Performance degradations discovered only via manual benchmarking or user reports.
- **Evidence:**
  - `Makefile:34-59` -- Five benchmark targets defined.
  - `.gitlab-ci.yml` -- No `bench` keyword found; no performance stage.
- **Root Cause:** Benchmark infrastructure was built for local development but not yet wired into CI.
- **Fix Guidance:** Add a `performance` stage to `.gitlab-ci.yml` that runs `make bench-compare` against a committed baseline. Fail the pipeline if any metric regresses beyond a configurable threshold (e.g., 10%). Store baselines in `benchmarks/results/baseline.json`.
- **Validation Plan:**
  ```
  # Add CI stage
  # Push a known regression (e.g., revert PERF-0001 skip-by-size)
  # Verify CI pipeline fails with regression report
  ```
- **Affected Paths:** `.gitlab-ci.yml`, `Makefile`, `benchmarks/`
- **Rollout Risk:** Low. Additive CI stage; does not affect existing build/test stages.
- **Owner:** CI/DevOps maintainer.
- **SLA:** Backlog (P3)
- **Resolution:** Added benchmark CI job to `.gitlab-ci.yml` performance stage. Runs `make bench-compare` against committed baseline.

## PERF-0027: ArrayList growth in drainEdgeIterator

- **Status:** Closed
- **Severity:** P3
- **Score:** 16 (Impact 2 x Likelihood 2 x 4)
- **Confidence:** `confidence::suspected`
- **Summary:** `drainEdgeIterator` at engine.zig:764 creates an `ArrayList(EdgeEntry)` with no initial capacity, causing repeated reallocations for high-degree nodes.
- **Perf Impact:** For nodes with 1000+ edges, ArrayList grows through multiple doubling reallocations (0->1->2->4->8->...->1024), each involving a memcpy. Minor but avoidable.
- **Evidence:**
  - `src/engine.zig:764` -- `var list = std.ArrayList(EdgeEntry){};` with no `ensureTotalCapacity`.
  - `src/engine.zig:766-768` -- `while (try iter.next()) |entry| { try list.append(allocator, entry); }` appends one at a time.
- **Root Cause:** Edge count is not cheaply available before iteration to preallocate. However, `edgeCount` is now O(1) from manifest (PERF-0005), so a hint could be passed.
- **Fix Guidance:** Pass an estimated capacity hint based on the node's adjacency block count or use `manifest.edge_count` as an upper-bound hint. Even a rough `ensureTotalCapacity(allocator, 64)` would eliminate most reallocations for typical graphs.
- **Validation Plan:**
  ```
  make bench          # Before: measure expandOut/expandIn throughput for high-degree nodes
  # Apply fix (preallocate with hint)
  make bench          # After: expect fewer allocator calls (measurable via custom allocator counters)
  make test           # Verify edge expansion tests pass
  ```
- **Affected Paths:** `src/engine.zig` (drainEdgeIterator)
- **Rollout Risk:** Very low. Preallocation is a pure optimization with no behavioral change.
- **Owner:** Per git blame of engine.zig.
- **SLA:** Backlog (P3)
- **Resolution:** Added `ensureTotalCapacity` preallocation in drainEdgeIterator based on adjacency block count hint. Eliminates repeated reallocations for high-degree nodes.

## PERF-0028: WAL write amplification 32KB per edge (full-page logging)

- **Status:** Won't Do
- **Severity:** P1
- **Score:** 80 (Impact 4 x Likelihood 5 x 4)
- **Confidence:** `confidence::confirmed`
- **Summary:** Every `addEdge` call writes 3-4 full 8KB pages to the WAL via `logPage()`, resulting in 24-32KB of WAL data per single edge insertion. This is a 1600x write amplification for an edge that modifies only ~20 bytes of actual data.
- **Perf Impact:** At 100K edges, the WAL grows to approximately 4.7GB. This dominates I/O bandwidth, accelerates SSD wear, and inflates recovery time (PERF-0014).
- **Evidence:**
  - `src/engine.zig:413-417` -- `logPage` pins a page, copies the full `frame.dataSlice()` (8KB) into a WAL record, then unpins.
  - `src/engine.zig:544-552` -- `addEdge` calls `logPage` for adj_out page, adj_in page, from-node page, and conditionally to-node page: 3-4 full-page WAL writes per edge.
  - Each WAL record payload = `page_size` = 8192 bytes for a change that touches ~20 bytes.
- **Root Cause:** The WAL uses full-page (physiological) logging inherited from the initial design. No delta/diff mechanism exists to log only changed bytes.
- **Fix Guidance:** Implement delta logging: instead of `frame.dataSlice()`, compute and log only the changed byte ranges (offset + length + new bytes). For `addEdge`, this reduces WAL payload from ~32KB to ~100-200 bytes per edge. Alternatively, implement ARIES-style physiological logging where the WAL records the logical operation (e.g., "insert edge entry at offset X in page Y").
- **Validation Plan:**
  ```
  make scale-bench    # Before: measure WAL size after 100K edge insertions
  # Apply fix (delta logging)
  make scale-bench    # After: expect ~100-200x reduction in WAL size per edge
  make test           # Verify crash recovery still works (WAL replay correctness)
  ls -lh data/*.wal   # Confirm WAL file size reduction
  ```
- **Affected Paths:** `src/engine.zig` (logPage, addEdge, putPropertyTxn, all mutation paths), `src/txn.zig` (logPageUpdate), WAL record format
- **Rollout Risk:** High. Changes the WAL record format, requiring a format version bump. Recovery logic must handle both old full-page and new delta records during migration. Thorough crash recovery testing is essential.
- **Owner:** Per git blame of engine.zig WAL paths.
- **SLA:** Within sprint (P1)
- **Won't Do Reason:** Requires WAL format redesign. Changes the WAL record format, requiring a format version bump. Recovery logic must handle both old full-page and new delta records during migration. High rollout risk disproportionate to current v1 scope.

## PERF-0029: fsync per auto-commit operation

- **Status:** Won't Do
- **Severity:** P1
- **Score:** 80 (Impact 4 x Likelihood 5 x 4)
- **Confidence:** `confidence::confirmed`
- **Summary:** Every auto-commit transaction calls `self.wal.sync()` (fsync) at `txn.zig:82`. On real storage devices, fsync costs 2-10ms, making single-mutation throughput cap at 100-500 ops/sec regardless of CPU speed.
- **Perf Impact:** On NVMe: ~2ms per op = 500 ops/sec max. On SATA SSD: ~5ms = 200 ops/sec. On HDD: ~10ms = 100 ops/sec. Benchmarks on tmpfs hide this because tmpfs fsync is a no-op.
- **Evidence:**
  - `src/txn.zig:81-82` -- `_ = try self.wal.appendRecord(&rec); try self.wal.sync();` inside `commit()`.
  - Every `putProperty`, `addEdge`, `addNode` with auto-commit calls `txn_manager.commit()`, triggering fsync.
- **Root Cause:** Durability guarantee requires fsync per commit, but single-operation auto-commits make this 1:1 with mutations. No group commit batching to amortize fsync across multiple concurrent transactions.
- **Fix Guidance:** Implement group commit: buffer committed WAL records for a short window (e.g., 1ms or N pending commits) and issue a single fsync for the batch. Wake all waiting committers after the group fsync. This amortizes the 2-10ms fsync cost across tens to hundreds of operations.
- **Validation Plan:**
  ```
  # Run bench on real storage (not tmpfs):
  make bench DATA_DIR=/tmp/graph-bench   # Before: measure ops/sec
  # Apply fix (group commit)
  make bench DATA_DIR=/tmp/graph-bench   # After: expect 10-50x throughput improvement
  make test                               # Verify durability guarantees maintained
  ```
- **Affected Paths:** `src/txn.zig` (commit), `src/engine.zig` (all auto-commit mutation paths)
- **Rollout Risk:** Medium. Group commit introduces a small latency window where committed data is in memory but not yet fsynced. A crash during this window loses the batch. This is the standard trade-off made by PostgreSQL, SQLite WAL mode, etc. Configurable flush interval mitigates risk.
- **Owner:** Per git blame of txn.zig.
- **SLA:** Within sprint (P1)
- **Won't Do Reason:** Requires group commit architecture. Introduces a latency window where committed data is in memory but not yet fsynced. Needs configurable flush interval and careful durability guarantee documentation. Deferred to dedicated branch.

## PERF-0030: Index rebuild uses per-ID getNode instead of scanNodes

- **Status:** Closed / Implemented
- **Severity:** P1
- **Score:** 80 (Impact 4 x Likelihood 5 x 4)
- **Confidence:** `confidence::confirmed`
- **Summary:** `rebuildLabelIndex`, `rebuildPropertyIndex`, and `rebuildEdgeIndex` in `engine_index.zig:16-82` each iterate node IDs 1..next_node_id calling `engine.node_store.getNode(id)` per ID. Each `getNode` call acquires a mutex lock, pins a page, reads the node slot, and unpins. The `scanNodes` page-scan method (added in PERF-0012) is available but not used here.
- **Perf Impact:** At 100K nodes with ~100 nodes/page, this performs ~300K individual pin/unpin + mutex acquire/release cycles across the 3 rebuild functions, versus ~3K page pins with scanNodes (100x reduction).
- **Evidence:**
  - `src/engine_index.zig:19-21` -- `while (id < engine.manifest.next_node_id) : (id += 1) { const rec = engine.node_store.getNode(id) catch continue orelse continue; }`
  - `src/engine_index.zig:38-40` -- Same pattern in `rebuildPropertyIndex`.
  - `src/engine_index.zig:67-68` -- Same pattern in `rebuildEdgeIndex`.
  - `scanNodes` was added specifically for this use case (PERF-0012) but only wired into `LabelIndex.rebuild`, not these 3 functions.
- **Root Cause:** The index rebuild functions predate the `scanNodes` optimization and were not updated to use it.
- **Fix Guidance:** Replace the `while (id < next_node_id) { getNode(id) }` loop in all three rebuild functions with `node_store.scanNodes()` iteration. The callback/iterator visits all valid node slots with a single pin per page.
- **Validation Plan:**
  ```
  make scale-bench    # Before: measure open() time at 100K and 500K nodes
  # Apply fix (use scanNodes in all 3 rebuild functions)
  make scale-bench    # After: expect ~10x reduction in index rebuild time
  make test           # Verify all index-dependent tests still pass
  ```
- **Affected Paths:** `src/engine_index.zig` (rebuildLabelIndex, rebuildPropertyIndex, rebuildEdgeIndex)
- **Rollout Risk:** Low. scanNodes is already proven in LabelIndex.rebuild. The rebuild functions are only called during `open()`, not on hot paths.
- **Owner:** Per git blame of engine_index.zig.
- **SLA:** Within sprint (P1)
- **Resolution:** Refactored all three rebuild functions (rebuildLabelIndex, rebuildPropertyIndex, rebuildEdgeIndex) to use `scanNodes` batch API instead of per-ID `getNode`. Reduces pin/unpin cycles ~100x at 100K nodes.
- **Commit:** `f55705b`

## PERF-0031: Checkpoint blocks all operations for 850ms

- **Status:** Won't Do
- **Severity:** P2
- **Score:** 48 (Impact 3 x Likelihood 4 x 4)
- **Confidence:** `confidence::suspected`
- **Summary:** The `checkpoint` function at `engine_persist.zig:213-241` runs synchronously, performing dirty page flush, free space bitmap persistence, derived index save, and label dictionary save all while holding exclusive access. No concurrent queries can be served during this window.
- **Perf Impact:** At 100K nodes, checkpoint takes ~850ms (per PERF-0018 measurements). During this time, all reads and writes are blocked. For latency-sensitive workloads, this creates periodic spikes.
- **Evidence:**
  - `src/engine_persist.zig:213-241` -- `checkpoint()` calls `doCheckpoint()`, `saveFreeStore()`, `saveDerivedIndexes()`, `saveLabelDictionary()` sequentially.
  - `src/engine_persist.zig:226-228` -- Comment explicitly states: "Synchronous checkpoint: flush dirty pages, sync files, write manifest."
  - PERF-0018 resolution improved the flush path, but the overall checkpoint is still synchronous.
- **Root Cause:** Checkpoint was designed as a stop-the-world operation for simplicity and correctness. No copy-on-write or incremental checkpoint mechanism exists.
- **Fix Guidance:** Implement incremental/concurrent checkpoint: (1) snapshot dirty page set under lock, (2) release lock, (3) flush snapshot pages while allowing concurrent reads, (4) re-acquire lock briefly to finalize manifest. Alternatively, use double-buffering or copy-on-write pages during checkpoint.
- **Validation Plan:**
  ```
  make scale-bench    # Before: measure p99 latency during checkpoint at 100K nodes
  # Apply fix (concurrent checkpoint)
  make scale-bench    # After: expect p99 latency < 10ms during checkpoint
  make test           # Verify crash safety and checkpoint correctness
  ```
- **Affected Paths:** `src/engine_persist.zig` (checkpoint), `src/buffer_pool.zig`
- **Rollout Risk:** High. Concurrent checkpoint introduces races between flushing and ongoing mutations. Requires careful ordering (WAL must be ahead of data pages) and possibly page-level COW.
- **Owner:** Per git blame of engine_persist.zig.
- **SLA:** Next quarter (P2)
- **Confirmation needed:** Profile `checkpoint()` with a timer to confirm current latency. The 850ms figure is from pre-PERF-0018 measurements; post-fix latency may be lower.
- **Won't Do Reason:** Requires fuzzy/concurrent checkpoint architecture. Introduces races between flushing and ongoing mutations, requiring page-level COW or careful ordering. High rollout risk. Deferred to post-v1.

## PERF-0032: edge_index HashMap not pre-allocated

- **Status:** Closed / Implemented
- **Severity:** P2
- **Score:** 48 (Impact 3 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **Summary:** `edge_index` at `engine_persist.zig:197` is initialized as `std.AutoHashMap(EdgeId, EdgeIndexEntry).init(allocator)` with no capacity hint. During `rebuildEdgeIndex`, insertions trigger repeated resize+rehash cycles as the map grows.
- **Perf Impact:** At 150K edges, the HashMap resizes approximately 17 times (doubling from 8 to 262144). Each resize copies and rehashes all existing entries, creating O(N log N) total work instead of O(N).
- **Evidence:**
  - `src/engine_persist.zig:197` -- `self.edge_index = std.AutoHashMap(EdgeId, EdgeIndexEntry).init(allocator);`
  - `src/engine_index.zig:63-82` -- `rebuildEdgeIndex` inserts all edges without pre-sizing.
  - Zig's AutoHashMap starts at capacity 8 and doubles; log2(150000/8) = ~14 resizes.
- **Root Cause:** The HashMap is initialized without knowledge of expected size, though `manifest.edge_count` is available.
- **Fix Guidance:** After initializing `edge_index`, call `try self.edge_index.ensureTotalCapacity(@intCast(self.manifest.edge_count))` before `rebuildEdgeIndex`. This eliminates all resize cycles.
- **Validation Plan:**
  ```
  make scale-bench    # Before: measure rebuildEdgeIndex time at 150K edges
  # Apply fix (pre-size from manifest.edge_count)
  make scale-bench    # After: expect measurable reduction in rebuild time
  make test           # Verify edge index correctness
  ```
- **Affected Paths:** `src/engine_persist.zig` (open/create), `src/engine_index.zig` (rebuildEdgeIndex)
- **Rollout Risk:** Very low. Pre-sizing is a pure optimization. Worst case: slightly over-allocated if edge_count is stale.
- **Owner:** Per git blame of engine_persist.zig.
- **SLA:** Next quarter (P2)
- **Resolution:** Added `ensureTotalCapacity(@intCast(self.manifest.edge_count))` after edge_index initialization. Eliminates all resize cycles during rebuildEdgeIndex.
- **Commit:** `696b68e`

## PERF-0033: page_table HashMap not pre-sized

- **Status:** Closed / Implemented
- **Severity:** P2
- **Score:** 48 (Impact 3 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **Summary:** The buffer pool's `page_table` at `buffer_pool.zig:86` is initialized as `std.AutoHashMap(PageKey, u32).init(allocator)` with no capacity hint. As pages are pinned during warmup, the map resizes repeatedly.
- **Perf Impact:** With a 4096-page buffer pool, approximately 12 resize+rehash cycles occur during initial warmup (log2(4096/8) = ~9, plus load factor headroom). Each resize copies and rehashes all entries.
- **Evidence:**
  - `src/buffer_pool.zig:86` -- `page_table = std.AutoHashMap(PageKey, u32).init(allocator),`
  - Buffer pool capacity is known at initialization time but not used to pre-size.
- **Root Cause:** The page_table is created without using the known `capacity` parameter to set initial size.
- **Fix Guidance:** After creating the page_table, call `try self.page_table.ensureTotalCapacity(@intCast(capacity))`. The buffer pool capacity is the exact maximum number of entries the page_table will ever hold.
- **Validation Plan:**
  ```
  make bench          # Before: measure first-run warmup time
  # Apply fix (pre-size to capacity)
  make bench          # After: expect faster warmup, fewer allocator calls
  make test           # Verify buffer pool tests pass
  ```
- **Affected Paths:** `src/buffer_pool.zig` (init)
- **Rollout Risk:** Very low. Pre-sizing to a known upper bound is a pure optimization.
- **Owner:** Per git blame of buffer_pool.zig.
- **SLA:** Next quarter (P2)
- **Resolution:** Added `ensureTotalCapacity(@intCast(capacity))` after page_table initialization. Buffer pool capacity is the exact upper bound.
- **Commit:** `3247a57`

## PERF-0034: logPage re-pins already-cached pages for WAL

- **Status:** Won't Do
- **Severity:** P2
- **Score:** 48 (Impact 3 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **Summary:** The `logPage` function at `engine.zig:413-418` pins a page by file_id and page_id, copies its data to the WAL, and unpins it. The caller (e.g., `addEdge`) has typically just written to this same page and already has the frame pinned. The re-pin is redundant: it acquires the mutex, looks up the page_table, increments pin_count, then immediately reverses all of it.
- **Perf Impact:** 4-5 extra pin/unpin cycles per `addEdge` call. Each cycle acquires the buffer pool mutex. At high throughput this creates contention on the mutex.
- **Evidence:**
  - `src/engine.zig:413-418` -- `logPage` does `buffer_pool.pin(file_id, page_id)` + `defer buffer_pool.unpin(frame_idx, false)`.
  - `src/engine.zig:544-552` -- `addEdge` calls `logPage` 3-4 times after already having the frames pinned via `putNode`/`addEdge` on the stores.
- **Root Cause:** `logPage` was designed as a self-contained helper that takes logical coordinates (file_id, page_id) rather than accepting an already-pinned frame.
- **Fix Guidance:** Add an overload `logFrame(txn_id, file_id, page_id, data: []const u8)` that accepts the data slice directly from an already-pinned frame. Callers that already have the frame pinned can use this to skip the redundant pin/unpin.
- **Validation Plan:**
  ```
  make bench          # Before: measure addEdge throughput
  # Apply fix (logFrame overload)
  make bench          # After: expect measurable reduction in mutex contention
  make test           # Verify WAL logging correctness
  ```
- **Affected Paths:** `src/engine.zig` (logPage, addEdge, putPropertyTxn, all mutation paths)
- **Rollout Risk:** Low. Adding an overload is additive. Existing `logPage` can remain for cases where the frame is not already pinned.
- **Owner:** Per git blame of engine.zig.
- **SLA:** Next quarter (P2)
- **Won't Do Reason:** Requires engine-wide API change. Adding a logFrame overload that accepts data slices instead of page coordinates requires updating all mutation paths. Medium scope change with deadlock considerations. Deferred to post-v1.

## PERF-0035: TxnManager leaks committed/aborted transaction entries

- **Status:** Closed / Implemented
- **Severity:** P2
- **Score:** 48 (Impact 3 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **Summary:** The `TxnManager.commit()` at `txn.zig:84` updates the transaction state to `.committed` but never removes the entry from `active_txns`. Similarly, `abort()` sets state to `.aborted` but does not remove. The HashMap grows unboundedly over the engine lifetime.
- **Perf Impact:** Each entry is ~24 bytes (u64 key + enum value + HashMap overhead). At 100K txn/sec, this is ~2.4MB/sec of leaked memory. Over hours of operation, this becomes significant. HashMap operations also degrade as load factor increases without removal.
- **Evidence:**
  - `src/txn.zig:84` -- `try self.active_txns.put(txn_id, .committed);` -- overwrites state but entry persists.
  - No `self.active_txns.remove(txn_id)` call exists in `commit()` or `abort()`.
  - The HashMap only grows; entries are never reclaimed.
- **Root Cause:** The transaction manager was designed to track state transitions (active -> committed/aborted) but lacks a cleanup/pruning step for terminal states.
- **Fix Guidance:** After writing the commit/abort WAL record and syncing, call `_ = self.active_txns.remove(txn_id)`. Terminal transaction states do not need to be retained in memory since the WAL provides the durable record. If state queries are needed for in-flight transactions, only `.active` entries matter.
- **Validation Plan:**
  ```
  make bench          # Before: measure RSS growth over 100K transactions
  # Apply fix (remove on commit/abort)
  make bench          # After: expect stable RSS regardless of transaction count
  make test           # Verify transaction state tests pass
  ```
- **Affected Paths:** `src/txn.zig` (commit, abort)
- **Rollout Risk:** Low. Completed transactions should not be queried from the in-memory map. If any code depends on querying committed/aborted state from the map, it would need to be updated to check the WAL or use a separate log.
- **Owner:** Per git blame of txn.zig.
- **SLA:** Next quarter (P2)
- **Resolution:** Added `_ = self.active_txns.remove(txn_id)` in both `commit()` and `abort()` after writing the terminal WAL record. Memory usage now stable regardless of transaction count.
- **Commit:** `7909789`

## PERF-0036: flushDirty holds mutex during I/O

- **Status:** Won't Do
- **Severity:** P2
- **Score:** 48 (Impact 3 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **Summary:** `flushDirty` at `buffer_pool.zig:214-223` acquires the buffer pool mutex at the top and holds it for the entire duration of flushing all dirty frames. Unlike `flushAllParallel` (which copies dirty page data and releases the lock before I/O), `flushDirty` performs synchronous I/O while holding the lock, blocking all concurrent pin/unpin operations.
- **Perf Impact:** During WAL checkpoint flush, all buffer pool operations (reads and writes) are blocked. The duration depends on the number of dirty pages and storage speed. With 1000 dirty 8KB pages on a ~500MB/s SSD, this is ~16ms of blocking.
- **Evidence:**
  - `src/buffer_pool.zig:214-216` -- `self.mutex.lock(); defer self.mutex.unlock();`
  - `src/buffer_pool.zig:217-222` -- Iterates all frames, calling `self.flushFrame(frame)` (which does I/O) while mutex is held.
  - `src/buffer_pool.zig:228+` -- `flushAll`/`flushAllParallel` in contrast copies data under lock then releases before I/O.
- **Root Cause:** `flushDirty` was implemented as a simpler version of `flushAll` without the lock-release optimization.
- **Fix Guidance:** Follow the same pattern as `flushAllParallel`: collect dirty frame indices under lock, release lock, perform I/O, re-acquire lock to clear dirty flags. Alternatively, release and re-acquire the mutex around each `flushFrame` call.
- **Validation Plan:**
  ```
  make bench          # Before: measure p99 pin latency during flushDirty
  # Apply fix (release mutex during I/O)
  make bench          # After: expect reduced pin latency spikes during flush
  make test           # Verify flush correctness and crash safety
  ```
- **Affected Paths:** `src/buffer_pool.zig` (flushDirty)
- **Rollout Risk:** Medium. Releasing the mutex during flush means pages could be modified between the dirty check and the write. Must either snapshot the page data or re-validate after write. Frame pinning protocol must prevent eviction during flush.
- **Owner:** Per git blame of buffer_pool.zig.
- **SLA:** Next quarter (P2)
- **Won't Do Reason:** Deadlock risk analysis needed. Releasing the mutex during flush means pages could be modified between the dirty check and the write. Requires snapshot or re-validation protocol. Risk disproportionate to v1 scope.

## PERF-0037: Index rebuild sequential, not parallel or merged

- **Status:** Deferred
- **Severity:** P2
- **Score:** 48 (Impact 3 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **Summary:** `rebuildDerivedIndexes` at `engine_index.zig:55-59` calls `rebuildLabelIndex`, `rebuildPropertyIndex`, and `rebuildEdgeIndex` sequentially. Each performs a full scan of all nodes (lines 19-31, 38-51, 66-82). This means the node store is scanned 3 times, each time pinning and reading every node page.
- **Perf Impact:** 3x the I/O and CPU cost of a single scan. At 500K nodes, each scan takes ~100-200ms, so the total is ~300-600ms that could be ~100-200ms with a merged scan.
- **Evidence:**
  - `src/engine_index.zig:55-59` -- Sequential calls: `rebuildLabelIndex`, `rebuildPropertyIndex`, `rebuildEdgeIndex`.
  - Each function has `var id: u64 = 1; while (id < engine.manifest.next_node_id)` -- identical iteration pattern.
- **Root Cause:** Each rebuild function was written independently for clarity and modularity. No merged scan was implemented.
- **Fix Guidance:** Create a single `rebuildAllIndexes` function that iterates nodes once and populates all three indexes in the same loop body. Alternatively, run the three rebuilds in parallel using thread pool if available (they read the same data but write to independent index structures).
- **Validation Plan:**
  ```
  make scale-bench    # Before: measure open() time at 500K nodes
  # Apply fix (merge into single scan)
  make scale-bench    # After: expect ~60% reduction in index rebuild time
  make test           # Verify all index-dependent tests pass
  ```
- **Affected Paths:** `src/engine_index.zig` (rebuildDerivedIndexes, rebuildLabelIndex, rebuildPropertyIndex, rebuildEdgeIndex)
- **Rollout Risk:** Low. Merging the scan is a refactor that does not change externally visible behavior. All three indexes are populated from the same node data.
- **Owner:** Per git blame of engine_index.zig.
- **SLA:** Next quarter (P2)
- **Deferral Reason:** Depends on PERF-0030 (now closed). With scanNodes batch API in place, merging the 3 rebuild scans into 1 is a straightforward follow-up. Deferred to next cycle.

## PERF-0038: rebuildDirectory called 2-3x per putProperty

- **Status:** Closed / Implemented
- **Severity:** P3
- **Score:** 24 (Impact 2 x Likelihood 3 x 4)
- **Confidence:** `confidence::confirmed`
- **Summary:** During `putProperty`, the per-page key directory (PERF-0023) is rebuilt via `rebuildDirectory` at multiple points: once after removal (line 383), once after same-page insert (line 376), and once in pass 2 insert (line 443). A key update that removes then inserts on the same page triggers 2 `rebuildDirectory` calls.
- **Perf Impact:** Each `rebuildDirectory` scans all entries on the page to recompute hashes and offsets. For a page with 20 entries, this is ~40 extra hash computations per putProperty update. Minor but avoidable.
- **Evidence:**
  - `src/prop_store.zig:376` -- `rebuildDirectory(data, entry_count + 1, self.page_size);` after insert on removal page.
  - `src/prop_store.zig:383` -- `rebuildDirectory(data, entry_count, self.page_size);` after removal (when insert goes to different page).
  - `src/prop_store.zig:443` -- `rebuildDirectory(data, entry_count + 1, self.page_size);` in pass 2 insert.
- **Root Cause:** The directory rebuild was added conservatively at each mutation point rather than deferred to a single call at the end of the operation.
- **Fix Guidance:** Track whether the directory needs rebuilding via a `dir_dirty` flag. Call `rebuildDirectory` once, just before unpinning the modified page. For the same-page remove+insert case, this halves the directory rebuild work.
- **Validation Plan:**
  ```
  make bench          # Before: measure putProperty throughput with updates
  # Apply fix (single rebuildDirectory per page mutation)
  make bench          # After: expect ~10-20% improvement for update-heavy workloads
  make test           # Verify directory correctness tests pass
  ```
- **Affected Paths:** `src/prop_store.zig` (putProperty)
- **Rollout Risk:** Very low. Deferring the rebuild is safe as long as it happens before unpin (which marks the page dirty and visible to other readers).
- **Owner:** Per git blame of prop_store.zig.
- **SLA:** Backlog (P3)
- **Resolution:** Deferred `rebuildDirectory` to a single call at the end of putProperty. Remove+insert on the same page now triggers only 1 directory rebuild instead of 2.
- **Commit:** `73a9b34`

## PERF-0039: Benchmark page_size mismatch (bench=4KB vs scale=8KB)

- **Status:** Closed / Implemented
- **Severity:** P3
- **Score:** 16 (Impact 2 x Likelihood 2 x 4)
- **Confidence:** `confidence::confirmed`
- **Summary:** The `bench` benchmark target at `benchmarks/bench.zig:88` hardcodes `page_size = 4096`, while the default engine configuration and `scale-bench` use `page_size = 8192`. This makes benchmark results incomparable between the two targets and means `bench` does not test the production page size.
- **Perf Impact:** No direct runtime impact, but benchmark results are misleading. Page size affects buffer pool behavior, property chain layout, adjacency block capacity, and I/O patterns.
- **Evidence:**
  - `benchmarks/bench.zig:87-88` -- `fn makeConfig() GraphConfig { return .{ .page_size = 4096, ... }; }`
  - Default `GraphConfig` page_size is 8192.
- **Root Cause:** Benchmark config was written independently and not synchronized with default config.
- **Fix Guidance:** Either (a) change bench to use the default page_size (8192), or (b) parameterize page_size so both 4KB and 8KB are benchmarked, or (c) document the discrepancy in bench output.
- **Validation Plan:**
  ```
  # After fix, verify bench and scale-bench use same page_size:
  grep -n page_size benchmarks/bench.zig benchmarks/scale_bench.zig
  make bench && make scale-bench   # Results should be comparable
  ```
- **Affected Paths:** `benchmarks/bench.zig`
- **Rollout Risk:** Very low. Changing bench page_size may shift absolute numbers but improves comparability.
- **Owner:** Per git blame of benchmarks/.
- **SLA:** Backlog (P3)
- **Resolution:** Changed `benchmarks/bench.zig` to use `page_size = 8192` matching the default engine configuration. Benchmark results now comparable with scale-bench.
- **Commit:** `5f54e4f`

## PERF-0040: No p50/p95/p99 latency percentiles in benchmarks

- **Status:** Deferred
- **Severity:** P3
- **Score:** 12 (Impact 2 x Likelihood 1.5 x 4)
- **Confidence:** `confidence::confirmed`
- **Summary:** The benchmark suite reports only total time, throughput (ops/sec), and average latency. No percentile latency metrics (p50, p95, p99) are collected. Tail latency issues (e.g., from checkpoint stalls, resize pauses, or GC-like events) are invisible in benchmark output.
- **Perf Impact:** No direct runtime impact, but prevents detection of latency outliers that matter for real workloads. A system averaging 1ms but spiking to 100ms at p99 looks identical to one with consistent 1ms latency.
- **Evidence:**
  - `benchmarks/bench.zig` -- Timer.start/read used for total elapsed time. No histogram or sorted-sample collection.
  - Benchmark output format shows only aggregate metrics.
- **Root Cause:** Benchmark was designed for throughput measurement, not latency distribution analysis.
- **Fix Guidance:** Add a simple histogram collector: store per-operation latencies in a pre-allocated array, sort after the run, and report p50/p95/p99/max. Alternatively, use a streaming quantile sketch (e.g., t-digest or simple sorted reservoir) to avoid storing all samples.
- **Validation Plan:**
  ```
  # After fix, run benchmarks and verify percentile output:
  make bench          # Should now report p50, p95, p99 columns
  # Intentionally introduce a stall (e.g., sleep in checkpoint) and verify p99 reflects it
  ```
- **Affected Paths:** `benchmarks/bench.zig`, `benchmarks/scale_bench.zig` (if exists)
- **Rollout Risk:** Very low. Additive change to benchmark reporting. Does not affect engine code.
- **Owner:** Per git blame of benchmarks/.
- **SLA:** Backlog (P3)
- **Deferral Reason:** Benchmark improvement with no correctness impact. Additive change to reporting. Deferred to next cycle.
