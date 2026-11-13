// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6461: the page checksum (CRC32C) runs on every plaintext buffer-pool
// miss and flush. It used the standard library's byte-at-a-time table, about
// 16 us per 8 KiB page, which made plaintext cold reads ~4x slower than
// encrypted ones (`zig build bench-checksum -Doptimize=ReleaseFast`). On a CPU
// with a CRC32C instruction (x86_64 SSE4.2, aarch64 CRC) the page checksum
// must use it, and it must stay bit-identical to the table (stores on disk
// carry the old value).

const std = @import("std");
const builtin = @import("builtin");
const gs = @import("graph_storage");

const testing = std.testing;

/// The test binary is built for the native CPU, so its feature set is the
/// machine's.
const cpu_has_crc32c = switch (builtin.cpu.arch) {
    .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .sse4_2),
    .aarch64 => std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc) or builtin.os.tag == .macos,
    else => false,
};

test "SONNY-6461: the page checksum uses the CPU's CRC32C instruction where there is one" {
    if (!cpu_has_crc32c) return error.SkipZigTest;
    try testing.expect(gs.page.checksumHardwareAccelerated());
}

test "SONNY-6461: the page checksum is bit-identical to the table CRC32C" {
    var prng = std.Random.DefaultPrng.init(0x6461_0003);
    const r = prng.random();
    var buf: [65536 + 64]u8 = undefined;
    r.bytes(&buf);
    for (0..32) |off| {
        for (0..129) |len| {
            const s = buf[off..][0..len];
            try testing.expectEqual(std.hash.crc.Crc32Iscsi.hash(s), gs.page.computeChecksum(s));
        }
    }
    for (0..1000) |_| {
        const off = r.uintLessThan(usize, 64);
        const len = r.uintLessThan(usize, 65536);
        const s = buf[off..][0..len];
        try testing.expectEqual(std.hash.crc.Crc32Iscsi.hash(s), gs.page.computeChecksum(s));
    }
}

test "SONNY-6461: a plaintext store written before the change still verifies" {
    // Pages written with the table checksum read back through the pager.
    var td = try gs.test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try td.tmp_dir.dir.createFile(io, "p.store", .{ .read = true, .truncate = true });
    defer file.close(io);
    var page: [8192]u8 = undefined;
    @memset(&page, 0);
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(page[32..]);
    std.mem.writeInt(u32, page[16..20], std.hash.crc.Crc32Iscsi.hash(page[32..]), .little);
    try file.writePositionalAll(io, &page, 8192);
    const pager = gs.pager.Pager.init(file, 8192);
    var back: [8192]u8 = undefined;
    try pager.readPage(1, &back);
    try testing.expectEqualSlices(u8, &page, &back);
}
