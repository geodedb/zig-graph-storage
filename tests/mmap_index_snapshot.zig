// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// GAP warm-reopen P1 — engine-lifecycle tests for the mmap-adopted edge-index
// snapshots (GSEIDX4 / GSXIDX2, sorted_index_snapshot container):
//
//   * clean reopen mmap-ADOPTS (metrics: load, not rebuild) and serves exact
//     edges + MERGE-dedup probes off the mapped base;
//   * post-reopen mutations (adds, deletes, prop-head updates) overlay the
//     base and the next FULL checkpoint serializes the MERGED view, which the
//     following reopen adopts again — multi-generation correctness;
//   * a NEVER-mutated mmap-backed index persists NOTHING new (dirty-flag gate
//     intact: snapshot files byte-identical across a read-only session);
//   * crash with the mmap base active → counter gate forces a clean REBUILD
//     with the exact pre-crash committed state;
//   * truncated / header-corrupt snapshot → clean version/integrity reject →
//     rebuild; payload corruption → LAZY error.ChecksumMismatch at first
//     access of the affected block (the documented failure-model change);
//   * BENCH: 1M-edge snapshot load — legacy whole-file-read + hashmap build
//     vs mmap-adopt (+ random probes), timings printed.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const test_support = gs.test_support;
const sorted = gs.sorted_index_snapshot;
const edge_index_map = gs.edge_index_map;

const REL: u32 = 7;

fn ioT() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Monotonic ns (`.awake` clock — immune to wall-clock jumps); Zig 0.16
/// removed std.time.Timer, this mirrors tests/buffer_pool_pin_scaling.zig.
fn nowNs() i96 {
    return std.Io.Clock.Timestamp.now(ioT(), .awake).raw.nanoseconds;
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

fn pid(i: usize) u64 {
    return 0xF00D_0000_0000_0000 | @as(u64, @intCast(i + 1));
}

const Fixture = struct {
    nodes: [6]u64,
    edges: [24]u64,
};

/// 6 nodes; 24 edges fanned out of node[0] with inline public ids.
fn populate(eng: *GraphEngine) !Fixture {
    var fx: Fixture = undefined;
    for (&fx.nodes) |*n| {
        n.* = try eng.allocNode();
        try eng.putNode(n.*, test_support.emptyNode(1));
    }
    for (&fx.edges, 0..) |*e, i| {
        const to = fx.nodes[1 + i % 5];
        e.* = try eng.addEdgeColocatedWithPublicId(fx.nodes[0], to, REL, pid(i));
    }
    return fx;
}

fn expectEdgePid(eng: *GraphEngine, edge_id: u64, want_pid: u64) !void {
    const e = (try eng.getEdge(edge_id)) orelse return error.EdgeNotFound;
    try testing.expectEqual(edge_id, e.edge_id);
    try testing.expectEqual(want_pid, e.public_id);
}

test "P1: clean reopen mmap-adopts; overlay mutations; checkpoint merges; next reopen adopts merged base" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xF1} ** 16;
    const cfg = test_support.testConfig();

    var fx: Fixture = undefined;
    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        fx = try populate(eng);
        try eng.checkpoint(); // writes GSEIDX4 + GSXIDX2 snapshots
    }

    var new_edge: u64 = 0;
    {
        // Generation 1: reopen → first access mmap-ADOPTS (load, no rebuild).
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        for (fx.edges, 0..) |e, i| try expectEdgePid(eng, e, pid(i));
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_loads);
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_rebuilds);

        // MERGE-dedup probes served from the mapped base.
        var buf: [8]u64 = undefined;
        const hits = try eng.probeEdge(fx.nodes[0], REL, fx.nodes[1], &buf);
        try testing.expectEqual(@as(usize, 5), hits.len); // i % 5 == 0 → 5 edges
        try testing.expectEqual(@as(usize, 0), (try eng.probeEdge(fx.nodes[1], REL, fx.nodes[0], &buf)).len);

        // Overlay mutations on top of the base: delete a base edge, add a new
        // one, then checkpoint → the saver merges base ⊕ overlay ⊖ tombstones.
        try eng.removeEdge(fx.nodes[0], fx.nodes[1 + 3 % 5], fx.edges[3]);
        new_edge = try eng.addEdgeColocatedWithPublicId(fx.nodes[2], fx.nodes[3], REL, pid(999));
        // Also dirty the label + property indexes so this test exercises the
        // ALL-FOUR-saved checkpoint shape. (Since P2 an edge-only session no
        // longer forces a rebuild — the full checkpoint RESTAMPS the clean
        // label/prop snapshot counters; tests/derived_restamp.zig covers
        // that path explicitly.)
        try eng.addLabel(fx.nodes[5], 3);
        var rec5 = (try eng.getNode(fx.nodes[5])).?;
        rec5.prop_head = try eng.putProperty(rec5.prop_head, "k", .{ .int = 42 });
        try eng.putNode(fx.nodes[5], rec5);
        try eng.checkpoint();
    }

    {
        // Generation 2: reopen adopts the MERGED snapshot.
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        try testing.expectEqual(@as(?gs.edge.EdgeEntry, null), try eng.getEdge(fx.edges[3]));
        try expectEdgePid(eng, new_edge, pid(999));
        for (fx.edges, 0..) |e, i| {
            if (i == 3) continue;
            try expectEdgePid(eng, e, pid(i));
        }
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_loads);
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_rebuilds);

        // The deleted edge's existence record is gone; the new one probes.
        var buf: [8]u64 = undefined;
        const hits = try eng.probeEdge(fx.nodes[0], REL, fx.nodes[1 + 3 % 5], &buf);
        for (hits) |id| try testing.expect(id != fx.edges[3]);
        const nhits = try eng.probeEdge(fx.nodes[2], REL, fx.nodes[3], &buf);
        try testing.expectEqual(@as(usize, 1), nhits.len);
        try testing.expectEqual(new_edge, nhits[0]);
        // Record-count cross-check: edge_index and existence index agree.
        try testing.expectEqual(eng.edgeIndexCount(), eng.edgeExistRecordCount());
        try testing.expectEqual(@as(usize, fx.edges.len), eng.edgeIndexCount());
    }
}

