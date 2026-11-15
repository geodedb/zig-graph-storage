// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6590: with at-rest encryption (GraphConfig.encryption_key) the store
// pages and the WAL are encrypted, but the side files that hold schema names
// were written in plaintext:
//   * labels.dict (every shard)  — label and relationship-type names;
//   * props.idx                  — property-key names (+ unkeyed value hashes);
//   * ordered_propidx.snap       — property-key names AND the indexed values;
//   * props.catalog              — property-key names of declared indexes.
// Schema names reveal what a database stores ("Patient", "ssn"), and the
// operations guide tells operators that the key protects the data at rest.
//
// Each test writes distinctive names and values through the real engine,
// then reads EVERY file under the data directory and looks for them as raw
// bytes: after a clean close, after a crash (no close) and after the reopen
// that recovers it, for a single GraphEngine and for a ShardedGraphEngine.
// The names must still resolve after every reopen.
//
// Upgrade: a store written by graph_storage <= 0.4.16 under a key (manifest
// format_version 4, side files in the plaintext layout) must open, keep every
// name, and leave no plaintext name behind.
//
// Integrity: a labels.dict from another graph must not be accepted (an
// accepted foreign dictionary silently remaps every label id).

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const GraphEngine = gs.GraphEngine;
const ShardedGraphEngine = gs.ShardedGraphEngine;
const GraphConfig = gs.GraphConfig;
const LabelId = gs.LabelId;
const NodeId = gs.NodeId;
const SHARD_COUNT = gs.sharded_engine.SHARD_COUNT;
const test_support = gs.test_support;

const io = std.Io.Threaded.global_single_threaded.io();

// Test-only key; never a real key.
const KEY: [32]u8 = [_]u8{0x5A} ** 32;

const LABEL_PATIENT = "Zq7PatientLabel";
const LABEL_DIAGNOSIS = "Zq7DiagnosisLabel";
const REL_TYPE = "Zq7DIAGNOSED_WITH";
const LATE_LABEL = "Zq7LateLabelAfterCheckpoint";
const KEY_SSN = "Zq7ssnKey";
const KEY_MRN = "Zq7mrnOrderedKey";
const KEY_BTREE = "Zq7btreeIndexedKey";
const KEY_EDGE = "Zq7icdEdgeKey";
const VAL_SSN = "Zq7val-123-45-6789";
const VAL_MRN = "Zq7mrnValue0001";
const VAL_EDGE = "Zq7icdValueJ45";

/// Every byte string that must never appear in plaintext on disk.
const NEEDLES = [_][]const u8{
    LABEL_PATIENT, LABEL_DIAGNOSIS, REL_TYPE,  LATE_LABEL,
    KEY_SSN,       KEY_MRN,         KEY_BTREE, KEY_EDGE,
    VAL_SSN,       VAL_MRN,         VAL_EDGE,
};

fn uuidFor(tag: u8) [16]u8 {
    return [_]u8{ 0x65, 0x90, tag } ++ [_]u8{0x59} ** 13;
}

fn tdeConfig() GraphConfig {
    var cfg = test_support.testConfig();
    cfg.encryption_key = KEY;
    return cfg;
}

fn plainConfig() GraphConfig {
    return test_support.testConfig();
}

// ---------------------------------------------------------------------------
// scanning
// ---------------------------------------------------------------------------

const Finding = struct { file: []u8, needle: []const u8 };

const Findings = struct {
    alloc: Allocator,
    items: std.ArrayList(Finding) = .empty,

    fn deinit(self: *Findings) void {
        for (self.items.items) |f| self.alloc.free(f.file);
        self.items.deinit(self.alloc);
    }

    fn report(self: *const Findings, what: []const u8) void {
        for (self.items.items) |f| {
            std.debug.print("{s}: plaintext '{s}' in {s}\n", .{ what, f.needle, f.file });
        }
    }
};

/// Read every regular file under `root` and record each needle found in it.
fn scanTree(alloc: Allocator, root: []const u8) !Findings {
    var out = Findings{ .alloc = alloc };
    errdefer out.deinit();
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const f = try entry.dir.openFile(io, entry.basename, .{});
        defer f.close(io);
        const st = try f.stat(io);
        const size: usize = @intCast(st.size);
        const buf = try alloc.alloc(u8, size);
        defer alloc.free(buf);
        const n = try f.readPositionalAll(io, buf, 0);
        for (NEEDLES) |needle| {
            if (std.mem.indexOf(u8, buf[0..n], needle) != null) {
                try out.items.append(alloc, .{ .file = try alloc.dupe(u8, entry.path), .needle = needle });
            }
        }
    }
    return out;
}

