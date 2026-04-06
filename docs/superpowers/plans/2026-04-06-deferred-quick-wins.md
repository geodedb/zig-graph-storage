# Deferred Quick Wins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close 3 small deferred items: index catalog integrity (SEC-0021), multi-op transactions (GAP-0022), and edge-ID index (GAP-0021).

**Architecture:** Each task is independent — no cross-dependencies. All 3 can be implemented and committed separately. The index catalog follows existing magic+CRC patterns from manifest.zig and registry.zig. Multi-op transactions extend the existing TxnManager. Edge-ID index adds a simple HashMap lookup.

**Tech Stack:** Zig 0.15.x, std.hash.crc.Crc32Iscsi, std.AutoHashMap

---

## File Structure

| Task | Files Created | Files Modified |
|------|--------------|----------------|
| Index Catalog Integrity | — | `src/index_catalog.zig` |
| Multi-Op Transactions | — | `src/engine.zig`, `src/txn.zig` |
| Edge-ID Index | — | `src/engine.zig`, `src/adj_store.zig` |

---

### Task 1: Index Catalog Integrity (SEC-0021)

**Files:**
- Modify: `src/index_catalog.zig`
- Test: inline tests in `src/index_catalog.zig`

- [ ] **Step 1: Write failing test for magic + CRC validation**

Add after existing tests in `src/index_catalog.zig`:

```zig
test "SEC-0021: loadFromFile rejects corrupted catalog" {
    const allocator = testing.allocator;
    var catalog = IndexCatalog.init(allocator);
    defer catalog.deinit();

    // Write a valid catalog first.
    try catalog.addIndex(allocator, 1, "name", .btree_property);
    const path = "test_io/catalog_integrity_test.bin";
    try catalog.saveToFile(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    // Corrupt the file by flipping a byte.
    {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        defer file.close();
        const stat = try file.stat();
        try file.seekTo(stat.size / 2);
        try file.writeAll(&[_]u8{0xFF});
    }

    // Load should fail with integrity error.
    var catalog2 = IndexCatalog.init(allocator);
    defer catalog2.deinit();
    try testing.expectError(error.IntegrityCheckFailed, catalog2.loadFromFile(path));
}

test "SEC-0021: loadFromFile rejects wrong magic" {
    const allocator = testing.allocator;
    const path = "test_io/catalog_bad_magic.bin";

    // Write garbage.
    {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll("NOTMAGIC" ++ &[_]u8{0} ** 20);
    }
    defer std.fs.cwd().deleteFile(path) catch {};

    var catalog = IndexCatalog.init(allocator);
    defer catalog.deinit();
    try testing.expectError(error.InvalidMagic, catalog.loadFromFile(path));
}
```

- [ ] **Step 2: Run tests — they should fail**

Run: `zig build test --summary all 2>&1 | tail -5`
Expected: FAIL (IntegrityCheckFailed and InvalidMagic not defined)

- [ ] **Step 3: Add magic constant and version**

At the top of `index_catalog.zig`, after the imports:

```zig
const Crc32 = std.hash.crc.Crc32Iscsi;

pub const CATALOG_MAGIC: [8]u8 = .{ 'G', 'E', 'O', 'C', 'A', 'T', '0', '1' };
pub const CATALOG_VERSION: u32 = 1;
```

- [ ] **Step 4: Update saveToFile to prepend magic+version and append CRC**

Replace the `saveToFile` function body. The new format is:
`[magic 8B] [version 4B] [count 4B] [entries...] [CRC32 4B]`

```zig
pub fn saveToFile(self: *const IndexCatalog, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{ .mode = owner_only_file_mode });
    defer file.close();

    var data: std.ArrayList(u8) = .{};
    defer data.deinit(self.allocator);

    // Magic.
    try data.appendSlice(self.allocator, &CATALOG_MAGIC);

    // Version.
    {
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp, CATALOG_VERSION, .little);
        try data.appendSlice(self.allocator, &tmp);
    }

    // Entry count.
    const entry_count: u32 = @intCast(self.indexes.items.len);
    {
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp, entry_count, .little);
        try data.appendSlice(self.allocator, &tmp);
    }

    // Entries.
    for (self.indexes.items) |entry| {
        {
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, entry.label_id, .little);
            try data.appendSlice(self.allocator, &tmp);
        }
        try data.append(self.allocator, @intFromEnum(entry.index_type));
        try data.append(self.allocator, @intFromEnum(entry.state));
        {
            const key_len: u16 = @intCast(entry.property_key.len);
            var tmp: [2]u8 = undefined;
            std.mem.writeInt(u16, &tmp, key_len, .little);
            try data.appendSlice(self.allocator, &tmp);
        }
        try data.appendSlice(self.allocator, entry.property_key);
    }

    // CRC32 over everything (magic + version + count + entries).
    var crc_buf: [4]u8 = undefined;
    const crc = Crc32.hash(data.items);
    std.mem.writeInt(u32, &crc_buf, crc, .little);
    try data.appendSlice(self.allocator, &crc_buf);

    try file.writeAll(data.items);
}
```

