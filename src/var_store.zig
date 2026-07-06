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

    /// Decode the FIRST PAGE ID of the chain a var-store reference points at.
    /// A ref is `first_page << 16`, NOT a page id — callers that need the
    /// on-disk page (e.g. to WAL-image the chain) must decode it here instead
    /// of passing the raw ref around as if it were a page id.
    pub fn refFirstPage(ref: u64) PageId {
        return ref >> 16;
    }

    /// Read the next-page link of a chain page (0 = end of chain). Used by
    /// the engine to WAL-image every page of a freshly written chain.
    pub fn nextChainPage(self: *VarStore, page_id: PageId) !PageId {
        const frame = try self.buffer_pool.pin(.var_store, page_id);
        const frame_idx = self.buffer_pool.frameIndex(frame);
        const page_data = frame.dataSlice();
        const next = std.mem.bytesToValue(u64, page_data[PAGE_HEADER_SIZE..][0..8]);
        self.buffer_pool.unpin(frame_idx, false);
        return next;
    }

    /// Read variable-length data by reference.
    /// Caller owns the returned slice and must free it.
    pub fn read(self: *VarStore, ref: u64, allocator: Allocator) ![]u8 {
        const start_page: PageId = ref >> 16;
        if (start_page == 0) return error.InvalidPageId;

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        var current_page = start_page;
        var hops: u32 = 0;
        const max_hops: u32 = 100_000;
        while (current_page != 0) : (hops += 1) {
            if (hops >= max_hops) return error.CircularChainDetected;

            const frame = try self.buffer_pool.pin(.var_store, current_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const page_data = frame.dataSlice();

            const meta_off = PAGE_HEADER_SIZE;
            const next_page = std.mem.bytesToValue(u64, page_data[meta_off..][0..8]);
            const data_len = std.mem.bytesToValue(u32, page_data[meta_off + 8 ..][0..4]);

            if (data_len > self.dataCapacity()) {
                self.buffer_pool.unpin(frame_idx, false);
                return error.DataCorruption;
            }

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
        var hops: u32 = 0;
        const max_hops: u32 = 100_000;
        while (current_page != 0) : (hops += 1) {
            if (hops >= max_hops) return error.CircularChainDetected;

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
const testing_support_mod = @import("testing_support.zig");
const SingleStoreEnv = testing_support_mod.SingleStoreEnv;

test "write + read round-trip for small data" {
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 32);
    env.register();
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
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 32);
    env.register();
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
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 32);
    env.register();
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

test "read rejects data_len exceeding dataCapacity (dataCapacity+1)" {
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 32);
    env.register();
    defer env.deinit();

    var store = VarStore.init(&env.pool, &env.fsm, 4096);

    // Allocate a real page through the free space manager so it has a valid page_id.
    const page_id = try env.fsm.allocPage();

    // Pin the page and write a corrupt header directly: next_page=0, data_len=cap+1.
    const frame = try env.pool.pinNew(.var_store, page_id);
    const frame_idx = env.pool.frameIndex(frame);
    const page_data = frame.dataSlice();
    const meta_off = PAGE_HEADER_SIZE;
    @memcpy(page_data[meta_off..][0..8], &std.mem.toBytes(@as(u64, 0))); // next_page = 0
    const bad_len: u32 = store.dataCapacity() + 1;
    @memcpy(page_data[meta_off + 8 ..][0..4], &std.mem.toBytes(bad_len));
    env.pool.unpin(frame_idx, true);

    // Build a ref matching how write() encodes it.
    const ref: u64 = @as(u64, page_id) << 16;
    try testing.expectError(error.DataCorruption, store.read(ref, testing.allocator));
}

test "read rejects data_len exceeding dataCapacity (0xFFFFFFFF)" {
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 32);
    env.register();
    defer env.deinit();

    var store = VarStore.init(&env.pool, &env.fsm, 4096);

    const page_id = try env.fsm.allocPage();

    const frame = try env.pool.pinNew(.var_store, page_id);
    const frame_idx = env.pool.frameIndex(frame);
    const page_data = frame.dataSlice();
    const meta_off = PAGE_HEADER_SIZE;
    @memcpy(page_data[meta_off..][0..8], &std.mem.toBytes(@as(u64, 0))); // next_page = 0
    @memcpy(page_data[meta_off + 8 ..][0..4], &std.mem.toBytes(@as(u32, 0xFFFFFFFF)));
    env.pool.unpin(frame_idx, true);

    const ref: u64 = @as(u64, page_id) << 16;
    try testing.expectError(error.DataCorruption, store.read(ref, testing.allocator));
}

