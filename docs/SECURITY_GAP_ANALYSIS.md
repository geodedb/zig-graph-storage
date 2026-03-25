# Security Gap Analysis

**Last updated:** 2026-03-25
**Source:** Full Codebase Audit (docs/AUDIT_REPORT.md)

## Summary

| Status | Count |
|--------|-------|
| Open | 11 |
| Closed | 2 |
| Won't Do | 0 |
| Blocked | 0 |

---

## SEC-0001: AES-GCM nonce reuse on page overwrite

- **Status:** Closed
- **Severity:** Critical
- **File:** `src/encryption.zig:24-29`
- **Description:** `buildNonce` produces a deterministic nonce from `(page_id, file_id)`. When a page is updated and re-encrypted, the same nonce is reused with the same key. AES-GCM with reused (key, nonce) leaks XOR of plaintexts and breaks authenticity.
- **Acceptance Criteria:**
  - [x] Nonce includes a monotonically increasing component (e.g., page write count or LSN)
  - [ ] OR switch to AES-GCM-SIV (nonce-misuse resistant)
  - [x] Test verifies different ciphertext for same page content at different write counts
- **Resolution:** `buildNonce` now takes a `u24 write_count` parameter occupying nonce bytes 9-11. `encryptPage` and `decryptPage` pass it through. Tests verify different ciphertexts and wrong-count rejection.
- **Affected Files:** `src/encryption.zig`
- **Remediation:** Include LSN or write counter in nonce, or switch to nonce-misuse-resistant AEAD.

## SEC-0002: Path traversal in backup restore

- **Status:** Open
- **Severity:** Critical
- **File:** `src/backup.zig:199-210`
- **Description:** `restoreBackup` reads filenames from untrusted backup data and concatenates with `target_dir` via `allocPrint("{s}/{s}")` without sanitizing `..` components. A crafted backup can write files outside target directory.
- **Acceptance Criteria:**
  - [ ] Filename validated: no `..` components, no absolute paths, no path separators
  - [ ] OR resolved path verified to be under target_dir
  - [ ] Test with malicious filename (`../../../tmp/evil`) returns error
- **Affected Files:** `src/backup.zig`
- **Remediation:** Validate filename is a simple basename (no `/`, no `..`, not absolute).

## SEC-0003: No encryption key zeroization

- **Status:** Closed
- **Severity:** Critical
- **File:** `src/encryption.zig:15-19`, `src/config.zig:14`, `src/wal.zig:12`
- **Description:** Encryption key stored as plain `[32]u8` with no zeroization on deinit. Key persists in memory after engine close.
- **Acceptance Criteria:**
  - [x] `PageEncryption.deinit()` calls `std.crypto.secureZero` on key
  - [x] Engine close zeros key in GraphConfig
  - [x] Test verifies key memory is zeroed after deinit
- **Resolution:** `PageEncryption.deinit()` zeros key via `std.crypto.secureZero`. `GraphConfig.zeroKey()` zeros and nulls the optional key. `GraphEngine.close()` calls `config.zeroKey()` before freeing memory.
- **Affected Files:** `src/encryption.zig`, `src/engine.zig`, `src/config.zig`
- **Remediation:** Add deinit with `std.crypto.secureZero(u8, &self.key)`.

## SEC-0004: WAL records not checksum-verified during recovery

- **Status:** Open
- **Severity:** High
- **File:** `src/recovery.zig:138-158`
- **Description:** During recovery replay, WAL records are applied without verifying `rec.checksum == rec.computeChecksum()`. Corrupted WAL records silently corrupt the database.
- **Acceptance Criteria:**
  - [ ] Recovery verifies checksum before applying each WAL record
  - [ ] Records failing checksum are skipped with a warning/error
  - [ ] Test with corrupted WAL record verifies it is not applied
- **Affected Files:** `src/recovery.zig`

## SEC-0005: Backup integrity uses CRC32 not MAC

- **Status:** Open
- **Severity:** High
- **File:** `src/backup.zig:139-141, 163-165`
- **Description:** Backup files protected only by CRC32 (non-cryptographic). Attacker can forge valid CRC32 after modification.
- **Acceptance Criteria:**
  - [ ] When encryption key is present, backup uses HMAC-SHA256 or AEAD
  - [ ] When no encryption key, CRC32 is acceptable (integrity only, not authenticity)
  - [ ] Test verifies tampered backup with valid CRC32 is rejected when key present
- **Affected Files:** `src/backup.zig`
- **Remediation:** Add keyed MAC when encryption is enabled.

## SEC-0006: Recovery opens WAL without encryption key

- **Status:** Open
- **Severity:** High
- **File:** `src/recovery.zig:98-104`
- **Description:** WAL opened with empty config `.{}` during recovery. If WAL was written with encryption, recovery fails silently or produces garbage.
- **Acceptance Criteria:**
  - [ ] `Recovery.recover()` accepts encryption key parameter
  - [ ] Key is passed through to WAL init
  - [ ] Test verifies encrypted WAL can be recovered
