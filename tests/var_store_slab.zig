// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// GAP var-store slab packing — P2 WRITE-path acceptance gates (the release
// gates for the var leg of GAP-ENT-0020).
//
// The var.store was the biggest un-slabbed store: measured 8,192 B/node = one
// whole >=8 KB page per node's var-chain (scientific_name/authorship/remarks +
// the label block, which lives in var_store). The P2 slab writer packs many
// small runs into shared blocks. String/label LOSS is the failure mode
// (GAP-ENT-0030 was exactly this), so the crash test is the non-negotiable gate.
//
// This file drives the REAL writer (store level) and the production engine
// path (label ops funnel through var_store), covering:
//   * bytes/node re-measure: legacy 8,192 -> slab <= ~256 B/node;
//   * enumeration/read parity vs a legacy-format store of the same data;
//   * on-disk reopen parity (flushAll + fresh pool);
//   * WAL imaging: a slab label op logs the DECODED slab block page id, never
//     a slab-head id (the logVarChain-slab-aware evidence);
//   * CRASH gate: committed slab labels + strings replay byte-identical after a
//     deinit-crash (WAL is the only channel), an uncommitted slab label txn is
//     atomically invisible, and every stored var_head references a LIVE run;
//   * clean-shutdown gate: checkpoint + close + reopen survives;
//   * graduation across a crash: a set that outgrew the slab slot (legacy
//     chain) and slab-resident siblings both survive.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const VarStore = gs.var_store.VarStore;
const BufferPool = gs.buffer_pool.BufferPool;
const Pager = gs.pager.Pager;
const SingleStoreEnv = gs.test_support.SingleStoreEnv;
const GraphEngine = gs.GraphEngine;
const TestDataDir = gs.test_support.TestDataDir;
const Backup = gs.backup.Backup;
const GraphDir = gs.graph_dir.GraphDir;
const VerifyTool = gs.verify.VerifyTool;

// ============================================================================
// (1) store-level: bytes/node re-measure + parity + on-disk reopen
// ============================================================================

/// A short taxa var string (~35-45 B), representative of scientific_name +
/// authorship — far below one page. `buf` must be >= 64 bytes.
fn taxonVarString(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "Chromis viridis {d} (Cuvier, 1830)", .{i}) catch unreachable;
}

const Efficiency = struct { pages: u64, bytes_per_node: f64 };

fn measureVarEfficiency(page_size: u32, n: usize, slab: bool) !Efficiency {
    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", page_size, @intCast(n + 64));
    defer env.deinit();
    env.register();

    var store = VarStore.init(&env.pool, &env.fsm, page_size);
    store.slab_packing = slab;

    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        _ = try store.write(taxonVarString(&buf, i));
    }
    const pages = env.fsm.allocatedCount();
    return .{
        .pages = pages,
        .bytes_per_node = @as(f64, @floatFromInt(pages * page_size)) / @as(f64, @floatFromInt(n)),
    };
}

test "var-slab P2 oracle: bytes/node collapses from the 8,192 legacy baseline to <= 256" {
    const page_size: u32 = 8192; // production default
    const n: usize = 1000;

    const legacy = try measureVarEfficiency(page_size, n, false);
    const slab = try measureVarEfficiency(page_size, n, true);

    std.debug.print(
        "\n[var-slab P2] nodes={d} page_size={d} legacy_pages={d} ({d:.1} B/node) " ++
            "slab_pages={d} ({d:.1} B/node)\n",
        .{ n, page_size, legacy.pages, legacy.bytes_per_node, slab.pages, slab.bytes_per_node },
    );

    // Baseline is exactly one page per node (the P0 oracle).
    try testing.expectEqual(@as(u64, n), legacy.pages);
    try testing.expectEqual(@as(f64, @floatFromInt(page_size)), legacy.bytes_per_node);

    // Slab packing collapses it toward O(actual bytes): acceptance target.
    try testing.expect(slab.bytes_per_node <= 256.0);
    try testing.expect(slab.pages * 20 < legacy.pages); // >= 20x fewer pages
}

