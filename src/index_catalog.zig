// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;
// fips-exempt: non-security — CRC32C record-integrity (corruption detection)
// for on-disk format; not authentication.
const Crc32 = std.hash.crc.Crc32Iscsi;
const owner_only_file_mode = 0o600;

pub const CATALOG_MAGIC: [8]u8 = .{ 'G', 'E', 'O', 'C', 'A', 'T', '0', '1' };
pub const CATALOG_VERSION: u32 = 1;

/// Built-in index kinds. These values (0 and 1) are permanently reserved;
/// they MUST NOT be reused by extension registrations (the registry rejects
/// any attempt to register a type_id that falls in the built-in range 0..127).
pub const IndexType = enum(u8) {
    btree_property = 0,
    label_posting = 1,
};

/// On-disk / in-memory representation of an index kind.
///
/// Built-in kinds use the closed `IndexType` enum; custom/extension kinds
/// occupy type_ids in the range 128..255 and must be registered via
/// `IndexKindRegistry.register` before the catalog can round-trip them.
///
/// Wire format: a single `u8` type_id.  Built-in: `@intFromEnum(IndexType)`.
/// Extension: the registered `type_id`.
pub const IndexKind = union(enum) {
    builtin: IndexType,
    extension: u8,

    /// Return the single-byte wire representation of this kind.
    pub fn typeId(self: IndexKind) u8 {
        return switch (self) {
            .builtin => |t| @intFromEnum(t),
            .extension => |id| id,
        };
    }

    /// Structural equality.
    pub fn eql(self: IndexKind, other: IndexKind) bool {
        return switch (self) {
            .builtin => |t| switch (other) {
                .builtin => |ot| t == ot,
                .extension => false,
            },
            .extension => |id| switch (other) {
                .builtin => false,
                .extension => |oid| id == oid,
            },
        };
    }
};

pub const IndexState = enum(u8) {
    building = 0,
    active = 1,
    inactive = 2,
    failed = 3,
};

pub const IndexDef = struct {
    label_id: u32,
    property_key: []const u8,
    index_type: IndexKind,
    state: IndexState,
};

// ============================================================================
// Extension registry
// ============================================================================

/// Descriptor for a custom index kind.  Callers that implement a new index
/// kind (e.g. full-text, vector, spatial) create one of these and pass it to
/// `IndexKindRegistry.register`.
///
/// `type_id` MUST be in the range 128..255 (the built-in range 0..127 is
/// permanently reserved).  Registering a duplicate type_id is an error.
pub const IndexKindDescriptor = struct {
    /// Stable on-disk identifier for this kind (128..255).
    type_id: u8,
    /// Human-readable name (e.g. "vector", "fulltext", "spatial").
    /// The registry does NOT own this memory; the descriptor must outlive
    /// the registry (or be a comptime literal, which is the common case).
    name: []const u8,
};

/// A registry of custom index kinds.  The `IndexCatalog` consults its
/// associated registry during `loadFromFile` to decide whether an unknown
/// type_id byte is a legitimately registered extension or an invalid entry
/// that must be rejected (fail-closed).
///
/// The registry does NOT own the descriptors; callers pass pointers to
/// descriptors with appropriate lifetime (typically comptime or static).
pub const IndexKindRegistry = struct {
    entries: std.ArrayListUnmanaged(*const IndexKindDescriptor) = .empty,

    /// Register a custom index kind.  Returns `error.InvalidTypeId` when
    /// `desc.type_id` is in the built-in range (0..127), and
    /// `error.DuplicateTypeId` when the id is already registered.
    pub fn register(self: *IndexKindRegistry, allocator: Allocator, desc: *const IndexKindDescriptor) !void {
        if (desc.type_id < 128) return error.InvalidTypeId;
        for (self.entries.items) |existing| {
            if (existing.type_id == desc.type_id) return error.DuplicateTypeId;
        }
        try self.entries.append(allocator, desc);
    }

    /// Look up a descriptor by `type_id`.  Returns `null` when not registered.
    pub fn lookup(self: *const IndexKindRegistry, type_id: u8) ?*const IndexKindDescriptor {
        for (self.entries.items) |desc| {
            if (desc.type_id == type_id) return desc;
        }
        return null;
    }

    /// Release the entry list.  Does NOT free the descriptors themselves.
    pub fn deinit(self: *IndexKindRegistry, allocator: Allocator) void {
        self.entries.deinit(allocator);
    }
};

