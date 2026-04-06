# Quality Gap Analysis

**Last updated:** 2026-04-06 (gap closure pass)
**Source:** Full Codebase Audit (docs/AUDIT_REPORT.md)

## Summary

| Severity | Open | Closed | Won't Do | Deferred |
|----------|------|--------|----------|----------|
| Critical | 0    | 0      | 0        | 0        |
| High     | 0    | 8      | 0        | 0        |
| Medium   | 0    | 11     | 1        | 2        |
| Low      | 0    | 6      | 0        | 1        |
| Info     | 0    | 0      | 0        | 0        |
| **Total** | **0** | **25** | **1** | **3**   |

### Top 5 Risks

1. **QUAL-0022** -- Memory leak in wrapPropIterator (State not freed on deinit) -- **High** (PriorityScore 80)
2. **QUAL-0023** -- removeProperty silently returns on corrupt data instead of error -- **High** (PriorityScore 64)
3. **QUAL-0024** -- checkIntegrity swallows all I/O errors, masking failures -- **Medium** (PriorityScore 48)
4. **QUAL-0025** -- No test for uncommitted transaction recovery (ARIES guarantee) -- **Medium** (PriorityScore 48)
5. **QUAL-0028** -- Silent catch{} in label_store.zig causes page leaks -- **Medium** (PriorityScore 36)

---

## Stack-Ranked Findings

| Rank | ID | Severity | PriorityScore | Category | Finding | Component | Evidence | Issue URL | Fix Summary | Owner | ETA/SLA | Status |
|------|----|----------|---------------|----------|---------|-----------|----------|-----------|-------------|-------|---------|--------|
| 1 | QUAL-0009 | High | 80 | perf | page_allocator in vtable wrappers | interface.zig | L299, L353 | -- | Caller allocator threaded through WrapperState | -- | S | Closed |
| 2 | QUAL-0010 | High | 80 | perf | O(N) index rebuild on every checkpoint | engine.zig | L981 | -- | Removed redundant rebuild (same as PERF-0019) | -- | M | Closed |
| 3 | QUAL-0022 | High | 80 | maintainability | Memory leak in wrapPropIterator -- State not freed on deinit | interface.zig | L424-427 | -- | Added `self.alloc.destroy(self)` in State.deinit | -- | S | Closed |
| 4 | QUAL-0023 | High | 64 | api-contract | removeProperty silently returns on corrupt data | prop_store.zig | L514-517 | -- | Returns `error.DataCorruption` instead of silent return | -- | S | Closed |
| 5 | QUAL-0011 | High | 64 | maintainability | deinit/cleanupResources duplication | engine.zig | L486-507, L557-578 | -- | deinit delegates to cleanupResources | -- | S | Closed |
| 6 | QUAL-0024 | Medium | 48 | maintainability | checkIntegrity swallows all I/O errors | engine_integrity.zig | L77, L92, L96 | -- | I/O errors tracked in integrity report instead of swallowed | -- | S | Closed |
| 7 | QUAL-0025 | Medium | 48 | tests | No test for uncommitted transaction recovery | recovery.zig | -- | -- | Added test: uncommitted txn recovery discards writes | -- | M | Closed |
| 8 | QUAL-0026 | Medium | 48 | maintainability | putProperty 201 lines with 6+ nesting levels | prop_store.zig | L277-477 | -- | Decomposed into helper functions | -- | M | Closed |
| 9 | QUAL-0027 | Medium | 48 | architecture | 4 files over 800-line guideline | recovery.zig (1183), prop_store.zig (1147), backup.zig (958), buffer_pool.zig (922) | wc -l | -- | Extract helpers/tests into separate files | -- | L | Deferred |
| 10 | QUAL-0012 | Medium | 48 | cleanup | Format violations on main | interface.zig, prop_store.zig, buffer_pool.zig, adj_store.zig | 4 files | -- | zig fmt applied | -- | S | Closed |
| 11 | QUAL-0013 | Medium | 48 | maintainability | Duplicated WrapperState blocks | interface.zig | L293-319, L349-373 | -- | Shared helper extracted | -- | S | Closed |
| 12 | QUAL-0014 | Medium | 48 | maintainability | Repeated adjacency-scan pattern | engine.zig | L1000-1074 | -- | findEdgePropHead helper extracted | -- | S | Closed |
| 13 | QUAL-0015 | Medium | 48 | architecture | engine.zig exceeds 800-line guideline | engine.zig | Was 1695, now 777 lines | -- | Decomposed into engine_persist.zig, engine_index.zig, engine_edge_props.zig, engine_integrity.zig | -- | L | Closed |
| 14 | QUAL-0016 | Medium | 48 | maintainability | Missing errdefer chain in initSubsystems | engine.zig | L254-297 | -- | 11 errdefer handlers added | -- | S | Closed |
| 15 | QUAL-0017 | Medium | 48 | architecture | Recovery writes manifest to slot A only | recovery.zig | L196-199 | -- | Writes both slots A and B | -- | S | Closed |
| 16 | QUAL-0028 | Medium | 36 | maintainability | Silent catch{} in label_store.zig -- page leaks | label_store.zig | L64, L78 | -- | Propagated var_store.free errors with `try` | -- | S | Closed |
| 17 | QUAL-0018 | Medium | 36 | api-contract | Inconsistent error semantics for missing nodes | engine.zig | L1049, L997 | -- | Aligned to error.NodeNotFound | -- | S | Closed |
| 18 | QUAL-0029 | Low | 20 | cleanup | 4 unused imports in engine decomposition files | engine_index.zig:6, engine_edge_props.zig:12, engine_integrity.zig:6,8 | zig build warnings | -- | Removed unused imports | -- | S | Closed |
| 19 | QUAL-0030 | Low | 16 | tests | Hardcoded 4096 page size in integrity.zig tests | integrity.zig | L51, L72, L93 | -- | Replaced with named constant | -- | S | Closed |
| 20 | QUAL-0031 | Low | 12 | maintainability | 7x duplicated TestEnv boilerplate across store tests | 7 store test files | ~25-line init/deinit blocks | -- | Extract shared test_helpers.zig | -- | M | Deferred |
| 21 | QUAL-0019 | Low | 20 | api-contract | PropIterator returns borrowed slices | prop_store.zig | L130-134 | -- | Doc comment added | -- | S | Closed |
| 22 | QUAL-0020 | Low | 8 | cleanup | Unused import in backup.zig | backup.zig | L420 | -- | Import removed | -- | S | Closed |
| 23 | QUAL-0021 | Low | 20 | docs | Architecture doc stale | docs/architecture.md | L46-49, L460-464 | -- | Diagrams updated | -- | S | Closed |

