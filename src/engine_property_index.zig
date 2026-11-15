// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! GAP-0027 / FR-016 / FR-017: opt-in B+tree property indexes wired into the
//! engine lifecycle.
//!
//! This module owns the per-graph `IndexCatalog` plus the live B+tree-backed
//! `PropertyIndex` instances that back declared indexes. It mirrors the
//! load-on-open / save-on-checkpoint discipline of the existing derived
//! indexes (engine_index.zig) but is strictly OPT-IN: a graph with no declared
//! index keeps no catalog file and behaves exactly as before. A missing catalog
//! is therefore treated as "no indexes", never an error.
//!
//! On-disk layout (under the graph directory):
//!   - `props.catalog`            : the IndexCatalog (magic + version + CRC32).
//!   - `propidx_<label>_<hash>.btree` : one B+tree snapshot per declared index,
//!                                   where <hash> is the Wyhash of the property
//!                                   key (keeps file names bounded + collision
//!                                   resistant). Each file is magic + version +
//!                                   CRC32 verified before its contents are
//!                                   trusted (SEC-0051 verify-before-trust).

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const node_mod = @import("node.zig");
const property_mod = @import("property.zig");
const index_catalog_mod = @import("index_catalog.zig");
const property_index_mod = @import("property_index.zig");
const engine_mod = @import("engine.zig");
const engine_persist = @import("engine_persist.zig");
const side_file_crypto = @import("side_file_crypto.zig");

const NodeId = types.NodeId;
const LabelId = types.LabelId;
const PropertyValue = types.PropertyValue;
const NodeRec = node_mod.NodeRec;
const IndexCatalog = index_catalog_mod.IndexCatalog;
const IndexType = index_catalog_mod.IndexType;
const IndexKind = index_catalog_mod.IndexKind;
const IndexState = index_catalog_mod.IndexState;
const PropertyIndex = property_index_mod.PropertyIndex;
const GraphEngine = engine_mod.GraphEngine;

/// File name for the per-graph index catalog.
const CATALOG_FILE_NAME = index_catalog_mod.FILE_NAME;

/// Owns the catalog and the set of live B+tree property indexes for one engine.
///
/// `live` is parallel to the active catalog entries of type `btree_property`:
/// each `PropertyIndex` is keyed by `(label_id, property_key)` exactly as the
/// matching `IndexDef`. The catalog is the durable source of truth for *which*
/// indexes exist; `live` holds the in-memory B+trees that serve lookups.
pub const PropertyIndexSet = struct {
    allocator: Allocator,
    catalog: IndexCatalog,
    live: std.ArrayList(PropertyIndex),

    pub fn init(allocator: Allocator) PropertyIndexSet {
        return .{
            .allocator = allocator,
            .catalog = IndexCatalog.init(allocator),
            .live = .empty,
        };
    }

    pub fn deinit(self: *PropertyIndexSet) void {
        for (self.live.items) |*idx| idx.deinit();
        self.live.deinit(self.allocator);
        self.catalog.deinit();
    }

    /// Find the live B+tree index for `(label_id, property_key)`, if any.
    fn findLive(self: *PropertyIndexSet, label_id: LabelId, property_key: []const u8) ?*PropertyIndex {
        for (self.live.items) |*idx| {
            if (idx.label_id == label_id and std.mem.eql(u8, idx.property_key, property_key)) {
                return idx;
            }
        }
        return null;
    }

    /// Drop every live B+tree instance (used before a full reload).
    fn clearLive(self: *PropertyIndexSet) void {
        for (self.live.items) |*idx| idx.deinit();
        self.live.clearRetainingCapacity();
    }
};

/// Hash a property value into the B+tree key space. Uses the same Wyhash seed
/// as property_chain_index so equality lookups are consistent regardless of how
/// the value entered the index (build scan vs. live insert vs. query).
pub fn hashEncodedValue(encoded_value: []const u8) u64 {
    // fips-exempt: non-security — non-cryptographic Wyhash mapping a value
    // into the B+tree key space for equality lookups.
    return std.hash.Wyhash.hash(0, encoded_value);
}