test "P1: never-mutated mmap-backed index persists NOTHING (snapshot files byte-identical)" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xF2} ** 16;
    const cfg = test_support.testConfig();

    var fx: Fixture = undefined;
    var idx_path: []u8 = undefined;
    var exist_path: []u8 = undefined;
    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        fx = try populate(eng);
        try eng.checkpoint();
        idx_path = try std.fmt.allocPrint(testing.allocator, "{s}/edges.idx", .{eng.graph_dir.path});
        exist_path = try std.fmt.allocPrint(testing.allocator, "{s}/edges_exist.idx", .{eng.graph_dir.path});
    }
    defer testing.allocator.free(idx_path);
    defer testing.allocator.free(exist_path);

    const idx_before = try readFileBytes(testing.allocator, idx_path);
    defer testing.allocator.free(idx_before);
    const exist_before = try readFileBytes(testing.allocator, exist_path);
    defer testing.allocator.free(exist_before);

    {
        // Read-only session: hydrate (adopt), read, checkpoint, close. The
        // dirty flags stay false → saveDerivedIndexesConditional writes
        // NOTHING → the old (still counter-valid) snapshots survive untouched.
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        var buf: [8]u64 = undefined;
        for (fx.edges, 0..) |e, i| try expectEdgePid(eng, e, pid(i));
        _ = try eng.probeEdge(fx.nodes[0], REL, fx.nodes[1], &buf);
        try eng.checkpoint();
        try eng.close();
    }

    const idx_after = try readFileBytes(testing.allocator, idx_path);
    defer testing.allocator.free(idx_after);
    const exist_after = try readFileBytes(testing.allocator, exist_path);
    defer testing.allocator.free(exist_after);
    try testing.expectEqualSlices(u8, idx_before, idx_after);
    try testing.expectEqualSlices(u8, exist_before, exist_after);

    {
        // And the untouched snapshots still adopt cleanly.
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        try expectEdgePid(eng, fx.edges[0], pid(0));
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_loads);
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_rebuilds);
    }
}

