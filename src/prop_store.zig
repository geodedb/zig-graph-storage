// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const types = @import("types.zig");
const page_mod = @import("page.zig");
const property_mod = @import("property.zig");
const buffer_pool_mod = @import("buffer_pool.zig");
const free_space_mod = @import("free_space.zig");
const var_store_mod = @import("var_store.zig");
const interface_mod = @import("interface.zig");

const Allocator = std.mem.Allocator;
const BufferPool = buffer_pool_mod.BufferPool;
const FreeSpaceManager = free_space_mod.FreeSpaceManager;
const VarStore = var_store_mod.VarStore;
const PropertyValue = types.PropertyValue;
const PropertyEntry = interface_mod.PropertyEntry;
const PageId = types.PageId;
const PAGE_HEADER_SIZE = page_mod.PAGE_HEADER_SIZE;

/// Property page metadata offsets (after PAGE_HEADER_SIZE):
/// - [0..8): next_page (u64), pointer to overflow property page
/// - [8..12): entry_count (u32), number of property entries on this page
/// - [12..): entries, each: key_len(2) + key_bytes + encoded_value_bytes
const PROP_META_SIZE: u32 = 12; // next_page(8) + entry_count(4)
const PROP_DATA_OFFSET: u32 = PAGE_HEADER_SIZE + PROP_META_SIZE;

/// Maximum hops allowed in a page chain traversal before assuming corruption.
const MAX_CHAIN_HOPS: u32 = 100_000;

/// Per-page property key directory (PERF-0023).
/// The directory grows backward from the end of each page and maps key hashes
/// to entry offsets for O(1) lookup within a page.
///
/// Page layout:
///   [PageHeader 32B] [meta 12B] [entries → ...free space... ← directory] [dir_count 2B]
///
/// Each directory entry is 4 bytes: [key_hash: u16] [entry_offset: u16].
/// dir_count (u16) is stored in the last 2 bytes of the page.
/// When dir_count == 0 the page is in legacy format and falls back to linear scan.
const DIR_ENTRY_SIZE: u32 = 4; // u16 hash + u16 offset
const DIR_COUNT_SIZE: u32 = 2; // u16 at end of page

/// Compute a 16-bit hash of a property key using FNV-1a.
fn keyHash(key: []const u8) u16 {
    var h: u32 = 2166136261;
    for (key) |b| {
        h ^= b;
        h *%= 16777619;
    }
    return @truncate(h);
}

/// Read the directory entry count from the last 2 bytes of a page.
fn readDirCount(data: []const u8) u16 {
    return std.mem.readInt(u16, data[data.len - DIR_COUNT_SIZE ..][0..DIR_COUNT_SIZE], .little);
}

/// Read dir_count with bounds validation: the directory region (dir_count
/// entries + the 2-byte count field) must fit entirely within the data
/// region that follows PROP_DATA_OFFSET. A corrupt or adversarially crafted
/// page with an inflated dir_count would otherwise cause an integer underflow
/// in readDirEntry's base-address calculation (OOB read in ReleaseFast,
/// panic in ReleaseSafe). SEC-0039.
fn readDirCountChecked(data: []const u8) error{DataCorruption}!u16 {
    const dir_count = readDirCount(data);
    if (dir_count == 0) return 0;
    // Ensure dirOverhead(dir_count) + PROP_DATA_OFFSET <= data.len
    const overhead = dirOverhead(dir_count);
    if (PROP_DATA_OFFSET + overhead > data.len) return error.DataCorruption;
    return dir_count;
}

/// Write the directory entry count to the last 2 bytes of a page.
fn writeDirCount(data: []u8, count: u16) void {
    std.mem.writeInt(u16, data[data.len - DIR_COUNT_SIZE ..][0..DIR_COUNT_SIZE], count, .little);
}

/// Read a directory entry by index (0-based, growing backward from end).
fn readDirEntry(data: []const u8, idx: u16) struct { hash: u16, offset: u16 } {
    const base = data.len - DIR_COUNT_SIZE - (@as(usize, idx) + 1) * DIR_ENTRY_SIZE;
    return .{
        .hash = std.mem.readInt(u16, data[base..][0..2], .little),
        .offset = std.mem.readInt(u16, data[base + 2 ..][0..2], .little),
    };
}

/// Write a directory entry at the given index.
fn writeDirEntry(data: []u8, idx: u16, hash: u16, offset: u16) void {
    const base = data.len - DIR_COUNT_SIZE - (@as(usize, idx) + 1) * DIR_ENTRY_SIZE;
    std.mem.writeInt(u16, data[base..][0..2], hash, .little);
    std.mem.writeInt(u16, data[base + 2 ..][0..2], offset, .little);
}

/// Compute the total directory overhead for a given entry count.
fn dirOverhead(dir_count: u16) u32 {
    return DIR_COUNT_SIZE + @as(u32, dir_count) * DIR_ENTRY_SIZE;
}

