// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6461: repair adjacency entries lost to the pre-0.4.12 TDE page tail.
//
// graph_storage <= 0.4.11 wrote the AES-GCM tag over the last 16 bytes of
// every encrypted page. 0.4.12 (SONNY-6441) stopped that and reads those bytes
// of an old page back as zero, but what they held is gone from the old page.
// For adjacency chains that is the last entry of a full chain block, for some
// formats and page sizes (edge.legacyTailLoss): a v1 block at 8 KiB loses the
// rel_type and prop_head of entry 338; a v3 block at 4 KiB loses the high half
// of entry 100's prop_head. The same edge is also stored in the other
// direction's chain, where it almost never sits in a tail slot.
//
// Each scenario builds a store with the library's writers, rewrites every page
// on disk in the old envelope exactly as an affected binary stored it (the tag
// over the body tail, flag clear; `PageEncryption.encryptPage` is that
// writer), proves the loss is visible after reopening, runs
// `GraphEngine.repairAdjTailEntries`, and checks the entries, the edge
// properties behind them and the derived edge index — also after a reopen.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const GraphConfig = gs.GraphConfig;
const EdgeEntry = gs.edge.EdgeEntry;
const test_support = gs.test_support;

const io = std.Io.Threaded.global_single_threaded.io();

const KEY: [32]u8 = [_]u8{0x61} ** 32;
const PAGE_HEADER_SIZE = gs.page.PAGE_HEADER_SIZE;

const paged_files = [_]gs.FileId{ .nodes, .adj_out, .adj_in, .props, .var_store, .in_idx, .in_dir };

fn config(page_size: u32, slab: bool) GraphConfig {
    return .{
        .page_size = page_size,
        .buffer_pool_pages = 256,
        .buffer_pool_auto_size = false,
        .encryption_key = KEY,
        .data_dir = "data",
        .adjacency_slab_packing = slab,
        .edge_prop_slab_packing = slab,
    };
}

/// Rewrite every written page of the store in the envelope graph_storage
/// <= 0.4.11 wrote: the page decrypted by the current reader, re-encrypted
/// with the tag over its last TAG_SIZE body bytes and the header-tag flag
/// clear. The bytes under the tag are gone, as they were on an old store.
fn downgradeToLegacyEnvelope(alloc: Allocator, graph_path: []const u8, page_size: u32) !u64 {
    const frame = try alloc.alloc(u8, page_size);
    defer alloc.free(frame);
    const raw = try alloc.alloc(u8, page_size);
    defer alloc.free(raw);
    var rewritten: u64 = 0;
    for (paged_files) |fid| {
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ graph_path, gs.file_manager.FILE_NAMES[@intFromEnum(fid)] });
        defer alloc.free(path);
        const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };
        defer file.close(io);
        var pager = gs.pager.Pager.init(file, page_size);
        pager.encryption = gs.encryption.PageEncryption.init(KEY);
        pager.file_id = fid;
        const pages = (try file.length(io)) / page_size;
        var pid: u64 = 0;
        while (pid < pages) : (pid += 1) {
            _ = try file.readPositionalAll(io, raw, pid * page_size);
            if (std.mem.allEqual(u8, raw, 0)) continue;
            try pager.readPage(pid, frame);
            frame[gs.page.FLAGS_OFFSET] &= ~gs.page.FLAG_HEADER_TAG;
            const wc = gs.page.readWriteCount(frame);
            pager.encryption.?.encryptPage(frame, pid, @intFromEnum(fid), wc);
            try file.writePositionalAll(io, frame, pid * page_size);
            rewritten += 1;
        }
    }
    return rewritten;
}

fn graphPath(alloc: Allocator, eng: *GraphEngine) ![]u8 {
    return alloc.dupe(u8, eng.graph_dir.path);
}

const Want = struct { src: u64, dst: u64, edge_id: u64, rel_type: u32, prop_head: u64, w: i64 };