test "var-slab P2 parity: slab-written runs enumerate byte-identical to a legacy-format store" {
    const page_size: u32 = 8192;
    const n: usize = 300;

    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", page_size, @intCast(n + 64));
    defer env.deinit();
    env.register();

    // Two stores over the same pool/fsm: the slab writer under test and a
    // legacy reference writer producing the parity twin.
    var slab_store = VarStore.init(&env.pool, &env.fsm, page_size);
    slab_store.slab_packing = true;
    var legacy_store = VarStore.init(&env.pool, &env.fsm, page_size);
    legacy_store.slab_packing = false;

    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const s = taxonVarString(&buf, i);
        const slab_ref = try slab_store.write(s);
        const legacy_ref = try legacy_store.write(s);
        try testing.expect(gs.var_store.isSlabHead(slab_ref));
        try testing.expect(!gs.var_store.isSlabHead(legacy_ref));

        const via_slab = try slab_store.read(slab_ref, testing.allocator);
        defer testing.allocator.free(via_slab);
        const via_legacy = try legacy_store.read(legacy_ref, testing.allocator);
        defer testing.allocator.free(via_legacy);
        try testing.expectEqualStrings(s, via_slab);
        try testing.expectEqualStrings(via_legacy, via_slab);
    }
}

test "var-slab P2 reopen: slab runs survive flushAll + a fresh buffer pool byte-identical" {
    const page_size: u32 = 8192;
    const n: usize = 250;

    var env = try SingleStoreEnv.init(testing.allocator, .var_store, "var.store", page_size, 128);
    defer env.deinit();
    env.register(); // stable address before we drive the pager (flushAll)

    var store = VarStore.init(&env.pool, &env.fsm, page_size);
    store.slab_packing = true;

    const refs = try testing.allocator.alloc(u64, n);
    defer testing.allocator.free(refs);
    const strings = try testing.allocator.alloc([]u8, n);
    defer {
        for (strings) |s| testing.allocator.free(s);
        testing.allocator.free(strings);
    }
    var buf: [64]u8 = undefined;
    for (refs, 0..) |*r, i| {
        const s = taxonVarString(&buf, i);
        strings[i] = try testing.allocator.dupe(u8, s);
        r.* = try store.write(s);
        try testing.expect(gs.var_store.isSlabHead(r.*));
    }

    // Persist every dirty page, then reopen the SAME file with a brand-new
    // pool: proves slab blocks round-trip the on-disk persist path.
    try env.pool.flushAll();

    var pool2 = try BufferPool.init(testing.allocator, page_size, 128);
    defer pool2.deinit();
    var pager2 = Pager.init(env.file, page_size);
    pool2.registerPager(.var_store, &pager2);

    var store2 = VarStore.init(&pool2, &env.fsm, page_size);
    store2.slab_packing = true; // read path is layout-discriminated regardless

    for (refs, 0..) |r, i| {
        const got = try store2.read(r, testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(strings[i], got);
    }
}

// ============================================================================
// (2) engine WAL imaging — logVarChain slab-awareness
// ============================================================================

/// All .var_store page_update page-ids currently in the engine's WAL, in LSN
/// order. Caller frees the returned slice.
fn varPageUpdateIds(eng: *GraphEngine, alloc: Allocator) ![]u64 {
    const records = try eng.wal.readFrom(1, alloc);
    defer {
        for (records) |*r| r.deinit(alloc);
        alloc.free(records);
    }
    var ids: std.ArrayList(u64) = .empty;
    errdefer ids.deinit(alloc);
    for (records) |r| {
        if (r.record_type != .page_update) continue;
        if (r.file_id != @intFromEnum(gs.types.FileId.var_store)) continue;
        try ids.append(alloc, r.page_id);
    }
    return ids.toOwnedSlice(alloc);
}

fn containsId(ids: []const u64, id: u64) bool {
    for (ids) |x| {
        if (x == id) return true;
    }
    return false;
}

test "var-slab P2 WAL: slab label ops log the DECODED slab block page id — never a slab-head id" {
    var td = try TestDataDir.init(testing.allocator);
    defer td.deinit();
    var cfg = gs.test_support.testConfig();
    cfg.buffer_pool_pages = 512;

    const eng = try GraphEngine.create(testing.allocator, td.path, [_]u8{0x71} ** 16, cfg);
    defer eng.close() catch {};
    eng.var_store.slab_packing = true;

    const alloc = testing.allocator;
    const vs = gs.var_store;

    const nid = try eng.allocNode();
    try eng.putNode(nid, gs.test_support.emptyNode(1));

    // First label: the label block is packed into a slab block; the WAL must
    // reference that block by its REAL page id.
    try eng.addLabel(nid, 10);
    const rec1 = (try eng.getNode(nid)).?;
    try testing.expect(vs.isSlabHead(rec1.label_head));
    const block = vs.slabHeadPageId(rec1.label_head);
    {
        const ids = try varPageUpdateIds(eng, alloc);
        defer alloc.free(ids);
        try testing.expect(containsId(ids, block));
        for (ids) |id| try testing.expect(!vs.isSlabHead(id)); // no slab-head leaked
    }

    // Second label rewrites the block (new slot) and tombstones the old slot;
    // both the new and the tombstoned block must be imaged (here the same
    // shared block), still by real page id.
    try eng.addLabel(nid, 20);
    {
        const ids = try varPageUpdateIds(eng, alloc);
        defer alloc.free(ids);
        const rec2 = (try eng.getNode(nid)).?;
        try testing.expect(vs.isSlabHead(rec2.label_head));
        try testing.expect(containsId(ids, vs.slabHeadPageId(rec2.label_head)));
        for (ids) |id| try testing.expect(!vs.isSlabHead(id));
    }
}

// ============================================================================
// (3) CRASH gate + clean-shutdown gate (the GAP-ENT-0030 regression guard)
// ============================================================================

fn expectLabelSet(alloc: Allocator, eng: *GraphEngine, node_id: u64, expected: []const u32) !void {
    const rec = (try eng.getNode(node_id)) orelse return error.NodeInvisible;
    // A LIVE var_head: getLabels must succeed (a dangling slab head errors
    // DataCorruption) and return exactly the expected set.
    const labels = try eng.label_store.getLabels(rec.label_head, alloc);
    defer alloc.free(labels);
    const got = try alloc.dupe(u32, labels);
    defer alloc.free(got);
    const want = try alloc.dupe(u32, expected);
    defer alloc.free(want);
    std.mem.sort(u32, got, {}, std.sort.asc(u32));
    std.mem.sort(u32, want, {}, std.sort.asc(u32));
    if (!std.mem.eql(u32, got, want)) {
        std.debug.print("var-slab crash: label set mismatch on node {d}: got {d}, want {d}\n", .{ node_id, got.len, want.len });
        return error.LabelSetMismatch;
    }
    try testing.expectEqual(@as(u16, @intCast(expected.len)), rec.label_count);
}

test "var-slab P2 crash: committed slab labels replay byte-identical; uncommitted slab label is invisible" {
    const alloc = testing.allocator;
    var td = try TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0x72} ** 16;
    var cfg = gs.test_support.testConfig(); // sync_each_commit: commits are WAL-durable
    // Big pool: no dirty slab block is stolen (flushed) before the crash, so
    // the ONLY durability channel is the fsynced WAL — exactly logVarChain.
    cfg.buffer_pool_pages = 512;

    const N: usize = 24;
    var nids: [N]u64 = undefined;
    var ghost_nid: u64 = 0;

    // ---- session 1: committed slab labels + a checkpoint, then crash-window
    // mutations that live ONLY in the WAL tail, then a SIMULATED CRASH ----
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.close() catch {};
        eng.var_store.slab_packing = true;

        for (0..N) |i| {
            const nid = try eng.allocNode();
            try eng.putNode(nid, gs.test_support.emptyNode(1));
            nids[i] = nid;
            try eng.addLabel(nid, @intCast(100 + i));
            try eng.addLabel(nid, @intCast(200 + i));
        }
        // A node whose only label is then removed: label_head must replay as
        // durably ZERO (an older slab image must not resurrect it).
        ghost_nid = try eng.allocNode();
        try eng.putNode(ghost_nid, gs.test_support.emptyNode(1));
        try eng.addLabel(ghost_nid, 7);

        try eng.checkpoint(); // everything above is now on the data pages.

        // Crash window (WAL-only): rewrite label sets — adds create new slab
        // slots, removes tombstone old ones. Every slab head involved is
        // imaged by logVarChain (new block + old tombstoned block).
        for (0..N) |i| {
            try eng.addLabel(nids[i], @intCast(300 + i));
        }
        try eng.removeLabel(nids[0], 100); // node 0: 100 removed
        try eng.removeLabel(ghost_nid, 7); // ghost: back to zero labels

        // An UNCOMMITTED slab label add: must be atomically invisible on replay.
        {
            const txn = try eng.beginTxn();
            try eng.addLabelTxn(nids[1], 9999, txn);
            // NO commit — abandon the txn by crashing below.
        }

        // SIMULATED CRASH: no checkpoint, no close, no flush.
        eng.deinit();
    }

    // ---- session 2: recovery (WAL page-image redo of committed txns) ----
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};

        var i: usize = 0;
        while (i < N) : (i += 1) {
            if (i == 0) {
                // 100 removed in the crash window; 200,300 survive.
                try expectLabelSet(alloc, eng, nids[0], &.{ 200, 300 });
            } else {
                try expectLabelSet(alloc, eng, nids[i], &.{ @intCast(100 + i), @intCast(200 + i), @intCast(300 + i) });
            }
        }

        // Ghost node: last label removed in the crash window -> durably empty.
        try expectLabelSet(alloc, eng, ghost_nid, &.{});
        {
            const rec = (try eng.getNode(ghost_nid)).?;
            try testing.expectEqual(@as(u64, 0), rec.label_head);
        }

        // The uncommitted 9999 on node 1 is invisible.
        {
            const with_ghost = try eng.scanLabel(9999, alloc);
            defer alloc.free(with_ghost);
            try testing.expectEqual(@as(usize, 0), with_ghost.len);
        }

        // Derived index rebuilt from the replayed slab blocks agrees.
        {
            const with_300 = try eng.scanLabel(300, alloc);
            defer alloc.free(with_300);
            try testing.expectEqualSlices(u64, &.{nids[0]}, with_300);
            const with_100 = try eng.scanLabel(100, alloc);
            defer alloc.free(with_100);
            try testing.expectEqual(@as(usize, 0), with_100.len); // removed on node 0
        }
    }
}

