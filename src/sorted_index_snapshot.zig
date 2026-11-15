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
//!   8   checkpoint_epoch    u64   (WAL-aware staleness gate; see manifest.zig)
//!   16  covered_lsn         u64   (WAL LSN this snapshot reflects)
//!   24  record_count        u64
//!   32  record_size         u32   (must equal the caller's expected size)
//!   36  block_size          u32
//!   40  payload             record_count * record_size bytes, SORTED
//!   ..  block_crcs          u32[ceil(payload_len / block_size)]
//!   ..  meta_crc            u32 over bytes [8..40) ++ block_crcs region
//!
//! CRASH-SAFETY / FAILURE MODEL (precise):
//!
//!   1. Torn checkpoint write. Production savers go through
//!      `writeAtomicReplace` (P1 review C1): the whole container is written
//!      to a `.tmp` sibling, fsynced, and RENAMED over the target, then the
//!      directory is fsynced. The rename is the commit point — a crash at any
//!      stage leaves either the complete OLD snapshot or the complete NEW
//!      one, never a torn file, and the old inode (possibly still mmap'd by a
//!      live adopted base — see MAPPED-INODE RULE below) is never written.
//!      The raw `write` helper additionally publishes the magic LAST (body →
//!      fsync → magic → fsync), so even a non-replace caller that crashes
//!      mid-write leaves a zero/partial magic or a short file → `load`
//!      rejects (error.InvalidFormat) → the caller's existing counter-gated
//!      REBUILD path runs.
//!   2. Old snapshot after crash-before-checkpoint-manifest. Both file and
//!      manifest are the OLD consistent state → counter gate accepts the old
//!      snapshot, which is correct (nothing newer was durable).
//!   3. Stale snapshot (light checkpoints, crash after manifest write). The
//!      caller compares `checkpoint_epoch` against manifest.checkpoint_epoch
//!      exactly as before → mismatch → rebuild. The epoch is covered by the
//!      eagerly verified meta-CRC, so a corrupt epoch cannot skip the gate.
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
//!
//! MAPPED-INODE RULE (P1 review C1, same hazard class as unmap-under-reader):
//! while a base mapping is live, the mapped inode must NEVER be truncated or
//! have payload/directory bytes rewritten in place — `ftruncate`/relocation
//! invalidates pages under every mapping of the file (SIGBUS past the new
//! EOF; re-faulted new bytes served past the stale verified bitset with no
//! CRC re-check = silent garbage). Snapshot REPLACEMENT therefore goes
//! through `writeAtomicReplace` (new inode + rename; the mapping keeps the
//! old inode alive and semantically valid). The ONLY in-place writes ever
//! performed on a possibly-mapped snapshot inode are `restampStamps` (bytes
//! [8,24) + the 4-byte meta-CRC trailer) and `Loaded.invalidateOnce` (bytes
//! [0,8), the magic): both are size-preserving and touch exclusively bytes
//! that `load` consumed once and no reader ever re-reads through the mapping
//! (recordAt reads payload bytes, dirEntry reads directory bytes).

const std = @import("std");
const scoped_file = @import("scoped_file.zig");
const side_file_crypto = @import("side_file_crypto.zig");

const Allocator = std.mem.Allocator;

/// Same CRC family as the legacy container + manifest.
// fips-exempt: non-security — CRC32C corruption detection for on-disk format.
const Crc32 = std.hash.crc.Crc32Iscsi;

/// magic(8) + checkpoint_epoch(8) + covered_lsn(8) + record_count(8) +
/// record_size(4) + block_size(4).
pub const HEADER_SIZE: usize = 40;
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
    checkpoint_epoch: u64,
    covered_lsn: u64,
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
    std.mem.writeInt(u64, hdr[8..16], checkpoint_epoch, .little);
    std.mem.writeInt(u64, hdr[16..24], covered_lsn, .little);
    std.mem.writeInt(u64, hdr[24..32], record_count, .little);
    std.mem.writeInt(u32, hdr[32..36], record_size, .little);
    std.mem.writeInt(u32, hdr[36..40], DEFAULT_BLOCK_SIZE, .little);

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

