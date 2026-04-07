# Gap Analysis

Last updated: 2026-04-07

## Summary

| Status | Count |
|--------|-------|
| Closed | 7 |
| Blocked | 2 |
| Won't Do | 1 |

- Verification completed in this closure pass:
  - `zig build`
  - `zig build check`
  - `zig build test --summary all`
  - `zig build test-integration --summary all`
  - `zig build test-fuzz-regression --summary all`
- Future agent note:
  - Repo-local CI component SHA pinning and Docker image digest pinning are intentional non-goals in this repository. They are handled by downstream platform controls and protected catalog release tags.
  - Pre-commit and CI are intentionally not kept in lockstep. Pre-commit remains a fast local subset; GitLab CI is the authoritative merge gate.

## Status Table

| Gap | Issue | Status | Resolution / blocker | Key evidence |
|-----|-------|--------|----------------------|--------------|
| `GAP-0034` version-2 backup validation accepts missing HMAC key | [#73](https://gitlab.com/devnw/zig/graph-storage/-/work_items/73) | Closed | `validateBackup()` now fails closed for HMAC-backed archives when no key is configured. | `src/backup.zig`, test `GAP-0034: validateBackup rejects version 2 backups without the HMAC key` |
| `GAP-0032` graph UUID bindings not enforced across open/verify/restore | [#48](https://gitlab.com/devnw/zig/graph-storage/-/work_items/48) | Closed | UUID mismatch checks now run in recovery, verify, backup restore, and WAL initialization. | `src/recovery.zig`, `src/verify.zig`, `src/backup.zig`, `src/wal.zig` |
| `GAP-0038` merge path lacks green-pipeline / approval gates | [#77](https://gitlab.com/devnw/zig/graph-storage/-/work_items/77) | Blocked | This is a GitLab project setting, not a repo file. The current environment cannot administer project merge rules. | `glab auth status` still reports an invalid token; enabling `only_allow_merge_if_pipeline_succeeds`, discussion resolution, approval rules, and CODEOWNERS enforcement requires repo-admin access in GitLab |
| `GAP-0039` protected `main` allows force pushes | [#78](https://gitlab.com/devnw/zig/graph-storage/-/work_items/78) | Blocked | This is a protected-branch setting outside the repository tree. | Disable force push for `main` in GitLab project settings once repo-admin credentials are available |
| `GAP-0035` `free.store` metadata can allocate unbounded bitmap memory | [#74](https://gitlab.com/devnw/zig/graph-storage/-/work_items/74) | Closed | Free-space loading now validates persisted counts against bounded page totals before resizing the bitmap. | `src/free_space.zig`, `src/engine_persist.zig`, new bounded-deserialize tests |
| `GAP-0030` recovery materializes the full WAL tail in memory | [#46](https://gitlab.com/devnw/zig/graph-storage/-/work_items/46) | Closed | Recovery now streams WAL records via `WalManager.forEachFrom()` and replays them in bounded passes. | `src/wal.zig`, `src/recovery.zig`, large-tail recovery regression test |
| `GAP-0036` page encryption can reuse nonces after `u24` counter exhaustion | [#75](https://gitlab.com/devnw/zig/graph-storage/-/work_items/75) | Closed | Pager writes now fail with `error.WriteCountExhausted` before nonce reuse can occur. | `src/pager.zig`, write-count exhaustion test |
| `GAP-0037` backup creation buffers whole graph contents in memory | [#76](https://gitlab.com/devnw/zig/graph-storage/-/work_items/76) | Closed | Backup creation now streams file payloads in chunks instead of materializing full file bodies in memory. | `src/backup.zig`, large-file streaming regression test |
| `GAP-0040` fuzz failures are suppressed and cannot gate merges | [#79](https://gitlab.com/devnw/zig/graph-storage/-/work_items/79) | Closed | Added deterministic `test-fuzz-regression` coverage in `build.zig` and a non-optional `fuzz-regression` CI job; exploratory fuzzing remains advisory without swallowing failures. | `build.zig`, `tests/fuzz_regression.zig`, `.gitlab-ci.yml` |
| `GAP-0041` CI catalog components use tags instead of immutable SHAs | [#80](https://gitlab.com/devnw/zig/graph-storage/-/work_items/80) | Won't Do | The user explicitly directed that repo-local CI SHA pinning stay out of scope. Shared catalog tag immutability and review controls live upstream. Future agents should not reopen this unless platform policy changes. | `.gitlab-ci.yml` header note, `docs/SECURITY_REVIEW_NOTES.md` |

## Blocker Details

### `GAP-0038`

- Required unblock:
  - authenticate `glab` with a repo-admin token
  - enable merge-only-if-pipeline-succeeds
  - enable merge-only-if-all-discussions-are-resolved
  - configure approval rules and required CODEOWNERS coverage

### `GAP-0039`

- Required unblock:
  - authenticate `glab` with a repo-admin token
  - update the protected `main` branch to set `allow_force_push = false`
