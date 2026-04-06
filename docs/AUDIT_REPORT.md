# Full Codebase Audit Summary

**Date:** 2026-04-06
**Previous audit:** 2026-03-25
**Auditors:** Automated multi-agent pipeline (16 agents across 4 phases)
**Status:** Audit complete. **Gap closure complete.** 37 items closed, 10 deferred, 1 blocked. 343/343 tests pass.

## Repository

- **Project:** devnw/zig/graph-storage
- **Platform:** GitLab (`gitlab.com/devnw/zig/graph-storage`)
- **Languages:** Zig 0.15.x (15,303 lines across 41 source files + 58 test/bench files)
- **Dependencies:** `wal` (devnw/zig/wal), `uuid` (devnw/zig/uuid), `spice` (devnw/zig/spice) -- all pinned by commit + content hash
- **Scope:** Entire repository
- **Build status:** PASS (`zig build check` clean, 319/319 tests pass)
- **Commit:** `5f6284d` (main, clean working tree)

---

## Changes Since Last Audit (2026-03-25)

Since the previous audit, significant work has been done:

- **CI pipeline now functional** (was Critical gap G-CI, now closed)
- **`close()` returns `!void`** (was High quality finding Q2, now closed)
- **Encryption key zeroization added** in `PageEncryption.deinit()` and `GraphConfig.zeroKey()` (was Critical S3, now closed)
- **WAL checksum verification added** during recovery (was High S4, now closed)
- **Path traversal protection added** in backup restore (was Critical S2, now closed)
- **File permissions set** to 0o600/0o700 (was Medium S11, now closed)
- **Backup HMAC-SHA256 added** for v2 backups (was High S5, now closed)
- **`spice` dependency added** for thread pool parallelism
- Codebase grew from 10,712 to 15,303 lines (+43%)
- Test count grew from 247 to 319 (+29%)
- 13 of 15 previous security findings closed

**However, new issues have emerged** -- particularly around the nonce reuse pattern (the fix from SEC-0001 is incomplete) and new parsing safety concerns as the codebase grew.

---

## Domain Results

### Gap Analysis

| Status | Count | Percentage |
|--------|-------|------------|
| Implemented | 31 | 79% |
| Partial | 5 | 13% |
| Not Implemented | 3 | 8% |

39 requirements traced (FR-001 through FR-021, 18 NFRs).

**Open gaps:** 11 (Critical: 0, High: 3, Medium: 4, Low: 3, Blocked: 1)

| Gap-ID | Requirement | Severity | Description |
|--------|-------------|----------|-------------|
| GAP-0002 | FR-018 (P0) | **Blocked** | Migration bulk-load stubbed -- `migration.zig:129-141` returns empty results |
| GAP-0018 | FR-019 (P1) | **High** | No read-only legacy fallback mode -- V1 rejected outright |
| GAP-0020 | FR-016/017 (P1) | **High** | B+tree index in-memory only, not persisted to pages |
| GAP-0021 | FR-003/008 (P0) | **High** | `getEdge()` always returns `error.EdgeIndexNotImplemented` |
| GAP-0016 | NFR-OBS-001 (P1) | Medium | Missing 4 of 7 required metric categories |
| GAP-0017 | NFR-OBS-002 (P1) | Medium | No structured event emission (log_fn never called) |
| GAP-0019 | NFR-CMP-001 (P1) | Medium | No operational documentation (runbooks, key management) |
| GAP-0022 | FR-012 (P0) | Medium | Per-mutation auto-commit -- no multi-op transaction API |
| GAP-0023 | FR-021 (P2) | Low | No extension mechanism for specialized index types |
| GAP-0024 | NFR-MNT-002 (P0) | Low | CI fuzz stage declared but has no jobs |
| GAP-0025 | NFR-ACC-001 (P1) | Low | No structured CLI/API output layer (JSON) |

### Code Quality

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 3 |
| Medium | 8 |
| Low | 3 |

**Top findings:**

| ID | Finding | Severity | File:Line |
|----|---------|----------|-----------|
| QUAL-0009 | `page_allocator` in vtable wrappers causes memory leak | High | `interface.zig:299,353` |
| QUAL-0010 | O(N) index rebuild on every checkpoint (redundant) | High | `engine.zig:981` |
| QUAL-0011 | `deinit`/`cleanupResources` are exact duplicates | High | `engine.zig:486-507,557-578` |
| QUAL-0012 | 4 files fail `zig fmt --check` on main | Medium | `interface.zig`, `prop_store.zig`, `buffer_pool.zig`, `adj_store.zig` |
| QUAL-0013 | Duplicated WrapperState blocks in vtable | Medium | `interface.zig:293-319,349-373` |
| QUAL-0014 | Repeated adjacency-scan pattern (4 methods) | Medium | `engine.zig:1000-1074` |
| QUAL-0015 | `engine.zig` at 1695 lines (2x 800-line guideline) | Medium | `engine.zig` |
| QUAL-0016 | Missing errdefer chain in `initSubsystems` | Medium | `engine.zig:149` |
| QUAL-0017 | Recovery writes manifest to slot A only (comment says both) | Medium | `recovery.zig:196-199` |
| QUAL-0018 | Inconsistent error semantics for missing nodes | Medium | `engine.zig:997,1049` |
| QUAL-0019 | PropIterator returns borrowed slices (undocumented lifetime) | Low | `prop_store.zig:130-134` |