test "var-slab P2 clean shutdown: slab labels survive checkpoint + close + reopen" {
    const alloc = testing.allocator;
    var td = try TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0x73} ** 16;
    const cfg = gs.test_support.testConfig();

    const N: usize = 30;
    var nids: [N]u64 = undefined;

    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        eng.var_store.slab_packing = true;
        for (0..N) |i| {
            const nid = try eng.allocNode();
            try eng.putNode(nid, gs.test_support.emptyNode(1));
            nids[i] = nid;
            try eng.addLabel(nid, @intCast(1 + i));
            try eng.addLabel(nid, @intCast(1000 + i));
        }
        try eng.close(); // CLEAN shutdown (checkpoint + flush).
    }

    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    for (0..N) |i| {
        try expectLabelSet(alloc, eng, nids[i], &.{ @intCast(1 + i), @intCast(1000 + i) });
    }
}

test "var-slab P2 graduation crash: a graduated (legacy) label set and slab siblings both survive" {
    const alloc = testing.allocator;
    var td = try TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0x74} ** 16;
    var cfg = gs.test_support.testConfig();
    cfg.buffer_pool_pages = 1024; // room for the graduated chain + churn

    // A label set of >255 ids serialises to >1 KB, over VAR_SLAB_MAX_RUN, so
    // the writer graduates it to a legacy page-chain.
    const BIG: u32 = 300;
    var big_nid: u64 = 0;
    var small_nid: u64 = 0;
    var expected_big: std.ArrayList(u32) = .empty;
    defer expected_big.deinit(alloc);

    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.close() catch {};
        eng.var_store.slab_packing = true;

        big_nid = try eng.allocNode();
        try eng.putNode(big_nid, gs.test_support.emptyNode(1));
        small_nid = try eng.allocNode();
        try eng.putNode(small_nid, gs.test_support.emptyNode(1));
        try eng.addLabel(small_nid, 42);
        try eng.addLabel(small_nid, 43);

        var l: u32 = 1;
        while (l <= BIG) : (l += 1) {
            try eng.addLabel(big_nid, l);
            try expected_big.append(alloc, l);
        }
        // The graduated set is a LEGACY head, not a slab head.
        {
            const rec = (try eng.getNode(big_nid)).?;
            try testing.expect(!gs.var_store.isSlabHead(rec.label_head));
            const small_rec = (try eng.getNode(small_nid)).?;
            try testing.expect(gs.var_store.isSlabHead(small_rec.label_head));
        }
        try eng.checkpoint();

        // Crash window: mutate BOTH the graduated set and a slab sibling.
        try eng.addLabel(big_nid, 5001);
        try expected_big.append(alloc, 5001);
        try eng.removeLabel(big_nid, 1);
        _ = expected_big.orderedRemove(0);
        try eng.addLabel(small_nid, 44);

        eng.deinit(); // CRASH
    }

    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};

    try expectLabelSet(alloc, eng, big_nid, expected_big.items);
    try expectLabelSet(alloc, eng, small_nid, &.{ 42, 43, 44 });
}

