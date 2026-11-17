//! SONNY-6692: scrub dead space — overwrite the bytes the store no longer
//! references, so values that were replaced, removed or spilled and freed
//! are not left on disk.
//!
//! A property write that does not fit its record's slab slot moves the
//! record's blob to a new slot and tombstones the old one with its bytes
//! intact (an open transaction's undo reads them); a value larger than a
//! property page spills to a var-store chain, and the chain's pages are
//! freed on replacement or removal without being cleared. Both kept
//! superseded values (field-level-encryption migration: the plaintext a
//! value was migrated from) until the space happened to be reused.
//!
//! `scrubDeadSpace` runs one transaction that
//!   * zeroes the body of every FREE page of the property and var stores
//!     that holds anything (in the file, or newer than the file in the
//!     buffer pool);
//!   * zeroes, on every allocated property page that validates as a slab
//!     page and is not a page of a live legacy property chain, every byte no
//!     slot with a length holds (tombstoned blobs and gaps);
//! and WAL-images every page it changed, so a crash after the commit replays
//! the cleared images. The caller then checkpoints: the pages reach the
//! store files and the WAL that still holds the old images is truncated.
//!
//! Only while no transaction is open on the engine (`error.TransactionsOpen`):
//! an open transaction's undo may read a tombstoned blob, and its pages are
//! claimed. Allocated pages the walk does not attribute (an orphan) are left
//! alone unless they validate as slab pages, where only unheld bytes are
//! cleared, so a mis-attribution can never touch a live byte.

const std = @import("std");
const types = @import("types.zig");
const engine_mod = @import("engine.zig");
const engine_undo = @import("engine_undo.zig");
const prop_store_mod = @import("prop_store.zig");
const var_store_mod = @import("var_store.zig");
const page_mod = @import("page.zig");
const node_mod = @import("node.zig");

const GraphEngine = engine_mod.GraphEngine;
const PageId = types.PageId;
const FileId = types.FileId;
const NodeId = types.NodeId;
const NodeRec = node_mod.NodeRec;

/// What `scrubDeadSpace` cleared.
pub const ScrubReport = struct {
    /// Free pages whose body held bytes and was zeroed.
    free_pages_zeroed: u64 = 0,
    /// Slab pages on which dead bytes were zeroed.
    slab_pages_scrubbed: u64 = 0,
    /// Dead slab bytes zeroed.
    slab_bytes_zeroed: u64 = 0,

    pub fn add(self: *ScrubReport, other: ScrubReport) void {
        self.free_pages_zeroed += other.free_pages_zeroed;
        self.slab_pages_scrubbed += other.slab_pages_scrubbed;
        self.slab_bytes_zeroed += other.slab_bytes_zeroed;
    }
};

pub fn scrubDeadSpace(engine: *GraphEngine) !ScrubReport {
    if (engine.txn_manager.activeCount() != 0) return error.TransactionsOpen;

    var report: ScrubReport = .{};
    var legacy: std.AutoHashMapUnmanaged(PageId, void) = .empty;
    defer legacy.deinit(engine.allocator);
    try collectLiveLegacyPropPages(engine, &legacy);

    const txn = try engine.beginTxn();
    var committed = false;
    errdefer if (!committed) engine.abortTxn(txn) catch {};
    // The pages are changed directly, not through an undoable store op.
    engine_undo.markNotUndoable(engine, txn, .caller_page_image);

    try zeroFreePages(engine, txn, .props, &engine.free_space_props, &report);
    try zeroFreePages(engine, txn, .var_store, &engine.free_space_var, &report);

    const props_pages = try filePages(engine, .props, &engine.free_space_props);
    var page: PageId = 1;
    while (page < props_pages) : (page += 1) {
        if (!engine.free_space_props.isAllocated(page)) continue;
        if (legacy.contains(page)) continue;
        const zeroed = try engine.prop_store.scrubDeadSlabBytes(page);
        if (zeroed == 0) continue;
        try engine.logPage(txn, .props, page);
        report.slab_pages_scrubbed += 1;
        report.slab_bytes_zeroed += zeroed;
    }

    try engine.commitTxn(txn);
    committed = true;
    // The next checkpoint writes the cleared pages (and truncates the WAL
    // holding the old images) even when nothing else changed.
    if (report.free_pages_zeroed != 0 or report.slab_bytes_zeroed != 0) engine.markPersistenceDirty();
    return report;
}

