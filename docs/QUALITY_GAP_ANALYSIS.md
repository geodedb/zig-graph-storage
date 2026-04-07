# Quality Gap Analysis

Last updated: 2026-04-07

GitLab remains the source of truth for the linked work items. This file records the repository-state outcome of the 2026-04-07 closure pass.

## Summary

| Status | Count |
|--------|-------|
| Closed | 12 |
| Won't Do | 1 |
| Blocked | 0 |

- Verification completed in this pass:
  - `zig build`
  - `zig build check`
  - `zig build test --summary all`
  - `zig build test-integration --summary all`
  - `zig build test-fuzz-regression --summary all`
- Future agent note:
  - `#83` is intentionally `Won't Do`. Pre-commit is a fast local subset, not the authoritative merge gate. Keep GitLab CI as the canonical enforcement layer unless repository policy changes.

## Status Table

| Finding | Issue | Status | What changed |
|---------|-------|--------|--------------|
| Recovery loads the full WAL tail into memory | [#46](https://gitlab.com/devnw/zig/graph-storage/-/work_items/46) | Closed | Added streaming WAL iteration in `src/wal.zig` and two-pass bounded replay in `src/recovery.zig`, with a large-tail replay regression test. |
| High-churn core modules remain oversized and multi-responsibility | [#72](https://gitlab.com/devnw/zig/graph-storage/-/work_items/72) | Closed | Extracted shared responsibilities into dedicated modules: `src/index_snapshot.zig`, `src/operation_result.zig`, and `src/testing_support.zig`; moved edge-index persistence into the indexing path; moved WAL-tail streaming responsibility into `src/wal.zig`. |
| Backup creation buffers graph contents in memory | [#76](https://gitlab.com/devnw/zig/graph-storage/-/work_items/76) | Closed | `createBackup()` now streams file contents with bounded chunk buffers and regression coverage for large files. |
| Quality checks are fragmented across local hooks and CI | [#83](https://gitlab.com/devnw/zig/graph-storage/-/work_items/83) | Won't Do | The user explicitly directed that pre-commit parity remain out of scope. CI now documents itself as the authoritative gate; pre-commit remains intentionally lighter weight. |
| Benchmark regression checks are advisory and cannot block drift | [#85](https://gitlab.com/devnw/zig/graph-storage/-/work_items/85) | Closed | `.gitlab-ci.yml` now defines a non-optional `benchmark-regression` job for merge-path pipelines. |
| GitLab CI re-installs Zig in every job | [#86](https://gitlab.com/devnw/zig/graph-storage/-/work_items/86) | Closed | Added `prepare-zig` plus artifact reuse so repository-defined Zig jobs consume one prepared toolchain per pipeline instead of bootstrapping Zig repeatedly. |
| Structured maintenance result schemas remain inconsistent | [#44](https://gitlab.com/devnw/zig/graph-storage/-/work_items/44) | Closed | Added shared `GraphOperationSummary`/`OperationKind` in `src/operation_result.zig`; backup, restore, verify, migration, and maintenance flows now expose structured JSON result types with serialization tests. |
| README drifts from API, dependency, encryption, and toolchain reality | [#56](https://gitlab.com/devnw/zig/graph-storage/-/work_items/56) | Closed | Updated `README.md` and `examples/basic.zig` to match the current API, dependency set, persisted snapshots, AES-256-GCM encryption, and tested Zig versions. |
| Test setup and fixture scaffolding is duplicated across the suite | [#81](https://gitlab.com/devnw/zig/graph-storage/-/work_items/81) | Closed | Added `src/testing_support.zig` and migrated unit/integration tests onto the shared temp-dir and config helpers. |
| `build.zig` duplicates dependency and module wiring across targets | [#82](https://gitlab.com/devnw/zig/graph-storage/-/work_items/82) | Closed | Consolidated dependency loading and module creation through `loadDeps`, `createModule`, and the shared build helper functions in `build.zig`. |
| Benchmark reporting only captures single averages | [#84](https://gitlab.com/devnw/zig/graph-storage/-/work_items/84) | Closed | `benchmarks/scale_bench.zig` now emits `avg`, `p50`, `p95`, `p99`, `stddev`, and sample counts; `benchmarks/compare.zig` compares those fields explicitly. |
| Derived index snapshot persistence is duplicated across two formats | [#87](https://gitlab.com/devnw/zig/graph-storage/-/work_items/87) | Closed | Added `src/index_snapshot.zig` and switched label/property snapshot persistence to the shared framing/parsing helper. |
| Fuzz failures are suppressed and cannot block merges | [#79](https://gitlab.com/devnw/zig/graph-storage/-/work_items/79) | Closed | Added the deterministic `test-fuzz-regression` target and a required `fuzz-regression` CI job; exploratory fuzzing remains advisory but no longer swallows real failures. |

## Notes For Future Agents

- Do not reopen `#83` just because pre-commit and CI are not identical. That divergence is now intentional and documented in `.pre-commit-config.yaml` and `.gitlab-ci.yml`.
- If repository policy changes and full parity is desired later, treat it as a new policy decision rather than a regression in this closure pass.
