// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const tp = @import("thread_pool");
const types = @import("types.zig");
const page_mod = @import("page.zig");
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
    // PERF-0051: per-FileId minimum number of resident frames. Eviction will
    // not drop a class below its floor while any non-reserved frame is
    // evictable. The floor is *soft*: when the only evictable frames belong to
    // a class at/over its floor, eviction still proceeds (no deadlock / no
    // spurious BufferPoolFull). Indexed by @intFromEnum(FileId); zero == no
    // reservation (classic behaviour).
    reserved_frames: [FILE_COUNT]u32 = [_]u32{0} ** FILE_COUNT,
    // PERF-0051: per-FileId count of currently resident (cached) pages. Kept in
    // lockstep with page_table insert/remove so eviction can enforce the floor
    // without scanning the table.
    resident_counts: [FILE_COUNT]u32 = [_]u32{0} ** FILE_COUNT,
    // Optional metrics pointer for recording buffer hits/misses and page I/O
    metrics: ?*Metrics = null,
    // Concurrency protection for multi-threaded access
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    cond: std.Io.Condition = std.Io.Condition.init,
    // Optional thread pool for parallel page flushes
    thread_pool: ?*tp.ThreadPool = null,

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
            .mutex = std.Io.Mutex.init,
            .cond = std.Io.Condition.init,
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

    /// PERF-0051: Reserve a minimum number of resident frames for `file_id`.
    ///
    /// While any non-reserved frame is evictable, eviction will avoid dropping
    /// `file_id` below `count` resident frames. The floor is clamped to the pool
    /// capacity so it can never make the pool unusable. Passing 0 clears the
    /// reservation. Safe to call before or after pages are loaded.
    pub fn setReservedFrames(self: *BufferPool, file_id: FileId, count: u32) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        self.reserved_frames[@intFromEnum(file_id)] = @min(count, self.capacity);
    }

    /// Increment the resident-page counter for `file_id`. Caller holds the mutex.
    fn incrResident(self: *BufferPool, file_id: FileId) void {
        self.resident_counts[@intFromEnum(file_id)] += 1;
    }

    /// Decrement the resident-page counter for `file_id`. Caller holds the mutex.
    fn decrResident(self: *BufferPool, file_id: FileId) void {
        const slot = &self.resident_counts[@intFromEnum(file_id)];
        std.debug.assert(slot.* > 0);
        slot.* -= 1;
    }

    /// Whether evicting one frame of `file_id` would drop it below its reserved
    /// floor. Caller holds the mutex.
    fn wouldUnderflowReserve(self: *const BufferPool, file_id: FileId) bool {
        const idx = @intFromEnum(file_id);
        const reserve = self.reserved_frames[idx];
        if (reserve == 0) return false;
        return self.resident_counts[idx] <= reserve;
    }

    /// Attach a metrics struct for recording buffer hit/miss and page I/O counters.
    pub fn setMetrics(self: *BufferPool, m: *Metrics) void {
        self.metrics = m;
    }

    /// Attach a thread pool for parallel dirty page flushes.
    pub fn setThreadPool(self: *BufferPool, pool: *tp.ThreadPool) void {
        self.thread_pool = pool;
    }

    /// Pin a page: return it from cache or read it from disk.
    /// If the page is already cached, increments pin_count and moves to LRU head.
    /// Otherwise, allocates a frame (evicting LRU if necessary) and reads from disk.
    pub fn pin(self: *BufferPool, file_id: FileId, page_id: PageId) !*PageFrame {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        const key = PageKey{ .file_id = file_id, .page_id = page_id };
        while (true) {
            if (self.page_table.get(key)) |frame_idx| {
                const frame = &self.frames[frame_idx];
                if (frame.loading) {
                    self.cond.waitUncancelable(std.Io.Threaded.global_single_threaded.io(), &self.mutex);
                    continue;
                }
                frame.pin_count += 1;
                self.moveToHead(frame_idx);
                if (self.metrics) |m| m.buffer_hits += 1;
                self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
                return frame;
            }

            if (self.metrics) |m| m.buffer_misses += 1;
            const frame_idx = try self.getFrame();
            const frame = &self.frames[frame_idx];
            const pager = self.pagers[@intFromEnum(file_id)] orelse {
                self.free_list.appendAssumeCapacity(frame_idx);
                self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
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
            self.incrResident(file_id);
            self.moveToHead(frame_idx);

            self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

            var read_err: ?anyerror = null;
            pager.readPage(page_id, frame.dataSlice()) catch |err| switch (err) {
                error.PageNotFound => @memset(frame.dataSlice(), 0),
                else => read_err = err,
            };

            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            if (read_err) |err| {
                frame.pin_count = 0;
                frame.dirty = false;
                frame.loading = false;
                frame.valid = false;
                frame.lsn = 0;
                self.removeFromLru(frame_idx);
                _ = self.page_table.remove(key);
                self.decrResident(file_id);
                self.free_list.appendAssumeCapacity(frame_idx);
                self.cond.broadcast(std.Io.Threaded.global_single_threaded.io());
                self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
                return err;
            }

            frame.loading = false;
            frame.valid = true;
            if (self.metrics) |m| m.page_reads += 1;
            self.cond.broadcast(std.Io.Threaded.global_single_threaded.io());
            self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            return frame;
        }
    }

    /// Pin a new page without reading from disk. Used when creating a new page.
    /// Zeros the data buffer and inserts into cache.
    pub fn pinNew(self: *BufferPool, file_id: FileId, page_id: PageId) !*PageFrame {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

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
        self.incrResident(file_id);
        self.moveToHead(frame_idx);

        return frame;
    }

    /// Unpin a frame. Decrements pin_count and optionally marks dirty.
    pub fn unpin(self: *BufferPool, frame_idx: u32, dirty: bool) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        const frame = &self.frames[frame_idx];
        std.debug.assert(frame.pin_count > 0);
        frame.pin_count -= 1;
        if (dirty) {
            frame.dirty = true;
        }
        if (frame.pin_count == 0) {
            self.cond.broadcast(std.Io.Threaded.global_single_threaded.io());
        }
    }

    /// Flush all dirty frames with LSN <= up_to_lsn to disk.
    pub fn flushDirty(self: *BufferPool, up_to_lsn: Lsn) !void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        for (self.frames, 0..) |*frame, i| {
            _ = i;
            if (frame.dirty and frame.valid and frame.lsn <= up_to_lsn) {
                try self.flushFrame(frame);
            }
        }
    }

    /// Flush all dirty frames to disk regardless of LSN.
    /// When a ThreadPool is attached, dirty pages are written in parallel
    /// using submitBatch + WaitGroup. Otherwise falls back to sequential I/O.
    pub fn flushAll(self: *BufferPool) !void {
        if (self.thread_pool) |pool| {
            return self.flushAllParallel(pool);
        }
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        for (self.frames) |*frame| {
            if (frame.dirty and frame.valid) {
                try self.flushFrame(frame);
            }
        }
    }

    /// Parallel flush: collect dirty frames under mutex, copy data, then
    /// write pages concurrently via submitBatch + WaitGroup.
    fn flushAllParallel(self: *BufferPool, pool: *tp.ThreadPool) !void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());

        // Count dirty frames
        var dirty_count: usize = 0;
        for (self.frames) |*frame| {
            if (frame.dirty and frame.valid) dirty_count += 1;
        }

        if (dirty_count == 0) {
            self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            return;
        }

        // Allocate descriptors and a contiguous data buffer for page copies
        const items = self.allocator.alloc(FlushItem, dirty_count) catch {
            self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            return error.OutOfMemory;
        };
        const ps: usize = self.page_size;
        const data_buf = self.allocator.alloc(u8, dirty_count * ps) catch {
            self.allocator.free(items);
            self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
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
                    self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
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
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        // Parallel I/O via submitBatch + WaitGroup
        const MAX_CHUNKS = 64;
        const n_chunks = @min(dirty_count, MAX_CHUNKS);
        var flush_ctxs: [MAX_CHUNKS]FlushChunkCtx = undefined;
        var batch_tasks: [MAX_CHUNKS]tp.BatchTask = undefined;
        var wg = pool.waitGroup();

        const chunk_size = (dirty_count + n_chunks - 1) / n_chunks;
        var n_chunks_actual: usize = 0;
        {
            var item_i: usize = 0;
            while (item_i < dirty_count) : (n_chunks_actual += 1) {
                const end = @min(item_i + chunk_size, dirty_count);
                flush_ctxs[n_chunks_actual] = .{
                    .items = items[item_i..end],
                    .data_buf = data_buf,
                    .page_size = self.page_size,
                };
                batch_tasks[n_chunks_actual] = .{
                    .task_fn = flushChunkFn,
                    .ctx = &flush_ctxs[n_chunks_actual],
                };
                item_i = end;
            }
        }

        // Single source of truth for done-counting: SubmitOptions.wait_group
        // auto-adds on each successful submit and auto-dones on completion.
        // Unsubmitted chunks run inline below *before* wg.wait(), so they
        // don't need their own wg accounting.
        const submitted: usize = if (pool.submitBatch(batch_tasks[0..n_chunks_actual], .{ .wait_group = &wg })) |r|
            r.submitted
        else |_|
            0;
        for (flush_ctxs[submitted..n_chunks_actual]) |*c| {
            flushChunkFn(c, undefined);
        }

        wg.wait();

        // Re-acquire mutex to unpin frames and handle errors
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        var first_err: ?anyerror = null;
        var write_count: u64 = 0;
        for (items) |*item| {
            self.frames[item.frame_idx].pin_count -= 1;
            if (item.err) |e| {
                self.frames[item.frame_idx].dirty = true;
                if (first_err == null) first_err = e;
            } else {
                // SEC-0037: writePage incremented write_count in the per-flush
                // copy (data_buf), not in the live cached frame. Propagate the
                // persisted write_count back so a later flush of this still-cached
                // page derives a strictly greater AES-GCM nonce. Only relevant
                // when encryption is active for this page's pager.
                if (item.pager.encryption != null) {
                    const copy = data_buf[item.data_offset..][0..ps];
                    page_mod.writeWriteCount(self.frames[item.frame_idx].dataSlice(), page_mod.readWriteCount(copy));
                }
                write_count += 1;
            }
        }
        if (self.metrics) |m| m.page_writes += write_count;
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        self.allocator.free(data_buf);
        self.allocator.free(items);

        if (first_err) |e| return e;
    }

    /// Flush up to max_count dirty unpinned pages to disk, starting from the LRU tail.
    /// Returns the number of pages actually flushed. This is intended to be called
    /// proactively (e.g. during maintenance) to reduce eviction stalls.
    pub fn flushDirtyPages(self: *BufferPool, max_count: u32) !u32 {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
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

        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        p.writePage(pid, buf[0..self.page_size]) catch |err| {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            frame.pin_count -= 1;
            // Restore dirty state if write failed so we can retry later
            frame.dirty = true;
            return err;
        };
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());

        // SEC-0037: writePage incremented write_count in its private copy `buf`,
        // not in the live cached frame. Propagate the persisted write_count back
        // into the live frame so the next flush of this still-cached page derives
        // a strictly greater AES-GCM nonce (nonce reuse otherwise). Only relevant
        // when encryption is active; harmless but unnecessary in plaintext mode.
        if (p.encryption != null) {
            page_mod.writeWriteCount(frame.dataSlice(), page_mod.readWriteCount(buf[0..self.page_size]));
        }

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
    ///
    /// PERF-0051: Two-pass walk from the LRU tail towards the head:
    ///   1. Prefer the least-recently-used evictable frame whose eviction does
    ///      NOT drop its FileId below its reserved floor. This keeps hot
    ///      reserved classes (e.g. node pages) resident under a flood of cold
    ///      scans from other classes.
    ///   2. If pass 1 finds nothing (every evictable frame belongs to a class
    ///      at/under its floor), fall back to evicting the least-recently-used
    ///      evictable frame regardless of reservation. This guarantees the
    ///      floor can never cause a deadlock or a spurious BufferPoolFull: if
    ///      ANY unpinned frame exists, eviction succeeds.
    fn evict(self: *BufferPool) !u32 {
        // Pass 1: honour reservation floors.
        var current = self.lru_tail;
        while (current) |idx| {
            const frame = &self.frames[idx];
            const prev = frame.lru_prev;
            if (frame.isEvictable() and !self.wouldUnderflowReserve(frame.file_id)) {
                try self.evictFrame(idx);
                return idx;
            }
            current = prev;
        }

        // Pass 2: reservation floor is the only thing left standing; evicting a
        // reserved frame is required to make progress, so allow it.
        current = self.lru_tail;
        while (current) |idx| {
            const frame = &self.frames[idx];
            const prev = frame.lru_prev;
            if (frame.isEvictable()) {
                try self.evictFrame(idx);
                return idx;
            }
            current = prev;
        }

        return error.BufferPoolFull;
    }

    /// Flush (if dirty), drop from the page table / LRU list, and reset a frame
    /// so it can be reused. Caller holds the mutex and has confirmed the frame
    /// is evictable. Keeps `resident_counts` in lockstep with the page table.
    fn evictFrame(self: *BufferPool, idx: u32) !void {
        const frame = &self.frames[idx];

        // Flush if dirty
        if (frame.dirty) {
            try self.flushFrame(frame);
        }

        // Remove from page table
        const key = PageKey{ .file_id = frame.file_id, .page_id = frame.page_id };
        _ = self.page_table.remove(key);
        self.decrResident(frame.file_id);

        // Remove from LRU list
        self.removeFromLru(idx);

        // Reset frame
        frame.valid = false;
        frame.pin_count = 0;
        frame.dirty = false;
        frame.loading = false;
        frame.lsn = 0;
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
    // Parallel flush types (used by flushAllParallel via submitBatch + WaitGroup)
    // ========================================================================

    const FlushItem = struct {
        pager: *const Pager,
        page_id: PageId,
        frame_idx: u32,
        data_offset: usize,
        err: ?anyerror,
    };

    const FlushChunkCtx = struct {
        items: []FlushItem,
        data_buf: []u8,
        page_size: u32,
    };

    /// Task function: write all pages in one chunk, record per-item errors.
    /// Per-task WaitGroup accounting is driven by `SubmitOptions.wait_group`
    /// on the submitBatch call site — thread-pool auto-adds on submit and
    /// auto-dones on task completion, so this function must NOT call
    /// `wg.done()` itself. Inline-fallback invocations (for chunks that
    /// submitBatch did not enqueue) are correct too: they don't touch `wg`
    /// because they run on the caller thread before `wg.wait()`.
    fn flushChunkFn(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
        const c: *FlushChunkCtx = @ptrCast(@alignCast(ctx_ptr));
        for (c.items) |*item| {
            const data = c.data_buf[item.data_offset..][0..c.page_size];
            item.pager.writePage(item.page_id, data) catch |e| {
                item.err = e;
            };
        }
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

fn createTempFile(name: []const u8) !std.Io.File {
    return std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), name, .{
        .read = true,
        .truncate = true,
    });
}

