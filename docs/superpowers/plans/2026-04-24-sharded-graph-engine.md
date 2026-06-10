# Sharded Graph Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `ShardedGraphEngine` facade that owns `N=16` independent single-threaded `GraphEngine` instances per logical graph, routing ops by `shardIndex(node_id)` and coordinating cross-shard edges via a small 2-phase protocol, unlocking N-way writer concurrency without changing each engine's single-threaded correctness argument.

**Architecture:** Each logical graph becomes `<data_dir>/<graph_uuid>/` containing N `shard_XX/` sub-directories (each a complete existing `GraphEngine` layout) plus a top-level `shard_manifest.json`. The facade reuses `sharded_store.shardIndex` for routing, allocates striped ids (`k*N + shard_index`) so `shard_of(id) == s`, extends `WalRecordType` with three cross-shard records (`cross_shard_prepare` / `_commit` / `_abort`), and owns a global label dictionary so `LabelId` stays meaningful across shards. The existing `GraphStorage` vtable shape is preserved exactly.

**Tech Stack:** Zig 0.15.x, existing `graph_storage` crate, `gitlab.com/devnw/zig/wal`, `std.Io.Mutex`, `std.atomic.Value`, `thread_pool` dep (already used by `GraphEngine`). No new third-party crates.

---

## File Structure

| File | Responsibility | Action |
|------|----------------|--------|
| `src/shard_count.zig` | `SHARD_COUNT` constant + `shardOfNode` / `shardOfEdgeSource` helpers | Create |
| `src/shard_manifest.zig` | Top-level `shard_manifest.json` read/write (version, N, algorithm hash, per-shard uuids) | Create |
| `src/shard_uuid.zig` | Derive per-shard uuid = `blake3(graph_uuid \|\| "shard_XX")[..16]` | Create |
| `src/sharded_store.zig` | Existing splitmix64 primitive | Re-use `shardIndex`; do not modify |
| `src/wal_record.zig` | WAL record enum | Modify: add 3 cross-shard record variants + `global_txn_id` payload parser |
| `src/engine.zig` | Single-engine entry point | Modify: accept `base_shard_index: ?usize` in `GraphConfig` and use it inside `allocNode` / `addEdgeTxn` for striped ids |
| `src/config.zig` | `GraphConfig` | Modify: add optional `base_shard_index` field |
| `src/sharded_engine.zig` | The `ShardedGraphEngine` facade (create/open/close/deinit, intra-shard routing, fan-out iterators, 2PC, global label dict, global manifest lifecycle, `storage()`) | Create |
| `src/sharded_engine_2pc.zig` | 2PC helpers (cross-shard edge-create protocol, durability barrier) | Create |
| `src/sharded_recovery.zig` | Sharded-recovery orchestration: parallel per-shard replay + dangling-prepare reconciliation pass | Create |
| `src/sharded_engine_test.zig` | Unit tests for the facade (isolated from integration tests) | Create |
| `src/root.zig` | Crate root re-exports | Modify: publish `ShardedGraphEngine`, `shard_count`, `shard_manifest`, `shard_uuid` |
| `tests/integration_sharded.zig` | Full-engine integration tests (create / CRUD / fan-out scan / checkpoint / reopen) | Create |
| `tests/test_cross_shard_recovery.zig` | Crash-at-every-step permutations for 2PC | Create |
| `benchmarks/sharded_throughput.zig` | Microbench proving ≥ 4× single-engine alloc+put+WAL throughput on 16 cores | Create |
| `build.zig` | Build wiring | Modify: add `test-integration-sharded`, `test-cross-shard-recovery`, `bench-sharded-throughput` steps |
| `CHANGELOG.md` | User-visible change | Modify: entry for the sharded engine |

**Responsibility split rationale:** `sharded_engine.zig` is the ops-routing and public API file; `sharded_engine_2pc.zig` keeps the cross-shard edge protocol isolated so the intra-shard fast path stays readable; `sharded_recovery.zig` is separate because it runs at open time only and shares nothing with the ops path. All three files live under 800 lines.

---

## Task 1: Shard-count module

**Files:**

- Create: `src/shard_count.zig`

- [ ] **Step 1: Write the failing test**

```zig
// src/shard_count.zig
const std = @import("std");
const sharded_store = @import("sharded_store.zig");

test "SHARD_COUNT matches sharded_store.SHARD_COUNT" {
    try std.testing.expectEqual(sharded_store.SHARD_COUNT, @import("shard_count.zig").SHARD_COUNT);
}

test "shardOfNode returns splitmix64(id) % SHARD_COUNT" {
    const mod = @import("shard_count.zig");
    try std.testing.expectEqual(sharded_store.shardIndex(42), mod.shardOfNode(42));
    try std.testing.expectEqual(sharded_store.shardIndex(0), mod.shardOfNode(0));
}

test "shardOfEdgeSource routes by source node id" {
    const mod = @import("shard_count.zig");
    const src: u64 = 17;
    try std.testing.expectEqual(mod.shardOfNode(src), mod.shardOfEdgeSource(src));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `shard_count.zig` does not export `SHARD_COUNT`, `shardOfNode`, `shardOfEdgeSource`.

- [ ] **Step 3: Write minimal implementation**

```zig
// src/shard_count.zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Centralises the shard-count constant and the two shard-routing
//! helpers the `ShardedGraphEngine` uses. Kept in its own module so
//! tests and callers import a single canonical `SHARD_COUNT` rather
//! than importing `sharded_store` (which is the in-memory primitive)
//! when they only want the routing math.

const std = @import("std");
const sharded_store = @import("sharded_store.zig");

/// Number of shards per logical graph. Build-time constant; changing
/// it requires a data-dir migration (see `shard_manifest.zig`).
pub const SHARD_COUNT: usize = sharded_store.SHARD_COUNT;

/// Route a node id to its owning shard.
pub fn shardOfNode(node_id: u64) usize {
    return sharded_store.shardIndex(node_id);
}

/// Edges co-locate with their source node.
pub fn shardOfEdgeSource(source_node_id: u64) usize {
    return sharded_store.shardIndex(source_node_id);
}

test {
    std.testing.refAllDecls(@This());
}
```

Then re-copy the three tests from Step 1 into the bottom of `src/shard_count.zig` (tests live in the same file per project convention).

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — all three `shard_count` tests green.

- [ ] **Step 5: Commit**

```bash
git add src/shard_count.zig
git commit -m "feat: add shard_count module with SHARD_COUNT and routing helpers"
```

---

## Task 2: Per-shard UUID derivation

**Files:**

- Create: `src/shard_uuid.zig`

- [ ] **Step 1: Write the failing test**

```zig
// src/shard_uuid.zig
const std = @import("std");

test "deriveShardUuid is deterministic and shard-distinct" {
    const parent: [16]u8 = .{0xA1} ** 16;
    const shard0 = @import("shard_uuid.zig").deriveShardUuid(parent, 0);
    const shard0_again = @import("shard_uuid.zig").deriveShardUuid(parent, 0);
    const shard1 = @import("shard_uuid.zig").deriveShardUuid(parent, 1);

    try std.testing.expectEqualSlices(u8, &shard0, &shard0_again);
    try std.testing.expect(!std.mem.eql(u8, &shard0, &shard1));
}