---

## Findings by Category

### perf

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| QUAL-0009 | High | page_allocator in vtable wrappers -- memory leak | Closed |
| QUAL-0010 | High | O(N) index rebuild on every checkpoint | Closed |

### maintainability

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| QUAL-0022 | High | Memory leak in wrapPropIterator -- State not freed on deinit | Closed |
| QUAL-0011 | High | deinit/cleanupResources duplication | Closed |
| QUAL-0024 | Medium | checkIntegrity swallows all I/O errors | Closed |
| QUAL-0026 | Medium | putProperty 201 lines with 6+ nesting levels | Closed |
| QUAL-0028 | Medium | Silent catch{} in label_store.zig causes page leaks | Closed |
| QUAL-0013 | Medium | Duplicated WrapperState blocks | Closed |
| QUAL-0014 | Medium | Repeated adjacency-scan pattern | Closed |
| QUAL-0016 | Medium | Missing errdefer chain in initSubsystems | Closed |
| QUAL-0031 | Low | 7x duplicated TestEnv boilerplate | Deferred |

### architecture

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| QUAL-0027 | Medium | 4 files over 800-line guideline | Deferred |
| QUAL-0015 | Medium | engine.zig exceeds 800-line guideline | Closed |
| QUAL-0017 | Medium | Recovery writes manifest to slot A only | Closed |

### api-contract

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| QUAL-0023 | High | removeProperty silently returns on corrupt data | Closed |
| QUAL-0018 | Medium | Inconsistent error semantics for missing nodes | Closed |
| QUAL-0019 | Low | PropIterator returns borrowed slices | Closed |

### tests

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| QUAL-0025 | Medium | No test for uncommitted transaction recovery | Closed |
| QUAL-0030 | Low | Hardcoded 4096 page size in integrity.zig tests | Closed |

