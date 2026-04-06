# Performance Gap Analysis

**Last updated:** 2026-04-06
**Source:** Full Codebase Audit (docs/AUDIT_REPORT.md)

## Summary

| Status | Count |
|--------|-------|
| Open | 0 |
| Closed | 17 |
| Won't Do | 2 |
| Deferred | 5 |

### Remaining Open Risks

No open items remain. Two items are deferred (format/architecture changes).

### Stack-Ranked Findings (All Resolved)

| Rank | Severity | Score | Finding | Component | Evidence | Issue URL | Fix Summary | SLA | Status |
|------|----------|-------|---------|-----------|----------|-----------|-------------|-----|--------|
| 1 | P0 | 100 | Full index rebuild on checkpoint | engine.zig:981 | rebuildDerivedIndexes() walks all nodes | -- | Removed redundant rebuild | Immediate | Closed |
| 2 | P0 | 100 | close() redundant index rebuild | engine.zig:534 | rebuildDerivedIndexes() after checkpoint | -- | Removed redundant rebuild | Immediate | Closed |
| 3 | P1 | 80 | Double chain traversal in putProperty | prop_store.zig:170-310 | Pass 2 rescans from head after Pass 1 remove | -- | Single-pass implementation | Within sprint | Closed |
| 4 | P1 | 80 | Heap alloc per property encode | property.zig:41-44 | allocator.alloc on every encode | -- | encodeInto + stack buffer | Within sprint | Closed |
| 5 | P1 | 64 | O(n) property lookup per key | prop_store.zig:57-91 | Linear scan of entries per page chain | -- | Format change required | Within sprint | Deferred |
| 6 | P2 | 48 | Redundant CRC32C when AES-GCM active | pager.zig:57-63 | computeChecksum after GCM decryption | -- | Skip CRC when GCM active | Next quarter | Closed |
| 7 | P2 | 48 | Parallel flush full data buffer copy | buffer_pool.zig:263 | dirty_count * page_size heap alloc | -- | Architecture change needed | Next quarter | Deferred |
| 8 | P3 | 24 | No benchmark suite in CI | .gitlab-ci.yml | No bench targets in pipeline | -- | Benchmark CI job added | Backlog | Closed |
| 9 | P3 | 16 | ArrayList growth in drainEdgeIterator | engine.zig:764 | No preallocation, repeated reallocs | -- | Preallocation added | Backlog | Closed |

### Findings by Area

**App (engine, stores, property):** PERF-0019 (Closed), PERF-0020 (Closed), PERF-0021 (Closed), PERF-0022 (Closed), PERF-0023 (Deferred), PERF-0027 (Closed)
**Infra (pager, buffer pool):** PERF-0024 (Closed), PERF-0025 (Deferred)
**CI:** PERF-0026 (Closed)

### Roadmap

All quick-win and medium items are closed. Two items remain deferred:

**Deferred:**
- PERF-0023: In-page property index (requires on-disk format change)
- PERF-0025: Chunked flush (requires architecture change to buffer pool)

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

- **Status:** Deferred
- **Severity:** P1
- **Score:** 64 (Impact 4 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **Summary:** `getProperty` at prop_store.zig:57-91 performs a linear scan of all entries across the page chain for every key lookup. The PropertyChainIndex only accelerates negative lookups (key not present), not positive ones.
- **Perf Impact:** For nodes with many properties (10+ entries across multiple pages), every read is O(entries). Traversal algorithms accessing properties per-hop are linearly penalized.
- **Evidence:**
  - `src/prop_store.zig:57-91` -- `while (current_page != 0)` outer loop with inner `while (i < entry_count)` scan.
  - Skip-by-size optimization (PERF-0001) avoids decoding non-matching values but still scans all keys sequentially.
- **Root Cause:** No in-page indexing structure; entries are stored as a flat packed array.
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
- **Deferral Reason:** Requires on-disk page format change (in-page offset table). Needs coordinated format-spec.md update and migration path. Deferred to dedicated branch.

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