test "P1 crash: mutations after mmap-adopt, crash before checkpoint → epoch gate → exact tail reconcile" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xF3} ** 16;
    const cfg = test_support.testConfig(); // sync_each_commit: WAL tail survives

    var fx: Fixture = undefined;
    var new_edge: u64 = 0;
    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        fx = try populate(eng);
        try eng.checkpoint();
    }
    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        errdefer eng.close() catch {};
        // Force the mmap adopt, then mutate ON TOP of the live base.
        try expectEdgePid(eng, fx.edges[0], pid(0));
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_loads);
        try eng.removeEdge(fx.nodes[0], fx.nodes[1 + 1 % 5], fx.edges[1]);
        new_edge = try eng.addEdgeColocatedWithPublicId(fx.nodes[4], fx.nodes[5], REL, pid(777));
        // SIMULATED CRASH: no checkpoint, no close. WAL replay advances
        // manifest.counter past the snapshots, but checkpoint_epoch is
        // UNCHANGED — so the next open LOADS the epoch-matched snapshots and
        // RECONCILES the committed tail (removeEdge + addEdge) into them.
        eng.deinit();
    }
    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        try testing.expectEqual(@as(?gs.edge.EdgeEntry, null), try eng.getEdge(fx.edges[1]));
        try expectEdgePid(eng, new_edge, pid(777));
        for (fx.edges, 0..) |e, i| {
            if (i == 1) continue;
            try expectEdgePid(eng, e, pid(i));
        }
        // Crash restart: LOADED the epoch-matched snapshot, then RECONCILED the
        // committed tail (removeEdge + addEdge) into it — NOT a full rebuild.
        // The exact-edge assertions above prove the reconcile is correct.
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_loads);
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_reconciles);
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_rebuilds);
        var buf: [8]u64 = undefined;
        const hits = try eng.probeEdge(fx.nodes[4], REL, fx.nodes[5], &buf);
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expectEqual(new_edge, hits[0]);
    }
}

fn corruptByte(path: []const u8, offset: u64) !void {
    const io = ioT();
    var f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer f.close(io);
    var b: [1]u8 = undefined;
    _ = try f.readPositionalAll(io, &b, offset);
    b[0] ^= 0xFF;
    try f.writePositionalAll(io, &b, offset);
}

test "P1 corrupt/truncated snapshot → clean reject at load → rebuild (header, truncation, zero-magic)" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xF4} ** 16;
    const cfg = test_support.testConfig();

    var fx: Fixture = undefined;
    var idx_path: []u8 = undefined;
    var exist_path: []u8 = undefined;
    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        fx = try populate(eng);
        try eng.checkpoint();
        idx_path = try std.fmt.allocPrint(testing.allocator, "{s}/edges.idx", .{eng.graph_dir.path});
        exist_path = try std.fmt.allocPrint(testing.allocator, "{s}/edges_exist.idx", .{eng.graph_dir.path});
    }
    defer testing.allocator.free(idx_path);
    defer testing.allocator.free(exist_path);

    // (a) Header corruption (checkpoint counter byte) → meta-CRC reject.
    try corruptByte(idx_path, 8);
    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        for (fx.edges, 0..) |e, i| try expectEdgePid(eng, e, pid(i));
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_loads);
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_rebuilds);
        try eng.checkpoint(); // rewrite clean snapshots for the next case
    }

    // (b) Truncation (drop the meta-CRC tail) of the EXISTENCE snapshot.
    {
        const io = ioT();
        var f = try std.Io.Dir.cwd().openFile(io, exist_path, .{ .mode = .read_write });
        const st = try f.stat(io);
        try f.setLength(io, st.size - 3);
        f.close(io);
    }
    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        var buf: [8]u64 = undefined;
        try testing.expectEqual(@as(usize, 5), (try eng.probeEdge(fx.nodes[0], REL, fx.nodes[1], &buf)).len);
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_rebuilds);
        try eng.checkpoint();
    }

    // (c) Zeroed magic — the exact on-disk state of a crash between the body
    // fsync and the magic publish (torn-write window) → InvalidFormat reject.
    {
        const io = ioT();
        var f = try std.Io.Dir.cwd().openFile(io, idx_path, .{ .mode = .read_write });
        const zeros = [_]u8{0} ** 8;
        try f.writePositionalAll(io, &zeros, 0);
        f.close(io);
    }
    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        for (fx.edges, 0..) |e, i| try expectEdgePid(eng, e, pid(i));
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_rebuilds);
    }
}

