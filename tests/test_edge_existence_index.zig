// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// Engine-level tests for the edge-EXISTENCE index (Phase 3 backbone):
// the durable O(1) MERGE-dedup probe mapping (from, rel_type, to) ->
// edge_id(s).
//
// RESTORED COVERAGE (GAP 0031(b)): build.zig's `test-edge-existence-index`
// step has referenced this file since the Phase 3 commit (ab1b3a04), but the
// file itself was never committed — only the src/ changes and the build step
// landed, so the step failed with FileNotFound and the described nine tests
// were lost. This file restores that coverage against the CURRENT engine API
// (inline public ids, sorted mmap snapshots, deferred Phase A hydration):
//
//   * probe hit/miss + complete candidate set semantics;
//   * parallel edges (same tuple) and per-edge delete;
//   * crash-recovery: clean snapshot reopen, hard-crash WAL-tail rebuild,
//     double-crash idempotency (no phantom records);
//   * migration: missing snapshot (pre-Phase-3 graph) and corrupt/truncated
//     snapshot both rebuild exactly from the durable adjacency;
//   * delete durability across checkpoint reopen AND crash recovery;
//   * the behavioral O(1)-not-O(degree) probe-cost proof on a 5000-child
//     parent (lastProbeEntriesExamined == tuple bucket size, never degree).
//
// The index is a pure function of the WAL-logged adjacency, so every
// recovery flavor must land on EXACTLY the adjacency's edge set — these
// tests assert record-count parity with edge_index and per-tuple agreement
// with adjacency enumeration after each flavor.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const test_support = gs.test_support;

const REL: u32 = 7;

fn eio() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn pid(i: usize) u64 {
    return 0xE216_0000_0000_0000 | @as(u64, @intCast(i + 1));
}

/// allocNode + putNode(emptyNode) — every edge endpoint in this file is a
/// durably created node (the create-node-before-edge contract).
fn mkNode(eng: *GraphEngine) !u64 {
    const id = try eng.allocNode();
    try eng.putNode(id, test_support.emptyNode(1));
    return id;
}

fn sortIds(ids: []u64) void {
    std.mem.sort(u64, ids, {}, std.sort.asc(u64));
}

/// Assert probe(from, REL, to) returns exactly `expect` (order-insensitive).
fn expectProbe(eng: *GraphEngine, from: u64, to: u64, expect: []const u64) !void {
    var buf: [8]u64 = undefined;
    const hits = try eng.probeEdge(from, REL, to, &buf);
    try testing.expectEqual(expect.len, hits.len);
    var got: [8]u64 = undefined;
    @memcpy(got[0..hits.len], hits);
    sortIds(got[0..hits.len]);
    var want: [8]u64 = undefined;
    @memcpy(want[0..expect.len], expect);
    sortIds(want[0..expect.len]);
    try testing.expectEqualSlices(u64, want[0..expect.len], got[0..hits.len]);
}

/// Cross-check: every edge the durable adjacency enumerates must probe to
/// itself, and the existence index must hold EXACTLY as many records as the
/// edge_index (both are derived from the same adjacency, so they must agree
/// record-for-record). Returns the enumerated edge count.
fn expectAgreesWithAdjacency(eng: *GraphEngine, from_nodes: []const u64) !usize {
    var total: usize = 0;
    for (from_nodes) |from| {
        var it = try eng.expandOutIter(from, null);
        defer it.deinit();
        while (try it.next()) |e| {
            var buf: [8]u64 = undefined;
            const hits = try eng.probeEdge(from, e.rel_type, e.neighbor, &buf);
            const found = for (hits) |h| {
                if (h == e.edge_id) break true;
            } else false;
            if (!found) {
                std.debug.print(
                    "adjacency edge {d} ({d})-[{d}]->({d}) missing from existence index\n",
                    .{ e.edge_id, from, e.rel_type, e.neighbor },
                );
                return error.ExistenceIndexDisagrees;
            }
            total += 1;
        }
    }
    try testing.expectEqual(total, eng.edgeExistRecordCount());
    try testing.expectEqual(total, eng.edgeIndexCount());
    return total;
}