- [ ] **Step 5: Update loadFromFile to validate magic + CRC**

Replace the `loadFromFile` function body:

```zig
pub fn loadFromFile(self: *IndexCatalog, path: []const u8) !void {
    // Clear existing.
    for (self.owned_keys.items) |key| {
        self.allocator.free(key);
    }
    self.owned_keys.clearRetainingCapacity();
    self.indexes.clearRetainingCapacity();

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.size < 8 + 4 + 4 + 4) return error.InvalidData; // magic + version + count + crc minimum
    const content = try self.allocator.alloc(u8, stat.size);
    defer self.allocator.free(content);
    const bytes_read = try file.readAll(content);
    if (bytes_read != stat.size) return error.UnexpectedEndOfFile;

    var pos: usize = 0;

    // Validate magic.
    if (!std.mem.eql(u8, content[0..8], &CATALOG_MAGIC)) return error.InvalidMagic;
    pos += 8;

    // Validate version.
    const version = std.mem.readInt(u32, content[pos..][0..4], .little);
    _ = version; // Forward-compatible: accept any version for now.
    pos += 4;

    // Validate CRC over everything except the trailing 4 CRC bytes.
    const payload = content[0 .. content.len - 4];
    const stored_crc = std.mem.readInt(u32, content[content.len - 4 ..][0..4], .little);
    const computed_crc = Crc32.hash(payload);
    if (stored_crc != computed_crc) return error.IntegrityCheckFailed;

    // Parse entries.
    const entry_count = std.mem.readInt(u32, content[pos..][0..4], .little);
    pos += 4;

    var i: u32 = 0;
    while (i < entry_count) : (i += 1) {
        if (pos + 8 > content.len - 4) return error.InvalidData;
        const label_id = std.mem.readInt(u32, content[pos..][0..4], .little);
        pos += 4;
        const type_byte = content[pos];
        pos += 1;
        const state_byte = content[pos];
        pos += 1;
        const key_len = std.mem.readInt(u16, content[pos..][0..2], .little);
        pos += 2;

        if (pos + key_len > content.len - 4) return error.InvalidData;
        const key_buf = try self.allocator.dupe(u8, content[pos..][0..key_len]);
        errdefer self.allocator.free(key_buf);
        pos += key_len;

        try self.owned_keys.append(self.allocator, key_buf);
        errdefer _ = self.owned_keys.pop();

        const index_type = std.meta.intToEnum(IndexType, type_byte) catch return error.InvalidData;
        const state = std.meta.intToEnum(IndexState, state_byte) catch return error.InvalidData;

        try self.indexes.append(self.allocator, .{
            .label_id = label_id,
            .property_key = key_buf,
            .index_type = index_type,
            .state = state,
        });
    }
}
```

- [ ] **Step 6: Run tests**

Run: `zig build test --summary all`
Expected: ALL PASS

- [ ] **Step 7: Commit**

```bash
git add src/index_catalog.zig
git commit -m "fix: close SEC-0021 - add magic+CRC integrity to index catalog"
```

---

### Task 2: Multi-Operation Transactions (GAP-0022)

**Files:**
- Modify: `src/engine.zig`
- Test: inline tests in `src/engine.zig`

The existing `beginTxn`/`commitTxn`/`abortTxn` already exist in the vtable. The problem is that mutation methods (putNode, addEdge, putProperty, etc.) auto-wrap each call in begin/commit. We need to allow callers to pass an active transaction ID so mutations join an existing transaction instead of creating their own.

- [ ] **Step 1: Write failing test for multi-op transaction**

Add in engine.zig test section:

```zig
test "GAP-0022: multi-op transaction groups mutations" {
    const allocator = std.heap.page_allocator;
    var engine = try GraphEngine.create(allocator, "test_io", test_uuid, .{});
    defer engine.close() catch {};
    defer std.fs.cwd().deleteTree("test_io/graphs") catch {};

    // Begin an explicit transaction.
    const txn = try engine.beginTxn();

    // Mutations within the transaction should not auto-commit.
    const id1 = try engine.allocNode();
    try engine.putNodeTxn(id1, NodeRec{ .label_head = 0, .label_count = 0, .prop_head = 0, .adj_out_head = 0, .adj_in_head = 0, .txn_stamp = 0 }, txn);
    const id2 = try engine.allocNode();
    try engine.putNodeTxn(id2, NodeRec{ .label_head = 0, .label_count = 0, .prop_head = 0, .adj_out_head = 0, .adj_in_head = 0, .txn_stamp = 0 }, txn);
    _ = try engine.addEdgeTxn(id1, id2, 1, txn);

    // Commit the group.
    try engine.commitTxn(txn);

    // Verify all data persists.
    const n1 = try engine.getNode(id1);
    try testing.expect(n1 != null);
    const n2 = try engine.getNode(id2);
    try testing.expect(n2 != null);
}
```

- [ ] **Step 2: Run tests — should fail**

Expected: FAIL (putNodeTxn and addEdgeTxn not defined)

- [ ] **Step 3: Add transaction-aware mutation methods**