test "P1 payload corruption is caught LAZILY as ChecksumMismatch at first touch (documented failure model)" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xF5} ** 16;
    const cfg = test_support.testConfig();

    var fx: Fixture = undefined;
    var idx_path: []u8 = undefined;
    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        fx = try populate(eng);
        try eng.checkpoint();
        idx_path = try std.fmt.allocPrint(testing.allocator, "{s}/edges.idx", .{eng.graph_dir.path});
    }
    defer testing.allocator.free(idx_path);

    // Flip one PAYLOAD byte (header + directory stay valid, so the load-time
    // meta-CRC passes and the counter gate accepts the snapshot).
    try corruptByte(idx_path, sorted.HEADER_SIZE + 4);

    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        // Bit-rot inside the mapped payload block surfaces as a hard integrity
        // error on access — the same class as a corrupt data page, NOT a
        // silent wrong answer (and no longer a silent whole-index rebuild).
        try testing.expectError(error.ChecksumMismatch, eng.getEdge(fx.edges[0]));
        // Deterministic for the rest of the session (no flapping).
        try testing.expectError(error.ChecksumMismatch, eng.getEdge(fx.edges[0]));
    }

    // I1 (P1 review): the first lazy ChecksumMismatch INVALIDATED the on-disk
    // snapshot (magic zeroed) so the wedge cannot persist across reopens —
    // without this, a read-only deployment would re-adopt the same corrupt
    // file and error on the same key range forever.
    {
        const io = ioT();
        var f = try std.Io.Dir.cwd().openFile(io, idx_path, .{});
        defer f.close(io);
        var magic_now: [8]u8 = undefined;
        _ = try f.readPositionalAll(io, &magic_now, 0);
        try testing.expectEqualSlices(u8, &([_]u8{0} ** 8), &magic_now);
    }

    // Next open: zeroed magic → InvalidFormat → counter-gate rebuild path →
    // the index self-heals from durable adjacency and serves every edge.
    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        for (fx.edges, 0..) |e, i| try expectEdgePid(eng, e, pid(i));
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_rebuilds);
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_loads);
        // Persist the healed snapshots; the following open loads clean again.
        try eng.checkpoint();
    }
    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        try expectEdgePid(eng, fx.edges[0], pid(0));
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_loads);
    }
}

// ============================================================================
// P1 review C1 — the checkpoint save must NEVER rewrite the live-mmap'd
// snapshot inode in place. The save now goes tmp + fsync + rename; the old
// inode stays alive under the adopted mapping, so a mid-session FULL
// checkpoint must leave the still-open engine fully readable (lookups,
// probes, first-touch CRC verification of blocks never touched before the
// checkpoint) — including after net-shrinking deletes (the old SIGBUS shape)
// and across a second mutate+checkpoint cycle.
// ============================================================================

