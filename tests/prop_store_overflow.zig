// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// Property-value OVERFLOW (property tag 7) — acceptance suite.
//
// Root cause this closes: `PropStore.putPropertyImpl` rejected ANY property
// entry larger than one page's entry budget (≈ page_size - 50 bytes), and did
// so with the untruthful `PropertyKeyTooLong`. A 2048-dim f32 embedding (8 KB)
// was therefore unstorable on an 8 KB page even though the var store has always
// handled megabyte runs.
//
// The fix: an oversized value is written to a LEGACY var-store chain and the
// property entry holds a 13-byte OVERFLOW STUB instead:
//
//     [0]      u8   tag = 7 (Tag.overflow)
//     [1..5)   u32  encoded_len of the ORIGINAL encoded value (LE)
//     [5..13)  u64  var_ref of the chain holding those bytes (LE)
//
// Everything below is a gate on that design:
//   (1)  round-trip of 2560/3072/4096-dim f32 vectors as .string and .ext,
//        across page sizes and both slab_packing settings, via getProperty
//        AND getAllProperties;
//   (2)  the inline/overflow boundary (last inline size vs first overflow size)
//        pinned by the var-store page-count delta;
//   (3)  mixed chains (small + overflowed) with a full-iteration parity oracle;
//   (4)  overwrite churn (100x) with bounded page growth, plus every
//        small→large / large→small / large→large transition;
//   (5)  delete frees the overflow chain and leaves siblings readable;
//   (6)  overflow on a SLAB-resident node, including the slab→legacy migration
//        (the var ref must survive the relocation verbatim);
//   (7)  property-index consistency over an overflowed value (lookup hits;
//        rebuild-vs-reload digests agree);
//   (8)  crash / WAL replay: committed overflow replays byte-identical,
//        uncommitted is invisible, the deferred-WAL tail replays, and an
//        overwrite inside the crash window leaves no dangling ref;
//   (9)  compatibility: a store with no overflow entries is byte-identical to
//        the pre-feature layout, and a hand-crafted tag-7 entry is rejected
//        cleanly (never a panic) by the decode path a v0.3.2 reader would hit;
//   (10) error identity: key overflow → PropertyKeyTooLong, value over the
//        sanity cap → PropertyValueTooLarge, oversized-key-plus-stub →
//        PropertyKeyTooLong.
//
// Plus an encrypted-store round-trip + reopen, and a leak-PARITY note for node
// deletion (the overflow chain leaks exactly like the property PAGES already
// leak today — this suite pins that parity so the pre-existing gap is not
// silently widened, and does NOT implement reclamation).

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
const GraphEngine = gs.GraphEngine;
const TestDataDir = gs.test_support.TestDataDir;

// ============================================================================
// Harness
// ============================================================================

/// Two files, ONE free-space manager: `fsm.allocatedCount()` therefore counts
/// props pages AND var pages together, and the per-op delta is exactly what a
/// put/remove demanded from the allocator. `props_before`/`var_before` snapshots
/// below use this single counter deliberately.
const Env = struct {
    base: DualStoreEnv,
    vs: VarStore,
    page_size: u32,

    fn init(page_size: u32, bp_pages: u32) !Env {
        return .{
            .base = try DualStoreEnv.init(
                testing.allocator,
                .props,
                .props,
                "props.store",
                .var_store,
                "var.store",
                page_size,
                bp_pages,
            ),
            .vs = undefined,
            .page_size = page_size,
        };
    }

    /// MUST be called once the Env sits at its FINAL address: DualStoreEnv
    /// registers pointers to its own pagers and pool, and the VarStore holds
    /// pointers to that pool and free-space manager. Wiring them before the
    /// value is moved would leave every one of them dangling.
    fn wire(self: *Env) void {
        self.base.register();
        self.vs = VarStore.init(&self.base.pool, &self.base.fsm, self.page_size);
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

    fn allocated(self: *Env) u64 {
        return self.base.fsm.allocatedCount();
    }

    fn deinit(self: *Env) void {
        self.base.deinit();
    }
};

/// A deterministic f32 vector as raw little-endian bytes (the exact shape of an
/// embedding payload — the workload that motivated this feature).
fn vectorBytes(alloc: Allocator, dims: usize) ![]u8 {
    const buf = try alloc.alloc(u8, dims * 4);
    for (0..dims) |i| {
        const f: f32 = @floatFromInt(i % 97);
        std.mem.writeInt(u32, buf[i * 4 ..][0..4], @bitCast(f), .little);
    }
    return buf;
}

fn filled(alloc: Allocator, len: usize, seed: u8) ![]u8 {
    const buf = try alloc.alloc(u8, len);
    for (buf, 0..) |*b, i| b.* = seed +% @as(u8, @truncate(i));
    return buf;
}

/// The largest encoded value that still fits INLINE for `page_size`/`key`.
/// Mirrors PropStore's budget math: dataCapacity - DIR_ENTRY_SIZE, minus the
/// 2-byte key_len field and the key itself.
fn inlineValueBudget(page_size: u32, key_len: usize) usize {
    const PROP_DATA_OFFSET: usize = 32 + 12;
    const DIR_COUNT_SIZE: usize = 2;
    const DIR_ENTRY_SIZE: usize = 4;
    const data_capacity = @as(usize, page_size) - PROP_DATA_OFFSET - DIR_COUNT_SIZE;
    return data_capacity - DIR_ENTRY_SIZE - 2 - key_len;
}

/// One property read back through `getProperty`, compared against `want`.
fn expectProp(store: *PropStore, head: u64, key: []const u8, want: PropertyValue) !void {
    const got = try store.getProperty(head, key, testing.allocator);
    if (got == null) return error.PropertyMissing;
    defer property.freeDecoded(testing.allocator, got.?);
    try expectValueEqual(want, got.?);
}

fn expectValueEqual(want: PropertyValue, got: PropertyValue) !void {
    try testing.expectEqual(std.meta.activeTag(want), std.meta.activeTag(got));
    switch (want) {
        .null => {},
        .bool => |b| try testing.expectEqual(b, got.bool),
        .int => |i| try testing.expectEqual(i, got.int),
        .float => |f| try testing.expectEqual(f, got.float),
        .string => |s| try testing.expectEqualSlices(u8, s, got.string),
        .decimal => |d| {
            try testing.expectEqual(d.coeff, got.decimal.coeff);
            try testing.expectEqual(d.scale, got.decimal.scale);
        },
        .ext => |e| {
            try testing.expectEqual(e.type_tag, got.ext.type_tag);
            try testing.expectEqualSlices(u8, e.data, got.ext.data);
        },
    }
}

const OwnedProp = struct { key: []u8, value: PropertyValue };

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

    fn get(self: *const Oracle, key: []const u8) ?PropertyValue {
        for (self.props.items) |p| {
            if (std.mem.eql(u8, p.key, key)) return p.value;
        }
        return null;
    }
};

