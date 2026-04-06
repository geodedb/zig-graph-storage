# Quality Gap Analysis

**Last updated:** 2026-04-06
**Source:** Full Codebase Audit (docs/AUDIT_REPORT.md)

## Summary

| Severity | Open | Closed | Won't Do | Deferred |
|----------|------|--------|----------|----------|
| Critical | 0    | 0      | 0        | 0        |
| High     | 0    | 6      | 0        | 0        |
| Medium   | 0    | 8      | 1        | 2        |
| Low      | 0    | 4      | 0        | 0        |
| Info     | 0    | 0      | 0        | 0        |
| **Total** | **0** | **18** | **1**  | **2**    |

### Top 5 Risks (All Closed)

1. **QUAL-0009** -- `page_allocator` in vtable wrappers -- **Closed** (caller allocator threaded through)
2. **QUAL-0010** -- O(N) index rebuild on every checkpoint -- **Closed** (redundant rebuild removed)
3. **QUAL-0011** -- `deinit`/`cleanupResources` duplication -- **Closed** (delegates to cleanupResources)
4. **QUAL-0016** -- Missing `errdefer` chain -- **Closed** (11 errdefer handlers added)
5. **QUAL-0017** -- Recovery writes manifest to slot A only -- **Closed** (writes both slots)

---

## Stack-Ranked Findings

| Rank | ID | Severity | PriorityScore | Category | Finding | Component | Evidence | Issue URL | Fix Summary | Owner | ETA/SLA | Status |
|------|----|----------|---------------|----------|---------|-----------|----------|-----------|-------------|-------|---------|--------|
| 1 | QUAL-0009 | High | 80 | perf | page_allocator in vtable wrappers | interface.zig | L299, L353 | -- | Caller allocator threaded through WrapperState | -- | S | Closed |
| 2 | QUAL-0010 | High | 80 | perf | O(N) index rebuild on every checkpoint | engine.zig | L981 | -- | Removed redundant rebuild (same as PERF-0019) | -- | M | Closed |
| 3 | QUAL-0011 | High | 64 | maintainability | deinit/cleanupResources duplication | engine.zig | L486-507, L557-578 | -- | deinit delegates to cleanupResources | -- | S | Closed |
| 4 | QUAL-0012 | Medium | 48 | cleanup | Format violations on main | interface.zig, prop_store.zig, buffer_pool.zig, adj_store.zig | 4 files | -- | zig fmt applied | -- | S | Closed |
| 5 | QUAL-0013 | Medium | 48 | maintainability | Duplicated WrapperState blocks | interface.zig | L293-319, L349-373 | -- | Shared helper extracted | -- | S | Closed |
| 6 | QUAL-0014 | Medium | 48 | maintainability | Repeated adjacency-scan pattern | engine.zig | L1000-1074 | -- | findEdgePropHead helper extracted | -- | S | Closed |
| 7 | QUAL-0015 | Medium | 48 | architecture | engine.zig exceeds 800-line guideline | engine.zig | 1695 lines | -- | Standalone refactor needed | -- | L | Deferred |
| 8 | QUAL-0016 | Medium | 48 | maintainability | Missing errdefer chain in initSubsystems | engine.zig | L254-297 | -- | 11 errdefer handlers added | -- | S | Closed |
| 9 | QUAL-0017 | Medium | 48 | architecture | Recovery writes manifest to slot A only | recovery.zig | L196-199 | -- | Writes both slots A and B | -- | S | Closed |
| 10 | QUAL-0018 | Medium | 36 | api-contract | Inconsistent error semantics for missing nodes | engine.zig | L1049, L997 | -- | Aligned to error.NodeNotFound | -- | S | Closed |
| 11 | QUAL-0019 | Low | 20 | api-contract | PropIterator returns borrowed slices | prop_store.zig | L130-134 | -- | Doc comment added | -- | S | Closed |
| 12 | QUAL-0020 | Low | 8 | cleanup | Unused import in backup.zig | backup.zig | L420 | -- | Import removed | -- | S | Closed |
| 13 | QUAL-0021 | Low | 20 | docs | Architecture doc stale | docs/architecture.md | L46-49, L460-464 | -- | Diagrams updated | -- | S | Closed |

---

## Findings by Category

