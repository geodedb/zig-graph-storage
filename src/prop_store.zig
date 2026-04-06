// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const types = @import("types.zig");
const page_mod = @import("page.zig");
const property_mod = @import("property.zig");
const buffer_pool_mod = @import("buffer_pool.zig");
const free_space_mod = @import("free_space.zig");
const var_store_mod = @import("var_store.zig");
const interface_mod = @import("interface.zig");

const Allocator = std.mem.Allocator;
const BufferPool = buffer_pool_mod.BufferPool;
const FreeSpaceManager = free_space_mod.FreeSpaceManager;
const VarStore = var_store_mod.VarStore;
const PropertyValue = types.PropertyValue;
const PropertyEntry = interface_mod.PropertyEntry;
const PageId = types.PageId;
const PAGE_HEADER_SIZE = page_mod.PAGE_HEADER_SIZE;

/// Property page metadata offsets (after PAGE_HEADER_SIZE):
/// - [0..8): next_page (u64), pointer to overflow property page
/// - [8..12): entry_count (u32), number of property entries on this page
/// - [12..): entries, each: key_len(2) + key_bytes + encoded_value_bytes
const PROP_META_SIZE: u32 = 12; // next_page(8) + entry_count(4)
const PROP_DATA_OFFSET: u32 = PAGE_HEADER_SIZE + PROP_META_SIZE;

