// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! ShardedGraphEngine — facade over N independent single-threaded
//! GraphEngine instances, one per shard. See
//! docs/superpowers/specs/2026-04-24-sharded-graph-engine-design.md.

const std = @import("std");
const Allocator = std.mem.Allocator;

const config_mod = @import("config.zig");
const engine_mod = @import("engine.zig");
const interface_mod = @import("interface.zig");
const shard_count_mod = @import("shard_count.zig");
const shard_manifest_mod = @import("shard_manifest.zig");
const shard_uuid_mod = @import("shard_uuid.zig");

const GraphConfig = config_mod.GraphConfig;
const GraphEngine = engine_mod.GraphEngine;
const GraphStorage = interface_mod.GraphStorage;

pub const SHARD_COUNT = shard_count_mod.SHARD_COUNT;

pub const ShardedGraphEngine = struct {
    allocator: Allocator,
    graph_uuid: [16]u8,
    graph_root: []u8, // owned, "<data_dir>/<graph_uuid_hex>"
    shards: [SHARD_COUNT]*GraphEngine,
    shard_manifest: shard_manifest_mod.ShardManifest,
    coordinator_txn_counter: std.atomic.Value(u64),

    pub fn create(
        allocator: Allocator,
        data_dir: []const u8,
        graph_uuid: [16]u8,
        cfg: GraphConfig,
    ) !*ShardedGraphEngine {
        const self = try allocator.create(ShardedGraphEngine);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.graph_uuid = graph_uuid;
        self.coordinator_txn_counter = std.atomic.Value(u64).init(0);

        const uuid_hex_buf = uuidHex(graph_uuid);
        self.graph_root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, uuid_hex_buf[0..] });
        errdefer allocator.free(self.graph_root);

        const io = std.Io.Threaded.global_single_threaded.io();
        try std.Io.Dir.cwd().createDirPath(io, self.graph_root);

        var per_shard: [SHARD_COUNT][16]u8 = undefined;
        for (&per_shard, 0..) |*u, s| {
            u.* = shard_uuid_mod.deriveShardUuid(graph_uuid, s);
        }

        self.shard_manifest = .{
            .version = shard_manifest_mod.SHARD_MANIFEST_VERSION,
            .shard_count = @intCast(SHARD_COUNT),
            .algorithm_hash = shard_manifest_mod.SHARD_ALGORITHM_HASH,
            .per_shard_uuids = per_shard,
        };

        try shard_manifest_mod.writeToDir(allocator, self.graph_root, self.shard_manifest);

        var created: usize = 0;
        errdefer for (self.shards[0..created]) |e| e.close() catch {};

        for (0..SHARD_COUNT) |s| {
            var per_shard_cfg = cfg;
            per_shard_cfg.base_shard_index = s;
            per_shard_cfg.buffer_pool_pages = @max(1, cfg.buffer_pool_pages / @as(u32, @intCast(SHARD_COUNT)));
            self.shards[s] = try GraphEngine.create(allocator, self.graph_root, per_shard[s], per_shard_cfg);
            created += 1;
        }

        return self;
    }

    pub fn open(
        allocator: Allocator,
        data_dir: []const u8,
        graph_uuid: [16]u8,
        cfg: GraphConfig,
    ) !*ShardedGraphEngine {
        const self = try allocator.create(ShardedGraphEngine);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.graph_uuid = graph_uuid;
        self.coordinator_txn_counter = std.atomic.Value(u64).init(0);

        const uuid_hex_buf = uuidHex(graph_uuid);
        self.graph_root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, uuid_hex_buf[0..] });
        errdefer allocator.free(self.graph_root);

        self.shard_manifest = try shard_manifest_mod.readFromDir(allocator, self.graph_root);

        var opened: usize = 0;
        errdefer for (self.shards[0..opened]) |e| e.close() catch {};

        for (0..SHARD_COUNT) |s| {
            var per_shard_cfg = cfg;
            per_shard_cfg.base_shard_index = s;
            per_shard_cfg.buffer_pool_pages = @max(1, cfg.buffer_pool_pages / @as(u32, @intCast(SHARD_COUNT)));
            self.shards[s] = try GraphEngine.open(
                allocator,
                self.graph_root,
                self.shard_manifest.per_shard_uuids[s],
                per_shard_cfg,
            );
            opened += 1;
        }

        return self;
    }

    pub fn close(self: *ShardedGraphEngine) !void {
        var first_err: ?anyerror = null;
        for (self.shards) |eng| {
            eng.close() catch |err| {
                if (first_err == null) first_err = err;
            };
        }
        self.allocator.free(self.graph_root);
        self.allocator.destroy(self);
        if (first_err) |err| return err;
    }

    pub fn deinit(self: *ShardedGraphEngine) void {
        for (self.shards) |eng| eng.deinit();
        self.allocator.free(self.graph_root);
        self.allocator.destroy(self);
    }
};

pub fn uuidHex(uuid: [16]u8) [32]u8 {
    var out: [32]u8 = undefined;
    const hex = "0123456789abcdef";
    for (uuid, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0F];
    }
    return out;
}

test {
    _ = @import("sharded_engine_test.zig");
}