/// Module-level default registry.  Tests and production code that do not need
/// isolation can use `globalRegistry()` to obtain a pointer to this instance.
/// It is zero-initialised (empty) at program start.
var global_registry: IndexKindRegistry = .{};

/// Return a pointer to the process-wide default `IndexKindRegistry`.
pub fn globalRegistry() *IndexKindRegistry {
    return &global_registry;
}

// ============================================================================
// Catalog
// ============================================================================

/// Catalog of all index definitions. Provides persistence via a simple
/// binary file format.
pub const IndexCatalog = struct {
    allocator: Allocator,
    indexes: std.ArrayList(IndexDef),
    /// Owned copies of property_key strings for entries managed by the catalog.
    owned_keys: std.ArrayList([]const u8),
    /// Registry consulted when loading extension entries.  Defaults to the
    /// global registry; callers may substitute an isolated registry for tests.
    registry: *IndexKindRegistry,

    pub fn init(allocator: Allocator) IndexCatalog {
        return .{
            .allocator = allocator,
            .indexes = .empty,
            .owned_keys = .empty,
            .registry = globalRegistry(),
        };
    }

    /// Construct a catalog that consults a caller-supplied registry.  Useful
    /// for unit tests that register kinds in isolation.
    pub fn initWithRegistry(allocator: Allocator, registry: *IndexKindRegistry) IndexCatalog {
        return .{
            .allocator = allocator,
            .indexes = .empty,
            .owned_keys = .empty,
            .registry = registry,
        };
    }

    pub fn deinit(self: *IndexCatalog) void {
        for (self.owned_keys.items) |key| {
            self.allocator.free(key);
        }
        self.owned_keys.deinit(self.allocator);
        self.indexes.deinit(self.allocator);
    }

    /// Register a new index definition. The property_key is copied.
    pub fn addIndex(self: *IndexCatalog, def: IndexDef) !void {
        const key_copy = try self.allocator.dupe(u8, def.property_key);
        errdefer self.allocator.free(key_copy);

        try self.owned_keys.append(self.allocator, key_copy);
        errdefer _ = self.owned_keys.pop();

        try self.indexes.append(self.allocator, .{
            .label_id = def.label_id,
            .property_key = key_copy,
            .index_type = def.index_type,
            .state = def.state,
        });
    }

    /// Remove an index definition. Returns true if found and removed.
    pub fn removeIndex(self: *IndexCatalog, label_id: u32, property_key: []const u8) bool {
        for (self.indexes.items, 0..) |entry, i| {
            if (entry.label_id == label_id and std.mem.eql(u8, entry.property_key, property_key)) {
                self.allocator.free(self.owned_keys.items[i]);
                _ = self.owned_keys.orderedRemove(i);
                _ = self.indexes.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Find an index definition.
    pub fn findIndex(self: *const IndexCatalog, label_id: u32, property_key: []const u8) ?IndexDef {
        for (self.indexes.items) |entry| {
            if (entry.label_id == label_id and std.mem.eql(u8, entry.property_key, property_key)) {
                return entry;
            }
        }
        return null;
    }

    /// Save the catalog to a file.
    /// Format: [magic 8B] [version 4B] [count 4B] then for each entry:
    ///   [u32 label_id] [u8 index_type] [u8 state] [u16 key_len] [key_len bytes]
    /// Followed by [CRC32 4B] over all preceding bytes.
    pub fn saveToFile(self: *const IndexCatalog, path: []const u8) !void {
        const file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), path, .{ .permissions = std.Io.File.Permissions.fromMode(owner_only_file_mode) });
        defer file.close(std.Io.Threaded.global_single_threaded.io());

        // Serialize to an in-memory buffer, then write all at once.
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(self.allocator);

        // Magic
        try data.appendSlice(self.allocator, &CATALOG_MAGIC);

        // Version
        {
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, CATALOG_VERSION, .little);
            try data.appendSlice(self.allocator, &tmp);
        }

        // Entry count
        const entry_count: u32 = @intCast(self.indexes.items.len);
        {
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, entry_count, .little);
            try data.appendSlice(self.allocator, &tmp);
        }

        for (self.indexes.items) |entry| {
            {
                var tmp: [4]u8 = undefined;
                std.mem.writeInt(u32, &tmp, entry.label_id, .little);
                try data.appendSlice(self.allocator, &tmp);
            }
            try data.append(self.allocator, entry.index_type.typeId());
            try data.append(self.allocator, @intFromEnum(entry.state));
            {
                const key_len: u16 = @intCast(entry.property_key.len);
                var tmp: [2]u8 = undefined;
                std.mem.writeInt(u16, &tmp, key_len, .little);
                try data.appendSlice(self.allocator, &tmp);
            }
            try data.appendSlice(self.allocator, entry.property_key);
        }

        // CRC32 over everything before the checksum
        const crc = Crc32.hash(data.items);
        {
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, crc, .little);
            try data.appendSlice(self.allocator, &tmp);
        }

        try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), data.items);
    }

    /// Load the catalog from a file, replacing any existing entries.
    /// Validates magic bytes, version, and CRC32 checksum.
    ///
    /// For each entry the type_id byte is resolved as follows:
    ///   - If it matches a known `IndexType` (built-in range 0..127 and valid):
    ///     loaded as `IndexKind{ .builtin = <IndexType> }`.
    ///   - If it is in the extension range (128..255) AND is registered in the
    ///     catalog's registry: loaded as `IndexKind{ .extension = type_id }`.
    ///   - Otherwise: `error.InvalidData` (fail-closed; no silent acceptance).
    pub fn loadFromFile(self: *IndexCatalog, path: []const u8) !void {
        // Clear existing.
        for (self.owned_keys.items) |key| {
            self.allocator.free(key);
        }
        self.owned_keys.clearRetainingCapacity();
        self.indexes.clearRetainingCapacity();

        const file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path, .{});
        defer file.close(std.Io.Threaded.global_single_threaded.io());

        // Read entire file into memory.
        const stat = try file.stat(std.Io.Threaded.global_single_threaded.io());
        const content = try self.allocator.alloc(u8, stat.size);
        defer self.allocator.free(content);
        const bytes_read = try file.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), content, 0);
        if (bytes_read != stat.size) return error.UnexpectedEndOfFile;

        // Minimum size: magic(8) + version(4) + count(4) + crc(4) = 20
        if (content.len < 20) return error.InvalidData;

        // Validate magic
        if (!std.mem.eql(u8, content[0..8], &CATALOG_MAGIC)) return error.InvalidMagic;

        // Validate CRC32 (over everything except the trailing 4 CRC bytes)
        const stored_crc = std.mem.readInt(u32, content[content.len - 4 ..][0..4], .little);
        const computed_crc = Crc32.hash(content[0 .. content.len - 4]);
        if (stored_crc != computed_crc) return error.ChecksumMismatch;

        var pos: usize = 8;

        // Version (read but accept any value for forward compatibility)
        _ = std.mem.readInt(u32, content[pos..][0..4], .little);
        pos += 4;

        const entry_count = std.mem.readInt(u32, content[pos..][0..4], .little);
        pos += 4;

        // The payload ends 4 bytes before the end (CRC bytes).
        const payload_end = content.len - 4;

        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            if (pos + 8 > payload_end) return error.InvalidData;
            const label_id = std.mem.readInt(u32, content[pos..][0..4], .little);
            pos += 4;
            const type_byte = content[pos];
            pos += 1;
            const state_byte = content[pos];
            pos += 1;
            const key_len = std.mem.readInt(u16, content[pos..][0..2], .little);
            pos += 2;

            if (pos + key_len > payload_end) return error.InvalidData;
            const key_buf = try self.allocator.dupe(u8, content[pos..][0..key_len]);
            errdefer self.allocator.free(key_buf);
            pos += key_len;

            // Resolve the type_id byte: built-in range first, then registry,
            // then fail-closed.
            const index_kind: IndexKind = blk: {
                if (std.enums.fromInt(IndexType, type_byte)) |t| {
                    break :blk .{ .builtin = t };
                }
                // Not a built-in; consult the extension registry.
                if (self.registry.lookup(type_byte) != null) {
                    break :blk .{ .extension = type_byte };
                }
                // Unknown — fail closed.
                return error.InvalidData;
            };

            const state = std.enums.fromInt(IndexState, state_byte) orelse return error.InvalidData;

            try self.owned_keys.append(self.allocator, key_buf);
            errdefer _ = self.owned_keys.pop();

            try self.indexes.append(self.allocator, .{
                .label_id = label_id,
                .property_key = key_buf,
                .index_type = index_kind,
                .state = state,
            });
        }
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "addIndex + findIndex" {
    var catalog = IndexCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.addIndex(.{
        .label_id = 1,
        .property_key = "name",
        .index_type = .{ .builtin = .btree_property },
        .state = .active,
    });

    const found = catalog.findIndex(1, "name");
    try testing.expect(found != null);
    try testing.expectEqual(@as(u32, 1), found.?.label_id);
    try testing.expectEqualStrings("name", found.?.property_key);
    try testing.expect(found.?.index_type.eql(.{ .builtin = .btree_property }));
    try testing.expectEqual(IndexState.active, found.?.state);
}

