// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const builtin = @import("builtin");
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

/// The single-threaded blocking Io used for all lock primitives in this file
/// (same instance used throughout the engine). Centralised so the PERF-0058
/// `mutex`/`cond` call sites stay readable.
inline fn bpio() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// PERF-0058 seqlock read side: order the speculative (plain) loads of the
/// lock-free lookup BEFORE the validating `table_gen` re-load. An acquire load
/// keeps LATER accesses after it but lets EARLIER plain loads sink below it,
/// which would let a torn read pass validation. x86 never reorders loads with
/// loads, so only the compiler needs fencing there; aarch64 needs `dmb ishld`
/// (Linux `smp_rmb`). Any other target falls back to a release RMW, which
/// orders every earlier access before it.
inline fn seqlockReadFence(gen: *std.atomic.Value(u64)) u64 {
    switch (builtin.cpu.arch) {
        .x86_64, .x86 => {
            asm volatile ("" ::: .{ .memory = true });
            return gen.load(.acquire);
        },
        .aarch64 => {
            asm volatile ("dmb ishld" ::: .{ .memory = true });
            return gen.load(.acquire);
        },
        else => return gen.fetchAdd(0, .acq_rel),
    }
}

/// ThreadSanitizer annotations for the ONE intentionally racy region: the
/// lock-free fast path's speculative page-table lookup and frame-identity
/// pre-check in `BufferPool.pin`. Those plain reads race with the slow path's
/// mutex-held page-table insert/remove and frame (re)publication BY DESIGN —
/// a seqlock reader. Their result is never trusted unless (1) `table_gen` was
/// even and unchanged across the lookup (no structural writer overlapped), and
/// (2) after the pin CAS succeeds, `table_gen` is still unchanged and the frame
/// still holds the requested page; otherwise the pin is undone and the slow
/// path runs. Only READS of this thread inside the region are ignored: every
/// write, and every read elsewhere (incl. the post-pin re-validation), stays
/// instrumented. Proven by tests/buffer_pool_concurrent_readers.zig (every
/// read checked; TSan step reports nothing) and buffer_pool_recreate_uaf.zig.
const tsan = struct {
    extern fn AnnotateIgnoreReadsBegin(file: [*:0]const u8, line: c_int) void;
    extern fn AnnotateIgnoreReadsEnd(file: [*:0]const u8, line: c_int) void;

    inline fn ignoreReadsBegin() void {
        if (builtin.sanitize_thread) AnnotateIgnoreReadsBegin(@src().file, @src().line);
    }

    inline fn ignoreReadsEnd() void {
        if (builtin.sanitize_thread) AnnotateIgnoreReadsEnd(@src().file, @src().line);
    }
};

/// PERF-0058: sentinel `pin_count` value meaning "exclusively claimed by an
/// eviction in progress" (flush + teardown). Eviction claims an UNPINNED frame
/// by atomically CAS-ing `pin_count` 0 -> PIN_EVICTING; while it holds this
/// sentinel no other thread can pin the frame (the lock-free fast path's pin is
/// a CAS that fails against the sentinel, and `isEvictable` excludes it). Because
/// the claim and every pin are CAS operations on the SAME word, they are totally
/// ordered by that atomic's modification order — exactly one wins — which makes
/// the pin-vs-evict exclusion provably correct WITHOUT any Dekker/StoreLoad
/// fence. Chosen as max-u32 so it can never collide with a real pin count (the
/// pool has at most `capacity` frames, far below 2^32 pins).
pub const PIN_EVICTING: u32 = std.math.maxInt(u32);

/// FIX #2 (edge-ingest wedge robustness): upper bound on how long a slow-path
/// pinner parks in the loading/evicting wait before it wakes ITSELF, re-takes
/// the mutex, and re-evaluates. The wait is woken PROMPTLY by `wakeFrameWaiters`
/// on every load/evict/unpin transition (the common, event-driven path); this
/// bound is a pure SAFETY NET that makes "park forever" structurally impossible:
/// even if a wakeup were ever dropped (today or by a future change), the pinner
/// re-checks within this interval and makes progress. A loading/evicting frame
/// is a transient state (microseconds), so the bound never gates steady-state
/// throughput — it only ever fires on a genuinely-lost wakeup. Kept short so
/// recovery from a (theoretical) lost wakeup is sub-perceptible.
pub const FRAME_WAIT_TIMEOUT_NS: u64 = 2 * std.time.ns_per_ms;