test "edge-existence probe: added edge found, other tuples miss, delete empties the tuple" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xC1} ** 16;

    const eng = try GraphEngine.create(testing.allocator, td.path, uuid, test_support.testConfig());
    defer eng.close() catch {};

    const n1 = try mkNode(eng);
    const n2 = try mkNode(eng);
    const e = try eng.addEdgeColocatedWithPublicId(n1, n2, REL, pid(0));

    try expectProbe(eng, n1, n2, &.{e});
    // Misses: wrong rel_type, reversed direction, unrelated tuple.
    var buf: [8]u64 = undefined;
    try testing.expectEqual(@as(usize, 0), (try eng.probeEdge(n1, REL + 1, n2, &buf)).len);
    try testing.expectEqual(@as(usize, 0), (try eng.probeEdge(n2, REL, n1, &buf)).len);
    try testing.expectEqual(@as(usize, 1), eng.edgeExistRecordCount());
    try testing.expectEqual(@as(usize, 1), eng.edgeIndexCount());

    // Delete clears the tuple in lock-step with the edge.
    try eng.removeEdge(n1, n2, e);
    try expectProbe(eng, n1, n2, &.{});
    try testing.expectEqual(@as(usize, 0), eng.edgeExistRecordCount());
    try testing.expectEqual(@as(usize, 0), eng.edgeIndexCount());
}

test "edge-existence parallel edges: complete candidate set; removing one keeps the rest" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xC2} ** 16;

    const eng = try GraphEngine.create(testing.allocator, td.path, uuid, test_support.testConfig());
    defer eng.close() catch {};

    const n1 = try mkNode(eng);
    const n2 = try mkNode(eng);
    const e1 = try eng.addEdgeColocatedWithPublicId(n1, n2, REL, pid(1));
    const e2 = try eng.addEdgeColocatedWithPublicId(n1, n2, REL, pid(2));
    const e3 = try eng.addEdgeColocatedWithPublicId(n1, n2, REL, pid(3));

    // A parallel-edge tuple returns ALL candidates so a higher layer (geode
    // tenant disambiguation) can preserve exact MERGE semantics.
    try expectProbe(eng, n1, n2, &.{ e1, e2, e3 });
    try testing.expectEqual(@as(usize, 3), eng.edgeExistRecordCount());

    try eng.removeEdge(n1, n2, e2);
    try expectProbe(eng, n1, n2, &.{ e1, e3 });
    try testing.expectEqual(@as(usize, 2), eng.edgeExistRecordCount());
    try testing.expectEqual(@as(usize, 2), eng.edgeIndexCount());
}

test "edge-existence snapshot path: checkpoint + clean reopen serves exact probes and counts" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xC3} ** 16;
    const cfg = test_support.testConfig();

    var from: u64 = 0;
    var tos: [4]u64 = undefined;
    var edges: [4]u64 = undefined;
    var par: u64 = 0; // parallel to edges[0]'s tuple

    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};

        from = try mkNode(eng);
        for (&tos, 0..) |*t, i| {
            t.* = try mkNode(eng);
            edges[i] = try eng.addEdgeColocatedWithPublicId(from, t.*, REL, pid(i));
        }
        par = try eng.addEdgeColocatedWithPublicId(from, tos[0], REL, pid(99));
        try eng.checkpoint(); // snapshot written (edges_exist.idx)
    }

    const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    defer eng.close() catch {};

    try expectProbe(eng, from, tos[0], &.{ edges[0], par });
    for (1..tos.len) |i| try expectProbe(eng, from, tos[i], &.{edges[i]});
    try testing.expectEqual(@as(usize, 5), eng.edgeExistRecordCount());
    try testing.expectEqual(@as(usize, 5), eng.edgeIndexCount());
    _ = try expectAgreesWithAdjacency(eng, &.{from});
}

