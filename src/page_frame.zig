// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const types = @import("types.zig");

pub const PageId = types.PageId;
pub const FileId = types.FileId;
pub const Lsn = types.Lsn;

/// A buffer pool frame holding one page's data in memory.
pub const PageFrame = struct {
    file_id: FileId,
    page_id: PageId,
    data: [*]u8, // pointer into the buffer pool's contiguous allocation
    page_size: u32, // so we know the slice length
    pin_count: u32 = 0,
    dirty: bool = false,
    loading: bool = false,
    // True while this frame is being torn down for reuse by eviction: its
    // dirty bytes are being flushed to disk with the pool mutex dropped, after
    // which the frame is repurposed for a different page. A frame in this state
    // must NOT be pinned or aliased by a concurrent `pin` of the SAME page (the
    // page is about to disappear) and must NOT be chosen as a victim by another
    // eviction. See BufferPool.evictFrame / pin / isEvictable. Always mutated
    // under the pool mutex.
    evicting: bool = false,
    valid: bool = false, // true if frame contains actual page data (not empty slot)
    lsn: Lsn = 0,
    // LRU doubly-linked list pointers (index-based, not pointer-based)
    lru_prev: ?u32 = null, // index into frames array
    lru_next: ?u32 = null, // index into frames array

    /// Get the page data as a slice.
    pub fn dataSlice(self: *const PageFrame) []u8 {
        return self.data[0..self.page_size];
    }

    /// Check if this frame can be evicted (unpinned).
    ///
    /// A frame already being torn down by another eviction (`evicting`) is not
    /// a valid victim: a second concurrent eviction must skip it so it never
    /// flushes/repurposes a frame whose teardown is already in flight.
    pub fn isEvictable(self: *const PageFrame) bool {
        return self.pin_count == 0 and self.valid and !self.loading and !self.evicting;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "PageFrame dataSlice returns correct length" {
    var buf: [4096]u8 = undefined;
    @memset(&buf, 0xAB);

    var frame = PageFrame{
        .file_id = .nodes,
        .page_id = 0,
        .data = &buf,
        .page_size = 4096,
    };

    const slice = frame.dataSlice();
    try testing.expectEqual(@as(usize, 4096), slice.len);
    try testing.expectEqual(@as(u8, 0xAB), slice[0]);
    try testing.expectEqual(@as(u8, 0xAB), slice[4095]);
}

test "PageFrame isEvictable returns true when unpinned and valid" {
    var buf: [4096]u8 = undefined;
    var frame = PageFrame{
        .file_id = .nodes,
        .page_id = 0,
        .data = &buf,
        .page_size = 4096,
        .pin_count = 0,
        .valid = true,
    };

    try testing.expect(frame.isEvictable());
}

test "PageFrame isEvictable returns false when pinned" {
    var buf: [4096]u8 = undefined;
    var frame = PageFrame{
        .file_id = .nodes,
        .page_id = 0,
        .data = &buf,
        .page_size = 4096,
        .pin_count = 1,
        .valid = true,
    };

    try testing.expect(!frame.isEvictable());
}

test "PageFrame isEvictable returns false when not valid" {
    var buf: [4096]u8 = undefined;
    var frame = PageFrame{
        .file_id = .nodes,
        .page_id = 0,
        .data = &buf,
        .page_size = 4096,
        .pin_count = 0,
        .valid = false,
    };

    try testing.expect(!frame.isEvictable());
}

test "PageFrame default values" {
    var buf: [4096]u8 = undefined;
    const frame = PageFrame{
        .file_id = .nodes,
        .page_id = 42,
        .data = &buf,
        .page_size = 4096,
    };

    try testing.expectEqual(@as(u32, 0), frame.pin_count);
    try testing.expect(!frame.dirty);
    try testing.expect(!frame.loading);
    try testing.expect(!frame.valid);
    try testing.expectEqual(@as(Lsn, 0), frame.lsn);
    try testing.expectEqual(@as(?u32, null), frame.lru_prev);
    try testing.expectEqual(@as(?u32, null), frame.lru_next);
}

test {
    std.testing.refAllDecls(@This());
}
