// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6441: committed records lost under at-rest page encryption.
//
// When a store is encrypted the pager writes the 16-byte AES-GCM tag into the
// LAST 16 bytes of every page it flushes, and on read it decrypts only the
// bytes before the tag, leaving the tag bytes in the cached frame. Any store
// whose records can occupy those bytes loses them the first time the page is
// written and read back: after an eviction under a small buffer pool, after a
// clean reopen, and after crash recovery (recovery replays the right image,
// the next flush cuts the tail off again). Decryption itself succeeds, so the
// loss is silent: a node whose record ends at the page end reads back with
// the tag in `flags`/`txn_stamp` and is reported DELETED, i.e. missing.
//
// Plaintext pages keep their whole body (the CRC32C sits in the header), so
// the same workload without a key is the control: it must stay lossless.
//
// The scenarios use the DEFAULT 8 KiB page (geode's layout) unless they
// target another size. Tests:
//   * small pool, encrypted: every node + property survives eviction/reload
//     (the operator reach reported against geode: GEODE_BUFFER_POOL_PAGES
//     below the store size with auto-sizing off), plaintext as control;
//   * clean close + reopen and crash recovery keep every node and property;
//   * the co-located incoming-edge directory (adj_in_dir) and wide (v3)
//     adjacency chain blocks at 4 KiB keep every entry;
//   * the ShardedGraphEngine workload of the geode reproduction;
//   * a page that fails authentication surfaces as an error, never as an
//     empty slot / missing node.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const GraphConfig = gs.GraphConfig;
const test_support = gs.test_support;

const io = std.Io.Threaded.global_single_threaded.io();

const KEY: [32]u8 = [_]u8{0x41} ** 32;
const PAYLOAD_LEN: usize = 512;

const Pager = gs.pager.Pager;
const PAGE_HEADER_SIZE = gs.page.PAGE_HEADER_SIZE;
const TAG_SIZE = gs.encryption.TAG_SIZE;

fn bodyPattern(buf: []u8) void {
    for (buf[PAGE_HEADER_SIZE..], 0..) |*b, j| b.* = @truncate(j *% 7 +% 1);
}

test "SONNY-6441: the encrypted pager round-trips the whole page body" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const file = try td.tmp_dir.dir.createFile(io, "pager.store", .{ .read = true, .truncate = true });
    defer file.close(io);

    for ([_]u32{ 4096, 8192, 16384 }) |ps| {
        var pager = Pager.init(file, ps);
        pager.encryption = gs.encryption.PageEncryption.init(KEY);
        pager.file_id = .nodes;

        const page = try testing.allocator.alloc(u8, ps);
        defer testing.allocator.free(page);
        const back = try testing.allocator.alloc(u8, ps);
        defer testing.allocator.free(back);
        // Two writes: the second re-encrypts a page whose write_count is 1.
        for (0..2) |round| {
            @memset(page, 0);
            bodyPattern(page);
            gs.page.writeWriteCount(page, @intCast(round));
            const scratch = try testing.allocator.dupe(u8, page);
            defer testing.allocator.free(scratch);
            try pager.writePage(3, scratch);
            try pager.readPage(3, back);
            if (!std.mem.eql(u8, page[PAGE_HEADER_SIZE..], back[PAGE_HEADER_SIZE..])) {
                var first: usize = PAGE_HEADER_SIZE;
                while (page[first] == back[first]) first += 1;
                std.debug.print("page_size {d}: body differs after encrypt/decrypt from byte {d} (page end - {d})\n", .{ ps, first, ps - first });
                return error.EncryptedBodyNotPreserved;
            }
        }
    }
}

