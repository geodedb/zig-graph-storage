// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6461: an offline tool (no engine, no buffer pool) must be able to
// tell which pages of a store file are free, so it does not report stale
// records on freed pages as data. `FreeSpaceManager.init` needs a
// `*BufferPool`, and free.store's layout (seven bitmaps, the last two absent
// in files written before edge co-location) was private to engine_persist.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const io = std.Io.Threaded.global_single_threaded.io();

test "SONNY-6461: free.store reads back without an engine and matches the engine's bitmaps" {
    const alloc = testing.allocator;
    var td = try gs.test_support.TestDataDir.init(alloc);
    defer td.deinit();
    var cfg = gs.test_support.testConfig();
    cfg.page_size = 4096;

    const eng = try gs.GraphEngine.create(alloc, td.path, [_]u8{0x46} ** 16, cfg);
    var closed = false;
    defer if (!closed) eng.deinit();
    // A value too big for a var-store slab lives in a page chain; overwriting
    // it frees that chain's pages.
    const big = try alloc.alloc(u8, 3 * 4096);
    defer alloc.free(big);
    var nodes: [40]u64 = undefined;
    for (&nodes, 0..) |*id, i| {
        id.* = try eng.allocNode();
        try eng.putNode(id.*, gs.test_support.emptyNode(1));
        @memset(big, @truncate(i));
        var rec = (try eng.getNode(id.*)).?;
        rec.prop_head = try eng.putProperty(rec.prop_head, "big", .{ .string = big });
        try eng.putNode(id.*, rec);
    }
    for (nodes[0..20]) |id| {
        var rec = (try eng.getNode(id)).?;
        rec.prop_head = try eng.putProperty(rec.prop_head, "big", .{ .int = 1 });
        try eng.putNode(id, rec);
    }
    try eng.checkpoint();

    const fsms = [_]struct { fid: gs.FileId, fsm: *const gs.free_space.FreeSpaceManager }{
        .{ .fid = .nodes, .fsm = &eng.free_space_nodes },
        .{ .fid = .adj_out, .fsm = &eng.free_space_adj_out },
        .{ .fid = .adj_in, .fsm = &eng.free_space_adj_in },
        .{ .fid = .props, .fsm = &eng.free_space_props },
        .{ .fid = .var_store, .fsm = &eng.free_space_var },
        .{ .fid = .in_idx, .fsm = &eng.free_space_in_idx },
        .{ .fid = .in_dir, .fsm = &eng.free_space_in_dir },
    };
    const path = try std.fmt.allocPrint(alloc, "{s}/free.store", .{eng.graph_dir.path});
    defer alloc.free(path);

    var store = try gs.free_space.FreeStore.readFromFile(alloc, io, path);
    defer store.deinit();
    var freed_var: u64 = 0;
    for (fsms) |f| {
        const bm = store.get(f.fid) orelse return error.MissingBitmap;
        try testing.expectEqual(f.fsm.total_pages, bm.total_pages);
        var p: u64 = 0;
        while (p < f.fsm.total_pages) : (p += 1) {
            try testing.expectEqual(f.fsm.isAllocated(p), store.isAllocated(f.fid, p).?);
        }
        if (f.fid == .var_store) freed_var = bm.freeCount();
    }
    // Pages the overwrite freed are still in var.store, and the reader says so.
    const var_pages = (try eng.file_manager.getPager(.var_store).?.pageCount());
    var freed_in_file: u64 = 0;
    var p: u64 = 1;
    while (p < var_pages) : (p += 1) {
        if (!store.isAllocated(.var_store, p).?) freed_in_file += 1;
    }
    try testing.expect(freed_in_file > 0);
    try testing.expect(freed_var >= freed_in_file);
    closed = true;
    try eng.close();
}

test "SONNY-6461: a free.store written before edge co-location has no in_idx/in_dir bitmaps" {
    const alloc = testing.allocator;
    var td = try gs.test_support.TestDataDir.init(alloc);
    defer td.deinit();
    // Five bitmaps of 64 pages each: header (total_pages, next_free_hint) and
    // one u64 mask with page 0 reserved.
    var buf: [5 * 24]u8 = undefined;
    for (0..5) |i| {
        std.mem.writeInt(u64, buf[i * 24 ..][0..8], 64, .little);
        std.mem.writeInt(u64, buf[i * 24 + 8 ..][0..8], 1, .little);
        std.mem.writeInt(u64, buf[i * 24 + 16 ..][0..8], 0b1011, .little);
    }
    const f = try td.tmp_dir.dir.createFile(io, "free.store", .{ .truncate = true });
    try f.writePositionalAll(io, &buf, 0);
    f.close(io);
    const path = try std.fmt.allocPrint(alloc, "{s}/free.store", .{td.path});
    defer alloc.free(path);
    var store = try gs.free_space.FreeStore.readFromFile(alloc, io, path);
    defer store.deinit();
    try testing.expect(store.isAllocated(.var_store, 3).?);
    try testing.expect(!store.isAllocated(.var_store, 2).?);
    try testing.expect(!store.isAllocated(.nodes, 100).?); // beyond the bitmap: never allocated
    try testing.expectEqual(@as(?bool, null), store.isAllocated(.in_idx, 1));
    try testing.expect(store.get(.in_dir) == null);

    // A damaged file is an error, never a guess.
    const t = try td.tmp_dir.dir.createFile(io, "free.store", .{ .truncate = true });
    try t.writePositionalAll(io, buf[0..30], 0);
    t.close(io);
    try testing.expectError(error.UnexpectedEof, gs.free_space.FreeStore.readFromFile(alloc, io, path));
}