### perf

| ID | Severity | Finding |
|----|----------|---------|
| QUAL-0009 | High | page_allocator in vtable wrappers -- memory leak |
| QUAL-0010 | High | O(N) index rebuild on every checkpoint |

### maintainability

| ID | Severity | Finding |
|----|----------|---------|
| QUAL-0011 | High | deinit/cleanupResources duplication |
| QUAL-0013 | Medium | Duplicated WrapperState blocks |
| QUAL-0014 | Medium | Repeated adjacency-scan pattern |
| QUAL-0016 | Medium | Missing errdefer chain in initSubsystems |

### architecture

| ID | Severity | Finding |
|----|----------|---------|
| QUAL-0015 | Medium | engine.zig exceeds 800-line guideline |
| QUAL-0017 | Medium | Recovery writes manifest to slot A only |

### api-contract

| ID | Severity | Finding |
|----|----------|---------|
| QUAL-0018 | Medium | Inconsistent error semantics for missing nodes |
| QUAL-0019 | Low | PropIterator returns borrowed slices |

### cleanup

| ID | Severity | Finding |
|----|----------|---------|
| QUAL-0012 | Medium | Format violations on main |
| QUAL-0020 | Low | Unused import in backup.zig |

### docs

| ID | Severity | Finding |
|----|----------|---------|
| QUAL-0021 | Low | Architecture doc stale |

---

## Roadmap

All quick-win and medium items are closed. One strategic item remains deferred:

### Deferred

| ID | Fix |
|----|-----|
| QUAL-0015 | Split engine.zig into focused modules (engine_core, vtable, persistence, edge helpers, tests) -- standalone refactor, own branch |

---

## Closed / Resolved Items

### QUAL-0001: close() returns void, silently swallows checkpoint/save errors

- **Status:** Closed
- **Severity:** High
- **Resolution:** Changed `close()` to `!void`, propagates checkpoint and label dict errors. Added `cleanupResources()` for guaranteed cleanup. Updated vtable signature. (Closed together with GAP-0006.)
- **Commit:** `3d201a2`

### QUAL-0002: Persistence tests don't assert durability

- **Status:** Closed
- **Severity:** High
- **Resolution:** Removed tautological `expect(true)`. Replaced hedging assertions with hard checks. Added `QUAL-0002: full durability round-trip` integration test verifying 3 nodes, 3 edges, labels, and adjacency survive checkpoint+close+reopen.
- **Commit:** `53f1b05`

### QUAL-0003: Silent error swallow in recovery WAL dir creation

- **Status:** Closed
- **Severity:** High
- **Resolution:** Changed `catch {}` to `try` on `makePath` call in `recovery.zig`.
- **Commit:** `5d1fa48`

### QUAL-0004: Duplicated init sequence in create() and open()

- **Status:** Closed
- **Severity:** Medium
- **Resolution:** Extracted `initSubsystems()` private helper covering free space, WAL, TxnManager, stores, labels, and checkpointer. Net reduction ~29 lines.
- **Commit:** `674f367`

### QUAL-0005: Deep nesting in B+tree operations

- **Status:** Closed
- **Severity:** Medium
- **Resolution:** Extracted `deinitChildren`, `findLeaf`, `collectRange` helpers. `search` refactored to use `findLeaf`. Max nesting reduced from 7 to 4.
- **Commit:** `524786e`

### QUAL-0006: getEdge() stub returns null unconditionally

- **Status:** Closed
- **Severity:** Medium
- **Resolution:** Changed to return `error.EdgeIndexNotImplemented` with doc comment explaining the limitation. Makes the limitation explicit rather than silent null.
- **Commit:** `3d201a2`

### QUAL-0007: anyerror return types in vtable (92 instances)

- **Status:** Won't Do
- **Severity:** Medium
- **Description:** Intentional Zig language limitation. Dynamic dispatch via vtables requires `anyerror` because concrete error sets are not known at the interface level. This is by-design.

### QUAL-0008: No binary format specification document

- **Status:** Closed
- **Severity:** Medium
- **Description:** Comprehensive binary format specification added in `docs/format-spec.md`, covering all on-disk structures: page headers, node records, edge entries, property encoding, manifest, backup, WAL records, registry, index catalog, and free space bitmap.
