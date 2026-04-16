// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;

const page_mod = @import("page.zig");
const manifest_mod = @import("manifest.zig");
const graph_dir_mod = @import("graph_dir.zig");
const file_manager_mod = @import("file_manager.zig");
const integrity_mod = @import("integrity.zig");
const operation_result_mod = @import("operation_result.zig");
const label_dict_mod = @import("label_dict.zig");
const wal_mod = @import("wal.zig");
const wal_record_mod = @import("wal_record.zig");
const types = @import("types.zig");

const Manifest = manifest_mod.Manifest;
const GraphDir = graph_dir_mod.GraphDir;
const Integrity = integrity_mod.Integrity;
const GraphOperationSummary = operation_result_mod.GraphOperationSummary;
const OperationArtifact = operation_result_mod.OperationArtifact;
const OperationArtifactStatus = operation_result_mod.OperationArtifactStatus;
const LabelDictionary = label_dict_mod.LabelDictionary;
const WalManager = wal_mod.WalManager;
const WalRecord = wal_record_mod.WalRecord;
const FileId = types.FileId;
const PAGE_HEADER_SIZE = page_mod.PAGE_HEADER_SIZE;

pub const ArtifactStatus = OperationArtifactStatus;
pub const VerifyArtifact = OperationArtifact;

pub const VerifyResult = struct {
    total_pages_checked: u64 = 0,
    corrupted_pages: u64 = 0,
    manifest_valid: bool = false,
    errors: std.ArrayList([]const u8) = .empty,
    artifacts: std.ArrayList(VerifyArtifact) = .empty,
    allocator: Allocator,

    pub fn init(allocator: Allocator) VerifyResult {
        return .{
            .allocator = allocator,
        };
    }

    pub fn isClean(self: *const VerifyResult) bool {
        return self.corrupted_pages == 0 and self.manifest_valid and self.errors.items.len == 0;
    }

    pub fn addError(self: *VerifyResult, msg: []const u8) !void {
        try self.errors.append(self.allocator, msg);
    }

    pub fn addArtifact(self: *VerifyResult, artifact: VerifyArtifact) !void {
        try self.artifacts.append(self.allocator, artifact);
    }

    /// Write the result as a JSON object to the provided writer.
    pub fn writeJson(self: *const VerifyResult, writer: anytype) !void {
        const summary = GraphOperationSummary{
            .operation = .verify,
            .status = if (self.isClean()) .ok else .warning,
            .items_processed = self.total_pages_checked,
            .bytes_processed = 0,
            .issue_count = self.corrupted_pages + self.errors.items.len,
            .changed = false,
        };
        try writer.writeByte('{');
        try summary.writeJsonFields(writer);
        try writer.print(",\"total_pages_checked\":{d},\"corrupted_pages\":{d},\"manifest_valid\":{},\"is_clean\":{},\"error_count\":{d},\"artifacts\":[", .{
            self.total_pages_checked,
            self.corrupted_pages,
            self.manifest_valid,
            self.isClean(),
            self.errors.items.len,
        });
        for (self.artifacts.items, 0..) |artifact, idx| {
            if (idx != 0) try writer.writeByte(',');
            try artifact.writeJson(writer);
        }
        try writer.writeAll("],\"details\":{");
        try writer.print("\"total_pages_checked\":{d}", .{self.total_pages_checked});
        try writer.print(",\"corrupted_pages\":{d}", .{self.corrupted_pages});
        try writer.print(",\"manifest_valid\":{}", .{self.manifest_valid});
        try writer.print(",\"is_clean\":{}", .{self.isClean()});
        try writer.print(",\"error_count\":{d}", .{self.errors.items.len});
        try writer.writeAll("}}");
    }

    pub fn deinit(self: *VerifyResult) void {
        for (self.errors.items) |msg| {
            self.allocator.free(msg);
        }
        self.errors.deinit(self.allocator);
        self.artifacts.deinit(self.allocator);
    }
};

