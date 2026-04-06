// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const types = @import("types.zig");

pub const PageId = types.PageId;
pub const Lsn = types.Lsn;

pub const PAGE_HEADER_SIZE: u32 = 32;
pub const DEFAULT_PAGE_SIZE: u32 = 8192;

pub const PageType = enum(u8) {
    free = 0,
    node_data = 1,
    adj_block = 2,
    prop_slotted = 3,
    var_overflow = 4,
    free_bitmap = 5,
    label_posting = 6,
    btree_internal = 7,
    btree_leaf = 8,
    manifest = 9,
};

pub const PageFlags = packed struct(u8) {
    dirty: bool = false,
    encrypted: bool = false,
    compressed: bool = false,
    _reserved: u5 = 0,
};

pub const PageHeader = extern struct {
    page_id: u64, // 8 bytes
    lsn: u64, // 8 bytes
    checksum: u32, // 4 bytes (CRC32C over body)
    page_type: u8, // 1 byte (PageType value)
    flags: u8, // 1 byte (PageFlags as u8)
    item_count: u16, // 2 bytes
    free_start: u16, // 2 bytes (for slotted pages)
    free_end: u16, // 2 bytes (for slotted pages)
    write_count: [3]u8, // 3 bytes (u24 LE, monotonic counter for AES-GCM nonce)
    _reserved: [1]u8, // 1 byte padding
};

comptime {
    if (@sizeOf(PageHeader) != 32) @compileError("PageHeader must be exactly 32 bytes");
}

/// Compute CRC32C checksum over body bytes.
pub fn computeChecksum(body: []const u8) u32 {
    return std.hash.crc.Crc32Iscsi.hash(body);
}

/// Create a zeroed header with the given page_id and page_type.
/// free_end is set to page_size - PAGE_HEADER_SIZE.
pub fn initHeader(page_id: PageId, page_type: PageType, page_size: u32) PageHeader {
    std.debug.assert(page_size >= PAGE_HEADER_SIZE);
    return PageHeader{
        .page_id = page_id,
        .lsn = 0,
        .checksum = 0,
        .page_type = @intFromEnum(page_type),
        .flags = 0,
        .item_count = 0,
        .free_start = 0,
        .free_end = @intCast(page_size - PAGE_HEADER_SIZE),
        .write_count = .{ 0, 0, 0 },
        ._reserved = .{ 0 },
    };
}

/// Cast a PageHeader pointer to a byte array pointer for I/O.
pub fn headerToBytes(header: *const PageHeader) *const [32]u8 {
    return @ptrCast(header);
}

/// Byte offset of write_count within the page header (after free_end at offset 28).
pub const WRITE_COUNT_OFFSET: usize = 28;

/// Read the write_count (u24 LE) directly from a page buffer without full header decode.
pub fn readWriteCount(buf: []const u8) u24 {
    return std.mem.readInt(u24, buf[WRITE_COUNT_OFFSET..][0..3], .little);
}

/// Write the write_count (u24 LE) directly into a page buffer.
pub fn writeWriteCount(buf: []u8, count: u24) void {
    std.mem.writeInt(u24, buf[WRITE_COUNT_OFFSET..][0..3], count, .little);
}

/// Decode a PageHeader from a 32-byte array.
/// Uses bytesToValue for alignment-safe reading -- the input bytes
/// do not need to satisfy PageHeader's alignment requirement.
pub fn headerFromBytes(bytes: *const [32]u8) PageHeader {
    return std.mem.bytesToValue(PageHeader, bytes);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "PageHeader is exactly 32 bytes" {
    // comptime assert above covers this, but verify at runtime too
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(PageHeader));
    try std.testing.expectEqual(@as(u32, 32), PAGE_HEADER_SIZE);
}

test "computeChecksum returns consistent value for same input" {
    const data = "hello world";
    const c1 = computeChecksum(data);
    const c2 = computeChecksum(data);
    try std.testing.expectEqual(c1, c2);
}

test "computeChecksum returns different value for different input" {
    const c1 = computeChecksum("hello world");
    const c2 = computeChecksum("hello worle");
    try std.testing.expect(c1 != c2);
}

test "initHeader sets correct default values" {
    const header = initHeader(42, .node_data, DEFAULT_PAGE_SIZE);
    try std.testing.expectEqual(@as(u64, 42), header.page_id);
    try std.testing.expectEqual(@as(u64, 0), header.lsn);
    try std.testing.expectEqual(@as(u32, 0), header.checksum);
    try std.testing.expectEqual(@intFromEnum(PageType.node_data), header.page_type);
    try std.testing.expectEqual(@as(u8, 0), header.flags);
    try std.testing.expectEqual(@as(u16, 0), header.item_count);
    try std.testing.expectEqual(@as(u16, 0), header.free_start);
    try std.testing.expectEqual(@as(u16, DEFAULT_PAGE_SIZE - PAGE_HEADER_SIZE), header.free_end);
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, header.write_count);
    try std.testing.expectEqual([1]u8{0}, header._reserved);
}

test "headerToBytes / headerFromBytes round-trip preserves all fields" {
    const original = initHeader(99, .btree_leaf, 4096);
    const bytes = headerToBytes(&original);
    const restored = headerFromBytes(bytes);

    try std.testing.expectEqual(original.page_id, restored.page_id);
    try std.testing.expectEqual(original.lsn, restored.lsn);
    try std.testing.expectEqual(original.checksum, restored.checksum);
    try std.testing.expectEqual(original.page_type, restored.page_type);
    try std.testing.expectEqual(original.flags, restored.flags);
    try std.testing.expectEqual(original.item_count, restored.item_count);
    try std.testing.expectEqual(original.free_start, restored.free_start);
    try std.testing.expectEqual(original.free_end, restored.free_end);
    try std.testing.expectEqual(original.write_count, restored.write_count);
    try std.testing.expectEqual(original._reserved, restored._reserved);
}

test "corruption detection: checksum mismatch after body modification" {
    var body = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const checksum_before = computeChecksum(&body);

    // Corrupt one byte
    body[3] = 0xFF;
    const checksum_after = computeChecksum(&body);

    try std.testing.expect(checksum_before != checksum_after);
}

test "headerFromBytes works with unaligned byte array" {
    // Create a buffer at an odd offset to force misalignment
    var buf: [33]u8 = undefined;
    @memset(&buf, 0);
    // Write a header starting at offset 1 (guaranteed unaligned for any >1 alignment)
    const original = initHeader(7, .prop_slotted, 4096);
    const header_bytes = headerToBytes(&original);
    @memcpy(buf[1..][0..32], header_bytes);

    // headerFromBytes should handle this without a crash
    const restored = headerFromBytes(buf[1..][0..32]);
    try std.testing.expectEqual(original.page_id, restored.page_id);
    try std.testing.expectEqual(original.page_type, restored.page_type);
    try std.testing.expectEqual(original.free_end, restored.free_end);
}

test {
    std.testing.refAllDecls(@This());
}