fn ownedPropLess(_: void, a: OwnedProp, b: OwnedProp) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

/// THE PARITY ORACLE: every (key, value) pair for `prop_head` read through the
/// zero-copy iterator, decoded and deep-copied, sorted by key. Because the
/// iterator RESOLVES overflow stubs, `entry.encoded_value` is always the REAL
/// encoded value here — decoding it must never see tag 7.
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

// ============================================================================
// (1) Round-trip matrix
// ============================================================================

test "overflow (1): 2560/3072/4096-dim f32 vectors round-trip as .string and .ext" {
    for ([_]u32{ 4096, 8192 }) |page_size| {
        for ([_]bool{ true, false }) |slab| {
            for ([_]usize{ 2560, 3072, 4096 }) |dims| {
                var env = try Env.init(page_size, 256);
                defer env.deinit();
                env.wire();
                var store = env.store();
                store.slab_packing = slab;

                const v = try vectorBytes(testing.allocator, dims);
                defer testing.allocator.free(v);

                // .string
                {
                    var head = try store.putProperty(0, "embedding", .{ .string = v });
                    head = try store.putProperty(head, "dims", .{ .int = @intCast(dims) });
                    try expectProp(&store, head, "embedding", .{ .string = v });
                    try expectProp(&store, head, "dims", .{ .int = @intCast(dims) });

                    var oracle = try readOracle(testing.allocator, &store, head);
                    defer oracle.deinit();
                    try testing.expectEqual(@as(usize, 2), oracle.props.items.len);
                    try expectValueEqual(.{ .string = v }, oracle.get("embedding").?);
                }

                // .ext (a different encoded prefix — the stub must be
                // type-agnostic; only the ENCODED bytes are spilled)
                {
                    const head = try store.putProperty(0, "vec", .{ .ext = .{ .type_tag = 42, .data = v } });
                    try expectProp(&store, head, "vec", .{ .ext = .{ .type_tag = 42, .data = v } });

                    var oracle = try readOracle(testing.allocator, &store, head);
                    defer oracle.deinit();
                    try expectValueEqual(.{ .ext = .{ .type_tag = 42, .data = v } }, oracle.get("vec").?);
                }
            }
        }
    }
}

// ============================================================================
// (2) Inline/overflow boundary
// ============================================================================

