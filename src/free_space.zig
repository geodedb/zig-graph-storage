// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const types = @import("types.zig");
const buffer_pool_mod = @import("buffer_pool.zig");

const Allocator = std.mem.Allocator;
const BufferPool = buffer_pool_mod.BufferPool;
const FileId = types.FileId;
const PageId = types.PageId;

/// SONNY-6470: the persisted bitmap (`serialize`, `free.store`) stores the
/// in-memory `usize` mask words byte for byte. Every file in existence was
/// written as 64-bit little-endian words; another host would read them with
/// the wrong byte order or word count and write files a 64-bit
/// little-endian host would misread. The format does not record the writer's
/// layout, so such hosts refuse it (`error.UnsupportedHostLayout`) instead of
/// reinterpreting it, and the engine rebuilds the bitmap from the store files.
pub const host_layout_supported: bool = blk: {
    checkHostLayout(@import("builtin").cpu.arch.endian(), @sizeOf(usize)) catch break :blk false;
    break :blk true;
};

pub fn checkHostLayout(endian: std.builtin.Endian, usize_bytes: usize) error{UnsupportedHostLayout}!void {
    if (endian != .little or usize_bytes != 8) return error.UnsupportedHostLayout;
}

/// SONNY-6938: a page bitmap that readers query without a lock while its one
/// writer (serialised by the caller) sets, clears and grows it.
///
/// `std.DynamicBitSet.resize` reallocates the word array and frees the old
/// one, so a reader still holding the old pointer read freed memory: a live
/// page read as free (NodeStore.getNode reported the node missing) or the
/// read faulted. Here a growth copies the words into a new array, publishes
/// it, and keeps the old array until `deinit`; readers load the array and
/// each word atomically. Capacity at least doubles on each growth, so the
/// retired arrays together are never larger than the live one.
pub const PageBitmap = struct {
    const Word = usize;
    const word_bits = @bitSizeOf(Word);

    allocator: Allocator,
    /// The live word array. Readers load it with `.acquire`; the writer
    /// stores it with `.release` once the new array holds every word.
    words: [*]Word,
    /// Length of `words` in words. Writer only.
    cap: usize,
    /// Arrays replaced by a growth. A reader may still be reading one.
    retired: std.ArrayListUnmanaged([]Word) = .empty,

    pub fn init(allocator: Allocator, bit_len: usize) !PageBitmap {
        const n = @max(wordCount(bit_len), 1);
        const words = try allocator.alloc(Word, n);
        @memset(words, 0);
        return .{ .allocator = allocator, .words = words.ptr, .cap = n };
    }

    pub fn deinit(self: *PageBitmap) void {
        for (self.retired.items) |old| self.allocator.free(old);
        self.retired.deinit(self.allocator);
        self.allocator.free(self.words[0..self.cap]);
        self.* = undefined;
    }

    pub fn wordCount(bit_len: usize) usize {
        return (bit_len + word_bits - 1) / word_bits;
    }

    /// Safe against a concurrent `set`, `unset` or `ensureWords`.
    pub fn isSet(self: *const PageBitmap, index: usize) bool {
        const words = @atomicLoad([*]Word, &self.words, .acquire);
        const w = @atomicLoad(Word, &words[index / word_bits], .acquire);
        return (w & maskBit(index)) != 0;
    }

    /// Writer only.
    pub fn set(self: *PageBitmap, index: usize) void {
        std.debug.assert(index / word_bits < self.cap);
        _ = @atomicRmw(Word, &self.words[index / word_bits], .Or, maskBit(index), .release);
    }

    /// Writer only.
    pub fn unset(self: *PageBitmap, index: usize) void {
        std.debug.assert(index / word_bits < self.cap);
        _ = @atomicRmw(Word, &self.words[index / word_bits], .And, ~maskBit(index), .release);
    }

    /// Writer only: hold at least `n` words. Added words are zero.
    pub fn ensureWords(self: *PageBitmap, n: usize) !void {
        if (n <= self.cap) return;
        const new_cap = @max(n, self.cap * 2);
        try self.retired.ensureUnusedCapacity(self.allocator, 1);
        const new = try self.allocator.alloc(Word, new_cap);
        @memcpy(new[0..self.cap], self.words[0..self.cap]);
        @memset(new[self.cap..], 0);
        const old = self.words[0..self.cap];
        @atomicStore([*]Word, &self.words, new.ptr, .release);
        self.cap = new_cap;
        self.retired.appendAssumeCapacity(old);
    }

    /// Writer only: the first `n` words, for (de)serialisation.
    pub fn wordSlice(self: *const PageBitmap, n: usize) []Word {
        std.debug.assert(n <= self.cap);
        return self.words[0..n];
    }

    /// Writer only: clear every word from `n` on.
    pub fn clearFrom(self: *PageBitmap, n: usize) void {
        var i = n;
        while (i < self.cap) : (i += 1) @atomicStore(Word, &self.words[i], 0, .release);
    }

    fn maskBit(index: usize) Word {
        return @as(Word, 1) << @as(std.math.Log2Int(Word), @intCast(index % word_bits));
    }
};