/// P1 review C1: atomically REPLACE the snapshot at `<dir_path>/<file_name>`
/// via tmp file + fsync + rename + directory fsync.
///
/// This is the ONLY correct save path once a base mapping may be live on the
/// current file: the old inode is never written or truncated (see the
/// MAPPED-INODE RULE in the file header), so an adopted base keeps serving
/// the old — still semantically valid, because the live view is
/// base ⊕ overlay ⊖ tombstones and neither changed — bytes with its verified
/// bitset intact. The rename is the durability commit point: a crash at any
/// stage leaves the complete OLD snapshot in place (this also removes the
/// legacy both-gone window of truncate-then-rewrite, review M5).
///
/// NOTE for callers that keep a long-lived fd on the target path (the
/// engine's FileManager): after this returns, that fd refers to the REPLACED
/// (old) inode and must be reopened (FileManager.reopenFile) before any
/// further fd-based access.
pub fn writeAtomicReplace(
    allocator: Allocator,
    dir_path: []const u8,
    file_name: []const u8,
    magic: []const u8,
    checkpoint_epoch: u64,
    covered_lsn: u64,
    record_size: u32,
    payload: []const u8,
) !void {
    const io = ioT();
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, file_name });
    defer allocator.free(path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    {
        // exclusive is omitted: a stale .tmp from a previous killed save may
        // exist and must simply be overwritten.
        const tmp_file = try scoped_file.create(io, tmp_path, .{
            .permissions = std.Io.File.Permissions.fromMode(0o600),
            .resolve_beneath = true,
        });
        defer tmp_file.close(io);
        // `write` fsyncs the body and the magic before returning, so the tmp
        // file is fully durable before the rename below publishes it.
        try write(allocator, tmp_file, magic, checkpoint_epoch, covered_lsn, record_size, payload);
    }

    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);

    // fsync the containing directory so the rename itself survives power
    // loss. `.iterate = true` forces a real O_RDONLY|O_DIRECTORY fd — the
    // default openDir uses O_PATH, on which fsync fails with EBADF (same
    // pattern as engine_persist.saveFreeStore).
    var gdir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer gdir.close(io);
    const gdir_file = std.Io.File{ .handle = gdir.handle, .flags = .{ .nonblocking = false } };
    try gdir_file.sync(io);
}

/// WAL-aware durability: re-stamp `(checkpoint_epoch, covered_lsn)` of an
/// existing sorted snapshot IN PLACE — 16 stamp bytes + the 4-byte meta-CRC
/// trailer; the payload and the per-block CRC directory are untouched.
/// O(directory), i.e. 4 bytes read per 64 KiB of payload, plus two small writes.
///
/// Used by the full checkpoint to keep a CLEAN (not re-serialized) index's
/// snapshot epoch-current when only OTHER indexes were dirty, so the next
/// open still takes the O(mmap) load path instead of an O(graph) rebuild. A
/// clean index is unchanged, so it is valid as of the new checkpoint's LSN —
/// both stamps advance to (manifest.checkpoint_epoch, checkpoint_lsn).
///
/// MAPPED-INODE SAFETY: this may write the very inode a live adopted base
/// has mmap'd. That is safe by construction (see the MAPPED-INODE RULE in
/// the file header): the write is size-preserving and changes only bytes
/// [8,24) and the meta-CRC trailer — both consumed exactly once by `load`
/// and never re-read through the mapping.
///
/// CRASH SAFETY (torn restamp): the stamp region and meta-CRC are two separate
/// small writes. A crash that lands any strict subset (or a torn fraction of
/// either) leaves stamps/meta inconsistent → `load`'s EAGER meta-CRC check
/// fails (error.ChecksumMismatch) → the caller's rebuild path runs. Both
/// landed = valid new stamp; neither = old stamp (epoch-stale → rebuild).
/// An accepted-but-corrupt outcome is impossible.
///
/// The existing meta-CRC is VERIFIED before writing (the directory has to be
/// read anyway): an already-corrupt header/directory is left untouched
/// (returns false) so the loader keeps rejecting it. Returns false — file
/// untouched — when there is nothing safe to restamp: empty/short file,
/// foreign or old-format magic, wrong record_size, or a layout mismatch.
/// Returns true when the file now carries the new stamps (including the
/// already-stamped no-op case).
pub fn restampStamps(
    allocator: Allocator,
    file: *std.Io.File,
    expected_magic: []const u8,
    expected_record_size: u32,
    new_epoch: u64,
    new_covered_lsn: u64,
) !bool {
    if (expected_magic.len != 8) return error.InvalidMagicLength;
    const io = ioT();

    const stat = try file.stat(io);
    if (stat.size == 0) return false;
    const size: usize = std.math.cast(usize, stat.size) orelse return false;
    if (size < HEADER_SIZE + META_CRC_SIZE) return false;

    var hdr: [HEADER_SIZE]u8 = undefined;
    const hn = try file.readPositionalAll(io, &hdr, 0);
    if (hn != hdr.len) return false;
    if (!std.mem.eql(u8, hdr[0..8], expected_magic)) return false;

    const old_epoch = std.mem.readInt(u64, hdr[8..16], .little);
    const old_covered = std.mem.readInt(u64, hdr[16..24], .little);
    const record_count = std.mem.readInt(u64, hdr[24..32], .little);
    const record_size = std.mem.readInt(u32, hdr[32..36], .little);
    const block_size = std.mem.readInt(u32, hdr[36..40], .little);

    if (record_size != expected_record_size) return false;
    if (block_size < MIN_BLOCK_SIZE or block_size > MAX_BLOCK_SIZE) return false;

    // Same overflow-checked layout equation as `load`; any mismatch means a
    // truncated/corrupt file → leave it for the loader to reject.
    const m = std.math;
    const payload_len = m.mul(usize, m.cast(usize, record_count) orelse return false, record_size) catch return false;
    const nblocks = if (payload_len == 0) 0 else (payload_len - 1) / block_size + 1;
    const dir_off = m.add(usize, HEADER_SIZE, payload_len) catch return false;
    const dir_len = m.mul(usize, nblocks, BLOCK_CRC_SIZE) catch return false;
    const meta_off = m.add(usize, dir_off, dir_len) catch return false;
    const total = m.add(usize, meta_off, META_CRC_SIZE) catch return false;
    if (total != size) return false;

    if (old_epoch == new_epoch and old_covered == new_covered_lsn) return true;

    // Read directory + stored meta-CRC, verify the OLD stamp is intact.
    const dir_and_meta = try allocator.alloc(u8, dir_len + META_CRC_SIZE);
    defer allocator.free(dir_and_meta);
    const dn = try file.readPositionalAll(io, dir_and_meta, dir_off);
    if (dn != dir_and_meta.len) return false;

    var old_meta = Crc32.init();
    old_meta.update(hdr[8..HEADER_SIZE]);
    old_meta.update(dir_and_meta[0..dir_len]);
    if (std.mem.readInt(u32, dir_and_meta[dir_len..][0..4], .little) != old_meta.final()) {
        return false; // already corrupt — never bless it with fresh stamps
    }

    std.mem.writeInt(u64, hdr[8..16], new_epoch, .little);
    std.mem.writeInt(u64, hdr[16..24], new_covered_lsn, .little);
    var new_meta = Crc32.init();
    new_meta.update(hdr[8..HEADER_SIZE]);
    new_meta.update(dir_and_meta[0..dir_len]);
    var meta_buf: [META_CRC_SIZE]u8 = undefined;
    std.mem.writeInt(u32, &meta_buf, new_meta.final(), .little);

    try file.writePositionalAll(io, hdr[8..24], 8);
    try file.writePositionalAll(io, &meta_buf, meta_off);
    try file.sync(io);
    return true;
}

