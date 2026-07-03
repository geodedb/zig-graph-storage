// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const testing = std.testing;
const graph_storage = @import("graph_storage");
const test_support = graph_storage.test_support;
const wal_record = graph_storage.wal_record;
const two_pc = graph_storage.sharded_engine_2pc;

/// Serialize a WAL record with a CORRUPTED stored checksum (the trailing 4
/// checksum bytes are flipped so they no longer match the record contents),
/// then inject the raw bytes verbatim into the given shard's WAL. This bypasses
/// `appendRecord`'s checksum recomputation so we can exercise the strict,
/// fail-closed recovery path against a forged record.
fn injectCorruptedRecord(
    eng: *graph_storage.GraphEngine,
    record_type: wal_record.WalRecordType,
    txn_id: u64,
    payload: []const u8,
) !void {
    var rec = wal_record.WalRecord{
        .lsn = 0,
        .txn_id = txn_id,
        .record_type = record_type,
        .file_id = 0,
        .page_id = 0,
        .payload = payload,
        .checksum = 0,
    };
    const bytes = try rec.serialize(testing.allocator);
    defer testing.allocator.free(bytes);
    // Flip every byte of the trailing 4-byte checksum so the stored checksum
    // can never match `computeChecksum()` over the record contents.
    const n = bytes.len;
    bytes[n - 4] ^= 0xFF;
    bytes[n - 3] ^= 0xFF;
    bytes[n - 2] ^= 0xFF;
    bytes[n - 1] ^= 0xFF;
    _ = try eng.wal.appendRawForTest(bytes);
    try eng.wal.sync();
}

// Edge co-location (Phase C): the two edge-specific 2PC crash-recovery tests
// that lived here ("crash after both prepares → edge not visible" and "crash
// after source commit → edge visible after reopen") encoded the OLD cross-shard
// edge 2PC behavior. Edges are now SINGLE-shard writes (no cross_shard_prepare/
// commit records are emitted for an edge), so those scenarios — and the
// `addEdgeCrashAfter{Prepares,SourceCommit}` test hooks that produced them — no
// longer exist. Single-shard edge crash recovery is covered by
// tests/edge_colocation.zig ("crash + reopen rebuilds in-index via page-image
// redo"). The SEC-0041 tests below are retained: they exercise the cross-shard
// reconciler's FAIL-CLOSED behavior against forged/corrupted WAL records (kept
// for any future genuinely cross-shard op), independently of edge writes.

test "SEC-0041: reconciler fails closed on a corrupted-checksum record in a shard WAL" {
    // Exercise the cross-shard 2PC reconciler in isolation from the per-shard
    // intra-shard recovery pass. `create` does NOT run recovery, so the
    // corrupted record we inject reaches the reconciler unguarded. A lenient
    // reconciler (readFrom + `catch continue`, no checksum check) silently
    // skips/accepts it; the strict reconciler must fail closed.
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x82} ** 16;

    var eng = try graph_storage.ShardedGraphEngine.create(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.deinit();

    const n = try eng.shards[0].allocNode();
    try eng.putNode(n, test_support.emptyNode(1));

    // Inject a cross-shard record into shard 0's WAL whose stored checksum does
    // not match its contents (a forged record). The payload itself decodes
    // fine, so a lenient reconciler would happily process it.
    const gid: u64 = 0xFEED_FACE;
    var decision_payload: [8]u8 = undefined;
    two_pc.encodeDecisionPayload(&decision_payload, gid);
    try injectCorruptedRecord(eng.shards[0], .cross_shard_commit, 7, &decision_payload);

    const result = graph_storage.sharded_recovery.reconcilePendingPrepares(eng);
    try testing.expectError(error.ChecksumMismatch, result);
}

