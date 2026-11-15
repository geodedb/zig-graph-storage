// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! SONNY-6590: authenticated encryption of the side files that carry schema
//! names or indexed values when at-rest encryption is on
//! (`GraphConfig.encryption_key`): `labels.dict`, `props.idx`,
//! `ordered_propidx.snap`, `props.catalog` and the `propidx_*.btree` files.
//! The store pages and the WAL were already encrypted; these files were not.
//!
//! Envelope (whole file):
//!
//!   magic(8) = 00 00 00 00 'G' 'S' 'E' 'F'
//!   version(1) = 1 | kind(1) | reserved(2) = 0 | nonce(12)
//!   ciphertext(n)  — the file's former plaintext layout, CRC included
//!   tag(16)
//!
//! Cipher: AES-256-GCM (the page cipher). Key: HKDF-SHA256 of the configured
//! key (salt and info below), so a side file never shares a key with the
//! pages or the WAL and their nonce schemes cannot collide with this one.
//!
//! Nonce: 96 bits from the OS CSPRNG (`Io.randomSecure`) for every write.
//! Side files are rewritten whole (temp + rename, or truncate + write), so
//! there is no stable per-file counter to persist across crashes, restores
//! and copies; a random nonce never repeats a (key, nonce) pair with more
//! than birthday probability: n writes under one key collide with
//! probability < n^2 / 2^97 (2^-33 at n = 2^32, the NIST SP 800-38D limit
//! for random 96-bit nonces; a store writes one side file per new label name
//! per shard and a few per checkpoint). Entropy failure fails the write.
//!
//! Associated data: the 24 header bytes (magic, version, kind, reserved,
//! nonce) + the graph's 16-byte uuid + the file's base name. A file moved to
//! another graph or shard (each shard has its own uuid), to another file
//! name, or presented as another kind fails authentication.
//!
//! Downgrade: the first four bytes are zero, so the <= 0.4.16 labels.dict
//! parser reads an entry count of 0 and then refuses the file
//! (`remaining != 0` → `error.InvalidData`) instead of loading an empty
//! dictionary; the other formats begin with an 8-byte magic that the new
//! magic does not match.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

// The page cipher (see encryption.zig) — a security primitive, not exempt.
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;

pub const MAGIC: [8]u8 = .{ 0, 0, 0, 0, 'G', 'S', 'E', 'F' };
pub const VERSION: u8 = 1;
pub const NONCE_SIZE = Aes256Gcm.nonce_length;
pub const TAG_SIZE = Aes256Gcm.tag_length;
pub const HEADER_SIZE: usize = 8 + 1 + 1 + 2 + NONCE_SIZE; // 24
pub const OVERHEAD: usize = HEADER_SIZE + TAG_SIZE; // 40

const KDF_SALT = "graph-storage side-file key (SONNY-6590)";
const KDF_INFO = "aes-256-gcm v1";

/// What a sealed file holds. Bound into the associated data.
pub const Kind = enum(u8) {
    label_dict = 1,
    prop_chain_index = 2,
    ordered_index = 3,
    index_catalog = 4,
    btree_index = 5,
};

pub const Error = error{
    /// The file is sealed but no encryption key is configured.
    SideFileEncrypted,
    /// Authentication failed: wrong key, a modified file, or a file that
    /// belongs to another graph, shard, file name or kind.
    SideFileAuthFailed,
    /// The file is in the plaintext layout but this store's side files are
    /// sealed (manifest format_version 5 under a key).
    SideFileNotSealed,
    /// Sealed with a version this build does not know.
    SideFileUnsupportedVersion,
    /// Shorter than an envelope.
    SideFileTruncated,
};

/// True when `bytes` starts with the envelope magic.
pub fn isSealed(bytes: []const u8) bool {
    return bytes.len >= MAGIC.len and std.mem.eql(u8, bytes[0..MAGIC.len], &MAGIC);
}

