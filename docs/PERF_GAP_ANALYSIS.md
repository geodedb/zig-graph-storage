# Performance Gap Analysis

Last updated: 2026-06-10

Authoritative performance findings tracker for `gitlab.com/devnw/zig/graph-storage`.
Evidence verified at HEAD `eca7466`. Scoring uses PerfScore = Impact(1-5) x
Likelihood(1-5) x 4, with PerfSeverity P0..P3/Info.

> 2026-06-10 remediation pass (branch `audit-remediation-2026-06-10`, full suite
> green Debug + ReleaseSafe): 10 findings implemented and CLOSED -- PERF-0051
> (#111), 0052 (#112), 0053 (#113), 0054 (#114), 0055 (#116), 0056 (#119),
> 0057 (#120), 0058 (#122), 0060 (#125), 0061 (#126). PERF-0045 (#98, opt-in
> sync policy added; group_commit N/A) and PERF-0059 (#123, deferred) remain
> open with updated status. PERF-0041 (#88) progressed (zero-copy vtable path
> now first-class) but stays open. See "Resolved this pass" below.
>
> Note on the prior 2026-04-07 close-out: that pass marked PERF-0041, 0043,
> 0044, 0045, 0046, 0047 Closed. Re-verification at HEAD `eca7466` shows several
> were only **partially** mitigated and their GitLab issues remain open (see
> table). Only PERF-0048 (#101), PERF-0049 (#102) -- verified resolved -- and
> PERF-0050 (#103) -- closed this pass -- are genuinely done. The disposition
> log at the bottom preserves the close-out history.
>
> Correction (refutes a prior Phase-2 claim): CI benchmarks do **not** run in
> Debug. `build.zig:289` hardcodes `const bench_optimize: OptimizeMode =
> .ReleaseFast;` and every bench step (bench, load-bench, scale-bench,
> compare-bench, sharded benches) uses it (`build.zig:289-362`). Bench numbers
> are ReleaseFast.

## Summary

### Counts by PerfSeverity (open findings)

| PerfSeverity | Open | Notes |
| --- | ---: | --- |
| P0 | 0 | -- |
| P1 | 3 | #88 (progressed), #98 (re-scoped), #100 (P1-residual) |
| P2 | 3 | #96, #99, #90 |
| P3 | 1 | #123 (deferred) |
| Info | 0 | -- |
| Closed this pass | 10 | #111, #112, #113, #114, #116, #119, #120, #122, #125, #126 |
| Verified resolved (recommend close) | 2 | #101 (PERF-0048), #102 (PERF-0049) |

### Top 5 risks (by expected impact)

1. **Checkpoint full-index rewrite on any change (PERF-0047, #100)** -- O(index
   size) rewrite per checkpoint when dirty. Now the dominant open checkpoint
   cost after PERF-0052 (#112) eliminated the per-field syscalls. Expected:
   log-structured / delta snapshots remove the per-checkpoint full re-serialize.
2. **fsync-per-auto-commit (PERF-0045, #98)** -- dominated >=98% of write wall
   time. Now mitigable via the opt-in `GraphConfig.sync_mode` (commit `710dea2`);
   true cross-thread group-commit is architecturally N/A (single-writer per-shard
   WAL). Remaining lever: a value-batching multi-write commit API.
3. **Traversal/label-scan materialize full slices (PERF-0041, #88)** -- O(degree)
   allocation on the slice forms. Zero-copy `expandOutIter`/`expandInIter` are now
   first-class vtable methods (commit `6e4974d`); remaining work is migrating
   default call sites off the materializing forms.
4. **Property-chain index refresh full-rescan on head change (PERF-0046, #99)** --
   O(chain length) per head-change, common during seed.
5. **Backup WAL-UUID validation allocs whole file (PERF-0044, #96)** -- up to
   1 GiB transient on restore; needs bounded streaming read.

## Stack-ranked findings (PerfScore descending)

Open findings only (10 findings closed 2026-06-10 -- see "Resolved this pass").

| Rank | PerfSeverity | PerfScore | Finding | Component | Evidence | Measurement | Issue | Fix Summary | Owner | SLA/Due | Status |
| ---: | --- | ---: | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | P1 | 64 | Traversal & label-scan APIs materialize full result slices on the vtable | app | `engine.zig:712-749`; `interface.zig:122-123,139-140` | O(degree) alloc per call; `scanLabel` full posting-list copy | [#88](https://gitlab.com/devnw/zig/graph-storage/-/issues/88) | Zero-copy `expandOutIter`/`expandInIter` now first-class vtable methods (`6e4974d`); remaining: migrate default call sites off slice forms | app/api | Within sprint | Open (progressed `6e4974d`) |
| 2 | P1 | 64 | fsync per single auto-commit write dominates write wall time | db | `txn.zig:82` (`wal.sync()` per commit) | >=98% of write wall time | [#98](https://gitlab.com/devnw/zig/graph-storage/-/issues/98) | Opt-in `GraphConfig.sync_mode` added (`710dea2`); group_commit N/A (single-writer per-shard WAL); residual = value-batching commit API | wal/txn | Within sprint | Open (re-scoped `710dea2`) |
| 3 | P1 | 48 | Checkpoint rewrites full index snapshot on any change | db | `engine_index.zig:205` (`setLength(0)` + full re-serialize); `engine_persist.zig:267-272` | O(index size) per checkpoint when dirty | [#100](https://gitlab.com/devnw/zig/graph-storage/-/issues/100) | Incremental/delta snapshot updates | checkpoint/index | Within sprint | Open (partial) |
| 4 | P2 | 36 | Property-chain index refresh full-rescans on head change | db | `engine.zig:387-395,917` | O(chain length) per head-change (common during seed) | [#99](https://gitlab.com/devnw/zig/graph-storage/-/issues/99) | Incremental upsert on head-change path | engine/property | Next quarter | Open (residual) |
| 5 | P2 | 36 | Backup WAL-UUID validation still allocs whole file (1 GiB bound) | db | `backup.zig:520-539,543` | up to 1 GiB transient on restore | [#96](https://gitlab.com/devnw/zig/graph-storage/-/issues/96) | Bounded streaming read for UUID validation | backup | Next quarter | Open (partial) |
| 6 | P2 | 36 | Benchmark regression gate: 1K-only + `allow_failure:true` (never blocks); 10K only on schedule/manual | ci | `.gitlab-ci.yml:185-227` | at-scale regressions ungated | [#90](https://gitlab.com/devnw/zig/graph-storage/-/issues/90) | Blocking >=10K MR gate; gate on misses/op | bench/ci | Next quarter | Open (confirmed) |
| 7 | P3 | 36 | BufferPool mutex acquired on every pin/unpin even on hits | db | `buffer_pool.zig:129,200,235` | single-engine multi-thread reads serialize | [#123](https://gitlab.com/devnw/zig/graph-storage/-/issues/123) | Deferred -- needs lock-free/sharded page-table + LRU; single-writer serializes writes, per-shard pools avoid cross-shard contention | buffer-pool | Backlog | Open (deferred) |

## Findings by area

### app (application hot path)

- **#88 PERF-0041** (P1, 64) -- `expandOut`/`expandIn`/`scanLabel` slice forms
  remain on the vtable. Progressed (`6e4974d`): `expandOutIter`/`expandInIter`
  are now first-class vtable methods, so the zero-copy path is reachable without
  reflection; slice forms retained for compat. Remaining: migrate default call
  sites off the materializing forms.

### db (storage & persistence)

- **#98 PERF-0045** (P1, 64) -- fsync per auto-commit write. Re-scoped
  (`710dea2`): opt-in `GraphConfig.sync_mode` added (default unchanged); true
  cross-thread group_commit is N/A under single-writer per-shard WAL; residual
  is a value-batching multi-write commit API.
- **#100 PERF-0047** (P1, 48) -- full index snapshot rewrite on any change
  (partial mitigation: `persistence_dirty` + conditional save now skip clean
  state).
- **#99 PERF-0046** (P2, 36) -- property-chain index full-rescan on head change
  (partial: incremental upsert exists for unchanged-head path).
- **#96 PERF-0044** (P2, 36) -- backup WAL-UUID `readFileAlloc` 1 GiB-bounded
  whole-file alloc (partial: bulk archive path now streams).
- **#123 PERF-0059** (P3, 36) -- BufferPool mutex on every pin/unpin even on
  hits. Deferred -- needs a lock-free/sharded page-table + LRU redesign for
  limited payoff (single-writer serializes writes; per-shard pools avoid
  cross-shard contention).

### infra (runtime)

- None open this pass.

### ci (benchmark & CI path)

- **#90 PERF-0043** (P2, 36) -- bench gate is 1K-only and `allow_failure:true`
  (never blocks MRs); 10K job only runs on schedule/manual. `.gitlab-ci.yml:185-227`.

## Roadmap

### Quick wins (< 1 day)

- **#90 PERF-0043** -- drop `allow_failure:true` on a >=10K MR-scoped gate.

### Medium (1-5 days)

- **#88 PERF-0041** -- migrate default traversal/scan call sites onto the now
  first-class `expandOutIter`/`expandInIter` vtable methods; demote slice forms
  to thin compat adapters.
- **#99 PERF-0046** -- incremental upsert on the head-change path.
- **#96 PERF-0044** -- bounded streaming read for WAL-UUID validation.

### Strategic (> 5 days)

- **#98 PERF-0045** -- value-batching multi-write commit API (group_commit itself
  is N/A under single-writer per-shard WAL; opt-in `sync_mode` already lands the
  durability/throughput trade-off lever).
- **#100 PERF-0047** -- log-structured / delta index snapshots with compaction.
- **#123 PERF-0059** -- sharded/lock-free buffer pool for multi-thread read
  scaling (deferred -- concurrency redesign).

## Disposition (history + this-pass verification)

### Resolved this pass (2026-06-10, branch `audit-remediation-2026-06-10`)

All implemented and CLOSED; full suite green Debug + ReleaseSafe.

- **PERF-0051 (#111)** -- buffer-pool sizing/pollution (1700x lookup).
  Commit `1d64e88`: `create()` auto-sizes the pool + per-FileId soft-floor frame
  reservation protecting hot node pages; two-pass eviction proven deadlock-free.
- **PERF-0052 (#112)** -- index snapshot per-field syscalls. Commit `afa4b5e`:
  buffered single-pass serialize/deserialize; CRC + bounds preserved.
- **PERF-0053 (#113)** -- sharded 2PC full WAL materialization. Commit `2a602fa`:
  streaming strict reconciliation (single pass).
- **PERF-0054 (#114)** -- LabelIndex O(N) insert/remove. Commit `cbc4e40`:
  hash-set posting lists, sorted scan on demand.
- **PERF-0055 (#116)** -- redundant per-write encode/alloc. Commit `d2b505f`:
  encode hoisted into upsert branch, reusable buffer.
- **PERF-0056 (#119)** -- flushFrame copy + transient buffer. Commit `5c39208`:
  bounded page_size scratch, wave flushing.
- **PERF-0057 (#120)** -- checkpoint `syncAll` all files. Commit `5c39208`:
  dirty-aware fsync; durability ordering preserved with errdefer restore.
- **PERF-0058 (#122)** -- cross-shard 2PC serialized fsyncs. Commit `f8f22fb`:
  parallel prepares/commits on disjoint per-shard state.
- **PERF-0060 (#125)** -- `checkIntegrity` double scan. Commit `99b5ea9`:
  single `scanNodes` pass.
- **PERF-0061 (#126)** -- scale_bench omits misses/op. Commit `1d64e88`:
  emits `buffer_misses`/`page_reads` per op.

### Closed (prior pass)

- **PERF-0050 (#103)** -- `close()` always forced another checkpoint/metadata
  save. VERIFIED FIXED at `eca7466`: `engine.zig:484-507` gates all close-time
  persistence behind `if (self.persistence_dirty)`. Closed.

### Verified resolved at HEAD (recommend close)

- **PERF-0048 (#101)** -- edge-property helpers no longer rescan adjacency;
  prop_head resolved from `edge_index` (`engine_edge_props.zig:22,61,68,75`).
- **PERF-0049 (#102)** -- startup metadata loaders stream via `loadHeader` +
  `readBounded` (`label_index.zig:186-215`, `property_chain_index.zig:203-240`,
  `engine_index.zig:236-273`); no whole-file materialization.

### Re-opened / re-scoped (2026-04-07 close-out was premature)

- **PERF-0041 (#88)** -- iterator forms exist, but materializing slice forms
  remain on the public vtable. Progressed 2026-06-10 (`6e4974d`):
  `expandOutIter`/`expandInIter` promoted to first-class vtable methods, so the
  zero-copy path is reachable without reflection; slice forms retained for
  compat. Still P1 (open) -- remaining work is migrating default call sites.
- **PERF-0043 (#90)** -- 10K job + baseline were added, but the MR-scoped gate
  is still 1K-only and `allow_failure:true`. Still P2.
- **PERF-0044 (#96)** -- bulk archive path streams, but `readFileAlloc` WAL-UUID
  validation still allocs up to 1 GiB. Downgraded to P2 (narrow path).
- **PERF-0045 (#98)** -- seed/bench rerouted to batched txns; the engine
  auto-commit API still fsyncs per write (`txn.zig:82`) by default. Re-scoped
  2026-06-10 (`710dea2`): an opt-in `GraphConfig.sync_mode` lets callers choose
  a deferred-sync policy (default `sync_each_commit` keeps durability unchanged).
  True cross-thread group_commit is architecturally N/A -- single-writer
  per-shard WAL has no concurrent committers to coalesce. Kept OPEN, re-scoped
  to a future value-batching multi-write commit API (may instead be closed as
  "addressed via opt-in sync policy; group_commit not applicable"). Still P1.
- **PERF-0046 (#99)** -- incremental upsert added, but the head-change path still
  full-rescans (`engine.zig:917`). Residual P2.
- **PERF-0047 (#100)** -- `persistence_dirty` + conditional save added, but a
  dirty index is fully rewritten (`engine_index.zig:205`). Residual P1.

### New findings cohort (PERF-0051 .. PERF-0061)

Created with evidence at `eca7466` (issues 111-126). As of the 2026-06-10
remediation pass, all are CLOSED except **PERF-0059 (#123)**, which is DEFERRED
and kept open (needs a lock-free/sharded buffer-pool concurrency redesign for a
read-fan-out-only payoff). See "Resolved this pass" above for the closed cohort
with commits.

## Verification commands

- Buffer pool / read path: `zig build scale-bench -- 1K 10K 100K` (compare
  `point_lookup_ns` and, after #126, `buffer_misses_per_op` across tiers); rerun
  with a larger pool (`--buffer-pool-pages 131072`) to confirm the cliff
  flattens.
- Checkpoint/open: `zig build scale-bench -- 10K 100K` and compare
  `last_checkpoint_duration_ns` before/after #112/#100.
- Regression gate: `zig build compare-bench -- benchmarks/results/ci-baseline.json benchmarks/results/current-ci.json`
  and the 10K equivalent.
- Tests: `zig build test --summary all`; `zig build test-integration --summary all`.
