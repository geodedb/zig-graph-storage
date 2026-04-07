// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const spice = @import("spice");
const types = @import("types.zig");
const page_frame_mod = @import("page_frame.zig");
const pager_mod = @import("pager.zig");
const metrics_mod = @import("metrics.zig");

const Allocator = std.mem.Allocator;
const PageFrame = page_frame_mod.PageFrame;
const Pager = pager_mod.Pager;
const Metrics = metrics_mod.Metrics;
const PageId = types.PageId;
const FileId = types.FileId;
const Lsn = types.Lsn;
const FILE_COUNT = @typeInfo(FileId).@"enum".fields.len;

pub const BufferPoolError = error{
    BufferPoolFull,
    NoPagerRegistered,
};

pub const PageKey = struct {
    file_id: FileId,
    page_id: PageId,
};

/// LRU buffer pool that caches pages in memory with dirty tracking and eviction.
pub const BufferPool = struct {
    allocator: Allocator,
    page_size: u32,
    capacity: u32,
    frames: []PageFrame,
    page_buf: []align(4096) u8, // contiguous allocation for all frame data
    page_table: std.AutoHashMap(PageKey, u32),
    // LRU list (doubly-linked via frame indices)
    lru_head: ?u32 = null, // most recently used
    lru_tail: ?u32 = null, // least recently used (eviction candidate)
    // Free list
    free_list: std.ArrayList(u32),
    // Pagers: one per FileId
    pagers: [FILE_COUNT]?*Pager, // indexed by @intFromEnum(FileId)
    // Optional metrics pointer for recording buffer hits/misses and page I/O
    metrics: ?*Metrics = null,
    // Concurrency protection for multi-threaded access
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    // Optional spice thread pool for parallel page flushes
    thread_pool: ?*spice.ThreadPool = null,

    /// Initialize a buffer pool with the given capacity (number of frames).
    pub fn init(allocator: Allocator, page_size: u32, capacity: u32) !BufferPool {
        const page_buf = try allocator.alignedAlloc(u8, .fromByteUnits(4096), @as(usize, capacity) * @as(usize, page_size));
        @memset(page_buf, 0);

        const frames = try allocator.alloc(PageFrame, capacity);
        for (frames, 0..) |*frame, i| {
            frame.* = PageFrame{
                .file_id = .nodes, // placeholder, overwritten on use
                .page_id = 0,
                .data = page_buf.ptr + (i * @as(usize, page_size)),
                .page_size = page_size,
                .pin_count = 0,
                .dirty = false,
                .valid = false,
                .lsn = 0,
                .lru_prev = null,
                .lru_next = null,
            };
        }

        var free_list = try std.ArrayList(u32).initCapacity(allocator, capacity);
        // Add all frame indices to free list (reverse order so pop gives 0, 1, 2, ...)
        var i: u32 = capacity;
        while (i > 0) {
            i -= 1;
            free_list.appendAssumeCapacity(i);
        }

        // PERF-0033: Pre-size page_table to avoid rehashing during initial load.
        var page_table = std.AutoHashMap(PageKey, u32).init(allocator);
        try page_table.ensureTotalCapacity(@intCast(capacity));

        return BufferPool{
            .allocator = allocator,
            .page_size = page_size,
            .capacity = capacity,
            .frames = frames,
            .page_buf = page_buf,
            .page_table = page_table,
            .lru_head = null,
            .lru_tail = null,
            .free_list = free_list,
            .pagers = [_]?*Pager{null} ** FILE_COUNT,
            .mutex = .{},
            .cond = .{},
        };
    }

    /// Free all resources owned by the buffer pool.
    pub fn deinit(self: *BufferPool) void {
        self.page_table.deinit();
        self.free_list.deinit(self.allocator);
        self.allocator.free(self.frames);
        self.allocator.free(self.page_buf);
    }

    /// Register a pager for the given file_id.
    pub fn registerPager(self: *BufferPool, file_id: FileId, p: *Pager) void {
        self.pagers[@intFromEnum(file_id)] = p;
    }

    /// Attach a metrics struct for recording buffer hit/miss and page I/O counters.
    pub fn setMetrics(self: *BufferPool, m: *Metrics) void {
        self.metrics = m;
    }

    /// Attach a spice thread pool for parallel dirty page flushes.
    pub fn setThreadPool(self: *BufferPool, tp: *spice.ThreadPool) void {
        self.thread_pool = tp;
    }

    /// Pin a page: return it from cache or read it from disk.
    /// If the page is already cached, increments pin_count and moves to LRU head.
    /// Otherwise, allocates a frame (evicting LRU if necessary) and reads from disk.
    pub fn pin(self: *BufferPool, file_id: FileId, page_id: PageId) !*PageFrame {
        self.mutex.lock();
        const key = PageKey{ .file_id = file_id, .page_id = page_id };
        while (true) {
            if (self.page_table.get(key)) |frame_idx| {
                const frame = &self.frames[frame_idx];
                if (frame.loading) {
                    self.cond.wait(&self.mutex);
                    continue;
                }
                frame.pin_count += 1;
                self.moveToHead(frame_idx);
                if (self.metrics) |m| m.buffer_hits += 1;
                self.mutex.unlock();
                return frame;
            }

            if (self.metrics) |m| m.buffer_misses += 1;
            const frame_idx = try self.getFrame();
            const frame = &self.frames[frame_idx];
            const pager = self.pagers[@intFromEnum(file_id)] orelse {
                self.free_list.appendAssumeCapacity(frame_idx);
                self.mutex.unlock();
                return error.NoPagerRegistered;
            };

            frame.file_id = file_id;
            frame.page_id = page_id;
            frame.pin_count = 1;
            frame.dirty = false;
            frame.loading = true;
            frame.valid = false;
            frame.lsn = 0;

            try self.page_table.put(key, frame_idx);
            self.moveToHead(frame_idx);

            self.mutex.unlock();

            var read_err: ?anyerror = null;
            pager.readPage(page_id, frame.dataSlice()) catch |err| switch (err) {
                error.PageNotFound => @memset(frame.dataSlice(), 0),
                else => read_err = err,
            };

            self.mutex.lock();
            if (read_err) |err| {
                frame.pin_count = 0;
                frame.dirty = false;
                frame.loading = false;
                frame.valid = false;
                frame.lsn = 0;
                self.removeFromLru(frame_idx);
                _ = self.page_table.remove(key);
                self.free_list.appendAssumeCapacity(frame_idx);
                self.cond.broadcast();
                self.mutex.unlock();
                return err;
            }

            frame.loading = false;
            frame.valid = true;
            if (self.metrics) |m| m.page_reads += 1;
            self.cond.broadcast();
            self.mutex.unlock();
            return frame;
        }
    }

    /// Pin a new page without reading from disk. Used when creating a new page.
    /// Zeros the data buffer and inserts into cache.
    pub fn pinNew(self: *BufferPool, file_id: FileId, page_id: PageId) !*PageFrame {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = PageKey{ .file_id = file_id, .page_id = page_id };

        // If already in cache, just pin it
        if (self.page_table.get(key)) |frame_idx| {
            const frame = &self.frames[frame_idx];
            frame.pin_count += 1;
            self.moveToHead(frame_idx);
            return frame;
        }

        const frame_idx = try self.getFrame();
        const frame = &self.frames[frame_idx];

        // Zero the data (new page)
        @memset(frame.dataSlice(), 0);

        frame.file_id = file_id;
        frame.page_id = page_id;
        frame.pin_count = 1;
        frame.dirty = false;
        frame.loading = false;
        frame.valid = true;
        frame.lsn = 0;

        try self.page_table.put(key, frame_idx);
        self.moveToHead(frame_idx);

        return frame;
    }

    /// Unpin a frame. Decrements pin_count and optionally marks dirty.
    pub fn unpin(self: *BufferPool, frame_idx: u32, dirty: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const frame = &self.frames[frame_idx];
        std.debug.assert(frame.pin_count > 0);
        frame.pin_count -= 1;
        if (dirty) {
            frame.dirty = true;
        }
        if (frame.pin_count == 0) {
            self.cond.broadcast();
        }
    }

    /// Flush all dirty frames with LSN <= up_to_lsn to disk.
    pub fn flushDirty(self: *BufferPool, up_to_lsn: Lsn) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.frames, 0..) |*frame, i| {
            _ = i;
            if (frame.dirty and frame.valid and frame.lsn <= up_to_lsn) {
                try self.flushFrame(frame);
            }
        }
    }

    /// Flush all dirty frames to disk regardless of LSN.
    /// When a spice ThreadPool is attached, dirty pages are written in parallel
    /// using fork/join. Otherwise falls back to sequential I/O.
    pub fn flushAll(self: *BufferPool) !void {
        if (self.thread_pool) |tp| {
            return self.flushAllParallel(tp);
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.frames) |*frame| {
            if (frame.dirty and frame.valid) {
                try self.flushFrame(frame);
            }
        }
    }

    /// Parallel flush: collect dirty frames under mutex, copy data, then
    /// write pages concurrently via spice fork/join.
    fn flushAllParallel(self: *BufferPool, tp: *spice.ThreadPool) !void {
        self.mutex.lock();

        // Count dirty frames
        var dirty_count: usize = 0;
        for (self.frames) |*frame| {
            if (frame.dirty and frame.valid) dirty_count += 1;
        }

        if (dirty_count == 0) {
            self.mutex.unlock();
            return;
        }

        // Allocate descriptors and a contiguous data buffer for page copies
        const items = self.allocator.alloc(FlushItem, dirty_count) catch {
            self.mutex.unlock();
            return error.OutOfMemory;
        };
        const ps: usize = self.page_size;
        const data_buf = self.allocator.alloc(u8, dirty_count * ps) catch {
            self.allocator.free(items);
            self.mutex.unlock();
            return error.OutOfMemory;
        };

        // Collect dirty frames: copy page data, bump pin, clear dirty
        var idx: usize = 0;
        for (self.frames, 0..) |*frame, fi| {
            if (frame.dirty and frame.valid) {
                const fid = frame.file_id;
                const p = self.pagers[@intFromEnum(fid)] orelse {
                    // Undo previously pinned frames and bail
                    for (items[0..idx]) |item| {
                        self.frames[item.frame_idx].pin_count -= 1;
                        self.frames[item.frame_idx].dirty = true;
                    }
                    self.allocator.free(data_buf);
                    self.allocator.free(items);
                    self.mutex.unlock();
                    return error.NoPagerRegistered;
                };

                const offset = idx * ps;
                @memcpy(data_buf[offset..][0..ps], frame.dataSlice());

                frame.pin_count += 1;
                frame.dirty = false;

                items[idx] = .{
                    .pager = p,
                    .page_id = frame.page_id,
                    .frame_idx = @intCast(fi),
                    .data_offset = offset,
                    .err = null,
                };
                idx += 1;
            }
        }
        self.mutex.unlock();

        // Parallel I/O via spice fork/join
        const ctx = FlushRange{
            .items = items,
            .data_buf = data_buf,
            .page_size = self.page_size,
        };
        tp.call(void, parallelFlushFn, ctx);

        // Re-acquire mutex to unpin frames and handle errors
        self.mutex.lock();
        var first_err: ?anyerror = null;
        var write_count: u64 = 0;
        for (items) |*item| {
            self.frames[item.frame_idx].pin_count -= 1;
            if (item.err) |e| {
                self.frames[item.frame_idx].dirty = true;
                if (first_err == null) first_err = e;
            } else {
                write_count += 1;
            }
        }
        if (self.metrics) |m| m.page_writes += write_count;
        self.mutex.unlock();

        self.allocator.free(data_buf);
        self.allocator.free(items);

        if (first_err) |e| return e;
    }

    /// Flush up to max_count dirty unpinned pages to disk, starting from the LRU tail.
    /// Returns the number of pages actually flushed. This is intended to be called
    /// proactively (e.g. during maintenance) to reduce eviction stalls.
    pub fn flushDirtyPages(self: *BufferPool, max_count: u32) !u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var flushed: u32 = 0;
        var current = self.lru_tail;
        while (current) |idx| {
            if (flushed >= max_count) break;
            const frame = &self.frames[idx];
            // Walk via lru_prev before we potentially modify the frame
            const prev = frame.lru_prev;
            if (frame.dirty and frame.valid and frame.pin_count == 0) {
                try self.flushFrame(frame);
                flushed += 1;
            }
            current = prev;
        }
        return flushed;
    }

    /// Get the frame index for a given frame pointer.
    pub fn frameIndex(self: *const BufferPool, frame: *const PageFrame) u32 {
        const base = @intFromPtr(self.frames.ptr);
        const addr = @intFromPtr(frame);
        return @intCast((addr - base) / @sizeOf(PageFrame));
    }

    // ========================================================================
    // Internal helpers
    // ========================================================================

    /// Flush a single dirty frame to disk via its pager.
    fn flushFrame(self: *BufferPool, frame: *PageFrame) !void {
        // Called WITH mutex held.
        const fid = frame.file_id;
        const pid = frame.page_id;
        const p = self.pagers[@intFromEnum(fid)] orelse return error.NoPagerRegistered;

        // Prevent eviction during I/O
        frame.pin_count += 1;
        frame.dirty = false;

        var buf: [16384]u8 = undefined;
        std.debug.assert(self.page_size <= buf.len);
        @memcpy(buf[0..self.page_size], frame.dataSlice());

        self.mutex.unlock();
        p.writePage(pid, buf[0..self.page_size]) catch |err| {
            self.mutex.lock();
            frame.pin_count -= 1;
            // Restore dirty state if write failed so we can retry later
            frame.dirty = true;
            return err;
        };
        self.mutex.lock();

        // Allowed to be evicted again
        frame.pin_count -= 1;

        if (self.metrics) |m| m.page_writes += 1;
    }

    /// Get a free frame index, evicting if necessary.
    fn getFrame(self: *BufferPool) !u32 {
        // Try free list first
        if (self.free_list.pop()) |idx| {
            return idx;
        }

        // Evict from LRU tail
        return try self.evict();
    }

    /// Evict the least recently used unpinned frame.
    /// Walks from LRU tail towards head to find first evictable frame.
    fn evict(self: *BufferPool) !u32 {
        var current = self.lru_tail;
        while (current) |idx| {
            const frame = &self.frames[idx];
            if (frame.isEvictable()) {
                // Flush if dirty
                if (frame.dirty) {
                    try self.flushFrame(frame);
                }

                // Remove from page table
                const key = PageKey{ .file_id = frame.file_id, .page_id = frame.page_id };
                _ = self.page_table.remove(key);

                // Remove from LRU list
                self.removeFromLru(idx);

                // Reset frame
                frame.valid = false;
                frame.pin_count = 0;
                frame.dirty = false;
                frame.loading = false;
                frame.lsn = 0;

                return idx;
            }
            current = frame.lru_prev;
        }

        return error.BufferPoolFull;
    }

    /// Move a frame to the head of the LRU list (most recently used).
    fn moveToHead(self: *BufferPool, idx: u32) void {
        // If already head, nothing to do
        if (self.lru_head) |head| {
            if (head == idx) return;
        }

        // Remove from current position if actually in the LRU list.
        // A frame is in the list if it has prev/next pointers, or is head/tail.
        const in_list = self.frames[idx].lru_prev != null or
            self.frames[idx].lru_next != null or
            (self.lru_head != null and self.lru_head.? == idx) or
            (self.lru_tail != null and self.lru_tail.? == idx);
        if (in_list) {
            self.removeFromLru(idx);
        }

        // Insert at head
        self.frames[idx].lru_prev = null;
        self.frames[idx].lru_next = self.lru_head;

        if (self.lru_head) |old_head| {
            self.frames[old_head].lru_prev = idx;
        }

        self.lru_head = idx;

        if (self.lru_tail == null) {
            self.lru_tail = idx;
        }
    }

    /// Remove a frame from the LRU list.
    fn removeFromLru(self: *BufferPool, idx: u32) void {
        const frame = &self.frames[idx];

        if (frame.lru_prev) |prev| {
            self.frames[prev].lru_next = frame.lru_next;
        } else {
            // This was the head
            self.lru_head = frame.lru_next;
        }

        if (frame.lru_next) |next| {
            self.frames[next].lru_prev = frame.lru_prev;
        } else {
            // This was the tail
            self.lru_tail = frame.lru_prev;
        }

        frame.lru_prev = null;
        frame.lru_next = null;
    }

    // ========================================================================
    // Parallel flush types (used by flushAllParallel via spice fork/join)
    // ========================================================================

    const FlushItem = struct {
        pager: *const Pager,
        page_id: PageId,
        frame_idx: u32,
        data_offset: usize,
        err: ?anyerror,
    };

    const FlushRange = struct {
        items: []FlushItem,
        data_buf: []u8,
        page_size: u32,
    };

    /// Recursive divide-and-conquer flush: splits the item list in half,
    /// forks one half to a background worker, processes the other half
    /// inline, then joins.  If the forked half was not picked up by a
    /// background worker (join returns null), it is executed inline so
    /// that no writes are silently dropped.
    fn parallelFlushFn(task: *spice.Task, range: FlushRange) void {
        const items = range.items;
        if (items.len == 0) return;

        if (items.len == 1) {
            const item = &items[0];
            const data = range.data_buf[item.data_offset..][0..range.page_size];
            item.pager.writePage(item.page_id, data) catch |e| {
                item.err = e;
            };
            return;
        }

        const mid = items.len / 2;
        const right_range = FlushRange{
            .items = items[mid..],
            .data_buf = range.data_buf,
            .page_size = range.page_size,
        };
        var future = spice.Future(FlushRange, void).init();
        future.fork(task, parallelFlushFn, right_range);
        parallelFlushFn(task, .{
            .items = items[0..mid],
            .data_buf = range.data_buf,
            .page_size = range.page_size,
        });
        // If join returns null the forked job was still queued (never
        // picked up by a background worker).  Execute it inline to
        // guarantee all pages are flushed.
        if (future.join(task) == null) {
            parallelFlushFn(task, right_range);
        }
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

fn createTempFile(name: []const u8) !std.fs.File {
    return std.fs.cwd().createFile(name, .{
        .read = true,
        .truncate = true,
    });
}

fn cleanupTempFile(file: std.fs.File, name: []const u8) void {
    file.close();
    std.fs.cwd().deleteFile(name) catch {};
}

/// Write a page with known data pattern to a file via a pager.
fn writeTestPage(p: *Pager, page_id: PageId, pattern: u8) !void {
    const page_mod = @import("page.zig");
    const page_size = p.page_size;
    const allocator = testing.allocator;
    const buf = try allocator.alloc(u8, page_size);
    defer allocator.free(buf);
    @memset(buf, 0);

    // Set up header
    const header = page_mod.initHeader(page_id, .node_data, page_size);
    const header_bytes = page_mod.headerToBytes(&header);
    @memcpy(buf[0..page_mod.PAGE_HEADER_SIZE], header_bytes);

    // Fill body with pattern
    @memset(buf[page_mod.PAGE_HEADER_SIZE..], pattern);

    try p.writePage(page_id, buf);
}

test "pin and read: data matches what was written to disk" {
    const file = try createTempFile(".test_bp_pin_read");
    defer cleanupTempFile(file, ".test_bp_pin_read");

    const page_size: u32 = 4096;
    var p = Pager.init(file, page_size);

    // Write a page with known pattern 0xAB
    try writeTestPage(&p, 0, 0xAB);

    var pool = try BufferPool.init(testing.allocator, page_size, 4);
    defer pool.deinit();
    pool.registerPager(.nodes, &p);

    const frame = try pool.pin(.nodes, 0);
    const page_mod = @import("page.zig");

    // Verify body data matches the pattern we wrote
    const body = frame.dataSlice()[page_mod.PAGE_HEADER_SIZE..];
    for (body) |byte| {
        try testing.expectEqual(@as(u8, 0xAB), byte);
    }

    try testing.expectEqual(@as(u32, 1), frame.pin_count);
    try testing.expect(frame.valid);
}

test "pin cache hit: same frame returned, pin_count incremented" {
    const file = try createTempFile(".test_bp_cache_hit");
    defer cleanupTempFile(file, ".test_bp_cache_hit");

    const page_size: u32 = 4096;
    var p = Pager.init(file, page_size);
    try writeTestPage(&p, 0, 0xCD);

    var pool = try BufferPool.init(testing.allocator, page_size, 4);
    defer pool.deinit();
    pool.registerPager(.nodes, &p);

    const frame1 = try pool.pin(.nodes, 0);
    const frame2 = try pool.pin(.nodes, 0);

    // Same frame pointer
    try testing.expectEqual(@intFromPtr(frame1), @intFromPtr(frame2));
    try testing.expectEqual(@as(u32, 2), frame1.pin_count);
}

test "unpin dirty: flush writes data to disk" {
    const file = try createTempFile(".test_bp_unpin_dirty");
    defer cleanupTempFile(file, ".test_bp_unpin_dirty");

    const page_size: u32 = 4096;
    var p = Pager.init(file, page_size);
    try writeTestPage(&p, 0, 0x00);

    var pool = try BufferPool.init(testing.allocator, page_size, 4);
    defer pool.deinit();
    pool.registerPager(.nodes, &p);

    const frame = try pool.pin(.nodes, 0);
    const frame_idx = pool.frameIndex(frame);

    // Modify data in the frame
    const page_mod = @import("page.zig");
    @memset(frame.dataSlice()[page_mod.PAGE_HEADER_SIZE..], 0xFF);

    pool.unpin(frame_idx, true);
    try testing.expect(pool.frames[frame_idx].dirty);

    try pool.flushAll();
    try testing.expect(!pool.frames[frame_idx].dirty);

    // Read file directly to verify written data
    var read_buf: [4096]u8 = undefined;
    try p.readPage(0, &read_buf);
    const body = read_buf[page_mod.PAGE_HEADER_SIZE..];
    for (body) |byte| {
        try testing.expectEqual(@as(u8, 0xFF), byte);
    }
}

test "eviction: LRU tail is evicted when pool is full" {
    const file = try createTempFile(".test_bp_eviction");
    defer cleanupTempFile(file, ".test_bp_eviction");

    const page_size: u32 = 4096;
    var p = Pager.init(file, page_size);

    // Write 3 pages with distinct patterns
    try writeTestPage(&p, 0, 0xAA);
    try writeTestPage(&p, 1, 0xBB);
    try writeTestPage(&p, 2, 0xCC);

    // Pool with capacity 2
    var pool = try BufferPool.init(testing.allocator, page_size, 2);
    defer pool.deinit();
    pool.registerPager(.nodes, &p);

    // Pin page 0, then unpin
    const f0 = try pool.pin(.nodes, 0);
    const f0_idx = pool.frameIndex(f0);
    pool.unpin(f0_idx, false);

    // Pin page 1, then unpin
    const f1 = try pool.pin(.nodes, 1);
    const f1_idx = pool.frameIndex(f1);
    pool.unpin(f1_idx, false);

    // Pin page 2 — should evict page 0 (LRU tail, since page 1 was pinned more recently)
    const f2 = try pool.pin(.nodes, 2);
    try testing.expect(f2.valid);

    const page_mod = @import("page.zig");
    const body = f2.dataSlice()[page_mod.PAGE_HEADER_SIZE..];
    for (body) |byte| {
        try testing.expectEqual(@as(u8, 0xCC), byte);
    }

    // Page 0 should no longer be in page table
    const key0 = PageKey{ .file_id = .nodes, .page_id = 0 };
    try testing.expect(pool.page_table.get(key0) == null);

    // Page 1 should still be in page table
    const key1 = PageKey{ .file_id = .nodes, .page_id = 1 };
    try testing.expect(pool.page_table.get(key1) != null);
}

test "pinned pages are not evicted" {
    const file = try createTempFile(".test_bp_no_evict_pinned");
    defer cleanupTempFile(file, ".test_bp_no_evict_pinned");

    const page_size: u32 = 4096;
    var p = Pager.init(file, page_size);

    try writeTestPage(&p, 0, 0xAA);
    try writeTestPage(&p, 1, 0xBB);
    try writeTestPage(&p, 2, 0xCC);

    var pool = try BufferPool.init(testing.allocator, page_size, 2);
    defer pool.deinit();
    pool.registerPager(.nodes, &p);

    // Pin page 0 and KEEP IT PINNED
    _ = try pool.pin(.nodes, 0);

    // Pin page 1, then unpin
    const f1 = try pool.pin(.nodes, 1);
    const f1_idx = pool.frameIndex(f1);
    pool.unpin(f1_idx, false);

    // Pin page 2 — should evict page 1 (page 0 is pinned)
    _ = try pool.pin(.nodes, 2);

    // Page 0 should still be cached (was pinned)
    const key0 = PageKey{ .file_id = .nodes, .page_id = 0 };
    try testing.expect(pool.page_table.get(key0) != null);

    // Page 1 should have been evicted
    const key1 = PageKey{ .file_id = .nodes, .page_id = 1 };
    try testing.expect(pool.page_table.get(key1) == null);
}

test "BufferPoolFull when all frames are pinned" {
    const file = try createTempFile(".test_bp_full");
    defer cleanupTempFile(file, ".test_bp_full");

    const page_size: u32 = 4096;
    var p = Pager.init(file, page_size);
    try writeTestPage(&p, 0, 0xAA);
    try writeTestPage(&p, 1, 0xBB);

    var pool = try BufferPool.init(testing.allocator, page_size, 1);
    defer pool.deinit();
    pool.registerPager(.nodes, &p);

    // Pin page 0 and keep it pinned
    _ = try pool.pin(.nodes, 0);

    // Try to pin page 1 — should fail
    const result = pool.pin(.nodes, 1);
    try testing.expectError(error.BufferPoolFull, result);
}

test "pinNew: data is zeroed" {
    var pool = try BufferPool.init(testing.allocator, 4096, 4);
    defer pool.deinit();

    // pinNew doesn't need a pager (no disk read)
    const frame = try pool.pinNew(.nodes, 0);

    // Verify all data is zero
    const slice = frame.dataSlice();
    for (slice) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }

    try testing.expectEqual(@as(u32, 1), frame.pin_count);
    try testing.expect(frame.valid);
}

