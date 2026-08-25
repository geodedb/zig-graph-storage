// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

pub const StorageError = error{
    // Corruption / integrity
    CorruptedPage,
    CorruptedManifest,
    CorruptedWal,
    ChecksumMismatch,
    UuidMismatch,
    VersionMismatch,
    HmacMismatch,
    DataCorruption,
    ManifestAuthFailed,

    // Not-found
    PageNotFound,
    NodeNotFound,
    EdgeNotFound,
    PropertyNotFound,
    GraphNotFound,
    IndexNotFound,

    // Already-exists / duplicate
    GraphAlreadyExists,

    // Capacity / limits
    BufferPoolFull,
    WalFull,
    DiskFull,
    BackupTooLarge,
    FileTooLarge,
    WriteCountExhausted,
    PropertyKeyTooLong,
    /// The property VALUE is too large to store: it exceeds
    /// `GraphConfig.max_property_value_bytes` (the sanity cap that bounds WAL
    /// record size and per-op memory), or it cannot be represented at all for
    /// the configured page size. Distinct from `PropertyKeyTooLong`, which is
    /// reserved for a genuinely oversized KEY.
    PropertyValueTooLarge,
    WalRecordTooLarge,

    // Contract / usage (caller violated a precondition)
    PagePinned,
    InvalidPageId,
    ReadOnlyMode,
    PageSizeMismatch,
    NoPagerRegistered,
    InvalidGraphPath,
    GraphDirectoryMissing,
    CrossShardEdgeUnsupported,
    NotCrossShard,

    // Input / format parsing
    InvalidMagic,
    InvalidMagicLength,
    InvalidFormat,
    InvalidData,
    InvalidBufferSize,
    BufferTooSmall,
    UnexpectedEndOfInput,
    UnexpectedEndOfFile,
    UnexpectedEof,
    IncompatibleVersion,
    /// A property value was decoded straight from its on-page bytes while it
    /// is an OVERFLOW STUB (tag 7) that only references the real value in the
    /// var store. Stubs must be resolved by the prop-store read path before
    /// decoding; reaching `property.decode` with one is a caller/plumbing bug,
    /// never valid input.
    UnresolvedOverflowValue,

    // WAL
    WalCorrupted,
    WalSegmentMissing,

    // Transaction
    TxnNotFound,
    TxnAlreadyCommitted,
    TxnAlreadyAborted,

    // Encryption / decryption
    EncryptionFailed,
    DecryptionFailed,
    InvalidKey,
    EncryptionKeyRequired,

    // Backup / restore
    LegacyBackupRestoreDisabled,
    ExpectedGraphUuidRequired,
    InvalidBackupFilename,

    // Shard manifest / routing
    NoManifest,
    InvalidShardManifest,
    InvalidShardUuid,
    ShardAlgorithmMismatch,
    ShardCountMismatch,
    ShardManifestVersionMismatch,

    // Index subsystem
    IndexBuildFailed,
    IndexCorrupted,
    EdgeIndexFileNotOpen,
    LabelIndexFileNotOpen,
    PropertyIndexFileNotOpen,

    // Graph traversal
    CircularChainDetected,

    // 2PC / distributed protocol
    InvalidPreparePayload,
    InvalidDecisionPayload,

    // Migration
    MigrationFailed,

    // I/O / memory (own contract surface — std errors that storage code owns)
    IoError,
    OutOfMemory,
};

// ============================================================================
// Unit Tests
// ============================================================================

test "StorageError variants can be used in error unions" {
    const TestResult = StorageError!u64;

    const ok_val: TestResult = 42;
    try std.testing.expectEqual(@as(u64, 42), ok_val);

    const err_val: TestResult = StorageError.CorruptedPage;
    try std.testing.expectError(StorageError.CorruptedPage, err_val);
}