/// Pages to consider in `file`: up to the larger of the file's page count
/// and the free-space bitmap's size.
fn filePages(engine: *GraphEngine, file: FileId, fsm: anytype) !u64 {
    const pager = engine.buffer_pool.pagers[@intFromEnum(file)] orelse return fsm.total_pages;
    return @max(try pager.pageCount(), fsm.total_pages);
}

fn zeroFreePages(engine: *GraphEngine, txn: u64, file: FileId, fsm: anytype, report: *ScrubReport) !void {
    const pager = engine.buffer_pool.pagers[@intFromEnum(file)] orelse return;
    const on_disk = try pager.pageCount();
    const total = @max(on_disk, fsm.total_pages);

    var page: PageId = 1;
    while (page < total) : (page += 1) {
        if (fsm.isAllocated(page)) continue;
        // Past the file: only a page the buffer pool holds newer than disk
        // can reach it.
        if (page >= on_disk and !engine.buffer_pool.pageNewerThanDisk(file, page)) continue;
        const frame = try engine.buffer_pool.pin(file, page);
        const frame_idx = engine.buffer_pool.frameIndex(frame);
        const body = frame.dataSlice()[page_mod.PAGE_HEADER_SIZE..];
        const holds = std.mem.indexOfNone(u8, body, &.{0}) != null;
        if (holds) @memset(body, 0);
        engine.buffer_pool.unpin(frame_idx, holds);
        if (!holds) continue;
        try engine.logPage(txn, file, page);
        report.free_pages_zeroed += 1;
    }
}

/// The pages of every live legacy property chain: each live node's own
/// chain and each of its edges' chains (out- and in-adjacency).
fn collectLiveLegacyPropPages(engine: *GraphEngine, out: *std.AutoHashMapUnmanaged(PageId, void)) !void {
    const Ctx = struct {
        engine: *GraphEngine,
        out: *std.AutoHashMapUnmanaged(PageId, void),
        err: ?anyerror = null,

        fn add(self: *@This(), head: u64) !void {
            try self.engine.prop_store.appendLegacyChainPages(self.engine.allocator, head, self.out);
        }

        fn edges(self: *@This(), store: anytype, head: u64) !void {
            if (head == 0) return;
            var iter = store.expand(head, null);
            defer iter.deinit();
            while (try iter.next()) |entry| try self.add(entry.prop_head);
        }

        fn callback(self: *@This(), _: NodeId, rec: NodeRec) void {
            if (self.err != null) return;
            self.add(rec.prop_head) catch |e| {
                self.err = e;
                return;
            };
            self.edges(&self.engine.adj_out, rec.out_head) catch |e| {
                self.err = e;
                return;
            };
            self.edges(&self.engine.adj_in, rec.in_head) catch |e| {
                self.err = e;
            };
        }
    };
    var ctx = Ctx{ .engine = engine, .out = out };
    try engine.node_store.scanNodes(engine.manifest.next_node_id, &ctx, Ctx.callback);
    if (ctx.err) |e| return e;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const test_support = @import("testing_support.zig");

/// Does any file under `dir_path` contain `needle`?
fn dirContains(dir_path: []const u8, needle: []const u8) !bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const data = dir.readFileAlloc(io, entry.path, testing.allocator, .limited(1 << 30)) catch continue;
        defer testing.allocator.free(data);
        if (std.mem.indexOf(u8, data, needle) != null) {
            std.debug.print("'{s}' is in {s}\n", .{ needle, entry.path });
            return true;
        }
    }
    return false;
}

