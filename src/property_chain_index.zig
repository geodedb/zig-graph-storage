// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const index_snapshot_mod = @import("index_snapshot.zig");

const Allocator = std.mem.Allocator;
// SEC-0051: v2 snapshot format appends a trailing CRC32 over the payload.
/// GAP warm-reopen P2: pub so engine_index.restampCleanDerivedSnapshots can
/// validate the file before an in-place counter restamp.
pub const SNAPSHOT_MAGIC = "GSPIDX2\x00";

// SEC-0044/SEC-0048: smallest bytes a single chain record consumes on disk
// (prop_head u64 + entry_count u32, with zero entries).
const CHAIN_RECORD_MIN_SIZE: usize = 8 + 4;

// SEC-0044/SEC-0048: smallest bytes a single chain entry consumes on disk
// (key_len u16 + zero-length key + value_hash u64).
const ENTRY_RECORD_MIN_SIZE: usize = 2 + 8;

pub const PropertyDigest = struct {
    key: []u8,
    value_hash: u64,
};

pub const PropertyChain = struct {
    entries: std.ArrayList(PropertyDigest),

    pub fn init() PropertyChain {
        return .{ .entries = .empty };
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

    pub fn upsertKey(self: *PropertyChainIndex, prop_head: u64, key: []const u8, encoded_value: []const u8) !void {
        if (prop_head == 0) return;

        const gop = try self.chains.getOrPut(prop_head);
        if (!gop.found_existing) {
            gop.value_ptr.* = PropertyChain.init();
        }

        for (gop.value_ptr.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                // fips-exempt: non-security — property value fingerprint for index
                // equality lookup; not a secret.
                entry.value_hash = std.hash.Wyhash.hash(0, encoded_value);
                return;
            }
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        try gop.value_ptr.entries.append(self.allocator, .{
            .key = key_copy,
            // fips-exempt: non-security — property value fingerprint for index
            // equality lookup; not a secret.
            .value_hash = std.hash.Wyhash.hash(0, encoded_value),
        });
    }

    pub fn removeKey(self: *PropertyChainIndex, prop_head: u64, key: []const u8) void {
        const chain = self.chains.getPtr(prop_head) orelse return;

        var idx: usize = 0;
        while (idx < chain.entries.items.len) : (idx += 1) {
            if (std.mem.eql(u8, chain.entries.items[idx].key, key)) {
                self.allocator.free(chain.entries.items[idx].key);
                _ = chain.entries.orderedRemove(idx);
                if (chain.entries.items.len == 0) {
                    self.removeChain(prop_head);
                }
                return;
            }
        }
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
                // GAP-ENT-0022(b): removeChain, not a bare map remove — the
                // partially-built chain owns duped keys and list capacity
                // that a bare remove leaked on this OOM path (exposed by
                // the slab error-injection sweep).
                self.removeChain(prop_head);
            } else {
                gop.value_ptr.clear(self.allocator);
            }
        }

        while (try iterator.next()) |entry| {
            const key_copy = try self.allocator.dupe(u8, entry.key);
            errdefer self.allocator.free(key_copy);

            try gop.value_ptr.entries.append(self.allocator, .{
                .key = key_copy,
                // fips-exempt: non-security — property value fingerprint for index
                // equality lookup; not a secret.
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
    pub fn saveToFile(self: *const PropertyChainIndex, file: *std.Io.File, checkpoint_counter: u64) !void {
        // PERF-0052: serialize the whole snapshot into one in-memory buffer and
        // flush it with a single positional write instead of ~3 syscalls per
        // chain entry. Byte layout and trailing CRC32 (SEC-0051) are unchanged.
        var w = index_snapshot_mod.SnapshotWriter.init(self.allocator);
        defer w.deinit();

        try w.writeHeader(SNAPSHOT_MAGIC, checkpoint_counter, self.chains.count());

        var it = self.chains.iterator();
        while (it.next()) |entry| {
            try w.writeU64(entry.key_ptr.*);
            try w.writeU32(@intCast(entry.value_ptr.entries.items.len));

            for (entry.value_ptr.entries.items) |digest| {
                try w.writeU16(@intCast(digest.key.len));
                try w.writeBytes(digest.key);
                try w.writeU64(digest.value_hash);
            }
        }

        try w.finalize(file.*);
    }

    /// Load a previously persisted props.idx snapshot.
    /// Returns the checkpoint counter embedded in the snapshot, or null when
    /// the file is empty.
    pub fn loadFromFile(self: *PropertyChainIndex, file: *std.Io.File) !?u64 {
        // PERF-0052: read + validate the whole snapshot once (CRC32 per SEC-0051,
        // chain_count bounded vs payload per SEC-0044/0048), then walk the
        // resident payload instead of ~3 positional reads per chain entry.
        var snapshot = (try index_snapshot_mod.loadPayload(self.allocator, file, SNAPSHOT_MAGIC, CHAIN_RECORD_MIN_SIZE)) orelse return null;
        defer snapshot.deinit();

        self.clear();
        errdefer self.clear();

        var r = index_snapshot_mod.SnapshotReader.init(snapshot.payload());
        const chain_count = snapshot.item_count;

        var i: u64 = 0;
        while (i < chain_count) : (i += 1) {
            const prop_head = try r.readU64();
            const entry_count = try r.readU32();

            // SEC-0044/SEC-0048: bound the per-chain entry reservation against
            // the bytes still available before reserving capacity.
            if (entry_count > r.remaining() / ENTRY_RECORD_MIN_SIZE) return error.InvalidFormat;

            const gop = try self.chains.getOrPut(prop_head);
            if (!gop.found_existing) {
                gop.value_ptr.* = PropertyChain.init();
            }

            try gop.value_ptr.entries.ensureTotalCapacity(self.allocator, entry_count);

            var j: u32 = 0;
            while (j < entry_count) : (j += 1) {
                const key_len = try r.readU16();

                // readBytes borrows from the resident buffer; copy into an owned
                // allocation so the digest outlives the snapshot buffer.
                const key_src = try r.readBytes(key_len);
                const key_copy = try self.allocator.dupe(u8, key_src);
                errdefer self.allocator.free(key_copy);

                const value_hash = try r.readU64();

                gop.value_ptr.entries.appendAssumeCapacity(.{
                    .key = key_copy,
                    .value_hash = value_hash,
                });
            }
        }

        if (r.remaining() != 0) return error.InvalidFormat;
        return snapshot.checkpoint_counter;
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

    var file = try tmp.dir.createFile(std.Io.Threaded.global_single_threaded.io(), "props.idx", .{ .read = true, .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.io());

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

// SEC-0044/SEC-0048: a tiny props.idx that declares a huge chain count must be
// rejected with error.InvalidFormat rather than driving a giant reservation.
// std.testing.allocator additionally fails the test on any leak/over-alloc.
test "loadFromFile rejects an oversized chain_count (SEC-0044/0048)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    var file = try tmp.dir.createFile(io, "props.idx", .{ .read = true, .truncate = true });
    defer file.close(io);

    // Header declares maxInt(u64) chains but writes only a 1-byte payload.
    var write_offset: u64 = 0;
    try index_snapshot_mod.writeHeader(file, &write_offset, SNAPSHOT_MAGIC, 1, std.math.maxInt(u64));
    try file.writePositionalAll(io, &[_]u8{0}, write_offset);
    write_offset += 1;
    try index_snapshot_mod.finalizeChecksum(testing.allocator, file, write_offset);

    var loaded = PropertyChainIndex.init(testing.allocator);
    defer loaded.deinit();

    try testing.expectError(error.InvalidFormat, loaded.loadFromFile(&file));
}

// SEC-0044/SEC-0048: a valid chain header but an absurd per-chain entry_count
// must be rejected before reserving the entries list.
test "loadFromFile rejects an oversized entry_count (SEC-0044/0048)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    var file = try tmp.dir.createFile(io, "props.idx", .{ .read = true, .truncate = true });
    defer file.close(io);

    var write_offset: u64 = 0;
    try index_snapshot_mod.writeHeader(file, &write_offset, SNAPSHOT_MAGIC, 1, 1);
    // One chain: prop_head=7, entry_count=maxInt(u32) but no entry bytes follow.
    var buf: [12]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], 7, .little);
    std.mem.writeInt(u32, buf[8..12], std.math.maxInt(u32), .little);
    try file.writePositionalAll(io, &buf, write_offset);
    write_offset += buf.len;
    try index_snapshot_mod.finalizeChecksum(testing.allocator, file, write_offset);

    var loaded = PropertyChainIndex.init(testing.allocator);
    defer loaded.deinit();

    try testing.expectError(error.InvalidFormat, loaded.loadFromFile(&file));
}

// SEC-0051: flipping one payload byte (header intact) must be rejected as a
// checksum mismatch rather than silently loading corrupt data.
test "loadFromFile rejects a flipped payload byte (SEC-0051)" {
    var idx = PropertyChainIndex.init(testing.allocator);
    defer idx.deinit();

    var iter = TestIterator{
        .entries = &[_]TestIterEntry{
            .{ .key = "name", .encoded_value = "Alice" },
        },
    };
    try idx.refreshFromIterator(7, &iter);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    var file = try tmp.dir.createFile(io, "props.idx", .{ .read = true, .truncate = true });
    defer file.close(io);

    try idx.saveToFile(&file, 123);

    // Flip the first payload byte (just past magic + 16-byte header).
    const payload_off: u64 = SNAPSHOT_MAGIC.len + index_snapshot_mod.HEADER_FIELDS_SIZE;
    var orig: [1]u8 = undefined;
    _ = try file.readPositionalAll(io, &orig, payload_off);
    const flipped: [1]u8 = .{orig[0] ^ 0xFF};
    try file.writePositionalAll(io, &flipped, payload_off);

    var loaded = PropertyChainIndex.init(testing.allocator);
    defer loaded.deinit();

    try testing.expectError(error.ChecksumMismatch, loaded.loadFromFile(&file));
}