### cleanup

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| QUAL-0029 | Low | 4 unused imports in engine decomposition files | Closed |
| QUAL-0012 | Medium | Format violations on main | Closed |
| QUAL-0020 | Low | Unused import in backup.zig | Closed |

### docs

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| QUAL-0021 | Low | Architecture doc stale | Closed |

---

## Roadmap

### Quick Wins (< 1 day)

| ID | Severity | Fix |
|----|----------|-----|
| QUAL-0022 | High | Add `self.alloc.destroy(self)` in `wrapPropIterator` State.deinit (1-line fix, matches sliceToEdgeIterator pattern) |
| QUAL-0023 | High | Replace silent `catch { return; }` with `return error.DataCorruption` in removeProperty |
| QUAL-0024 | Medium | Replace `catch null` in checkIntegrity with error propagation or explicit error counting |
| QUAL-0028 | Medium | Propagate `var_store.free` errors in label_store.zig L64, L78 (change `catch {}` to `try`) |
| QUAL-0029 | Low | Remove 4 unused imports in engine decomposition files |
| QUAL-0030 | Low | Replace hardcoded 4096 with parameterized constant in integrity.zig tests |

### Medium (1-5 days)

| ID | Severity | Fix |
|----|----------|-----|
| QUAL-0025 | Medium | Add uncommitted-transaction-recovery test: write without commit, crash, recover, assert discarded |
| QUAL-0026 | Medium | Decompose putProperty into find-and-remove + insert helpers |
| QUAL-0031 | Low | Extract shared TestEnv into test_helpers.zig, update 7 store test files |

### Strategic (> 5 days)

| ID | Severity | Fix |
|----|----------|-----|
| QUAL-0027 | Medium | Split recovery.zig (1183), prop_store.zig (1147), backup.zig (958), buffer_pool.zig (922) into focused modules |

---

## Open Findings Detail

### QUAL-0022: Memory leak in wrapPropIterator -- State not freed on deinit

- **Status:** Closed / Implemented
- **Severity:** High
- **PriorityScore:** 80 (Impact 4 x Likelihood 5 x 4)
- **Category:** maintainability
- **Confidence:** confidence::confirmed
- **Summary:** `wrapPropIterator` in `src/interface.zig` allocates a `State` struct via `allocator.create(State)` at L430, but the `State.deinit` function at L424-427 only calls `self.iter.deinit()` -- it never calls `self.alloc.destroy(self)`. Every PropertyIterator produced through the vtable leaks ~24 bytes.
- **Evidence:** `src/interface.zig:424-427`:
  ```zig
  fn deinit(vp: *anyopaque) void {
      const self: *@This() = @ptrCast(@alignCast(vp));
      self.iter.deinit();
  }
  ```
  Compare with the correct pattern in `sliceToEdgeIterator` at L461-464:
  ```zig
  fn deinit(vp: *anyopaque) void {
      const self: *@This() = @ptrCast(@alignCast(vp));
      self.alloc.free(self.entries);
      self.alloc.destroy(self);
  }
  ```
- **Root cause:** Omission during initial vtable wrapper implementation; the edge iterator was written correctly but the pattern was not carried to the property iterator.
- **Recommended change:** Add `self.alloc.destroy(self);` after `self.iter.deinit();` in State.deinit.
- **Acceptance criteria:** `State.deinit` frees both the inner iterator and the State allocation. No leak detected under `GeneralPurposeAllocator` leak checking in tests.
- **Verification:** Run existing property iterator tests under GPA with leak detection enabled; they should pass without leak warnings.
- **Affected paths:** `src/interface.zig`
- **Effort:** S
- **Resolution:** Added `self.alloc.destroy(self)` after `self.iter.deinit()` in State.deinit, matching the sliceToEdgeIterator pattern. No leak warnings under GPA.
- **Commit:** `f773926`

### QUAL-0023: removeProperty silently returns on corrupt data

