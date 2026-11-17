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
//! `scrubDeadSpace` first proves ownership (SONNY-6700): it walks every live
//! node (property chain, labels) and each of its out-edges (property chain),
//! following every overflowed value into the var store, and records the
//! pages of live legacy chains and the live slots of slab pages. Any
//! reference that does not resolve aborts the scrub before anything changes.
//! Then one transaction
//!   * zeroes the body of every FREE page of the property and var stores
//!     that holds anything (in the file, or newer than the file in the
//!     buffer pool);
//!   * on every property slab page and var-store slab block a live record
//!     owns, tombstones the slots no live record references (orphaned
//!     copies) and zeroes every byte no live slot holds (tombstoned blobs and
//!     runs, gaps); the shared fill page or block is emptied the same way;
//!   * zeroes and frees every other allocated page of the two stores: no
//!     live record owns it (a leak, a crash leftover);
//! and WAL-images every page it changed, so a crash after the commit replays
//! the cleared images. The caller then checkpoints: the pages reach the
//! store files and the WAL that still holds the old images is truncated.
//!
//! Only while no transaction is open on the engine (`error.TransactionsOpen`):
//! an open transaction's undo may read a tombstoned blob, its pages are
//! claimed, and its fill pages are its own. The caller excludes every writer
//! for the duration (the engine is single-writer): a property or label head
//! a writer holds but has not yet stored in a node record or edge entry is
//! owned by nobody, and would be freed.

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
    /// Property slab pages on which dead bytes were zeroed.
    slab_pages_scrubbed: u64 = 0,
    /// Property slab bytes zeroed (and orphaned slots tombstoned).
    slab_bytes_zeroed: u64 = 0,
    /// SONNY-6700: var-store slab blocks scrubbed, and their bytes.
    var_slab_blocks_scrubbed: u64 = 0,
    var_slab_bytes_zeroed: u64 = 0,
    /// SONNY-6700: allocated pages no live record owns, zeroed and freed.
    orphan_pages_freed: u64 = 0,

    pub fn add(self: *ScrubReport, other: ScrubReport) void {
        inline for (@typeInfo(ScrubReport).@"struct".fields) |f| @field(self, f.name) += @field(other, f.name);
    }
};

/// SONNY-6700: what every live record owns in the property and var stores,
/// from a walk of every live node (its property chain, its labels) and each
/// of its out-edges (their property chains; an edge's properties live in its
/// source's store, beside the out-adjacency entry), and every property's
/// overflow ref. Pages a walk does not reach are owned by nobody.
const Ownership = struct {
    allocator: std.mem.Allocator,
    /// Pages of live legacy property chains.
    props_pages: std.AutoHashMapUnmanaged(PageId, void) = .empty,
    /// Live slots per property slab page.
    props_slots: std.AutoHashMapUnmanaged(PageId, std.ArrayListUnmanaged(u32)) = .empty,
    /// Pages of live legacy var-store chains (labels, overflowed values).
    var_pages: std.AutoHashMapUnmanaged(PageId, void) = .empty,
    /// Live runs per var-store slab block.
    var_slots: std.AutoHashMapUnmanaged(PageId, std.ArrayListUnmanaged(u32)) = .empty,

    fn deinit(self: *Ownership) void {
        self.props_pages.deinit(self.allocator);
        var it = self.props_slots.valueIterator();
        while (it.next()) |l| l.deinit(self.allocator);
        self.props_slots.deinit(self.allocator);
        self.var_pages.deinit(self.allocator);
        var vit = self.var_slots.valueIterator();
        while (vit.next()) |l| l.deinit(self.allocator);
        self.var_slots.deinit(self.allocator);
    }

    fn addSlot(self: *Ownership, map: *std.AutoHashMapUnmanaged(PageId, std.ArrayListUnmanaged(u32)), page: PageId, slot: u32) !void {
        const gop = try map.getOrPut(self.allocator, page);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        if (std.mem.indexOfScalar(u32, gop.value_ptr.items, slot) == null) try gop.value_ptr.append(self.allocator, slot);
    }

    fn ownVar(self: *Ownership, engine: *GraphEngine, ref: u64) !void {
        if (ref == 0) return;
        if (var_store_mod.isSlabHead(ref)) {
            const page = var_store_mod.slabHeadPageId(ref);
            if (page == 0) return error.DataCorruption;
            return self.addSlot(&self.var_slots, page, var_store_mod.slabHeadSlot(ref));
        }
        try engine.var_store.appendChainPages(self.allocator, ref, &self.var_pages);
    }

    fn ownProps(self: *Ownership, engine: *GraphEngine, head: u64) !void {
        if (head == 0) return;
        if (prop_store_mod.isSlabHead(head)) {
            try self.addSlot(&self.props_slots, prop_store_mod.slabPageId(head), prop_store_mod.slabSlot(head));
        } else {
            try engine.prop_store.appendLegacyChainPages(self.allocator, head, &self.props_pages);
        }
        var iter = engine.prop_store.getAllProperties(head);
        defer iter.deinit();
        while (try iter.next()) |_| {
            if (iter.last_var_ref) |ref| try self.ownVar(engine, ref);
        }
    }

    fn walk(self: *Ownership, engine: *GraphEngine) !void {
        const Ctx = struct {
            own: *Ownership,
            engine: *GraphEngine,
            err: ?anyerror = null,

            fn node(c: *@This(), rec: NodeRec) !void {
                try c.own.ownProps(c.engine, rec.prop_head);
                try c.own.ownVar(c.engine, rec.label_head);
                if (rec.out_head == 0) return;
                var iter = c.engine.adj_out.expand(rec.out_head, null);
                defer iter.deinit();
                while (try iter.next()) |entry| try c.own.ownProps(c.engine, entry.prop_head);
            }

            fn callback(c: *@This(), _: NodeId, rec: NodeRec) void {
                if (c.err != null) return;
                c.node(rec) catch |e| {
                    c.err = e;
                };
            }
        };
        var ctx = Ctx{ .own = self, .engine = engine };
        try engine.node_store.scanNodes(engine.manifest.next_node_id, &ctx, Ctx.callback);
        if (ctx.err) |e| return e;
    }
};

