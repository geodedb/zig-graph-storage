# Performance Gap Analysis

Last updated: 2026-04-07

GitLab remains the source of truth for the linked work items. This file records the repository-state outcome of the 2026-04-07 closure pass.

## Summary

| Status | Count |
|--------|-------|
| Closed | 8 |
| Blocked | 1 |
| Won't Do | 0 |

- Verification completed in this pass:
  - `zig build`
  - `zig build scale-bench -- 1K > /tmp/current-ci.json`
  - `zig build compare-bench -- benchmarks/results/ci-baseline.json /tmp/current-ci.json`
- Future agent note:
  - The merge-path benchmark gate intentionally uses the checked-in 1K `ci-baseline.json` because it is repeatable on standard CI runners.
  - `benchmarks/results/baseline.json` is still the full-scale aspirational reference file, but regenerating an all-tier 250K/500K baseline remains blocked by runtime on the current hardware/workspace.

## Status Table

| Finding | Issue | Status | What changed |
|---------|-------|--------|--------------|
| Recovery loads the full WAL tail into memory | [#46](https://gitlab.com/devnw/zig/graph-storage/-/work_items/46) | Closed | Recovery now streams WAL replay via `WalManager.forEachFrom()` instead of materializing a full record slice. |
| Traversal and label-scan APIs materialize full result slices | [#88](https://gitlab.com/devnw/zig/graph-storage/-/work_items/88) | Closed | Added iterator-native `expandOutIter`, `expandInIter`, and `scanLabelIter` paths through `src/engine.zig` and `src/interface.zig`, plus allocation-sensitive coverage in `src/engine_test.zig`. |
| Open rebuilds the full edge index because it is not persisted | [#71](https://gitlab.com/devnw/zig/graph-storage/-/work_items/71) | Closed | Added persisted `edges.idx` snapshot support and load-on-open behavior so reopen no longer depends on rescanning adjacency when snapshots are valid. |
| Benchmark regression checks are advisory and cannot block drift | [#85](https://gitlab.com/devnw/zig/graph-storage/-/work_items/85) | Closed | Added a required merge-path `benchmark-regression` job backed by the checked-in `benchmarks/results/ci-baseline.json` and the `compare-bench` command. |
| Backup creation buffers graph contents in memory | [#76](https://gitlab.com/devnw/zig/graph-storage/-/work_items/76) | Closed | `createBackup()` now streams file reads in fixed-size chunks instead of buffering full payloads. |
| Benchmark reporting only captures single averages | [#84](https://gitlab.com/devnw/zig/graph-storage/-/work_items/84) | Closed | The benchmark JSON schema now includes `avg`, `p50`, `p95`, `p99`, `stddev`, and `samples`, and `compare-bench` diffs those fields explicitly. |
| Benchmark baseline coverage omits the 250K and 500K tiers | [#90](https://gitlab.com/devnw/zig/graph-storage/-/work_items/90) | Blocked | Full multi-tier baseline regeneration remains too slow on the current hardware/workspace, even after refactoring the benchmark to seed once per sample and reducing large-tier tuning. | 
| GitLab CI re-installs Zig in every job | [#86](https://gitlab.com/devnw/zig/graph-storage/-/work_items/86) | Closed | Repository-defined Zig jobs now consume a prepared `prepare-zig` artifact instead of bootstrapping Zig in every job. |
| `BufferPool.pin()` holds the global mutex across miss I/O | [#89](https://gitlab.com/devnw/zig/graph-storage/-/work_items/89) | Closed | Cache-miss reads now reserve the frame, drop the mutex during disk I/O, and coordinate with a condition variable so other threads wait on the in-flight load instead of serializing behind the global lock. |

## Blocker Details

### `#90` full 250K / 500K baseline regeneration

- Current state:
  - `compare-bench` now fails tier-set mismatches and skipped tiers as intended.
  - A practical CI gate exists via `benchmarks/results/ci-baseline.json` and the 1K benchmark profile.
  - The full all-tier baseline still does not complete within a reasonable review/runtime budget on the current machine.
- Required unblock:
  - either provision a faster benchmark runner or a dedicated overnight benchmark pipeline
  - or improve large-tier seed/checkpoint/open throughput enough for full 250K/500K runs to complete reliably
  - once that exists, regenerate `benchmarks/results/baseline.json` from a successful full-tier run and keep `compare-bench` pointed at it for non-CI full-scale comparisons