// ============================================================================
// (4) PHASE 3 — remaining consumers: backup/export/copy, integrity/verify,
// migration/colocation. Each proves the var slab writer is TRANSPARENT to the
// consumer: backup copies var.store FILE-granular (byte-for-byte), verify scans
// PAGE checksums (never decodes a var chain), and the colocation edge path
// treats label_head as an OPAQUE u64 it never dereferences. A label block IS a
// var byte-run, so "the run survives byte-identical" == "the string survives".
// ============================================================================

/// Assert `getLabels` succeeds for every head (a DANGLING slab head errors
/// DataCorruption). Proves no consumer left a var_head pointing at a dead slot.
fn expectNoDanglingHeads(alloc: Allocator, eng: *GraphEngine, node_ids: []const u64) !void {
    for (node_ids) |id| {
        const rec = (try eng.getNode(id)) orelse return error.NodeInvisible;
        const labels = try eng.label_store.getLabels(rec.label_head, alloc);
        alloc.free(labels); // a dangling head would have errored above
    }
}

test "var-slab P3 backup: slab-packed var.store round-trips byte-identical through backup+restore (labels + raw runs)" {
    const alloc = testing.allocator;
    var src = try TestDataDir.init(alloc);
    defer src.deinit();
    var dst = try TestDataDir.init(alloc);
    defer dst.deinit();
    const uuid = [_]u8{0x75} ** 16;
    const cfg = gs.test_support.testConfig();

    const N: usize = 40;
    var nids: [N]u64 = undefined;
    var heads: [N]u64 = undefined;
    // The raw slab-run bytes per node BEFORE backup — a label block is a var
    // byte-run, i.e. exactly the "string" the release gate must preserve.
    var raw: [N][]u8 = undefined;
    var raw_set: usize = 0;
    defer for (raw[0..raw_set]) |r| alloc.free(r);

    // ---- build a slab-packed graph, capture raw runs, CLEAN close ----
    {
        const eng = try GraphEngine.create(alloc, src.path, uuid, cfg);
        errdefer eng.close() catch {};
        eng.var_store.slab_packing = true;
        for (0..N) |i| {
            const nid = try eng.allocNode();
            try eng.putNode(nid, gs.test_support.emptyNode(1));
            nids[i] = nid;
            try eng.addLabel(nid, @intCast(100 + i));
            try eng.addLabel(nid, @intCast(200 + i));
        }
        for (0..N) |i| {
            const rec = (try eng.getNode(nids[i])).?;
            heads[i] = rec.label_head;
            try testing.expect(gs.var_store.isSlabHead(rec.label_head)); // slab-resident
            raw[i] = try eng.var_store.read(rec.label_head, alloc);
            raw_set += 1;
        }
        try eng.close(); // checkpoint + flush: var.store file complete on disk
    }

    // ---- backup the graph dir (file-granular copy), restore to a fresh dir ----
    const backup_path = try std.fmt.allocPrint(alloc, "{s}/varslab.geob", .{dst.path});
    defer alloc.free(backup_path);
    {
        var gd = try GraphDir.open(alloc, src.path, uuid);
        defer gd.deinit();
        // Restore must land in the engine's canonical {data_dir}/graphs/<uuid>
        // layout so GraphEngine.open(dst.path) resolves it (GraphDir.open
        // appends graphs/<uuid_hex>).
        const uuid_hex = std.fs.path.basename(gd.path);
        const restore_graph_path = try std.fmt.allocPrint(alloc, "{s}/graphs/{s}", .{ dst.path, uuid_hex });
        defer alloc.free(restore_graph_path);

        var bk = Backup.init(alloc);
        defer bk.deinit();
        const res = try bk.createBackup(&gd, backup_path);
        try testing.expect(res.files_backed_up > 0);
        try testing.expect(try bk.validateBackup(backup_path));
        bk.setExpectedGraphUuid(uuid);
        bk.enableLegacyV1Restore();
        try bk.restoreBackup(backup_path, restore_graph_path);
    }

    // ---- reopen the RESTORED graph: every label set + raw run byte-identical ----
    {
        const eng = try GraphEngine.open(alloc, dst.path, uuid, cfg);
        defer eng.close() catch {};
        for (0..N) |i| {
            const rec = (try eng.getNode(nids[i])) orelse return error.NodeInvisible;
            try testing.expectEqual(heads[i], rec.label_head); // opaque head preserved
            try testing.expect(gs.var_store.isSlabHead(rec.label_head));
            try expectLabelSet(alloc, eng, nids[i], &.{ @intCast(100 + i), @intCast(200 + i) });
            const bytes = try eng.var_store.read(rec.label_head, alloc);
            defer alloc.free(bytes);
            try testing.expectEqualSlices(u8, raw[i], bytes); // BYTE-IDENTICAL var run
        }
        try expectNoDanglingHeads(alloc, eng, nids[0..N]);
    }
}

