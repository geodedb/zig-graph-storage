// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6529 item 1: `abortTxn` must undo what the transaction wrote.
//
// The engine applies every write to its pages in place, in the buffer pool,
// before commit (the WAL holds after-images; recovery redoes committed
// transactions only and has no undo pass). `TxnManager.abort` used to drop
// the transaction's WAL records and nothing else: the pages it had written
// stayed modified and the slots, counts and ids it had taken stayed taken,
// so readers saw the aborted writes and the next checkpoint made them
// durable.
//
// Every scenario below commits a base state, runs one transaction, aborts
// it, and checks that the aborted writes are gone — in memory right after
// the abort, and again after (a) a checkpoint and a clean reopen and (b) a
// crash (engine dropped without checkpoint or close) and reopen. Counts are
// checked against the stores (`checkIntegrity`), ids are checked to be
// handed out again, and the derived indexes are checked to equal a rebuild
// over the same pages.
//
// A write the engine cannot undo exactly (a page the caller imaged itself, a
// legacy property chain) makes the abort fail closed: `error.AbortNotUndone`,
// and the engine refuses further writes and checkpoints, so the aborted
// change is never checkpointed.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const GraphEngine = gs.GraphEngine;
const test_support = gs.test_support;

const REL: u32 = 7;

fn uuidFor(tag: u8) [16]u8 {
    return [_]u8{ 0x65, 0x29, 0xAB, tag } ++ [_]u8{0x29} ** 12;
}

fn emptyNode() gs.node.NodeRec {
    return test_support.emptyNode(1);
}

fn intProp(eng: *GraphEngine, alloc: Allocator, head: u64, key: []const u8) !?i64 {
    const v = (try eng.getProperty(head, key, alloc)) orelse return null;
    return switch (v) {
        .int => |x| x,
        else => error.WrongPropertyType,
    };
}

fn hasLabel(eng: *GraphEngine, alloc: Allocator, node: u64, label: gs.LabelId) !bool {
    const ids = try eng.scanLabel(label, alloc);
    defer alloc.free(ids);
    for (ids) |id| if (id == node) return true;
    return false;
}

fn outEdgeIds(eng: *GraphEngine, alloc: Allocator, node: u64) ![]gs.EdgeId {
    const es = try eng.expandOut(node, null, alloc);
    defer alloc.free(es);
    const out = try alloc.alloc(gs.EdgeId, es.len);
    for (es, out) |e, *o| o.* = e.edge_id;
    std.mem.sort(gs.EdgeId, out, {}, std.sort.asc(gs.EdgeId));
    return out;
}

fn inEdgeCount(eng: *GraphEngine, node: u64) !usize {
    var it = try eng.expandInRemoteIter(node, null);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    return n;
}

/// Counts agree with the stores and the derived indexes are what a rebuild
/// over the same pages gives.
fn expectConsistent(eng: *GraphEngine, what: []const u8) !void {
    const rep = try eng.checkIntegrity();
    if (!rep.node_count_consistent or !rep.edge_count_consistent) {
        std.debug.print("{s}: manifest counts disagree with the stores (nodes consistent={}, edges consistent={})\n", .{ what, rep.node_count_consistent, rep.edge_count_consistent });
        return error.CountsInconsistent;
    }
    const live = try eng.debugDerivedDigests();
    try eng.rebuildDerivedForTest();
    if (!live.eql(try eng.debugDerivedDigests())) {
        std.debug.print("{s}: derived indexes differ from a rebuild\n", .{what});
        return error.DerivedIndexesDiverged;
    }
}

const Reopen = enum { checkpoint_close, crash };

/// Base state every scenario starts from (committed and checkpointed):
///   a: node, property p=1, label L0, out-edge a->b (public id 0xA1)
///   b: node, no properties, no labels
const Base = struct {
    a: u64,
    b: u64,
    l0: gs.LabelId,
    l1: gs.LabelId,
    ab: gs.EdgeId,
    nodes: u64,
    edges: u64,
};

fn buildBase(eng: *GraphEngine) !Base {
    const l0 = try eng.getOrAssignLabel("L0");
    const l1 = try eng.getOrAssignLabel("L1");
    const a = try eng.allocNode();
    try eng.putNode(a, emptyNode());
    const b = try eng.allocNode();
    try eng.putNode(b, emptyNode());
    const h = try eng.putProperty(0, "p", .{ .int = 1 });
    var rec = (try eng.getNode(a)).?;
    rec.prop_head = h;
    try eng.putNode(a, rec);
    try eng.addLabel(a, l0);
    const ab = try eng.addEdgeColocatedWithPublicId(a, b, REL, 0xA1);
    try eng.checkpoint();
    return .{ .a = a, .b = b, .l0 = l0, .l1 = l1, .ab = ab, .nodes = try eng.nodeCount(), .edges = try eng.edgeCount() };
}