/// Slotted-page property storage with overflow.
/// For v1, uses a simple sequential layout within each property page.
pub const PropStore = struct {
    buffer_pool: *BufferPool,
    free_space: *FreeSpaceManager,
    var_store: *VarStore,
    page_size: u32,

    pub fn init(buffer_pool: *BufferPool, free_space: *FreeSpaceManager, var_store: *VarStore, page_size: u32) PropStore {
        return .{
            .buffer_pool = buffer_pool,
            .free_space = free_space,
            .var_store = var_store,
            .page_size = page_size,
        };
    }

    /// Usable data bytes per property page.
    fn dataCapacity(self: *const PropStore) u32 {
        return self.page_size - PROP_DATA_OFFSET;
    }

    /// Get a property value by key from a property page chain.
    /// Returns null if not found.
    pub fn getProperty(self: *PropStore, prop_head: u64, key: []const u8, allocator: Allocator) !?PropertyValue {
        if (prop_head == 0) return null;

        var current_page: PageId = prop_head;
        while (current_page != 0) {
            const frame = try self.buffer_pool.pin(.props, current_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const data = frame.dataSlice();

            const next_page = readNextPage(data);
            const entry_count = readEntryCount(data);

            // Scan entries — only decode the value when the key matches
            var offset: u32 = PROP_DATA_OFFSET;
            var i: u32 = 0;
            while (i < entry_count) : (i += 1) {
                const key_len = std.mem.bytesToValue(u16, data[offset..][0..2]);
                offset += 2;
                const entry_key = data[offset..][0..key_len];
                offset += key_len;

                if (std.mem.eql(u8, entry_key, key)) {
                    // Found it — decode the value
                    const decode_result = try property_mod.decode(allocator, data[offset..]);
                    self.buffer_pool.unpin(frame_idx, false);
                    return decode_result.value;
                }

                // Not the key we want: skip value by encoded size (no heap alloc)
                const val_size = try encodedSizeFromBytes(data[offset..]);
                offset += @intCast(val_size);
            }

            self.buffer_pool.unpin(frame_idx, false);
            current_page = next_page;
        }

        return null;
    }

    pub const PropertyEntrySlice = struct {
        key: []const u8,
        encoded_value: []const u8,
    };

    pub const PropIterator = struct {
        store: *PropStore,
        current_page: u64,
        current_frame_idx: ?u32 = null,
        current_index: u32 = 0,
        current_offset: u32 = PROP_DATA_OFFSET,
        entry_count_cache: u32 = 0,

        pub fn deinit(self: *PropIterator) void {
            if (self.current_frame_idx) |idx| {
                self.store.buffer_pool.unpin(idx, false);
                self.current_frame_idx = null;
            }
        }

        pub fn next(self: *PropIterator) anyerror!?PropertyEntrySlice {
            while (self.current_page != 0) {
                if (self.current_frame_idx == null) {
                    const frame = try self.store.buffer_pool.pin(.props, self.current_page);
                    self.current_frame_idx = self.store.buffer_pool.frameIndex(frame);
                    const data = frame.dataSlice();
                    self.entry_count_cache = readEntryCount(data);
                    self.current_offset = PROP_DATA_OFFSET;
                }

                const frame = &self.store.buffer_pool.frames[self.current_frame_idx.?];
                const data = frame.dataSlice();

                if (self.current_index < self.entry_count_cache) {
                    const key_len = std.mem.bytesToValue(u16, data[self.current_offset..][0..2]);
                    self.current_offset += 2;

                    const entry_key = data[self.current_offset..][0..key_len];
                    self.current_offset += key_len;

                    const val_size = try encodedSizeFromBytes(data[self.current_offset..]);
                    const encoded_val = data[self.current_offset..][0..val_size];
                    self.current_offset += @intCast(val_size);

                    self.current_index += 1;

                    return PropertyEntrySlice{
                        .key = entry_key,
                        .encoded_value = encoded_val,
                    };
                }

                const next_page = readNextPage(data);
                self.store.buffer_pool.unpin(self.current_frame_idx.?, false);
                self.current_frame_idx = null;
                self.current_page = next_page;
                self.current_index = 0;
                self.current_offset = PROP_DATA_OFFSET;
            }

            return null;
        }
    };

    /// Get an iterator over all properties in a property page chain (zero allocation).
    pub fn getAllProperties(self: *PropStore, prop_head: u64) PropIterator {
        return .{
            .store = self,
            .current_page = prop_head,
        };
    }

    /// Put a property. Returns the (possibly new) prop_head.
    /// If the key already exists, it is replaced (remove + re-add).
    ///
    /// PERF-0002: Combined find-and-remove pass reduces 3 chain traversals
    /// to at most 2 (find+remove in pass 1, insert in pass 2).
    pub fn putProperty(self: *PropStore, prop_head: u64, key: []const u8, val: PropertyValue) !u64 {
        // Encode value up front (needed for size calculation)
        const encoded_val = try property_mod.encode(self.buffer_pool.allocator, val);
        defer self.buffer_pool.allocator.free(encoded_val);

        const entry_size: u32 = 2 + @as(u32, @intCast(key.len)) + @as(u32, @intCast(encoded_val.len));

        if (prop_head == 0) {
            // Allocate new property page
            const new_page = try self.free_space.allocPage();
            const frame = try self.buffer_pool.pinNew(.props, new_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const data = frame.dataSlice();

            writeNextPage(data, 0);
            writeEntryCount(data, 1);
            self.writePropertyEntry(data, PROP_DATA_OFFSET, key, encoded_val);

            self.buffer_pool.unpin(frame_idx, true);
            return new_page;
        }

        // Pass 1: Scan chain to find and remove existing key (combined find+remove).
        // This replaces the separate getProperty + removeProperty calls.
        var current_page: PageId = prop_head;
        while (current_page != 0) {
            const frame = try self.buffer_pool.pin(.props, current_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const data = frame.dataSlice();

            const next_page = readNextPage(data);
            var entry_count = readEntryCount(data);

            var offset: u32 = PROP_DATA_OFFSET;
            var i: u32 = 0;
            while (i < entry_count) : (i += 1) {
                const entry_start = offset;
                const key_len = std.mem.bytesToValue(u16, data[offset..][0..2]);
                offset += 2;
                const entry_key = data[offset..][0..key_len];
                offset += key_len;

                const val_size = try encodedSizeFromBytes(data[offset..]);
                offset += @intCast(val_size);

                if (std.mem.eql(u8, entry_key, key)) {
                    // Found existing key: compact it out (same logic as removeProperty).
                    // Scan remaining entries to find total used end.
                    var ri: u32 = i + 1;
                    var scan_end = offset;
                    while (ri < entry_count) : (ri += 1) {
                        const rkl = std.mem.bytesToValue(u16, data[scan_end..][0..2]);
                        scan_end += 2;
                        scan_end += rkl;
                        const rsize = try encodedSizeFromBytes(data[scan_end..]);
                        scan_end += @intCast(rsize);
                    }

                    const remaining = scan_end - offset;
                    if (remaining > 0) {
                        std.mem.copyForwards(u8, data[entry_start..], data[offset..][0..remaining]);
                    }
                    const new_end = entry_start + remaining;
                    @memset(data[new_end..scan_end], 0);

                    entry_count -= 1;
                    writeEntryCount(data, entry_count);
                    self.buffer_pool.unpin(frame_idx, true);

                    // Key removed; now fall through to pass 2 (insert)
                    break;
                }
            } else {
                // Didn't find key on this page, move to next
                self.buffer_pool.unpin(frame_idx, false);
                current_page = next_page;
                continue;
            }
            // If we broke out of the inner loop (key found and removed), stop pass 1
            break;
        }

        // Pass 2: Find space and insert the new entry
        current_page = prop_head;
        while (current_page != 0) {
            const frame = try self.buffer_pool.pin(.props, current_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const data = frame.dataSlice();

            const next_page = readNextPage(data);
            const entry_count = readEntryCount(data);

            // Compute used space inline (avoids separate usedBytes rescan)
            var used: u32 = 0;
            {
                var scan_off: u32 = PROP_DATA_OFFSET;
                var ei: u32 = 0;
                while (ei < entry_count) : (ei += 1) {
                    const kl = std.mem.bytesToValue(u16, data[scan_off..][0..2]);
                    scan_off += 2;
                    scan_off += kl;
                    const esize = try encodedSizeFromBytes(data[scan_off..]);
                    scan_off += @intCast(esize);
                }
                used = scan_off - PROP_DATA_OFFSET;
            }
            const available = self.dataCapacity() - used;

            if (available >= entry_size) {
                // Append here
                const write_offset = PROP_DATA_OFFSET + used;
                self.writePropertyEntry(data, write_offset, key, encoded_val);
                writeEntryCount(data, entry_count + 1);
                self.buffer_pool.unpin(frame_idx, true);
                return prop_head;
            }

            if (next_page == 0) {
                // Allocate overflow page
                const new_page = try self.free_space.allocPage();
                const new_frame = try self.buffer_pool.pinNew(.props, new_page);
                const new_frame_idx = self.buffer_pool.frameIndex(new_frame);
                const new_data = new_frame.dataSlice();

                writeNextPage(new_data, 0);
                writeEntryCount(new_data, 1);
                self.writePropertyEntry(new_data, PROP_DATA_OFFSET, key, encoded_val);
                self.buffer_pool.unpin(new_frame_idx, true);

                // Link from current page
                writeNextPage(data, new_page);
                self.buffer_pool.unpin(frame_idx, true);
                return prop_head;
            }

            self.buffer_pool.unpin(frame_idx, false);
            current_page = next_page;
        }

        unreachable;
    }

    /// Remove a property by key. Scans all pages in the chain.
    /// Compacts the page by shifting remaining entries forward.
    pub fn removeProperty(self: *PropStore, prop_head: u64, key: []const u8) !void {
        if (prop_head == 0) return;

        var current_page: PageId = prop_head;
        while (current_page != 0) {
            const frame = try self.buffer_pool.pin(.props, current_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const data = frame.dataSlice();

            const next_page = readNextPage(data);
            var entry_count = readEntryCount(data);

            var offset: u32 = PROP_DATA_OFFSET;
            var i: u32 = 0;
            while (i < entry_count) : (i += 1) {
                const entry_start = offset;
                const key_len = std.mem.bytesToValue(u16, data[offset..][0..2]);
                offset += 2;
                const entry_key = data[offset..][0..key_len];
                offset += key_len;

                // Skip value bytes by encoded size (no heap alloc)
                const val_size = encodedSizeFromBytes(data[offset..]) catch {
                    self.buffer_pool.unpin(frame_idx, false);
                    return;
                };
                offset += @intCast(val_size);

                if (std.mem.eql(u8, entry_key, key)) {
                    // Found: shift remaining entries
                    const total_used = PROP_DATA_OFFSET + try self.usedBytes(data, entry_count);
                    const remaining = total_used - offset;
                    if (remaining > 0) {
                        std.mem.copyForwards(u8, data[entry_start..], data[offset..][0..remaining]);
                    }
                    // Zero out the freed space
                    const new_end = entry_start + remaining;
                    @memset(data[new_end..total_used], 0);

                    entry_count -= 1;
                    writeEntryCount(data, entry_count);
                    self.buffer_pool.unpin(frame_idx, true);
                    return;
                }
            }

            self.buffer_pool.unpin(frame_idx, false);
            current_page = next_page;
        }
    }

    // Internal helpers

    fn writePropertyEntry(_: *const PropStore, data: []u8, offset: u32, key: []const u8, encoded_val: []const u8) void {
        var off = offset;
        const key_len: u16 = @intCast(key.len);
        @memcpy(data[off..][0..2], &std.mem.toBytes(key_len));
        off += 2;
        @memcpy(data[off..][0..key.len], key);
        off += @intCast(key.len);
        @memcpy(data[off..][0..encoded_val.len], encoded_val);
    }

    fn usedBytes(_: *const PropStore, data: []const u8, entry_count: u32) !u32 {
        var i: u32 = 0;
        var off: u32 = PROP_DATA_OFFSET;
        while (i < entry_count) : (i += 1) {
            const key_len = std.mem.bytesToValue(u16, data[off..][0..2]);
            off += 2;
            off += key_len;
            const esize = try encodedSizeFromBytes(data[off..]);
            off += @intCast(esize);
        }
        return off - PROP_DATA_OFFSET;
    }
};

/// Determine the encoded size of a property value from its raw bytes.
/// This avoids needing to fully decode the value.
fn encodedSizeFromBytes(bytes: []const u8) error{InvalidData}!usize {
    if (bytes.len < 1) return 0;
    const tag: property_mod.Tag = std.meta.intToEnum(property_mod.Tag, bytes[0]) catch return error.InvalidData;
    return switch (tag) {
        .null => 1,
        .bool => 2,
        .int => 9,
        .float => 9,
        .string => blk: {
            if (bytes.len < 5) break :blk 1;
            const len = std.mem.bytesToValue(u32, bytes[1..5]);
            break :blk 5 + @as(usize, len);
        },
        .decimal => 18,
        .ext => blk: {
            if (bytes.len < 7) break :blk 1;
            const data_len = std.mem.bytesToValue(u32, bytes[3..7]);
            break :blk 7 + @as(usize, data_len);
        },
    };
}

fn readNextPage(data: []const u8) PageId {
    return std.mem.bytesToValue(u64, data[PAGE_HEADER_SIZE..][0..8]);
}

fn readEntryCount(data: []const u8) u32 {
    return std.mem.bytesToValue(u32, data[PAGE_HEADER_SIZE + 8 ..][0..4]);
}

fn writeNextPage(data: []u8, page_id: PageId) void {
    @memcpy(data[PAGE_HEADER_SIZE..][0..8], &std.mem.toBytes(page_id));
}

fn writeEntryCount(data: []u8, count: u32) void {
    @memcpy(data[PAGE_HEADER_SIZE + 8 ..][0..4], &std.mem.toBytes(count));
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;
const pager_mod = @import("pager.zig");
const Pager = pager_mod.Pager;

const TestEnv = struct {
    pool: BufferPool,
    fsm: FreeSpaceManager,
    vs: VarStore,
    tmp_dir: testing.TmpDir,
    prop_file: std.fs.File,
    prop_pager: Pager,
    var_file: std.fs.File,
    var_pager: Pager,

    fn init() !TestEnv {
        var tmp_dir = testing.tmpDir(.{});
        const prop_file = tmp_dir.dir.createFile("props.store", .{ .read = true, .truncate = true }) catch unreachable;
        const var_file = tmp_dir.dir.createFile("var.store", .{ .read = true, .truncate = true }) catch unreachable;

        var pool = try BufferPool.init(testing.allocator, 4096, 32);
        const fsm = try FreeSpaceManager.init(testing.allocator, &pool, .props);

        return .{
            .pool = pool,
            .fsm = fsm,
            .vs = undefined, // set in fixup
            .tmp_dir = tmp_dir,
            .prop_file = prop_file,
            .prop_pager = Pager.init(prop_file, 4096),
            .var_file = var_file,
            .var_pager = Pager.init(var_file, 4096),
        };
    }

    fn fixup(self: *TestEnv) void {
        self.pool.registerPager(.props, &self.prop_pager);
        self.pool.registerPager(.var_store, &self.var_pager);
        self.fsm.buffer_pool = &self.pool;
        self.vs = VarStore.init(&self.pool, &self.fsm, 4096);
    }

    fn deinit(self: *TestEnv) void {
        self.fsm.deinit();
        self.pool.deinit();
        self.prop_file.close();
        self.var_file.close();
        self.tmp_dir.cleanup();
    }
};

test "putProperty + getProperty round-trip: int" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = PropStore.init(&env.pool, &env.fsm, &env.vs, 4096);

    const head = try store.putProperty(0, "age", .{ .int = 30 });
    try testing.expect(head != 0);

    const val = try store.getProperty(head, "age", testing.allocator);
    try testing.expect(val != null);
    try testing.expectEqual(@as(i64, 30), val.?.int);
}

test "putProperty + getProperty round-trip: string" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = PropStore.init(&env.pool, &env.fsm, &env.vs, 4096);

    const head = try store.putProperty(0, "name", .{ .string = "Alice" });

    const val = try store.getProperty(head, "name", testing.allocator);
    try testing.expect(val != null);
    defer property_mod.freeDecoded(testing.allocator, val.?);
    try testing.expectEqualStrings("Alice", val.?.string);
}

test "putProperty + getProperty round-trip: bool" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = PropStore.init(&env.pool, &env.fsm, &env.vs, 4096);

    const head = try store.putProperty(0, "active", .{ .bool = true });
    const val = try store.getProperty(head, "active", testing.allocator);
    try testing.expect(val != null);
    try testing.expect(val.?.bool);
}

test "putProperty + getProperty round-trip: float" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = PropStore.init(&env.pool, &env.fsm, &env.vs, 4096);

    const head = try store.putProperty(0, "score", .{ .float = 3.14 });
    const val = try store.getProperty(head, "score", testing.allocator);
    try testing.expect(val != null);
    try testing.expectApproxEqAbs(@as(f64, 3.14), val.?.float, 0.001);
}

test "putProperty + getProperty round-trip: null" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = PropStore.init(&env.pool, &env.fsm, &env.vs, 4096);

    const head = try store.putProperty(0, "nothing", PropertyValue.null);
    const val = try store.getProperty(head, "nothing", testing.allocator);
    try testing.expect(val != null);
    try testing.expectEqual(PropertyValue.null, val.?);
}

test "getAllProperties returns all stored properties" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = PropStore.init(&env.pool, &env.fsm, &env.vs, 4096);

    var head = try store.putProperty(0, "name", .{ .string = "Bob" });
    head = try store.putProperty(head, "age", .{ .int = 25 });
    head = try store.putProperty(head, "active", .{ .bool = false });

    var iter = store.getAllProperties(head);
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |_| {
        count += 1;
    }

    try testing.expectEqual(@as(usize, 3), count);
}

