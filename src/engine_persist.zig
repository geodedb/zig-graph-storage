// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Persistence helpers extracted from engine.zig.
//! Covers free space bitmap serialization, label dictionary persistence,
//! and free space rebuild from disk.

const std = @import("std");

const types = @import("types.zig");
const free_space_mod = @import("free_space.zig");
const engine_mod = @import("engine.zig");

const FreeSpaceManager = free_space_mod.FreeSpaceManager;
const GraphEngine = engine_mod.GraphEngine;
const owner_only_file_mode = 0o600;

/// Persist the 5 free space bitmaps to a `free.store` file so that
/// freed pages are correctly tracked across restarts.
pub fn saveFreeStore(engine: *GraphEngine) !void {
    const path = try std.fmt.allocPrint(engine.allocator, "{s}/free.store", .{engine.graph_dir.path});
    defer engine.allocator.free(path);

    // Compute total size needed for all 5 bitmaps.
    const total_size = engine.free_space_nodes.serializedSize() +
        engine.free_space_adj_out.serializedSize() +
        engine.free_space_adj_in.serializedSize() +
        engine.free_space_props.serializedSize() +
        engine.free_space_var.serializedSize();

    const buf = try engine.allocator.alloc(u8, total_size);
    defer engine.allocator.free(buf);

    var offset: usize = 0;
    const managers = [_]*const FreeSpaceManager{
        &engine.free_space_nodes,
        &engine.free_space_adj_out,
        &engine.free_space_adj_in,
        &engine.free_space_props,
        &engine.free_space_var,
    };
    for (managers) |fsm| {
        const written = fsm.serialize(buf[offset..]) catch return error.BufferTooSmall;
        offset += written;
    }

    const file = try std.fs.cwd().createFile(path, .{ .mode = owner_only_file_mode });
    defer file.close();
    try file.writeAll(buf[0..offset]);
}

/// Try to load free space bitmaps from a persisted `free.store` file.
/// Returns true if the file was loaded successfully, false if it does
/// not exist.
pub fn loadFreeStore(engine: *GraphEngine) !bool {
    const path = try std.fmt.allocPrint(engine.allocator, "{s}/free.store", .{engine.graph_dir.path});
    defer engine.allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    const file_size = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
    const buf = try engine.allocator.alloc(u8, file_size);
    defer engine.allocator.free(buf);

    const bytes_read = try file.readAll(buf);
    if (bytes_read != file_size) return error.UnexpectedEof;

    var offset: usize = 0;
    var managers = [_]*FreeSpaceManager{
        &engine.free_space_nodes,
        &engine.free_space_adj_out,
        &engine.free_space_adj_in,
        &engine.free_space_props,
        &engine.free_space_var,
    };
    for (&managers) |fsm| {
        const consumed = try fsm.deserialize(buf[offset..]);
        offset += consumed;
    }

    return true;
}

/// Rebuild free space bitmaps by scanning on-disk file sizes.
/// Called during open() after initSubsystems so that pages written in a
/// previous session are visible to scanNodes and other page walkers.
pub fn rebuildFreeSpaceFromDisk(engine: *GraphEngine) !void {
    const pairs = [_]struct { fsm: *FreeSpaceManager, fid: types.FileId }{
        .{ .fsm = &engine.free_space_nodes, .fid = .nodes },
        .{ .fsm = &engine.free_space_adj_out, .fid = .adj_out },
        .{ .fsm = &engine.free_space_adj_in, .fid = .adj_in },
        .{ .fsm = &engine.free_space_props, .fid = .props },
        .{ .fsm = &engine.free_space_var, .fid = .var_store },
    };

    for (pairs) |pair| {
        const pager = engine.file_manager.getPager(pair.fid) orelse continue;
        const page_count = pager.pageCount() catch continue;
        if (page_count == 0) continue;

        try pair.fsm.ensureCapacity(page_count);
        var i: usize = 0;
        while (i < page_count) : (i += 1) {
            pair.fsm.bitmap.set(i);
        }
    }
}

/// Persist the label dictionary to a `labels.dict` file.
pub fn saveLabelDictionary(engine: *GraphEngine) !void {
    const labels_path = try std.fmt.allocPrint(engine.allocator, "{s}/labels.dict", .{engine.graph_dir.path});
    defer engine.allocator.free(labels_path);
    try engine.label_dict.saveToFile(labels_path);
}
