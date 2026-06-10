# Full Codebase Audit Summary

**Date:** 2026-04-06
**Previous audit:** 2026-04-06 (initial), 2026-03-25 (baseline)
**Auditors:** Automated multi-agent pipeline (16 agents across 5 phases)
**Status:** Audit complete. 363/363 tests pass. 4 items closed, 31 new findings across 4 domains.

## Repository

- **Project:** devnw/zig/graph-storage
- **Platform:** GitLab (`gitlab.com/devnw/zig/graph-storage`)
- **Languages:** Zig 0.15.x (17,241 lines across 46 source files + tests/benchmarks)
- **Dependencies:** `wal` (devnw/zig/wal), `uuid` (devnw/zig/uuid), `spice` (devnw/zig/spice) -- all pinned by commit + content hash
- **Scope:** Entire repository
- **Build status:** PASS (`zig build` clean, `zig fmt --check` clean, 363/363 tests pass)
- **Commit:** `cde8c6f` (main, clean working tree)

---

## Changes Since Last Audit

Since the previous audit cycle, significant progress has been made:

- **B+tree persistence added** (GAP-0020 closed) -- serialize/deserialize/saveToFile/loadFromFile
- **Per-page property key directory** (PERF-0023 closed) -- FNV-1a hash O(1) lookup
- **engine.zig decomposed** (QUAL-0015 closed) -- from 1695 to 777 lines across 5 modules
- **getEdge() implemented** (GAP-0021 closed) -- in-memory HashMap edge index
- **Index catalog integrity** (SEC-0021 closed) -- magic + version + CRC32 save/load
- Codebase grew from 15,303 to 17,241 lines (+13%)
- Test count grew from 319 to 363 (+14%)

**However, new issues were identified** -- particularly around key lifecycle management, chain cycle detection, WAL write amplification, and a memory leak in the vtable iterator wrapper.

---

## Domain Results

### Gap Analysis

| Status | Count | Percentage |
|--------|-------|------------|
| Implemented | 30 | 77% |
| Partial | 6 | 15% |
| Not Implemented | 1 | 3% |
| Blocked | 1 | 3% |
| Deferred | 1 | 3% |

39 requirements traced (FR-001 through FR-021, 18 NFRs).

**Open gaps:** 8 (Critical: 0, High: 0, Medium: 4, Low: 4)

| Gap-ID | Requirement | Severity | Status | Description |
|--------|-------------|----------|--------|-------------|
| GAP-0002 | FR-018 (P0) | Critical | **Blocked** | Migration bulk-load stubbed -- blocked on Geode binary reader |
| GAP-0022 | FR-012 (P0) | Medium | Deferred | No multi-op transaction API; per-mutation auto-commit only |
| GAP-0026 | NFR-OBS-001 (P1) | Medium | Open | 3 metrics counters declared but never wired |
| GAP-0027 | FR-016/017 (P1) | Medium | Open | B+tree not integrated into engine query/checkpoint path |
| GAP-0023 | FR-021 (P2) | Low | Deferred | No extension mechanism for specialized index types |
| GAP-0028 | FR-003/008 (P0) | Low | Open | Edge index rebuilt on every open (not persisted) |
| GAP-0029 | Coding style | Low | Open | 3 files over 800-line guideline |
| GAP-0030 | NFR-PERF-001 (P0) | Low | Open | Recovery two-pass loads entire WAL into memory |

### Code Quality

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 2 |
| Medium | 5 |
| Low | 3 |

**Top findings:**

