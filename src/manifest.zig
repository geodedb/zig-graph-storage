// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
// fips-exempt: non-security — CRC32C record-integrity (corruption detection)
// for on-disk format; not authentication.
const Crc32 = std.hash.crc.Crc32Iscsi;
// fips-exempt: non-security — type alias only; manifest integrity tag over
// on-disk format, not authentication of a security principal.
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
// fips-exempt: non-security — type alias only; constant-time compare helper
// for the non-security integrity tag above.
const timing_safe = std.crypto.timing_safe;
const owner_only_file_mode = 0o600;

pub const MANIFEST_MAGIC: [8]u8 = .{ 'G', 'E', 'O', 'M', 'N', 'F', '0', '1' };
pub const MANIFEST_VERSION: u32 = 2;

/// SEC-0043: When Transparent Data Encryption is enabled (an encryption key is
/// configured), the manifest carries a keyed HMAC-SHA256 trailer in addition to
/// the CRC32 footer. The trailer is appended after the CRC-only body, so its
/// presence is detectable purely from the on-disk file size — the change is
/// additive and plaintext (no-key) manifests are byte-for-byte unchanged.
///
/// The HMAC is computed over the ENTIRE CRC-only body (magic + fields + CRC32),
/// keyed with the configured encryption key, mirroring `backup.zig`. CRC32 is
/// trivially recomputable, so without this trailer an attacker with filesystem
/// write access could forge a manifest (roll back `last_checkpoint_lsn`, tamper
/// page counts/UUID) to redirect recovery undetected.
pub const MANIFEST_HMAC_SIZE: usize = HmacSha256.mac_length;

/// V1 used a 40-byte NodeRec with label_set: u32 bitmap.
/// V2 uses a 48-byte NodeRec with label_head: u64 + label_count: u16.
/// Migration from V1 to V2 requires recreating the data directory.
pub const MANIFEST_VERSION_V1: u32 = 1;

/// Size of the serialized manifest in bytes:
/// magic(8) + fields (see below) + CRC32(4)
const FIELD_SIZE: usize = 4 + 16 + 4 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 4 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 8; // = 148
/// Size of the CRC-only (plaintext) serialized manifest: magic + fields + crc = 160.
pub const SERIALIZED_SIZE: usize = 8 + FIELD_SIZE + 4;
/// Authenticated (TDE) size: CRC-only body + HMAC-SHA256 trailer = 192.
pub const SERIALIZED_SIZE_HMAC: usize = SERIALIZED_SIZE + MANIFEST_HMAC_SIZE;