test "StorageError covers all categories" {
    // Corruption errors
    try std.testing.expectError(StorageError.CorruptedPage, @as(StorageError!void, StorageError.CorruptedPage));
    try std.testing.expectError(StorageError.CorruptedManifest, @as(StorageError!void, StorageError.CorruptedManifest));
    try std.testing.expectError(StorageError.CorruptedWal, @as(StorageError!void, StorageError.CorruptedWal));
    try std.testing.expectError(StorageError.ChecksumMismatch, @as(StorageError!void, StorageError.ChecksumMismatch));

    // Not-found errors
    try std.testing.expectError(StorageError.PageNotFound, @as(StorageError!void, StorageError.PageNotFound));
    try std.testing.expectError(StorageError.NodeNotFound, @as(StorageError!void, StorageError.NodeNotFound));
    try std.testing.expectError(StorageError.EdgeNotFound, @as(StorageError!void, StorageError.EdgeNotFound));

    // Transaction errors
    try std.testing.expectError(StorageError.TxnNotFound, @as(StorageError!void, StorageError.TxnNotFound));
    try std.testing.expectError(StorageError.TxnAlreadyCommitted, @as(StorageError!void, StorageError.TxnAlreadyCommitted));

    // Encryption errors
    try std.testing.expectError(StorageError.EncryptionFailed, @as(StorageError!void, StorageError.EncryptionFailed));
    try std.testing.expectError(StorageError.DecryptionFailed, @as(StorageError!void, StorageError.DecryptionFailed));
    try std.testing.expectError(StorageError.InvalidKey, @as(StorageError!void, StorageError.InvalidKey));

    // I/O errors
    try std.testing.expectError(StorageError.DiskFull, @as(StorageError!void, StorageError.DiskFull));
    try std.testing.expectError(StorageError.IoError, @as(StorageError!void, StorageError.IoError));
    try std.testing.expectError(StorageError.OutOfMemory, @as(StorageError!void, StorageError.OutOfMemory));

    // Index errors
    try std.testing.expectError(StorageError.IndexNotFound, @as(StorageError!void, StorageError.IndexNotFound));
    try std.testing.expectError(StorageError.IndexBuildFailed, @as(StorageError!void, StorageError.IndexBuildFailed));
    try std.testing.expectError(StorageError.IndexCorrupted, @as(StorageError!void, StorageError.IndexCorrupted));
}

// Coherence guard: asserts that every ad-hoc error returned by library code
// is a member of StorageError.  Add a line here whenever you add a new
// `return error.Foo` in src/ so the discrepancy is caught at compile time.
// Uses std.meta.fieldNames (the correct introspection API for error sets).
test "StorageError coherence guard — ad-hoc errors used by library code are declared" {
    // Helper that fails at comptime if `name` is not a member of StorageError.
    const assertMember = struct {
        fn check(comptime name: []const u8) void {
            comptime {
                var found = false;
                for (std.meta.fieldNames(StorageError)) |field| {
                    if (std.mem.eql(u8, field, name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) @compileError("StorageError is missing member: " ++ name);
            }
        }
    }.check;

    // Corruption / integrity
    assertMember("DataCorruption");
    assertMember("HmacMismatch");
    assertMember("ManifestAuthFailed");

    // Input / format parsing
    assertMember("InvalidData");
    assertMember("InvalidBufferSize");
    assertMember("InvalidMagicLength");
    assertMember("BufferTooSmall");
    assertMember("UnexpectedEndOfInput");
    assertMember("UnexpectedEndOfFile");
    assertMember("UnexpectedEof");
    assertMember("UnresolvedOverflowValue");

    // Capacity / limits
    assertMember("BackupTooLarge");
    assertMember("FileTooLarge");
    assertMember("WriteCountExhausted");
    assertMember("PropertyKeyTooLong");
    assertMember("PropertyValueTooLarge");
    assertMember("WalRecordTooLarge");

    // Contract / usage
    assertMember("ReadOnlyMode");
    assertMember("PageSizeMismatch");
    assertMember("NoPagerRegistered");
    assertMember("InvalidGraphPath");
    assertMember("CrossShardEdgeUnsupported");
    assertMember("NotCrossShard");

    // Manifest / shard routing
    assertMember("NoManifest");
    assertMember("InvalidShardManifest");
    assertMember("InvalidShardUuid");
    assertMember("ShardAlgorithmMismatch");
    assertMember("ShardCountMismatch");
    assertMember("ShardManifestVersionMismatch");

    // Backup / restore
    assertMember("LegacyBackupRestoreDisabled");
    assertMember("EncryptionKeyRequired");
    assertMember("ExpectedGraphUuidRequired");
    assertMember("InvalidBackupFilename");

    // Index subsystem
    assertMember("EdgeIndexFileNotOpen");
    assertMember("LabelIndexFileNotOpen");
    assertMember("PropertyIndexFileNotOpen");

    // Graph traversal
    assertMember("CircularChainDetected");

    // 2PC / distributed protocol
    assertMember("InvalidPreparePayload");
    assertMember("InvalidDecisionPayload");
}

test {
    std.testing.refAllDecls(@This());
}
