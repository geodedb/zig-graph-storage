// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const config_mod = @import("config.zig");
const node_mod = @import("node.zig");
const types = @import("types.zig");
const buffer_pool_mod = @import("buffer_pool.zig");
const free_space_mod = @import("free_space.zig");
const pager_mod = @import("pager.zig");

const Allocator = std.mem.Allocator;
const GraphConfig = config_mod.GraphConfig;
const NodeRec = node_mod.NodeRec;
const FileId = types.FileId;
const BufferPool = buffer_pool_mod.BufferPool;
const FreeSpaceManager = free_space_mod.FreeSpaceManager;
const Pager = pager_mod.Pager;

pub const TestDataDir = struct {
    allocator: Allocator,
    tmp_dir: std.testing.TmpDir,
    path: [:0]const u8,

    pub fn init(allocator: Allocator) !TestDataDir {
        var tmp_dir = std.testing.tmpDir(.{});
        const path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
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

pub const SingleStoreEnv = struct {
    pool: BufferPool,
    fsm: FreeSpaceManager,
    tmp_dir: std.testing.TmpDir,
    file: std.Io.File,
    pager: Pager,
    file_id: FileId,

    pub fn init(
        allocator: Allocator,
        file_id: FileId,
        file_name: []const u8,
        page_size: u32,
        buffer_pool_pages: u32,
    ) !SingleStoreEnv {
        var tmp_dir = std.testing.tmpDir(.{});
        const file = try tmp_dir.dir.createFile(std.Io.Threaded.global_single_threaded.io(), file_name, .{ .read = true, .truncate = true });
        var pool = try BufferPool.init(allocator, page_size, buffer_pool_pages);
        const fsm = try FreeSpaceManager.init(allocator, &pool, file_id);

        return .{
            .pool = pool,
            .fsm = fsm,
            .tmp_dir = tmp_dir,
            .file = file,
            .pager = Pager.init(file, page_size),
            .file_id = file_id,
        };
    }

    pub fn register(self: *SingleStoreEnv) void {
        self.pool.registerPager(self.file_id, &self.pager);
        self.fsm.buffer_pool = &self.pool;
    }

    pub fn deinit(self: *SingleStoreEnv) void {
        self.fsm.deinit();
        self.pool.deinit();
        self.file.close(std.Io.Threaded.global_single_threaded.io());
        self.tmp_dir.cleanup();
    }
};

pub const DualStoreEnv = struct {
    pool: BufferPool,
    fsm: FreeSpaceManager,
    tmp_dir: std.testing.TmpDir,
    primary_file: std.Io.File,
    primary_pager: Pager,
    primary_id: FileId,
    secondary_file: std.Io.File,
    secondary_pager: Pager,
    secondary_id: FileId,

    pub fn init(
        allocator: Allocator,
        fsm_file_id: FileId,
        primary_id: FileId,
        primary_name: []const u8,
        secondary_id: FileId,
        secondary_name: []const u8,
        page_size: u32,
        buffer_pool_pages: u32,
    ) !DualStoreEnv {
        var tmp_dir = std.testing.tmpDir(.{});
        const primary_file = try tmp_dir.dir.createFile(std.Io.Threaded.global_single_threaded.io(), primary_name, .{ .read = true, .truncate = true });
        const secondary_file = try tmp_dir.dir.createFile(std.Io.Threaded.global_single_threaded.io(), secondary_name, .{ .read = true, .truncate = true });
        var pool = try BufferPool.init(allocator, page_size, buffer_pool_pages);
        const fsm = try FreeSpaceManager.init(allocator, &pool, fsm_file_id);

        return .{
            .pool = pool,
            .fsm = fsm,
            .tmp_dir = tmp_dir,
            .primary_file = primary_file,
            .primary_pager = Pager.init(primary_file, page_size),
            .primary_id = primary_id,
            .secondary_file = secondary_file,
            .secondary_pager = Pager.init(secondary_file, page_size),
            .secondary_id = secondary_id,
        };
    }

    pub fn register(self: *DualStoreEnv) void {
        self.pool.registerPager(self.primary_id, &self.primary_pager);
        self.pool.registerPager(self.secondary_id, &self.secondary_pager);
        self.fsm.buffer_pool = &self.pool;
    }

    pub fn deinit(self: *DualStoreEnv) void {
        self.fsm.deinit();
        self.pool.deinit();
        self.primary_file.close(std.Io.Threaded.global_single_threaded.io());
        self.secondary_file.close(std.Io.Threaded.global_single_threaded.io());
        self.tmp_dir.cleanup();
    }
};