fn bigValue(comptime marker: []const u8) []const u8 {
    return marker ++ ("v" ** 12000);
}

test "SONNY-6692: scrubDeadSpace + checkpoint leaves no replaced, removed or spilled-and-freed value in any file; live values read back" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x92} ** 16;
    const engine = try GraphEngine.create(testing.allocator, td.path, uuid, test_support.testConfig());
    defer engine.close() catch {};

    const small_old = "SCRUB-6692-SMALL-OLD";
    const small_live = "SCRUB-6692-SMALL-LIVE-AND-LONGER-SO-IT-RELOCATES";
    const gone = "SCRUB-6692-REMOVED";
    const big_old = comptime bigValue("SCRUB-6692-BIG-OLD");
    const big_live = comptime bigValue("SCRUB-6692-BIG-LIVE");

    const a = try engine.allocNode();
    var ra = test_support.emptyNode(1);
    try engine.putNode(a, ra);
    ra.prop_head = try engine.putProperty(ra.prop_head, "k", .{ .string = small_old });
    ra.prop_head = try engine.putProperty(ra.prop_head, "g", .{ .string = gone });
    try engine.putNode(a, ra);
    // Another record's blob after it on the slab page, so `a`'s cannot grow
    // in place.
    const c = try engine.allocNode();
    var rc = test_support.emptyNode(1);
    try engine.putNode(c, rc);
    rc.prop_head = try engine.putProperty(rc.prop_head, "other", .{ .string = "SCRUB-6692-NEIGHBOUR" });
    try engine.putNode(c, rc);
    // On disk, then superseded: the longer value moves the blob to a new
    // slot and tombstones the old one with its bytes.
    try engine.checkpoint();
    ra.prop_head = try engine.putProperty(ra.prop_head, "k", .{ .string = small_live });
    try engine.putNode(a, ra);
    try engine.removeProperty(ra.prop_head, "g");

    const b = try engine.allocNode();
    var rb = test_support.emptyNode(1);
    try engine.putNode(b, rb);
    rb.prop_head = try engine.putProperty(rb.prop_head, "big", .{ .string = big_old });
    rb.prop_head = try engine.putProperty(rb.prop_head, "big", .{ .string = big_live });
    try engine.putNode(b, rb);
    try engine.checkpoint();

    // On disk before the scrub (the old blob in a tombstoned slot, the old
    // spill in freed var pages).
    for ([_][]const u8{ small_old, "SCRUB-6692-BIG-OLD" }) |m| try testing.expect(try dirContains(td.path, m));

    const report = try engine.scrubDeadSpace();
    try engine.checkpoint();
    try testing.expect(report.slab_bytes_zeroed > 0);
    try testing.expect(report.free_pages_zeroed > 0);
    for ([_][]const u8{ small_old, gone, "SCRUB-6692-BIG-OLD" }) |m| {
        if (try dirContains(td.path, m)) {
            std.debug.print("SONNY-6692: '{s}' is still on disk after scrubDeadSpace + checkpoint ({any})\n", .{ m, report });
            return error.DeadBytesRemain;
        }
    }
    // Live values untouched.
    const ra2 = (try engine.getNode(a)).?;
    const got = (try engine.getProperty(ra2.prop_head, "k", testing.allocator)).?;
    defer @import("property.zig").freeDecoded(testing.allocator, got);
    try testing.expectEqualStrings(small_live, got.string);
    const rb2 = (try engine.getNode(b)).?;
    const got_big = (try engine.getProperty(rb2.prop_head, "big", testing.allocator)).?;
    defer @import("property.zig").freeDecoded(testing.allocator, got_big);
    try testing.expectEqualStrings(big_live, got_big.string);
    try testing.expect(try dirContains(td.path, "SCRUB-6692-SMALL-LIVE"));
    const rc2 = (try engine.getNode(c)).?;
    const got_c = (try engine.getProperty(rc2.prop_head, "other", testing.allocator)).?;
    defer @import("property.zig").freeDecoded(testing.allocator, got_c);
    try testing.expectEqualStrings("SCRUB-6692-NEIGHBOUR", got_c.string);
}

