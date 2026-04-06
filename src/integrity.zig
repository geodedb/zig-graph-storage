// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const page_mod = @import("page.zig");
const manifest_mod = @import("manifest.zig");

const Manifest = manifest_mod.Manifest;
const PAGE_HEADER_SIZE = page_mod.PAGE_HEADER_SIZE;

pub const Integrity = struct {
    /// Verify a page buffer's checksum. The stored checksum in the header
    /// (bytes 16..20, little-endian u32) must match the CRC32C computed
    /// over the body (everything after the 32-byte header).
    /// Returns true if valid, false if corrupted.
    /// An all-zero header is considered valid (uninitialized page).
    pub fn verifyPage(page_buf: []const u8) bool {
        if (page_buf.len <= PAGE_HEADER_SIZE) return false;

        // Check if the header is all zeros (uninitialized page) — only checks
        // the 32-byte header instead of the full page buffer.
        if (std.mem.readInt(u128, page_buf[0..16], .little) == 0 and
            std.mem.readInt(u128, page_buf[16..32], .little) == 0) return true;

        const body = page_buf[PAGE_HEADER_SIZE..];
        const stored_checksum = std.mem.readInt(u32, page_buf[16..20], .little);
        const computed_checksum = page_mod.computeChecksum(body);

        return stored_checksum == computed_checksum;
    }

    /// Verify a manifest's integrity by serializing it and checking that
    /// the round-trip produces valid data (magic + CRC32 pass).
    pub fn verifyManifest(m: *const Manifest, allocator: std.mem.Allocator) bool {
        const data = m.serialize(allocator) catch return false;
        defer allocator.free(data);

        // Attempt deserialization which validates magic + CRC32
        _ = Manifest.deserialize(allocator, data) catch return false;
        return true;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;
const test_page_size: u32 = 4096;

test "valid page passes verification" {
    const page_size = test_page_size;
    var buf: [test_page_size]u8 = undefined;
    @memset(&buf, 0);

    // Set up header
    const header = page_mod.initHeader(0, .node_data, page_size);
    const header_bytes = page_mod.headerToBytes(&header);
    @memcpy(buf[0..PAGE_HEADER_SIZE], header_bytes);

    // Write known body data
    @memset(buf[PAGE_HEADER_SIZE..], 0xAB);

    // Compute and store checksum
    const body = buf[PAGE_HEADER_SIZE..];
    const checksum = page_mod.computeChecksum(body);
    std.mem.writeInt(u32, buf[16..20], checksum, .little);

    try testing.expect(Integrity.verifyPage(&buf));
}

test "corrupted page fails verification" {
    const page_size = test_page_size;
    var buf: [test_page_size]u8 = undefined;
    @memset(&buf, 0);

    // Set up header
    const header = page_mod.initHeader(0, .node_data, page_size);
    const header_bytes = page_mod.headerToBytes(&header);
    @memcpy(buf[0..PAGE_HEADER_SIZE], header_bytes);

    // Write known body data and compute checksum
    @memset(buf[PAGE_HEADER_SIZE..], 0xAB);
    const checksum = page_mod.computeChecksum(buf[PAGE_HEADER_SIZE..]);
    std.mem.writeInt(u32, buf[16..20], checksum, .little);

    // Corrupt a body byte
    buf[PAGE_HEADER_SIZE + 10] = 0xFF;

    try testing.expect(!Integrity.verifyPage(&buf));
}

test "all-zero page passes verification (uninitialized)" {
    var buf: [test_page_size]u8 = undefined;
    @memset(&buf, 0);
    try testing.expect(Integrity.verifyPage(&buf));
}

test "buffer too small fails verification" {
    var buf: [16]u8 = undefined;
    @memset(&buf, 0);
    try testing.expect(!Integrity.verifyPage(&buf));
}

test "valid manifest passes verification" {
    const m = Manifest{
        .counter = 10,
        .next_node_id = 100,
    };
    try testing.expect(Integrity.verifyManifest(&m, testing.allocator));
}

test "manifest verification round-trips correctly" {
    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0xAB);

    const m = Manifest{
        .graph_uuid = uuid,
        .counter = 42,
        .next_node_id = 500,
        .next_edge_id = 600,
    };
    try testing.expect(Integrity.verifyManifest(&m, testing.allocator));
}

test {
    std.testing.refAllDecls(@This());
}
