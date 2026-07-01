// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// GAP-ENT-0020 Phase P0 — prop-store slab packing: FOUNDATION ONLY.
//
// This file is measurement + parity infrastructure. It does NOT change the
// production prop_store format (P0 is zero-risk). It provides three things the
// later slab-packing phases (P1+) build on:
//
//   1. A "props-store bytes per node" efficiency METRIC over a tmpDir graph of
//      N small-property nodes. Locks in the CURRENT one-page-per-node baseline
//      (≈ page_size bytes/node) that the redesign must beat.
//
//   2. A property-set parity ORACLE: reads ALL (key,value) pairs for a
//      prop_head via the existing PropStore.getAllProperties path, decodes them,
//      and returns a sorted, comparable, deep-copied structure. This is the
//      reference every future slab reader/writer must match byte-for-byte.
//
//   3. A read-both parity SKELETON: legacy one-page-per-node layout is exercised
//      and passing now; the future slab-packed layout half is SKIPPED (P1 TODO)
//      but wired so P1 only has to fill it in.
//
// Root cause being measured (see design plan 2026-07-01-*-propstore-slab-
// packing.md): prop_store.putProperty allocates a whole ≥page_size page for the
// FIRST property of each node (free_space.allocPage when prop_head == 0), so a
// node with ~150 bytes of props still burns a full page → ~98% waste.

const std = @import("std");
const gs = @import("graph_storage");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const PropStore = gs.prop_store.PropStore;
const BufferPool = gs.buffer_pool.BufferPool;
const FreeSpaceManager = gs.free_space.FreeSpaceManager;
const VarStore = gs.var_store.VarStore;
const property = gs.property;
const PropertyValue = gs.PropertyValue;
const DualStoreEnv = gs.test_support.DualStoreEnv;

// ============================================================================
// Test environment (mirrors prop_store.zig's PropTestEnv, parameterized on
// page_size + buffer-pool size so the metric test can size the pool to hold
// every node's page and read a clean allocatedCount without eviction).
// ============================================================================

const Env = struct {
    base: DualStoreEnv,
    vs: VarStore,
    page_size: u32,

    fn init(page_size: u32, bp_pages: u32) !Env {
        var base = try DualStoreEnv.init(
            testing.allocator,
            .props,
            .props,
            "props.store",
            .var_store,
            "var.store",
            page_size,
            bp_pages,
        );
        base.register();
        return .{
            .base = base,
            .vs = VarStore.init(&base.pool, &base.fsm, page_size),
            .page_size = page_size,
        };
    }

    fn pool(self: *Env) *BufferPool {
        return &self.base.pool;
    }

    fn fsm(self: *Env) *FreeSpaceManager {
        return &self.base.fsm;
    }

    fn store(self: *Env) PropStore {
        return PropStore.init(self.pool(), self.fsm(), &self.vs, self.page_size);
    }

    fn deinit(self: *Env) void {
        self.base.deinit();
    }
};

// ============================================================================
// (1) props-store efficiency metric
// ============================================================================

/// The taxonomy-shaped small-property schema: ~6 short string props per node,
/// which is representative of the 1M/14.27M taxa workload GAP-ENT-0020 targets.
fn putTaxonNode(store: *PropStore, id: usize, buf: []u8) !u64 {
    var head: u64 = 0;
    head = try store.putProperty(head, "name", .{ .string = "Genus species" });
    head = try store.putProperty(head, "rank", .{ .string = "species" });
    head = try store.putProperty(head, "kingdom", .{ .string = "Animalia" });
    head = try store.putProperty(head, "phylum", .{ .string = "Chordata" });
    head = try store.putProperty(head, "status", .{ .string = "accepted" });
    const idstr = try std.fmt.bufPrint(buf, "T{d}", .{id});
    head = try store.putProperty(head, "src_id", .{ .string = idstr });
    return head;
}

const EfficiencyResult = struct {
    node_count: usize,
    allocated_pages: u64,
    page_size: u32,
    /// (allocated props pages × page_size) / N.
    bytes_per_node: f64,
};

/// Build `n` small-property nodes and compute props-store bytes/node from the
/// free-space allocator's page count (authoritative; independent of flush).
fn measurePropsEfficiency(page_size: u32, n: usize) !EfficiencyResult {
    // Size the buffer pool to hold every node's page plus headroom so no
    // eviction/pager-writeback occurs — allocatedCount then reflects exactly
    // the pages the prop store demanded.
    const bp_pages: u32 = @intCast(n + 32);
    var env = try Env.init(page_size, bp_pages);
    defer env.deinit();

    var store = env.store();

    var idbuf: [24]u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const head = try putTaxonNode(&store, i, &idbuf);
        try testing.expect(head != 0);
    }

    const allocated = env.fsm().allocatedCount();
    return .{
        .node_count = n,
        .allocated_pages = allocated,
        .page_size = page_size,
        .bytes_per_node = @as(f64, @floatFromInt(allocated * page_size)) / @as(f64, @floatFromInt(n)),
    };
}

