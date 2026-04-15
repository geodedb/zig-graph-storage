// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const Crc32 = std.hash.crc.Crc32Iscsi;
const owner_only_file_mode = 0o600;

pub const REGISTRY_MAGIC: [8]u8 = .{ 'G', 'E', 'O', 'D', 'R', 'E', 'G', '1' };
pub const REGISTRY_VERSION: u32 = 1;

pub const GraphEntry = struct {
    name: []const u8, // owned by registry
    uuid: [16]u8,
    node_count: u64,
    edge_count: u64,
};

pub const GraphRegistry = struct {
    allocator: Allocator,
    next_node_id: u64 = 1,
    next_edge_id: u64 = 1,
    entries: std.ArrayListUnmanaged(GraphEntry) = .empty,

    pub fn init(allocator: Allocator) GraphRegistry {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GraphRegistry) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn addGraph(self: *GraphRegistry, name: []const u8, uuid: [16]u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        try self.entries.append(self.allocator, .{
            .name = owned_name,
            .uuid = uuid,
            .node_count = 0,
            .edge_count = 0,
        });
    }

    pub fn removeGraph(self: *GraphRegistry, name: []const u8) bool {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, name)) {
                self.allocator.free(entry.name);
                _ = self.entries.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn findByName(self: *const GraphRegistry, name: []const u8) ?GraphEntry {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return entry;
            }
        }
        return null;
    }

    pub fn findByUuid(self: *const GraphRegistry, uuid: [16]u8) ?GraphEntry {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, &entry.uuid, &uuid)) {
                return entry;
            }
        }
        return null;
    }

    pub fn graphCount(self: *const GraphRegistry) usize {
        return self.entries.items.len;
    }

    /// Save to file in GEODREG1 format.
    /// Header: magic(8) + version(4) + reserved(4) + next_node_id(8) + next_edge_id(8) + graph_count(8) + crc(4) = 44 bytes
    /// Entries: name_len(4) + name_bytes + uuid(16) + node_count(8) + edge_count(8)
    /// CRC32 covers header[0..40] + all entry bytes
    pub fn saveToFile(self: *const GraphRegistry, path: []const u8) !void {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);

        // Header (without CRC - we'll compute it over everything)
        try buf.appendSlice(self.allocator, &REGISTRY_MAGIC); // 8
        try appendU32(&buf, self.allocator, REGISTRY_VERSION); // 4
        try appendU32(&buf, self.allocator, 0); // reserved 4
        try appendU64(&buf, self.allocator, self.next_node_id); // 8
        try appendU64(&buf, self.allocator, self.next_edge_id); // 8
        try appendU64(&buf, self.allocator, @intCast(self.entries.items.len)); // 8
        // = 40 bytes so far

        // Entries
        for (self.entries.items) |entry| {
            try appendU32(&buf, self.allocator, @intCast(entry.name.len));
            try buf.appendSlice(self.allocator, entry.name);
            try buf.appendSlice(self.allocator, &entry.uuid);
            try appendU64(&buf, self.allocator, entry.node_count);
            try appendU64(&buf, self.allocator, entry.edge_count);
        }

        // CRC32 over everything
        const crc = Crc32.hash(buf.items);
        try appendU32(&buf, self.allocator, crc);

        // Write atomically
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp_path);

        const tmp_file = try std.fs.cwd().createFile(tmp_path, .{ .mode = owner_only_file_mode });
        defer tmp_file.close();
        try tmp_file.writeAll(buf.items);
        try tmp_file.sync();

        try std.fs.cwd().rename(tmp_path, path);
    }

    /// Load from file in GEODREG1 format.
    pub fn loadFromFile(self: *GraphRegistry, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const data = try file.readToEndAlloc(self.allocator, 64 * 1024 * 1024);
        defer self.allocator.free(data);

        if (data.len < 44) return error.InvalidData;

        // Validate magic
        if (!std.mem.eql(u8, data[0..8], &REGISTRY_MAGIC)) return error.InvalidMagic;

        // The CRC is the last 4 bytes
        const stored_crc = readU32(data, data.len - 4);
        const computed_crc = Crc32.hash(data[0 .. data.len - 4]);
        if (stored_crc != computed_crc) return error.ChecksumMismatch;

        // Parse header
        var pos: usize = 8;
        _ = readU32(data, pos); // version
        pos += 4;
        _ = readU32(data, pos); // reserved
        pos += 4;
        self.next_node_id = readU64(data, pos);
        pos += 8;
        self.next_edge_id = readU64(data, pos);
        pos += 8;
        const graph_count: usize = std.math.cast(usize, readU64(data, pos)) orelse return error.InvalidData;
        pos += 8;

        // Clear existing entries
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.entries.clearRetainingCapacity();

        // Parse entries
        for (0..graph_count) |_| {
            if (pos + 4 > data.len - 4) return error.InvalidData;
            const name_len: usize = readU32(data, pos);
            pos += 4;

            if (pos + name_len + 32 > data.len - 4) return error.InvalidData;
            const name = try self.allocator.dupe(u8, data[pos..][0..name_len]);
            errdefer self.allocator.free(name);
            pos += name_len;

            var uuid: [16]u8 = undefined;
            @memcpy(&uuid, data[pos..][0..16]);
            pos += 16;

            const node_count = readU64(data, pos);
            pos += 8;
            const edge_count = readU64(data, pos);
            pos += 8;

            try self.entries.append(self.allocator, .{
                .name = name,
                .uuid = uuid,
                .node_count = node_count,
                .edge_count = edge_count,
            });
        }
    }
};