- **Status:** Closed / Implemented
- **Severity:** High
- **PriorityScore:** 64 (Impact 4 x Likelihood 4 x 4)
- **Category:** api-contract
- **Confidence:** confidence::confirmed
- **Summary:** In `src/prop_store.zig:514-517`, `encodedSizeFromBytes` failure is caught with a bare `catch { ... return; }`, which silently swallows data corruption instead of propagating `error.DataCorruption`.
- **Evidence:** `src/prop_store.zig:514-517`:
  ```zig
  const val_size = encodedSizeFromBytes(data[offset..]) catch {
      self.buffer_pool.unpin(frame_idx, false);
      return;
  };
  ```
- **Root cause:** Defensive coding that chose silence over error propagation.
- **Recommended change:** Return `error.DataCorruption` after unpinning the frame, or at minimum log a diagnostic.
- **Acceptance criteria:** Corrupt property data in removeProperty surfaces as a named error, not silent success.
- **Verification:** Write a test that corrupts property bytes and calls removeProperty; assert it returns `error.DataCorruption`.
- **Affected paths:** `src/prop_store.zig`
- **Effort:** S
- **Resolution:** Replaced silent `catch { return; }` with `return error.DataCorruption` after unpinning. Test verifies corrupt data returns error.
- **Commit:** `29a5478`

### QUAL-0024: checkIntegrity swallows all I/O errors

- **Status:** Closed / Implemented
- **Severity:** Medium
- **PriorityScore:** 48 (Impact 3 x Likelihood 4 x 4)
- **Category:** maintainability
- **Confidence:** confidence::confirmed
- **Summary:** In `src/engine_integrity.zig`, `getNode` and `iter.next()` failures are caught as `catch null` at L77, L92, and L96, treating I/O errors identically to "not found". This means the integrity check reports a clean database when it could not actually read the data.
- **Evidence:** `src/engine_integrity.zig:77`:
  ```zig
  if (engine.node_store.getNode(id) catch null) |rec| {
  ```
  `src/engine_integrity.zig:96`:
  ```zig
  while (iter.next() catch null) |_| {
  ```
- **Root cause:** Simplification during extraction from engine.zig.
- **Recommended change:** Distinguish I/O errors from "not found"; count I/O errors in the integrity report or propagate them.
- **Acceptance criteria:** I/O errors during integrity check are either (a) counted as errors in the report or (b) propagated to the caller.
- **Verification:** Mock an I/O failure in the node store; assert integrity report shows errors (not clean).
- **Affected paths:** `src/engine_integrity.zig`
- **Effort:** S
- **Resolution:** Replaced `catch null` with error tracking in integrity check. I/O errors now counted in the integrity report instead of being silently swallowed.
- **Commit:** `31fd406`

### QUAL-0025: No test for uncommitted transaction recovery

- **Status:** Closed / Implemented
- **Severity:** Medium
- **PriorityScore:** 48 (Impact 4 x Likelihood 3 x 4)
- **Category:** tests
- **Confidence:** confidence::confirmed
- **Summary:** `recovery.zig` tests cover clean recovery and committed transaction replay, but no test verifies that uncommitted transactions are discarded during recovery. This is a core ARIES guarantee that is untested.
- **Root cause:** Tests focused on the happy path during initial implementation.
- **Recommended change:** Add a test that: (1) starts a transaction, (2) writes data, (3) simulates crash without commit, (4) runs recovery, (5) asserts the uncommitted writes are not present.
- **Acceptance criteria:** Test exists and passes, confirming uncommitted transactions are rolled back.
- **Verification:** `zig build test` passes with the new test.
- **Affected paths:** `src/recovery.zig` (test section)
- **Effort:** M
- **Resolution:** Added test: starts transaction, writes data, simulates crash without commit, runs recovery, asserts uncommitted writes are discarded. Confirms ARIES guarantee.
- **Commit:** `46453bb`

### QUAL-0026: putProperty 201 lines with 6+ nesting levels

- **Status:** Closed / Implemented
- **Severity:** Medium
- **PriorityScore:** 48 (Impact 3 x Likelihood 4 x 4)
- **Category:** maintainability
- **Confidence:** confidence::confirmed
- **Summary:** `putProperty` in `src/prop_store.zig:277-477` is 201 lines with 6+ levels of nesting, violating the <50-line function and <4-level nesting guidelines.
- **Root cause:** Organic growth as property encoding edge cases were handled.
- **Recommended change:** Decompose into: (1) `findAndRemoveExisting` -- scan for key, remove if present; (2) `insertEntry` -- append new key-value at end of page or allocate overflow.
- **Acceptance criteria:** putProperty body is under 80 lines and nesting does not exceed 4 levels.
- **Verification:** `zig build test` passes; no behavioral change.
- **Affected paths:** `src/prop_store.zig`
- **Effort:** M
- **Resolution:** Decomposed putProperty into helper functions. Body reduced to under 80 lines with nesting at 4 levels max.
- **Commit:** `cf9c682`

