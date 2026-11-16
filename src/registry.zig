// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const scoped_file = @import("scoped_file.zig");
const side_file_crypto = @import("side_file_crypto.zig");
const Allocator = std.mem.Allocator;
// fips-exempt: non-security — CRC32C record-integrity (corruption detection)
// for on-disk format; not authentication.
const Crc32 = std.hash.crc.Crc32Iscsi;
const owner_only_file_mode = 0o600;

pub const REGISTRY_MAGIC: [8]u8 = .{ 'G', 'E', 'O', 'D', 'R', 'E', 'G', '1' };
pub const REGISTRY_VERSION: u32 = 1;

/// SONNY-6616: the uuid a data directory's registry cipher is bound to when
/// the caller has none of its own (`Cipher.forKey(key, SEAL_UUID)`).
pub const SEAL_UUID: [16]u8 = [_]u8{0} ** 16;

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
        return self.saveToFileWith(path, null);
    }

    /// SONNY-6616: save, sealed with `cipher` under at-rest encryption, else
    /// in the plaintext layout. The registry names every graph (and counts
    /// its nodes and edges). The envelope binds the file's base name and
    /// `Kind.graph_registry`; the registry belongs to a data directory, not a
    /// graph, so the caller picks the uuid the cipher is bound to
    /// (`SEAL_UUID` unless it has a better one).
    pub fn saveToFileWith(self: *const GraphRegistry, path: []const u8, cipher: ?*const side_file_crypto.Cipher) !void {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer {
            if (cipher != null) std.crypto.secureZero(u8, buf.items);
            buf.deinit(self.allocator);
        }

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

        const disk = try side_file_crypto.encode(self.allocator, cipher, .graph_registry, std.fs.path.basename(path), buf.items);
        defer self.allocator.free(disk);

        // Write atomically
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp_path);

        // SEC-0052: resolve_beneath prevents symlink traversal out of the
        // registry directory via a crafted path.  exclusive is omitted because
        // a stale .tmp file from a previous crashed write may exist.
        const tmp_file = try scoped_file.create(std.Io.Threaded.global_single_threaded.io(), tmp_path, .{
            .permissions = std.Io.File.Permissions.fromMode(owner_only_file_mode),
            .resolve_beneath = true,
        });
        defer tmp_file.close(std.Io.Threaded.global_single_threaded.io());
        try tmp_file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), disk);
        try tmp_file.sync(std.Io.Threaded.global_single_threaded.io());

        try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, std.Io.Threaded.global_single_threaded.io());
    }

    /// Load from file in GEODREG1 format.
    /// A sealed file is refused with `error.SideFileEncrypted`.
    pub fn loadFromFile(self: *GraphRegistry, path: []const u8) !void {
        _ = try self.loadFromFileWith(path, .{ .cipher = null, .require_sealed = false });
    }

    /// SONNY-6616: load under `policy`. Returns true when the file was in
    /// the plaintext layout (written without a key, or by a build that did
    /// not seal the registry: the caller saves it sealed).
    pub fn loadFromFileWith(self: *GraphRegistry, path: []const u8, policy: side_file_crypto.ReadPolicy) !bool {
        const io = std.Io.Threaded.global_single_threaded.io();
        const raw = blk: {
            const file = try std.Io.Dir.cwd().openFile(io, path, .{});
            defer file.close(io);
            const file_len = try file.length(io);
            if (file_len > 64 * 1024 * 1024) return error.InvalidData;
            break :blk try side_file_crypto.readWholeOpenFile(self.allocator, file);
        };
        const decoded = try side_file_crypto.decode(self.allocator, policy, .graph_registry, std.fs.path.basename(path), raw);
        defer {
            std.crypto.secureZero(u8, decoded.bytes);
            self.allocator.free(decoded.bytes);
        }
        try self.parse(decoded.bytes);
        return decoded.was_plaintext;
    }

    fn parse(self: *GraphRegistry, data: []const u8) !void {
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

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
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

    const saved_file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), file_path, .{});
    defer saved_file.close(std.Io.Threaded.global_single_threaded.io());
    const saved_stat = try saved_file.stat(std.Io.Threaded.global_single_threaded.io());
    try std.testing.expectEqual(@as(u32, owner_only_file_mode), saved_stat.permissions.toMode() & 0o7777);

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

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
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

const TEST_KEY_6635 = [_]u8{0x35} ** 32;

fn tmpRealPath(allocator: Allocator, tmp_dir: *std.testing.TmpDir) ![]u8 {
    return tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
}

