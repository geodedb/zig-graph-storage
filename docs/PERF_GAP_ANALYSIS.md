# Performance Gap Analysis

**Last updated:** 2026-03-25
**Source:** Full Codebase Audit (docs/AUDIT_REPORT.md)

## Summary

| Status | Count |
|--------|-------|
| Open | 0 |
| Closed | 11 |
| Won't Do | 2 |
| Deferred | 2 |

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