/// Hash a caller-supplied PropertyValue (for query paths). Encodes into a
/// stack buffer for the common fixed-size case, falling back to a heap slice
/// for variable-length values (string/ext), exactly mirroring putPropertyTxn.
fn hashValue(allocator: Allocator, value: PropertyValue) !u64 {
    var stack_buf: [32]u8 = undefined;
    const enc_size = property_mod.encodedSize(value);
    if (enc_size <= stack_buf.len) {
        _ = property_mod.encodeInto(&stack_buf, value) catch unreachable;
        return hashEncodedValue(stack_buf[0..enc_size]);
    }
    const heap = try allocator.alloc(u8, enc_size);
    defer allocator.free(heap);
    _ = property_mod.encodeInto(heap, value) catch unreachable;
    return hashEncodedValue(heap);
}

/// Build (or rebuild) the B+tree for a single declared index by scanning every
/// live node, filtering to those carrying `label_id`, and indexing the value of
/// `property_key` from each such node's property chain.
///
/// FR-017 offline build flow: the tree is populated fully from the primary
/// stores before it is published to `live`, so a partially-built tree is never
/// queryable.
fn buildIndexTree(engine: *GraphEngine, label_id: LabelId, property_key: []const u8) !PropertyIndex {
    var idx = try PropertyIndex.init(engine.allocator, label_id, property_key);
    errdefer idx.deinit();

    const Ctx = struct {
        engine: *GraphEngine,
        idx: *PropertyIndex,
        label_id: LabelId,
        property_key: []const u8,
        err: ?anyerror = null,

        fn callback(self: *@This(), node_id: NodeId, rec: NodeRec) void {
            if (self.err != null) return;
            if (rec.prop_head == 0) return;

            // Filter by label: only nodes carrying label_id are indexed.
            if (rec.label_head == 0) return;
            const labels = self.engine.label_store.getLabels(rec.label_head, self.engine.allocator) catch |e| {
                self.err = e;
                return;
            };
            defer self.engine.allocator.free(labels);
            var has_label = false;
            for (labels) |l| {
                if (l == self.label_id) {
                    has_label = true;
                    break;
                }
            }
            if (!has_label) return;

            // Find the indexed property in the node's chain and index its value.
            var iter = self.engine.prop_store.getAllProperties(rec.prop_head);
            defer iter.deinit();
            while (iter.next() catch |e| {
                self.err = e;
                return;
            }) |entry| {
                if (std.mem.eql(u8, entry.key, self.property_key)) {
                    const value_hash = hashEncodedValue(entry.encoded_value);
                    self.idx.insert(node_id, value_hash) catch |e| {
                        self.err = e;
                        return;
                    };
                    break;
                }
            }
        }
    };

    var ctx = Ctx{
        .engine = engine,
        .idx = &idx,
        .label_id = label_id,
        .property_key = property_key,
    };
    try engine.node_store.scanNodes(engine.manifest.next_node_id, &ctx, Ctx.callback);
    if (ctx.err) |e| return e;

    return idx;
}

/// Build the absolute path of the per-graph catalog file. Caller owns the slice.
fn catalogPath(engine: *GraphEngine) ![]u8 {
    return std.fmt.allocPrint(engine.allocator, "{s}/{s}", .{ engine.graph_dir.path, CATALOG_FILE_NAME });
}

/// Build the absolute path of a single index's B+tree snapshot. Caller owns it.
/// The key is folded into a Wyhash so the file name stays bounded and free of
/// path-traversal characters even for arbitrary property keys (defense in depth:
/// the key never reaches the filesystem verbatim).
fn indexTreePath(engine: *GraphEngine, label_id: LabelId, property_key: []const u8) ![]u8 {
    // fips-exempt: non-security — non-cryptographic Wyhash folding the key
    // into a bounded, traversal-safe filename component.
    const key_hash = std.hash.Wyhash.hash(0, property_key);
    return std.fmt.allocPrint(
        engine.allocator,
        "{s}/propidx_{d}_{x}.btree",
        .{ engine.graph_dir.path, label_id, key_hash },
    );
}