fn appendU32(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, value: u32) !void {
    try buf.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
}

fn appendU64(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, value: u64) !void {
    try buf.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
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

test "add/remove/find by name" {
    const allocator = std.testing.allocator;
    var reg = GraphRegistry.init(allocator);
    defer reg.deinit();

    var uuid1: [16]u8 = undefined;
    @memset(&uuid1, 0x01);

    var uuid2: [16]u8 = undefined;
    @memset(&uuid2, 0x02);

    try reg.addGraph("graph1", uuid1);
    try reg.addGraph("graph2", uuid2);
    try std.testing.expectEqual(@as(usize, 2), reg.graphCount());

    const found = reg.findByName("graph1");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("graph1", found.?.name);
    try std.testing.expectEqual(uuid1, found.?.uuid);

    try std.testing.expect(reg.removeGraph("graph1"));
    try std.testing.expectEqual(@as(usize, 1), reg.graphCount());
    try std.testing.expect(reg.findByName("graph1") == null);

    // Remove non-existent
    try std.testing.expect(!reg.removeGraph("nonexistent"));
}

test "find by UUID" {
    const allocator = std.testing.allocator;
    var reg = GraphRegistry.init(allocator);
    defer reg.deinit();

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0xAA);

    try reg.addGraph("test_graph", uuid);

    const found = reg.findByUuid(uuid);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("test_graph", found.?.name);

    var unknown: [16]u8 = undefined;
    @memset(&unknown, 0xFF);
    try std.testing.expect(reg.findByUuid(unknown) == null);
}

test "save/load round-trip" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/registry.dat", .{tmp_path});
    defer allocator.free(file_path);

    // Create and populate registry
    var reg = GraphRegistry.init(allocator);
    defer reg.deinit();

    var uuid1: [16]u8 = undefined;
    @memset(&uuid1, 0x10);
    var uuid2: [16]u8 = undefined;
    @memset(&uuid2, 0x20);

    try reg.addGraph("alpha", uuid1);
    try reg.addGraph("beta", uuid2);
    reg.next_node_id = 42;
    reg.next_edge_id = 99;

    try reg.saveToFile(file_path);

    const saved_file = try std.fs.cwd().openFile(file_path, .{});
    defer saved_file.close();
    const saved_stat = try saved_file.stat();
    try std.testing.expectEqual(@as(u32, owner_only_file_mode), saved_stat.mode & 0o777);

    // Load into new registry
    var reg2 = GraphRegistry.init(allocator);
    defer reg2.deinit();

    try reg2.loadFromFile(file_path);

    try std.testing.expectEqual(@as(usize, 2), reg2.graphCount());
    try std.testing.expectEqual(@as(u64, 42), reg2.next_node_id);
    try std.testing.expectEqual(@as(u64, 99), reg2.next_edge_id);

    const found_alpha = reg2.findByName("alpha");
    try std.testing.expect(found_alpha != null);
    try std.testing.expectEqual(uuid1, found_alpha.?.uuid);

    const found_beta = reg2.findByName("beta");
    try std.testing.expect(found_beta != null);
    try std.testing.expectEqual(uuid2, found_beta.?.uuid);
}

test "empty registry save/load" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/empty_registry.dat", .{tmp_path});
    defer allocator.free(file_path);

    var reg = GraphRegistry.init(allocator);
    defer reg.deinit();

    try reg.saveToFile(file_path);

    var reg2 = GraphRegistry.init(allocator);
    defer reg2.deinit();

    try reg2.loadFromFile(file_path);
    try std.testing.expectEqual(@as(usize, 0), reg2.graphCount());
}

test {
    std.testing.refAllDecls(@This());
}
