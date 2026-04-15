// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const VarStore = @import("var_store.zig").VarStore;

/// Variable-length label storage backed by VarStore.
///
/// Labels are stored as a packed binary block:
///   [0..2)  u16 LE  count
///   [2..)   count * u32 LE  label IDs
///
/// A label_head of 0 means "no labels".
pub const LabelStore = struct {
    var_store: *VarStore,

    pub fn init(var_store: *VarStore) LabelStore {
        return .{ .var_store = var_store };
    }

    /// Read all label IDs for a node. Caller owns returned slice.
    pub fn getLabels(self: *LabelStore, label_head: u64, allocator: std.mem.Allocator) ![]u32 {
        if (label_head == 0) return try allocator.alloc(u32, 0);
        const data = try self.var_store.read(label_head, allocator);
        defer allocator.free(data);
        if (data.len < 2) return try allocator.alloc(u32, 0);
        const count = std.mem.readInt(u16, data[0..2], .little);
        const needed = 2 + @as(usize, count) * 4;
        if (data.len < needed) return try allocator.alloc(u32, 0);
        const result = try allocator.alloc(u32, count);
        for (0..count) |i| {
            const offset = 2 + i * 4;
            result[i] = std.mem.readInt(u32, data[offset..][0..4], .little);
        }
        return result;
    }

    /// Write label list, return new var.store reference. Returns 0 for empty list.
    pub fn putLabels(self: *LabelStore, labels: []const u32, allocator: std.mem.Allocator) !u64 {
        if (labels.len == 0) return 0;
        const count: u16 = @intCast(labels.len);
        const buf = try allocator.alloc(u8, 2 + labels.len * 4);
        defer allocator.free(buf);
        std.mem.writeInt(u16, buf[0..2], count, .little);
        for (labels, 0..) |label_id, i| {
            const offset = 2 + i * 4;
            std.mem.writeInt(u32, buf[offset..][0..4], label_id, .little);
        }
        return self.var_store.write(buf);
    }

    /// Add a label to the set. Returns the new label_head and updated count.
    pub fn addLabel(self: *LabelStore, label_head: u64, label_id: u32, allocator: std.mem.Allocator) !struct { head: u64, count: u16 } {
        const existing = try self.getLabels(label_head, allocator);
        defer allocator.free(existing);
        // Check for duplicates
        for (existing) |id| {
            if (id == label_id) return .{ .head = label_head, .count = @intCast(existing.len) };
        }
        const new_list = try allocator.alloc(u32, existing.len + 1);
        defer allocator.free(new_list);
        @memcpy(new_list[0..existing.len], existing);
        new_list[existing.len] = label_id;
        if (label_head != 0) try self.var_store.free(label_head);
        const new_head = try self.putLabels(new_list, allocator);
        return .{ .head = new_head, .count = @intCast(new_list.len) };
    }

    /// Remove a label from the set. Returns the new label_head and updated count.
    pub fn removeLabel(self: *LabelStore, label_head: u64, label_id: u32, allocator: std.mem.Allocator) !struct { head: u64, count: u16 } {
        const existing = try self.getLabels(label_head, allocator);
        defer allocator.free(existing);
        var new_list: std.ArrayList(u32) = .{};
        defer new_list.deinit(allocator);
        for (existing) |id| {
            if (id != label_id) try new_list.append(allocator, id);
        }
        if (label_head != 0) try self.var_store.free(label_head);
        if (new_list.items.len == 0) return .{ .head = 0, .count = 0 };
        const new_head = try self.putLabels(new_list.items, allocator);
        return .{ .head = new_head, .count = @intCast(new_list.items.len) };
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;
const buffer_pool_mod = @import("buffer_pool.zig");
const free_space_mod = @import("free_space.zig");
const pager_mod = @import("pager.zig");
const BufferPool = buffer_pool_mod.BufferPool;
const FreeSpaceManager = free_space_mod.FreeSpaceManager;
const Pager = pager_mod.Pager;
const VarStoreType = @import("var_store.zig").VarStore;

const TestEnv = struct {
    pool: BufferPool,
    fsm: FreeSpaceManager,
    tmp_dir: testing.TmpDir,
    var_file: std.Io.File,
    var_pager: Pager,
    vs: VarStoreType,

    fn create() !*TestEnv {
        const self = try testing.allocator.create(TestEnv);
        self.tmp_dir = testing.tmpDir(.{});
        self.var_file = self.tmp_dir.dir.createFile("var.store", .{ .read = true, .truncate = true }) catch unreachable;
        self.pool = try BufferPool.init(testing.allocator, 4096, 32);
        self.fsm = try FreeSpaceManager.init(testing.allocator, &self.pool, .var_store);
        self.var_pager = Pager.init(self.var_file, 4096);
        self.pool.registerPager(.var_store, &self.var_pager);
        self.fsm.buffer_pool = &self.pool;
        self.vs = VarStoreType.init(&self.pool, &self.fsm, 4096);
        return self;
    }

    fn deinit(self: *TestEnv) void {
        self.fsm.deinit();
        self.pool.deinit();
        self.var_file.close();
        self.tmp_dir.cleanup();
        testing.allocator.destroy(self);
    }
};

test "LabelStore: empty label_head returns empty slice" {
    const env = try TestEnv.create();
    defer env.deinit();

    var ls = LabelStore.init(&env.vs);
    const labels = try ls.getLabels(0, testing.allocator);
    defer testing.allocator.free(labels);
    try testing.expectEqual(@as(usize, 0), labels.len);
}

test "LabelStore: putLabels + getLabels round-trip" {
    const env = try TestEnv.create();
    defer env.deinit();

    var ls = LabelStore.init(&env.vs);

    const input = [_]u32{ 10, 20, 30 };
    const head = try ls.putLabels(&input, testing.allocator);
    try testing.expect(head != 0);

    const result = try ls.getLabels(head, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqual(@as(u32, 10), result[0]);
    try testing.expectEqual(@as(u32, 20), result[1]);
    try testing.expectEqual(@as(u32, 30), result[2]);
}

test "LabelStore: addLabel appends new label" {
    const env = try TestEnv.create();
    defer env.deinit();

    var ls = LabelStore.init(&env.vs);

    const r1 = try ls.addLabel(0, 5, testing.allocator);
    try testing.expect(r1.head != 0);
    try testing.expectEqual(@as(u16, 1), r1.count);

    const r2 = try ls.addLabel(r1.head, 10, testing.allocator);
    try testing.expectEqual(@as(u16, 2), r2.count);

    const labels = try ls.getLabels(r2.head, testing.allocator);
    defer testing.allocator.free(labels);
    try testing.expectEqual(@as(usize, 2), labels.len);
    try testing.expectEqual(@as(u32, 5), labels[0]);
    try testing.expectEqual(@as(u32, 10), labels[1]);
}

test "LabelStore: addLabel deduplicates" {
    const env = try TestEnv.create();
    defer env.deinit();

    var ls = LabelStore.init(&env.vs);

    const r1 = try ls.addLabel(0, 42, testing.allocator);
    const r2 = try ls.addLabel(r1.head, 42, testing.allocator);

    try testing.expectEqual(r1.head, r2.head);
    try testing.expectEqual(@as(u16, 1), r2.count);
}

test "LabelStore: removeLabel removes existing label" {
    const env = try TestEnv.create();
    defer env.deinit();

    var ls = LabelStore.init(&env.vs);

    var r = try ls.addLabel(0, 1, testing.allocator);
    r = try ls.addLabel(r.head, 2, testing.allocator);
    r = try ls.addLabel(r.head, 3, testing.allocator);

    const removed = try ls.removeLabel(r.head, 2, testing.allocator);
    try testing.expectEqual(@as(u16, 2), removed.count);

    const labels = try ls.getLabels(removed.head, testing.allocator);
    defer testing.allocator.free(labels);
    try testing.expectEqual(@as(usize, 2), labels.len);
    try testing.expectEqual(@as(u32, 1), labels[0]);
    try testing.expectEqual(@as(u32, 3), labels[1]);
}

test "LabelStore: removeLabel last label returns head=0" {
    const env = try TestEnv.create();
    defer env.deinit();

    var ls = LabelStore.init(&env.vs);

    const r = try ls.addLabel(0, 99, testing.allocator);
    const removed = try ls.removeLabel(r.head, 99, testing.allocator);
    try testing.expectEqual(@as(u64, 0), removed.head);
    try testing.expectEqual(@as(u16, 0), removed.count);
}

test "LabelStore: putLabels empty returns 0" {
    const env = try TestEnv.create();
    defer env.deinit();

    var ls = LabelStore.init(&env.vs);
    const head = try ls.putLabels(&[_]u32{}, testing.allocator);
    try testing.expectEqual(@as(u64, 0), head);
}

test {
    std.testing.refAllDecls(@This());
}
