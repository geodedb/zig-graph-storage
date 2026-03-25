// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const types = @import("types.zig");
const buffer_pool_mod = @import("buffer_pool.zig");

const Allocator = std.mem.Allocator;
const BufferPool = buffer_pool_mod.BufferPool;
const FileId = types.FileId;
const PageId = types.PageId;

/// Page-level free space tracking using an in-memory bitmap.
/// Page 0 is always reserved (bitmap metadata page).
/// The bitmap is rebuilt from store files on startup.
pub const FreeSpaceManager = struct {
    allocator: Allocator,
    buffer_pool: *BufferPool,
    file_id: FileId,
    bitmap: std.DynamicBitSet,
    total_pages: u64,

    pub fn init(allocator: Allocator, buffer_pool: *BufferPool, file_id: FileId) !FreeSpaceManager {
        var bitmap = try std.DynamicBitSet.initEmpty(allocator, 64);
        // Reserve page 0 (bitmap metadata page)
        bitmap.set(0);

        return FreeSpaceManager{
            .allocator = allocator,
            .buffer_pool = buffer_pool,
            .file_id = file_id,
            .bitmap = bitmap,
            .total_pages = 64,
        };
    }

    pub fn deinit(self: *FreeSpaceManager) void {
        self.bitmap.deinit();
    }

    /// Allocate a free page. Returns the PageId.
    /// Scans the bitmap for the first unset bit starting from page 1.
    pub fn allocPage(self: *FreeSpaceManager) !PageId {
        // Find first free page (skip page 0 which is reserved)
        var i: usize = 1;
        while (i < self.total_pages) : (i += 1) {
            if (!self.bitmap.isSet(i)) {
                self.bitmap.set(i);
                return @intCast(i);
            }
        }

        // No free pages: expand and allocate
        const old_total = self.total_pages;
        const new_total = old_total * 2;
        try self.ensureCapacity(new_total);
        // Search from where old range ended
        var j: usize = @intCast(old_total);
        while (j < self.total_pages) : (j += 1) {
            if (!self.bitmap.isSet(j)) {
                self.bitmap.set(j);
                return @intCast(j);
            }
        }

        return error.OutOfMemory;
    }

    /// Free a previously allocated page.
    pub fn freePage(self: *FreeSpaceManager, page_id: PageId) !void {
        const idx: usize = @intCast(page_id);
        if (idx >= self.total_pages) return error.InvalidPageId;
        if (idx == 0) return error.InvalidPageId; // Cannot free reserved page 0
        self.bitmap.unset(idx);
    }

    /// Check if a page is allocated.
    pub fn isAllocated(self: *const FreeSpaceManager, page_id: PageId) bool {
        const idx: usize = @intCast(page_id);
        if (idx >= self.total_pages) return false;
        return self.bitmap.isSet(idx);
    }

    /// Number of free pages (excluding page 0 which is always reserved).
    pub fn freeCount(self: *const FreeSpaceManager) u64 {
        var count: u64 = 0;
        var i: usize = 1;
        while (i < self.total_pages) : (i += 1) {
            if (!self.bitmap.isSet(i)) {
                count += 1;
            }
        }
        return count;
    }

    /// Expand to accommodate at least `min_pages` total pages.
    pub fn ensureCapacity(self: *FreeSpaceManager, min_pages: u64) !void {
        if (min_pages <= self.total_pages) return;
        try self.bitmap.resize(min_pages, false);
        self.total_pages = min_pages;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "allocPage returns incrementing IDs starting from 1" {
    var pool = try BufferPool.init(testing.allocator, 4096, 4);
    defer pool.deinit();

    var fsm = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);
    defer fsm.deinit();

    const p1 = try fsm.allocPage();
    const p2 = try fsm.allocPage();
    const p3 = try fsm.allocPage();

    try testing.expectEqual(@as(PageId, 1), p1);
    try testing.expectEqual(@as(PageId, 2), p2);
    try testing.expectEqual(@as(PageId, 3), p3);
}

test "freePage + allocPage reuses freed page" {
    var pool = try BufferPool.init(testing.allocator, 4096, 4);
    defer pool.deinit();

    var fsm = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);
    defer fsm.deinit();

    const p1 = try fsm.allocPage();
    const p2 = try fsm.allocPage();
    _ = p2;

    // Free page 1
    try fsm.freePage(p1);

    // Next alloc should reuse page 1
    const p3 = try fsm.allocPage();
    try testing.expectEqual(p1, p3);
}

test "isAllocated reports correctly" {
    var pool = try BufferPool.init(testing.allocator, 4096, 4);
    defer pool.deinit();

    var fsm = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);
    defer fsm.deinit();

    // Page 0 is always allocated (reserved)
    try testing.expect(fsm.isAllocated(0));

    // Page 1 is not allocated yet
    try testing.expect(!fsm.isAllocated(1));

    const p1 = try fsm.allocPage();
    try testing.expect(fsm.isAllocated(p1));

    try fsm.freePage(p1);
    try testing.expect(!fsm.isAllocated(p1));
}

test "freeCount tracks available pages" {
    var pool = try BufferPool.init(testing.allocator, 4096, 4);
    defer pool.deinit();

    var fsm = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);
    defer fsm.deinit();

    const initial_free = fsm.freeCount();
    try testing.expectEqual(@as(u64, 63), initial_free); // 64 total - 1 reserved

    _ = try fsm.allocPage();
    try testing.expectEqual(@as(u64, 62), fsm.freeCount());

    _ = try fsm.allocPage();
    try testing.expectEqual(@as(u64, 61), fsm.freeCount());

    try fsm.freePage(1);
    try testing.expectEqual(@as(u64, 62), fsm.freeCount());
}

test "ensureCapacity expands bitmap" {
    var pool = try BufferPool.init(testing.allocator, 4096, 4);
    defer pool.deinit();

    var fsm = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);
    defer fsm.deinit();

    try testing.expectEqual(@as(u64, 64), fsm.total_pages);

    try fsm.ensureCapacity(128);
    try testing.expectEqual(@as(u64, 128), fsm.total_pages);

    // Existing allocations should still be valid
    try testing.expect(fsm.isAllocated(0));
}

test "allocPage auto-expands when full" {
    var pool = try BufferPool.init(testing.allocator, 4096, 128);
    defer pool.deinit();

    var fsm = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);
    defer fsm.deinit();

    // Allocate all 63 free pages (64 total - 1 reserved)
    var i: usize = 0;
    while (i < 63) : (i += 1) {
        _ = try fsm.allocPage();
    }
    try testing.expectEqual(@as(u64, 0), fsm.freeCount());

    // Next alloc should auto-expand
    const p = try fsm.allocPage();
    try testing.expect(p >= 64);
    try testing.expect(fsm.total_pages > 64);
}

test {
    std.testing.refAllDecls(@This());
}
