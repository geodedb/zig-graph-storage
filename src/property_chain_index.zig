// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

const Allocator = std.mem.Allocator;
const SNAPSHOT_MAGIC = "GSPIDX1\x00";

pub const PropertyDigest = struct {
    key: []u8,
    value_hash: u64,
};

pub const PropertyChain = struct {
    entries: std.ArrayList(PropertyDigest),

    pub fn init() PropertyChain {
        return .{ .entries = .{} };
    }

    pub fn clear(self: *PropertyChain, allocator: Allocator) void {
        for (self.entries.items) |entry| {
            allocator.free(entry.key);
        }
        self.entries.clearAndFree(allocator);
    }

    pub fn deinit(self: *PropertyChain, allocator: Allocator) void {
        self.clear(allocator);
        self.entries.deinit(allocator);
    }

    pub fn hasKey(self: *const PropertyChain, key: []const u8) bool {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return true;
        }
        return false;
    }
};

/// A persisted digest of each property chain keyed by prop_head.
/// This lets the engine quickly reject missing keys before walking props.store,
/// and persists that derived state to props.idx.
pub const PropertyChainIndex = struct {
    allocator: Allocator,
    chains: std.AutoHashMap(u64, PropertyChain),

    pub fn init(allocator: Allocator) PropertyChainIndex {
        return .{
            .allocator = allocator,
            .chains = std.AutoHashMap(u64, PropertyChain).init(allocator),
        };
    }

    pub fn clear(self: *PropertyChainIndex) void {
        var it = self.chains.valueIterator();
        while (it.next()) |chain| {
            @constCast(chain).deinit(self.allocator);
        }
        self.chains.clearAndFree();
    }

    pub fn deinit(self: *PropertyChainIndex) void {
        self.clear();
        self.chains.deinit();
    }

    pub fn containsChain(self: *const PropertyChainIndex, prop_head: u64) bool {
        return self.chains.contains(prop_head);
    }

    pub fn hasKey(self: *const PropertyChainIndex, prop_head: u64, key: []const u8) bool {
        const chain = self.chains.getPtr(prop_head) orelse return false;
        return chain.hasKey(key);
    }

    pub fn removeChain(self: *PropertyChainIndex, prop_head: u64) void {
        const removed = self.chains.fetchRemove(prop_head) orelse return;
        var chain = removed.value;
        chain.deinit(self.allocator);
    }

    pub fn refreshFromIterator(self: *PropertyChainIndex, prop_head: u64, iterator: anytype) !void {
        if (prop_head == 0) {
            self.removeChain(prop_head);
            return;
        }

        const gop = try self.chains.getOrPut(prop_head);
        if (!gop.found_existing) {
            gop.value_ptr.* = PropertyChain.init();
        } else {
            gop.value_ptr.clear(self.allocator);
        }

        errdefer {
            if (!gop.found_existing) {
                _ = self.chains.remove(prop_head);
            } else {
                gop.value_ptr.clear(self.allocator);
            }
        }

        while (try iterator.next()) |entry| {
            const key_copy = try self.allocator.dupe(u8, entry.key);
            errdefer self.allocator.free(key_copy);

            try gop.value_ptr.entries.append(self.allocator, .{
                .key = key_copy,
                .value_hash = std.hash.Wyhash.hash(0, entry.encoded_value),
            });
        }

        if (gop.value_ptr.entries.items.len == 0) {
            self.removeChain(prop_head);
        }
    }

    /// Persist the property-chain digest map to props.idx.
    /// Format:
    ///   [8 bytes magic][u64 checkpoint_counter][u64 chain_count]
    ///   repeated chain_count times:
    ///     [u64 prop_head][u32 entry_count]
    ///     repeated entry_count times:
    ///       [u16 key_len][key bytes][u64 value_hash]
    pub fn saveToFile(self: *const PropertyChainIndex, file: *std.fs.File, checkpoint_counter: u64) !void {
        try file.setEndPos(0);
        try file.seekTo(0);
        try file.writeAll(SNAPSHOT_MAGIC);

        var u64_buf: [8]u8 = undefined;
        var u32_buf: [4]u8 = undefined;
        var u16_buf: [2]u8 = undefined;

        std.mem.writeInt(u64, &u64_buf, checkpoint_counter, .little);
        try file.writeAll(&u64_buf);

        std.mem.writeInt(u64, &u64_buf, self.chains.count(), .little);
        try file.writeAll(&u64_buf);

        var it = self.chains.iterator();
        while (it.next()) |entry| {
            std.mem.writeInt(u64, &u64_buf, entry.key_ptr.*, .little);
            try file.writeAll(&u64_buf);

            std.mem.writeInt(u32, &u32_buf, @intCast(entry.value_ptr.entries.items.len), .little);
            try file.writeAll(&u32_buf);

            for (entry.value_ptr.entries.items) |digest| {
                std.mem.writeInt(u16, &u16_buf, @intCast(digest.key.len), .little);
                try file.writeAll(&u16_buf);
                try file.writeAll(digest.key);

                std.mem.writeInt(u64, &u64_buf, digest.value_hash, .little);
                try file.writeAll(&u64_buf);
            }
        }
    }

    /// Load a previously persisted props.idx snapshot.
    /// Returns the checkpoint counter embedded in the snapshot, or null when
    /// the file is empty.
    pub fn loadFromFile(self: *PropertyChainIndex, file: *std.fs.File) !?u64 {
        const stat = try file.stat();
        if (stat.size == 0) return null;

        const size: usize = @intCast(stat.size);
        const data = try self.allocator.alloc(u8, size);
        defer self.allocator.free(data);

        try file.seekTo(0);
        const bytes_read = try file.readAll(data);
        if (bytes_read != size) return error.UnexpectedEndOfFile;
        if (size < SNAPSHOT_MAGIC.len + 16) return error.InvalidFormat;
        if (!std.mem.eql(u8, data[0..SNAPSHOT_MAGIC.len], SNAPSHOT_MAGIC)) {
            return error.InvalidFormat;
        }

        self.clear();
        errdefer self.clear();

        var offset: usize = SNAPSHOT_MAGIC.len;
        const checkpoint_counter = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;

        const chain_count = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;

        var i: u64 = 0;
        while (i < chain_count) : (i += 1) {
            if (offset + 12 > data.len) return error.InvalidFormat;

            const prop_head = std.mem.readInt(u64, data[offset..][0..8], .little);
            offset += 8;

            const entry_count = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;

            const gop = try self.chains.getOrPut(prop_head);
            if (!gop.found_existing) {
                gop.value_ptr.* = PropertyChain.init();
            }

            try gop.value_ptr.entries.ensureTotalCapacity(self.allocator, entry_count);

            var j: u32 = 0;
            while (j < entry_count) : (j += 1) {
                if (offset + 2 > data.len) return error.InvalidFormat;
                const key_len = std.mem.readInt(u16, data[offset..][0..2], .little);
                offset += 2;

                if (offset + key_len + 8 > data.len) return error.InvalidFormat;
                const key_copy = try self.allocator.dupe(u8, data[offset .. offset + key_len]);
                offset += key_len;

                const value_hash = std.mem.readInt(u64, data[offset..][0..8], .little);
                offset += 8;

                gop.value_ptr.entries.appendAssumeCapacity(.{
                    .key = key_copy,
                    .value_hash = value_hash,
                });
            }
        }

        if (offset != data.len) return error.InvalidFormat;
        return checkpoint_counter;
    }
};

