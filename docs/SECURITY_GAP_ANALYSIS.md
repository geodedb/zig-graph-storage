# Security Gap Analysis

**Last updated:** 2026-04-06
**Source:** Full Codebase Audit (docs/AUDIT_REPORT.md)

## Summary

| Status | Count |
|--------|-------|
| Open | 0 |
| Closed | 25 |
| Won't Do | 1 |
| Blocked | 0 |
| Deferred | 2 |

### Top 5 Risks (All Closed)

| Rank | Finding | Risk Score | Severity | Status |
|------|---------|------------|----------|--------|
| 1 | SEC-0015: AES-GCM nonce reuse (write_count hardcoded) | 100 | Critical | Closed |
| 2 | SEC-0016: HMAC timing side channel | 80 | High | Closed |
| 3 | SEC-0017: HMAC bypass on V2 backup restore | 80 | High | Closed |
| 4 | SEC-0018: PropStore unbounded key_len from page data | 80 | High | Closed |
| 5 | SEC-0019: @intCast on stat.size without bounds check | 64 | High | Closed |

### Stack-Ranked Findings (All Resolved)

| Rank | Severity | Risk Score | Finding | Component | CWE/OWASP | Evidence | Fix | Status |
|------|----------|------------|---------|-----------|------------|----------|-----|--------|
| 1 | Critical | 100 | SEC-0015: AES-GCM nonce reuse | pager.zig | CWE-323 / A02:2021 | pager.zig:52,79 | write_count persisted in PageHeader | Closed |
| 2 | High | 80 | SEC-0016: HMAC timing side channel | backup.zig | CWE-208 / A02:2021 | backup.zig:223,320 | timing_safe.eql | Closed |
| 3 | High | 80 | SEC-0017: HMAC bypass on V2 restore | backup.zig | CWE-345 / A07:2021 | backup.zig:226-229 | error.EncryptionKeyRequired | Closed |
| 4 | High | 80 | SEC-0018: PropStore unbounded key_len | prop_store.zig | CWE-125 / A03:2021 | prop_store.zig:69-72,127-130,206-210,330-331,380-381 | DataCorruption bounds checks | Closed |
| 5 | High | 64 | SEC-0019: @intCast on stat.size | engine.zig, label_index.zig, property_chain_index.zig | CWE-681 / A03:2021 | engine.zig:347, label_index.zig:170, property_chain_index.zig:167 | std.math.cast at all 3 sites | Closed |
| 6 | Medium | 48 | SEC-0020: AdjStore trusts bh.count | adj_store.zig | CWE-125 / A03:2021 | adj_store.zig:172-174 | count validation added | Closed |
| 7 | Medium | 48 | SEC-0021: Index catalog no integrity check | index_catalog.zig | CWE-354 / A08:2021 | index_catalog.zig:93-180 | Format change required | Deferred |
| 8 | Medium | 48 | SEC-0022: Free space unbounded total_pages | free_space.zig | CWE-400 / A05:2021 | free_space.zig:172-181 | Policy decision needed | Deferred |
| 9 | Medium | 36 | SEC-0023: Encryption key not zeroed in Recovery/Backup | recovery.zig, backup.zig | CWE-316 / A02:2021 | recovery.zig:43, backup.zig:66 | Recovery.deinit with secureZero | Closed |
| 10 | Medium | 36 | SEC-0024: WAL payload_len controls allocation | wal_record.zig | CWE-400 / A05:2021 | wal_record.zig:138-143 | MAX_WAL_PAYLOAD cap | Closed |
| 11 | Medium | 36 | SEC-0025: PropStore encodedSizeFromBytes trusts length fields | prop_store.zig | CWE-125 / A03:2021 | prop_store.zig:400-412 | bounds validation added | Closed |
| 12 | Medium | 36 | SEC-0026: Silent prop_head truncation | engine.zig | CWE-681 / A03:2021 | engine.zig:1015 | std.math.cast | Closed |
| 13 | Medium | 36 | SEC-0027: Registry graph_count @intCast | registry.zig | CWE-681 / A03:2021 | registry.zig:153 | std.math.cast | Closed |
| 14 | Medium | 36 | SEC-0028: catch unreachable on WAL serialization | wal.zig | CWE-248 / A11:2021 | wal.zig:74,80 | error propagation | Closed |

### Roadmap

All quick-win and medium items are closed. Two strategic items remain deferred:

**Deferred:**
- SEC-0021: Add magic, version, and CRC32 integrity check to index catalog format (format change, own branch)
- SEC-0022: Add maximum total_pages bound and validate before bitmap resize (policy decision needed)

---

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

- **Status:** Deferred
- **Severity:** Medium
- **Risk Score:** 48 (Impact 3 x Likelihood 4 x 4)
- **Confidence:** `confidence::confirmed`
- **CWE:** CWE-354 (Improper Validation of Integrity Check Value)
- **OWASP:** A08:2021 Software and Data Integrity Failures
- **Exploit Surface:** Corrupted or tampered storage files
- **Summary:** The index catalog format has no magic bytes, version field, or CRC. Corrupted or tampered catalog data is silently accepted.
- **Evidence:** `index_catalog.zig:93-180` -- deserialization has no integrity validation.
- **Fix Guidance:** Add a magic header, version byte, and CRC32 checksum consistent with other on-disk formats in the project.
- **Acceptance Criteria:** (1) Catalog with wrong magic/CRC returns error. (2) Valid catalogs round-trip correctly. (3) Format versioned for future changes.
- **SLA:** 90 days (Medium)
- **Deferral Reason:** Requires on-disk format change (magic + version + CRC header). Needs its own branch and coordinated format-spec.md update.

## SEC-0022: Free space unbounded total_pages

- **Status:** Deferred
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
- **Deferral Reason:** Requires policy decision on maximum database size and coordination with config layer. Needs design discussion before implementation.

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
- **Resolution:** The user explicitly stated this is out of scope since CI/CD is managed downstream via GitLab orchestration. Image pinning will not be enforced at the repository level. Avoids unnecessary merge conflict overhead for security patches on tags.