test "removeProperty removes the property" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = PropStore.init(&env.pool, &env.fsm, &env.vs, 4096);

    var head = try store.putProperty(0, "x", .{ .int = 1 });
    head = try store.putProperty(head, "y", .{ .int = 2 });
    head = try store.putProperty(head, "z", .{ .int = 3 });

    try store.removeProperty(head, "y");

    const val = try store.getProperty(head, "y", testing.allocator);
    try testing.expect(val == null);

    // x and z should still be there
    const vx = try store.getProperty(head, "x", testing.allocator);
    try testing.expect(vx != null);
    try testing.expectEqual(@as(i64, 1), vx.?.int);

    const vz = try store.getProperty(head, "z", testing.allocator);
    try testing.expect(vz != null);
    try testing.expectEqual(@as(i64, 3), vz.?.int);
}

test "multiple properties on same entity" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = PropStore.init(&env.pool, &env.fsm, &env.vs, 4096);

    var head = try store.putProperty(0, "a", .{ .int = 1 });
    head = try store.putProperty(head, "b", .{ .int = 2 });
    head = try store.putProperty(head, "c", .{ .int = 3 });
    head = try store.putProperty(head, "d", .{ .int = 4 });

    const va = try store.getProperty(head, "a", testing.allocator);
    try testing.expectEqual(@as(i64, 1), va.?.int);

    const vd = try store.getProperty(head, "d", testing.allocator);
    try testing.expectEqual(@as(i64, 4), vd.?.int);
}

test "getProperty returns null for nonexistent key" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = PropStore.init(&env.pool, &env.fsm, &env.vs, 4096);

    const head = try store.putProperty(0, "x", .{ .int = 1 });
    const val = try store.getProperty(head, "nope", testing.allocator);
    try testing.expect(val == null);
}

test "getProperty returns null for empty prop_head" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = PropStore.init(&env.pool, &env.fsm, &env.vs, 4096);

    const val = try store.getProperty(0, "anything", testing.allocator);
    try testing.expect(val == null);
}

test "encodedSizeFromBytes rejects invalid property tag byte" {
    const bad_bytes = [_]u8{0xFF}; // 0xFF is not a valid property_mod.Tag
    try testing.expectError(error.InvalidData, encodedSizeFromBytes(&bad_bytes));
}

test "encodedSizeFromBytes returns 0 for empty input" {
    const empty: []const u8 = &.{};
    const result = try encodedSizeFromBytes(empty);
    try testing.expectEqual(@as(usize, 0), result);
}

test {
    std.testing.refAllDecls(@This());
}
