# B+Tree Page Persistence Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist the in-memory B+tree property index to disk pages so it survives restart without a full rebuild from the node store.

**Architecture:** Serialize B+tree nodes into `btree_internal` and `btree_leaf` page types (already defined in `page.zig`). Use the existing buffer pool and pager infrastructure. On checkpoint, dirty B+tree pages are flushed with all other dirty pages. On recovery, load the root page and lazily fault in B+tree pages on access.

**Tech Stack:** Zig 0.15.x, existing BufferPool/Pager/FreeSpaceManager infrastructure, page types 7 (`btree_internal`) and 8 (`btree_leaf`)

---

## File Structure

| File | Responsibility | Action |
|------|---------------|--------|
| `src/btree.zig` | In-memory B+tree (current) | Modify: add serialize/deserialize per node |
| `src/btree_pager.zig` | Disk-backed B+tree using buffer pool | Create: page-based B+tree with pin/unpin |
| `src/page.zig` | Page header + types | Modify: define btree page layout constants |
| `src/engine.zig` | Engine wiring | Modify: use btree_pager instead of in-memory btree |
| `src/index_catalog.zig` | Index catalog | Modify: store btree root page_id |

---

### Task 1: Define B+tree page layout

**Files:**

- Modify: `src/page.zig`

- [ ] **Step 1: Define B+tree page body layout**

After the existing page header definitions in `page.zig`, add constants for B+tree pages:

```zig
/// B+tree leaf page layout (after 32-byte PageHeader):
/// [is_leaf: u8] [count: u16] [next_leaf: u64] [prev_leaf: u64]
/// Then count entries of: [key_len: u16] [key: key_len bytes] [value: 8 bytes (u64)]
pub const BTREE_NODE_HEADER_SIZE = 1 + 2 + 8 + 8; // 19 bytes

/// B+tree internal page layout:
/// [is_leaf: u8] [count: u16] [padding: 16 bytes]
/// Then count+1 child pointers (u64) followed by count keys [key_len: u16] [key bytes]
```

- [ ] **Step 2: Run tests — ALL PASS (no behavioral change)**
- [ ] **Step 3: Commit**

---

### Task 2: Implement B+tree node serialization

**Files:**

- Create: `src/btree_pager.zig`

- [ ] **Step 1: Write test for leaf node round-trip**

```zig
test "btree leaf page round-trip" {
    var buf: [8192]u8 = undefined;
    // Serialize a leaf node with 3 entries into buf
    // Deserialize from buf
    // Assert all 3 entries match
}
```

- [ ] **Step 2: Implement serializeLeaf and deserializeLeaf**

Functions that pack/unpack leaf node data into a page-sized buffer.

- [ ] **Step 3: Write test for internal node round-trip**
- [ ] **Step 4: Implement serializeInternal and deserializeInternal**
- [ ] **Step 5: Run tests — ALL PASS**
- [ ] **Step 6: Commit**

---

### Task 3: Implement page-backed B+tree operations

**Files:**

- Modify: `src/btree_pager.zig`

- [ ] **Step 1: Write test for insert + lookup through pages**

Create a `PagedBPlusTree` that uses BufferPool for I/O. Insert several entries, look them up.

- [ ] **Step 2: Implement PagedBPlusTree struct**

Key methods: `init(buffer_pool, free_space, root_page_id)`, `insert(key, value)`, `get(key)`, `scan(start, end)`.

Each operation pins the relevant page, deserializes, operates, serializes back, marks dirty, unpins.

- [ ] **Step 3: Implement node splitting through pages**

When a node overflows, allocate a new page from free_space, split entries, update parent.

- [ ] **Step 4: Run tests — ALL PASS**
- [ ] **Step 5: Commit**

---

### Task 4: Wire into engine checkpoint/recovery

**Files:**

- Modify: `src/engine.zig`, `src/index_catalog.zig`

- [ ] **Step 1: Store btree root page_id in IndexCatalog/manifest**
- [ ] **Step 2: On checkpoint, btree dirty pages flush with buffer pool (automatic)**
- [ ] **Step 3: On recovery, load root page_id from catalog, init PagedBPlusTree**
- [ ] **Step 4: Remove property index rebuild from open() path when snapshot exists**
- [ ] **Step 5: Run full test suite + integration tests**
- [ ] **Step 6: Commit**

---

### Task 5: Benchmark and validate

- [ ] **Step 1: Run `make scale-bench` before and after**
- [ ] **Step 2: Compare cold-start times (should improve significantly for large graphs)**
- [ ] **Step 3: Compare property lookup latency (should be O(log n) instead of O(n))**
- [ ] **Step 4: Save new baseline: `make bench-save`**