pub const VerifyTool = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) VerifyTool {
        return .{ .allocator = allocator };
    }

    /// Verify a graph's integrity by checking:
    /// 1. Manifest A/B validity
    /// 2. All page checksums in each store file
    /// 3. Graph UUID consistency
    pub fn verifyGraph(self: *VerifyTool, graph_dir: *const GraphDir, page_size: u32) !VerifyResult {
        var result = VerifyResult.init(self.allocator);
        errdefer result.deinit();

        // 1. Verify manifests
        try self.verifyManifests(graph_dir, &result);

        // 2. Verify all store files
        const file_ids = [_]FileId{ .nodes, .adj_out, .adj_in, .props, .var_store, .free };
        for (file_ids) |file_id| {
            try self.verifyStoreFile(graph_dir, file_id, page_size, &result);
        }

        // 3. Verify required metadata snapshots and auxiliary artifacts.
        try self.verifyAuxiliaryArtifact(graph_dir, "labels.idx", true, &result);
        try self.verifyAuxiliaryArtifact(graph_dir, "props.idx", true, &result);
        try self.verifyAuxiliaryArtifact(graph_dir, "edges.idx", true, &result);
        try self.verifyLabelDictionary(graph_dir, &result);

        // 4. Verify WAL identity and WAL contents.
        try self.verifyWalArtifacts(graph_dir, &result);

        return result;
    }

    fn verifyManifests(self: *VerifyTool, graph_dir: *const GraphDir, result: *VerifyResult) !void {
        var any_valid = false;

        // Check manifest A
        const path_a = try graph_dir.manifestPath(self.allocator, .a);
        defer self.allocator.free(path_a);

        if (Manifest.readFromFile(self.allocator, path_a) catch null) |m| {
            if (!std.mem.eql(u8, &m.graph_uuid, &graph_dir.graph_uuid)) {
                const msg = try std.fmt.allocPrint(self.allocator, "manifest.a: graph UUID mismatch", .{});
                try result.addError(msg);
                try result.addArtifact(.{ .name = "manifest.a", .status = .invalid, .issue_count = 1 });
            } else if (Integrity.verifyManifest(&m, self.allocator)) {
                any_valid = true;
                try result.addArtifact(.{ .name = "manifest.a", .status = .ok });
            } else {
                const msg = try std.fmt.allocPrint(self.allocator, "manifest.a: checksum invalid", .{});
                try result.addError(msg);
                try result.addArtifact(.{ .name = "manifest.a", .status = .invalid, .issue_count = 1 });
            }
        } else {
            const msg = try std.fmt.allocPrint(self.allocator, "manifest.a: missing or unreadable", .{});
            try result.addError(msg);
            try result.addArtifact(.{ .name = "manifest.a", .status = .missing, .issue_count = 1 });
        }

        // Check manifest B
        const path_b = try graph_dir.manifestPath(self.allocator, .b);
        defer self.allocator.free(path_b);

        if (Manifest.readFromFile(self.allocator, path_b) catch null) |m| {
            if (!std.mem.eql(u8, &m.graph_uuid, &graph_dir.graph_uuid)) {
                const msg = try std.fmt.allocPrint(self.allocator, "manifest.b: graph UUID mismatch", .{});
                try result.addError(msg);
                try result.addArtifact(.{ .name = "manifest.b", .status = .invalid, .issue_count = 1 });
            } else if (Integrity.verifyManifest(&m, self.allocator)) {
                any_valid = true;
                try result.addArtifact(.{ .name = "manifest.b", .status = .ok });
            } else {
                const msg = try std.fmt.allocPrint(self.allocator, "manifest.b: checksum invalid", .{});
                try result.addError(msg);
                try result.addArtifact(.{ .name = "manifest.b", .status = .invalid, .issue_count = 1 });
            }
        } else {
            const msg = try std.fmt.allocPrint(self.allocator, "manifest.b: missing or unreadable", .{});
            try result.addError(msg);
            try result.addArtifact(.{ .name = "manifest.b", .status = .missing, .issue_count = 1 });
        }

        result.manifest_valid = any_valid;
        if (!any_valid) {
            const msg = try std.fmt.allocPrint(self.allocator, "no valid manifest found", .{});
            try result.addError(msg);
        }
    }

    fn verifyStoreFile(
        self: *VerifyTool,
        graph_dir: *const GraphDir,
        file_id: FileId,
        page_size: u32,
        result: *VerifyResult,
    ) !void {
        const store_path = try graph_dir.storePath(self.allocator, file_id);
        defer self.allocator.free(store_path);

        const file = std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), store_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                const file_name = file_manager_mod.FILE_NAMES[@intFromEnum(file_id)];
                const msg = try std.fmt.allocPrint(self.allocator, "{s}: missing", .{file_name});
                try result.addError(msg);
                try result.addArtifact(.{ .name = file_name, .status = .missing, .issue_count = 1 });
                return;
            }
            return err;
        };
        defer file.close(std.Io.Threaded.global_single_threaded.io());

        const stat = try file.stat(std.Io.Threaded.global_single_threaded.io());
        const file_name = file_manager_mod.FILE_NAMES[@intFromEnum(file_id)];
        if (stat.size == 0) {
            try result.addArtifact(.{
                .name = file_name,
                .status = .ok,
                .bytes_checked = 0,
            });
            return;
        }
        if (stat.size % page_size != 0) {
            const msg = try std.fmt.allocPrint(self.allocator, "{s}: size {d} is not page-aligned", .{ file_name, stat.size });
            try result.addError(msg);
            try result.addArtifact(.{
                .name = file_name,
                .status = .invalid,
                .bytes_checked = stat.size,
                .issue_count = 1,
            });
            return;
        }

        const page_count = stat.size / page_size;
        const buf = try self.allocator.alloc(u8, page_size);
        defer self.allocator.free(buf);

        var page_idx: u64 = 0;
        var corrupted_pages: u64 = 0;
        while (page_idx < page_count) : (page_idx += 1) {
            const offset = page_idx * @as(u64, page_size);
            const bytes_read = try file.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), buf, offset);

            if (bytes_read < page_size) break;

            result.total_pages_checked += 1;

            if (!Integrity.verifyPage(buf)) {
                result.corrupted_pages += 1;
                corrupted_pages += 1;
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}: page {d} checksum mismatch",
                    .{ file_name, page_idx },
                );
                try result.addError(msg);
            }
        }

        try result.addArtifact(.{
            .name = file_name,
            .status = if (corrupted_pages == 0) .ok else .invalid,
            .items_checked = page_count,
            .bytes_checked = stat.size,
            .issue_count = corrupted_pages,
        });
    }

    fn verifyAuxiliaryArtifact(
        self: *VerifyTool,
        graph_dir: *const GraphDir,
        name: []const u8,
        required: bool,
        result: *VerifyResult,
    ) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ graph_dir.path, name });
        defer self.allocator.free(path);

        const file = std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                if (required) {
                    const msg = try std.fmt.allocPrint(self.allocator, "{s}: missing", .{name});
                    try result.addError(msg);
                    try result.addArtifact(.{ .name = name, .status = .missing, .issue_count = 1 });
                }
                return;
            }
            return err;
        };
        defer file.close(std.Io.Threaded.global_single_threaded.io());

        const stat = try file.stat(std.Io.Threaded.global_single_threaded.io());
        try result.addArtifact(.{
            .name = name,
            .status = .ok,
            .bytes_checked = stat.size,
        });
    }

    fn verifyLabelDictionary(self: *VerifyTool, graph_dir: *const GraphDir, result: *VerifyResult) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/labels.dict", .{graph_dir.path});
        defer self.allocator.free(path);

        const file = std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close(std.Io.Threaded.global_single_threaded.io());

        const stat = try file.stat(std.Io.Threaded.global_single_threaded.io());
        var dict = LabelDictionary.init(self.allocator);
        defer dict.deinit();
        dict.loadFromFile(path) catch |err| {
            const msg = try std.fmt.allocPrint(self.allocator, "labels.dict: invalid ({s})", .{@errorName(err)});
            try result.addError(msg);
            try result.addArtifact(.{
                .name = "labels.dict",
                .status = .invalid,
                .bytes_checked = stat.size,
                .issue_count = 1,
            });
            return;
        };

        try result.addArtifact(.{
            .name = "labels.dict",
            .status = .ok,
            .bytes_checked = stat.size,
        });
    }

    fn verifyWalArtifacts(self: *VerifyTool, graph_dir: *const GraphDir, result: *VerifyResult) !void {
        _ = self;
        const wal_dir_path = try std.fmt.allocPrint(result.allocator, "{s}/wal", .{graph_dir.path});
        defer result.allocator.free(wal_dir_path);
        var wal_dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                const msg = try std.fmt.allocPrint(result.allocator, "wal/: missing", .{});
                try result.addError(msg);
                try result.addArtifact(.{ .name = "wal/", .status = .missing, .issue_count = 1 });
                return;
            }
            return err;
        };
        defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

        const identity_file = wal_dir.openFile(std.Io.Threaded.global_single_threaded.io(), "graph.uuid", .{}) catch |err| {
            if (err == error.FileNotFound) {
                const msg = try std.fmt.allocPrint(result.allocator, "wal/graph.uuid: missing", .{});
                try result.addError(msg);
                try result.addArtifact(.{ .name = "wal/graph.uuid", .status = .missing, .issue_count = 1 });
                return;
            }
            return err;
        };
        defer identity_file.close(std.Io.Threaded.global_single_threaded.io());

        const identity_stat = try identity_file.stat(std.Io.Threaded.global_single_threaded.io());
        var identity_buf: [16]u8 = undefined;
        if (identity_stat.size != identity_buf.len or (try identity_file.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), &identity_buf, 0)) != identity_buf.len or !std.mem.eql(u8, &identity_buf, &graph_dir.graph_uuid)) {
            const msg = try std.fmt.allocPrint(result.allocator, "wal/graph.uuid: invalid or mismatched", .{});
            try result.addError(msg);
            try result.addArtifact(.{
                .name = "wal/graph.uuid",
                .status = .invalid,
                .bytes_checked = identity_stat.size,
                .issue_count = 1,
            });
            return;
        }
        try result.addArtifact(.{
            .name = "wal/graph.uuid",
            .status = .ok,
            .bytes_checked = identity_stat.size,
        });

        const wal_file = wal_dir.openFile(std.Io.Threaded.global_single_threaded.io(), "graph.wal", .{}) catch |err| {
            if (err == error.FileNotFound) {
                const msg = try std.fmt.allocPrint(result.allocator, "wal/graph.wal: missing", .{});
                try result.addError(msg);
                try result.addArtifact(.{ .name = "wal/graph.wal", .status = .missing, .issue_count = 1 });
                return;
            }
            return err;
        };
        defer wal_file.close(std.Io.Threaded.global_single_threaded.io());

        const wal_stat = try wal_file.stat(std.Io.Threaded.global_single_threaded.io());
        var wal_mgr = WalManager.init(result.allocator, wal_dir, graph_dir.graph_uuid, 0, .{
            .create_identity_if_missing = false,
        }) catch |err| {
            const msg = try std.fmt.allocPrint(result.allocator, "wal/graph.wal: unreadable ({s})", .{@errorName(err)});
            try result.addError(msg);
            try result.addArtifact(.{
                .name = "wal/graph.wal",
                .status = .invalid,
                .bytes_checked = wal_stat.size,
                .issue_count = 1,
            });
            return;
        };
        defer wal_mgr.deinit();

        var record_count: u64 = 0;
        var failure: ?wal_mod.ReplayFailure = null;
        const Ctx = struct {
            record_count: *u64,

            fn visit(ctx: *@This(), _: *const WalRecord) !void {
                ctx.record_count.* += 1;
            }
        };
        var ctx = Ctx{ .record_count = &record_count };
        wal_mgr.forEachFromStrict(1, result.allocator, &failure, &ctx, Ctx.visit) catch |err| {
            const lsn = if (failure) |f| f.lsn else 0;
            const msg = try std.fmt.allocPrint(result.allocator, "wal/graph.wal: invalid at LSN {d} ({s})", .{ lsn, @errorName(err) });
            try result.addError(msg);
            try result.addArtifact(.{
                .name = "wal/graph.wal",
                .status = .invalid,
                .items_checked = record_count,
                .bytes_checked = wal_stat.size,
                .issue_count = 1,
            });
            return;
        };

        try result.addArtifact(.{
            .name = "wal/graph.wal",
            .status = .ok,
            .items_checked = record_count,
            .bytes_checked = wal_stat.size,
        });
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

