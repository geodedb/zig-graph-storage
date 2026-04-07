// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Legacy format import — detects Geode's current persistence formats and
//! provides infrastructure for bulk-loading into the new page store.
//!
//! For v1, the module provides:
//! - Storage state detection (matching Geode's storage/migration.zig logic)
//! - Per-graph header validation (GEODGRF1 magic, version, UUID, counts, CRC)
//! - Migration result struct
//! The actual bulk-load is stubbed until Geode's binary serialization format
//! reader is available.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Crc32 = std.hash.crc.Crc32Iscsi;
const operation_result_mod = @import("operation_result.zig");
const GraphOperationSummary = operation_result_mod.GraphOperationSummary;

/// Magic bytes for the per-graph file header.
pub const PER_GRAPH_MAGIC: [8]u8 = .{ 'G', 'E', 'O', 'D', 'G', 'R', 'F', '1' };

/// Size of the per-graph header in bytes:
/// magic(8) + version(4) + uuid(16) + node_count(8) + edge_count(8) + CRC32(4) = 48
pub const PER_GRAPH_HEADER_SIZE: usize = 48;

/// Detected state of the data directory's storage format.
pub const StorageState = enum {
    /// No data files found.
    fresh,
    /// graph_store.dat exists (old single-file format).
    legacy_monolithic,
    /// graph_registry.dat + per-graph UUID files.
    per_graph,
    /// Both graph_store.dat AND graph_registry.dat without .migrated marker
    /// (interrupted migration).
    interrupted,
};

/// Result of a migration operation.
pub const MigrationResult = struct {
    graphs_migrated: u64 = 0,
    total_nodes: u64 = 0,
    total_edges: u64 = 0,

    pub fn writeJson(self: *const MigrationResult, writer: anytype) !void {
        const summary = GraphOperationSummary{
            .operation = .migration,
            .status = .ok,
            .items_processed = self.graphs_migrated,
            .bytes_processed = 0,
            .issue_count = 0,
            .changed = self.graphs_migrated > 0,
        };
        try writer.writeByte('{');
        try summary.writeJsonFields(writer);
        try writer.print(
            ",\"graphs_migrated\":{d},\"total_nodes\":{d},\"total_edges\":{d}}}",
            .{ self.graphs_migrated, self.total_nodes, self.total_edges },
        );
    }
};

/// Parsed per-graph file header.
pub const PerGraphHeader = struct {
    version: u32,
    graph_uuid: [16]u8,
    node_count: u64,
    edge_count: u64,
};

/// Legacy format migration infrastructure.
///
/// Detects storage states and validates per-graph headers. The actual
/// bulk-load from Geode's binary format is stubbed for v1.
pub const Migration = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) Migration {
        return .{ .allocator = allocator };
    }

    /// Detect the storage state of a data directory by checking for
    /// known marker files.
    pub fn detectStorageState(self: *const Migration, data_dir: []const u8) StorageState {
        _ = self;

        const has_monolithic = fileExists(data_dir, "graph_store.dat");
        const has_registry = fileExists(data_dir, "graph_registry.dat");
        const has_migrated = fileExists(data_dir, "graph_store.dat.migrated");

        if (has_monolithic and has_registry and !has_migrated) {
            return .interrupted;
        }
        if (has_registry) {
            return .per_graph;
        }
        if (has_monolithic) {
            return .legacy_monolithic;
        }
        return .fresh;
    }

    /// Validate that a file has the GEODGRF1 magic header and a correct CRC.
    pub fn validatePerGraphHeader(self: *const Migration, path: []const u8) !PerGraphHeader {
        _ = self;

        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        var buf: [PER_GRAPH_HEADER_SIZE]u8 = undefined;
        const bytes_read = try file.readAll(&buf);
        if (bytes_read < PER_GRAPH_HEADER_SIZE) return error.InvalidData;

        // Validate magic
        if (!std.mem.eql(u8, buf[0..8], &PER_GRAPH_MAGIC)) return error.InvalidMagic;

        // Parse fields
        var pos: usize = 8;
        const version = readU32(&buf, pos);
        pos += 4;

        var uuid: [16]u8 = undefined;
        @memcpy(&uuid, buf[pos..][0..16]);
        pos += 16;

        const node_count = readU64(&buf, pos);
        pos += 8;

        const edge_count = readU64(&buf, pos);
        pos += 8;

        // Validate CRC32 over everything before the checksum
        const stored_crc = readU32(&buf, pos);
        const computed_crc = Crc32.hash(buf[0..pos]);
        if (stored_crc != computed_crc) return error.ChecksumMismatch;

        return .{
            .version = version,
            .graph_uuid = uuid,
            .node_count = node_count,
            .edge_count = edge_count,
        };
    }

    /// Migrate legacy format data into a new graph storage engine.
    ///
    /// This is a stub for v1 — full migration requires the old serialization
    /// format reader. For now, provide detection and header validation
    /// infrastructure.
    pub fn migrate(self: *Migration, data_dir: []const u8, target_dir: []const u8) !MigrationResult {
        _ = target_dir;
        const state = self.detectStorageState(data_dir);
        return switch (state) {
            .fresh => .{},
            .per_graph => .{}, // Would iterate registry and load each graph
            .legacy_monolithic => .{}, // Would load single file
            .interrupted => .{}, // Would clean up and retry
        };
    }
};

