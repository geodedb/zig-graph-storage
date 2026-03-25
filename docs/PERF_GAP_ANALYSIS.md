# Performance Gap Analysis

**Last updated:** 2026-03-25
**Source:** Full Codebase Audit (docs/AUDIT_REPORT.md)

## Summary

| Status | Count |
|--------|-------|
| Open | 0 |
| Closed | 6 |
| Won't Do | 2 |
| Deferred | 7 |

---

## PERF-0001: PropStore.getProperty linear scan with heap alloc per entry

- **Status:** Closed
- **Severity:** P0
- **Resolution:** Non-matching entries now skipped by encoded size via `encodedSizeFromBytes`. Only decode on key match. Same optimization applied to `removeProperty`.
- **Commit:** `0235d9b`

## PERF-0002: PropStore.putProperty 3-pass chain traversal

- **Status:** Deferred
- **Severity:** P0
- **Description:** Significant refactor of prop_store internals. Should be paired with a dedicated benchmark to validate improvement. Deferred to post-v1.

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

- **Status:** Deferred
- **Severity:** P1
- **Description:** Requires WAL interface change (caller-provided buffer). Deferred to post-v1.

## PERF-0010: Double CRC in WAL append

- **Status:** Deferred
- **Severity:** P1
- **Description:** Coupled with PERF-0009; serialize/checksum refactor. Deferred to post-v1.

## PERF-0011: LabelIndex.addNode O(n) sorted insert

- **Status:** Deferred
- **Severity:** P1
- **Description:** Requires switching to B+tree for posting lists. Significant refactor. Deferred to post-v1.

## PERF-0012: getNode pin/unpin per call in scan loops

- **Status:** Deferred
- **Severity:** P2
- **Description:** Requires new scanPage API and updating all call sites. Deferred to post-v1.

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