fn setupWalArtifacts(allocator: Allocator, graph_path: []const u8, uuid: [16]u8) !void {
    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{graph_path});
    defer allocator.free(wal_dir_path);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), wal_dir_path);

    const uuid_path = try std.fmt.allocPrint(allocator, "{s}/graph.uuid", .{wal_dir_path});
    defer allocator.free(uuid_path);
    const uuid_file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), uuid_path, .{ .read = true, .truncate = true });
    defer uuid_file.close(std.Io.Threaded.global_single_threaded.io());
    try uuid_file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), &uuid);

    const wal_path = try std.fmt.allocPrint(allocator, "{s}/graph.wal", .{wal_dir_path});
    defer allocator.free(wal_path);
    const wal_file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), wal_path, .{ .read = true, .truncate = true });
    wal_file.close(std.Io.Threaded.global_single_threaded.io());
}

test "clean graph passes verification" {
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0x55);

    // Create graph directory with store files
    var gd = try GraphDir.create(allocator, tmp_path, uuid);
    defer gd.deinit();

    // Write a valid manifest to slot A
    const m = Manifest{
        .graph_uuid = uuid,
        .page_size = 4096,
        .counter = 1,
    };
    const path_a = try gd.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try m.writeToFile(allocator, path_a);
    const path_b = try gd.manifestPath(allocator, .b);
    defer allocator.free(path_b);
    try m.writeToFile(allocator, path_b);
    try setupWalArtifacts(allocator, gd.path, uuid);

    // Write a valid page to nodes.store
    const page_size: u32 = 4096;
    const store_path = try gd.storePath(allocator, .nodes);
    defer allocator.free(store_path);

    const store_file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), store_path, .{
        .read = true,
        .truncate = true,
    });
    defer store_file.close(std.Io.Threaded.global_single_threaded.io());

    var page_buf: [4096]u8 = undefined;
    @memset(&page_buf, 0);
    const header = page_mod.initHeader(0, .node_data, page_size);
    const header_bytes = page_mod.headerToBytes(&header);
    @memcpy(page_buf[0..PAGE_HEADER_SIZE], header_bytes);
    @memset(page_buf[PAGE_HEADER_SIZE..], 0xAA);

    // Compute and store checksum
    const checksum = page_mod.computeChecksum(page_buf[PAGE_HEADER_SIZE..]);
    std.mem.writeInt(u32, page_buf[16..20], checksum, .little);

    try store_file.writePositionalAll(std.Io.Threaded.global_single_threaded.io(), &page_buf, 0);

    // Verify
    var tool = VerifyTool.init(allocator);
    var result = try tool.verifyGraph(&gd, page_size);
    defer result.deinit();

    try testing.expect(result.isClean());
    try testing.expect(result.manifest_valid);
    try testing.expectEqual(@as(u64, 0), result.corrupted_pages);
    try testing.expect(result.total_pages_checked >= 1);
}