/// An mmap'd, lazily-verified snapshot base. Owns the mapping and the
/// verified-block bitset. NOT internally synchronized beyond the bitset:
/// callers keep the same external-serialization contract the resident
/// hashmaps had (the bitset itself uses atomics so concurrent READERS are
/// safe — verification is idempotent and monotone).
pub const Loaded = struct {
    allocator: Allocator,
    mapping: []align(std.heap.page_size_min) u8,
    checkpoint_epoch: u64,
    covered_lsn: u64,
    record_count: u64,
    record_size: u32,
    block_size: u32,
    payload_len: usize,
    /// One bit per payload block, set once the block's CRC has verified.
    verified: []std.atomic.Value(usize),
    /// I1 (P1 review): set once a LAZY block verification failed. Guards the
    /// one-shot on-disk invalidation below.
    poisoned: std.atomic.Value(bool),
    /// I1 (P1 review): optional owned path of the snapshot file backing this
    /// mapping (set via `enableInvalidateOnCorruption`). When set, the FIRST
    /// lazy ChecksumMismatch zeroes the file's 8 magic bytes (best-effort) so
    /// the NEXT open's `load` rejects the snapshot (error.InvalidFormat) and
    /// the caller rebuilds — restoring the legacy container's bit-rot
    /// self-heal for the lazy-verification failure mode. Without this, a
    /// read-only deployment would re-adopt the same corrupt file on every
    /// open and error on the same key range forever.
    invalidate_path: ?[]u8,
    /// SONNY-6616: the "mapping" is a heap buffer holding the decrypted image
    /// of a sealed snapshot (`loadSealed`), not an mmap of the file. Freed
    /// (after zeroing) instead of unmapped; never madvise'd.
    heap: bool = false,

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
            self.invalidateOnce();
            return error.ChecksumMismatch;
        }
        _ = self.verified[word].fetchOr(bit, .acq_rel);
    }

    /// I1 (P1 review): register `path` as the on-disk snapshot backing this
    /// mapping, arming the one-shot corruption invalidation (see
    /// `invalidate_path`). Duplicates the path; freed by `deinit`.
    pub fn enableInvalidateOnCorruption(self: *Loaded, path: []const u8) !void {
        std.debug.assert(self.invalidate_path == null);
        self.invalidate_path = try self.allocator.dupe(u8, path);
    }

    /// I1: one-shot best-effort on-disk invalidation after a lazy payload CRC
    /// failure. Zeroes the 8 magic bytes so the NEXT open rebuilds; this
    /// session keeps surfacing the per-query error. Size-preserving write of
    /// bytes [0,8) only — mapped-inode-safe (see the MAPPED-INODE RULE in the
    /// file header: the magic is never re-read through the mapping). A torn
    /// zero-write still differs from the expected magic → still rejected.
    /// Best-effort: a truly read-only deployment (no write permission) keeps
    /// the wedge, but the error is surfaced either way.
    fn invalidateOnce(self: *Loaded) void {
        if (self.poisoned.swap(true, .acq_rel)) return;
        const path = self.invalidate_path orelse return;
        const io = ioT();
        const f = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only }) catch return;
        defer f.close(io);
        const zeros = [_]u8{0} ** 8;
        f.writePositionalAll(io, &zeros, 0) catch return;
        f.sync(io) catch {};
    }

    /// M4 (P1 review): hint the kernel before/after the strictly sequential
    /// full-payload scans (checkpoint-save iteration) — the load-time
    /// MADV_RANDOM would otherwise disable readahead for hundreds of MB.
    pub fn adviseSequential(self: *const Loaded) void {
        if (self.heap) return;
        std.posix.madvise(self.mapping.ptr, self.mapping.len, std.posix.MADV.SEQUENTIAL) catch {};
    }

    /// Restore the point-lookup access hint (pairs with adviseSequential).
    pub fn adviseRandom(self: *const Loaded) void {
        if (self.heap) return;
        std.posix.madvise(self.mapping.ptr, self.mapping.len, std.posix.MADV.RANDOM) catch {};
    }

    /// Borrow record `i` (bytes alias the mapping — valid until deinit).
    /// Verifies the covering block(s) on first touch; a CRC mismatch is
    /// surfaced as error.ChecksumMismatch (failure model #4 above).
    pub fn recordAt(self: *Loaded, i: u64) ![]const u8 {
        // M6 (P1 review): hard bound, not a Debug-only assert — ReleaseFast
        // must not turn an out-of-range index into an OOB mapping read.
        if (i >= self.record_count) return error.InvalidRecordIndex;
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
        if (self.heap) {
            std.crypto.secureZero(u8, self.mapping);
            self.allocator.free(self.mapping);
        } else std.posix.munmap(self.mapping);
        self.allocator.free(self.verified);
        if (self.invalidate_path) |p| self.allocator.free(p);
        self.invalidate_path = null;
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
    return try adopt(allocator, mapping, expected_magic, expected_record_size, false);
}