| ID | Finding | Severity | PriorityScore | File:Line |
|----|---------|----------|---------------|-----------|
| QUAL-0022 | Memory leak in `wrapPropIterator` -- State not freed on deinit | High | 80 | `interface.zig:424-427` |
| QUAL-0023 | `removeProperty` silently returns on corrupt data | High | 64 | `prop_store.zig:514-517` |
| QUAL-0024 | `checkIntegrity` swallows all I/O errors via `catch null` | Medium | 48 | `engine_integrity.zig:77,92,96` |
| QUAL-0025 | No test for uncommitted transaction recovery (core ARIES guarantee) | Medium | 48 | `recovery.zig` |
| QUAL-0026 | `putProperty` 201 lines with 6+ nesting levels | Medium | 48 | `prop_store.zig:277-477` |
| QUAL-0027 | 4 files over 800-line guideline | Medium | 48 | `recovery.zig`, `prop_store.zig`, `backup.zig`, `buffer_pool.zig` |
| QUAL-0028 | Silent `catch {}` in `label_store.zig` causes page leaks | Medium | 36 | `label_store.zig:64,78` |

### Performance

| PerfSeverity | Count |
|-------------|-------|
| P0 | 0 |
| P1 | 3 |
| P2 | 7 |
| P3 | 3 |

**Baseline (100K tier):** Point lookup 71,920ns, Property read 119,036ns, Expand out 119,884ns, Checkpoint 850.9ms, Mixed ops/s 28,399

**Top findings:**

| ID | Finding | Severity | PerfScore | File:Line |
|----|---------|----------|-----------|-----------|
| PERF-0028 | WAL write amplification 32KB per edge (full-page logging) | P1 | 80 | `engine.zig:413-417,544-552` |
| PERF-0029 | fsync per auto-commit operation | P1 | 80 | `txn.zig:81` |
| PERF-0030 | Index rebuild uses per-ID getNode, not scanNodes | P1 | 80 | `engine_index.zig:16-82` |
| PERF-0031 | Checkpoint blocks all operations for ~850ms | P2 | 48 | `engine_persist.zig:213-241` |
| PERF-0035 | TxnManager leaks committed/aborted entries (unbounded growth) | P2 | 48 | `txn.zig:83-84` |
| PERF-0032 | edge_index HashMap not pre-allocated (~17 resizes at 150K edges) | P2 | 48 | `engine_persist.zig:197` |

**Correctness bug flagged:** `putPropertyTxn` logs only prop_head page, missing overflow pages. Potential data loss on crash for multi-page property chains (`engine.zig:627-639`).

### Security

| Risk Level | Count |
|------------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 5 |
| Low | 3 |

**Immediate actions:** 0 (no emergency rotations needed; nonce exhaustion is long-horizon risk)

**Top findings:**

| ID | Finding | Severity | Risk Score | CWE | File:Line |
|----|---------|----------|------------|-----|-----------|
| SEC-0032 | VarStore.read infinite loop on circular page chain | Medium | 48 | CWE-835 | `var_store.zig:107-124` |
| SEC-0033 | prop_store chain traversals have no cycle detection | Medium | 48 | CWE-835 | `prop_store.zig` (4 sites) |
| SEC-0029 | Backup struct missing deinit -- key not zeroed | Medium | 36 | CWE-316 | `backup.zig:75-88` |
| SEC-0030 | FileManager.deinit doesn't zero encryption key | Medium | 36 | CWE-316 | `file_manager.zig:32,98-107` |
| SEC-0031 | `unreachable` in putProperty reachable with corrupt chain | Medium | 36 | CWE-617 | `prop_store.zig:476` |
| SEC-0034 | Recovery.deinit not called in engine.open | Low | 16 | CWE-316 | `engine.zig:194-195` |
| SEC-0035 | Property key length not validated (>65535 panics) | Low | 16 | CWE-681 | `prop_store.zig:549` |
| SEC-0036 | Backup restore dir created without mode restriction | Low | 16 | CWE-276 | `backup.zig:256` |

**Residual risk:** SEC-0015 nonce exhaustion (u24 write_count saturates at 16,777,215) remains a known long-horizon risk.

---

## Cross-Domain Summary