/// FR-016: declare and build a B+tree property index on `(label_id, property_key)`.
///
/// Idempotent: if the index is already declared, this is a no-op that returns
/// without rebuilding. Otherwise it records the index in the catalog, performs
/// an offline build from the primary stores, publishes the live B+tree, and
/// marks the engine dirty so the next checkpoint persists both the catalog and
/// the tree.
pub fn createPropertyIndex(engine: *GraphEngine, label_id: LabelId, property_key: []const u8) !void {
    const set = &engine.property_index_set;

    if (set.catalog.findIndex(label_id, property_key) != null) {
        // Already declared — keep the existing (possibly live) index intact.
        return;
    }

    // Build the tree first so a build failure leaves the catalog untouched.
    var tree = try buildIndexTree(engine, label_id, property_key);
    errdefer tree.deinit();

    try set.live.append(set.allocator, tree);
    errdefer _ = set.live.pop();

    try set.catalog.addIndex(.{
        .label_id = label_id,
        .property_key = property_key,
        .index_type = .{ .builtin = .btree_property },
        .state = .active,
    });

    engine.property_catalog_dirty = true;
    engine.markPersistenceDirty();
}

/// FR-016: drop a declared B+tree property index. Returns true if it existed.
pub fn dropPropertyIndex(engine: *GraphEngine, label_id: LabelId, property_key: []const u8) !bool {
    const set = &engine.property_index_set;
    if (set.catalog.findIndex(label_id, property_key) == null) return false;

    // Remove the live tree (if present) and the catalog entry.
    for (set.live.items, 0..) |*idx, i| {
        if (idx.label_id == label_id and std.mem.eql(u8, idx.property_key, property_key)) {
            idx.deinit();
            _ = set.live.orderedRemove(i);
            break;
        }
    }
    _ = set.catalog.removeIndex(label_id, property_key);

    // Remove the on-disk snapshot if it exists; missing is fine.
    const path = try indexTreePath(engine, label_id, property_key);
    defer engine.allocator.free(path);
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    engine.property_catalog_dirty = true;
    engine.markPersistenceDirty();
    return true;
}

/// FR-017 equality lookup: return the node id indexed for `value` under the
/// declared index, or null when no index is declared or no node matches.
pub fn lookupPropertyIndex(
    engine: *GraphEngine,
    label_id: LabelId,
    property_key: []const u8,
    value: PropertyValue,
) !?NodeId {
    const set = &engine.property_index_set;
    const idx = set.findLive(label_id, property_key) orelse return null;
    const value_hash = try hashValue(engine.allocator, value);
    return idx.findExact(value_hash);
}

/// FR-017 range lookup: return all node ids whose indexed value hashes fall in
/// the inclusive range [lo, hi]. Caller owns the returned slice and frees it
/// with `allocator`. Returns an empty slice when no index is declared.
///
/// NOTE: the B+tree is keyed by value *hash*, so range semantics are over the
/// hash space rather than the natural property ordering. This is exposed for
/// completeness (and to round-trip the underlying btree range API) but callers
/// that need ordered range scans over the original values should not rely on
/// hash-space ordering matching value ordering.
pub fn rangePropertyIndex(
    engine: *GraphEngine,
    label_id: LabelId,
    property_key: []const u8,
    lo: u64,
    hi: u64,
    allocator: Allocator,
) ![]NodeId {
    const set = &engine.property_index_set;
    const idx = set.findLive(label_id, property_key) orelse return allocator.alloc(NodeId, 0);
    return idx.findRange(lo, hi, allocator);
}

