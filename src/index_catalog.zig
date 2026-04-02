// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
const owner_only_file_mode = 0o600;

pub const IndexType = enum(u8) {
    btree_property = 0,
    label_posting = 1,
};

pub const IndexState = enum(u8) {
    building = 0,
    active = 1,
    inactive = 2,
    failed = 3,
};

pub const IndexDef = struct {
    label_id: u32,
    property_key: []const u8,
    index_type: IndexType,
    state: IndexState,
};

/// Catalog of all index definitions. Provides persistence via a simple
/// binary file format.
pub const IndexCatalog = struct {
    allocator: Allocator,
    indexes: std.ArrayList(IndexDef),
    /// Owned copies of property_key strings for entries managed by the catalog.
    owned_keys: std.ArrayList([]const u8),

    pub fn init(allocator: Allocator) IndexCatalog {
        return .{
            .allocator = allocator,
            .indexes = .{},
            .owned_keys = .{},
        };
    }

    pub fn deinit(self: *IndexCatalog) void {
        for (self.owned_keys.items) |key| {
            self.allocator.free(key);
        }
        self.owned_keys.deinit(self.allocator);
        self.indexes.deinit(self.allocator);
    }

    /// Register a new index definition. The property_key is copied.
    pub fn addIndex(self: *IndexCatalog, def: IndexDef) !void {
        const key_copy = try self.allocator.dupe(u8, def.property_key);
        errdefer self.allocator.free(key_copy);

        try self.owned_keys.append(self.allocator, key_copy);
        errdefer _ = self.owned_keys.pop();

        try self.indexes.append(self.allocator, .{
            .label_id = def.label_id,
            .property_key = key_copy,
            .index_type = def.index_type,
            .state = def.state,
        });
    }

    /// Remove an index definition. Returns true if found and removed.
    pub fn removeIndex(self: *IndexCatalog, label_id: u32, property_key: []const u8) bool {
        for (self.indexes.items, 0..) |entry, i| {
            if (entry.label_id == label_id and std.mem.eql(u8, entry.property_key, property_key)) {
                self.allocator.free(self.owned_keys.items[i]);
                _ = self.owned_keys.orderedRemove(i);
                _ = self.indexes.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Find an index definition.
    pub fn findIndex(self: *const IndexCatalog, label_id: u32, property_key: []const u8) ?IndexDef {
        for (self.indexes.items) |entry| {
            if (entry.label_id == label_id and std.mem.eql(u8, entry.property_key, property_key)) {
                return entry;
            }
        }
        return null;
    }

    /// Save the catalog to a file.
    /// Format: [u32 count] then for each entry:
    ///   [u32 label_id] [u8 index_type] [u8 state] [u16 key_len] [key_len bytes]
    pub fn saveToFile(self: *const IndexCatalog, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{ .mode = owner_only_file_mode });
        defer file.close();

        // Serialize to an in-memory buffer, then write all at once.
        var data: std.ArrayList(u8) = .{};
        defer data.deinit(self.allocator);

        const entry_count: u32 = @intCast(self.indexes.items.len);
        {
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, entry_count, .little);
            try data.appendSlice(self.allocator, &tmp);
        }

        for (self.indexes.items) |entry| {
            {
                var tmp: [4]u8 = undefined;
                std.mem.writeInt(u32, &tmp, entry.label_id, .little);
                try data.appendSlice(self.allocator, &tmp);
            }
            try data.append(self.allocator, @intFromEnum(entry.index_type));
            try data.append(self.allocator, @intFromEnum(entry.state));
            {
                const key_len: u16 = @intCast(entry.property_key.len);
                var tmp: [2]u8 = undefined;
                std.mem.writeInt(u16, &tmp, key_len, .little);
                try data.appendSlice(self.allocator, &tmp);
            }
            try data.appendSlice(self.allocator, entry.property_key);
        }

        try file.writeAll(data.items);
    }

    /// Load the catalog from a file, replacing any existing entries.
    pub fn loadFromFile(self: *IndexCatalog, path: []const u8) !void {
        // Clear existing.
        for (self.owned_keys.items) |key| {
            self.allocator.free(key);
        }
        self.owned_keys.clearRetainingCapacity();
        self.indexes.clearRetainingCapacity();

        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        // Read entire file into memory.
        const stat = try file.stat();
        const content = try self.allocator.alloc(u8, stat.size);
        defer self.allocator.free(content);
        const bytes_read = try file.readAll(content);
        if (bytes_read != stat.size) return error.UnexpectedEndOfFile;

        var pos: usize = 0;

        const entry_count = std.mem.readInt(u32, content[pos..][0..4], .little);
        pos += 4;

        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            const label_id = std.mem.readInt(u32, content[pos..][0..4], .little);
            pos += 4;
            const type_byte = content[pos];
            pos += 1;
            const state_byte = content[pos];
            pos += 1;
            const key_len = std.mem.readInt(u16, content[pos..][0..2], .little);
            pos += 2;

            const key_buf = try self.allocator.dupe(u8, content[pos..][0..key_len]);
            errdefer self.allocator.free(key_buf);
            pos += key_len;

            try self.owned_keys.append(self.allocator, key_buf);
            errdefer _ = self.owned_keys.pop();

            const index_type = std.meta.intToEnum(IndexType, type_byte) catch return error.InvalidData;
            const state = std.meta.intToEnum(IndexState, state_byte) catch return error.InvalidData;

            try self.indexes.append(self.allocator, .{
                .label_id = label_id,
                .property_key = key_buf,
                .index_type = index_type,
                .state = state,
            });
        }
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "addIndex + findIndex" {
    var catalog = IndexCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.addIndex(.{
        .label_id = 1,
        .property_key = "name",
        .index_type = .btree_property,
        .state = .active,
    });

    const found = catalog.findIndex(1, "name");
    try testing.expect(found != null);
    try testing.expectEqual(@as(u32, 1), found.?.label_id);
    try testing.expectEqualStrings("name", found.?.property_key);
    try testing.expectEqual(IndexType.btree_property, found.?.index_type);
    try testing.expectEqual(IndexState.active, found.?.state);
}

test "findIndex returns null for unknown" {
    var catalog = IndexCatalog.init(testing.allocator);
    defer catalog.deinit();

    try testing.expect(catalog.findIndex(1, "name") == null);
}

test "removeIndex" {
    var catalog = IndexCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.addIndex(.{
        .label_id = 1,
        .property_key = "name",
        .index_type = .btree_property,
        .state = .active,
    });

    try testing.expect(catalog.removeIndex(1, "name"));
    try testing.expect(catalog.findIndex(1, "name") == null);
    try testing.expect(!catalog.removeIndex(1, "name"));
}

test "saveToFile + loadFromFile round-trip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path);

    const full_path = try std.fmt.allocPrint(testing.allocator, "{s}/catalog.bin", .{path});
    defer testing.allocator.free(full_path);

    // Create and save.
    {
        var catalog = IndexCatalog.init(testing.allocator);
        defer catalog.deinit();

        try catalog.addIndex(.{
            .label_id = 1,
            .property_key = "name",
            .index_type = .btree_property,
            .state = .active,
        });
        try catalog.addIndex(.{
            .label_id = 2,
            .property_key = "email",
            .index_type = .label_posting,
            .state = .building,
        });

        try catalog.saveToFile(full_path);
    }

    {
        const saved_file = try std.fs.cwd().openFile(full_path, .{});
        defer saved_file.close();
        const saved_stat = try saved_file.stat();
        try testing.expectEqual(@as(u32, owner_only_file_mode), saved_stat.mode & 0o777);
    }

    // Load and verify.
    {
        var catalog = IndexCatalog.init(testing.allocator);
        defer catalog.deinit();

        try catalog.loadFromFile(full_path);

        try testing.expectEqual(@as(usize, 2), catalog.indexes.items.len);

        const first = catalog.findIndex(1, "name");
        try testing.expect(first != null);
        try testing.expectEqual(IndexType.btree_property, first.?.index_type);
        try testing.expectEqual(IndexState.active, first.?.state);

        const second = catalog.findIndex(2, "email");
        try testing.expect(second != null);
        try testing.expectEqual(IndexType.label_posting, second.?.index_type);
        try testing.expectEqual(IndexState.building, second.?.state);
    }
}

test "multiple indexes for same label" {
    var catalog = IndexCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.addIndex(.{
        .label_id = 1,
        .property_key = "name",
        .index_type = .btree_property,
        .state = .active,
    });
    try catalog.addIndex(.{
        .label_id = 1,
        .property_key = "age",
        .index_type = .btree_property,
        .state = .active,
    });

    try testing.expect(catalog.findIndex(1, "name") != null);
    try testing.expect(catalog.findIndex(1, "age") != null);
    try testing.expect(catalog.findIndex(1, "email") == null);
}

test "loadFromFile rejects invalid index_type byte" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path);

    const full_path = try std.fmt.allocPrint(testing.allocator, "{s}/bad_catalog.bin", .{path});
    defer testing.allocator.free(full_path);

    // Craft a catalog file with 1 entry whose index_type byte (0xFF) is invalid.
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    // entry_count = 1
    std.mem.writeInt(u32, buf[pos..][0..4], 1, .little);
    pos += 4;
    // label_id = 1
    std.mem.writeInt(u32, buf[pos..][0..4], 1, .little);
    pos += 4;
    // index_type = 0xFF (invalid)
    buf[pos] = 0xFF;
    pos += 1;
    // state = 0 (valid)
    buf[pos] = 0;
    pos += 1;
    // key_len = 3
    std.mem.writeInt(u16, buf[pos..][0..2], 3, .little);
    pos += 2;
    // key = "foo"
    @memcpy(buf[pos..][0..3], "foo");
    pos += 3;

    const file = try std.fs.cwd().createFile(full_path, .{});
    try file.writeAll(buf[0..pos]);
    file.close();

    var catalog = IndexCatalog.init(testing.allocator);
    defer catalog.deinit();

    try testing.expectError(error.InvalidData, catalog.loadFromFile(full_path));
}

test "loadFromFile rejects invalid state byte" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path);

    const full_path = try std.fmt.allocPrint(testing.allocator, "{s}/bad_state.bin", .{path});
    defer testing.allocator.free(full_path);

    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    std.mem.writeInt(u32, buf[pos..][0..4], 1, .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 1, .little);
    pos += 4;
    // index_type = 0 (valid: btree_property)
    buf[pos] = 0;
    pos += 1;
    // state = 0xAA (invalid)
    buf[pos] = 0xAA;
    pos += 1;
    std.mem.writeInt(u16, buf[pos..][0..2], 3, .little);
    pos += 2;
    @memcpy(buf[pos..][0..3], "bar");
    pos += 3;

    const file = try std.fs.cwd().createFile(full_path, .{});
    try file.writeAll(buf[0..pos]);
    file.close();

    var catalog = IndexCatalog.init(testing.allocator);
    defer catalog.deinit();

    try testing.expectError(error.InvalidData, catalog.loadFromFile(full_path));
}

test {
    std.testing.refAllDecls(@This());
}