test "corrupted page detected" {
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0x66);

    var gd = try GraphDir.create(allocator, tmp_path, uuid);
    defer gd.deinit();

    // Write valid manifest
    const m = Manifest{
        .graph_uuid = uuid,
        .page_size = 4096,
        .counter = 1,
    };
    const path_a = try gd.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try m.writeToFile(allocator, path_a);
    const path_b = try gd.manifestPath(allocator, .b);
    defer allocator.free(path_b);
    try m.writeToFile(allocator, path_b);
    try setupWalArtifacts(allocator, gd.path, uuid);

    // Write a valid page then corrupt it
    const page_size: u32 = 4096;
    const store_path = try gd.storePath(allocator, .nodes);
    defer allocator.free(store_path);

    const store_file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), store_path, .{
        .read = true,
        .truncate = true,
    });
    defer store_file.close(std.Io.Threaded.global_single_threaded.io());

    var page_buf: [4096]u8 = undefined;
    @memset(&page_buf, 0);
    const header = page_mod.initHeader(0, .node_data, page_size);
    const header_bytes = page_mod.headerToBytes(&header);
    @memcpy(page_buf[0..PAGE_HEADER_SIZE], header_bytes);
    @memset(page_buf[PAGE_HEADER_SIZE..], 0xBB);

    // Compute and store correct checksum first
    const checksum = page_mod.computeChecksum(page_buf[PAGE_HEADER_SIZE..]);
    std.mem.writeInt(u32, page_buf[16..20], checksum, .little);

    // Now corrupt a body byte AFTER computing checksum
    page_buf[PAGE_HEADER_SIZE + 50] = 0xFF;

    try store_file.writePositionalAll(std.Io.Threaded.global_single_threaded.io(), &page_buf, 0);

    // Verify — should detect corruption
    var tool = VerifyTool.init(allocator);
    var result = try tool.verifyGraph(&gd, page_size);
    defer result.deinit();

    try testing.expect(!result.isClean());
    try testing.expectEqual(@as(u64, 1), result.corrupted_pages);
    try testing.expect(result.errors.items.len >= 1);
}