/// Slotted-page property storage with overflow.
/// For v1, uses a simple sequential layout within each property page.
pub const PropStore = struct {
    buffer_pool: *BufferPool,
    free_space: *FreeSpaceManager,
    var_store: *VarStore,
    page_size: u32,
    /// Bytes reserved at the tail of every physical property page for the
    /// page-level AES-GCM authentication tag when at-rest encryption is
    /// enabled. The slotted-page directory (dir_count + dir entries) grows
    /// backward from the LOGICAL page end (page_size - tail_reserve), so it
    /// never collides with the tag that the pager writes into the final
    /// `tail_reserve` bytes on flush. Set to the encryption tag size when a
    /// key is configured, 0 otherwise.
    ///
    /// SEC: Without this reservation the directory footer and the AES-GCM tag
    /// share the last bytes of the page. Within a session reads hit the
    /// decrypted in-memory frame, but after a restart the page is read from
    /// disk where the tag has overwritten dir_count — producing a garbage
    /// count and an integer-overflow panic in readDirEntry. Reserving the tag
    /// tail keeps the directory inside the encrypted body so it round-trips.
    /// Plaintext mode keeps tail_reserve == 0 for backward compatibility.
    tail_reserve: u32 = 0,

    pub fn init(buffer_pool: *BufferPool, free_space: *FreeSpaceManager, var_store: *VarStore, page_size: u32) PropStore {
        return .{
            .buffer_pool = buffer_pool,
            .free_space = free_space,
            .var_store = var_store,
            .page_size = page_size,
            .tail_reserve = 0,
        };
    }

    /// Trim a physical page buffer to the logical region usable by the
    /// slotted-page layout, excluding the reserved encryption-tag tail.
    /// All directory and entry math operates on this logical slice so the
    /// directory footer stays clear of the AES-GCM tag region.
    inline fn logical(self: *const PropStore, data: []u8) []u8 {
        return data[0 .. data.len - self.tail_reserve];
    }

    /// Usable data bytes per property page (excluding the dir_count footer
    /// and the reserved encryption-tag tail).
    /// The actual available space also depends on the number of directory
    /// entries; callers must subtract dirOverhead(dir_count) separately.
    fn dataCapacity(self: *const PropStore) u32 {
        return self.page_size - PROP_DATA_OFFSET - DIR_COUNT_SIZE - self.tail_reserve;
    }

    /// Get a property value by key from a property page chain.
    /// Returns null if not found.
    ///
    /// PERF-0023: When a per-page key directory is present (dir_count > 0),
    /// the search key is hashed and looked up in the directory for O(1) access.
    /// Falls back to linear scan for legacy pages or on hash collision miss.
    pub fn getProperty(self: *PropStore, prop_head: u64, key: []const u8, allocator: Allocator) !?PropertyValue {
        if (prop_head == 0) return null;

        var current_page: PageId = prop_head;
        var chain_hops: u32 = 0;
        while (current_page != 0) : (chain_hops += 1) {
            if (chain_hops >= MAX_CHAIN_HOPS) return error.CircularChainDetected;
            const frame = try self.buffer_pool.pin(.props, current_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const data = self.logical(frame.dataSlice());

            const next_page = readNextPage(data);
            const entry_count = readEntryCountChecked(data, self.page_size) catch {
                self.buffer_pool.unpin(frame_idx, false);
                return error.DataCorruption;
            };

            // PERF-0023: Try directory-based lookup first.
            const dir_count = readDirCountChecked(data) catch {
                self.buffer_pool.unpin(frame_idx, false);
                return error.DataCorruption;
            };
            if (dir_count > 0) {
                const target_hash = keyHash(key);
                var di: u16 = 0;
                while (di < dir_count) : (di += 1) {
                    const entry = readDirEntry(data, di);
                    if (entry.hash == target_hash) {
                        // Candidate match — verify the actual key at the stored offset.
                        const off = @as(u32, entry.offset);
                        if (off + 2 <= data.len) {
                            const key_len = std.mem.bytesToValue(u16, data[off..][0..2]);
                            if (off + 2 + key_len <= data.len) {
                                const entry_key = data[off + 2 ..][0..key_len];
                                if (std.mem.eql(u8, entry_key, key)) {
                                    const val_start = off + 2 + key_len;
                                    const decode_result = try property_mod.decode(allocator, data[val_start..]);
                                    self.buffer_pool.unpin(frame_idx, false);
                                    return decode_result.value;
                                }
                            }
                        }
                        // Hash collision — continue scanning directory entries.
                    }
                }
                // If directory was present but key not found, skip to next page
                // (no need to linear-scan since directory is authoritative).
                self.buffer_pool.unpin(frame_idx, false);
                current_page = next_page;
                continue;
            }

            // Legacy path: linear scan when dir_count == 0.
            var offset: u32 = PROP_DATA_OFFSET;
            var i: u32 = 0;
            while (i < entry_count) : (i += 1) {
                if (offset + 2 > data.len) return error.DataCorruption;
                const key_len = std.mem.bytesToValue(u16, data[offset..][0..2]);
                offset += 2;
                if (offset + key_len > data.len) return error.DataCorruption;
                const entry_key = data[offset..][0..key_len];
                offset += key_len;

                if (std.mem.eql(u8, entry_key, key)) {
                    // Found it — decode the value
                    const decode_result = try property_mod.decode(allocator, data[offset..]);
                    self.buffer_pool.unpin(frame_idx, false);
                    return decode_result.value;
                }

                // Not the key we want: skip value by encoded size (no heap alloc)
                const val_size = try encodedSizeFromBytes(data[offset..]);
                offset += @intCast(val_size);
            }

            self.buffer_pool.unpin(frame_idx, false);
            current_page = next_page;
        }

        return null;
    }

    pub const PropertyEntrySlice = struct {
        key: []const u8,
        encoded_value: []const u8,
    };

    /// Zero-allocation iterator over property entries in a page chain.
    ///
    /// **Lifetime:** Returned `PropertyEntrySlice` values contain slices that
    /// point directly into pinned buffer pool frames. These slices become
    /// invalid after the next call to `next()` (which may unpin the current
    /// frame and pin a new one) or after `deinit()` is called. Callers must
    /// copy any key or encoded_value data they need to retain beyond the
    /// current iteration step.
    pub const PropIterator = struct {
        store: *PropStore,
        current_page: u64,
        current_frame_idx: ?u32 = null,
        current_index: u32 = 0,
        current_offset: u32 = PROP_DATA_OFFSET,
        entry_count_cache: u32 = 0,

        pub fn deinit(self: *PropIterator) void {
            if (self.current_frame_idx) |idx| {
                self.store.buffer_pool.unpin(idx, false);
                self.current_frame_idx = null;
            }
        }

        pub fn next(self: *PropIterator) anyerror!?PropertyEntrySlice {
            while (self.current_page != 0) {
                if (self.current_frame_idx == null) {
                    const frame = try self.store.buffer_pool.pin(.props, self.current_page);
                    self.current_frame_idx = self.store.buffer_pool.frameIndex(frame);
                    const data = self.store.logical(frame.dataSlice());
                    self.entry_count_cache = try readEntryCountChecked(data, self.store.page_size);
                    self.current_offset = PROP_DATA_OFFSET;
                }

                const frame = &self.store.buffer_pool.frames[self.current_frame_idx.?];
                const data = self.store.logical(frame.dataSlice());

                if (self.current_index < self.entry_count_cache) {
                    if (self.current_offset + 2 > data.len) return error.DataCorruption;
                    const key_len = std.mem.bytesToValue(u16, data[self.current_offset..][0..2]);
                    self.current_offset += 2;
                    if (self.current_offset + key_len > data.len) return error.DataCorruption;

                    const entry_key = data[self.current_offset..][0..key_len];
                    self.current_offset += key_len;

                    const val_size = try encodedSizeFromBytes(data[self.current_offset..]);
                    const encoded_val = data[self.current_offset..][0..val_size];
                    self.current_offset += @intCast(val_size);

                    self.current_index += 1;

                    return PropertyEntrySlice{
                        .key = entry_key,
                        .encoded_value = encoded_val,
                    };
                }

                const next_page = readNextPage(data);
                self.store.buffer_pool.unpin(self.current_frame_idx.?, false);
                self.current_frame_idx = null;
                self.current_page = next_page;
                self.current_index = 0;
                self.current_offset = PROP_DATA_OFFSET;
            }

            return null;
        }
    };

    /// Get an iterator over all properties in a property page chain (zero allocation).
    pub fn getAllProperties(self: *PropStore, prop_head: u64) PropIterator {
        return .{
            .store = self,
            .current_page = prop_head,
        };
    }

    /// Put a property. Returns the (possibly new) prop_head.
    /// If the key already exists, it is replaced (remove + re-add).
    ///
    /// PERF-0002: Combined find-and-remove pass reduces 3 chain traversals
    /// to at most 2 (find+remove in pass 1, insert in pass 2).
    /// QUAL-0026: Decomposed into findAndRemoveKey + insertEntry helpers.
    pub fn putProperty(self: *PropStore, prop_head: u64, key: []const u8, val: PropertyValue) !u64 {
        if (key.len > std.math.maxInt(u16)) return error.PropertyKeyTooLong;

        // PERF-0022: Use a stack buffer for small fixed-size types to avoid
        // heap allocation on every putProperty call.
        var stack_buf: [32]u8 = undefined;
        const size = property_mod.encodedSize(val);
        var heap_alloc: ?[]const u8 = null;
        const encoded_val: []const u8 = if (size <= stack_buf.len) blk: {
            const n = property_mod.encodeInto(&stack_buf, val) catch unreachable;
            break :blk stack_buf[0..n];
        } else blk: {
            const h = try property_mod.encode(self.buffer_pool.allocator, val);
            heap_alloc = h;
            break :blk h;
        };
        defer if (heap_alloc) |h| self.buffer_pool.allocator.free(h);

        const entry_size: u32 = 2 + @as(u32, @intCast(key.len)) + @as(u32, @intCast(encoded_val.len));

        if (prop_head == 0) {
            // Allocate new property page
            const new_page = try self.free_space.allocPage();
            const frame = try self.buffer_pool.pinNew(.props, new_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const data = self.logical(frame.dataSlice());

            writeNextPage(data, 0);
            writeEntryCount(data, 1);
            self.writePropertyEntry(data, PROP_DATA_OFFSET, key, encoded_val);

            // PERF-0023: Initialize directory with the first entry.
            writeDirCount(data, 1);
            writeDirEntry(data, 0, keyHash(key), PROP_DATA_OFFSET);

            self.buffer_pool.unpin(frame_idx, true);
            return new_page;
        }

        // Pass 1: find and remove existing key. If the key is found and
        // there is enough space on the same page, inserts immediately
        // (PERF-0021 fast path) and returns the prop_head directly.
        if (try self.findAndRemoveKey(prop_head, key, encoded_val, entry_size)) |head| {
            return head;
        }

        // Pass 2: insert the new entry into the first page with space,
        // allocating an overflow page if necessary.
        return try self.insertEntry(prop_head, key, encoded_val, entry_size);
    }

    /// Pass 1: Scan the chain to find and remove an existing key.
    /// Returns prop_head if the entry was removed and re-inserted on the
    /// same page (PERF-0021 fast path), or null if Pass 2 is needed.
    fn findAndRemoveKey(
        self: *PropStore,
        prop_head: u64,
        key: []const u8,
        encoded_val: []const u8,
        entry_size: u32,
    ) !?u64 {
        var current_page: PageId = prop_head;
        var chain_hops: u32 = 0;
        while (current_page != 0) : (chain_hops += 1) {
            if (chain_hops >= MAX_CHAIN_HOPS) return error.CircularChainDetected;
            const frame = try self.buffer_pool.pin(.props, current_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const data = self.logical(frame.dataSlice());

            const next_page = readNextPage(data);
            var entry_count = readEntryCountChecked(data, self.page_size) catch {
                self.buffer_pool.unpin(frame_idx, false);
                return error.DataCorruption;
            };

            if (try self.findEntrySpan(data, entry_count, key)) |span| {
                const removal = try self.removeEntryAt(data, entry_count, span);
                entry_count = removal.entry_count;

                // PERF-0021: Check if freed space is enough for the new entry.
                const used_after_remove = removal.new_end - PROP_DATA_OFFSET;
                const new_dir_size = @as(u32, entry_count + 1) * DIR_ENTRY_SIZE;
                const available = self.dataCapacity() -| (used_after_remove + new_dir_size);
                if (available >= entry_size) {
                    self.writePropertyEntry(data, removal.new_end, key, encoded_val);
                    writeEntryCount(data, entry_count + 1);
                    rebuildDirectory(data, entry_count + 1, self.page_size);
                    self.buffer_pool.unpin(frame_idx, true);
                    return prop_head;
                }

                writeEntryCount(data, entry_count);
                rebuildDirectory(data, entry_count, self.page_size);
                self.buffer_pool.unpin(frame_idx, true);

                // Key removed but page too full; caller needs Pass 2.
                return null;
            } else {
                self.buffer_pool.unpin(frame_idx, false);
                current_page = next_page;
                continue;
            }
        }
        // Key not found anywhere in chain; Pass 2 will insert.
        return null;
    }

    /// Pass 2: Find space in the chain and insert the new entry.
    /// Allocates an overflow page if no existing page has room.
    fn insertEntry(
        self: *PropStore,
        prop_head: u64,
        key: []const u8,
        encoded_val: []const u8,
        entry_size: u32,
    ) !u64 {
        var current_page: PageId = prop_head;
        var chain_hops: u32 = 0;
        while (current_page != 0) : (chain_hops += 1) {
            if (chain_hops >= MAX_CHAIN_HOPS) return error.CircularChainDetected;
            const frame = try self.buffer_pool.pin(.props, current_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const data = self.logical(frame.dataSlice());

            const next_page = readNextPage(data);
            const entry_count = readEntryCountChecked(data, self.page_size) catch {
                self.buffer_pool.unpin(frame_idx, false);
                return error.DataCorruption;
            };

            const used = try self.usedBytes(data, entry_count);
            const new_dir_size = @as(u32, entry_count + 1) * DIR_ENTRY_SIZE;
            const available = self.dataCapacity() -| (used + new_dir_size);

            if (available >= entry_size) {
                const write_offset = PROP_DATA_OFFSET + used;
                self.writePropertyEntry(data, write_offset, key, encoded_val);
                writeEntryCount(data, entry_count + 1);

                // PERF-0038: Append a single directory entry.
                const new_count: u16 = @intCast(entry_count + 1);
                writeDirCount(data, new_count);
                writeDirEntry(data, @intCast(entry_count), keyHash(key), @intCast(write_offset));

                self.buffer_pool.unpin(frame_idx, true);
                return prop_head;
            }

            if (next_page == 0) {
                // Allocate overflow page.
                const new_page = try self.free_space.allocPage();
                const new_frame = try self.buffer_pool.pinNew(.props, new_page);
                const new_frame_idx = self.buffer_pool.frameIndex(new_frame);
                const new_data = self.logical(new_frame.dataSlice());

                writeNextPage(new_data, 0);
                writeEntryCount(new_data, 1);
                self.writePropertyEntry(new_data, PROP_DATA_OFFSET, key, encoded_val);

                writeDirCount(new_data, 1);
                writeDirEntry(new_data, 0, keyHash(key), PROP_DATA_OFFSET);

                self.buffer_pool.unpin(new_frame_idx, true);

                writeNextPage(data, new_page);
                self.buffer_pool.unpin(frame_idx, true);
                return prop_head;
            }

            self.buffer_pool.unpin(frame_idx, false);
            current_page = next_page;
        }

        return error.DataCorruption;
    }

    /// Remove a property by key. Scans all pages in the chain.
    /// Compacts the page by shifting remaining entries forward.
    pub fn removeProperty(self: *PropStore, prop_head: u64, key: []const u8) !void {
        if (prop_head == 0) return;

        var current_page: PageId = prop_head;
        var chain_hops: u32 = 0;
        while (current_page != 0) : (chain_hops += 1) {
            if (chain_hops >= MAX_CHAIN_HOPS) return error.CircularChainDetected;
            const frame = try self.buffer_pool.pin(.props, current_page);
            const frame_idx = self.buffer_pool.frameIndex(frame);
            const data = self.logical(frame.dataSlice());

            const next_page = readNextPage(data);
            const entry_count = readEntryCountChecked(data, self.page_size) catch {
                self.buffer_pool.unpin(frame_idx, false);
                return error.DataCorruption;
            };

            if (try self.findEntrySpan(data, entry_count, key)) |span| {
                const removal = try self.removeEntryAt(data, entry_count, span);
                writeEntryCount(data, removal.entry_count);
                rebuildDirectory(data, removal.entry_count, self.page_size);
                self.buffer_pool.unpin(frame_idx, true);
                return;
            }

            self.buffer_pool.unpin(frame_idx, false);
            current_page = next_page;
        }
    }

    // Internal helpers

    const EntryCursor = struct {
        offset: u32 = PROP_DATA_OFFSET,
    };

    const ParsedEntry = struct {
        key: []const u8,
        value_offset: u32,
        value_size: usize,
    };

    const EntrySpan = struct {
        index: u32,
        start: u32,
        end: u32,
    };

    const RemovalResult = struct {
        entry_count: u32,
        new_end: u32,
        total_used: u32,
    };

    fn readEntryAt(_: *const PropStore, data: []const u8, cursor: *EntryCursor) !ParsedEntry {
        if (cursor.offset + 2 > data.len) return error.DataCorruption;
        const key_len = std.mem.bytesToValue(u16, data[cursor.offset..][0..2]);
        cursor.offset += 2;
        if (cursor.offset + key_len > data.len) return error.DataCorruption;
        const entry_key = data[cursor.offset..][0..key_len];
        cursor.offset += key_len;

        const value_offset = cursor.offset;
        const value_size = try encodedSizeFromBytes(data[value_offset..]);
        cursor.offset += @intCast(value_size);

        return .{
            .key = entry_key,
            .value_offset = value_offset,
            .value_size = value_size,
        };
    }

    fn findEntrySpan(self: *const PropStore, data: []const u8, entry_count: u32, key: []const u8) !?EntrySpan {
        var cursor: EntryCursor = .{};
        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            const entry_start = cursor.offset;
            const entry = try self.readEntryAt(data, &cursor);
            if (std.mem.eql(u8, entry.key, key)) {
                return .{
                    .index = i,
                    .start = entry_start,
                    .end = cursor.offset,
                };
            }
        }
        return null;
    }

    fn compactEntryRange(_: *const PropStore, data: []u8, entry_start: u32, entry_end: u32, total_used: u32) u32 {
        const remaining = total_used - entry_end;
        if (remaining > 0) {
            std.mem.copyForwards(u8, data[entry_start..], data[entry_end..][0..remaining]);
        }

        const new_end = entry_start + remaining;
        @memset(data[new_end..total_used], 0);
        return new_end;
    }

    fn removeEntryAt(self: *const PropStore, data: []u8, entry_count: u32, span: EntrySpan) !RemovalResult {
        const total_used = PROP_DATA_OFFSET + try self.usedBytes(data, entry_count);
        const new_end = self.compactEntryRange(data, span.start, span.end, total_used);
        return .{
            .entry_count = entry_count - 1,
            .new_end = new_end,
            .total_used = total_used,
        };
    }

    fn writePropertyEntry(_: *const PropStore, data: []u8, offset: u32, key: []const u8, encoded_val: []const u8) void {
        var off = offset;
        const key_len: u16 = @intCast(key.len);
        @memcpy(data[off..][0..2], &std.mem.toBytes(key_len));
        off += 2;
        @memcpy(data[off..][0..key.len], key);
        off += @intCast(key.len);
        @memcpy(data[off..][0..encoded_val.len], encoded_val);
    }

    fn usedBytes(self: *const PropStore, data: []const u8, entry_count: u32) !u32 {
        var cursor: EntryCursor = .{};
        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            _ = try self.readEntryAt(data, &cursor);
        }
        return cursor.offset - PROP_DATA_OFFSET;
    }
};

/// Determine the encoded size of a property value from its raw bytes.
/// This avoids needing to fully decode the value.
/// Returns error.DataCorruption if the encoded length exceeds available bytes.
fn encodedSizeFromBytes(bytes: []const u8) error{ InvalidData, DataCorruption }!usize {
    if (bytes.len < 1) return error.DataCorruption;
    const tag: property_mod.Tag = std.enums.fromInt(property_mod.Tag, bytes[0]) orelse return error.InvalidData;
    const size: usize = switch (tag) {
        .null => 1,
        .bool => 2,
        .int => 9,
        .float => 9,
        .string => blk: {
            if (bytes.len < 5) return error.DataCorruption;
            const len = std.mem.bytesToValue(u32, bytes[1..5]);
            break :blk 5 + @as(usize, len);
        },
        .decimal => 18,
        .ext => blk: {
            if (bytes.len < 7) return error.DataCorruption;
            const data_len = std.mem.bytesToValue(u32, bytes[3..7]);
            break :blk 7 + @as(usize, data_len);
        },
    };
    if (size > bytes.len) return error.DataCorruption;
    return size;
}

fn readNextPage(data: []const u8) PageId {
    return std.mem.bytesToValue(u64, data[PAGE_HEADER_SIZE..][0..8]);
}

fn readEntryCount(data: []const u8) u32 {
    return std.mem.bytesToValue(u32, data[PAGE_HEADER_SIZE + 8 ..][0..4]);
}

/// Read entry_count with bounds validation: the minimum entry size is 3 bytes
/// (2-byte key_len + 1-byte value tag), so entry_count * 3 must fit in the
/// data capacity (minus DIR_COUNT_SIZE for the directory footer).
fn readEntryCountChecked(data: []const u8, page_size: u32) error{DataCorruption}!u32 {
    // `data` is the logical page slice (physical page minus any reserved
    // encryption-tag tail), so derive the capacity from data.len rather than
    // the physical page_size to keep the corruption bound tight when at-rest
    // encryption reserves a tail. page_size is retained for call-site
    // compatibility but data.len is authoritative.
    _ = page_size;
    const entry_count = readEntryCount(data);
    const capacity = @as(u32, @intCast(data.len)) - PROP_DATA_OFFSET - DIR_COUNT_SIZE;
    // Minimum entry is 2 (key_len) + 0 (key) + 1 (tag) = 3 bytes
    // Plus DIR_ENTRY_SIZE bytes of directory overhead per entry.
    const min_per_entry = 3 + DIR_ENTRY_SIZE;
    const max_entries = capacity / min_per_entry;
    if (entry_count > max_entries) return error.DataCorruption;
    return entry_count;
}

fn writeNextPage(data: []u8, page_id: PageId) void {
    @memcpy(data[PAGE_HEADER_SIZE..][0..8], &std.mem.toBytes(page_id));
}

fn writeEntryCount(data: []u8, count: u32) void {
    @memcpy(data[PAGE_HEADER_SIZE + 8 ..][0..4], &std.mem.toBytes(count));
}

/// PERF-0023: Rebuild the per-page key directory by scanning all entries.
/// This is called after insertions and removals to keep the directory
/// consistent with the entry data. The scan is O(entry_count) which is
/// bounded by the page size.
fn rebuildDirectory(data: []u8, entry_count: u32, page_size: u32) void {
    _ = page_size;
    // First verify there is room for the directory. If entries + directory
    // would overlap, write dir_count=0 to disable the directory (legacy mode).
    const max_dir_end = data.len - DIR_COUNT_SIZE - @as(usize, entry_count) * DIR_ENTRY_SIZE;

    var off: u32 = PROP_DATA_OFFSET;
    var di: u16 = 0;
    var i: u32 = 0;
    while (i < entry_count) : (i += 1) {
        const entry_off = off;
        if (off + 2 > data.len) break;
        const key_len = std.mem.bytesToValue(u16, data[off..][0..2]);
        off += 2;
        if (off + key_len > data.len) break;
        const k = data[off..][0..key_len];
        off += key_len;

        // Skip value
        const val_size = encodedSizeFromBytes(data[off..]) catch break;
        off += @intCast(val_size);

        // Check that entry data hasn't grown into the directory space.
        if (off > max_dir_end) {
            // No room for directory — disable it.
            writeDirCount(data, 0);
            return;
        }

        writeDirEntry(data, di, keyHash(k), @intCast(entry_off));
        di += 1;
    }

    writeDirCount(data, di);
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;
const testing_support_mod = @import("testing_support.zig");
const DualStoreEnv = testing_support_mod.DualStoreEnv;

const PropTestEnv = struct {
    base: DualStoreEnv,
    vs: VarStore,

    fn init() !PropTestEnv {
        var base = try DualStoreEnv.init(
            testing.allocator,
            .props,
            .props,
            "props.store",
            .var_store,
            "var.store",
            4096,
            32,
        );
        base.register();
        return .{
            .base = base,
            .vs = VarStore.init(&base.pool, &base.fsm, 4096),
        };
    }

    fn pool(self: *PropTestEnv) *BufferPool {
        return &self.base.pool;
    }

    fn fsm(self: *PropTestEnv) *FreeSpaceManager {
        return &self.base.fsm;
    }

    fn deinit(self: *PropTestEnv) void {
        self.base.deinit();
    }
};

test "putProperty + getProperty round-trip: int" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const head = try store.putProperty(0, "age", .{ .int = 30 });
    try testing.expect(head != 0);

    const val = try store.getProperty(head, "age", testing.allocator);
    try testing.expect(val != null);
    try testing.expectEqual(@as(i64, 30), val.?.int);
}

test "putProperty + getProperty round-trip: string" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const head = try store.putProperty(0, "name", .{ .string = "Alice" });

    const val = try store.getProperty(head, "name", testing.allocator);
    try testing.expect(val != null);
    defer property_mod.freeDecoded(testing.allocator, val.?);
    try testing.expectEqualStrings("Alice", val.?.string);
}

test "putProperty + getProperty round-trip: bool" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const head = try store.putProperty(0, "active", .{ .bool = true });
    const val = try store.getProperty(head, "active", testing.allocator);
    try testing.expect(val != null);
    try testing.expect(val.?.bool);
}