fn cleanupTempFile(file: std.Io.File, name: []const u8) void {
    file.close(std.Io.Threaded.global_single_threaded.io());
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), name) catch {};
}

/// Write a page with known data pattern to a file via a pager.
fn writeTestPage(p: *Pager, page_id: PageId, pattern: u8) !void {
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
            std.Io.Threaded.global_single_threaded.io().sleep(std.Io.Duration.fromMilliseconds(20), .awake) catch {};
            p.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer p.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            p.frames[0].loading = false;
            p.frames[0].valid = true;
            p.cond.broadcast(std.Io.Threaded.global_single_threaded.io());
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

test "SEC-0037: re-flushing a cached encrypted page advances on-disk write_count (no nonce reuse)" {
    // Without the fix, flushFrame copies the frame before writePage increments
    // write_count, so the live cached frame never advances. Re-flushing the same
    // hot page across two checkpoints reuses write_count N+1 -> SAME AES-GCM nonce.
    const file = try createTempFile(".test_bp_sec0037_seq");
    defer cleanupTempFile(file, ".test_bp_sec0037_seq");

    const encryption_mod = @import("encryption.zig");
    const page_size: u32 = 4096;
    const key = [_]u8{0x37} ** 32;
    var p = Pager.init(file, page_size);
    p.encryption = encryption_mod.PageEncryption.init(key);

    var pool = try BufferPool.init(testing.allocator, page_size, 4);
    defer pool.deinit();
    pool.registerPager(.nodes, &p);

    // Pin a fresh page (write_count starts at 0 in the zeroed frame).
    const frame = try pool.pinNew(.nodes, 0);
    const frame_idx = pool.frameIndex(frame);

    // First modification + flush (the page stays cached -- doCheckpoint does NOT evict).
    @memset(frame.dataSlice()[page_mod.PAGE_HEADER_SIZE..], 0x11);
    frame.dirty = true;
    try pool.flushAll();

    // Capture the persisted write_count from the raw on-disk header bytes.
    var raw1: [4096]u8 = undefined;
    _ = try file.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), &raw1, 0);
    const wc1 = page_mod.readWriteCount(&raw1);

    // Second modification (DIFFERENT content) + flush, WITHOUT poking write_count.
    @memset(frame.dataSlice()[page_mod.PAGE_HEADER_SIZE..], 0x22);
    frame.dirty = true;
    try pool.flushAll();

    var raw2: [4096]u8 = undefined;
    _ = try file.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), &raw2, 0);
    const wc2 = page_mod.readWriteCount(&raw2);

    // The on-disk write_count MUST strictly increase between the two flushes,
    // otherwise the same (page_id, file_id, write_count) nonce is reused.
    try testing.expect(wc2 > wc1);

    _ = frame_idx;
}

