// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const config_mod = @import("config.zig");
const node_mod = @import("node.zig");

const Allocator = std.mem.Allocator;
const GraphConfig = config_mod.GraphConfig;
const NodeRec = node_mod.NodeRec;

pub const TestDataDir = struct {
    allocator: Allocator,
    tmp_dir: std.testing.TmpDir,
    path: []const u8,

    pub fn init(allocator: Allocator) !TestDataDir {
        var tmp_dir = std.testing.tmpDir(.{});
        const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
        return .{
            .allocator = allocator,
            .tmp_dir = tmp_dir,
            .path = path,
        };
    }

    pub fn deinit(self: *TestDataDir) void {
        self.allocator.free(self.path);
        self.tmp_dir.cleanup();
    }
};

pub fn testConfig() GraphConfig {
    return .{
        .page_size = 4096,
        .buffer_pool_pages = 64,
        .data_dir = "data",
    };
}

pub fn emptyNode(txn_stamp: u64) NodeRec {
    return .{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = txn_stamp,
    };
}