/// The base state, unchanged.
fn expectBase(eng: *GraphEngine, alloc: Allocator, base: *const Base, what: []const u8) !void {
    try testing.expectEqual(base.nodes, try eng.nodeCount());
    try testing.expectEqual(base.edges, try eng.edgeCount());
    const ra = (try eng.getNode(base.a)) orelse return error.BaseNodeLost;
    try testing.expectEqual(@as(?i64, 1), try intProp(eng, alloc, ra.prop_head, "p"));
    try testing.expect(try hasLabel(eng, alloc, base.a, base.l0));
    try testing.expect(!try hasLabel(eng, alloc, base.a, base.l1));
    const rb = (try eng.getNode(base.b)) orelse return error.BaseNodeLost;
    try testing.expectEqual(@as(u64, 0), rb.prop_head);
    try testing.expect(!try hasLabel(eng, alloc, base.b, base.l0));
    const outs = try outEdgeIds(eng, alloc, base.a);
    defer alloc.free(outs);
    try testing.expectEqualSlices(gs.EdgeId, &.{base.ab}, outs);
    const outs_b = try outEdgeIds(eng, alloc, base.b);
    defer alloc.free(outs_b);
    try testing.expectEqual(@as(usize, 0), outs_b.len);
    try testing.expectEqual(@as(usize, 1), try inEdgeCount(eng, base.b));
    const e = (try eng.getEdge(base.ab)) orelse return error.BaseEdgeLost;
    try testing.expectEqual(@as(u64, 0xA1), e.public_id);
    try testing.expectEqual(@as(u64, 0), e.prop_head);
    try expectConsistent(eng, what);
}

/// One transaction's writes; `extra` carries ids it created so the check
/// can look for them.
const Extra = struct {
    node: ?u64 = null,
    edge: ?gs.EdgeId = null,
    next_node: u64 = 0,
    next_edge: u64 = 0,
};

fn runScenario(
    tag: u8,
    comptime body: fn (*GraphEngine, gs.TxnId, *const Base, *Extra) anyerror!void,
    reopen: Reopen,
) !void {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(tag);
    const cfg = test_support.testConfig();

    var base: Base = undefined;
    var extra = Extra{};
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        base = try buildBase(eng);
        extra.next_node = eng.manifest.next_node_id;
        extra.next_edge = eng.manifest.next_edge_id;

        const txn = try eng.beginTxn();
        try body(eng, txn, &base, &extra);
        try eng.abortTxn(txn);

        // In memory, right after the abort.
        try expectBase(eng, alloc, &base, "after abort");
        if (extra.node) |n| try testing.expect((try eng.getNode(n)) == null);
        if (extra.edge) |e| try testing.expect((try eng.getEdge(e)) == null);
        // Slots and ids the transaction took are handed out again.
        try testing.expectEqual(extra.next_node, eng.manifest.next_node_id);
        try testing.expectEqual(extra.next_edge, eng.manifest.next_edge_id);

        switch (reopen) {
            .checkpoint_close => {
                try eng.checkpoint();
                try eng.close();
            },
            .crash => eng.deinit(),
        }
    }

    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    try expectBase(eng, alloc, &base, "after reopen");
    if (extra.node) |n| try testing.expect((try eng.getNode(n)) == null);
    if (extra.edge) |e| try testing.expect((try eng.getEdge(e)) == null);
}

// --- transaction bodies ----------------------------------------------------

fn createNodeWithPropsLabelAndEdge(eng: *GraphEngine, txn: gs.TxnId, base: *const Base, extra: *Extra) !void {
    const n = try eng.allocNode();
    extra.node = n;
    try eng.putNodeTxn(n, emptyNode(), txn);
    var h = try eng.putPropertyTxn(0, "name", .{ .int = 7 }, txn);
    h = try eng.putPropertyTxn(h, "age", .{ .int = 40 }, txn);
    var rec = (try eng.getNode(n)).?;
    rec.prop_head = h;
    try eng.putNodeTxn(n, rec, txn);
    try eng.addLabelTxn(n, base.l0, txn);
    try eng.addLabelTxn(n, base.l1, txn);
    extra.edge = try eng.addEdgeColocatedTxnWithPublicId(n, base.b, REL, txn, 0xB1);
    _ = try eng.addEdgeColocatedTxnWithPublicId(base.a, n, REL, txn, 0xB2);
}