test "edge-existence hard crash: WAL-tail edges + a removal rebuild in exact agreement with adjacency" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xC4} ** 16;
    const cfg = test_support.testConfig();

    var from: u64 = 0;
    var tos: [3]u64 = undefined;
    var edges: [3]u64 = undefined;

    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        errdefer eng.close() catch {};

        from = try mkNode(eng);
        for (&tos) |*t| t.* = try mkNode(eng);
        // Durable baseline for the post-crash derived-index scan bound; every
        // edge op below stays in the crash window (fsynced WAL tail only).
        try eng.checkpoint();

        for (&edges, 0..) |*e, i| {
            e.* = try eng.addEdgeColocatedWithPublicId(from, tos[i], REL, pid(i));
        }
        try eng.removeEdge(from, tos[1], edges[1]);

        // SIMULATED CRASH: no checkpoint, no close — recovery replay is the
        // sole authority; the existence index must be rebuilt from whatever
        // adjacency the WAL restores, never from stale in-memory state.
        eng.deinit();
    }

    const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    defer eng.close() catch {};

    try expectProbe(eng, from, tos[0], &.{edges[0]});
    try expectProbe(eng, from, tos[1], &.{}); // committed remove must NOT resurrect
    try expectProbe(eng, from, tos[2], &.{edges[2]});
    const live = try expectAgreesWithAdjacency(eng, &.{from});
    try testing.expectEqual(@as(usize, 2), live);
}

test "edge-existence idempotency: double crash/recovery mints no phantom records" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xC5} ** 16;
    const cfg = test_support.testConfig();

    var from: u64 = 0;
    var tos: [3]u64 = undefined;
    var edges: [3]u64 = undefined;

    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        errdefer eng.close() catch {};
        from = try mkNode(eng);
        for (&tos) |*t| t.* = try mkNode(eng);
        try eng.checkpoint();
        for (&edges, 0..) |*e, i| {
            e.* = try eng.addEdgeColocatedWithPublicId(from, tos[i], REL, pid(i));
        }
        eng.deinit(); // crash #1
    }

    {
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        errdefer eng.close() catch {};
        // Hydrate + verify, then crash AGAIN without checkpointing: the same
        // WAL tail is replayed a second time on the next open. `put` is
        // idempotent per edge_id, so re-apply/rebuild cannot insert phantoms.
        try testing.expectEqual(@as(usize, 3), eng.edgeExistRecordCount());
        eng.deinit(); // crash #2
    }

    const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    defer eng.close() catch {};
    for (0..tos.len) |i| try expectProbe(eng, from, tos[i], &.{edges[i]});
    try testing.expectEqual(@as(usize, 3), eng.edgeExistRecordCount());
    try testing.expectEqual(@as(usize, 3), eng.edgeIndexCount());
}

test "edge-existence migration: missing snapshot (pre-Phase-3 graph) rebuilds from adjacency" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xC6} ** 16;
    const cfg = test_support.testConfig();

    var from: u64 = 0;
    var to: u64 = 0;
    var edge: u64 = 0;
    var exist_path: []u8 = undefined;

    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        from = try mkNode(eng);
        to = try mkNode(eng);
        edge = try eng.addEdgeColocatedWithPublicId(from, to, REL, pid(0));
        try eng.checkpoint();
        exist_path = try std.fmt.allocPrint(testing.allocator, "{s}/edges_exist.idx", .{eng.graph_dir.path});
    }
    defer testing.allocator.free(exist_path);

    // A pre-Phase-3 graph has no existence snapshot at all: the loader must
    // report a miss and the open must fall back to the full derived rebuild.
    try std.Io.Dir.cwd().deleteFile(eio(), exist_path);

    const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    defer eng.close() catch {};
    try expectProbe(eng, from, to, &.{edge});
    _ = try expectAgreesWithAdjacency(eng, &.{from});
}

test "edge-existence corrupt snapshot: truncated file cleanly rejected, rebuilds from adjacency" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xC7} ** 16;
    const cfg = test_support.testConfig();

    var from: u64 = 0;
    var to: u64 = 0;
    var edge: u64 = 0;
    var exist_path: []u8 = undefined;

    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        from = try mkNode(eng);
        to = try mkNode(eng);
        edge = try eng.addEdgeColocatedWithPublicId(from, to, REL, pid(0));
        try eng.checkpoint();
        exist_path = try std.fmt.allocPrint(testing.allocator, "{s}/edges_exist.idx", .{eng.graph_dir.path});
    }
    defer testing.allocator.free(exist_path);

    // Truncate to a garbage stub: too short for the header, wrong magic.
    {
        const io = eio();
        const f = try std.Io.Dir.cwd().createFile(io, exist_path, .{ .truncate = true });
        defer f.close(io);
        try f.writePositionalAll(io, "GARBAGE", 0);
    }

    const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    defer eng.close() catch {};
    try expectProbe(eng, from, to, &.{edge});
    _ = try expectAgreesWithAdjacency(eng, &.{from});
}

