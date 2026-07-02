// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// GAP warm-reopen P2 — cross-index checkpoint-counter RE-STAMP.
//
// Concern being fixed: every persisted derived-index snapshot embeds the
// manifest counter at its save time, and the load gate requires ALL FOUR
// gated snapshots (label / property-chain / edge / edge-exist) to equal
// manifest.counter. A full checkpoint that saves only the DIRTY snapshots
// (Lever B) therefore counter-invalidates the CLEAN ones — an edges-only
// session voided the whole warm-reopen win and forced an O(graph) rebuild on
// the next open even though the label/prop snapshots were semantically
// current the entire time.
//
// Fix under test: after a successful full checkpoint, every CLEAN gated
// snapshot gets its persisted counter cheaply RE-STAMPED (header-only write,
// payload untouched) to the new manifest.counter — gated on the engine
// KNOWING those snapshots are content-current (derived_snapshots_trusted).
//
// Covered here:
//   * edges-only session → label/prop restamped (2), next open LOADS all
//     indexes (derived + ordered + exact) — no rebuild;
//   * label-only session → dirty label SAVED (full rewrite), clean
//     prop/edge/exist RESTAMPED (3, and the big edge snapshot provably
//     changed by only the 12 header/trailer bytes — the cheap-restamp
//     proof), THEN the still-open engine keeps reading through the live
//     mmap base that was restamped in place (mapped-inode safety);
//   * torn restamp (crash window: counter landed, CRC did not) → loader
//     rejects → rebuild → correct data → next checkpoint heals;
//   * SAFETY GATE: a crash restart followed by a page-only session (derived
//     indexes never hydrated) must NOT restamp — blessing the crash-stale
//     snapshots would silently lose the WAL-tail mutations. The next open
//     must rebuild and serve the tail edge.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const test_support = gs.test_support;

const REL: u32 = 3;
const LABEL_A: u32 = 11;
const LABEL_B: u32 = 22;

fn ioT() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn readFileBytes(allocator: Allocator, path: []const u8) ![]u8 {
    const io = ioT();
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    const buf = try allocator.alloc(u8, @intCast(st.size));
    errdefer allocator.free(buf);
    const n = try f.readPositionalAll(io, buf, 0);
    try testing.expectEqual(buf.len, n);
    return buf;
}

/// Assert `path` changed ONLY in the counter bytes [8,16) and the trailing
/// `trailer_len` bytes — the on-disk shape of a cheap header restamp.
fn expectOnlyCounterAndTrailerChanged(before: []const u8, after: []const u8, trailer_len: usize) !void {
    try testing.expectEqual(before.len, after.len);
    try testing.expectEqualSlices(u8, before[0..8], after[0..8]);
    try testing.expectEqualSlices(
        u8,
        before[16 .. before.len - trailer_len],
        after[16 .. after.len - trailer_len],
    );
    try testing.expect(!std.mem.eql(u8, before[8..16], after[8..16]));
}

const Fixture = struct {
    nodes: [40]u64,
    edges: [40]u64,
};

/// 40 nodes (all LABEL_A, half LABEL_B, each with an int property "score")
/// fanned into a ring of 40 edges; plus one declared exact B+tree index and
/// one ordered index on (LABEL_A, "score").
fn populate(eng: *GraphEngine) !Fixture {
    var fx: Fixture = undefined;
    for (&fx.nodes, 0..) |*n, i| {
        n.* = try eng.allocNode();
        try eng.putNode(n.*, test_support.emptyNode(1));
        try eng.addLabel(n.*, LABEL_A);
        if (i % 2 == 0) try eng.addLabel(n.*, LABEL_B);
        var rec = (try eng.getNode(n.*)).?;
        rec.prop_head = try eng.putProperty(rec.prop_head, "score", .{ .int = @intCast(i) });
        try eng.putNode(n.*, rec);
    }
    for (&fx.edges, 0..) |*e, i| {
        e.* = try eng.addEdge(fx.nodes[i], fx.nodes[(i + 1) % fx.nodes.len], REL);
    }
    try eng.createPropertyIndex(LABEL_A, "score");
    try eng.createOrderedIndex(LABEL_A, "score");
    return fx;
}

fn verifyBase(eng: *GraphEngine, fx: *const Fixture) !void {
    const a_nodes = try eng.scanLabel(LABEL_A, testing.allocator);
    defer testing.allocator.free(a_nodes);
    try testing.expectEqual(fx.nodes.len, a_nodes.len);
    const b_nodes = try eng.scanLabel(LABEL_B, testing.allocator);
    defer testing.allocator.free(b_nodes);
    try testing.expectEqual(fx.nodes.len / 2, b_nodes.len);
    const rec = (try eng.getNode(fx.nodes[5])).?;
    const val = try eng.getProperty(rec.prop_head, "score", testing.allocator);
    try testing.expect(val != null);
    try testing.expectEqual(@as(i64, 5), val.?.int);
}