/// FR-017 online flow: refresh every declared index from the primary stores.
///
/// The engine's property write path is keyed by prop_head (a shared chain), not
/// by node id, so it has no cheap reverse mapping to the owning node + labels.
/// Rather than maintain a fragile per-write hook, declared indexes are rebuilt
/// from the authoritative primary stores at the checkpoint/close durability
/// boundary (see `save`). This guarantees the persisted tree reflects every
/// write made since the index was declared, regardless of write path. No-op
/// when nothing is declared, so the opt-in case stays free.
fn refreshLive(engine: *GraphEngine) !void {
    const set = &engine.property_index_set;
    for (set.live.items) |*idx| {
        const rebuilt = try buildIndexTree(engine, idx.label_id, idx.property_key);
        // Swap in the freshly built tree and release the stale one.
        idx.tree.deinit();
        idx.tree = rebuilt.tree;
        // The rebuilt PropertyIndex owns a duplicate key copy; free it since we
        // keep the existing idx (which already owns its key).
        engine.allocator.free(rebuilt.property_key);
    }
}

/// Save the catalog and every live B+tree to disk. Mirrors the derived-index
/// save discipline: the catalog uses its own magic + CRC32 format, and each
/// tree uses the btree snapshot format (magic + version + CRC32). No-op when
/// nothing is declared, so a graph without indexes never writes a catalog file
/// (backward compatibility).
pub fn save(engine: *GraphEngine) !void {
    const set = &engine.property_index_set;

    // Nothing declared and nothing previously persisted: skip entirely so the
    // opt-out case leaves no catalog artifact behind.
    if (set.catalog.indexes.items.len == 0 and !engine.property_catalog_dirty) return;

    // FR-017: refresh declared indexes from the primary stores so the persisted
    // snapshot reflects every write made since the index was declared.
    try refreshLive(engine);

    const path = try catalogPath(engine);
    defer engine.allocator.free(path);
    // SONNY-6590: sealed under at-rest encryption (key names, value hashes).
    var cipher = engine_persist.sideCipher(engine);
    defer if (cipher) |*c| c.deinit();
    const cptr: ?*const side_file_crypto.Cipher = if (cipher) |*c| c else null;
    try set.catalog.saveToFileWith(path, cptr);

    for (set.live.items) |*idx| {
        const tree_path = try indexTreePath(engine, idx.label_id, idx.property_key);
        defer engine.allocator.free(tree_path);
        try idx.tree.saveToFileWith(engine.allocator, tree_path, cptr);
    }

    engine.property_catalog_dirty = false;
}

/// Load the catalog and rehydrate live B+trees on open(). A missing catalog
/// file means "no indexes" (opt-in / backward compat) and returns cleanly.
///
/// For each declared btree_property index we attempt to load its persisted
/// snapshot; if the snapshot is missing or fails verification (bad magic,
/// version, or CRC32 — SEC-0051), we transparently rebuild it from the primary
/// stores so the index is never silently stale or trusted from corrupt bytes.
pub fn load(engine: *GraphEngine) !void {
    const set = &engine.property_index_set;
    set.clearLive();

    const path = try catalogPath(engine);
    defer engine.allocator.free(path);

    var cipher = engine_persist.sideCipher(engine);
    defer if (cipher) |*c| c.deinit();
    const policy = engine_persist.sideReadPolicy(engine, if (cipher) |*c| c else null);
    // SONNY-6590: a sealed catalog without the key, or one that fails
    // authentication, refuses the open like a corrupt one.
    set.catalog.loadFromFileWith(path, policy) catch |err| switch (err) {
        error.FileNotFound => return, // opt-in: no catalog → no indexes
        else => return err,
    };

    for (set.catalog.indexes.items) |def| {
        if (!def.index_type.eql(.{ .builtin = .btree_property })) continue;
        if (def.state == .inactive or def.state == .failed) continue;

        const tree_path = try indexTreePath(engine, def.label_id, def.property_key);
        defer engine.allocator.free(tree_path);

        var idx = loadOrRebuild(engine, def.label_id, def.property_key, tree_path, policy) catch |err| {
            return err;
        };
        errdefer idx.deinit();
        try set.live.append(set.allocator, idx);
    }
}