/// Fail (printing every hit) when any needle is on disk under `root`.
fn expectNoPlaintext(alloc: Allocator, root: []const u8, what: []const u8) !void {
    var found = try scanTree(alloc, root);
    defer found.deinit();
    if (found.items.items.len != 0) {
        found.report(what);
        return error.SchemaNamesInPlaintext;
    }
}

// ---------------------------------------------------------------------------
// workload
// ---------------------------------------------------------------------------

const Ids = struct {
    patient: LabelId,
    diagnosis: LabelId,
    rel: LabelId,
};

/// One node per label with string properties, an edge with a property, an
/// ordered index and a declared B+tree index — single engine.
fn workloadSingle(eng: *GraphEngine) !Ids {
    const ids = Ids{
        .patient = try eng.getOrAssignLabel(LABEL_PATIENT),
        .diagnosis = try eng.getOrAssignLabel(LABEL_DIAGNOSIS),
        .rel = try eng.getOrAssignLabel(REL_TYPE),
    };
    const a = try eng.allocNode();
    try eng.putNode(a, test_support.emptyNode(1));
    var rec = (try eng.getNode(a)).?;
    rec.prop_head = try eng.putProperty(rec.prop_head, KEY_SSN, .{ .string = VAL_SSN });
    rec.prop_head = try eng.putProperty(rec.prop_head, KEY_MRN, .{ .string = VAL_MRN });
    rec.prop_head = try eng.putProperty(rec.prop_head, KEY_BTREE, .{ .int = 42 });
    try eng.putNode(a, rec);
    try eng.addLabel(a, ids.patient);

    const b = try eng.allocNode();
    try eng.putNode(b, test_support.emptyNode(1));
    try eng.addLabel(b, ids.diagnosis);

    const e = try eng.addEdge(a, b, ids.rel);
    try eng.setEdgeProperty(a, b, e, KEY_EDGE, .{ .string = VAL_EDGE });

    try eng.createOrderedIndex(ids.patient, KEY_MRN);
    try eng.createPropertyIndex(ids.patient, KEY_BTREE);
    return ids;
}

fn expectNamesSingle(eng: *GraphEngine, ids: Ids, late: bool) !void {
    try testing.expectEqual(@as(?LabelId, ids.patient), eng.label_dict.getId(LABEL_PATIENT));
    try testing.expectEqual(@as(?LabelId, ids.diagnosis), eng.label_dict.getId(LABEL_DIAGNOSIS));
    try testing.expectEqual(@as(?LabelId, ids.rel), eng.label_dict.getId(REL_TYPE));
    try testing.expectEqualStrings(LABEL_PATIENT, eng.label_dict.getName(ids.patient).?);
    if (late) try testing.expect(eng.label_dict.getId(LATE_LABEL) != null);
    try testing.expect(eng.hasOrderedIndex(ids.patient, KEY_MRN));
}

/// The sharded workload: names via the facade (shard 0 then 1..N-1), one
/// labelled node with properties and one edge on every shard.
fn workloadSharded(eng: *ShardedGraphEngine) !Ids {
    const ids = Ids{
        .patient = try eng.getOrAssignLabel(LABEL_PATIENT),
        .diagnosis = try eng.getOrAssignLabel(LABEL_DIAGNOSIS),
        .rel = try eng.getOrAssignLabel(REL_TYPE),
    };
    for (0..SHARD_COUNT) |k| {
        const a = try eng.shards[k].allocNode();
        try eng.putNode(a, test_support.emptyNode(1));
        var rec = (try eng.getNode(a)).?;
        rec.prop_head = try eng.putNodeProperty(a, rec.prop_head, KEY_SSN, .{ .string = VAL_SSN });
        rec.prop_head = try eng.putNodeProperty(a, rec.prop_head, KEY_MRN, .{ .string = VAL_MRN });
        try eng.putNode(a, rec);
        try eng.addLabel(a, ids.patient);
        const b = try eng.shards[k].allocNode();
        try eng.putNode(b, test_support.emptyNode(1));
        try eng.addLabel(b, ids.diagnosis);
        const e = try eng.addEdge(a, b, ids.rel);
        try eng.setEdgeProperty(a, b, e, KEY_EDGE, .{ .string = VAL_EDGE });
        try eng.shards[k].createOrderedIndex(ids.patient, KEY_MRN);
    }
    return ids;
}