test "SEC-0037: re-flushing a cached encrypted page advances write_count under parallel flush" {
    // Same invariant as the sequential test, exercised through the ThreadPool
    // path (flushAllParallel / flushChunkFn) which uses a separate copy buffer.
    const encryption_mod = @import("encryption.zig");
    const file = try createTempFile(".test_bp_sec0037_par");
    defer cleanupTempFile(file, ".test_bp_sec0037_par");

    const page_size: u32 = 4096;
    const key = [_]u8{0x73} ** 32;
    var p = Pager.init(file, page_size);
    p.encryption = encryption_mod.PageEncryption.init(key);

    var pool = try BufferPool.init(testing.allocator, page_size, 4);
    defer pool.deinit();
    pool.registerPager(.nodes, &p);

    var thread_pool = try tp.ThreadPool.init(testing.allocator, .{ .max_threads = 2 });
    defer thread_pool.deinit();
    pool.setThreadPool(&thread_pool);

    const frame = try pool.pinNew(.nodes, 0);

    @memset(frame.dataSlice()[page_mod.PAGE_HEADER_SIZE..], 0x33);
    frame.dirty = true;
    try pool.flushAll();

    var raw1: [4096]u8 = undefined;
    _ = try file.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), &raw1, 0);
    const wc1 = page_mod.readWriteCount(&raw1);

    @memset(frame.dataSlice()[page_mod.PAGE_HEADER_SIZE..], 0x44);
    frame.dirty = true;
    try pool.flushAll();

    var raw2: [4096]u8 = undefined;
    _ = try file.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), &raw2, 0);
    const wc2 = page_mod.readWriteCount(&raw2);

    try testing.expect(wc2 > wc1);
}

