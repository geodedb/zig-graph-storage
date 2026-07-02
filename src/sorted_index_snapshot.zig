// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! GAP warm-reopen P1: mmap-backed SORTED fixed-width-record index snapshot.
//!
//! The legacy container (index_snapshot.zig) forces the loader to READ the
//! whole file (whole-file CRC + resident hashmap build) — O(snapshot) at
//! open/first-access. This container is designed so the load is
//! O(mmap + header/directory read) and record access pages in on demand:
//!
//!   * records are FIXED WIDTH and SORTED by the caller's key, so lookups are
//!     a binary search directly over the mapped bytes — no resident hashmap
//!     is ever built from the base;
//!   * integrity is per-BLOCK: the payload is covered by a CRC32 directory
//!     (one CRC per `block_size` payload bytes) that is verified LAZILY on
//!     first touch of each block, while the header + directory themselves are
//!     verified EAGERLY at load by a trailing meta-CRC.
//!
//! On-disk layout (all integers little-endian; readers use std.mem.readInt so
//! no alignment is assumed):
//!
//!   0   magic[8]            (per-index format version — bump on ANY change)
//!   8   checkpoint_counter  u64   (caller's staleness gate)
//!   16  record_count        u64
//!   24  record_size         u32   (must equal the caller's expected size)
//!   28  block_size          u32
//!   32  payload             record_count * record_size bytes, SORTED
//!   ..  block_crcs          u32[ceil(payload_len / block_size)]
//!   ..  meta_crc            u32 over bytes [8..32) ++ block_crcs region
//!
//! CRASH-SAFETY / FAILURE MODEL (precise):
//!
//!   1. Torn checkpoint write. `write` truncates, writes the ENTIRE file with
//!      the magic ZEROED, fsyncs, then writes the magic and fsyncs again. A
//!      valid magic therefore implies the payload + directory were durable
//!      BEFORE it (write-ordering via fsync). A crash anywhere in the window
//!      leaves a zero/partial magic or a short file → `load` rejects
//!      (error.InvalidFormat) → the caller's existing counter-gated REBUILD
//!      path runs. This relies on the journaled-fs guarantee the rest of the
//!      engine already assumes (a truncate is never reordered after later
//!      writes to the same file).
//!   2. Old snapshot after crash-before-checkpoint-manifest. Both file and
//!      manifest are the OLD consistent state → counter gate accepts the old
//!      snapshot, which is correct (nothing newer was durable).
//!   3. Stale snapshot (light checkpoints, crash after manifest write). The
//!      caller compares `checkpoint_counter` against manifest.counter exactly
//!      as before → mismatch → rebuild. The counter is covered by the eagerly
//!      verified meta-CRC, so a corrupt counter cannot skip the gate.
//!   4. Post-write media corruption (bit-rot). Header/directory corruption is
//!      caught EAGERLY at load (meta-CRC → error.ChecksumMismatch → rebuild).
//!      Payload corruption is caught LAZILY at first access of the affected
//!      block (error.ChecksumMismatch surfaced to the accessor). This is the
//!      SAME failure class as bit-rot on a data page (page CRC → hard error),
//!      NOT a silent wrong answer; eager whole-payload verification would
//!      reintroduce the O(snapshot) read this format exists to remove.
//!
//! UNMAP ORDERING (GAP-ENT-0018 UAF class): `Loaded.deinit` unmaps the base.
//! Record slices returned by `recordAt` alias the mapping, so the base MUST
//! outlive every reader. Owners (edge_index_map.zig / edge_exist_index.zig)
//! only unmap in paths where no concurrent reader can exist: under the
//! derived-hydration latch (before the index is published / on load failure)
//! and at engine teardown.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Same CRC family as the legacy container + manifest.
// fips-exempt: non-security — CRC32C corruption detection for on-disk format.
const Crc32 = std.hash.crc.Crc32Iscsi;

pub const HEADER_SIZE: usize = 32;
pub const META_CRC_SIZE: usize = 4;
pub const BLOCK_CRC_SIZE: usize = 4;

/// Payload bytes covered by one directory CRC. 64 KiB keeps first-touch
/// verification cheap (a binary search over millions of records verifies a
/// few dozen blocks, ~single-digit MB of CRC work, amortized to zero).
pub const DEFAULT_BLOCK_SIZE: u32 = 64 * 1024;

/// Bounds accepted from disk for `block_size` (defense vs corrupt headers —
/// the directory length derives from it).
const MIN_BLOCK_SIZE: u32 = 4096;
const MAX_BLOCK_SIZE: u32 = 1 << 24;