pub fn scrubDeadSpace(engine: *GraphEngine) !ScrubReport {
    if (engine.txn_manager.activeCount() != 0) return error.TransactionsOpen;

    // The proof first: every live reference resolved, before any change.
    var own = Ownership{ .allocator = engine.allocator };
    defer own.deinit();
    try own.walk(engine);

    var report: ScrubReport = .{};
    const txn = try engine.beginTxn();
    var committed = false;
    errdefer if (!committed) engine.abortTxn(txn) catch {};
    // The pages are changed directly, not through an undoable store op.
    engine_undo.markNotUndoable(engine, txn, .caller_page_image);

    try zeroFreePages(engine, txn, .props, &engine.free_space_props, &report);
    try zeroFreePages(engine, txn, .var_store, &engine.free_space_var, &report);

    // Property store: owned slab pages scrubbed against their live slots,
    // live legacy chain pages kept, the fill page emptied of dead slots,
    // every other allocated page (owned by nobody) zeroed and freed.
    const props_fill = engine.prop_store.currentFillPage();
    const props_pages = try filePages(engine, .props, &engine.free_space_props);
    var page: PageId = 1;
    while (page < props_pages) : (page += 1) {
        if (!engine.free_space_props.isAllocated(page)) continue;
        if (own.props_pages.contains(page)) continue;
        if (own.props_slots.get(page)) |live| {
            const zeroed = try engine.prop_store.scrubSlabPageOwned(page, live.items);
            if (zeroed == 0) continue;
            try engine.logPage(txn, .props, page);
            report.slab_pages_scrubbed += 1;
            report.slab_bytes_zeroed += zeroed;
            continue;
        }
        if (props_fill != null and props_fill.? == page) {
            const zeroed = engine.prop_store.scrubSlabPageOwned(page, &.{}) catch 0;
            if (zeroed == 0) continue;
            try engine.logPage(txn, .props, page);
            report.slab_pages_scrubbed += 1;
            report.slab_bytes_zeroed += zeroed;
            continue;
        }
        try freeOrphan(engine, txn, .props, &engine.free_space_props, page, &report);
    }

    // Var store: the same, with slab blocks.
    const var_fill = engine.var_store.currentFillPage();
    const var_pages = try filePages(engine, .var_store, &engine.free_space_var);
    page = 1;
    while (page < var_pages) : (page += 1) {
        if (!engine.free_space_var.isAllocated(page)) continue;
        if (own.var_pages.contains(page)) continue;
        if (own.var_slots.get(page)) |live| {
            const zeroed = try engine.var_store.scrubSlabBlockOwned(page, live.items);
            if (zeroed == 0) continue;
            try engine.logPage(txn, .var_store, page);
            report.var_slab_blocks_scrubbed += 1;
            report.var_slab_bytes_zeroed += zeroed;
            continue;
        }
        if (var_fill != null and var_fill.? == page) {
            const zeroed = engine.var_store.scrubSlabBlockOwned(page, &.{}) catch 0;
            if (zeroed == 0) continue;
            try engine.logPage(txn, .var_store, page);
            report.var_slab_blocks_scrubbed += 1;
            report.var_slab_bytes_zeroed += zeroed;
            continue;
        }
        try freeOrphan(engine, txn, .var_store, &engine.free_space_var, page, &report);
    }

    try engine.commitTxn(txn);
    committed = true;
    // The next checkpoint writes the cleared pages (and truncates the WAL
    // holding the old images) even when nothing else changed.
    if (report.free_pages_zeroed != 0 or report.slab_bytes_zeroed != 0 or report.var_slab_bytes_zeroed != 0 or report.orphan_pages_freed != 0) engine.markPersistenceDirty();
    return report;
}