test "putProperty + getProperty round-trip: float" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const head = try store.putProperty(0, "score", .{ .float = 3.14 });
    const val = try store.getProperty(head, "score", testing.allocator);
    try testing.expect(val != null);
    try testing.expectApproxEqAbs(@as(f64, 3.14), val.?.float, 0.001);
}

test "putProperty + getProperty round-trip: null" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const head = try store.putProperty(0, "nothing", PropertyValue.null);
    const val = try store.getProperty(head, "nothing", testing.allocator);
    try testing.expect(val != null);
    try testing.expectEqual(PropertyValue.null, val.?);
}

test "getAllProperties returns all stored properties" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    var head = try store.putProperty(0, "name", .{ .string = "Bob" });
    head = try store.putProperty(head, "age", .{ .int = 25 });
    head = try store.putProperty(head, "active", .{ .bool = false });

    var iter = store.getAllProperties(head);
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |_| {
        count += 1;
    }

    try testing.expectEqual(@as(usize, 3), count);
}

test "removeProperty removes the property" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    var head = try store.putProperty(0, "x", .{ .int = 1 });
    head = try store.putProperty(head, "y", .{ .int = 2 });
    head = try store.putProperty(head, "z", .{ .int = 3 });

    try store.removeProperty(head, "y");

    const val = try store.getProperty(head, "y", testing.allocator);
    try testing.expect(val == null);

    // x and z should still be there
    const vx = try store.getProperty(head, "x", testing.allocator);
    try testing.expect(vx != null);
    try testing.expectEqual(@as(i64, 1), vx.?.int);

    const vz = try store.getProperty(head, "z", testing.allocator);
    try testing.expect(vz != null);
    try testing.expectEqual(@as(i64, 3), vz.?.int);
}

