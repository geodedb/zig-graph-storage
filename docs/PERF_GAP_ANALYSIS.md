# Performance Gap Analysis

Last updated: 2026-06-10

Authoritative performance findings tracker for `gitlab.com/devnw/zig/graph-storage`.
Evidence verified at HEAD `eca7466`. Scoring uses PerfScore = Impact(1-5) x
Likelihood(1-5) x 4, with PerfSeverity P0..P3/Info.

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
| P1 | 4 | #111, #112, #98, #88 (and #100 P1-residual) |
| P2 | 6 | #96, #99, #100, #113, #114, #116, #119, #120 |
| P3 | 4 | #122, #123, #125, #126 |
| Info | 0 | -- |
| Closed this pass | 1 | #103 (PERF-0050) |
| Verified resolved (recommend close) | 2 | #101 (PERF-0048), #102 (PERF-0049) |

### Top 5 risks (by expected impact)

1. **Buffer-pool capacity/pollution (PERF-0051, #111)** -- 1700x point-lookup
   degradation (42ns @1K -> 72us @100K). Single shared LRU undersized for the
   ~820 MB prop working set @100K; cold prop scans evict hot node pages.
   Expected: point_lookup 72us -> sub-microsecond @100K.
2. **fsync-per-auto-commit (PERF-0045, #98)** -- dominates >=98% of write wall
   time. Group-commit is the lever. Expected: write throughput up by the
   commit-batch factor.
3. **Index snapshot per-field syscalls (PERF-0052, #112)** -- ~750K syscalls per
   checkpoint at 150K edges. Expected 5-20x checkpoint/open improvement.
4. **Traversal/label-scan materialize full slices (PERF-0041, #88)** -- O(degree)
   allocation per `expandOut`/`scanLabel` on the public vtable.
5. **Checkpoint full-index rewrite on any change (PERF-0047, #100)** -- O(index
   size) rewrite per checkpoint; compounds with PERF-0052 syscall cost.

## Stack-ranked findings (PerfScore descending)

| Rank | PerfSeverity | PerfScore | Finding | Component | Evidence | Measurement | Issue | Fix Summary | Owner | SLA/Due | Status |
| ---: | --- | ---: | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | P1 | 100 | Buffer-pool capacity/pollution causes 1700x point-lookup degradation at scale | app/db | `config.zig:50-55`; `engine.zig:197,267-285`; `engine_persist.zig:201-205`; `scale_bench.zig:226,954` | 42ns@1K -> 72us@100K (~1700x); 820MB props vs 32MB bench pool | [#111](https://gitlab.com/devnw/zig/graph-storage/-/issues/111) | Auto-size/raise pool on create; per-FileId frame reservation; surface misses/op | buffer-pool | Within sprint | Open (confirmed) |
| 2 | P1 | 64 | Traversal & label-scan APIs materialize full result slices on the vtable | app | `engine.zig:712-749`; `interface.zig:122-123,139-140` | O(degree) alloc per call; `scanLabel` full posting-list copy | [#88](https://gitlab.com/devnw/zig/graph-storage/-/issues/88) | Demote slice forms to adapters; surface `expandOutIter`/`scanLabelIter` as vtable hot path | app/api | Within sprint | Open (confirmed) |
| 3 | P1 | 64 | Index snapshot save/load does per-field positional syscalls | db | `engine_index.zig:214-232,247-268`; `label_index.zig:167-179` | 5 syscalls/edge x 150K = ~750K/checkpoint | [#112](https://gitlab.com/devnw/zig/graph-storage/-/issues/112) | Buffered writer/reader, single serialize | index/persist | Within sprint | Open (confirmed) |
| 4 | P1 | 64 | fsync per single auto-commit write dominates write wall time | db | `txn.zig:82` (`wal.sync()` per commit) | >=98% of write wall time | [#98](https://gitlab.com/devnw/zig/graph-storage/-/issues/98) | Group-commit / commit pipelining | wal/txn | Within sprint | Open (confirmed) |
| 5 | P1 | 48 | Checkpoint rewrites full index snapshot on any change | db | `engine_index.zig:205` (`setLength(0)` + full re-serialize); `engine_persist.zig:267-272` | O(index size) per checkpoint when dirty | [#100](https://gitlab.com/devnw/zig/graph-storage/-/issues/100) | Incremental/delta snapshot updates | checkpoint/index | Within sprint | Open (partial) |
| 6 | P2 | 48 | LabelIndex O(N) posting-list insert/remove (O(N^2) bulk seed) | db | `label_index.zig:85-95,113` | 10K same-label seed ~50M element moves | [#114](https://gitlab.com/devnw/zig/graph-storage/-/issues/114) | Append+sort-once for bulk; monotonic fast-path | index | Next quarter | Open (confirmed) |
| 7 | P2 | 48 | Redundant per-write property encode + heap alloc in putPropertyTxn | db | `engine.zig:911-918`; `prop_store.zig:314-324` | ~400K extra allocs @100K seed | [#116](https://gitlab.com/devnw/zig/graph-storage/-/issues/116) | Hoist encode into upsert branch; reuse stack buffer | engine/property | Next quarter | Open (confirmed) |
| 8 | P2 | 36 | Property-chain index refresh full-rescans on head change | db | `engine.zig:387-395,917` | O(chain length) per head-change (common during seed) | [#99](https://gitlab.com/devnw/zig/graph-storage/-/issues/99) | Incremental upsert on head-change path | engine/property | Next quarter | Open (residual) |
| 9 | P2 | 36 | Backup WAL-UUID validation still allocs whole file (1 GiB bound) | db | `backup.zig:520-539,543` | up to 1 GiB transient on restore | [#96](https://gitlab.com/devnw/zig/graph-storage/-/issues/96) | Bounded streaming read for UUID validation | backup | Next quarter | Open (partial) |
| 10 | P2 | 36 | Sharded 2PC recovery materializes full WAL twice per shard | db | `sharded_recovery.zig:53,98` | 2x WAL decode + RSS on recovery path | [#113](https://gitlab.com/devnw/zig/graph-storage/-/issues/113) | Single streaming strict pass (with SEC-0041) | sharding/recovery | Next quarter | Open (confirmed) |
| 11 | P2 | 36 | flushFrame 16KB stack copy under mutex + transient dirty_count*page_size buffer | db | `buffer_pool.zig:446-448,294-303` | ~800MB transient @100K checkpoint | [#119](https://gitlab.com/devnw/zig/graph-storage/-/issues/119) | page_size scratch; chunked parallel flush | buffer-pool | Next quarter | Open (confirmed) |
| 12 | P2 | 36 | Checkpoint syncAll fsyncs every store file sequentially regardless of dirtiness | db | `checkpoint.zig:67`; `file_manager.zig:122-127` | N serial fsyncs/checkpoint incl. clean files | [#120](https://gitlab.com/devnw/zig/graph-storage/-/issues/120) | Dirty-aware + parallel sync | checkpoint/file-mgr | Next quarter | Open (confirmed) |
| 13 | P3 | 36 | BufferPool mutex acquired on every pin/unpin even on hits | db | `buffer_pool.zig:129,200,235` | single-engine multi-thread reads serialize | [#123](https://gitlab.com/devnw/zig/graph-storage/-/issues/123) | Shard pool / lock-free hit path | buffer-pool | Backlog | Open (confirmed) |
| 14 | P3 | 32 | scale_bench JSON omits buffer_misses/page_reads per op | ci | `scale_bench.zig:181-210,954-1024` | thrash invisible to CI gate | [#126](https://gitlab.com/devnw/zig/graph-storage/-/issues/126) | Emit misses/reads per op; gate on them | bench/ci | Backlog | Open (confirmed) |
| 15 | P3 | 24 | Cross-shard 2PC issues 4 serialized fsyncs per cross-shard edge | db | `sharded_engine_2pc.zig:99,122`; `sharded_engine.zig:328-334,367-371` | 4x fsync latency floor per cross-shard edge | [#122](https://gitlab.com/devnw/zig/graph-storage/-/issues/122) | Parallelize prepares/commits | sharding | Backlog | Open (confirmed) |
| 16 | P3 | 16 | checkIntegrity double full-scan via per-node getNode | db | `engine_integrity.zig:76-113` | 2x id-space walks + per-id pins | [#125](https://gitlab.com/devnw/zig/graph-storage/-/issues/125) | Single `scanNodes` batched pass | integrity | Backlog | Open (confirmed) |
| -- | P2 | 36 | Benchmark regression gate: 1K-only + `allow_failure:true` (never blocks); 10K only on schedule/manual | ci | `.gitlab-ci.yml:185-227` | at-scale regressions ungated | [#90](https://gitlab.com/devnw/zig/graph-storage/-/issues/90) | Blocking >=10K MR gate; gate on misses/op | bench/ci | Next quarter | Open (confirmed) |

## Findings by area

### app (application hot path)

- **#88 PERF-0041** (P1, 64) -- `expandOut`/`expandIn`/`scanLabel` materialize
  full slices on the public vtable; lazy `expandOutIter`/`expandInIter` exist
  internally (`engine.zig:707,724`) but are not the vtable surface.

### db (storage & persistence)

- **#111 PERF-0051** (P1, 100) -- buffer-pool capacity/pollution; 1700x lookup
  cliff.
- **#112 PERF-0052** (P1, 64) -- per-field positional syscalls in index
  snapshot save/load.
- **#98 PERF-0045** (P1, 64) -- fsync per auto-commit write; group-commit lever.
- **#100 PERF-0047** (P1, 48) -- full index snapshot rewrite on any change
  (partial mitigation: `persistence_dirty` + conditional save now skip clean
  state).
- **#114 PERF-0054** (P2, 48) -- LabelIndex O(N) insert/remove.
- **#116 PERF-0055** (P2, 48) -- redundant per-write encode/alloc in
  `putPropertyTxn`.
- **#99 PERF-0046** (P2, 36) -- property-chain index full-rescan on head change
  (partial: incremental upsert exists for unchanged-head path).
- **#96 PERF-0044** (P2, 36) -- backup WAL-UUID `readFileAlloc` 1 GiB-bounded
  whole-file alloc (partial: bulk archive path now streams).
- **#113 PERF-0053** (P2, 36) -- sharded recovery double full WAL materialization
  (overlaps SEC-0041).
- **#119 PERF-0056** (P2, 36) -- flushFrame 16KB stack copy under mutex +
  `dirty_count*page_size` transient flush buffer.
- **#120 PERF-0057** (P2, 36) -- checkpoint `syncAll` fsyncs every store file
  sequentially regardless of dirtiness.
- **#123 PERF-0059** (P3, 36) -- BufferPool mutex on every pin/unpin even on
  hits.
- **#122 PERF-0058** (P3, 24) -- cross-shard 2PC 4 serialized fsyncs per edge.
- **#125 PERF-0060** (P3, 16) -- `checkIntegrity` double full-scan via per-node
  `getNode`.

### infra (runtime)

- None open this pass.

### ci (benchmark & CI path)

- **#90 PERF-0043** (P2, 36) -- bench gate is 1K-only and `allow_failure:true`
  (never blocks MRs); 10K job only runs on schedule/manual. `.gitlab-ci.yml:185-227`.
- **#126 PERF-0061** (P3, 32) -- scale_bench JSON omits `buffer_misses`/
  `page_reads` per op, so thrash (PERF-0051) is invisible to the gate.

## Roadmap

### Quick wins (< 1 day)

- **#116 PERF-0055** -- hoist `property_indexEncodedValue` into the upsert branch
  and reuse a stack buffer.
- **#120 PERF-0057** -- gate `syncAll` on per-file dirtiness (data already known
  to the buffer pool).
- **#126 PERF-0061** -- snapshot `engine.metrics` buffer counters into the
  scale_bench JSON.
- **#90 PERF-0043** -- drop `allow_failure:true` on a >=10K MR-scoped gate.
- **#125 PERF-0060** -- collapse `checkIntegrity` to one `scanNodes` pass.

### Medium (1-5 days)

- **#111 PERF-0051** -- auto-size pool on create + per-FileId frame reservation.
- **#112 PERF-0052** -- buffered single-serialize for index snapshots
  (do with #100 PERF-0047).
- **#114 PERF-0054** -- bulk-seed append+sort-once / monotonic fast-path.
- **#99 PERF-0046** -- incremental upsert on the head-change path.
- **#119 PERF-0056** -- page_size scratch + chunked parallel flush.
- **#122 PERF-0058** -- parallelize cross-shard prepares/commits.
- **#96 PERF-0044** -- bounded streaming read for WAL-UUID validation.

### Strategic (> 5 days)

- **#98 PERF-0045** -- group-commit / commit pipelining (highest write-path
  leverage; also amortizes #122 cross-shard fsyncs).
- **#100 PERF-0047** -- log-structured / delta index snapshots with compaction.
- **#113 PERF-0053** -- single streaming strict WAL reader for sharded recovery
  (joint with SEC-0041).
- **#123 PERF-0059** -- sharded/lock-free buffer pool for multi-thread read
  scaling.

## Disposition (history + this-pass verification)

### Closed this pass

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
  remain on the public vtable and `expandOut` drains internally. Still P1.
- **PERF-0043 (#90)** -- 10K job + baseline were added, but the MR-scoped gate
  is still 1K-only and `allow_failure:true`. Still P2.
- **PERF-0044 (#96)** -- bulk archive path streams, but `readFileAlloc` WAL-UUID
  validation still allocs up to 1 GiB. Downgraded to P2 (narrow path).
- **PERF-0045 (#98)** -- seed/bench rerouted to batched txns, but the engine
  auto-commit API still fsyncs per write (`txn.zig:82`). Group-commit unbuilt.
- **PERF-0046 (#99)** -- incremental upsert added, but the head-change path still
  full-rescans (`engine.zig:917`). Residual P2.
- **PERF-0047 (#100)** -- `persistence_dirty` + conditional save added, but a
  dirty index is fully rewritten (`engine_index.zig:205`). Residual P1.

### New findings this pass (PERF-0051 .. PERF-0061)

See the stack-ranked table and "Findings by area" above. All created on GitLab
with evidence at `eca7466`. Issue numbers: 111, 112, 113, 114, 116, 119, 120,
122, 123, 125, 126.

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