/// Validate a complete snapshot image (header, layout, eager meta-CRC) and
/// wrap it. On success the returned `Loaded` owns `mapping`; on error the
/// caller still does.
fn adopt(
    allocator: Allocator,
    mapping: []align(std.heap.page_size_min) u8,
    expected_magic: []const u8,
    expected_record_size: u32,
    heap: bool,
) !Loaded {
    const size = mapping.len;
    if (size < HEADER_SIZE + META_CRC_SIZE) return error.InvalidFormat;
    if (!std.mem.eql(u8, mapping[0..8], expected_magic)) return error.InvalidFormat;

    const checkpoint_epoch = std.mem.readInt(u64, mapping[8..16], .little);
    const covered_lsn = std.mem.readInt(u64, mapping[16..24], .little);
    const record_count = std.mem.readInt(u64, mapping[24..32], .little);
    const record_size = std.mem.readInt(u32, mapping[32..36], .little);
    const block_size = std.mem.readInt(u32, mapping[36..40], .little);

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
        .checkpoint_epoch = checkpoint_epoch,
        .covered_lsn = covered_lsn,
        .record_count = record_count,
        .record_size = record_size,
        .block_size = block_size,
        .payload_len = payload_len,
        .verified = verified,
        .poisoned = std.atomic.Value(bool).init(false),
        .invalidate_path = null,
        .heap = heap,
    };
}

// ---------------------------------------------------------------------------
// SONNY-6616: sealed snapshots (at-rest encryption)
// ---------------------------------------------------------------------------
//
// Under a key the snapshot image (the same layout as above) is sealed whole
// with the side-file envelope (side_file_crypto: AES-256-GCM, bound to the
// shard's uuid, the file name and `kind`). A sealed file cannot be mmap'd and
// read in place: it is read, authenticated and decrypted into a page-aligned
// heap buffer, which the `Loaded` owns (`heap = true`). The trade-off is
// O(file) at load and the snapshot resident in memory, instead of O(header)
// and paged on demand; without a key nothing changes. The heap base is not a
// mapping of the file, so the mapped-inode rule does not constrain the
// sealed restamp, which rewrites the file atomically.