test "GAP-ENT-0020 P0 metric: baseline props-store bytes per node (one page per node)" {
    const page_size: u32 = 8192; // production default page size
    const n: usize = 1000;

    const r = try measurePropsEfficiency(page_size, n);

    std.debug.print(
        "\n[GAP-ENT-0020 P0 baseline] nodes={d} page_size={d} " ++
            "allocated_props_pages={d} => {d:.1} props-store bytes/node " ++
            "(~6 short string props/node)\n",
        .{ r.node_count, r.page_size, r.allocated_pages, r.bytes_per_node },
    );

    // Current layout allocates exactly one page per node (prop_head is a
    // page-granular PageId; the first putProperty allocPage()s a whole page and
    // all ~6 short props fit inside it). This is the regression baseline the
    // slab redesign (P2+) must beat: bytes/node should drop toward O(real bytes)
    // (~150), i.e. many nodes per shared page.
    try testing.expectEqual(@as(u64, n), r.allocated_pages);
    try testing.expectEqual(@as(f64, @floatFromInt(page_size)), r.bytes_per_node);
}

// ============================================================================
// (2) property-set parity oracle
// ============================================================================

const OwnedProp = struct {
    key: []u8,
    value: PropertyValue, // owns its string/ext heap data
};

/// A sorted, deep-copied snapshot of a node's full property set. Every future
/// phase's slab reader MUST produce an Oracle that compares equal to the legacy
/// reader's Oracle for the same logical property set.
const Oracle = struct {
    allocator: Allocator,
    props: std.ArrayList(OwnedProp),

    fn deinit(self: *Oracle) void {
        for (self.props.items) |*p| {
            self.allocator.free(p.key);
            property.freeDecoded(self.allocator, p.value);
        }
        self.props.deinit(self.allocator);
    }

    /// Assert this oracle is byte-for-byte identical to `other` (the P1+ parity
    /// contract). Compares key order, keys, value tags, and value payloads.
    fn expectEqual(self: *const Oracle, other: *const Oracle) !void {
        try testing.expectEqual(self.props.items.len, other.props.items.len);
        for (self.props.items, other.props.items) |a, b| {
            try testing.expectEqualStrings(a.key, b.key);
            try expectValueEqual(a.value, b.value);
        }
    }
};

fn ownedPropLess(_: void, a: OwnedProp, b: OwnedProp) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

fn expectValueEqual(a: PropertyValue, b: PropertyValue) !void {
    try testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
    switch (a) {
        .null => {},
        .bool => |v| try testing.expectEqual(v, b.bool),
        .int => |v| try testing.expectEqual(v, b.int),
        .float => |v| try testing.expectEqual(@as(u64, @bitCast(v)), @as(u64, @bitCast(b.float))),
        .string => |v| try testing.expectEqualStrings(v, b.string),
        .decimal => |v| {
            try testing.expectEqual(v.coeff, b.decimal.coeff);
            try testing.expectEqual(v.scale, b.decimal.scale);
        },
        .ext => |v| {
            try testing.expectEqual(v.type_tag, b.ext.type_tag);
            try testing.expectEqualSlices(u8, v.data, b.ext.data);
        },
    }
}

/// THE ORACLE: read every (key,value) pair for `prop_head` via the existing
/// PropStore read path (getAllProperties + property.decode), deep-copy, and
/// return sorted by key. prop_head == 0 yields an empty oracle.
fn readOracle(allocator: Allocator, store: *PropStore, prop_head: u64) !Oracle {
    var props: std.ArrayList(OwnedProp) = .empty;
    errdefer {
        for (props.items) |*p| {
            allocator.free(p.key);
            property.freeDecoded(allocator, p.value);
        }
        props.deinit(allocator);
    }

    var iter = store.getAllProperties(prop_head);
    defer iter.deinit();
    while (try iter.next()) |entry| {
        const decoded = try property.decode(allocator, entry.encoded_value);
        errdefer property.freeDecoded(allocator, decoded.value);
        const key = try allocator.dupe(u8, entry.key);
        errdefer allocator.free(key);
        try props.append(allocator, .{ .key = key, .value = decoded.value });
    }

    std.mem.sort(OwnedProp, props.items, {}, ownedPropLess);
    return .{ .allocator = allocator, .props = props };
}