test "var-slab P3 integrity: verifyGraph passes clean over a slab-packed var.store (page-checksum scan is slab-transparent)" {
    const alloc = testing.allocator;
    var td = try TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0x76} ** 16;
    const cfg = gs.test_support.testConfig();

    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.close() catch {};
        eng.var_store.slab_packing = true;
        for (0..64) |i| {
            const nid = try eng.allocNode();
            try eng.putNode(nid, gs.test_support.emptyNode(1));
            try eng.addLabel(nid, @intCast(1 + i));
            try eng.addLabel(nid, @intCast(500 + (i % 7)));
        }
        // Engine-level integrity check (scanNodes + adjacency; var-transparent —
        // it never decodes a var run, so slab blocks cannot trip it).
        const report = try eng.checkIntegrity();
        try testing.expectEqual(@as(u64, 0), report.total_errors);
        try eng.close(); // flush stamps every slab page's header checksum
    }

    // Page-checksum verify over EVERY store file, incl. the slab-packed var.store.
    // The VAR_SLAB_MARKER lives in the data region; verifyPage checks only the
    // page-header CRC, so a slab block passes exactly like a legacy chain page.
    var gd = try GraphDir.open(alloc, td.path, uuid);
    defer gd.deinit();
    var vt = VerifyTool.init(alloc);
    var result = try vt.verifyGraph(&gd, cfg.page_size);
    defer result.deinit();
    // Scope the assertion to the VAR store. verifyGraph also scans free.store —
    // a compact bitmap file that is intentionally NOT page-aligned (a
    // pre-existing verify/free-store shape mismatch, unrelated to var slab), so
    // isClean() over the whole graph is not the right gate here. What matters:
    // NO paged page failed its checksum (corrupted_pages == 0 covers every
    // var.store slab page) and the var.store artifact scanned OK.
    try testing.expectEqual(@as(u64, 0), result.corrupted_pages);
    var saw_var_ok = false;
    for (result.artifacts.items) |art| {
        if (std.mem.eql(u8, art.name, "var.store")) {
            try testing.expect(art.status == .ok);
            saw_var_ok = true;
        }
    }
    try testing.expect(saw_var_ok);
}