test "SONNY-6692: scrubDeadSpace refuses while a transaction is open" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const engine = try GraphEngine.create(testing.allocator, td.path, [_]u8{0x93} ** 16, test_support.testConfig());
    defer engine.close() catch {};
    const txn = try engine.beginTxn();
    try testing.expectError(error.TransactionsOpen, engine.scrubDeadSpace());
    try engine.abortTxn(txn);
    _ = try engine.scrubDeadSpace();
}

/// SONNY-6700: an allocated page of `file` no record owns (as a leak or a
/// crash leaves one), holding `marker`.
fn leakPage(engine: *GraphEngine, file: FileId, fsm: anytype, marker: []const u8) !PageId {
    const p = try fsm.allocPage();
    const frame = try engine.buffer_pool.pinNew(file, p);
    const idx = engine.buffer_pool.frameIndex(frame);
    @memcpy(frame.dataSlice()[page_mod.PAGE_HEADER_SIZE + 64 ..][0..marker.len], marker);
    engine.buffer_pool.unpin(idx, true);
    engine.markPersistenceDirty();
    return p;
}

test "SONNY-6700: scrubDeadSpace clears superseded var-store slab runs and allocated pages no record owns; live labels and properties read back" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const engine = try GraphEngine.create(testing.allocator, td.path, [_]u8{0x70} ** 16, test_support.testConfig());
    defer engine.close() catch {};

    // Live: a node with labels (a var-store slab run) and a property.
    const n = try engine.allocNode();
    try engine.putNode(n, test_support.emptyNode(1));
    try engine.addLabel(n, 7);
    try engine.addLabel(n, 9);
    var rn = (try engine.getNode(n)).?;
    rn.prop_head = try engine.putProperty(rn.prop_head, "keep", .{ .string = "SCRUB-6700-LIVE" });
    try engine.putNode(n, rn);

    // Superseded: a small var-store run (packed into the shared slab block)
    // written and freed; and an orphaned props page and var-store page.
    const ref = try engine.var_store.write("SCRUB-6700-VARSLAB-OLD");
    try testing.expect(var_store_mod.isSlabHead(ref));
    try engine.var_store.free(ref);
    _ = try leakPage(engine, .props, &engine.free_space_props, "SCRUB-6700-ORPHAN-PROPS");
    _ = try leakPage(engine, .var_store, &engine.free_space_var, "SCRUB-6700-ORPHAN-VAR");
    try engine.checkpoint();
    const dead = [_][]const u8{ "SCRUB-6700-VARSLAB-OLD", "SCRUB-6700-ORPHAN-PROPS", "SCRUB-6700-ORPHAN-VAR" };
    for (dead) |m| try testing.expect(try dirContains(td.path, m));

    const report = try engine.scrubDeadSpace();
    try engine.checkpoint();
    var remaining: usize = 0;
    for (dead) |m| {
        if (try dirContains(td.path, m)) remaining += 1;
    }
    if (remaining != 0) {
        std.debug.print("SONNY-6700: {d} of {d} dead values still on disk after scrubDeadSpace + checkpoint ({any})\n", .{ remaining, dead.len, report });
        return error.DeadBytesRemain;
    }

    const rn2 = (try engine.getNode(n)).?;
    const labels = try engine.label_store.getLabels(rn2.label_head, testing.allocator);
    defer testing.allocator.free(labels);
    try testing.expectEqualSlices(u32, &.{ 7, 9 }, labels);
    const got = (try engine.getProperty(rn2.prop_head, "keep", testing.allocator)).?;
    defer @import("property.zig").freeDecoded(testing.allocator, got);
    try testing.expectEqualStrings("SCRUB-6700-LIVE", got.string);
}