/// Canonical, deterministic text snapshot of an oracle: one "key=typed_value"
/// line per property, sorted, newline-terminated. This is the golden form later
/// phases diff against. Caller owns the returned slice.
fn formatOracle(allocator: Allocator, oracle: *const Oracle) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (oracle.props.items) |p| {
        try buf.appendSlice(allocator, p.key);
        try buf.append(allocator, '=');
        try appendValue(allocator, &buf, p.value);
        try buf.append(allocator, '\n');
    }
    return buf.toOwnedSlice(allocator);
}

fn appendValue(allocator: Allocator, buf: *std.ArrayList(u8), v: PropertyValue) !void {
    switch (v) {
        .null => try buf.appendSlice(allocator, "null"),
        .bool => |b| try buf.appendSlice(allocator, if (b) "bool:true" else "bool:false"),
        .int => |i| try appendFmt(allocator, buf, "int:{d}", .{i}),
        .float => |f| try appendFmt(allocator, buf, "float:{d}", .{f}),
        .string => |s| try appendFmt(allocator, buf, "string:{s}", .{s}),
        .decimal => |d| try appendFmt(allocator, buf, "decimal:{d}e{d}", .{ d.coeff, d.scale }),
        .ext => |e| {
            try appendFmt(allocator, buf, "ext:{d}:", .{e.type_tag});
            for (e.data) |byte| try appendFmt(allocator, buf, "{x:0>2}", .{byte});
        },
    }
}

fn appendFmt(allocator: Allocator, buf: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}

test "GAP-ENT-0020 P0 oracle: golden snapshot of a taxonomy-shaped node" {
    var env = try Env.init(8192, 32);
    defer env.deinit();
    var store = env.store();

    // Insertion order deliberately unsorted; the oracle must canonicalize.
    var head: u64 = 0;
    head = try store.putProperty(head, "name", .{ .string = "Homo sapiens" });
    head = try store.putProperty(head, "rank", .{ .string = "species" });
    head = try store.putProperty(head, "ncbi_id", .{ .int = 9606 });
    head = try store.putProperty(head, "kingdom", .{ .string = "Animalia" });
    head = try store.putProperty(head, "extinct", .{ .bool = false });

    var oracle = try readOracle(testing.allocator, &store, head);
    defer oracle.deinit();

    const text = try formatOracle(testing.allocator, &oracle);
    defer testing.allocator.free(text);

    const golden =
        "extinct=bool:false\n" ++
        "kingdom=string:Animalia\n" ++
        "name=string:Homo sapiens\n" ++
        "ncbi_id=int:9606\n" ++
        "rank=string:species\n";
    try testing.expectEqualStrings(golden, text);
}

