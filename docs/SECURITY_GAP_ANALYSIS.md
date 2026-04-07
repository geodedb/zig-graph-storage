# Security Gap Analysis

**Last updated:** 2026-04-07 (gap closure pass)
**Source:** Full Codebase Audit (docs/AUDIT_REPORT.md), Phase 4 review

## Summary

| Status | Count |
|--------|-------|
| Open | 0 |
| Closed | 35 |
| Won't Do | 1 |
| Blocked | 0 |
| Deferred | 0 |

**Known residual risk:** No open cryptographic or storage-integrity gaps remain from this review pass. The previous SEC-0015 residual note was closed once pager writes began failing closed at counter exhaustion.

### Top Remaining Notes

No open items remain. All security findings are Closed or Won't Do.

### Stack-Ranked Findings

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

All tracked items in this pass are now closed except the user-directed Won't Do item for repo-local Docker digest pinning.

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