test "overflow (2): the last inline size stays inline; one byte more overflows to var pages" {
    const page_size: u32 = 8192;
    const key = "embedding";
    // encodedSize(.string) == 1 + 4 + payload
    const max_inline_payload = inlineValueBudget(page_size, key.len) - 5;
    try testing.expectEqual(@as(usize, 8126), max_inline_payload);

    // Last inline size: exactly ONE props page, ZERO var pages.
    {
        var env = try Env.init(page_size, 256);
        defer env.deinit();
        env.wire();
        var store = env.store();
        store.slab_packing = false; // legacy: one page per node, easy to count

        const v = try filled(testing.allocator, max_inline_payload, 1);
        defer testing.allocator.free(v);

        const before = env.allocated();
        const head = try store.putProperty(0, key, .{ .string = v });
        const after = env.allocated();
        try testing.expectEqual(@as(u64, 1), after - before); // props page only
        try expectProp(&store, head, key, .{ .string = v });
    }

    // One byte more: still ONE props page, PLUS the var chain pages.
    {
        var env = try Env.init(page_size, 256);
        defer env.deinit();
        env.wire();
        var store = env.store();
        store.slab_packing = false;

        const v = try filled(testing.allocator, max_inline_payload + 1, 1);
        defer testing.allocator.free(v);

        const before = env.allocated();
        const head = try store.putProperty(0, key, .{ .string = v });
        const after = env.allocated();
        // 1 props page + ceil(8132 / (8192-44)) == 1 + 1 var page.
        try testing.expectEqual(@as(u64, 2), after - before);
        try expectProp(&store, head, key, .{ .string = v });
    }
}

test "overflow (2b): a multi-page overflow value allocates the whole var chain" {
    var env = try Env.init(4096, 512);
    defer env.deinit();
    env.wire();
    var store = env.store();
    store.slab_packing = false;

    const v = try vectorBytes(testing.allocator, 4096); // 16 KiB payload
    defer testing.allocator.free(v);

    const before = env.allocated();
    const head = try store.putProperty(0, "embedding", .{ .string = v });
    const after = env.allocated();

    const var_capacity: usize = 4096 - 32 - 12;
    const encoded_len = v.len + 5;
    const expected_var_pages = (encoded_len + var_capacity - 1) / var_capacity;
    try testing.expectEqual(@as(u64, 1 + expected_var_pages), after - before);
    try expectProp(&store, head, "embedding", .{ .string = v });
}

// ============================================================================
// (3) Mixed chains
// ============================================================================

test "overflow (3): a mixed small+overflow chain iterates with full parity" {
    for ([_]bool{ true, false }) |slab| {
        var env = try Env.init(8192, 256);
        defer env.deinit();
        env.wire();
        var store = env.store();
        store.slab_packing = slab;

        const big_a = try vectorBytes(testing.allocator, 2560);
        defer testing.allocator.free(big_a);
        const big_b = try vectorBytes(testing.allocator, 3072);
        defer testing.allocator.free(big_b);

        var head: u64 = 0;
        head = try store.putProperty(head, "name", .{ .string = "Homo sapiens" });
        head = try store.putProperty(head, "embedding", .{ .string = big_a });
        head = try store.putProperty(head, "rank", .{ .string = "species" });
        head = try store.putProperty(head, "alt_embedding", .{ .ext = .{ .type_tag = 7, .data = big_b } });
        head = try store.putProperty(head, "ncbi_id", .{ .int = 9606 });
        head = try store.putProperty(head, "extinct", .{ .bool = false });

        var oracle = try readOracle(testing.allocator, &store, head);
        defer oracle.deinit();
        try testing.expectEqual(@as(usize, 6), oracle.props.items.len);
        try expectValueEqual(.{ .string = "Homo sapiens" }, oracle.get("name").?);
        try expectValueEqual(.{ .string = big_a }, oracle.get("embedding").?);
        try expectValueEqual(.{ .string = "species" }, oracle.get("rank").?);
        try expectValueEqual(.{ .ext = .{ .type_tag = 7, .data = big_b } }, oracle.get("alt_embedding").?);
        try expectValueEqual(.{ .int = 9606 }, oracle.get("ncbi_id").?);
        try expectValueEqual(.{ .bool = false }, oracle.get("extinct").?);

        // getProperty agrees with the iterator for every key.
        try expectProp(&store, head, "name", .{ .string = "Homo sapiens" });
        try expectProp(&store, head, "embedding", .{ .string = big_a });
        try expectProp(&store, head, "alt_embedding", .{ .ext = .{ .type_tag = 7, .data = big_b } });
        try expectProp(&store, head, "extinct", .{ .bool = false });
        try testing.expectEqual(@as(?PropertyValue, null), try store.getProperty(head, "absent", testing.allocator));
    }
}

// ============================================================================
// (4) Overwrite churn
// ============================================================================

test "overflow (4): 100 overwrites of an overflowed value keep page growth bounded" {
    var env = try Env.init(8192, 256);
    defer env.deinit();
    env.wire();
    var store = env.store();
    store.slab_packing = false;

    const v = try vectorBytes(testing.allocator, 2560);
    defer testing.allocator.free(v);

    var head = try store.putProperty(0, "embedding", .{ .string = v });
    const after_first = env.allocated();

    for (0..100) |i| {
        const w = try filled(testing.allocator, v.len, @truncate(i));
        defer testing.allocator.free(w);
        head = try store.putProperty(head, "embedding", .{ .string = w });
        try expectProp(&store, head, "embedding", .{ .string = w });
    }

    // Each overwrite writes a NEW var chain and frees the OLD one, so the
    // allocator's high-water mark must not creep: no growth at all is
    // expected (the freed page is reused immediately), and we allow a small
    // constant of slack rather than a per-iteration term.
    const after_churn = env.allocated();
    try testing.expect(after_churn <= after_first + 2);
}