test "GAP-ENT-0020 P0 oracle: varied property sets (empty / one / all types / overflow chain)" {
    // Fresh env; overflow chain will consume >1 page so keep the pool generous.
    var env = try Env.init(4096, 128);
    defer env.deinit();
    var store = env.store();

    // (a) empty set: prop_head == 0 → empty oracle.
    {
        var oracle = try readOracle(testing.allocator, &store, 0);
        defer oracle.deinit();
        try testing.expectEqual(@as(usize, 0), oracle.props.items.len);
    }

    // (b) single property.
    {
        const head = try store.putProperty(0, "only", .{ .int = 7 });
        var oracle = try readOracle(testing.allocator, &store, head);
        defer oracle.deinit();
        try testing.expectEqual(@as(usize, 1), oracle.props.items.len);
        try testing.expectEqualStrings("only", oracle.props.items[0].key);
        try expectValueEqual(.{ .int = 7 }, oracle.props.items[0].value);
    }

    // (c) all value types round-trip through the oracle.
    {
        var head: u64 = 0;
        head = try store.putProperty(head, "v_null", PropertyValue.null);
        head = try store.putProperty(head, "v_bool", .{ .bool = true });
        head = try store.putProperty(head, "v_int", .{ .int = -123456789 });
        head = try store.putProperty(head, "v_float", .{ .float = 2.5 });
        head = try store.putProperty(head, "v_string", .{ .string = "hello world" });
        head = try store.putProperty(head, "v_decimal", .{ .decimal = .{ .coeff = 12345, .scale = 2 } });
        head = try store.putProperty(head, "v_ext", .{ .ext = .{ .type_tag = 99, .data = "binary" } });

        var oracle = try readOracle(testing.allocator, &store, head);
        defer oracle.deinit();
        try testing.expectEqual(@as(usize, 7), oracle.props.items.len);

        // Sorted by key: v_bool, v_decimal, v_ext, v_float, v_int, v_null, v_string
        try expectValueEqual(.{ .bool = true }, oracle.props.items[0].value);
        try expectValueEqual(.{ .decimal = .{ .coeff = 12345, .scale = 2 } }, oracle.props.items[1].value);
        try expectValueEqual(.{ .ext = .{ .type_tag = 99, .data = "binary" } }, oracle.props.items[2].value);
        try expectValueEqual(.{ .float = 2.5 }, oracle.props.items[3].value);
        try expectValueEqual(.{ .int = -123456789 }, oracle.props.items[4].value);
        try expectValueEqual(PropertyValue.null, oracle.props.items[5].value);
        try expectValueEqual(.{ .string = "hello world" }, oracle.props.items[6].value);
    }

    // (d) multi-page overflow chain: enough props that the entry data spills
    // onto ≥2 pages of the legacy chain. The oracle must walk the whole chain.
    {
        const before = env.fsm().allocatedCount();
        var head: u64 = 0;
        const overflow_n: usize = 400;
        var kbuf: [16]u8 = undefined;
        var i: usize = 0;
        while (i < overflow_n) : (i += 1) {
            const k = try std.fmt.bufPrint(&kbuf, "k{d:0>5}", .{i});
            head = try store.putProperty(head, k, .{ .int = @intCast(i) });
        }
        const pages_used = env.fsm().allocatedCount() - before;
        try testing.expect(pages_used >= 2); // proved an overflow chain formed

        var oracle = try readOracle(testing.allocator, &store, head);
        defer oracle.deinit();
        try testing.expectEqual(overflow_n, oracle.props.items.len);

        // Spot-check a few keys survived the chain walk with correct values.
        // (items are sorted lexicographically by the zero-padded key.)
        try testing.expectEqualStrings("k00000", oracle.props.items[0].key);
        try expectValueEqual(.{ .int = 0 }, oracle.props.items[0].value);
        try testing.expectEqualStrings("k00399", oracle.props.items[overflow_n - 1].key);
        try expectValueEqual(.{ .int = 399 }, oracle.props.items[overflow_n - 1].value);
    }
}

// ============================================================================
// (3) read-both parity skeleton
// ============================================================================

/// Shared property set used by both halves of the read-both parity test, so the
/// legacy and (future) slab readers are exercised over identical logical data.
fn buildReferenceNode(store: *PropStore) !u64 {
    var head: u64 = 0;
    head = try store.putProperty(head, "name", .{ .string = "Panthera leo" });
    head = try store.putProperty(head, "rank", .{ .string = "species" });
    head = try store.putProperty(head, "year", .{ .int = 1758 });
    head = try store.putProperty(head, "valid", .{ .bool = true });
    head = try store.putProperty(head, "note", PropertyValue.null);
    return head;
}

test "GAP-ENT-0020 P0 read-both: legacy one-page-per-node layout (implemented)" {
    var env = try Env.init(8192, 32);
    defer env.deinit();
    var store = env.store();

    // Two independently-built legacy nodes carrying the same logical props must
    // yield identical oracles. This proves the oracle + parity harness that P1's
    // slab half will reuse verbatim.
    const head_a = try buildReferenceNode(&store);
    const head_b = try buildReferenceNode(&store);

    var oracle_a = try readOracle(testing.allocator, &store, head_a);
    defer oracle_a.deinit();
    var oracle_b = try readOracle(testing.allocator, &store, head_b);
    defer oracle_b.deinit();

    try oracle_a.expectEqual(&oracle_b);
    try testing.expectEqual(@as(usize, 5), oracle_a.props.items.len);
}

// ----------------------------------------------------------------------------
// P1 slab-page hand-build helpers.
//
// A slab BLOB reuses the legacy property-entry format verbatim:
//   [entry_count: u32 LE] then entry_count × (key_len: u16 LE, key, encoded_value)
// The page's slot directory (offset,len per slot) grows backward from the tail
// via the PropStore slab helpers. These helpers let the test hand-build a page
// exactly as the future P2 writer will, so the P1 reader is exercised over a
// real slab layout.
// ----------------------------------------------------------------------------

const KV = struct { key: []const u8, val: PropertyValue };