test "deriveShardUuid differs across parents for the same shard" {
    const a: [16]u8 = .{0xA1} ** 16;
    const b: [16]u8 = .{0xB2} ** 16;
    const shard0_a = @import("shard_uuid.zig").deriveShardUuid(a, 0);
    const shard0_b = @import("shard_uuid.zig").deriveShardUuid(b, 0);
    try std.testing.expect(!std.mem.eql(u8, &shard0_a, &shard0_b));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `shard_uuid.zig` does not export `deriveShardUuid`.

- [ ] **Step 3: Write minimal implementation**

```zig
// src/shard_uuid.zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Derive a deterministic per-shard 16-byte UUID from the parent
//! graph UUID and the shard index. Uses BLAKE3 via std.crypto for
//! collision resistance.

const std = @import("std");

pub fn deriveShardUuid(parent: [16]u8, shard_index: usize) [16]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(&parent);
    var tag_buf: [16]u8 = undefined;
    const tag = std.fmt.bufPrint(&tag_buf, "shard_{d:0>2}", .{shard_index}) catch unreachable;
    hasher.update(tag);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var out: [16]u8 = undefined;
    @memcpy(&out, digest[0..16]);
    return out;
}

test {
    std.testing.refAllDecls(@This());
}
```

Append the two tests from Step 1.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/shard_uuid.zig
git commit -m "feat: add deriveShardUuid BLAKE3-based per-shard UUID helper"
```

---

## Task 3: ShardManifest JSON format

**Files:**

- Create: `src/shard_manifest.zig`

- [ ] **Step 1: Write the failing test**

```zig
// src/shard_manifest.zig
const std = @import("std");

test "ShardManifest round-trip via writeToDir / readFromDir" {
    const sm = @import("shard_manifest.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var per_shard: [16][16]u8 = undefined;
    for (&per_shard, 0..) |*u, i| u.* = .{@as(u8, @intCast(i))} ** 16;

    const original = sm.ShardManifest{
        .version = sm.SHARD_MANIFEST_VERSION,
        .shard_count = 16,
        .algorithm_hash = sm.SHARD_ALGORITHM_HASH,
        .per_shard_uuids = per_shard,
    };

    try sm.writeToDir(std.testing.allocator, path, original);

    const loaded = try sm.readFromDir(std.testing.allocator, path);
    try std.testing.expectEqual(original.version, loaded.version);
    try std.testing.expectEqual(original.shard_count, loaded.shard_count);
    try std.testing.expectEqual(original.algorithm_hash, loaded.algorithm_hash);
    for (0..16) |i| {
        try std.testing.expectEqualSlices(u8, &original.per_shard_uuids[i], &loaded.per_shard_uuids[i]);
    }
}

test "readFromDir rejects wrong algorithm_hash" {
    const sm = @import("shard_manifest.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var per_shard: [16][16]u8 = undefined;
    for (&per_shard) |*u| u.* = .{0} ** 16;

    var bad = sm.ShardManifest{
        .version = sm.SHARD_MANIFEST_VERSION,
        .shard_count = 16,
        .algorithm_hash = 0xDEADBEEFDEADBEEF,
        .per_shard_uuids = per_shard,
    };
    try sm.writeToDir(std.testing.allocator, path, bad);

    try std.testing.expectError(error.ShardAlgorithmMismatch, sm.readFromDir(std.testing.allocator, path));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `shard_manifest.zig` missing.

- [ ] **Step 3: Write minimal implementation**

```zig
// src/shard_manifest.zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Top-level per-graph manifest recording the shard-count, the
//! shard-routing algorithm version hash (so a mismatched build is
//! detected at open), and the per-shard derived UUIDs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const shard_count_mod = @import("shard_count.zig");

pub const SHARD_MANIFEST_VERSION: u32 = 1;

/// Stable 64-bit fingerprint of the shard-routing algorithm. Bumped
/// whenever the routing function semantics change. Value = crc32 of
/// "splitmix64%N:v1" encoded as LE u64.
pub const SHARD_ALGORITHM_HASH: u64 = 0x5350_4C49_544D_3601; // "SPLITM6\x01"

pub const ShardManifest = struct {
    version: u32,
    shard_count: u32,
    algorithm_hash: u64,
    per_shard_uuids: [shard_count_mod.SHARD_COUNT][16]u8,
};

const FILE_NAME = "shard_manifest.json";

pub fn writeToDir(allocator: Allocator, dir_path: []const u8, manifest: ShardManifest) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.writer(allocator).print(
        "{{\"version\":{d},\"shard_count\":{d},\"algorithm_hash\":{d},\"per_shard_uuids\":[",
        .{ manifest.version, manifest.shard_count, manifest.algorithm_hash },
    );
    for (manifest.per_shard_uuids, 0..) |uuid, i| {
        if (i != 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "\"");
        for (uuid) |b| try buf.writer(allocator).print("{x:0>2}", .{b});
        try buf.appendSlice(allocator, "\"");
    }
    try buf.appendSlice(allocator, "]}");

    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, FILE_NAME });
    defer allocator.free(file_path);
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().createFile(io, file_path, .{
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    defer file.close(io);
    try file.writePositionalAll(io, buf.items, 0);
    try file.sync(io);
}

pub fn readFromDir(allocator: Allocator, dir_path: []const u8) !ShardManifest {
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, FILE_NAME });
    defer allocator.free(file_path);
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);

    const bytes = try file.readAllAlloc(io, allocator, 1 << 16);
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const version = @as(u32, @intCast(root.get("version").?.integer));
    const shard_count = @as(u32, @intCast(root.get("shard_count").?.integer));
    const algorithm_hash = @as(u64, @intCast(root.get("algorithm_hash").?.integer));

    if (version != SHARD_MANIFEST_VERSION) return error.ShardManifestVersionMismatch;
    if (shard_count != shard_count_mod.SHARD_COUNT) return error.ShardCountMismatch;
    if (algorithm_hash != SHARD_ALGORITHM_HASH) return error.ShardAlgorithmMismatch;

    const arr = root.get("per_shard_uuids").?.array;
    if (arr.items.len != shard_count_mod.SHARD_COUNT) return error.ShardCountMismatch;

    var per_shard: [shard_count_mod.SHARD_COUNT][16]u8 = undefined;
    for (arr.items, 0..) |item, i| {
        const hex = item.string;
        if (hex.len != 32) return error.InvalidShardUuid;
        var out: [16]u8 = undefined;
        _ = try std.fmt.hexToBytes(&out, hex);
        per_shard[i] = out;
    }

    return .{
        .version = version,
        .shard_count = shard_count,
        .algorithm_hash = algorithm_hash,
        .per_shard_uuids = per_shard,
    };
}

test {
    std.testing.refAllDecls(@This());
}
```

Append both tests from Step 1 to the bottom of the file.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — round-trip and algorithm-mismatch tests both green.

- [ ] **Step 5: Commit**

```bash
git add src/shard_manifest.zig
git commit -m "feat: add ShardManifest JSON format with version/algorithm guard"
```

---

## Task 4: Striped-id support in GraphConfig and GraphEngine

**Rationale:** Every shard must allocate ids of the form `k*N + shard_index` so that `shardOfNode(id) == shard_index`. The single-engine `GraphEngine` today writes `manifest.next_node_id += 1`. We extend `GraphConfig` with an optional `base_shard_index` and change the allocator to `manifest.next_node_id += SHARD_COUNT` (or `+= 1` in the classic single-engine default).

**Files:**

- Modify: `src/config.zig`
- Modify: `src/engine.zig` lines around 586–594 (`allocNode`) and 664–668 (`addEdgeTxn` edge-id bump) and lines 140–148 (`Manifest` init in `create`).

- [ ] **Step 1: Write the failing test**

```zig
// append to src/engine_test.zig
test "GraphEngine with base_shard_index allocates striped node ids" {
    const SHARD_COUNT = @import("sharded_store.zig").SHARD_COUNT;

    var td = try testDataDir();
    defer td.deinit();
    const uuid = [_]u8{0xAA} ** 16;

    var cfg = testConfig();
    cfg.base_shard_index = 3; // shard 3 of 16

    const engine = try GraphEngine.create(std.testing.allocator, td.path, uuid, cfg);
    defer engine.close() catch {};

    const id1 = try engine.allocNode();
    const id2 = try engine.allocNode();
    try std.testing.expectEqual(@as(u64, 3), id1);                 // 0*16 + 3
    try std.testing.expectEqual(@as(u64, 3 + SHARD_COUNT), id2);   // 1*16 + 3
    try std.testing.expectEqual(@as(usize, 3), @import("sharded_store.zig").shardIndex(id1));
    try std.testing.expectEqual(@as(usize, 3), @import("sharded_store.zig").shardIndex(id2));
}

test "GraphEngine with base_shard_index bumps edge ids in stride" {
    const SHARD_COUNT = @import("sharded_store.zig").SHARD_COUNT;

    var td = try testDataDir();
    defer td.deinit();
    const uuid = [_]u8{0xAB} ** 16;

    var cfg = testConfig();
    cfg.base_shard_index = 5;

    const engine = try GraphEngine.create(std.testing.allocator, td.path, uuid, cfg);
    defer engine.close() catch {};

    const n1 = try engine.allocNode();
    try engine.putNode(n1, test_support.emptyNode(1));
    const n2 = try engine.allocNode();
    try engine.putNode(n2, test_support.emptyNode(1));

    const e1 = try engine.addEdge(n1, n2, 1);
    const e2 = try engine.addEdge(n1, n2, 1);
    try std.testing.expectEqual(@as(u64, 5), e1);                  // first edge id = base
    try std.testing.expectEqual(@as(u64, 5 + SHARD_COUNT), e2);    // second = +N
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `GraphConfig.base_shard_index` field missing, and `allocNode` returns `1`, not `3`.

- [ ] **Step 3: Write minimal implementation — config**

In `src/config.zig`, add to `GraphConfig`:

```zig
/// Shard index (0..SHARD_COUNT-1) for striped id allocation. When
/// non-null, `allocNode` returns `k*SHARD_COUNT + base_shard_index`
/// and `addEdge` bumps edge ids by `SHARD_COUNT`. `null` preserves
/// the classic single-engine behaviour (++1 stride).
base_shard_index: ?usize = null,
```

- [ ] **Step 4: Write minimal implementation — manifest init**

In `src/engine.zig` `create` function around line 140, after manifest fields are set, adjust initial `next_node_id` / `next_edge_id` when `cfg.base_shard_index != null`:

```zig
if (cfg.base_shard_index) |base| {
    self.manifest.next_node_id = base;
    self.manifest.next_edge_id = base;
    self.manifest.next_txn_id = base;
}
```

(Place this block right after the `self.manifest = Manifest{ ... };` initializer.)

- [ ] **Step 5: Write minimal implementation — allocNode**

Replace `src/engine.zig` `allocNode` body so the stride is `SHARD_COUNT` when `base_shard_index != null`:

```zig
pub fn allocNode(self: *GraphEngine) anyerror!NodeId {
    try self.ensureWritable();
    const id = self.manifest.next_node_id;
    const stride: u64 = if (self.config.base_shard_index != null)
        @intCast(@import("sharded_store.zig").SHARD_COUNT)
    else
        1;
    self.manifest.next_node_id += stride;
    self.manifest.node_count += 1;
    self.metrics.nodes_created += 1;
    self.markDirty();
    return id;
}
```

- [ ] **Step 6: Write minimal implementation — edge-id bump**

In `src/engine.zig` `addEdgeTxn`, replace:

```zig
const edge_id = self.manifest.next_edge_id;
self.manifest.next_edge_id += 1;
```

with:

```zig
const edge_id = self.manifest.next_edge_id;
const stride: u64 = if (self.config.base_shard_index != null)
    @intCast(@import("sharded_store.zig").SHARD_COUNT)
else
    1;
self.manifest.next_edge_id += stride;
```

- [ ] **Step 7: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — both new tests green, all existing engine tests still green.

- [ ] **Step 8: Commit**

```bash
git add src/config.zig src/engine.zig src/engine_test.zig
git commit -m "feat(engine): optional striped id allocation via base_shard_index"
```

---

## Task 5: Extend WalRecord with cross-shard record types

**Files:**

- Modify: `src/wal_record.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/wal_record.zig` tests:

```zig
test "cross_shard_prepare record round-trips with global_txn_id payload" {
    const allocator = std.testing.allocator;

    // Payload encodes: global_txn_id(8) + remote_shard_index(2) + edge_id(8)
    const global_txn_id: u64 = 0xC0FFEE;
    const remote_shard: u16 = 7;
    const edge_id: u64 = 42;

    var payload: [18]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], global_txn_id, .little);
    std.mem.writeInt(u16, payload[8..10], remote_shard, .little);
    std.mem.writeInt(u64, payload[10..18], edge_id, .little);

    var rec = WalRecord{
        .lsn = 10,
        .txn_id = 5,
        .record_type = .cross_shard_prepare,
        .file_id = 0,
        .page_id = 0,
        .payload = &payload,
        .checksum = 0,
    };
    rec.checksum = rec.computeChecksum();

    const bytes = try rec.serialize(allocator);
    defer allocator.free(bytes);

    const result = try WalRecord.deserialize(allocator, bytes);
    defer result.record.deinit(allocator);

    try std.testing.expectEqual(WalRecordType.cross_shard_prepare, result.record.record_type);
    try std.testing.expectEqualSlices(u8, &payload, result.record.payload);
}

test "cross_shard_commit and cross_shard_abort record types round-trip" {
    const allocator = std.testing.allocator;

    const rts = [_]WalRecordType{ .cross_shard_commit, .cross_shard_abort };
    for (rts) |rt| {
        var payload: [8]u8 = undefined;
        std.mem.writeInt(u64, &payload, 0xBEEF, .little);

        var rec = WalRecord{
            .lsn = 1,
            .txn_id = 1,
            .record_type = rt,
            .file_id = 0,
            .page_id = 0,
            .payload = &payload,
            .checksum = 0,
        };
        rec.checksum = rec.computeChecksum();

        const bytes = try rec.serialize(allocator);
        defer allocator.free(bytes);

        const result = try WalRecord.deserialize(allocator, bytes);
        defer result.record.deinit(allocator);

        try std.testing.expectEqual(rt, result.record.record_type);
        try std.testing.expectEqualSlices(u8, &payload, result.record.payload);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `cross_shard_prepare` / `cross_shard_commit` / `cross_shard_abort` not in the enum.

- [ ] **Step 3: Write minimal implementation**

In `src/wal_record.zig`, extend `WalRecordType`:

```zig
pub const WalRecordType = enum(u8) {
    page_update = 1,
    begin_txn = 2,
    commit_txn = 3,
    abort_txn = 4,
    checkpoint_marker = 5,
    cross_shard_prepare = 6,
    cross_shard_commit = 7,
    cross_shard_abort = 8,
};
```

No other changes are needed — serialization is type-agnostic beyond the enum byte, and `deserialize` already uses `std.enums.fromInt` so the new values parse correctly.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — both new tests green.

- [ ] **Step 5: Commit**

```bash
git add src/wal_record.zig
git commit -m "feat(wal): add cross_shard_{prepare,commit,abort} record types"
```

---

## Task 6: ShardedGraphEngine scaffolding — create/open/close/deinit

**Files:**

- Create: `src/sharded_engine.zig`
- Create: `src/sharded_engine_test.zig`
- Modify: `src/root.zig`
- Modify: `src/engine.zig` (`test { ... }` at the bottom — add `_ = @import("sharded_engine.zig");`)

**Scope:** This task stands up the facade struct, creates N sub-directories, writes the `shard_manifest.json`, instantiates N `GraphEngine` instances with `base_shard_index = s`, and tears them down in `close`/`deinit`. No op routing yet.

- [ ] **Step 1: Write the failing test**

```zig
// src/sharded_engine_test.zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const testing = std.testing;
const test_support = @import("testing_support.zig");
const config_mod = @import("config.zig");
const sharded_engine_mod = @import("sharded_engine.zig");
const shard_count_mod = @import("shard_count.zig");
const shard_manifest_mod = @import("shard_manifest.zig");

test "ShardedGraphEngine.create writes shard_manifest.json and N shard dirs" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x11} ** 16;

    var eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    // shard_manifest.json must exist at <data_dir>/<uuid_hex>/shard_manifest.json
    const graph_root = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/{s}",
        .{ td.path, sharded_engine_mod.uuidHex(uuid)[0..] },
    );
    defer testing.allocator.free(graph_root);

    const loaded = try shard_manifest_mod.readFromDir(testing.allocator, graph_root);
    try testing.expectEqual(@as(u32, @intCast(shard_count_mod.SHARD_COUNT)), loaded.shard_count);

    // Every per-shard uuid is distinct.
    for (0..shard_count_mod.SHARD_COUNT) |i| {
        for ((i + 1)..shard_count_mod.SHARD_COUNT) |j| {
            try testing.expect(!std.mem.eql(u8, &loaded.per_shard_uuids[i], &loaded.per_shard_uuids[j]));
        }
    }
}

test "ShardedGraphEngine.open re-reads an existing manifest and rebinds shards" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x22} ** 16;

    {
        var eng = try sharded_engine_mod.ShardedGraphEngine.create(
            testing.allocator,
            td.path,
            uuid,
            test_support.testConfig(),
        );
        try eng.close();
    }

    var eng = try sharded_engine_mod.ShardedGraphEngine.open(
        testing.allocator,
        td.path,
        uuid,
        test_support.testConfig(),
    );
    defer eng.close() catch {};

    try testing.expectEqual(shard_count_mod.SHARD_COUNT, eng.shards.len);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `sharded_engine.zig` missing.

- [ ] **Step 3: Write minimal implementation**

```zig
// src/sharded_engine.zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! ShardedGraphEngine — facade over N independent single-threaded
//! GraphEngine instances, one per shard. See
//! docs/superpowers/specs/2026-04-24-sharded-graph-engine-design.md.

const std = @import("std");
const Allocator = std.mem.Allocator;

const config_mod = @import("config.zig");
const engine_mod = @import("engine.zig");
const interface_mod = @import("interface.zig");
const shard_count_mod = @import("shard_count.zig");
const shard_manifest_mod = @import("shard_manifest.zig");
const shard_uuid_mod = @import("shard_uuid.zig");

const GraphConfig = config_mod.GraphConfig;
const GraphEngine = engine_mod.GraphEngine;
const GraphStorage = interface_mod.GraphStorage;

pub const SHARD_COUNT = shard_count_mod.SHARD_COUNT;

pub const ShardedGraphEngine = struct {
    allocator: Allocator,
    graph_uuid: [16]u8,
    graph_root: []u8, // owned, "<data_dir>/<graph_uuid_hex>"
    shards: [SHARD_COUNT]*GraphEngine,
    shard_manifest: shard_manifest_mod.ShardManifest,
    coordinator_txn_counter: std.atomic.Value(u64),

    pub fn create(
        allocator: Allocator,
        data_dir: []const u8,
        graph_uuid: [16]u8,
        cfg: GraphConfig,
    ) !*ShardedGraphEngine {
        const self = try allocator.create(ShardedGraphEngine);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.graph_uuid = graph_uuid;
        self.coordinator_txn_counter = std.atomic.Value(u64).init(0);

        // graph_root = "<data_dir>/<uuid_hex>"
        const uuid_hex_buf = uuidHex(graph_uuid);
        self.graph_root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, uuid_hex_buf[0..] });
        errdefer allocator.free(self.graph_root);

        const io = std.Io.Threaded.global_single_threaded.io();
        try std.Io.Dir.cwd().createDirPath(io, self.graph_root);

        // Derive per-shard uuids, instantiate N engines.
        var per_shard: [SHARD_COUNT][16]u8 = undefined;
        for (&per_shard, 0..) |*u, s| {
            u.* = shard_uuid_mod.deriveShardUuid(graph_uuid, s);
        }

        self.shard_manifest = .{
            .version = shard_manifest_mod.SHARD_MANIFEST_VERSION,
            .shard_count = @intCast(SHARD_COUNT),
            .algorithm_hash = shard_manifest_mod.SHARD_ALGORITHM_HASH,
            .per_shard_uuids = per_shard,
        };

        try shard_manifest_mod.writeToDir(allocator, self.graph_root, self.shard_manifest);

        // Spin up N GraphEngine instances with per-shard data_dir = graph_root.
        // Each engine's GraphDir path becomes "<graph_root>/graphs/<shard_uuid_hex>".
        var created: usize = 0;
        errdefer for (self.shards[0..created]) |e| e.close() catch {};

        for (0..SHARD_COUNT) |s| {
            var per_shard_cfg = cfg;
            per_shard_cfg.base_shard_index = s;
            // Per-shard buffer pool sizing: total / N (spec §Buffer pool).
            per_shard_cfg.buffer_pool_pages = @max(1, cfg.buffer_pool_pages / @as(u32, @intCast(SHARD_COUNT)));
            self.shards[s] = try GraphEngine.create(allocator, self.graph_root, per_shard[s], per_shard_cfg);
            created += 1;
        }

        return self;
    }

    pub fn open(
        allocator: Allocator,
        data_dir: []const u8,
        graph_uuid: [16]u8,
        cfg: GraphConfig,
    ) !*ShardedGraphEngine {
        const self = try allocator.create(ShardedGraphEngine);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.graph_uuid = graph_uuid;
        self.coordinator_txn_counter = std.atomic.Value(u64).init(0);

        const uuid_hex_buf = uuidHex(graph_uuid);
        self.graph_root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, uuid_hex_buf[0..] });
        errdefer allocator.free(self.graph_root);

        self.shard_manifest = try shard_manifest_mod.readFromDir(allocator, self.graph_root);

        var opened: usize = 0;
        errdefer for (self.shards[0..opened]) |e| e.close() catch {};

        for (0..SHARD_COUNT) |s| {
            var per_shard_cfg = cfg;
            per_shard_cfg.base_shard_index = s;
            per_shard_cfg.buffer_pool_pages = @max(1, cfg.buffer_pool_pages / @as(u32, @intCast(SHARD_COUNT)));
            self.shards[s] = try GraphEngine.open(
                allocator,
                self.graph_root,
                self.shard_manifest.per_shard_uuids[s],
                per_shard_cfg,
            );
            opened += 1;
        }

        return self;
    }

    pub fn close(self: *ShardedGraphEngine) !void {
        var first_err: ?anyerror = null;
        for (self.shards) |eng| {
            eng.close() catch |err| {
                if (first_err == null) first_err = err;
            };
        }
        self.allocator.free(self.graph_root);
        self.allocator.destroy(self);
        if (first_err) |err| return err;
    }

    pub fn deinit(self: *ShardedGraphEngine) void {
        for (self.shards) |eng| eng.deinit();
        self.allocator.free(self.graph_root);
        self.allocator.destroy(self);
    }
};

