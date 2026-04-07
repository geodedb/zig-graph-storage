# Performance Gap Analysis

Last updated: 2026-04-07

This file is the authoritative close-out record for the 2026-04-07
performance pass.

## Summary

| Status | Count |
| --- | ---: |
| Closed | 10 |
| Blocked | 0 |
| Won't Do | 0 |
| Open | 0 |

## Disposition

### PERF-0045: auto-commit mutation wrappers forced a WAL sync per single write

- Status: Closed
- Implemented:
  - `tests/seed.zig` now drives node and edge creation through explicit batched
    transactions instead of per-mutation auto-commit wrappers.
  - `src/engine.zig` adds `getOrAssignLabel(...)` so seed/bench paths can stay
    inside the same transaction batch.
- Outcome: the benchmark and large seed hot path no longer pays one durability
  sync per individual mutation.

### PERF-0041: traversal and label-scan APIs materialized full result slices

- Status: Closed
- Implemented:
  - Iterator-first APIs (`expandOutIter`, `expandInIter`, `scanLabelIter`) are
    the hot-path surface.
  - Slice adapters remain only as compatibility helpers.
- Notes:
  - This finding was stale in the runtime hot path; the closure pass confirmed
    the iterator path is the supported performance path.

### PERF-0047: checkpoint rewrote full metadata snapshots on every run

- Status: Closed
- Implemented:
  - `src/engine.zig` now tracks `persistence_dirty`.
  - `src/engine_persist.zig` skips checkpoint work entirely when the engine is
    already durably clean.
  - Mutating property/index paths now update incremental in-memory state so
    clean checkpoints do not rewrite metadata snapshots redundantly.
- Outcome: checkpoint/close no longer rewrites metadata "on every run"; it runs
  only when state changed.

### PERF-0046: property-chain refresh rescanned and rehashed full chains on every mutation

- Status: Closed
- Implemented:
  - `src/property_chain_index.zig` adds `upsertKey(...)` and `removeKey(...)`.
  - `src/engine.zig` now uses incremental property-index maintenance when a
    single key changes, falling back to full refresh only when the chain head
    changes unexpectedly.

### GAP-0043: crash restart could rebuild derived indexes via full store scans

- Status: Closed
- Implemented:
  - `src/engine_index.zig` persists and loads `labels.idx`, `props.idx`, and
    `edges.idx` against the checkpoint counter.
  - This pass confirmed the restart path loads persisted snapshots when they
    match the manifest counter instead of rebuilding by default.
- Notes:
  - The finding was stale relative to the current persisted-snapshot restart
    path; tracker state is now aligned to the implementation.

### PERF-0044: backup validate and restore loaded whole archives into memory

- Status: Closed
- Implemented:
  - `src/backup.zig` now streams restore and validation.
  - CRC and HMAC validation are computed incrementally instead of over a
    whole-file allocation.

### PERF-0048: edge-property helpers rescanned adjacency lists instead of using `edge_index`

- Status: Closed
- Implemented:
  - `src/engine_edge_props.zig` now resolves edge property heads from
    `edge_index` instead of rescanning outgoing adjacency lists.

### PERF-0049: startup metadata loaders materialized full snapshot files

- Status: Closed
- Implemented:
  - `src/index_snapshot.zig` exposes bounded snapshot header/payload helpers.
  - `src/label_index.zig`, `src/property_chain_index.zig`,
    `src/engine_index.zig`, and `src/label_dict.zig` now stream metadata
    snapshots and the label dictionary instead of loading them whole.

### PERF-0050: `close()` always forced another checkpoint and metadata save

- Status: Closed
- Implemented:
  - `src/engine.zig` and `src/engine_persist.zig` now skip redundant
    close-time persistence when the engine has no dirty state after an explicit
    checkpoint.

### PERF-0043: benchmark regression gate only exercised the `1K` smoke tier

- Status: Closed
- Implemented:
  - Added `benchmarks/results/ci-10k-baseline.json`.
  - Added `benchmark-regression-10k` to `.gitlab-ci.yml` for scheduled/manual
    larger-tier coverage.
  - Added `bench-baseline-10k` and `bench-compare-10k` to `Makefile`.
  - Updated `benchmarks/results/README.md` to distinguish CI baselines from
    local exploratory baselines.

## Verification

- `zig build compare-bench -- benchmarks/results/ci-baseline.json benchmarks/results/ci-baseline.json`
- `zig build compare-bench -- benchmarks/results/ci-10k-baseline.json benchmarks/results/ci-10k-baseline.json`
- `zig build test --summary all`
- `zig build test-integration --summary all`