pub const Manifest = struct {
    format_version: u32 = MANIFEST_VERSION,
    graph_uuid: [16]u8 = [_]u8{0} ** 16,
    page_size: u32 = 8192,
    counter: u64 = 0,
    last_checkpoint_lsn: u64 = 0,
    node_high_water: u64 = 0,
    edge_high_water: u64 = 0,
    next_node_id: u64 = 1,
    next_edge_id: u64 = 1,
    next_txn_id: u64 = 1,
    label_count: u32 = 0,
    nodes_pages: u64 = 0,
    adj_out_pages: u64 = 0,
    adj_in_pages: u64 = 0,
    props_pages: u64 = 0,
    var_pages: u64 = 0,
    free_pages: u64 = 0,
    node_count: u64 = 0,
    edge_count: u64 = 0,

    /// Serialize to bytes: magic(8) + all fields in little-endian + CRC32(4).
    /// Plaintext (no-key) form. Identical to `serializeWithKey(allocator, null)`.
    pub fn serialize(self: *const Manifest, allocator: Allocator) ![]u8 {
        return self.serializeWithKey(allocator, null);
    }

    /// SEC-0043: Serialize, optionally authenticating with a keyed HMAC-SHA256.
    ///
    /// When `key` is null the output is the plaintext CRC-only form (unchanged).
    /// When `key` is set, a 32-byte HMAC-SHA256 trailer is appended over the
    /// entire CRC-only body (magic + fields + CRC32). The longer length makes
    /// the authenticated form detectable from the file size alone.
    pub fn serializeWithKey(self: *const Manifest, allocator: Allocator, key: ?[32]u8) ![]u8 {
        const out_len: usize = if (key != null) SERIALIZED_SIZE_HMAC else SERIALIZED_SIZE;
        const buf = try allocator.alloc(u8, out_len);
        errdefer allocator.free(buf);

        var pos: usize = 0;

        // Magic
        @memcpy(buf[pos..][0..8], &MANIFEST_MAGIC);
        pos += 8;

        // Fields in order
        writeU32(buf, &pos, self.format_version);
        @memcpy(buf[pos..][0..16], &self.graph_uuid);
        pos += 16;
        writeU32(buf, &pos, self.page_size);
        writeU64(buf, &pos, self.counter);
        writeU64(buf, &pos, self.last_checkpoint_lsn);
        writeU64(buf, &pos, self.node_high_water);
        writeU64(buf, &pos, self.edge_high_water);
        writeU64(buf, &pos, self.next_node_id);
        writeU64(buf, &pos, self.next_edge_id);
        writeU64(buf, &pos, self.next_txn_id);
        writeU32(buf, &pos, self.label_count);
        writeU64(buf, &pos, self.nodes_pages);
        writeU64(buf, &pos, self.adj_out_pages);
        writeU64(buf, &pos, self.adj_in_pages);
        writeU64(buf, &pos, self.props_pages);
        writeU64(buf, &pos, self.var_pages);
        writeU64(buf, &pos, self.free_pages);
        writeU64(buf, &pos, self.node_count);
        writeU64(buf, &pos, self.edge_count);

        // CRC32 over everything before the checksum
        const crc = Crc32.hash(buf[0..pos]);
        writeU32(buf, &pos, crc);

        // SEC-0043: keyed HMAC-SHA256 trailer over the full CRC-only body.
        if (key) |k| {
            var tag: [MANIFEST_HMAC_SIZE]u8 = undefined;
            HmacSha256.create(&tag, buf[0..SERIALIZED_SIZE], &k);
            @memcpy(buf[pos..][0..MANIFEST_HMAC_SIZE], &tag);
            pos += MANIFEST_HMAC_SIZE;
        }

        return buf;
    }

    /// Parse bytes, validate magic and CRC32, return manifest.
    /// Plaintext (no-key) form. Identical to `deserializeWithKey(.., null)`.
    pub fn deserialize(allocator: Allocator, data: []const u8) !Manifest {
        return deserializeWithKey(allocator, data, null);
    }

    /// SEC-0043: Parse bytes, validate magic + CRC32, and (when a key is set)
    /// verify the HMAC-SHA256 trailer with a constant-time compare.
    ///
    /// Fail-closed semantics under TDE: if a key is configured the trailer is
    /// REQUIRED. A CRC-only manifest (legacy/plaintext layout) or any HMAC
    /// mismatch returns `error.ManifestAuthFailed` — an attacker cannot strip
    /// the trailer to downgrade to CRC-only verification.
    pub fn deserializeWithKey(allocator: Allocator, data: []const u8, key: ?[32]u8) !Manifest {
        _ = allocator;

        if (data.len < SERIALIZED_SIZE) return error.InvalidData;

        // Validate magic
        if (!std.mem.eql(u8, data[0..8], &MANIFEST_MAGIC)) return error.InvalidMagic;

        // Validate CRC32 over the CRC-only body.
        const stored_crc = readU32(data, SERIALIZED_SIZE - 4);
        const computed_crc = Crc32.hash(data[0 .. SERIALIZED_SIZE - 4]);
        if (stored_crc != computed_crc) return error.ChecksumMismatch;

        // SEC-0043: under TDE the HMAC trailer is mandatory and authenticated.
        if (key) |k| {
            if (data.len < SERIALIZED_SIZE_HMAC) return error.ManifestAuthFailed;
            var expected: [MANIFEST_HMAC_SIZE]u8 = undefined;
            HmacSha256.create(&expected, data[0..SERIALIZED_SIZE], &k);
            var stored: [MANIFEST_HMAC_SIZE]u8 = undefined;
            @memcpy(&stored, data[SERIALIZED_SIZE..][0..MANIFEST_HMAC_SIZE]);
            if (!timing_safe.eql([MANIFEST_HMAC_SIZE]u8, stored, expected)) {
                return error.ManifestAuthFailed;
            }
        }

        var pos: usize = 8;
        var m = Manifest{};

        m.format_version = readU32(data, pos);
        pos += 4;
        @memcpy(&m.graph_uuid, data[pos..][0..16]);
        pos += 16;
        m.page_size = readU32(data, pos);
        pos += 4;
        m.counter = readU64(data, pos);
        pos += 8;
        m.last_checkpoint_lsn = readU64(data, pos);
        pos += 8;
        m.node_high_water = readU64(data, pos);
        pos += 8;
        m.edge_high_water = readU64(data, pos);
        pos += 8;
        m.next_node_id = readU64(data, pos);
        pos += 8;
        m.next_edge_id = readU64(data, pos);
        pos += 8;
        m.next_txn_id = readU64(data, pos);
        pos += 8;
        m.label_count = readU32(data, pos);
        pos += 4;
        m.nodes_pages = readU64(data, pos);
        pos += 8;
        m.adj_out_pages = readU64(data, pos);
        pos += 8;
        m.adj_in_pages = readU64(data, pos);
        pos += 8;
        m.props_pages = readU64(data, pos);
        pos += 8;
        m.var_pages = readU64(data, pos);
        pos += 8;
        m.free_pages = readU64(data, pos);
        pos += 8;
        m.node_count = readU64(data, pos);
        pos += 8;
        m.edge_count = readU64(data, pos);

        return m;
    }

    /// Serialize and write atomically (write to .tmp, fsync, rename).
    /// Plaintext (no-key) form. Identical to `writeToFileWithKey(.., null)`.
    pub fn writeToFile(self: *const Manifest, allocator: Allocator, path: []const u8) !void {
        return self.writeToFileWithKey(allocator, path, null);
    }

    /// SEC-0043: Serialize (optionally HMAC-authenticated) and write atomically
    /// (write to .tmp, fsync, rename). When `key` is set the on-disk manifest
    /// carries a keyed HMAC-SHA256 trailer verified by `readFromFileWithKey`.
    pub fn writeToFileWithKey(self: *const Manifest, allocator: Allocator, path: []const u8, key: ?[32]u8) !void {
        const data = try self.serializeWithKey(allocator, key);
        defer allocator.free(data);

        const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
        defer allocator.free(tmp_path);

        // Write to tmp file.
        // SEC-0052: resolve_beneath prevents symlink traversal out of the
        // graph directory via a crafted path.  exclusive is omitted because a
        // previous crashed write may have left a stale .tmp file behind that
        // is legitimately safe to overwrite on the retry path.
        const tmp_file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), tmp_path, .{
            .permissions = std.Io.File.Permissions.fromMode(owner_only_file_mode),
            .resolve_beneath = true,
        });
        defer tmp_file.close(std.Io.Threaded.global_single_threaded.io());

        try tmp_file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), data);
        try tmp_file.sync(std.Io.Threaded.global_single_threaded.io());

        // Atomic rename
        try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, std.Io.Threaded.global_single_threaded.io());
    }

    /// Read file, deserialize. Return null if file doesn't exist.
    /// Plaintext (no-key) form. Identical to `readFromFileWithKey(.., null)`.
    pub fn readFromFile(allocator: Allocator, path: []const u8) !?Manifest {
        return readFromFileWithKey(allocator, path, null);
    }

    /// SEC-0043: Read file, deserialize and (when a key is set) verify the
    /// HMAC-SHA256 trailer. Returns null if the file doesn't exist.
    pub fn readFromFileWithKey(allocator: Allocator, path: []const u8, key: ?[32]u8) !?Manifest {
        const file = std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close(std.Io.Threaded.global_single_threaded.io());

        const io = std.Io.Threaded.global_single_threaded.io();
        const file_len = try file.length(io);
        if (file_len > SERIALIZED_SIZE_HMAC * 2) return error.FileTooLarge;
        const data = try allocator.alloc(u8, @intCast(file_len));
        defer allocator.free(data);
        const bytes_read = try file.readPositionalAll(io, data, 0);
        if (bytes_read != data.len) return error.UnexpectedEndOfFile;

        return try deserializeWithKey(allocator, data, key);
    }

    /// Pick the manifest with the higher counter.
    /// If both null, return error. If one null, return the other.
    pub fn selectManifest(a: ?Manifest, b: ?Manifest) !Manifest {
        if (a == null and b == null) return error.NoManifest;
        if (a == null) return b.?;
        if (b == null) return a.?;
        return if (a.?.counter >= b.?.counter) a.? else b.?;
    }
};