fn createNodeOnly(eng: *GraphEngine, txn: gs.TxnId, _: *const Base, extra: *Extra) !void {
    const n = try eng.allocNode();
    extra.node = n;
    try eng.putNodeTxn(n, emptyNode(), txn);
}

fn firstPropertyOnExistingNode(eng: *GraphEngine, txn: gs.TxnId, base: *const Base, _: *Extra) !void {
    const h = try eng.putPropertyTxn(0, "q", .{ .int = 5 }, txn);
    var rec = (try eng.getNode(base.b)).?;
    rec.prop_head = h;
    try eng.putNodeTxn(base.b, rec, txn);
}

fn labelChanges(eng: *GraphEngine, txn: gs.TxnId, base: *const Base, _: *Extra) !void {
    try eng.addLabelTxn(base.a, base.l1, txn);
    try eng.removeLabelTxn(base.a, base.l0, txn);
    try eng.addLabelTxn(base.b, base.l0, txn);
}

fn setExistingPropertyInPlace(eng: *GraphEngine, txn: gs.TxnId, base: *const Base, _: *Extra) !void {
    // SET a.p = 2: same size, rewritten in place in the committed chain.
    const ra = (try eng.getNode(base.a)).?;
    const h = try eng.putPropertyTxn(ra.prop_head, "p", .{ .int = 2 }, txn);
    try testing.expectEqual(ra.prop_head, h);
}

fn setExistingPropertyRelocating(eng: *GraphEngine, txn: gs.TxnId, base: *const Base, _: *Extra) !void {
    // Another chain is written after a's on the same slab page first, so
    // a's blob is no longer the page tail; then SET a.p = 3, a.big = <300
    // bytes>: the chain outgrows its slot and moves; the node is pointed at
    // the new head, as a caller does.
    _ = try eng.putPropertyTxn(0, "other", .{ .int = 8 }, txn);
    const ra = (try eng.getNode(base.a)).?;
    var h = try eng.putPropertyTxn(ra.prop_head, "p", .{ .int = 3 }, txn);
    var big: [300]u8 = undefined;
    @memset(&big, 'b');
    h = try eng.putPropertyTxn(h, "big", .{ .string = &big }, txn);
    try testing.expect(h != ra.prop_head);
    var rec = ra;
    rec.prop_head = h;
    try eng.putNodeTxn(base.a, rec, txn);
}

fn edgeAdd(eng: *GraphEngine, txn: gs.TxnId, base: *const Base, extra: *Extra) !void {
    extra.edge = try eng.addEdgeColocatedTxnWithPublicId(base.b, base.a, REL, txn, 0xC1);
    _ = try eng.addEdgeColocatedTxnWithPublicId(base.a, base.b, REL + 1, txn, 0xC2);
}

fn edgeRemove(eng: *GraphEngine, txn: gs.TxnId, base: *const Base, _: *Extra) !void {
    try eng.removeEdgeTxn(base.a, base.b, base.ab, txn);
}

fn nodeDelete(eng: *GraphEngine, txn: gs.TxnId, base: *const Base, _: *Extra) !void {
    // As a DETACH DELETE: the out-edge first, then the node.
    try eng.removeEdgeTxn(base.a, base.b, base.ab, txn);
    try eng.deleteNodeTxn(base.a, txn);
}

fn firstEdgePropertyBody(eng: *GraphEngine, txn: gs.TxnId, base: *const Base, _: *Extra) !void {
    try eng.setEdgePropertyTxn(base.a, base.b, base.ab, "w", .{ .int = 3 }, txn);
}

fn firstEdgeProperty(eng: *GraphEngine, txn: gs.TxnId, base: *const Base, extra: *Extra) !void {
    if (comptime !@hasDecl(GraphEngine, "setEdgePropertyTxn")) return error.NoSetEdgePropertyTxn;
    return firstEdgePropertyBody(eng, txn, base, extra);
}

// --- tests -----------------------------------------------------------------

test "SONNY-6529: abort undoes a node create with properties, labels and edges (checkpoint, reopen)" {
    try runScenario(1, createNodeWithPropsLabelAndEdge, .checkpoint_close);
}

test "SONNY-6529: abort undoes a node create with properties, labels and edges (crash, reopen)" {
    try runScenario(2, createNodeWithPropsLabelAndEdge, .crash);
}

test "SONNY-6529: abort gives back the node slot, count and id of a create" {
    try runScenario(3, createNodeOnly, .checkpoint_close);
}

test "SONNY-6529: abort undoes the first property of an existing node" {
    try runScenario(4, firstPropertyOnExistingNode, .checkpoint_close);
}