test "SONNY-6635: a registry sealed in one data directory does not authenticate in another" {
    const allocator = std.testing.allocator;
    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();
    const dir_a = try tmpRealPath(allocator, &tmp_a);
    defer allocator.free(dir_a);
    const dir_b = try tmpRealPath(allocator, &tmp_b);
    defer allocator.free(dir_b);

    const id_a = try DataDirIdentity.generate();
    const id_b = try DataDirIdentity.generate();
    try std.testing.expect(!std.mem.eql(u8, &id_a.uuid, &id_b.uuid));
    try std.testing.expect(!std.mem.eql(u8, &id_a.uuid, &SEAL_UUID));

    var reg = GraphRegistry.init(allocator);
    defer reg.deinit();
    try reg.addGraph("tenant_a", [_]u8{0x0A} ** 16);
    const path_a = try std.fmt.allocPrint(allocator, "{s}/graph_registry.dat", .{dir_a});
    defer allocator.free(path_a);
    {
        var c = id_a.cipher(TEST_KEY_6635).?;
        defer c.deinit();
        try reg.saveToFileWith(path_a, &c);
    }
    // The same file in data directory B (same key, B's identity).
    const raw = try side_file_crypto.readWholeFile(allocator, path_a);
    defer allocator.free(raw);
    const path_b = try std.fmt.allocPrint(allocator, "{s}/graph_registry.dat", .{dir_b});
    defer allocator.free(path_b);
    try side_file_crypto.writeAtomic(allocator, path_b, raw);

    var in_b = GraphRegistry.init(allocator);
    defer in_b.deinit();
    var cb = id_b.cipher(TEST_KEY_6635).?;
    defer cb.deinit();
    try std.testing.expectError(error.SideFileAuthFailed, in_b.loadFromFileWith(path_b, .{ .cipher = &cb, .require_sealed = true }));
    // In A, under A's identity, it loads.
    var in_a = GraphRegistry.init(allocator);
    defer in_a.deinit();
    var ca = id_a.cipher(TEST_KEY_6635).?;
    defer ca.deinit();
    try std.testing.expect(!try in_a.loadFromFileWith(path_a, .{ .cipher = &ca, .require_sealed = true }));
    try std.testing.expect(in_a.findByName("tenant_a") != null);
}

test "SONNY-6635: the data-directory identity round-trips sealed, private, and records the bound registry" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpRealPath(allocator, &tmp);
    defer allocator.free(dir);

    try std.testing.expect((try DataDirIdentity.load(allocator, dir, TEST_KEY_6635)) == null);

    var id = try DataDirIdentity.generate();
    try std.testing.expect(!id.registry_bound);
    try id.save(allocator, dir, TEST_KEY_6635);
    id.registry_bound = true;
    try id.save(allocator, dir, TEST_KEY_6635);

    const got = (try DataDirIdentity.load(allocator, dir, TEST_KEY_6635)).?;
    try std.testing.expectEqualSlices(u8, &id.uuid, &got.uuid);
    try std.testing.expect(got.registry_bound);

    const path = try std.fmt.allocPrint(allocator, "{s}/" ++ IDENTITY_FILE_NAME, .{dir});
    defer allocator.free(path);
    const raw = try side_file_crypto.readWholeFile(allocator, path);
    defer allocator.free(raw);
    try std.testing.expect(side_file_crypto.isSealed(raw));
    try std.testing.expect(std.mem.indexOf(u8, raw, &id.uuid) == null);
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    try std.testing.expectEqual(@as(u32, owner_only_file_mode), (try f.stat(io)).permissions.toMode() & 0o7777);

    // Without the key it is sealed; under another key it does not authenticate.
    try std.testing.expectError(error.SideFileEncrypted, DataDirIdentity.load(allocator, dir, null));
    try std.testing.expectError(error.SideFileAuthFailed, DataDirIdentity.load(allocator, dir, [_]u8{0x36} ** 32));

    // Under a key a plaintext identity (one that could say "not bound") is refused.
    var plain = id;
    plain.registry_bound = false;
    try plain.save(allocator, dir, null);
    try std.testing.expectError(error.SideFileNotSealed, DataDirIdentity.load(allocator, dir, TEST_KEY_6635));
    // Without a key a plaintext identity loads.
    const p = (try DataDirIdentity.load(allocator, dir, null)).?;
    try std.testing.expect(!p.registry_bound);
}

test {
    std.testing.refAllDecls(@This());
}