### Performance

| PerfSeverity | Count |
|-------------|-------|
| P0 | 2 |
| P1 | 3 |
| P2 | 2 |
| P3 | 2 |

**Baseline (100K tier):** Point lookup 72us, Property read 119us, Expand out 120us, Checkpoint 851ms

**Top findings:**

| ID | Finding | Severity | Est. Impact | File:Line |
|----|---------|----------|-------------|-----------|
| PERF-0019 | Full derived index rebuild on every checkpoint | P0 | 5-10x checkpoint speedup | `engine.zig:981` |
| PERF-0020 | `close()` redundant index rebuild | P0 | 2x close speedup | `engine.zig:534` |
| PERF-0021 | Double chain traversal in `putProperty` | P1 | 50% fewer pin/unpin | `prop_store.zig:170-310` |
| PERF-0022 | Heap allocation per property encode | P1 | 10-20% bulk write improvement | `property.zig:41-44` |
| PERF-0023 | O(n) property lookup per key | P1 | Linear scaling concern | `prop_store.zig:57-91` |
| PERF-0024 | Redundant CRC32C when AES-GCM active | P2 | ~2us per page I/O | `pager.zig:57-63` |
| PERF-0025 | Parallel flush allocates full data copy | P2 | Memory pressure at scale | `buffer_pool.zig:263` |

### Security

| Risk Level | Count |
|------------|-------|
| Critical | 1 |
| High | 4 |
| Medium | 9 |
| Low | 0 |

**Immediate actions:** 1 (AES-GCM nonce reuse -- encryption is effectively broken)

**Top findings:**

| ID | Finding | Severity | CWE | File:Line |
|----|---------|----------|-----|-----------|
| SEC-0015 | **AES-GCM nonce reuse** -- `write_count` hardcoded to 0 in Pager; every page overwrite reuses nonce, breaking confidentiality and authentication | **Critical** | CWE-323 | `pager.zig:52,79` |
| SEC-0016 | HMAC comparison uses non-constant-time `std.mem.eql` | High | CWE-208 | `backup.zig:223,320` |
| SEC-0017 | V2 backup restore without key silently skips HMAC | High | CWE-345 | `backup.zig:226-229` |
| SEC-0018 | PropStore key_len from page data used without bounds check | High | CWE-125 | `prop_store.zig:69-72` |
| SEC-0019 | `@intCast` on `stat.size` without bounds (3 sites) | High | CWE-681 | `engine.zig:347` et al. |
| SEC-0020 | AdjStore `bh.count` not validated against page capacity | Medium | CWE-125 | `adj_store.zig:172-174` |
| SEC-0021 | Index catalog has no magic, version, or CRC | Medium | CWE-354 | `index_catalog.zig:93-180` |
| SEC-0022 | Free space `total_pages` unbounded from disk | Medium | CWE-400 | `free_space.zig:172-181` |
| SEC-0023 | Encryption key not zeroed in Recovery/Backup structs | Medium | CWE-316 | `recovery.zig:43`, `backup.zig:66` |
| SEC-0024 | WAL `payload_len` controls allocation without cap | Medium | CWE-400 | `wal_record.zig:138-143` |

---

## Cross-Domain Summary

| Domain | Findings | Issues Created | Issues Updated | Issues Closed |
|--------|----------|---------------|----------------|---------------|
| Gap Analysis | 11 | 0 | 0 | 0 |
| Quality | 14 | 0 | 0 | 0 |
| Performance | 9 | 0 | 0 | 0 |
| Security | 14 | 0 | 0 | 0 |
| **Total** | **48** | **0** | **0** | **0** |

Note: Issue creation skipped due to invalid GitLab auth token. All findings tracked in gap analysis docs.

---

## Docs Updated

| File | Domain | Action |
|------|--------|--------|
| `docs/GAP_ANALYSIS.md` | Gap | Updated (10 new gaps, 2 status changes) |
| `docs/QUALITY_GAP_ANALYSIS.md` | Quality | Updated (13 new findings) |
| `docs/PERF_GAP_ANALYSIS.md` | Performance | Updated (9 new findings) |
| `docs/SECURITY_GAP_ANALYSIS.md` | Security | Updated (14 new findings) |
| `docs/AUDIT_REPORT.md` | All | Replaced with this report |

---

## Top 10 Findings (cross-domain, by severity)