test "flushDirty respects LSN threshold" {
    const file = try createTempFile(".test_bp_flush_lsn");
    defer cleanupTempFile(file, ".test_bp_flush_lsn");

    const page_size: u32 = 4096;
    var p = Pager.init(file, page_size);

    var pool = try BufferPool.init(testing.allocator, page_size, 4);
    defer pool.deinit();
    pool.registerPager(.nodes, &p);

    // Create two new pages with different LSNs
    const f0 = try pool.pinNew(.nodes, 0);
    const f0_idx = pool.frameIndex(f0);
    f0.lsn = 5;
    pool.unpin(f0_idx, true);

    const f1 = try pool.pinNew(.nodes, 1);
    const f1_idx = pool.frameIndex(f1);
    f1.lsn = 10;
    pool.unpin(f1_idx, true);

    // Flush only up to LSN 7 — should flush f0 (lsn=5) but not f1 (lsn=10)
    try pool.flushDirty(7);

    try testing.expect(!pool.frames[f0_idx].dirty); // flushed
    try testing.expect(pool.frames[f1_idx].dirty); // still dirty
}

test "LRU ordering: head is most recent, tail is least recent" {
    var pool = try BufferPool.init(testing.allocator, 4096, 4);
    defer pool.deinit();

    const f0 = try pool.pinNew(.nodes, 0);
    const f0_idx = pool.frameIndex(f0);
    pool.unpin(f0_idx, false);

    const f1 = try pool.pinNew(.nodes, 1);
    const f1_idx = pool.frameIndex(f1);
    pool.unpin(f1_idx, false);

    const f2 = try pool.pinNew(.nodes, 2);
    const f2_idx = pool.frameIndex(f2);
    pool.unpin(f2_idx, false);

    // Head should be most recently pinned (f2), tail should be f0
    try testing.expectEqual(@as(?u32, f2_idx), pool.lru_head);
    try testing.expectEqual(@as(?u32, f0_idx), pool.lru_tail);
}