test "multiple properties on same entity" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    var head = try store.putProperty(0, "a", .{ .int = 1 });
    head = try store.putProperty(head, "b", .{ .int = 2 });
    head = try store.putProperty(head, "c", .{ .int = 3 });
    head = try store.putProperty(head, "d", .{ .int = 4 });

    const va = try store.getProperty(head, "a", testing.allocator);
    try testing.expectEqual(@as(i64, 1), va.?.int);

    const vd = try store.getProperty(head, "d", testing.allocator);
    try testing.expectEqual(@as(i64, 4), vd.?.int);
}

test "getProperty returns null for nonexistent key" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const head = try store.putProperty(0, "x", .{ .int = 1 });
    const val = try store.getProperty(head, "nope", testing.allocator);
    try testing.expect(val == null);
}

test "getProperty returns null for empty prop_head" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const val = try store.getProperty(0, "anything", testing.allocator);
    try testing.expect(val == null);
}

test "putProperty replace-in-place uses single-pass optimization" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    // Write a property then replace it with a value of same or smaller size.
    // This exercises the PERF-0021 in-place replacement path.
    var head = try store.putProperty(0, "counter", .{ .int = 100 });
    head = try store.putProperty(head, "counter", .{ .int = 999 });

    const val = try store.getProperty(head, "counter", testing.allocator);
    try testing.expect(val != null);
    try testing.expectEqual(@as(i64, 999), val.?.int);

    // Verify only one entry exists (no duplicate after replace)
    var iter = store.getAllProperties(head);
    defer iter.deinit();
    var count: usize = 0;
    while (try iter.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 1), count);
}