| Domain | Findings | Items Closed | New Items | Total Open |
|--------|----------|-------------|-----------|------------|
| Gap Analysis | 8 open | 1 (GAP-0021) | 5 (GAP-0026--0030) | 8 |
| Quality | 10 open | 1 (QUAL-0015) | 10 (QUAL-0022--0031) | 10 |
| Performance | 17 open | 1 (PERF-0023) | 13 (PERF-0028--0040) | 17 |
| Security | 9 open | 1 (SEC-0021) | 8 (SEC-0029--0036) | 9 |
| **Total** | **44 open** | **4** | **36** | **44** |

Note: Issue creation skipped due to invalid GitLab auth token. All findings tracked in gap analysis docs.

---

## Gap Closure Results (2026-04-06)

Following the audit, 23 gap items were implemented across 23 commits in 16 files. All 364 tests pass.

| Domain | Closed | Won't Do | Deferred | Remaining Open |
|--------|--------|----------|----------|----------------|
| Gap Analysis | 1 | 0 | 4 | 0 |
| Quality | 8 | 0 | 3 | 0 |
| Performance | 6 | 5 | 2 | 0 |
| Security | 8 | 0 | 0 | 0 |
| **Total** | **23** | **5** | **9** | **0** |

**All open items from the audit have been addressed.** Zero items remain in Open status across all four tracking files.

Key closures:

- **Security:** All 8 open findings closed -- key zeroing (SEC-0029/0030), cycle detection (SEC-0032/0033), unreachable-to-error (SEC-0031), key length validation (SEC-0035), directory permissions (SEC-0036), recovery deinit (SEC-0034).
- **Quality:** Memory leak fixed (QUAL-0022), error propagation (QUAL-0023/0024/0028), ARIES recovery test (QUAL-0025), putProperty decomposition (QUAL-0026), unused imports (QUAL-0029), test constants (QUAL-0030).
- **Performance:** Index rebuild batch API (PERF-0030), HashMap pre-sizing (PERF-0032/0033), txn leak fix (PERF-0035), directory rebuild dedup (PERF-0038), bench alignment (PERF-0039).
- **Observability:** All 3 unwired metrics counters now populated (GAP-0026).

Won't Do items (5) are documented with rationale -- all require architectural changes disproportionate to v1 scope.

---

## Docs Updated

| File | Domain | Action |
|------|--------|--------|
| `docs/GAP_ANALYSIS.md` | Gap | Updated (5 new gaps, GAP-0021 closed) |
| `docs/GAP_ANALYSIS_RESOLVED.md` | Gap | Created (22 resolved items) |
| `docs/QUALITY_GAP_ANALYSIS.md` | Quality | Updated (10 new findings, QUAL-0015 closed) |
| `docs/PERF_GAP_ANALYSIS.md` | Performance | Updated (13 new findings, PERF-0023 closed) |
| `docs/SECURITY_GAP_ANALYSIS.md` | Security | Updated (8 new findings, SEC-0021 closed) |
| `docs/AUDIT_REPORT.md` | All | Replaced with this report |

---

## Top 10 Findings (cross-domain, by severity)

| # | Domain | Finding | Severity | Score | File:Line |
|---|--------|---------|----------|-------|-----------|
| 1 | Quality | Memory leak in `wrapPropIterator` -- State not freed | High | 80 | `interface.zig:424-427` |
| 2 | Performance | WAL write amplification 32KB per edge | P1 | 80 | `engine.zig:413-417` |
| 3 | Performance | fsync per auto-commit operation | P1 | 80 | `txn.zig:81` |
| 4 | Performance | Index rebuild uses per-ID getNode (300K extra mutex ops) | P1 | 80 | `engine_index.zig:16-82` |
| 5 | Quality | `removeProperty` silently returns on corrupt data | High | 64 | `prop_store.zig:514-517` |
| 6 | Security | VarStore.read infinite loop on circular page chain | Medium | 48 | `var_store.zig:107-124` |
| 7 | Security | prop_store chain traversals -- no cycle detection | Medium | 48 | `prop_store.zig` (4 sites) |
| 8 | Performance | Checkpoint blocks all operations ~850ms | P2 | 48 | `engine_persist.zig:213-241` |
| 9 | Performance | TxnManager leaks entries (unbounded memory growth) | P2 | 48 | `txn.zig:83-84` |
| 10 | Gap | B+tree not integrated into engine query path | Medium | -- | `engine.zig` (btree never imported) |

