# Security Gap Analysis

**Last updated:** 2026-03-25
**Source:** Full Codebase Audit (docs/AUDIT_REPORT.md)

## Summary

| Status | Count |
|--------|-------|
| Open | 0 |
| Closed | 13 |
| Won't Do | 0 |
| Blocked | 0 |

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
