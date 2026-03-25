// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const page_mod = @import("page.zig");

const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

pub const NONCE_SIZE = Aes256Gcm.nonce_length; // 12 bytes
pub const TAG_SIZE = Aes256Gcm.tag_length; // 16 bytes
pub const KEY_SIZE = Aes256Gcm.key_length; // 32 bytes
pub const OVERHEAD = TAG_SIZE;
pub const PAGE_HEADER_SIZE = page_mod.PAGE_HEADER_SIZE;

pub const PageEncryption = struct {
    key: [KEY_SIZE]u8,

    pub fn init(key: [KEY_SIZE]u8) PageEncryption {
        return .{ .key = key };
    }

    /// Build a nonce from page_id and file_id.
    /// Nonce = page_id(8 bytes LE) + file_id(1 byte) + 3 zero bytes = 12 bytes
    pub fn buildNonce(page_id: u64, file_id: u8) [NONCE_SIZE]u8 {
        var nonce: [NONCE_SIZE]u8 = [_]u8{0} ** NONCE_SIZE;
        std.mem.writeInt(u64, nonce[0..8], page_id, .little);
        nonce[8] = file_id;
        return nonce;
    }

    /// Encrypt page body in-place. The header is NOT encrypted (it contains
    /// page_id needed for the nonce). The authentication tag is stored in the
    /// last TAG_SIZE bytes of the body region, so usable body space is reduced
    /// by TAG_SIZE when encryption is enabled. The header is included as
    /// additional authenticated data, binding the ciphertext to its header.
    pub fn encryptPage(self: *const PageEncryption, page_buf: []u8, page_id: u64, file_id: u8) void {
        std.debug.assert(page_buf.len > PAGE_HEADER_SIZE + TAG_SIZE);

        const header_slice = page_buf[0..PAGE_HEADER_SIZE];
        const body = page_buf[PAGE_HEADER_SIZE..];
        const nonce = buildNonce(page_id, file_id);

        const plaintext_len = body.len - TAG_SIZE;
        const plaintext = body[0..plaintext_len];
        var tag: [TAG_SIZE]u8 = undefined;

        // Encrypt in-place: ciphertext written over plaintext buffer
        Aes256Gcm.encrypt(
            plaintext, // ciphertext output (in-place)
            &tag,
            plaintext, // plaintext input
            header_slice, // additional authenticated data
            nonce,
            self.key,
        );

        // Append tag at end of body
        @memcpy(body[plaintext_len..][0..TAG_SIZE], &tag);
    }

    /// Decrypt page body in-place. Verifies the authentication tag which
    /// covers both the header (as AD) and the body ciphertext. Returns
    /// error.DecryptionFailed if the tag does not match (wrong key, wrong
    /// page_id/file_id, or data corruption).
    pub fn decryptPage(self: *const PageEncryption, page_buf: []u8, page_id: u64, file_id: u8) !void {
        std.debug.assert(page_buf.len > PAGE_HEADER_SIZE + TAG_SIZE);

        const header_slice = page_buf[0..PAGE_HEADER_SIZE];
        const body = page_buf[PAGE_HEADER_SIZE..];
        const nonce = buildNonce(page_id, file_id);

        const ciphertext_len = body.len - TAG_SIZE;
        const ciphertext = body[0..ciphertext_len];
        const tag: [TAG_SIZE]u8 = body[ciphertext_len..][0..TAG_SIZE].*;

        Aes256Gcm.decrypt(
            ciphertext, // plaintext output (in-place)
            ciphertext, // ciphertext input
            tag,
            header_slice, // additional authenticated data
            nonce,
            self.key,
        ) catch return error.DecryptionFailed;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

fn makeTestPage(page_id: u64, fill: u8, page_size: u32) []u8 {
    const buf = testing.allocator.alloc(u8, page_size) catch unreachable;
    @memset(buf, 0);

    // Write header
    const header = page_mod.initHeader(page_id, .node_data, page_size);
    const header_bytes = page_mod.headerToBytes(&header);
    @memcpy(buf[0..PAGE_HEADER_SIZE], header_bytes);

    // Fill body (excluding tag area) with pattern
    const body_start = PAGE_HEADER_SIZE;
    const body_end = page_size - TAG_SIZE;
    @memset(buf[body_start..body_end], fill);

    return buf;
}

test "encrypt + decrypt round-trip — body matches original" {
    const page_size: u32 = 4096;
    const page_id: u64 = 42;
    const file_id: u8 = 1;
    const fill: u8 = 0xAB;

    const key = [_]u8{0x01} ** KEY_SIZE;
    const enc = PageEncryption.init(key);

    // Create page and save original body
    const buf = makeTestPage(page_id, fill, page_size);
    defer testing.allocator.free(buf);

    const original_body = try testing.allocator.alloc(u8, page_size - PAGE_HEADER_SIZE - TAG_SIZE);
    defer testing.allocator.free(original_body);
    @memcpy(original_body, buf[PAGE_HEADER_SIZE .. page_size - TAG_SIZE]);

    // Encrypt then decrypt
    enc.encryptPage(buf, page_id, file_id);

    // After encryption, body should differ from original
    const encrypted_body = buf[PAGE_HEADER_SIZE .. page_size - TAG_SIZE];
    try testing.expect(!std.mem.eql(u8, original_body, encrypted_body));

    try enc.decryptPage(buf, page_id, file_id);

    // After decryption, body should match original
    const decrypted_body = buf[PAGE_HEADER_SIZE .. page_size - TAG_SIZE];
    try testing.expectEqualSlices(u8, original_body, decrypted_body);
}

test "page-swap detection — wrong page_id fails decryption" {
    const page_size: u32 = 4096;
    const file_id: u8 = 0;

    const key = [_]u8{0x02} ** KEY_SIZE;
    const enc = PageEncryption.init(key);

    const buf = makeTestPage(1, 0xCC, page_size);
    defer testing.allocator.free(buf);

    // Encrypt as page 1
    enc.encryptPage(buf, 1, file_id);

    // Attempt to decrypt as page 2 — must fail
    const result = enc.decryptPage(buf, 2, file_id);
    try testing.expectError(error.DecryptionFailed, result);
}

test "wrong key fails decryption" {
    const page_size: u32 = 4096;
    const page_id: u64 = 10;
    const file_id: u8 = 3;

    const key1 = [_]u8{0x10} ** KEY_SIZE;
    const key2 = [_]u8{0x20} ** KEY_SIZE;
    const enc1 = PageEncryption.init(key1);
    const enc2 = PageEncryption.init(key2);

    const buf = makeTestPage(page_id, 0xDD, page_size);
    defer testing.allocator.free(buf);

    enc1.encryptPage(buf, page_id, file_id);

    // Decrypt with wrong key — must fail
    const result = enc2.decryptPage(buf, page_id, file_id);
    try testing.expectError(error.DecryptionFailed, result);
}

test "header preserved — encryption does not modify header bytes" {
    const page_size: u32 = 4096;
    const page_id: u64 = 7;
    const file_id: u8 = 2;

    const key = [_]u8{0x03} ** KEY_SIZE;
    const enc = PageEncryption.init(key);

    const buf = makeTestPage(page_id, 0xEE, page_size);
    defer testing.allocator.free(buf);

    // Save original header
    var original_header: [PAGE_HEADER_SIZE]u8 = undefined;
    @memcpy(&original_header, buf[0..PAGE_HEADER_SIZE]);

    enc.encryptPage(buf, page_id, file_id);

    // Header must be unchanged
    try testing.expectEqualSlices(u8, &original_header, buf[0..PAGE_HEADER_SIZE]);
}

test "buildNonce produces deterministic output" {
    const n1 = PageEncryption.buildNonce(42, 3);
    const n2 = PageEncryption.buildNonce(42, 3);
    try testing.expectEqualSlices(u8, &n1, &n2);
}

test "buildNonce differs for different page_id" {
    const n1 = PageEncryption.buildNonce(1, 0);
    const n2 = PageEncryption.buildNonce(2, 0);
    try testing.expect(!std.mem.eql(u8, &n1, &n2));
}

test "buildNonce differs for different file_id" {
    const n1 = PageEncryption.buildNonce(1, 0);
    const n2 = PageEncryption.buildNonce(1, 1);
    try testing.expect(!std.mem.eql(u8, &n1, &n2));
}

test {
    std.testing.refAllDecls(@This());
}
