// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");

/// Create a file beneath its containing directory, accepting either an
/// absolute or a relative path to that directory. The caller supplies the
/// trusted parent path; resolve_beneath applies to the final component.
/// Passing the full absolute path to cwd().createFile with resolve_beneath
/// fails on macOS because an absolute path escapes the directory handle.
pub fn create(io: std.Io, path: []const u8, options: std.Io.Dir.CreateFileOptions) !std.Io.File {
    var parent = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(path) orelse ".", .{});
    defer parent.close(io);
    return parent.createFile(io, std.fs.path.basename(path), options);
}

test "scoped create accepts an absolute parent and retains exclusive creation" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const parent = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(parent);
    const path = try std.fs.path.join(allocator, &.{ parent, "store" });
    defer allocator.free(path);
    const options: std.Io.Dir.CreateFileOptions = .{
        .exclusive = true,
        .resolve_beneath = true,
        .permissions = .fromMode(0o600),
    };
    const file = try create(io, path, options);
    file.close(io);
    try std.testing.expectError(error.PathAlreadyExists, create(io, path, options));
    if (@import("builtin").os.tag != .windows) {
        const stat = try tmp.dir.statFile(io, "store", .{});
        try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    }
}

test "scoped create accepts a relative parent and replaces stale temporary contents" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const absolute = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(absolute);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cwd);
    const relative = try std.fs.path.relative(allocator, cwd, null, cwd, absolute);
    defer allocator.free(relative);
    const path = try std.fs.path.join(allocator, &.{ relative, "store.tmp" });
    defer allocator.free(path);
    const options: std.Io.Dir.CreateFileOptions = .{ .resolve_beneath = true };
    {
        const file = try create(io, path, options);
        defer file.close(io);
        try file.writeStreamingAll(io, "stale contents");
    }
    const file = try create(io, path, options);
    defer file.close(io);
    try std.testing.expectEqual(@as(u64, 0), (try file.stat(io)).size);
}
