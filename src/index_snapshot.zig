// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Same CRC used by the manifest (manifest.zig) for on-disk integrity.
// fips-exempt: non-security — CRC32C record-integrity (corruption detection)
// for on-disk format; not authentication.
const Crc32 = std.hash.crc.Crc32Iscsi;

/// WAL-aware derived-index durability (Path B): the header fields preceding the
/// payload are now `checkpoint_epoch(u64) + covered_lsn(u64) + item_count(u64)`.
///
/// `checkpoint_epoch` is the durable freshness token the load gate compares
/// against `manifest.checkpoint_epoch` (advanced ONLY at checkpoint, NOT by a
/// WAL-tail recovery — see checkpoint.zig / manifest.zig). `covered_lsn` is the
/// checkpoint LSN this snapshot reflects; the reader compares it against
/// `wal.currentLsn()` to detect a WAL tail beyond the snapshot.
///
/// The ordered (H3) index shares this container but is NOT part of the WAL-tail
/// epoch contract: it stamps its `manifest.counter` into the `checkpoint_epoch`
/// slot and leaves `covered_lsn == 0`, keeping its existing counter gate. See
/// ordered_property_index.zig.
pub const HEADER_FIELDS_SIZE: usize = 24;

/// Trailing CRC32 appended after the payload (SEC-0051).
pub const CHECKSUM_SIZE: usize = 4;

/// The durable freshness stamp a derived-index snapshot carries: the
/// `checkpoint_epoch` it was saved at and the WAL LSN that checkpoint covered.
pub const Stamp = struct {
    epoch: u64,
    covered_lsn: u64,
};

pub const LoadedSnapshot = struct {
    allocator: Allocator,
    data: []u8,
    checkpoint_epoch: u64,
    covered_lsn: u64,
    item_count: u64,
    payload_offset: usize,
    payload_size: usize,

    pub fn payload(self: *const LoadedSnapshot) []const u8 {
        return self.data[self.payload_offset..][0..self.payload_size];
    }

    pub fn deinit(self: *LoadedSnapshot) void {
        self.allocator.free(self.data);
    }
};

pub const SnapshotHeader = struct {
    checkpoint_epoch: u64,
    covered_lsn: u64,
    item_count: u64,
    payload_size: usize,
};

pub fn writeHeader(file: std.Io.File, offset: *u64, magic: []const u8, checkpoint_epoch: u64, covered_lsn: u64, item_count: u64) !void {
    if (magic.len != 8) return error.InvalidMagicLength;
    const io = std.Io.Threaded.global_single_threaded.io();

    var u64_buf: [8]u8 = undefined;

    try file.writePositionalAll(io, magic, offset.*);
    offset.* += magic.len;

    std.mem.writeInt(u64, &u64_buf, checkpoint_epoch, .little);
    try file.writePositionalAll(io, &u64_buf, offset.*);
    offset.* += 8;

    std.mem.writeInt(u64, &u64_buf, covered_lsn, .little);
    try file.writePositionalAll(io, &u64_buf, offset.*);
    offset.* += 8;

    std.mem.writeInt(u64, &u64_buf, item_count, .little);
    try file.writePositionalAll(io, &u64_buf, offset.*);
    offset.* += 8;
}

/// SEC-0051: After the header + payload have been written, compute a CRC32 over
/// the entire on-disk region [0, payload_end) and append it as a 4-byte trailer.
/// `payload_end` is the byte offset immediately after the last payload byte
/// (i.e. magic.len + 16 + payload_size).
pub fn finalizeChecksum(allocator: Allocator, file: std.Io.File, payload_end: u64) !void {
    const io = std.Io.Threaded.global_single_threaded.io();

    const len: usize = std.math.cast(usize, payload_end) orelse return error.FileTooLarge;
    const buf = try allocator.alloc(u8, len);
    defer allocator.free(buf);

    const bytes_read = try file.readPositionalAll(io, buf, 0);
    if (bytes_read != len) return error.UnexpectedEndOfFile;

    const crc = Crc32.hash(buf);
    var crc_buf: [CHECKSUM_SIZE]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc, .little);
    try file.writePositionalAll(io, &crc_buf, payload_end);
}