/// Every expected edge is present, once, with its rel_type and prop_head in
/// the outgoing chain AND the co-located incoming chain, and its property
/// reads back through the edge index. Returns the number of wrong entries.
fn countWrong(alloc: Allocator, eng: *GraphEngine, want: []const Want, check_props: bool) !usize {
    var wrong: usize = 0;
    for (want) |w| {
        var found_out = false;
        var it = try eng.expandOutIter(w.src, null);
        defer it.deinit();
        while (try it.next()) |e| {
            if (e.edge_id != w.edge_id) continue;
            found_out = e.neighbor == w.dst and e.rel_type == w.rel_type and e.prop_head == w.prop_head;
            if (!found_out) std.debug.print("adj_out edge {d}: rel_type {d} prop_head {x}, want {d} {x}\n", .{ w.edge_id, e.rel_type, e.prop_head, w.rel_type, w.prop_head });
        }
        var found_in = false;
        var in_it = try eng.expandInRemoteIter(w.dst, null);
        defer in_it.deinit();
        while (try in_it.next()) |e| {
            if (e.edge_id != w.edge_id) continue;
            found_in = e.neighbor == w.src and e.rel_type == w.rel_type and e.prop_head == w.prop_head;
            if (!found_in) std.debug.print("in_idx edge {d}: rel_type {d} prop_head {x}, want {d} {x}\n", .{ w.edge_id, e.rel_type, e.prop_head, w.rel_type, w.prop_head });
        }
        var ok = found_out and found_in;
        if (ok and check_props) {
            const idx = (try eng.getEdge(w.edge_id)) orelse return error.EdgeIndexMissing;
            ok = idx.rel_type == w.rel_type and idx.prop_head == w.prop_head;
            const v = try eng.getEdgeProperty(w.src, w.edge_id, "w", alloc);
            ok = ok and v != null and v.?.int == w.w;
        }
        if (!ok) wrong += 1;
    }
    return wrong;
}

fn recordWant(eng: *GraphEngine, src: u64, dst: u64, edge_id: u64, w: i64, list: *std.ArrayList(Want), alloc: Allocator) !void {
    const e = (try eng.getEdge(edge_id)).?;
    try list.append(alloc, .{ .src = src, .dst = dst, .edge_id = edge_id, .rel_type = e.rel_type, .prop_head = e.prop_head, .w = w });
}

fn newNode(eng: *GraphEngine) !u64 {
    const id = try eng.allocNode();
    try eng.putNode(id, test_support.emptyNode(1));
    return id;
}

test "SONNY-6461: 4 KiB v3 chain blocks — lost prop_head high halves are restored from the mirror, both directions" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0x71} ** 16;
    const cfg = config(4096, true);

    var want: std.ArrayList(Want) = .empty;
    defer want.deinit(alloc);
    var path: []u8 = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        path = try graphPath(alloc, eng);
        // A fan-out source (outgoing v3 blocks of 101, entry 100 in the tail;
        // each destination's incoming chain is a one-entry slab run) and a
        // fan-in hub (incoming v3 blocks full; each source's outgoing chain is
        // a slab run). Every edge carries a slab-packed property, so its
        // prop_head has bit 63 set: the high half is the lost one. Node ids
        // stay below 506: in_dir heads 506/507 of a 4 KiB page are in the
        // tail too, and re-attaching those is migrateColocateInEdges' job.
        const src = try newNode(eng);
        const hub = try newNode(eng);
        var k: i64 = 0;
        for (0..250) |_| {
            const d = try newNode(eng);
            const eid = try eng.addEdgeColocatedWithPublicId(src, d, 9, d + 1);
            try eng.setEdgeProperty(src, d, eid, "w", .{ .int = k });
            try recordWant(eng, src, d, eid, k, &want, alloc);
            k += 1;
        }
        for (0..150) |_| {
            const s = try newNode(eng);
            const eid = try eng.addEdgeColocatedWithPublicId(s, hub, 11, s + 1);
            try eng.setEdgeProperty(s, hub, eid, "w", .{ .int = k });
            try recordWant(eng, s, hub, eid, k, &want, alloc);
            k += 1;
        }
        for (want.items) |w| try testing.expect(w.prop_head >> 63 == 1);
        try testing.expectEqual(@as(usize, 0), try countWrong(alloc, eng, want.items, true));
        try eng.checkpoint();
    }
    defer alloc.free(path);
    try testing.expect(try downgradeToLegacyEnvelope(alloc, path, 4096) > 0);

    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        // The loss is visible: one outgoing entry per full block of the
        // fan-out and one incoming entry per full block of the hub lost the
        // high half of its prop_head.
        // Here: the fan-out's two full blocks and the hub's one.
        const before = try countWrong(alloc, eng, want.items, false);
        try testing.expectEqual(@as(usize, 3), before);

        var report = try eng.repairAdjTailEntries(alloc);
        defer report.deinit(alloc);
        try testing.expect(report.encrypted);
        try testing.expectEqual(@as(u64, before), report.repaired);
        try testing.expectEqual(@as(usize, 0), report.unrepairable.items.len);
        try testing.expectEqual(report.examined, report.repaired + report.consistent);
        try testing.expectEqual(@as(usize, 0), try countWrong(alloc, eng, want.items, true));

        // Idempotent.
        var again = try eng.repairAdjTailEntries(alloc);
        defer again.deinit(alloc);
        try testing.expectEqual(@as(u64, 0), again.repaired);
        try testing.expectEqual(report.examined, again.consistent);
        try eng.checkpoint();
    }
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try testing.expectEqual(@as(usize, 0), try countWrong(alloc, eng, want.items, true));
    }
}

