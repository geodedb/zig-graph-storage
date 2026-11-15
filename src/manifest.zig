// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const scoped_file = @import("scoped_file.zig");
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
/// V4 (v0.2.29): appends the durable `checkpoint_epoch` field (8 B) at the END
/// of the field block so persisted derived-index snapshots survive a WAL-tail
/// recovery. This is an ADDITIVE, positional change (mirrors the in_idx/in_dir
/// append precedent). The byte layout is 8 bytes LONGER than V3, so the bump
/// doubles as a downgrade gate: a pre-v0.2.29 (V3) binary opening a V4 manifest
/// fails closed at open — its CRC boundary (SERIALIZED_SIZE-4 at the shorter
/// V3 size) lands inside the appended field, so the CRC check mismatches and
/// both slots read null (recovery aborts) rather than silently misparsing.
///
/// V3 (v0.2.24, GAP-ENT-0024): store-level downgrade gate for inline edge
/// public ids. The manifest's own byte layout is UNCHANGED from V2 — that bump
/// existed so a pre-v0.2.24 binary fails on a store this version has touched.
/// A V4 reader treats a V3 (or lower) format_version per the version gate's
/// existing read-only-or-IncompatibleVersion policy (recovery.zig).
pub const MANIFEST_VERSION: u32 = 4;

/// V5 (SONNY-6590): the format_version of a store under at-rest encryption
/// whose side files (labels.dict, props.idx, ordered_propidx.snap,
/// props.catalog, propidx_*.btree) are sealed. The manifest's byte layout is
/// IDENTICAL to V4; only the value differs. Under a key it is authenticated
/// by the manifest HMAC (SEC-0043), so it is the durable, tamper-evident
/// record that a plaintext side file must be refused rather than adopted
/// (V4 under a key = a store written by <= 0.4.16, upgraded at open). The
/// bump doubles as a downgrade gate: graph_storage <= 0.4.16 refuses a V5
/// manifest with `error.IncompatibleVersion`. Stores without a key stay V4.
pub const MANIFEST_VERSION_SEALED_SIDE_FILES: u32 = 5;

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

/// V2 (v0.2.23 and earlier): 48-byte NodeRec, 24 B adjacency entries only.
/// Every store byte a V2 binary wrote is readable by a V3 binary (v2 adjacency
/// blocks are self-describing via `entry_format` in the block header), so V2
/// stores are accepted and upgraded in place at open.
pub const MANIFEST_VERSION_V2: u32 = 2;

/// V3 (v0.2.24 .. v0.2.28): the inline-edge-public-id byte layout PLUS the two
/// edge-co-location page counts. V4 (this build) is a strictly additive
/// extension — it appends `checkpoint_epoch` (8 B) at the END of the field
/// block, so a V3 manifest is 8 bytes shorter and a V4 manifest opened by a
/// pre-v0.2.29 (V3) binary fails closed at open (its CRC boundary lands inside
/// the appended field). Recovery's version gate requires V4; a V3 (or lower)
/// format_version follows the existing read-only-or-IncompatibleVersion policy.
pub const MANIFEST_VERSION_V3: u32 = 3;

/// Size of the serialized manifest in bytes:
/// magic(8) + fields (see below) + CRC32(4)
/// Edge co-location (Phase A) appends in_idx_pages + in_dir_pages (two u64) to
/// the field block; V4 appends checkpoint_epoch (one u64). The format is
/// otherwise unchanged. (Migrating a legacy, shorter manifest is Phase B;
/// fresh graphs created by this build are self-consistent.)
const FIELD_SIZE: usize = 4 + 16 + 4 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 4 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 8; // = 172
/// Size of the CRC-only (plaintext) serialized manifest: magic + fields + crc = 184.
pub const SERIALIZED_SIZE: usize = 8 + FIELD_SIZE + 4;
/// Authenticated (TDE) size: CRC-only body + HMAC-SHA256 trailer = 216.
pub const SERIALIZED_SIZE_HMAC: usize = SERIALIZED_SIZE + MANIFEST_HMAC_SIZE;