/// The complete image `write` produces, magic included, in one buffer
/// (caller frees; it holds the plaintext records).
fn buildImage(
    allocator: Allocator,
    magic: []const u8,
    checkpoint_epoch: u64,
    covered_lsn: u64,
    record_size: u32,
    payload: []const u8,
) ![]u8 {
    if (magic.len != 8) return error.InvalidMagicLength;
    std.debug.assert(record_size > 0);
    std.debug.assert(payload.len % record_size == 0);
    const record_count: u64 = payload.len / record_size;
    const nblocks: usize = (payload.len + DEFAULT_BLOCK_SIZE - 1) / DEFAULT_BLOCK_SIZE;
    const dir_len = nblocks * BLOCK_CRC_SIZE;
    const total = HEADER_SIZE + payload.len + dir_len + META_CRC_SIZE;
    const img = try allocator.alloc(u8, total);
    errdefer allocator.free(img);

    @memcpy(img[0..8], magic);
    std.mem.writeInt(u64, img[8..16], checkpoint_epoch, .little);
    std.mem.writeInt(u64, img[16..24], covered_lsn, .little);
    std.mem.writeInt(u64, img[24..32], record_count, .little);
    std.mem.writeInt(u32, img[32..36], record_size, .little);
    std.mem.writeInt(u32, img[36..40], DEFAULT_BLOCK_SIZE, .little);
    @memcpy(img[HEADER_SIZE..][0..payload.len], payload);
    const dir = img[HEADER_SIZE + payload.len ..][0..dir_len];
    var b: usize = 0;
    while (b < nblocks) : (b += 1) {
        const start = b * DEFAULT_BLOCK_SIZE;
        const end = @min(start + DEFAULT_BLOCK_SIZE, payload.len);
        std.mem.writeInt(u32, dir[b * BLOCK_CRC_SIZE ..][0..4], Crc32.hash(payload[start..end]), .little);
    }
    var meta = Crc32.init();
    meta.update(img[8..HEADER_SIZE]);
    meta.update(dir);
    std.mem.writeInt(u32, img[total - META_CRC_SIZE ..][0..4], meta.final(), .little);
    return img;
}

/// Seal `image` and replace `<dir_path>/<file_name>` atomically (tmp file,
/// fsync, rename, directory fsync).
fn writeSealedImage(
    allocator: Allocator,
    dir_path: []const u8,
    file_name: []const u8,
    image: []const u8,
    cipher: *const side_file_crypto.Cipher,
    kind: side_file_crypto.Kind,
) !void {
    const sealed = try cipher.seal(allocator, kind, file_name, image);
    defer allocator.free(sealed);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, file_name });
    defer allocator.free(path);
    try side_file_crypto.writeAtomic(allocator, path, sealed);
    var gdir = try std.Io.Dir.cwd().openDir(ioT(), dir_path, .{ .iterate = true });
    defer gdir.close(ioT());
    const gdir_file = std.Io.File{ .handle = gdir.handle, .flags = .{ .nonblocking = false } };
    try gdir_file.sync(ioT());
}

/// SONNY-6616: `writeAtomicReplace`, sealed under `cipher` as `kind`.
pub fn writeAtomicReplaceSealed(
    allocator: Allocator,
    dir_path: []const u8,
    file_name: []const u8,
    magic: []const u8,
    checkpoint_epoch: u64,
    covered_lsn: u64,
    record_size: u32,
    payload: []const u8,
    cipher: *const side_file_crypto.Cipher,
    kind: side_file_crypto.Kind,
) !void {
    const image = try buildImage(allocator, magic, checkpoint_epoch, covered_lsn, record_size, payload);
    defer {
        std.crypto.secureZero(u8, image);
        allocator.free(image);
    }
    try writeSealedImage(allocator, dir_path, file_name, image, cipher, kind);
}

/// SONNY-6616: `load` for a sealed snapshot. Returns null for an empty file
/// (never written: rebuild). `error.SideFileNotSealed` for a file in the
/// plaintext layout (written without the key, e.g. by 0.4.17, which did not
/// seal topology snapshots), `error.SideFileAuthFailed` for one sealed under
/// another key, modified, or copied from another shard or file; the caller
/// rebuilds on any error, as for a torn or corrupt plaintext snapshot.
pub fn loadSealed(
    allocator: Allocator,
    file: *std.Io.File,
    expected_magic: []const u8,
    expected_record_size: u32,
    cipher: *const side_file_crypto.Cipher,
    kind: side_file_crypto.Kind,
    file_name: []const u8,
) !?Loaded {
    if (expected_magic.len != 8) return error.InvalidMagicLength;
    const raw = try side_file_crypto.readWholeOpenFile(allocator, file.*);
    defer allocator.free(raw);
    if (raw.len == 0) return null;
    if (!side_file_crypto.isSealed(raw)) return error.SideFileNotSealed;
    const plain = try cipher.open(allocator, kind, file_name, raw);
    defer {
        std.crypto.secureZero(u8, plain);
        allocator.free(plain);
    }
    const image = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(std.heap.page_size_min), plain.len);
    errdefer {
        std.crypto.secureZero(u8, image);
        allocator.free(image);
    }
    @memcpy(image, plain);
    return try adopt(allocator, image, expected_magic, expected_record_size, true);
}

