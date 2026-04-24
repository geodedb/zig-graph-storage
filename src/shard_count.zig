// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Centralises the shard-count constant and the two shard-routing
//! helpers the `ShardedGraphEngine` uses.
//!
//! Routing uses plain `id % SHARD_COUNT`, NOT the splitmix64 mixer
//! in `sharded_store.shardIndex`. This matters because the engine
//! allocates striped ids (`k*SHARD_COUNT + base_shard_index`) so
//! that `shardOfNode(allocated_id) == base_shard_index` holds by
//! construction. An avalanching mixer would break that invariant
//! and misroute ops across shards.
//!
//! `sharded_store.shardIndex` remains the right choice for the
//! in-memory `ShardedStore` primitive, where keys come from the
//! outside world and need avalanche to spread uniformly. The two
//! routing functions are deliberately different.

const std = @import("std");
const sharded_store = @import("sharded_store.zig");

/// Number of shards per logical graph. Build-time constant; changing
/// it requires a data-dir migration (see `shard_manifest.zig`).
pub const SHARD_COUNT: usize = sharded_store.SHARD_COUNT;

/// Route a node id to its owning shard. Plain modulo so striped
/// allocation (`k*N + s`) routes back to shard `s`.
pub fn shardOfNode(node_id: u64) usize {
    return @as(usize, @intCast(node_id % @as(u64, @intCast(SHARD_COUNT))));
}

/// Edges co-locate with their source node — route by source id.
pub fn shardOfEdgeSource(source_node_id: u64) usize {
    return shardOfNode(source_node_id);
}

test {
    std.testing.refAllDecls(@This());
}

test "SHARD_COUNT matches sharded_store.SHARD_COUNT" {
    try std.testing.expectEqual(sharded_store.SHARD_COUNT, @import("shard_count.zig").SHARD_COUNT);
}

test "shardOfNode is simple id % SHARD_COUNT" {
    const mod = @import("shard_count.zig");
    try std.testing.expectEqual(@as(usize, 0), mod.shardOfNode(0));
    try std.testing.expectEqual(@as(usize, 3), mod.shardOfNode(3));
    try std.testing.expectEqual(@as(usize, 3), mod.shardOfNode(3 + SHARD_COUNT));
    try std.testing.expectEqual(@as(usize, 3), mod.shardOfNode(3 + 2 * SHARD_COUNT));
}

test "striped allocation round-trips through shardOfNode" {
    const mod = @import("shard_count.zig");
    var s: u64 = 0;
    while (s < SHARD_COUNT) : (s += 1) {
        var k: u64 = 0;
        while (k < 32) : (k += 1) {
            const id = k * @as(u64, @intCast(SHARD_COUNT)) + s;
            try std.testing.expectEqual(@as(usize, @intCast(s)), mod.shardOfNode(id));
        }
    }
}

test "shardOfEdgeSource agrees with shardOfNode on the source id" {
    const mod = @import("shard_count.zig");
    const src: u64 = 17;
    try std.testing.expectEqual(mod.shardOfNode(src), mod.shardOfEdgeSource(src));
}