test "empty graph with manifest passes" {
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0x77);

    var gd = try GraphDir.create(allocator, tmp_path, uuid);
    defer gd.deinit();

    // Write valid manifest, no pages in store files
    const m = Manifest{
        .graph_uuid = uuid,
        .page_size = 4096,
        .counter = 1,
    };
    const path_a = try gd.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try m.writeToFile(allocator, path_a);
    const path_b = try gd.manifestPath(allocator, .b);
    defer allocator.free(path_b);
    try m.writeToFile(allocator, path_b);
    try setupWalArtifacts(allocator, gd.path, uuid);

    var tool = VerifyTool.init(allocator);
    var result = try tool.verifyGraph(&gd, 4096);
    defer result.deinit();

    try testing.expect(result.isClean());
    try testing.expectEqual(@as(u64, 0), result.total_pages_checked);
}

test "no manifest fails verification" {
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0x88);

    var gd = try GraphDir.create(allocator, tmp_path, uuid);
    defer gd.deinit();

    // No manifest written — just empty store files
    try setupWalArtifacts(allocator, gd.path, uuid);
    var tool = VerifyTool.init(allocator);
    var result = try tool.verifyGraph(&gd, 4096);
    defer result.deinit();

    try testing.expect(!result.isClean());
    try testing.expect(!result.manifest_valid);
}

