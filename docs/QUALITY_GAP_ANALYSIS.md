# Quality Gap Analysis

**Last updated:** 2026-03-25
**Source:** Full Codebase Audit (docs/AUDIT_REPORT.md)

## Summary

| Status | Count |
|--------|-------|
| Open | 0 |
| Closed | 4 |
| Won't Do | 1 |
| Deferred | 3 |

---

## QUAL-0001: close() returns void, silently swallows checkpoint/save errors

- **Status:** Closed
- **Severity:** High
- **Resolution:** Changed `close()` to `!void`, propagates checkpoint and label dict errors. Added `cleanupResources()` for guaranteed cleanup. Updated vtable signature. (Closed together with GAP-0006.)
- **Commit:** `3d201a2`

## QUAL-0002: Persistence tests don't assert durability

- **Status:** Closed
- **Severity:** High
- **Resolution:** Removed tautological `expect(true)`. Replaced hedging assertions with hard checks. Added `QUAL-0002: full durability round-trip` integration test verifying 3 nodes, 3 edges, labels, and adjacency survive checkpoint+close+reopen.
- **Commit:** `53f1b05`

## QUAL-0003: Silent error swallow in recovery WAL dir creation

- **Status:** Closed
- **Severity:** High
- **Resolution:** Changed `catch {}` to `try` on `makePath` call in `recovery.zig`.
- **Commit:** `5d1fa48`

## QUAL-0004: Duplicated init sequence in create() and open()

- **Status:** Deferred
- **Severity:** Medium
- **Description:** Refactoring only; no correctness or security impact. Deferred to post-v1.

## QUAL-0005: Deep nesting in B+tree operations

- **Status:** Deferred
- **Severity:** Medium
- **Description:** Style only; no correctness or security impact. Deferred to post-v1.

## QUAL-0006: getEdge() stub returns null unconditionally

- **Status:** Closed
- **Severity:** Medium
- **Resolution:** Changed to return `error.EdgeIndexNotImplemented` with doc comment explaining the limitation. Makes the limitation explicit rather than silent null.
- **Commit:** `3d201a2`

## QUAL-0007: anyerror return types in vtable (92 instances)

- **Status:** Won't Do
- **Severity:** Medium
- **Description:** Intentional Zig language limitation. Dynamic dispatch via vtables requires `anyerror` because concrete error sets are not known at the interface level. This is by-design.

## QUAL-0008: No binary format specification document

- **Status:** Deferred
- **Severity:** Medium
- **Description:** Documentation only; large effort, no code impact. Deferred to post-v1.
