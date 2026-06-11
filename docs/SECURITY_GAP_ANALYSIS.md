# Security Gap Analysis

**Last updated:** 2026-06-10 (closure sync -- SEC-0037..SEC-0052 all IMPLEMENTED, verified, and CLOSED on branch audit-remediation-2026-06-10; Phase 4b appsec pass SEC-0047..SEC-0052; prior Phase 4 SEC-0037..SEC-0046)
**Source:** AppSec Review (docs/APPSEC_REVIEW_2026-06-10.md), Full Codebase Audit (docs/AUDIT_REPORT.md), Phase 4/4b review

## Summary

| Status | Count |
|--------|-------|
| Open | 0 |
| Closed | 51 |
| Won't Do | 1 |
| Blocked | 0 |
| Deferred | 0 |

**Open by severity:** none. All 16 findings from the 2026-06-10 audit (SEC-0037..SEC-0052) were implemented and verified (full suite green in Debug + ReleaseSafe) on branch `audit-remediation-2026-06-10`; an independent adversarial security review confirmed the fixes correct, and the residuals it surfaced were also fixed. See the **Resolved / Closed (2026-06-10 closure)** section below for per-finding fix commits and evidence.

**Resolved this pass (severity at time of finding):** Critical 1 (SEC-0037) · High 5 (SEC-0038, SEC-0039, SEC-0040, SEC-0041, SEC-0047) · Medium 5 (SEC-0042, SEC-0043, SEC-0044, SEC-0048, SEC-0049) · Low 4 (SEC-0045, SEC-0046, SEC-0050, SEC-0051) · Info 1 (SEC-0052).

**Residual risk:** None open. The 2026-06-10 tracking pass had reopened the cryptographic and storage-integrity attack surface against the embedded-library threat model (attacker with filesystem write access to the data directory, malicious backup archives, supply chain). The headline finding (SEC-0037) was a live AES-GCM nonce-reuse bug that occurred during normal checkpoint cycling; it is now fixed (write_count write-back on flush + recovery seed, commit 326d544). SEC-0045 (regression of the per-pager portion of SEC-0030) is fixed. The Phase 4b appsec findings (SEC-0047..SEC-0052) on the secondary on-disk loaders -- JSON shard manifest, derived-index `.idx` snapshots, `labels.dict`, backup-restore symlink handling -- are all fixed: every loader now follows "validate-before-allocate, verify-before-materialize." The adversarial review additionally found and fixed three residuals (SEC-0049 intermediate-symlink, SEC-0038 verify/extract TOCTOU, SEC-0043 verify-path key gap); see "Residual review notes" below.

### Top 5 Risks (all RESOLVED 2026-06-10)

1. **SEC-0037 (Critical, 100)** -- RESOLVED (326d544). AES-GCM nonce reuse via stale in-memory `write_count` on cached frames; same nonce reused across checkpoints -> plaintext-XOR recovery + GHASH key recovery + tag forgery. Triggered without an attacker. Fixed by write_count write-back on flush + recovery seed.
2. **SEC-0038 (High, 64)** -- RESOLVED (821df37 + 587feac). Backup restore extracted attacker-controlled file contents before CRC/HMAC verification; poisoned store files in place despite failing HMAC, with no cleanup. Fixed by verify-before-extract + tamper-evident re-verify during extract.
3. **SEC-0039 (High, 64)** -- RESOLVED (3e4d0b9). prop_store `dir_count` read from disk unvalidated; offset underflow -> panic (ReleaseSafe) / OOB read (ReleaseFast). Fixed by bound check before use.
4. **SEC-0040 (High, 64)** -- RESOLVED (6021bee). var_store `data_len` used as a slice bound without capacity check -> OOB read / info disclosure. Fixed by `data_len > dataCapacity()` rejection.
5. **SEC-0041 (High, 64)** -- RESOLVED (2a602fa). 2PC recovery replayed unauthenticated WAL records (`readFrom` never verified checksum); forged prepare+commit forged cross-shard edges during recovery. Fixed by strict checksum streaming.

### Immediate Actions (status)

- **SEC-0037:** RESOLVED (326d544). Recommended operational follow-up still stands for any data encrypted by an affected pre-fix build: rotate the master encryption key and re-encrypt at-rest data, and treat any captured same-page ciphertext pairs from a pre-fix build as exposed.
- **SEC-0038:** RESOLVED (821df37 + 587feac). Restore is now verify-before-extract; a tampered archive leaves the target byte-for-byte unchanged.
- **SEC-0046:** RESOLVED (8518e2d). `package.json`/`package-lock.json` removed and gitignored; root is clean of unaudited npm artifacts.
- **SEC-0047:** RESOLVED (f70babb). Shard manifest now typed-parsed with tag+range guards; malformed `shard_manifest.json` returns a clean error under ReleaseSafe (no DoS/UB) before integrity gates. No secret rotation required.
- **SEC-0049:** RESOLVED (821df37 + 587feac). Restore now uses per-component `O_NOFOLLOW` (the real defense, as `resolve_beneath` is a Linux no-op in this stdlib version) so a planted symlink at a legal filename is not followed; compounding with SEC-0038's verify-before-extract.

### Documented Informational Notes (no issue)

- **wal-0.1.4 random-nonce AES-GCM:** The vendored `wal-0.1.4` uses random CSPRNG nonces (birthday bound ~2^32, documented). This is sound and is NOT a SEC-0015-class deterministic-counter reuse. No issue.
- **No key-rotation enforcement:** Defense-in-depth note; the engine does not enforce periodic key rotation. No issue this pass.
- **Retraction -- interface.zig:737-764:** The "vtable undefined" pattern is a test-only Mock, not a product defect. No issue.
- **Retraction -- buffer_pool.zig:375:** `flushChunkFn(c, undefined)` -- the `undefined` argument is explicitly ignored by the callee; safe. No issue.
- **Re-verified fixed:** SEC-0002, SEC-0007, SEC-0013, SEC-0015 confirmed still fixed.
- **FIND-CI-1 (catalog tag pinning):** Maps to existing GAP-0041 "Won't Do" policy. Note only; not a SEC issue.
- **FIND-CI-2 (Zig toolchain TOFU):** Maps to existing GAP-0048 / #107. Do not duplicate.
- **otel/wal ref-vs-version label mismatch in build.zig.zon:** Left for the quality tracker; out of SECURITY scope.

### Stack-Ranked Findings

#### Resolved / Closed (2026-06-10 closure)

All 16 implemented and verified on branch `audit-remediation-2026-06-10` (full suite green in Debug + ReleaseSafe); adversarial review confirmed correct. GitLab issues closed 2026-06-10.

| Rank | Severity | Risk Score | Finding | Component | CWE/OWASP | Evidence (file:line) | Issue | Fix Commit(s) | Status |
|------|----------|------------|---------|-----------|------------|----------------------|-------|---------------|--------|
| 1 | Critical | 100 | SEC-0037: AES-GCM nonce reuse via stale in-memory write_count | buffer_pool.zig, pager.zig, recovery.zig | CWE-323 / A02:2021 | buffer_pool.zig:446-451,322-323,590-594; pager.zig:81-85; recovery.zig:221 | #115 (confidential) | 326d544 (write_count write-back on flush + recovery seed) | Closed |
| 2 | High | 64 | SEC-0038: Backup restore parse-then-verify (extract before CRC/HMAC) | backup.zig | CWE-345 / A08:2021 | backup.zig:251,291-320,314,316,327,336-338 | #117 (confidential) | 821df37 + 587feac (verify-before-extract + tamper-evident re-verify during extract) | Closed |
| 3 | High | 64 | SEC-0039: prop_store dir_count unchecked from disk | prop_store.zig | CWE-191,CWE-125 / A03:2021 | prop_store.zig:160,66-72 | #128 | 3e4d0b9 (dir_count bound check) | Closed |
| 4 | High | 64 | SEC-0040: var_store data_len unbounded before slice | var_store.zig | CWE-125 / A03:2021 | var_store.zig:118-123,44 | #129 | 6021bee (reject data_len > dataCapacity()) | Closed |
| 5 | High | 64 | SEC-0041: 2PC recovery trusts unauthenticated WAL records | sharded_recovery.zig, wal.zig | CWE-345 / A08:2021 | sharded_recovery.zig:53,98,128; wal.zig:106-133 | #118 (confidential) | 2a602fa (strict checksum streaming) | Closed |
| 6 | High | 64 | SEC-0047: Unchecked std.json.Value union access in shard manifest parse (panic/UB) | shard_manifest.zig, sharded_engine.zig | CWE-843,CWE-754,CWE-704 / A10:2021,A08:2021 | shard_manifest.zig:90-117; sharded_engine.zig:168 | #140 (confidential) | f70babb (typed parse + tag/range guards) | Closed |
| 7 | Medium | 48 | SEC-0042: adj_store + prop_store iterator traversals lack hop/cycle guard | adj_store.zig, prop_store.zig | CWE-835 / A05:2021 | adj_store.zig:120-146,163-195,214-238,248-258,273-279; prop_store.zig:249-250 | #130 | 569c621 (MAX_CHAIN_HOPS + CircularChainDetected) | Closed |
| 8 | Medium | 48 | SEC-0044: label_index snapshot OOM (node_count before bounds) | label_index.zig | CWE-789 / A05:2021 | label_index.zig:204-211 | #133 | 50d7294 (node_count*8 <= remaining bound) | Closed |
| 9 | Medium | 48 | SEC-0048: Unbounded ensureTotalCapacity from untrusted snapshot counts (edge + prop-chain) | engine_index.zig, property_chain_index.zig, index_snapshot.zig | CWE-789,CWE-1284 / A10:2021,A08:2021 | engine_index.zig:241; property_chain_index.zig:222-229; index_snapshot.zig:85-89 | #142 | 50d7294 + d9272eb (u32 cast clamp; bound by payload/min-record) | Closed |
| 10 | Medium | 48 | SEC-0049: Backup restore follows symlinks (no resolve_beneath/exclusive) | backup.zig | CWE-59,CWE-22 / A08:2021,A01:2021 | backup.zig:306-316,559-580,291-339 | #141 (confidential) | 821df37 + 587feac (per-component O_NOFOLLOW; resolve_beneath is a Linux no-op) | Closed |
| 11 | Medium | 36 | SEC-0043: Manifest CRC32-only under TDE | manifest.zig | CWE-345,CWE-353 / A08:2021 | manifest.zig:76-95 | #132 | 194c6ef (HMAC) + d9272eb (verify-path key threading) | Closed |
| 12 | Low | 24 | SEC-0046: Untracked npm package.json/lock in repo root, not gitignored | repo root, .gitignore | CWE-1104 / A06:2021 | package.json, package-lock.json (untracked); .gitignore | #135 | 8518e2d (removed + gitignored) | Closed |
| 13 | Low | 24 | SEC-0050: labels.dict dup-key aliasing (leak / potential double-free) + verify-after-materialize | label_dict.zig | CWE-415,CWE-401,CWE-345 / A08:2021,A10:2021 | label_dict.zig:123-147,23-31,151 | #143 | 4b8414f (reject dup names/ids; verify CRC before commit) | Closed |
| 14 | Low | 16 | SEC-0045: Pager key copies not securely wiped (SEC-0030 regression) | file_manager.zig | CWE-316 / A02:2021 | file_manager.zig:106-119,78-79 | #134 | a0811ce (iterate pagers, PageEncryption.deinit before nulling) | Closed |
| 15 | Low | 16 | SEC-0051: Derived-index .idx snapshots have no checksum/HMAC | index_snapshot.zig, engine_index.zig | CWE-353 / A08:2021 | index_snapshot.zig:30-90; engine_index.zig:162 | #144 | 50d7294 (CRC32), preserved through afa4b5e buffered rewrite | Closed |
| 16 | Info | 4 | SEC-0052: Creation paths omit resolve_beneath/exclusive (defense-in-depth) | graph_dir.zig, file_manager.zig, manifest.zig, registry.zig, label_dict.zig | CWE-59 / A02:2021 | graph_dir.zig:39; file_manager.zig:67; manifest.zig:150; registry.zig:117; label_dict.zig:94 | #145 | a0811ce (create-path hardening) | Closed |

