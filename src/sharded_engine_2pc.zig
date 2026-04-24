// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Cross-shard edge-create 2PC helpers for ShardedGraphEngine.
//! See docs/superpowers/specs/2026-04-24-sharded-graph-engine-design.md
//! §Cross-shard operations.1 and §WAL and durability.

const std = @import("std");
const engine_mod = @import("engine.zig");
const wal_record_mod = @import("wal_record.zig");
const types = @import("types.zig");

const NodeId = types.NodeId;
const EdgeId = types.EdgeId;
const GraphEngine = engine_mod.GraphEngine;
const WalRecord = wal_record_mod.WalRecord;

/// Payload layout for `cross_shard_prepare`:
///   global_txn_id: u64  (8 bytes)
///   role: u8            (0 = source, 1 = target)  (1 byte)
///   peer_shard: u16                                 (2 bytes)
///   edge_id: u64                                    (8 bytes)
///   from: u64                                       (8 bytes)
///   to: u64                                         (8 bytes)
///   rel_type: u32                                   (4 bytes)
/// Total: 39 bytes.
pub const PREPARE_PAYLOAD_SIZE: usize = 39;

pub const Role = enum(u8) { source = 0, target = 1 };

pub fn encodePreparePayload(
    buf: *[PREPARE_PAYLOAD_SIZE]u8,
    global_txn_id: u64,
    role: Role,
    peer_shard: u16,
    edge_id: EdgeId,
    from: NodeId,
    to: NodeId,
    rel_type: u32,
) void {
    std.mem.writeInt(u64, buf[0..8], global_txn_id, .little);
    buf[8] = @intFromEnum(role);
    std.mem.writeInt(u16, buf[9..11], peer_shard, .little);
    std.mem.writeInt(u64, buf[11..19], edge_id, .little);
    std.mem.writeInt(u64, buf[19..27], from, .little);
    std.mem.writeInt(u64, buf[27..35], to, .little);
    std.mem.writeInt(u32, buf[35..39], rel_type, .little);
}

pub const PreparePayload = struct {
    global_txn_id: u64,
    role: Role,
    peer_shard: u16,
    edge_id: EdgeId,
    from: NodeId,
    to: NodeId,
    rel_type: u32,
};

pub fn decodePreparePayload(buf: []const u8) !PreparePayload {
    if (buf.len != PREPARE_PAYLOAD_SIZE) return error.InvalidPreparePayload;
    const role_byte = buf[8];
    if (role_byte > 1) return error.InvalidPreparePayload;
    return .{
        .global_txn_id = std.mem.readInt(u64, buf[0..8], .little),
        .role = @enumFromInt(role_byte),
        .peer_shard = std.mem.readInt(u16, buf[9..11], .little),
        .edge_id = std.mem.readInt(u64, buf[11..19], .little),
        .from = std.mem.readInt(u64, buf[19..27], .little),
        .to = std.mem.readInt(u64, buf[27..35], .little),
        .rel_type = std.mem.readInt(u32, buf[35..39], .little),
    };
}

pub fn encodeDecisionPayload(buf: *[8]u8, global_txn_id: u64) void {
    std.mem.writeInt(u64, buf, global_txn_id, .little);
}

pub fn decodeDecisionPayload(buf: []const u8) !u64 {
    if (buf.len != 8) return error.InvalidDecisionPayload;
    return std.mem.readInt(u64, buf[0..8], .little);
}

/// Append a cross_shard_prepare record to the given shard's WAL and
/// fsync. Returns the assigned LSN.
pub fn appendPrepare(eng: *GraphEngine, payload: [PREPARE_PAYLOAD_SIZE]u8, txn_id: u64) !u64 {
    var payload_buf = payload;
    var rec = WalRecord{
        .lsn = 0,
        .txn_id = txn_id,
        .record_type = .cross_shard_prepare,
        .file_id = 0,
        .page_id = 0,
        .payload = &payload_buf,
        .checksum = 0,
    };
    rec.checksum = rec.computeChecksum();
    const lsn = try eng.wal.appendRecord(&rec);
    try eng.wal.sync();
    return lsn;
}

pub fn appendDecision(
    eng: *GraphEngine,
    record_type: wal_record_mod.WalRecordType,
    global_txn_id: u64,
    txn_id: u64,
) !u64 {
    var payload: [8]u8 = undefined;
    encodeDecisionPayload(&payload, global_txn_id);
    var rec = WalRecord{
        .lsn = 0,
        .txn_id = txn_id,
        .record_type = record_type,
        .file_id = 0,
        .page_id = 0,
        .payload = &payload,
        .checksum = 0,
    };
    rec.checksum = rec.computeChecksum();
    const lsn = try eng.wal.appendRecord(&rec);
    try eng.wal.sync();
    return lsn;
}

test "prepare payload round-trips" {
    var buf: [PREPARE_PAYLOAD_SIZE]u8 = undefined;
    encodePreparePayload(&buf, 123, .source, 7, 42, 100, 200, 3);
    const p = try decodePreparePayload(&buf);
    try std.testing.expectEqual(@as(u64, 123), p.global_txn_id);
    try std.testing.expectEqual(Role.source, p.role);
    try std.testing.expectEqual(@as(u16, 7), p.peer_shard);
    try std.testing.expectEqual(@as(EdgeId, 42), p.edge_id);
    try std.testing.expectEqual(@as(NodeId, 100), p.from);
    try std.testing.expectEqual(@as(NodeId, 200), p.to);
    try std.testing.expectEqual(@as(u32, 3), p.rel_type);
}

test "decision payload round-trips" {
    var buf: [8]u8 = undefined;
    encodeDecisionPayload(&buf, 0xCAFEBABE);
    try std.testing.expectEqual(@as(u64, 0xCAFEBABE), try decodeDecisionPayload(&buf));
}

test {
    std.testing.refAllDecls(@This());
}