fn expectNamesSharded(eng: *ShardedGraphEngine, ids: Ids, late: bool) !void {
    for (eng.shards) |s| {
        try testing.expectEqual(@as(?LabelId, ids.patient), s.label_dict.getId(LABEL_PATIENT));
        try testing.expectEqual(@as(?LabelId, ids.diagnosis), s.label_dict.getId(LABEL_DIAGNOSIS));
        try testing.expectEqual(@as(?LabelId, ids.rel), s.label_dict.getId(REL_TYPE));
        if (late) try testing.expect(s.label_dict.getId(LATE_LABEL) != null);
    }
}

// ---------------------------------------------------------------------------
// single engine
// ---------------------------------------------------------------------------

test "SONNY-6590: GraphEngine under TDE writes no schema name or indexed value in plaintext (clean close, reopen)" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(1);

    var ids: Ids = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, tdeConfig());
        defer eng.close() catch {};
        ids = try workloadSingle(eng);
        try eng.checkpoint();
        _ = try eng.getOrAssignLabel(LATE_LABEL);
    }
    try expectNoPlaintext(alloc, td.path, "after clean close");
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, tdeConfig());
        defer eng.close() catch {};
        try expectNamesSingle(eng, ids, true);
        try eng.checkpoint();
    }
    try expectNoPlaintext(alloc, td.path, "after reopen + checkpoint + close");
}

test "SONNY-6590: GraphEngine under TDE writes no schema name in plaintext across a crash and recovery" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(2);

    var ids: Ids = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, tdeConfig());
        errdefer eng.deinit();
        ids = try workloadSingle(eng);
        try eng.checkpoint();
        _ = try eng.getOrAssignLabel(LATE_LABEL);
        eng.deinit(); // crash: no close
    }
    try expectNoPlaintext(alloc, td.path, "after crash");
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, tdeConfig());
        defer eng.close() catch {};
        try expectNamesSingle(eng, ids, true);
    }
    try expectNoPlaintext(alloc, td.path, "after recovery + close");
}

// ---------------------------------------------------------------------------
// sharded engine
// ---------------------------------------------------------------------------

test "SONNY-6590: ShardedGraphEngine under TDE writes no schema name in plaintext on any shard (close, crash, reopen)" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = uuidFor(3);

    var ids: Ids = undefined;
    {
        const eng = try ShardedGraphEngine.create(alloc, td.path, uuid, tdeConfig());
        defer eng.close() catch {};
        ids = try workloadSharded(eng);
        try eng.checkpoint();
    }
    try expectNoPlaintext(alloc, td.path, "sharded: after clean close");
    {
        const eng = try ShardedGraphEngine.open(alloc, td.path, uuid, tdeConfig());
        errdefer eng.deinit();
        try expectNamesSharded(eng, ids, false);
        _ = try eng.getOrAssignLabel(LATE_LABEL);
        eng.deinit(); // crash: no close
    }
    try expectNoPlaintext(alloc, td.path, "sharded: after crash");
    {
        const eng = try ShardedGraphEngine.open(alloc, td.path, uuid, tdeConfig());
        defer eng.close() catch {};
        try expectNamesSharded(eng, ids, true);
    }
    try expectNoPlaintext(alloc, td.path, "sharded: after recovery + close");
}

// ---------------------------------------------------------------------------
// upgrade from <= 0.4.16
// ---------------------------------------------------------------------------

/// Copy `name` from graph directory `from` to graph directory `to` (skip when
/// absent in `from`).
fn copySideFile(alloc: Allocator, from: []const u8, to: []const u8, name: []const u8) !void {
    const src = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ from, name });
    defer alloc.free(src);
    const dst = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ to, name });
    defer alloc.free(dst);
    std.Io.Dir.copyFile(std.Io.Dir.cwd(), src, std.Io.Dir.cwd(), dst, io, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

/// Rewrite both manifest slots of `graph_path` with format_version 4, the
/// version graph_storage <= 0.4.16 writes.
fn setManifestVersion(alloc: Allocator, graph_path: []const u8, version: u32) !void {
    for ([_][]const u8{ "manifest.a", "manifest.b" }) |slot| {
        const p = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ graph_path, slot });
        defer alloc.free(p);
        var m = (gs.manifest.Manifest.readFromFileWithKey(alloc, p, KEY) catch continue) orelse continue;
        m.format_version = version;
        try m.writeToFileWithKey(alloc, p, KEY);
    }
}