test "findIndex returns null for unknown" {
    var catalog = IndexCatalog.init(testing.allocator);
    defer catalog.deinit();

    try testing.expect(catalog.findIndex(1, "name") == null);
}

test "removeIndex" {
    var catalog = IndexCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.addIndex(.{
        .label_id = 1,
        .property_key = "name",
        .index_type = .{ .builtin = .btree_property },
        .state = .active,
    });

    try testing.expect(catalog.removeIndex(1, "name"));
    try testing.expect(catalog.findIndex(1, "name") == null);
    try testing.expect(!catalog.removeIndex(1, "name"));
}

test "saveToFile + loadFromFile round-trip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(path);

    const full_path = try std.fmt.allocPrint(testing.allocator, "{s}/catalog.bin", .{path});
    defer testing.allocator.free(full_path);

    // Create and save.
    {
        var catalog = IndexCatalog.init(testing.allocator);
        defer catalog.deinit();

        try catalog.addIndex(.{
            .label_id = 1,
            .property_key = "name",
            .index_type = .{ .builtin = .btree_property },
            .state = .active,
        });
        try catalog.addIndex(.{
            .label_id = 2,
            .property_key = "email",
            .index_type = .{ .builtin = .label_posting },
            .state = .building,
        });

        try catalog.saveToFile(full_path);
    }

    {
        const saved_file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), full_path, .{});
        defer saved_file.close(std.Io.Threaded.global_single_threaded.io());
        const saved_stat = try saved_file.stat(std.Io.Threaded.global_single_threaded.io());
        try testing.expectEqual(@as(u32, owner_only_file_mode), saved_stat.permissions.toMode() & 0o7777);
    }

    // Load and verify.
    {
        var catalog = IndexCatalog.init(testing.allocator);
        defer catalog.deinit();

        try catalog.loadFromFile(full_path);

        try testing.expectEqual(@as(usize, 2), catalog.indexes.items.len);

        const first = catalog.findIndex(1, "name");
        try testing.expect(first != null);
        try testing.expect(first.?.index_type.eql(.{ .builtin = .btree_property }));
        try testing.expectEqual(IndexState.active, first.?.state);

        const second = catalog.findIndex(2, "email");
        try testing.expect(second != null);
        try testing.expect(second.?.index_type.eql(.{ .builtin = .label_posting }));
        try testing.expectEqual(IndexState.building, second.?.state);
    }
}