### QUAL-0027: 4 files over 800-line guideline

- **Status:** Deferred
- **Severity:** Medium
- **PriorityScore:** 48 (Impact 3 x Likelihood 4 x 4)
- **Category:** architecture
- **Confidence:** confidence::confirmed
- **Summary:** Four source files exceed the 800-line project guideline: recovery.zig (1183), prop_store.zig (1147), backup.zig (958), buffer_pool.zig (922).
- **Evidence:** `wc -l` output confirms current line counts.
- **Root cause:** Same organic growth pattern that affected engine.zig before its decomposition.
- **Recommended change:** Apply the same decomposition pattern used for engine.zig: extract test blocks, helpers, and logically separable subsystems into focused files.
- **Acceptance criteria:** All source files under 800 lines.
- **Verification:** `wc -l src/*.zig | sort -rn | head` shows no file above 800.
- **Affected paths:** `src/recovery.zig`, `src/prop_store.zig`, `src/backup.zig`, `src/buffer_pool.zig`
- **Effort:** L
- **Deferral Reason:** Cosmetic refactor with no correctness or performance impact. Cross-references GAP-0029. Deferred to post-v1.

### QUAL-0028: Silent catch{} in label_store.zig causes page leaks

- **Status:** Closed / Implemented
- **Severity:** Medium
- **PriorityScore:** 36 (Impact 3 x Likelihood 3 x 4)
- **Category:** maintainability
- **Confidence:** confidence::confirmed
- **Summary:** In `src/label_store.zig`, `var_store.free` errors are swallowed with `catch {}` at L64 and L78. If the free fails, the old label page is leaked permanently.
- **Evidence:** `src/label_store.zig:64`:
  ```zig
  if (label_head != 0) self.var_store.free(label_head) catch {};
  ```
  `src/label_store.zig:78`:
  ```zig
  if (label_head != 0) self.var_store.free(label_head) catch {};
  ```
- **Root cause:** Defensive coding to avoid failing the entire label operation on a free error.
- **Recommended change:** Propagate the error with `try`, or at minimum increment a leaked-pages counter for diagnostics.
- **Acceptance criteria:** var_store.free errors are either propagated or tracked.
- **Verification:** Inject a free failure in tests; assert it surfaces rather than being swallowed.
- **Affected paths:** `src/label_store.zig`
- **Effort:** S
- **Resolution:** Changed `catch {}` to `try` for `var_store.free` calls in label_store.zig at L64 and L78. Errors now propagated to caller.
- **Commit:** `9a3e0ba`

### QUAL-0029: 4 unused imports in engine decomposition files

- **Status:** Closed / Implemented
- **Severity:** Low
- **PriorityScore:** 20 (Impact 2 x Likelihood 5 x 2... adjusted to 20)
- **Category:** cleanup
- **Confidence:** confidence::suspected (based on review; `zig build` warnings would confirm)
- **Summary:** The engine decomposition introduced unused imports: `engine_index.zig:6` (`std`), `engine_edge_props.zig:12` (`prop_store_mod`), `engine_integrity.zig:6` (`std`), `engine_integrity.zig:8` (`types`).
- **Root cause:** Imports copied from engine.zig during extraction without pruning.
- **Recommended change:** Remove the unused imports.
- **Acceptance criteria:** `zig build` produces no unused-import warnings for these files.
- **Verification:** `zig build 2>&1 | grep unused` returns empty.
- **Affected paths:** `src/engine_index.zig`, `src/engine_edge_props.zig`, `src/engine_integrity.zig`
- **Effort:** S
- **Resolution:** Removed 4 unused imports from engine_index.zig, engine_edge_props.zig, and engine_integrity.zig. No unused-import warnings remain.
- **Commit:** `0c05eab`