test "SONNY-6441: pages written in the pre-fix envelope (tag in the body tail) stay readable" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const file = try td.tmp_dir.dir.createFile(io, "legacy.store", .{ .read = true, .truncate = true });
    defer file.close(io);
    const ps: u32 = 8192;
    var pager = Pager.init(file, ps);
    pager.encryption = gs.encryption.PageEncryption.init(KEY);
    pager.file_id = .props;

    // Build exactly what an affected binary put on disk: write_count 1, the
    // tag over the last TAG_SIZE body bytes, AAD = the whole 32-byte header.
    var page: [8192]u8 = undefined;
    @memset(&page, 0);
    bodyPattern(&page);
    gs.page.writeWriteCount(&page, 1);
    var disk = page;
    pager.encryption.?.encryptPage(&disk, 5, @intFromEnum(gs.types.FileId.props), 1);
    try file.writePositionalAll(io, &disk, 5 * ps);

    var back: [8192]u8 = undefined;
    try pager.readPage(5, &back);
    // Every byte the legacy envelope persisted reads back intact ...
    try testing.expectEqualSlices(u8, page[PAGE_HEADER_SIZE .. ps - TAG_SIZE], back[PAGE_HEADER_SIZE .. ps - TAG_SIZE]);
    // ... and the tail that held the tag (never data) reads as zero, so no
    // layout decodes tag bytes as a record.
    try testing.expectEqualSlices(u8, &([_]u8{0} ** TAG_SIZE), back[ps - TAG_SIZE ..]);

    // Rewriting it (next flush) moves the page to the current envelope and
    // the full body round-trips from then on.
    bodyPattern(&back);
    var scratch = back;
    try pager.writePage(5, &scratch);
    var again: [8192]u8 = undefined;
    try pager.readPage(5, &again);
    try testing.expectEqualSlices(u8, back[PAGE_HEADER_SIZE..], again[PAGE_HEADER_SIZE..]);
    try testing.expect(gs.page.readWriteCount(&again) == 2);

    // A wrong key is still an authentication failure for both envelopes.
    var wrong = Pager.init(file, ps);
    wrong.encryption = gs.encryption.PageEncryption.init([_]u8{0x42} ** 32);
    wrong.file_id = .props;
    try testing.expectError(error.DecryptionFailed, wrong.readPage(5, &again));
    try file.writePositionalAll(io, &disk, 6 * ps);
    try testing.expectError(error.DecryptionFailed, pager.readPage(6, &again)); // nonce bound to page id
}

fn config(page_size: u32, key: ?[32]u8, pool_pages: u32) GraphConfig {
    return .{
        .page_size = page_size,
        .buffer_pool_pages = pool_pages,
        .buffer_pool_auto_size = false,
        .encryption_key = key,
        .data_dir = "data",
    };
}

fn payloadByte(i: usize, j: usize) u8 {
    return @truncate((i *% 2654435761) +% j *% 31 +% 7);
}

fn fillPayload(buf: *[PAYLOAD_LEN]u8, i: usize) void {
    for (buf, 0..) |*b, j| b.* = payloadByte(i, j);
}

/// Insert node #i with an int property "i" and a 512-byte string "payload".
fn writeNode(eng: *GraphEngine, i: usize) !u64 {
    var payload: [PAYLOAD_LEN]u8 = undefined;
    fillPayload(&payload, i);
    const id = try eng.allocNode();
    try eng.putNode(id, test_support.emptyNode(1));
    var rec = (try eng.getNode(id)).?;
    rec.prop_head = try eng.putProperty(rec.prop_head, "i", .{ .int = @intCast(i) });
    rec.prop_head = try eng.putProperty(rec.prop_head, "payload", .{ .string = &payload });
    try eng.putNode(id, rec);
    return id;
}

/// Verify node #i and both of its properties. Returns false (and prints the
/// node's page/slot) when the node or a property is missing or wrong.
fn nodeIntact(alloc: Allocator, eng: *GraphEngine, id: u64, i: usize, what: []const u8) !bool {
    const npp = eng.node_store.nodes_per_page;
    const rec = (try eng.getNode(id)) orelse {
        std.debug.print("{s}: committed node {d} (#{d}, page {d} slot {d}/{d}) reads back as MISSING\n", .{ what, id, i, id / npp, id % npp, npp });
        return false;
    };
    if (rec.txn_stamp != 1 or rec.label_count != 0) {
        std.debug.print("{s}: node {d} (slot {d}/{d}) record corrupted: txn_stamp={x} label_count={d} flags={x}\n", .{ what, id, id % npp, npp, rec.txn_stamp, rec.label_count, rec.flags });
        return false;
    }
    const iv = (try eng.getProperty(rec.prop_head, "i", alloc)) orelse {
        std.debug.print("{s}: node {d} lost property 'i'\n", .{ what, id });
        return false;
    };
    switch (iv) {
        .int => |x| if (x != @as(i64, @intCast(i))) {
            std.debug.print("{s}: node {d} property 'i' = {d}, want {d}\n", .{ what, id, x, i });
            return false;
        },
        else => return false,
    }
    const pv = (try eng.getProperty(rec.prop_head, "payload", alloc)) orelse {
        std.debug.print("{s}: node {d} lost property 'payload'\n", .{ what, id });
        return false;
    };
    defer gs.property.freeDecoded(alloc, pv);
    var want: [PAYLOAD_LEN]u8 = undefined;
    fillPayload(&want, i);
    switch (pv) {
        .string => |s| if (!std.mem.eql(u8, s, &want)) {
            std.debug.print("{s}: node {d} property 'payload' differs\n", .{ what, id });
            return false;
        },
        else => return false,
    }
    return true;
}