test "multiple indexes for same label" {
    var catalog = IndexCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.addIndex(.{
        .label_id = 1,
        .property_key = "name",
        .index_type = .{ .builtin = .btree_property },
        .state = .active,
    });
    try catalog.addIndex(.{
        .label_id = 1,
        .property_key = "age",
        .index_type = .{ .builtin = .btree_property },
        .state = .active,
    });

    try testing.expect(catalog.findIndex(1, "name") != null);
    try testing.expect(catalog.findIndex(1, "age") != null);
    try testing.expect(catalog.findIndex(1, "email") == null);
}

test "loadFromFile rejects invalid index_type byte" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(path);

    const full_path = try std.fmt.allocPrint(testing.allocator, "{s}/bad_catalog.bin", .{path});
    defer testing.allocator.free(full_path);

    // Craft a catalog file with 1 entry whose index_type byte (0xFF) is invalid
    // (not registered in the default global registry).
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    // magic
    @memcpy(buf[pos..][0..8], &CATALOG_MAGIC);
    pos += 8;
    // version
    std.mem.writeInt(u32, buf[pos..][0..4], CATALOG_VERSION, .little);
    pos += 4;
    // entry_count = 1
    std.mem.writeInt(u32, buf[pos..][0..4], 1, .little);
    pos += 4;
    // label_id = 1
    std.mem.writeInt(u32, buf[pos..][0..4], 1, .little);
    pos += 4;
    // index_type = 0xFF (not registered)
    buf[pos] = 0xFF;
    pos += 1;
    // state = 0 (valid)
    buf[pos] = 0;
    pos += 1;
    // key_len = 3
    std.mem.writeInt(u16, buf[pos..][0..2], 3, .little);
    pos += 2;
    // key = "foo"
    @memcpy(buf[pos..][0..3], "foo");
    pos += 3;
    // CRC32 over everything so far
    const crc = Crc32.hash(buf[0..pos]);
    std.mem.writeInt(u32, buf[pos..][0..4], crc, .little);
    pos += 4;

    const file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), full_path, .{});
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), buf[0..pos]);
    file.close(std.Io.Threaded.global_single_threaded.io());

    var catalog = IndexCatalog.init(testing.allocator);
    defer catalog.deinit();

    try testing.expectError(error.InvalidData, catalog.loadFromFile(full_path));
}