test "encodedSizeFromBytes rejects invalid property tag byte" {
    const bad_bytes = [_]u8{0xFF}; // 0xFF is not a valid property_mod.Tag
    try testing.expectError(error.InvalidData, encodedSizeFromBytes(&bad_bytes));
}

test "encodedSizeFromBytes returns DataCorruption for empty input" {
    const empty: []const u8 = &.{};
    try testing.expectError(error.DataCorruption, encodedSizeFromBytes(empty));
}

test "encodedSizeFromBytes returns DataCorruption for truncated string" {
    // string tag with only 2 bytes (needs at least 5 for tag + u32 length)
    const truncated = [_]u8{ @intFromEnum(property_mod.Tag.string), 0x05 };
    try testing.expectError(error.DataCorruption, encodedSizeFromBytes(&truncated));
}

test "encodedSizeFromBytes returns DataCorruption for string length exceeding buffer" {
    // string tag with length 100 but only 9 bytes total
    var buf: [9]u8 = undefined;
    buf[0] = @intFromEnum(property_mod.Tag.string);
    @memcpy(buf[1..5], &std.mem.toBytes(@as(u32, 100)));
    try testing.expectError(error.DataCorruption, encodedSizeFromBytes(&buf));
}

test "readEntryCountChecked rejects entry_count exceeding page capacity" {
    // Build a fake page buffer with an absurdly large entry_count
    var data: [4096]u8 = undefined;
    @memset(&data, 0);
    // Write entry_count = 10000 which is way more than (4096 - PROP_DATA_OFFSET) / 3
    @memcpy(data[PAGE_HEADER_SIZE + 8 ..][0..4], &std.mem.toBytes(@as(u32, 10000)));
    try testing.expectError(error.DataCorruption, readEntryCountChecked(&data, 4096));
}

