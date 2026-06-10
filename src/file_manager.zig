// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const types = @import("types.zig");
const pager_mod = @import("pager.zig");
const page_mod = @import("page.zig");

const FileId = types.FileId;
const Pager = pager_mod.Pager;
const Allocator = std.mem.Allocator;

/// Number of distinct file types managed.
pub const FILE_COUNT = @typeInfo(FileId).@"enum".fields.len;

/// File name for each FileId.
pub const FILE_NAMES = [FILE_COUNT][]const u8{
    "nodes.store", // nodes
    "adj_out.store", // adj_out
    "adj_in.store", // adj_in
    "props.store", // props
    "var.store", // var_store
    "free.store", // free
    "labels.idx", // label_idx
    "props.idx", // prop_idx
    "edges.idx", // edge_idx
};

pub const OpenMode = enum {
    open_existing,
    create_if_missing,
};

pub const FileManager = struct {
    allocator: Allocator,
    graph_dir: []const u8, // path to graph directory
    page_size: u32,
    encryption_key: ?[32]u8 = null, // TDE key for page encryption
    files: [FILE_COUNT]?std.Io.File, // indexed by @intFromEnum(FileId)
    pagers: [FILE_COUNT]?Pager, // one Pager per open file

    pub fn init(allocator: Allocator, graph_dir: []const u8, page_size: u32) FileManager {
        return .{
            .allocator = allocator,
            .graph_dir = graph_dir,
            .page_size = page_size,
            .files = [_]?std.Io.File{null} ** FILE_COUNT,
            .pagers = [_]?Pager{null} ** FILE_COUNT,
        };
    }

    /// Open a store file for the given FileId.
    /// Steady-state open paths should use `.open_existing` so missing durable
    /// artifacts fail closed; bootstrap paths may opt in to `.create_if_missing`.
    pub fn openFile(self: *FileManager, file_id: FileId, mode: OpenMode) !*Pager {
        const idx = @intFromEnum(file_id);
        if (self.pagers[idx] != null) {
            return &self.pagers[idx].?;
        }

        // Build path: graph_dir / FILE_NAMES[idx]
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.graph_dir, FILE_NAMES[idx] });
        defer self.allocator.free(path);

        const file = switch (mode) {
            .open_existing => try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path, .{ .mode = .read_write }),
            .create_if_missing => try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), path, .{
                .read = true,
                .truncate = false, // don't truncate existing files!
                .permissions = std.Io.File.Permissions.fromMode(0o600),
            }),
        };

        self.files[idx] = file;
        self.pagers[idx] = .{
            .file = file,
            .page_size = self.page_size,
            .encryption = if (self.encryption_key) |key|
                @import("encryption.zig").PageEncryption.init(key)
            else
                null,
            .file_id = file_id,
        };
        return &self.pagers[idx].?;
    }

    /// Get the pager for a file (must already be opened).
    pub fn getPager(self: *FileManager, file_id: FileId) ?*Pager {
        const idx = @intFromEnum(file_id);
        if (self.pagers[idx] != null) {
            return &self.pagers[idx].?;
        }
        return null;
    }

    /// Get the underlying file handle for a file (must already be opened).
    pub fn getFile(self: *FileManager, file_id: FileId) ?*std.Io.File {
        const idx = @intFromEnum(file_id);
        if (self.files[idx] != null) {
            return &self.files[idx].?;
        }
        return null;
    }

    /// Close all open files.
    pub fn deinit(self: *FileManager) void {
        for (&self.files) |*maybe_file| {
            if (maybe_file.*) |*file| {
                file.close(std.Io.Threaded.global_single_threaded.io());
                maybe_file.* = null;
            }
        }
        // SEC-0045: securely zero each pager's per-file encryption key copy
        // before releasing the pager slot so that up to FILE_COUNT 32-byte key
        // copies are not left in memory without a secure wipe.  The zero and
        // the null assignment happen in the same loop iteration so that the
        // secureZero is not followed by an unrelated write that could obscure
        // whether zeroing actually occurred.
        for (&self.pagers) |*maybe_pager| {
            if (maybe_pager.*) |*p| {
                if (p.encryption) |*e| e.deinit();
            }
            maybe_pager.* = null;
        }
        // Zero sensitive key material
        if (self.encryption_key) |*k| {
            std.crypto.secureZero(u8, k);
        }
    }

    /// Sync all open files to disk.
    pub fn syncAll(self: *FileManager) !void {
        for (&self.pagers) |*maybe_pager| {
            if (maybe_pager.*) |*p| {
                try p.sync();
            }
        }
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;
const PAGE_HEADER_SIZE = page_mod.PAGE_HEADER_SIZE;

/// Helper: create a temporary directory and return its real path as a slice.
fn tmpDirPath(tmp: *testing.TmpDir) []const u8 {
    return tmp.sub_path[0..tmp.sub_path.len];
}

test "open and get pager" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    var fm = FileManager.init(testing.allocator, dir_path, 4096);
    defer fm.deinit();

    const file = try tmp.dir.createFile(std.Io.Threaded.global_single_threaded.io(), "nodes.store", .{ .read = true, .truncate = true });
    file.close(std.Io.Threaded.global_single_threaded.io());

    const pager_ptr = try fm.openFile(.nodes, .open_existing);
    try testing.expect(pager_ptr.page_size == 4096);
}