fn ioT() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Write a complete snapshot: header (magic LAST, see failure model above),
/// caller-sorted payload, per-block CRC directory, meta-CRC trailer.
/// `payload.len` must be a multiple of `record_size`.
pub fn write(
    allocator: Allocator,
    file: std.Io.File,
    magic: []const u8,
    checkpoint_counter: u64,
    record_size: u32,
    payload: []const u8,
) !void {
    if (magic.len != 8) return error.InvalidMagicLength;
    std.debug.assert(record_size > 0);
    std.debug.assert(payload.len % record_size == 0);
    const io = ioT();

    const record_count: u64 = payload.len / record_size;
    const nblocks: usize = (payload.len + DEFAULT_BLOCK_SIZE - 1) / DEFAULT_BLOCK_SIZE;

    // Header with the magic ZEROED — it is published last, after the body is
    // durable, so a valid magic implies a complete file.
    var hdr = [_]u8{0} ** HEADER_SIZE;
    std.mem.writeInt(u64, hdr[8..16], checkpoint_counter, .little);
    std.mem.writeInt(u64, hdr[16..24], record_count, .little);
    std.mem.writeInt(u32, hdr[24..28], record_size, .little);
    std.mem.writeInt(u32, hdr[28..32], DEFAULT_BLOCK_SIZE, .little);

    // Per-block payload CRC directory + trailing meta-CRC over
    // (header-after-magic ++ directory).
    const dir = try allocator.alloc(u8, nblocks * BLOCK_CRC_SIZE + META_CRC_SIZE);
    defer allocator.free(dir);
    var b: usize = 0;
    while (b < nblocks) : (b += 1) {
        const start = b * DEFAULT_BLOCK_SIZE;
        const end = @min(start + DEFAULT_BLOCK_SIZE, payload.len);
        std.mem.writeInt(u32, dir[b * BLOCK_CRC_SIZE ..][0..4], Crc32.hash(payload[start..end]), .little);
    }
    var meta = Crc32.init();
    meta.update(hdr[8..HEADER_SIZE]);
    meta.update(dir[0 .. nblocks * BLOCK_CRC_SIZE]);
    std.mem.writeInt(u32, dir[nblocks * BLOCK_CRC_SIZE ..][0..4], meta.final(), .little);

    try file.setLength(io, 0);
    try file.writePositionalAll(io, &hdr, 0);
    try file.writePositionalAll(io, payload, HEADER_SIZE);
    try file.writePositionalAll(io, dir, HEADER_SIZE + payload.len);
    // Body durable BEFORE the magic is published (torn-write defense #1).
    try file.sync(io);
    try file.writePositionalAll(io, magic, 0);
    try file.sync(io);
}

/// An mmap'd, lazily-verified snapshot base. Owns the mapping and the
/// verified-block bitset. NOT internally synchronized beyond the bitset:
/// callers keep the same external-serialization contract the resident
/// hashmaps had (the bitset itself uses atomics so concurrent READERS are
/// safe — verification is idempotent and monotone).
pub const Loaded = struct {
    allocator: Allocator,
    mapping: []align(std.heap.page_size_min) u8,
    checkpoint_counter: u64,
    record_count: u64,
    record_size: u32,
    block_size: u32,
    payload_len: usize,
    /// One bit per payload block, set once the block's CRC has verified.
    verified: []std.atomic.Value(usize),

    const WORD_BITS = @bitSizeOf(usize);

    fn payload(self: *const Loaded) []const u8 {
        return self.mapping[HEADER_SIZE..][0..self.payload_len];
    }

    fn dirEntry(self: *const Loaded, block: usize) u32 {
        const dir_off = HEADER_SIZE + self.payload_len + block * BLOCK_CRC_SIZE;
        return std.mem.readInt(u32, self.mapping[dir_off..][0..4], .little);
    }

    fn verifyBlock(self: *Loaded, block: usize) !void {
        const word = block / WORD_BITS;
        const bit: usize = @as(usize, 1) << @intCast(block % WORD_BITS);
        if (self.verified[word].load(.acquire) & bit != 0) return;
        const start = block * @as(usize, self.block_size);
        const end = @min(start + self.block_size, self.payload_len);
        if (Crc32.hash(self.payload()[start..end]) != self.dirEntry(block)) {
            return error.ChecksumMismatch;
        }
        _ = self.verified[word].fetchOr(bit, .acq_rel);
    }

    /// Borrow record `i` (bytes alias the mapping — valid until deinit).
    /// Verifies the covering block(s) on first touch; a CRC mismatch is
    /// surfaced as error.ChecksumMismatch (failure model #4 above).
    pub fn recordAt(self: *Loaded, i: u64) ![]const u8 {
        std.debug.assert(i < self.record_count);
        const rs: usize = self.record_size;
        const off: usize = @as(usize, @intCast(i)) * rs;
        const b0 = off / self.block_size;
        const b1 = (off + rs - 1) / self.block_size;
        try self.verifyBlock(b0);
        if (b1 != b0) try self.verifyBlock(b1);
        return self.payload()[off..][0..rs];
    }

    /// Unmap. See the UNMAP ORDERING note in the file header: callers must
    /// guarantee no reader still holds a `recordAt` slice.
    pub fn deinit(self: *Loaded) void {
        std.posix.munmap(self.mapping);
        self.allocator.free(self.verified);
    }
};

