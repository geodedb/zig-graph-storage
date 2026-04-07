# Security Review Notes

Last updated: 2026-04-07

## Orientation

- `git rev-parse --show-toplevel` -> `/home/benji/src/devnw/zig/graph-storage`
- `git status --porcelain` at review start showed pre-existing doc edits:
  - `M docs/GAP_ANALYSIS.md`
  - `M docs/GAP_ANALYSIS_RESOLVED.md`
  - `M docs/PERF_GAP_ANALYSIS.md`
  - `M docs/QUALITY_GAP_ANALYSIS.md`
- `git remote -v` -> `origin git@gitlab.com:devnw/zig/graph-storage.git`
- `glab repo view` resolved the project as `Developer Network / Zig Shared Projects / graph-storage`
- Repo map highlights:
  - primary code under `src/`
  - build metadata in `build.zig` and `build.zig.zon`
  - GitLab pipeline in `.gitlab-ci.yml`
  - no Dockerfiles, Terraform, Helm, Kubernetes manifests, or shell-heavy deployment scripts in the tracked tree

## Threat Model Snapshot

- Assets:
  - graph data, manifests, store files, WAL segments, backups
  - page-encryption keys and backup-integrity keys
  - CI/CD trust for builds, scans, and releases
- Trust boundaries:
  - on-disk graph artifacts are untrusted once corruption, tampering, or wrong-graph restores are possible
  - backup archives are operator-facing inputs and may traverse shared storage
  - GitLab project settings and imported CI behavior sit outside the repo tree
- Primary attacker classes:
  - local attacker or faulty operator supplying corrupted/tampered storage artifacts
  - compromised maintainer account changing GitLab governance or branch history
  - supply-chain attacker targeting CI toolchain bootstrap or release inputs

## Tool Inventory

| Tool | `command -v` | Version / status |
| --- | --- | --- |
| `glab` | `/usr/bin/glab` | `glab version 1.36.0` |
| `git` | `/usr/bin/git` | `git version 2.53.0` |
| `zig` | `/home/benji/.local/bin/zig` | `0.15.1` |
| `python3` | `/usr/bin/python3` | `Python 3.12.3` |
| `gitleaks` | `/usr/bin/gitleaks` | installed |
| `trufflehog` | `/usr/local/bin/trufflehog` | `3.92.5` |
| `syft` | `/usr/bin/syft` | `1.41.1` |
| `grype` | `/usr/bin/grype` | `0.107.0` |
| `osv-scanner` | `/usr/bin/osv-scanner` | `2.3.2` |
| `trivy` | `/usr/bin/trivy` | `0.69.0` |
| `semgrep` | `/usr/bin/semgrep` | `1.150.0` |
| `bandit` | `/usr/bin/bandit` | `1.9.3` |
| `shellcheck` | `/usr/bin/shellcheck` | installed |
| `hadolint` | `/usr/bin/hadolint` | `2.14.0` |
| `checkov` | `/usr/bin/checkov` | `3.2.499` |
| `safety` | `/usr/bin/safety` | `3.7.0` |
| `cargo` | `/usr/bin/cargo` | `cargo 1.91.1` |
| `cargo-audit` | `/usr/bin/cargo-audit` | `0.22.0` |
| `govulncheck` | `/home/benji/go/bin/govulncheck` | installed |
| `npm` | `/usr/bin/npm` | `9.2.0` |
| `snyk` | missing | not installed |
| `pnpm` | missing | not installed |
| `yarn` | missing | not installed |

All scan outputs were written under `/tmp/security-review-20260407/`.

## Automated Check Results