pub fn uuidHex(uuid: [16]u8) [32]u8 {
    var out: [32]u8 = undefined;
    const hex = "0123456789abcdef";
    for (uuid, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0F];
    }
    return out;
}

test {
    _ = @import("sharded_engine_test.zig");
}
```

- [ ] **Step 4: Wire into root.zig**

Modify `src/root.zig` to add:

```zig
pub const shard_count = @import("shard_count.zig");
pub const shard_uuid = @import("shard_uuid.zig");
pub const shard_manifest = @import("shard_manifest.zig");
pub const sharded_engine = @import("sharded_engine.zig");
pub const ShardedGraphEngine = sharded_engine.ShardedGraphEngine;
```

(Place alongside existing `pub const sharded_store = ...;` line.)

- [ ] **Step 5: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — both `sharded_engine_test` tests green.

- [ ] **Step 6: Commit**

```bash
git add src/sharded_engine.zig src/sharded_engine_test.zig src/root.zig
git commit -m "feat(sharded): ShardedGraphEngine create/open/close/deinit scaffolding"
```

---

## Task 7: Intra-shard read op routing

**Scope:** Implement the read side of the `GraphStorage` vtable — `getNode`, `getEdge`, `expandOutIter`, `expandInIter`, `getProperty`, `getAllProperties`, `nodeCount`, `edgeCount`, `getMetrics`. Each routes to `shards[shardOfNode(id)]` (or `shardOfEdgeSource(edge.from)`); aggregates come from all shards.

**Files:**

- Modify: `src/sharded_engine.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/sharded_engine_test.zig`:

```zig
const engine_mod_t = @import("engine.zig");
const node_mod_t = @import("node.zig");

test "ShardedGraphEngine.getNode routes by node id" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x33} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    const n = try eng.allocNode();
    try eng.putNode(n, test_support.emptyNode(1));

    const got = try eng.getNode(n);
    try testing.expect(got != null);

    // The node must live in the shard that shardOfNode(n) selects.
    const expected_shard = shard_count_mod.shardOfNode(n);
    const direct_got = try eng.shards[expected_shard].getNode(n);
    try testing.expect(direct_got != null);
}

test "ShardedGraphEngine.nodeCount sums per-shard counts" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x34} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    var created: u64 = 0;
    while (created < 100) : (created += 1) {
        const n = try eng.allocNode();
        try eng.putNode(n, test_support.emptyNode(1));
    }

    try testing.expectEqual(@as(u64, 100), try eng.nodeCount());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `getNode`, `allocNode`, `putNode`, `nodeCount` not declared on `ShardedGraphEngine`.

- [ ] **Step 3: Write minimal implementation**

Add to `ShardedGraphEngine` (in `src/sharded_engine.zig`):

```zig
const types = @import("types.zig");
const node_mod = @import("node.zig");
const edge_mod = @import("edge.zig");
const metrics_mod = @import("metrics.zig");
const NodeId = types.NodeId;
const EdgeId = types.EdgeId;
const LabelId = types.LabelId;
const TxnId = types.TxnId;
const PropertyValue = types.PropertyValue;
const NodeRec = node_mod.NodeRec;
const EdgeEntry = edge_mod.EdgeEntry;
const Metrics = metrics_mod.Metrics;

pub fn getNode(self: *ShardedGraphEngine, id: NodeId) anyerror!?NodeRec {
    return self.shards[shard_count_mod.shardOfNode(id)].getNode(id);
}

pub fn putNode(self: *ShardedGraphEngine, id: NodeId, rec: NodeRec) anyerror!void {
    return self.shards[shard_count_mod.shardOfNode(id)].putNode(id, rec);
}

pub fn allocNode(self: *ShardedGraphEngine) anyerror!NodeId {
    // Round-robin across shards so consumers that call allocNode in a
    // tight loop get balanced distribution. We intentionally do NOT
    // pick randomly — deterministic routing keeps tests reproducible.
    const idx = self.coordinator_txn_counter.fetchAdd(1, .monotonic) % SHARD_COUNT;
    return self.shards[idx].allocNode();
}

pub fn deleteNode(self: *ShardedGraphEngine, id: NodeId) anyerror!void {
    return self.shards[shard_count_mod.shardOfNode(id)].deleteNode(id);
}

pub fn getEdge(self: *ShardedGraphEngine, edge_id: EdgeId) anyerror!?EdgeEntry {
    // Edges live on their source node's shard. Edge id itself is
    // shard-striped so `shard_of(edge_id) == source_shard`.
    return self.shards[shard_count_mod.shardOfNode(edge_id)].getEdge(edge_id);
}

pub fn expandOutIter(self: *ShardedGraphEngine, id: NodeId, rel_type: ?u32) anyerror!@TypeOf(self.shards[0].expandOutIter(id, rel_type) catch unreachable) {
    return self.shards[shard_count_mod.shardOfNode(id)].expandOutIter(id, rel_type);
}

pub fn expandInIter(self: *ShardedGraphEngine, id: NodeId, rel_type: ?u32) anyerror!@TypeOf(self.shards[0].expandInIter(id, rel_type) catch unreachable) {
    // expandIn is intra-shard by construction — incoming adjacency
    // for node v lives in v's shard (§Cross-shard operations.2).
    return self.shards[shard_count_mod.shardOfNode(id)].expandInIter(id, rel_type);
}

pub fn getProperty(self: *ShardedGraphEngine, prop_head: u64, key: []const u8, allocator: Allocator) anyerror!?PropertyValue {
    // Property chain heads live on the same shard as their owning
    // node; prop_head is itself shard-striped (allocated on that shard).
    return self.shards[shard_count_mod.shardOfNode(prop_head)].getProperty(prop_head, key, allocator);
}

pub fn nodeCount(self: *ShardedGraphEngine) anyerror!u64 {
    var total: u64 = 0;
    for (self.shards) |eng| total += try eng.nodeCount();
    return total;
}

pub fn edgeCount(self: *ShardedGraphEngine) anyerror!u64 {
    var total: u64 = 0;
    for (self.shards) |eng| total += try eng.edgeCount();
    return total;
}
```

Note on the `@TypeOf(... catch unreachable)` trick: this keeps the iterator type private to `GraphEngine` (it's `AdjStore.AdjEdgeIterator`). An alternative is to import `adj_store.zig` and use `adj_store.AdjStore.AdjEdgeIterator` directly. Prefer the explicit import for readability:

```zig
const adj_store_mod = @import("adj_store.zig");

pub fn expandOutIter(self: *ShardedGraphEngine, id: NodeId, rel_type: ?u32) anyerror!adj_store_mod.AdjStore.AdjEdgeIterator {
    return self.shards[shard_count_mod.shardOfNode(id)].expandOutIter(id, rel_type);
}

pub fn expandInIter(self: *ShardedGraphEngine, id: NodeId, rel_type: ?u32) anyerror!adj_store_mod.AdjStore.AdjEdgeIterator {
    return self.shards[shard_count_mod.shardOfNode(id)].expandInIter(id, rel_type);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — both new tests green.

- [ ] **Step 5: Commit**

```bash
git add src/sharded_engine.zig src/sharded_engine_test.zig
git commit -m "feat(sharded): intra-shard read op routing (getNode/getEdge/expand/properties)"
```

---

## Task 8: Intra-shard edge create routing

**Scope:** Route `addEdge` to the source shard **when source and target live on the same shard**. Cross-shard is deferred to Task 12. Route `removeEdge` identically.

**Files:**

- Modify: `src/sharded_engine.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/sharded_engine_test.zig`:

```zig
test "ShardedGraphEngine.addEdge succeeds when source and target are co-located" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x40} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    // Two allocations from the same shard by forcing the round-robin.
    // Simplest approach: grab shard 0 directly.
    const n1 = try eng.shards[0].allocNode();
    const n2 = try eng.shards[0].allocNode();
    try eng.putNode(n1, test_support.emptyNode(1));
    try eng.putNode(n2, test_support.emptyNode(1));

    const e = try eng.addEdge(n1, n2, 1);
    try testing.expect(e != 0);

    const got = try eng.getEdge(e);
    try testing.expect(got != null);
    try testing.expectEqual(n2, got.?.neighbor);
}