test "C1: mid-session full checkpoint; live base keeps serving reads (multi-block, net shrink, two cycles)" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xF6} ** 16;
    const cfg = test_support.testConfig();

    // Enough edges for a multi-block payload: 40 B/record, 64 KiB/block →
    // 1638 records per block. 4000 edges ≈ 2.5 blocks.
    const N: usize = 4000;
    var nodes: [8]u64 = undefined;
    var edges: [N]u64 = undefined;
    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        for (&nodes) |*n| {
            n.* = try eng.allocNode();
            try eng.putNode(n.*, test_support.emptyNode(1));
        }
        for (&edges, 0..) |*e, i| {
            e.* = try eng.addEdgeColocatedWithPublicId(nodes[i % 4], nodes[4 + i % 4], REL, pid(i));
        }
        try eng.checkpoint();
    }

    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};

        // Adopt the base but touch ONLY a handful of low records — most
        // blocks must get their FIRST CRC verification after the checkpoint
        // below, through the old mapping.
        try expectEdgePid(eng, edges[0], pid(0));
        try expectEdgePid(eng, edges[1], pid(1));
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_loads);

        // NET SHRINK: delete half the edges (the merged snapshot written by
        // the checkpoint is markedly smaller than the mapped one — the exact
        // shape that SIGBUS'd with an in-place truncate+rewrite), plus a few
        // adds so the overlay is non-trivial.
        var i: usize = 0;
        while (i < N / 2) : (i += 1) {
            try eng.removeEdge(nodes[i % 4], nodes[4 + i % 4], edges[i]);
        }
        const extra1 = try eng.addEdgeColocatedWithPublicId(nodes[0], nodes[7], REL, pid(N + 1));

        // Mid-session FULL checkpoint — rewrites both edge snapshots via
        // rename while the mapping is live.
        try eng.checkpoint();

        // KEEP READING through the previously-adopted base: every surviving
        // edge (first-touch verifies untouched blocks of the OLD inode),
        // every deleted edge stays gone, probes stay exact.
        i = N / 2;
        while (i < N) : (i += 1) {
            try expectEdgePid(eng, edges[i], pid(i));
        }
        i = 0;
        while (i < N / 2) : (i += 1) {
            try testing.expectEqual(@as(?gs.edge.EdgeEntry, null), try eng.getEdge(edges[i]));
        }
        try expectEdgePid(eng, extra1, pid(N + 1));
        try testing.expectEqual(@as(usize, N / 2 + 1), eng.edgeIndexCount());
        try testing.expectEqual(eng.edgeIndexCount(), eng.edgeExistRecordCount());
        var buf: [8]u64 = undefined;
        const hits = try eng.probeEdge(nodes[0], REL, nodes[7], &buf);
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expectEqual(extra1, hits[0]);

        // SECOND mutate + checkpoint cycle on the SAME still-open engine,
        // then read again (the first rename already swapped the inode under
        // the path; the fd must have been reopened for this save to land in
        // the right file).
        try eng.removeEdge(nodes[(N - 1) % 4], nodes[4 + (N - 1) % 4], edges[N - 1]);
        const extra2 = try eng.addEdgeColocatedWithPublicId(nodes[1], nodes[6], REL, pid(N + 2));
        try eng.checkpoint();

        i = N / 2;
        while (i < N - 1) : (i += 1) {
            try expectEdgePid(eng, edges[i], pid(i));
        }
        try testing.expectEqual(@as(?gs.edge.EdgeEntry, null), try eng.getEdge(edges[N - 1]));
        try expectEdgePid(eng, extra2, pid(N + 2));
        try testing.expectEqual(@as(usize, N / 2 + 1), eng.edgeIndexCount());
    }

    // Reopen: adopts the LAST renamed-in snapshot (counter-current, loads,
    // no rebuild) with the exact merged state.
    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        var i: usize = N / 2;
        while (i < N - 1) : (i += 1) {
            try expectEdgePid(eng, edges[i], pid(i));
        }
        try testing.expectEqual(@as(?gs.edge.EdgeEntry, null), try eng.getEdge(edges[0]));
        try testing.expectEqual(@as(u64, 1), eng.getMetrics().derived_index_loads);
        try testing.expectEqual(@as(u64, 0), eng.getMetrics().derived_index_rebuilds);
        try testing.expectEqual(@as(usize, N / 2 + 1), eng.edgeIndexCount());
    }
}

// ============================================================================
// BENCH — 1M-edge snapshot: legacy load (whole-file read + hashmap build) vs
// mmap-adopt. Not a pass/fail perf gate (CI boxes vary); prints timings and
// asserts only correctness + that the adopt path did not read the payload
// eagerly (via a sanity bound: adopt must not be slower than 4x legacy —
// generous enough for any host while catching an accidental O(payload) load).
// ============================================================================

const BENCH_N: usize = 1_000_000;
const LEGACY_MAGIC = "GSEIDX3\x00";
const Crc32 = std.hash.crc.Crc32Iscsi;
/// Current edge-index record size (GAP-0060 widened prop_head to u64: 44 B).
const REC = edge_index_map.RECORD_SIZE;

fn benchEntry(i: usize) edge_index_map.EdgeIndexEntry {
    return .{
        .from = @as(u64, i) / 10 + 1,
        .neighbor = @as(u64, i % 9973) + 1,
        .rel_type = @intCast(i % 17),
        .prop_head = 0,
        .public_id = 0x1111_0000_0000_0000 | @as(u64, i),
    };
}

