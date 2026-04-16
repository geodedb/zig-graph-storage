// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const Crc32 = std.hash.crc.Crc32Iscsi;
const owner_only_file_mode = 0o600;

pub const MANIFEST_MAGIC: [8]u8 = .{ 'G', 'E', 'O', 'M', 'N', 'F', '0', '1' };
pub const MANIFEST_VERSION: u32 = 2;

/// V1 used a 40-byte NodeRec with label_set: u32 bitmap.
/// V2 uses a 48-byte NodeRec with label_head: u64 + label_count: u16.
/// Migration from V1 to V2 requires recreating the data directory.
pub const MANIFEST_VERSION_V1: u32 = 1;

/// Size of the serialized manifest in bytes:
/// magic(8) + fields (see below) + CRC32(4)
const FIELD_SIZE: usize = 4 + 16 + 4 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 4 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 8; // = 148
const SERIALIZED_SIZE: usize = 8 + FIELD_SIZE + 4; // magic + fields + crc = 160

pub const Manifest = struct {
    format_version: u32 = MANIFEST_VERSION,
    graph_uuid: [16]u8 = [_]u8{0} ** 16,
    page_size: u32 = 8192,
    counter: u64 = 0,
    last_checkpoint_lsn: u64 = 0,
    node_high_water: u64 = 0,
    edge_high_water: u64 = 0,
    next_node_id: u64 = 1,
    next_edge_id: u64 = 1,
    next_txn_id: u64 = 1,
    label_count: u32 = 0,
    nodes_pages: u64 = 0,
    adj_out_pages: u64 = 0,
    adj_in_pages: u64 = 0,
    props_pages: u64 = 0,
    var_pages: u64 = 0,
    free_pages: u64 = 0,
    node_count: u64 = 0,
    edge_count: u64 = 0,

    /// Serialize to bytes: magic(8) + all fields in little-endian + CRC32(4).
    pub fn serialize(self: *const Manifest, allocator: Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, SERIALIZED_SIZE);
        errdefer allocator.free(buf);

        var pos: usize = 0;

        // Magic
        @memcpy(buf[pos..][0..8], &MANIFEST_MAGIC);
        pos += 8;

        // Fields in order
        writeU32(buf, &pos, self.format_version);
        @memcpy(buf[pos..][0..16], &self.graph_uuid);
        pos += 16;
        writeU32(buf, &pos, self.page_size);
        writeU64(buf, &pos, self.counter);
        writeU64(buf, &pos, self.last_checkpoint_lsn);
        writeU64(buf, &pos, self.node_high_water);
        writeU64(buf, &pos, self.edge_high_water);
        writeU64(buf, &pos, self.next_node_id);
        writeU64(buf, &pos, self.next_edge_id);
        writeU64(buf, &pos, self.next_txn_id);
        writeU32(buf, &pos, self.label_count);
        writeU64(buf, &pos, self.nodes_pages);
        writeU64(buf, &pos, self.adj_out_pages);
        writeU64(buf, &pos, self.adj_in_pages);
        writeU64(buf, &pos, self.props_pages);
        writeU64(buf, &pos, self.var_pages);
        writeU64(buf, &pos, self.free_pages);
        writeU64(buf, &pos, self.node_count);
        writeU64(buf, &pos, self.edge_count);

        // CRC32 over everything before the checksum
        const crc = Crc32.hash(buf[0..pos]);
        writeU32(buf, &pos, crc);

        return buf;
    }

    /// Parse bytes, validate magic and CRC32, return manifest.
    pub fn deserialize(allocator: Allocator, data: []const u8) !Manifest {
        _ = allocator;

        if (data.len < SERIALIZED_SIZE) return error.InvalidData;

        // Validate magic
        if (!std.mem.eql(u8, data[0..8], &MANIFEST_MAGIC)) return error.InvalidMagic;

        // Validate CRC32
        const stored_crc = readU32(data, SERIALIZED_SIZE - 4);
        const computed_crc = Crc32.hash(data[0 .. SERIALIZED_SIZE - 4]);
        if (stored_crc != computed_crc) return error.ChecksumMismatch;

        var pos: usize = 8;
        var m = Manifest{};

        m.format_version = readU32(data, pos);
        pos += 4;
        @memcpy(&m.graph_uuid, data[pos..][0..16]);
        pos += 16;
        m.page_size = readU32(data, pos);
        pos += 4;
        m.counter = readU64(data, pos);
        pos += 8;
        m.last_checkpoint_lsn = readU64(data, pos);
        pos += 8;
        m.node_high_water = readU64(data, pos);
        pos += 8;
        m.edge_high_water = readU64(data, pos);
        pos += 8;
        m.next_node_id = readU64(data, pos);
        pos += 8;
        m.next_edge_id = readU64(data, pos);
        pos += 8;
        m.next_txn_id = readU64(data, pos);
        pos += 8;
        m.label_count = readU32(data, pos);
        pos += 4;
        m.nodes_pages = readU64(data, pos);
        pos += 8;
        m.adj_out_pages = readU64(data, pos);
        pos += 8;
        m.adj_in_pages = readU64(data, pos);
        pos += 8;
        m.props_pages = readU64(data, pos);
        pos += 8;
        m.var_pages = readU64(data, pos);
        pos += 8;
        m.free_pages = readU64(data, pos);
        pos += 8;
        m.node_count = readU64(data, pos);
        pos += 8;
        m.edge_count = readU64(data, pos);

        return m;
    }

    /// Serialize and write atomically (write to .tmp, fsync, rename).
    pub fn writeToFile(self: *const Manifest, allocator: Allocator, path: []const u8) !void {
        const data = try self.serialize(allocator);
        defer allocator.free(data);

        const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
        defer allocator.free(tmp_path);

        // Write to tmp file
        const tmp_file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), tmp_path, .{ .permissions = std.Io.File.Permissions.fromMode(owner_only_file_mode) });
        defer tmp_file.close(std.Io.Threaded.global_single_threaded.io());

        try tmp_file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), data);
        try tmp_file.sync(std.Io.Threaded.global_single_threaded.io());

        // Atomic rename
        try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, std.Io.Threaded.global_single_threaded.io());
    }

    /// Read file, deserialize. Return null if file doesn't exist.
    pub fn readFromFile(allocator: Allocator, path: []const u8) !?Manifest {
        const file = std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close(std.Io.Threaded.global_single_threaded.io());

        const io = std.Io.Threaded.global_single_threaded.io();
        const file_len = try file.length(io);
        if (file_len > SERIALIZED_SIZE * 2) return error.FileTooLarge;
        const data = try allocator.alloc(u8, @intCast(file_len));
        defer allocator.free(data);
        const bytes_read = try file.readPositionalAll(io, data, 0);
        if (bytes_read != data.len) return error.UnexpectedEndOfFile;

        return try deserialize(allocator, data);
    }

    /// Pick the manifest with the higher counter.
    /// If both null, return error. If one null, return the other.
    pub fn selectManifest(a: ?Manifest, b: ?Manifest) !Manifest {
        if (a == null and b == null) return error.NoManifest;
        if (a == null) return b.?;
        if (b == null) return a.?;
        return if (a.?.counter >= b.?.counter) a.? else b.?;
    }
};