test "ShardedGraphEngine.addEdge returns CrossShardEdge error when source and target are in different shards" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x41} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    const n_src = try eng.shards[0].allocNode();
    const n_dst = try eng.shards[3].allocNode();
    try eng.putNode(n_src, test_support.emptyNode(1));
    try eng.putNode(n_dst, test_support.emptyNode(1));

    // Task 8 (intra-shard-only) must surface a distinct error for
    // cross-shard edges. Task 12 replaces this with the 2PC flow.
    try testing.expectError(error.CrossShardEdgeUnsupported, eng.addEdge(n_src, n_dst, 1));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `addEdge` not declared on `ShardedGraphEngine`.

- [ ] **Step 3: Write minimal implementation**

Add to `src/sharded_engine.zig`:

```zig
pub fn addEdge(self: *ShardedGraphEngine, from: NodeId, to: NodeId, rel_type: u32) anyerror!EdgeId {
    const s_from = shard_count_mod.shardOfNode(from);
    const s_to = shard_count_mod.shardOfNode(to);
    if (s_from != s_to) return error.CrossShardEdgeUnsupported;
    return self.shards[s_from].addEdge(from, to, rel_type);
}

pub fn removeEdge(self: *ShardedGraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId) anyerror!void {
    const s_from = shard_count_mod.shardOfNode(from);
    const s_to = shard_count_mod.shardOfNode(to);
    if (s_from != s_to) return error.CrossShardEdgeUnsupported;
    return self.shards[s_from].removeEdge(from, to, edge_id);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — both tests green. `error.CrossShardEdgeUnsupported` is a placeholder that Task 12 replaces with the 2PC path.

- [ ] **Step 5: Commit**

```bash
git add src/sharded_engine.zig src/sharded_engine_test.zig
git commit -m "feat(sharded): intra-shard addEdge/removeEdge routing (cross-shard deferred)"
```

---

## Task 9: Properties, labels, transactions — fan-out write routing

**Scope:** `putProperty`, `removeProperty`, edge-property variants, `addLabel`, `removeLabel`, `beginTxn`/`commitTxn`/`abortTxn`, `checkpoint`, `getMetrics`. Labels route by node id; property owner is a node-id-shaped head so it routes identically. Transactions are per-shard — `beginTxn` on the facade returns an opaque `TxnId` that encodes `(shard_index, local_txn_id)`; commit/abort route back to the shard.

**Files:**

- Modify: `src/sharded_engine.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/sharded_engine_test.zig`:

```zig
test "ShardedGraphEngine.addLabel + scanLabel round-trips" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x50} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    const n1 = try eng.allocNode();
    const n2 = try eng.allocNode();
    try eng.putNode(n1, test_support.emptyNode(1));
    try eng.putNode(n2, test_support.emptyNode(1));
    try eng.addLabel(n1, 7);
    try eng.addLabel(n2, 7);

    const nodes = try eng.scanLabel(7, testing.allocator);
    defer testing.allocator.free(nodes);
    try testing.expectEqual(@as(usize, 2), nodes.len);
}

test "ShardedGraphEngine.putProperty + getProperty round-trips on one shard" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x51} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    const n = try eng.allocNode();
    try eng.putNode(n, test_support.emptyNode(1));

    var rec = (try eng.getNode(n)).?;
    const new_head = try eng.putProperty(rec.prop_head, "name", .{ .string = "alice" });
    rec.prop_head = new_head;
    try eng.putNode(n, rec);

    const got = try eng.getProperty(new_head, "name", testing.allocator);
    try testing.expect(got != null);
    defer if (got) |v| switch (v) {
        .string => |s| testing.allocator.free(s),
        else => {},
    };
    try testing.expectEqualStrings("alice", got.?.string);
}

test "ShardedGraphEngine.beginTxn encodes shard + commit routes back" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x52} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    const txn = try eng.beginTxn();
    try eng.commitTxn(txn);

    const txn2 = try eng.beginTxn();
    try eng.abortTxn(txn2);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `addLabel`, `scanLabel`, `putProperty`, `beginTxn`, etc. not declared on `ShardedGraphEngine`.

- [ ] **Step 3: Write minimal implementation — properties**

Add to `src/sharded_engine.zig`:

```zig
pub fn putProperty(self: *ShardedGraphEngine, owner: u64, key: []const u8, val: PropertyValue) anyerror!u64 {
    // Route by owner shard. `owner == 0` is the "create new chain"
    // sentinel — since the facade cannot route a `0`, we round-robin.
    if (owner == 0) {
        const idx = self.coordinator_txn_counter.fetchAdd(1, .monotonic) % SHARD_COUNT;
        return self.shards[idx].putProperty(owner, key, val);
    }
    return self.shards[shard_count_mod.shardOfNode(owner)].putProperty(owner, key, val);
}

pub fn removeProperty(self: *ShardedGraphEngine, owner: u64, key: []const u8) anyerror!void {
    return self.shards[shard_count_mod.shardOfNode(owner)].removeProperty(owner, key);
}

pub fn getAllProperties(self: *ShardedGraphEngine, prop_head: u64) anyerror!@TypeOf(self.shards[0].getAllProperties(prop_head) catch unreachable) {
    return self.shards[shard_count_mod.shardOfNode(prop_head)].getAllProperties(prop_head);
}

pub fn setEdgeProperty(self: *ShardedGraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId, key: []const u8, val: PropertyValue) anyerror!void {
    return self.shards[shard_count_mod.shardOfNode(from)].setEdgeProperty(from, to, edge_id, key, val);
}

pub fn removeEdgeProperty(self: *ShardedGraphEngine, from: NodeId, edge_id: EdgeId, key: []const u8) anyerror!void {
    return self.shards[shard_count_mod.shardOfNode(from)].removeEdgeProperty(from, edge_id, key);
}

pub fn getEdgeProperty(self: *ShardedGraphEngine, from: NodeId, edge_id: EdgeId, key: []const u8, allocator: Allocator) anyerror!?PropertyValue {
    return self.shards[shard_count_mod.shardOfNode(from)].getEdgeProperty(from, edge_id, key, allocator);
}

pub fn getAllEdgeProperties(self: *ShardedGraphEngine, from: NodeId, edge_id: EdgeId) anyerror!@TypeOf(self.shards[0].getAllEdgeProperties(from, edge_id) catch unreachable) {
    return self.shards[shard_count_mod.shardOfNode(from)].getAllEdgeProperties(from, edge_id);
}
```

- [ ] **Step 4: Write minimal implementation — labels (scan fan-out)**

```zig
pub fn addLabel(self: *ShardedGraphEngine, node_id: NodeId, label: LabelId) anyerror!void {
    return self.shards[shard_count_mod.shardOfNode(node_id)].addLabel(node_id, label);
}

pub fn removeLabel(self: *ShardedGraphEngine, node_id: NodeId, label: LabelId) anyerror!void {
    return self.shards[shard_count_mod.shardOfNode(node_id)].removeLabel(node_id, label);
}

pub fn scanLabel(self: *ShardedGraphEngine, label: LabelId, allocator: Allocator) anyerror![]NodeId {
    var out: std.ArrayList(NodeId) = .empty;
    errdefer out.deinit(allocator);
    for (self.shards) |eng| {
        const slice = try eng.scanLabel(label, allocator);
        defer allocator.free(slice);
        try out.appendSlice(allocator, slice);
    }
    return out.toOwnedSlice(allocator);
}

pub fn getOrAssignLabel(self: *ShardedGraphEngine, label_name: []const u8) !LabelId {
    // Label dictionary is global across shards in this plan — we
    // assign on shard 0 and broadcast the mapping to every shard so
    // each shard's `label_dict.get` agrees on the id.
    const id = try self.shards[0].getOrAssignLabel(label_name);
    for (self.shards[1..]) |eng| {
        _ = try eng.getOrAssignLabel(label_name);
    }
    return id;
}
```

**Note:** `getOrAssignLabel` broadcasting is sequential and only fires when a new label name is registered. Hot-path `addLabel(node, id)` is single-shard. A future optimisation (open question 1) is a facade-owned dictionary, but this simpler form keeps every shard's existing label machinery intact.

- [ ] **Step 5: Write minimal implementation — transactions**

```zig
// Encoded TxnId layout: high 8 bits = shard_index, low 56 bits = local_txn_id.
const TXN_SHARD_SHIFT: u6 = 56;
const TXN_LOCAL_MASK: u64 = (@as(u64, 1) << 56) - 1;

fn encodeTxn(shard: usize, local: TxnId) TxnId {
    return (@as(TxnId, @intCast(shard)) << TXN_SHARD_SHIFT) | (local & TXN_LOCAL_MASK);
}

fn decodeTxn(txn: TxnId) struct { shard: usize, local: TxnId } {
    const shard = @as(usize, @intCast(txn >> TXN_SHARD_SHIFT));
    const local = txn & TXN_LOCAL_MASK;
    return .{ .shard = shard, .local = local };
}

pub fn beginTxn(self: *ShardedGraphEngine) anyerror!TxnId {
    const idx = self.coordinator_txn_counter.fetchAdd(1, .monotonic) % SHARD_COUNT;
    const local = try self.shards[idx].beginTxn();
    return encodeTxn(idx, local);
}

pub fn commitTxn(self: *ShardedGraphEngine, txn: TxnId) anyerror!void {
    const d = decodeTxn(txn);
    return self.shards[d.shard].commitTxn(d.local);
}

pub fn abortTxn(self: *ShardedGraphEngine, txn: TxnId) anyerror!void {
    const d = decodeTxn(txn);
    return self.shards[d.shard].abortTxn(d.local);
}
```

- [ ] **Step 6: Write minimal implementation — checkpoint and metrics**

```zig
pub fn checkpoint(self: *ShardedGraphEngine) anyerror!void {
    var first_err: ?anyerror = null;
    for (self.shards) |eng| {
        eng.checkpoint() catch |err| {
            if (first_err == null) first_err = err;
        };
    }
    if (first_err) |err| return err;
}

/// Aggregated metrics snapshot. Sums counters across shards and
/// returns a pointer to an internal buffer refreshed on each call.
/// Valid until the next `getMetrics` call.
pub fn getMetrics(self: *ShardedGraphEngine) *const Metrics {
    self.aggregated_metrics = .{};
    inline for (std.meta.fields(Metrics)) |field| {
        if (@typeInfo(field.type) == .int) {
            var sum: field.type = 0;
            for (self.shards) |eng| {
                sum += @field(eng.getMetrics(), field.name);
            }
            @field(self.aggregated_metrics, field.name) = sum;
        }
    }
    return &self.aggregated_metrics;
}
```

And add a field:

```zig
aggregated_metrics: Metrics = .{},
```

to the `ShardedGraphEngine` struct (top of the struct).

- [ ] **Step 7: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — three new tests (label round-trip, property round-trip, txn round-trip) green; all previous tests still green.

- [ ] **Step 8: Commit**

```bash
git add src/sharded_engine.zig src/sharded_engine_test.zig
git commit -m "feat(sharded): properties, labels, transactions, checkpoint, metrics"
```

---

## Task 10: GraphStorage vtable binding

**Scope:** Expose `ShardedGraphEngine.storage()` returning a `GraphStorage` backed by the facade so external consumers (geode) use the sharded engine through the existing vtable with zero API changes.

**Files:**

- Modify: `src/sharded_engine.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/sharded_engine_test.zig`:

```zig
test "ShardedGraphEngine.storage() exposes GraphStorage vtable" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x60} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    const gs = eng.storage();
    const n = try gs.allocNode();
    try gs.putNode(n, test_support.emptyNode(1));
    try gs.addLabel(n, 42);
    const nodes = try gs.scanLabel(42, testing.allocator);
    defer testing.allocator.free(nodes);
    try testing.expectEqual(@as(usize, 1), nodes.len);
    try testing.expectEqual(n, nodes[0]);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `storage()` not declared on `ShardedGraphEngine`.

- [ ] **Step 3: Write minimal implementation**

Add to `src/sharded_engine.zig`:

```zig
pub fn storage(self: *ShardedGraphEngine) GraphStorage {
    return GraphStorage.init(ShardedGraphEngine, self);
}

/// scanLabelIter — delegate to fan-out implementation (see Task 11).
pub fn scanLabelIter(self: *ShardedGraphEngine, label: LabelId, allocator: Allocator) anyerror!interface_mod.NodeIterator {
    // Temporary: materialise and slice-wrap. Task 11 replaces this
    // with a streaming FanOutNodeIterator that avoids full materialisation.
    const slice = try self.scanLabel(label, allocator);
    return sliceToNodeIterator(slice, allocator);
}

