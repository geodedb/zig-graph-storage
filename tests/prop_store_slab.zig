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

test "GAP-ENT-0020 P0 read-both: slab-packed layout matches legacy (P1 TODO)" {
    // P1 (slab read path) fills this in:
    //   1. build a node the legacy way            -> legacy_head, legacy oracle
    //   2. hand-build the SAME property set into a slab-packed page (many nodes
    //      per shared page; prop_head = (page_id, intra-page offset))
    //   3. read it via the P1 slab-aware PropStore -> slab oracle
    //   4. try legacy_oracle.expectEqual(&slab_oracle)  // byte-for-byte parity
    //
    // The slab writer/reader do not exist in P0 (production format unchanged),
    // so this half is skipped until P1. The oracle + expectEqual harness above
    // is the exact contract it must satisfy.
    return error.SkipZigTest;
}