### QUAL-0030: Hardcoded 4096 page size in integrity.zig tests

- **Status:** Closed / Implemented
- **Severity:** Low
- **PriorityScore:** 16 (Impact 2 x Likelihood 2 x 4)
- **Category:** tests
- **Confidence:** confidence::confirmed
- **Summary:** Tests in `src/integrity.zig` at L51, L72, and L93 hardcode `4096` as the page size rather than using a configurable constant. If the default page size changes, these tests will silently test the wrong size.
- **Root cause:** Tests written with a fixed assumption during initial implementation.
- **Recommended change:** Define a `test_page_size` constant or import from config.
- **Acceptance criteria:** No literal `4096` in integrity.zig test code.
- **Verification:** grep for hardcoded 4096 returns nothing in test code.
- **Affected paths:** `src/integrity.zig`
- **Effort:** S
- **Resolution:** Replaced hardcoded 4096 with a named `test_page_size` constant in integrity.zig tests.
- **Commit:** `b2520fd`

### QUAL-0031: 7x duplicated TestEnv boilerplate across store tests

- **Status:** Deferred
- **Severity:** Low
- **PriorityScore:** 12 (Impact 1 x Likelihood 3 x 4)
- **Category:** maintainability
- **Confidence:** confidence::confirmed
- **Summary:** Seven store test files duplicate approximately 25-line init/deinit blocks for test environment setup.
- **Root cause:** Each store was developed independently with its own test scaffolding.
- **Recommended change:** Extract a shared `test_helpers.zig` with a common `TestEnv` struct providing init/deinit.
- **Acceptance criteria:** Test env setup is defined once and imported by all store test files.
- **Verification:** `zig build test` passes; grep for duplicated init blocks finds only the shared helper.
- **Affected paths:** 7 store test files (node_store, edge_store, prop_store, adj_store, label_store, var_store, buffer_pool tests)
- **Effort:** M
- **Deferral Reason:** Broad test infrastructure refactor affecting 7 files. No correctness impact. Deferred to post-v1.

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

### QUAL-0009: page_allocator in vtable wrappers

- **Status:** Closed
- **Severity:** High
- **Resolution:** Caller allocator threaded through WrapperState.

### QUAL-0010: O(N) index rebuild on every checkpoint

- **Status:** Closed
- **Severity:** High
- **Resolution:** Removed redundant rebuild (same as PERF-0019).

### QUAL-0011: deinit/cleanupResources duplication

- **Status:** Closed
- **Severity:** High
- **Resolution:** deinit delegates to cleanupResources.

### QUAL-0012: Format violations on main

- **Status:** Closed
- **Severity:** Medium
- **Resolution:** zig fmt applied to 4 files.

### QUAL-0013: Duplicated WrapperState blocks

- **Status:** Closed
- **Severity:** Medium
- **Resolution:** Shared helper extracted.

### QUAL-0014: Repeated adjacency-scan pattern

- **Status:** Closed
- **Severity:** Medium
- **Resolution:** findEdgePropHead helper extracted.

### QUAL-0015: engine.zig exceeds 800-line guideline

- **Status:** Closed (was Deferred)
- **Severity:** Medium
- **Resolution:** Decomposed engine.zig from 1695 lines to 777 lines. Extracted engine_persist.zig, engine_index.zig, engine_edge_props.zig, engine_integrity.zig.

### QUAL-0016: Missing errdefer chain in initSubsystems

- **Status:** Closed
- **Severity:** Medium
- **Resolution:** 11 errdefer handlers added.

### QUAL-0017: Recovery writes manifest to slot A only

- **Status:** Closed
- **Severity:** Medium
- **Resolution:** Writes both slots A and B.

### QUAL-0018: Inconsistent error semantics for missing nodes

- **Status:** Closed
- **Severity:** Medium
- **Resolution:** Aligned to error.NodeNotFound.

### QUAL-0019: PropIterator returns borrowed slices

- **Status:** Closed
- **Severity:** Low
- **Resolution:** Doc comment added.

### QUAL-0020: Unused import in backup.zig

- **Status:** Closed
- **Severity:** Low
- **Resolution:** Import removed.

### QUAL-0021: Architecture doc stale

- **Status:** Closed
- **Severity:** Low
- **Resolution:** Diagrams updated.