/// mmap + validate a snapshot file. Returns:
///   * null                    — empty file (never written): caller rebuilds;
///   * error.InvalidFormat     — wrong/zero magic (old format or torn write),
///                               wrong record_size, insane block_size, or a
///                               size/layout mismatch (truncation): caller's
///                               `catch false` routes to the rebuild path;
///   * error.ChecksumMismatch  — header/directory corruption: rebuild path.
/// The payload is NOT read here — that is the point.
pub fn load(
    allocator: Allocator,
    file: *std.Io.File,
    expected_magic: []const u8,
    expected_record_size: u32,
) !?Loaded {
    if (expected_magic.len != 8) return error.InvalidMagicLength;
    const io = ioT();

    const stat = try file.stat(io);
    if (stat.size == 0) return null;
    const size: usize = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
    if (size < HEADER_SIZE + META_CRC_SIZE) return error.InvalidFormat;

    const mapping: []align(std.heap.page_size_min) u8 = try std.posix.mmap(
        null,
        size,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
    errdefer std.posix.munmap(mapping);
    // Lookups are binary searches / point probes — hint random access.
    std.posix.madvise(mapping.ptr, mapping.len, std.posix.MADV.RANDOM) catch {};

    if (!std.mem.eql(u8, mapping[0..8], expected_magic)) return error.InvalidFormat;

    const counter = std.mem.readInt(u64, mapping[8..16], .little);
    const record_count = std.mem.readInt(u64, mapping[16..24], .little);
    const record_size = std.mem.readInt(u32, mapping[24..28], .little);
    const block_size = std.mem.readInt(u32, mapping[28..32], .little);

    if (record_size != expected_record_size) return error.InvalidFormat;
    if (block_size < MIN_BLOCK_SIZE or block_size > MAX_BLOCK_SIZE) return error.InvalidFormat;

    // Overflow-checked layout; any mismatch = truncated/corrupt → reject.
    const m = std.math;
    const payload_len = m.mul(usize, m.cast(usize, record_count) orelse return error.InvalidFormat, record_size) catch return error.InvalidFormat;
    const nblocks = if (payload_len == 0) 0 else (payload_len - 1) / block_size + 1;
    const dir_off = m.add(usize, HEADER_SIZE, payload_len) catch return error.InvalidFormat;
    const meta_off = m.add(usize, dir_off, m.mul(usize, nblocks, BLOCK_CRC_SIZE) catch return error.InvalidFormat) catch return error.InvalidFormat;
    const total = m.add(usize, meta_off, META_CRC_SIZE) catch return error.InvalidFormat;
    if (total != size) return error.InvalidFormat;

    // Eager meta-CRC over (header-after-magic ++ block directory). The
    // counter, counts and every per-block CRC are trusted only past this.
    var meta = Crc32.init();
    meta.update(mapping[8..HEADER_SIZE]);
    meta.update(mapping[dir_off..meta_off]);
    if (std.mem.readInt(u32, mapping[meta_off..][0..4], .little) != meta.final()) {
        return error.ChecksumMismatch;
    }

    const nwords = (nblocks + Loaded.WORD_BITS - 1) / Loaded.WORD_BITS;
    const verified = try allocator.alloc(std.atomic.Value(usize), nwords);
    errdefer allocator.free(verified);
    for (verified) |*w| w.* = std.atomic.Value(usize).init(0);

    return .{
        .allocator = allocator,
        .mapping = mapping,
        .checkpoint_counter = counter,
        .record_count = record_count,
        .record_size = record_size,
        .block_size = block_size,
        .payload_len = payload_len,
        .verified = verified,
    };
}

/// In-place sort of fixed-width records inside `payload`. `lessThan` compares
/// two record byte-slices. Used by the snapshot savers so the merged
/// (overlay ⊕ base ⊖ tombstones) record set is written key-sorted without a
/// second staging array.
pub fn sortRecords(
    payload: []u8,
    record_size: usize,
    comptime recordLess: fn (a: []const u8, b: []const u8) bool,
) void {
    std.debug.assert(payload.len % record_size == 0);
    const Ctx = struct {
        buf: []u8,
        rs: usize,

        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return recordLess(ctx.buf[a * ctx.rs ..][0..ctx.rs], ctx.buf[b * ctx.rs ..][0..ctx.rs]);
        }

        pub fn swap(ctx: @This(), a: usize, b: usize) void {
            if (a == b) return; // pdq may request a self-swap; @memcpy must not alias
            const ra = ctx.buf[a * ctx.rs ..][0..ctx.rs];
            const rb = ctx.buf[b * ctx.rs ..][0..ctx.rs];
            var tmp: [64]u8 = undefined;
            std.debug.assert(ctx.rs <= tmp.len);
            @memcpy(tmp[0..ctx.rs], ra);
            @memcpy(ra, rb);
            @memcpy(rb, tmp[0..ctx.rs]);
        }
    };
    std.sort.pdqContext(0, payload.len / record_size, Ctx{ .buf = payload, .rs = record_size });
}