// Helper functions for little-endian encoding

fn writeU32(buf: []u8, pos: *usize, value: u32) void {
    @memcpy(buf[pos.*..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
    pos.* += 4;
}

fn writeU64(buf: []u8, pos: *usize, value: u64) void {
    @memcpy(buf[pos.*..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    pos.* += 8;
}

fn readU32(data: []const u8, offset: usize) u32 {
    return std.mem.littleToNative(u32, @bitCast(data[offset..][0..4].*));
}

fn readU64(data: []const u8, offset: usize) u64 {
    return std.mem.littleToNative(u64, @bitCast(data[offset..][0..8].*));
}

// ============================================================================
// Unit Tests
// ============================================================================

test "serialize/deserialize round-trip" {
    const allocator = std.testing.allocator;
    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0xAB);

    const m = Manifest{
        .graph_uuid = uuid,
        .counter = 42,
        .next_node_id = 100,
        .next_edge_id = 200,
        .next_txn_id = 300,
        .label_count = 5,
        .nodes_pages = 10,
        .adj_out_pages = 20,
        .adj_in_pages = 30,
        .props_pages = 40,
        .var_pages = 50,
        .free_pages = 60,
        .node_count = 70,
        .edge_count = 80,
    };

    const data = try m.serialize(allocator);
    defer allocator.free(data);

    const m2 = try Manifest.deserialize(allocator, data);

    try std.testing.expectEqual(m.format_version, m2.format_version);
    try std.testing.expectEqual(m.graph_uuid, m2.graph_uuid);
    try std.testing.expectEqual(m.page_size, m2.page_size);
    try std.testing.expectEqual(m.counter, m2.counter);
    try std.testing.expectEqual(m.next_node_id, m2.next_node_id);
    try std.testing.expectEqual(m.next_edge_id, m2.next_edge_id);
    try std.testing.expectEqual(m.next_txn_id, m2.next_txn_id);
    try std.testing.expectEqual(m.label_count, m2.label_count);
    try std.testing.expectEqual(m.nodes_pages, m2.nodes_pages);
    try std.testing.expectEqual(m.adj_out_pages, m2.adj_out_pages);
    try std.testing.expectEqual(m.adj_in_pages, m2.adj_in_pages);
    try std.testing.expectEqual(m.props_pages, m2.props_pages);
    try std.testing.expectEqual(m.var_pages, m2.var_pages);
    try std.testing.expectEqual(m.free_pages, m2.free_pages);
    try std.testing.expectEqual(m.node_count, m2.node_count);
    try std.testing.expectEqual(m.edge_count, m2.edge_count);
}

test "corrupt data detected (bad CRC)" {
    const allocator = std.testing.allocator;
    const m = Manifest{};
    const data = try m.serialize(allocator);
    defer allocator.free(data);

    // Corrupt a byte in the middle
    data[20] ^= 0xFF;

    const result = Manifest.deserialize(allocator, data);
    try std.testing.expectError(error.ChecksumMismatch, result);
}

test "bad magic detected" {
    const allocator = std.testing.allocator;
    const m = Manifest{};
    const data = try m.serialize(allocator);
    defer allocator.free(data);

    // Corrupt magic
    data[0] = 'X';

    const result = Manifest.deserialize(allocator, data);
    try std.testing.expectError(error.InvalidMagic, result);
}

test "A/B selection: higher counter wins" {
    const a = Manifest{ .counter = 10 };
    const b = Manifest{ .counter = 20 };
    const selected = try Manifest.selectManifest(a, b);
    try std.testing.expectEqual(@as(u64, 20), selected.counter);

    const selected2 = try Manifest.selectManifest(b, a);
    try std.testing.expectEqual(@as(u64, 20), selected2.counter);
}

test "A/B selection: one null returns the other" {
    const m = Manifest{ .counter = 5 };
    const from_a = try Manifest.selectManifest(m, null);
    try std.testing.expectEqual(@as(u64, 5), from_a.counter);

    const from_b = try Manifest.selectManifest(null, m);
    try std.testing.expectEqual(@as(u64, 5), from_b.counter);
}

test "A/B selection: both null returns error" {
    const result = Manifest.selectManifest(null, null);
    try std.testing.expectError(error.NoManifest, result);
}

test "writeToFile/readFromFile round-trip" {
    const allocator = std.testing.allocator;

    // Use a temp directory for file I/O tests
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(tmp_path);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/manifest.test", .{tmp_path});
    defer allocator.free(file_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0xCD);

    const m = Manifest{
        .graph_uuid = uuid,
        .counter = 99,
        .next_node_id = 500,
    };

    try m.writeToFile(allocator, file_path);

    const saved_file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), file_path, .{});
    defer saved_file.close(std.Io.Threaded.global_single_threaded.io());
    const saved_stat = try saved_file.stat(std.Io.Threaded.global_single_threaded.io());
    try std.testing.expectEqual(@as(u32, owner_only_file_mode), saved_stat.permissions.toMode() & 0o7777);

    const loaded = try Manifest.readFromFile(allocator, file_path);
    try std.testing.expect(loaded != null);

    const m2 = loaded.?;
    try std.testing.expectEqual(m.graph_uuid, m2.graph_uuid);
    try std.testing.expectEqual(m.counter, m2.counter);
    try std.testing.expectEqual(m.next_node_id, m2.next_node_id);
}

test "readFromFile returns null for missing file" {
    const allocator = std.testing.allocator;
    const result = try Manifest.readFromFile(allocator, "/tmp/nonexistent_manifest_file_12345");
    try std.testing.expectEqual(@as(?Manifest, null), result);
}

test {
    std.testing.refAllDecls(@This());
}