// ============================================================================
// GAP var-store slab packing — P0 oracle: bytes/node baseline + round-trip
// parity harness.
//
// The var.store is the biggest un-slabbed store: measured at the 14.27M scale
// it costs exactly 8,192 B/node = ONE 8 KB page per node's var-chain, because
// `write` allocates a fresh page (chain) per call even for a ~40-90 B string.
// These tests LOCK that baseline as a regression oracle (the "before" number
// the slab initiative is judged against) and provide the round-trip parity
// harness reused by P1 (a slab-format block must read byte-identical to the
// legacy page-chain encoding) and the future writer.
// ============================================================================

/// Round-trip parity oracle. Writes every opaque var record through the legacy
/// funnel, forces the pages to disk (`flushAll` + a buffer pool small enough
/// that natural eviction re-reads from the persisted image), then reads each
/// back and asserts byte-identical. A node's label block and a property string
/// are both just bytes to VarStore, so one harness covers "every var string AND
/// every label reads back byte-identical after write + reopen".
fn expectVarRoundTripParity(store: *VarStore, pool: *buffer_pool_mod.BufferPool, records: []const []const u8) !void {
    const refs = try testing.allocator.alloc(u64, records.len);
    defer testing.allocator.free(refs);
    for (records, 0..) |rec, i| refs[i] = try store.write(rec);

    // Persist the whole store; with a small pool the earlier chains have
    // already been evicted to disk, so the read-back exercises the on-disk
    // image, not just the write cache.
    try pool.flushAll();

    for (records, 0..) |rec, i| {
        const got = try store.read(refs[i], testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, rec, got);
    }
}

test "P0 oracle: legacy var.store costs one full 8 KB page per small chain (the bloat baseline)" {
    const page_size: u32 = 8192;
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", page_size, 64);
    env.register();
    defer env.deinit();

    var store = VarStore.init(&env.pool, &env.fsm, page_size);

    // Short taxa var strings — scientific_name + authorship sized (~40-90 B),
    // far below one page.
    const n: u32 = 200;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        var buf: [96]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "Acanthurus leucosternon {d} (Bennett, 1833)", .{i});
        _ = try store.write(s);
    }

    // One page allocated per chain — the un-slabbed layout, verbatim.
    const pages = env.fsm.allocatedCount();
    try testing.expectEqual(@as(u64, n), pages);

    // The number the whole initiative is judged against: 8,192 B/node.
    // P2's slab writer flips this assertion toward O(actual bytes); until then
    // this LOCKS the baseline so a regression that reinflates it fails loudly.
    const bytes_per_node = pages * page_size / n;
    try testing.expectEqual(@as(u64, 8192), bytes_per_node);
}

test "P0 parity: short strings + label blocks round-trip byte-identical (legacy, after flush)" {
    // Small pool (8 pages) vs many chains ⇒ eviction forces disk round-trips.
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", 4096, 8);
    env.register();
    defer env.deinit();

    var store = VarStore.init(&env.pool, &env.fsm, 4096);

    var records: std.ArrayList([]const u8) = .empty;
    defer {
        for (records.items) |r| testing.allocator.free(r);
        records.deinit(testing.allocator);
    }

    // Interleave variable-length taxa strings with encoded label blocks — the
    // exact on-disk LabelStore encoding ([u16 count][u32 ids...]) so "labels
    // read back byte-identical" is covered at the byte level.
    var i: u32 = 0;
    while (i < 40) : (i += 1) {
        if (i % 2 == 0) {
            const s = try std.fmt.allocPrint(testing.allocator, "Chromis viridis {d} authorship remark payload", .{i});
            try records.append(testing.allocator, s);
        } else {
            const nlabels: u32 = 1 + (i % 5);
            const buf = try testing.allocator.alloc(u8, 2 + nlabels * 4);
            std.mem.writeInt(u16, buf[0..2], @intCast(nlabels), .little);
            var k: u32 = 0;
            while (k < nlabels) : (k += 1) {
                std.mem.writeInt(u32, buf[2 + k * 4 ..][0..4], i * 100 + k, .little);
            }
            try records.append(testing.allocator, buf);
        }
    }

    try expectVarRoundTripParity(&store, &env.pool, records.items);
}

test {
    std.testing.refAllDecls(@This());
}