test "PERF-0051: reserved node frames survive a flood of cold prop-page accesses" {
    const node_file = try createTempFile(".test_bp_perf0051_nodes");
    defer cleanupTempFile(node_file, ".test_bp_perf0051_nodes");
    const prop_file = try createTempFile(".test_bp_perf0051_props");
    defer cleanupTempFile(prop_file, ".test_bp_perf0051_props");

    const page_size: u32 = 4096;
    var node_pager = Pager.init(node_file, page_size);
    var prop_pager = Pager.init(prop_file, page_size);

    // One hot node page (page 0) and many cold prop pages (0..15).
    try writeTestPage(&node_pager, 0, 0xAA);
    var i: PageId = 0;
    while (i < 16) : (i += 1) {
        try writeTestPage(&prop_pager, i, 0xBB);
    }

    // Pool of 8 frames; reserve 2 frames for node pages.
    var pool = try BufferPool.init(testing.allocator, page_size, 8);
    defer pool.deinit();
    pool.registerPager(.nodes, &node_pager);
    pool.registerPager(.props, &prop_pager);
    pool.setReservedFrames(.nodes, 2);

    // Bring the hot node page resident and unpin it (eviction-eligible).
    const nf = try pool.pin(.nodes, 0);
    const nf_idx = pool.frameIndex(nf);
    pool.unpin(nf_idx, false);

    // Flood the pool with cold prop-page reads, far more than the pool holds.
    i = 0;
    while (i < 16) : (i += 1) {
        const pf = try pool.pin(.props, i);
        pool.unpin(pool.frameIndex(pf), false);
    }

    // The reserved hot node page must still be cached despite the flood.
    const node_key = PageKey{ .file_id = .nodes, .page_id = 0 };
    try testing.expect(pool.page_table.get(node_key) != null);
    // Re-pinning the node page must return the cached data.
    const nf2 = try pool.pin(.nodes, 0);
    const body = nf2.dataSlice()[page_mod.PAGE_HEADER_SIZE..];
    for (body) |byte| try testing.expectEqual(@as(u8, 0xAA), byte);
    pool.unpin(pool.frameIndex(nf2), false);

    // resident_counts must stay in lockstep with the page table.
    try testing.expectEqual(@as(u32, 1), pool.resident_counts[@intFromEnum(FileId.nodes)]);
}