/// Serialize a per-graph header to bytes (for testing).
pub fn serializePerGraphHeader(header: PerGraphHeader, buf: *[PER_GRAPH_HEADER_SIZE]u8) void {
    var pos: usize = 0;

    // Magic
    @memcpy(buf[pos..][0..8], &PER_GRAPH_MAGIC);
    pos += 8;

    // Version
    writeU32(buf, &pos, header.version);

    // UUID
    @memcpy(buf[pos..][0..16], &header.graph_uuid);
    pos += 16;

    // Counts
    writeU64(buf, &pos, header.node_count);
    writeU64(buf, &pos, header.edge_count);

    // CRC32 over everything before the checksum
    const crc = Crc32.hash(buf[0..pos]);
    writeU32(buf, &pos, crc);
}

// ============================================================================
// Helpers
// ============================================================================

fn fileExists(dir_path: []const u8, name: []const u8) bool {
    // Build path on stack using a fixed buffer
    var path_buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch return false;
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

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

test "detectStorageState: empty dir returns fresh" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const m = Migration.init(allocator);
    const state = m.detectStorageState(tmp_path);
    try std.testing.expectEqual(StorageState.fresh, state);
}

test "detectStorageState: graph_registry.dat returns per_graph" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create graph_registry.dat
    const file = try tmp_dir.dir.createFile("graph_registry.dat", .{});
    file.close();

    const m = Migration.init(allocator);
    const state = m.detectStorageState(tmp_path);
    try std.testing.expectEqual(StorageState.per_graph, state);
}

test "detectStorageState: graph_store.dat returns legacy_monolithic" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create graph_store.dat
    const file = try tmp_dir.dir.createFile("graph_store.dat", .{});
    file.close();

    const m = Migration.init(allocator);
    const state = m.detectStorageState(tmp_path);
    try std.testing.expectEqual(StorageState.legacy_monolithic, state);
}

test "detectStorageState: both files without migrated marker returns interrupted" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create both files
    const f1 = try tmp_dir.dir.createFile("graph_store.dat", .{});
    f1.close();
    const f2 = try tmp_dir.dir.createFile("graph_registry.dat", .{});
    f2.close();

    const m = Migration.init(allocator);
    const state = m.detectStorageState(tmp_path);
    try std.testing.expectEqual(StorageState.interrupted, state);
}

