// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Derive a deterministic per-shard 16-byte UUID from the parent
//! graph UUID and the shard index. Uses BLAKE3 via std.crypto for
//! collision resistance.

const std = @import("std");

pub fn deriveShardUuid(parent: [16]u8, shard_index: usize) [16]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(&parent);
    var tag_buf: [16]u8 = undefined;
    const tag = std.fmt.bufPrint(&tag_buf, "shard_{d:0>2}", .{shard_index}) catch unreachable;
    hasher.update(tag);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var out: [16]u8 = undefined;
    @memcpy(&out, digest[0..16]);
    return out;
}

test {
    std.testing.refAllDecls(@This());
}

test "deriveShardUuid is deterministic and shard-distinct" {
    const parent: [16]u8 = .{0xA1} ** 16;
    const shard0 = @import("shard_uuid.zig").deriveShardUuid(parent, 0);
    const shard0_again = @import("shard_uuid.zig").deriveShardUuid(parent, 0);
    const shard1 = @import("shard_uuid.zig").deriveShardUuid(parent, 1);

    try std.testing.expectEqualSlices(u8, &shard0, &shard0_again);
    try std.testing.expect(!std.mem.eql(u8, &shard0, &shard1));
}

test "deriveShardUuid differs across parents for the same shard" {
    const a: [16]u8 = .{0xA1} ** 16;
    const b: [16]u8 = .{0xB2} ** 16;
    const shard0_a = @import("shard_uuid.zig").deriveShardUuid(a, 0);
    const shard0_b = @import("shard_uuid.zig").deriveShardUuid(b, 0);
    try std.testing.expect(!std.mem.eql(u8, &shard0_a, &shard0_b));
}
