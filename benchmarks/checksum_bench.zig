// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6461: page checksum micro-benchmark.
//
// Times `page.computeChecksum` over 8 KiB page bodies (what the pager hashes
// on every plaintext read and write), the standard library's table CRC32C
// for reference, and `Pager.readPage` of a plaintext and an encrypted page
// (the file is in the page cache, so the difference is CPU: CRC32C versus
// AES-GCM). Run with `zig build bench-checksum -Doptimize=ReleaseFast`.

const std = @import("std");
const gs = @import("graph_storage");

const PAGE: usize = 8192;
const BODY: usize = PAGE - gs.page.PAGE_HEADER_SIZE;
const ROUNDS: usize = 5;

fn nowNs() u64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds);
}

/// Median over ROUNDS of the per-call time of `f(arg)` repeated `iters` times.
fn medianNs(comptime f: anytype, arg: anytype, iters: usize) f64 {
    var samples: [ROUNDS]f64 = undefined;
    var sink: u32 = 0;
    for (&samples) |*s| {
        const t0 = nowNs();
        for (0..iters) |_| sink +%= f(arg);
        s.* = @as(f64, @floatFromInt(nowNs() - t0)) / @as(f64, @floatFromInt(iters));
    }
    std.mem.doNotOptimizeAway(sink);
    std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
    return samples[ROUNDS / 2];
}

fn pageChecksum(body: []const u8) u32 {
    return gs.page.computeChecksum(body);
}

fn tableChecksum(body: []const u8) u32 {
    return std.hash.crc.Crc32Iscsi.hash(body);
}

const ReadArg = struct { pager: *const gs.pager.Pager, buf: []u8, pages: u64 };
var next_page: u64 = 0;

fn readOne(a: ReadArg) u32 {
    next_page = (next_page + 1) % a.pages;
    a.pager.readPage(next_page, a.buf) catch unreachable;
    return a.buf[100];
}

pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var body: [BODY]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x6461);
    prng.random().bytes(&body);

    const iters: usize = 20_000;
    const page_ns = medianNs(pageChecksum, @as([]const u8, &body), iters);
    const table_ns = medianNs(tableChecksum, @as([]const u8, &body), iters);

    const tmp_name = "checksum-bench.tmp";
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, tmp_name);
    defer cwd.deleteTree(io, tmp_name) catch {};
    var tmp_dir = try cwd.openDir(io, tmp_name, .{});
    defer tmp_dir.close(io);
    const pages: u64 = 512;
    var results: [2]f64 = undefined;
    for ([_]?[32]u8{ null, [_]u8{0x5a} ** 32 }, 0..) |key, ki| {
        const name = if (key == null) "plain.store" else "enc.store";
        const file = try tmp_dir.createFile(io, name, .{ .read = true, .truncate = true });
        defer file.close(io);
        var pager = gs.pager.Pager.init(file, PAGE);
        if (key) |k| pager.encryption = gs.encryption.PageEncryption.init(k);
        pager.file_id = .nodes;
        var buf: [PAGE]u8 = undefined;
        for (0..pages) |p| {
            @memset(&buf, 0);
            prng.random().bytes(buf[gs.page.PAGE_HEADER_SIZE..]);
            try pager.writePage(p, &buf);
        }
        results[ki] = medianNs(readOne, ReadArg{ .pager = &pager, .buf = &buf, .pages = pages }, 20_000);
    }

    std.debug.print(
        \\{{"page_size":{d},"page_checksum_ns":{d:.0},"page_checksum_gbps":{d:.2},"std_table_crc32c_ns":{d:.0},"read_page_plaintext_ns":{d:.0},"read_page_encrypted_ns":{d:.0}}}
        \\
    , .{
        PAGE,
        page_ns,
        @as(f64, @floatFromInt(BODY)) / page_ns,
        table_ns,
        results[0],
        results[1],
    });
}
