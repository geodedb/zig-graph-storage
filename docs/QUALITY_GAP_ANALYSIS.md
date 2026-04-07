# Quality Gap Analysis

Last updated: 2026-04-07

This file is the authoritative close-out record for the 2026-04-07 quality and
maintainability pass.

## Summary

| Status | Count |
| --- | ---: |
| Closed | 9 |
| Blocked | 0 |
| Won't Do | 1 |
| Open | 0 |

## Future Agent Notes

- GitLab CI is the authoritative merge gate.
- Repo-local pre-commit hooks are intentionally a fast subset. Do not reopen
  parity work unless repository governance changes and explicitly requires it.

## Disposition

### QUAL-0027: oversized high-churn core modules remained multi-responsibility

- Status: Closed
- Implemented:
  - `src/engine_edge_props.zig` and `src/engine_index.zig` carry more of the
    engine coordination surface.
  - `src/backup.zig` now routes archive parsing and restore/validate through
    focused streaming helpers instead of one whole-file path.
  - `src/prop_store.zig` now shares page-edit helpers for entry parse/remove
    flows instead of maintaining separate byte-level implementations.
- Outcome: the highest-churn logic called out by this review now lives behind
  narrower modules or shared helpers with direct unit coverage.

### PERF-0041: traversal and label-scan APIs materialized full result slices

- Status: Closed
- Implemented:
  - Iterator-first traversal and label-scan paths remain the hot-path API
    surface; slice-returning helpers are compatibility adapters only.

### QUAL-0033: quality checks were fragmented across Makefile, pre-commit, and GitLab CI

- Status: Won't Do
- Reason: local and CI parity is intentionally not the repository control
  model.
- Documented controls:
  - `.gitlab-ci.yml` explicitly states that GitLab CI is the authoritative
    merge gate.
  - `.pre-commit-config.yaml` explicitly states that local hooks are an
    intentionally fast subset.
  - `Makefile` now repeats the same future-agent note near the pre-commit
    targets.
- Future-agent instruction: do not reopen parity work unless repository
  governance changes.

### QUAL-0039: pre-commit configuration was syntactically invalid and unverified

- Status: Closed
- Implemented:
  - `.pre-commit-config.yaml` now uses a valid YAML form for `check-todos`.
  - `.gitlab-ci.yml` adds a `precommit-config-validate` job.
  - Targeted hooks now pass for config syntax, YAML formatting, JSON validity,
    trailing whitespace, and end-of-file normalization.
- Notes:
  - A full `pre-commit run --all-files` still reports a separate repository-wide
    markdownlint backlog outside this gap item.

### QUAL-0040: PropStore duplicated slotted-page mutation and compaction logic

- Status: Closed
- Implemented:
  - `src/prop_store.zig` now shares entry parsing, span discovery, compaction,
    and removal helpers across update/delete paths.

### PERF-0044: backup validate and restore paths loaded whole archives into memory

- Status: Closed
- Implemented:
  - `src/backup.zig` now streams restore and validation with bounded buffers and
    incremental integrity checks.

### GAP-0025: structured maintenance results remained incomplete

- Status: Closed
- Implemented:
  - `src/operation_result.zig` now exposes a shared operation-artifact schema.
  - `src/verify.zig` and `src/maintenance.zig` now both emit `artifacts` plus
    structured `details` JSON payloads.
  - `src/maintenance.zig` adds per-operation details for checkpoint, rebuild,
    flush, and storage-stats flows.

### QUAL-0034: public docs drifted from the implemented topology and crypto mode

- Status: Closed
- Implemented:
  - Updated `README.md`, `src/root.zig`, `docs/architecture.md`,
    `docs/operations.md`, and `docs/format-spec.md` to describe
    `PropertyChainIndex`, derived snapshots, `wal/graph.wal`, and AES-256-GCM.

### PERF-0043: benchmark regression gate only exercised the `1K` smoke tier

- Status: Closed
- Implemented:
  - Added `benchmarks/results/ci-10k-baseline.json`.
  - Added `benchmark-regression-10k` to `.gitlab-ci.yml`.
  - Added `bench-baseline-10k` and `bench-compare-10k` to `Makefile`.

### QUAL-0031: store-level fixture scaffolding remained duplicated outside `testing_support.zig`

- Status: Closed
- Implemented:
  - `src/testing_support.zig` now provides shared `SingleStoreEnv` and
    `DualStoreEnv` test harnesses.
  - `src/node_store.zig`, `src/var_store.zig`, `src/label_index.zig`,
    `src/prop_store.zig`, and `src/maintenance.zig` now consume the shared
    harness instead of duplicating temp-dir/pager bootstrap code.

## Verification

- `zig build test --summary all`
- `zig build test-integration --summary all`
- `zig build test-fuzz-regression --summary all`
- `pre-commit validate-config`
- `pre-commit run check-json --all-files`
- `pre-commit run pretty-format-yaml --all-files`