// Helper functions for little-endian encoding

fn writeU32(buf: []u8, pos: *usize, value: u32) void {
    @memcpy(buf[pos.*..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
    pos.* += 4;
}

fn writeU64(buf: []u8, pos: *usize, value: u64) void {
    @memcpy(buf[pos.*..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    pos.* += 8;
}

fn readU32(data: []const u8, offset: usize) u32 {
    return std.mem.littleToNative(u32, @bitCast(data[offset..][0..4].*));
}

fn readU64(data: []const u8, offset: usize) u64 {
    return std.mem.littleToNative(u64, @bitCast(data[offset..][0..8].*));
}

// ============================================================================
// Unit Tests
// ============================================================================

test "serialize/deserialize round-trip" {
    const allocator = std.testing.allocator;
    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0xAB);

    const m = Manifest{
        .graph_uuid = uuid,
        .counter = 42,
        .next_node_id = 100,
        .next_edge_id = 200,
        .next_txn_id = 300,
        .label_count = 5,
        .nodes_pages = 10,
        .adj_out_pages = 20,
        .adj_in_pages = 30,
        .props_pages = 40,
        .var_pages = 50,
        .free_pages = 60,
        .node_count = 70,
        .edge_count = 80,
    };

    const data = try m.serialize(allocator);
    defer allocator.free(data);

    const m2 = try Manifest.deserialize(allocator, data);

    try std.testing.expectEqual(m.format_version, m2.format_version);
    try std.testing.expectEqual(m.graph_uuid, m2.graph_uuid);
    try std.testing.expectEqual(m.page_size, m2.page_size);
    try std.testing.expectEqual(m.counter, m2.counter);
    try std.testing.expectEqual(m.next_node_id, m2.next_node_id);
    try std.testing.expectEqual(m.next_edge_id, m2.next_edge_id);
    try std.testing.expectEqual(m.next_txn_id, m2.next_txn_id);
    try std.testing.expectEqual(m.label_count, m2.label_count);
    try std.testing.expectEqual(m.nodes_pages, m2.nodes_pages);
    try std.testing.expectEqual(m.adj_out_pages, m2.adj_out_pages);
    try std.testing.expectEqual(m.adj_in_pages, m2.adj_in_pages);
    try std.testing.expectEqual(m.props_pages, m2.props_pages);
    try std.testing.expectEqual(m.var_pages, m2.var_pages);
    try std.testing.expectEqual(m.free_pages, m2.free_pages);
    try std.testing.expectEqual(m.node_count, m2.node_count);
    try std.testing.expectEqual(m.edge_count, m2.edge_count);
}

test "corrupt data detected (bad CRC)" {
    const allocator = std.testing.allocator;
    const m = Manifest{};
    const data = try m.serialize(allocator);
    defer allocator.free(data);

    // Corrupt a byte in the middle
    data[20] ^= 0xFF;

    const result = Manifest.deserialize(allocator, data);
    try std.testing.expectError(error.ChecksumMismatch, result);
}

test "bad magic detected" {
    const allocator = std.testing.allocator;
    const m = Manifest{};
    const data = try m.serialize(allocator);
    defer allocator.free(data);

    // Corrupt magic
    data[0] = 'X';

    const result = Manifest.deserialize(allocator, data);
    try std.testing.expectError(error.InvalidMagic, result);
}

test "A/B selection: higher counter wins" {
    const a = Manifest{ .counter = 10 };
    const b = Manifest{ .counter = 20 };
    const selected = try Manifest.selectManifest(a, b);
    try std.testing.expectEqual(@as(u64, 20), selected.counter);

    const selected2 = try Manifest.selectManifest(b, a);
    try std.testing.expectEqual(@as(u64, 20), selected2.counter);
}

test "A/B selection: one null returns the other" {
    const m = Manifest{ .counter = 5 };
    const from_a = try Manifest.selectManifest(m, null);
    try std.testing.expectEqual(@as(u64, 5), from_a.counter);

    const from_b = try Manifest.selectManifest(null, m);
    try std.testing.expectEqual(@as(u64, 5), from_b.counter);
}

test "A/B selection: both null returns error" {
    const result = Manifest.selectManifest(null, null);
    try std.testing.expectError(error.NoManifest, result);
}

test "writeToFile/readFromFile round-trip" {
    const allocator = std.testing.allocator;

    // Use a temp directory for file I/O tests
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(tmp_path);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/manifest.test", .{tmp_path});
    defer allocator.free(file_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0xCD);

    const m = Manifest{
        .graph_uuid = uuid,
        .counter = 99,
        .next_node_id = 500,
    };

    try m.writeToFile(allocator, file_path);

    const saved_file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), file_path, .{});
    defer saved_file.close(std.Io.Threaded.global_single_threaded.io());
    const saved_stat = try saved_file.stat(std.Io.Threaded.global_single_threaded.io());
    try std.testing.expectEqual(@as(u32, owner_only_file_mode), saved_stat.permissions.toMode() & 0o7777);

    const loaded = try Manifest.readFromFile(allocator, file_path);
    try std.testing.expect(loaded != null);

    const m2 = loaded.?;
    try std.testing.expectEqual(m.graph_uuid, m2.graph_uuid);
    try std.testing.expectEqual(m.counter, m2.counter);
    try std.testing.expectEqual(m.next_node_id, m2.next_node_id);
}

test "readFromFile returns null for missing file" {
    const allocator = std.testing.allocator;
    const result = try Manifest.readFromFile(allocator, "/tmp/nonexistent_manifest_file_12345");
    try std.testing.expectEqual(@as(?Manifest, null), result);
}

test "SEC-0043: TDE round-trip — HMAC manifest written and read back with key succeeds" {
    const allocator = std.testing.allocator;
    const key = [_]u8{0x43} ** 32;

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0xCD);

    const m = Manifest{
        .graph_uuid = uuid,
        .counter = 7,
        .last_checkpoint_lsn = 1234,
        .next_node_id = 500,
        .node_count = 9,
        .edge_count = 11,
    };

    const data = try m.serializeWithKey(allocator, key);
    defer allocator.free(data);

    // Authenticated form is longer than the plaintext (CRC-only) form.
    try std.testing.expect(data.len > SERIALIZED_SIZE);

    const m2 = try Manifest.deserializeWithKey(allocator, data, key);
    try std.testing.expectEqual(m.graph_uuid, m2.graph_uuid);
    try std.testing.expectEqual(m.counter, m2.counter);
    try std.testing.expectEqual(m.last_checkpoint_lsn, m2.last_checkpoint_lsn);
    try std.testing.expectEqual(m.next_node_id, m2.next_node_id);
    try std.testing.expectEqual(m.node_count, m2.node_count);
    try std.testing.expectEqual(m.edge_count, m2.edge_count);
}