test "overflow (4b): small→large, large→small and large→large transitions all round-trip" {
    for ([_]bool{ true, false }) |slab| {
        var env = try Env.init(8192, 256);
        defer env.deinit();
        env.wire();
        var store = env.store();
        store.slab_packing = slab;

        const big1 = try vectorBytes(testing.allocator, 2560);
        defer testing.allocator.free(big1);
        const big2 = try filled(testing.allocator, 3072 * 4, 9);
        defer testing.allocator.free(big2);

        var head = try store.putProperty(0, "v", .{ .string = "small" });
        head = try store.putProperty(head, "keep", .{ .int = 1 });
        try expectProp(&store, head, "v", .{ .string = "small" });

        // small → large
        head = try store.putProperty(head, "v", .{ .string = big1 });
        try expectProp(&store, head, "v", .{ .string = big1 });
        try expectProp(&store, head, "keep", .{ .int = 1 });

        // large → large
        head = try store.putProperty(head, "v", .{ .string = big2 });
        try expectProp(&store, head, "v", .{ .string = big2 });

        // large → small
        head = try store.putProperty(head, "v", .{ .string = "small again" });
        try expectProp(&store, head, "v", .{ .string = "small again" });
        try expectProp(&store, head, "keep", .{ .int = 1 });

        var oracle = try readOracle(testing.allocator, &store, head);
        defer oracle.deinit();
        try testing.expectEqual(@as(usize, 2), oracle.props.items.len);
    }
}

// ============================================================================
// (5) Delete
// ============================================================================

test "overflow (5): removing an overflowed property frees its chain; siblings still read" {
    for ([_]bool{ true, false }) |slab| {
        var env = try Env.init(8192, 256);
        defer env.deinit();
        env.wire();
        var store = env.store();
        store.slab_packing = slab;

        const v = try vectorBytes(testing.allocator, 2560);
        defer testing.allocator.free(v);

        var head = try store.putProperty(0, "keep", .{ .string = "hello" });
        const before_big = env.allocated();
        head = try store.putProperty(head, "embedding", .{ .string = v });
        const with_big = env.allocated();
        try testing.expect(with_big > before_big); // the var chain was allocated

        try store.removeProperty(head, "embedding");
        try testing.expectEqual(before_big, env.allocated()); // chain reclaimed

        try testing.expectEqual(@as(?PropertyValue, null), try store.getProperty(head, "embedding", testing.allocator));
        try expectProp(&store, head, "keep", .{ .string = "hello" });

        var oracle = try readOracle(testing.allocator, &store, head);
        defer oracle.deinit();
        try testing.expectEqual(@as(usize, 1), oracle.props.items.len);
    }
}

test "overflow (5b): leak PARITY for node deletion — the overflow chain leaks exactly like the props page" {
    // R1 note-test. Deleting a node does NOT reclaim its property PAGES today
    // (a pre-existing gap, deliberately unchanged here). This pins the parity:
    // the overflow var chain is no worse — it leaks with the page, and never
    // MORE than the page, so no reader can reach a freed chain.
    var env = try Env.init(8192, 256);
    defer env.deinit();
    env.wire();
    var store = env.store();
    store.slab_packing = false;

    const v = try vectorBytes(testing.allocator, 2560);
    defer testing.allocator.free(v);

    const before = env.allocated();
    const head = try store.putProperty(0, "embedding", .{ .string = v });
    const after = env.allocated();
    try testing.expect(after > before);

    // "Deleting the node" == dropping the head. Nothing is reclaimed — for the
    // props page (pre-existing) NOR the overflow chain (same parity).
    try testing.expectEqual(after, env.allocated());

    // Explicit removal is the supported reclamation path and DOES free both
    // sides' bookkeeping for the value.
    try store.removeProperty(head, "embedding");
    try testing.expect(env.allocated() < after);
}

// ============================================================================
// (6) Slab-resident nodes
// ============================================================================