test "loadFromFile rejects invalid state byte" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(path);

    const full_path = try std.fmt.allocPrint(testing.allocator, "{s}/bad_state.bin", .{path});
    defer testing.allocator.free(full_path);

    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    // magic
    @memcpy(buf[pos..][0..8], &CATALOG_MAGIC);
    pos += 8;
    // version
    std.mem.writeInt(u32, buf[pos..][0..4], CATALOG_VERSION, .little);
    pos += 4;
    // entry_count = 1
    std.mem.writeInt(u32, buf[pos..][0..4], 1, .little);
    pos += 4;
    // label_id = 1
    std.mem.writeInt(u32, buf[pos..][0..4], 1, .little);
    pos += 4;
    // index_type = 0 (valid: btree_property)
    buf[pos] = 0;
    pos += 1;
    // state = 0xAA (invalid)
    buf[pos] = 0xAA;
    pos += 1;
    // key_len = 3
    std.mem.writeInt(u16, buf[pos..][0..2], 3, .little);
    pos += 2;
    @memcpy(buf[pos..][0..3], "bar");
    pos += 3;
    // CRC32 over everything so far
    const crc = Crc32.hash(buf[0..pos]);
    std.mem.writeInt(u32, buf[pos..][0..4], crc, .little);
    pos += 4;

    const file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), full_path, .{});
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), buf[0..pos]);
    file.close(std.Io.Threaded.global_single_threaded.io());

    var catalog = IndexCatalog.init(testing.allocator);
    defer catalog.deinit();

    try testing.expectError(error.InvalidData, catalog.loadFromFile(full_path));
}