- **Affected Files:** `src/recovery.zig`, `src/engine.zig`

## SEC-0007: Unbounded file read in backup restore

- **Status:** Open
- **Severity:** High
- **File:** `src/backup.zig:261-276`
- **Description:** `readFileAlloc` reads entire backup into memory based on `stat.size` with no upper bound. Maliciously large file causes OOM.
- **Acceptance Criteria:**
  - [ ] Maximum backup file size enforced (configurable, default reasonable limit)
  - [ ] Files exceeding limit return error
  - [ ] Test verifies rejection of oversized backup
- **Affected Files:** `src/backup.zig`, `src/config.zig`

## SEC-0008: deleteTree on user-influenced path

- **Status:** Open
- **Severity:** High
- **File:** `src/graph_dir.zig:77-79`
- **Description:** `GraphDir.delete()` calls `deleteTree(self.path)` where path includes caller-provided `data_dir`. No validation that path is within expected directory.
- **Acceptance Criteria:**
  - [ ] `delete()` validates path is within expected data directory
  - [ ] OR document that `data_dir` must be trusted input (library contract)
  - [ ] Test with path outside data_dir returns error (if validation added)
- **Affected Files:** `src/graph_dir.zig`

## SEC-0009: Unsafe @enumFromInt on disk data

- **Status:** Closed
- **Severity:** Medium
- **File:** `src/index_catalog.zig:172-173`, `src/prop_store.zig:308`, `src/recovery.zig:146`
- **Description:** `@enumFromInt` on bytes from disk is undefined behavior in ReleaseFast for invalid values. `wal_record.zig:96` and `property.zig:90` correctly use `std.meta.intToEnum`.
- **Acceptance Criteria:**
  - [x] All `@enumFromInt` on disk-read data replaced with `std.meta.intToEnum`
  - [x] Error returned on invalid enum values
  - [x] Test with invalid enum byte verifies error (not UB)
- **Affected Files:** `src/index_catalog.zig`, `src/prop_store.zig`, `src/recovery.zig`
- **Resolution:** Replaced all three `@enumFromInt` calls with `std.meta.intToEnum` + error propagation. Added tests for invalid IndexType, IndexState, and property Tag bytes.

## SEC-0010: No page_size validation on engine open

- **Status:** Open
- **Severity:** Medium
- **File:** `src/engine.zig:173-241`
- **Description:** `GraphEngine.open` uses `cfg.page_size` without verifying it matches `manifest.page_size`. Mismatch causes silent data corruption.
- **Acceptance Criteria:**
  - [ ] After recovery, assert `cfg.page_size == manifest.page_size`
  - [ ] Return error on mismatch
  - [ ] Test covers page_size mismatch scenario
- **Affected Files:** `src/engine.zig`

## SEC-0011: No file permissions set on created files

- **Status:** Closed
- **Severity:** Medium
- **File:** `src/file_manager.zig:58-61`, `src/graph_dir.zig:33-34`
- **Description:** All files created with default umask. On shared systems, store files may be world-readable.
- **Acceptance Criteria:**
  - [x] Store files created with mode 0o600 (owner read/write only)
  - [x] Directory created with mode 0o700
- **Affected Files:** `src/file_manager.zig`, `src/graph_dir.zig`
- **Resolution:** Set `.mode = 0o600` in all `createFile` calls. Added `dir.chmod(0o700)` after `makePath` for graph directories. Added permission verification tests.

## SEC-0012: Unsafe @ptrCast/@alignCast on page data

- **Status:** Closed
- **Severity:** Medium
- **File:** `src/node_store.zig:50,92`, `src/page.zig:78`, `src/adj_store.zig:227,239`
- **Description:** `@ptrCast(@alignCast(...))` on page buffer data. Buffer pool uses 4096-aligned allocation so in-pool casts are safe, but `page.zig:78` (`headerFromBytes`) could fail alignment if called with stack-allocated `[32]u8`.
- **Acceptance Criteria:**
  - [x] `headerFromBytes` uses `std.mem.bytesToValue` instead of pointer cast
  - [x] OR document alignment requirement in function doc comment
- **Affected Files:** `src/page.zig`, `src/node_store.zig`
- **Resolution:** Replaced `headerFromBytes` with `std.mem.bytesToValue` returning a value instead of a pointer. Replaced `@ptrCast/@alignCast` in `node_store.zig` getNode and deleteNode with `bytesToValue` for alignment-safe access. Added test for unaligned input.

## SEC-0013: Integer truncation in backup on 32-bit

- **Status:** Open
- **Severity:** Medium
- **File:** `src/backup.zig:191-195`
- **Description:** `file_size` is `u64` but used as `usize` slice index. On 32-bit targets, truncation could occur.
- **Acceptance Criteria:**
  - [ ] Explicit check that `file_size` fits in `usize` before use as index
  - [ ] Return error if file_size exceeds `std.math.maxInt(usize)`
- **Affected Files:** `src/backup.zig`