test "BENCH 1M-edge snapshot load: legacy read+build vs mmap-adopt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = ioT();
    const a = testing.allocator;

    // --- Write the LEGACY (GSEIDX3-style) container: magic | counter |
    // count | REC-byte records | whole-file CRC32.
    {
        var buf = try a.alloc(u8, 24 + BENCH_N * REC + 4);
        defer a.free(buf);
        @memcpy(buf[0..8], LEGACY_MAGIC);
        std.mem.writeInt(u64, buf[8..16], 42, .little);
        std.mem.writeInt(u64, buf[16..24], BENCH_N, .little);
        for (0..BENCH_N) |i| {
            const rec = buf[24 + i * REC ..][0..REC];
            edge_index_map.encodeRecord(rec, @as(u64, i) + 1, benchEntry(i));
        }
        const crc = Crc32.hash(buf[0 .. buf.len - 4]);
        std.mem.writeInt(u32, buf[buf.len - 4 ..][0..4], crc, .little);
        const f = try tmp.dir.createFile(io, "legacy.idx", .{});
        defer f.close(io);
        try f.writePositionalAll(io, buf, 0);
        try f.sync(io);
    }

    // --- Write the NEW sorted container (records already id-sorted).
    {
        const payload = try a.alloc(u8, BENCH_N * REC);
        defer a.free(payload);
        for (0..BENCH_N) |i| {
            edge_index_map.encodeRecord(payload[i * REC ..][0..REC], @as(u64, i) + 1, benchEntry(i));
        }
        const f = try tmp.dir.createFile(io, "sorted.idx", .{ .read = true });
        defer f.close(io);
        try sorted.write(a, f, "GSEIDX4\x00", 42, 0, REC, payload);
    }

    // --- Legacy path: read whole file, CRC-verify, build the hashmap.
    var legacy_ns: u64 = 0;
    {
        var f = try tmp.dir.openFile(io, "legacy.idx", .{});
        defer f.close(io);
        const t0 = nowNs();
        const st = try f.stat(io);
        const data = try a.alloc(u8, @intCast(st.size));
        defer a.free(data);
        _ = try f.readPositionalAll(io, data, 0);
        const stored = std.mem.readInt(u32, data[data.len - 4 ..][0..4], .little);
        try testing.expectEqual(stored, Crc32.hash(data[0 .. data.len - 4]));
        var map = std.AutoHashMap(u64, edge_index_map.EdgeIndexEntry).init(a);
        defer map.deinit();
        try map.ensureTotalCapacity(@intCast(BENCH_N));
        for (0..BENCH_N) |i| {
            const rec = data[24 + i * REC ..];
            map.putAssumeCapacity(std.mem.readInt(u64, rec[0..8], .little), .{
                .from = std.mem.readInt(u64, rec[8..16], .little),
                .neighbor = std.mem.readInt(u64, rec[16..24], .little),
                .rel_type = std.mem.readInt(u32, rec[24..28], .little),
                .prop_head = std.mem.readInt(u64, rec[28..36], .little),
                .public_id = std.mem.readInt(u64, rec[36..44], .little),
            });
        }
        legacy_ns = @intCast(nowNs() - t0);
        try testing.expectEqual(@as(u32, BENCH_N), map.count());
    }

    // --- New path: mmap-adopt, then 1000 random point lookups off the base.
    var adopt_ns: u64 = 0;
    var lookups_ns: u64 = 0;
    {
        var f = try tmp.dir.openFile(io, "sorted.idx", .{});
        defer f.close(io);
        var m = edge_index_map.EdgeIndexMap.init(a);
        defer m.deinit();
        const t0 = nowNs();
        try m.adoptBase((try sorted.load(a, &f, "GSEIDX4\x00", REC)).?);
        adopt_ns = @intCast(nowNs() - t0);
        try testing.expectEqual(BENCH_N, m.count());

        var prng = std.Random.DefaultPrng.init(1234);
        const rnd = prng.random();
        const t1 = nowNs();
        for (0..1000) |_| {
            const id = 1 + rnd.uintLessThan(u64, BENCH_N);
            const e = (try m.get(id)).?;
            try testing.expectEqual(benchEntry(@intCast(id - 1)).public_id, e.public_id);
        }
        lookups_ns = @intCast(nowNs() - t1);
    }

    std.debug.print(
        "\nBENCH 1M-edge snapshot load ({d} B records, {d} MiB payload):\n" ++
            "  legacy  (read whole file + CRC + hashmap build): {d:.2} ms\n" ++
            "  mmap    (adopt: mmap + header/dir verify)      : {d:.3} ms\n" ++
            "  mmap    (1000 random binary-search lookups)    : {d:.3} ms total\n" ++
            "  adopt speedup vs legacy: {d:.0}x\n",
        .{
            REC,
            BENCH_N * REC / (1024 * 1024),
            @as(f64, @floatFromInt(legacy_ns)) / 1e6,
            @as(f64, @floatFromInt(adopt_ns)) / 1e6,
            @as(f64, @floatFromInt(lookups_ns)) / 1e6,
            @as(f64, @floatFromInt(legacy_ns)) / @as(f64, @floatFromInt(adopt_ns)),
        },
    );

    // Sanity: the adopt path must not have degenerated into an O(payload)
    // eager read + build. (Generous bound; typical result is 100-10000x.)
    try testing.expect(adopt_ns < legacy_ns * 4);
}

test {
    std.testing.refAllDecls(@This());
}