pub const Cipher = struct {
    key: [32]u8,
    graph_uuid: [16]u8,

    /// Derive the side-file key from the configured at-rest key.
    pub fn init(master: [32]u8, graph_uuid: [16]u8) Cipher {
        var prk = HkdfSha256.extract(KDF_SALT, &master);
        defer std.crypto.secureZero(u8, &prk);
        var c = Cipher{ .key = undefined, .graph_uuid = graph_uuid };
        HkdfSha256.expand(&c.key, KDF_INFO, prk);
        return c;
    }

    /// `null` when at-rest encryption is off.
    pub fn forKey(master: ?[32]u8, graph_uuid: [16]u8) ?Cipher {
        const k = master orelse return null;
        return init(k, graph_uuid);
    }

    pub fn deinit(self: *Cipher) void {
        std.crypto.secureZero(u8, &self.key);
    }

    fn associatedData(self: *const Cipher, header: *const [HEADER_SIZE]u8, name: []const u8, buf: []u8) []const u8 {
        @memcpy(buf[0..HEADER_SIZE], header);
        @memcpy(buf[HEADER_SIZE..][0..16], &self.graph_uuid);
        @memcpy(buf[HEADER_SIZE + 16 ..][0..name.len], name);
        return buf[0 .. HEADER_SIZE + 16 + name.len];
    }

    /// Encrypt `plaintext` into a new envelope. `name` is the file's base
    /// name (e.g. "labels.dict"), at most 255 bytes.
    pub fn seal(self: *const Cipher, allocator: Allocator, kind: Kind, name: []const u8, plaintext: []const u8) ![]u8 {
        if (name.len > 255) return error.NameTooLong;
        const out = try allocator.alloc(u8, plaintext.len + OVERHEAD);
        errdefer allocator.free(out);

        const header = out[0..HEADER_SIZE];
        @memcpy(header[0..8], &MAGIC);
        header[8] = VERSION;
        header[9] = @intFromEnum(kind);
        header[10] = 0;
        header[11] = 0;
        const io = std.Io.Threaded.global_single_threaded.io();
        try io.randomSecure(header[12..HEADER_SIZE]);

        var ad_buf: [HEADER_SIZE + 16 + 255]u8 = undefined;
        const ad = self.associatedData(header, name, &ad_buf);
        var tag: [TAG_SIZE]u8 = undefined;
        Aes256Gcm.encrypt(
            out[HEADER_SIZE..][0..plaintext.len],
            &tag,
            plaintext,
            ad,
            header[12..HEADER_SIZE].*,
            self.key,
        );
        @memcpy(out[HEADER_SIZE + plaintext.len ..][0..TAG_SIZE], &tag);
        return out;
    }

    /// Authenticate and decrypt an envelope written by `seal` for the same
    /// graph, `kind` and `name`. Caller owns the returned plaintext.
    pub fn open(self: *const Cipher, allocator: Allocator, kind: Kind, name: []const u8, sealed: []const u8) ![]u8 {
        if (name.len > 255) return error.NameTooLong;
        if (sealed.len < OVERHEAD) return error.SideFileTruncated;
        if (!isSealed(sealed)) return error.SideFileNotSealed;
        const header = sealed[0..HEADER_SIZE];
        if (header[8] != VERSION) return error.SideFileUnsupportedVersion;
        // Kind and reserved bytes are authenticated as well; checking them
        // first only names the failure.
        if (header[9] != @intFromEnum(kind) or header[10] != 0 or header[11] != 0) return error.SideFileAuthFailed;

        const ct_len = sealed.len - OVERHEAD;
        const out = try allocator.alloc(u8, ct_len);
        errdefer allocator.free(out);

        var ad_buf: [HEADER_SIZE + 16 + 255]u8 = undefined;
        const ad = self.associatedData(header, name, &ad_buf);
        Aes256Gcm.decrypt(
            out,
            sealed[HEADER_SIZE..][0..ct_len],
            sealed[HEADER_SIZE + ct_len ..][0..TAG_SIZE].*,
            ad,
            header[12..HEADER_SIZE].*,
            self.key,
        ) catch {
            std.crypto.secureZero(u8, out);
            return error.SideFileAuthFailed;
        };
        return out;
    }
};