fn countDamaged(alloc: Allocator, eng: *GraphEngine, ids: []const u64, what: []const u8) !usize {
    var damaged: usize = 0;
    for (ids, 0..) |id, i| {
        if (!try nodeIntact(alloc, eng, id, i, what)) damaged += 1;
    }
    return damaged;
}

/// The geode workload: insert, read back a random earlier node after every
/// insert, checkpoint every 256. Returns how many random reads found the node
/// missing or damaged.
fn ingestWithRandomReads(alloc: Allocator, eng: *GraphEngine, ids: []u64) !usize {
    var prng = std.Random.DefaultPrng.init(0x6441);
    const r = prng.random();
    var lost: usize = 0;
    for (ids, 0..) |*id, i| {
        id.* = try writeNode(eng, i);
        const k = r.uintLessThan(usize, i + 1);
        if (!try nodeIntact(alloc, eng, ids[k], k, "random read during ingest")) lost += 1;
        if ((i + 1) % 256 == 0) try eng.checkpoint();
    }
    return lost;
}

fn smallPoolScenario(alloc: Allocator, page_size: u32, key: ?[32]u8, n: usize) !void {
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0x64} ** 16;
    var cfg = config(page_size, key, 8);
    cfg.sync_mode = .deferred;

    const ids = try alloc.alloc(u64, n);
    defer alloc.free(ids);
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        const lost = try ingestWithRandomReads(alloc, eng, ids);
        try testing.expectEqual(@as(usize, 0), lost);
        try testing.expectEqual(@as(usize, 0), try countDamaged(alloc, eng, ids, "full scan after ingest"));
    }
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try testing.expectEqual(@as(usize, 0), try countDamaged(alloc, eng, ids, "full scan after reopen"));
        // A page scan must see exactly the committed nodes: no node lost and
        // no phantom node decoded from tag bytes in an unused slot.
        var counter = ScanCounter{};
        try eng.node_store.scanNodes(eng.manifest.next_node_id, &counter, &ScanCounter.visit);
        try testing.expectEqual(n, counter.n);
    }
}

const ScanCounter = struct {
    n: usize = 0,
    fn visit(self: *ScanCounter, _: u64, _: gs.node.NodeRec) void {
        self.n += 1;
    }
};

test "SONNY-6441: encrypted 8 KiB store keeps every node through small-pool eviction and reopen" {
    try smallPoolScenario(testing.allocator, 8192, KEY, 2000);
}

test "SONNY-6441: plaintext 8 KiB store keeps every node through small-pool eviction and reopen (control)" {
    try smallPoolScenario(testing.allocator, 8192, null, 2000);
}

test "SONNY-6441: encrypted 4 KiB and 16 KiB stores keep every node through small-pool eviction and reopen" {
    try smallPoolScenario(testing.allocator, 4096, KEY, 600);
    try smallPoolScenario(testing.allocator, 16384, KEY, 800);
}