test "VerifyResult writeJson produces valid structured output" {
    const allocator = testing.allocator;
    var result = VerifyResult.init(allocator);
    defer result.deinit();

    result.total_pages_checked = 42;
    result.corrupted_pages = 0;
    result.manifest_valid = true;

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    try result.writeJson(&aw.writer);
    const json = aw.writer.buffer[0..aw.writer.end];

    // Verify key fields present
    try testing.expect(std.mem.indexOf(u8, json, "\"total_pages_checked\":42") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"corrupted_pages\":0") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"manifest_valid\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"is_clean\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"error_count\":0") != null);
}

test "VerifyResult writeJson reports unclean state" {
    const allocator = testing.allocator;
    var result = VerifyResult.init(allocator);
    defer result.deinit();

    result.total_pages_checked = 10;
    result.corrupted_pages = 2;
    result.manifest_valid = false;

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    try result.writeJson(&aw.writer);
    const json = aw.writer.buffer[0..aw.writer.end];

    try testing.expect(std.mem.indexOf(u8, json, "\"is_clean\":false") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"corrupted_pages\":2") != null);
}

test "GAP-0032: verifyGraph reports a manifest UUID mismatch" {
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(tmp_path);

    var graph_uuid: [16]u8 = undefined;
    @memset(&graph_uuid, 0xAA);
    var manifest_uuid: [16]u8 = undefined;
    @memset(&manifest_uuid, 0xBB);

    var gd = try GraphDir.create(allocator, tmp_path, graph_uuid);
    defer gd.deinit();

    const m = Manifest{
        .graph_uuid = manifest_uuid,
        .page_size = 4096,
        .counter = 1,
    };
    const path_a = try gd.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try m.writeToFile(allocator, path_a);
    const path_b = try gd.manifestPath(allocator, .b);
    defer allocator.free(path_b);
    try m.writeToFile(allocator, path_b);
    try setupWalArtifacts(allocator, gd.path, graph_uuid);

    var tool = VerifyTool.init(allocator);
    var result = try tool.verifyGraph(&gd, 4096);
    defer result.deinit();

    try testing.expect(!result.manifest_valid);
    try testing.expect(!result.isClean());
    try testing.expect(result.errors.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, result.errors.items[0], "graph UUID mismatch") != null);
}

test "verifyGraph reports missing WAL artifacts" {
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(tmp_path);

    const uuid = [_]u8{0xAB} ** 16;
    var gd = try GraphDir.create(allocator, tmp_path, uuid);
    defer gd.deinit();

    const m = Manifest{
        .graph_uuid = uuid,
        .page_size = 4096,
        .counter = 1,
    };
    const path_a = try gd.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try m.writeToFile(allocator, path_a);
    const path_b = try gd.manifestPath(allocator, .b);
    defer allocator.free(path_b);
    try m.writeToFile(allocator, path_b);

    var tool = VerifyTool.init(allocator);
    var result = try tool.verifyGraph(&gd, 4096);
    defer result.deinit();

    try testing.expect(!result.isClean());
    try testing.expect(std.mem.indexOf(u8, result.errors.items[result.errors.items.len - 1], "wal/: missing") != null);
}

test {
    std.testing.refAllDecls(@This());
}
