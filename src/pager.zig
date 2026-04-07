// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const page_mod = @import("page.zig");
const types = @import("types.zig");
const encryption_mod = @import("encryption.zig");

const PageId = types.PageId;
const FileId = types.FileId;
const PageHeader = page_mod.PageHeader;
const PAGE_HEADER_SIZE = page_mod.PAGE_HEADER_SIZE;
const PageEncryption = encryption_mod.PageEncryption;

pub const PagerError = error{
    ChecksumMismatch,
    PageNotFound,
    InvalidBufferSize,
    DecryptionFailed,
    WriteCountExhausted,
};

pub const Pager = struct {
    file: std.fs.File,
    page_size: u32,
    encryption: ?PageEncryption = null,
    file_id: FileId = .nodes,

    pub fn init(file: std.fs.File, page_size: u32) Pager {
        return .{ .file = file, .page_size = page_size };
    }

    /// Read a page from disk into the provided buffer.
    /// Buffer must be exactly page_size bytes.
    /// When encryption is enabled, decrypts the page body after reading.
    /// Validates the page checksum after reading (and decrypting).
    /// Returns error.ChecksumMismatch if checksum doesn't match.
    /// Returns error.PageNotFound if reading beyond file end (short read).
    pub fn readPage(self: *const Pager, page_id: PageId, buf: []u8) !void {
        if (buf.len != self.page_size) return error.InvalidBufferSize;

        const offset: u64 = page_id * @as(u64, self.page_size);
        const bytes_read = try self.file.preadAll(buf, offset);

        if (bytes_read < self.page_size) return error.PageNotFound;

        // Check if the header is all zeros (fresh/uninitialized page).
        if (std.mem.readInt(u128, buf[0..16], .little) == 0 and
            std.mem.readInt(u128, buf[16..32], .little) == 0) return;

        // Decrypt page body if encryption is enabled.
        // AES-GCM provides authenticated integrity, so CRC32C is redundant
        // when encryption is active -- skip it to avoid false mismatches
        // (the auth tag occupies body tail bytes that differ after round-trip).
        if (self.encryption) |enc| {
            const write_count = page_mod.readWriteCount(buf);
            enc.decryptPage(buf, page_id, @intFromEnum(self.file_id), write_count) catch {
                return error.DecryptionFailed;
            };
        } else {
            // Plaintext mode: validate CRC32C checksum
            const body = buf[PAGE_HEADER_SIZE..];
            const stored_checksum = std.mem.readInt(u32, buf[16..20], .little);
            const computed_checksum = page_mod.computeChecksum(body);

            if (stored_checksum != computed_checksum) return error.ChecksumMismatch;
        }
    }

    /// Write a page to disk from the provided buffer.
    /// Buffer must be exactly page_size bytes.
    /// Computes and sets the checksum in the header before writing.
    /// When encryption is enabled, encrypts the page body after checksumming.
    pub fn writePage(self: *const Pager, page_id: PageId, buf: []u8) !void {
        if (buf.len != self.page_size) return error.InvalidBufferSize;

        // When encryption is active, AES-GCM provides authenticated integrity,
        // so CRC32C is redundant. Only compute CRC for plaintext mode.
        if (self.encryption) |enc| {
            // Increment write_count to ensure unique AES-GCM nonce per write
            const current_wc = page_mod.readWriteCount(buf);
            if (current_wc == std.math.maxInt(u24)) return error.WriteCountExhausted;
            const new_wc = current_wc + 1;
            page_mod.writeWriteCount(buf, new_wc);
            enc.encryptPage(buf, page_id, @intFromEnum(self.file_id), new_wc);
        } else {
            // Plaintext mode: compute CRC32C over body and write into header
            const body = buf[PAGE_HEADER_SIZE..];
            const checksum = page_mod.computeChecksum(body);
            std.mem.writeInt(u32, buf[16..20], checksum, .little);
        }

        // Write page at the correct offset
        const offset: u64 = page_id * @as(u64, self.page_size);
        try self.file.pwriteAll(buf, offset);
    }

    /// Get the number of pages currently in the file (based on file size).
    pub fn pageCount(self: *const Pager) !u64 {
        const stat = try self.file.stat();
        return stat.size / self.page_size;
    }

    /// Sync file to disk (fdatasync).
    pub fn sync(self: *const Pager) !void {
        try self.file.sync();
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

fn createTempFile() !std.fs.File {
    return std.fs.cwd().createFile(".test_pager_tmp", .{
        .read = true,
        .truncate = true,
    });
}

fn cleanupTempFile(file: std.fs.File) void {
    file.close();
    std.fs.cwd().deleteFile(".test_pager_tmp") catch {};
}

test "write then read round-trip preserves page contents" {
    const file = try createTempFile();
    defer cleanupTempFile(file);

    const page_size: u32 = 4096;
    const pager = Pager.init(file, page_size);

    // Prepare a page with known data
    var write_buf: [4096]u8 = undefined;
    @memset(&write_buf, 0);

    // Set up a header with page_id = 0
    const header = page_mod.initHeader(0, .node_data, page_size);
    const header_bytes = page_mod.headerToBytes(&header);
    @memcpy(write_buf[0..PAGE_HEADER_SIZE], header_bytes);

    // Write known pattern in body
    for (write_buf[PAGE_HEADER_SIZE..]) |*byte| {
        byte.* = 0xAB;
    }

    try pager.writePage(0, &write_buf);

    // Read it back
    var read_buf: [4096]u8 = undefined;
    @memset(&read_buf, 0);
    try pager.readPage(0, &read_buf);

    // Verify body matches
    try testing.expectEqualSlices(u8, write_buf[PAGE_HEADER_SIZE..], read_buf[PAGE_HEADER_SIZE..]);

    // Verify header fields preserved (page_id, page_type)
    // Read fields directly to avoid alignment issues with stack buffers
    const read_page_id = std.mem.readInt(u64, read_buf[0..8], .little);
    try testing.expectEqual(@as(u64, 0), read_page_id);
    try testing.expectEqual(@intFromEnum(page_mod.PageType.node_data), read_buf[20]);
}

test "checksum validation detects corruption" {
    const file = try createTempFile();
    defer cleanupTempFile(file);

    const page_size: u32 = 4096;
    const pager = Pager.init(file, page_size);

    // Write a valid page
    var buf: [4096]u8 = undefined;
    @memset(&buf, 0);
    const header = page_mod.initHeader(0, .node_data, page_size);
    const header_bytes = page_mod.headerToBytes(&header);
    @memcpy(buf[0..PAGE_HEADER_SIZE], header_bytes);
    buf[PAGE_HEADER_SIZE] = 0x42; // some data in the body

    try pager.writePage(0, &buf);

    // Corrupt one byte in the body directly on disk
    // (byte at offset PAGE_HEADER_SIZE + 1, which is in the body)
    var corrupt_byte: [1]u8 = .{0xFF};
    _ = try file.pwriteAll(&corrupt_byte, PAGE_HEADER_SIZE + 1);

    // Reading should detect corruption
    var read_buf: [4096]u8 = undefined;
    const result = pager.readPage(0, &read_buf);
    try testing.expectError(error.ChecksumMismatch, result);
}

test "empty page (all zeros) is handled gracefully" {
    const file = try createTempFile();
    defer cleanupTempFile(file);

    const page_size: u32 = 4096;
    const pager = Pager.init(file, page_size);

    // Write an all-zero page directly to the file to simulate uninitialized space
    var zero_buf: [4096]u8 = undefined;
    @memset(&zero_buf, 0);
    _ = try file.pwriteAll(&zero_buf, 0);

    // Reading should succeed (all-zero page is treated as empty)
    var read_buf: [4096]u8 = undefined;
    try pager.readPage(0, &read_buf);

    // Verify it's all zeros
    for (read_buf) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "pageCount returns correct number of pages" {
    const file = try createTempFile();
    defer cleanupTempFile(file);

    const page_size: u32 = 4096;
    const pager = Pager.init(file, page_size);

    // Initially empty
    try testing.expectEqual(@as(u64, 0), try pager.pageCount());

    // Write 3 pages
    var buf: [4096]u8 = undefined;
    @memset(&buf, 0);

    for (0..3) |i| {
        const header = page_mod.initHeader(@intCast(i), .node_data, page_size);
        const header_bytes = page_mod.headerToBytes(&header);
        @memcpy(buf[0..PAGE_HEADER_SIZE], header_bytes);
        try pager.writePage(@intCast(i), &buf);
    }

    try testing.expectEqual(@as(u64, 3), try pager.pageCount());
}

test "multiple pages with different data" {
    const file = try createTempFile();
    defer cleanupTempFile(file);

    const page_size: u32 = 4096;
    const pager = Pager.init(file, page_size);

    // Write 3 pages with different fill patterns
    const patterns = [_]u8{ 0x11, 0x22, 0x33 };

    for (patterns, 0..) |pattern, i| {
        var buf: [4096]u8 = undefined;
        @memset(&buf, 0);
        const header = page_mod.initHeader(@intCast(i), .node_data, page_size);
        const header_bytes = page_mod.headerToBytes(&header);
        @memcpy(buf[0..PAGE_HEADER_SIZE], header_bytes);

        // Fill body with the pattern
        @memset(buf[PAGE_HEADER_SIZE..], pattern);

        try pager.writePage(@intCast(i), &buf);
    }

    // Read them back and verify each has the correct data
    for (patterns, 0..) |pattern, i| {
        var read_buf: [4096]u8 = undefined;
        try pager.readPage(@intCast(i), &read_buf);

        // Verify body has the correct pattern
        for (read_buf[PAGE_HEADER_SIZE..]) |byte| {
            try testing.expectEqual(pattern, byte);
        }

        // Verify page_id in header (read directly to avoid alignment issues)
        const read_page_id = std.mem.readInt(u64, read_buf[0..8], .little);
        try testing.expectEqual(@as(u64, @intCast(i)), read_page_id);
    }
}

test "readPage returns PageNotFound for page beyond file end" {
    const file = try createTempFile();
    defer cleanupTempFile(file);

    const page_size: u32 = 4096;
    const pager = Pager.init(file, page_size);

    // File is empty, reading page 0 should fail
    var buf: [4096]u8 = undefined;
    const result = pager.readPage(0, &buf);
    try testing.expectError(error.PageNotFound, result);
}

test "readPage rejects buffer with wrong size" {
    const file = try createTempFile();
    defer cleanupTempFile(file);

    const page_size: u32 = 4096;
    const pager = Pager.init(file, page_size);

    var small_buf: [100]u8 = undefined;
    const result = pager.readPage(0, &small_buf);
    try testing.expectError(error.InvalidBufferSize, result);
}

test "SEC-0015: encrypted page writes produce different ciphertexts (no nonce reuse)" {
    const file = try createTempFile();
    defer cleanupTempFile(file);

    const page_size: u32 = 4096;
    const key = [_]u8{0x42} ** 32;
    var enc = encryption_mod.PageEncryption.init(key);

    var pager = Pager.init(file, page_size);
    pager.encryption = enc;

    // Write the same page content twice
    var write_buf1: [4096]u8 = undefined;
    @memset(&write_buf1, 0);
    const header = page_mod.initHeader(0, .node_data, page_size);
    const header_bytes = page_mod.headerToBytes(&header);
    @memcpy(write_buf1[0..PAGE_HEADER_SIZE], header_bytes);
    @memset(write_buf1[PAGE_HEADER_SIZE..], 0xAB);

    try pager.writePage(0, &write_buf1);

    // Read the raw ciphertext from disk
    var ct1: [4096]u8 = undefined;
    _ = try file.preadAll(&ct1, 0);

    // Prepare the same content again (reset write_count to 0 as if fresh page)
    @memset(&write_buf1, 0);
    @memcpy(write_buf1[0..PAGE_HEADER_SIZE], header_bytes);
    @memset(write_buf1[PAGE_HEADER_SIZE..], 0xAB);
    // Set write_count to 1 to simulate the page having been written once already
    page_mod.writeWriteCount(&write_buf1, 1);

    try pager.writePage(0, &write_buf1);

    // Read the raw ciphertext from disk again
    var ct2: [4096]u8 = undefined;
    _ = try file.preadAll(&ct2, 0);

    // The encrypted bodies must differ (different nonce due to incremented write_count)
    try testing.expect(!std.mem.eql(u8, ct1[PAGE_HEADER_SIZE..], ct2[PAGE_HEADER_SIZE..]));

    // Both should still be readable (decrypt correctly)
    var read_buf: [4096]u8 = undefined;
    try pager.readPage(0, &read_buf);

    _ = &enc;
}

test "GAP-0036: encrypted writes fail closed when the per-page nonce counter is exhausted" {
    const file = try createTempFile();
    defer cleanupTempFile(file);

    const page_size: u32 = 4096;
    const key = [_]u8{0x24} ** 32;

    var pager = Pager.init(file, page_size);
    pager.encryption = encryption_mod.PageEncryption.init(key);

    var write_buf: [4096]u8 = undefined;
    @memset(&write_buf, 0);
    const header = page_mod.initHeader(0, .node_data, page_size);
    const header_bytes = page_mod.headerToBytes(&header);
    @memcpy(write_buf[0..PAGE_HEADER_SIZE], header_bytes);
    page_mod.writeWriteCount(&write_buf, std.math.maxInt(u24));

    try testing.expectError(error.WriteCountExhausted, pager.writePage(0, &write_buf));
}

test {
    std.testing.refAllDecls(@This());
}