test "loadFromFile rejects corrupted CRC" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(path);

    const full_path = try std.fmt.allocPrint(testing.allocator, "{s}/corrupt_crc.bin", .{path});
    defer testing.allocator.free(full_path);

    // Save a valid catalog, then corrupt a byte to invalidate the CRC.
    {
        var catalog = IndexCatalog.init(testing.allocator);
        defer catalog.deinit();
        try catalog.addIndex(.{
            .label_id = 1,
            .property_key = "name",
            .index_type = .{ .builtin = .btree_property },
            .state = .active,
        });
        try catalog.saveToFile(full_path);
    }

    // Corrupt a data byte (not the CRC itself).
    {
        const file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), full_path, .{ .mode = .read_write });
        defer file.close(std.Io.Threaded.global_single_threaded.io());
        const stat = try file.stat(std.Io.Threaded.global_single_threaded.io());
        // Flip a byte in the middle of the payload.
        const corrupt_pos = stat.size / 2;
        var byte: [1]u8 = undefined;
        _ = try file.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), &byte, corrupt_pos);
        byte[0] ^= 0xFF;
        try file.writePositionalAll(std.Io.Threaded.global_single_threaded.io(), &byte, corrupt_pos);
    }

    var catalog = IndexCatalog.init(testing.allocator);
    defer catalog.deinit();
    try testing.expectError(error.ChecksumMismatch, catalog.loadFromFile(full_path));
}

test "loadFromFile rejects wrong magic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(path);

    const full_path = try std.fmt.allocPrint(testing.allocator, "{s}/bad_magic.bin", .{path});
    defer testing.allocator.free(full_path);

    // Write a file with wrong magic but otherwise valid-ish structure.
    const file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), full_path, .{});
    var buf: [20]u8 = undefined;
    @memcpy(buf[0..8], "XXXXXXXX"); // wrong magic
    std.mem.writeInt(u32, buf[8..12], 1, .little); // version
    std.mem.writeInt(u32, buf[12..16], 0, .little); // count = 0
    std.mem.writeInt(u32, buf[16..20], 0, .little); // fake CRC
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), &buf);
    file.close(std.Io.Threaded.global_single_threaded.io());

    var catalog = IndexCatalog.init(testing.allocator);
    defer catalog.deinit();
    try testing.expectError(error.InvalidMagic, catalog.loadFromFile(full_path));
}

test "loadFromFile rejects file too small" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(path);

    const full_path = try std.fmt.allocPrint(testing.allocator, "{s}/tiny.bin", .{path});
    defer testing.allocator.free(full_path);

    // Write a file that's too small (less than 20 bytes minimum).
    const file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), full_path, .{});
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "short");
    file.close(std.Io.Threaded.global_single_threaded.io());

    var catalog = IndexCatalog.init(testing.allocator);
    defer catalog.deinit();
    try testing.expectError(error.InvalidData, catalog.loadFromFile(full_path));
}

// ============================================================================
// FR-021: Extension-kind tests
// ============================================================================

test "IndexKindRegistry rejects built-in range type_id" {
    var reg: IndexKindRegistry = .{};
    defer reg.deinit(testing.allocator);

    const desc = IndexKindDescriptor{ .type_id = 0, .name = "bad" };
    try testing.expectError(error.InvalidTypeId, reg.register(testing.allocator, &desc));

    const desc2 = IndexKindDescriptor{ .type_id = 127, .name = "bad2" };
    try testing.expectError(error.InvalidTypeId, reg.register(testing.allocator, &desc2));
}

test "IndexKindRegistry rejects duplicate type_id" {
    var reg: IndexKindRegistry = .{};
    defer reg.deinit(testing.allocator);

    const desc = IndexKindDescriptor{ .type_id = 128, .name = "vector" };
    try reg.register(testing.allocator, &desc);

    const desc2 = IndexKindDescriptor{ .type_id = 128, .name = "vector2" };
    try testing.expectError(error.DuplicateTypeId, reg.register(testing.allocator, &desc2));
}

test "IndexKindRegistry lookup returns null for unknown id" {
    var reg: IndexKindRegistry = .{};
    defer reg.deinit(testing.allocator);

    try testing.expect(reg.lookup(200) == null);
}