/// SONNY-6616: `restampStamps` for a sealed snapshot: authenticate, check
/// the old stamp's meta-CRC, write the new stamps, reseal and replace the
/// file atomically (a sealed file cannot be patched in place). Same return
/// contract: false (file untouched) when there is nothing safe to restamp —
/// absent, empty, plaintext, unauthenticated, foreign or corrupt.
pub fn restampSealed(
    allocator: Allocator,
    dir_path: []const u8,
    file_name: []const u8,
    expected_magic: []const u8,
    expected_record_size: u32,
    new_epoch: u64,
    new_covered_lsn: u64,
    cipher: *const side_file_crypto.Cipher,
    kind: side_file_crypto.Kind,
) !bool {
    if (expected_magic.len != 8) return error.InvalidMagicLength;
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, file_name });
    defer allocator.free(path);
    const raw = side_file_crypto.readWholeFile(allocator, path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(raw);
    if (raw.len == 0 or !side_file_crypto.isSealed(raw)) return false;
    const img = cipher.open(allocator, kind, file_name, raw) catch return false;
    defer {
        std.crypto.secureZero(u8, img);
        allocator.free(img);
    }
    if (img.len < HEADER_SIZE + META_CRC_SIZE) return false;
    if (!std.mem.eql(u8, img[0..8], expected_magic)) return false;
    const record_count = std.mem.readInt(u64, img[24..32], .little);
    const record_size = std.mem.readInt(u32, img[32..36], .little);
    const block_size = std.mem.readInt(u32, img[36..40], .little);
    if (record_size != expected_record_size) return false;
    if (block_size < MIN_BLOCK_SIZE or block_size > MAX_BLOCK_SIZE) return false;
    const m = std.math;
    const payload_len = m.mul(usize, m.cast(usize, record_count) orelse return false, record_size) catch return false;
    const nblocks = if (payload_len == 0) 0 else (payload_len - 1) / block_size + 1;
    const dir_off = m.add(usize, HEADER_SIZE, payload_len) catch return false;
    const dir_len = m.mul(usize, nblocks, BLOCK_CRC_SIZE) catch return false;
    const meta_off = m.add(usize, dir_off, dir_len) catch return false;
    const total = m.add(usize, meta_off, META_CRC_SIZE) catch return false;
    if (total != img.len) return false;

    if (std.mem.readInt(u64, img[8..16], .little) == new_epoch and
        std.mem.readInt(u64, img[16..24], .little) == new_covered_lsn) return true;

    var old_meta = Crc32.init();
    old_meta.update(img[8..HEADER_SIZE]);
    old_meta.update(img[dir_off..meta_off]);
    if (std.mem.readInt(u32, img[meta_off..][0..4], .little) != old_meta.final()) return false;

    std.mem.writeInt(u64, img[8..16], new_epoch, .little);
    std.mem.writeInt(u64, img[16..24], new_covered_lsn, .little);
    var new_meta = Crc32.init();
    new_meta.update(img[8..HEADER_SIZE]);
    new_meta.update(img[dir_off..meta_off]);
    std.mem.writeInt(u32, img[meta_off..][0..4], new_meta.final(), .little);
    try writeSealedImage(allocator, dir_path, file_name, img, cipher, kind);
    return true;
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
    try write(t.allocator, file, TEST_MAGIC, 77, 0xC0DE, 16, payload);

    var loaded = (try load(t.allocator, &file, TEST_MAGIC, 16)).?;
    defer loaded.deinit();
    try t.expectEqual(@as(u64, 77), loaded.checkpoint_epoch);
    try t.expectEqual(@as(u64, 0xC0DE), loaded.covered_lsn);
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
    try write(t.allocator, file, "GSTSORT0", 1, 0, 16, payload);
    try t.expectError(error.InvalidFormat, load(t.allocator, &file, TEST_MAGIC, 16));
}

test "zeroed magic (crash before magic publish) is rejected → rebuild path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try openTmpSnapshot(&tmp, "snap.bin");
    defer file.close(ioT());

    const payload = try makePayload(t.allocator, 8);
    defer t.allocator.free(payload);
    try write(t.allocator, file, TEST_MAGIC, 1, 0, 16, payload);
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
    try write(t.allocator, file, TEST_MAGIC, 1, 0, 16, payload);
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
    try write(t.allocator, file, TEST_MAGIC, 1, 0, 16, payload);
    try t.expectError(error.InvalidFormat, load(t.allocator, &file, TEST_MAGIC, 40));
}

test "corrupt directory / header byte is caught EAGERLY at load (meta-CRC)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try openTmpSnapshot(&tmp, "snap.bin");
    defer file.close(ioT());

    const payload = try makePayload(t.allocator, 8);
    defer t.allocator.free(payload);
    try write(t.allocator, file, TEST_MAGIC, 123, 0, 16, payload);
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
    try write(t.allocator, file, TEST_MAGIC, 9, 0, 16, payload);

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

    try write(t.allocator, file, TEST_MAGIC, 55, 0, 16, &.{});
    var loaded = (try load(t.allocator, &file, TEST_MAGIC, 16)).?;
    defer loaded.deinit();
    try t.expectEqual(@as(u64, 55), loaded.checkpoint_epoch);
    try t.expectEqual(@as(u64, 0), loaded.record_count);
}

