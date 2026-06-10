# Engine.zig Decomposition Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `src/engine.zig` (1,665 lines) into focused modules while preserving the `GraphEngine` struct as the public API facade.

**Architecture:** Extract logical groups into separate files that the engine imports. The `GraphEngine` struct remains in `engine.zig` but delegates to extracted modules. Each extraction is a pure refactor — no behavioral changes, all existing tests must continue to pass after each task.

**Tech Stack:** Zig 0.15.x — file splitting, `@import`, `pub` visibility

---

## File Structure

| File | Responsibility | Lines (est.) |
|------|---------------|-------------|
| `src/engine.zig` | GraphEngine struct, create/open/close, vtable wiring | ~400 |
| `src/engine_stores.zig` | Node/edge/property/label mutation methods | ~300 |
| `src/engine_index.zig` | Label index, property index, derived index rebuild/save | ~200 |
| `src/engine_persist.zig` | Free-space save/load, checkpoint, manifest helpers | ~200 |
| `src/engine_integrity.zig` | checkIntegrity, getStorageStats, getMetrics | ~150 |
| `src/engine_edge_props.zig` | Edge property methods + findEdgePropHead helper | ~150 |

Tests remain inline in each extracted file, or move to a shared `tests/engine_test.zig`.

---

### Task 1: Extract edge-property methods to `engine_edge_props.zig`

**Files:**

- Create: `src/engine_edge_props.zig`
- Modify: `src/engine.zig`

The 4 edge-property methods + `findEdgePropHead` helper (~80 lines) are the most self-contained extraction.

- [ ] **Step 1: Create `src/engine_edge_props.zig`**

Move `findEdgePropHead`, `setEdgeProperty`, `removeEdgeProperty`, `getEdgeProperty`, `getAllEdgeProperties` into a new file. These methods take `*GraphEngine` as their first parameter, so they become free functions that accept the engine pointer:

```zig
// src/engine_edge_props.zig
const std = @import("std");
const types = @import("types.zig");
const prop_store_mod = @import("prop_store.zig");
// ... other needed imports

const NodeId = types.NodeId;
const EdgeId = types.EdgeId;
const PropertyValue = types.PropertyValue;
const PropStore = prop_store_mod.PropStore;

const GraphEngine = @import("engine.zig").GraphEngine;

pub fn findEdgePropHead(engine: *GraphEngine, from: NodeId, edge_id: EdgeId) !?u32 {
    // ... extracted body ...
}

pub fn setEdgeProperty(engine: *GraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId, key: []const u8, value: PropertyValue) !void {
    // ... extracted body using findEdgePropHead ...
}
// ... etc for removeEdgeProperty, getEdgeProperty, getAllEdgeProperties
```

- [ ] **Step 2: In engine.zig, replace method bodies with delegation**

```zig
const engine_edge_props = @import("engine_edge_props.zig");

pub fn setEdgeProperty(self: *GraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId, key: []const u8, value: PropertyValue) anyerror!void {
    return engine_edge_props.setEdgeProperty(self, from, to, edge_id, key, value);
}
```

- [ ] **Step 3: Run tests**

Run: `zig build test --summary all`
Expected: ALL PASS (pure refactor)

- [ ] **Step 4: Commit**

```bash
git add src/engine.zig src/engine_edge_props.zig
git commit -m "refactor: extract edge-property methods to engine_edge_props.zig"
```

---

### Task 2: Extract integrity/stats to `engine_integrity.zig`

**Files:**

- Create: `src/engine_integrity.zig`
- Modify: `src/engine.zig`

Move `checkIntegrity`, `getStorageStats`, `getMetrics` (~100 lines).

- [ ] **Step 1: Create file, move functions**
- [ ] **Step 2: Delegate from engine.zig**
- [ ] **Step 3: Run tests — ALL PASS**
- [ ] **Step 4: Commit**

```bash
git commit -m "refactor: extract integrity/stats methods to engine_integrity.zig"
```

---

### Task 3: Extract index operations to `engine_index.zig`

Move `rebuildLabelIndex`, `rebuildPropertyIndex`, `rebuildDerivedIndexes`, `saveDerivedIndexes`, `loadDerivedIndexes` (~120 lines).

- [ ] **Step 1–4: Same pattern as Task 1**

```bash
git commit -m "refactor: extract index operations to engine_index.zig"
```

---

### Task 4: Extract persistence helpers to `engine_persist.zig`

Move `saveFreeStore`, `loadFreeStore`, `saveManifest`, free-space manager init/load logic (~150 lines).

- [ ] **Step 1–4: Same pattern**

```bash
git commit -m "refactor: extract persistence helpers to engine_persist.zig"
```

---

### Task 5: Extract store operations to `engine_stores.zig`

Move `getNode`, `putNode`, `deleteNode`, `allocNode`, `addEdge`, `removeEdge`, `expandOut`, `expandIn`, `getProperty`, `putProperty`, `getAllProperties`, `addLabel`, `removeLabel`, `scanLabel`, `logPage`, `drainEdgeIterator` (~350 lines).

This is the largest extraction. The engine.zig file should be ~400 lines after this.

- [ ] **Step 1–4: Same pattern**

```bash
git commit -m "refactor: extract store operations to engine_stores.zig"
```

---

### Task 6: Move tests to `tests/engine_test.zig`

Move the ~125 lines of inline tests from engine.zig to a dedicated test file.

- [ ] **Step 1: Create `tests/engine_test.zig` with imports**
- [ ] **Step 2: Move test blocks**
- [ ] **Step 3: Run `zig build test --summary all` — ALL PASS**
- [ ] **Step 4: Commit**

```bash
git commit -m "refactor: move engine tests to tests/engine_test.zig"
```

---

### Task 7: Final verification

- [ ] **Step 1: Verify engine.zig is under 500 lines**

Run: `wc -l src/engine.zig` — should be ~400

- [ ] **Step 2: Run full test suite**

Run: `zig build test --summary all && zig build test-integration --summary all`

- [ ] **Step 3: Verify formatting**

Run: `zig fmt --check src/engine*.zig`
