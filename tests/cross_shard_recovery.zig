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

test "recovery: crash after both prepares with no commit → edge not visible after reopen" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x80} ** 16;

    {
        var eng = try graph_storage.ShardedGraphEngine.create(
            testing.allocator,
            td.path,
            uuid,
            test_support.testConfig(),
        );
        const n_src = try eng.shards[0].allocNode();
        const n_dst = try eng.shards[5].allocNode();
        try eng.putNode(n_src, test_support.emptyNode(1));
        try eng.putNode(n_dst, test_support.emptyNode(1));
        try eng.addEdgeCrashAfterPrepares(n_src, n_dst, 1);
        eng.deinit();
    }

    var eng = try graph_storage.ShardedGraphEngine.open(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    try testing.expectEqual(@as(u64, 0), try eng.edgeCount());
}

test "recovery: crash after source commit, before target commit → edge visible after reopen" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x81} ** 16;

    var n_src_saved: u64 = 0;
    var n_dst_saved: u64 = 0;
    var edge_saved: u64 = 0;
    {
        var eng = try graph_storage.ShardedGraphEngine.create(
            testing.allocator,
            td.path,
            uuid,
            test_support.testConfig(),
        );
        n_src_saved = try eng.shards[0].allocNode();
        n_dst_saved = try eng.shards[5].allocNode();
        try eng.putNode(n_src_saved, test_support.emptyNode(1));
        try eng.putNode(n_dst_saved, test_support.emptyNode(1));
        edge_saved = try eng.addEdgeCrashAfterSourceCommit(n_src_saved, n_dst_saved, 1);
        eng.deinit();
    }

    var eng = try graph_storage.ShardedGraphEngine.open(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    const got = try eng.getEdge(edge_saved);
    try testing.expect(got != null);
    try testing.expectEqual(n_dst_saved, got.?.neighbor);
}

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

test "SEC-0041: larger valid WAL still reconciles a committed cross-shard edge" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x84} ** 16;

    var n_src_saved: u64 = 0;
    var n_dst_saved: u64 = 0;
    var edge_saved: u64 = 0;
    {
        var eng = try graph_storage.ShardedGraphEngine.create(
            testing.allocator,
            td.path,
            uuid,
            test_support.testConfig(),
        );
        n_src_saved = try eng.shards[0].allocNode();
        n_dst_saved = try eng.shards[5].allocNode();
        try eng.putNode(n_src_saved, test_support.emptyNode(1));
        try eng.putNode(n_dst_saved, test_support.emptyNode(1));

        // Generate a larger volume of legitimate WAL traffic so the streaming
        // reconciler is exercised against a non-trivial log (PERF-0053:
        // streaming must not materialize the whole WAL).
        var i: u64 = 0;
        while (i < 256) : (i += 1) {
            const node = try eng.shards[0].allocNode();
            try eng.putNode(node, test_support.emptyNode(1));
        }

        edge_saved = try eng.addEdgeCrashAfterSourceCommit(n_src_saved, n_dst_saved, 1);
        eng.deinit();
    }

    var eng = try graph_storage.ShardedGraphEngine.open(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    const got = try eng.getEdge(edge_saved);
    try testing.expect(got != null);
    try testing.expectEqual(n_dst_saved, got.?.neighbor);
}