test "PERF-0051: reservation does not deadlock when the reserved class fills the pool" {
    const node_file = try createTempFile(".test_bp_perf0051_full_nodes");
    defer cleanupTempFile(node_file, ".test_bp_perf0051_full_nodes");
    const prop_file = try createTempFile(".test_bp_perf0051_full_props");
    defer cleanupTempFile(prop_file, ".test_bp_perf0051_full_props");

    const page_size: u32 = 4096;
    var node_pager = Pager.init(node_file, page_size);
    var prop_pager = Pager.init(prop_file, page_size);

    var i: PageId = 0;
    while (i < 8) : (i += 1) {
        try writeTestPage(&node_pager, i, 0xAA);
    }
    try writeTestPage(&prop_pager, 0, 0xCC);

    // Pool of 4 frames, reserve ALL 4 for node pages.
    var pool = try BufferPool.init(testing.allocator, page_size, 4);
    defer pool.deinit();
    pool.registerPager(.nodes, &node_pager);
    pool.registerPager(.props, &prop_pager);
    pool.setReservedFrames(.nodes, 4);

    // Fill the pool entirely with (unpinned) node pages, exactly at the floor.
    i = 0;
    while (i < 4) : (i += 1) {
        const f = try pool.pin(.nodes, i);
        pool.unpin(pool.frameIndex(f), false);
    }
    try testing.expectEqual(@as(u32, 4), pool.resident_counts[@intFromEnum(FileId.nodes)]);

    // Pinning a prop page now requires evicting a reserved node frame. The
    // soft-floor fallback (pass 2) MUST allow this rather than deadlocking or
    // returning BufferPoolFull.
    const pf = try pool.pin(.props, 0);
    try testing.expect(pf.valid);
    const body = pf.dataSlice()[page_mod.PAGE_HEADER_SIZE..];
    for (body) |byte| try testing.expectEqual(@as(u8, 0xCC), byte);
    pool.unpin(pool.frameIndex(pf), false);

    // One node frame was sacrificed; counts remain consistent.
    try testing.expectEqual(@as(u32, 3), pool.resident_counts[@intFromEnum(FileId.nodes)]);
    try testing.expectEqual(@as(u32, 1), pool.resident_counts[@intFromEnum(FileId.props)]);
}

