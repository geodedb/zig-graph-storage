# Property O(1) Lookup Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace O(n) linear property scan with O(1) hash-based lookup within property pages.

**Architecture:** Add a small per-page directory (hash of key → entry offset) at the end of each property page. When looking up a property by key, hash the key, check the directory for a candidate offset, and verify the key match. Falls back to linear scan on hash collision or if directory is full. This avoids the B+tree dependency and keeps the change localized to `prop_store.zig`.

**Tech Stack:** Zig 0.15.x, existing slotted-page infrastructure

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `src/prop_store.zig` | Modify | Add per-page key directory at page tail |
| `docs/format-spec.md` | Modify | Document new property page layout |

---

### Task 1: Design per-page directory format

The property page currently uses sequential entries from `PROP_DATA_OFFSET` forward. The directory lives at the end of the page, growing backward (like PostgreSQL's line pointer array).

```
Page layout:
[PageHeader 32B] [meta 12B] [entries →  ...free space...  ← directory] [dir_count 2B]

Directory entry: [key_hash: u16] [entry_offset: u16] = 4 bytes each
Max entries per 8KB page: (8192 - 32 - 12 - 2) / (min_entry_size + 4) ≈ 100
```

- [ ] **Step 1: Define directory constants in prop_store.zig**
- [ ] **Step 2: Write test for directory-based lookup**
- [ ] **Step 3: Implement writeDirectory on putProperty**
- [ ] **Step 4: Implement readDirectory on getProperty**
- [ ] **Step 5: Handle directory full → fallback to linear scan**
- [ ] **Step 6: Run tests — ALL PASS**
- [ ] **Step 7: Benchmark getProperty latency improvement**
- [ ] **Step 8: Update format-spec.md**
- [ ] **Step 9: Commit**

### Task 2: Migration compatibility

Since existing property pages don't have directories, the code must handle both formats:
- Pages without directory (dir_count == 0 or legacy) → linear scan (current behavior)
- Pages with directory → hash lookup

- [ ] **Step 1: Add directory version detection**
- [ ] **Step 2: On putProperty to a legacy page, rebuild directory**
- [ ] **Step 3: Test mixed old/new page handling**
- [ ] **Step 4: Commit**