##### Residual review notes (low/info, addressed)

The independent adversarial security review of the 2026-06-10 remediation found three residual gaps in the initial fixes; all were fixed and re-verified:

- **SEC-0049 intermediate-symlink:** the first symlink defense covered the final filename component but not interior path components. The final fix applies per-component `O_NOFOLLOW` across the whole relative path. (`resolve_beneath` is a Linux no-op in this Zig stdlib version, so per-component no-follow is the real defense.) — 821df37 + 587feac.
- **SEC-0038 verify/extract TOCTOU:** an attacker could swap the archive between the verify pass and the extract pass. The final fix re-verifies tamper-evidently during extraction, so a between-passes swap is detected. — 821df37 + 587feac.
- **SEC-0043 verify-path key gap:** the initial HMAC manifest change did not thread the TDE key into the verification routine, so the HMAC was not actually checked on the verify path. d9272eb threads the key through the verify path and closes the gap. — 194c6ef + d9272eb.

#### Closed / Prior Passes

| Rank | Severity | Risk Score | Finding | Component | CWE/OWASP | Evidence | Fix | Status |
|------|----------|------------|---------|-----------|------------|----------|-----|--------|
| 1 | Critical | 100 | SEC-0015: AES-GCM nonce reuse | pager.zig | CWE-323 / A02:2021 | pager.zig:52,79 | write_count persisted in PageHeader | Closed |
| 2 | High | 80 | SEC-0016: HMAC timing side channel | backup.zig | CWE-208 / A02:2021 | backup.zig:223,320 | timing_safe.eql | Closed |
| 3 | High | 80 | SEC-0017: HMAC bypass on V2 restore | backup.zig | CWE-345 / A07:2021 | backup.zig:226-229 | error.EncryptionKeyRequired | Closed |
| 4 | High | 80 | SEC-0018: PropStore unbounded key_len | prop_store.zig | CWE-125 / A03:2021 | prop_store.zig:69-72,127-130,206-210,330-331,380-381 | DataCorruption bounds checks | Closed |
| 5 | High | 64 | SEC-0019: @intCast on stat.size | engine.zig, label_index.zig, property_chain_index.zig | CWE-681 / A03:2021 | engine.zig:347, label_index.zig:170, property_chain_index.zig:167 | std.math.cast at all 3 sites | Closed |
| 6 | Medium | 48 | SEC-0020: AdjStore trusts bh.count | adj_store.zig | CWE-125 / A03:2021 | adj_store.zig:172-174 | count validation added | Closed |
| 7 | Medium | 48 | SEC-0021: Index catalog no integrity check | index_catalog.zig | CWE-354 / A08:2021 | index_catalog.zig:94-181 | magic+version+CRC32 added | Closed |
| 8 | Medium | 48 | SEC-0022: Free space unbounded total_pages | free_space.zig | CWE-400 / A05:2021 | free_space.zig:172-181 | bounded deserialization tied to persisted page-count limits | Closed |
| 9 | Medium | 48 | SEC-0032: VarStore.read infinite loop on circular page chain | var_store.zig | CWE-835 / A05:2021 | var_store.zig:107-124 | Cycle detection with max-hop limit | Closed |
| 10 | Medium | 48 | SEC-0033: prop_store chain traversals have no cycle detection | prop_store.zig | CWE-835 / A05:2021 | prop_store.zig:117,317,401,485 | Cycle detection at all 4 traversal sites | Closed |
| 11 | Medium | 36 | SEC-0023: Encryption key not zeroed in Recovery/Backup | recovery.zig, backup.zig | CWE-316 / A02:2021 | recovery.zig:43, backup.zig:66 | Recovery.deinit with secureZero | Closed |
| 12 | Medium | 36 | SEC-0024: WAL payload_len controls allocation | wal_record.zig | CWE-400 / A05:2021 | wal_record.zig:138-143 | MAX_WAL_PAYLOAD cap | Closed |
| 13 | Medium | 36 | SEC-0025: PropStore encodedSizeFromBytes trusts length fields | prop_store.zig | CWE-125 / A03:2021 | prop_store.zig:400-412 | bounds validation added | Closed |
| 14 | Medium | 36 | SEC-0026: Silent prop_head truncation | engine.zig | CWE-681 / A03:2021 | engine.zig:1015 | std.math.cast | Closed |
| 15 | Medium | 36 | SEC-0027: Registry graph_count @intCast | registry.zig | CWE-681 / A03:2021 | registry.zig:153 | std.math.cast | Closed |
| 16 | Medium | 36 | SEC-0028: catch unreachable on WAL serialization | wal.zig | CWE-248 / A11:2021 | wal.zig:74,80 | error propagation | Closed |
| 17 | Medium | 36 | SEC-0029: Backup struct missing deinit - key not zeroed | backup.zig | CWE-316 / A02:2021 | backup.zig:75-88 | Added Backup.deinit with secureZero | Closed |
| 18 | Medium | 36 | SEC-0030: FileManager.deinit does not zero encryption key | file_manager.zig | CWE-316 / A02:2021 | file_manager.zig:32,98-107 | secureZero key + PageEncryption.deinit called | Closed |
| 19 | Medium | 36 | SEC-0031: unreachable in putProperty reachable with corrupt chain | prop_store.zig | CWE-617 / A05:2021 | prop_store.zig:476 | Replaced unreachable with error.DataCorruption | Closed |
| 20 | Low | 16 | SEC-0034: Recovery.deinit not called in engine.open | engine.zig | CWE-316 / A02:2021 | engine.zig:194-195 | Added defer recovery.deinit() | Closed |
| 21 | Low | 16 | SEC-0035: Property key length not validated at API boundary | prop_store.zig | CWE-681 / A03:2021 | prop_store.zig:549 | Guard key.len > maxInt(u16) added | Closed |
| 22 | Low | 16 | SEC-0036: Backup restore creates directory without mode restriction | backup.zig | CWE-276 / A05:2021 | backup.zig:256 | chmod 0o700 after makePath | Closed |

### Roadmap

All roadmap items below were COMPLETED on branch `audit-remediation-2026-06-10` (2026-06-10). Retained for historical traceability; each line carries its fix commit.

**Quick wins (< 1 day each) -- DONE:**

- SEC-0040 -- add `data_len <= dataCapacity()` check in `VarStore.read`. DONE (6021bee).
- SEC-0039 -- add `dir_count` bound check (mirror `readEntryCountChecked`). DONE (3e4d0b9).
- SEC-0044 -- validate `node_count*8 <= remaining` before `ensureTotalCapacity`. DONE (50d7294).
- SEC-0048 -- bound `item_count`/`entry_count` by `payload_size/min_record_size` before `ensureTotalCapacity` at `engine_index.zig:241`, `property_chain_index.zig:229`, and `loadHeader`; back-port to SEC-0044. DONE (50d7294 + d9272eb).
- SEC-0045 -- iterate pagers and call `PageEncryption.deinit()` in `FileManager.deinit` (restores SEC-0030). DONE (a0811ce).
- SEC-0046 -- remove or gitignore `package.json`/`package-lock.json`/`node_modules`. DONE (8518e2d).
- SEC-0050 -- reject duplicate names/ids in `label_dict.loadFromFile` (`error.InvalidData`, free `owned`); verify CRC before committing the maps. DONE (4b8414f).

**Medium (1-5 days each) -- DONE:**

- SEC-0047 -- replace unchecked `std.json.Value` accesses in `shard_manifest.readFromDir` with typed `parseFromSlice` or per-field tag/range guards; add malformed-JSON regression tests run under `ReleaseSafe`. DONE (f70babb).
- SEC-0042 -- shared `MAX_CHAIN_HOPS` helper across adj_store traversals + `PropIterator.next`. DONE (569c621).
- SEC-0041 -- route 2PC reconciliation reads through checksum-verified WAL reads. DONE (2a602fa).
- SEC-0038 -- restructure backup restore to verify-then-extract with cleanup. DONE (821df37 + 587feac; final form re-verifies tamper-evidently during extract).
- SEC-0049 -- extract restores safely; per-component `O_NOFOLLOW` on extraction `createFile` (coordinate with SEC-0038). DONE (821df37 + 587feac; `resolve_beneath` is a Linux no-op so per-component no-follow is the real defense).
- SEC-0051 -- add CRC32 (or HMAC under TDE) over `.idx` snapshot payload; verify on load -> rebuild on mismatch (also cheaply enables SEC-0048 bound check). DONE (50d7294; preserved through afa4b5e buffered rewrite).
- SEC-0052 -- apply held-`Dir`-handle creation / no-follow on create across `graph_dir`/`file_manager`/`manifest`/`registry`/`label_dict` (consistency follow-up to SEC-0049). DONE (a0811ce).

**Strategic (> 5 days) -- DONE:**

- SEC-0037 -- per-`(file_id, page_id)` write_count that survives WAL replay and is advanced on the live frame; key-rotation/re-encryption guidance for already-exposed data. DONE (326d544; write_count write-back on flush + recovery seed).
- SEC-0043 -- HMAC-SHA256 manifest format (versioned) when a TDE key is configured. DONE (194c6ef + d9272eb verify-path key threading).

**Process follow-up:** add a fuzz target per untrusted on-disk artifact (shard manifest, each `.idx`, `labels.dict`, registry, free.store) to `fuzz_regression.zig`; gate CI to run the parser fuzz corpus under `ReleaseSafe` so future loaders inherit "validate-before-allocate, verify-before-materialize." (Carried forward as defense-in-depth process work; not gating any open SEC finding.)

---

---

## SEC-0037: AES-GCM nonce reuse via stale in-memory write_count on cached frames