test "SONNY-6461: 8 KiB v1 chain blocks — lost rel_type and prop_head of entry 338 are restored" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0x72} ** 16;
    // A pre-public-id store: no slab packing, narrow (u32) edge prop heads.
    const cfg = config(8192, false);
    const v1_cap = gs.edge.entriesPerBlock(8192, gs.edge.ENTRY_FORMAT_V1);
    try testing.expectEqual(@as(u32, 339), v1_cap);

    var want: std.ArrayList(Want) = .empty;
    defer want.deinit(alloc);
    var path: []u8 = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        path = try graphPath(alloc, eng);
        const src = try newNode(eng);
        // An empty v1 chain block as the source's head, as a pre-P2 store
        // left it; the library's writer appends id-less edges into a v1 head
        // in place, so it fills to all 339 v1 slots.
        {
            const page = try eng.free_space_adj_out.allocPage();
            const frame = try eng.buffer_pool.pinNew(.adj_out, page);
            const bh = gs.edge.EdgeBlockHeader{ .next_block = 0, .count = 0, .kind = 0, .entry_format = gs.edge.ENTRY_FORMAT_V1, .payload_size = 0, .checksum = 0 };
            @memcpy(frame.dataSlice()[PAGE_HEADER_SIZE..][0..16], std.mem.asBytes(&bh));
            eng.buffer_pool.unpin(eng.buffer_pool.frameIndex(frame), true);
            const txn = try eng.beginTxn();
            var rec = (try eng.getNode(src)).?;
            rec.out_head = page;
            try eng.putNodeTxn(src, rec, txn);
            try eng.logPagePublic(txn, .adj_out, page);
            try eng.commitTxn(txn);
        }
        var k: i64 = 0;
        for (0..v1_cap) |_| {
            const d = try newNode(eng);
            const eid = try eng.addEdgeColocated(src, d, 7);
            try eng.setEdgeProperty(src, d, eid, "w", .{ .int = k });
            try recordWant(eng, src, d, eid, k, &want, alloc);
            k += 1;
        }
        const rec = (try eng.getNode(src)).?;
        const raw = try eng.buffer_pool.pin(.adj_out, rec.out_head);
        const bh = std.mem.bytesToValue(gs.edge.EdgeBlockHeader, raw.dataSlice()[PAGE_HEADER_SIZE..][0..16]);
        eng.buffer_pool.unpin(eng.buffer_pool.frameIndex(raw), false);
        try testing.expectEqual(gs.edge.ENTRY_FORMAT_V1, bh.entry_format);
        try testing.expectEqual(@as(u16, 339), bh.count);
        for (want.items) |w| try testing.expect(w.prop_head != 0 and w.prop_head >> 32 == 0);
        try eng.checkpoint();
    }
    defer alloc.free(path);
    try testing.expect(try downgradeToLegacyEnvelope(alloc, path, 8192) > 0);

    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        // Entry 338 reads back with rel_type 0 and prop_head 0: a typed
        // expand misses it.
        try testing.expectEqual(@as(usize, 1), try countWrong(alloc, eng, want.items, false));
        const typed = try eng.expandOut(want.items[0].src, 7, alloc);
        try testing.expectEqual(@as(usize, 338), typed.len);
        alloc.free(typed);

        var report = try eng.repairAdjTailEntries(alloc);
        defer report.deinit(alloc);
        try testing.expectEqual(@as(u64, 1), report.examined);
        try testing.expectEqual(@as(u64, 1), report.repaired);
        try testing.expectEqual(@as(usize, 0), report.unrepairable.items.len);
        try testing.expectEqual(@as(usize, 0), try countWrong(alloc, eng, want.items, true));
        const typed_after = try eng.expandOut(want.items[0].src, 7, alloc);
        try testing.expectEqual(@as(usize, 339), typed_after.len);
        alloc.free(typed_after);
        // The derived existence index follows the repaired rel_type.
        var buf: [4]u64 = undefined;
        const last = want.items[want.items.len - 1];
        try testing.expectEqualSlices(u64, &.{last.edge_id}, try eng.probeEdge(last.src, 7, last.dst, &buf));
        // Crash: no checkpoint, no close. The repair must come back from the
        // WAL, derived indexes included.
        eng.deinit();
    }
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try testing.expectEqual(@as(usize, 0), try countWrong(alloc, eng, want.items, true));
        var buf: [4]u64 = undefined;
        const last = want.items[want.items.len - 1];
        try testing.expectEqualSlices(u64, &.{last.edge_id}, try eng.probeEdge(last.src, 7, last.dst, &buf));
    }
}