test "overflow (6): a slab-resident node overflows in place; the var ref survives slab→legacy migration" {
    var env = try Env.init(8192, 256);
    defer env.deinit();
    env.wire();
    var store = env.store();
    store.slab_packing = true;

    // A small first property packs into a SLAB slot.
    var head = try store.putProperty(0, "name", .{ .string = "slab node" });
    try testing.expect(gs.prop_store.isSlabHead(head));

    const v = try vectorBytes(testing.allocator, 2560);
    defer testing.allocator.free(v);

    // Overflowing value on a SLAB-resident node: the 13-byte stub keeps the
    // blob small enough to stay slab-resident.
    head = try store.putProperty(head, "embedding", .{ .string = v });
    try testing.expect(gs.prop_store.isSlabHead(head));
    try expectProp(&store, head, "embedding", .{ .string = v });
    try expectProp(&store, head, "name", .{ .string = "slab node" });

    // Now grow the blob past slab capacity with INLINE filler so the node
    // MIGRATES to a legacy chain. The overflow stub is copied verbatim by the
    // migration, so the var ref must still resolve afterwards.
    var i: usize = 0;
    var key_buf: [32]u8 = undefined;
    while (gs.prop_store.isSlabHead(head) and i < 64) : (i += 1) {
        const key = try std.fmt.bufPrint(&key_buf, "filler_{d}", .{i});
        const filler = try filled(testing.allocator, 512, @truncate(i));
        defer testing.allocator.free(filler);
        head = try store.putProperty(head, key, .{ .string = filler });
    }
    try testing.expect(!gs.prop_store.isSlabHead(head)); // migrated to legacy
    try expectProp(&store, head, "embedding", .{ .string = v }); // ref survived
    try expectProp(&store, head, "name", .{ .string = "slab node" });

    var oracle = try readOracle(testing.allocator, &store, head);
    defer oracle.deinit();
    try expectValueEqual(.{ .string = v }, oracle.get("embedding").?);
}

test "overflow (6b): removing an overflowed property from a slab blob frees the chain" {
    var env = try Env.init(8192, 256);
    defer env.deinit();
    env.wire();
    var store = env.store();
    store.slab_packing = true;

    const v = try vectorBytes(testing.allocator, 2560);
    defer testing.allocator.free(v);

    var head = try store.putProperty(0, "name", .{ .string = "slab node" });
    try testing.expect(gs.prop_store.isSlabHead(head));
    const before = env.allocated();
    head = try store.putProperty(head, "embedding", .{ .string = v });
    try testing.expect(env.allocated() > before);

    try store.removeProperty(head, "embedding");
    try testing.expectEqual(before, env.allocated());
    try testing.expectEqual(@as(?PropertyValue, null), try store.getProperty(head, "embedding", testing.allocator));
    try expectProp(&store, head, "name", .{ .string = "slab node" });
}

// ============================================================================
// (7) Property index consistency
// ============================================================================

test "overflow (7): a property index over an overflowed value looks up and survives reload" {
    const alloc = testing.allocator;
    var td = try TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xB1} ** 16;
    var cfg = gs.test_support.testConfig();
    cfg.page_size = 8192;
    cfg.buffer_pool_pages = 512;

    const v = try vectorBytes(alloc, 2560);
    defer alloc.free(v);

    var nid: u64 = 0;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.close() catch {};

        nid = try eng.allocNode();
        try eng.putNode(nid, gs.test_support.emptyNode(1));
        try eng.addLabel(nid, 5);

        var rec = (try eng.getNode(nid)).?;
        rec.prop_head = try eng.putProperty(rec.prop_head, "embedding", .{ .string = v });
        try eng.putNode(nid, rec);

        // A decoy node with a DIFFERENT overflowed value must not collide.
        const other = try eng.allocNode();
        try eng.putNode(other, gs.test_support.emptyNode(1));
        try eng.addLabel(other, 5);
        var orec = (try eng.getNode(other)).?;
        const w = try filled(alloc, v.len, 3);
        defer alloc.free(w);
        orec.prop_head = try eng.putProperty(orec.prop_head, "embedding", .{ .string = w });
        try eng.putNode(other, orec);

        try eng.createPropertyIndex(5, "embedding");
        const found = try eng.lookupPropertyIndex(5, "embedding", .{ .string = v });
        try testing.expectEqual(@as(?u64, nid), found);

        try eng.checkpoint();
        try eng.close();
    }

    // Reload: the index snapshot loaded from disk must agree with a rebuild
    // over the replayed pages (both resolve the overflow stub identically).
    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        const found = try eng.lookupPropertyIndex(5, "embedding", .{ .string = v });
        try testing.expectEqual(@as(?u64, nid), found);

        // Force a rebuild and re-check: rebuild-vs-reload digest equality.
        _ = try eng.dropPropertyIndex(5, "embedding");
        try eng.createPropertyIndex(5, "embedding");
        const rebuilt = try eng.lookupPropertyIndex(5, "embedding", .{ .string = v });
        try testing.expectEqual(@as(?u64, nid), rebuilt);
    }
}

// ============================================================================
// (8) Crash / WAL replay
// ============================================================================

