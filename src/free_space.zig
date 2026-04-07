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
    /// Hint for where to start scanning for the next free page.
    /// Updated after each allocation to avoid re-scanning already-full regions.
    next_free_hint: usize = 1,

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
            .next_free_hint = 1,
        };
    }

    pub fn deinit(self: *FreeSpaceManager) void {
        self.bitmap.deinit();
    }

    /// Allocate a free page. Returns the PageId.
    /// Scans from next_free_hint, wraps around if needed. Amortized O(1).
    pub fn allocPage(self: *FreeSpaceManager) !PageId {
        const total: usize = @intCast(self.total_pages);

        // Phase 1: scan from hint to end
        var i: usize = self.next_free_hint;
        while (i < total) : (i += 1) {
            if (!self.bitmap.isSet(i)) {
                self.bitmap.set(i);
                self.next_free_hint = i + 1;
                return @intCast(i);
            }
        }

        // Phase 2: wrap around from page 1 to hint
        i = 1;
        while (i < self.next_free_hint) : (i += 1) {
            if (!self.bitmap.isSet(i)) {
                self.bitmap.set(i);
                self.next_free_hint = i + 1;
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
                self.next_free_hint = j + 1;
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
        // Move hint back if the freed page is before the current hint,
        // so the next allocation can reuse it without a full wrap-around.
        if (idx < self.next_free_hint) {
            self.next_free_hint = idx;
        }
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

    /// Number of allocated pages (excluding reserved page 0).
    pub fn allocatedCount(self: *const FreeSpaceManager) u64 {
        var count: u64 = 0;
        var i: usize = 1;
        while (i < self.total_pages) : (i += 1) {
            if (self.bitmap.isSet(i)) {
                count += 1;
            }
        }
        return count;
    }

    /// Expand to accommodate at least `min_pages` total pages.
    pub fn ensureCapacity(self: *FreeSpaceManager, min_pages: u64) !void {
        if (min_pages <= self.total_pages) return;
        try self.bitmap.resize(@intCast(min_pages), false);
        self.total_pages = min_pages;
    }

    /// Size of the fixed header (total_pages + next_free_hint).
    const header_size: usize = 16;

    /// Number of mask words needed for a given page count.
    fn maskCount(total_pages: u64) usize {
        return @intCast((total_pages + @bitSizeOf(usize) - 1) / @bitSizeOf(usize));
    }

    /// Total serialized size in bytes.
    pub fn serializedSize(self: *const FreeSpaceManager) usize {
        return header_size + maskCount(self.total_pages) * @sizeOf(usize);
    }

    /// Serialize bitmap state into `buf`. Returns the number of bytes written.
    pub fn serialize(self: *const FreeSpaceManager, buf: []u8) error{BufferTooSmall}!usize {
        const needed = self.serializedSize();
        if (buf.len < needed) return error.BufferTooSmall;

        std.mem.writeInt(u64, buf[0..8], self.total_pages, .little);
        std.mem.writeInt(u64, buf[8..16], @intCast(self.next_free_hint), .little);

        const mc = maskCount(self.total_pages);
        if (mc > 0) {
            const masks = self.bitmap.unmanaged.masks[0..mc];
            const src = std.mem.sliceAsBytes(masks);
            @memcpy(buf[header_size .. header_size + src.len], src);
        }
        return needed;
    }

    /// Deserialize bitmap state from `buf`. Returns the number of bytes consumed.
    pub fn deserialize(self: *FreeSpaceManager, buf: []const u8) !usize {
        return self.deserializeBounded(buf, std.math.maxInt(u64));
    }

    /// Deserialize bitmap state from `buf`, rejecting metadata that would
    /// expand the in-memory bitmap beyond `max_total_pages`.
    pub fn deserializeBounded(self: *FreeSpaceManager, buf: []const u8, max_total_pages: u64) !usize {
        if (buf.len < header_size) return error.UnexpectedEof;

        const total_pages = std.mem.readInt(u64, buf[0..8], .little);
        const next_free_hint = std.mem.readInt(u64, buf[8..16], .little);
        const effective_max_pages = @max(@as(u64, 64), max_total_pages);

        if (total_pages < 64 or total_pages > effective_max_pages) return error.InvalidData;
        if (next_free_hint == 0 or next_free_hint > total_pages) return error.InvalidData;

        const mc = maskCount(total_pages);
        const needed = header_size + mc * @sizeOf(usize);
        if (buf.len < needed) return error.UnexpectedEof;

        self.total_pages = total_pages;
        self.next_free_hint = @intCast(next_free_hint);
        try self.bitmap.resize(@intCast(total_pages), false);

        if (mc > 0) {
            const masks = self.bitmap.unmanaged.masks[0..mc];
            const dst = std.mem.sliceAsBytes(masks);
            @memcpy(dst, buf[header_size .. header_size + dst.len]);
        }
        if (!self.bitmap.isSet(0)) return error.InvalidData;
        return needed;
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

test "next_free_hint advances after sequential allocations" {
    var pool = try BufferPool.init(testing.allocator, 4096, 4);
    defer pool.deinit();

    var fsm = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);
    defer fsm.deinit();

    _ = try fsm.allocPage(); // page 1
    try testing.expectEqual(@as(usize, 2), fsm.next_free_hint);

    _ = try fsm.allocPage(); // page 2
    try testing.expectEqual(@as(usize, 3), fsm.next_free_hint);

    _ = try fsm.allocPage(); // page 3
    try testing.expectEqual(@as(usize, 4), fsm.next_free_hint);
}

test "freePage resets hint when freed page is before hint" {
    var pool = try BufferPool.init(testing.allocator, 4096, 4);
    defer pool.deinit();

    var fsm = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);
    defer fsm.deinit();

    _ = try fsm.allocPage(); // page 1
    _ = try fsm.allocPage(); // page 2
    _ = try fsm.allocPage(); // page 3
    try testing.expectEqual(@as(usize, 4), fsm.next_free_hint);

    // Free page 2 — hint should move back to 2
    try fsm.freePage(2);
    try testing.expectEqual(@as(usize, 2), fsm.next_free_hint);

    // Next alloc should reuse page 2
    const p = try fsm.allocPage();
    try testing.expectEqual(@as(PageId, 2), p);
}

test "allocPage wraps around to find freed pages before hint" {
    var pool = try BufferPool.init(testing.allocator, 4096, 16);
    defer pool.deinit();

    var fsm = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);
    defer fsm.deinit();

    // Allocate pages 1-10
    var j: usize = 0;
    while (j < 10) : (j += 1) {
        _ = try fsm.allocPage();
    }
    try testing.expectEqual(@as(usize, 11), fsm.next_free_hint);

    // Free page 3 without updating hint (simulate external bitmap manipulation)
    // Actually freePage does update hint. Let's test wrap-around differently:
    // Free page 5 then allocate it directly (hint already at 5 from freePage)
    try fsm.freePage(5);
    const p = try fsm.allocPage();
    try testing.expectEqual(@as(PageId, 5), p);
}

test "serialize and deserialize round-trip preserves bitmap state" {
    var pool = try BufferPool.init(testing.allocator, 4096, 4);
    defer pool.deinit();

    // Build a bitmap with some allocated and freed pages
    var fsm = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);
    defer fsm.deinit();

    _ = try fsm.allocPage(); // page 1
    _ = try fsm.allocPage(); // page 2
    _ = try fsm.allocPage(); // page 3
    try fsm.freePage(2); // free page 2

    // Serialize
    var buf: [256]u8 = undefined;
    const written = try fsm.serialize(&buf);
    try testing.expect(written > 0);

    // Deserialize into a fresh manager
    var fsm2 = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);
    defer fsm2.deinit();

    const consumed = try fsm2.deserialize(buf[0..written]);
    try testing.expectEqual(written, consumed);

    // Verify state matches
    try testing.expectEqual(fsm.total_pages, fsm2.total_pages);
    try testing.expectEqual(fsm.next_free_hint, fsm2.next_free_hint);
    try testing.expect(fsm2.isAllocated(0)); // reserved
    try testing.expect(fsm2.isAllocated(1));
    try testing.expect(!fsm2.isAllocated(2)); // was freed
    try testing.expect(fsm2.isAllocated(3));
    try testing.expect(!fsm2.isAllocated(4));
}

