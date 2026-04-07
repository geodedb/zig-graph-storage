# Security Review Notes

Last updated: 2026-04-07

## Orientation

- `git rev-parse --show-toplevel` -> `/home/benji/src/devnw/zig/graph-storage`
- `git status --porcelain` at review start showed existing doc changes:
  - `M docs/GAP_ANALYSIS.md`
  - `M docs/GAP_ANALYSIS_RESOLVED.md`
- `git remote -v` -> `origin git@gitlab.com:devnw/zig/graph-storage.git`
- `glab repo view` resolved the project as `Developer Network / Zig Shared Projects / graph-storage`
- `glab auth status` on 2026-04-07 still reports `Invalid token provided`, so GitLab project-setting changes remain blocked from this environment.
- GitLab project settings observed during the review:
  - `visibility: public`
  - `default_branch: main`
  - `ci_separated_caches: True`
  - `only_allow_merge_if_pipeline_succeeds: False`
  - `only_allow_merge_if_all_discussions_are_resolved: False`
  - `approvals_before_merge: 0`

## Threat Model Snapshot

- Assets:
  - graph data on disk
  - backup archives
  - encryption keys used for page and backup protection
  - CI/CD trust for published code and releases
- Trust boundaries:
  - on-disk manifests, WAL segments, and backup files are untrusted once corruption or swap is possible
  - GitLab project settings and imported CI components are outside the repository tree
  - maintenance workflows (`backup`, `restore`, `verify`, `recovery`) are operator-facing and can process attacker-supplied artifacts
- Primary attacker classes:
  - local attacker or faulty operator supplying corrupted/tampered storage artifacts
  - compromised developer or maintainer account in GitLab
  - upstream CI component maintainer compromise or tag-governance failure

## Tool Inventory

| Tool | `command -v` | Version / status |
| --- | --- | --- |
| `glab` | `/usr/bin/glab` | `glab version 1.36.0 (unknown)` |
| `git` | `/usr/bin/git` | `git version 2.53.0` |
| `zig` | `/home/benji/.local/zig-x86_64-linux-0.15.1/zig` | `0.15.1` |
| `python3` | `/usr/bin/python3` | `Python 3.12.3` |
| `gitleaks` | `/home/benji/.local/bin/gitleaks` | installed |
| `trufflehog` | `/home/benji/.local/bin/trufflehog` | `3.92.5` |
| `syft` | `/home/benji/.local/bin/syft` | installed |
| `grype` | `/home/benji/.local/bin/grype` | installed |
| `osv-scanner` | `/home/benji/.local/bin/osv-scanner` | `2.3.2` |
| `trivy` | `/home/benji/.local/bin/trivy` | `0.69.0` |
| `semgrep` | `/home/benji/.local/bin/semgrep` | `1.150.0` |
| `bandit` | `/home/benji/.local/bin/bandit` | `1.9.3` |
| `shellcheck` | `/usr/bin/shellcheck` | installed |
| `hadolint` | `/home/benji/.local/bin/hadolint` | `2.14.0` |
| `checkov` | `/home/benji/.local/bin/checkov` | `3.2.499` |
| `safety` | `/home/benji/.local/bin/safety` | `3.7.0` |
| `cargo` | `/home/benji/.cargo/bin/cargo` | `cargo 1.91.1` |
| `cargo-audit` | `/home/benji/.cargo/bin/cargo-audit` | `0.22.0` |
| `govulncheck` | `/home/benji/go/bin/govulncheck` | installed |
| `npm` | `/usr/bin/npm` | `9.2.0` |
| `snyk` | missing | not installed |
| `pnpm` | missing | not installed |
| `yarn` | missing | not installed |

## Automated Check Results

| Command | Result | Notes | Output |
| --- | --- | --- | --- |
| `gitleaks detect --source . --redact --report-format json --report-path /tmp/gitleaks.json` | non-zero, 1 hit | false positive on `src/encryption.zig:11` (`KEY_SIZE`) | `/tmp/gitleaks.json` |
| `trufflehog --no-update git file://$PWD --json > /tmp/trufflehog.json` | clean | initial run failed due updater self-replacement; rerun with `--no-update`; stderr reported `verified_secrets: 0`, `unverified_secrets: 0` | `/tmp/trufflehog.json` |
| `syft dir:. -o cyclonedx-json=/tmp/sbom.cdx.json` | clean but empty | CycloneDX SBOM contained `0` components for this repo | `/tmp/sbom.cdx.json` |
| `grype sbom:/tmp/sbom.cdx.json -o json > /tmp/grype.json` | clean | `matches: 0` | `/tmp/grype.json` |
| `osv-scanner scan --recursive . --format json > /tmp/osv.json` | skipped by tool | `No package sources found` | `/tmp/osv.json` |
| `trivy fs . --format json -o /tmp/trivy-fs.json` | no actionable results | DB update succeeded; report contained no confirmed findings | `/tmp/trivy-fs.json` |
| `trivy config . --format json -o /tmp/trivy-config.json` | no config files | report said `Detected config files num=0` | `/tmp/trivy-config.json` |
| `SEMGREP_SEND_METRICS=off semgrep scan --config p/default --metrics=off --json -o /tmp/semgrep.json` | clean | `--config auto` could not run with metrics off, so the review used `p/default` | `/tmp/semgrep.json` |
| `bandit -r . -f json -o /tmp/bandit.json` | clean | no Python findings in this Zig repo | `/tmp/bandit.json` |
| `checkov -d . -o json > /tmp/checkov.json` | no failed checks | one benign parse error on `benchmarks/results/516140e.json` | `/tmp/checkov.json` |
| `git ls-files '*.sh' | xargs -r shellcheck -x` | clean | no tracked shell issues | `/tmp/shellcheck.txt` |
| `git ls-files '*Dockerfile*' | xargs -r hadolint` | clean | no tracked Dockerfiles | `/tmp/hadolint.txt` |

Not applicable in this repo layout:

- `safety` / `requirements*.txt`: no Python dependency manifest to audit
- `cargo audit`: no `Cargo.toml`
- `govulncheck`: no `go.mod`
- `npm audit` / `pnpm audit` / `yarn audit`: no Node dependency manifest or lockfile
- `snyk`: tool not installed, so no authenticated Snyk run was possible

## Manual Verification Notes

- Minimal proof-of-behavior for `GAP-0034` was run from `/tmp/poc_validate_backup_without_key.zig`:
  - `zig run --dep lib -Mmain=/tmp/poc_validate_backup_without_key.zig -Mlib=/home/benji/src/devnw/zig/graph-storage/src/root.zig`
  - Output: `validate_without_key=true`
- GitLab issue sync output was captured in `/tmp/security_issue_results.json`
- The review updated or created these security gap work items:
  - `#46`, `#48`, `#73`, `#74`, `#75`, `#76`, `#77`, `#78`, `#79`, `#80`

## Future Agent Notes

- Do not reopen repo-local CI SHA pinning or Docker digest pinning unless the shared GitLab platform control model changes. Those items were explicitly closed as `Won't Do`.
- Do not treat pre-commit / CI mismatch as a regression by itself. Pre-commit is intentionally a fast local subset, while GitLab CI is the authoritative merge gate.
- `GAP-0038` and `GAP-0039` are still external-admin work. They require a valid repo-admin GitLab token plus project-setting changes, not more repository edits.