test "P2: edges-only session restamps clean label/prop; next open LOADS derived + ordered + exact (no rebuild)" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xE1} ** 16;
    const cfg = test_support.testConfig();

    var fx: Fixture = undefined;
    var new_edge: u64 = 0;
    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        fx = try populate(eng);
        try eng.checkpoint(); // all four saved at counter C
    }

    {
        // EDGES-ONLY session: the exact scenario from the P1 report's
        // concern (1). Before P2 this left label/prop counter-stale and the
        // next open rebuilt EVERYTHING.
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        new_edge = try eng.addEdge(fx.nodes[0], fx.nodes[20], REL);
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_loads);

        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_restamps);
        try eng.checkpoint();
        // label + prop were clean → restamped; edge + exist were dirty →
        // SAVED (never restamped).
        try testing.expectEqual(@as(u64, 2), eng.getMetrics().derived_index_restamps);
    }

    {
        // Clean reopen: every index loads from snapshot.
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};

        // Deferred build: counters are 0 until first access.
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_loads);
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_rebuilds);

        try verifyBase(eng, &fx);
        const e = (try eng.getEdge(new_edge)) orelse return error.EdgeNotFound;
        try testing.expectEqual(new_edge, e.edge_id);
        try testing.expectEqual(@as(usize, fx.edges.len + 1), eng.edgeIndexCount());

        // THE P2 ASSERTION: loaded, not rebuilt.
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_loads);
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_rebuilds);
        // Ordered index loaded counter-current (set at open).
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().ordered_index_loads);
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().ordered_index_rebuilds);
        // Exact B+tree index is live and answering.
        const hit = try eng.lookupPropertyIndex(LABEL_A, "score", .{ .int = 7 });
        try testing.expectEqual(fx.nodes[7], hit orelse return error.IndexMiss);
    }
}

test "P2: dirty label SAVED (never restamped); clean edge snapshot restamped by exactly 12 bytes; live base keeps serving" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xE2} ** 16;
    const cfg = test_support.testConfig();

    var fx: Fixture = undefined;
    var label_path: []u8 = undefined;
    var prop_path: []u8 = undefined;
    var edge_path: []u8 = undefined;
    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        fx = try populate(eng);
        try eng.checkpoint();
        label_path = try std.fmt.allocPrint(testing.allocator, "{s}/labels.idx", .{eng.graph_dir.path});
        prop_path = try std.fmt.allocPrint(testing.allocator, "{s}/props.idx", .{eng.graph_dir.path});
        edge_path = try std.fmt.allocPrint(testing.allocator, "{s}/edges.idx", .{eng.graph_dir.path});
    }
    defer testing.allocator.free(label_path);
    defer testing.allocator.free(prop_path);
    defer testing.allocator.free(edge_path);

    const label_before = try readFileBytes(testing.allocator, label_path);
    defer testing.allocator.free(label_before);
    const prop_before = try readFileBytes(testing.allocator, prop_path);
    defer testing.allocator.free(prop_before);
    const edge_before = try readFileBytes(testing.allocator, edge_path);
    defer testing.allocator.free(edge_before);

    {
        // LABEL-ONLY session on a live mmap-adopted base.
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};

        // Adopt the base and touch only edge 0 before the checkpoint.
        const e0 = (try eng.getEdge(fx.edges[0])) orelse return error.EdgeNotFound;
        try testing.expectEqual(fx.edges[0], e0.edge_id);

        try eng.addLabel(fx.nodes[1], LABEL_B); // label index DIRTY
        try eng.checkpoint();
        // prop + edge + exist clean → 3 restamps; label saved, not restamped.
        try testing.expectEqual(@as(u64, 3), eng.getMetrics().derived_index_restamps);

        // MAPPED-INODE SAFETY: the edge restamp wrote the very inode this
        // session's base has mmap'd. Keep reading EVERY edge through it —
        // blocks first-touched only now must still CRC-verify.
        for (fx.edges) |e| {
            const got = (try eng.getEdge(e)) orelse return error.EdgeNotFound;
            try testing.expectEqual(e, got.edge_id);
        }
        try testing.expectEqual(@as(usize, fx.edges.len), eng.edgeIndexCount());
    }

    // On-disk shapes: label fully rewritten (content changed — it MUST NOT
    // have been restamped); prop + edge changed by ONLY counter + trailer.
    const label_after = try readFileBytes(testing.allocator, label_path);
    defer testing.allocator.free(label_after);
    const prop_after = try readFileBytes(testing.allocator, prop_path);
    defer testing.allocator.free(prop_after);
    const edge_after = try readFileBytes(testing.allocator, edge_path);
    defer testing.allocator.free(edge_after);

    // Legacy container trailer = 4-byte whole-file CRC.
    try expectOnlyCounterAndTrailerChanged(prop_before, prop_after, 4);
    // Sorted container trailer = 4-byte meta-CRC.
    try expectOnlyCounterAndTrailerChanged(edge_before, edge_after, 4);
    // The dirty label snapshot was re-serialized: same-length-and-payload
    // would mean the new label never reached disk.
    try testing.expect(label_after.len != label_before.len or
        !std.mem.eql(u8, label_before, label_after));

    {
        // Clean reopen: loads, and the new label membership is durable.
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        const b_nodes = try eng.scanLabel(LABEL_B, testing.allocator);
        defer testing.allocator.free(b_nodes);
        try testing.expectEqual(fx.nodes.len / 2 + 1, b_nodes.len);
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_loads);
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_rebuilds);
    }
}

