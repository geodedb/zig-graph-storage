// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const Crc32 = std.hash.crc.Crc32Iscsi;

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
        var buf: std.ArrayList(u8) = .{};
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

        const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
        defer tmp_file.close();
        try tmp_file.writeAll(buf.items);
        try tmp_file.sync();

        try std.fs.cwd().rename(tmp_path, path);
    }

    /// Load from file.
    pub fn loadFromFile(self: *LabelDictionary, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const data = try file.readToEndAlloc(self.allocator, 64 * 1024 * 1024);
        defer self.allocator.free(data);

        if (data.len < 8) return error.InvalidData; // at least count(4) + crc(4)

        // Validate CRC32
        const stored_crc = readU32(data, data.len - 4);
        const computed_crc = Crc32.hash(data[0 .. data.len - 4]);
        if (stored_crc != computed_crc) return error.ChecksumMismatch;

        // Clear existing entries
        var it = self.name_to_id.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.name_to_id.clearRetainingCapacity();
        self.id_to_name.clearRetainingCapacity();

        var pos: usize = 0;
        const entry_count = readU32(data, pos);
        pos += 4;

        var max_id: u32 = 0;
        for (0..entry_count) |_| {
            if (pos + 4 > data.len - 4) return error.InvalidData;
            const name_len: usize = readU32(data, pos);
            pos += 4;

            if (pos + name_len + 4 > data.len - 4) return error.InvalidData;
            const owned = try self.allocator.dupe(u8, data[pos..][0..name_len]);
            errdefer self.allocator.free(owned);
            pos += name_len;

            const id = readU32(data, pos);
            pos += 4;

            try self.name_to_id.put(owned, id);
            try self.id_to_name.put(id, owned);

            if (id >= max_id) max_id = id + 1;
        }

        self.next_id = max_id;
    }
};

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

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
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

test {
    std.testing.refAllDecls(@This());
}