test "SEC-0041: reconciler does not forge an edge from a bad-checksum prepare+commit" {
    // A crafted source-role `cross_shard_prepare` + matching `cross_shard_commit`
    // with a corrupted checksum must NOT cause the reconciler to replay the
    // adjacency write (forge the edge). The reconciler must fail closed and the
    // edge must be absent.
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x83} ** 16;

    var eng = try graph_storage.ShardedGraphEngine.create(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.deinit();

    const from = try eng.shards[0].allocNode();
    const to = try eng.shards[5].allocNode();
    try eng.putNode(from, test_support.emptyNode(1));
    try eng.putNode(to, test_support.emptyNode(1));

    // Pick an edge id that routes to shard 0 (source shard) but is NOT present
    // anywhere yet.
    const forged_edge_id = from + @as(u64, @intCast(graph_storage.shard_count.SHARD_COUNT)) * 7;

    const gid: u64 = 0xDEAD_BEEF;
    var prepare_payload: [two_pc.PREPARE_PAYLOAD_SIZE]u8 = undefined;
    two_pc.encodePreparePayload(&prepare_payload, gid, .source, 5, forged_edge_id, from, to, 1);
    try injectCorruptedRecord(eng.shards[0], .cross_shard_prepare, 99, &prepare_payload);

    var decision_payload: [8]u8 = undefined;
    two_pc.encodeDecisionPayload(&decision_payload, gid);
    try injectCorruptedRecord(eng.shards[5], .cross_shard_commit, 99, &decision_payload);

    // The reconciler must fail closed instead of forging the edge.
    const result = graph_storage.sharded_recovery.reconcilePendingPrepares(eng);
    try testing.expectError(error.ChecksumMismatch, result);

    // And the forged edge must not have been materialized on the source shard.
    const got = try eng.getEdge(forged_edge_id);
    try testing.expect(got == null);
}

test "SEC-0041: full open fails closed on a corrupted cross-shard record" {
    // End-to-end: an attacker-corrupted record persisted in a shard WAL must
    // make ShardedGraphEngine.open fail closed rather than silently recover.
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x85} ** 16;

    {
        var eng = try graph_storage.ShardedGraphEngine.create(
            testing.allocator,
            td.path,
            uuid,
            test_support.testConfig(),
        );
        const n = try eng.shards[0].allocNode();
        try eng.putNode(n, test_support.emptyNode(1));
        const gid: u64 = 0xC0DE_C0DE;
        var decision_payload: [8]u8 = undefined;
        two_pc.encodeDecisionPayload(&decision_payload, gid);
        try injectCorruptedRecord(eng.shards[0], .cross_shard_commit, 7, &decision_payload);
        eng.deinit();
    }

    const open_result = graph_storage.ShardedGraphEngine.open(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    try testing.expectError(error.ChecksumMismatch, open_result);
}

// Edge co-location (Phase C): the "larger valid WAL still reconciles a committed
// cross-shard edge" test was removed with the `addEdgeCrashAfterSourceCommit`
// hook — it was the only way to produce a committed dangling cross-shard EDGE
// prepare, and edges are now single-shard (no such record is ever emitted). The
// reconciler's streaming fail-closed behavior on forged records remains covered
// by the SEC-0041 tests above.

