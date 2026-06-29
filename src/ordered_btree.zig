// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// H3-P1 Task 1: byte-key ordered B+Tree with a lazy ASC/DESC cursor.
// RED stub — the real implementation lands in the GREEN commit.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const OrderedBTree = struct {
    const Self = @This();

    allocator: Allocator,
    count: usize = 0,

    pub const Entry = struct { key: []const u8, node_id: u64 };

    pub const Cursor = struct {
        pub fn seek(_: *Cursor, _: []const u8) void {}
        pub fn seekToLast(_: *Cursor) void {}
        pub fn next(_: *Cursor) ?Entry {
            return null;
        }
        pub fn prev(_: *Cursor) ?Entry {
            return null;
        }
    };

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn insert(_: *Self, _: []const u8, _: u64) !void {}

    pub fn remove(_: *Self, _: []const u8) bool {
        return false;
    }

    pub fn len(self: *const Self) usize {
        return self.count;
    }

    pub fn cursor(_: *Self) Cursor {
        return .{};
    }

    pub fn serialize(_: *const Self, allocator: Allocator) ![]u8 {
        return allocator.alloc(u8, 0);
    }

    pub fn deserialize(allocator: Allocator, _: []const u8) !Self {
        return Self.init(allocator);
    }
};