pub fn loadFile(allocator: Allocator, file: *std.Io.File, expected_magic: []const u8) !?LoadedSnapshot {
    if (expected_magic.len != 8) return error.InvalidMagicLength;

    const stat = try file.stat(std.Io.Threaded.global_single_threaded.io());
    if (stat.size == 0) return null;

    const size: usize = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
    if (size < expected_magic.len + HEADER_FIELDS_SIZE + CHECKSUM_SIZE) return error.InvalidFormat;

    const io = std.Io.Threaded.global_single_threaded.io();
    const data = try allocator.alloc(u8, size);
    errdefer allocator.free(data);

    const bytes_read = try file.readPositionalAll(io, data, 0);
    if (bytes_read != size) return error.UnexpectedEndOfFile;

    if (!std.mem.eql(u8, data[0..expected_magic.len], expected_magic)) {
        return error.InvalidFormat;
    }

    // SEC-0051: verify trailing CRC32 over everything before the checksum.
    const stored_crc = std.mem.readInt(u32, data[size - CHECKSUM_SIZE ..][0..CHECKSUM_SIZE], .little);
    const computed_crc = Crc32.hash(data[0 .. size - CHECKSUM_SIZE]);
    if (stored_crc != computed_crc) return error.ChecksumMismatch;

    const payload_offset = expected_magic.len + HEADER_FIELDS_SIZE;
    return .{
        .allocator = allocator,
        .data = data,
        .checkpoint_epoch = std.mem.readInt(u64, data[expected_magic.len..][0..8], .little),
        .covered_lsn = std.mem.readInt(u64, data[expected_magic.len + 8 ..][0..8], .little),
        .item_count = std.mem.readInt(u64, data[expected_magic.len + 16 ..][0..8], .little),
        .payload_offset = payload_offset,
        .payload_size = size - payload_offset - CHECKSUM_SIZE,
    };
}

/// Read and validate the snapshot header, verify its CRC32, and bound the
/// declared `item_count` against the available payload.
///
/// SEC-0044/SEC-0048: `min_record_size` is the smallest number of payload bytes
/// a single declared item can consume. The loader rejects any snapshot whose
/// `item_count` exceeds `payload_size / min_record_size`, so a tiny crafted file
/// can never drive a multi-GB capacity reservation before the bytes exist on
/// disk. Pass `min_record_size == 0` only when the per-item minimum is genuinely
/// zero (no fixed-size records), which disables the count bound.
///
/// SEC-0051: the trailing CRC32 is verified here, so a corrupted snapshot
/// returns `error.ChecksumMismatch` (treated by callers as "snapshot invalid →
/// rebuild") rather than loading attacker-controlled data.
pub fn loadHeader(file: *std.Io.File, expected_magic: []const u8, min_record_size: usize) !?SnapshotHeader {
    if (expected_magic.len != 8) return error.InvalidMagicLength;

    const stat = try file.stat(std.Io.Threaded.global_single_threaded.io());
    if (stat.size == 0) return null;

    const size: usize = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
    if (size < expected_magic.len + HEADER_FIELDS_SIZE + CHECKSUM_SIZE) return error.InvalidFormat;

    const io = std.Io.Threaded.global_single_threaded.io();

    // magic(8) + checkpoint_epoch(8) + covered_lsn(8) + item_count(8) = 32.
    var header_buf: [32]u8 = undefined;
    const header_read = try file.readPositionalAll(io, &header_buf, 0);
    if (header_read != header_buf.len) return error.UnexpectedEndOfFile;
    if (!std.mem.eql(u8, header_buf[0..expected_magic.len], expected_magic)) {
        return error.InvalidFormat;
    }

    // SEC-0051: stream the whole file through the CRC and compare the trailer.
    var hasher = Crc32.init();
    var crc_buf: [4096]u8 = undefined;
    var consumed: usize = 0;
    const body_len = size - CHECKSUM_SIZE;
    while (consumed < body_len) {
        const want = @min(crc_buf.len, body_len - consumed);
        const n = try file.readPositionalAll(io, crc_buf[0..want], consumed);
        if (n != want) return error.UnexpectedEndOfFile;
        hasher.update(crc_buf[0..n]);
        consumed += n;
    }
    var trailer_buf: [CHECKSUM_SIZE]u8 = undefined;
    const trailer_read = try file.readPositionalAll(io, &trailer_buf, body_len);
    if (trailer_read != trailer_buf.len) return error.UnexpectedEndOfFile;
    const stored_crc = std.mem.readInt(u32, &trailer_buf, .little);
    if (stored_crc != hasher.final()) return error.ChecksumMismatch;

    const item_count = std.mem.readInt(u64, header_buf[expected_magic.len + 16 ..][0..8], .little);
    const payload_size = size - (expected_magic.len + HEADER_FIELDS_SIZE + CHECKSUM_SIZE);

    // SEC-0044/SEC-0048: reject counts that cannot possibly be backed by bytes.
    if (min_record_size != 0) {
        const max_items = payload_size / min_record_size;
        if (item_count > max_items) return error.InvalidFormat;
    }

    return .{
        .checkpoint_epoch = std.mem.readInt(u64, header_buf[expected_magic.len..][0..8], .little),
        .covered_lsn = std.mem.readInt(u64, header_buf[expected_magic.len + 8 ..][0..8], .little),
        .item_count = item_count,
        .payload_size = payload_size,
    };
}