| # | Domain | Finding | Severity | Score | File:Line |
|---|--------|---------|----------|-------|-----------|
| 1 | Security | AES-GCM nonce reuse -- `write_count=0` on every page encrypt/decrypt | Critical | 100 | `pager.zig:52,79` |
| 2 | Performance | Full index rebuild on every checkpoint (redundant O(N) work) | P0 | 100 | `engine.zig:981` |
| 3 | Performance | `close()` rebuilds indexes again after checkpoint | P0 | 100 | `engine.zig:534` |
| 4 | Security | HMAC timing side channel (`std.mem.eql` instead of constant-time) | High | 80 | `backup.zig:223` |
| 5 | Security | V2 backup HMAC silently bypassed without key | High | 80 | `backup.zig:226-229` |
| 6 | Security | PropStore key_len OOB read on corrupted pages | High | 80 | `prop_store.zig:69-72` |
| 7 | Quality | `page_allocator` in vtable wrappers (memory leak) | High | 80 | `interface.zig:299,353` |
| 8 | Security | `@intCast` on `stat.size` without bounds check | High | 80 | `engine.zig:347` |
| 9 | Gap | B+tree index not persisted -- rebuilt on every open | High | -- | `btree.zig:7-11` |
| 10 | Gap | `getEdge()` always returns error (no edge-ID index) | High | -- | `engine.zig:742-746` |

---

## Recommended Remediation Priority

### Immediate (this week)

1. **SEC-0015: Fix AES-GCM nonce reuse** -- Store per-page write counter in `PageHeader._reserved` bytes. Increment on every `writePage`. This is the single most critical finding; encryption is currently broken for any page written more than once.

2. **PERF-0019/0020: Remove redundant `rebuildDerivedIndexes()`** from `checkpoint()` and `close()`. Indexes are already maintained incrementally. Just call `saveDerivedIndexes()`. Expected 5-10x checkpoint speedup.

3. **SEC-0016: Use constant-time HMAC comparison** -- Replace `std.mem.eql` with `std.crypto.timing_safe.eql` at two sites in `backup.zig`.

### Next sprint

4. **SEC-0017: Require key for V2 backup restore** -- Return `error.HmacKeyRequired` instead of silently downgrading to CRC-only.

5. **SEC-0018/SEC-0020: Add bounds checks** on file-derived lengths in `prop_store.zig` and `adj_store.zig`.

6. **QUAL-0009: Fix vtable allocator mismatch** -- Thread caller's allocator through `WrapperState` instead of using `page_allocator`.

7. **SEC-0019: Replace `@intCast` with `std.math.cast`** at 3 `stat.size` sites.

8. **QUAL-0012: Run `zig fmt`** on the 4 files with formatting violations.

### This quarter

9. **GAP-0020: B+tree page persistence** -- Implement serialization using existing `btree_internal`/`btree_leaf` page types.

10. **GAP-0021: Edge-ID index** -- Add edge-to-node mapping for O(1) edge lookup.

11. **PERF-0021: Merge putProperty passes** -- Single-pass remove+insert for property updates.

12. **QUAL-0015: Decompose engine.zig** -- Extract edge-property helpers, integrity check, persistence, and tests.

---

## Blockers

- **GitLab auth token invalid** -- cannot create/update issues. Re-authenticate via `glab auth login`.
- **No Zig-specific SAST tools** -- all security findings from manual review. Semgrep has no Zig rules.
- **No code coverage tooling** -- 80% coverage target cannot be measured. `.gitignore` has coverage entries but no tooling configured.
- **External `wal` library not audited** -- WAL encryption and crash safety depend on unaudited `devnw/zig/wal` code.
- **Migration blocked** -- FR-018 (P0) requires Geode binary format reader which is an external dependency.

---

## Comparison with Previous Audit (2026-03-25)

| Metric | 2026-03-25 | 2026-04-06 | Delta |
|--------|------------|------------|-------|
| Source lines | 10,712 | 15,303 | +43% |
| Source files | 38 | 41 | +3 |
| Tests passing | 247 | 319 | +29% |
| Dependencies | 2 | 3 | +1 (spice) |
| Security: Open | 15 | 14 | -1 (13 old closed, 14 new found) |
| Security: Critical | 3 | 1 | -2 (2 fixed, 1 persists as incomplete fix) |
| Quality: Open | 13 | 14 | +1 |
| Performance: Open | 15 | 9 | -6 (many closed/deferred, 9 new) |
| Gaps: Open | 10 | 11 | +1 (1 closed, 10 new found) |
| **Total open findings** | **53** | **48** | **-5** |

The codebase has improved significantly since the last audit -- CI is functional, 13 security issues were closed, key zeroization was added, and test coverage grew. However, the AES-GCM nonce reuse (SEC-0015) remains the most critical issue and has persisted across both audits (originally SEC-0001, partially fixed but the pager still passes `write_count=0`). New parsing safety issues emerged as the codebase grew.