fn sliceToNodeIterator(slice: []NodeId, allocator: Allocator) anyerror!interface_mod.NodeIterator {
    const State = struct {
        entries: []NodeId,
        index: usize,
        alloc: Allocator,
        fn next(vp: *anyopaque) anyerror!?NodeId {
            const s: *@This() = @ptrCast(@alignCast(vp));
            if (s.index >= s.entries.len) return null;
            const e = s.entries[s.index];
            s.index += 1;
            return e;
        }
        fn deinit(vp: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(vp));
            s.alloc.free(s.entries);
            s.alloc.destroy(s);
        }
    };
    const st = try allocator.create(State);
    st.* = .{ .entries = slice, .index = 0, .alloc = allocator };
    return interface_mod.NodeIterator{
        .ptr = @ptrCast(st),
        .vtable = &.{ .next = State.next, .deinit = State.deinit },
    };
}
```

The `GraphStorage.init(T, *T)` machinery uses `@hasDecl(T, "expandOutIter")` to pick the iterator-returning form; we already have `expandOutIter`/`expandInIter` declared, so vtable binding is automatic.

**Important:** `GraphStorage.VTable` requires `expandOut` and `expandIn` member functions on `T`. The current `GraphEngine` satisfies these (lines 636 and 647 of `engine.zig`). Add these on `ShardedGraphEngine` too — they simply drain the iterator returned by `expandOutIter`/`expandInIter`:

```zig
pub fn expandOut(self: *ShardedGraphEngine, id: NodeId, rel_type: ?u32, allocator: Allocator) anyerror![]EdgeEntry {
    var iter = try self.expandOutIter(id, rel_type);
    defer iter.deinit();
    var list: std.ArrayList(EdgeEntry) = .empty;
    errdefer list.deinit(allocator);
    while (try iter.next()) |entry| try list.append(allocator, entry);
    return list.toOwnedSlice(allocator);
}