In `engine.zig`, for each auto-committing mutation method, extract the core logic into a `*Txn` variant. The original method becomes a wrapper that auto-commits.

For `putNode`, the pattern is:

```zig
/// Put a node within an existing transaction (no auto-commit).
pub fn putNodeTxn(self: *GraphEngine, id: NodeId, rec: NodeRec, txn: TxnId) anyerror!void {
    self.node_store.putNode(&self.buffer_pool, id, rec);
    try self.logPage(.nodes, self.node_store.pageForNode(id), txn);
    self.metrics.nodes_written += 1;
}

/// Put a node with auto-commit.
pub fn putNode(self: *GraphEngine, id: NodeId, rec: NodeRec) anyerror!void {
    const txn = try self.txn_manager.begin();
    errdefer self.txn_manager.abort(txn) catch {};
    try self.putNodeTxn(id, rec, txn);
    try self.txn_manager.commit(txn);
}
```

Apply the same pattern for `addEdge` → `addEdgeTxn`:

```zig
pub fn addEdgeTxn(self: *GraphEngine, from: NodeId, to: NodeId, rel_type: u32, txn: TxnId) anyerror!EdgeId {
    // ... same body as addEdge but using txn instead of auto-begin/commit ...
}
```

- [ ] **Step 4: Run tests**

Run: `zig build test --summary all`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add src/engine.zig
git commit -m "feat: close GAP-0022 - add transaction-aware mutation methods"
```

---

### Task 3: Edge-ID Index (GAP-0021)

**Files:**
- Modify: `src/engine.zig`
- Test: inline tests in `src/engine.zig`

Add a simple in-memory HashMap from EdgeId → (from: NodeId, prop_head: u32) so `getEdge` can do O(1) lookup instead of returning an error.

- [ ] **Step 1: Write failing test**

```zig
test "GAP-0021: getEdge returns edge after addEdge" {
    const allocator = std.heap.page_allocator;
    var engine = try GraphEngine.create(allocator, "test_io", test_uuid, .{});
    defer engine.close() catch {};
    defer std.fs.cwd().deleteTree("test_io/graphs") catch {};

    const n1 = try engine.allocNode();
    try engine.putNode(n1, NodeRec{ .label_head = 0, .label_count = 0, .prop_head = 0, .adj_out_head = 0, .adj_in_head = 0, .txn_stamp = 0 });
    const n2 = try engine.allocNode();
    try engine.putNode(n2, NodeRec{ .label_head = 0, .label_count = 0, .prop_head = 0, .adj_out_head = 0, .adj_in_head = 0, .txn_stamp = 0 });

    const edge_id = try engine.addEdge(n1, n2, 42);

    const edge = try engine.getEdge(edge_id);
    try testing.expect(edge != null);
    try testing.expectEqual(@as(u32, 42), edge.?.rel_type);
    try testing.expectEqual(n2, edge.?.neighbor);
}
```

- [ ] **Step 2: Run test — should fail**

Expected: FAIL (getEdge returns error.EdgeIndexNotImplemented)

- [ ] **Step 3: Add edge index field and maintain it**

In `GraphEngine` struct, add:
```zig
edge_index: std.AutoHashMap(EdgeId, EdgeIndexEntry),
```

Where `EdgeIndexEntry` is:
```zig
const EdgeIndexEntry = struct {
    from: NodeId,
    neighbor: NodeId,
    rel_type: u32,
    prop_head: u32,
};
```

In `create()` / `initSubsystems()`, initialize: `self.edge_index = std.AutoHashMap(EdgeId, EdgeIndexEntry).init(allocator);`

In `deinit()`/`cleanupResources()`, add: `self.edge_index.deinit();`

In `addEdge()`, after the edge is created, add to index:
```zig
try self.edge_index.put(edge_id, .{ .from = from, .neighbor = to, .rel_type = rel_type, .prop_head = 0 });
```

In `removeEdge()`, remove from index:
```zig
_ = self.edge_index.remove(edge_id);
```

Replace `getEdge()`:
```zig
pub fn getEdge(self: *GraphEngine, edge_id: EdgeId) anyerror!?EdgeEntry {
    const entry = self.edge_index.get(edge_id) orelse return null;
    return EdgeEntry{
        .neighbor = entry.neighbor,
        .edge_id = edge_id,
        .rel_type = entry.rel_type,
        .prop_head = entry.prop_head,
    };
}
```

In `open()`, rebuild the edge index from adjacency stores (similar to label index rebuild).

- [ ] **Step 4: Run tests**

Run: `zig build test --summary all`
Expected: ALL PASS (including the old QUAL-0006 test — update it to expect success instead of error)

- [ ] **Step 5: Update QUAL-0006 test**

Find the existing test that expects `error.EdgeIndexNotImplemented` and update it to expect a successful `null` return (for a nonexistent edge) or a valid result.

- [ ] **Step 6: Commit**

```bash
git add src/engine.zig
git commit -m "feat: close GAP-0021 - implement edge-ID index for O(1) edge lookup"
```