test "M1: reconciled legacy 2PC edge id is never re-issued by post-open edge creates" {
    // A LEGACY (pre-co-location) dangling prepared cross-shard edge carries an
    // edge id allocated by the old 2PC path. The reconciler re-applies that
    // edge AFTER the per-shard counter heal — the heal cannot see it (the
    // prepare payload is not a committed page image), so `payload.edge_id` can
    // sit ABOVE the healed next_edge_id. Without a post-reconcile counter
    // bump, allocEdge later re-issues exactly that id and the edge_index put
    // silently overwrites the reconciled edge.
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x86} ** 16;
    const cfg = test_support.testConfig();
    const stride: u64 = @intCast(graph_storage.shard_count.SHARD_COUNT);

    var from: u64 = 0;
    var to: u64 = 0;
    var reconciled_eid: u64 = 0;
    const gid: u64 = 0xBEEF_0001;

    {
        var eng = try graph_storage.ShardedGraphEngine.create(
            testing.allocator,
            td.path,
            uuid,
            cfg,
        );
        errdefer eng.close() catch {};

        from = try eng.shards[0].allocNode(); // source shard 0
        to = try eng.shards[5].allocNode(); // target shard 5
        try eng.putNode(from, test_support.emptyNode(1));
        try eng.putNode(to, test_support.emptyNode(1));
        // Durable baseline: the WAL tail below holds NO committed edge page
        // images, so the per-shard heal leaves next_edge_id at this value.
        try eng.checkpoint();

        // Dangling edge id: in shard 0's residue class, several strides ABOVE
        // the (checkpoint-durable, heal-invisible) counter.
        reconciled_eid = eng.shards[0].manifest.next_edge_id + stride * 4;

        // Legacy 2PC shape: prepare on source (shard 0) + prepare on target
        // (shard 5) + COMMIT decision logged only by the peer — the source
        // crashed before its local decision, leaving its prepare dangling.
        var prep_src: [two_pc.PREPARE_PAYLOAD_SIZE]u8 = undefined;
        two_pc.encodePreparePayload(&prep_src, gid, .source, 5, reconciled_eid, from, to, 1);
        _ = try two_pc.appendPrepare(eng.shards[0], prep_src, 41);
        var prep_tgt: [two_pc.PREPARE_PAYLOAD_SIZE]u8 = undefined;
        two_pc.encodePreparePayload(&prep_tgt, gid, .target, 0, reconciled_eid, from, to, 1);
        _ = try two_pc.appendPrepare(eng.shards[5], prep_tgt, 42);
        _ = try two_pc.appendDecision(eng.shards[5], .cross_shard_commit, gid, 42);

        // SIMULATED CRASH.
        eng.deinit();
    }

    var eng = try graph_storage.ShardedGraphEngine.open(
        testing.allocator,
        td.path,
        uuid,
        cfg,
    );
    defer eng.close() catch {};

    // The reconciler re-applied the committed dangling edge (legacy record:
    // public_id 0 by construction).
    const got = (try eng.getEdge(reconciled_eid)) orelse return error.ReconciledEdgeMissing;
    try testing.expectEqual(to, got.neighbor);
    try testing.expectEqual(@as(u64, 0), got.public_id);

    // Counter bumped ABOVE the reconciled id, residue class preserved.
    if (eng.shards[0].manifest.next_edge_id <= reconciled_eid) {
        std.debug.print(
            "shard 0 next_edge_id {d} not raised above reconciled legacy edge id {d} — the id WILL be re-issued\n",
            .{ eng.shards[0].manifest.next_edge_id, reconciled_eid },
        );
    }
    try testing.expect(eng.shards[0].manifest.next_edge_id > reconciled_eid);
    try testing.expectEqual(reconciled_eid % stride, eng.shards[0].manifest.next_edge_id % stride);

    // Aggressive creates through the normal edge-id path: more strides than
    // the gap between the healed counter and the reconciled id, so a missing
    // bump MUST collide.
    for (0..8) |i| {
        const eid = try eng.addEdgeColocatedWithPublicId(from, to, 1, 0xAB00_0000 | @as(u64, @intCast(i + 1)));
        if (eid == reconciled_eid) {
            std.debug.print("allocEdge RE-ISSUED reconciled legacy edge id {d}\n", .{eid});
            return error.EdgeSlotReissued;
        }
    }

    // The reconciled edge is still byte-intact — a collision would have
    // overwritten its edge_index entry with a nonzero public id.
    const after = (try eng.getEdge(reconciled_eid)) orelse return error.ReconciledEdgeLost;
    try testing.expectEqual(@as(u64, 0), after.public_id);
    try testing.expectEqual(to, after.neighbor);
}
