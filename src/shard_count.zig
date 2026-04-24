// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Centralises the shard-count constant and the two shard-routing
//! helpers the `ShardedGraphEngine` uses. Kept in its own module so
//! tests and callers import a single canonical `SHARD_COUNT` rather
//! than importing `sharded_store` (which is the in-memory primitive)
//! when they only want the routing math.

const std = @import("std");
const sharded_store = @import("sharded_store.zig");

/// Number of shards per logical graph. Build-time constant; changing
/// it requires a data-dir migration (see `shard_manifest.zig`).
pub const SHARD_COUNT: usize = sharded_store.SHARD_COUNT;

/// Route a node id to its owning shard.
pub fn shardOfNode(node_id: u64) usize {
    return sharded_store.shardIndex(node_id);
}

/// Edges co-locate with their source node.
pub fn shardOfEdgeSource(source_node_id: u64) usize {
    return sharded_store.shardIndex(source_node_id);
}

test {
    std.testing.refAllDecls(@This());
}

test "SHARD_COUNT matches sharded_store.SHARD_COUNT" {
    try std.testing.expectEqual(sharded_store.SHARD_COUNT, @import("shard_count.zig").SHARD_COUNT);
}

test "shardOfNode returns splitmix64(id) % SHARD_COUNT" {
    const mod = @import("shard_count.zig");
    try std.testing.expectEqual(sharded_store.shardIndex(42), mod.shardOfNode(42));
    try std.testing.expectEqual(sharded_store.shardIndex(0), mod.shardOfNode(0));
}

test "shardOfEdgeSource routes by source node id" {
    const mod = @import("shard_count.zig");
    const src: u64 = 17;
    try std.testing.expectEqual(mod.shardOfNode(src), mod.shardOfEdgeSource(src));
}