test "readEntryCountChecked accepts valid entry_count" {
    var data: [4096]u8 = undefined;
    @memset(&data, 0);
    @memcpy(data[PAGE_HEADER_SIZE + 8 ..][0..4], &std.mem.toBytes(@as(u32, 5)));
    const count = try readEntryCountChecked(&data, 4096);
    try testing.expectEqual(@as(u32, 5), count);
}

// ============================================================================
// PERF-0023: Per-page key directory tests
// ============================================================================

test "PERF-0023: directory is created on put and used for lookup" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    // Insert 10 properties and verify each is found via directory.
    var head: u64 = 0;
    const keys = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa" };
    for (keys, 0..) |k, idx| {
        head = try store.putProperty(head, k, .{ .int = @intCast(idx) });
    }

    // Verify each key is found.
    for (keys, 0..) |k, idx| {
        const val = try store.getProperty(head, k, testing.allocator);
        try testing.expect(val != null);
        try testing.expectEqual(@as(i64, @intCast(idx)), val.?.int);
    }

    // Verify the directory is present on the page by pinning and reading dir_count.
    const frame = try env.pool().pin(.props, head);
    const frame_idx = env.pool().frameIndex(frame);
    const data = frame.dataSlice();
    const dir_count = readDirCount(data);
    try testing.expect(dir_count == 10);
    env.pool().unpin(frame_idx, false);
}