// ---------------------------------------------------------------------------
// GAP warm-reopen P2 / WAL-aware durability: cheap freshness-stamp re-stamp.
//
// The legacy container's trailing CRC32C covers the WHOLE file (magic |
// checkpoint_epoch | covered_lsn | item_count | payload), so changing the
// stamp naively would require re-reading the entire payload to recompute the
// trailer — exactly the O(file) work a restamp must avoid. Instead we exploit
// that CRC32C is AFFINE over GF(2): for two equal-length messages M and
// M' = M ⊕ D, the init/xorout contributions cancel and
//
//     crc(M') = crc(M) ⊕ rawcrc(D)
//
// where rawcrc is the pure-linear CRC (init 0, xorout 0). Our delta D is
// zero everywhere except the 16 stamp bytes at offset 8 (checkpoint_epoch ++
// covered_lsn), so
//
//     rawcrc(D) = zeroExtend(rawcrc16(old ⊕ new), bytes_after_stamps)
//
// (leading zero bytes leave a zero register unchanged; the trailing zero
// bytes are applied in O(log n) with the zlib crc32_combine GF(2)-matrix
// method). Total restamp cost: two small reads, O(log file) arithmetic,
// two small writes, one fsync.
// ---------------------------------------------------------------------------

/// Reflected CRC-32C (Castagnoli) polynomial — the bit-reversed form of
/// 0x1EDC6F41, i.e. the polynomial `Crc32Iscsi` implements.
const CRC32C_POLY_REFLECTED: u32 = 0x82F63B78;

/// Pure-linear (init 0, xorout 0) reflected CRC32C update.
fn crcRawUpdate(reg: u32, bytes: []const u8) u32 {
    var r = reg;
    for (bytes) |byte| {
        r ^= byte;
        var k: u8 = 0;
        while (k < 8) : (k += 1) {
            r = if (r & 1 != 0) (r >> 1) ^ CRC32C_POLY_REFLECTED else r >> 1;
        }
    }
    return r;
}

fn gf2MatrixTimes(mat: *const [32]u32, vec: u32) u32 {
    var sum: u32 = 0;
    var v = vec;
    var i: usize = 0;
    while (v != 0) : (v >>= 1) {
        if (v & 1 != 0) sum ^= mat[i];
        i += 1;
    }
    return sum;
}

fn gf2MatrixSquare(dst: *[32]u32, src: *const [32]u32) void {
    for (dst, 0..) |*d, i| d.* = gf2MatrixTimes(src, src[i]);
}

/// Advance the raw CRC register over `len` ZERO bytes in O(log len) — the
/// zlib crc32_combine matrix method, with the CRC32C polynomial.
fn crcZeroExtend(crc: u32, len: u64) u32 {
    if (len == 0 or crc == 0) return crc;

    var odd: [32]u32 = undefined; // operator for one zero BIT
    odd[0] = CRC32C_POLY_REFLECTED;
    var row: u32 = 1;
    for (odd[1..]) |*p| {
        p.* = row;
        row <<= 1;
    }
    var even: [32]u32 = undefined;
    gf2MatrixSquare(&even, &odd); // two zero bits
    gf2MatrixSquare(&odd, &even); // four zero bits

    var result = crc;
    var n = len;
    while (true) {
        gf2MatrixSquare(&even, &odd); // first pass: eight bits = one byte
        if (n & 1 != 0) result = gf2MatrixTimes(&even, result);
        n >>= 1;
        if (n == 0) break;
        gf2MatrixSquare(&odd, &even);
        if (n & 1 != 0) result = gf2MatrixTimes(&odd, result);
        n >>= 1;
        if (n == 0) break;
    }
    return result;
}