fn graphPathOf(alloc: Allocator, data_dir: []const u8, uuid: [16]u8) ![]u8 {
    const hex = gs.sharded_engine.uuidHex(uuid);
    return std.fmt.allocPrint(alloc, "{s}/graphs/{s}", .{ data_dir, &hex });
}

test "SONNY-6590: a store written by <= 0.4.16 under TDE (plaintext side files) opens, keeps every name and leaves no plaintext" {
    const alloc = testing.allocator;
    var td_old = try test_support.TestDataDir.init(alloc);
    defer td_old.deinit();
    var td_plain = try test_support.TestDataDir.init(alloc);
    defer td_plain.deinit();
    const uuid = uuidFor(4);

    // The same operations against a plaintext twin with the same graph id
    // produce, byte for byte, the side files <= 0.4.16 writes under a key.
    var ids: Ids = undefined;
    inline for (.{ true, false }) |encrypted| {
        const dir = if (encrypted) td_old.path else td_plain.path;
        const eng = try GraphEngine.create(alloc, dir, uuid, if (encrypted) tdeConfig() else plainConfig());
        defer eng.close() catch {};
        ids = try workloadSingle(eng);
        try eng.checkpoint();
    }
    const old_graph = blk: {
        const eng = try GraphEngine.open(alloc, td_old.path, uuid, tdeConfig());
        defer eng.close() catch {};
        break :blk try alloc.dupe(u8, eng.graph_dir.path);
    };
    defer alloc.free(old_graph);
    const plain_graph = try graphPathOf(alloc, td_plain.path, uuid);
    defer alloc.free(plain_graph);
    for ([_][]const u8{ "labels.dict", "props.idx", "ordered_propidx.snap", "props.catalog" }) |name| {
        try copySideFile(alloc, plain_graph, old_graph, name);
    }
    try setManifestVersion(alloc, old_graph, 4);

    {
        const eng = try GraphEngine.open(alloc, td_old.path, uuid, tdeConfig());
        defer eng.close() catch {};
        try expectNamesSingle(eng, ids, false);
        // Every property key still answers through the rebuilt derived index.
        const a: NodeId = 1;
        const rec = (try eng.getNode(a)).?;
        const v = (try eng.getProperty(rec.prop_head, KEY_SSN, alloc)).?;
        defer gs.property.freeDecoded(alloc, v);
        try testing.expectEqualStrings(VAL_SSN, v.string);
    }
    try expectNoPlaintext(alloc, td_old.path, "after opening a <= 0.4.16 store");
}

// ---------------------------------------------------------------------------
// integrity
// ---------------------------------------------------------------------------

test "SONNY-6590: a labels.dict copied from another encrypted graph is refused, never adopted" {
    const alloc = testing.allocator;
    var td = try test_support.TestDataDir.init(alloc);
    defer td.deinit();
    const victim = uuidFor(5);
    const donor = uuidFor(6);

    var victim_path: []u8 = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, victim, tdeConfig());
        defer eng.close() catch {};
        _ = try eng.getOrAssignLabel(LABEL_PATIENT);
        _ = try eng.getOrAssignLabel(LABEL_DIAGNOSIS);
        victim_path = try alloc.dupe(u8, eng.graph_dir.path);
    }
    defer alloc.free(victim_path);
    var donor_path: []u8 = undefined;
    {
        const eng = try GraphEngine.create(alloc, td.path, donor, tdeConfig());
        defer eng.close() catch {};
        // Same ids, other meanings.
        _ = try eng.getOrAssignLabel(LABEL_DIAGNOSIS);
        _ = try eng.getOrAssignLabel(LABEL_PATIENT);
        donor_path = try alloc.dupe(u8, eng.graph_dir.path);
    }
    defer alloc.free(donor_path);
    try copySideFile(alloc, donor_path, victim_path, "labels.dict");

    if (GraphEngine.open(alloc, td.path, victim, tdeConfig())) |eng| {
        defer eng.close() catch {};
        std.debug.print("foreign labels.dict adopted: id {?d} now names '{s}'\n", .{ eng.label_dict.getId(LABEL_PATIENT), eng.label_dict.getName(0) orelse "<none>" });
        return error.ForeignLabelDictionaryAdopted;
    } else |_| {}
}