test "SONNY-6441: encrypted store keeps every committed node across a crash (WAL recovery)" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0x65} ** 16;
    // Full pool: no eviction before the crash, so the only reload is recovery.
    const cfg = config(8192, KEY, 256);

    var ids: [400]u64 = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.deinit();
        for (ids[0..200], 0..) |*id, i| id.* = try writeNode(eng, i);
        try eng.checkpoint();
        for (ids[200..], 200..) |*id, i| id.* = try writeNode(eng, i);
        eng.deinit(); // crash: no checkpoint, no close
    }
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try testing.expectEqual(@as(usize, 0), try countDamaged(alloc, eng, &ids, "after crash recovery"));
        try eng.checkpoint();
    }
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try testing.expectEqual(@as(usize, 0), try countDamaged(alloc, eng, &ids, "reopen after post-recovery checkpoint"));
    }
}

test "SONNY-6441: encrypted co-located incoming-edge directory keeps every head" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0x66} ** 16;
    // 4 KiB in_dir pages hold 508 heads; heads 506/507 end at the page end
    // (every page size leaves the directory zero slack). 4 KiB node pages end
    // 32 bytes short of the tag, so node records are not involved here.
    const cfg = config(4096, KEY, 8);
    const n: usize = 1100;
    const ids = try alloc.alloc(u64, n);
    defer alloc.free(ids);
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        for (ids) |*id| {
            id.* = try eng.allocNode();
            try eng.putNode(id.*, test_support.emptyNode(1));
        }
        for (ids[1..]) |dst| _ = try eng.addEdgeColocatedWithPublicId(ids[0], dst, 7, dst + 1);
        try eng.checkpoint();
    }
    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    var missing: usize = 0;
    for (ids[1..]) |dst| {
        var it = try eng.expandInRemoteIter(dst, null);
        defer it.deinit();
        var found = false;
        while (try it.next()) |e| {
            if (e.neighbor == ids[0] and e.public_id == dst + 1) found = true;
        }
        if (!found) {
            std.debug.print("incoming edge to {d} (in_dir slot {d}/{d}) missing after reopen\n", .{ dst, dst % eng.in_head_dir.heads_per_page, eng.in_head_dir.heads_per_page });
            missing += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), missing);
}

test "SONNY-6441: encrypted 4 KiB wide adjacency chain blocks keep every entry" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0x67} ** 16;
    // 4 KiB v3 (40 B) chain blocks hold 101 entries ending 8 bytes before the
    // page end — inside the 16-byte tag.
    const cfg = config(4096, KEY, 8);

    const fanout: usize = 350;
    var dsts: [fanout]u64 = undefined;
    var src: u64 = 0;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        src = try eng.allocNode();
        try eng.putNode(src, test_support.emptyNode(1));
        for (&dsts) |*d| {
            d.* = try eng.allocNode();
            try eng.putNode(d.*, test_support.emptyNode(1));
        }
        for (dsts) |d| _ = try eng.addEdgeColocatedWithPublicId(src, d, 9, d + 1);
        try eng.checkpoint();
    }
    const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
    defer eng.close() catch {};
    const out = try eng.expandOut(src, null, alloc);
    defer alloc.free(out);
    var seen = [_]bool{false} ** fanout;
    for (out) |e| {
        for (dsts, 0..) |d, k| {
            // No edge carries properties: a nonzero prop_head is tag bytes
            // in the high half of the block's last v3 entry.
            if (e.neighbor == d and e.public_id == d + 1 and e.rel_type == 9 and e.prop_head == 0) seen[k] = true;
        }
    }
    var missing: usize = 0;
    for (seen, 0..) |s, k| if (!s) {
        std.debug.print("out-edge {d} -> {d} missing or corrupted after reopen\n", .{ src, dsts[k] });
        missing += 1;
    };
    try testing.expectEqual(@as(usize, 0), missing);
    try testing.expectEqual(fanout, out.len);
}