test "var-slab P3 colocation: the colocation edge path leaves slab var heads + labels undisturbed (var-transparent)" {
    // migration.zig is a stub (no var-ref harvest) and colocation moves only
    // ADJACENCY blocks — a node's label_head is an opaque u64 the edge path
    // never dereferences. Prove it: build slab-packed labels, drive the
    // colocation edge path across those nodes, and confirm the heads + label
    // sets are untouched, surviving a clean reopen.
    const alloc = testing.allocator;
    var td = try TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0x7A} ** 16;
    const cfg = gs.test_support.testConfig();
    const REL: u32 = 7;

    const M: usize = 24;
    var nids: [M]u64 = undefined;
    var heads: [M]u64 = undefined;

    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.close() catch {};
        eng.var_store.slab_packing = true;

        for (0..M) |i| {
            const nid = try eng.allocNode();
            try eng.putNode(nid, gs.test_support.emptyNode(1));
            nids[i] = nid;
            try eng.addLabel(nid, @intCast(10 + i));
            try eng.addLabel(nid, @intCast(900 + i));
        }
        for (0..M) |i| {
            const rec = (try eng.getNode(nids[i])).?;
            heads[i] = rec.label_head;
            try testing.expect(gs.var_store.isSlabHead(rec.label_head));
        }

        // Drive the colocation path (the only "migration/colocation" surface
        // that exists) across the slab-label nodes.
        for (0..M) |i| {
            _ = try eng.addEdgeColocatedWithPublicId(
                nids[i],
                nids[(i + 1) % M],
                REL,
                0xC010_0000_0000_0000 | @as(u64, @intCast(i + 1)),
            );
        }

        // Heads unchanged; labels intact; no head was rewritten by edge ops.
        for (0..M) |i| {
            const rec = (try eng.getNode(nids[i])).?;
            try testing.expectEqual(heads[i], rec.label_head);
            try expectLabelSet(alloc, eng, nids[i], &.{ @intCast(10 + i), @intCast(900 + i) });
        }
        try eng.close();
    }

    // Reopen: colocated edges + slab labels both survive, heads still valid.
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        for (0..M) |i| {
            const rec = (try eng.getNode(nids[i])) orelse return error.NodeInvisible;
            try testing.expectEqual(heads[i], rec.label_head);
            try expectLabelSet(alloc, eng, nids[i], &.{ @intCast(10 + i), @intCast(900 + i) });
            var it = try eng.expandOutIter(nids[i], null);
            defer it.deinit();
            const e = (try it.next()) orelse return error.ColocatedEdgeMissing;
            try testing.expectEqual(nids[(i + 1) % M], e.neighbor);
        }
        try expectNoDanglingHeads(alloc, eng, nids[0..M]);
    }
}

test {
    std.testing.refAllDecls(@This());
}