test "SONNY-6529: abort undoes an in-place change of an existing property" {
    try runScenario(15, setExistingPropertyInPlace, .checkpoint_close);
}

test "SONNY-6529: abort undoes an in-place change of an existing property (crash, reopen)" {
    try runScenario(16, setExistingPropertyInPlace, .crash);
}

test "SONNY-6529: abort undoes a property change that moved an existing chain" {
    try runScenario(17, setExistingPropertyRelocating, .checkpoint_close);
}

test "SONNY-6529: abort undoes a property change that moved an existing chain (crash, reopen)" {
    try runScenario(18, setExistingPropertyRelocating, .crash);
}

test "SONNY-6529: abort undoes label adds and removes on existing nodes" {
    try runScenario(5, labelChanges, .checkpoint_close);
}

test "SONNY-6529: abort undoes edge creates" {
    try runScenario(6, edgeAdd, .checkpoint_close);
}

test "SONNY-6529: abort undoes an edge removal" {
    try runScenario(7, edgeRemove, .checkpoint_close);
}

test "SONNY-6529: abort undoes a node delete" {
    try runScenario(8, nodeDelete, .checkpoint_close);
}

test "SONNY-6529: abort undoes a node delete (crash, reopen)" {
    try runScenario(9, nodeDelete, .crash);
}

test "SONNY-6529: abort undoes the first property of an existing edge" {
    try runScenario(10, firstEdgeProperty, .checkpoint_close);
}

test "SONNY-6529: an aborted create on a node page another transaction commits is not resurrected by that commit" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(11);
    const cfg = test_support.testConfig();

    var base: Base = undefined;
    var aborted: u64 = 0;
    var kept: u64 = 0;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        base = try buildBase(eng);

        // T1 creates a node, then T2 creates one on the SAME node page.
        // T2's image of that page would carry T1's record, so (SONNY-6659)
        // T2's write is refused while T1 is open; T2 retries after T1 ends.
        const t1 = try eng.beginTxn();
        aborted = try eng.allocNode();
        try eng.putNodeTxn(aborted, emptyNode(), t1);
        const t2 = try eng.beginTxn();
        kept = try eng.allocNode();
        try testing.expectError(error.WriteConflict, eng.putNodeTxn(kept, emptyNode(), t2));
        try testing.expectError(error.WriteConflict, eng.commitTxn(t2));
        // T1 first: its abort must not be refused because T2's bytes are
        // still on the page.
        try eng.abortTxn(t1);
        try eng.abortTxn(t2);
        // The aborts gave both ids back; T3 allocates its own.
        const t3 = try eng.beginTxn();
        kept = try eng.allocNode();
        try eng.putNodeTxn(kept, emptyNode(), t3);
        try eng.commitTxn(t3);

        try testing.expect((try eng.getNode(aborted)) == null);
        try testing.expect((try eng.getNode(kept)) != null);
        eng.deinit(); // crash: recovery replays T3's page image
    }

    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    try testing.expect((try eng.getNode(aborted)) == null);
    try testing.expect((try eng.getNode(kept)) != null);
    try testing.expectEqual(base.nodes + 1, try eng.nodeCount());
    try expectConsistent(eng, "after reopen");
}

test "SONNY-6529: an abort that cannot undo a write fails closed and the write is never checkpointed" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(12);
    const cfg = test_support.testConfig();

    var base: Base = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        base = try buildBase(eng);

        // The caller rewrites an adjacency entry itself and images the page
        // (geode's publishEdgePropHead shape): the engine cannot undo it.
        const txn = try eng.beginTxn();
        const ra = (try eng.getNode(base.a)).?;
        const h = try eng.putPropertyTxn(0, "w", .{ .int = 99 }, txn);
        const page = (try eng.adj_out.updateEdgePropHead(ra.out_head, base.ab, h)).?;
        try eng.logPagePublic(txn, .adj_out, page);
        try eng.edge_index.updatePropHead(base.ab, h);
        // SONNY-6657: another transaction was open meanwhile, so the abort
        // cannot discard the pages instead (they could carry its bytes).
        const other = try eng.beginTxn();
        try eng.commitTxn(other);
        try testing.expectError(error.AbortNotUndone, eng.abortTxn(txn));
        try testing.expectEqual(@as(u64, 1), eng.metrics.txn_aborts_not_undone);

        // Fail closed: no write, no checkpoint can make it durable.
        try testing.expectError(error.AbortNotUndone, eng.checkpoint());
        try testing.expectError(error.AbortNotUndone, eng.beginTxn());
        try testing.expectError(error.AbortNotUndone, eng.close());
    }

    // The store reopens at its last committed state.
    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    try expectBase(eng, alloc, &base, "after a refused abort and reopen");
}