test "restampStamps: epoch+covered_lsn + meta-CRC updated in place; payload/dir bytes untouched; records readable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try openTmpSnapshot(&tmp, "snap.bin");
    defer file.close(ioT());

    const payload = try makePayload(t.allocator, 5000); // > 1 block
    defer t.allocator.free(payload);
    try write(t.allocator, file, TEST_MAGIC, 41, 100, 16, payload);

    const stat = try file.stat(ioT());
    const size: usize = @intCast(stat.size);
    const before = try t.allocator.alloc(u8, size);
    defer t.allocator.free(before);
    _ = try file.readPositionalAll(ioT(), before, 0);

    try t.expect(try restampStamps(t.allocator, &file, TEST_MAGIC, 16, 42, 200));

    const after = try t.allocator.alloc(u8, size);
    defer t.allocator.free(after);
    _ = try file.readPositionalAll(ioT(), after, 0);

    // The CHEAP-restamp property: same length, and only bytes [8,24) (the
    // epoch + covered_lsn stamps) and the trailing 4 meta-CRC bytes may differ.
    try t.expectEqualSlices(u8, before[0..8], after[0..8]);
    try t.expectEqualSlices(u8, before[24 .. size - META_CRC_SIZE], after[24 .. size - META_CRC_SIZE]);
    try t.expect(!std.mem.eql(u8, before[8..24], after[8..24]));

    var loaded = (try load(t.allocator, &file, TEST_MAGIC, 16)).?;
    defer loaded.deinit();
    try t.expectEqual(@as(u64, 42), loaded.checkpoint_epoch);
    try t.expectEqual(@as(u64, 200), loaded.covered_lsn);
    var i: u64 = 0;
    while (i < 5000) : (i += 100) {
        const rec = try loaded.recordAt(i);
        try t.expectEqual(i * 2, std.mem.readInt(u64, rec[0..8], .little));
    }

    // Idempotent no-op when already stamped.
    try t.expect(try restampStamps(t.allocator, &file, TEST_MAGIC, 16, 42, 200));
}

test "restampStamps skips (returns false, no write) on empty file, wrong magic, wrong record_size, truncation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Empty (never written).
    var empty = try openTmpSnapshot(&tmp, "empty.bin");
    defer empty.close(ioT());
    try t.expect(!(try restampStamps(t.allocator, &empty, TEST_MAGIC, 16, 9, 90)));

    // Wrong magic (old format).
    var wrong = try openTmpSnapshot(&tmp, "wrong.bin");
    defer wrong.close(ioT());
    const payload = try makePayload(t.allocator, 8);
    defer t.allocator.free(payload);
    try write(t.allocator, wrong, "GSTSORT0", 1, 0, 16, payload);
    try t.expect(!(try restampStamps(t.allocator, &wrong, TEST_MAGIC, 16, 9, 90)));

    // Wrong record size.
    var rs = try openTmpSnapshot(&tmp, "rs.bin");
    defer rs.close(ioT());
    try write(t.allocator, rs, TEST_MAGIC, 1, 0, 16, payload);
    try t.expect(!(try restampStamps(t.allocator, &rs, TEST_MAGIC, 40, 9, 90)));

    // Truncated (layout mismatch).
    var trunc = try openTmpSnapshot(&tmp, "trunc.bin");
    defer trunc.close(ioT());
    try write(t.allocator, trunc, TEST_MAGIC, 1, 0, 16, payload);
    const st = try trunc.stat(ioT());
    try trunc.setLength(ioT(), st.size - 3);
    try t.expect(!(try restampStamps(t.allocator, &trunc, TEST_MAGIC, 16, 9, 90)));
}

test "restampStamps refuses to bless a corrupt header/directory (meta-CRC pre-check)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try openTmpSnapshot(&tmp, "snap.bin");
    defer file.close(ioT());

    const payload = try makePayload(t.allocator, 8);
    defer t.allocator.free(payload);
    try write(t.allocator, file, TEST_MAGIC, 5, 0, 16, payload);

    // Corrupt the record_count → meta-CRC mismatch... but that also breaks
    // the layout equation. Corrupt a DIRECTORY byte instead: layout holds,
    // meta fails.
    const dir_off = HEADER_SIZE + payload.len;
    var b: [1]u8 = undefined;
    _ = try file.readPositionalAll(ioT(), &b, dir_off);
    b[0] ^= 0x40;
    try file.writePositionalAll(ioT(), &b, dir_off);

    try t.expect(!(try restampStamps(t.allocator, &file, TEST_MAGIC, 16, 9, 90)));
    // Still rejected by the loader (never blessed).
    try t.expectError(error.ChecksumMismatch, load(t.allocator, &file, TEST_MAGIC, 16));
}