const testing = std.testing;

const TestIterEntry = struct {
    key: []const u8,
    encoded_value: []const u8,
};

const TestIterator = struct {
    entries: []const TestIterEntry,
    index: usize = 0,

    fn next(self: *TestIterator) !?TestIterEntry {
        if (self.index >= self.entries.len) return null;
        defer self.index += 1;
        return self.entries[self.index];
    }
};

test "refreshFromIterator indexes keys and supports membership checks" {
    var idx = PropertyChainIndex.init(testing.allocator);
    defer idx.deinit();

    var iter = TestIterator{
        .entries = &[_]TestIterEntry{
            .{ .key = "name", .encoded_value = "Alice" },
            .{ .key = "age", .encoded_value = "30" },
        },
    };

    try idx.refreshFromIterator(99, &iter);

    try testing.expect(idx.containsChain(99));
    try testing.expect(idx.hasKey(99, "name"));
    try testing.expect(idx.hasKey(99, "age"));
    try testing.expect(!idx.hasKey(99, "email"));
}

test "saveToFile + loadFromFile round-trip preserves chain metadata" {
    var idx = PropertyChainIndex.init(testing.allocator);
    defer idx.deinit();

    var iter = TestIterator{
        .entries = &[_]TestIterEntry{
            .{ .key = "name", .encoded_value = "Alice" },
            .{ .key = "active", .encoded_value = "\x01" },
        },
    };
    try idx.refreshFromIterator(7, &iter);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("props.idx", .{ .read = true, .truncate = true });
    defer file.close();

    try idx.saveToFile(&file, 123);

    var loaded = PropertyChainIndex.init(testing.allocator);
    defer loaded.deinit();

    const checkpoint_counter = try loaded.loadFromFile(&file);
    try testing.expect(checkpoint_counter != null);
    try testing.expectEqual(@as(u64, 123), checkpoint_counter.?);
    try testing.expect(loaded.containsChain(7));
    try testing.expect(loaded.hasKey(7, "name"));
    try testing.expect(loaded.hasKey(7, "active"));
    try testing.expect(!loaded.hasKey(7, "missing"));
}