test "edge-existence delete durability: removed tuple stays absent across checkpoint reopen AND crash recovery" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xC8} ** 16;
    const cfg = test_support.testConfig();

    var n1: u64 = 0;
    var n2: u64 = 0;
    var n3: u64 = 0;
    var e12: u64 = 0;
    var e13: u64 = 0;

    {
        const eng = try GraphEngine.create(testing.allocator, td.path, uuid, cfg);
        defer eng.close() catch {};
        n1 = try mkNode(eng);
        n2 = try mkNode(eng);
        n3 = try mkNode(eng);
        e12 = try eng.addEdgeColocatedWithPublicId(n1, n2, REL, pid(0));
        e13 = try eng.addEdgeColocatedWithPublicId(n1, n3, REL, pid(1));
        try eng.removeEdge(n1, n2, e12);
        try eng.checkpoint(); // remove reaches the snapshot
    }

    {
        // Clean reopen (snapshot path): the removed tuple is absent.
        const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
        errdefer eng.close() catch {};
        try expectProbe(eng, n1, n2, &.{});
        try expectProbe(eng, n1, n3, &.{e13});

        // Now remove the second edge and CRASH: the WAL-tail remove must not
        // resurrect in the rebuilt index either.
        try eng.removeEdge(n1, n3, e13);
        eng.deinit();
    }

    const eng = try GraphEngine.open(testing.allocator, td.path, uuid, cfg);
    defer eng.close() catch {};
    try expectProbe(eng, n1, n2, &.{});
    try expectProbe(eng, n1, n3, &.{});
    try testing.expectEqual(@as(usize, 0), eng.edgeExistRecordCount());
    try testing.expectEqual(@as(usize, 0), eng.edgeIndexCount());
}

test "edge-existence O(1) probe cost: 5000-child parent examines the tuple bucket, never the degree" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xC9} ** 16;

    const eng = try GraphEngine.create(testing.allocator, td.path, uuid, test_support.testConfig());
    defer eng.close() catch {};

    const K: usize = 5000;
    const parent = try mkNode(eng);
    const children = try testing.allocator.alloc(u64, K);
    defer testing.allocator.free(children);
    const child_edges = try testing.allocator.alloc(u64, K);
    defer testing.allocator.free(child_edges);

    for (children, 0..) |*c, i| {
        c.* = try mkNode(eng);
        child_edges[i] = try eng.addEdgeColocatedWithPublicId(parent, c.*, REL, pid(i));
    }
    // Two extra PARALLEL edges onto child 0, so its tuple bucket holds 3
    // candidates while the parent's out-degree is K + 2.
    const par1 = try eng.addEdgeColocatedWithPublicId(parent, children[0], REL, pid(K + 1));
    const par2 = try eng.addEdgeColocatedWithPublicId(parent, children[0], REL, pid(K + 2));

    try testing.expectEqual(K + 2, eng.edgeExistRecordCount());
    try testing.expectEqual(K + 2, eng.edgeIndexCount());

    // Single-candidate tuple in the middle of a 5000+-degree fan-out: the
    // probe walks exactly ONE candidate — this is the behavioral proof that
    // the MERGE-dedup probe replaced the O(out-degree) adjacency scan.
    try expectProbe(eng, parent, children[2500], &.{child_edges[2500]});
    try testing.expectEqual(@as(usize, 1), eng.lastProbeEntriesExamined());

    // Parallel tuple: cost is the bucket size (3), still not the degree.
    try expectProbe(eng, parent, children[0], &.{ child_edges[0], par1, par2 });
    try testing.expectEqual(@as(usize, 3), eng.lastProbeEntriesExamined());

    // Miss on the high-degree parent: zero candidates examined... a missing
    // key touches no records at all (hash miss + empty base run).
    var buf: [8]u64 = undefined;
    const misses = try eng.probeEdge(parent, REL + 1, children[0], &buf);
    try testing.expectEqual(@as(usize, 0), misses.len);
    try testing.expect(eng.lastProbeEntriesExamined() <= 1);
}