test "P2 crash mid-restamp: torn label counter (CRC not updated) → loader rejects → rebuild, then heals" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xE3} ** 16;
    const cfg = test_support.testConfig();

    var fx: Fixture = undefined;
    var label_path: []u8 = undefined;
    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        fx = try populate(eng);
        try eng.checkpoint();
        label_path = try std.fmt.allocPrint(testing.allocator, "{s}/labels.idx", .{eng.graph_dir.path});
    }
    defer testing.allocator.free(label_path);

    // Simulate the exact torn-restamp crash window: the 8 counter bytes
    // landed, the whole-file CRC trailer write did not.
    {
        const io = ioT();
        var f = try std.Io.Dir.cwd().openFile(io, label_path, .{ .mode = .read_write });
        defer f.close(io);
        var counter_buf: [8]u8 = undefined;
        _ = try f.readPositionalAll(io, &counter_buf, 8);
        const old = std.mem.readInt(u64, &counter_buf, .little);
        std.mem.writeInt(u64, &counter_buf, old + 1, .little);
        try f.writePositionalAll(io, &counter_buf, 8);
    }

    {
        // The torn file must be REJECTED (ChecksumMismatch → catch false →
        // rebuild) — never accepted with the torn counter.
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        try verifyBase(eng, &fx);
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_rebuilds);
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_loads);
        try eng.checkpoint(); // heal: rebuild marked all four dirty → saved
    }

    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        try verifyBase(eng, &fx);
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_loads);
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_rebuilds);
    }
}

test "P2 safety gate: crash restart + never-hydrated page-only session must NOT restamp (no blessing of crash-stale snapshots)" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xE4} ** 16;
    // sync_each_commit (default test config) so the post-checkpoint WAL tail
    // survives the simulated crash and is replayed by recovery.
    const cfg = test_support.testConfig();

    var fx: Fixture = undefined;
    var tail_edge: u64 = 0;
    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        fx = try populate(eng);
        try eng.checkpoint(); // snapshots current at counter C

        // Committed WAL-tail mutation AFTER the snapshot save…
        tail_edge = try eng.addEdge(fx.nodes[10], fx.nodes[30], REL);
        // …then CRASH (no checkpoint, no close).
        eng.deinit();
    }

    {
        // Recovery replayed the tail and bumped manifest.counter → the
        // on-disk snapshots are CRASH-STALE (missing tail_edge) behind CLEAN
        // dirty flags. A page-only session must not restamp them.
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};

        // Page-only write: no derived accessor runs, no hydration.
        var rec = (try eng.getNode(fx.nodes[0])).?;
        rec.flags = 0x5;
        try eng.putNode(fx.nodes[0], rec);

        try eng.checkpoint(); // FULL — bumps the counter again
        // THE SAFETY ASSERTION: zero restamps (derived_snapshots_trusted is
        // false — the snapshots were never counter-gate-checked this session).
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_restamps);
    }

    {
        // Next open must REBUILD (snapshots counter-stale, correctly so) and
        // the rebuilt index must contain the WAL-tail edge — this is exactly
        // the data an ungated restamp would have silently lost.
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        const e = (try eng.getEdge(tail_edge)) orelse return error.TailEdgeLost;
        try testing.expectEqual(tail_edge, e.edge_id);
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_rebuilds);
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_loads);
    }
}