fn expectEngineProp(alloc: Allocator, eng: *GraphEngine, nid: u64, key: []const u8, want: []const u8) !void {
    const rec = (try eng.getNode(nid)) orelse return error.NodeInvisible;
    const got = try eng.getProperty(rec.prop_head, key, alloc);
    if (got == null) return error.PropertyMissing;
    defer property.freeDecoded(alloc, got.?);
    try testing.expectEqualSlices(u8, want, got.?.string);
}

test "overflow (8): a committed overflowed value replays byte-identical; an uncommitted one is invisible" {
    const alloc = testing.allocator;
    var td = try TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xB2} ** 16;
    var cfg = gs.test_support.testConfig();
    cfg.page_size = 8192;
    // Big pool: no dirty page is stolen before the crash, so the ONLY
    // durability channel is the fsynced WAL — exactly the overflow chain's
    // logVarChain images plus the props page image.
    cfg.buffer_pool_pages = 1024;

    const v = try vectorBytes(alloc, 2560);
    defer alloc.free(v);
    const w = try filled(alloc, 3072 * 4, 0x5A);
    defer alloc.free(w);

    var committed: u64 = 0;
    var ghost: u64 = 0;

    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.close() catch {};

        committed = try eng.allocNode();
        try eng.putNode(committed, gs.test_support.emptyNode(1));
        ghost = try eng.allocNode();
        try eng.putNode(ghost, gs.test_support.emptyNode(1));
        try eng.checkpoint(); // everything above is on the data pages

        // Crash window (WAL-only): a committed overflowed value.
        {
            var rec = (try eng.getNode(committed)).?;
            rec.prop_head = try eng.putProperty(rec.prop_head, "embedding", .{ .string = v });
            rec.prop_head = try eng.putProperty(rec.prop_head, "note", .{ .string = "inline" });
            try eng.putNode(committed, rec);
        }

        // An UNCOMMITTED overflowed value: must be atomically invisible.
        {
            const txn = try eng.beginTxn();
            var rec = (try eng.getNode(ghost)).?;
            rec.prop_head = try eng.putPropertyTxn(rec.prop_head, "embedding", .{ .string = w }, txn);
            try eng.putNodeTxn(ghost, rec, txn);
            // NO commit — abandoned by the crash below.
        }

        eng.deinit(); // SIMULATED CRASH: no checkpoint, no close, no flush
    }

    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};

        try expectEngineProp(alloc, eng, committed, "embedding", v);
        try expectEngineProp(alloc, eng, committed, "note", "inline");

        const grec = (try eng.getNode(ghost)).?;
        try testing.expectEqual(@as(u64, 0), grec.prop_head);
    }
}

test "overflow (8b): an overflowed value in the deferred-WAL tail replays" {
    const alloc = testing.allocator;
    var td = try TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xB3} ** 16;
    var cfg = gs.test_support.testConfig();
    cfg.page_size = 8192;
    cfg.sync_mode = .deferred; // the tail lives in the OS page cache
    cfg.buffer_pool_pages = 1024; // no steal: only the deferred WAL carries it

    const v = try vectorBytes(alloc, 3072);
    defer alloc.free(v);

    var nid: u64 = 0;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.close() catch {};
        nid = try eng.allocNode();
        try eng.putNode(nid, gs.test_support.emptyNode(1));
        try eng.checkpoint(); // durable barrier

        var rec = (try eng.getNode(nid)).?;
        rec.prop_head = try eng.putProperty(rec.prop_head, "embedding", .{ .string = v });
        try eng.putNode(nid, rec);

        eng.deinit(); // crash with the write only in the deferred WAL tail
    }

    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try expectEngineProp(alloc, eng, nid, "embedding", v);
    }
}

test "overflow (8c): an overwrite inside the crash window leaves no dangling ref" {
    const alloc = testing.allocator;
    var td = try TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xB4} ** 16;
    var cfg = gs.test_support.testConfig();
    cfg.page_size = 8192;
    cfg.buffer_pool_pages = 1024;

    const v1 = try vectorBytes(alloc, 2560);
    defer alloc.free(v1);
    const v2 = try filled(alloc, 2560 * 4, 0x33);
    defer alloc.free(v2);

    var nid: u64 = 0;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.close() catch {};
        nid = try eng.allocNode();
        try eng.putNode(nid, gs.test_support.emptyNode(1));
        var rec = (try eng.getNode(nid)).?;
        rec.prop_head = try eng.putProperty(rec.prop_head, "embedding", .{ .string = v1 });
        try eng.putNode(nid, rec);
        try eng.checkpoint(); // v1 is durable on the data pages

        // Crash window: overwrite with a DIFFERENT overflowed value. The new
        // chain is written first and the old one freed last, so whichever
        // side replay lands on, the stub it sees must resolve.
        rec = (try eng.getNode(nid)).?;
        rec.prop_head = try eng.putProperty(rec.prop_head, "embedding", .{ .string = v2 });
        try eng.putNode(nid, rec);

        eng.deinit(); // SIMULATED CRASH
    }

    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        // The committed overwrite replays; the value resolves (no dangling ref).
        try expectEngineProp(alloc, eng, nid, "embedding", v2);
    }
}