// ============================================================================
// Unit tests
// ============================================================================

const t = std.testing;

const TEST_MAGIC = "GSTSORT1";

fn makePayload(allocator: Allocator, n: usize) ![]u8 {
    // 16-byte records: key u64 (== 2*i), value u64 (== i ^ 0x5A).
    const buf = try allocator.alloc(u8, n * 16);
    for (0..n) |i| {
        std.mem.writeInt(u64, buf[i * 16 ..][0..8], @as(u64, i) * 2, .little);
        std.mem.writeInt(u64, buf[i * 16 + 8 ..][0..8], @as(u64, i) ^ 0x5A, .little);
    }
    return buf;
}

fn openTmpSnapshot(tmp: *std.testing.TmpDir, name: []const u8) !std.Io.File {
    return tmp.dir.createFile(ioT(), name, .{ .read = true, .truncate = false });
}

test "sorted snapshot round-trip: header fields + every record readable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try openTmpSnapshot(&tmp, "snap.bin");
    defer file.close(ioT());

    const payload = try makePayload(t.allocator, 1000);
    defer t.allocator.free(payload);
    try write(t.allocator, file, TEST_MAGIC, 77, 16, payload);

    var loaded = (try load(t.allocator, &file, TEST_MAGIC, 16)).?;
    defer loaded.deinit();
    try t.expectEqual(@as(u64, 77), loaded.checkpoint_counter);
    try t.expectEqual(@as(u64, 1000), loaded.record_count);
    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        const rec = try loaded.recordAt(i);
        try t.expectEqual(i * 2, std.mem.readInt(u64, rec[0..8], .little));
        try t.expectEqual(i ^ 0x5A, std.mem.readInt(u64, rec[8..16], .little));
    }
}

test "empty file loads as null (never-written → rebuild)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try openTmpSnapshot(&tmp, "snap.bin");
    defer file.close(ioT());
    try t.expect((try load(t.allocator, &file, TEST_MAGIC, 16)) == null);
}

test "wrong magic (old snapshot format) is version-rejected, never misparsed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try openTmpSnapshot(&tmp, "snap.bin");
    defer file.close(ioT());

    const payload = try makePayload(t.allocator, 8);
    defer t.allocator.free(payload);
    try write(t.allocator, file, "GSTSORT0", 1, 16, payload);
    try t.expectError(error.InvalidFormat, load(t.allocator, &file, TEST_MAGIC, 16));
}

test "zeroed magic (crash before magic publish) is rejected → rebuild path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try openTmpSnapshot(&tmp, "snap.bin");
    defer file.close(ioT());

    const payload = try makePayload(t.allocator, 8);
    defer t.allocator.free(payload);
    try write(t.allocator, file, TEST_MAGIC, 1, 16, payload);
    // Simulate the crash window: body durable, magic never published.
    const zeros = [_]u8{0} ** 8;
    try file.writePositionalAll(ioT(), &zeros, 0);
    try t.expectError(error.InvalidFormat, load(t.allocator, &file, TEST_MAGIC, 16));
}