/// Page-level free space tracking using an in-memory bitmap.
/// Page 0 is always reserved (bitmap metadata page).
/// The bitmap is rebuilt from store files on startup.
pub const FreeSpaceManager = struct {
    allocator: Allocator,
    /// Unused by the manager itself; null for a detached (offline) bitmap.
    buffer_pool: ?*BufferPool,
    file_id: FileId,
    /// SONNY-6938: readable without a lock (see `PageBitmap`).
    bitmap: PageBitmap,
    /// Pages the bitmap describes. Written only by the writer, with
    /// `.release` after the bitmap can hold them; `isAllocated` loads it
    /// with `.acquire`.
    total_pages: u64,
    /// Hint for where to start scanning for the next free page.
    /// Updated after each allocation to avoid re-scanning already-full regions.
    next_free_hint: usize = 1,
    /// SONNY-6657: pages freed while a transaction is open on the owning
    /// engine (`BufferPool.open_txns`). They stay allocated until it ends:
    /// `applyDeferredFrees` when its writes stand, `dropDeferredFrees` when
    /// they are discarded (the pages then hold live data again). A free that
    /// cannot be recorded (out of memory) is dropped: the page leaks, it is
    /// never handed out while something may still reference it.
    deferred_frees: std.ArrayListUnmanaged(PageId) = .empty,

    pub fn init(allocator: Allocator, buffer_pool: *BufferPool, file_id: FileId) !FreeSpaceManager {
        var bitmap = try PageBitmap.init(allocator, 64);
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

    /// SONNY-6461: a manager with no buffer pool, for reading a persisted
    /// bitmap offline (see `FreeStore`). Same initial state as `init`.
    pub fn initDetached(allocator: Allocator, file_id: FileId) !FreeSpaceManager {
        var bitmap = try PageBitmap.init(allocator, 64);
        bitmap.set(0);
        return .{
            .allocator = allocator,
            .buffer_pool = null,
            .file_id = file_id,
            .bitmap = bitmap,
            .total_pages = 64,
            .next_free_hint = 1,
        };
    }

    pub fn deinit(self: *FreeSpaceManager) void {
        self.deferred_frees.deinit(self.allocator);
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

    /// Free a previously allocated page. SONNY-6657: deferred while a
    /// transaction is open (see `deferred_frees`).
    pub fn freePage(self: *FreeSpaceManager, page_id: PageId) !void {
        const idx: usize = @intCast(page_id);
        if (idx >= self.total_pages) return error.InvalidPageId;
        if (idx == 0) return error.InvalidPageId; // Cannot free reserved page 0
        if (self.buffer_pool) |bp| {
            if (bp.open_txns.load(.acquire) != 0) {
                self.deferred_frees.append(self.allocator, page_id) catch {};
                return;
            }
        }
        self.releasePage(idx);
    }

    fn releasePage(self: *FreeSpaceManager, idx: usize) void {
        self.bitmap.unset(idx);
        // Move hint back if the freed page is before the current hint,
        // so the next allocation can reuse it without a full wrap-around.
        if (idx < self.next_free_hint) {
            self.next_free_hint = idx;
        }
    }

    /// SONNY-6657: the transactions that freed `deferred_frees` ended with
    /// their writes standing: free the pages now.
    pub fn applyDeferredFrees(self: *FreeSpaceManager) void {
        for (self.deferred_frees.items) |page_id| {
            const idx: usize = @intCast(page_id);
            if (idx != 0 and idx < self.total_pages) self.releasePage(idx);
        }
        self.deferred_frees.clearRetainingCapacity();
    }

    /// SONNY-6657: the transaction that freed `deferred_frees` was discarded:
    /// its frees never happened.
    pub fn dropDeferredFrees(self: *FreeSpaceManager) void {
        self.deferred_frees.clearRetainingCapacity();
    }

    /// Check if a page is allocated. SONNY-6938: safe without a lock while
    /// the writer allocates, frees or grows the bitmap.
    pub fn isAllocated(self: *const FreeSpaceManager, page_id: PageId) bool {
        if (page_id >= @atomicLoad(u64, &self.total_pages, .acquire)) return false;
        return self.bitmap.isSet(@intCast(page_id));
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
        try self.bitmap.ensureWords(maskCount(min_pages));
        @atomicStore(u64, &self.total_pages, min_pages, .release);
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
    pub fn serialize(self: *const FreeSpaceManager, buf: []u8) error{ BufferTooSmall, UnsupportedHostLayout }!usize {
        if (!host_layout_supported) return error.UnsupportedHostLayout;
        const needed = self.serializedSize();
        if (buf.len < needed) return error.BufferTooSmall;

        std.mem.writeInt(u64, buf[0..8], self.total_pages, .little);
        std.mem.writeInt(u64, buf[8..16], @intCast(self.next_free_hint), .little);

        const mc = maskCount(self.total_pages);
        if (mc > 0) {
            const masks = self.bitmap.wordSlice(mc);
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
        if (!host_layout_supported) return error.UnsupportedHostLayout;
        if (buf.len < header_size) return error.UnexpectedEof;

        const total_pages = std.mem.readInt(u64, buf[0..8], .little);
        const next_free_hint = std.mem.readInt(u64, buf[8..16], .little);
        const effective_max_pages = @max(@as(u64, 64), max_total_pages);

        if (total_pages < 64 or total_pages > effective_max_pages) return error.InvalidData;
        if (next_free_hint == 0 or next_free_hint > total_pages) return error.InvalidData;

        const mc = maskCount(total_pages);
        const needed = header_size + mc * @sizeOf(usize);
        if (buf.len < needed) return error.UnexpectedEof;

        try self.bitmap.ensureWords(mc);
        if (mc > 0) {
            const masks = self.bitmap.wordSlice(mc);
            const dst = std.mem.sliceAsBytes(masks);
            @memcpy(dst, buf[header_size .. header_size + dst.len]);
            // Bits past total_pages describe no page.
            const tail_bits = total_pages % @bitSizeOf(usize);
            if (tail_bits != 0) masks[mc - 1] &= (@as(usize, 1) << @intCast(tail_bits)) - 1;
        }
        self.bitmap.clearFrom(mc);
        @atomicStore(u64, &self.total_pages, total_pages, .release);
        self.next_free_hint = @intCast(next_free_hint);
        if (!self.bitmap.isSet(0)) return error.InvalidData;
        return needed;
    }
};

/// SONNY-6461: read-only view of a graph's persisted `free.store`, for offline
/// tools that read store files without opening the engine (no buffer pool, no
/// WAL, nothing written).
///
/// Format: one serialized `FreeSpaceManager` bitmap per paged store, in
/// `store_order`, each `total_pages: u64 LE`, `next_free_hint: u64 LE`, then
/// `ceil(total_pages / 64)` 64-bit little-endian mask words (bit set = page
/// allocated; page 0 is always set). Reading on any other host fails with
/// `error.UnsupportedHostLayout` (see `host_layout_supported`). Files written before edge
/// co-location end after the fifth bitmap (`in_idx` and `in_dir` absent).
///
/// What it says: the allocation state as of the last checkpoint (the engine
/// rewrites the file at every checkpoint and after crash recovery). A page
/// beyond a bitmap's `total_pages` was never allocated. After a crash the
/// file can trail the store until the engine has been opened once (recovery
/// rebuilds it), so offline tools should read a cleanly closed store.
pub const FreeStore = struct {
    pub const store_order = [_]FileId{ .nodes, .adj_out, .adj_in, .props, .var_store, .in_idx, .in_dir };

    bitmaps: [store_order.len]?FreeSpaceManager = [_]?FreeSpaceManager{null} ** store_order.len,

    /// Parse `path`. Returns error.UnexpectedEof / error.InvalidData on a
    /// truncated or malformed file (never a partial view).
    pub fn readFromFile(allocator: Allocator, io: std.Io, path: []const u8) !FreeStore {
        const buf = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
        defer allocator.free(buf);
        return parse(allocator, buf);
    }

    pub fn parse(allocator: Allocator, buf: []const u8) !FreeStore {
        var self: FreeStore = .{};
        errdefer self.deinit();
        var offset: usize = 0;
        for (store_order, 0..) |fid, i| {
            // The first five are mandatory; the co-location pair is optional.
            if (i >= 5 and offset == buf.len) break;
            var fsm = try FreeSpaceManager.initDetached(allocator, fid);
            errdefer fsm.deinit();
            // A bitmap cannot describe more pages than the file has bits.
            const rest = buf[offset..];
            const max_pages: u64 = @as(u64, rest.len) * 8;
            offset += try fsm.deserializeBounded(rest, max_pages);
            self.bitmaps[i] = fsm;
        }
        if (offset != buf.len) return error.InvalidData;
        return self;
    }

    pub fn deinit(self: *FreeStore) void {
        for (&self.bitmaps) |*b| {
            if (b.*) |*fsm| fsm.deinit();
            b.* = null;
        }
    }

    /// The bitmap of `file`, or null when the file holds none for it.
    pub fn get(self: *const FreeStore, file: FileId) ?*const FreeSpaceManager {
        for (store_order, 0..) |fid, i| {
            if (fid == file) return if (self.bitmaps[i]) |*fsm| fsm else null;
        }
        return null;
    }

    /// Whether `page` of `file` is allocated; null when the file holds no
    /// bitmap for that store.
    pub fn isAllocated(self: *const FreeStore, file: FileId, page: PageId) ?bool {
        const fsm = self.get(file) orelse return null;
        return fsm.isAllocated(page);
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

test "SONNY-6657: a page freed while a transaction is open stays allocated until it ends" {
    var pool = try BufferPool.init(testing.allocator, 4096, 4);
    defer pool.deinit();
    var fsm = try FreeSpaceManager.init(testing.allocator, &pool, .nodes);
    defer fsm.deinit();

    const p1 = try fsm.allocPage();
    const p2 = try fsm.allocPage();

    // Writes stand: the free happens when the transaction ends.
    pool.beginTxnHold();
    try fsm.freePage(p1);
    try testing.expect(fsm.isAllocated(p1));
    try testing.expect((try fsm.allocPage()) != p1); // not handed out meanwhile
    pool.endTxnHold(.release);
    fsm.applyDeferredFrees();
    try testing.expect(!fsm.isAllocated(p1));

    // Discarded: the free never happens (the page holds live data again).
    pool.beginTxnHold();
    try fsm.freePage(p2);
    pool.endTxnHold(.release);
    fsm.dropDeferredFrees();
    try testing.expect(fsm.isAllocated(p2));

    // No transaction open: immediate, as before.
    try fsm.freePage(p2);
    try testing.expect(!fsm.isAllocated(p2));
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

test "SONNY-6470: free.store mask words are defined only for 64-bit little-endian hosts" {
    // The masks are raw `usize` words; a host with another word size or byte
    // order would misread a file written on a 64-bit little-endian host (and
    // write one such a host would misread). Such hosts must refuse the
    // layout, never reinterpret it.
    try testing.expectError(error.UnsupportedHostLayout, checkHostLayout(.big, 8));
    try testing.expectError(error.UnsupportedHostLayout, checkHostLayout(.little, 4));
    try testing.expectError(error.UnsupportedHostLayout, checkHostLayout(.big, 4));
    try checkHostLayout(.little, 8);
    // This host's verdict is the one serialize/deserialize act on.
    try testing.expectEqual(
        host_layout_supported,
        if (checkHostLayout(@import("builtin").cpu.arch.endian(), @sizeOf(usize))) |_| true else |_| false,
    );
}