/// Append one node's property blob (entry_count + entries) into `page` at
/// `write_off.*`, advancing `write_off`. Returns nothing; caller records the
/// (offset,len) span for the slot directory.
fn appendBlob(alloc: Allocator, page: []u8, write_off: *u32, kvs: []const KV) !void {
    std.mem.writeInt(u32, page[write_off.*..][0..4], @intCast(kvs.len), .little);
    write_off.* += 4;
    for (kvs) |kv| {
        const enc = try property.encode(alloc, kv.val);
        defer alloc.free(enc);
        std.mem.writeInt(u16, page[write_off.*..][0..2], @intCast(kv.key.len), .little);
        write_off.* += 2;
        @memcpy(page[write_off.*..][0..kv.key.len], kv.key);
        write_off.* += @intCast(kv.key.len);
        @memcpy(page[write_off.*..][0..enc.len], enc);
        write_off.* += @intCast(enc.len);
    }
}

/// Build the same property set two ways — legacy (putProperty chain) and slab
/// (`slab_head`) — and assert their oracles are byte-for-byte identical.
fn expectSlabMatchesLegacy(store: *PropStore, kvs: []const KV, slab_head: u64) !void {
    var legacy_head: u64 = 0;
    for (kvs) |kv| {
        legacy_head = try store.putProperty(legacy_head, kv.key, kv.val);
    }
    var legacy_oracle = try readOracle(testing.allocator, store, legacy_head);
    defer legacy_oracle.deinit();

    var slab_oracle = try readOracle(testing.allocator, store, slab_head);
    defer slab_oracle.deinit();

    try legacy_oracle.expectEqual(&slab_oracle);
    try testing.expectEqual(kvs.len, slab_oracle.props.items.len);
}

test "GAP-ENT-0020 P1 read-both: slab-packed layout matches legacy" {
    var env = try Env.init(8192, 32);
    defer env.deinit();
    var store = env.store();

    const ps = gs.prop_store;

    // Three nodes' property sets, ALL packed into ONE shared slab page:
    //   slot 0: a single property
    //   slot 1: many properties spanning every value type
    //   slot 2: the shared reference set (byte-for-byte vs a legacy node)
    const set0 = [_]KV{
        .{ .key = "only", .val = .{ .int = 7 } },
    };
    const set1 = [_]KV{
        .{ .key = "v_null", .val = PropertyValue.null },
        .{ .key = "v_bool", .val = .{ .bool = true } },
        .{ .key = "v_int", .val = .{ .int = -123456789 } },
        .{ .key = "v_float", .val = .{ .float = 2.5 } },
        .{ .key = "v_string", .val = .{ .string = "hello world" } },
        .{ .key = "v_decimal", .val = .{ .decimal = .{ .coeff = 12345, .scale = 2 } } },
        .{ .key = "v_ext", .val = .{ .ext = .{ .type_tag = 99, .data = "binary" } } },
        .{ .key = "name", .val = .{ .string = "Genus species" } },
    };
    const set2 = [_]KV{
        .{ .key = "name", .val = .{ .string = "Panthera leo" } },
        .{ .key = "rank", .val = .{ .string = "species" } },
        .{ .key = "year", .val = .{ .int = 1758 } },
        .{ .key = "valid", .val = .{ .bool = true } },
        .{ .key = "note", .val = PropertyValue.null },
    };

    // Hand-build a single slab page holding all three blobs + a 3-slot directory.
    const page_id = try env.fsm().allocPage();
    const frame = try env.pool().pinNew(.props, page_id);
    const frame_idx = env.pool().frameIndex(frame);
    const data = frame.dataSlice();

    var write_off: u32 = ps.SLAB_DATA_OFFSET;
    const off0 = write_off;
    try appendBlob(testing.allocator, data, &write_off, &set0);
    const len0 = write_off - off0;
    const off1 = write_off;
    try appendBlob(testing.allocator, data, &write_off, &set1);
    const len1 = write_off - off1;
    const off2 = write_off;
    try appendBlob(testing.allocator, data, &write_off, &set2);
    const len2 = write_off - off2;

    ps.writeSlabSlot(data, 0, off0, len0);
    ps.writeSlabSlot(data, 1, off1, len1);
    ps.writeSlabSlot(data, 2, off2, len2);
    ps.writeSlabSlotCount(data, 3);
    ps.writeSlabLayoutVersion(data);
    env.pool().unpin(frame_idx, true);

    const head0 = ps.encodeSlabHead(page_id, 0);
    const head1 = ps.encodeSlabHead(page_id, 1);
    const head2 = ps.encodeSlabHead(page_id, 2);

    // Encode/decode round-trip sanity: the tag bit discriminates and (page,slot)
    // survives the encoding.
    try testing.expect(ps.isSlabHead(head1));
    try testing.expect(!ps.isSlabHead(page_id)); // a legacy bare page id
    try testing.expectEqual(page_id, ps.slabPageId(head1));
    try testing.expectEqual(@as(u32, 1), ps.slabSlot(head1));

    // Byte-for-byte oracle parity vs an equivalent legacy-written node, for each
    // of the three slots — proving multiple nodes' props coexist in one page and
    // read back correctly (single prop, many/mixed types, shared reference set).
    try expectSlabMatchesLegacy(&store, &set0, head0);
    try expectSlabMatchesLegacy(&store, &set1, head1);
    try expectSlabMatchesLegacy(&store, &set2, head2);

    // Direct getProperty on the slab path resolves the right blob per slot and
    // does NOT leak keys across sibling nodes sharing the page.
    {
        const v = try store.getProperty(head0, "only", testing.allocator);
        try testing.expect(v != null);
        try testing.expectEqual(@as(i64, 7), v.?.int);
    }
    {
        const v = try store.getProperty(head1, "v_string", testing.allocator);
        try testing.expect(v != null);
        defer property.freeDecoded(testing.allocator, v.?);
        try testing.expectEqualStrings("hello world", v.?.string);
    }
    {
        // "v_string" lives only in slot 1's blob; slot 0 must not see it.
        const v = try store.getProperty(head0, "v_string", testing.allocator);
        try testing.expect(v == null);
    }
    {
        const v = try store.getProperty(head2, "year", testing.allocator);
        try testing.expect(v != null);
        try testing.expectEqual(@as(i64, 1758), v.?.int);
        // slot 0's key must not resolve against slot 2's blob.
        const miss = try store.getProperty(head2, "only", testing.allocator);
        try testing.expect(miss == null);
    }
}

