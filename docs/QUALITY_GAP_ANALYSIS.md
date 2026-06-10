# Quality Gap Analysis

Last updated: 2026-06-10

This file tracks open QUALITY-domain findings for `graph-storage`, scored with a
consistent framework and linked to GitLab issues. Gap, security, and performance
findings are tracked in their own `*_GAP_ANALYSIS.md` documents.

Scoring: `PriorityScore = Impact(1-5) × Likelihood(1-5) × 4` (0-100). Severity is
the qualitative band; PriorityScore is the stack-rank key.

## Summary

### Open findings by severity

| Severity | Open count |
| --- | ---: |
| Critical | 0 |
| High | 3 |
| Medium | 4 |
| Low | 3 |
| Info | 0 |
| Won't Do | 1 (QUAL-0033) |

### Top 5 risks (by PriorityScore)

1. **QUAL-0027** (80) — Oversized high-churn core modules; `engine.zig` grew to
   1172 lines (+46% since filing) and remains the top-churn file.
2. **QUAL-0041** (60) — Error-set incoherence: declared `StorageError` is
   unenforced and the entire vtable is `anyerror`.
3. **QUAL-0042** (48) — Resource/FD leak on post-`initSubsystems` error paths in
   `create()` / `open()`.
4. **QUAL-0044** (48) — Test gaps on the hardest paths (property overflow chain,
   create/open faults, real fuzzing of format decoders).
5. **QUAL-0040** (36) — Residual intra-file chain-traversal scaffold duplicated
   4× in `prop_store.zig` (`PageChainCursor` extraction proposed).

## Stack-ranked findings (open)