/// How to read a side file that may be sealed.
pub const ReadPolicy = struct {
    /// The store's cipher; null when at-rest encryption is off.
    cipher: ?*const Cipher,
    /// Refuse a plaintext file under a cipher (manifest format_version 5).
    /// False only for a store written by <= 0.4.16 that is being upgraded.
    require_sealed: bool,
};

pub const Decoded = struct {
    /// The file's plaintext layout (owned).
    bytes: []u8,
    /// True when the file was in the plaintext layout (to be migrated).
    was_plaintext: bool,
};

/// Turn a side file's on-disk bytes into its plaintext layout under
/// `policy`. Takes ownership of `raw` (returned as-is or freed).
pub fn decode(allocator: Allocator, policy: ReadPolicy, kind: Kind, name: []const u8, raw: []u8) !Decoded {
    if (isSealed(raw)) {
        const c = policy.cipher orelse {
            allocator.free(raw);
            return error.SideFileEncrypted;
        };
        defer allocator.free(raw);
        return .{ .bytes = try c.open(allocator, kind, name, raw), .was_plaintext = false };
    }
    if (policy.cipher != null and policy.require_sealed) {
        allocator.free(raw);
        return error.SideFileNotSealed;
    }
    return .{ .bytes = raw, .was_plaintext = true };
}

/// Encode a plaintext layout for disk: sealed under a cipher, else as-is
/// (copied, so the caller always frees the result).
pub fn encode(allocator: Allocator, cipher: ?*const Cipher, kind: Kind, name: []const u8, plaintext: []const u8) ![]u8 {
    if (cipher) |c| return c.seal(allocator, kind, name, plaintext);
    return allocator.dupe(u8, plaintext);
}

/// Read a whole file. `error.FileNotFound` passes through.
pub fn readWholeFile(allocator: Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return readWholeOpenFile(allocator, file);
}

pub fn readWholeOpenFile(allocator: Allocator, file: std.Io.File) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stat = try file.stat(io);
    const size = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    if (n != size) return error.UnexpectedEndOfFile;
    return buf;
}

/// Write `bytes` to `path` atomically: `<path>.tmp` (owner-only), fsync,
/// rename. The caller fsyncs the directory when the rename must survive
/// power loss.
pub fn writeAtomic(allocator: Allocator, path: []const u8, bytes: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);
    {
        const scoped_file = @import("scoped_file.zig");
        const f = try scoped_file.create(io, tmp_path, .{
            .permissions = std.Io.File.Permissions.fromMode(0o600),
            .resolve_beneath = true,
        });
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
        try f.sync(io);
    }
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

// ---------------------------------------------------------------------------
// Upgrade fault injection (tests only)
// ---------------------------------------------------------------------------

/// TEST-ONLY crash points of the open-time upgrade of a <= 0.4.16 store
/// (engine.zig `sealLegacySideFiles`). A test sets `test_fault`; the open then
/// stops with `error.TestCrashInjected` right after the named step, leaving on
/// disk what a process killed there leaves. `void` outside test builds.
pub const UpgradeStep = enum {
    /// labels.dict.tmp holds the sealed dictionary; labels.dict is still the
    /// plaintext one (killed before the rename).
    label_dict_tmp_written,
    /// labels.dict sealed (renamed + directory fsync).
    label_dict_sealed,
    /// The plaintext props.idx was emptied (rebuilt from pages on use).
    prop_chain_index_dropped,
    /// ordered_propidx.snap rewritten sealed.
    ordered_index_sealed,
    /// props.catalog rewritten sealed.
    catalog_sealed,
    /// Every declared propidx_*.btree rewritten sealed.
    btree_sealed,
};

pub var test_fault: if (builtin.is_test) ?UpgradeStep else void = if (builtin.is_test) null else {};