| Command | Result | Notes | Output |
| --- | --- | --- | --- |
| `gitleaks detect --source . --redact --report-format json --report-path /tmp/security-review-20260407/gitleaks.json` | false positive | one hit on `src/encryption.zig:11` (`KEY_SIZE = ...`), not a secret | `/tmp/security-review-20260407/gitleaks.json` |
| `trufflehog git file://$PWD --no-update --json > /tmp/security-review-20260407/trufflehog.json` | false positive | one unverified detector hit on `docs/QUALITY_GAP_ANALYSIS.md` text near `benchmark-regressionhttps://gitlab.com`; not a token | `/tmp/security-review-20260407/trufflehog.json` |
| `syft dir:. -o cyclonedx-json=/tmp/security-review-20260407/sbom.cdx.json` | clean but empty | no package components were identified in this repo layout | `/tmp/security-review-20260407/sbom.cdx.json` |
| `grype sbom:/tmp/security-review-20260407/sbom.cdx.json -o json > /tmp/security-review-20260407/grype.json` | clean | `matches: 0` | `/tmp/security-review-20260407/grype.json` |
| `osv-scanner scan --recursive . --format json > /tmp/security-review-20260407/osv.json` | not applicable | stderr: `No package sources found` | `/tmp/security-review-20260407/osv.json`, `/tmp/security-review-20260407/osv.stderr` |
| `trivy fs . --format json -o /tmp/security-review-20260407/trivy-fs.json` | clean | no actionable filesystem findings | `/tmp/security-review-20260407/trivy-fs.json` |
| `trivy config . --format json -o /tmp/security-review-20260407/trivy-config.json` | clean / none found | repo contains no supported IaC config set for this scan | `/tmp/security-review-20260407/trivy-config.json` |
| `SEMGREP_SEND_METRICS=off semgrep scan --config auto --metrics=off --json ...` | blocked by tool behavior | stderr: `Cannot create auto config when metrics are off`; reran with `--config p/default` | `/tmp/security-review-20260407/semgrep.stderr` |
| `SEMGREP_SEND_METRICS=off semgrep scan --config p/default --metrics=off --json -o /tmp/security-review-20260407/semgrep-pdefault.json .` | clean | `results: 0` | `/tmp/security-review-20260407/semgrep-pdefault.json` |
| `bandit -r . -f json -o /tmp/security-review-20260407/bandit.json` | clean | no Python findings in this Zig repo | `/tmp/security-review-20260407/bandit.json` |
| `checkov -d . -o json > /tmp/security-review-20260407/checkov.json` | clean | no failed checks; JSON output was a two-entry result array | `/tmp/security-review-20260407/checkov.json` |
| `git ls-files '*.sh' | xargs -r shellcheck -x` | clean | no tracked shell issues | `/tmp/security-review-20260407/shellcheck.txt` |
| `git ls-files '*Dockerfile*' | xargs -r hadolint` | clean | repo has no tracked Dockerfiles | `/tmp/security-review-20260407/hadolint.txt` |

Not applicable in this repo layout:

- `safety`: no Python dependency manifest
- `cargo audit`: no `Cargo.toml`
- `govulncheck`: no `go.mod`
- `npm audit`, `pnpm audit`, `yarn audit`: no Node dependency manifest or lockfile
- `snyk`: tool not installed

## Manual Verification Highlights

- GitLab governance was verified directly with `glab api`:
  - `glab api "projects/devnw%2Fzig%2Fgraph-storage" | jq '{visibility,default_branch,only_allow_merge_if_pipeline_succeeds,only_allow_merge_if_all_discussions_are_resolved}'`
  - Output: `{"visibility":"public","default_branch":"main","only_allow_merge_if_pipeline_succeeds":false,"only_allow_merge_if_all_discussions_are_resolved":false}`
  - `glab api "projects/devnw%2Fzig%2Fgraph-storage/approvals" | jq '{approvals_before_merge,reset_approvals_on_push}'`
  - Output: `{"approvals_before_merge":0,"reset_approvals_on_push":true}`
  - `glab api "projects/devnw%2Fzig%2Fgraph-storage/protected_branches?per_page=100" | jq -r '.[] | [.name, (.allow_force_push|tostring)] | @tsv'`
  - Output included `main	true`
- Verified code-level fail-open recovery behavior:
  - `src/wal.zig:107-145` drops deserialize failures with `catch continue`
  - `src/recovery.zig:169-183` skips checksum-invalid WAL records
  - `src/recovery.zig:624-710` tests the skip behavior explicitly
- Verified code-level fail-open startup behavior:
  - `src/file_manager.zig:47-65` creates missing primary store files during open
  - `src/recovery.zig:145-155` recreates `wal/`
  - `src/wal.zig:167-177` recreates `wal/graph.uuid`
- Verified restore identity/authentication gaps:
  - `src/backup.zig:289-293` validates UUID only when the destination path encodes a UUID
  - `src/backup.zig:141`, `src/backup.zig:259-277`, and `src/backup.zig:382-396` still accept CRC-only version-1 backups without HMAC
- Verified docs/security drift:
  - `src/root.zig:24-25`, `docs/architecture.md:409-413`, and `docs/operations.md:128-130` still say AES-256-CTR
  - `src/encryption.zig:7-11` implements AES-256-GCM

## GitLab Issue Sync

- Existing issues updated or refreshed:
  - [#92](https://gitlab.com/devnw/zig/graph-storage/-/work_items/92)
  - [#48](https://gitlab.com/devnw/zig/graph-storage/-/work_items/48) (reopened)
  - [#42](https://gitlab.com/devnw/zig/graph-storage/-/work_items/42)
  - [#56](https://gitlab.com/devnw/zig/graph-storage/-/work_items/56)
- New issues created:
  - [#104](https://gitlab.com/devnw/zig/graph-storage/-/work_items/104)
  - [#105](https://gitlab.com/devnw/zig/graph-storage/-/work_items/105)
  - [#106](https://gitlab.com/devnw/zig/graph-storage/-/work_items/106)
  - [#107](https://gitlab.com/devnw/zig/graph-storage/-/work_items/107)
