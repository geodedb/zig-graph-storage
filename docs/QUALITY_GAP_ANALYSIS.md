# Quality Gap Analysis

Last updated: 2026-06-10

This file tracks open QUALITY-domain findings for `graph-storage`, scored with a
consistent framework and linked to GitLab issues. Gap, security, and performance
findings are tracked in their own `*_GAP_ANALYSIS.md` documents.

Scoring: `PriorityScore = Impact(1-5) × Likelihood(1-5) × 4` (0-100). Severity is
the qualitative band; PriorityScore is the stack-rank key.

## Summary

The 2026-06-10 audit-remediation pass (branch `audit-remediation-2026-06-10`,
full suite green on Debug + ReleaseSafe: 542/543 unit + 23 integration + 8 fuzz

+ 6 cross-shard + 3 sharded) resolved QUAL-0040 through QUAL-0048. Two of those
fixes addressed **real defects discovered during remediation**:

+ **QUAL-0044** — fixed-seed `std.testing.fuzz` targets found and fixed two real
  bugs: an out-of-bounds write on an oversized key in the property decode path,
  and `rebuildDirectory` partial-write corruption.
+ **QUAL-0047** — the integrity scan was silently swallowing I/O errors
  (`catch`→count); it now propagates them. Real error-swallowing bug fixed.

### Open findings by severity

| Severity | Open count |
| --- | ---: |
| Critical | 0 |
| High | 1 |
| Medium | 1 |
| Low | 0 |
| Info | 0 |
| Won't Do | 1 (QUAL-0033) |

### Top open risks (by PriorityScore)

1. **QUAL-0027** (80) — Oversized high-churn core modules; `backup.zig` 2054,
   `prop_store.zig` 1753, `recovery.zig` 1629, `buffer_pool.zig` 1543,
   `engine.zig` 1368. Delegation pattern extended (new `engine_property_index`)
   but core files remain large and multi-responsibility.
2. **QUAL-0031** (24) — Residual bespoke test fixture in `label_store.zig`; most
   stores migrated onto the shared `SingleStoreEnv`/`DualStoreEnv` harness.

## Stack-ranked findings (open)