| Rank | Severity | PriorityScore | Category | Finding | Component | Evidence | Issue URL | Fix Summary | Owner | ETA/SLA | Status |
| ---: | --- | ---: | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | High | 80 | architecture | QUAL-0027 Oversized high-churn core modules | `backup.zig` 1399, `recovery.zig` 1395, `engine.zig` 1172, `prop_store.zig` 1171, `buffer_pool.zig` 1009 | `engine.zig` mixes lifecycle + vtable + ~9 auto-commit wrappers + index refresh + thread-pool + metrics | [#72](https://gitlab.com/devnw/zig/graph-storage/-/issues/72) | Extend `engine_persist`/`engine_index`/`engine_integrity` delegation; factor auto-commit wrapper; split backup/recovery by responsibility | Engine owner | 5-10d | Open |
| 2 | High | 60 | api-contract | QUAL-0041 Error-set incoherence | `errors.zig`, `interface.zig`, all stores | `StorageError` 35 variants vs ad-hoc `InvalidData`×36, `DataCorruption`×24, `UnexpectedEndOfInput`×19, …; vtable `anyerror` `interface.zig:116-152` | [#121](https://gitlab.com/devnw/zig/graph-storage/-/issues/121) | Adopt/extend `StorageError` as real return union; narrow vtable off `anyerror` | Interface owner | 3-5d | Open |
| 3 | High | 48 | reliability | QUAL-0042 Resource/FD leak on create/open error paths | `engine.zig`, `engine_persist.zig` | `errdefer`s scoped to `initSubsystems` (`engine_persist.zig:171-226`); post-call failures at `engine.zig:216/293/295/301-304/310/323` leak all subsystems incl. `wal_dir_handle` | [#124](https://gitlab.com/devnw/zig/graph-storage/-/issues/124) | Add `cleanupSubsystems()` + `errdefer` after `initSubsystems` in create (`:209`) and open (`:288`); fault-injection test | Engine owner | 1-3d | Open |
| 4 | Medium | 48 | tests | QUAL-0044 Test gaps on hardest paths | `prop_store.zig` tests, `tests/fuzz_regression.zig` | All 24 prop_store tests single-page; overflow chain `prop_store.zig:145-216` untested; "fuzz" = 3 fixed cases; no `std.testing.fuzz` | [#131](https://gitlab.com/devnw/zig/graph-storage/-/issues/131) | Overflow-chain test, dir-disable/max-key tests, create/open fault tests, `std.testing.fuzz` decoder targets | Format/test owner | 5-10d | Open |
| 5 | Medium | 36 | maintainability | QUAL-0040 Residual chain-traversal scaffold dup | `prop_store.zig` | Pin/loop/hop-guard/`DataCorruption` prologue repeated at `:147,372,427,492` (~120 dup lines) | [#97](https://gitlab.com/devnw/zig/graph-storage/-/issues/97) | Extract `PageChainCursor` owning pin/unpin/hop-guard/corruption mapping; reuse existing `EntryCursor`/`findEntrySpan` | PropStore owner | 1-3d | Open |
| 6 | Medium | 36 | api-contract | QUAL-0043 Read methods lack ownership docs; iter API not first-class | `engine.zig`, `interface.zig` | `expandOut/getProperty/scanLabel/getEdgeProperty` (`engine.zig:712,870,1034,1133`) no doc comments; iter bridged via `@hasDecl` `interface.zig:315-323,388-396`; allocator-param asymmetry | [#127](https://gitlab.com/devnw/zig/graph-storage/-/issues/127) | Doc ownership; promote iter methods to vtable; reconcile signatures | Interface owner | 1-3d | Open |
| 7 | Medium | 36 | docs | QUAL-0045 Doc drift (version/Zig/threading/spec) | `build.zig.zon`, `root.zig`, `README.md`, `format-spec.md` | zon `0.1.5` vs root `0.2.0` vs README v0.2.0; README Zig-0.15.x vs CI `0.16.0`; spec §3.5.1 omits AES-GCM tail; README:13 "single-threaded" stale | [#136](https://gitlab.com/devnw/zig/graph-storage/-/issues/136) | Single-source version; fix Zig claim; document tag tail in spec; "single-writer"; clear markdownlint backlog | Docs owner | 1d | Open |
| 8 | Medium | 24 | tests | QUAL-0031 Store fixture scaffolding (residual: `label_store.zig`) | `label_store.zig` | Most stores migrated to `testing_support` `SingleStoreEnv`/`DualStoreEnv`; `label_store.zig:98-126` still bespoke | [#81](https://gitlab.com/devnw/zig/graph-storage/-/issues/81) | Migrate `label_store.zig` tests onto shared harness | Test owner | <1d | Open |
| 9 | Low | 24 | maintainability | QUAL-0047 Span/pager boilerplate + integrity swallows IO errors | `engine.zig`, `engine_integrity.zig` | Span pattern ×~25 (`engine.zig:609-613`, 103 refs); pager block dup `:199-204`/`:279-284`; `engine_integrity.zig:95-114` `catch`→count | [#138](https://gitlab.com/devnw/zig/graph-storage/-/issues/138) | Span wrapper helper; `registerAllPagers()`; preserve error detail in integrity scan | Engine owner | 1-3d | Open |
| 10 | Low | 16 | deps | QUAL-0048 build.zig.zon ref/version label mismatch | `build.zig.zon` | `wal` ref=v0.1.5 vs hash `wal-0.1.4`; `otel` ref=v0.1.8 vs hash `otel-0.1.7` | [#139](https://gitlab.com/devnw/zig/graph-storage/-/issues/139) | Align upstream tags with declared versions; refresh hashes | Deps owner | <1d | Open |
| 11 | Low | 12 | readability | QUAL-0046 catch-unreachable type-inference hack | `sharded_engine.zig` | `@TypeOf(... catch unreachable)` at `:404,420` | [#137](https://gitlab.com/devnw/zig/graph-storage/-/issues/137) | Spell concrete return types | Sharded-engine owner | <1d | Open |
| — | — | — | ci-cd | QUAL-0033 Quality checks fragmented across Make/pre-commit/CI | `Makefile`, `.pre-commit-config.yaml`, `.gitlab-ci.yml` | Intentional fast-subset model; CI is authoritative gate | [#83](https://gitlab.com/devnw/zig/graph-storage/-/issues/83) | Won't Do — parity is not the control model | — | — | Won't Do |

## Findings by category

### api-contract

- **QUAL-0041** (High, 60) — `StorageError` unenforced; vtable `anyerror`. [#121]
- **QUAL-0043** (Medium, 36) — read-method ownership docs + iterator API not
  first-class in vtable. [#127]

### architecture

- **QUAL-0027** (High, 80) — oversized high-churn modules; extend the existing
  `engine_*` delegation pattern. [#72]

### reliability

- **QUAL-0042** (High, 48) — resource/FD leak on create/open error paths. [#124]

### maintainability

- **QUAL-0040** (Medium, 36) — residual chain-traversal scaffold dup;
  `PageChainCursor` extraction. [#97]
- **QUAL-0047** (Low, 24) — span/pager boilerplate + integrity error-swallowing.
  [#138]

### tests

- **QUAL-0044** (Medium, 48) — overflow chain / create-open faults / real fuzz.
  [#131]
- **QUAL-0031** (Medium, 24) — residual bespoke fixture in `label_store.zig`.
  [#81]

### docs

- **QUAL-0045** (Medium, 36) — version/Zig/threading/spec drift; folds the
  markdownlint backlog. Related to QUAL-0034 (#56, still open). [#136]

### deps

- **QUAL-0048** (Low, 16) — `wal`/`otel` ref-vs-hash version label mismatch.
  [#139]

### readability

- **QUAL-0046** (Low, 12) — `catch unreachable` type-inference hack. [#137]

### ci-cd

- **QUAL-0033** (Won't Do) — quality-check fragmentation is intentional;
  GitLab CI is the authoritative merge gate. [#83]

## Roadmap

### Quick wins (< 1 day)

- **QUAL-0045** doc drift — single-source version, fix Zig claim, document the
  AES-GCM tag tail in `format-spec.md` §3.5.1, fix README "single-writer".
- **QUAL-0031** migrate `label_store.zig` tests onto `SingleStoreEnv`.
- **QUAL-0046** spell concrete return types in `sharded_engine.zig`.
- **QUAL-0048** align `wal`/`otel` tags with declared versions.

### Medium (1-5 days)

- **QUAL-0041** adopt/extend `StorageError`; narrow vtable off `anyerror`.
- **QUAL-0042** add `cleanupSubsystems()` + `errdefer` in create/open + fault
  test.
- **QUAL-0040** extract `PageChainCursor`.
- **QUAL-0043** ownership docs + promote iterator methods to the vtable.
- **QUAL-0047** span wrapper + `registerAllPagers()` + integrity error detail.

### Strategic (> 5 days)

- **QUAL-0027** decompose `engine.zig` (auto-commit wrapper, runtime/metrics) and
  split `backup.zig` / `recovery.zig` by responsibility, extending the existing
  `engine_persist`/`engine_index`/`engine_integrity` delegation.
- **QUAL-0044** build out overflow-chain coverage and `std.testing.fuzz` targets
  for the property/WAL/page-directory decoders.

## Historical close-out (2026-04-07 pass)

The following items were dispositioned in the 2026-04-07 quality pass. Note that
several GitLab issues for these IDs remained open at re-audit on 2026-06-10 and
have been re-scored above with current measurements.

- **QUAL-0027** — partial decomposition landed (`engine_edge_props`,
  `engine_index`, focused backup/prop_store helpers) but modules have since grown;
  re-opened scope above.
- **QUAL-0040** — inter-file/inter-path duplication resolved (`EntryCursor`,
  `findEntrySpan`); residual intra-file chain-traversal scaffold remains.
- **QUAL-0031** — shared `SingleStoreEnv`/`DualStoreEnv` added; `label_store.zig`
  still bespoke.
- **QUAL-0039** — pre-commit config refuted/closed: `pre-commit validate-config`
  exits 0; `precommit-config-validate` CI job guards regression.
- **QUAL-0033** — Won't Do: local/CI parity is intentionally not the control
  model; GitLab CI is the authoritative merge gate.
- **QUAL-0034** (#56, still open) — public-doc/topology/crypto drift; D3/D4 of
  QUAL-0045 are additional drift surfaced after that issue's last edit.
- Closed in that pass and not re-opened: PERF-0041, PERF-0043, PERF-0044,
  GAP-0025 (tracked in their own domain docs).

### Future agent notes

- GitLab CI is the authoritative merge gate; do not reopen local/CI parity work
  (QUAL-0033) unless repository governance changes.
- CI catalog tag-pinning is covered by GAP-0041 (Won't Do) — do not file QUAL
  issues for it.
- Untracked `package.json` / `node_modules` is owned by the security tracker.

## Verification commands

- `zig build test --summary all`
- `zig build test-integration --summary all`
- `zig build test-fuzz-regression --summary all`
- `pre-commit validate-config`
- `wc -l src/backup.zig src/recovery.zig src/engine.zig src/prop_store.zig src/buffer_pool.zig`