test "detectStorageState: both files with migrated marker returns per_graph" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create both files + .migrated marker
    const f1 = try tmp_dir.dir.createFile("graph_store.dat", .{});
    f1.close();
    const f2 = try tmp_dir.dir.createFile("graph_registry.dat", .{});
    f2.close();
    const f3 = try tmp_dir.dir.createFile("graph_store.dat.migrated", .{});
    f3.close();

    const m = Migration.init(allocator);
    const state = m.detectStorageState(tmp_path);
    try std.testing.expectEqual(StorageState.per_graph, state);
}

test "validatePerGraphHeader: valid header" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0xAB);

    const header = PerGraphHeader{
        .version = 1,
        .graph_uuid = uuid,
        .node_count = 100,
        .edge_count = 200,
    };

    var buf: [PER_GRAPH_HEADER_SIZE]u8 = undefined;
    serializePerGraphHeader(header, &buf);

    // Write to file
    const file_path = try std.fmt.allocPrint(allocator, "{s}/test_graph.dat", .{tmp_path});
    defer allocator.free(file_path);

    const file = try std.fs.cwd().createFile(file_path, .{});
    try file.writeAll(&buf);
    file.close();

    const m = Migration.init(allocator);
    const parsed = try m.validatePerGraphHeader(file_path);

    try std.testing.expectEqual(@as(u32, 1), parsed.version);
    try std.testing.expectEqual(uuid, parsed.graph_uuid);
    try std.testing.expectEqual(@as(u64, 100), parsed.node_count);
    try std.testing.expectEqual(@as(u64, 200), parsed.edge_count);
}

test "validatePerGraphHeader: invalid magic" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0xAB);

    var buf: [PER_GRAPH_HEADER_SIZE]u8 = undefined;
    serializePerGraphHeader(.{
        .version = 1,
        .graph_uuid = uuid,
        .node_count = 0,
        .edge_count = 0,
    }, &buf);

    // Corrupt magic
    buf[0] = 'X';

    const file_path = try std.fmt.allocPrint(allocator, "{s}/bad_magic.dat", .{tmp_path});
    defer allocator.free(file_path);

    const file = try std.fs.cwd().createFile(file_path, .{});
    try file.writeAll(&buf);
    file.close();

    const m = Migration.init(allocator);
    const result = m.validatePerGraphHeader(file_path);
    try std.testing.expectError(error.InvalidMagic, result);
}

test "validatePerGraphHeader: corrupted CRC" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var uuid: [16]u8 = undefined;
    @memset(&uuid, 0xCD);

    var buf: [PER_GRAPH_HEADER_SIZE]u8 = undefined;
    serializePerGraphHeader(.{
        .version = 1,
        .graph_uuid = uuid,
        .node_count = 50,
        .edge_count = 75,
    }, &buf);

    // Corrupt data (but not magic)
    buf[12] ^= 0xFF;

    const file_path = try std.fmt.allocPrint(allocator, "{s}/bad_crc.dat", .{tmp_path});
    defer allocator.free(file_path);

    const file = try std.fs.cwd().createFile(file_path, .{});
    try file.writeAll(&buf);
    file.close();

    const m = Migration.init(allocator);
    const result = m.validatePerGraphHeader(file_path);
    try std.testing.expectError(error.ChecksumMismatch, result);
}

test "migrate: fresh directory returns zero result" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var m = Migration.init(allocator);
    const result = try m.migrate(tmp_path, "/tmp/target");

    try std.testing.expectEqual(@as(u64, 0), result.graphs_migrated);
    try std.testing.expectEqual(@as(u64, 0), result.total_nodes);
    try std.testing.expectEqual(@as(u64, 0), result.total_edges);
}

test "MigrationResult writeJson produces valid structured output" {
    const result = MigrationResult{
        .graphs_migrated = 2,
        .total_nodes = 15,
        .total_edges = 27,
    };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);

    try result.writeJson(buf.writer(std.testing.allocator));
    const json = buf.items;

    try std.testing.expect(std.mem.indexOf(u8, json, "\"operation\":\"migration\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"graphs_migrated\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total_nodes\":15") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total_edges\":27") != null);
}

test {
    std.testing.refAllDecls(@This());
}