test "SONNY-6461: an entry whose mirror lost the same bytes is reported, never guessed" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0x73} ** 16;
    const cfg = config(4096, true);

    var want: std.ArrayList(Want) = .empty;
    defer want.deinit(alloc);
    var path: []u8 = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        path = try graphPath(alloc, eng);
        // 101 parallel edges a -> b: the outgoing and the incoming chain
        // receive the same appends, so the same edge ends up in the tail slot
        // of both full blocks.
        const a = try newNode(eng);
        const b = try newNode(eng);
        for (0..101) |i| {
            const eid = try eng.addEdgeColocatedWithPublicId(a, b, 5, 1000 + i);
            try eng.setEdgeProperty(a, b, eid, "w", .{ .int = @intCast(i) });
            try recordWant(eng, a, b, eid, @intCast(i), &want, alloc);
        }
        try eng.checkpoint();
    }
    defer alloc.free(path);
    _ = try downgradeToLegacyEnvelope(alloc, path, 4096);

    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    try testing.expectEqual(@as(usize, 1), try countWrong(alloc, eng, want.items, false));
    var report = try eng.repairAdjTailEntries(alloc);
    defer report.deinit(alloc);
    try testing.expectEqual(@as(u64, 2), report.examined);
    try testing.expectEqual(@as(u64, 0), report.repaired);
    try testing.expectEqual(@as(usize, 2), report.unrepairable.items.len);
    var files = [_]bool{ false, false };
    for (report.unrepairable.items) |is| {
        try testing.expectEqual(gs.engine.AdjTailIssue.Reason.mirror_in_tail, is.reason);
        try testing.expect(is.edge_id == report.unrepairable.items[0].edge_id);
        if (is.file == .adj_out) files[0] = true;
        if (is.file == .in_idx) files[1] = true;
    }
    try testing.expect(files[0] and files[1]);
    // Nothing was written: the entry still reads as damaged.
    try testing.expectEqual(@as(usize, 1), try countWrong(alloc, eng, want.items, false));
}

test "SONNY-6461: a plaintext store is never examined" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    var cfg = config(4096, true);
    cfg.encryption_key = null;
    const eng = try GraphEngine.create(alloc, td.path, [_]u8{0x74} ** 16, cfg);
    defer eng.close() catch {};
    var report = try eng.repairAdjTailEntries(alloc);
    defer report.deinit(alloc);
    try testing.expect(!report.encrypted);
    try testing.expectEqual(@as(u64, 0), report.examined);
}

test "SONNY-6461: legacyTailLoss names the lost slot and bytes for every page size" {
    const E = gs.edge;
    const Case = struct { ps: u32, fmt: u8, want: ?E.LegacyTailLoss };
    const cases = [_]Case{
        .{ .ps = 4096, .fmt = E.ENTRY_FORMAT_V1, .want = null },
        .{ .ps = 4096, .fmt = E.ENTRY_FORMAT_V2, .want = null },
        .{ .ps = 4096, .fmt = E.ENTRY_FORMAT_V3, .want = .{ .slot = 100, .lost_from = 32 } },
        .{ .ps = 8192, .fmt = E.ENTRY_FORMAT_V1, .want = .{ .slot = 338, .lost_from = 16 } },
        .{ .ps = 8192, .fmt = E.ENTRY_FORMAT_V2, .want = null },
        .{ .ps = 8192, .fmt = E.ENTRY_FORMAT_V3, .want = null },
        .{ .ps = 16384, .fmt = E.ENTRY_FORMAT_V1, .want = null },
        .{ .ps = 16384, .fmt = E.ENTRY_FORMAT_V2, .want = null },
        .{ .ps = 16384, .fmt = E.ENTRY_FORMAT_V3, .want = null },
        .{ .ps = 32768, .fmt = E.ENTRY_FORMAT_V1, .want = .{ .slot = 1362, .lost_from = 16 } },
        .{ .ps = 32768, .fmt = E.ENTRY_FORMAT_V3, .want = .{ .slot = 817, .lost_from = 24 } },
        .{ .ps = 65536, .fmt = E.ENTRY_FORMAT_V1, .want = null },
        .{ .ps = 65536, .fmt = E.ENTRY_FORMAT_V3, .want = .{ .slot = 1636, .lost_from = 32 } },
        .{ .ps = 8192, .fmt = E.ENTRY_FORMAT_SLAB, .want = null },
        .{ .ps = 4096, .fmt = E.ENTRY_FORMAT_SLAB_V3, .want = null },
    };
    for (cases) |c| try testing.expectEqual(c.want, E.legacyTailLoss(c.ps, c.fmt));
}
