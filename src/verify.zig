// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;

const config_mod = @import("config.zig");
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
    /// Optional log callback for structured event emission.
    log_fn: ?*const fn (level: config_mod.LogLevel, msg: []const u8) void = null,
    /// SEC-0043: When TDE is active, thread the encryption key through manifest
    /// verification so the HMAC trailer is authenticated. When null, falls back
    /// to CRC-only verification (unchanged behavior for non-TDE graphs).
    encryption_key: ?[32]u8 = null,

    pub fn init(allocator: Allocator) VerifyTool {
        return .{ .allocator = allocator };
    }

    /// Verify a graph's integrity by checking:
    /// 1. Manifest A/B validity
    /// 2. All page checksums in each store file
    /// 3. Graph UUID consistency
    pub fn verifyGraph(self: *VerifyTool, graph_dir: *const GraphDir, page_size: u32) !VerifyResult {
        config_mod.emitEvent(self.log_fn, .verify_start);
        defer config_mod.emitEvent(self.log_fn, .verify_end);
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

        // SEC-0043: use keyed read when encryption_key is configured so the HMAC
        // trailer is authenticated; fall back to CRC-only when no key is set.
        if (Manifest.readFromFileWithKey(self.allocator, path_a, self.encryption_key) catch null) |m| {
            if (!std.mem.eql(u8, &m.graph_uuid, &graph_dir.graph_uuid)) {
                const msg = try std.fmt.allocPrint(self.allocator, "manifest.a: graph UUID mismatch", .{});
                try result.addError(msg);
                try result.addArtifact(.{ .name = "manifest.a", .status = .invalid, .issue_count = 1 });
            } else if (Integrity.verifyManifestWithKey(&m, self.allocator, self.encryption_key)) {
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

        if (Manifest.readFromFileWithKey(self.allocator, path_b, self.encryption_key) catch null) |m| {
            if (!std.mem.eql(u8, &m.graph_uuid, &graph_dir.graph_uuid)) {
                const msg = try std.fmt.allocPrint(self.allocator, "manifest.b: graph UUID mismatch", .{});
                try result.addError(msg);
                try result.addArtifact(.{ .name = "manifest.b", .status = .invalid, .issue_count = 1 });
            } else if (Integrity.verifyManifestWithKey(&m, self.allocator, self.encryption_key)) {
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
        // SONNY-6590: a sealed dictionary is authenticated with the store's
        // key (without one it reports SideFileEncrypted).
        var cipher = @import("side_file_crypto.zig").Cipher.forKey(self.encryption_key, graph_dir.graph_uuid);
        defer if (cipher) |*c| c.deinit();
        _ = dict.loadFromFileWith(path, .{ .cipher = if (cipher) |*c| c else null, .require_sealed = false }) catch |err| {
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
        // SONNY-6622: the store's WAL is only ever opened read-only here. It
        // used to go through WalManager.init on the store's own directory,
        // without the key and with a modifying open: on wal <= 0.1.23 an
        // encrypted log read as a torn tail and was truncated to nothing.
        // The wal library has no read-only open, so the log is copied into a
        // private temporary directory and validated there, under the key.
        var scratch = WalScratch.create(result.allocator, wal_dir) catch |err| {
            const msg = try std.fmt.allocPrint(result.allocator, "wal/graph.wal: could not be copied for checking ({s})", .{@errorName(err)});
            try result.addError(msg);
            try result.addArtifact(.{ .name = "wal/graph.wal", .status = .invalid, .bytes_checked = wal_stat.size, .issue_count = 1 });
            return;
        };
        defer scratch.destroy();
        var wal_mgr = WalManager.init(result.allocator, scratch.dir, graph_dir.graph_uuid, 0, .{
            .create_identity_if_missing = false,
            .encryption_key = self.encryption_key,
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

/// SONNY-6622: a private copy of a graph's WAL directory (`graph.wal`, its
/// checkpoint sidecar and `graph.uuid`) in a new directory under $TMPDIR (or
/// /tmp), for a check that must not modify the store. Files are 0600; the
/// directory is removed by `destroy`. Under at-rest encryption the copied
/// log is ciphertext; without it, it is as plaintext as the store.
const WalScratch = struct {
    allocator: Allocator,
    path: []u8,
    dir: std.Io.Dir,

    const files = [_][]const u8{ "graph.wal", "graph.wal.ckpt", "graph.uuid" };

    fn create(allocator: Allocator, src: std.Io.Dir) !WalScratch {
        const io = std.Io.Threaded.global_single_threaded.io();
        var rnd: [8]u8 = undefined;
        io.random(&rnd);
        const base = if (std.c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
        const path = try std.fmt.allocPrint(allocator, "{s}/graph-storage-verify-{x}", .{ base, &rnd });
        errdefer allocator.free(path);
        try std.Io.Dir.cwd().createDirPath(io, path);
        errdefer std.Io.Dir.cwd().deleteTree(io, path) catch {};
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
        errdefer dir.close(io);
        for (files) |name| {
            const in = src.openFile(io, name, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer in.close(io);
            const out = try dir.createFile(io, name, .{
                .exclusive = true,
                .permissions = std.Io.File.Permissions.fromMode(0o600),
            });
            defer out.close(io);
            var buf: [64 * 1024]u8 = undefined;
            var off: u64 = 0;
            while (true) {
                const n = try in.readPositional(io, &.{&buf}, off);
                if (n == 0) break;
                try out.writePositionalAll(io, buf[0..n], off);
                off += n;
            }
        }
        return .{ .allocator = allocator, .path = path, .dir = dir };
    }

    fn destroy(self: *WalScratch) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.dir.close(io);
        std.Io.Dir.cwd().deleteTree(io, self.path) catch {};
        self.allocator.free(self.path);
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

var verify_event_count: usize = 0;
var verify_event_labels: [8][]const u8 = undefined;

fn verifyTestLogFn(_: config_mod.LogLevel, msg: []const u8) void {
    if (verify_event_count < verify_event_labels.len) {
        verify_event_labels[verify_event_count] = msg;
        verify_event_count += 1;
    }
}

test "NFR-OBS-002: verifyGraph emits verify_start and verify_end events" {
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0x99);

    var gd = try GraphDir.create(allocator, tmp_path, uuid);
    defer gd.deinit();

    const m = manifest_mod.Manifest{
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

    verify_event_count = 0;
    var tool = VerifyTool.init(allocator);
    tool.log_fn = &verifyTestLogFn;
    var result = try tool.verifyGraph(&gd, 4096);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), verify_event_count);
    try testing.expectEqualStrings("verify_start", verify_event_labels[0]);
    try testing.expectEqualStrings("verify_end", verify_event_labels[1]);
}

test "SEC-0043: verifyGraph with key detects HMAC-forged manifest (CRC recomputed)" {
    // A tampered manifest whose CRC32 has been recomputed must NOT be accepted
    // by VerifyTool when an encryption key is configured. Without threading the
    // key, only the CRC is checked and the forgery passes silently (false OK).
    const allocator = testing.allocator;
    // fips-exempt: non-security — CRC32C record-integrity (corruption detection)
    // for on-disk format; not authentication.
    const Crc32 = std.hash.crc.Crc32Iscsi;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0x43);

    var gd = try GraphDir.create(allocator, tmp_path, uuid);
    defer gd.deinit();

    const key = [_]u8{0x43} ** 32;

    // Write an authenticated (TDE) manifest.
    const m = Manifest{
        .graph_uuid = uuid,
        .page_size = 4096,
        .counter = 5,
        .last_checkpoint_lsn = 9000,
    };
    const path_a = try gd.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try m.writeToFileWithKey(allocator, path_a, key);

    const path_b = try gd.manifestPath(allocator, .b);
    defer allocator.free(path_b);
    try m.writeToFileWithKey(allocator, path_b, key);

    try setupWalArtifacts(allocator, gd.path, uuid);

    // Tamper slot A: roll back last_checkpoint_lsn, recompute CRC32 so a
    // CRC-only check would pass, but the HMAC trailer no longer matches.
    {
        const f = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path_a, .{ .mode = .read_write });
        defer f.close(std.Io.Threaded.global_single_threaded.io());
        const io = std.Io.Threaded.global_single_threaded.io();
        const flen = try f.length(io);
        const buf = try allocator.alloc(u8, @intCast(flen));
        defer allocator.free(buf);
        _ = try f.readPositionalAll(io, buf, 0);
        const lsn_offset: usize = 8 + 4 + 16 + 4 + 8; // magic+fmt+uuid+page_size+counter
        @memcpy(buf[lsn_offset..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, @as(u64, 0))));
        const new_crc = Crc32.hash(buf[0 .. manifest_mod.SERIALIZED_SIZE - 4]);
        @memcpy(buf[manifest_mod.SERIALIZED_SIZE - 4 ..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, new_crc)));
        try f.writePositionalAll(io, buf, 0);
    }

    // With a key configured, tampered slot A must be rejected (HMAC fails) and
    // tampered-B is untouched, so B remains valid — but we tamper B too so
    // that neither slot passes and manifest_valid is false.
    {
        const f = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path_b, .{ .mode = .read_write });
        defer f.close(std.Io.Threaded.global_single_threaded.io());
        const io = std.Io.Threaded.global_single_threaded.io();
        const flen = try f.length(io);
        const buf = try allocator.alloc(u8, @intCast(flen));
        defer allocator.free(buf);
        _ = try f.readPositionalAll(io, buf, 0);
        const lsn_offset: usize = 8 + 4 + 16 + 4 + 8;
        @memcpy(buf[lsn_offset..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, @as(u64, 0))));
        const new_crc = Crc32.hash(buf[0 .. manifest_mod.SERIALIZED_SIZE - 4]);
        @memcpy(buf[manifest_mod.SERIALIZED_SIZE - 4 ..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, new_crc)));
        try f.writePositionalAll(io, buf, 0);
    }

    // Verify with the encryption key: both forged manifests must be rejected.
    var tool = VerifyTool.init(allocator);
    tool.encryption_key = key;
    var result = try tool.verifyGraph(&gd, 4096);
    defer result.deinit();

    try testing.expect(!result.manifest_valid);
    try testing.expect(!result.isClean());
}

test "SEC-0043: verifyGraph without key passes on plaintext manifest (regression)" {
    // Without a key, the CRC-only path is used. A valid plaintext manifest
    // must still pass (no regression from threading the key field).
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0x44);

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
    try setupWalArtifacts(allocator, gd.path, uuid);

    var tool = VerifyTool.init(allocator);
    var result = try tool.verifyGraph(&gd, 4096);
    defer result.deinit();

    try testing.expect(result.manifest_valid);
    try testing.expect(result.isClean());
}

test "SONNY-6635: the WAL copy is made in a private directory inside the graph's directory and removed" {
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0x66);
    var gd = try GraphDir.create(allocator, tmp_path, uuid);
    defer gd.deinit();
    try setupWalArtifacts(allocator, gd.path, uuid);
    const wal_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{gd.path});
    defer allocator.free(wal_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(io, wal_path, .{});
    defer wal_dir.close(io);

    var scratch = try WalScratch.create(allocator, gd.path, wal_dir);
    var destroyed = false;
    defer if (!destroyed) scratch.destroy();
    // Inside the graph's directory (the store's own filesystem and
    // permissions), never under $TMPDIR or /tmp.
    try testing.expect(std.mem.startsWith(u8, scratch.path, gd.path));
    try testing.expectEqualStrings(gd.path, std.fs.path.dirname(scratch.path).?);
    const st = try std.Io.Dir.cwd().statFile(io, scratch.path, .{ .follow_symlinks = false });
    try testing.expectEqual(std.Io.File.Kind.directory, st.kind);
    try testing.expectEqual(@as(u32, 0o700), st.permissions.toMode() & 0o7777);
    const copied = try scratch.dir.statFile(io, "graph.uuid", .{});
    try testing.expectEqual(@as(u32, 0o600), copied.permissions.toMode() & 0o7777);
    const scratch_path = try allocator.dupe(u8, scratch.path);
    defer allocator.free(scratch_path);
    scratch.destroy();
    destroyed = true;
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, scratch_path, .{}));

    // A whole verification leaves nothing behind in the graph's directory.
    const m = Manifest{ .graph_uuid = uuid, .page_size = 4096, .counter = 1 };
    const path_a = try gd.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try m.writeToFile(allocator, path_a);
    const path_b = try gd.manifestPath(allocator, .b);
    defer allocator.free(path_b);
    try m.writeToFile(allocator, path_b);
    var tool = VerifyTool.init(allocator);
    var result = try tool.verifyGraph(&gd, 4096);
    defer result.deinit();
    var gdir = try std.Io.Dir.cwd().openDir(io, gd.path, .{ .iterate = true });
    defer gdir.close(io);
    var it = gdir.iterate();
    while (try it.next(io)) |e| {
        try testing.expect(!std.mem.startsWith(u8, e.name, WalScratch.prefix));
    }
}

test {
    std.testing.refAllDecls(@This());
}