/// WAL-aware durability: re-stamp the (checkpoint_epoch, covered_lsn) of an
/// existing legacy snapshot (magic | epoch | covered_lsn | item_count |
/// payload | whole-file CRC32C) to `(new_epoch, new_covered_lsn)` WITHOUT
/// reading or rewriting the payload — see the delta derivation above. Used by
/// the full checkpoint for CLEAN (not re-saved) indexes so a partially-dirty
/// session does not epoch-invalidate them: a clean index is unchanged, so it
/// is valid as of the new checkpoint's LSN and gets both stamps advanced.
///
/// CRASH SAFETY (torn restamp): two separately-positioned small writes
/// (16-byte stamp region, 4-byte trailer). A crash landing any strict subset
/// — or a torn fraction of either — leaves the stamps and trailer
/// inconsistent → the loader's whole-file CRC check fails
/// (error.ChecksumMismatch) → callers' existing `catch false` → rebuild. Both
/// landed = valid new stamp; neither = old stamp (epoch-stale → rebuild).
/// Accepted-but-corrupt is impossible.
///
/// CORRUPTION TRANSPARENCY: the old trailer is used WITHOUT verifying it
/// (verification would be the O(file) read this helper exists to avoid). If
/// the file is already corrupt (stored ≠ computed), the delta shifts BOTH
/// sides by the same value, so the mismatch — and the loader's rejection —
/// is preserved, never masked.
///
/// Returns false (file untouched) when there is nothing safe to restamp:
/// empty/never-written, too short, or foreign/old magic. Returns true when
/// the file now carries the new stamps (including the already-stamped no-op).
pub fn restampStamps(file: *std.Io.File, expected_magic: []const u8, new_epoch: u64, new_covered_lsn: u64) !bool {
    if (expected_magic.len != 8) return error.InvalidMagicLength;
    const io = std.Io.Threaded.global_single_threaded.io();

    const stat = try file.stat(io);
    if (stat.size == 0) return false;
    const size: usize = std.math.cast(usize, stat.size) orelse return false;
    if (size < expected_magic.len + HEADER_FIELDS_SIZE + CHECKSUM_SIZE) return false;

    // magic(8) + checkpoint_epoch(8) + covered_lsn(8) = 24.
    var head: [24]u8 = undefined;
    const hn = try file.readPositionalAll(io, &head, 0);
    if (hn != head.len) return false;
    if (!std.mem.eql(u8, head[0..8], expected_magic)) return false;

    const old_epoch = std.mem.readInt(u64, head[8..16], .little);
    const old_covered = std.mem.readInt(u64, head[16..24], .little);
    if (old_epoch == new_epoch and old_covered == new_covered_lsn) return true;

    var trailer: [CHECKSUM_SIZE]u8 = undefined;
    const tn = try file.readPositionalAll(io, &trailer, size - CHECKSUM_SIZE);
    if (tn != trailer.len) return false;
    const old_crc = std.mem.readInt(u32, &trailer, .little);

    // Delta over the 16 stamp bytes at offset 8 (epoch ++ covered_lsn).
    var delta: [16]u8 = undefined;
    std.mem.writeInt(u64, delta[0..8], old_epoch ^ new_epoch, .little);
    std.mem.writeInt(u64, delta[8..16], old_covered ^ new_covered_lsn, .little);

    // Bytes covered by the CRC after the stamp region: item_count + payload.
    const tail_len: u64 = @intCast(size - CHECKSUM_SIZE - (expected_magic.len + 16));
    const new_crc = old_crc ^ crcZeroExtend(crcRawUpdate(0, &delta), tail_len);

    var stamp_buf: [16]u8 = undefined;
    std.mem.writeInt(u64, stamp_buf[0..8], new_epoch, .little);
    std.mem.writeInt(u64, stamp_buf[8..16], new_covered_lsn, .little);
    try file.writePositionalAll(io, &stamp_buf, expected_magic.len);
    var crc_buf: [CHECKSUM_SIZE]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, new_crc, .little);
    try file.writePositionalAll(io, &crc_buf, size - CHECKSUM_SIZE);
    try file.sync(io);
    return true;
}

pub fn readBounded(file: *std.Io.File, offset: *u64, remaining: *usize, buf: []u8) !void {
    if (buf.len > remaining.*) return error.InvalidFormat;
    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes_read = try file.readPositionalAll(io, buf, offset.*);
    if (bytes_read != buf.len) return error.UnexpectedEndOfFile;
    offset.* += buf.len;
    remaining.* -= buf.len;
}