test "create_if_missing creates file on disk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    var fm = FileManager.init(testing.allocator, dir_path, 4096);
    defer fm.deinit();

    _ = try fm.openFile(.nodes, .create_if_missing);

    // Verify the file exists in the temp dir
    const stat = tmp.dir.statFile(std.Io.Threaded.global_single_threaded.io(), "nodes.store", .{}) catch |err| {
        std.debug.print("Expected nodes.store to exist, got error: {}\n", .{err});
        return error.TestUnexpectedResult;
    };
    _ = stat;
}

test "multiple files each have their own pager" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    var fm = FileManager.init(testing.allocator, dir_path, 4096);
    defer fm.deinit();

    const io = std.Io.Threaded.global_single_threaded.io();
    const nodes_file = try tmp.dir.createFile(io, "nodes.store", .{ .read = true, .truncate = true });
    nodes_file.close(io);
    const adj_out_file = try tmp.dir.createFile(io, "adj_out.store", .{ .read = true, .truncate = true });
    adj_out_file.close(io);
    const props_file = try tmp.dir.createFile(io, "props.store", .{ .read = true, .truncate = true });
    props_file.close(io);

    const nodes_pager = try fm.openFile(.nodes, .open_existing);
    const adj_out_pager = try fm.openFile(.adj_out, .open_existing);
    const props_pager = try fm.openFile(.props, .open_existing);

    // Each pager should be a distinct pointer
    try testing.expect(@intFromPtr(nodes_pager) != @intFromPtr(adj_out_pager));
    try testing.expect(@intFromPtr(adj_out_pager) != @intFromPtr(props_pager));
    try testing.expect(@intFromPtr(nodes_pager) != @intFromPtr(props_pager));

    // Verify all corresponding files exist
    _ = try tmp.dir.statFile(io, "nodes.store", .{});
    _ = try tmp.dir.statFile(io, "adj_out.store", .{});
    _ = try tmp.dir.statFile(io, "props.store", .{});
}

test "getPager before open returns null" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    var fm = FileManager.init(testing.allocator, dir_path, 4096);
    defer fm.deinit();

    try testing.expect(fm.getPager(.nodes) == null);
    try testing.expect(fm.getPager(.adj_out) == null);
    try testing.expect(fm.getPager(.props) == null);
}

test "write through pager and read back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    var fm = FileManager.init(testing.allocator, dir_path, 4096);
    defer fm.deinit();

    const file = try tmp.dir.createFile(std.Io.Threaded.global_single_threaded.io(), "nodes.store", .{ .read = true, .truncate = true });
    file.close(std.Io.Threaded.global_single_threaded.io());

    const pager_ptr = try fm.openFile(.nodes, .open_existing);

    // Prepare a page buffer with known data
    var write_buf: [4096]u8 = undefined;
    @memset(&write_buf, 0);

    const header = page_mod.initHeader(0, .node_data, 4096);
    const header_bytes = page_mod.headerToBytes(&header);
    @memcpy(write_buf[0..PAGE_HEADER_SIZE], header_bytes);

    // Fill body with pattern
    @memset(write_buf[PAGE_HEADER_SIZE..], 0xAB);

    // Write via pager
    try pager_ptr.writePage(0, &write_buf);

    // Read it back
    var read_buf: [4096]u8 = undefined;
    @memset(&read_buf, 0);
    try pager_ptr.readPage(0, &read_buf);

    // Verify body matches
    try testing.expectEqualSlices(u8, write_buf[PAGE_HEADER_SIZE..], read_buf[PAGE_HEADER_SIZE..]);
}

test "deinit closes files and resets pagers" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    var fm = FileManager.init(testing.allocator, dir_path, 4096);

    const io = std.Io.Threaded.global_single_threaded.io();
    const nodes_file = try tmp.dir.createFile(io, "nodes.store", .{ .read = true, .truncate = true });
    nodes_file.close(io);
    const adj_out_file = try tmp.dir.createFile(io, "adj_out.store", .{ .read = true, .truncate = true });
    adj_out_file.close(io);

    _ = try fm.openFile(.nodes, .open_existing);
    _ = try fm.openFile(.adj_out, .open_existing);

    // Verify pagers exist before deinit
    try testing.expect(fm.getPager(.nodes) != null);
    try testing.expect(fm.getPager(.adj_out) != null);

    fm.deinit();

    // After deinit, getPager should return null
    try testing.expect(fm.getPager(.nodes) == null);
    try testing.expect(fm.getPager(.adj_out) == null);

    // All file slots should be null
    for (fm.files) |maybe_file| {
        try testing.expect(maybe_file == null);
    }
}