test "SEC-0043: TDE tamper with recomputed CRC32 is rejected (HMAC auth fails)" {
    const allocator = std.testing.allocator;
    const key = [_]u8{0x43} ** 32;

    const m = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .counter = 10,
        .last_checkpoint_lsn = 9999,
    };

    const data = try m.serializeWithKey(allocator, key);
    defer allocator.free(data);

    // Roll back last_checkpoint_lsn in the serialized body and RECOMPUTE the
    // CRC32 so a CRC-only check would pass. The HMAC must still catch it.
    const lsn_offset: usize = 8 + 4 + 16 + 4 + 8; // magic + fmt + uuid + page_size + counter
    @memcpy(data[lsn_offset..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, @as(u64, 0))));
    const new_crc = Crc32.hash(data[0 .. SERIALIZED_SIZE - 4]);
    @memcpy(data[SERIALIZED_SIZE - 4 ..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, new_crc)));

    // CRC-only deserialize would happily accept the forgery...
    const forged = try Manifest.deserialize(allocator, data[0..SERIALIZED_SIZE]);
    try std.testing.expectEqual(@as(u64, 0), forged.last_checkpoint_lsn);

    // ...but the keyed path detects the tamper via HMAC and fails closed.
    const result = Manifest.deserializeWithKey(allocator, data, key);
    try std.testing.expectError(error.ManifestAuthFailed, result);
}