/// PERF-0052: in-memory snapshot serializer.
///
/// Producers append the magic, header, and payload into a single growable
/// buffer; `finalize` computes the CRC32 over everything accumulated, appends
/// the 4-byte trailer (SEC-0051), and flushes the whole snapshot to disk with a
/// single `writePositionalAll`. This collapses the previous per-field positional
/// write loop (~5 syscalls per entry) into one buffered pass while keeping the
/// on-disk layout (magic | epoch | covered_lsn | item_count | payload | crc32)
/// byte-identical.
pub const SnapshotWriter = struct {
    buf: std.ArrayList(u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) SnapshotWriter {
        return .{ .buf = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *SnapshotWriter) void {
        self.buf.deinit(self.allocator);
    }

    /// Append the 8-byte magic and the 24-byte header (checkpoint_epoch,
    /// covered_lsn, item_count). Mirrors `writeHeader`'s on-disk byte order.
    pub fn writeHeader(self: *SnapshotWriter, magic: []const u8, checkpoint_epoch: u64, covered_lsn: u64, item_count: u64) !void {
        if (magic.len != 8) return error.InvalidMagicLength;
        try self.buf.appendSlice(self.allocator, magic);
        var u64_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &u64_buf, checkpoint_epoch, .little);
        try self.buf.appendSlice(self.allocator, &u64_buf);
        std.mem.writeInt(u64, &u64_buf, covered_lsn, .little);
        try self.buf.appendSlice(self.allocator, &u64_buf);
        std.mem.writeInt(u64, &u64_buf, item_count, .little);
        try self.buf.appendSlice(self.allocator, &u64_buf);
    }

    pub fn writeU16(self: *SnapshotWriter, value: u16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, value, .little);
        try self.buf.appendSlice(self.allocator, &b);
    }

    pub fn writeU32(self: *SnapshotWriter, value: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, value, .little);
        try self.buf.appendSlice(self.allocator, &b);
    }

    pub fn writeU64(self: *SnapshotWriter, value: u64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, value, .little);
        try self.buf.appendSlice(self.allocator, &b);
    }

    pub fn writeBytes(self: *SnapshotWriter, bytes: []const u8) !void {
        try self.buf.appendSlice(self.allocator, bytes);
    }

    /// SEC-0051: append the CRC32 trailer over the accumulated bytes and flush
    /// the entire snapshot to `file` with a single positional write.
    pub fn finalize(self: *SnapshotWriter, file: std.Io.File) !void {
        const crc = Crc32.hash(self.buf.items);
        var crc_buf: [CHECKSUM_SIZE]u8 = undefined;
        std.mem.writeInt(u32, &crc_buf, crc, .little);
        try self.buf.appendSlice(self.allocator, &crc_buf);

        const io = std.Io.Threaded.global_single_threaded.io();
        try file.setLength(io, 0);
        try file.writePositionalAll(io, self.buf.items, 0);
    }
};