/// An allocated page no live record owns: its body zeroed (WAL-imaged) and
/// the page freed (it returns to the free list when the scrub commits).
fn freeOrphan(engine: *GraphEngine, txn: u64, file: FileId, fsm: anytype, page: PageId, report: *ScrubReport) !void {
    const frame = try engine.buffer_pool.pin(file, page);
    const frame_idx = engine.buffer_pool.frameIndex(frame);
    const body = frame.dataSlice()[page_mod.PAGE_HEADER_SIZE..];
    const holds = std.mem.indexOfNone(u8, body, &.{0}) != null;
    if (holds) @memset(body, 0);
    engine.buffer_pool.unpin(frame_idx, holds);
    if (holds) try engine.logPage(txn, file, page);
    try fsm.freePage(page);
    report.orphan_pages_freed += 1;
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
        if (std.mem.indexOf(u8, data, needle) != null) return true;
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

test "SONNY-6700: the ownership proof keeps every live byte: node and edge properties (inline and overflowed), labels, a deleted neighbour; a second scrub changes nothing; all of it reads back after reopen" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x71} ** 16;
    var engine = try GraphEngine.create(testing.allocator, td.path, uuid, test_support.testConfig());
    var open = true;
    defer if (open) engine.close() catch {};

    var ids: [6]NodeId = undefined;
    for (&ids, 0..) |*id, i| {
        id.* = try engine.allocNode();
        try engine.putNode(id.*, test_support.emptyNode(1));
        try engine.addLabel(id.*, @intCast(10 + i));
        try engine.addLabel(id.*, 100);
        var rec = (try engine.getNode(id.*)).?;
        var buf: [32]u8 = undefined;
        const v = try std.fmt.bufPrint(&buf, "LIVE-6700-N{d}", .{i});
        rec.prop_head = try engine.putProperty(rec.prop_head, "k", .{ .string = v });
        if (i == 3) rec.prop_head = try engine.putProperty(rec.prop_head, "big", .{ .string = bigValue("LIVE-6700-BIG") });
        try engine.putNode(id.*, rec);
    }
    const e01 = try engine.addEdge(ids[0], ids[1], 1);
    const e12 = try engine.addEdge(ids[1], ids[2], 1);
    try engine.setEdgeProperty(ids[0], ids[1], e01, "w", .{ .string = "LIVE-6700-E01" });
    try engine.setEdgeProperty(ids[1], ids[2], e12, "w", .{ .string = bigValue("LIVE-6700-EBIG") });
    try engine.deleteNode(ids[5]);
    try engine.checkpoint();

    _ = try engine.scrubDeadSpace();
    const again = try engine.scrubDeadSpace();
    try testing.expectEqual(ScrubReport{}, again);
    try engine.checkpoint();
    try engine.close();
    open = false;

    engine = try GraphEngine.open(testing.allocator, td.path, uuid, test_support.testConfig());
    open = true;
    for (ids[0..5], 0..) |id, i| {
        const rec = (try engine.getNode(id)).?;
        const labels = try engine.label_store.getLabels(rec.label_head, testing.allocator);
        defer testing.allocator.free(labels);
        try testing.expectEqualSlices(u32, &.{ @intCast(10 + i), 100 }, labels);
        var buf: [32]u8 = undefined;
        const want = try std.fmt.bufPrint(&buf, "LIVE-6700-N{d}", .{i});
        const got = (try engine.getProperty(rec.prop_head, "k", testing.allocator)).?;
        defer @import("property.zig").freeDecoded(testing.allocator, got);
        try testing.expectEqualStrings(want, got.string);
        if (i == 3) {
            const big = (try engine.getProperty(rec.prop_head, "big", testing.allocator)).?;
            defer @import("property.zig").freeDecoded(testing.allocator, big);
            try testing.expectEqualStrings(bigValue("LIVE-6700-BIG"), big.string);
        }
    }
    const w01 = (try engine.getEdgeProperty(ids[0], e01, "w", testing.allocator)).?;
    defer @import("property.zig").freeDecoded(testing.allocator, w01);
    try testing.expectEqualStrings("LIVE-6700-E01", w01.string);
    const w12 = (try engine.getEdgeProperty(ids[1], e12, "w", testing.allocator)).?;
    defer @import("property.zig").freeDecoded(testing.allocator, w12);
    try testing.expectEqualStrings(bigValue("LIVE-6700-EBIG"), w12.string);
}