/// The geode reproduction (tests/test_sonny6435_tde_small_pool_node_loss.zig)
/// against the sharded engine it drives: 2000 nodes, 8-page pools.
fn shardedLostReads(alloc: Allocator, dir: []const u8, key: ?[32]u8, n: usize) !usize {
    const eng = try gs.ShardedGraphEngine.create(alloc, dir, [_]u8{0x35} ** 16, .{
        .data_dir = dir,
        .encryption_key = key,
        .sync_mode = .deferred,
        .buffer_pool_pages = 8,
        .buffer_pool_auto_size = false,
    });
    defer eng.close() catch {};
    var ids: std.ArrayListUnmanaged(u64) = .empty;
    defer ids.deinit(alloc);
    var prng = std.Random.DefaultPrng.init(0x6435);
    const r = prng.random();
    var payload: [PAYLOAD_LEN]u8 = undefined;
    var lost: usize = 0;
    for (0..n) |i| {
        r.bytes(&payload);
        const id = try eng.allocNode();
        try eng.putNode(id, test_support.emptyNode(1));
        var rec = (try eng.getNode(id)).?;
        rec.prop_head = try eng.putNodeProperty(id, rec.prop_head, "payload", .{ .string = &payload });
        try eng.putNode(id, rec);
        try ids.append(alloc, id);
        const earlier = ids.items[r.uintLessThan(usize, ids.items.len)];
        if ((try eng.getNode(earlier)) == null) lost += 1;
        if ((i + 1) % 256 == 0) try eng.checkpoint();
    }
    return lost;
}

test "SONNY-6441: sharded engine with page encryption and 8-page pools loses no node (geode workload)" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const plain_dir = try std.fmt.allocPrint(alloc, "{s}/plain", .{td.path});
    defer alloc.free(plain_dir);
    const tde_dir = try std.fmt.allocPrint(alloc, "{s}/tde", .{td.path});
    defer alloc.free(tde_dir);
    try std.Io.Dir.cwd().createDirPath(io, plain_dir);
    try std.Io.Dir.cwd().createDirPath(io, tde_dir);
    const plain_lost = try shardedLostReads(alloc, plain_dir, null, 2000);
    const tde_lost = try shardedLostReads(alloc, tde_dir, KEY, 2000);
    try testing.expectEqual(@as(usize, 0), plain_lost);
    try testing.expectEqual(@as(usize, 0), tde_lost);
}

/// Path of `file` inside the engine's graph directory (caller frees).
fn storePath(alloc: Allocator, eng: *GraphEngine, file: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ eng.graph_dir.path, file });
}

fn tamperNodePage(alloc: Allocator, td_path: []const u8, uuid: [16]u8, cfg: GraphConfig, offset: u64, bytes: []const u8) !void {
    const eng = try GraphEngine.open(alloc, td_path, uuid, cfg);
    const path = try storePath(alloc, eng, "nodes.store");
    defer alloc.free(path);
    try eng.close();
    const f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer f.close(io);
    try f.writePositionalAll(io, bytes, offset);
}

test "SONNY-6441: an encrypted page that fails authentication is an error, never a missing node" {
    const alloc = testing.allocator;
    const uuid = [_]u8{0x68} ** 16;
    const cfg = config(8192, KEY, 8);

    // (a) one flipped ciphertext byte; (b) the whole page header zeroed
    // (the header is what tells a fresh page from a written one).
    const zero_header = [_]u8{0} ** 32;
    const flip = [_]u8{0x5a};
    const cases = [_]struct { offset: u64, bytes: []const u8 }{
        .{ .offset = 8192 + 1000, .bytes = &flip },
        .{ .offset = 8192, .bytes = &zero_header },
    };
    for (cases) |c| {
        var td = try test_support.TestDataDir.init(alloc);
        defer td.deinit();
        var ids: [300]u64 = undefined;
        {
            const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
            defer eng.close() catch {};
            for (&ids, 0..) |*id, i| id.* = try writeNode(eng, i);
            try eng.checkpoint();
        }
        try tamperNodePage(alloc, td.path, uuid, cfg, c.offset, c.bytes);

        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        // Node page 1 holds ids [npp, 2*npp). Reading one must fail loudly.
        const npp = eng.node_store.nodes_per_page;
        var errors: usize = 0;
        var missing: usize = 0;
        for (ids) |id| {
            if (id / npp != 1) continue;
            if (eng.getNode(id)) |maybe| {
                if (maybe == null) missing += 1;
            } else |_| errors += 1;
        }
        if (missing != 0) std.debug.print("tampered page (offset {d}): {d} nodes read back as MISSING instead of an error\n", .{ c.offset, missing });
        try testing.expectEqual(@as(usize, 0), missing);
        try testing.expect(errors > 0);
    }
}