test "PERF-0023: hash collision still finds correct key" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    // Find two keys that produce the same hash to test collision handling.
    // We'll brute-force a collision with the keyHash function.
    var collision_key: [8]u8 = undefined;
    const target_hash = keyHash("testkey");
    var found_collision = false;
    var seed: u32 = 0;
    while (seed < 1_000_000) : (seed += 1) {
        const bytes = std.mem.toBytes(seed);
        @memcpy(collision_key[0..4], &bytes);
        @memcpy(collision_key[4..8], "COLL");
        if (keyHash(&collision_key) == target_hash and !std.mem.eql(u8, &collision_key, "testkey")) {
            found_collision = true;
            break;
        }
    }

    if (!found_collision) {
        // Extremely unlikely but skip if no collision found in reasonable range.
        return;
    }

    var head = try store.putProperty(0, "testkey", .{ .int = 42 });
    head = try store.putProperty(head, &collision_key, .{ .int = 99 });

    // Both keys should be retrievable despite same hash.
    const val1 = try store.getProperty(head, "testkey", testing.allocator);
    try testing.expect(val1 != null);
    try testing.expectEqual(@as(i64, 42), val1.?.int);

    const val2 = try store.getProperty(head, &collision_key, testing.allocator);
    try testing.expect(val2 != null);
    try testing.expectEqual(@as(i64, 99), val2.?.int);
}

test "PERF-0023: legacy page without directory uses linear scan" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    // Create a page with entries but manually zero out the directory.
    var head = try store.putProperty(0, "key1", .{ .int = 10 });
    head = try store.putProperty(head, "key2", .{ .int = 20 });

    // Manually set dir_count to 0 to simulate a legacy page.
    const frame = try env.pool().pin(.props, head);
    const frame_idx = env.pool().frameIndex(frame);
    const data = frame.dataSlice();
    writeDirCount(data, 0);
    env.pool().unpin(frame_idx, true);

    // Linear scan fallback should still find both keys.
    const val1 = try store.getProperty(head, "key1", testing.allocator);
    try testing.expect(val1 != null);
    try testing.expectEqual(@as(i64, 10), val1.?.int);

    const val2 = try store.getProperty(head, "key2", testing.allocator);
    try testing.expect(val2 != null);
    try testing.expectEqual(@as(i64, 20), val2.?.int);
}

