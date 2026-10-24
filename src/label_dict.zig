// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const scoped_file = @import("scoped_file.zig");
const Allocator = std.mem.Allocator;
// fips-exempt: non-security — CRC32C record-integrity (corruption detection)
// for on-disk format; not authentication.
const Crc32 = std.hash.crc.Crc32Iscsi;
const owner_only_file_mode = 0o600;

pub const LabelDictionary = struct {
    allocator: Allocator,
    next_id: u32 = 0,
    name_to_id: std.StringHashMap(u32),
    id_to_name: std.AutoHashMap(u32, []const u8),

    pub fn init(allocator: Allocator) LabelDictionary {
        return .{
            .allocator = allocator,
            .name_to_id = std.StringHashMap(u32).init(allocator),
            .id_to_name = std.AutoHashMap(u32, []const u8).init(allocator),
        };
    }

    pub fn deinit(self: *LabelDictionary) void {
        // Free all owned label strings (stored as keys in name_to_id)
        var it = self.name_to_id.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.name_to_id.deinit();
        self.id_to_name.deinit();
    }

    /// Get or assign a LabelId for the given label string.
    /// If the label already has an ID, returns it. Otherwise assigns the next ID.
    pub fn getOrAssign(self: *LabelDictionary, label: []const u8) !u32 {
        if (self.name_to_id.get(label)) |id| {
            return id;
        }

        const id = self.next_id;
        self.next_id += 1;

        const owned = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned);

        try self.name_to_id.put(owned, id);
        errdefer _ = self.name_to_id.remove(owned);

        try self.id_to_name.put(id, owned);

        return id;
    }

    /// Look up ID for a label string. Returns null if not found.
    pub fn getId(self: *const LabelDictionary, label: []const u8) ?u32 {
        return self.name_to_id.get(label);
    }

    /// Look up label string for an ID. Returns null if not found.
    pub fn getName(self: *const LabelDictionary, id: u32) ?[]const u8 {
        return self.id_to_name.get(id);
    }

    pub fn count(self: *const LabelDictionary) u32 {
        return @intCast(self.name_to_id.count());
    }

    /// Save to file.
    /// Format: count(4) + repeated [name_len(4) + name_bytes + id(4)] + CRC32(4)
    pub fn saveToFile(self: *const LabelDictionary, path: []const u8) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        const entry_count: u32 = @intCast(self.name_to_id.count());
        try appendU32(&buf, self.allocator, entry_count);

        var it = self.name_to_id.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const id = entry.value_ptr.*;
            try appendU32(&buf, self.allocator, @intCast(name.len));
            try buf.appendSlice(self.allocator, name);
            try appendU32(&buf, self.allocator, id);
        }

        // CRC32 over everything
        const crc = Crc32.hash(buf.items);
        try appendU32(&buf, self.allocator, crc);

        // Write atomically
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp_path);

        // SEC-0052: resolve_beneath prevents symlink traversal out of the
        // label dictionary directory via a crafted path.  exclusive is omitted
        // because a stale .tmp file from a previous crashed write may exist.
        const tmp_file = try scoped_file.create(std.Io.Threaded.global_single_threaded.io(), tmp_path, .{
            .permissions = std.Io.File.Permissions.fromMode(owner_only_file_mode),
            .resolve_beneath = true,
        });
        defer tmp_file.close(std.Io.Threaded.global_single_threaded.io());
        try tmp_file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), buf.items);
        try tmp_file.sync(std.Io.Threaded.global_single_threaded.io());

        try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, std.Io.Threaded.global_single_threaded.io());
    }

    /// Load from file.
    pub fn loadFromFile(self: *LabelDictionary, path: []const u8) !void {
        var file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path, .{});
        defer file.close(std.Io.Threaded.global_single_threaded.io());

        const stat = try file.stat(std.Io.Threaded.global_single_threaded.io());
        const file_size = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
        if (file_size < 8) return error.InvalidData;

        var next = LabelDictionary.init(self.allocator);
        errdefer next.deinit();

        var remaining = file_size - 4;
        var crc = Crc32.init();
        var u32_buf: [4]u8 = undefined;
        var file_offset: u64 = 0;

        try readTracked(&file, &file_offset, &remaining, &crc, &u32_buf);
        const entry_count = std.mem.readInt(u32, &u32_buf, .little);

        var max_id: u32 = 0;
        for (0..entry_count) |_| {
            try readTracked(&file, &file_offset, &remaining, &crc, &u32_buf);
            const name_len = std.mem.readInt(u32, &u32_buf, .little);

            const owned = try self.allocator.alloc(u8, name_len);
            // owned is freed here on any error before it is adopted into next.name_to_id.
            errdefer self.allocator.free(owned);
            try readTracked(&file, &file_offset, &remaining, &crc, owned);

            try readTracked(&file, &file_offset, &remaining, &crc, &u32_buf);
            const id = std.mem.readInt(u32, &u32_buf, .little);

            // Reject duplicate names.  If found_existing the errdefer above
            // frees owned because it was not inserted into name_to_id.
            const name_gop = try next.name_to_id.getOrPut(owned);
            if (name_gop.found_existing) return error.InvalidData;
            name_gop.value_ptr.* = id;

            // Reject duplicate ids.  owned is now in next.name_to_id, so
            // next.deinit() will free it.  On this error path we remove owned
            // from name_to_id first so that the local errdefer (not deinit)
            // handles the free, preventing a double-free.
            const id_gop = try next.id_to_name.getOrPut(id);
            if (id_gop.found_existing) {
                _ = next.name_to_id.remove(owned);
                return error.InvalidData;
            }
            id_gop.value_ptr.* = owned;
            // Single-owner invariant: owned is the key in name_to_id and the
            // value in id_to_name; deinit frees only name_to_id keys, which
            // covers both pointers because they alias the same allocation.

            if (id >= max_id) max_id = id + 1;
        }

        if (remaining != 0) return error.InvalidData;

        const stored_crc = try readU32FromFile(&file, &file_offset);
        if (stored_crc != crc.final()) return error.ChecksumMismatch;

        self.deinit();
        self.* = next;
        self.next_id = max_id;
    }
};