/// GAP-0053 v3→v4 upgrade path — the on-disk sizes of a pre-v0.2.29 (V3)
/// manifest. V4 appends `checkpoint_epoch` (8 B) at the END of the field block,
/// so a V3 manifest's field block is exactly 8 B shorter. These constants exist
/// ONLY to recognise and validate a genuine V3 manifest so `deserialize` can
/// upgrade it in-memory; SERIALIZE never emits them (it always writes V4).
const FIELD_SIZE_V3: usize = FIELD_SIZE - 8; // = 164 (no checkpoint_epoch)
/// V3 CRC-only serialized size: magic(8) + v3 fields(164) + crc(4) = 176.
const SERIALIZED_SIZE_V3: usize = 8 + FIELD_SIZE_V3 + 4;
/// V3 authenticated (TDE) size: v3 CRC-only body + HMAC-SHA256 trailer = 208.
const SERIALIZED_SIZE_V3_HMAC: usize = SERIALIZED_SIZE_V3 + MANIFEST_HMAC_SIZE;

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
    /// Edge co-location (Phase A): allocated page counts for the per-shard
    /// incoming-adjacency chain bodies (`in_idx`) and the dst->head directory
    /// (`in_dir`). Serialized at the END of the field block (additive).
    in_idx_pages: u64 = 0,
    in_dir_pages: u64 = 0,
    /// Durable derived-index freshness epoch. Advanced ONLY by
    /// `checkpoint.zig:doCheckpoint`, NEVER by `recovery.zig:recover` (unlike
    /// `counter`, which recovery bumps for A/B freshness, and
    /// `last_checkpoint_lsn`, which recovery overwrites when it replays a tail).
    /// Derived-index snapshots stamp this so a snapshot taken at epoch E stays
    /// valid across a pure WAL-tail recovery (counter advances, epoch does not).
    /// Serialized LAST in the field block (additive, mirrors the in_idx/in_dir
    /// append precedent).
    checkpoint_epoch: u64 = 0,

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
        writeU64(buf, &pos, self.in_idx_pages);
        writeU64(buf, &pos, self.in_dir_pages);
        writeU64(buf, &pos, self.checkpoint_epoch);

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

        // GAP-0053 v3→v4 UPGRADE PATH. A store written by v0.2.24..v0.2.28 has a
        // V3 manifest: exactly SERIALIZED_SIZE_V3 (176) bytes, or
        // SERIALIZED_SIZE_V3_HMAC (208) under TDE — 8 bytes SHORTER than V4
        // because checkpoint_epoch is absent. Without this branch the V4 length
        // gate below rejects it (176 < 184 → InvalidData → NoManifest), bricking
        // every existing store.
        //
        // Discriminate on BOTH the exact V3 length AND the embedded
        // format_version field (== 3). This is unambiguous:
        //   * A V4 store is always 184/216 bytes, never 176/208 — never confused.
        //   * A truncated/torn V4 keeps format_version==4 (offset 8, ahead of any
        //     tail truncation), so it never matches even if it happens to land on
        //     176/208 bytes; it falls through and fails closed.
        //   * A matched candidate is then validated with the V3 CRC (and, under
        //     TDE, the V3 HMAC) EXACTLY as v0.2.28 did — a corrupt or tampered V3
        //     fails closed (ChecksumMismatch / ManifestAuthFailed). There is NO
        //     heuristic acceptance.
        // A VALID V3 is upgraded in-memory to V4 (checkpoint_epoch = 0); SERIALIZE
        // always emits V4, so the store auto-migrates on the next manifest write.
        if ((data.len == SERIALIZED_SIZE_V3 or data.len == SERIALIZED_SIZE_V3_HMAC) and
            std.mem.eql(u8, data[0..8], &MANIFEST_MAGIC) and
            readU32(data, 8) == MANIFEST_VERSION_V3)
        {
            return deserializeV3Upgrade(data, key);
        }

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
        pos += 8;
        m.in_idx_pages = readU64(data, pos);
        pos += 8;
        m.in_dir_pages = readU64(data, pos);
        pos += 8;
        m.checkpoint_epoch = readU64(data, pos);

        return m;
    }

    /// GAP-0053: parse a V3-layout manifest (caller already confirmed the exact
    /// V3 length, valid magic, and format_version == 3) and return it upgraded
    /// in-memory to the V4 shape.
    ///
    /// The V3 CRC (over magic + the 164-byte V3 field block) and, under TDE, the
    /// V3 HMAC trailer (over the V3 CRC-only body) are validated EXACTLY as
    /// v0.2.28 did, so a corrupt or tampered V3 manifest fails closed
    /// (ChecksumMismatch / ManifestAuthFailed) and is NEVER heuristically
    /// upgraded. On success:
    ///   * every persisted V3 field is preserved verbatim,
    ///   * checkpoint_epoch is set to its upgrade default of 0 — a freshly
    ///     upgraded store has no epoch-stamped derived snapshots (their old
    ///     counter/magic forces a rebuild), and the first post-upgrade checkpoint
    ///     bumps epoch 0 → 1, so no stale snapshot can false-match a later epoch,
    ///   * format_version is bumped to the current MANIFEST_VERSION so the next
    ///     SERIALIZE persists the store in V4 layout (auto-migration).
    fn deserializeV3Upgrade(data: []const u8, key: ?[32]u8) !Manifest {
        // V3 CRC covers magic + V3 field block: bytes 0 .. SERIALIZED_SIZE_V3-4.
        const stored_crc = readU32(data, SERIALIZED_SIZE_V3 - 4);
        const computed_crc = Crc32.hash(data[0 .. SERIALIZED_SIZE_V3 - 4]);
        if (stored_crc != computed_crc) return error.ChecksumMismatch;

        // SEC-0043 parity: under TDE the V3 HMAC trailer is mandatory and
        // constant-time verified — an attacker cannot strip it to downgrade to
        // CRC-only verification, and a forged body is rejected.
        if (key) |k| {
            if (data.len < SERIALIZED_SIZE_V3_HMAC) return error.ManifestAuthFailed;
            var expected: [MANIFEST_HMAC_SIZE]u8 = undefined;
            HmacSha256.create(&expected, data[0..SERIALIZED_SIZE_V3], &k);
            var stored: [MANIFEST_HMAC_SIZE]u8 = undefined;
            @memcpy(&stored, data[SERIALIZED_SIZE_V3..][0..MANIFEST_HMAC_SIZE]);
            if (!timing_safe.eql([MANIFEST_HMAC_SIZE]u8, stored, expected)) {
                return error.ManifestAuthFailed;
            }
        }

        var pos: usize = 8;
        var m = Manifest{};

        // format_version is read to advance the cursor; it is authoritatively
        // set to MANIFEST_VERSION at the end (this IS the upgrade).
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
        pos += 8;
        m.in_idx_pages = readU64(data, pos);
        pos += 8;
        m.in_dir_pages = readU64(data, pos);
        pos += 8;
        // V3 has NO checkpoint_epoch here — pos now == SERIALIZED_SIZE_V3 - 4
        // (the CRC we already validated). Apply the upgrade defaults.
        m.checkpoint_epoch = 0;
        m.format_version = MANIFEST_VERSION;

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
        const tmp_file = try scoped_file.create(std.Io.Threaded.global_single_threaded.io(), tmp_path, .{
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

/// GAP-0053 TEST/FIXTURE ONLY — reproduce the exact pre-v0.2.29 (V3) on-disk
/// byte layout: magic(8) + V3 field block(164, NO checkpoint_epoch) + V3 CRC(4),
/// optionally followed by the V3 keyed HMAC-SHA256 trailer over the V3 CRC-only
/// body. This is byte-for-byte what a v0.2.24..v0.2.28 binary's `serialize`
/// produced, and is the authoritative fixture for the v3→v4 upgrade tests
/// (manifest.zig unit tests and the recovery integration test). Production code
/// NEVER emits V3 — SERIALIZE always writes V4. `m.format_version` is written
/// verbatim so an adversarial fixture can also stamp a non-3 version.
pub fn serializeV3Legacy(allocator: Allocator, m: Manifest, key: ?[32]u8) ![]u8 {
    const out_len: usize = if (key != null) SERIALIZED_SIZE_V3_HMAC else SERIALIZED_SIZE_V3;
    const buf = try allocator.alloc(u8, out_len);
    errdefer allocator.free(buf);

    var pos: usize = 0;
    @memcpy(buf[pos..][0..8], &MANIFEST_MAGIC);
    pos += 8;

    // V3 field block: identical to V4 THROUGH in_dir_pages; checkpoint_epoch is
    // absent in V3 (it is the appended field V4 introduced).
    writeU32(buf, &pos, m.format_version);
    @memcpy(buf[pos..][0..16], &m.graph_uuid);
    pos += 16;
    writeU32(buf, &pos, m.page_size);
    writeU64(buf, &pos, m.counter);
    writeU64(buf, &pos, m.last_checkpoint_lsn);
    writeU64(buf, &pos, m.node_high_water);
    writeU64(buf, &pos, m.edge_high_water);
    writeU64(buf, &pos, m.next_node_id);
    writeU64(buf, &pos, m.next_edge_id);
    writeU64(buf, &pos, m.next_txn_id);
    writeU32(buf, &pos, m.label_count);
    writeU64(buf, &pos, m.nodes_pages);
    writeU64(buf, &pos, m.adj_out_pages);
    writeU64(buf, &pos, m.adj_in_pages);
    writeU64(buf, &pos, m.props_pages);
    writeU64(buf, &pos, m.var_pages);
    writeU64(buf, &pos, m.free_pages);
    writeU64(buf, &pos, m.node_count);
    writeU64(buf, &pos, m.edge_count);
    writeU64(buf, &pos, m.in_idx_pages);
    writeU64(buf, &pos, m.in_dir_pages);
    // (no checkpoint_epoch) — pos is now SERIALIZED_SIZE_V3 - 4.

    const crc = Crc32.hash(buf[0..pos]);
    writeU32(buf, &pos, crc);

    if (key) |k| {
        var tag: [MANIFEST_HMAC_SIZE]u8 = undefined;
        HmacSha256.create(&tag, buf[0..SERIALIZED_SIZE_V3], &k);
        @memcpy(buf[pos..][0..MANIFEST_HMAC_SIZE], &tag);
        pos += MANIFEST_HMAC_SIZE;
    }

    return buf;
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

test "checkpoint_epoch round-trips through serialize/deserialize" {
    const allocator = std.testing.allocator;
    const m = Manifest{
        .graph_uuid = [_]u8{0x5E} ** 16,
        .counter = 7,
        .checkpoint_epoch = 0xDEAD_BEEF_1234,
    };

    const data = try m.serialize(allocator);
    defer allocator.free(data);

    const m2 = try Manifest.deserialize(allocator, data);
    try std.testing.expectEqual(@as(u64, 0xDEAD_BEEF_1234), m2.checkpoint_epoch);
    // The pre-existing tail field must still survive alongside the new one.
    try std.testing.expectEqual(m.counter, m2.counter);
}

test "A/B selection preserves checkpoint_epoch through serialize/deserialize" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(tmp_path);
    const path_a = try std.fmt.allocPrint(allocator, "{s}/manifest.a", .{tmp_path});
    defer allocator.free(path_a);
    const path_b = try std.fmt.allocPrint(allocator, "{s}/manifest.b", .{tmp_path});
    defer allocator.free(path_b);

    // The stale slot (lower counter) carries a stale epoch; the fresh slot
    // (higher counter) carries the epoch selection must ride along.
    const older = Manifest{ .counter = 5, .checkpoint_epoch = 2 };
    const newer = Manifest{ .counter = 9, .checkpoint_epoch = 3 };
    try older.writeToFile(allocator, path_a);
    try newer.writeToFile(allocator, path_b);

    const a_read = try Manifest.readFromFile(allocator, path_a);
    const b_read = try Manifest.readFromFile(allocator, path_b);
    const sel = try Manifest.selectManifest(a_read, b_read);

    try std.testing.expectEqual(@as(u64, 9), sel.counter);
    try std.testing.expectEqual(@as(u64, 3), sel.checkpoint_epoch);
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

// ============================================================================
// GAP-0053: v3 → v4 manifest upgrade path
// ----------------------------------------------------------------------------
// A store written by v0.2.24..v0.2.28 has a V3 manifest — 176 bytes (208 under
// TDE), 8 bytes SHORTER than V4 (no checkpoint_epoch). deserialize must UPGRADE
// a VALID V3 in-memory (all fields preserved, checkpoint_epoch = 0) while a
// corrupt/forged buffer of either version still fails closed.
// ============================================================================

// A V3 manifest with every field distinct and non-zero so preservation is
// verifiable field-by-field (byte-for-byte through the parse).
fn v3FixtureFields() Manifest {
    return Manifest{
        .format_version = MANIFEST_VERSION_V3,
        .graph_uuid = [_]u8{0x3C} ** 16,
        .page_size = 8192,
        .counter = 7,
        .last_checkpoint_lsn = 0xCAFE_BABE,
        .node_high_water = 111,
        .edge_high_water = 222,
        .next_node_id = 333,
        .next_edge_id = 444,
        .next_txn_id = 555,
        .label_count = 66,
        .nodes_pages = 10,
        .adj_out_pages = 20,
        .adj_in_pages = 30,
        .props_pages = 40,
        .var_pages = 50,
        .free_pages = 60,
        .node_count = 70,
        .edge_count = 80,
        .in_idx_pages = 90,
        .in_dir_pages = 100,
        // checkpoint_epoch intentionally left default (0); V3 has no such field.
    };
}

// Assert every V3 DATA field survived the upgrade byte-for-byte (format_version
// is intentionally bumped 3 -> 4 by the upgrade; checkpoint_epoch defaults 0).
fn expectV3FieldsPreserved(src: Manifest, got: Manifest) !void {
    try std.testing.expectEqual(src.graph_uuid, got.graph_uuid);
    try std.testing.expectEqual(src.page_size, got.page_size);
    try std.testing.expectEqual(src.counter, got.counter);
    try std.testing.expectEqual(src.last_checkpoint_lsn, got.last_checkpoint_lsn);
    try std.testing.expectEqual(src.node_high_water, got.node_high_water);
    try std.testing.expectEqual(src.edge_high_water, got.edge_high_water);
    try std.testing.expectEqual(src.next_node_id, got.next_node_id);
    try std.testing.expectEqual(src.next_edge_id, got.next_edge_id);
    try std.testing.expectEqual(src.next_txn_id, got.next_txn_id);
    try std.testing.expectEqual(src.label_count, got.label_count);
    try std.testing.expectEqual(src.nodes_pages, got.nodes_pages);
    try std.testing.expectEqual(src.adj_out_pages, got.adj_out_pages);
    try std.testing.expectEqual(src.adj_in_pages, got.adj_in_pages);
    try std.testing.expectEqual(src.props_pages, got.props_pages);
    try std.testing.expectEqual(src.var_pages, got.var_pages);
    try std.testing.expectEqual(src.free_pages, got.free_pages);
    try std.testing.expectEqual(src.node_count, got.node_count);
    try std.testing.expectEqual(src.edge_count, got.edge_count);
    try std.testing.expectEqual(src.in_idx_pages, got.in_idx_pages);
    try std.testing.expectEqual(src.in_dir_pages, got.in_dir_pages);
}

test "GAP-0053 v3-upgrade: valid 176-byte V3 manifest upgrades to V4 in-memory" {
    const allocator = std.testing.allocator;
    const src = v3FixtureFields();

    const v3 = try serializeV3Legacy(allocator, src, null);
    defer allocator.free(v3);
    // Byte-exact V3 length (the current bug rejects this at the length gate).
    try std.testing.expectEqual(SERIALIZED_SIZE_V3, v3.len);
    try std.testing.expectEqual(@as(usize, 176), v3.len);

    const got = try Manifest.deserialize(allocator, v3);

    // UPGRADE: version bumped to V4, epoch defaulted to 0, all data preserved.
    try std.testing.expectEqual(MANIFEST_VERSION, got.format_version);
    try std.testing.expectEqual(@as(u32, 4), got.format_version);
    try std.testing.expectEqual(@as(u64, 0), got.checkpoint_epoch);
    try expectV3FieldsPreserved(src, got);

    // Re-serialize: the upgraded manifest persists as a VALID V4 (184 bytes)
    // that round-trips cleanly (auto-migration on the next manifest write).
    const v4 = try got.serialize(allocator);
    defer allocator.free(v4);
    try std.testing.expectEqual(SERIALIZED_SIZE, v4.len);
    try std.testing.expectEqual(@as(usize, 184), v4.len);

    const rt = try Manifest.deserialize(allocator, v4);
    try std.testing.expectEqual(@as(u32, 4), rt.format_version);
    try std.testing.expectEqual(@as(u64, 0), rt.checkpoint_epoch);
    try expectV3FieldsPreserved(src, rt);
}

test "GAP-0053 v3-upgrade: valid 208-byte V3 HMAC manifest upgrades under TDE" {
    const allocator = std.testing.allocator;
    const key = [_]u8{0x53} ** 32;
    const src = v3FixtureFields();

    const v3 = try serializeV3Legacy(allocator, src, key);
    defer allocator.free(v3);
    try std.testing.expectEqual(SERIALIZED_SIZE_V3_HMAC, v3.len);
    try std.testing.expectEqual(@as(usize, 208), v3.len);

    const got = try Manifest.deserializeWithKey(allocator, v3, key);
    try std.testing.expectEqual(@as(u32, 4), got.format_version);
    try std.testing.expectEqual(@as(u64, 0), got.checkpoint_epoch);
    try expectV3FieldsPreserved(src, got);

    // Auto-migrates to a valid V4 HMAC (216 bytes) that round-trips with key.
    const v4 = try got.serializeWithKey(allocator, key);
    defer allocator.free(v4);
    try std.testing.expectEqual(SERIALIZED_SIZE_HMAC, v4.len);
    const rt = try Manifest.deserializeWithKey(allocator, v4, key);
    try std.testing.expectEqual(@as(u32, 4), rt.format_version);
    try expectV3FieldsPreserved(src, rt);
}

test "GAP-0053 v3-upgrade: V3 HMAC with a bad trailer fails closed (no upgrade)" {
    const allocator = std.testing.allocator;
    const key = [_]u8{0x53} ** 32;
    const src = v3FixtureFields();

    const v3 = try serializeV3Legacy(allocator, src, key);
    defer allocator.free(v3);
    // Corrupt one byte of the HMAC trailer (after the V3 CRC-only body).
    v3[SERIALIZED_SIZE_V3 + 4] ^= 0xFF;

    const result = Manifest.deserializeWithKey(allocator, v3, key);
    try std.testing.expectError(error.ManifestAuthFailed, result);
}

test "GAP-0053 v3-upgrade: V3 with a bad CRC fails closed (no heuristic upgrade)" {
    const allocator = std.testing.allocator;
    const src = v3FixtureFields();

    const v3 = try serializeV3Legacy(allocator, src, null);
    defer allocator.free(v3);
    // Flip a field byte WITHOUT recomputing the V3 CRC -> checksum mismatch.
    v3[40] ^= 0xFF;

    const result = Manifest.deserialize(allocator, v3);
    try std.testing.expectError(error.ChecksumMismatch, result);
}

test "GAP-0053 v3-upgrade: 176-byte buffer claiming format_version=4 fails closed" {
    const allocator = std.testing.allocator;
    // Adversarial: V3 LENGTH but the embedded version field says 4. This is
    // impossible for a real store (a V4 binary always writes 184 bytes) and
    // must NOT be treated as a V3 upgrade. The length-based V4 gate rejects it.
    var src = v3FixtureFields();
    src.format_version = MANIFEST_VERSION; // 4, in a 176-byte body
    const buf = try serializeV3Legacy(allocator, src, null);
    defer allocator.free(buf);
    try std.testing.expectEqual(@as(usize, 176), buf.len);

    const result = Manifest.deserialize(allocator, buf);
    try std.testing.expectError(error.InvalidData, result);
}

test "GAP-0053 v3-upgrade: truncated (170-byte) buffer fails closed" {
    const allocator = std.testing.allocator;
    const src = v3FixtureFields();
    const v3 = try serializeV3Legacy(allocator, src, null);
    defer allocator.free(v3);

    // A short read / torn write: neither a V3 (176) nor V4 (184) length.
    const result = Manifest.deserialize(allocator, v3[0..170]);
    try std.testing.expectError(error.InvalidData, result);
}

test "GAP-0053 v3-upgrade: V4-length manifest declaring version 3 is NOT upgraded" {
    const allocator = std.testing.allocator;
    // Downgrade-gate guard at the manifest layer: a 184-byte body whose version
    // field is 3 (forged / impossible) must deserialize AS-IS (format_version
    // stays 3) so recovery's version gate rejects it — it must NOT be silently
    // upgraded to 4. The discriminator keys on LENGTH, not just the field.
    var m = Manifest{ .graph_uuid = [_]u8{0xD0} ** 16, .counter = 3 };
    m.format_version = MANIFEST_VERSION_V3;
    const buf = try m.serialize(allocator); // 184-byte V4 layout, version field 3
    defer allocator.free(buf);
    try std.testing.expectEqual(@as(usize, 184), buf.len);

    const got = try Manifest.deserialize(allocator, buf);
    try std.testing.expectEqual(MANIFEST_VERSION_V3, got.format_version); // NOT bumped to 4
}

test "GAP-0053 v3-upgrade: V4-reads-V4 normal path is unchanged (epoch preserved)" {
    const allocator = std.testing.allocator;
    const m = Manifest{
        .graph_uuid = [_]u8{0x44} ** 16,
        .counter = 12,
        .checkpoint_epoch = 9,
    };
    const buf = try m.serialize(allocator);
    defer allocator.free(buf);
    try std.testing.expectEqual(@as(usize, 184), buf.len);

    const got = try Manifest.deserialize(allocator, buf);
    try std.testing.expectEqual(@as(u32, 4), got.format_version);
    try std.testing.expectEqual(@as(u64, 12), got.counter);
    try std.testing.expectEqual(@as(u64, 9), got.checkpoint_epoch);
}

test {
    std.testing.refAllDecls(@This());
}