test "custom index kind round-trips through catalog save/load" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(path);

    const full_path = try std.fmt.allocPrint(testing.allocator, "{s}/ext_catalog.bin", .{path});
    defer testing.allocator.free(full_path);

    // Set up an isolated registry with a "vector" kind (type_id = 200).
    var reg: IndexKindRegistry = .{};
    defer reg.deinit(testing.allocator);

    const vector_desc = IndexKindDescriptor{ .type_id = 200, .name = "vector" };
    try reg.register(testing.allocator, &vector_desc);

    // Save a catalog with one builtin entry and one custom-kind entry.
    {
        var catalog = IndexCatalog.initWithRegistry(testing.allocator, &reg);
        defer catalog.deinit();

        try catalog.addIndex(.{
            .label_id = 10,
            .property_key = "embedding",
            .index_type = .{ .extension = 200 },
            .state = .active,
        });
        try catalog.addIndex(.{
            .label_id = 11,
            .property_key = "title",
            .index_type = .{ .builtin = .btree_property },
            .state = .active,
        });

        try catalog.saveToFile(full_path);
    }

    // Load it back using the same registry and verify both entries round-trip.
    {
        var catalog = IndexCatalog.initWithRegistry(testing.allocator, &reg);
        defer catalog.deinit();

        try catalog.loadFromFile(full_path);

        try testing.expectEqual(@as(usize, 2), catalog.indexes.items.len);

        const ext_entry = catalog.findIndex(10, "embedding");
        try testing.expect(ext_entry != null);
        // Verify the custom kind survived the round-trip.
        try testing.expect(ext_entry.?.index_type.eql(.{ .extension = 200 }));
        // The name is accessible via the registry.
        const loaded_desc = reg.lookup(ext_entry.?.index_type.typeId());
        try testing.expect(loaded_desc != null);
        try testing.expectEqualStrings("vector", loaded_desc.?.name);
        try testing.expectEqual(IndexState.active, ext_entry.?.state);

        const builtin_entry = catalog.findIndex(11, "title");
        try testing.expect(builtin_entry != null);
        try testing.expect(builtin_entry.?.index_type.eql(.{ .builtin = .btree_property }));
    }
}

test "loading catalog entry with unregistered type_id fails closed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(path);

    const full_path = try std.fmt.allocPrint(testing.allocator, "{s}/unknown_kind.bin", .{path});
    defer testing.allocator.free(full_path);

    // Write a catalog file with type_id = 200 (an extension range byte) but
    // do NOT register it in the registry used for loading.
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    @memcpy(buf[pos..][0..8], &CATALOG_MAGIC);
    pos += 8;
    std.mem.writeInt(u32, buf[pos..][0..4], CATALOG_VERSION, .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 1, .little); // entry_count = 1
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 99, .little); // label_id = 99
    pos += 4;
    buf[pos] = 200; // type_id = 200 (unregistered extension)
    pos += 1;
    buf[pos] = 1; // state = active
    pos += 1;
    std.mem.writeInt(u16, buf[pos..][0..2], 3, .little); // key_len = 3
    pos += 2;
    @memcpy(buf[pos..][0..3], "vec");
    pos += 3;
    const crc = Crc32.hash(buf[0..pos]);
    std.mem.writeInt(u32, buf[pos..][0..4], crc, .little);
    pos += 4;

    const file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), full_path, .{});
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), buf[0..pos]);
    file.close(std.Io.Threaded.global_single_threaded.io());

    // Load with an EMPTY registry: type_id 200 is unknown → must fail closed.
    var empty_reg: IndexKindRegistry = .{};
    defer empty_reg.deinit(testing.allocator);

    var catalog = IndexCatalog.initWithRegistry(testing.allocator, &empty_reg);
    defer catalog.deinit();

    try testing.expectError(error.InvalidData, catalog.loadFromFile(full_path));
}

test "IndexKind.typeId and eql" {
    const builtin_kind: IndexKind = .{ .builtin = .btree_property };
    try testing.expectEqual(@as(u8, 0), builtin_kind.typeId());

    const ext_kind: IndexKind = .{ .extension = 200 };
    try testing.expectEqual(@as(u8, 200), ext_kind.typeId());

    try testing.expect(builtin_kind.eql(.{ .builtin = .btree_property }));
    try testing.expect(!builtin_kind.eql(.{ .builtin = .label_posting }));
    try testing.expect(!builtin_kind.eql(.{ .extension = 0 }));
    try testing.expect(ext_kind.eql(.{ .extension = 200 }));
    try testing.expect(!ext_kind.eql(.{ .extension = 201 }));
    try testing.expect(!ext_kind.eql(.{ .builtin = .btree_property }));
}

test {
    std.testing.refAllDecls(@This());
}