/// PERF-0052: in-memory snapshot deserializer.
///
/// `loadHeader` already validated the magic, verified the CRC32 (SEC-0051), and
/// bounded `item_count` against the payload (SEC-0044/0048). This reader walks
/// the already-resident payload slice instead of issuing one positional read per
/// field, preserving the same byte-level bounds checks via `remaining`.
pub const SnapshotReader = struct {
    payload: []const u8,
    pos: usize = 0,

    pub fn init(payload: []const u8) SnapshotReader {
        return .{ .payload = payload, .pos = 0 };
    }

    /// Bytes still unread in the payload. Mirrors the `remaining` counter the
    /// per-chain/per-label bound checks consult before reserving capacity.
    pub fn remaining(self: *const SnapshotReader) usize {
        return self.payload.len - self.pos;
    }

    fn take(self: *SnapshotReader, n: usize) ![]const u8 {
        if (n > self.remaining()) return error.InvalidFormat;
        const slice = self.payload[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }

    pub fn readU16(self: *SnapshotReader) !u16 {
        const s = try self.take(2);
        return std.mem.readInt(u16, s[0..2], .little);
    }

    pub fn readU32(self: *SnapshotReader) !u32 {
        const s = try self.take(4);
        return std.mem.readInt(u32, s[0..4], .little);
    }

    pub fn readU64(self: *SnapshotReader) !u64 {
        const s = try self.take(8);
        return std.mem.readInt(u64, s[0..8], .little);
    }

    /// Borrow `n` payload bytes without copying. The slice aliases the loaded
    /// snapshot buffer and is only valid while that buffer lives.
    pub fn readBytes(self: *SnapshotReader, n: usize) ![]const u8 {
        return self.take(n);
    }
};

/// Read, validate, and return the full snapshot as an in-memory buffer.
///
/// PERF-0052: combines the validation `loadHeader` performs (magic check, CRC32
/// verification per SEC-0051, and the `item_count` vs `payload_size` bound per
/// SEC-0044/0048) with a single whole-file read, so callers can deserialize
/// entries from memory instead of issuing per-field positional reads. The
/// returned `LoadedSnapshot` owns `data`; callers must `deinit` it.
pub fn loadPayload(allocator: Allocator, file: *std.Io.File, expected_magic: []const u8, min_record_size: usize) !?LoadedSnapshot {
    const loaded = (try loadFile(allocator, file, expected_magic)) orelse return null;
    errdefer {
        var l = loaded;
        l.deinit();
    }

    // SEC-0044/SEC-0048: reject counts that cannot possibly be backed by bytes,
    // exactly as loadHeader does, before any caller reservation.
    if (min_record_size != 0) {
        const max_items = loaded.payload_size / min_record_size;
        if (loaded.item_count > max_items) return error.InvalidFormat;
    }

    return loaded;
}

test "writeHeader + finalizeChecksum and loadFile round-trip epoch + covered_lsn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(std.Io.Threaded.global_single_threaded.io(), "snapshot.bin", .{ .read = true, .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.io());

    var write_offset: u64 = 0;
    try writeHeader(file, &write_offset, "GSTEST1\x00", 99, 0xABCD_1234, 7);
    try file.writePositionalAll(std.Io.Threaded.global_single_threaded.io(), "payload", write_offset);
    write_offset += "payload".len;
    try finalizeChecksum(std.testing.allocator, file, write_offset);

    var loaded = (try loadFile(std.testing.allocator, &file, "GSTEST1\x00")).?;
    defer loaded.deinit();

    try std.testing.expectEqual(@as(u64, 99), loaded.checkpoint_epoch);
    try std.testing.expectEqual(@as(u64, 0xABCD_1234), loaded.covered_lsn);
    try std.testing.expectEqual(@as(u64, 7), loaded.item_count);
    try std.testing.expectEqualStrings("payload", loaded.payload());

    // loadHeader agrees on the same stamps.
    const hdr = (try loadHeader(&file, "GSTEST1\x00", 0)).?;
    try std.testing.expectEqual(@as(u64, 99), hdr.checkpoint_epoch);
    try std.testing.expectEqual(@as(u64, 0xABCD_1234), hdr.covered_lsn);
    try std.testing.expectEqual(@as(u64, 7), hdr.item_count);
}

test "loadHeader rejects an item_count too large for the payload (SEC-0044/0048)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(std.Io.Threaded.global_single_threaded.io(), "snapshot.bin", .{ .read = true, .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.io());

    // Tiny payload (8 bytes) but a huge declared item_count.
    var write_offset: u64 = 0;
    try writeHeader(file, &write_offset, "GSTEST1\x00", 1, 0, std.math.maxInt(u64));
    try file.writePositionalAll(std.Io.Threaded.global_single_threaded.io(), &[_]u8{0} ** 8, write_offset);
    write_offset += 8;
    try finalizeChecksum(std.testing.allocator, file, write_offset);

    // min_record_size of 8 → at most 1 item fits; maxInt(u64) must be rejected
    // *before* any reservation. std.testing.allocator would also catch a leak,
    // but the bound is checked prior to allocation.
    try std.testing.expectError(error.InvalidFormat, loadHeader(&file, "GSTEST1\x00", 8));
}

test "loadHeader rejects a corrupted payload byte (SEC-0051)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(std.Io.Threaded.global_single_threaded.io(), "snapshot.bin", .{ .read = true, .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.io());

    var write_offset: u64 = 0;
    try writeHeader(file, &write_offset, "GSTEST1\x00", 5, 0, 1);
    try file.writePositionalAll(std.Io.Threaded.global_single_threaded.io(), &[_]u8{0xAB} ** 8, write_offset);
    write_offset += 8;
    try finalizeChecksum(std.testing.allocator, file, write_offset);

    // Flip a single payload byte, keeping the stamp header intact.
    var flip: [1]u8 = .{0x00};
    const payload_byte_offset: u64 = 8 + HEADER_FIELDS_SIZE; // magic + header fields
    try file.writePositionalAll(std.Io.Threaded.global_single_threaded.io(), &flip, payload_byte_offset);

    try std.testing.expectError(error.ChecksumMismatch, loadHeader(&file, "GSTEST1\x00", 8));
}