test "SEC-0043: keyed read of a plaintext (CRC-only) manifest fails closed" {
    const allocator = std.testing.allocator;
    const key = [_]u8{0x43} ** 32;

    const m = Manifest{ .graph_uuid = [_]u8{0xAA} ** 16, .counter = 3 };
    const data = try m.serialize(allocator); // plaintext, no HMAC trailer
    defer allocator.free(data);

    // Attempting to read it with a key must not silently downgrade.
    const result = Manifest.deserializeWithKey(allocator, data, key);
    try std.testing.expectError(error.ManifestAuthFailed, result);
}

test "SEC-0043: plaintext regression — no key path unchanged (CRC32 only)" {
    const allocator = std.testing.allocator;
    const m = Manifest{ .graph_uuid = [_]u8{0x11} ** 16, .counter = 42 };

    // serialize and serializeWithKey(null) must produce identical bytes.
    const a = try m.serialize(allocator);
    defer allocator.free(a);
    const b = try m.serializeWithKey(allocator, null);
    defer allocator.free(b);
    try std.testing.expectEqualSlices(u8, a, b);
    try std.testing.expectEqual(@as(usize, SERIALIZED_SIZE), a.len);

    // Round-trips both ways.
    const m1 = try Manifest.deserialize(allocator, a);
    const m2 = try Manifest.deserializeWithKey(allocator, a, null);
    try std.testing.expectEqual(m.counter, m1.counter);
    try std.testing.expectEqual(m.counter, m2.counter);
}