fn readTracked(file: *std.Io.File, offset: *u64, remaining: *usize, crc: *Crc32, buf: []u8) !void {
    if (buf.len > remaining.*) return error.InvalidData;
    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes_read = try file.readPositionalAll(io, buf, offset.*);
    if (bytes_read != buf.len) return error.InvalidData;
    crc.update(buf);
    offset.* += buf.len;
    remaining.* -= buf.len;
}

fn readU32FromFile(file: *std.Io.File, offset: *u64) !u32 {
    var buf: [4]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes_read = try file.readPositionalAll(io, &buf, offset.*);
    if (bytes_read != buf.len) return error.InvalidData;
    offset.* += buf.len;
    return std.mem.readInt(u32, &buf, .little);
}

fn appendU32(buf: *std.ArrayList(u8), allocator: Allocator, value: u32) !void {
    try buf.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
}

fn readU32(data: []const u8, offset: usize) u32 {
    return std.mem.littleToNative(u32, @bitCast(data[offset..][0..4].*));
}

// ============================================================================
// Unit Tests
// ============================================================================

test "getOrAssign returns same ID for same label" {
    const allocator = std.testing.allocator;
    var dict = LabelDictionary.init(allocator);
    defer dict.deinit();

    const id1 = try dict.getOrAssign("Person");
    const id2 = try dict.getOrAssign("Person");
    try std.testing.expectEqual(id1, id2);
}

test "getOrAssign assigns incrementing IDs" {
    const allocator = std.testing.allocator;
    var dict = LabelDictionary.init(allocator);
    defer dict.deinit();

    const id_a = try dict.getOrAssign("A");
    const id_b = try dict.getOrAssign("B");
    const id_c = try dict.getOrAssign("C");

    try std.testing.expectEqual(@as(u32, 0), id_a);
    try std.testing.expectEqual(@as(u32, 1), id_b);
    try std.testing.expectEqual(@as(u32, 2), id_c);
    try std.testing.expectEqual(@as(u32, 3), dict.count());
}

test "getId / getName lookups" {
    const allocator = std.testing.allocator;
    var dict = LabelDictionary.init(allocator);
    defer dict.deinit();

    const id = try dict.getOrAssign("Edge");

    try std.testing.expectEqual(id, dict.getId("Edge").?);
    try std.testing.expectEqualStrings("Edge", dict.getName(id).?);

    try std.testing.expect(dict.getId("Unknown") == null);
    try std.testing.expect(dict.getName(999) == null);
}

test "save/load round-trip preserves all mappings" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(tmp_path);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/labels.dict", .{tmp_path});
    defer allocator.free(file_path);

    // Create and populate dictionary
    var dict = LabelDictionary.init(allocator);
    defer dict.deinit();

    _ = try dict.getOrAssign("Person");
    _ = try dict.getOrAssign("Company");
    _ = try dict.getOrAssign("WORKS_AT");

    try dict.saveToFile(file_path);

    const saved_file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), file_path, .{});
    defer saved_file.close(std.Io.Threaded.global_single_threaded.io());
    const saved_stat = try saved_file.stat(std.Io.Threaded.global_single_threaded.io());
    try std.testing.expectEqual(@as(u32, owner_only_file_mode), saved_stat.permissions.toMode() & 0o7777);

    // Load into new dictionary
    var dict2 = LabelDictionary.init(allocator);
    defer dict2.deinit();

    try dict2.loadFromFile(file_path);

    try std.testing.expectEqual(@as(u32, 3), dict2.count());

    // Verify all mappings preserved
    const person_id = dict2.getId("Person");
    try std.testing.expect(person_id != null);
    try std.testing.expectEqual(dict.getId("Person").?, person_id.?);

    const company_id = dict2.getId("Company");
    try std.testing.expect(company_id != null);
    try std.testing.expectEqual(dict.getId("Company").?, company_id.?);

    const works_at_id = dict2.getId("WORKS_AT");
    try std.testing.expect(works_at_id != null);
    try std.testing.expectEqual(dict.getId("WORKS_AT").?, works_at_id.?);

    // Verify reverse lookups
    try std.testing.expectEqualStrings("Person", dict2.getName(person_id.?).?);
    try std.testing.expectEqualStrings("Company", dict2.getName(company_id.?).?);
    try std.testing.expectEqualStrings("WORKS_AT", dict2.getName(works_at_id.?).?);

    // Verify next_id is correctly restored
    const new_id = try dict2.getOrAssign("NewLabel");
    try std.testing.expectEqual(@as(u32, 3), new_id);
}