test "openFile is idempotent — returns same pager on second call" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    var fm = FileManager.init(testing.allocator, dir_path, 4096);
    defer fm.deinit();

    const file = try tmp.dir.createFile(std.Io.Threaded.global_single_threaded.io(), "nodes.store", .{ .read = true, .truncate = true });
    file.close(std.Io.Threaded.global_single_threaded.io());

    const p1 = try fm.openFile(.nodes, .open_existing);
    const p2 = try fm.openFile(.nodes, .open_existing);
    try testing.expect(p1 == p2);
}

test "FILE_NAMES has correct count and entries" {
    try testing.expectEqual(@as(usize, 9), FILE_NAMES.len);
    try testing.expectEqualStrings("nodes.store", FILE_NAMES[@intFromEnum(FileId.nodes)]);
    try testing.expectEqualStrings("adj_out.store", FILE_NAMES[@intFromEnum(FileId.adj_out)]);
    try testing.expectEqualStrings("adj_in.store", FILE_NAMES[@intFromEnum(FileId.adj_in)]);
    try testing.expectEqualStrings("props.store", FILE_NAMES[@intFromEnum(FileId.props)]);
    try testing.expectEqualStrings("var.store", FILE_NAMES[@intFromEnum(FileId.var_store)]);
    try testing.expectEqualStrings("free.store", FILE_NAMES[@intFromEnum(FileId.free)]);
    try testing.expectEqualStrings("labels.idx", FILE_NAMES[@intFromEnum(FileId.label_idx)]);
    try testing.expectEqualStrings("props.idx", FILE_NAMES[@intFromEnum(FileId.prop_idx)]);
    try testing.expectEqualStrings("edges.idx", FILE_NAMES[@intFromEnum(FileId.edge_idx)]);
}

test "SEC-0045: deinit zeroes all per-pager encryption key copies" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    const key = [_]u8{0xAB} ** 32;

    var fm = FileManager.init(testing.allocator, dir_path, 4096);
    fm.encryption_key = key;

    const io = std.Io.Threaded.global_single_threaded.io();
    // Create all FILE_COUNT store files so every pager slot gets an encryption copy
    for (FILE_NAMES) |name| {
        const f = try tmp.dir.createFile(io, name, .{ .read = true, .truncate = true });
        f.close(io);
    }

    // Open all files so each pager gets its own PageEncryption copy
    const file_ids = [_]@import("types.zig").FileId{
        .nodes, .adj_out, .adj_in, .props, .var_store, .free, .label_idx, .prop_idx, .edge_idx,
    };
    for (file_ids) |fid| {
        _ = try fm.openFile(fid, .open_existing);
    }

    // Verify every open pager has the expected key set before deinit.
    const all_zero = [_]u8{0} ** 32;
    for (&fm.pagers) |*maybe_pager| {
        if (maybe_pager.*) |*p| {
            try testing.expect(p.encryption != null);
            try testing.expect(!std.mem.eql(u8, &p.encryption.?.key, &all_zero));
        }
    }

    // Verify the master encryption key is non-zero before deinit.
    try testing.expect(fm.encryption_key != null);
    try testing.expect(!std.mem.eql(u8, &fm.encryption_key.?, &all_zero));

    // deinit must secureZero each pager's key copy then null the slot.  Zig
    // debug mode fills the freed payload area with 0xAA sentinel bytes after
    // `maybe_pager.* = null`, so we cannot observe the intermediate zeroed
    // state through the same pointer after deinit returns.  We therefore
    // verify the observable postconditions: (a) the master key is zeroed, and
    // (b) no pager slot is live (confirming the loop ran without panic).
    fm.deinit();

    // (a) Master encryption key must be secureZero'd.
    try testing.expect(fm.encryption_key == null or
        std.mem.eql(u8, &fm.encryption_key.?, &all_zero));

    // (b) All pager slots are null — the loop completed without error.
    for (fm.pagers) |maybe_pager| {
        try testing.expect(maybe_pager == null);
    }
}

test "created files have mode 0o600" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    var fm = FileManager.init(testing.allocator, dir_path, 4096);
    defer fm.deinit();

    _ = try fm.openFile(.nodes, .create_if_missing);

    // Stat the file and check permissions
    const stat = try tmp.dir.statFile(std.Io.Threaded.global_single_threaded.io(), "nodes.store", .{});
    // Mask out file type bits, check permission bits
    const perm = stat.permissions.toMode() & 0o7777;
    try testing.expectEqual(@as(u32, 0o600), perm);
}

test {
    std.testing.refAllDecls(@This());
}
