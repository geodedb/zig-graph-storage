// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

pub const StorageError = error{
    CorruptedPage,
    CorruptedManifest,
    CorruptedWal,
    ChecksumMismatch,
    UuidMismatch,
    VersionMismatch,
    PageNotFound,
    NodeNotFound,
    EdgeNotFound,
    PropertyNotFound,
    BufferPoolFull,
    PagePinned,
    InvalidPageId,
    WalFull,
    WalCorrupted,
    WalSegmentMissing,
    TxnNotFound,
    TxnAlreadyCommitted,
    TxnAlreadyAborted,
    GraphNotFound,
    GraphAlreadyExists,
    GraphDirectoryMissing,
    EncryptionFailed,
    DecryptionFailed,
    InvalidKey,
    DiskFull,
    IoError,
    OutOfMemory,
    InvalidMagic,
    InvalidFormat,
    MigrationFailed,
    IndexNotFound,
    IndexBuildFailed,
    IndexCorrupted,
    IncompatibleVersion,
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

test {
    std.testing.refAllDecls(@This());
}