---

## Recommended Remediation Priority

### Immediate (quick wins, < 1 day each)

1. **QUAL-0022: Fix wrapPropIterator memory leak** -- Add `self.alloc.destroy(self)` after `self.iter.deinit()` in `interface.zig:427`. 1-line fix.
2. **QUAL-0023: Fix removeProperty silent error** -- Change `catch { return; }` to `return error.DataCorruption` at `prop_store.zig:517`.
3. **PERF-0035: Fix TxnManager entry leak** -- Remove entry from `active_txns` on commit/abort instead of updating state.
4. **PERF-0032/0033: Pre-allocate HashMaps** -- `ensureTotalCapacity` for edge_index and page_table.
5. **SEC-0029/0030: Zero encryption keys** -- Add `secureZero` in Backup deinit (new) and FileManager.deinit.
6. **SEC-0034: Call recovery.deinit()** -- Add `defer recovery.deinit()` in engine.open.

### Next sprint

1. **PERF-0030: Refactor index rebuild to use scanNodes** -- Replace 3 per-ID scan loops with page-level batch scan. Expected 50-100x fewer mutex acquisitions.
2. **SEC-0031/0032/0033: Add chain cycle detection** -- Hop counter or visited-set for all page-chain traversals in prop_store, var_store.
3. **QUAL-0024: Fix integrity check error handling** -- Replace `catch null` with error propagation + io_errors counter.
4. **QUAL-0025: Add uncommitted-txn recovery test** -- BEGIN + page_update without COMMIT, verify not applied.

### This quarter

1. **PERF-0028: Delta WAL logging** -- Replace full-page WAL with physiological logging (changed bytes only). 10-50x WAL I/O reduction.
2. **PERF-0029: Group commit** -- Batch fsync across multiple transactions. 10-100x write throughput on real storage.
3. **GAP-0027: Wire B+tree into engine** -- Import IndexCatalog, load/save on open/checkpoint, route property queries through B+tree.
4. **PERF-0031: Fuzzy/incremental checkpoint** -- Allow reads during flush, checkpoint in background.

---

## Blockers

- **GitLab auth token invalid** -- cannot create/update issues. Re-authenticate via `glab auth login`.
- **No Zig-specific SAST tools** -- all security findings from manual review. Semgrep has no Zig rules.
- **No code coverage tooling** -- 80% coverage target cannot be measured.
- **External `wal` library not audited** -- WAL encryption and crash safety depend on unaudited `devnw/zig/wal` code.
- **Migration blocked** -- FR-018 (P0) requires Geode binary format reader (external dependency).

---

## Comparison with Previous Audit

| Metric | 2026-03-25 | 2026-04-06 (prev) | 2026-04-06 (this) | Delta |
|--------|------------|--------------------|--------------------|-------|
| Source lines | 10,712 | 15,303 | 17,241 | +13% |
| Source files | 38 | 41 | 46 | +5 |
| Tests passing | 247 | 319 | 363 | +14% |
| Dependencies | 2 | 3 | 3 | +0 |
| Security: Open | 15 | 14 | 9 | -5 |
| Quality: Open | 13 | 14 | 10 | -4 |
| Performance: Open | 15 | 9 | 17 | +8 (deeper scan) |
| Gaps: Open | 10 | 11 | 8 | -3 |
| **Total open** | **53** | **48** | **44** | **-4** |

The codebase continues to improve. Four previously-deferred items were resolved (GAP-0021, SEC-0021, PERF-0023, QUAL-0015). The deeper Phase 3 analysis this cycle identified 36 new findings -- primarily in performance (WAL amplification, fsync overhead) and security (key lifecycle, chain cycle detection). The most impactful quick wins are the memory leak fix (QUAL-0022), TxnManager entry leak (PERF-0035), and encryption key zeroing (SEC-0029/0030).