- **Status:** Closed / Implemented (2026-06-10)
- **Severity:** Critical
- **Risk Score:** 100 (Impact 5 x Likelihood 5 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-323 (Reusing a Nonce, Key Pair in Encryption)
- **OWASP:** A02:2021 Cryptographic Failures
- **Issue:** #115 (confidential)
- **Exploit Surface:** Read access to encrypted storage files; also occurs without any attacker under normal checkpoint cycling
- **Summary:** Flush paths copy the cached frame into a transient buffer and advance the AES-GCM `write_count` only in that copy; the live cached frame's `write_count` is never advanced. A hot page flushed across multiple checkpoints reuses the same nonce `(page_id || file_id || write_count)` with different plaintexts.
- **Evidence:** `buffer_pool.zig:446-451` (sequential flushFrame copies frame to local buf), `buffer_pool.zig:322-323`+`590-594` (parallel batch copies to data_buf), `pager.zig:81-85` (new_wc derived from the buffer being written, not the frame), `recovery.zig:221` (pinNew + WAL-payload memcpy carrying pre-flush wc -> wc regression), `pager.zig:304-334` (SEC-0015 test masks the bug by manually poking writeWriteCount).
- **Attack Scenario:** Same hot page flushed at checkpoints N and N+1 both encrypt under `write_count = 1`; attacker with read access recovers P1 XOR P2, then GHASH key, then forges authenticated pages.
- **Distinction:** Distinct from GAP-0036/#75 (u24 counter saturation) and SEC-0015 (write_count hardcoded to 0). This is a liveness bug -- the counter is advanced on the wrong buffer.
- **Fix Guidance:** Advance write_count in the live frame on flush, or maintain a per-(file,page) monotonic counter independent of frame contents; seed recovery's counter from `max(on-disk wc, wal wc)+1` so replay cannot regress it.
- **Acceptance Criteria:** (1) Test flushing the same cached frame twice (no manual poke) asserts distinct nonces. (2) Recovery replay test asserts post-replay flush write_count is strictly monotonic. (3) SEC-0015 test passes without manual write_count poke. (4) Plaintext path unaffected.
- **SLA:** 7 days (Critical)
- **Immediate Action:** Rotate the master key and re-encrypt at-rest data after the fix; treat captured same-page ciphertext pairs as exposed.
- **Resolution:** write_count is now written back to the live cached frame on flush (sequential and parallel batch paths), and recovery seeds the per-(file,page) counter from `max(on-disk wc, wal wc)+1` so replay cannot regress the nonce. Same hot page flushed across consecutive checkpoints now produces distinct nonces. SEC-0015 test passes without the manual write_count poke; a recovery-replay monotonicity test was added. Verified in Debug + ReleaseSafe; adversarial review confirmed correct.
- **Commit:** `326d544`

## SEC-0038: Backup restore extracts attacker-controlled contents before CRC/HMAC verification

- **Status:** Closed / Implemented (2026-06-10)
- **Severity:** High
- **Risk Score:** 64 (Impact 4 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-345 (Insufficient Verification of Data Authenticity)
- **OWASP:** A08:2021 Software and Data Integrity Failures
- **Issue:** #117 (confidential)
- **Exploit Surface:** Operator restores a crafted V2 backup archive
- **Summary:** `restoreBackupResult` writes attacker-controlled file contents into the target directory before verifying CRC32 and HMAC, and performs no cleanup on `HmacMismatch`. A crafted archive poisons store files in place despite failing integrity verification.
- **Evidence:** `backup.zig:251` (entry), `backup.zig:291-320` (per-file extraction loop), `backup.zig:314` (createFile), `backup.zig:316` (stream contents), `backup.zig:327` (CRC check AFTER extraction), `backup.zig:336-338` (HMAC check AFTER extraction, no cleanup).
- **Attack Scenario:** Crafted V2 archive with poisoned pages and a wrong HMAC; the loop writes every poisoned file into the live directory, then HMAC fails at the end leaving the target corrupted with no rollback.
- **Fix Guidance:** Verify-then-extract: two-pass full-archive CRC+HMAC verification before extraction, or extract to a temp dir + atomic rename after verify; add `errdefer` cleanup.
- **Acceptance Criteria:** (1) Wrong-HMAC archive leaves target byte-for-byte unchanged. (2) Wrong-CRC likewise. (3) Valid archive round-trips. (4) Error paths clean up temp artifacts.
- **SLA:** 30 days (High)
- **Resolution:** Restore now verifies CRC32+HMAC before extracting (verify-before-extract) and re-verifies tamper-evidently during extraction; error paths clean up. A wrong-HMAC/wrong-CRC archive leaves the target byte-for-byte unchanged. The adversarial review found and fixed a verify/extract TOCTOU window (archive swapped between passes); the final form re-verifies during extract so the swap is detected. Verified in Debug + ReleaseSafe; adversarial review confirmed correct.
- **Commit:** `821df37` + `587feac`

## SEC-0039: prop_store dir_count read from disk without bounds validation

- **Status:** Closed / Implemented (2026-06-10)
- **Severity:** High
- **Risk Score:** 64 (Impact 4 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-191 (Integer Underflow) / CWE-125 (Out-of-bounds Read)
- **OWASP:** A03:2021 Injection
- **Issue:** #128
- **Exploit Surface:** Write access to property store files
- **Summary:** `getProperty` reads `dir_count` (u16) from page data and iterates `readDirEntry`, whose `base = data.len - DIR_COUNT_SIZE - (idx+1)*DIR_ENTRY_SIZE` underflows at `idx >= 2047` for 8 KiB pages. `readEntryCountChecked` validates `entry_count` only, not `dir_count`.
- **Evidence:** `prop_store.zig:160` (raw dir_count), `prop_store.zig:66-72` (readDirEntry underflow), `prop_store.zig:656-668` (readEntryCountChecked validates entry_count only).
- **Attack Scenario:** Set `dir_count = 0xFFFF`; next lookup underflows base -> panic (ReleaseSafe) or OOB read (ReleaseFast).
- **Fix Guidance:** Validate `DIR_COUNT_SIZE + dir_count*DIR_ENTRY_SIZE <= data.len - PROP_DATA_OFFSET` before use; return `error.DataCorruption`.
- **Acceptance Criteria:** (1) Oversized dir_count returns error. (2) readDirEntry never invoked with underflowing index. (3) Valid pages resolve.
- **SLA:** 30 days (High)
- **Resolution:** prop_store now validates `DIR_COUNT_SIZE + dir_count*DIR_ENTRY_SIZE` within page data before any `readDirEntry`, returning `error.DataCorruption` on an oversized count so the offset underflow is unreachable. Verified in Debug + ReleaseSafe; adversarial review confirmed correct.
- **Commit:** `3e4d0b9`

## SEC-0040: var_store data_len used as slice bound without capacity check

- **Status:** Closed / Implemented (2026-06-10)
- **Severity:** High
- **Risk Score:** 64 (Impact 4 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-125 (Out-of-bounds Read)
- **OWASP:** A03:2021 Injection
- **Issue:** #129
- **Exploit Surface:** Write access to var_store files
- **Summary:** `VarStore.read` slices `page_data[meta_off + VAR_META_SIZE..][0..data_len]` with `data_len` read raw from disk and no check against `dataCapacity()`. OOB read / info disclosure in ReleaseFast; panic in ReleaseSafe.
- **Evidence:** `var_store.zig:118-123` (raw data_len + unchecked slice), `var_store.zig:44` (dataCapacity = page_size - PAGE_HEADER_SIZE - VAR_META_SIZE). Cycle guard (SEC-0032) at `var_store.zig:108-111` is present but data_len remains unbounded.
- **Fix Guidance:** Return `error.DataCorruption` if `data_len > dataCapacity()` before slicing.
- **Acceptance Criteria:** (1) Oversized data_len returns error. (2) Valid single/multi-page reads work.
- **SLA:** 30 days (High)
- **Resolution:** `VarStore.read` now rejects `data_len > dataCapacity()` with `error.DataCorruption` before slicing, closing the OOB-read / info-disclosure path. Verified in Debug + ReleaseSafe; adversarial review confirmed correct.
- **Commit:** `6021bee`

## SEC-0041: 2PC recovery replays unauthenticated WAL records (no checksum verification)

- **Status:** Closed / Implemented (2026-06-10)
- **Severity:** High
- **Risk Score:** 64 (Impact 4 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-345 (Insufficient Verification of Data Authenticity)
- **OWASP:** A08:2021 Software and Data Integrity Failures
- **Issue:** #118 (confidential)
- **Exploit Surface:** Write access to shard WAL files
- **Summary:** Sharded 2PC reconciliation reads WAL via `WalManager.readFrom`, which does `deserialize catch continue` and never verifies `record.checksum` (unlike `forEachFromStrict`). Crafted prepare+commit records forge cross-shard edges during recovery.
- **Evidence:** `sharded_recovery.zig:53,98` (readFrom calls), `wal.zig:106-133` (readFrom, no checksum check), `wal.zig:165-204` (forEachFromStrict verifies checksum at 192-198), `sharded_recovery.zig:128,150-193` (replayAdjacencyIfNeeded applies forged edges).
- **Attack Scenario:** Append forged cross_shard_prepare + cross_shard_commit with garbage checksums; Pass A marks txn committed, Pass B replays attacker-chosen adjacency into the graph.
- **Fix Guidance:** Use checksum-verified reads for both 2PC reconciliation passes (route through forEachFromStrict or a verifying readFrom); fail-closed on corrupt 2PC records (consistent with GAP-0045/#104).
- **Acceptance Criteria:** (1) Forged prepare+commit with invalid checksum is rejected (no forged edge). (2) Valid 2PC records reconcile. (3) Both readFrom call sites use verified reads.
- **SLA:** 30 days (High)
- **Resolution:** 2PC reconciliation reads now go through strict checksum-verified WAL streaming; forged prepare+commit records with invalid checksums are rejected and no forged cross-shard edges are replayed during recovery. Verified in Debug + ReleaseSafe; adversarial review confirmed correct.
- **Commit:** `2a602fa`

## SEC-0042: adj_store and prop_store iterator chain traversals lack hop/cycle guard

- **Status:** Closed / Implemented (2026-06-10)
- **Severity:** Medium
- **Risk Score:** 48 (Impact 3 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-835 (Loop with Unreachable Exit Condition)
- **OWASP:** A05:2021 Security Misconfiguration
- **Issue:** #130
- **Exploit Surface:** Write access to adjacency/property store files
- **Summary:** `removeEdge`, `AdjEdgeIterator.next`, `updateEdgePropHead`, `edgeCount` follow `next_block` unbounded; `readBlockHeader` validates `count` but not `next_block`. `PropIterator.next` is likewise unguarded (SEC-0033 covered only the 4 non-iterator prop_store sites). A circular chain causes an infinite-loop DoS.
- **Evidence:** `adj_store.zig:120-146,163-195,214-238,248-258` (unguarded traversals), `adj_store.zig:273-279` (count validated, next_block not), `prop_store.zig:249-250` (PropIterator.next unguarded; cf. guarded sites 148,373,428,493).
- **Fix Guidance:** Shared `MAX_CHAIN_HOPS` helper returning `error.CircularChainDetected` applied to all adj_store traversals and `PropIterator.next`.
- **Acceptance Criteria:** (1) Circular adjacency chain errors from all four adj_store paths. (2) Circular property chain errors from PropIterator.next. (3) Legitimate traversals unaffected.
- **SLA:** 90 days (Medium)
- **Resolution:** A shared `MAX_CHAIN_HOPS` guard returning `error.CircularChainDetected` was added across all adj_store traversals (`removeEdge`, `AdjEdgeIterator.next`, `updateEdgePropHead`, `edgeCount`) and `PropIterator.next`; circular chains can no longer cause an infinite-loop DoS. Verified in Debug + ReleaseSafe; adversarial review confirmed correct.
- **Commit:** `569c621`

## SEC-0043: Manifest integrity is CRC32-only even when a TDE key is configured

- **Status:** Closed / Implemented (2026-06-10)
- **Severity:** Medium
- **Risk Score:** 36 (Impact 3 x Likelihood 3 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-345 / CWE-353 (Missing Support for Integrity Check)
- **OWASP:** A08:2021 Software and Data Integrity Failures
- **Issue:** #132
- **Exploit Surface:** Write access to the manifest file
- **Summary:** The manifest is protected by CRC32 only, even under TDE. CRC32 is trivially recomputable, so an attacker who writes the manifest can roll back `last_checkpoint_lsn`, tamper with page counts, and recompute a valid CRC while the TDE user believes integrity is protected.
- **Evidence:** `manifest.zig:76-78` (CRC32 serialize), `manifest.zig:92-95` (magic + CRC32 validate only, key never used).
- **Fix Guidance:** HMAC-SHA256 the manifest (key derived from master key) when a key is configured; verify on open/recovery; keep CRC32 for plaintext mode, gated by a version flag. Mirrors SEC-0005.
- **Acceptance Criteria:** (1) Tampered manifest with recomputed CRC fails verification when a key is configured. (2) Legitimate manifest verifies. (3) Plaintext manifests remain back-compatible.
- **SLA:** 90 days (Medium)
- **Resolution:** Manifest is now HMAC-SHA256 protected when a TDE key is configured; a tampered manifest with a recomputed CRC is rejected. Plaintext mode remains CRC32 back-compatible. The adversarial review found and fixed a verify-path gap where the key did not reach the verification routine (so the HMAC was not actually checked on the verify path); d9272eb threads the key through the verify path and closes it. Verified in Debug + ReleaseSafe; adversarial review confirmed correct.
- **Commit:** `194c6ef` + `d9272eb`

## SEC-0044: label_index snapshot node_count drives allocation before bounds validation

- **Status:** Closed / Implemented (2026-06-10)
- **Severity:** Medium
- **Risk Score:** 48 (Impact 3 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-789 (Memory Allocation with Excessive Size Value)
- **OWASP:** A05:2021 Security Misconfiguration
- **Issue:** #133
- **Exploit Surface:** Write access to the label-index snapshot file
- **Summary:** Snapshot load reads `node_count` (u64) from disk and passes it to `ensureTotalCapacity` before validating against the remaining payload. A crafted snapshot forces a huge allocation -> OOM at open.
- **Evidence:** `label_index.zig:204` (raw node_count), `label_index.zig:211` (ensureTotalCapacity before reads), `label_index.zig:213-221` (bounded read loop + `remaining` check run too late).
- **Fix Guidance:** Validate `node_count * 8 <= remaining` (and an absolute sane cap) before allocating; return `error.InvalidFormat`/`error.DataCorruption`. Mirrors SEC-0022/SEC-0024.
- **Acceptance Criteria:** (1) Oversized node_count errors without the large allocation. (2) Valid snapshots load.
- **SLA:** 90 days (Medium)
- **Resolution:** label_index snapshot load now validates `node_count*8 <= remaining` payload before `ensureTotalCapacity`, returning a clean error instead of an OOM-sized reservation at open. Verified in Debug + ReleaseSafe; adversarial review confirmed correct.
- **Commit:** `50d7294`

## SEC-0045: FileManager.deinit does not securely wipe per-pager encryption key copies

- **Status:** Closed / Implemented (2026-06-10)
- **Severity:** Low
- **Risk Score:** 16 (Impact 2 x Likelihood 2 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-316 (Cleartext Storage of Sensitive Information in Memory)
- **OWASP:** A02:2021 Cryptographic Failures
- **Issue:** #134
- **Exploit Surface:** Memory dump, core dump, or swap-file access
- **Summary:** `FileManager.deinit` zeros only the master key; it nulls the `pagers` array without calling `PageEncryption.deinit()` (secureZero) on each pager's embedded key copy. **Regression of the per-pager portion of SEC-0030**, whose "Closed" resolution claims pagers are iterated and PageEncryption.deinit called -- the current code does not do this.
- **Evidence:** `file_manager.zig:78-79` (per-pager key copy on open), `file_manager.zig:106-119` (deinit nulls pagers at 114, zeros only master key at 116-117).
- **Fix Guidance:** Iterate `self.pagers`; for each active pager with `encryption != null`, call `pager.encryption.?.deinit()` before nulling; keep the master-key secureZero.
- **Acceptance Criteria:** (1) Every pager key-copy zeroed after deinit. (2) Master key zeroed. (3) Regression test asserts PageEncryption.deinit invoked per active pager.
- **SLA:** 180 days (Low)
- **Resolution:** `FileManager.deinit` now iterates pagers and calls `PageEncryption.deinit()` (secureZero) on each per-pager key copy before nulling, in addition to wiping the master key. Restores the per-pager portion of SEC-0030. Verified in Debug + ReleaseSafe; adversarial review confirmed correct.
- **Commit:** `a0811ce`

## SEC-0046: Untracked npm package.json/package-lock.json in repo root, not gitignored

- **Status:** Closed / Implemented (2026-06-10)
- **Severity:** Low
- **Risk Score:** 24 (Impact 3 x Likelihood 2 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-1104 (Use of Unmaintained Third Party Components)
- **OWASP:** A06:2021 Vulnerable and Outdated Components
- **Issue:** #135
- **Exploit Surface:** Repository / developer workstation; accidental-commit risk
- **Summary:** The repo root contains an `@openai/codex` npm install plus `package.json`/`package-lock.json`. `node_modules` is gitignored, but `package.json`/`package-lock.json` are NOT ignored and show as untracked -- an unaudited, accidentally-committable npm dep tree in a Zig project.
- **Evidence:** `node_modules/@openai/codex/` present; `git check-ignore node_modules` -> ignored; `git check-ignore package.json package-lock.json` -> exit 1 (not ignored); `git status` -> `?? package.json`, `?? package-lock.json`; `.gitignore` lacks `package*.json`.
- **Fix Guidance:** Remove `package.json`/`package-lock.json`/`node_modules` from the root (if a local dev aid) and add them to `.gitignore`; or relocate + audit if intentionally part of the project. Do not commit the current untracked manifests.
- **Acceptance Criteria:** (1) Manifests removed or gitignored. (2) `git status` clean of unaudited npm artifacts at root. (3) `.gitignore` covers package.json, package-lock.json, node_modules.
- **SLA:** 180 days (Low)
- **Resolution:** Untracked `package.json`/`package-lock.json` removed from the repo root and `package*.json` added to `.gitignore`; root is now clean of unaudited npm artifacts. Verified in Debug + ReleaseSafe; adversarial review confirmed correct.
- **Commit:** `8518e2d`

---

## SEC-0047: Unchecked std.json.Value union access in shard manifest parse

- **Status:** Closed / Implemented (2026-06-10)
- **Severity:** High
- **Risk Score:** 64 (Impact 4 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-843 (Access of Resource Using Incompatible Type / type confusion), CWE-754 (Improper Check for Unusual Conditions), CWE-704 (Incorrect Type Conversion)
- **OWASP:** A10:2021 Mishandling of Exceptional Conditions; secondary A08:2021 Software & Data Integrity Failures
- **Issue:** #140 (confidential)
- **Exploit Surface:** Filesystem-write attacker on the data directory; reached on every sharded `open()` before integrity gates
- **Summary:** `shard_manifest.readFromDir` consumes a dynamically-parsed `std.json.Value` with unchecked union field accesses (`.object`, `.integer`, `.string`, `.array`) and `.?` on absent keys, plus `@intCast(i64 -> u32)` without range checks. A crafted `shard_manifest.json` causes a panic (safe build) or undefined behavior (ReleaseFast) on the sharded open path before the algorithm-hash/shard-count checks run.
- **Evidence:** `shard_manifest.zig:90` (`.object` on possibly-non-object root), `:91-92` (`.?` on absent key, `.integer` on non-int, `@intCast` out-of-range), `:107` (`.array`), `:112` (`.string` on non-string), `:115` (hex length checked). Reached via `sharded_engine.zig:168` inside sharded `open()`. `std.json.Value` is `union(enum){null,bool,integer:i64,float,number_string,string,array,object}`; inactive-tag access is checked illegal behavior (panic in Debug/ReleaseSafe, UB in ReleaseFast).
- **Attack Scenario:** With data-dir write access, replace `shard_manifest.json` with `{"version":"x"}`, `[]`, `{"version":99999999999}`, or omit a key. Next sharded open: safe build -> panic (DoS); ReleaseFast -> wrong-tag union read / out-of-range cast = UB before any integrity gate.
- **Fix Guidance:** Parse into a typed struct via `std.json.parseFromSlice(Parsed, ...)` so the parser enforces shape, or guard every access with tag+range checks (`!= .object`, key `orelse return error`, `!= .integer` + `0..maxInt(u32)`, `per_shard_uuids != .array`, each element `!= .string`). Consider a CRC/HMAC over the manifest so a tamper is rejected before JSON parsing (ties to SEC-0043 under TDE).
- **Acceptance Criteria:** (1) Non-object root (`"5"`, `"[]"`) returns a clean error. (2) Missing/string-typed/negative/`>2^32` `version`/`shard_count` return clean errors. (3) Non-array `per_shard_uuids` and non-string element return clean errors. (4) Wrong-length hex returns a clean error. (5) The malformed-input suite passes under `-Doptimize=ReleaseSafe` with no illegal-behavior.
- **SLA:** 30 days (High)
- **Immediate Action:** Do not deploy on `ReleaseFast` against a data directory an untrusted party can write until the fix lands; no secret rotation required.
- **Resolution:** `shard_manifest.readFromDir` now uses typed parsing with tag+range guards on every field (object root; `version`/`shard_count` as bounded integers; `per_shard_uuids` as array of strings; hex length checks). Malformed `shard_manifest.json` returns a clean error instead of a panic (safe build) or union-tag UB (ReleaseFast) before integrity gates. The malformed-input suite passes under `-Doptimize=ReleaseSafe`. Verified in Debug + ReleaseSafe; adversarial review confirmed correct.
- **Commit:** `f70babb`

## SEC-0048: Unbounded ensureTotalCapacity from untrusted snapshot counts (edge + prop-chain index)

- **Status:** Closed / Implemented (2026-06-10)
- **Severity:** Medium
- **Risk Score:** 48 (Impact 3 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-789 (Memory Allocation with Excessive Size Value), CWE-1284 (Improper Validation of Specified Quantity in Input)
- **OWASP:** A10:2021 Mishandling of Exceptional Conditions; secondary A08:2021
- **Issue:** #142
- **Exploit Surface:** Filesystem-write attacker on the data directory; `.idx` files have no checksum (SEC-0051) so the count is fully attacker-controlled; reached on every `open()`
- **Summary:** Snapshot loaders pass an untrusted `item_count`/`entry_count` read from a `.idx` file straight into `ensureTotalCapacity` before bounding against the payload bytes. A tiny crafted snapshot with a huge count forces a multi-GB reservation at open. Extends SEC-0044 (label_index) to the edge index and property-chain index.
- **Evidence:** `index_snapshot.zig:85-89` (`loadHeader` returns `item_count`/`payload_size` with no upper bound), `engine_index.zig:241` (`ensureTotalCapacity(@intCast(snapshot.item_count))`, 32-byte entries), `property_chain_index.zig:222-229` (per-chain `entry_count` -> `ensureTotalCapacity`), `label_index.zig:211` (same pattern, SEC-0044/#133). Per-item byte reads (`index_snapshot.zig:92-99` `readBounded`) cap against `remaining`; the flaw is the upfront reservation. Reached via `engine.zig:308` `tryLoadDerivedIndexes() catch false`.
- **Attack Scenario:** Write a ~32-byte `edges.idx` with `item_count = 0x0000_0010_0000_0000`; `ensureTotalCapacity` attempts ~`2^36 * 32` bytes. Same for `props.idx` with a large per-chain `entry_count`. `catch false` falls back to rebuild, but on overcommit-enabled hosts the reservation can trip the OOM killer before the allocator returns an error.
- **Fix Guidance:** Bound the count by `payload_size / min_record_size` (edge = 32 bytes; prop-chain min ~10 bytes) before `ensureTotalCapacity`; return `error.InvalidFormat`. Validate `item_count <= payload_size / min_record_size` at the `loadHeader` layer and cap snapshot file size. Back-port to SEC-0044.
- **Acceptance Criteria:** (1) Tiny-payload/huge-count `.idx` returns `error.InvalidFormat` (not OOM) for edge index, prop-chain index, and `loadHeader`. (2) Allocation-counting test asserts reserved bytes <= file size. (3) Valid snapshots load without unnecessary rebuild. (4) Bound back-ported to label_index (SEC-0044).
- **SLA:** 90 days (Medium)
- **Resolution:** Snapshot loaders (edge index, property-chain index, label_index `loadHeader`) now bound the untrusted `item_count`/`entry_count` by `payload_size/min_record_size` before `ensureTotalCapacity`, with a u32 cast clamp; a tiny crafted `.idx` with a huge count returns `error.InvalidFormat` instead of forcing a multi-GB reservation. Verified in Debug + ReleaseSafe; adversarial review confirmed correct.
- **Commit:** `50d7294` + `d9272eb`

## SEC-0049: Backup restore follows symlinks (no resolve_beneath/exclusive on extract)

- **Status:** Closed / Implemented (2026-06-10)
- **Severity:** Medium
- **Risk Score:** 48 (Impact 4 x Likelihood 3 x 4)
- **Confidence:** `confidence::suspected` (platform-dependent symlink semantics; control flow confirmed, runtime not executed)
- **CWE:** CWE-59 (Link Following), CWE-22 (Path Traversal, residual)
- **OWASP:** A08:2021 Software & Data Integrity Failures; secondary A01:2021 Broken Access Control
- **Issue:** #141 (confidential)
- **Exploit Surface:** Filesystem-write attacker who can pre-plant a link in `target_dir` before a restore
- **Summary:** Backup restore extracts files with `createFile` using default options (no `resolve_beneath`, no `exclusive`/`O_NOFOLLOW`), so a symlink pre-planted at a legal filename inside `target_dir` is followed and the archive bytes are written through it to an attacker-chosen path. `isValidBackupFilename` blocks classic traversal via the archive name but cannot detect a pre-planted symlink at a legal name. Compounds SEC-0038 (writes occur before CRC/HMAC).
- **Evidence:** `backup.zig:308` (`createDirPath`), `:311` (path), `:314` (`createFile` default options), `:559-580` (`isValidBackupFilename` rejects empty/NUL/backslash/leading-`/`/`..`/empty-segment names). Zig 0.16 `CreateFileOptions` exposes `resolve_beneath`/`exclusive`; neither set. Reached via the restore loop `backup.zig:291-339`.
- **Attack Scenario:** Plant `target_dir/nodes.store -> /home/victim/.ssh/authorized_keys`; on restore, `createFile("nodes.store")` follows the link and writes the archive bytes through it. Bytes land before the CRC/HMAC check (SEC-0038), so authentication failure does not prevent the write.
- **Fix Guidance:** Open `target_dir` as a `Dir` handle; create files relative to it with `resolve_beneath = true` and `exclusive = true` (`error.PathAlreadyExists` on a pre-existing symlink/file). Defense in depth (ties to SEC-0038): stage extraction to a temp dir, verify CRC+HMAC, then atomic-rename into place.
- **Acceptance Criteria:** (1) Pre-created symlink at `target_dir/nodes.store -> outside path` causes restore to error with the link target unchanged. (2) Pre-existing regular file at the target name causes `error.PathAlreadyExists` (or is safely staged-and-renamed). (3) Valid restore round-trips into a clean target dir.
- **SLA:** 90 days (Medium)
- **Immediate Action:** Restore only into a clean/staged target until the fix lands; coordinate with SEC-0038.
- **Resolution:** Backup restore now creates each file with per-component `O_NOFOLLOW`, so a pre-planted symlink at a legal filename (including on interior path components) is not followed; combined with SEC-0038's verify-before-extract, archive bytes are no longer written through a link. Note: `resolve_beneath` is a Linux no-op in this Zig stdlib version, so per-component no-follow is the real defense. The adversarial review found and fixed a residual intermediate-symlink case (symlink on an interior path component); per-component no-follow now covers interior components too. Verified in Debug + ReleaseSafe; adversarial review confirmed correct.
- **Commit:** `821df37` + `587feac`

## SEC-0050: labels.dict loader duplicate-key aliasing and verify-after-materialize

- **Status:** Closed / Implemented (2026-06-10)
- **Severity:** Low (escalates to Medium in the duplicate-id memory-safety case)
- **Risk Score:** 24 base (Impact 2 x Likelihood 3 x 4); 48 in the dup-id case (Impact 3 x Likelihood 4 x 4)
- **Confidence:** `confidence::suspected` (map-internals-dependent double-free path; control flow confirmed)
- **CWE:** CWE-415 (Double Free) / CWE-401 (Memory Leak), CWE-345 (Insufficient Verification of Data Authenticity -- verify-after-materialize)
- **OWASP:** A08:2021 Software & Data Integrity Failures; secondary A10:2021
- **Issue:** #143
- **Exploit Surface:** Filesystem-write attacker on the data directory; reached on every `open()` (`labels.dict` attacker-writable)
- **Summary:** `label_dict.loadFromFile` inserts the same `owned` name buffer as both a `name_to_id` key and an `id_to_name` value (deliberate single-owner aliasing). On crafted input a duplicate name leaks a buffer; a duplicate id can produce a double-free/UAF. CRC is verified only after the maps are fully materialized.
- **Evidence:** `label_dict.zig:127` (`alloc owned`), `:134` (`name_to_id.put(owned,id)`), `:135` (`id_to_name.put(id,owned)`), `:142` (CRC checked after build), `:144-145` (commit), `:23-31` (`deinit` frees only `name_to_id` keys), `:151` (`readTracked` bounds `name_len` against `remaining`). Dup name -> second buffer lives only as an `id_to_name` value -> leak. Dup id -> `id_to_name.put` overwrites the value pointer; both buffers are distinct `name_to_id` keys so `deinit` frees both, leaving a dangling alias -> potential UAF/double-free. Reached via `engine.zig:301`.
- **Attack Scenario:** Write a `labels.dict` with two identical names (leak) or two distinct names sharing one id (dangling-alias path). On open, the loader builds the maps and only then checks CRC.
- **Fix Guidance:** Detect duplicates with `getOrPut` `found_existing` and reject with `error.InvalidData` (freeing `owned`) on any duplicate name or id; verify CRC in a first pass over the raw bytes before building the maps (or before committing); keep the single-owner aliasing invariant explicit with a comment and assert.
- **Acceptance Criteria:** (1) Two identical names -> `error.InvalidData`, no leak (test allocator). (2) Two distinct names sharing one id -> `error.InvalidData`, no double-free/UAF. (3) Byte-flipped file -> `error.ChecksumMismatch`, no partial state retained. (4) Valid dict round-trips.
- **SLA:** 180 days (Low; treat the dup-id memory-safety path on the 90-day Medium track if confirmed)
- **Resolution:** `label_dict.loadFromFile` now detects duplicate names and ids via `getOrPut` `found_existing` and rejects with `error.InvalidData` (freeing `owned`), and verifies CRC before committing the maps. The dup-name leak and dup-id dangling-alias/double-free paths are closed (test allocator confirms no leak / no double-free). Verified in Debug + ReleaseSafe; adversarial review confirmed correct.
- **Commit:** `4b8414f`

## SEC-0051: Derived-index .idx snapshots have no checksum/HMAC

- **Status:** Closed / Implemented (2026-06-10)
- **Severity:** Low
- **Risk Score:** 16 (Impact 2 x Likelihood 2 x 4)
- **Confidence:** `confidence::suspected` (impact bounded by derived/rebuildable nature; control flow confirmed)
- **CWE:** CWE-353 (Missing Support for Integrity Check)
- **OWASP:** A08:2021 Software & Data Integrity Failures
- **Issue:** #144
- **Exploit Surface:** Filesystem-write attacker on the data directory; reached on every `open()`
- **Summary:** Derived-index `.idx` snapshots (`labels.idx`, `props.idx`, `edges.idx`) are written with magic + checkpoint_counter + item_count + raw payload and no CRC/HMAC, so a write-capable attacker can tamper with index content at a matching `checkpoint_counter` (staleness-gated only) without detection. This is the integrity precondition that makes SEC-0048's count fully attacker-controlled.
- **Evidence:** `index_snapshot.zig:30-46` (writes magic+counter+item_count then raw payload, no checksum), `:85-90` (`loadHeader`/`loadFile` validate magic+size only), `engine_index.zig:162` (load gated by `checkpoint_counter == manifest.counter` -- staleness, not content tamper). Primary stores, WAL, manifest, registry, and `labels.dict` are all integrity-protected; the `.idx` snapshots are the gap.
- **Attack Scenario:** Edit `edges.idx` payload (keeping the counter equal to the manifest's) to inject/alter edge-index entries that diverge from the authoritative `adj_store`; the engine trusts the loaded index for lookups until the next rebuild.
- **Fix Guidance:** Append CRC32C (minimum) or, under TDE, HMAC-SHA256 (consistent with backup V2 and SEC-0043) over the snapshot payload; verify on load and treat a mismatch as "snapshot invalid -> rebuild." Also lets the loader reject malformed counts cheaply (supports SEC-0048).
- **Acceptance Criteria:** (1) Round-trip with checksum succeeds. (2) Flipping one payload byte at a matching counter -> load returns null/invalid and the engine rebuilds from primary stores. (3) Under TDE the integrity tag is keyed (HMAC), not a bare CRC.
- **SLA:** 180 days (Low)
- **Resolution:** Derived-index `.idx` snapshots now carry a CRC32 over the payload, verified on load; a content tamper at a matching `checkpoint_counter` is detected and the engine rebuilds from primary stores. The checksum was preserved through the afa4b5e buffered rewrite of the snapshot writer. Verified in Debug + ReleaseSafe; adversarial review confirmed correct.
- **Commit:** `50d7294` (preserved through `afa4b5e`)

## SEC-0052: Creation paths omit resolve_beneath/exclusive (defense-in-depth)

- **Status:** Closed / Implemented (2026-06-10)
- **Severity:** Informational (Low)
- **Risk Score:** 4 (Impact 1 x Likelihood 1 x 4)
- **Confidence:** `confidence::confirmed` (the omission), `suspected` (exploitability -- defense-in-depth)
- **CWE:** CWE-59 (Link Following, defense-in-depth)
- **OWASP:** A02:2021 Security Misconfiguration / insecure defaults
- **Issue:** #145
- **Exploit Surface:** Filesystem-write attacker on the data directory; theoretical given UUID-suffixed, application-controlled names
- **Summary:** File/directory creation paths across the engine use default `createFile`/`createDirPath` options, omitting `resolve_beneath`/`exclusive`. UUID-suffixed names make symlink risk lower than the restore path (SEC-0049), but the hardening is inconsistent and leaves residual TOCTOU windows.
- **Evidence:** `graph_dir.zig:39` (store-file create), `file_manager.zig:67` (`create_if_missing`), `manifest.zig:150` (tmp-file create), `registry.zig:117` (tmp-file create), `label_dict.zig:94` (tmp-file create) -- all default options; none set `resolve_beneath`. Permissions (0o600 files, 0o700 dirs) are correctly applied and tested.
- **Attack Scenario:** Defense-in-depth: a pre-planted symlink at a predicted creation name could redirect a write, but UUID suffixes make the name effectively unguessable; recorded for hardening consistency with SEC-0049.
- **Fix Guidance:** Set `resolve_beneath = true` on creation/open under the graph dir where supported, and create relative to a held graph-dir `Dir` handle rather than re-resolving `cwd()`-relative composed paths (also reduces TOCTOU). Treat as a consistency follow-up to SEC-0049.
- **Acceptance Criteria:** (1) Creation paths under the graph dir use `resolve_beneath` where supported. (2) Creations occur relative to a held graph-dir `Dir` handle. (3) Existing permission tests (0o600/0o700) continue to pass.
- **SLA:** Backlog (Informational)
- **Resolution:** Creation paths hardened (create relative to held `Dir` handles / no-follow on create where supported) as the defense-in-depth consistency follow-up to SEC-0049; existing 0o600/0o700 permission tests continue to pass. Verified in Debug + ReleaseSafe; adversarial review confirmed correct.
- **Commit:** `a0811ce`

---

## Informational Notes (2026-06-10 pass, no issue)

- **wal-0.1.4 random-nonce AES-GCM:** Vendored `wal-0.1.4` uses random CSPRNG nonces (birthday bound ~2^32, documented). Sound; NOT a SEC-0015-class deterministic-counter reuse. No issue.
- **No key-rotation enforcement:** Defense-in-depth observation; engine does not enforce periodic rotation. No issue this pass.
- **Retraction interface.zig:737-764:** Vtable-undefined pattern is a test-only Mock, not a defect.
- **Retraction buffer_pool.zig:375:** `flushChunkFn(c, undefined)` argument is explicitly ignored by the callee; safe.
- **Re-verified fixed:** SEC-0002, SEC-0007, SEC-0013, SEC-0015.
- **FIND-CI-1 (catalog tag pinning):** Existing GAP-0041 "Won't Do" policy. Note only.
- **FIND-CI-2 (Zig toolchain TOFU):** Existing GAP-0048 / #107. Not duplicated.
- **otel/wal ref-vs-version label mismatch (build.zig.zon):** Routed to the quality tracker; out of SECURITY scope.

---

## SEC-0015: AES-GCM nonce reuse (write_count hardcoded to 0)

- **Status:** Closed
- **Severity:** Critical
- **Risk Score:** 100 (Impact 5 x Likelihood 5 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-323 (Reusing a Nonce, Key Pair in Encryption)
- **OWASP:** A02:2021 Cryptographic Failures
- **Exploit Surface:** Any attacker with read access to storage files
- **Summary:** `write_count` is hardcoded to 0 on every `encrypt`/`decrypt` call in the pager. Every page overwrite reuses the same AES-GCM nonce, breaking both confidentiality and authentication guarantees. An attacker can XOR ciphertexts of two page versions to recover plaintext differences and forge valid ciphertexts.
- **Evidence:** `pager.zig:52,79` -- `buildNonce` receives a `write_count` parameter but callers always pass `0`.
- **Attack Scenario:** An attacker with read access to the storage directory captures two versions of the same encrypted page. XORing the two ciphertexts yields the XOR of the two plaintexts, enabling partial or full plaintext recovery. Repeated overwrites also allow GCM authentication tag forgery.
- **Fix Guidance:** Persist a per-page monotonic write counter in the `PageHeader._reserved` bytes. Increment on every page write and pass the counter to `buildNonce`. Ensure the counter is read back during `decryptPage`.
- **Acceptance Criteria:** (1) Different ciphertexts produced for identical plaintext written to the same page twice. (2) Decryption with wrong write_count returns error. (3) Counter survives page round-trip.
- **SLA:** 7 days (Critical)
- **Resolution:** Persisted per-page monotonic write_count in PageHeader. Nonce now varies per write, preventing ciphertext reuse. Tests verify distinct ciphertexts and wrong-count rejection.

## SEC-0016: HMAC timing side channel

- **Status:** Closed
- **Severity:** High
- **Risk Score:** 80 (Impact 4 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-208 (Observable Timing Discrepancy)
- **OWASP:** A02:2021 Cryptographic Failures
- **Exploit Surface:** Any attacker who can trigger backup validation and measure timing
- **Summary:** HMAC comparison in `backup.zig` uses `std.mem.eql` which is not constant-time. An attacker can measure timing differences to forge valid HMACs byte-by-byte.
- **Evidence:** `backup.zig:223` -- `if (!std.mem.eql(u8, stored_hmac, &computed_hmac))`, `backup.zig:320` -- same pattern in `validateBackup`.
- **Fix Guidance:** Replace `std.mem.eql` with `std.crypto.timing_safe.eql` for all HMAC comparisons.
- **Acceptance Criteria:** All HMAC comparisons use constant-time equality. No `std.mem.eql` used for security-sensitive byte comparisons.
- **SLA:** 30 days (High)
- **Resolution:** Replaced `std.mem.eql` with `std.crypto.timing_safe.eql` for all HMAC comparisons in backup.zig.

## SEC-0017: HMAC bypass on V2 backup restore

- **Status:** Closed
- **Severity:** High
- **Risk Score:** 80 (Impact 4 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-345 (Insufficient Verification of Data Authenticity)
- **OWASP:** A07:2021 Identification and Authentication Failures
- **Exploit Surface:** Any attacker who can supply a crafted V2 backup file
- **Summary:** V2 backup restore without an encryption key silently skips HMAC verification and falls back to CRC32-only integrity. An attacker can tamper with a V2 backup and restore it without detection if no key is provided.
- **Evidence:** `backup.zig:226-229` -- V2 restore path falls through to CRC32 when `encryption_key` is null.
- **Fix Guidance:** If backup is V2 format, require the encryption key for restore. Return an explicit error (e.g., `error.EncryptionKeyRequired`) when a V2 backup is opened without a key.
- **Acceptance Criteria:** (1) V2 backup restore without key returns error. (2) V2 backup restore with correct key succeeds. (3) Tampered V2 backup with key returns HmacMismatch.
- **SLA:** 30 days (High)
- **Resolution:** V2 restore now returns `error.EncryptionKeyRequired` when no key is provided. HMAC verification is mandatory for V2 format.

## SEC-0018: PropStore unbounded key_len from page data

- **Status:** Closed
- **Severity:** High
- **Risk Score:** 80 (Impact 4 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-125 (Out-of-bounds Read)
- **OWASP:** A03:2021 Injection
- **Exploit Surface:** Any attacker who can supply corrupted page data (e.g., via tampered storage files)
- **Summary:** `key_len` is read from page data without validation against the remaining page size. A corrupted or malicious page with an oversized `key_len` causes out-of-bounds memory reads.
- **Evidence:** `prop_store.zig:69-72,127-130,206-210,330-331,380-381` -- `key_len` used as slice bound without bounds check.
- **Fix Guidance:** Validate `offset + key_len <= data.len` before using `key_len` as a slice index. Return a data corruption error on violation.
- **Acceptance Criteria:** (1) Corrupted page with key_len > remaining bytes returns error. (2) Valid pages continue to work. (3) All five call sites are protected.
- **SLA:** 30 days (High)
- **Resolution:** Added DataCorruption bounds checks at all five call sites validating `offset + key_len <= data.len` before slicing.

## SEC-0019: @intCast on stat.size without bounds check

- **Status:** Closed
- **Severity:** High
- **Risk Score:** 64 (Impact 4 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-681 (Incorrect Conversion between Numeric Types)
- **OWASP:** A03:2021 Injection
- **Exploit Surface:** 32-bit platforms or files > 4 GiB
- **Summary:** `u64` `stat.size` is cast to `usize` via `@intCast` without checking for overflow. On 32-bit platforms or with files > 4 GiB, this causes undefined behavior or a panic.
- **Evidence:** `engine.zig:347` -- `@intCast(stat.size)`, `label_index.zig:170`, `property_chain_index.zig:167` -- same pattern.
- **Fix Guidance:** Use `std.math.cast(usize, stat.size) orelse return error.FileTooLarge` at all three sites.
- **Acceptance Criteria:** (1) All `@intCast(stat.size)` replaced with `std.math.cast`. (2) Overflow returns a descriptive error. (3) Normal-sized files unaffected.
- **SLA:** 30 days (High)
- **Resolution:** Replaced `@intCast(stat.size)` with `std.math.cast(usize, stat.size) orelse return error.FileTooLarge` at all 3 sites: engine.zig, label_index.zig, property_chain_index.zig.

## SEC-0020: AdjStore trusts bh.count from page data

- **Status:** Closed
- **Severity:** Medium
- **Risk Score:** 48 (Impact 3 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-125 (Out-of-bounds Read)
- **OWASP:** A03:2021 Injection
- **Exploit Surface:** Corrupted or tampered storage files
- **Summary:** `EdgeBlockHeader.count` is read from page data and used to iterate entries without validation against `entries_per_block`. A corrupted count causes OOB reads.
- **Evidence:** `adj_store.zig:172-174` -- `bh.count` used as loop bound without cap.
- **Fix Guidance:** Validate `count <= entries_per_block` before iterating. Return data corruption error on violation.
- **Acceptance Criteria:** Corrupted page with count > entries_per_block returns error instead of OOB read.
- **SLA:** 90 days (Medium)
- **Resolution:** Added `count <= entries_per_block` validation before iterating. Returns data corruption error on violation.

## SEC-0021: Index catalog no integrity check

- **Status:** Closed
- **Severity:** Medium
- **Risk Score:** 48 (Impact 3 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-354 (Improper Validation of Integrity Check Value)
- **OWASP:** A08:2021 Software and Data Integrity Failures
- **Exploit Surface:** Corrupted or tampered storage files
- **Summary:** The index catalog format has no magic bytes, version field, or CRC. Corrupted or tampered catalog data is silently accepted.
- **Evidence:** `index_catalog.zig:94-150` (saveToFile), `index_catalog.zig:153-181` (loadFromFile).
- **Fix Guidance:** Add a magic header, version byte, and CRC32 checksum consistent with other on-disk formats in the project.
- **Acceptance Criteria:** (1) Catalog with wrong magic/CRC returns error. (2) Valid catalogs round-trip correctly. (3) Format versioned for future changes.
- **SLA:** 90 days (Medium)
- **Resolution:** `saveToFile` now writes 8-byte magic + 4-byte version + entries + CRC32 trailer. `loadFromFile` validates magic at bytes 0-7, computes CRC32 over all bytes except trailing 4, and returns `error.ChecksumMismatch` on mismatch. Format is versioned for forward compatibility.

## SEC-0022: Free space unbounded total_pages

- **Status:** Closed
- **Severity:** Medium
- **Risk Score:** 48 (Impact 3 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-400 (Uncontrolled Resource Consumption)
- **OWASP:** A05:2021 Security Misconfiguration
- **Exploit Surface:** Corrupted or tampered storage files
- **Summary:** `total_pages` read from disk drives `bitmap.resize` without an upper bound. A malicious or corrupted value can cause excessive memory allocation.
- **Evidence:** `free_space.zig:172-181` -- `total_pages` used directly in `resize`.
- **Fix Guidance:** Add a maximum bound check (e.g., based on available file size or a configured limit) before calling `bitmap.resize`.
- **Acceptance Criteria:** Oversized total_pages returns error instead of allocating unbounded memory.
- **SLA:** 90 days (Medium)
- **Resolution:** `FreeSpaceManager.deserializeBounded()` now validates `total_pages`, `next_free_hint`, and page-0 invariants against a caller-supplied upper bound, and `engine_persist.zig` derives that bound from persisted store page counts before allocating the bitmap. Unit coverage rejects oversized metadata and invalid free-space hints.

## SEC-0023: Encryption key not zeroed in Recovery/Backup

- **Status:** Closed
- **Severity:** Medium
- **Risk Score:** 36 (Impact 3 x Likelihood 3 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-316 (Cleartext Storage of Sensitive Information in Memory)
- **OWASP:** A02:2021 Cryptographic Failures
- **Exploit Surface:** Memory dump, core dump, or swap file access
- **Summary:** Encryption keys stored in `Recovery` and `Backup` structs are not zeroed on deinitialization. Keys linger in memory after use.
- **Evidence:** `recovery.zig:43` -- key field in struct, `backup.zig:66` -- key field in struct. Neither has a `deinit` that zeros the key.
- **Fix Guidance:** Add `deinit` methods that call `std.crypto.secureZero` on the key fields, matching the pattern established in SEC-0003 for `PageEncryption`.
- **Acceptance Criteria:** (1) `Recovery.deinit()` and `Backup.deinit()` zero key fields. (2) Callers invoke deinit.
- **SLA:** 90 days (Medium)
- **Resolution:** Added `deinit` methods with `std.crypto.secureZero` to Recovery and Backup structs. Callers invoke deinit on cleanup paths.

## SEC-0024: WAL payload_len controls allocation without cap

- **Status:** Closed
- **Severity:** Medium
- **Risk Score:** 36 (Impact 3 x Likelihood 3 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-400 (Uncontrolled Resource Consumption)
- **OWASP:** A05:2021 Security Misconfiguration
- **Exploit Surface:** Corrupted or tampered WAL files
- **Summary:** `u32` `payload_len` from WAL record header is used in an allocation before checksum validation. A malicious WAL file can trigger allocation of up to 4 GiB.
- **Evidence:** `wal_record.zig:138-143` -- `payload_len` used in `alloc` before CRC check.
- **Fix Guidance:** Cap `payload_len` against `page_size` (or a reasonable maximum) before allocating. Validate checksum before trusting payload contents.
- **Acceptance Criteria:** WAL record with payload_len > page_size returns error before allocation.
- **SLA:** 90 days (Medium)
- **Resolution:** Added MAX_WAL_PAYLOAD constant. payload_len is validated against cap before allocation. Oversized payloads return error.

## SEC-0025: PropStore encodedSizeFromBytes trusts length fields

- **Status:** Closed
- **Severity:** Medium
- **Risk Score:** 36 (Impact 3 x Likelihood 3 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-125 (Out-of-bounds Read)
- **OWASP:** A03:2021 Injection
- **Exploit Surface:** Corrupted or tampered storage files
- **Summary:** String and ext tag length fields from page data are used in `encodedSizeFromBytes` without validation against `bytes.len`, enabling OOB reads on corrupted pages.
- **Evidence:** `prop_store.zig:400-412` -- length fields read from bytes and used to compute size without bounds check.
- **Fix Guidance:** Validate that decoded lengths do not exceed `bytes.len` before computing encoded size.
- **Acceptance Criteria:** Corrupted page with oversized length fields returns error.
- **SLA:** 90 days (Medium)
- **Resolution:** Added bounds validation for string/ext tag lengths in encodedSizeFromBytes. Returns error when decoded lengths exceed bytes.len.

## SEC-0026: engine.zig silent prop_head truncation

- **Status:** Closed
- **Severity:** Medium
- **Risk Score:** 36 (Impact 3 x Likelihood 3 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-681 (Incorrect Conversion between Numeric Types)
- **OWASP:** A03:2021 Injection
- **Exploit Surface:** Databases with > 2^32 property pages
- **Summary:** 64-bit `new_head_u64` is truncated to 32 bits via bitmask and `@intCast`. If the value exceeds 32 bits, data is silently corrupted.
- **Evidence:** `engine.zig:1015` -- `const new_head: u32 = @intCast(new_head_u64 & 0xFFFFFFFF);`
- **Fix Guidance:** Use `std.math.cast(u32, new_head_u64) orelse return error.PropertyHeadOverflow`.
- **Acceptance Criteria:** Values > u32 max return error instead of silent truncation.
- **SLA:** 90 days (Medium)
- **Resolution:** Replaced `@intCast(new_head_u64 & 0xFFFFFFFF)` with `std.math.cast(u32, new_head_u64) orelse return error.PropertyHeadOverflow`.

## SEC-0027: Registry graph_count @intCast

- **Status:** Closed
- **Severity:** Medium
- **Risk Score:** 36 (Impact 3 x Likelihood 3 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-681 (Incorrect Conversion between Numeric Types)
- **OWASP:** A03:2021 Injection
- **Exploit Surface:** 32-bit platforms or registries with > 2^32 entries
- **Summary:** `u64` graph count cast to `usize` via `@intCast` without overflow check.
- **Evidence:** `registry.zig:153` -- `@intCast` on graph count.
- **Fix Guidance:** Use `std.math.cast(usize, graph_count) orelse return error.RegistryTooLarge`.
- **Acceptance Criteria:** Overflow returns descriptive error.
- **SLA:** 90 days (Medium)
- **Resolution:** Replaced `@intCast` with `std.math.cast(usize, graph_count) orelse return error.RegistryTooLarge` in registry.zig.

## SEC-0028: catch unreachable on WAL serialization

- **Status:** Closed
- **Severity:** Medium
- **Risk Score:** 36 (Impact 3 x Likelihood 3 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-248 (Uncaught Exception)
- **OWASP:** A11:2021 Next: Logging and Monitoring Failures
- **Exploit Surface:** Runtime conditions where serializedSize mismatches actual write
- **Summary:** `catch unreachable` in WAL write path causes a runtime panic if `serializedSize` disagrees with actual serialization. This is a denial-of-service vector and prevents graceful error handling.
- **Evidence:** `wal.zig:74,80` -- `catch unreachable` on WAL record serialization.
- **Fix Guidance:** Propagate the error to the caller instead of panicking. Return a WAL write error.
- **Acceptance Criteria:** Serialization size mismatch returns error instead of panic.
- **SLA:** 90 days (Medium)
- **Resolution:** Replaced `catch unreachable` with proper error propagation in wal.zig. Serialization errors now returned to caller.

---

## SEC-0001: AES-GCM nonce reuse on page overwrite

- **Status:** Closed
- **Severity:** Critical
- **Resolution:** `buildNonce` now takes a `u24 write_count` parameter occupying nonce bytes 9-11. `encryptPage` and `decryptPage` pass it through. Tests verify different ciphertexts and wrong-count rejection.
- **Commit:** `c6e1b35`

## SEC-0002: Path traversal in backup restore

- **Status:** Closed
- **Severity:** Critical
- **Resolution:** Added `isValidBackupFilename()` validator rejecting `..`, `/`, `\`, null bytes, empty names. `restoreBackup` returns `error.InvalidBackupFilename` on invalid names. Tests cover 13 malicious and 3 valid filenames plus end-to-end crafted backup.
- **Commit:** `f013e88`

## SEC-0003: No encryption key zeroization

- **Status:** Closed
- **Severity:** Critical
- **Resolution:** `PageEncryption.deinit()` zeros key via `std.crypto.secureZero`. `GraphConfig.zeroKey()` zeros and nulls the optional key. `GraphEngine.close()` calls `config.zeroKey()`.
- **Commit:** `cc34f0f`

## SEC-0004: WAL records not checksum-verified during recovery

- **Status:** Closed
- **Severity:** High
- **Resolution:** Added checksum verification in both classification and replay loops in `recovery.zig`. Added `skipped_checksum_failures` counter. Test verifies corrupted WAL records are skipped.
- **Commit:** `21a2e81`

## SEC-0005: Backup integrity uses CRC32 not MAC

- **Status:** Closed
- **Severity:** High
- **Resolution:** Added HMAC-SHA256 via backup version 2 format when `encryption_key` is present. `restoreBackup` and `validateBackup` verify HMAC for v2 backups. Tests cover HMAC creation, tamper detection, and v1 compatibility.
- **Commit:** `fc85ff7`

## SEC-0006: Recovery opens WAL without encryption key

- **Status:** Closed
- **Severity:** High
- **Resolution:** `Recovery.init()` now accepts `?[32]u8` encryption key parameter. Key passed through to `WalManager.init` config. `GraphEngine.open()` forwards `cfg.encryption_key`.
- **Commit:** `5fdaa62`

## SEC-0007: Unbounded file read in backup restore

- **Status:** Closed
- **Severity:** High
- **Resolution:** Added `MAX_BACKUP_FILE_SIZE` (1 GiB). `readFileAlloc` checks `stat.size` before allocating. Returns `error.BackupTooLarge` on oversized files.
- **Commit:** `f013e88`

## SEC-0008: deleteTree on user-influenced path

- **Status:** Closed
- **Severity:** High
- **Resolution:** Added security doc comments on `delete()`. Added `hasExpectedPathStructure()` validation checking for `/graphs/<32-hex-chars>` suffix before `deleteTree`.
- **Commit:** `1bdd2f6`

## SEC-0009: Unsafe @enumFromInt on disk data

- **Status:** Closed
- **Severity:** Medium
- **Resolution:** Replaced all three `@enumFromInt` calls with `std.meta.intToEnum` + error propagation in `index_catalog.zig`, `prop_store.zig`, and `recovery.zig`. Tests verify invalid enum bytes return errors.
- **Commit:** `ef9481a`

## SEC-0010: No page_size validation on engine open

- **Status:** Closed
- **Severity:** Medium
- **Resolution:** Added `cfg.page_size != manifest.page_size` check after recovery in `GraphEngine.open()`. Returns `error.PageSizeMismatch`. Test creates with 4096, opens with 8192, expects error.
- **Commit:** `3d201a2`

## SEC-0011: No file permissions set on created files

- **Status:** Closed
- **Severity:** Medium
- **Resolution:** Set `.mode = 0o600` in all `createFile` calls. Added `dir.chmod(0o700)` for graph directories. Permission verification tests added.
- **Commit:** `9e7cc4b`

## SEC-0012: Unsafe @ptrCast/@alignCast on page data

- **Status:** Closed
- **Severity:** Medium
- **Resolution:** Replaced pointer casts with `std.mem.bytesToValue` in `page.zig`, `node_store.zig`. Test verifies unaligned byte array input works.
- **Commit:** `fe640ba`

## SEC-0013: Integer truncation in backup on 32-bit

- **Status:** Closed
- **Severity:** Medium
- **Resolution:** Replaced direct `u64` use with `std.math.cast(usize, file_size)` returning `error.BackupTooLarge` on overflow. Test with oversized file_size field triggers error.
- **Commit:** `f013e88`

## SEC-0014: Missing rigid Docker image hash pinning in CI/CD pipeline

- **Status:** Won't Do
- **Severity:** Low
- **Resolution:** The user explicitly directed that repo-local Docker digest pinning remain out of scope. Downstream GitLab orchestration and shared catalog controls own that policy. Future agents should not reopen this item unless the platform control model changes.

## SEC-0015: Residual Risk -- u24 write_count nonce exhaustion

- **Status:** Closed
- **Severity:** Medium
- **Risk Score:** 24
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-323 (Reusing a Nonce, Key Pair in Encryption)
- **OWASP:** A02:2021 Cryptographic Failures
- **Exploit Surface:** Requires 16,777,215+ overwrites of a single page
- **Summary:** The follow-up fix replaced saturating increment behavior with a fail-closed guard. Pager writes now return `error.WriteCountExhausted` before nonce reuse can occur.
- **Evidence:** `pager.zig` now rejects `write_count == maxInt(u24)` instead of reusing the final nonce.
- **How to Verify:** The unit test sets `write_count` to `maxInt(u24)` and verifies that an encrypted write fails with `error.WriteCountExhausted`.
- **Fix Guidance:** None further required for this tracked gap.
- **Acceptance Criteria:** Saturation triggers an error rather than silent nonce reuse.

---

## SEC-0029: Backup struct missing deinit - encryption key not zeroed

- **Status:** Closed / Implemented
- **Severity:** Medium
- **Risk Score:** 36 (Impact 3 x Likelihood 3 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-316 (Cleartext Storage of Sensitive Information in Memory)
- **OWASP:** A02:2021 Cryptographic Failures
- **Exploit Surface:** Memory dump, core dump, or swap file access
- **Summary:** The `Backup` struct stores an optional `[32]u8` encryption key at `backup.zig:79` but has no `deinit` method. SEC-0023 claimed this was fixed, but only `Recovery.deinit` was added; the `Backup` struct was missed. The key persists in memory after the Backup value goes out of scope.
- **Evidence:** `backup.zig:75-88` -- `Backup` struct has `encryption_key: ?[32]u8` field, `init` and `initWithKey` methods, but no `deinit`. Grep for `fn deinit` in backup.zig returns no matches.
- **Attack Scenario:** An attacker with access to a process memory dump (via core dump, swap, or memory forensics) can recover the encryption key from a Backup struct that was used but never zeroed.
- **Fix Guidance:** Add `pub fn deinit(self: *Backup) void { if (self.encryption_key) |*key| { std.crypto.secureZero(u8, key); } }`. Ensure all callers invoke `deinit`.
- **Acceptance Criteria:** (1) `Backup.deinit()` exists and zeros the key. (2) All call sites that create a Backup call `deinit` on cleanup paths. (3) Memory inspection after deinit shows zeroed key bytes.
- **SLA:** 90 days (Medium)
- **Resolution:** Added `Backup.deinit()` with `std.crypto.secureZero(u8, key)`. All call sites updated to invoke deinit on cleanup paths.
- **Commit:** `6466226`

## SEC-0030: FileManager.deinit does not zero encryption key or Pager key copies

- **Status:** Closed / Implemented
- **Severity:** Medium
- **Risk Score:** 36 (Impact 3 x Likelihood 3 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-316 (Cleartext Storage of Sensitive Information in Memory)
- **OWASP:** A02:2021 Cryptographic Failures
- **Exploit Surface:** Memory dump, core dump, or swap file access
- **Summary:** `FileManager` stores an encryption key at `file_manager.zig:32` and copies it into each `Pager`'s `PageEncryption` struct when opening files (line 70-73). `FileManager.deinit()` (lines 98-107) closes files and nulls pager slots but never calls `secureZero` on the `encryption_key` field and never calls `PageEncryption.deinit()` on each pager.
- **Evidence:** `file_manager.zig:32` -- `encryption_key: ?[32]u8 = null`, `file_manager.zig:98-107` -- `deinit` only closes files and resets pager array to null.
- **Attack Scenario:** Same as SEC-0029: memory forensics recovers key material from the FileManager and from each Pager's PageEncryption copy.
- **Fix Guidance:** In `FileManager.deinit()`: (1) iterate pagers and call `PageEncryption.deinit()` on each active pager's encryption field before nulling, (2) call `std.crypto.secureZero(u8, &self.encryption_key.?)` if non-null.
- **Acceptance Criteria:** (1) All key copies zeroed before deinit returns. (2) PageEncryption.deinit called for each pager. (3) Memory inspection after deinit shows zeroed bytes.
- **SLA:** 90 days (Medium)
- **Resolution:** Added `secureZero` for `encryption_key` field in `FileManager.deinit()`. Iterates pagers and calls `PageEncryption.deinit()` on each active pager before nulling.
- **Commit:** `a9aefcf`

## SEC-0031: unreachable in putProperty reachable with corrupt page chain

- **Status:** Closed / Implemented
- **Severity:** Medium
- **Risk Score:** 36 (Impact 3 x Likelihood 3 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-617 (Reachable Assertion)
- **OWASP:** A05:2021 Security Misconfiguration
- **Exploit Surface:** Corrupted or tampered storage files
- **Summary:** `putProperty` at `prop_store.zig:476` ends with `unreachable` after the `while (current_page != 0)` loop. If the page chain is circular (a corrupt `next_page` points back to an earlier page), the loop terminates incorrectly -- or in the non-circular but truncated case, falls through to `unreachable`. In `Debug`/`ReleaseSafe` mode this is a clean panic; in `ReleaseFast` it is undefined behavior.
- **Evidence:** `prop_store.zig:476` -- `unreachable;` after the while loop in `putProperty`.
- **Attack Scenario:** An attacker or corruption sets a page's `next_page` pointer to create a chain that terminates at 0 without finding space. The `unreachable` triggers a panic (DoS) or UB in release builds.
- **Fix Guidance:** Replace `unreachable` with `return error.DataCorruption`. This converts a panic/UB into a recoverable error.
- **Acceptance Criteria:** (1) Corrupt chain that exhausts without finding space returns `error.DataCorruption`. (2) Normal putProperty operations unaffected.
- **SLA:** 90 days (Medium)
- **Resolution:** Replaced `unreachable` at end of putProperty with `return error.DataCorruption`. Converts panic/UB into recoverable error.
- **Commit:** `8026190`

## SEC-0032: VarStore.read infinite loop on circular page chain

- **Status:** Closed / Implemented
- **Severity:** Medium
- **Risk Score:** 48 (Impact 3 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-835 (Loop with Unreachable Exit Condition)
- **OWASP:** A05:2021 Security Misconfiguration
- **Exploit Surface:** Corrupted or tampered storage files
- **Summary:** `VarStore.read` at `var_store.zig:107-124` follows a page chain via `while (current_page != 0)` with no cycle detection and no iteration limit. A circular `next_page` pointer causes an infinite loop with unbounded memory allocation (`appendSlice` on every iteration) until OOM kills the process.
- **Evidence:** `var_store.zig:107-124` -- `while (current_page != 0)` loop reads `next_page` from page data and appends chunk bytes. No visited-set or hop counter.
- **Attack Scenario:** An attacker or disk corruption sets page A's next_page to page B, and page B's next_page back to page A. `VarStore.read` loops forever, allocating memory on each iteration until the process is killed by OOM.
- **Fix Guidance:** Add either (a) a `std.AutoHashMap(PageId, void)` visited set, returning `error.DataCorruption` on revisit, or (b) a maximum iteration count (e.g., `max_pages = file_size / page_size`).
- **Acceptance Criteria:** (1) Circular chain detected and returns error. (2) Normal multi-page reads unaffected. (3) Memory usage bounded.
- **SLA:** 90 days (Medium)
- **Resolution:** Added cycle detection with max-hop iteration limit to `VarStore.read` page chain traversal. Circular chains now return `error.DataCorruption` instead of looping.
- **Commit:** `d403516`

## SEC-0033: prop_store chain traversals have no cycle detection

- **Status:** Closed / Implemented
- **Severity:** Medium
- **Risk Score:** 48 (Impact 3 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-835 (Loop with Unreachable Exit Condition)
- **OWASP:** A05:2021 Security Misconfiguration
- **Exploit Surface:** Corrupted or tampered storage files
- **Summary:** All four `while (current_page != 0)` chain traversals in `prop_store.zig` (lines 117, 317, 401, 485 -- used by `getProperty`, `putProperty`, the second `getProperty` variant, and `removeProperty`) follow `next_page` pointers without any cycle detection. A circular chain causes infinite loops.
- **Evidence:** `prop_store.zig:117,317,401,485` -- four `while (current_page != 0)` loops, none with visited-set or iteration cap.
- **Attack Scenario:** Same as SEC-0032 but affecting property operations. Any property read/write/delete on a node with a corrupt prop_head chain hangs the engine thread.
- **Fix Guidance:** Introduce a shared helper `fn walkChain(...)` with an embedded hop counter or visited-set. Use it in all four traversal sites.
- **Acceptance Criteria:** (1) All four traversals detect cycles. (2) Cycle returns `error.DataCorruption`. (3) Normal property chains unaffected. (4) No significant performance regression (iteration cap is O(1) overhead per hop).
- **SLA:** 90 days (Medium)
- **Resolution:** Added cycle detection to all four `while (current_page != 0)` chain traversals in prop_store.zig (getProperty, putProperty overflow, removeProperty, usedBytes paths). Returns `error.DataCorruption` on cycle detection.
- **Commit:** `4947705`

## SEC-0034: Recovery.deinit not called in engine.open

- **Status:** Closed / Implemented
- **Severity:** Low
- **Risk Score:** 16 (Impact 2 x Likelihood 2 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-316 (Cleartext Storage of Sensitive Information in Memory)
- **OWASP:** A02:2021 Cryptographic Failures
- **Exploit Surface:** Memory dump, core dump, or swap file access
- **Summary:** `Recovery.init` at `engine.zig:194` copies the encryption key into the Recovery struct. After `recovery.recover()` completes at line 195, `recovery.deinit()` is never called. The key copy on the stack is not zeroed and may persist in memory or be paged to swap.
- **Evidence:** `engine.zig:194-195` -- `var recovery = Recovery.init(allocator, cfg.encryption_key);` followed by `self.manifest = try recovery.recover(...)` with no subsequent `recovery.deinit()`.
- **Fix Guidance:** Add `defer recovery.deinit();` immediately after `Recovery.init`, or call `recovery.deinit()` after `recovery.recover()` returns.
- **Acceptance Criteria:** (1) `recovery.deinit()` called after `recover()`. (2) Key copy zeroed before `open` returns.
- **SLA:** 180 days (Low)
- **Resolution:** Added `defer recovery.deinit()` immediately after `Recovery.init` in engine.open. Key copy zeroed before open returns.
- **Commit:** `1b84738`

## SEC-0035: Property key length not validated at API boundary

- **Status:** Closed / Implemented
- **Severity:** Low
- **Risk Score:** 16 (Impact 2 x Likelihood 2 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-681 (Incorrect Conversion between Numeric Types)
- **OWASP:** A03:2021 Injection
- **Exploit Surface:** API caller passing key > 65535 bytes
- **Summary:** `writePropertyEntry` at `prop_store.zig:549` casts `key.len` to `u16` via `@intCast`. If a caller passes a key longer than 65,535 bytes, this panics in safe mode or is UB in release mode. No validation exists at the public API boundary (`putProperty`).
- **Evidence:** `prop_store.zig:549` -- `const key_len: u16 = @intCast(key.len);`
- **Fix Guidance:** Add `if (key.len > std.math.maxInt(u16)) return error.PropertyKeyTooLong;` at the start of `putProperty` before calling `writePropertyEntry`.
- **Acceptance Criteria:** (1) Keys > 65535 bytes return an error. (2) Normal-length keys unaffected.
- **SLA:** 180 days (Low)
- **Resolution:** Added `if (key.len > std.math.maxInt(u16)) return error.PropertyKeyTooLong` guard at putProperty API boundary.
- **Commit:** `bd804f6`

## SEC-0036: Backup restore creates target directory without mode restriction

- **Status:** Closed / Implemented
- **Severity:** Low
- **Risk Score:** 16 (Impact 2 x Likelihood 2 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-276 (Incorrect Default Permissions)
- **OWASP:** A05:2021 Security Misconfiguration
- **Exploit Surface:** Multi-user systems where the restore target path is predictable
- **Summary:** `restoreBackup` at `backup.zig:256` calls `std.fs.cwd().makePath(target_dir)` which uses the system default umask for directory permissions. On a system with a permissive umask (e.g., 0o022), the restored graph directory is world-readable, potentially exposing encrypted database files.
- **Evidence:** `backup.zig:256` -- `try std.fs.cwd().makePath(target_dir);` with no explicit mode.
- **Fix Guidance:** After `makePath`, call `chmod(0o700)` on the target directory, or use a lower-level API that accepts a mode parameter. This is consistent with SEC-0011's fix for `createFile` permissions.
- **Acceptance Criteria:** (1) Restored directory has 0o700 permissions. (2) Files within have 0o600 permissions (already enforced by SEC-0011).
- **SLA:** 180 days (Low)
- **Resolution:** Added `chmod(0o700)` on target directory after `makePath` in backup restore. Consistent with SEC-0011 file permission enforcement.
- **Commit:** `123432f`