// ---------------------------------------------------------------------------
// Helper: build a raw labels.dict byte buffer from a slice of (name, id) pairs
// and write it to a temp file using the std.Io.Dir API.
// ---------------------------------------------------------------------------
fn buildDictFile(
    allocator: Allocator,
    dir: std.Io.Dir,
    filename: []const u8,
    entries: []const struct { name: []const u8, id: u32 },
) !void {
    const io = std.Io.Threaded.global_single_threaded.io();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const entry_count: u32 = @intCast(entries.len);
    try appendU32(&buf, allocator, entry_count);

    for (entries) |e| {
        try appendU32(&buf, allocator, @intCast(e.name.len));
        try buf.appendSlice(allocator, e.name);
        try appendU32(&buf, allocator, e.id);
    }

    const crc = Crc32.hash(buf.items);
    try appendU32(&buf, allocator, crc);

    const f = try dir.createFile(io, filename, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, buf.items);
}

// SEC-0050 regression: duplicate name entries must be rejected (no leak).
test "loadFromFile rejects duplicate name entries" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Two entries with the same name but different IDs.
    try buildDictFile(allocator, tmp_dir.dir, "dup_name.dict", &.{
        .{ .name = "Person", .id = 0 },
        .{ .name = "Person", .id = 1 },
    });

    const dir_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir_path);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/dup_name.dict", .{dir_path});
    defer allocator.free(file_path);

    var dict = LabelDictionary.init(allocator);
    defer dict.deinit();

    try std.testing.expectError(error.InvalidData, dict.loadFromFile(file_path));
    // dict must be empty — no partial state committed.
    try std.testing.expectEqual(@as(u32, 0), dict.count());
}

// SEC-0050 regression: duplicate id entries must be rejected (no leak).
test "loadFromFile rejects duplicate id entries" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Two distinct names mapped to the same ID.
    try buildDictFile(allocator, tmp_dir.dir, "dup_id.dict", &.{
        .{ .name = "Person", .id = 42 },
        .{ .name = "Company", .id = 42 },
    });

    const dir_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir_path);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/dup_id.dict", .{dir_path});
    defer allocator.free(file_path);

    var dict = LabelDictionary.init(allocator);
    defer dict.deinit();

    try std.testing.expectError(error.InvalidData, dict.loadFromFile(file_path));
    try std.testing.expectEqual(@as(u32, 0), dict.count());
}

// SEC-0050 regression: bad CRC must be rejected without retaining partial state.
test "loadFromFile rejects bad CRC with no partial state" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Build a valid buffer then flip the last byte of the CRC to corrupt it.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const entries = [_]struct { name: []const u8, id: u32 }{
        .{ .name = "Person", .id = 0 },
        .{ .name = "Company", .id = 1 },
    };
    try appendU32(&buf, allocator, @intCast(entries.len));
    for (entries) |e| {
        try appendU32(&buf, allocator, @intCast(e.name.len));
        try buf.appendSlice(allocator, e.name);
        try appendU32(&buf, allocator, e.id);
    }
    const crc = Crc32.hash(buf.items);
    try appendU32(&buf, allocator, crc);
    // Corrupt the last byte of the stored CRC.
    buf.items[buf.items.len - 1] ^= 0xFF;

    const bad_file = try tmp_dir.dir.createFile(io, "bad_crc.dict", .{});
    defer bad_file.close(io);
    try bad_file.writeStreamingAll(io, buf.items);

    const dir_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir_path);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/bad_crc.dict", .{dir_path});
    defer allocator.free(file_path);

    var dict = LabelDictionary.init(allocator);
    defer dict.deinit();

    try std.testing.expectError(error.ChecksumMismatch, dict.loadFromFile(file_path));
    // No partial state should be committed after a CRC failure.
    try std.testing.expectEqual(@as(u32, 0), dict.count());
}

test {
    std.testing.refAllDecls(@This());
}