test "PERF-0052: SnapshotWriter output is byte-identical to writeHeader+finalizeChecksum" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    // Legacy per-field path.
    var legacy = try tmp.dir.createFile(io, "legacy.bin", .{ .read = true, .truncate = true });
    defer legacy.close(io);
    var write_offset: u64 = 0;
    try writeHeader(legacy, &write_offset, "GSTEST1\x00", 0xDEAD, 0xBEEF, 2);
    try legacy.writePositionalAll(io, &[_]u8{ 1, 2, 3, 4, 5 }, write_offset);
    write_offset += 5;
    try finalizeChecksum(std.testing.allocator, legacy, write_offset);

    // Buffered writer path with the same logical content.
    var buffered = try tmp.dir.createFile(io, "buffered.bin", .{ .read = true, .truncate = true });
    defer buffered.close(io);
    var w = SnapshotWriter.init(std.testing.allocator);
    defer w.deinit();
    try w.writeHeader("GSTEST1\x00", 0xDEAD, 0xBEEF, 2);
    try w.writeBytes(&[_]u8{ 1, 2, 3, 4, 5 });
    try w.finalize(buffered);

    const legacy_stat = try legacy.stat(io);
    const buffered_stat = try buffered.stat(io);
    try std.testing.expectEqual(legacy_stat.size, buffered_stat.size);

    const len: usize = @intCast(legacy_stat.size);
    const a = try std.testing.allocator.alloc(u8, len);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alloc(u8, len);
    defer std.testing.allocator.free(b);
    _ = try legacy.readPositionalAll(io, a, 0);
    _ = try buffered.readPositionalAll(io, b, 0);
    try std.testing.expectEqualSlices(u8, a, b);
}

test "PERF-0052: loadPayload round-trips and SnapshotReader honors bounds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var file = try tmp.dir.createFile(io, "snapshot.bin", .{ .read = true, .truncate = true });
    defer file.close(io);

    var w = SnapshotWriter.init(std.testing.allocator);
    defer w.deinit();
    try w.writeHeader("GSTEST1\x00", 42, 0x7777, 1);
    try w.writeU64(0x1122334455667788);
    try w.writeU32(0xAABBCCDD);
    try w.writeU16(0xBEEF);
    try w.finalize(file);

    var loaded = (try loadPayload(std.testing.allocator, &file, "GSTEST1\x00", 0)).?;
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u64, 42), loaded.checkpoint_epoch);
    try std.testing.expectEqual(@as(u64, 0x7777), loaded.covered_lsn);
    try std.testing.expectEqual(@as(u64, 1), loaded.item_count);

    var r = SnapshotReader.init(loaded.payload());
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), try r.readU64());
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), try r.readU32());
    try std.testing.expectEqual(@as(u16, 0xBEEF), try r.readU16());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
    // Past-the-end read is rejected as malformed, not a positional EOF.
    try std.testing.expectError(error.InvalidFormat, r.readU16());
}

test "PERF-0052: loadPayload enforces the count bound (SEC-0044/0048)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var file = try tmp.dir.createFile(io, "snapshot.bin", .{ .read = true, .truncate = true });
    defer file.close(io);

    var w = SnapshotWriter.init(std.testing.allocator);
    defer w.deinit();
    try w.writeHeader("GSTEST1\x00", 1, 0, std.math.maxInt(u64));
    try w.writeBytes(&[_]u8{0} ** 8);
    try w.finalize(file);

    // min_record_size of 8 → at most 1 item fits; maxInt(u64) must be rejected.
    try std.testing.expectError(error.InvalidFormat, loadPayload(std.testing.allocator, &file, "GSTEST1\x00", 8));
}

test "restampStamps: delta-updated trailer CRC matches a full recompute across payload sizes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var prng = std.Random.DefaultPrng.init(0xD3714);
    const rnd = prng.random();

    const sizes = [_]usize{ 0, 1, 7, 8, 63, 64, 65, 1000, 4096, 70_000 };
    for (sizes, 0..) |payload_len, case| {
        var namebuf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&namebuf, "snap{d}.bin", .{case});
        var file = try tmp.dir.createFile(io, name, .{ .read = true, .truncate = true });
        defer file.close(io);

        const payload = try std.testing.allocator.alloc(u8, payload_len);
        defer std.testing.allocator.free(payload);
        rnd.bytes(payload);

        var w = SnapshotWriter.init(std.testing.allocator);
        defer w.deinit();
        try w.writeHeader("GSTEST1\x00", rnd.int(u64), rnd.int(u64), 3);
        try w.writeBytes(payload);
        try w.finalize(file);

        const new_epoch = rnd.int(u64);
        const new_lsn = rnd.int(u64);
        try std.testing.expect(try restampStamps(&file, "GSTEST1\x00", new_epoch, new_lsn));

        // Loader accepts (whole-file CRC valid) and sees BOTH new stamps.
        var loaded = (try loadFile(std.testing.allocator, &file, "GSTEST1\x00")).?;
        defer loaded.deinit();
        try std.testing.expectEqual(new_epoch, loaded.checkpoint_epoch);
        try std.testing.expectEqual(new_lsn, loaded.covered_lsn);

        // Ground truth: the stored trailer equals a from-scratch CRC of the
        // modified body — proves the GF(2) delta path bit-exactly.
        const stat = try file.stat(io);
        const size: usize = @intCast(stat.size);
        const buf = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(buf);
        _ = try file.readPositionalAll(io, buf, 0);
        const stored = std.mem.readInt(u32, buf[size - CHECKSUM_SIZE ..][0..CHECKSUM_SIZE], .little);
        try std.testing.expectEqual(Crc32.hash(buf[0 .. size - CHECKSUM_SIZE]), stored);
    }
}