pub fn faultPoint(step: UpgradeStep) error{TestCrashInjected}!void {
    if (comptime !builtin.is_test) return;
    if (test_fault) |f| {
        if (f == step) return error.TestCrashInjected;
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const TEST_KEY = [_]u8{0x11} ** 32;
const UUID_A = [_]u8{0xA0} ** 16;
const UUID_B = [_]u8{0xB0} ** 16;

test "seal/open round-trips and hides the plaintext" {
    var c = Cipher.init(TEST_KEY, UUID_A);
    defer c.deinit();
    const msg = "PatientLabel\x00ssn";
    const s = try c.seal(testing.allocator, .label_dict, "labels.dict", msg);
    defer testing.allocator.free(s);
    try testing.expect(isSealed(s));
    try testing.expect(std.mem.indexOf(u8, s, "PatientLabel") == null);
    try testing.expectEqual(msg.len + OVERHEAD, s.len);
    const p = try c.open(testing.allocator, .label_dict, "labels.dict", s);
    defer testing.allocator.free(p);
    try testing.expectEqualStrings(msg, p);
}

test "every rewrite uses a fresh nonce" {
    var c = Cipher.init(TEST_KEY, UUID_A);
    defer c.deinit();
    const a = try c.seal(testing.allocator, .label_dict, "labels.dict", "same");
    defer testing.allocator.free(a);
    const b = try c.seal(testing.allocator, .label_dict, "labels.dict", "same");
    defer testing.allocator.free(b);
    try testing.expect(!std.mem.eql(u8, a[12..HEADER_SIZE], b[12..HEADER_SIZE]));
    try testing.expect(!std.mem.eql(u8, a[HEADER_SIZE..], b[HEADER_SIZE..]));
}

test "wrong key, other graph, other name, other kind and any flipped byte fail authentication" {
    var c = Cipher.init(TEST_KEY, UUID_A);
    defer c.deinit();
    const s = try c.seal(testing.allocator, .label_dict, "labels.dict", "names");
    defer testing.allocator.free(s);

    var wrong_key = Cipher.init([_]u8{0x12} ** 32, UUID_A);
    defer wrong_key.deinit();
    try testing.expectError(error.SideFileAuthFailed, wrong_key.open(testing.allocator, .label_dict, "labels.dict", s));
    var other_graph = Cipher.init(TEST_KEY, UUID_B);
    defer other_graph.deinit();
    try testing.expectError(error.SideFileAuthFailed, other_graph.open(testing.allocator, .label_dict, "labels.dict", s));
    try testing.expectError(error.SideFileAuthFailed, c.open(testing.allocator, .label_dict, "props.catalog", s));
    try testing.expectError(error.SideFileAuthFailed, c.open(testing.allocator, .index_catalog, "labels.dict", s));
    for (0..s.len) |i| {
        if (i < MAGIC.len or i == 8) continue; // not an envelope / other version
        const t = try testing.allocator.dupe(u8, s);
        defer testing.allocator.free(t);
        t[i] ^= 0x01;
        try testing.expectError(error.SideFileAuthFailed, c.open(testing.allocator, .label_dict, "labels.dict", t));
    }
}

test "the derived key is not the configured key" {
    var c = Cipher.init(TEST_KEY, UUID_A);
    defer c.deinit();
    try testing.expect(!std.mem.eql(u8, &c.key, &TEST_KEY));
}

test "decode policy: sealed without key, plaintext when sealed is required" {
    var c = Cipher.init(TEST_KEY, UUID_A);
    defer c.deinit();
    const s = try c.seal(testing.allocator, .label_dict, "labels.dict", "x");
    try testing.expectError(error.SideFileEncrypted, decode(testing.allocator, .{ .cipher = null, .require_sealed = false }, .label_dict, "labels.dict", s));
    const p = try testing.allocator.dupe(u8, "plain");
    try testing.expectError(error.SideFileNotSealed, decode(testing.allocator, .{ .cipher = &c, .require_sealed = true }, .label_dict, "labels.dict", p));
    const p2 = try testing.allocator.dupe(u8, "plain");
    const d = try decode(testing.allocator, .{ .cipher = &c, .require_sealed = false }, .label_dict, "labels.dict", p2);
    defer testing.allocator.free(d.bytes);
    try testing.expect(d.was_plaintext);
}

test {
    std.testing.refAllDecls(@This());
}
