# Gap Analysis

Last updated: 2026-06-10

This file is the close-out record for the gap closure passes. It was first
written for the 2026-04-07 pass and updated during the 2026-06-10 Phase 4
tracking sync, which verified a further batch Implemented at HEAD (`eca7466`)
and moved them to `docs/GAP_ANALYSIS_RESOLVED.md`. GitLab issues are the
authoritative source of truth; this file mirrors them.

## Summary

The counts below cover the dispositions recorded in this file. The full set of
resolved/invalidated gap IDs lives in `docs/GAP_ANALYSIS_RESOLVED.md`, and the
live open gaps are tracked in GitLab.

| Status | Count |
| --- | ---: |
| Closed (2026-06-10 verified Implemented) | 6 |
| Closed (2026-04-07 pass) | 7 |
| Blocked | 2 |
| Won't Do | 1 |
| Open (this file) | 0 |

Open requirement/gap IDs in GitLab as of 2026-06-10: `GAP-0002` (#40),
`GAP-0017` (#41), `GAP-0023` (#43), `GAP-0025` (#44), `GAP-0027` (#45),
`GAP-0031` (#47), `GAP-0033` (#49), `GAP-0038` (#77), `GAP-0039` (#78),
`GAP-0043` (#93), `GAP-0044` (#94), `GAP-0048` (#107).

## Future Agent Notes

- Do not reopen `GAP-0048` for repo-local CI component SHA pinning, same-origin
  Zig bootstrap hash pinning, or Docker image digest pinning unless shared
  platform policy changes. Those controls live in the shared CI catalog and
  downstream platform controls, not in this repository.
- GitLab CI is the authoritative merge gate. Local pre-commit hooks are
  intentionally a fast subset and are tracked separately in
  `docs/QUALITY_GAP_ANALYSIS.md`.
- `GAP-0030` (#46) stays closed. Single-engine recovery streams the WAL tail;
  the sharded path still materializes the full per-shard WAL at
  `src/sharded_recovery.zig:53,98` (`eng.wal.readFrom(0, allocator)`). That
  residual is a performance/memory concern tracked by the performance tracker
  as `PERF-0051`, not a correctness regression — do not reopen `GAP-0030` for it.

## 2026-06-10 Phase 4 tracking sync

Verified Implemented at HEAD (`eca7466`); full suite green
(`zig build test` 443/444 with 1 Windows-skip, `test-integration` 14/14,
`test-fuzz-regression` 3/3, 464 total). Closed and moved to
`docs/GAP_ANALYSIS_RESOLVED.md`:

- `GAP-0018` ([#42](https://gitlab.com/devnw/zig/graph-storage/-/work_items/42)) — legacy read-only policy wired through `GraphEngine.open()`.
- `GAP-0032` ([#48](https://gitlab.com/devnw/zig/graph-storage/-/work_items/48)) — restore requires an authoritative expected graph UUID.
- `GAP-0042` ([#92](https://gitlab.com/devnw/zig/graph-storage/-/work_items/92)) — verify validates WAL/auxiliary artifacts, no longer treats missing files as clean.
- `GAP-0045` ([#104](https://gitlab.com/devnw/zig/graph-storage/-/work_items/104)) — recovery fails closed on malformed/checksum-invalid WAL records.
- `GAP-0046` ([#105](https://gitlab.com/devnw/zig/graph-storage/-/work_items/105)) — open/recovery no longer auto-create missing durable artifacts.
- `GAP-0047` ([#106](https://gitlab.com/devnw/zig/graph-storage/-/work_items/106)) — restore rejects CRC-only V1 backups by default.

The detailed dispositions for `GAP-0018`, `GAP-0032`, `GAP-0042`, `GAP-0045`,
`GAP-0046`, and `GAP-0047` recorded under "Disposition" below remain accurate
and are retained for historical continuity.

## Disposition

### GAP-0038: `main` can merge without green pipelines or meaningful approval gates

- Status: Blocked
- Reason: This requires GitLab project-admin settings outside the repo.
- Evidence: The repo-local code and docs cannot enforce
  `only_allow_merge_if_pipeline_succeeds`, discussion resolution, or approvals.
- Unblock:
  1. A GitLab project admin enables green-pipeline-only merges.
  2. A GitLab project admin enables "all discussions resolved".
  3. A GitLab project admin sets non-zero approvals and real CODEOWNERS.

### GAP-0039: protected `main` still allows force pushes

- Status: Blocked
- Reason: This requires GitLab protected-branch settings outside the repo.
- Unblock:
  1. A GitLab project admin edits the protected `main` branch.
  2. Disable force-push for `main` and any protected release branches.

### GAP-0045: recovery skipped malformed or checksum-invalid WAL records

- Status: Closed
- Implemented:
  - `src/wal.zig` adds strict replay classification with `ReplayFailure`.
  - `src/recovery.zig` now fails closed on deserialize or checksum errors and
    records the offending `wal/graph.wal` LSN in `last_failure`.
- Verified by:
  - `zig build test --summary all`
  - `src/recovery.zig` corruption tests now expect `error.ChecksumMismatch` and
    `error.InvalidFormat` instead of skip-and-continue behavior.

### GAP-0042: `verify` omitted WAL / auxiliary artifacts and treated missing files as clean

- Status: Closed
- Implemented:
  - `src/verify.zig` now validates manifests, required store files,
    `labels.idx`, `props.idx`, `edges.idx`, `labels.dict`, `wal/graph.uuid`,
    and `wal/graph.wal`.
  - JSON output now includes per-artifact machine-readable status.
- Verified by:
  - `src/verify.zig` tests covering missing WAL artifacts and structured JSON.

### GAP-0046: open and recovery auto-created missing durable artifacts

- Status: Closed
- Implemented:
  - `src/file_manager.zig` now distinguishes `.open_existing` from
    `.create_if_missing`.
  - `src/config.zig`, `src/engine_persist.zig`, `src/wal.zig`, and
    `src/recovery.zig` now fail closed during steady-state open/recovery unless
    the caller explicitly requested bootstrap creation.
- Verified by:
  - `zig build test --summary all`

### GAP-0032: restore only validated UUID when the target path encoded a UUID

- Status: Closed
- Implemented:
  - `src/backup.zig` now requires an authoritative expected graph UUID via
    `setExpectedGraphUuid(...)` or an already-present `wal/graph.uuid`.
  - Path-string heuristics were removed from restore validation.
- Verified by:
  - `src/backup.zig` test `GAP-0032: restoreBackup rejects a configured expected UUID that mismatches the archive`
  - `zig build test --summary all`

### GAP-0047: restore accepted CRC-only V1 backups without authenticated integrity

- Status: Closed
- Implemented:
  - `src/backup.zig` now rejects legacy V1 restore by default with
    `error.LegacyBackupRestoreDisabled`.
  - Restoring a V1 archive now requires an explicit compatibility opt-in via
    `enableLegacyV1Restore()`.
- Verified by:
  - `src/backup.zig` test `GAP-0047: restoreBackup rejects legacy V1 backups by default`
  - `zig build test --summary all`

### GAP-0048: GitLab CI bootstraps Zig from same-origin hash and binary downloads

- Status: Won't Do
- Reason: Repo-local SHA/digest pinning is intentionally not the control point
  for this repository.
- Documented controls:
  - `.gitlab-ci.yml` documents that CI catalog components intentionally use
    protected release tags governed in the shared catalog.
  - `.gitlab-ci.yml` documents that Docker image digest pinning is handled by
    downstream platform controls.
- Future-agent instruction: do not reopen this gap unless the shared CI catalog
  or platform-control policy changes.

### GAP-0018: legacy read-only compatibility policy was not wired through `GraphEngine.open()`

- Status: Closed
- Implemented:
  - `src/engine.zig` now threads `GraphConfig.legacy_policy` into recovery and
    records engine `read_only` state on open.
  - Mutating engine APIs now call `ensureWritable()` and reject writes when a V1
    graph is opened in compatibility read-only mode.
- Verified by:
  - `src/recovery.zig` and `src/engine.zig` legacy-policy tests
  - `zig build test --summary all`

### QUAL-0034: public docs still described AES-256-CTR

- Status: Closed
- Implemented:
  - `src/root.zig`, `README.md`, `docs/architecture.md`,
    `docs/operations.md`, and `docs/format-spec.md` now describe the runtime as
    AES-256-GCM and reflect the current derived-index topology.
- Verified by:
  - Repo grep for `AES-256-CTR` in public runtime docs now returns only
    historical tracking notes, not live user-facing guidance.