test "torn restamp (stamps landed, meta-CRC did not) → eager ChecksumMismatch at load → rebuild path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try openTmpSnapshot(&tmp, "snap.bin");
    defer file.close(ioT());

    const payload = try makePayload(t.allocator, 64);
    defer t.allocator.free(payload);
    try write(t.allocator, file, TEST_MAGIC, 7, 70, 16, payload);

    // Simulate the crash window inside restampStamps: the 16 stamp bytes
    // hit disk, the meta-CRC trailer write did not.
    var counter_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &counter_buf, 8, .little);
    try file.writePositionalAll(ioT(), &counter_buf, 8);

    try t.expectError(error.ChecksumMismatch, load(t.allocator, &file, TEST_MAGIC, 16));
}

test "writeAtomicReplace: replaces via rename; old mapping keeps serving old records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = ioT();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", t.allocator);
    defer t.allocator.free(dir_path);

    const payload1 = try makePayload(t.allocator, 100);
    defer t.allocator.free(payload1);
    try writeAtomicReplace(t.allocator, dir_path, "snap.bin", TEST_MAGIC, 1, 10, 16, payload1);

    var f1 = try tmp.dir.openFile(io, "snap.bin", .{ .mode = .read_write });
    var loaded_old = (try load(t.allocator, &f1, TEST_MAGIC, 16)).?;
    defer loaded_old.deinit();
    f1.close(io); // mapping outlives the fd

    // Replace with DIFFERENT content (values shifted) under the live mapping.
    const payload2 = try t.allocator.dupe(u8, payload1);
    defer t.allocator.free(payload2);
    for (0..100) |i| {
        std.mem.writeInt(u64, payload2[i * 16 + 8 ..][0..8], @as(u64, i) + 7000, .little);
    }
    try writeAtomicReplace(t.allocator, dir_path, "snap.bin", TEST_MAGIC, 2, 20, 16, payload2);

    // Old mapping: OLD values, every block still CRC-valid (old inode intact).
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        const rec = try loaded_old.recordAt(i);
        try t.expectEqual(i ^ 0x5A, std.mem.readInt(u64, rec[8..16], .little));
    }

    // Fresh open sees the NEW snapshot.
    var f2 = try tmp.dir.openFile(io, "snap.bin", .{ .mode = .read_write });
    defer f2.close(io);
    var loaded_new = (try load(t.allocator, &f2, TEST_MAGIC, 16)).?;
    defer loaded_new.deinit();
    try t.expectEqual(@as(u64, 2), loaded_new.checkpoint_epoch);
    try t.expectEqual(@as(u64, 20), loaded_new.covered_lsn);
    const rec0 = try loaded_new.recordAt(0);
    try t.expectEqual(@as(u64, 7000), std.mem.readInt(u64, rec0[8..16], .little));
}

test "I1: lazy payload ChecksumMismatch zeroes the magic (one-shot) so the next load rejects → rebuild" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = ioT();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", t.allocator);
    defer t.allocator.free(dir_path);
    const path = try std.fmt.allocPrint(t.allocator, "{s}/snap.bin", .{dir_path});
    defer t.allocator.free(path);

    const n: usize = 5000; // > 1 block
    const payload = try makePayload(t.allocator, n);
    defer t.allocator.free(payload);
    var file = try openTmpSnapshot(&tmp, "snap.bin");
    defer file.close(io);
    try write(t.allocator, file, TEST_MAGIC, 3, 30, 16, payload);

    // Bit-rot in block 0.
    var b: [1]u8 = undefined;
    _ = try file.readPositionalAll(io, &b, HEADER_SIZE + 100);
    b[0] ^= 0xFF;
    try file.writePositionalAll(io, &b, HEADER_SIZE + 100);

    var loaded = (try load(t.allocator, &file, TEST_MAGIC, 16)).?;
    defer loaded.deinit();
    try loaded.enableInvalidateOnCorruption(path);

    // Untouched block still fine; corrupt block errors AND invalidates.
    _ = try loaded.recordAt(4500);
    try t.expectError(error.ChecksumMismatch, loaded.recordAt(3));
    // Error stays deterministic for the rest of the session.
    try t.expectError(error.ChecksumMismatch, loaded.recordAt(3));

    // The on-disk magic is now zeroed → next load takes the rebuild path.
    var magic_now: [8]u8 = undefined;
    _ = try file.readPositionalAll(io, &magic_now, 0);
    try t.expectEqualSlices(u8, &([_]u8{0} ** 8), &magic_now);
    try t.expectError(error.InvalidFormat, load(t.allocator, &file, TEST_MAGIC, 16));
}

test "M6: recordAt out-of-range index is a hard error, not UB" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try openTmpSnapshot(&tmp, "snap.bin");
    defer file.close(ioT());

    const payload = try makePayload(t.allocator, 4);
    defer t.allocator.free(payload);
    try write(t.allocator, file, TEST_MAGIC, 1, 0, 16, payload);
    var loaded = (try load(t.allocator, &file, TEST_MAGIC, 16)).?;
    defer loaded.deinit();
    try t.expectError(error.InvalidRecordIndex, loaded.recordAt(4));
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