| Rank | Severity | PriorityScore | Category | Finding | Component | Evidence | Issue URL | Fix Summary | Owner | ETA/SLA | Status |
| ---: | --- | ---: | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | High | 80 | architecture | QUAL-0027 Oversized high-churn core modules | `backup.zig` 2054, `prop_store.zig` 1753, `recovery.zig` 1629, `buffer_pool.zig` 1543, `engine.zig` 1368 | `engine.zig` mixes lifecycle + vtable + auto-commit wrappers + index refresh + thread-pool + metrics; core files still large despite extended delegation | [#72](https://gitlab.com/devnw/zig/graph-storage/-/issues/72) | Extend `engine_*` delegation (now incl. `engine_property_index`); factor auto-commit wrapper; split backup/recovery by responsibility | Engine owner | 5-10d | Open |
| 2 | Medium | 24 | tests | QUAL-0031 Store fixture scaffolding (residual: `label_store.zig`) | `label_store.zig` | Most stores migrated to `testing_support` `SingleStoreEnv`/`DualStoreEnv`; `label_store.zig:98-126` still bespoke | [#81](https://gitlab.com/devnw/zig/graph-storage/-/issues/81) | Migrate `label_store.zig` tests onto shared harness | Test owner | <1d | Open |
| — | — | — | ci-cd | QUAL-0033 Quality checks fragmented across Make/pre-commit/CI | `Makefile`, `.pre-commit-config.yaml`, `.gitlab-ci.yml` | Intentional fast-subset model; CI is authoritative gate | [#83](https://gitlab.com/devnw/zig/graph-storage/-/issues/83) | Won't Do — parity is not the control model | — | — | Won't Do |

## Findings by category (open)

### architecture

+ **QUAL-0027** (High, 80) — oversized high-churn modules; extend the existing
  `engine_*` delegation pattern (extended this pass with `engine_property_index`,
  core files still large). [#72]

### tests

+ **QUAL-0031** (Medium, 24) — residual bespoke fixture in `label_store.zig`.
  [#81]

### ci-cd

+ **QUAL-0033** (Won't Do) — quality-check fragmentation is intentional;
  GitLab CI is the authoritative merge gate. [#83]

## Roadmap

### Quick wins (< 1 day)

+ **QUAL-0031** migrate `label_store.zig` tests onto `SingleStoreEnv`.

### Strategic (> 5 days)

+ **QUAL-0027** decompose `engine.zig` (auto-commit wrapper, runtime/metrics) and
  split `backup.zig` / `recovery.zig` by responsibility, continuing the existing
  `engine_persist`/`engine_index`/`engine_integrity`/`engine_property_index`
  delegation.

## Resolved (2026-06-10 audit-remediation pass)

Branch `audit-remediation-2026-06-10`; full suite green on Debug + ReleaseSafe
(542/543 unit + 23 integration + 8 fuzz + 6 cross-shard + 3 sharded).

| Finding | Sev / Score | Issue | Fix commit(s) | Disposition |
| --- | --- | --- | --- | --- |
| QUAL-0040 PropStore chain duplication | Medium / 36 | [#97](https://gitlab.com/devnw/zig/graph-storage/-/issues/97) | `31d33aa` | `PageChainCursor` extraction; first overflow-page-chain tests added. Closed. |
| QUAL-0041 Error-set incoherence | High / 60 | [#121](https://gitlab.com/devnw/zig/graph-storage/-/issues/121) | `6104ada` | `StorageError` completed + comptime coherence guard test. Closed. |
| QUAL-0042 Resource leak on create/open | High / 48 | [#124](https://gitlab.com/devnw/zig/graph-storage/-/issues/124) | `562c778` | `cleanupSubsystems` + `errdefer`; fault-injection test. Closed. |
| QUAL-0043 Ownership docs + iter vtable asymmetry | Medium / 36 | [#127](https://gitlab.com/devnw/zig/graph-storage/-/issues/127) | `6e4974d` | `expandOutIter`/`expandInIter` first-class in vtable + ownership doc comments. Closed. |
| QUAL-0044 Test gaps on hardest paths | Medium / 48 | [#131](https://gitlab.com/devnw/zig/graph-storage/-/issues/131) | `644bf54` | Dir-disable/boundary tests + fixed-seed fuzz targets (property.decode / wal_record / page-directory). **Fuzzing found and fixed 2 real defects: OOB write on oversized key, and `rebuildDirectory` partial-write corruption.** Closed. |
| QUAL-0045 Doc drift | Medium / 36 | [#136](https://gitlab.com/devnw/zig/graph-storage/-/issues/136) | `3717df9`, `8518e2d` | Version reconciled to 0.2.0 (build.zig.zon/root.zig/README); Zig 0.16.0; format-spec tail_reserve; single-threaded→single-writer; markdownlint backlog cleared. Closed. |
| QUAL-0046 catch-unreachable type hack | Low / 12 | [#137](https://gitlab.com/devnw/zig/graph-storage/-/issues/137) | `1d8d2f6` | Explicit return types in `sharded_engine`. Closed. |
| QUAL-0047 Boilerplate + integrity error-swallowing | Low / 24 | [#138](https://gitlab.com/devnw/zig/graph-storage/-/issues/138) | `1d8d2f6` | `registerDataPagers` helper; **`engine_integrity` now propagates I/O errors — real error-swallowing defect fixed.** Span-boilerplate extraction deferred (not safely factorable in Zig). Closed. |
| QUAL-0048 build.zig.zon ref/version label mismatch | Low / 16 | [#139](https://gitlab.com/devnw/zig/graph-storage/-/issues/139) | `1d8d2f6` | Clarifying comments; pins unchanged. Closed. |
| QUAL-0039 Pre-commit config "invalid" | — | [#95](https://gitlab.com/devnw/zig/graph-storage/-/issues/95) | — | REFUTED; config validates. Already closed in prior pass. |

## Historical close-out (2026-04-07 pass)

The following items were dispositioned in the 2026-04-07 quality pass. Note that
several GitLab issues for these IDs remained open at re-audit on 2026-06-10 and
have been re-scored above with current measurements.

+ **QUAL-0027** — partial decomposition landed (`engine_edge_props`,
  `engine_index`, focused backup/prop_store helpers) but modules have since grown;
  re-opened scope above.
+ **QUAL-0040** — inter-file/inter-path duplication resolved (`EntryCursor`,
  `findEntrySpan`); residual intra-file chain-traversal scaffold remains.
+ **QUAL-0031** — shared `SingleStoreEnv`/`DualStoreEnv` added; `label_store.zig`
  still bespoke.
+ **QUAL-0039** — pre-commit config refuted/closed: `pre-commit validate-config`
  exits 0; `precommit-config-validate` CI job guards regression.
+ **QUAL-0033** — Won't Do: local/CI parity is intentionally not the control
  model; GitLab CI is the authoritative merge gate.
+ **QUAL-0034** (#56, still open) — public-doc/topology/crypto drift; D3/D4 of
  QUAL-0045 are additional drift surfaced after that issue's last edit.
+ Closed in that pass and not re-opened: PERF-0041, PERF-0043, PERF-0044,
  GAP-0025 (tracked in their own domain docs).

### Future agent notes

+ GitLab CI is the authoritative merge gate; do not reopen local/CI parity work
  (QUAL-0033) unless repository governance changes.
+ CI catalog tag-pinning is covered by GAP-0041 (Won't Do) — do not file QUAL
  issues for it.
+ Untracked `package.json` / `node_modules` is owned by the security tracker.

## Verification commands

+ `zig build test --summary all`
+ `zig build test-integration --summary all`
+ `zig build test-fuzz-regression --summary all`
+ `pre-commit validate-config`
+ `wc -l src/backup.zig src/recovery.zig src/engine.zig src/prop_store.zig src/buffer_pool.zig`