pub fn expandIn(self: *ShardedGraphEngine, id: NodeId, rel_type: ?u32, allocator: Allocator) anyerror![]EdgeEntry {
    var iter = try self.expandInIter(id, rel_type);
    defer iter.deinit();
    var list: std.ArrayList(EdgeEntry) = .empty;
    errdefer list.deinit(allocator);
    while (try iter.next()) |entry| try list.append(allocator, entry);
    return list.toOwnedSlice(allocator);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — `storage()` test green.

- [ ] **Step 5: Commit**

```bash
git add src/sharded_engine.zig src/sharded_engine_test.zig
git commit -m "feat(sharded): GraphStorage vtable binding via storage()"
```

---

## Task 11: Fan-out node iterator

**Scope:** Replace the materialising `scanLabelIter` from Task 10 with a streaming iterator that advances across shards without pre-allocating the full result slice. This preserves memory bounds for large-cardinality labels.

**Files:**

- Modify: `src/sharded_engine.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/sharded_engine_test.zig`:

```zig
test "FanOutNodeIterator streams nodes from every shard in order" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x61} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    // 20 nodes, all labelled 99 — spread across shards.
    var created: [20]NodeId = undefined;
    for (&created) |*slot| {
        const n = try eng.allocNode();
        try eng.putNode(n, test_support.emptyNode(1));
        try eng.addLabel(n, 99);
        slot.* = n;
    }

    var it = try eng.scanLabelIter(99, testing.allocator);
    defer it.deinit();

    var count: usize = 0;
    while (try it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 20), count);
}
```

- [ ] **Step 2: Run test to verify it fails (after removing the Task 10 materialising impl)**

Run: `zig build test`
Expected: Test passes today (Task 10's impl works). We'll fail a *stricter* variant by adding a memory-bound assertion — skip this step and just replace the impl with a streaming version; measure memory via the test allocator.

Actually: the simpler failing test is one that exercises a *huge* label set and requires the iterator to not materialise. We instead strengthen the correctness test to exercise all 16 shards via a deterministic id spread:

```zig
test "FanOutNodeIterator touches every shard that has matching nodes" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x62} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    // Add a labelled node to each shard explicitly.
    var shard_nodes: [shard_count_mod.SHARD_COUNT]NodeId = undefined;
    for (0..shard_count_mod.SHARD_COUNT) |s| {
        const n = try eng.shards[s].allocNode();
        try eng.putNode(n, test_support.emptyNode(1));
        try eng.addLabel(n, 7);
        shard_nodes[s] = n;
    }

    var it = try eng.scanLabelIter(7, testing.allocator);
    defer it.deinit();

    var seen = std.AutoHashMap(NodeId, void).init(testing.allocator);
    defer seen.deinit();
    while (try it.next()) |nid| try seen.put(nid, {});

    try testing.expectEqual(@as(usize, shard_count_mod.SHARD_COUNT), seen.count());
    for (shard_nodes) |n| try testing.expect(seen.contains(n));
}
```

- [ ] **Step 3: Write minimal implementation — streaming FanOutNodeIterator**

Replace the materialising `scanLabelIter` in `src/sharded_engine.zig` with:

```zig
const label_index_mod = @import("label_index.zig");

pub const FanOutNodeIterator = struct {
    owner: *ShardedGraphEngine,
    label: LabelId,
    allocator: Allocator,
    shard_idx: usize,
    current: ?label_index_mod.LabelIndex.Iterator,

    pub fn next(self: *FanOutNodeIterator) anyerror!?NodeId {
        while (true) {
            if (self.current) |*inner| {
                if (inner.next()) |nid| return nid;
            }
            if (self.shard_idx >= SHARD_COUNT) return null;
            self.current = try self.owner.shards[self.shard_idx].scanLabelIter(self.label);
            self.shard_idx += 1;
        }
    }

    pub fn deinit(self: *FanOutNodeIterator) void {
        // Nothing heap-owned; LabelIndex.Iterator is a lightweight
        // cursor that borrows from the engine's in-memory index.
        _ = self;
    }
};

pub fn scanLabelIter(self: *ShardedGraphEngine, label: LabelId, allocator: Allocator) anyerror!interface_mod.NodeIterator {
    const state = try allocator.create(FanOutNodeIterator);
    state.* = .{
        .owner = self,
        .label = label,
        .allocator = allocator,
        .shard_idx = 0,
        .current = null,
    };
    const Wrapper = struct {
        fn nextFn(vp: *anyopaque) anyerror!?NodeId {
            const s: *FanOutNodeIterator = @ptrCast(@alignCast(vp));
            return s.next();
        }
        fn deinitFn(vp: *anyopaque) void {
            const s: *FanOutNodeIterator = @ptrCast(@alignCast(vp));
            s.deinit();
            s.allocator.destroy(s);
        }
    };
    return interface_mod.NodeIterator{
        .ptr = @ptrCast(state),
        .vtable = &.{ .next = Wrapper.nextFn, .deinit = Wrapper.deinitFn },
    };
}
```

Delete the `sliceToNodeIterator` helper added in Task 10 — it's no longer used.

**Note on `LabelIndex.Iterator` import:** verify in `src/label_index.zig` that the iterator type is public. If it's not, expose it with `pub const Iterator = ...;` there.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — streaming variant yields 16 distinct nodes.

- [ ] **Step 5: Commit**

```bash
git add src/sharded_engine.zig src/sharded_engine_test.zig
git commit -m "feat(sharded): streaming FanOutNodeIterator for scanLabelIter"
```

---

## Task 12: Cross-shard edge create (2PC)

**Scope:** Implement the two-phase protocol from §Architecture / Cross-shard operations.1 — prepare → write source adjacency → write target adjacency → commit. Replaces `error.CrossShardEdgeUnsupported` from Task 8.

**Files:**

- Create: `src/sharded_engine_2pc.zig`
- Modify: `src/sharded_engine.zig` — re-dispatch `addEdge` to the 2PC helper when `s_from != s_to`.

- [ ] **Step 1: Write the failing test**

Append to `src/sharded_engine_test.zig`:

```zig
test "addEdge across shards commits via 2PC and both adjacencies are readable" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x70} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    // Pick ids on two distinct shards deliberately.
    const n_src = try eng.shards[0].allocNode();
    const n_dst = try eng.shards[5].allocNode();
    try eng.putNode(n_src, test_support.emptyNode(1));
    try eng.putNode(n_dst, test_support.emptyNode(1));

    const e = try eng.addEdge(n_src, n_dst, 9);
    try testing.expect(e != 0);

    // Outgoing adjacency on source shard.
    var out_iter = try eng.expandOutIter(n_src, null);
    defer out_iter.deinit();
    var saw_out = false;
    while (try out_iter.next()) |entry| {
        if (entry.edge_id == e) {
            saw_out = true;
            try testing.expectEqual(n_dst, entry.neighbor);
        }
    }
    try testing.expect(saw_out);

    // Incoming adjacency on target shard.
    var in_iter = try eng.expandInIter(n_dst, null);
    defer in_iter.deinit();
    var saw_in = false;
    while (try in_iter.next()) |entry| {
        if (entry.edge_id == e) {
            saw_in = true;
            try testing.expectEqual(n_src, entry.neighbor);
        }
    }
    try testing.expect(saw_in);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `addEdge` between different shards still returns `error.CrossShardEdgeUnsupported`.

- [ ] **Step 3: Write minimal implementation — cross-shard helpers**

Create `src/sharded_engine_2pc.zig`:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Cross-shard edge-create 2PC helpers for ShardedGraphEngine.
//! See docs/superpowers/specs/2026-04-24-sharded-graph-engine-design.md
//! §Cross-shard operations.1 and §WAL and durability.

const std = @import("std");
const engine_mod = @import("engine.zig");
const wal_record_mod = @import("wal_record.zig");
const types = @import("types.zig");

const NodeId = types.NodeId;
const EdgeId = types.EdgeId;
const GraphEngine = engine_mod.GraphEngine;
const WalRecord = wal_record_mod.WalRecord;

/// Payload layout for cross_shard_prepare:
///   global_txn_id: u64  (8 bytes)
///   role: u8            (0 = source, 1 = target)  (1 byte)
///   peer_shard: u16                                 (2 bytes)
///   edge_id: u64                                    (8 bytes)
///   from: u64                                       (8 bytes)
///   to: u64                                         (8 bytes)
///   rel_type: u32                                   (4 bytes)
/// Total: 39 bytes.
pub const PREPARE_PAYLOAD_SIZE: usize = 39;

pub const Role = enum(u8) { source = 0, target = 1 };

pub fn encodePreparePayload(
    buf: *[PREPARE_PAYLOAD_SIZE]u8,
    global_txn_id: u64,
    role: Role,
    peer_shard: u16,
    edge_id: EdgeId,
    from: NodeId,
    to: NodeId,
    rel_type: u32,
) void {
    std.mem.writeInt(u64, buf[0..8], global_txn_id, .little);
    buf[8] = @intFromEnum(role);
    std.mem.writeInt(u16, buf[9..11], peer_shard, .little);
    std.mem.writeInt(u64, buf[11..19], edge_id, .little);
    std.mem.writeInt(u64, buf[19..27], from, .little);
    std.mem.writeInt(u64, buf[27..35], to, .little);
    std.mem.writeInt(u32, buf[35..39], rel_type, .little);
}

pub const PreparePayload = struct {
    global_txn_id: u64,
    role: Role,
    peer_shard: u16,
    edge_id: EdgeId,
    from: NodeId,
    to: NodeId,
    rel_type: u32,
};

pub fn decodePreparePayload(buf: []const u8) !PreparePayload {
    if (buf.len != PREPARE_PAYLOAD_SIZE) return error.InvalidPreparePayload;
    const role_byte = buf[8];
    if (role_byte > 1) return error.InvalidPreparePayload;
    return .{
        .global_txn_id = std.mem.readInt(u64, buf[0..8], .little),
        .role = @enumFromInt(role_byte),
        .peer_shard = std.mem.readInt(u16, buf[9..11], .little),
        .edge_id = std.mem.readInt(u64, buf[11..19], .little),
        .from = std.mem.readInt(u64, buf[19..27], .little),
        .to = std.mem.readInt(u64, buf[27..35], .little),
        .rel_type = std.mem.readInt(u32, buf[35..39], .little),
    };
}

pub fn encodeDecisionPayload(buf: *[8]u8, global_txn_id: u64) void {
    std.mem.writeInt(u64, buf, global_txn_id, .little);
}

pub fn decodeDecisionPayload(buf: []const u8) !u64 {
    if (buf.len != 8) return error.InvalidDecisionPayload;
    return std.mem.readInt(u64, buf[0..8], .little);
}

/// Append a cross_shard_prepare record to the given shard's WAL and
/// fsync. Returns the assigned LSN.
pub fn appendPrepare(eng: *GraphEngine, payload: [PREPARE_PAYLOAD_SIZE]u8, txn_id: u64) !u64 {
    var rec = WalRecord{
        .lsn = 0,
        .txn_id = txn_id,
        .record_type = .cross_shard_prepare,
        .file_id = 0,
        .page_id = 0,
        .payload = &payload,
        .checksum = 0,
    };
    rec.checksum = rec.computeChecksum();
    const lsn = try eng.wal.appendRecord(&rec);
    try eng.wal.sync();
    return lsn;
}

pub fn appendDecision(
    eng: *GraphEngine,
    record_type: wal_record_mod.WalRecordType,
    global_txn_id: u64,
    txn_id: u64,
) !u64 {
    var payload: [8]u8 = undefined;
    encodeDecisionPayload(&payload, global_txn_id);
    var rec = WalRecord{
        .lsn = 0,
        .txn_id = txn_id,
        .record_type = record_type,
        .file_id = 0,
        .page_id = 0,
        .payload = &payload,
        .checksum = 0,
    };
    rec.checksum = rec.computeChecksum();
    const lsn = try eng.wal.appendRecord(&rec);
    try eng.wal.sync();
    return lsn;
}

test {
    std.testing.refAllDecls(@This());
}
```

- [ ] **Step 4: Write minimal implementation — facade hookup**

In `src/sharded_engine.zig`, add a private helper and update `addEdge`:

```zig
const two_pc = @import("sharded_engine_2pc.zig");

fn crossShardAddEdge(
    self: *ShardedGraphEngine,
    from: NodeId,
    to: NodeId,
    rel_type: u32,
    s_from: usize,
    s_to: usize,
) !EdgeId {
    const src = self.shards[s_from];
    const dst = self.shards[s_to];

    // 1. Allocate edge id on source shard (striped → shard_of(id) == s_from).
    const edge_id = src.manifest.next_edge_id;
    src.manifest.next_edge_id += @intCast(SHARD_COUNT);

    const global_txn_id = self.coordinator_txn_counter.fetchAdd(1, .monotonic) + 1;

    // 2. Prepare on source — durable before any data write.
    var src_prepare: [two_pc.PREPARE_PAYLOAD_SIZE]u8 = undefined;
    two_pc.encodePreparePayload(&src_prepare, global_txn_id, .source, @intCast(s_to), edge_id, from, to, rel_type);
    const src_local_txn = try src.beginTxn();
    _ = try two_pc.appendPrepare(src, src_prepare, src_local_txn);

    // 3. Prepare on target.
    var dst_prepare: [two_pc.PREPARE_PAYLOAD_SIZE]u8 = undefined;
    two_pc.encodePreparePayload(&dst_prepare, global_txn_id, .target, @intCast(s_from), edge_id, from, to, rel_type);
    const dst_local_txn = try dst.beginTxn();
    _ = try two_pc.appendPrepare(dst, dst_prepare, dst_local_txn);

    // 4. Write source outgoing adjacency.
    var from_rec = try src.getNode(from) orelse return error.NodeNotFound;
    const out_entry = edge_mod.EdgeEntry{
        .neighbor = to,
        .edge_id = edge_id,
        .rel_type = rel_type,
        .prop_head = 0,
    };
    const new_out_head = try src.adj_out.addEdge(from_rec.out_head, out_entry);
    from_rec.out_head = new_out_head;
    try src.node_store.putNode(from, from_rec);
    try src.edge_index.put(edge_id, .{
        .from = from,
        .neighbor = to,
        .rel_type = rel_type,
        .prop_head = 0,
    });

    // 5. Write target incoming adjacency.
    const in_entry = edge_mod.EdgeEntry{
        .neighbor = from,
        .edge_id = edge_id,
        .rel_type = rel_type,
        .prop_head = 0,
    };
    var to_rec = try dst.getNode(to) orelse return error.NodeNotFound;
    const new_in_head = try dst.adj_in.addEdge(to_rec.in_head, in_entry);
    to_rec.in_head = new_in_head;
    try dst.node_store.putNode(to, to_rec);

    // 6. Commit on both shards — WAL-durable before acknowledging.
    _ = try two_pc.appendDecision(src, .cross_shard_commit, global_txn_id, src_local_txn);
    _ = try two_pc.appendDecision(dst, .cross_shard_commit, global_txn_id, dst_local_txn);

    try src.commitTxn(src_local_txn);
    try dst.commitTxn(dst_local_txn);

    src.manifest.edge_count += 1;
    return edge_id;
}

pub fn addEdge(self: *ShardedGraphEngine, from: NodeId, to: NodeId, rel_type: u32) anyerror!EdgeId {
    const s_from = shard_count_mod.shardOfNode(from);
    const s_to = shard_count_mod.shardOfNode(to);
    if (s_from == s_to) return self.shards[s_from].addEdge(from, to, rel_type);
    return self.crossShardAddEdge(from, to, rel_type, s_from, s_to);
}
```

Also add the missing imports near the top of `sharded_engine.zig`:

```zig
const edge_mod = @import("edge.zig");
```

Remove the stub `error.CrossShardEdgeUnsupported` test from Task 8 (or replace it with: "cross-shard edge now succeeds" — the test in Step 1 of this task already covers the success path).

**Note on access to private GraphEngine internals (`adj_out`, `adj_in`, `node_store`, `edge_index`, `manifest`):** Zig's field access is module-local by default. Since `sharded_engine.zig` imports `engine.zig` and `GraphEngine` fields are declared `pub` indirectly via top-level `struct {}` (they're public by default in Zig), this works. Verify with a quick check — fields without a leading underscore on a pub struct are publicly accessible in Zig. If any become private later, expose a method on `GraphEngine` instead.

- [ ] **Step 5: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — cross-shard edge round-trip works; update the Task 8 cross-shard test to assert success instead of `error.CrossShardEdgeUnsupported` (it's now a legal operation):

Change the body of the "ShardedGraphEngine.addEdge returns CrossShardEdge error" test to assert success:

```zig
test "ShardedGraphEngine.addEdge succeeds across shards via 2PC" {
    // ... same setup ...
    const e = try eng.addEdge(n_src, n_dst, 1);
    try testing.expect(e != 0);
}
```

- [ ] **Step 6: Commit**

```bash
git add src/sharded_engine_2pc.zig src/sharded_engine.zig src/sharded_engine_test.zig
git commit -m "feat(sharded): cross-shard edge create via 2PC prepare/commit"
```

---

## Task 13: Crash recovery reconciliation

**Scope:** After per-shard WAL replay (each shard's existing `Recovery` runs as-is), scan all shards' replayed records for dangling `cross_shard_prepare` records — ones whose matching `cross_shard_commit` or `cross_shard_abort` is missing. Resolve: if ANY shard logged the commit for a given `global_txn_id`, all shards commit (replay the adjacency write); otherwise all abort (undo).

**Files:**

- Create: `src/sharded_recovery.zig`
- Modify: `src/sharded_engine.zig` — call `sharded_recovery.reconcilePendingPrepares(self)` at the end of `open`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_cross_shard_recovery.zig`:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const testing = std.testing;
const graph_storage = @import("graph_storage");
const test_support = graph_storage.test_support;

// SUBSET SCOPE — full permutations land in subsequent commits.
// Step 1 of Task 13 covers "crash after both prepares, before any commit":
// both shards should observe the abort after reopen.

test "recovery: crash after both prepares with no commit → edge not visible after reopen" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x80} ** 16;

    // Phase 1: create a dangling 2PC transaction by hand-forcing the
    // prepare records and crashing before commit. We do this by
    // manually appending prepare records via sharded_engine_2pc.*
    // after opening the engine, then closing without commit records.
    //
    // The facade doesn't expose a "simulate crash" helper, so this
    // test uses a test-only entry point — addEdgeCrashAfterPrepares —
    // defined in src/sharded_engine.zig guarded by `@import("builtin").is_test`.
    {
        var eng = try graph_storage.ShardedGraphEngine.create(
            testing.allocator, td.path, uuid, test_support.testConfig(),
        );
        const n_src = try eng.shards[0].allocNode();
        const n_dst = try eng.shards[5].allocNode();
        try eng.putNode(n_src, test_support.emptyNode(1));
        try eng.putNode(n_dst, test_support.emptyNode(1));
        try eng.addEdgeCrashAfterPrepares(n_src, n_dst, 1);
        // No close — simulate crash by calling deinit (drops buffers
        // without doCheckpoint) and letting WAL replay be the only
        // recovery mechanism.
        eng.deinit();
    }

    // Phase 2: reopen — reconciliation should observe dangling
    // prepares on both shards with no commit record and abort.
    var eng = try graph_storage.ShardedGraphEngine.open(
        testing.allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    // Expect no visible edges between nodes on shards 0 and 5.
    // (We cannot easily address the node ids across instances since
    // they were allocated in the crashed run. Assert instead via
    // edge counts — both shards should show edge_count == 0.)
    try testing.expectEqual(@as(u64, 0), try eng.edgeCount());
}
```

- [ ] **Step 2: Wire the test into build.zig**

Modify `build.zig` after `fuzz_regression_step`:

```zig
const cross_shard_step = b.step("test-cross-shard-recovery", "Run cross-shard 2PC crash recovery tests");
const cross_shard_tests = b.addTest(.{
    .root_module = createModule(b, "tests/test_cross_shard_recovery.zig", target, optimize, &.{
        .{ .name = "graph_storage", .module = graph_storage_mod },
    }),
});
const run_cross_shard = b.addRunArtifact(cross_shard_tests);
cross_shard_step.dependOn(&run_cross_shard.step);
```

Also register `ShardedGraphEngine` in `root.zig` (already done in Task 6) and expose `test_support` in `root.zig` for the test (already done at line 99: `pub const test_support = @import("testing_support.zig");`).

- [ ] **Step 3: Run test to verify it fails**

Run: `zig build test-cross-shard-recovery`
Expected: FAIL — `addEdgeCrashAfterPrepares` and `reconcilePendingPrepares` not implemented.

- [ ] **Step 4: Write minimal implementation — test-only crash helper**

In `src/sharded_engine.zig`, add:

```zig
const builtin = @import("builtin");

/// Test-only hook: issue both prepares for a cross-shard edge but
/// never write the commit or abort record. Simulates a crash between
/// step 3 and step 6 of crossShardAddEdge. Available only in test
/// builds.
pub fn addEdgeCrashAfterPrepares(
    self: *ShardedGraphEngine,
    from: NodeId,
    to: NodeId,
    rel_type: u32,
) !void {
    if (!builtin.is_test) return error.TestOnly;
    const s_from = shard_count_mod.shardOfNode(from);
    const s_to = shard_count_mod.shardOfNode(to);
    if (s_from == s_to) return error.NotCrossShard;

    const src = self.shards[s_from];
    const dst = self.shards[s_to];

    const edge_id = src.manifest.next_edge_id;
    src.manifest.next_edge_id += @intCast(SHARD_COUNT);

    const global_txn_id = self.coordinator_txn_counter.fetchAdd(1, .monotonic) + 1;

    var src_prepare: [two_pc.PREPARE_PAYLOAD_SIZE]u8 = undefined;
    two_pc.encodePreparePayload(&src_prepare, global_txn_id, .source, @intCast(s_to), edge_id, from, to, rel_type);
    const src_local_txn = try src.beginTxn();
    _ = try two_pc.appendPrepare(src, src_prepare, src_local_txn);

    var dst_prepare: [two_pc.PREPARE_PAYLOAD_SIZE]u8 = undefined;
    two_pc.encodePreparePayload(&dst_prepare, global_txn_id, .target, @intCast(s_from), edge_id, from, to, rel_type);
    const dst_local_txn = try dst.beginTxn();
    _ = try two_pc.appendPrepare(dst, dst_prepare, dst_local_txn);

    // Simulated crash: do NOT issue commit, and do NOT call commitTxn
    // on the local shard txns. The on-disk WAL now has two prepares
    // for `global_txn_id` and no decision record.
}
```

- [ ] **Step 5: Write minimal implementation — reconciliation pass**

Create `src/sharded_recovery.zig`:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Second-pass cross-shard recovery reconciliation for
//! ShardedGraphEngine. Each shard's single-threaded Recovery has
//! already replayed its local WAL before this runs, so the engines
//! are in a self-consistent intra-shard state. This pass walks the
//! WAL of every shard to identify cross_shard_prepare records and
//! joins them by global_txn_id with any cross_shard_commit /
//! cross_shard_abort record on any shard. Dangling prepares are
//! resolved per the spec:
//!
//!   - If ANY shard logged a commit for the global_txn_id: replay
//!     the adjacency write on any shard whose prepare is dangling,
//!     then log a commit decision locally.
//!   - Otherwise: log an abort decision on every shard with a
//!     dangling prepare. No data writes needed — prepares never
//!     touched the stores.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sharded_engine = @import("sharded_engine.zig");
const two_pc = @import("sharded_engine_2pc.zig");
const wal_record = @import("wal_record.zig");
const engine_mod = @import("engine.zig");

const WalRecordType = wal_record.WalRecordType;
const ShardedGraphEngine = sharded_engine.ShardedGraphEngine;
const GraphEngine = engine_mod.GraphEngine;

pub const ReconcileStats = struct {
    committed: u32 = 0,
    aborted: u32 = 0,
};

pub fn reconcilePendingPrepares(self: *ShardedGraphEngine) !ReconcileStats {
    const allocator = self.allocator;

    // Pass A: scan every shard WAL, tally (global_txn_id) state.
    // state: 0b01 = prepare seen on some shard, 0b10 = commit seen, 0b100 = abort seen
    var state = std.AutoHashMap(u64, u8).init(allocator);
    defer state.deinit();

    // Per-shard: prepares with no peer decision yet.
    var prepared_here: [sharded_engine.SHARD_COUNT]std.AutoHashMap(u64, two_pc.PreparePayload) = undefined;
    for (&prepared_here) |*m| m.* = std.AutoHashMap(u64, two_pc.PreparePayload).init(allocator);
    defer for (&prepared_here) |*m| m.deinit();

    for (self.shards, 0..) |eng, s| {
        const records = try eng.wal.readFrom(0, allocator);
        defer {
            for (records) |*r| r.deinit(allocator);
            allocator.free(records);
        }
        for (records) |r| {
            switch (r.record_type) {
                .cross_shard_prepare => {
                    const payload = try two_pc.decodePreparePayload(r.payload);
                    try prepared_here[s].put(payload.global_txn_id, payload);
                    const entry = try state.getOrPut(payload.global_txn_id);
                    if (!entry.found_existing) entry.value_ptr.* = 0;
                    entry.value_ptr.* |= 0b001;
                },
                .cross_shard_commit => {
                    const gid = try two_pc.decodeDecisionPayload(r.payload);
                    const entry = try state.getOrPut(gid);
                    if (!entry.found_existing) entry.value_ptr.* = 0;
                    entry.value_ptr.* |= 0b010;
                },
                .cross_shard_abort => {
                    const gid = try two_pc.decodeDecisionPayload(r.payload);
                    const entry = try state.getOrPut(gid);
                    if (!entry.found_existing) entry.value_ptr.* = 0;
                    entry.value_ptr.* |= 0b100;
                },
                else => {},
            }
        }
    }

    // Pass B: for each shard, for each prepare it owns, apply the
    // global decision.
    var stats = ReconcileStats{};
    for (self.shards, 0..) |eng, s| {
        var it = prepared_here[s].iterator();
        while (it.next()) |entry| {
            const gid = entry.key_ptr.*;
            const payload = entry.value_ptr.*;
            const st = state.get(gid) orelse 0;
            const committed = (st & 0b010) != 0;
            const aborted = (st & 0b100) != 0;
            if (committed and !aborted) {
                // Replay adjacency write if missing, then log commit
                // on this shard (idempotent — no-op if already logged).
                try replayAdjacencyIfNeeded(eng, payload, s);
                const local_txn = try eng.beginTxn();
                _ = try two_pc.appendDecision(eng, .cross_shard_commit, gid, local_txn);
                try eng.commitTxn(local_txn);
                stats.committed += 1;
            } else {
                // Abort path — log the abort locally. No data undo
                // needed because the prepare happens *before* any
                // adjacency mutation (see crossShardAddEdge step 4).
                const local_txn = try eng.beginTxn();
                _ = try two_pc.appendDecision(eng, .cross_shard_abort, gid, local_txn);
                try eng.commitTxn(local_txn);
                stats.aborted += 1;
            }
        }
    }
    return stats;
}

fn replayAdjacencyIfNeeded(
    eng: *GraphEngine,
    payload: two_pc.PreparePayload,
    shard_index: usize,
) !void {
    _ = shard_index;
    // Check if the edge already lives in this shard's edge_index (the
    // adjacency was written pre-crash). If yes, no-op.
    if (eng.edge_index.contains(payload.edge_id)) return;

    switch (payload.role) {
        .source => {
            // Write outgoing adjacency.
            var from_rec = try eng.getNode(payload.from) orelse return error.NodeNotFound;
            const adj_store_mod = @import("adj_store.zig");
            _ = adj_store_mod; // only needed for the import
            const out_entry = @import("edge.zig").EdgeEntry{
                .neighbor = payload.to,
                .edge_id = payload.edge_id,
                .rel_type = payload.rel_type,
                .prop_head = 0,
            };
            const new_out_head = try eng.adj_out.addEdge(from_rec.out_head, out_entry);
            from_rec.out_head = new_out_head;
            try eng.node_store.putNode(payload.from, from_rec);
            try eng.edge_index.put(payload.edge_id, .{
                .from = payload.from,
                .neighbor = payload.to,
                .rel_type = payload.rel_type,
                .prop_head = 0,
            });
            eng.manifest.edge_count += 1;
        },
        .target => {
            var to_rec = try eng.getNode(payload.to) orelse return error.NodeNotFound;
            const in_entry = @import("edge.zig").EdgeEntry{
                .neighbor = payload.from,
                .edge_id = payload.edge_id,
                .rel_type = payload.rel_type,
                .prop_head = 0,
            };
            const new_in_head = try eng.adj_in.addEdge(to_rec.in_head, in_entry);
            to_rec.in_head = new_in_head;
            try eng.node_store.putNode(payload.to, to_rec);
        },
    }
}

test {
    std.testing.refAllDecls(@This());
}
```

- [ ] **Step 6: Hook reconciliation into open()**

In `src/sharded_engine.zig` `open`, after the `for (0..SHARD_COUNT)` loop that opens all shards, add:

```zig
const sharded_recovery = @import("sharded_recovery.zig");
_ = try sharded_recovery.reconcilePendingPrepares(self);
```

- [ ] **Step 7: Run test to verify it passes**

Run: `zig build test-cross-shard-recovery`
Expected: PASS — dangling-prepare abort case green. No edges visible after reopen.

- [ ] **Step 8: Add the commit-survives case**

Append to `tests/test_cross_shard_recovery.zig`:

```zig
test "recovery: crash after source commit, before target commit → edge is visible after reopen" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x81} ** 16;

    var n_src_saved: u64 = 0;
    var n_dst_saved: u64 = 0;
    var edge_saved: u64 = 0;
    {
        var eng = try graph_storage.ShardedGraphEngine.create(
            testing.allocator, td.path, uuid, test_support.testConfig(),
        );
        n_src_saved = try eng.shards[0].allocNode();
        n_dst_saved = try eng.shards[5].allocNode();
        try eng.putNode(n_src_saved, test_support.emptyNode(1));
        try eng.putNode(n_dst_saved, test_support.emptyNode(1));
        edge_saved = try eng.addEdgeCrashAfterSourceCommit(n_src_saved, n_dst_saved, 1);
        eng.deinit();
    }

    var eng = try graph_storage.ShardedGraphEngine.open(
        testing.allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    const got = try eng.getEdge(edge_saved);
    try testing.expect(got != null);
    try testing.expectEqual(n_dst_saved, got.?.neighbor);
}
```

Add `addEdgeCrashAfterSourceCommit` to `src/sharded_engine.zig` — same shape as `addEdgeCrashAfterPrepares` but runs through step 5 (dst adjacency write) and logs the source-side commit, then crashes before dst commit:

```zig
pub fn addEdgeCrashAfterSourceCommit(
    self: *ShardedGraphEngine,
    from: NodeId,
    to: NodeId,
    rel_type: u32,
) !EdgeId {
    if (!builtin.is_test) return error.TestOnly;
    const s_from = shard_count_mod.shardOfNode(from);
    const s_to = shard_count_mod.shardOfNode(to);
    if (s_from == s_to) return error.NotCrossShard;
    const src = self.shards[s_from];
    const dst = self.shards[s_to];

    const edge_id = src.manifest.next_edge_id;
    src.manifest.next_edge_id += @intCast(SHARD_COUNT);

    const global_txn_id = self.coordinator_txn_counter.fetchAdd(1, .monotonic) + 1;

    var src_prepare: [two_pc.PREPARE_PAYLOAD_SIZE]u8 = undefined;
    two_pc.encodePreparePayload(&src_prepare, global_txn_id, .source, @intCast(s_to), edge_id, from, to, rel_type);
    const src_local_txn = try src.beginTxn();
    _ = try two_pc.appendPrepare(src, src_prepare, src_local_txn);

    var dst_prepare: [two_pc.PREPARE_PAYLOAD_SIZE]u8 = undefined;
    two_pc.encodePreparePayload(&dst_prepare, global_txn_id, .target, @intCast(s_from), edge_id, from, to, rel_type);
    const dst_local_txn = try dst.beginTxn();
    _ = try two_pc.appendPrepare(dst, dst_prepare, dst_local_txn);

    // Source-side adjacency write + commit.
    var from_rec = try src.getNode(from) orelse return error.NodeNotFound;
    const out_entry = edge_mod.EdgeEntry{
        .neighbor = to,
        .edge_id = edge_id,
        .rel_type = rel_type,
        .prop_head = 0,
    };
    const new_out_head = try src.adj_out.addEdge(from_rec.out_head, out_entry);
    from_rec.out_head = new_out_head;
    try src.node_store.putNode(from, from_rec);
    try src.edge_index.put(edge_id, .{
        .from = from,
        .neighbor = to,
        .rel_type = rel_type,
        .prop_head = 0,
    });
    src.manifest.edge_count += 1;

    _ = try two_pc.appendDecision(src, .cross_shard_commit, global_txn_id, src_local_txn);
    try src.commitTxn(src_local_txn);

    // Simulated crash *before* dst adjacency write and decision.
    _ = dst_local_txn;
    return edge_id;
}
```

- [ ] **Step 9: Run test to verify both cases pass**

Run: `zig build test-cross-shard-recovery`
Expected: PASS — both tests green. Reconciliation replays the target adjacency via `replayAdjacencyIfNeeded` and logs the target commit.

- [ ] **Step 10: Commit**

```bash
git add src/sharded_recovery.zig src/sharded_engine.zig tests/test_cross_shard_recovery.zig build.zig
git commit -m "feat(sharded): crash recovery reconciliation for 2PC dangling prepares"
```

---

## Task 14: Per-shard WAL durability barrier on cross-shard commit

**Rationale:** The spec §WAL and durability says "for a 2PC commit, both shards must have the commit record durable before the caller sees success." `appendPrepare` and `appendDecision` in Task 12 already call `eng.wal.sync()` after each append, so every prepare and decision is durable on disk before control returns. This task is a **verification-only task** — no new code — to confirm the invariant holds and to assert it with a test.

**Files:**

- Modify: `src/sharded_engine_test.zig`

- [ ] **Step 1: Write the failing test**

Append:

```zig
test "cross-shard commit blocks until both shards' WAL commit records are durable" {
    // We can't directly observe fsync timing, but we can assert that
    // after addEdge returns, both shards' wal.currentLsn() has
    // advanced past the commit record. Specifically, reading back the
    // last records from WAL must show cross_shard_commit at the tail.
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0x90} ** 16;
    const eng = try sharded_engine_mod.ShardedGraphEngine.create(
        testing.allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    const n_src = try eng.shards[0].allocNode();
    const n_dst = try eng.shards[7].allocNode();
    try eng.putNode(n_src, test_support.emptyNode(1));
    try eng.putNode(n_dst, test_support.emptyNode(1));

    const wal_record_mod = @import("wal_record.zig");
    _ = try eng.addEdge(n_src, n_dst, 1);

    for ([_]usize{ 0, 7 }) |s| {
        const records = try eng.shards[s].wal.readFrom(0, testing.allocator);
        defer {
            for (records) |*r| r.deinit(testing.allocator);
            testing.allocator.free(records);
        }
        // Find at least one cross_shard_commit record.
        var found = false;
        for (records) |r| {
            if (r.record_type == wal_record_mod.WalRecordType.cross_shard_commit) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}
```

- [ ] **Step 2: Run test**

Run: `zig build test`
Expected: PASS immediately — the durability call in Task 12's `appendDecision` already satisfies the contract.

- [ ] **Step 3: Commit**

```bash
git add src/sharded_engine_test.zig
git commit -m "test(sharded): assert cross-shard commit records are WAL-durable post-addEdge"
```

---

## Task 15: Integration tests — full-engine exercise

**Files:**

- Create: `tests/integration_sharded.zig`
- Modify: `build.zig` — add `test-integration-sharded` step.

- [ ] **Step 1: Write the failing test**

```zig
// tests/integration_sharded.zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const testing = std.testing;
const graph_storage = @import("graph_storage");
const test_support = graph_storage.test_support;

const ShardedGraphEngine = graph_storage.ShardedGraphEngine;
const NodeRec = graph_storage.node.NodeRec;

test "full CRUD + cross-shard edges + reopen" {
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xC1} ** 16;

    {
        var eng = try ShardedGraphEngine.create(
            testing.allocator, td.path, uuid, test_support.testConfig(),
        );

        // 100 nodes, all labelled.
        var ids: [100]u64 = undefined;
        for (&ids) |*slot| {
            const n = try eng.allocNode();
            try eng.putNode(n, test_support.emptyNode(1));
            try eng.addLabel(n, 1);
            slot.* = n;
        }

        // Fully-connected pairs: 100 edges spread across shard pairs.
        for (0..50) |i| {
            _ = try eng.addEdge(ids[i], ids[i + 50], 1);
        }

        try testing.expectEqual(@as(u64, 100), try eng.nodeCount());
        try testing.expectEqual(@as(u64, 50), try eng.edgeCount());

        try eng.checkpoint();
        try eng.close();
    }

    // Reopen — state must be intact.
    var eng = try ShardedGraphEngine.open(
        testing.allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    try testing.expectEqual(@as(u64, 100), try eng.nodeCount());
    try testing.expectEqual(@as(u64, 50), try eng.edgeCount());

    const label_nodes = try eng.scanLabel(1, testing.allocator);
    defer testing.allocator.free(label_nodes);
    try testing.expectEqual(@as(usize, 100), label_nodes.len);
}

test "concurrent writers across shards make forward progress (smoke)" {
    // Minimal smoke test: spawn 4 threads, each writing to distinct
    // shards via ShardedGraphEngine.shards[thread_idx].allocNode. Not a
    // throughput benchmark — see benchmarks/sharded_throughput.zig —
    // just proves concurrent writers to different shards don't
    // deadlock or corrupt state.
    var td = try test_support.TestDataDir.init(testing.allocator);
    defer td.deinit();
    const uuid = [_]u8{0xC2} ** 16;
    var eng = try ShardedGraphEngine.create(
        testing.allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    const Worker = struct {
        engine: *ShardedGraphEngine,
        shard_idx: usize,
        n: usize,

        fn run(ctx: *@This()) void {
            var i: usize = 0;
            while (i < ctx.n) : (i += 1) {
                const id = ctx.engine.shards[ctx.shard_idx].allocNode() catch return;
                ctx.engine.shards[ctx.shard_idx].putNode(id, test_support.emptyNode(1)) catch return;
            }
        }
    };

    var workers: [4]Worker = undefined;
    for (&workers, 0..) |*w, i| w.* = .{ .engine = eng, .shard_idx = i, .n = 100 };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Worker.run, .{&workers[i]});
    for (threads) |t| t.join();

    try testing.expectEqual(@as(u64, 400), try eng.nodeCount());
}
```

- [ ] **Step 2: Wire into build.zig**

In `build.zig`, after `cross_shard_step`:

```zig
const integration_sharded_step = b.step("test-integration-sharded", "Run sharded-engine integration tests");
const integration_sharded_tests = b.addTest(.{
    .root_module = createModule(b, "tests/integration_sharded.zig", target, optimize, &.{
        .{ .name = "graph_storage", .module = graph_storage_mod },
    }),
});
const run_integration_sharded = b.addRunArtifact(integration_sharded_tests);
integration_sharded_step.dependOn(&run_integration_sharded.step);
```

- [ ] **Step 3: Run tests to verify they fail / pass per expectation**

Run: `zig build test-integration-sharded`
Expected: PASS — all three scenarios green.

- [ ] **Step 4: Commit**

```bash
git add tests/integration_sharded.zig build.zig
git commit -m "test(sharded): integration — CRUD, cross-shard, reopen, concurrent writers"
```

---

## Task 16: Microbench — ≥ 4× single-engine throughput target

**Files:**

- Create: `benchmarks/sharded_throughput.zig`
- Modify: `build.zig` — add `bench-sharded-throughput` step.

- [ ] **Step 1: Write the benchmark source**

```zig
// benchmarks/sharded_throughput.zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Measures ShardedGraphEngine N-way writer throughput vs single
//! GraphEngine. Spec §Measurement: sharded engine at ≥ 4× single-
//! engine throughput on 16 cores.
//!
//! Workload: each of W worker threads issues `N_OPS / W` cycles of
//! (allocNode → putNode → addEdge-to-previous) against its own shard.
//! Result lines are machine-readable:
//!
//!   SHARDED_THROUGHPUT workers=W ops=OPS elapsed_ns=... ops_per_s=...
//!   SINGLE_THROUGHPUT  workers=1 ops=OPS elapsed_ns=... ops_per_s=...

const std = @import("std");
const graph_storage = @import("graph_storage");
const test_support = graph_storage.test_support;

const N_OPS: usize = 20_000;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Run 1: ShardedGraphEngine with 16 writers.
    const sharded_elapsed = try benchSharded(allocator);
    std.debug.print(
        "SHARDED_THROUGHPUT workers={d} ops={d} elapsed_ns={d} ops_per_s={d}\n",
        .{ 16, N_OPS, sharded_elapsed, @divTrunc(N_OPS * std.time.ns_per_s, sharded_elapsed) },
    );

    // Run 2: single GraphEngine with 1 writer (baseline).
    const single_elapsed = try benchSingle(allocator);
    std.debug.print(
        "SINGLE_THROUGHPUT workers={d} ops={d} elapsed_ns={d} ops_per_s={d}\n",
        .{ 1, N_OPS, single_elapsed, @divTrunc(N_OPS * std.time.ns_per_s, single_elapsed) },
    );

    const ratio = @as(f64, @floatFromInt(single_elapsed)) / @as(f64, @floatFromInt(sharded_elapsed));
    std.debug.print("SHARDING_SPEEDUP ratio={d:.2}\n", .{ratio});
}

fn benchSharded(allocator: std.mem.Allocator) !u64 {
    var td = try test_support.TestDataDir.init(allocator);
    defer td.deinit();
    const uuid = [_]u8{0xBE} ** 16;
    var eng = try graph_storage.ShardedGraphEngine.create(
        allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    const n_workers: usize = 16;
    const per_worker: usize = N_OPS / n_workers;

    const Worker = struct {
        engine: *graph_storage.ShardedGraphEngine,
        shard_idx: usize,
        n: usize,
        prev_node: u64 = 0,

        fn run(ctx: *@This()) void {
            var i: usize = 0;
            while (i < ctx.n) : (i += 1) {
                const id = ctx.engine.shards[ctx.shard_idx].allocNode() catch return;
                ctx.engine.shards[ctx.shard_idx].putNode(id, test_support.emptyNode(1)) catch return;
                if (ctx.prev_node != 0) {
                    _ = ctx.engine.shards[ctx.shard_idx].addEdge(ctx.prev_node, id, 1) catch {};
                }
                ctx.prev_node = id;
            }
        }
    };

    var workers: [16]Worker = undefined;
    for (&workers, 0..) |*w, i| w.* = .{ .engine = eng, .shard_idx = i, .n = per_worker };

    var start_ns = std.time.nanoTimestamp();
    var threads: [16]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Worker.run, .{&workers[i]});
    for (threads) |t| t.join();
    var end_ns = std.time.nanoTimestamp();

    return @intCast(end_ns - start_ns);
}

fn benchSingle(allocator: std.mem.Allocator) !u64 {
    var td = try test_support.TestDataDir.init(allocator);
    defer td.deinit();
    const uuid = [_]u8{0xBF} ** 16;
    var eng = try graph_storage.GraphEngine.create(
        allocator, td.path, uuid, test_support.testConfig(),
    );
    defer eng.close() catch {};

    var prev: u64 = 0;
    const start_ns = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < N_OPS) : (i += 1) {
        const id = try eng.allocNode();
        try eng.putNode(id, test_support.emptyNode(1));
        if (prev != 0) _ = try eng.addEdge(prev, id, 1);
        prev = id;
    }
    const end_ns = std.time.nanoTimestamp();
    return @intCast(end_ns - start_ns);
}
```

- [ ] **Step 2: Wire into build.zig**

```zig
// In addBenchmarks, after `sharded_bench_step`:
const sharded_throughput_step = b.step("bench-sharded-throughput", "ShardedGraphEngine vs single-engine throughput");
const sharded_throughput_exe = b.addExecutable(.{
    .name = "sharded-throughput-bench",
    .root_module = createModule(b, "benchmarks/sharded_throughput.zig", target, bench_optimize, &.{
        .{ .name = "graph_storage", .module = graph_storage_mod },
    }),
});
const run_sharded_throughput = b.addRunArtifact(sharded_throughput_exe);
sharded_throughput_step.dependOn(&run_sharded_throughput.step);
```

- [ ] **Step 3: Build and run the benchmark**

Run: `zig build bench-sharded-throughput`
Expected: Output lines like:

```text
SHARDED_THROUGHPUT workers=16 ops=20000 elapsed_ns=... ops_per_s=...
SINGLE_THROUGHPUT  workers=1 ops=20000 elapsed_ns=... ops_per_s=...
SHARDING_SPEEDUP ratio=4.XX
```

with `ratio >= 4.0` on a 16-core host. If the ratio is below 4, investigate per §Risks: check shard size skew via `eng.shards[i].nodeCount()` and confirm `shardIndex` distribution is uniform. **Do not** lower the 4× bar; that is the spec's success criterion.

- [ ] **Step 4: Commit**

```bash
git add benchmarks/sharded_throughput.zig build.zig
git commit -m "bench: sharded-vs-single throughput microbench (target ≥4× on 16 cores)"
```

---

## Task 17: CHANGELOG + README pointer

**Files:**

- Modify: `CHANGELOG.md`
- Modify: `README.md` (brief section linking to the design spec and this plan)

- [ ] **Step 1: Update CHANGELOG**

In `CHANGELOG.md`, add a new unreleased entry at the top describing the sharded engine, citing the design spec path, and warning that on-disk layout is incompatible with pre-sharded data (MEMORY.md §"No migration path needed" applies — users nuke data dirs on upgrade).

```markdown
## [Unreleased] — Sharded Graph Engine

### Added
- `ShardedGraphEngine` facade owning N=16 independent per-shard
  `GraphEngine` instances per logical graph. Enables N-way writer
  concurrency per graph while preserving each engine's single-threaded
  correctness argument.
- Top-level `<graph_uuid>/shard_manifest.json` records shard-count,
  routing-algorithm fingerprint, and per-shard UUIDs.
- WAL record types `cross_shard_prepare`, `cross_shard_commit`,
  `cross_shard_abort` — support for cross-shard edge-create 2PC.
- Striped id allocation (`GraphConfig.base_shard_index`) so
  `shardOfNode(id) == shard_index` for every allocated id.
- `zig build bench-sharded-throughput` microbench (target ≥4× on 16
  cores).

### Breaking
- On-disk layout for sharded graphs is incompatible with the
  pre-sharded single-engine layout. Upgrade requires wiping the data
  directory; see `docs/superpowers/specs/2026-04-24-sharded-graph-engine-design.md`.
```

- [ ] **Step 2: Update README**

In `README.md`, add a section linking to the design spec and implementation plan under an "Architecture" heading, next to any existing pointers to `docs/architecture.md`.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md README.md
git commit -m "docs: changelog + readme pointer for ShardedGraphEngine"
```

---

## Task 18: Final verification gate

- [ ] **Step 1: Run every test step end-to-end**

```bash
zig build test
zig build test-integration
zig build test-integration-sharded
zig build test-cross-shard-recovery
zig build test-fuzz-regression
```

All steps must exit 0.

- [ ] **Step 2: Run the benchmark and record the ratio**

```bash
zig build bench-sharded-throughput
```

Paste the three `SHARDED_THROUGHPUT` / `SINGLE_THROUGHPUT` / `SHARDING_SPEEDUP` lines into the commit message below. If `ratio < 4.0`, stop and investigate — do not ship without hitting the spec's bar.

- [ ] **Step 3: Verify re-exports**

Read `src/root.zig` and confirm these lines exist:

```zig
pub const shard_count = @import("shard_count.zig");
pub const shard_uuid = @import("shard_uuid.zig");
pub const shard_manifest = @import("shard_manifest.zig");
pub const sharded_engine = @import("sharded_engine.zig");
pub const ShardedGraphEngine = sharded_engine.ShardedGraphEngine;
```

- [ ] **Step 4: Final commit (no code change, just a verification tag)**

If everything is green, create a final no-op commit recording the bench ratio:

```bash
git commit --allow-empty -m "chore(sharded): verify gate — all tests pass, bench ratio=<PASTED>"
```

---

## Open items deferred to a follow-up spec

The design spec's Open Questions section captures three items:

1. **Label dictionary per-shard vs global.** This plan implements the simple form: every shard has its own `LabelDictionary`, and `getOrAssignLabel` broadcasts to all shards so the global `LabelId -> name` mapping agrees. Upgrading to a facade-owned single dict is a non-breaking optimisation covered in a follow-up spec.
2. **Txn id for cross-shard.** This plan uses an atomic global counter (`coordinator_txn_counter`). Lamport tuples are a later optimisation.
3. **Checkpoint coordination.** This plan uses per-shard checkpoints inside `ShardedGraphEngine.checkpoint()`, which fans out and awaits all N. A logical "graph checkpoint" that quiesces all shards briefly is a follow-up.

None of these block the success criteria in the spec (N-way writer concurrency + crash-recovery correctness).