test "flushDirtyPages flushes dirty unpinned frames from LRU tail" {
    const file = try createTempFile(".test_bp_flush_dirty_pages");
    defer cleanupTempFile(file, ".test_bp_flush_dirty_pages");

    const page_size: u32 = 4096;
    var p = Pager.init(file, page_size);

    var pool = try BufferPool.init(testing.allocator, page_size, 8);
    defer pool.deinit();
    pool.registerPager(.nodes, &p);

    // Create 4 dirty unpinned pages
    var indices: [4]u32 = undefined;
    for (0..4) |i| {
        const f = try pool.pinNew(.nodes, @intCast(i));
        indices[i] = pool.frameIndex(f);
        pool.unpin(indices[i], true); // mark dirty
    }

    // All 4 should be dirty
    for (indices) |idx| {
        try testing.expect(pool.frames[idx].dirty);
    }

    // Flush at most 2
    const flushed = try pool.flushDirtyPages(2);
    try testing.expectEqual(@as(u32, 2), flushed);

    // Count remaining dirty frames
    var still_dirty: u32 = 0;
    for (indices) |idx| {
        if (pool.frames[idx].dirty) still_dirty += 1;
    }
    try testing.expectEqual(@as(u32, 2), still_dirty);
}

test "flushDirtyPages skips pinned frames" {
    const file = try createTempFile(".test_bp_flush_skip_pinned");
    defer cleanupTempFile(file, ".test_bp_flush_skip_pinned");

    const page_size: u32 = 4096;
    var p = Pager.init(file, page_size);

    var pool = try BufferPool.init(testing.allocator, page_size, 4);
    defer pool.deinit();
    pool.registerPager(.nodes, &p);

    // Create page 0: dirty but pinned (should be skipped)
    const f0 = try pool.pinNew(.nodes, 0);
    const f0_idx = pool.frameIndex(f0);
    f0.dirty = true; // mark dirty but don't unpin

    // Create page 1: dirty and unpinned (should be flushed)
    const f1 = try pool.pinNew(.nodes, 1);
    const f1_idx = pool.frameIndex(f1);
    pool.unpin(f1_idx, true);

    const flushed = try pool.flushDirtyPages(10);
    try testing.expectEqual(@as(u32, 1), flushed);

    // f0 still dirty (was pinned), f1 clean (was flushed)
    try testing.expect(pool.frames[f0_idx].dirty);
    try testing.expect(!pool.frames[f1_idx].dirty);
}