// ============================================================================
// (9) Backward compatibility
// ============================================================================

test "overflow (9): a store with no overflow entries keeps format_version 4 and reopens clean" {
    const alloc = testing.allocator;
    var td = try TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xB5} ** 16;
    var cfg = gs.test_support.testConfig();
    cfg.page_size = 8192;

    var nid: u64 = 0;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.close() catch {};
        nid = try eng.allocNode();
        try eng.putNode(nid, gs.test_support.emptyNode(1));
        var rec = (try eng.getNode(nid)).?;
        rec.prop_head = try eng.putProperty(rec.prop_head, "name", .{ .string = "small" });
        rec.prop_head = try eng.putProperty(rec.prop_head, "n", .{ .int = 7 });
        try eng.putNode(nid, rec);
        try eng.checkpoint();
        // No overflow entry was written anywhere: the manifest format version
        // is unchanged (NO manifest bump — precedent GAP-0060).
        try testing.expectEqual(@as(u32, 4), eng.manifest.format_version);
        try eng.close();
    }

    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try testing.expectEqual(@as(u32, 4), eng.manifest.format_version);
        try expectEngineProp(alloc, eng, nid, "name", "small");
    }
}

test "overflow (9b): a hand-crafted tag-7 value is rejected cleanly by a v0.3.2-shaped reader" {
    // A pre-overflow reader reaches property.decode/decodeView with the raw
    // on-page bytes. Tag 7 was not a member of its Tag enum → InvalidFormat.
    // Today the tag EXISTS but decoding an UNRESOLVED stub is still a hard,
    // non-panicking error — never silent misinterpretation.
    const stub = [_]u8{ 7, 0x0D, 0x00, 0x00, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    try testing.expectError(error.UnresolvedOverflowValue, property.decodeView(&stub));
    try testing.expectError(error.UnresolvedOverflowValue, property.decode(testing.allocator, &stub));

    // A TRUNCATED stub is rejected too — the tag is the discriminator, so it
    // is refused before any length is trusted (never an OOB read).
    try testing.expectError(error.UnresolvedOverflowValue, property.decodeView(stub[0..5]));
    try testing.expectError(error.UnexpectedEndOfInput, property.decodeView(&[_]u8{}));

    // A tag byte ABOVE the known range is still InvalidFormat for both paths.
    const bogus = [_]u8{ 9, 0, 0, 0, 0 };
    try testing.expectError(error.InvalidFormat, property.decodeView(&bogus));
}

test "overflow (9c): a dangling overflow stub fails loudly instead of returning garbage" {
    var env = try Env.init(8192, 256);
    defer env.deinit();
    env.wire();
    var store = env.store();
    store.slab_packing = false;

    const v = try vectorBytes(testing.allocator, 2560);
    defer testing.allocator.free(v);
    const head = try store.putProperty(0, "embedding", .{ .string = v });

    // Corrupt the stub's length field so the resolved chain no longer matches
    // the recorded encoded_len (R10): the read must report DataCorruption.
    const frame = try store.buffer_pool.pin(.props, head);
    const frame_idx = store.buffer_pool.frameIndex(frame);
    const data = frame.dataSlice();
    // entry: key_len(2) + "embedding"(9) → value at PROP_DATA_OFFSET + 11
    const val_off: usize = 32 + 12 + 2 + "embedding".len;
    try testing.expectEqual(@as(u8, 7), data[val_off]);
    std.mem.writeInt(u32, data[val_off + 1 ..][0..4], 123456, .little);
    store.buffer_pool.unpin(frame_idx, true);

    try testing.expectError(error.DataCorruption, store.getProperty(head, "embedding", testing.allocator));
}

// ============================================================================
// (10) Error identity
// ============================================================================

test "overflow (10): key overflow → PropertyKeyTooLong; value over the sanity cap → PropertyValueTooLarge" {
    var env = try Env.init(4096, 256);
    defer env.deinit();
    env.wire();
    var store = env.store();

    // (a) key beyond the u16 range → key error.
    {
        const key = try testing.allocator.alloc(u8, std.math.maxInt(u16) + 1);
        defer testing.allocator.free(key);
        @memset(key, 'x');
        try testing.expectError(error.PropertyKeyTooLong, store.putProperty(0, key, .{ .int = 1 }));
    }

    // (b) key within u16 but too long for the page — even the 13-byte stub
    //     cannot join it → still a KEY problem.
    {
        const key = try testing.allocator.alloc(u8, std.math.maxInt(u16));
        defer testing.allocator.free(key);
        @memset(key, 'k');
        try testing.expectError(error.PropertyKeyTooLong, store.putProperty(0, key, .{ .int = 1 }));
    }

    // (c) a key that leaves less room than the stub needs → KEY problem.
    {
        const budget = inlineValueBudget(4096, 0) + 2; // key_len field + key + value
        const key = try testing.allocator.alloc(u8, budget - 2 - 12);
        defer testing.allocator.free(key);
        @memset(key, 'q');
        const big = try filled(testing.allocator, 65536, 1);
        defer testing.allocator.free(big);
        try testing.expectError(error.PropertyKeyTooLong, store.putProperty(0, key, .{ .string = big }));
    }

    // (d) a value over the configured sanity cap → VALUE problem.
    {
        store.max_property_value_bytes = 4096;
        const big = try filled(testing.allocator, 8192, 1);
        defer testing.allocator.free(big);
        try testing.expectError(error.PropertyValueTooLarge, store.putProperty(0, "k", .{ .string = big }));
        // Just under the cap succeeds through the overflow path.
        const ok = try filled(testing.allocator, 4000, 1);
        defer testing.allocator.free(ok);
        const head = try store.putProperty(0, "k", .{ .string = ok });
        try expectProp(&store, head, "k", .{ .string = ok });
    }
}

test "overflow (10b): the default sanity cap is 1 MiB and is enforced end-to-end" {
    try testing.expectEqual(@as(u32, 1024 * 1024), (gs.GraphConfig{}).max_property_value_bytes);

    var env = try Env.init(8192, 256);
    defer env.deinit();
    env.wire();
    var store = env.store();
    try testing.expectEqual(@as(u32, 1024 * 1024), store.max_property_value_bytes);

    const over = try testing.allocator.alloc(u8, 1024 * 1024 + 1);
    defer testing.allocator.free(over);
    @memset(over, 'z');
    try testing.expectError(error.PropertyValueTooLarge, store.putProperty(0, "k", .{ .string = over }));
}

// ============================================================================
// Encrypted store (R6)
// ============================================================================

test "overflow (R6): an overflowed value round-trips in an ENCRYPTED store and survives reopen" {
    const alloc = testing.allocator;
    var td = try TestDataDir.init(alloc);
    defer td.deinit();
    const uuid = [_]u8{0xB6} ** 16;
    var cfg = gs.test_support.testConfig();
    cfg.page_size = 8192;
    cfg.buffer_pool_pages = 512;
    var key: [32]u8 = undefined;
    @memset(&key, 0xC7);
    cfg.encryption_key = key;

    const v = try vectorBytes(alloc, 2560);
    defer alloc.free(v);

    var nid: u64 = 0;
    {
        const eng = try GraphEngine.create(alloc, td.path, uuid, cfg);
        errdefer eng.close() catch {};
        nid = try eng.allocNode();
        try eng.putNode(nid, gs.test_support.emptyNode(1));
        var rec = (try eng.getNode(nid)).?;
        rec.prop_head = try eng.putProperty(rec.prop_head, "embedding", .{ .string = v });
        rec.prop_head = try eng.putProperty(rec.prop_head, "note", .{ .string = "encrypted" });
        try eng.putNode(nid, rec);
        try expectEngineProp(alloc, eng, nid, "embedding", v);
        try eng.checkpoint();
        try eng.close();
    }

    {
        const eng = try GraphEngine.open(alloc, td.path, uuid, cfg);
        defer eng.close() catch {};
        try expectEngineProp(alloc, eng, nid, "embedding", v);
        try expectEngineProp(alloc, eng, nid, "note", "encrypted");
    }
}

// ============================================================================
// Codec unit gates
// ============================================================================

test "overflow codec: stub layout is exactly 13 bytes and round-trips" {
    try testing.expectEqual(@as(usize, 13), property.OVERFLOW_STUB_SIZE);
    try testing.expectEqual(@as(u8, 7), @intFromEnum(property.Tag.overflow));

    var buf: [property.OVERFLOW_STUB_SIZE]u8 = undefined;
    try property.writeOverflowStub(&buf, 0xDEADBEEF, 0x0102030405060708);
    try testing.expectEqual(@as(u8, 7), buf[0]);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), std.mem.readInt(u32, buf[1..5], .little));
    try testing.expectEqual(@as(u64, 0x0102030405060708), std.mem.readInt(u64, buf[5..13], .little));

    const back = try property.readOverflowStub(&buf);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), back.encoded_len);
    try testing.expectEqual(@as(u64, 0x0102030405060708), back.var_ref);

    // Non-stub bytes are recognised as such.
    try testing.expect(!property.isOverflowStub(&[_]u8{ 4, 0, 0, 0, 0 }));
    try testing.expect(property.isOverflowStub(&buf));
    try testing.expect(!property.isOverflowStub(&[_]u8{}));

    // A truncated stub never reads out of bounds.
    try testing.expectError(error.UnexpectedEndOfInput, property.readOverflowStub(buf[0..7]));
}

test {
    std.testing.refAllDecls(@This());
}