test "SEC-0043: writeToFileWithKey/readFromFileWithKey round-trip and tamper detection" {
    const allocator = std.testing.allocator;
    const key = [_]u8{0x77} ** 32;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(tmp_path);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/manifest.hmac", .{tmp_path});
    defer allocator.free(file_path);

    const m = Manifest{ .graph_uuid = [_]u8{0xEE} ** 16, .counter = 21, .last_checkpoint_lsn = 555 };
    try m.writeToFileWithKey(allocator, file_path, key);

    const loaded = try Manifest.readFromFileWithKey(allocator, file_path, key);
    try std.testing.expect(loaded != null);
    try std.testing.expectEqual(@as(u64, 555), loaded.?.last_checkpoint_lsn);

    // Tamper the on-disk body and recompute CRC; keyed read must reject it.
    {
        const f = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), file_path, .{ .mode = .read_write });
        defer f.close(std.Io.Threaded.global_single_threaded.io());
        const io = std.Io.Threaded.global_single_threaded.io();
        const flen = try f.length(io);
        const buf = try allocator.alloc(u8, @intCast(flen));
        defer allocator.free(buf);
        _ = try f.readPositionalAll(io, buf, 0);
        const lsn_offset: usize = 8 + 4 + 16 + 4 + 8;
        @memcpy(buf[lsn_offset..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, @as(u64, 0))));
        const new_crc = Crc32.hash(buf[0 .. SERIALIZED_SIZE - 4]);
        @memcpy(buf[SERIALIZED_SIZE - 4 ..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, new_crc)));
        try f.writePositionalAll(io, buf, 0);
    }

    const tampered = Manifest.readFromFileWithKey(allocator, file_path, key);
    try std.testing.expectError(error.ManifestAuthFailed, tampered);
}

test {
    std.testing.refAllDecls(@This());
}