test "PERF-0023: directory survives put-replace cycle" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    var head = try store.putProperty(0, "x", .{ .int = 1 });
    head = try store.putProperty(head, "y", .{ .int = 2 });
    head = try store.putProperty(head, "z", .{ .int = 3 });

    // Replace y
    head = try store.putProperty(head, "y", .{ .int = 222 });

    // Verify all accessible
    const vx = try store.getProperty(head, "x", testing.allocator);
    try testing.expectEqual(@as(i64, 1), vx.?.int);

    const vy = try store.getProperty(head, "y", testing.allocator);
    try testing.expectEqual(@as(i64, 222), vy.?.int);

    const vz = try store.getProperty(head, "z", testing.allocator);
    try testing.expectEqual(@as(i64, 3), vz.?.int);

    // Verify directory count is correct (3 entries, not 4).
    const frame = try env.pool().pin(.props, head);
    const frame_idx = env.pool().frameIndex(frame);
    const data = frame.dataSlice();
    const dir_count = readDirCount(data);
    try testing.expectEqual(@as(u16, 3), dir_count);
    env.pool().unpin(frame_idx, false);
}

test "PERF-0023: directory rebuilt after removeProperty" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    var head = try store.putProperty(0, "a", .{ .int = 1 });
    head = try store.putProperty(head, "b", .{ .int = 2 });
    head = try store.putProperty(head, "c", .{ .int = 3 });

    try store.removeProperty(head, "b");

    // a and c should still be found via directory.
    const va = try store.getProperty(head, "a", testing.allocator);
    try testing.expectEqual(@as(i64, 1), va.?.int);

    const vc = try store.getProperty(head, "c", testing.allocator);
    try testing.expectEqual(@as(i64, 3), vc.?.int);

    // b should not be found.
    const vb = try store.getProperty(head, "b", testing.allocator);
    try testing.expect(vb == null);

    // Directory should have 2 entries.
    const frame = try env.pool().pin(.props, head);
    const frame_idx = env.pool().frameIndex(frame);
    const data = frame.dataSlice();
    try testing.expectEqual(@as(u16, 2), readDirCount(data));
    env.pool().unpin(frame_idx, false);
}

test "PERF-0023: keyHash helper produces consistent u16 values" {
    // Verify deterministic hashing.
    const h1 = keyHash("hello");
    const h2 = keyHash("hello");
    try testing.expectEqual(h1, h2);

    // Different keys should (very likely) produce different hashes.
    const h3 = keyHash("world");
    try testing.expect(h1 != h3);
}

test "PERF-0023: directory helpers read/write round-trip" {
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);

    writeDirCount(&buf, 3);
    try testing.expectEqual(@as(u16, 3), readDirCount(&buf));

    writeDirEntry(&buf, 0, 0xABCD, 44);
    const e0 = readDirEntry(&buf, 0);
    try testing.expectEqual(@as(u16, 0xABCD), e0.hash);
    try testing.expectEqual(@as(u16, 44), e0.offset);

    writeDirEntry(&buf, 1, 0x1234, 100);
    const e1 = readDirEntry(&buf, 1);
    try testing.expectEqual(@as(u16, 0x1234), e1.hash);
    try testing.expectEqual(@as(u16, 100), e1.offset);
}

// ============================================================================
// SEC-0039: dir_count bounds-validation regression tests
// ============================================================================

test "SEC-0039: getProperty returns DataCorruption when dir_count is 0xFFFF" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    // Create a real property page.
    const head = try store.putProperty(0, "k", .{ .int = 1 });

    // Corrupt the dir_count field to the maximum possible u16 value.
    // This makes dirOverhead(0xFFFF) = 2 + 65535*4 = 262142 bytes, which
    // far exceeds the 4096-byte page; readDirEntry would underflow the base
    // index in ReleaseFast or panic in ReleaseSafe.
    const frame = try env.pool().pin(.props, head);
    const frame_idx = env.pool().frameIndex(frame);
    writeDirCount(frame.dataSlice(), 0xFFFF);
    env.pool().unpin(frame_idx, true);

    // getProperty must return DataCorruption rather than panicking or
    // producing an out-of-bounds read.
    try testing.expectError(error.DataCorruption, store.getProperty(head, "k", testing.allocator));
}

test "SEC-0039: getProperty returns DataCorruption when dir_count just exceeds capacity" {
    var env = try PropTestEnv.init();
    defer env.deinit();

    var store = PropStore.init(env.pool(), env.fsm(), &env.vs, 4096);

    const head = try store.putProperty(0, "k", .{ .int = 1 });

    // Compute the maximum valid dir_count for a 4096-byte page.
    // capacity = 4096 - PROP_DATA_OFFSET - DIR_COUNT_SIZE
    // PROP_DATA_OFFSET = PAGE_HEADER_SIZE(32) + PROP_META_SIZE(12) = 44
    // capacity = 4096 - 44 - 2 = 4050
    // max_valid = capacity / DIR_ENTRY_SIZE(4) = 1012
    // One past capacity: 1013
    const one_past_capacity: u16 = 1013;

    const frame = try env.pool().pin(.props, head);
    const frame_idx = env.pool().frameIndex(frame);
    writeDirCount(frame.dataSlice(), one_past_capacity);
    env.pool().unpin(frame_idx, true);

    try testing.expectError(error.DataCorruption, store.getProperty(head, "k", testing.allocator));
}

test {
    std.testing.refAllDecls(@This());
}