/// PERF-0056: upper bound (in pages) on the reusable parallel-flush scratch
/// buffer. With a 16 KiB page this caps the transient flush allocation at
/// 16 MiB regardless of how many pages are dirty in a single checkpoint;
/// larger dirty sets are written in successive capacity-sized waves.
pub const PARALLEL_FLUSH_SCRATCH_PAGES: usize = 1024;

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
    // PERF (CLOCK eviction): count of `moveToHead` calls made WHILE the eviction
    // victim-selection loop is active (see `in_evict`). The textbook CLOCK
    // hand-advance must NOT move frames while sweeping, so the current
    // implementation makes ZERO such calls and this stays exactly 0. The prior
    // second-chance code moved every referenced frame to the head per sweep (O(N)
    // list writes per victim, O(K*N) for K victims under a hot scan — the
    // 62%-self-time hotspot). `moveToHead` self-increments this ONLY when
    // `in_evict` is set, so a reintroduced in-sweep `moveToHead` (the O(N)
    // restart regression) is caught automatically by the `== 0` assertion in the
    // CLOCK-eviction regression test — the ordinary pin/pinNew `moveToHead` runs
    // with `in_evict` clear and is not counted. Both fields are mutated only
    // under `mutex`, so plain (non-atomic) fields suffice.
    evict_list_moves: usize = 0,
    // Set for the duration of `evict()` (victim selection). Read by `moveToHead`
    // to decide whether to bump `evict_list_moves`. Written only under `mutex`.
    in_evict: bool = false,
    // PERF-0057: per-FileId "needs fsync" flags. Set whenever a page is
    // successfully written to a file's pager via any flush path (flushFrame,
    // flushAllParallel, eviction). Cleared only by takeDirtyFiles() once the
    // caller commits to fsyncing that file. This lets the checkpointer fsync
    // ONLY the store files actually modified since their last successful sync,
    // without ever dropping a fsync the data depends on. Indexed by
    // @intFromEnum(FileId). Always mutated under `mutex`.
    dirty_files: [FILE_COUNT]bool = [_]bool{false} ** FILE_COUNT,
    // PERF-0056: bounded scratch buffer reused by flushAllParallel instead of
    // allocating dirty_count*page_size per checkpoint. Grown on demand up to
    // max_scratch_pages pages; flushes with more dirty pages are written in
    // capacity-sized waves so peak transient memory stays bounded.
    flush_scratch: []u8 = &.{},
    // PERF-0056: cap (in pages) on the reusable scratch buffer. Defaults to
    // PARALLEL_FLUSH_SCRATCH_PAGES; lowered in tests to exercise the wave path.
    max_scratch_pages: usize = PARALLEL_FLUSH_SCRATCH_PAGES,
    // Concurrency protection for multi-threaded access.
    //
    // `mutex` guards ALL structural mutation (the page table, LRU list, free
    // list, eviction/load coordination, dirty-file flags, reserved-frame
    // accounting) — UNCHANGED from the v0.2.6 dirty-eviction-race fix. Every
    // structural mutator still holds `mutex` exactly as before.
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    // FIX #2 (edge-ingest wedge robustness): the loading/evicting wait protocol.
    //
    // A slow-path pinner that finds its target frame mid load/evict must park
    // until that transition completes. v0.2.6..v0.2.11 used `Io.Condition.
    // waitUncancelable`, which sleeps FOREVER if its wakeup is ever lost — and
    // `Io.Condition` exposes no timed wait. Under the 14.27M edge ingest, with
    // 16 handler threads resolving endpoints through property-page chains on a
    // working set vastly exceeding the 512MB engine pool, a parked pinner that
    // missed its wake could wedge the pod ("restart to recover").
    //
    // Replaced with a generation-counter futex wait that is BOTH event-driven
    // (woken promptly by `wakeFrameWaiters` on every load/evict/unpin
    // transition) AND bounded (`FRAME_WAIT_TIMEOUT_NS`): a waiter snapshots
    // `wait_gen` UNDER the mutex, releases the mutex, and `futexWaitTimeout`s on
    // `wait_gen` until it changes OR the bound elapses, then re-takes the mutex
    // and re-evaluates the loop. Because the snapshot is taken under the mutex
    // and every waker bumps `wait_gen` (release) before/at its wake, a wake that
    // races the park is NEVER lost (the futex returns immediately when the
    // observed value already differs from the snapshot). The bound then
    // guarantees progress even against a (theoretical) dropped wake: pin can
    // NEVER sleep forever. This is the v0.2.6 wait protocol made deadlock-proof,
    // not a new coordination model — the mutex discipline is identical.
    wait_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// SONNY-6632: page writes in flight, pool-wide (the sum of every frame's
    /// `writes_in_flight`). Under `mutex`. A durability flush (`flushAll`,
    /// `flushDirty`) waits for it to reach zero: the frames of those writes
    /// were already clean when it looked, and their new image is not on disk
    /// until the writes land.
    writes_in_flight_total: u32 = 0,
    // PERF-0058 (pin-contention): a SEQLOCK generation counter that lets the
    // COMMON cache-HIT pin/unpin path run lock-free, so concurrent readers no
    // longer serialize on the pool-wide `mutex` (which collapsed aggregate
    // throughput to BELOW single-thread under many cores). It is the single most
    // important field for read scaling.
    //
    // PROTOCOL:
    //   * EVEN value  => the page table + frame identities are STABLE (no
    //     structural writer in its critical region).
    //   * ODD value   => a structural writer (a page_table insert/remove, a frame
    //     identity change, an eviction teardown) is IN PROGRESS; the table/frames
    //     may be momentarily inconsistent and the lock-free fast path must defer.
    //   Writers (always under `mutex`) bracket every page_table mutation / frame
    //   identity change with `beginTableWrite()` (gen -> odd, release) ...
    //   `endTableWrite()` (gen -> even, release).
    //
    //   The fast path reads `table_gen` (acquire) BEFORE and AFTER its lock-free
    //   `page_table.get`; if the value changed or was odd, a writer overlapped the
    //   lookup, so the result is discarded and the slow (mutex) path is taken.
    //   "gen stable & even across the get" PROVES no put/remove overlapped the
    //   get — so the get observed a fully consistent, non-rehashing map and can
    //   neither tear nor crash. After atomically bumping `pin_count` the fast path
    //   re-checks the frame identity + gen once more to close the
    //   lookup->pin window against a writer that starts mid-pin (see `pin`).
    //
    // The fast path therefore writes only its own frame's `pin_count`/`referenced`
    // cachelines and merely READS the shared `table_gen` (shared reads don't
    // ping-pong), so it scales ~linearly with cores. The page table is pre-sized
    // to `capacity` at init and never holds more than `capacity` entries, so it
    // never rehashes — its bucket storage never moves under a lock-free reader.
    table_gen: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    // PERF-0058: number of threads currently PARKED in the slow-path
    // loading/evicting wait. Incremented (under `mutex`) right before the wait
    // (FIX #2: a bounded `wait_gen` futex wait — see `waitFrameChange`),
    // decremented right after. `unpin` consults it to decide whether to wake
    // anyone: in the overwhelmingly common case (no parked waiter) unpin stays
    // FULLY LOCK-FREE. The acquire load here pairs with the release increment;
    // a waiter that parked before our decrement is observed. Without this,
    // every unpin would have to issue a (now lock-free) wake — still cheap, but
    // the gate keeps the hot read path free of even the futex syscall.
    pin_waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    // Optional thread pool for parallel page flushes
    thread_pool: ?*tp.ThreadPool = null,

    /// Initialize a buffer pool with the given capacity (number of frames).
    pub fn init(allocator: Allocator, page_size: u32, capacity: u32) !BufferPool {
        // PERF: back the page-frame data with an ANONYMOUS PRIVATE mmap instead
        // of an allocator alloc followed by an eager `@memset(.., 0)`. The kernel
        // zero-fills mapped pages LAZILY on first fault, so open no longer pays a
        // capacity-proportional zeroing pass (~0.5-1s for a multi-hundred-MB
        // pool; GBs across 16 shards). A freshly-faulted anonymous page reads as
        // zero — the SAME guarantee the `@memset` provided — so any frame whose
        // first use reads before a write still observes zeros (and `pinNew`
        // memsets the frame on reuse regardless). The mapping is page (>=4096)
        // aligned, preserving the previous 4096-byte alignment contract. Pages
        // still fault in on first `pin`/`pinNew` exactly as before — only the
        // eager up-front zero is removed.
        const map_len = @as(usize, capacity) * @as(usize, page_size);
        const page_buf: []align(4096) u8 = @alignCast(try std.posix.mmap(
            null,
            map_len,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ));

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
            .wait_gen = std.atomic.Value(u32).init(0),
        };
    }

    /// Free all resources owned by the buffer pool.
    pub fn deinit(self: *BufferPool) void {
        self.page_table.deinit();
        self.free_list.deinit(self.allocator);
        self.allocator.free(self.frames);
        // page_buf is an anonymous mmap (see init), not an allocator allocation.
        std.posix.munmap(@alignCast(self.page_buf));
        if (self.flush_scratch.len != 0) self.allocator.free(self.flush_scratch);
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

    /// PERF-0058: open a structural-write critical region — bump `table_gen` to
    /// ODD so the lock-free fast path defers while the page table / a frame's
    /// identity is being mutated. Caller holds `mutex`. MUST be paired with
    /// `endTableWrite`. Re-entrancy is NOT supported: a writer must not nest these
    /// (every call site below brackets one contiguous mutation region).
    /// PERF-0058 CORRECTNESS: the gen->odd store and the eviction's subsequent
    /// `pin_count` re-check load form a Dekker/StoreLoad handshake with the fast
    /// path's `pin_count` increment and its `gen` re-load. StoreLoad is the one
    /// reordering even x86-TSO permits, so BOTH the gen stores here and the
    /// matching fast-path/eviction accesses use `.seq_cst` to establish a single
    /// total order — guaranteeing at least one side observes the other (no
    /// frame is repurposed under a freshly-taken lock-free pin).
    fn beginTableWrite(self: *BufferPool) void {
        const g = self.table_gen.load(.monotonic);
        std.debug.assert(g & 1 == 0); // must be even (no nested writer)
        self.table_gen.store(g + 1, .seq_cst);
    }

    /// PERF-0058: close a structural-write critical region — bump `table_gen`
    /// back to EVEN. Caller holds `mutex`.
    fn endTableWrite(self: *BufferPool) void {
        const g = self.table_gen.load(.monotonic);
        std.debug.assert(g & 1 == 1); // must be odd (inside a writer)
        self.table_gen.store(g + 1, .seq_cst);
    }

    /// FIX #2: wake every slow-path pinner parked in the loading/evicting wait.
    /// Bumps `wait_gen` (release) so any waiter that snapshotted the old value —
    /// even one still between its snapshot and its `futexWaitTimeout` — observes
    /// the change and does not park (or returns immediately), then wakes all
    /// parked futex waiters. Replaces `cond.broadcast`. Safe to call with or
    /// without the mutex held: it touches only the atomic `wait_gen`. Callers
    /// that mutate frame state (load/evict completion, error rollback) bump it
    /// while holding the mutex so the state change is published before the wake.
    /// EVERY caller holds the mutex (the load/evict completion + error-rollback
    /// paths, and `unpin`'s waiter-present branch): that serialises the wake
    /// against the loader/eviction's plain-store `pin_count`/identity mutations on
    /// a published frame, preserving the v0.2.6 invariant that every `pin_count`
    /// mutation on a table-reachable frame is atomic or mutex-serialised.
    fn wakeFrameWaiters(self: *BufferPool) void {
        _ = self.wait_gen.fetchAdd(1, .release);
        bpio().futexWake(u32, &self.wait_gen.raw, std.math.maxInt(u32));
    }

    /// FIX #2: park the calling slow-path pinner until a frame load/evict/unpin
    /// transition (a `wakeFrameWaiters` bump) OR a bounded timeout, whichever
    /// comes first, then return so the caller re-takes the mutex and re-evaluates
    /// its loop. `expected_gen` MUST be the value of `wait_gen` read while the
    /// caller still held the mutex (so a wake that races the park is never lost:
    /// `futexWaitTimeout` returns immediately when the live value already differs
    /// from `expected_gen`). The caller holds `mutex` on entry; this drops it for
    /// the wait and re-acquires it before returning — same contract as the old
    /// `cond.waitUncancelable(io, &self.mutex)`. The timeout makes "wait forever"
    /// structurally impossible (deadlock-proof against any lost wake).
    fn waitFrameChange(self: *BufferPool, io: std.Io, expected_gen: u32) void {
        self.mutex.unlock(io);
        defer self.mutex.lockUncancelable(io);
        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromNanoseconds(FRAME_WAIT_TIMEOUT_NS),
            .clock = .awake,
        } };
        io.futexWaitTimeout(u32, &self.wait_gen.raw, expected_gen, timeout) catch {};
    }

    /// SONNY-6632: a flush copied `frame` and will write the copy. Caller
    /// holds the mutex.
    fn beginFrameWrite(self: *BufferPool, frame: *PageFrame) void {
        frame.writes_in_flight += 1;
        self.writes_in_flight_total += 1;
    }

    /// SONNY-6632: a flush's write of `frame` landed or failed; wakes the
    /// flushes waiting for it. Caller holds the mutex.
    fn endFrameWrite(self: *BufferPool, frame: *PageFrame) void {
        frame.writes_in_flight -= 1;
        self.writes_in_flight_total -= 1;
        self.wakeFrameWaiters();
    }

    /// SONNY-6632: wait until no flush has a write of `frame` in flight, so
    /// a newer copy is never written before an older one lands (the older
    /// would overwrite it). Caller holds the mutex (dropped while waiting)
    /// and a pin on `frame` or its eviction claim.
    fn waitFrameWrites(self: *BufferPool, io: std.Io, frame: *const PageFrame) void {
        while (frame.writes_in_flight != 0) self.waitFrameChange(io, self.wait_gen.load(.acquire));
    }

    /// SONNY-6632: wait until no flush has a write in flight. Caller holds
    /// the mutex (dropped while waiting).
    fn waitAllWrites(self: *BufferPool, io: std.Io) void {
        while (self.writes_in_flight_total != 0) self.waitFrameChange(io, self.wait_gen.load(.acquire));
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

    /// PERF-0057: mark `file_id` as needing an fsync because a page was just
    /// persisted to its pager. Caller holds the mutex. The flag is only cleared
    /// later by takeDirtyFiles(), so a mark can never be lost between flush and
    /// the fsync that makes the write durable.
    fn markFileDirty(self: *BufferPool, file_id: FileId) void {
        self.dirty_files[@intFromEnum(file_id)] = true;
    }

    /// PERF-0057: atomically read and clear the set of files that have received
    /// page writes since the previous call (or since init). The returned set is
    /// the caller's obligation: it MUST fsync every file flagged `true` before
    /// relying on those writes being durable (e.g. before writing the manifest).
    /// Because the flags are cleared here and only set under the same mutex by
    /// the flush paths, a write that races in after this drain stays flagged for
    /// the next drain — no fsync is ever silently dropped.
    pub fn takeDirtyFiles(self: *BufferPool) [FILE_COUNT]bool {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        const snapshot = self.dirty_files;
        self.dirty_files = [_]bool{false} ** FILE_COUNT;
        return snapshot;
    }

    /// PERF-0057: OR a previously-drained dirty set back into the live flags.
    /// Used by the checkpoint to recover after a failed fsync so the affected
    /// files are re-synced on the next checkpoint and no durability-relevant
    /// fsync is ever lost. Safe to call with a set produced by takeDirtyFiles().
    pub fn restoreDirtyFiles(self: *BufferPool, dirty: [FILE_COUNT]bool) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        for (dirty, 0..) |d, i| {
            if (d) self.dirty_files[i] = true;
        }
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
    ///
    /// CACHE HIT (the common case under concurrent readers) runs LOCK-FREE: it
    /// reads the `table_gen` seqlock, does a lock-free `page_table.get`, and — if
    /// no structural writer overlapped the lookup — atomically bumps `pin_count`
    /// and sets the `referenced` clock bit. No pool-wide `mutex`, no LRU-list
    /// write: the only memory it WRITES is its own frame's `pin_count`/`referenced`
    /// cachelines, so concurrent readers scale ~linearly (PERF-0058). Anything
    /// else — a miss, a frame found mid load/evict, or a writer racing the
    /// lookup — falls through to the structural slow path, which takes the `mutex`
    /// and preserves the v0.2.6 loading/evicting cond-var protocol unchanged.
    pub fn pin(self: *BufferPool, file_id: FileId, page_id: PageId) !*PageFrame {
        const io = bpio();
        const key = PageKey{ .file_id = file_id, .page_id = page_id };

        // ---- FAST PATH: lock-free cache hit. --------------------------------
        // A stable, EVEN `table_gen` ACROSS the lookup proves no page_table
        // insert/remove overlapped it (writers bracket every such mutation with
        // begin/endTableWrite -> odd/even), so the lock-free `get` observed a
        // fully consistent, non-rehashing map. `speculativeLookup` does that
        // lookup + the frame-identity pre-check (the only intentionally racy
        // reads, hidden from TSan — see `tsan`); the second gen check after the
        // pin bump closes the lookup->pin window against a writer that starts
        // mid-pin.
        {
            const g0 = self.table_gen.load(.acquire);
            if (g0 & 1 == 0) {
                tsan.ignoreReadsBegin();
                const candidate = self.speculativeLookup(key, g0);
                tsan.ignoreReadsEnd();
                if (candidate) |frame| {
                    // CAS-increment pin_count, REFUSING the eviction sentinel.
                    // The claim (evict: CAS 0->PIN_EVICTING) and this pin both
                    // CAS the SAME word, so they are totally ordered and mutually
                    // exclusive WITHOUT a Dekker fence: if eviction has claimed the
                    // frame we see PIN_EVICTING and defer; otherwise our pin wins
                    // and eviction's 0->sentinel CAS then fails.
                    var c = @atomicLoad(u32, &frame.pin_count, .acquire);
                    while (c != PIN_EVICTING) {
                        if (@cmpxchgWeak(u32, &frame.pin_count, c, c + 1, .acq_rel, .acquire)) |actual| {
                            c = actual; // contended; retry with fresh value
                            continue;
                        }
                        // Pinned. Re-validate that the frame still holds OUR page
                        // and no structural writer (re)claimed it after the lookup
                        // — a repurpose happens under a gen bracket, so a changed
                        // gen or identity means we pinned a frame that is being /
                        // has been reused: undo and defer. The undo is safe
                        // because every other pin_count change is an atomic RMW
                        // too (see the slow path's publication).
                        if (self.table_gen.load(.acquire) == g0 and
                            frame.file_id == file_id and frame.page_id == page_id and
                            !frame.evicting and frame.valid)
                        {
                            @atomicStore(u8, &frame.referenced, 1, .monotonic);
                            if (self.metrics) |m| _ = @atomicRmw(u64, &m.buffer_hits, .Add, 1, .monotonic);
                            return frame;
                        }
                        _ = @atomicRmw(u32, &frame.pin_count, .Sub, 1, .acq_rel);
                        break;
                    }
                }
            }
            // Miss, writer-overlap, frame loading/evicting, or eviction-claimed:
            // fall through to the structural slow path.
        }

        // ---- SLOW PATH: structural, under `mutex`. Page-table / frame-identity
        // mutations are bracketed by begin/endTableWrite so the fast path defers
        // while they are in flight. The loading/evicting wait protocol is the
        // v0.2.6 logic, made bounded/lost-wakeup-free by FIX #2 (waitFrameChange).
        // -------------------------------------------------------------------
        self.mutex.lockUncancelable(io);
        while (true) {
            if (self.page_table.get(key)) |frame_idx| {
                const frame = &self.frames[frame_idx];
                // A frame still loading, or one being torn down by a concurrent
                // eviction, is unsafe to alias: wait for the transition and
                // re-evaluate. For `loading` the same frame becomes valid and we
                // pin it. For `evicting` the page-table entry is removed once
                // teardown completes, so the re-loop misses and reloads the page
                // fresh (or, if the eviction is aborted, finds it cached again).
                // Either way we never hand back a frame that is about to be — or
                // has just been — repurposed for a different page.
                if (frame.loading or frame.evicting) {
                    // FIX #2: snapshot `wait_gen` UNDER the mutex, then bounded-
                    // wait on it. Snapshotting here (before waitFrameChange drops
                    // the mutex) is what makes the wake lost-wakeup-free: any
                    // `wakeFrameWaiters` that runs after this load and before our
                    // futex park bumped wait_gen, so the park returns at once.
                    // Publish that a waiter is parking (so a lock-free unpin knows
                    // to wake us). Incremented under the mutex.
                    const gen = self.wait_gen.load(.acquire);
                    _ = self.pin_waiters.fetchAdd(1, .acq_rel);
                    self.waitFrameChange(io, gen);
                    _ = self.pin_waiters.fetchSub(1, .acq_rel);
                    continue;
                }
                // Hit discovered on the slow path (e.g. a racing loader just
                // finished). The mutex serialises us against structural writers,
                // so a bare atomic bump is sufficient; set the clock bit instead
                // of an LRU move. No gen bracket needed: pin_count is not part of
                // the seqlock-protected identity (the fast path re-checks it
                // atomically), and we are not changing the page table.
                _ = @atomicRmw(u32, &frame.pin_count, .Add, 1, .acq_rel);
                @atomicStore(u8, &frame.referenced, 1, .monotonic);
                if (self.metrics) |m| _ = @atomicRmw(u64, &m.buffer_hits, .Add, 1, .monotonic);
                self.mutex.unlock(io);
                return frame;
            }

            if (self.metrics) |m| m.buffer_misses += 1;
            // getFrame can fail (e.g. BufferPoolFull when every frame is pinned
            // or mid-eviction). The mutex is held here, so release it before
            // propagating the error -- otherwise the caller's natural retry
            // (`pin` again) would re-lock a mutex this thread still holds and
            // self-deadlock. (Pre-existing latent bug; surfaced by tiny-pool
            // concurrent eviction where BufferPoolFull is common.)
            //
            // getFrame is NOT wrapped in a gen bracket: it may evict a dirty
            // victim, which flushes with the mutex (and the gen) released so other
            // readers keep flowing — evictFrame opens its own fine-grained
            // brackets around the `evicting` publication and the teardown. The
            // frame getFrame returns is NOT in the page table (free or just
            // evicted), so no fast-path reader can reach it until we `put` it.
            const frame_idx = self.getFrame() catch |err| {
                self.mutex.unlock(io);
                return err;
            };

            // CORRECTNESS (double-load window): `getFrame` may have DROPPED the
            // mutex to flush a dirty eviction victim (evictFrame -> writeFrameBytes
            // releases `mutex` across the blocking write). During that window a
            // concurrent slow-path `pin` of THIS SAME key can have missed the
            // table, loaded the page, and inserted it. If we now blindly
            // `putAssumeCapacity(key, ...)` we would (a) overwrite that entry,
            // orphaning the other thread's frame (a permanent leak whose pin never
            // drops), and (b) double-count `resident_counts` (resident > table).
            // So RE-PROBE the table now that the mutex is held again: if the key
            // is resident, give our just-obtained frame back to the free list and
            // restart the loop, which will pin the existing entry via the hit
            // branch (or re-wait if it is still loading/evicting). The frame from
            // getFrame is not in the table, not pinned, and not on the LRU list,
            // so returning it to the free list is safe. (This race PRE-DATES the
            // PERF-0058 lock-free fast path — it exists in v0.2.6 — but the fast
            // path widens the window enough to surface it, so it is fixed here.)
            if (self.page_table.get(key) != null) {
                self.free_list.appendAssumeCapacity(frame_idx);
                // A racing loader may still be holding the frame `loading`; wake
                // semantics are unchanged because the restart re-enters the hit/
                // wait branch under the mutex.
                continue;
            }

            const frame = &self.frames[frame_idx];
            const pager = self.pagers[@intFromEnum(file_id)] orelse {
                self.free_list.appendAssumeCapacity(frame_idx);
                self.mutex.unlock(io);
                return error.NoPagerRegistered;
            };

            // Bracket only the step that makes the frame reachable: set its
            // identity then publish it into the table. The fast path will find it
            // but see loading=true and defer; it cannot be pinned until load
            // completes.
            self.beginTableWrite();
            frame.file_id = file_id;
            frame.page_id = page_id;
            // Publish OUR pin with an atomic +1, never a plain `= 1`: a stale
            // fast-path reader that looked this frame up under its previous
            // identity may have CAS-pinned it after eviction released it, and
            // will undo that pin when its re-validation fails. A plain store
            // would overwrite its +1 and its undo would then steal ours (the
            // frame evicted while we use it).
            _ = @atomicRmw(u32, &frame.pin_count, .Add, 1, .acq_rel);
            frame.referenced = 1;
            frame.dirty = false;
            frame.loading = true;
            frame.evicting = false;
            frame.valid = false;
            frame.lsn = 0;

            // putAssumeCapacity (not put): the table is pre-sized to `capacity`
            // at init and never holds more than `capacity` entries, so it NEVER
            // rehashes — which is exactly what lets the lock-free fast path read
            // it without the bucket storage moving underneath it.
            self.page_table.putAssumeCapacity(key, frame_idx);
            self.incrResident(file_id);
            self.moveToHead(frame_idx);
            self.endTableWrite();

            self.mutex.unlock(io);

            var read_err: ?anyerror = null;
            pager.readPage(page_id, frame.dataSlice()) catch |err| switch (err) {
                error.PageNotFound => @memset(frame.dataSlice(), 0),
                else => read_err = err,
            };

            self.mutex.lockUncancelable(io);
            if (read_err) |err| {
                self.beginTableWrite();
                // Drop OUR pin only (see the publication above).
                _ = @atomicRmw(u32, &frame.pin_count, .Sub, 1, .acq_rel);
                frame.dirty = false;
                frame.loading = false;
                frame.evicting = false;
                frame.valid = false;
                frame.lsn = 0;
                self.removeFromLru(frame_idx);
                _ = self.page_table.remove(key);
                self.decrResident(file_id);
                self.free_list.appendAssumeCapacity(frame_idx);
                self.endTableWrite();
                self.wakeFrameWaiters();
                self.mutex.unlock(io);
                return err;
            }

            // Publish the load completion inside a gen bracket so a fast-path pin
            // observes the loading->resident transition as one atomic step rather
            // than racing it.
            self.beginTableWrite();
            frame.loading = false;
            frame.valid = true;
            self.endTableWrite();
            if (self.metrics) |m| m.page_reads += 1;
            self.wakeFrameWaiters();
            self.mutex.unlock(io);
            return frame;
        }
    }

    /// PERF-0058 fast path, speculative half: look `key` up in the page table
    /// and pre-check the frame's identity WITHOUT the mutex. Plain reads racing
    /// structural writers (see `tsan`); the result is only a CANDIDATE that
    /// `pin` revalidates after pinning it. The `frame_idx` returned by a `get`
    /// that raced a writer can be a TORN value (e.g. 0xAAAAAAAA), so it is not
    /// used to index `frames` until the seqlock re-check has confirmed no
    /// writer overlapped — and is bounds-checked even then.
    fn speculativeLookup(self: *BufferPool, key: PageKey, g0: u64) ?*PageFrame {
        const hit = self.page_table.get(key);
        if (seqlockReadFence(&self.table_gen) != g0) return null;
        const frame_idx = hit orelse return null;
        if (frame_idx >= self.capacity) return null;
        const frame = &self.frames[frame_idx];
        if (frame.file_id != key.file_id or frame.page_id != key.page_id or
            !frame.valid or frame.loading or frame.evicting) return null;
        return frame;
    }

    /// Pin a new page without reading from disk. Used when creating a new page.
    /// Zeros the data buffer and inserts into cache.
    ///
    /// Structural (allocates/repurposes a frame), so it runs under the `mutex`
    /// and brackets the page-table/identity mutation with begin/endTableWrite
    /// (PERF-0058) so the lock-free fast path defers while it is in flight.
    pub fn pinNew(self: *BufferPool, file_id: FileId, page_id: PageId) !*PageFrame {
        const io = bpio();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const key = PageKey{ .file_id = file_id, .page_id = page_id };

        // Looped so the post-getFrame re-probe (below) can restart the cache-hit
        // check when a concurrent loader inserted `key` while getFrame had the
        // mutex dropped for a dirty-victim flush.
        while (true) {
            // If already in cache, just pin it. As in `pin`, a frame still loading
            // or being torn down by a concurrent eviction is unsafe to alias: wait
            // for the transition and re-check rather than handing back a frame that
            // is about to be (or has just been) repurposed for a different page.
            while (self.page_table.get(key)) |frame_idx| {
                const frame = &self.frames[frame_idx];
                if (frame.loading or frame.evicting) {
                    // FIX #2: bounded, lost-wakeup-free wait (see `pin`).
                    const gen = self.wait_gen.load(.acquire);
                    _ = self.pin_waiters.fetchAdd(1, .acq_rel);
                    self.waitFrameChange(io, gen);
                    _ = self.pin_waiters.fetchSub(1, .acq_rel);
                    continue;
                }
                // Hit: bump atomically (consistent with the fast path); no gen
                // bracket needed since the page table is unchanged.
                _ = @atomicRmw(u32, &frame.pin_count, .Add, 1, .acq_rel);
                @atomicStore(u8, &frame.referenced, 1, .monotonic);
                return frame;
            }

            // getFrame may evict a dirty victim (flushing with the mutex/gen
            // released), so it runs OUTSIDE the gen bracket — exactly as in the
            // `pin` slow path — and evictFrame opens its own fine-grained
            // brackets. The returned frame is not in the page table, so no
            // fast-path reader can reach it until the bracketed put below.
            const frame_idx = try self.getFrame();

            // CORRECTNESS (double-load window): getFrame may have DROPPED the
            // mutex to flush a dirty victim; during that window a concurrent
            // loader could have inserted `key`. Re-probe before publishing so we
            // never overwrite (leak) another thread's frame or double-count
            // resident_counts. If present now, return our frame to the free list
            // and restart — the inner loop will pin the existing entry. Same
            // latent v0.2.6 race as in `pin`, fixed here too.
            if (self.page_table.get(key) != null) {
                self.free_list.appendAssumeCapacity(frame_idx);
                continue;
            }

            const frame = &self.frames[frame_idx];

            // Zero the data (new page)
            @memset(frame.dataSlice(), 0);

            self.beginTableWrite();
            frame.file_id = file_id;
            frame.page_id = page_id;
            // Atomic +1, as in `pin`'s load publication.
            _ = @atomicRmw(u32, &frame.pin_count, .Add, 1, .acq_rel);
            frame.referenced = 1;
            frame.dirty = false;
            frame.loading = false;
            frame.evicting = false;
            frame.valid = true;
            frame.lsn = 0;

            self.page_table.putAssumeCapacity(key, frame_idx);
            self.incrResident(file_id);
            self.moveToHead(frame_idx);
            self.endTableWrite();

            return frame;
        }
    }

    /// Unpin a frame: decrement pin_count and optionally mark dirty.
    ///
    /// PERF-0058: fully LOCK-FREE in the common case — a single atomic decrement
    /// of `pin_count` and (if dirtying) a monotonic false->true store of `dirty`.
    /// It touches only the frame's own cachelines, so unpins scale with cores
    /// alongside cache-hit pins. `dirty` is only ever CLEARED by a flush/eviction
    /// holding the `mutex` (and the v0.2.6 eviction re-reads it under the mutex),
    /// and an unpin only ever SETS it, so the relaxed atomic store cannot lose a
    /// dirty mark. Only when a waiter actually exists do we wake it — and that
    /// wake takes the mutex (exactly as the v0.2.6/v0.2.7 wake did), which is what
    /// serialises it against the loader/eviction's mutex-held frame mutations.
    pub fn unpin(self: *BufferPool, frame_idx: u32, dirty: bool) void {
        const io = bpio();
        const frame = &self.frames[frame_idx];

        if (dirty) {
            @atomicStore(bool, &frame.dirty, true, .monotonic);
        }
        const prev = @atomicRmw(u32, &frame.pin_count, .Sub, 1, .acq_rel);
        // prev must be a real pin count (1..): never 0 (underflow) and never the
        // eviction sentinel (a pinned frame cannot be claimed by eviction). Note
        // pin_count can legitimately reach the number of concurrent pinners of a
        // hot page, so there is NO small upper bound to assert.
        std.debug.assert(prev > 0 and prev != PIN_EVICTING);

        // Wake a parked slow-path waiter ONLY when one actually exists. A waiter
        // parks while a frame is loading/evicting and (if pool-full) re-attempts
        // eviction on wake; an unpin freeing a frame may be exactly what lets it
        // make progress, so we must wake it. In the common case there are NO
        // waiters (`pin_waiters == 0`) and unpin stays FULLY LOCK-FREE — never
        // touching the mutex — which is what makes pin/unpin scale (PERF-0058,
        // v0.2.7).
        //
        // FIX #2: when a waiter exists we take the mutex and wake under it. The
        // mutex is ESSENTIAL here, not just for the wake: it serialises this wake
        // path against the slow-path loader/eviction, which mutate a published
        // frame's `pin_count`/identity with PLAIN (non-atomic) stores WHILE
        // HOLDING THE MUTEX (e.g. the loader's `frame.pin_count = 1` publish).
        // The v0.2.7 lock-free unpin was safe only because those plain stores
        // happen on a frame NOT yet pin-reachable; but a *waiting* unpin can race
        // a concurrent repurpose of the same slot. Taking the mutex restores the
        // v0.2.6 invariant that every pin_count mutation on a table-reachable
        // frame is either atomic or mutex-serialised — closing a use-after-evict
        // data race. The `pin_waiters` acquire load pairs with the waiter's
        // release increment (published under the mutex before the wait); the
        // double-check under the mutex avoids a spurious wake. The wake itself is
        // `wakeFrameWaiters` (wait_gen bump + futexWake), replacing the removed
        // `Io.Condition`. (We wake on ANY unpin while waiters exist, not only the
        // zero transition: a spurious wake is harmless — the waiter re-checks.)
        if (self.pin_waiters.load(.acquire) != 0) {
            self.mutex.lockUncancelable(io);
            if (self.pin_waiters.load(.acquire) != 0) self.wakeFrameWaiters();
            self.mutex.unlock(io);
        }
    }

    /// Flush all dirty frames with LSN <= up_to_lsn to disk.
    /// SONNY-6632: also waits for the writes other flushes have in flight,
    /// before the pass (their frames are clean but not on disk) and after it
    /// (a frame another flush took while this one dropped the mutex).
    pub fn flushDirty(self: *BufferPool, up_to_lsn: Lsn) !void {
        const io = bpio();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.waitAllWrites(io);
        for (self.frames, 0..) |*frame, i| {
            _ = i;
            if (frame.dirty and frame.valid and frame.lsn <= up_to_lsn) {
                try self.flushFrame(frame);
            }
        }
        self.waitAllWrites(io);
    }

    /// Flush all dirty frames to disk regardless of LSN.
    /// When a ThreadPool is attached, dirty pages are written in parallel
    /// using submitBatch + WaitGroup. Otherwise falls back to sequential I/O.
    pub fn flushAll(self: *BufferPool) !void {
        if (self.thread_pool) |pool| {
            return self.flushAllParallel(pool);
        }
        const io = bpio();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        // SONNY-6632: as `flushDirty`.
        self.waitAllWrites(io);
        for (self.frames) |*frame| {
            if (frame.dirty and frame.valid) {
                try self.flushFrame(frame);
            }
        }
        self.waitAllWrites(io);
    }

    /// Parallel flush: collect dirty frames under mutex, copy data, then
    /// write pages concurrently via submitBatch + WaitGroup.
    ///
    /// PERF-0056: the per-page copy buffer is a bounded, reusable scratch buffer
    /// (`flush_scratch`, capped at PARALLEL_FLUSH_SCRATCH_PAGES pages) rather
    /// than a fresh `dirty_count * page_size` allocation per checkpoint. When the
    /// dirty set exceeds the scratch capacity the flush proceeds in successive
    /// capacity-sized waves, so peak transient memory stays bounded no matter how
    /// many pages are dirty.
    fn flushAllParallel(self: *BufferPool, pool: *tp.ThreadPool) !void {
        const io = bpio();
        // Runs under `mutex`, dropped only during each wave's parallel-I/O window
        // (as in v0.2.6). PERF-0058: the lock-free fast path is NOT excluded
        // during that window — but this path never changes a frame's identity or
        // the page table, only writes page bytes and toggles pin_count/dirty, so a
        // concurrent fast-path pin of a frame being flushed is safe. Because the
        // window drops the mutex while frames are pin-bumped, every pin_count/
        // dirty mutation here is atomic (a concurrent fast-path unpin may race).
        self.mutex.lockUncancelable(io);
        // SONNY-6632: the writes other flushes have in flight land first:
        // their frames are clean but their new images are not on disk (this
        // flush would return before them), and a frame dirtied again during
        // one would be copied and could be written before it (the older copy
        // landing last). The selection below then runs under one hold of the
        // mutex, so no other flush starts a write in between.
        self.waitAllWrites(io);

        // Count dirty frames
        var dirty_count: usize = 0;
        for (self.frames) |*frame| {
            if (frame.dirty and frame.valid) dirty_count += 1;
        }

        if (dirty_count == 0) {
            self.mutex.unlock(io);
            return;
        }

        const ps: usize = self.page_size;

        // Descriptor array for every dirty frame (tiny, ~constant per frame).
        // The large page-copy storage is the bounded scratch buffer below.
        const items = self.allocator.alloc(FlushItem, dirty_count) catch {
            self.mutex.unlock(io);
            return error.OutOfMemory;
        };

        // Bounded reusable scratch buffer: holds at most wave_pages page copies.
        const wave_pages: usize = @min(dirty_count, @max(self.max_scratch_pages, 1));
        self.ensureFlushScratch(wave_pages * ps) catch {
            self.allocator.free(items);
            self.mutex.unlock(io);
            return error.OutOfMemory;
        };
        const data_buf = self.flush_scratch;

        // Collect descriptors for every dirty frame: pin (prevent eviction
        // across the whole flush) and clear dirty. No page bytes are copied yet;
        // copies happen per wave into the bounded scratch buffer.
        var idx: usize = 0;
        for (self.frames, 0..) |*frame, fi| {
            if (frame.dirty and frame.valid) {
                const fid = frame.file_id;
                const p = self.pagers[@intFromEnum(fid)] orelse {
                    // Undo previously pinned frames and bail
                    for (items[0..idx]) |item| {
                        _ = @atomicRmw(u32, &self.frames[item.frame_idx].pin_count, .Sub, 1, .acq_rel);
                        self.endFrameWrite(&self.frames[item.frame_idx]);
                        @atomicStore(bool, &self.frames[item.frame_idx].dirty, true, .monotonic);
                    }
                    self.allocator.free(items);
                    self.mutex.unlock(io);
                    return error.NoPagerRegistered;
                };

                _ = @atomicRmw(u32, &frame.pin_count, .Add, 1, .acq_rel);
                @atomicStore(bool, &frame.dirty, false, .monotonic);
                // SONNY-6605: clean from here, but the disk keeps the older
                // image until this frame's wave has written it
                // (`newerThanDisk`); cleared below when the write is done.
                self.beginFrameWrite(frame);

                items[idx] = .{
                    .pager = p,
                    .page_id = frame.page_id,
                    .frame_idx = @intCast(fi),
                    .data_offset = 0, // assigned per wave
                    .err = null,
                };
                idx += 1;
            }
        }

        const MAX_CHUNKS = 64;
        var flush_ctxs: [MAX_CHUNKS]FlushChunkCtx = undefined;
        var batch_tasks: [MAX_CHUNKS]tp.BatchTask = undefined;
        var first_err: ?anyerror = null;
        var write_count: u64 = 0;

        // Process the dirty set in bounded waves of at most wave_pages frames.
        var wave_start: usize = 0;
        while (wave_start < dirty_count) {
            const wave_end = @min(wave_start + wave_pages, dirty_count);
            const wave = items[wave_start..wave_end];
            const wave_len = wave.len;

            // Copy this wave's page bytes into the scratch buffer (locks held).
            for (wave, 0..) |*item, w| {
                const offset = w * ps;
                item.data_offset = offset;
                @memcpy(data_buf[offset..][0..ps], self.frames[item.frame_idx].dataSlice());
            }
            // Drop the mutex for the parallel I/O window so cache-hit pins keep
            // flowing during the writes (the pinned frames stay protected by the
            // atomic pin bump above; their identity/page-table entry is untouched).
            self.mutex.unlock(io);

            // Parallel I/O via submitBatch + WaitGroup for this wave.
            const n_chunks = @min(wave_len, MAX_CHUNKS);
            var wg = pool.waitGroup();
            const chunk_size = (wave_len + n_chunks - 1) / n_chunks;
            var n_chunks_actual: usize = 0;
            {
                var item_i: usize = 0;
                while (item_i < wave_len) : (n_chunks_actual += 1) {
                    const end = @min(item_i + chunk_size, wave_len);
                    flush_ctxs[n_chunks_actual] = .{
                        .items = wave[item_i..end],
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

            // Re-acquire the mutex to unpin this wave's frames and reconcile
            // errors.
            self.mutex.lockUncancelable(io);
            for (wave) |*item| {
                _ = @atomicRmw(u32, &self.frames[item.frame_idx].pin_count, .Sub, 1, .acq_rel);
                self.endFrameWrite(&self.frames[item.frame_idx]);
                if (item.err) |e| {
                    @atomicStore(bool, &self.frames[item.frame_idx].dirty, true, .monotonic);
                    if (first_err == null) first_err = e;
                } else {
                    // PERF-0057: the page reached the OS page cache; flag its file
                    // for fsync so the next checkpoint syncs it (never skips it).
                    self.markFileDirty(self.frames[item.frame_idx].file_id);
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

            wave_start = wave_end;
            // Keep the mutex held for the next wave's copy phase; the final wave
            // unlocks below.
        }

        if (self.metrics) |m| m.page_writes += write_count;
        self.mutex.unlock(io);

        self.allocator.free(items);

        if (first_err) |e| return e;
    }

    /// PERF-0056: ensure `flush_scratch` is at least `min_bytes` long, growing
    /// (never shrinking) the reusable buffer. Caller holds the mutex.
    fn ensureFlushScratch(self: *BufferPool, min_bytes: usize) !void {
        if (self.flush_scratch.len >= min_bytes) return;
        if (self.flush_scratch.len != 0) self.allocator.free(self.flush_scratch);
        self.flush_scratch = &.{};
        self.flush_scratch = try self.allocator.alloc(u8, min_bytes);
    }

    /// Flush up to max_count dirty unpinned pages to disk, starting from the LRU tail.
    /// Returns the number of pages actually flushed. This is intended to be called
    /// proactively (e.g. during maintenance) to reduce eviction stalls.
    pub fn flushDirtyPages(self: *BufferPool, max_count: u32) !u32 {
        const io = bpio();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var flushed: u32 = 0;
        var current = self.lru_tail;
        while (current) |idx| {
            if (flushed >= max_count) break;
            const frame = &self.frames[idx];
            // Walk via lru_prev before we potentially modify the frame
            const prev = frame.lru_prev;
            if (frame.dirty and frame.valid and @atomicLoad(u32, &frame.pin_count, .acquire) == 0) {
                try self.flushFrame(frame);
                flushed += 1;
            }
            current = prev;
        }
        return flushed;
    }

    /// SONNY-6605: whether the bytes on disk of a page the pool holds may be
    /// older than the pool's copy, so a reader that reads pages straight from
    /// the pager (bypassing the pool) must read this one through the pool.
    /// True while the frame is dirty and while a flush's write of it is in
    /// flight: a flush clears `dirty` when it copies the frame, before its
    /// write reaches the file. False for a page the pool does not hold.
    pub fn pageNewerThanDisk(self: *BufferPool, file_id: FileId, page_id: PageId) bool {
        const io = bpio();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const idx = self.page_table.get(.{ .file_id = file_id, .page_id = page_id }) orelse return false;
        return self.frames[idx].newerThanDisk();
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

    /// Flush a single dirty frame to disk via its pager — for callers that do NOT
    /// already hold an exclusive claim on the frame (the bulk flush paths). It
    /// temporarily bumps `pin_count` (atomically) so the frame cannot be evicted
    /// across the mutex-dropping I/O window, then restores it.
    ///
    /// CONTRACT: called WITH `mutex` held; the blocking disk write DROPS the mutex
    /// (the v0.2.6 reason — never serialise I/O behind the pool lock) and
    /// re-acquires it before returning. It does NOT touch the page table or the
    /// frame's identity, so the PERF-0058 lock-free fast path may pin this frame
    /// during the write — safe (the page stays resident; only its bytes are
    /// written). The pin bump is atomic because a concurrent fast-path unpin of a
    /// still-pinned frame can run while the mutex is dropped.
    fn flushFrame(self: *BufferPool, frame: *PageFrame) !void {
        // Prevent eviction during I/O: eviction claims via CAS(0 -> sentinel),
        // which fails while pin_count is bumped. Atomic because the mutex is
        // dropped during the write.
        _ = @atomicRmw(u32, &frame.pin_count, .Add, 1, .acq_rel);
        self.writeFrameBytes(frame) catch |err| {
            _ = @atomicRmw(u32, &frame.pin_count, .Sub, 1, .acq_rel);
            return err;
        };
        _ = @atomicRmw(u32, &frame.pin_count, .Sub, 1, .acq_rel);
    }

    /// Flush a single dirty frame to disk for an EVICTION that already holds the
    /// frame's exclusive claim (`pin_count == PIN_EVICTING`). It must NOT touch
    /// `pin_count` — the sentinel is the protection; bumping it would overflow.
    /// Same mutex-drop-across-I/O contract as `flushFrame`.
    fn flushFrameClaimed(self: *BufferPool, frame: *PageFrame) !void {
        std.debug.assert(@atomicLoad(u32, &frame.pin_count, .acquire) == PIN_EVICTING);
        try self.writeFrameBytes(frame);
    }

    /// Shared body of the flush paths: copy the frame's bytes under the mutex,
    /// DROP the mutex for the blocking write, re-acquire, and (on success) flag
    /// the file for fsync + propagate the encryption write_count. Caller manages
    /// any pin_count/claim protection. Caller holds `mutex` on entry and exit.
    fn writeFrameBytes(self: *BufferPool, frame: *PageFrame) !void {
        const io = bpio();
        const fid = frame.file_id;
        const pid = frame.page_id;
        const p = self.pagers[@intFromEnum(fid)] orelse return error.NoPagerRegistered;

        // SONNY-6632: one write of a frame at a time, in copy order. The
        // caller found the frame dirty; another flush may have written it
        // while this one waited.
        self.waitFrameWrites(io, frame);
        if (!@atomicLoad(bool, &frame.dirty, .acquire)) return;

        @atomicStore(bool, &frame.dirty, false, .monotonic);
        // SONNY-6605: clean from here, but the disk keeps the older image
        // until the write below lands (`newerThanDisk`).
        self.beginFrameWrite(frame);

        var buf: [16384]u8 = undefined;
        std.debug.assert(self.page_size <= buf.len);
        @memcpy(buf[0..self.page_size], frame.dataSlice());

        self.mutex.unlock(io);
        p.writePage(pid, buf[0..self.page_size]) catch |err| {
            self.mutex.lockUncancelable(io);
            self.endFrameWrite(frame);
            // Restore dirty state if write failed so we can retry later.
            @atomicStore(bool, &frame.dirty, true, .monotonic);
            return err;
        };
        self.mutex.lockUncancelable(io);
        self.endFrameWrite(frame);

        // PERF-0057: the write reached the OS page cache; this file now needs an
        // fsync before its data is durable. Flag it so the next checkpoint syncs
        // exactly this file (and never skips it).
        self.markFileDirty(fid);

        // SEC-0037: writePage incremented write_count in its private copy `buf`,
        // not in the live cached frame. Propagate the persisted write_count back
        // into the live frame so the next flush of this still-cached page derives
        // a strictly greater AES-GCM nonce (nonce reuse otherwise). Only relevant
        // when encryption is active; harmless but unnecessary in plaintext mode.
        if (p.encryption != null) {
            page_mod.writeWriteCount(frame.dataSlice(), page_mod.readWriteCount(buf[0..self.page_size]));
        }

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

    /// Evict an unpinned frame, choosing the victim by an approximate-LRU
    /// CLOCK / second-chance rule. Caller holds `mutex` (NOT a gen bracket —
    /// evictFrame opens its own fine-grained brackets so the dirty flush runs
    /// with gen even).
    ///
    /// PERF-0058: the cache-HIT pin path no longer moves frames to the LRU head
    /// (that pool-wide list write is exactly what serialised readers). Instead a
    /// hit sets the frame's `referenced` clock bit. Eviction walks the LRU list
    /// from the tail and gives any frame whose bit is set a SECOND CHANCE: it
    /// clears the bit and the CLOCK hand ADVANCES toward the head, leaving the
    /// frame exactly where it is. A frame with a clear bit (not touched since the
    /// last sweep) is the victim. This keeps genuinely-hot pages resident without
    /// any per-hit OR per-eviction list mutation.
    ///
    /// PERF (CLOCK hand-advance): the prior code cleared the bit AND moved the
    /// frame to the head AND restarted the whole tail sweep on every second
    /// chance. On a full pool during a scan ~every frame is referenced, so that
    /// was O(N) list writes + O(N) restarts to find ONE victim — O(K*N) for K
    /// victims, the 62%-self-time cold-open hotspot. The textbook CLOCK fix: clear
    /// the bit and advance the hand via the already-captured `prev` (no list
    /// write, no restart). One sweep clears every set bit; the outer loop then
    /// re-sweeps and finds the now-clear tail as the victim. Work is O(N) per
    /// FULLY-HOT sweep but amortizes to O(1) per victim once bits are cleared.
    ///
    /// PERF-0051: the reservation floor is still honoured in pass 1 (don't drop a
    /// reserved class below its floor) with a pass-2 fallback so the floor can
    /// never deadlock or spuriously raise BufferPoolFull.
    ///
    /// CONCURRENCY — why advancing via the captured `prev` is sound: the caller
    /// holds `mutex` for the whole call, and the LRU list is mutated ONLY under
    /// `mutex` (the lock-free pin/unpin fast path touches only its own frame's
    /// pin_count/referenced, never the list — PERF-0058). Within a sweep the loop
    /// itself performs NO list mutation. `evictFrame` is the only callee that can
    /// drop the mutex, and it does so ONLY on the SUCCESS/dirty-flush path, which
    /// returns true → we `return idx` immediately and never reuse `prev`. On ABORT
    /// (claim CAS 0→PIN_EVICTING failed because the frame was pinned) it returns
    /// false WITHOUT dropping the mutex and WITHOUT touching the list, so the
    /// captured `prev` is still a valid, current `lru_prev` — we advance to it.
    /// An aborted/pinned frame has pin_count != 0, so `isEvictable` skips it on a
    /// re-sweep. Each outer iteration makes progress (clears ≥1 bit, or aborts a
    /// transiently-pinned frame, or evicts); a sweep that does NONE of these means
    /// no frame is evictable → error.BufferPoolFull. So this cannot livelock while
    /// any genuinely-evictable (unpinned, clear-bit) frame exists.
    fn evict(self: *BufferPool) !u32 {
        // Mark the eviction victim-selection context so any `moveToHead` reached
        // from this call (there should be NONE — the CLOCK hand-advance never
        // moves frames) self-increments `evict_list_moves`, arming the regression
        // guard against a reintroduced in-sweep list move. Set/cleared only under
        // the caller's `mutex`; cleared on every exit path via `defer`.
        self.in_evict = true;
        defer self.in_evict = false;
        while (true) {
            // Pass 1: honour reservation floors; second-chance via clock bit.
            // Sweep tail → head, advancing the clock hand without moving frames.
            var current = self.lru_tail;
            var saw_reserved_evictable = false;
            var made_progress = false; // cleared a bit or aborted a pinned victim
            while (current) |idx| {
                const frame = &self.frames[idx];
                const prev = frame.lru_prev;
                if (frame.isEvictable()) {
                    if (self.wouldUnderflowReserve(frame.file_id)) {
                        saw_reserved_evictable = true;
                    } else if (@atomicLoad(u8, &frame.referenced, .acquire) != 0) {
                        // Second chance: clear the bit and ADVANCE the hand. No
                        // list write, no restart — the cleared bit makes this
                        // frame a victim on the next sweep.
                        @atomicStore(u8, &frame.referenced, 0, .monotonic);
                        made_progress = true;
                        current = prev;
                        continue;
                    } else {
                        if (try self.evictFrame(idx)) return idx;
                        // ABORT: victim got pinned (no mutex drop, list intact);
                        // advance the hand and keep sweeping. Force a re-sweep so a
                        // frame unpinned in the meantime gets retried.
                        made_progress = true;
                        current = prev;
                        continue;
                    }
                }
                current = prev;
            }

            // The sweep cleared bits and/or aborted transient pins but evicted
            // nothing: re-sweep (now-clear bits become victims). Pass 1 takes
            // priority over the reserved-class fallback.
            if (made_progress) continue;

            // Pass 2: only reserved-class frames remain evictable. Evicting one is
            // required to make progress, so allow it (still respect the clock bit
            // for second-chance ordering among them). Same hand-advance discipline.
            if (saw_reserved_evictable) {
                current = self.lru_tail;
                var made_progress2 = false;
                while (current) |idx| {
                    const frame = &self.frames[idx];
                    const prev = frame.lru_prev;
                    if (frame.isEvictable()) {
                        if (@atomicLoad(u8, &frame.referenced, .acquire) != 0) {
                            @atomicStore(u8, &frame.referenced, 0, .monotonic);
                            made_progress2 = true;
                            current = prev;
                            continue;
                        }
                        if (try self.evictFrame(idx)) return idx;
                        made_progress2 = true;
                        current = prev;
                        continue;
                    }
                    current = prev;
                }
                // Re-sweep from pass 1 (an unpin/clear may now expose a non-reserved
                // victim, matching the prior `continue :restart` semantics).
                if (made_progress2) continue;
            }

            return error.BufferPoolFull;
        }
    }

    /// Flush (if dirty), drop from the page table / LRU list, and reset a frame
    /// so it can be reused. Caller holds the mutex. Keeps `resident_counts` in
    /// lockstep with the page table.
    ///
    /// Returns `true` when the frame was evicted (the index is now free for the
    /// caller to repurpose) and `false` when the eviction was ABORTED because the
    /// victim could not be CLAIMED (it is pinned) — the caller picks a different
    /// victim.
    ///
    /// CONCURRENCY (PERF-0058 + the v0.2.6 dirty-eviction fix):
    ///
    ///  1. CLAIM the frame atomically: CAS `pin_count` 0 -> PIN_EVICTING. This is
    ///     the single point that excludes the lock-free fast path: a pin is a CAS
    ///     on the same word, so either our claim wins (and every subsequent pin
    ///     CAS fails against the sentinel) or a pin already holds the frame (our
    ///     CAS fails -> abort). No Dekker fence needed — same-word CAS is totally
    ///     ordered. If the claim fails, the frame is pinned: abort.
    ///
    ///  2. Once claimed, the frame is OURS exclusively; pin_count stays at the
    ///     sentinel across the (possibly mutex-dropping) dirty flush, so unlike
    ///     v0.2.6 no pin can alias it and no post-flush pin_count re-check is
    ///     needed. We still set `evicting` (bracketed) so the fast path's cheap
    ///     pre-CAS identity check also defers, and so a concurrent eviction's
    ///     `isEvictable` skips it. The flush drops the mutex with gen EVEN so
    ///     reads of OTHER pages keep flowing.
    ///
    ///  3. On flush error, RELEASE the claim (pin_count sentinel -> 0), restore
    ///     dirty, clear `evicting`, broadcast, and return the error.
    ///
    ///  4. On success, TEARDOWN under a gen bracket (remove from table, reset the
    ///     frame including pin_count -> 0) and broadcast parked pinners.
    fn evictFrame(self: *BufferPool, idx: u32) !bool {
        const frame = &self.frames[idx];

        // (1) Atomically claim the frame. Fails if it is pinned (incl. by a
        // lock-free fast-path pin that just won the CAS race) -> abort.
        if (@cmpxchgStrong(u32, &frame.pin_count, 0, PIN_EVICTING, .acq_rel, .acquire) != null) {
            return false;
        }

        // From here the frame is exclusively ours (pin_count == PIN_EVICTING).
        if (frame.dirty) {
            // (2) Publish `evicting` to the fast path's pre-CAS check. Bracketed
            // so the flag is observed coherently; gen returns to even so the
            // flush does not stall reads of other pages.
            self.beginTableWrite();
            frame.evicting = true;
            self.endTableWrite();

            self.flushFrameClaimed(frame) catch |err| {
                // (3) Flush failed: release the claim and restore the frame so it
                // stays resident and pinnable; wake any parked pinners.
                self.beginTableWrite();
                frame.evicting = false;
                @atomicStore(bool, &frame.dirty, true, .monotonic);
                @atomicStore(u32, &frame.pin_count, 0, .release);
                self.endTableWrite();
                self.wakeFrameWaiters();
                return err;
            };
        }

        // (4) Teardown under a gen bracket so the lock-free fast path never
        // observes a half-removed frame. No pin_count re-check is needed: the
        // sentinel has held the frame exclusively since the claim.
        self.beginTableWrite();
        const key = PageKey{ .file_id = frame.file_id, .page_id = frame.page_id };
        _ = self.page_table.remove(key);
        self.decrResident(frame.file_id);
        self.removeFromLru(idx);
        frame.valid = false;
        // Release the claim; the frame is now free. Atomic: from here a stale
        // fast-path reader can CAS-pin it (and will undo that).
        @atomicStore(u32, &frame.pin_count, 0, .release);
        frame.referenced = 0;
        frame.dirty = false;
        frame.writes_in_flight = 0;
        frame.loading = false;
        frame.evicting = false;
        frame.lsn = 0;
        self.endTableWrite();

        // Wake any pinner that parked while this frame was `evicting`: the page
        // is gone from the table now, so it will miss and re-load it fresh.
        self.wakeFrameWaiters();
        return true;
    }

    /// Move a frame to the head of the LRU list (most recently used).
    fn moveToHead(self: *BufferPool, idx: u32) void {
        // Regression guard: a `moveToHead` reached from the eviction
        // victim-selection loop (`in_evict`) is exactly the O(N)-restart hotspot
        // the CLOCK hand-advance removed. Count it so the CLOCK-eviction test's
        // `evict_list_moves == 0` assertion fails if such a call is reintroduced.
        // Ordinary pin/pinNew moves run with `in_evict` clear and are not counted.
        if (self.in_evict) self.evict_list_moves += 1;

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

test "PERF: large-capacity pool uses lazy anon-mmap backing — no eager zero, fresh frames read as zero" {
    // A large pool: 65536 * 4096 = 256 MiB of frame backing. The old code did an
    // eager `@memset(page_buf, 0)` here, touching all 256 MiB (a
    // capacity-proportional ~0.5-1s cost at scale, GBs across 16 shards). The
    // anonymous-mmap backing zero-fills LAZILY on first fault, so init no longer
    // pays that cost. We can't assert wall-time without flakiness, but we CAN
    // assert the correctness invariant the memset used to provide: a freshly
    // mapped frame reads as zero — and that this holds across the whole mapping.
    const capacity: u32 = 65536;
    var pool = try BufferPool.init(testing.allocator, 4096, capacity);
    defer pool.deinit();

    try testing.expectEqual(capacity, pool.capacity);
    try testing.expectEqual(@as(usize, capacity) * 4096, pool.page_buf.len);

    // Sample frame backing across the whole mapping (first, middle, last) and
    // confirm the kernel zero-filled it — these reads go straight to the
    // mmap-backed bytes (no pinNew, which would itself memset the frame).
    const samples = [_]u32{ 0, capacity / 2, capacity - 1 };
    for (samples) |i| {
        const slice = pool.frames[i].dataSlice();
        try testing.expectEqual(@as(usize, 4096), slice.len);
        for (slice) |byte| try testing.expectEqual(@as(u8, 0), byte);
    }

    // And pinNew still returns a zeroed, valid, pinned fresh frame.
    const frame = try pool.pinNew(.nodes, 0);
    for (frame.dataSlice()) |byte| try testing.expectEqual(@as(u8, 0), byte);
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

test "PERF: CLOCK eviction is O(1)-amortized (no per-victim LRU churn under a hot scan)" {
    // Reproduces the 62%-self-time hotspot: on a FULL pool during a large scan,
    // ~every frame's `referenced` bit is set when a miss forces eviction. The
    // pre-CLOCK code gave each referenced frame a "second chance" by clearing the
    // bit AND moving it to the LRU head, then RESTARTING the whole tail sweep —
    // O(N) list writes + restarts per single victim, O(K*N) for K victims. The
    // textbook CLOCK hand-advance clears the bit and advances the hand WITHOUT any
    // list mutation, so victim selection does ZERO `moveToHead` calls.
    //
    // We simulate the worst case: before EVERY eviction we re-set all resident
    // `referenced` bits (the ongoing scan touched the whole working set since the
    // last sweep). With K == N evictions, the old code performed ~K*N list moves;
    // the CLOCK loop performs EXACTLY ZERO. `evict_list_moves` is incremented by
    // `moveToHead` ONLY while the eviction victim-selection loop is active
    // (`in_evict`), so it measures precisely the in-sweep list moves the CLOCK
    // fix eliminated. We assert it is 0: if anyone reintroduces an in-sweep
    // `moveToHead` (the O(K*N) restart regression), this counter goes non-zero
    // and the test fails. (The `<= 2*N` bound this replaced was vacuous — the
    // counter was never incremented, so 0 <= 2*N always held.)
    const file = try createTempFile(".test_bp_clock_evict");
    defer cleanupTempFile(file, ".test_bp_clock_evict");

    const page_size: u32 = 4096;
    var p = Pager.init(file, page_size);

    const N: u32 = 64;
    var pool = try BufferPool.init(testing.allocator, page_size, N);
    defer pool.deinit();
    pool.registerPager(.nodes, &p);

    // Fill the pool to capacity with N clean, unpinned, resident pages.
    var pid: PageId = 0;
    while (pid < N) : (pid += 1) {
        const f = try pool.pinNew(.nodes, pid);
        pool.unpin(pool.frameIndex(f), false);
    }
    try testing.expectEqual(@as(usize, 0), pool.free_list.items.len); // pool is full

    pool.evict_list_moves = 0;
    const K: u32 = N; // evict a full pool's worth of victims
    var evicted: u32 = 0;
    var next_pid: PageId = N;
    var i: u32 = 0;
    while (i < K) : (i += 1) {
        // Simulate the scan: every resident frame was referenced since the last
        // sweep -> set all clock bits. This is the pathological eviction input.
        for (pool.frames) |*fr| {
            if (fr.valid) @atomicStore(u8, &fr.referenced, 1, .monotonic);
        }

        // Must always find a victim (pool full of unpinned frames); a CLOCK bug
        // that fails to re-sweep after clearing bits would surface as BufferPoolFull.
        const victim = try pool.evict();
        evicted += 1;

        // Re-fill the freed frame with a fresh page so the pool stays full and the
        // next eviction must run the full second-chance machinery again. (pinNew's
        // own moveToHead is NOT counted — only the eviction loop increments the
        // counter.)
        pool.free_list.appendAssumeCapacity(victim);
        const nf = try pool.pinNew(.nodes, next_pid);
        next_pid += 1;
        pool.unpin(pool.frameIndex(nf), false);
    }

    try testing.expectEqual(K, evicted); // every eviction succeeded
    try testing.expectEqual(@as(usize, 0), pool.free_list.items.len); // still full + consistent

    // The whole point: victim selection must perform NO LRU-list moves. Old
    // code: ~K*N == 4096 in-sweep moves. CLOCK hand-advance: exactly 0. Any
    // non-zero value means an in-sweep `moveToHead` was reintroduced.
    try testing.expectEqual(@as(usize, 0), pool.evict_list_moves);
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
            p.wakeFrameWaiters();
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

test "PERF-0057: flushAll flags only the files that had pages written" {
    const node_file = try createTempFile(".test_bp_perf0057_nodes");
    defer cleanupTempFile(node_file, ".test_bp_perf0057_nodes");
    const prop_file = try createTempFile(".test_bp_perf0057_props");
    defer cleanupTempFile(prop_file, ".test_bp_perf0057_props");

    const page_size: u32 = 4096;
    var node_pager = Pager.init(node_file, page_size);
    var prop_pager = Pager.init(prop_file, page_size);

    var pool = try BufferPool.init(testing.allocator, page_size, 8);
    defer pool.deinit();
    pool.registerPager(.nodes, &node_pager);
    pool.registerPager(.props, &prop_pager);

    // No flush yet -> nothing dirty.
    const initial = pool.takeDirtyFiles();
    for (initial) |d| try testing.expect(!d);

    // Write a dirty page to the NODES store only and flush.
    const nf = try pool.pinNew(.nodes, 0);
    @memset(nf.dataSlice()[page_mod.PAGE_HEADER_SIZE..], 0x11);
    nf.dirty = true;
    pool.unpin(pool.frameIndex(nf), true);
    try pool.flushAll();

    var dirty = pool.takeDirtyFiles();
    try testing.expect(dirty[@intFromEnum(FileId.nodes)]);
    try testing.expect(!dirty[@intFromEnum(FileId.props)]);

    // takeDirtyFiles drained the set: a second drain with no new writes is empty.
    dirty = pool.takeDirtyFiles();
    for (dirty) |d| try testing.expect(!d);

    // Now modify a DIFFERENT store (props) and flush: only props must be flagged.
    const pf = try pool.pinNew(.props, 0);
    @memset(pf.dataSlice()[page_mod.PAGE_HEADER_SIZE..], 0x22);
    pf.dirty = true;
    pool.unpin(pool.frameIndex(pf), true);
    try pool.flushAll();

    dirty = pool.takeDirtyFiles();
    try testing.expect(dirty[@intFromEnum(FileId.props)]);
    try testing.expect(!dirty[@intFromEnum(FileId.nodes)]);
}

test "PERF-0057: parallel flushAll flags only the files that had pages written" {
    const node_file = try createTempFile(".test_bp_perf0057_par_nodes");
    defer cleanupTempFile(node_file, ".test_bp_perf0057_par_nodes");
    const prop_file = try createTempFile(".test_bp_perf0057_par_props");
    defer cleanupTempFile(prop_file, ".test_bp_perf0057_par_props");

    const page_size: u32 = 4096;
    var node_pager = Pager.init(node_file, page_size);
    var prop_pager = Pager.init(prop_file, page_size);

    var pool = try BufferPool.init(testing.allocator, page_size, 8);
    defer pool.deinit();
    pool.registerPager(.nodes, &node_pager);
    pool.registerPager(.props, &prop_pager);

    var thread_pool = try tp.ThreadPool.init(testing.allocator, .{ .max_threads = 2 });
    defer thread_pool.deinit();
    pool.setThreadPool(&thread_pool);

    // Write dirty pages to the props store only, then flush in parallel.
    const pf = try pool.pinNew(.props, 0);
    @memset(pf.dataSlice()[page_mod.PAGE_HEADER_SIZE..], 0xCD);
    pf.dirty = true;
    pool.unpin(pool.frameIndex(pf), true);
    try pool.flushAll();

    const dirty = pool.takeDirtyFiles();
    try testing.expect(dirty[@intFromEnum(FileId.props)]);
    try testing.expect(!dirty[@intFromEnum(FileId.nodes)]);
}

test "PERF-0056: bounded scratch flushes more dirty pages than scratch capacity in waves" {
    const file = try createTempFile(".test_bp_perf0056_waves");
    defer cleanupTempFile(file, ".test_bp_perf0056_waves");

    const page_size: u32 = 4096;
    var p = Pager.init(file, page_size);

    // Force the wave path: cap the reusable scratch at 3 pages while making 16
    // frames dirty, so the parallel flush must run several capacity-sized waves.
    // Every page must still be persisted with its distinct pattern.
    const capacity: u32 = 16;
    var pool = try BufferPool.init(testing.allocator, page_size, capacity);
    defer pool.deinit();
    pool.registerPager(.nodes, &p);
    pool.max_scratch_pages = 3;

    var thread_pool = try tp.ThreadPool.init(testing.allocator, .{ .max_threads = 4 });
    defer thread_pool.deinit();
    pool.setThreadPool(&thread_pool);

    // Make every frame dirty with a per-page distinct pattern.
    var i: PageId = 0;
    while (i < capacity) : (i += 1) {
        const f = try pool.pinNew(.nodes, i);
        @memset(f.dataSlice()[page_mod.PAGE_HEADER_SIZE..], @intCast(0x40 + i));
        f.dirty = true;
        pool.unpin(pool.frameIndex(f), true);
    }

    try pool.flushAll();

    // Every page must be persisted with its distinct pattern.
    i = 0;
    while (i < capacity) : (i += 1) {
        var read_buf: [4096]u8 = undefined;
        try p.readPage(i, &read_buf);
        for (read_buf[page_mod.PAGE_HEADER_SIZE..]) |b| {
            try testing.expectEqual(@as(u8, @intCast(0x40 + i)), b);
        }
    }

    // The reused scratch buffer must stay within the configured cap (3 pages),
    // proving the allocation did NOT scale to dirty_count*page_size.
    try testing.expect(pool.flush_scratch.len <= 3 * @as(usize, page_size));
}

test {
    std.testing.refAllDecls(@This());
}

// SONNY-6605: a flush clears a frame's dirty flag when it copies the frame and
// writes the copy with the pool mutex dropped. A reader that reads pages
// straight from the pager and asks the pool which pages to read through it
// must be told the page is newer than disk until the write has landed.
const Gate6605 = struct {
    release: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(usize) = .init(0),

    fn run(ctx: *anyopaque, _: *tp.TaskContext) void {
        const self: *Gate6605 = @ptrCast(@alignCast(ctx));
        _ = self.started.fetchAdd(1, .acq_rel);
        while (!self.release.load(.acquire)) bpio().sleep(.fromMilliseconds(1), .awake) catch {};
    }
};

fn flushAllThread6605(pool: *BufferPool, err: *?anyerror) void {
    pool.flushAll() catch |e| {
        err.* = e;
    };
}

fn frameDirtyLocked6605(pool: *BufferPool, idx: u32) bool {
    pool.mutex.lockUncancelable(bpio());
    defer pool.mutex.unlock(bpio());
    return pool.frames[idx].dirty;
}

fn diskBodyIs6605(p: *Pager, page_id: PageId, pattern: u8) !bool {
    var read_buf: [4096]u8 = undefined;
    try p.readPage(page_id, &read_buf);
    for (read_buf[page_mod.PAGE_HEADER_SIZE..]) |b| {
        if (b != pattern) return false;
    }
    return true;
}

test "SONNY-6605: a page whose parallel flush write is in flight reads as newer than disk" {
    const file = try createTempFile(".test_bp_6605_parallel");
    defer cleanupTempFile(file, ".test_bp_6605_parallel");
    const page_size: u32 = 4096;
    var p = Pager.init(file, page_size);
    try writeTestPage(&p, 0, 0x11);

    var pool = try BufferPool.init(testing.allocator, page_size, 4);
    defer pool.deinit();
    pool.registerPager(.nodes, &p);
    var thread_pool = try tp.ThreadPool.init(testing.allocator, .{ .max_threads = 1 });
    defer thread_pool.deinit();
    pool.setThreadPool(&thread_pool);

    const frame = try pool.pin(.nodes, 0);
    const idx = pool.frameIndex(frame);
    @memset(frame.dataSlice()[page_mod.PAGE_HEADER_SIZE..], 0x22);
    pool.unpin(idx, true);
    try testing.expect(pool.pageNewerThanDisk(.nodes, 0));

    // Keep the pool's only worker busy: the flush copies the frame, clears
    // its dirty flag, drops the mutex and waits for a write that cannot run.
    var gate = Gate6605{};
    _ = try thread_pool.submit(Gate6605.run, @ptrCast(&gate), .{});
    while (gate.started.load(.acquire) == 0) try bpio().sleep(.fromMilliseconds(1), .awake);
    defer gate.release.store(true, .release);

    var flush_err: ?anyerror = null;
    const flusher = try std.Thread.spawn(.{}, flushAllThread6605, .{ &pool, &flush_err });
    var waited: usize = 0;
    while (frameDirtyLocked6605(&pool, idx)) : (waited += 1) {
        if (waited > 10_000) return error.FlushDidNotStart;
        try bpio().sleep(.fromMilliseconds(1), .awake);
    }

    // In the window: the frame reads clean and the disk still holds the old
    // image. The page is newer than disk.
    try testing.expect(try diskBodyIs6605(&p, 0, 0x11));
    const in_window = pool.pageNewerThanDisk(.nodes, 0);

    gate.release.store(true, .release);
    flusher.join();
    try testing.expectEqual(@as(?anyerror, null), flush_err);
    try testing.expect(in_window);

    // The write landed: the disk holds the new image, and the page is not
    // newer than disk any more.
    try testing.expect(try diskBodyIs6605(&p, 0, 0x22));
    try testing.expect(!pool.pageNewerThanDisk(.nodes, 0));
}

test "SONNY-6605: a failed flush write leaves the page dirty, and no write in flight" {
    // A read-only file: every page write fails (EBADF), sequentially
    // (`writeFrameBytes`) and in parallel (`flushAllParallel`).
    const name = ".test_bp_6605_failed_write";
    {
        const file = try createTempFile(name);
        var p = Pager.init(file, 4096);
        try writeTestPage(&p, 0, 0x11);
        try writeTestPage(&p, 1, 0x11);
        file.close(bpio());
    }
    defer std.Io.Dir.cwd().deleteFile(bpio(), name) catch {};
    const ro = try std.Io.Dir.cwd().openFile(bpio(), name, .{ .mode = .read_only });
    defer ro.close(bpio());
    var p = Pager.init(ro, 4096);

    var pool = try BufferPool.init(testing.allocator, 4096, 4);
    defer pool.deinit();
    pool.registerPager(.nodes, &p);

    for ([_]PageId{ 0, 1 }) |page_id| {
        const frame = try pool.pin(.nodes, page_id);
        @memset(frame.dataSlice()[page_mod.PAGE_HEADER_SIZE..], 0x22);
        pool.unpin(pool.frameIndex(frame), true);
    }

    // Sequential.
    if (pool.flushAll()) |_| return error.FlushOfReadOnlyFileSucceeded else |_| {}
    try testing.expect(pool.pageNewerThanDisk(.nodes, 0));
    for (pool.frames) |*f| try testing.expectEqual(@as(u16, 0), f.writes_in_flight);

    // Parallel.
    var thread_pool = try tp.ThreadPool.init(testing.allocator, .{ .max_threads = 2 });
    defer thread_pool.deinit();
    pool.setThreadPool(&thread_pool);
    if (pool.flushAll()) |_| return error.FlushOfReadOnlyFileSucceeded else |_| {}
    for ([_]PageId{ 0, 1 }) |page_id| try testing.expect(pool.pageNewerThanDisk(.nodes, page_id));
    for (pool.frames) |*f| try testing.expectEqual(@as(u16, 0), f.writes_in_flight);
}

// SONNY-6632: a frame dirtied again while one flush's write of it is in
// flight can be taken by a second flush; the two writes must land in copy
// order. And a flush that must make every earlier change durable (`flushAll`,
// a checkpoint) must wait for the writes other flushes have in flight: their
// frames were already clean when it looked.

fn flushDirtyThread6632(pool: *BufferPool, done: *std.atomic.Value(bool), err: *?anyerror) void {
    pool.flushDirty(std.math.maxInt(Lsn)) catch |e| {
        err.* = e;
    };
    done.store(true, .release);
}

const FlushAllProbe6632 = struct {
    pool: *BufferPool,
    pager: *Pager,
    done: std.atomic.Value(bool) = .init(false),
    err: ?anyerror = null,
    /// The disk image when `flushAll` returned held the second write.
    durable_on_return: bool = false,

    fn run(self: *FlushAllProbe6632) void {
        self.pool.flushAll() catch |e| {
            self.err = e;
        };
        self.durable_on_return = diskBodyIs6605(self.pager, 0, 0x22) catch false;
        self.done.store(true, .release);
    }
};

/// Wait up to `ms` for `flag`; true when it was set.
fn waitFlag6632(flag: *std.atomic.Value(bool), ms: u64) bool {
    var waited: u64 = 0;
    while (!flag.load(.acquire)) : (waited += 1) {
        if (waited >= ms) return false;
        bpio().sleep(.fromMilliseconds(1), .awake) catch {};
    }
    return true;
}

/// Pool with one worker, page 0 on disk holding 0x11 and cached dirty with
/// 0x22, and a parallel flush of it held in its write window (the worker is
/// busy with `gate`). Returns the flusher thread.
const HeldFlush6632 = struct {
    file: std.Io.File,
    name: []const u8,
    p: Pager,
    pool: BufferPool,
    thread_pool: *tp.ThreadPool,
    gate: Gate6605 = .{},
    flush_err: ?anyerror = null,
    flusher: ?std.Thread = null,
    idx: u32 = 0,

    fn start(self: *HeldFlush6632, name: []const u8) !void {
        self.* = .{ .file = undefined, .name = name, .p = undefined, .pool = undefined, .thread_pool = undefined };
        self.file = try createTempFile(name);
        errdefer cleanupTempFile(self.file, name);
        self.p = Pager.init(self.file, 4096);
        try writeTestPage(&self.p, 0, 0x11);
        self.pool = try BufferPool.init(testing.allocator, 4096, 4);
        errdefer self.pool.deinit();
        self.pool.registerPager(.nodes, &self.p);
        self.thread_pool = try testing.allocator.create(tp.ThreadPool);
        errdefer testing.allocator.destroy(self.thread_pool);
        self.thread_pool.* = try tp.ThreadPool.init(testing.allocator, .{ .max_threads = 1 });
        self.pool.setThreadPool(self.thread_pool);

        const frame = try self.pool.pin(.nodes, 0);
        self.idx = self.pool.frameIndex(frame);
        @memset(frame.dataSlice()[page_mod.PAGE_HEADER_SIZE..], 0x22);
        self.pool.unpin(self.idx, true);

        _ = try self.thread_pool.submit(Gate6605.run, @ptrCast(&self.gate), .{});
        while (self.gate.started.load(.acquire) == 0) try bpio().sleep(.fromMilliseconds(1), .awake);
        self.flusher = try std.Thread.spawn(.{}, flushAllThread6605, .{ &self.pool, &self.flush_err });
        var waited: usize = 0;
        while (frameDirtyLocked6605(&self.pool, self.idx)) : (waited += 1) {
            if (waited > 10_000) return error.FlushDidNotStart;
            try bpio().sleep(.fromMilliseconds(1), .awake);
        }
    }

    fn release(self: *HeldFlush6632) void {
        self.gate.release.store(true, .release);
        if (self.flusher) |t| t.join();
        self.flusher = null;
    }

    fn deinit(self: *HeldFlush6632) void {
        self.release();
        self.thread_pool.deinit();
        testing.allocator.destroy(self.thread_pool);
        self.pool.deinit();
        cleanupTempFile(self.file, self.name);
    }
};

test "SONNY-6632: two flushes of a frame dirtied again during the first write land in copy order" {
    var h: HeldFlush6632 = undefined;
    try h.start(".test_bp_6632_order");
    defer h.deinit();

    // The first flush copied 0x22 and waits to write it. Dirty the frame
    // again with 0x33 and flush it on the sequential path.
    const frame = try h.pool.pin(.nodes, 0);
    @memset(frame.dataSlice()[page_mod.PAGE_HEADER_SIZE..], 0x33);
    h.pool.unpin(h.idx, true);
    var second_done = std.atomic.Value(bool).init(false);
    var second_err: ?anyerror = null;
    const second = try std.Thread.spawn(.{}, flushDirtyThread6632, .{ &h.pool, &second_done, &second_err });
    // Give the second flush time to write ahead of the first (it does when
    // writes are not ordered), then let the first write.
    _ = waitFlag6632(&second_done, 200);
    h.release();
    second.join();
    try testing.expectEqual(@as(?anyerror, null), h.flush_err);
    try testing.expectEqual(@as(?anyerror, null), second_err);

    // The frame holds 0x33 and reads clean: the disk must hold 0x33.
    try testing.expect(!h.pool.pageNewerThanDisk(.nodes, 0));
    const newest = try diskBodyIs6605(&h.p, 0, 0x33);
    if (!newest) {
        const older = try diskBodyIs6605(&h.p, 0, 0x22);
        std.debug.print("SONNY-6632: the page reads clean with 0x33 cached and the disk holds {s}\n", .{if (older) "the older copy 0x22" else "neither copy"});
    }
    try testing.expect(newest);
}

test "SONNY-6632: flushAll waits for a write another flush has in flight" {
    var h: HeldFlush6632 = undefined;
    try h.start(".test_bp_6632_flushall");
    defer h.deinit();

    // A checkpoint's flushAll while another flush's write of page 0 is in
    // flight: page 0 is clean in the pool, its new image is not on disk.
    var probe = FlushAllProbe6632{ .pool = &h.pool, .pager = &h.p };
    const t = try std.Thread.spawn(.{}, FlushAllProbe6632.run, .{&probe});
    _ = waitFlag6632(&probe.done, 200);
    h.release();
    t.join();
    try testing.expectEqual(@as(?anyerror, null), h.flush_err);
    try testing.expectEqual(@as(?anyerror, null), probe.err);
    if (!probe.durable_on_return) std.debug.print("SONNY-6632: flushAll returned while page 0's write was still in flight (the disk held the old image)\n", .{});
    try testing.expect(probe.durable_on_return);
}