/// SONNY-6590: upgrade step of `engine_persist.sealLegacySideFiles` — rewrite
/// a plaintext props.catalog and every plaintext declared propidx_*.btree
/// sealed with `cipher` from the state `load` just read (temp + fsync +
/// rename each, then a directory fsync). Returns true when it rewrote
/// anything.
pub fn sealLegacy(engine: *GraphEngine, cipher: *const side_file_crypto.Cipher) !bool {
    const set = &engine.property_index_set;
    const path = try catalogPath(engine);
    defer engine.allocator.free(path);
    var did = false;
    if (try engine_persist.plaintextFileOnDisk(path)) {
        try set.catalog.saveToFileWith(path, cipher);
        try engine_persist.syncGraphDir(engine);
        try side_file_crypto.faultPoint(.catalog_sealed);
        did = true;
    }
    var trees = false;
    for (set.live.items) |*idx| {
        const tree_path = try indexTreePath(engine, idx.label_id, idx.property_key);
        defer engine.allocator.free(tree_path);
        if (try engine_persist.plaintextFileOnDisk(tree_path)) {
            try idx.tree.saveToFileWith(engine.allocator, tree_path, cipher);
            trees = true;
        }
    }
    if (trees) {
        try engine_persist.syncGraphDir(engine);
        try side_file_crypto.faultPoint(.btree_sealed);
        did = true;
    }
    return did;
}

/// Load a single index's B+tree from disk; on any missing/invalid snapshot,
/// rebuild from the primary stores. The rebuilt-from-disk distinction is
/// flagged so the next checkpoint re-persists a verified snapshot.
fn loadOrRebuild(
    engine: *GraphEngine,
    label_id: LabelId,
    property_key: []const u8,
    tree_path: []const u8,
    policy: side_file_crypto.ReadPolicy,
) !PropertyIndex {
    const BTree = property_index_mod.BPlusTreeU64U64;
    const loaded_tree = BTree.loadFromFileWith(engine.allocator, tree_path, policy) catch |err| switch (err) {
        // Missing or unverifiable snapshot → rebuild + mark dirty. A sealed
        // tree that fails authentication, or a plaintext one where sealed
        // trees are required, is unverifiable too (SONNY-6590).
        error.FileNotFound,
        error.InvalidFormat,
        error.UnexpectedEndOfFile,
        error.FileTooLarge,
        error.SideFileAuthFailed,
        error.SideFileNotSealed,
        error.SideFileTruncated,
        error.SideFileUnsupportedVersion,
        => {
            engine.property_catalog_dirty = true;
            return buildIndexTree(engine, label_id, property_key);
        },
        else => return err,
    };

    // Wrap the verified tree in a PropertyIndex with an owned key copy.
    const key_copy = try engine.allocator.dupe(u8, property_key);
    errdefer engine.allocator.free(key_copy);
    var tree = loaded_tree;
    errdefer tree.deinit();
    return PropertyIndex{
        .allocator = engine.allocator,
        .tree = tree,
        .label_id = label_id,
        .property_key = key_copy,
    };
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "hashEncodedValue is stable + matches property_chain hashing" {
    const a = hashEncodedValue("hello");
    // fips-exempt: non-security — test KAT asserting the non-cryptographic index hash is stable.
    const b = std.hash.Wyhash.hash(0, "hello");
    try testing.expectEqual(b, a);
}

test "hashValue encodes then hashes (fixed-size int)" {
    const v = PropertyValue{ .int = 42 };
    const encoded = try property_mod.encode(testing.allocator, v);
    defer testing.allocator.free(encoded);
    const expected = hashEncodedValue(encoded);
    const got = try hashValue(testing.allocator, v);
    try testing.expectEqual(expected, got);
}

test "hashValue encodes then hashes (variable-size string)" {
    const long = "this is a property string value longer than the 32 byte stack buffer";
    const v = PropertyValue{ .string = long };
    const encoded = try property_mod.encode(testing.allocator, v);
    defer testing.allocator.free(encoded);
    const expected = hashEncodedValue(encoded);
    const got = try hashValue(testing.allocator, v);
    try testing.expectEqual(expected, got);
}

test {
    std.testing.refAllDecls(@This());
}
