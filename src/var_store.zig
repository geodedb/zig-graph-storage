// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const types = @import("types.zig");
const page_mod = @import("page.zig");
const buffer_pool_mod = @import("buffer_pool.zig");
const free_space_mod = @import("free_space.zig");

const Allocator = std.mem.Allocator;
const BufferPool = buffer_pool_mod.BufferPool;
const FreeSpaceManager = free_space_mod.FreeSpaceManager;
const PageId = types.PageId;
const PAGE_HEADER_SIZE = page_mod.PAGE_HEADER_SIZE;

/// Variable-length data overflow store.
/// Stores large values that don't fit inline in property pages.
///
/// Each write returns a reference: (page_id << 16 | offset).
/// For v1, each write allocates a new page (or chain of pages for large data).
///
/// Page layout:
/// - [0..PAGE_HEADER_SIZE): PageHeader
/// - [PAGE_HEADER_SIZE..PAGE_HEADER_SIZE+8): next_page pointer (u64, 0 = none)
/// - [PAGE_HEADER_SIZE+8..PAGE_HEADER_SIZE+12): data_len (u32, bytes used on this page)
/// - [PAGE_HEADER_SIZE+12..): data bytes
const VAR_META_SIZE: u32 = 12; // next_page(8) + data_len(4)

pub const VarStore = struct {
    buffer_pool: *BufferPool,
    free_space: *FreeSpaceManager,
    page_size: u32,

    pub fn init(buffer_pool: *BufferPool, free_space: *FreeSpaceManager, page_size: u32) VarStore {
        return .{
            .buffer_pool = buffer_pool,
            .free_space = free_space,
            .page_size = page_size,
        };
    }

    /// Usable data bytes per page.
    fn dataCapacity(self: *const VarStore) u32 {
        return self.page_size - PAGE_HEADER_SIZE - VAR_META_SIZE;
    }

    /// Write variable-length data. Returns a reference (page_id << 16 | 0).
    /// For multi-page data, pages are chained via next_page pointers.
    pub fn write(self: *VarStore, data: []const u8) !u64 {
        const cap = self.dataCapacity();
        var remaining = data;
        var first_page: PageId = 0;
        var prev_page: PageId = 0;
        var prev_frame_idx: ?u32 = null;

        while (remaining.len > 0 or first_page == 0) {
            const page_id = try self.free_space.allocPage();
            if (first_page == 0) first_page = page_id;

            const frame = try self.buffer_pool.pinNew(.var_store, page_id);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const page_data = frame.dataSlice();

            const chunk_len: u32 = @intCast(@min(remaining.len, cap));

            // Write metadata: next_page = 0 (will be updated if more pages follow)
            const meta_off = PAGE_HEADER_SIZE;
            @memcpy(page_data[meta_off..][0..8], &std.mem.toBytes(@as(u64, 0)));
            @memcpy(page_data[meta_off + 8 ..][0..4], &std.mem.toBytes(chunk_len));

            // Write data
            if (chunk_len > 0) {
                @memcpy(page_data[meta_off + VAR_META_SIZE ..][0..chunk_len], remaining[0..chunk_len]);
            }

            // Link previous page to this one
            if (prev_frame_idx) |pfi| {
                // Re-pin previous page to update its next_page pointer
                const pframe = try self.buffer_pool.pin(.var_store, prev_page);
                const pfi2 = self.buffer_pool.frameIndex(pframe);
                const pdata = pframe.dataSlice();
                @memcpy(pdata[PAGE_HEADER_SIZE..][0..8], &std.mem.toBytes(page_id));
                self.buffer_pool.unpin(pfi2, true);
                _ = pfi; // prev_frame_idx was already unpinned
            }

            self.buffer_pool.unpin(frame_idx, true);
            prev_page = page_id;
            prev_frame_idx = frame_idx;

            if (chunk_len >= remaining.len) break;
            remaining = remaining[chunk_len..];
        }

        return first_page << 16;
    }

    /// Read variable-length data by reference.
    /// Caller owns the returned slice and must free it.
    pub fn read(self: *VarStore, ref: u64, allocator: Allocator) ![]u8 {
        const start_page: PageId = ref >> 16;
        if (start_page == 0) return error.InvalidPageId;

        var result: std.ArrayList(u8) = .{};
        errdefer result.deinit(allocator);

        var current_page = start_page;
        while (current_page != 0) {
            const frame = try self.buffer_pool.pin(.var_store, current_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const page_data = frame.dataSlice();

            const meta_off = PAGE_HEADER_SIZE;
            const next_page = std.mem.bytesToValue(u64, page_data[meta_off..][0..8]);
            const data_len = std.mem.bytesToValue(u32, page_data[meta_off + 8 ..][0..4]);

            if (data_len > 0) {
                const chunk = page_data[meta_off + VAR_META_SIZE ..][0..data_len];
                try result.appendSlice(allocator, chunk);
            }

            self.buffer_pool.unpin(frame_idx, false);
            current_page = next_page;
        }

        return result.toOwnedSlice(allocator);
    }

    /// Free variable-length data by reference.
    /// Walks the page chain and frees each page.
    pub fn free(self: *VarStore, ref: u64) !void {
        const start_page: PageId = ref >> 16;
        if (start_page == 0) return;

        var current_page = start_page;
        while (current_page != 0) {
            const frame = try self.buffer_pool.pin(.var_store, current_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const page_data = frame.dataSlice();

            const next_page = std.mem.bytesToValue(u64, page_data[PAGE_HEADER_SIZE..][0..8]);

            self.buffer_pool.unpin(frame_idx, false);
            try self.free_space.freePage(current_page);

            current_page = next_page;
        }
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;
const pager_mod = @import("pager.zig");
const Pager = pager_mod.Pager;

const TestEnv = struct {
    pool: BufferPool,
    fsm: FreeSpaceManager,
    tmp_dir: testing.TmpDir,
    var_file: std.fs.File,
    var_pager: Pager,

    fn init() !TestEnv {
        var tmp_dir = testing.tmpDir(.{});
        const var_file = tmp_dir.dir.createFile("var.store", .{ .read = true, .truncate = true }) catch unreachable;
        var pool = try BufferPool.init(testing.allocator, 4096, 32);
        const fsm = try FreeSpaceManager.init(testing.allocator, &pool, .var_store);

        return .{
            .pool = pool,
            .fsm = fsm,
            .tmp_dir = tmp_dir,
            .var_file = var_file,
            .var_pager = Pager.init(var_file, 4096),
        };
    }

    fn fixup(self: *TestEnv) void {
        self.pool.registerPager(.var_store, &self.var_pager);
        self.fsm.buffer_pool = &self.pool;
    }

    fn deinit(self: *TestEnv) void {
        self.fsm.deinit();
        self.pool.deinit();
        self.var_file.close();
        self.tmp_dir.cleanup();
    }
};

test "write + read round-trip for small data" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = VarStore.init(&env.pool, &env.fsm, 4096);

    const data = "hello, world!";
    const ref = try store.write(data);
    try testing.expect(ref != 0);

    const result = try store.read(ref, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(data, result);
}

test "write + read for data larger than a page (multi-page)" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = VarStore.init(&env.pool, &env.fsm, 4096);

    // Data capacity per page: 4096 - 32 - 12 = 4052
    // Create data that spans 3 pages
    const size = 4052 * 2 + 100; // ~8200 bytes, needs 3 pages
    const data = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(data);
    for (data, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }

    const ref = try store.write(data);
    const result = try store.read(ref, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqual(data.len, result.len);
    try testing.expectEqualSlices(u8, data, result);
}

test "free releases pages" {
    var env = try TestEnv.init();
    env.fixup();
    defer env.deinit();

    var store = VarStore.init(&env.pool, &env.fsm, 4096);

    const free_before = env.fsm.freeCount();
    const ref = try store.write("some data");
    const free_after_write = env.fsm.freeCount();
    try testing.expect(free_after_write < free_before);

    try store.free(ref);
    const free_after_free = env.fsm.freeCount();
    try testing.expectEqual(free_before, free_after_free);
}

test {
    std.testing.refAllDecls(@This());
}