test "restampStamps: torn restamp (stamps landed, trailer did not) is rejected at load → rebuild path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var file = try tmp.dir.createFile(io, "snapshot.bin", .{ .read = true, .truncate = true });
    defer file.close(io);
    var w = SnapshotWriter.init(std.testing.allocator);
    defer w.deinit();
    try w.writeHeader("GSTEST1\x00", 10, 100, 1);
    try w.writeBytes(&[_]u8{0xEE} ** 32);
    try w.finalize(file);

    // Crash window: only the 16-byte stamp write hit the disk.
    var stamp_buf: [16]u8 = undefined;
    std.mem.writeInt(u64, stamp_buf[0..8], 11, .little);
    std.mem.writeInt(u64, stamp_buf[8..16], 200, .little);
    try file.writePositionalAll(io, &stamp_buf, 8);

    try std.testing.expectError(error.ChecksumMismatch, loadFile(std.testing.allocator, &file, "GSTEST1\x00"));
    try std.testing.expectError(error.ChecksumMismatch, loadHeader(&file, "GSTEST1\x00", 8));
}

test "restampStamps: skips empty files and foreign magic; preserves an existing corruption mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var empty = try tmp.dir.createFile(io, "empty.bin", .{ .read = true, .truncate = true });
    defer empty.close(io);
    try std.testing.expect(!(try restampStamps(&empty, "GSTEST1\x00", 5, 50)));

    var foreign = try tmp.dir.createFile(io, "foreign.bin", .{ .read = true, .truncate = true });
    defer foreign.close(io);
    var w = SnapshotWriter.init(std.testing.allocator);
    defer w.deinit();
    try w.writeHeader("GSOTHER\x00", 1, 10, 1);
    try w.writeBytes(&[_]u8{1} ** 8);
    try w.finalize(foreign);
    try std.testing.expect(!(try restampStamps(&foreign, "GSTEST1\x00", 5, 50)));

    // Pre-corrupted file: restamp must not mask the corruption.
    var corrupt = try tmp.dir.createFile(io, "corrupt.bin", .{ .read = true, .truncate = true });
    defer corrupt.close(io);
    var w2 = SnapshotWriter.init(std.testing.allocator);
    defer w2.deinit();
    try w2.writeHeader("GSTEST1\x00", 1, 10, 1);
    try w2.writeBytes(&[_]u8{2} ** 16);
    try w2.finalize(corrupt);
    var flip: [1]u8 = .{0xFF};
    try corrupt.writePositionalAll(io, &flip, 8 + HEADER_FIELDS_SIZE + 3); // payload byte
    try std.testing.expect(try restampStamps(&corrupt, "GSTEST1\x00", 5, 50));
    try std.testing.expectError(error.ChecksumMismatch, loadFile(std.testing.allocator, &corrupt, "GSTEST1\x00"));
}

test "PERF-0052: loadPayload rejects a corrupted payload byte (SEC-0051)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    var file = try tmp.dir.createFile(io, "snapshot.bin", .{ .read = true, .truncate = true });
    defer file.close(io);

    var w = SnapshotWriter.init(std.testing.allocator);
    defer w.deinit();
    try w.writeHeader("GSTEST1\x00", 5, 0, 1);
    try w.writeBytes(&[_]u8{0xAB} ** 8);
    try w.finalize(file);

    var flip: [1]u8 = .{0x00};
    const payload_byte_offset: u64 = 8 + HEADER_FIELDS_SIZE;
    try file.writePositionalAll(io, &flip, payload_byte_offset);

    try std.testing.expectError(error.ChecksumMismatch, loadPayload(std.testing.allocator, &file, "GSTEST1\x00", 8));
}