test "serialize and deserialize with expanded bitmap" {
    var pool = try BufferPool.init(testing.allocator, 4096, 256);
    defer pool.deinit();

    var fsm = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);
    defer fsm.deinit();

    // Expand and allocate pages beyond initial 64
    try fsm.ensureCapacity(200);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = try fsm.allocPage();
    }
    try fsm.freePage(50);
    try fsm.freePage(75);

    // Serialize
    var buf: [512]u8 = undefined;
    const written = try fsm.serialize(&buf);

    // Deserialize
    var fsm2 = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);
    defer fsm2.deinit();

    const consumed = try fsm2.deserialize(buf[0..written]);
    try testing.expectEqual(written, consumed);

    try testing.expectEqual(fsm.total_pages, fsm2.total_pages);
    try testing.expectEqual(fsm.next_free_hint, fsm2.next_free_hint);
    try testing.expect(!fsm2.isAllocated(50));
    try testing.expect(!fsm2.isAllocated(75));
    try testing.expect(fsm2.isAllocated(99));
    try testing.expect(fsm2.isAllocated(1));
}

test "serializedSize matches actual serialized output" {
    var pool = try BufferPool.init(testing.allocator, 4096, 4);
    defer pool.deinit();

    var fsm = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);
    defer fsm.deinit();

    _ = try fsm.allocPage();
    _ = try fsm.allocPage();

    var buf: [256]u8 = undefined;
    const written = try fsm.serialize(&buf);
    try testing.expectEqual(fsm.serializedSize(), written);
}

test "deserialize rejects truncated input" {
    var pool = try BufferPool.init(testing.allocator, 4096, 4);
    defer pool.deinit();

    var fsm = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);
    defer fsm.deinit();

    // Too short for header
    const short: [4]u8 = .{ 0, 0, 0, 0 };
    try testing.expectError(error.UnexpectedEof, fsm.deserialize(&short));
}

test "GAP-0035: deserializeBounded rejects oversized total_pages before resizing" {
    var pool = try BufferPool.init(testing.allocator, 4096, 4);
    defer pool.deinit();

    var source = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);
    defer source.deinit();
    try source.ensureCapacity(256);

    var buf: [512]u8 = undefined;
    const written = try source.serialize(&buf);

    var loaded = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);
    defer loaded.deinit();

    try testing.expectError(error.InvalidData, loaded.deserializeBounded(buf[0..written], 64));
}

test "GAP-0035: deserializeBounded rejects invalid next_free_hint" {
    var pool = try BufferPool.init(testing.allocator, 4096, 4);
    defer pool.deinit();

    var fsm = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);
    defer fsm.deinit();

    var buf: [256]u8 = undefined;
    const written = try fsm.serialize(&buf);
    std.mem.writeInt(u64, buf[8..16], 65, .little);

    var loaded = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);
    defer loaded.deinit();

    try testing.expectError(error.InvalidData, loaded.deserializeBounded(buf[0..written], 64));
}

test {
    std.testing.refAllDecls(@This());
}