test "PERF-0051: BufferPoolFull still raised when reserved frames are all pinned" {
    const node_file = try createTempFile(".test_bp_perf0051_pinned");
    defer cleanupTempFile(node_file, ".test_bp_perf0051_pinned");
    const prop_file = try createTempFile(".test_bp_perf0051_pinned_props");
    defer cleanupTempFile(prop_file, ".test_bp_perf0051_pinned_props");

    const page_size: u32 = 4096;
    var node_pager = Pager.init(node_file, page_size);
    var prop_pager = Pager.init(prop_file, page_size);
    try writeTestPage(&node_pager, 0, 0xAA);
    try writeTestPage(&node_pager, 1, 0xAB);
    try writeTestPage(&prop_pager, 0, 0xCC);

    var pool = try BufferPool.init(testing.allocator, page_size, 2);
    defer pool.deinit();
    pool.registerPager(.nodes, &node_pager);
    pool.registerPager(.props, &prop_pager);
    pool.setReservedFrames(.nodes, 2);

    // Pin both frames with node pages and keep them pinned.
    _ = try pool.pin(.nodes, 0);
    _ = try pool.pin(.nodes, 1);

    // No evictable frame exists in either pass -> must still surface the error
    // rather than spin or corrupt the floor accounting.
    try testing.expectError(error.BufferPoolFull, pool.pin(.props, 0));
}

test {
    std.testing.refAllDecls(@This());
}