test "truncated file is rejected (layout/size mismatch)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try openTmpSnapshot(&tmp, "snap.bin");
    defer file.close(ioT());

    const payload = try makePayload(t.allocator, 64);
    defer t.allocator.free(payload);
    try write(t.allocator, file, TEST_MAGIC, 1, 16, payload);
    const stat = try file.stat(ioT());
    try file.setLength(ioT(), stat.size - 5);
    try t.expectError(error.InvalidFormat, load(t.allocator, &file, TEST_MAGIC, 16));
}

test "record_size mismatch is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try openTmpSnapshot(&tmp, "snap.bin");
    defer file.close(ioT());

    const payload = try makePayload(t.allocator, 8);
    defer t.allocator.free(payload);
    try write(t.allocator, file, TEST_MAGIC, 1, 16, payload);
    try t.expectError(error.InvalidFormat, load(t.allocator, &file, TEST_MAGIC, 40));
}

test "corrupt directory / header byte is caught EAGERLY at load (meta-CRC)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try openTmpSnapshot(&tmp, "snap.bin");
    defer file.close(ioT());

    const payload = try makePayload(t.allocator, 8);
    defer t.allocator.free(payload);
    try write(t.allocator, file, TEST_MAGIC, 123, 16, payload);
    // Flip a bit in the checkpoint counter — the staleness gate's input MUST
    // be integrity-covered or a corrupt counter could skip the rebuild.
    var b: [1]u8 = undefined;
    _ = try file.readPositionalAll(ioT(), &b, 8);
    b[0] ^= 0x01;
    try file.writePositionalAll(ioT(), &b, 8);
    try t.expectError(error.ChecksumMismatch, load(t.allocator, &file, TEST_MAGIC, 16));
}

test "corrupt payload byte: load succeeds, touched block fails LAZILY, others fine" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try openTmpSnapshot(&tmp, "snap.bin");
    defer file.close(ioT());

    // > 1 block of payload (64 KiB / 16 B = 4096 records per block).
    const n: usize = 5000;
    const payload = try makePayload(t.allocator, n);
    defer t.allocator.free(payload);
    try write(t.allocator, file, TEST_MAGIC, 9, 16, payload);

    // Corrupt a byte in block 0's payload.
    var b: [1]u8 = undefined;
    _ = try file.readPositionalAll(ioT(), &b, HEADER_SIZE + 100);
    b[0] ^= 0xFF;
    try file.writePositionalAll(ioT(), &b, HEADER_SIZE + 100);

    var loaded = (try load(t.allocator, &file, TEST_MAGIC, 16)).?;
    defer loaded.deinit();
    // Block 1 records still verify + read fine.
    const rec = try loaded.recordAt(4500);
    try t.expectEqual(@as(u64, 9000), std.mem.readInt(u64, rec[0..8], .little));
    // Block 0 records fail with a checksum error, deterministically.
    try t.expectError(error.ChecksumMismatch, loaded.recordAt(3));
    try t.expectError(error.ChecksumMismatch, loaded.recordAt(3));
}

test "zero records round-trips (empty index keeps its counter)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try openTmpSnapshot(&tmp, "snap.bin");
    defer file.close(ioT());

    try write(t.allocator, file, TEST_MAGIC, 55, 16, &.{});
    var loaded = (try load(t.allocator, &file, TEST_MAGIC, 16)).?;
    defer loaded.deinit();
    try t.expectEqual(@as(u64, 55), loaded.checkpoint_counter);
    try t.expectEqual(@as(u64, 0), loaded.record_count);
}

test "sortRecords sorts fixed-width records in place" {
    var buf: [16 * 4]u8 = undefined;
    const keys = [_]u64{ 30, 10, 40, 20 };
    for (keys, 0..) |k, i| {
        std.mem.writeInt(u64, buf[i * 16 ..][0..8], k, .little);
        std.mem.writeInt(u64, buf[i * 16 + 8 ..][0..8], k + 1, .little);
    }
    const less = struct {
        fn f(a: []const u8, b: []const u8) bool {
            return std.mem.readInt(u64, a[0..8], .little) < std.mem.readInt(u64, b[0..8], .little);
        }
    }.f;
    sortRecords(&buf, 16, less);
    const want = [_]u64{ 10, 20, 30, 40 };
    for (want, 0..) |k, i| {
        try t.expectEqual(k, std.mem.readInt(u64, buf[i * 16 ..][0..8], .little));
        try t.expectEqual(k + 1, std.mem.readInt(u64, buf[i * 16 + 8 ..][0..8], .little));
    }
}