// ============================================================================
// Phase P2 — slab WRITE path.
//
// RED baseline: the P0 metric test above (slab OFF) locks in 8192 bytes/node
// (exactly one page per node). GREEN: with `slab_packing = true` the SAME
// putProperty workload packs many nodes per shared page.
// ============================================================================

/// Golden oracle text for a putTaxonNode-shaped node (keys sorted).
fn taxonGolden(allocator: Allocator, id: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "kingdom=string:Animalia\n" ++
        "name=string:Genus species\n" ++
        "phylum=string:Chordata\n" ++
        "rank=string:species\n" ++
        "src_id=string:T{d}\n" ++
        "status=string:accepted\n", .{id});
}

fn expectOracleText(store: *PropStore, head: u64, expected: []const u8) !void {
    var oracle = try readOracle(testing.allocator, store, head);
    defer oracle.deinit();
    const text = try formatOracle(testing.allocator, &oracle);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

test "GAP-ENT-0020 P2 packing: 1000 small-prop nodes share slab pages (bytes/node collapses)" {
    const page_size: u32 = 8192; // production default; P0 baseline = 8192 bytes/node
    const n: usize = 1000;

    var env = try Env.init(page_size, @intCast(n + 32));
    defer env.deinit();
    var store = env.store();
    store.slab_packing = true;

    const heads = try testing.allocator.alloc(u64, n);
    defer testing.allocator.free(heads);

    var idbuf: [24]u8 = undefined;
    for (heads, 0..) |*h, i| {
        h.* = try putTaxonNode(&store, i, &idbuf);
        // Every small-prop node must be slab-resident, not legacy.
        try testing.expect(gs.prop_store.isSlabHead(h.*));
    }

    const allocated = env.fsm().allocatedCount();
    const bytes_per_node =
        @as(f64, @floatFromInt(allocated * page_size)) / @as(f64, @floatFromInt(n));
    std.debug.print(
        "\n[GAP-ENT-0020 P2 packed] nodes={d} page_size={d} allocated_props_pages={d} " ++
            "=> {d:.1} props-store bytes/node (baseline was 8192.0)\n",
        .{ n, page_size, allocated, bytes_per_node },
    );

    // Headline assertion: bytes/node is a small fraction of the 8192 baseline.
    try testing.expect(bytes_per_node < 1024.0);

    // Byte-identical round-trip for EVERY node through the P1 slab reader.
    for (heads, 0..) |h, i| {
        const golden = try taxonGolden(testing.allocator, i);
        defer testing.allocator.free(golden);
        try expectOracleText(&store, h, golden);
    }
}

test "GAP-ENT-0020 P2 parity: interleaved slab and legacy(oversized) writes match legacy oracles" {
    const page_size: u32 = 8192;
    var env = try Env.init(page_size, 256);
    defer env.deinit();

    // Two stores over the same pool/fsm: the slab writer under test and a
    // legacy reference writer (slab off) producing the oracle twin.
    var slab_store = env.store();
    slab_store.slab_packing = true;
    var legacy_store = env.store(); // slab_packing stays false

    const ps = gs.prop_store;

    // Oversized first write: the blob (4-byte count + entry) must exceed the
    // slab max blob while the entry still fits a legacy page:
    //   slab max blob = page_size - SLAB_DATA_OFFSET(36) - 4 - 8      = 8144
    //   blob          = 4 + 2 + key.len(3) + string_enc(5 + vlen)     = 14 + vlen
    //   legacy max    = dataCapacity(8146) - DIR_ENTRY_SIZE(4)        = 8142
    //   entry         = 2 + 3 + 5 + vlen                              = 10 + vlen
    // vlen = 8131 → blob 8145 (> 8144, no slab) and entry 8141 (≤ 8142, legacy ok).
    const oversize_len: usize = 8131;
    const big_val = try testing.allocator.alloc(u8, oversize_len);
    defer testing.allocator.free(big_val);
    @memset(big_val, 'x');

    var idbuf: [24]u8 = undefined;
    var i: usize = 0;
    while (i < 24) : (i += 1) {
        if (i % 4 == 3) {
            // Oversized node: slab writer must fall back to the legacy layout.
            const h = try slab_store.putProperty(0, "big", .{ .string = big_val });
            try testing.expect(!ps.isSlabHead(h));
            const h_ref = try legacy_store.putProperty(0, "big", .{ .string = big_val });

            var a = try readOracle(testing.allocator, &slab_store, h);
            defer a.deinit();
            var b = try readOracle(testing.allocator, &legacy_store, h_ref);
            defer b.deinit();
            try b.expectEqual(&a);
        } else {
            // Small node: packs into the shared fill page.
            const h = try putTaxonNode(&slab_store, i, &idbuf);
            try testing.expect(ps.isSlabHead(h));
            const h_ref = try putTaxonNode(&legacy_store, i, &idbuf);

            var a = try readOracle(testing.allocator, &slab_store, h);
            defer a.deinit();
            var b = try readOracle(testing.allocator, &legacy_store, h_ref);
            defer b.deinit();
            try b.expectEqual(&a);
        }
    }
}

test "GAP-ENT-0020 P2 update/remove: slab-resident nodes stay correct (in-place, relocate+tombstone, legacy migration)" {
    const page_size: u32 = 8192;
    var env = try Env.init(page_size, 256);
    defer env.deinit();
    var store = env.store();
    store.slab_packing = true;

    const ps = gs.prop_store;

    // Node A first, node B second — so A's blob is NOT the page tail and a
    // grow of A must RELOCATE (new slot) rather than grow in place.
    var head_a: u64 = 0;
    head_a = try store.putProperty(head_a, "name", .{ .string = "Panthera leo" });
    head_a = try store.putProperty(head_a, "rank", .{ .string = "species" });
    head_a = try store.putProperty(head_a, "year", .{ .int = 1758 });
    const head_b = try store.putProperty(0, "name", .{ .string = "Homo sapiens" });
    try testing.expect(ps.isSlabHead(head_a));
    try testing.expect(ps.isSlabHead(head_b));

    // (1) same-size replace → in place, head unchanged.
    {
        const h = try store.putProperty(head_a, "year", .{ .int = 1759 });
        try testing.expectEqual(head_a, h);
        const v = try store.getProperty(head_a, "year", testing.allocator);
        try testing.expectEqual(@as(i64, 1759), v.?.int);
    }

    // (2) growing replace on a non-tail blob → relocated to a new slot; the
    // old slot is tombstoned (len = 0) and a dangling read fails loudly.
    var head_a2: u64 = undefined;
    {
        const old_page = ps.slabPageId(head_a);
        const old_slot = ps.slabSlot(head_a);
        head_a2 = try store.putProperty(head_a, "name", .{ .string = "Panthera leo persica (relocated)" });
        try testing.expect(head_a2 != head_a);
        try testing.expect(ps.isSlabHead(head_a2));

        // Old slot tombstoned in the slot directory.
        const frame = try env.pool().pin(.props, old_page);
        const frame_idx = env.pool().frameIndex(frame);
        const s = ps.readSlabSlot(frame.dataSlice(), old_slot);
        env.pool().unpin(frame_idx, false);
        try testing.expectEqual(@as(u32, 0), s.len);

        // Dangling old head errors instead of returning stale data.
        try testing.expectError(error.DataCorruption, store.getProperty(head_a, "name", testing.allocator));

        // New head carries the full updated set.
        try expectOracleText(&store, head_a2, "name=string:Panthera leo persica (relocated)\n" ++
            "rank=string:species\n" ++
            "year=int:1759\n");
    }

    // (3) grow past slab capacity → migrated to a LEGACY chain, old slot
    // tombstoned, no data loss.
    var head_a3: u64 = undefined;
    {
        const filler = try testing.allocator.alloc(u8, 4200);
        defer testing.allocator.free(filler);
        @memset(filler, 'y');
        // First big value still fits a slab blob…
        const h1 = try store.putProperty(head_a2, "blob1", .{ .string = filler });
        try testing.expect(ps.isSlabHead(h1));
        // …the second pushes the blob past the slab max → legacy migration.
        head_a3 = try store.putProperty(h1, "blob2", .{ .string = filler });
        try testing.expect(!ps.isSlabHead(head_a3));

        const v1 = try store.getProperty(head_a3, "blob1", testing.allocator);
        try testing.expect(v1 != null);
        defer property.freeDecoded(testing.allocator, v1.?);
        try testing.expectEqualStrings(filler, v1.?.string);
        const v2 = try store.getProperty(head_a3, "name", testing.allocator);
        try testing.expect(v2 != null);
        defer property.freeDecoded(testing.allocator, v2.?);
        try testing.expectEqualStrings("Panthera leo persica (relocated)", v2.?.string);

        var oracle = try readOracle(testing.allocator, &store, head_a3);
        defer oracle.deinit();
        try testing.expectEqual(@as(usize, 5), oracle.props.items.len);
    }

    // (4) remove on a slab-resident node: in-place shrink, head stays valid.
    {
        var head_c: u64 = 0;
        head_c = try store.putProperty(head_c, "x", .{ .int = 1 });
        head_c = try store.putProperty(head_c, "y", .{ .int = 2 });
        head_c = try store.putProperty(head_c, "z", .{ .int = 3 });
        try testing.expect(ps.isSlabHead(head_c));

        try store.removeProperty(head_c, "y");
        const gone = try store.getProperty(head_c, "y", testing.allocator);
        try testing.expect(gone == null);
        try expectOracleText(&store, head_c, "x=int:1\nz=int:3\n");

        // Remove everything: the head still reads back as an empty set.
        try store.removeProperty(head_c, "x");
        try store.removeProperty(head_c, "z");
        var oracle = try readOracle(testing.allocator, &store, head_c);
        defer oracle.deinit();
        try testing.expectEqual(@as(usize, 0), oracle.props.items.len);

        // Removing an absent key is a no-op, exactly like legacy.
        try store.removeProperty(head_c, "never-there");
    }

    // Sibling B was never disturbed by any of A's/C's rewrites.
    try expectOracleText(&store, head_b, "name=string:Homo sapiens\n");
}

test "GAP-ENT-0020 P2 reopen: slab pages survive flush + clean reopen (oracle parity)" {
    const page_size: u32 = 8192;
    const n: usize = 50;

    var env = try Env.init(page_size, 128);
    defer env.deinit();
    // Env.init registers pager pointers BEFORE the env struct is moved to its
    // final address, so they dangle; every other test tolerates that because
    // it never flushes. This test drives the pager (flushAll), so re-register
    // at the stable address first.
    env.base.register();
    var store = env.store();
    store.slab_packing = true;

    const heads = try testing.allocator.alloc(u64, n);
    defer testing.allocator.free(heads);
    var idbuf: [24]u8 = undefined;
    for (heads, 0..) |*h, i| {
        h.* = try putTaxonNode(&store, i, &idbuf);
    }

    // Persist every dirty page through the pager (clean close), then reopen
    // the SAME props file with a brand-new buffer pool: proves slab pages
    // round-trip through the on-disk persist path, not just pool frames.
    try env.pool().flushAll();

    var pool2 = try BufferPool.init(testing.allocator, page_size, 128);
    defer pool2.deinit();
    var pager2 = gs.pager.Pager.init(env.base.primary_file, page_size);
    pool2.registerPager(.props, &pager2);

    var store2 = PropStore.init(&pool2, env.fsm(), &env.vs, page_size);
    store2.slab_packing = true; // read path is layout-discriminated regardless

    for (heads, 0..) |h, i| {
        const golden = try taxonGolden(testing.allocator, i);
        defer testing.allocator.free(golden);
        try expectOracleText(&store2, h, golden);
    }
}