test "SONNY-6657: the same abort with no other transaction open discards its pages and the engine stays writable" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(40);
    const cfg = test_support.testConfig();

    var base: Base = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        base = try buildBase(eng);
        const txn = try eng.beginTxn();
        const ra = (try eng.getNode(base.a)).?;
        const h = try eng.putPropertyTxn(0, "w", .{ .int = 99 }, txn);
        const page = (try eng.adj_out.updateEdgePropHead(ra.out_head, base.ab, h)).?;
        try eng.logPagePublic(txn, .adj_out, page);
        try eng.edge_index.updatePropHead(base.ab, h);
        try eng.abortTxn(txn);
        try testing.expectEqual(@as(u64, 1), eng.metrics.txn_aborts_discarded);
        try testing.expectEqual(@as(u64, 0), eng.metrics.txn_aborts_not_undone);
        try expectBase(eng, alloc, &base, "after a discard-abort");
        try eng.checkpoint();
        eng.deinit(); // crash
    }
    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    try expectBase(eng, alloc, &base, "after a discard-abort, checkpoint and crash");
}

test "SONNY-6529: abort_undo = .keep_writes keeps a write it cannot undo, as before, and stays writable" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    var cfg = test_support.testConfig();
    cfg.abort_undo = .keep_writes;
    const eng = try GraphEngine.create(alloc, td.path, uuidFor(13), cfg);
    defer eng.close() catch {};
    const base = try buildBase(eng);

    const txn = try eng.beginTxn();
    const ra = (try eng.getNode(base.a)).?;
    const h = try eng.putPropertyTxn(0, "w", .{ .int = 99 }, txn);
    const page = (try eng.adj_out.updateEdgePropHead(ra.out_head, base.ab, h)).?;
    try eng.logPagePublic(txn, .adj_out, page);
    try eng.abortTxn(txn);
    try testing.expectEqual(@as(u64, 1), eng.metrics.txn_aborts_not_undone);
    // The caller's write stays (the old behaviour).
    var it = try eng.expandOutIter(base.a, null);
    defer it.deinit();
    try testing.expectEqual(h, (try it.next()).?.prop_head);

    // Undoable transactions are still undone under this policy.
    const t2 = try eng.beginTxn();
    const n = try eng.allocNode();
    try eng.putNodeTxn(n, emptyNode(), t2);
    try eng.abortTxn(t2);
    try testing.expect((try eng.getNode(n)) == null);
    try eng.checkpoint();
}

test "SONNY-6529: ShardedGraphEngine: an aborted shard transaction is undone across a crash" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(14);
    var cfg = test_support.testConfig();
    cfg.sync_mode = .deferred;

    var a: u64 = 0;
    var b: u64 = 0;
    var n: u64 = 0;
    {
        const eng = try gs.ShardedGraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        const l = try eng.getOrAssignLabel("L");
        a = try eng.allocNode();
        try eng.putNode(a, emptyNode());
        b = try eng.allocNode();
        try eng.putNode(b, emptyNode());
        _ = try eng.addEdgeColocatedWithPublicId(a, b, REL, 0xD1);
        try eng.checkpoint();

        // A statement on a's shard: a new node with a property and a label,
        // and an edge a -> new node; then aborted.
        const shard = eng.shards[gs.shard_count.shardOfNode(a)];
        const txn = try shard.beginTxn();
        n = try shard.allocNode();
        try shard.putNodeTxn(n, emptyNode(), txn);
        const h = try shard.putPropertyTxn(0, "k", .{ .int = 1 }, txn);
        var rec = (try shard.getNode(n)).?;
        rec.prop_head = h;
        try shard.putNodeTxn(n, rec, txn);
        try shard.addLabelTxn(n, l, txn);
        _ = try shard.addEdgeColocatedTxnWithPublicId(a, n, REL, txn, 0xD2);
        try shard.abortTxn(txn);
        eng.deinit(); // crash
    }

    const eng = try gs.ShardedGraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    try testing.expect((try eng.getNode(n)) == null);
    try testing.expectEqual(@as(u64, 2), try eng.nodeCount());
    try testing.expectEqual(@as(u64, 1), try eng.edgeCount());
    const shard = eng.shards[gs.shard_count.shardOfNode(a)];
    const outs = try outEdgeIds(shard, alloc, a);
    defer alloc.free(outs);
    try testing.expectEqual(@as(usize, 1), outs.len);
    try expectConsistent(shard, "sharded, after reopen");
}