test "flushDirtyPages returns 0 when no dirty pages" {
    var pool = try BufferPool.init(testing.allocator, 4096, 4);
    defer pool.deinit();

    // Create clean unpinned page
    const f0 = try pool.pinNew(.nodes, 0);
    const f0_idx = pool.frameIndex(f0);
    pool.unpin(f0_idx, false); // not dirty

    const flushed = try pool.flushDirtyPages(10);
    try testing.expectEqual(@as(u32, 0), flushed);
}

test "GAP-0089: pin waits for an in-flight page load" {
    var pool = try BufferPool.init(testing.allocator, 4096, 2);
    defer pool.deinit();

    const reserved = pool.free_list.pop() orelse unreachable;
    try testing.expectEqual(@as(u32, 0), reserved);

    pool.frames[reserved].file_id = .nodes;
    pool.frames[reserved].page_id = 7;
    pool.frames[reserved].pin_count = 1;
    pool.frames[reserved].dirty = false;
    pool.frames[reserved].loading = true;
    pool.frames[reserved].valid = false;
    try pool.page_table.put(.{ .file_id = .nodes, .page_id = 7 }, reserved);
    pool.moveToHead(reserved);

    const Loader = struct {
        fn finish(p: *BufferPool) void {
            std.Thread.sleep(20 * std.time.ns_per_ms);
            p.mutex.lock();
            defer p.mutex.unlock();
            p.frames[0].loading = false;
            p.frames[0].valid = true;
            p.cond.broadcast();
        }
    };

    const thread = try std.Thread.spawn(.{}, Loader.finish, .{&pool});
    defer thread.join();

    const frame = try pool.pin(.nodes, 7);
    const frame_idx = pool.frameIndex(frame);
    try testing.expectEqual(@as(u32, 0), frame_idx);
    try testing.expect(!frame.loading);
    try testing.expect(frame.valid);
    try testing.expectEqual(@as(u32, 2), frame.pin_count);

    pool.unpin(frame_idx, false);
}

test {
    std.testing.refAllDecls(@This());
}
