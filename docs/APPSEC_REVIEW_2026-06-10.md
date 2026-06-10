# AppSec Review — graph-storage (full library)

**Date:** 2026-06-10 · **Reviewer:** Claude (defensive appsec code review) · **Standards:** OWASP Top 10:2025, CIS Controls v8.1.2 · **Commit:** `eca7466` (branch `main`)

---

## 1. Scope and Assumptions

**Reviewed.** Per the input contract, with depth focused on the five open questions and parsing/trust paths *not* covered by the previously filed SEC-0037..0046. Files read in full or in relevant part: `node_store.zig`, `free_space.zig`, `label_store.zig`, `label_dict.zig`, `shard_manifest.zig`, `registry.zig`, `wal_record.zig`, `engine_index.zig`, `index_snapshot.zig`, `var_store.zig`, `label_index.zig`, `property_chain_index.zig`, `property.zig`, `prop_store.zig` (parse paths), `adj_store.zig` (header validation), `manifest.zig` (deser/CRC), `recovery.zig` (manifest/WAL/index gating), `graph_dir.zig`, `file_manager.zig`, `backup.zig` (restore/extract paths), `encryption.zig`, `operation_result.zig`, `metrics.zig`, `errors.zig`, `engine.zig` (open path), `.gitlab-ci.yml` (Zig install), `build.zig.zon`. Cross-checked Zig 0.16.0 stdlib (`std.json.Value` union, `Io.Dir.CreateFileOptions`).

**Trust model applied (from contract).** In-process embedded library; the caller already has full memory access, so the in-memory API is **not** an attack surface. The security boundary is the **filesystem**: an attacker is assumed to have write access to the data directory and can supply crafted page files, WAL records, manifests, index snapshots, `labels.dict`, `shard_manifest.json`, registry files, and malicious backup archives for restore. Secondary: supply chain. No network surface.

**Critical build assumption.** The contract states production uses **`ReleaseFast`**, which disables Zig's safety checks. This is load-bearing for severity: in `ReleaseFast`, an unchecked `@intCast` overflow, a wrong-tag union field access, an integer-underflow in a slice index, or `.?` on null become **undefined behavior / out-of-bounds memory access** rather than a clean panic. Findings are rated against that build. In `ReleaseSafe`/`Debug` the same bugs are deterministic panics (DoS only).

**Not reviewed / out of scope.** Runtime exploitation, fuzzing execution (no code run), the external `wal`/`uuid`/`thread_pool`/`otel` dependency internals (only their pinning), Windows/macOS-specific filesystem semantics (claimed-but-untested per contract), and the full re-derivation of SEC-0037..0046 (cited only).

**Confidence note.** All findings are from static reading. I did not execute the code; "Confidence" reflects how certain the control-flow conclusion is from the source.

---

## 2. Executive Summary

- **The filesystem trust boundary is mostly well-guarded for the *primary* stores** (WAL record, property decode, registry, free-space, manifest, adj-store all bounds-check or CRC-verify untrusted lengths before use), but **derived-index snapshots and the JSON shard manifest are the weak edge** — they are read at `open()` with little or no integrity protection and feed untrusted counts straight into allocation or wrong-typed union access.
- **Highest new risk: `shard_manifest.json` parsing (SEC-NEW-01, High).** `readFromDir` performs unchecked `std.json.Value` union field accesses (`.integer`, `.object`, `.string`, `.array`) and `.?` on absent keys. A malformed manifest (attacker has FS write) causes a panic in safe builds and **undefined behavior in ReleaseFast** on the sharded `open()` path. CWE-754/CWE-843.
- **Index-snapshot OOM extends beyond the filed SEC-0044 (SEC-NEW-02, Medium).** The same untrusted-`item_count` → `ensureTotalCapacity` pattern flagged for `label_index` also exists, **unguarded**, in the **edge index** (`engine_index.zig:241`) and **property-chain index** (`property_chain_index.zig:229`), plus the root `loadHeader.item_count` has no cap. `.idx` files carry no checksum, so any FS-write attacker can force a multi-GB allocation at `open()`.
- **Symlink-following write during backup restore (SEC-NEW-03, Medium).** `restoreBackupResult` blocks `..`/absolute/backslash filenames but extracts via `createFile` with default flags (no `resolve_beneath`, no `O_NOFOLLOW`). A pre-planted symlink in `target_dir` lets restore write attacker-controlled bytes through the link. Compounds the already-filed SEC-0038 parse-then-verify (files land on disk before HMAC check).
- **`labels.dict` loader has a lifetime bug on crafted input (SEC-NEW-04, Low/Medium).** Duplicate names/IDs alias the same `owned` buffer across `name_to_id`/`id_to_name`, producing a leak (dup name) or a potential double-free on `deinit` (dup id), and CRC is checked only after full materialization.
- **Answers to the five questions, in brief:** (1) Yes — shard manifest JSON, edge/prop-chain snapshot loaders, and `labels.dict` were not covered. (2) Recovery/verify is **fail-closed** on the WAL and manifest paths (malformed WAL aborts recovery; `selectManifest` errors when both manifests are null); index-snapshot load failure is intentionally caught and falls back to rebuild — acceptable. (3) One real symlink/TOCTOU gap in restore (SEC-NEW-03); `graph_dir`/`file_manager` creation is constrained but also lacks `resolve_beneath`. (4) Most casts are guarded; the unguarded ones of concern are the snapshot counts (SEC-NEW-02) and the JSON `@intCast` in shard manifest (SEC-NEW-01). (5) **No key or plaintext leakage** found in logs, metrics, errors, or `operation_result` JSON — these emit only counters, enum labels, and UUID hex.

**Overall confidence: Medium-High.** The primary data-path parsing is genuinely hardened; the residual risk concentrates in a handful of secondary loaders and the restore path.

---

## 3. Findings Table

| ID | Severity | Confidence | Title | Location | OWASP | Status |
|----|----------|-----------|-------|----------|-------|--------|
| SEC-NEW-01 | High | High | Unchecked `std.json.Value` union access in shard manifest parse (panic/UB on crafted JSON) | `shard_manifest.zig:90-117` | A10 / A08 | **New** |
| SEC-NEW-02 | Medium | High | Unbounded `ensureTotalCapacity` from untrusted snapshot counts (edge + prop-chain index, `loadHeader`) | `engine_index.zig:241`; `property_chain_index.zig:229`; `index_snapshot.zig:85-89` | A10 / A08 | **New** (extends SEC-0044) |
| SEC-NEW-03 | Medium | Medium | Backup restore follows symlinks / no `resolve_beneath` on extract | `backup.zig:306-316`; `isValidBackupFilename` `:559-580` | A08 / A01 | **New** |
| SEC-NEW-04 | Low→Med | Medium | `labels.dict` loader: duplicate-key aliasing → leak / potential double-free; CRC verified after materialization | `label_dict.zig:123-147` | A08 / A10 | **New** |
| SEC-NEW-05 | Low | Medium | `.idx` derived-index snapshots have no checksum/HMAC (silent tamper of index content) | `index_snapshot.zig:30-90`; `label_index.zig`, `engine_index.zig` | A08 | **New** |
| SEC-NEW-06 | Info | High | Hardening: `createFile`/`createDirPath` across creation paths omit `resolve_beneath`/`exclusive` | `graph_dir.zig:39`; `file_manager.zig:67`; `manifest.zig:150` | A02 | **New** |
| SEC-0037 | Critical | — | AES-GCM nonce reuse (flush never advances cached write_count) | `buffer_pool.zig:446-451`; `pager.zig:81-85` | A04 | Previously filed (#115) |
| SEC-0038 | High | — | Backup restore parse-then-verify (files written before HMAC) | `backup.zig:291-339` | A08 | Previously filed (#117) |
| SEC-0039 | High | — | prop_store `dir_count` underflow → OOB | `prop_store.zig:56-72,160` | A10 | Previously filed (#128) |
| SEC-0040 | High | — | var_store `data_len` OOB read | `var_store.zig:118-123` | A10 | Previously filed (#129) |
| SEC-0041 | High | — | 2PC recovery lenient WAL `readFrom` | `sharded_recovery.zig:53,98` | A08 | Previously filed (#118) |
| SEC-0042 | Medium | — | adj_store / prop-iterator missing hop guards | `adj_store.zig`, `prop_store.zig` | A10 | Previously filed (#130) |
| SEC-0043 | Medium | — | Manifest CRC32-only under TDE | `manifest.zig:84-95` | A04 | Previously filed (#132) |
| SEC-0044 | Medium | — | label_index `node_count` OOM | `label_index.zig:211` | A10 | Previously filed (#133) |
| SEC-0045 | Medium | — | Pager key copies not `secureZero`'d | `file_manager.zig:106-119` | A04 | Previously filed (#134) |
| SEC-0046 | Low | — | Untracked npm files | repo root | A03 | Previously filed (#135) |

---

## 4. Finding Details

### SEC-NEW-01 — Unchecked `std.json.Value` union access in shard manifest parse

**Severity: High · Confidence: High · OWASP A10 (Mishandling of Exceptional Conditions), secondary A08 · CWE-843 (type confusion on union), CWE-754, CWE-704**

**Evidence.** `src/shard_manifest.zig:90-117`:

```zig
const root = parsed.value.object;                              // :90  panic/UB if top-level not an object
const version = @as(u32, @intCast(root.get("version").?.integer));   // :91  .? on absent key; .integer on non-int; @intCast on out-of-range
const shard_count = @as(u32, @intCast(root.get("shard_count").?.integer)); // :92
...
const arr = root.get("per_shard_uuids").?.array;              // :107
const hex = item.string;                                       // :112  .string on non-string
_ = try std.fmt.hexToBytes(&out, hex);                         // :115  (this one is checked)
```

`std.json.Value` is `union(enum) { null, bool, integer: i64, float, number_string, string, array, object }` (confirmed in `lib/std/json/dynamic.zig:20-28`). Accessing an inactive field is **checked illegal behavior**: panic in Debug/ReleaseSafe, **undefined behavior in ReleaseFast**. `.?` on a missing key is the same. `@intCast(i64→u32)` panics/UB on negative or `>2^32-1`.

**Reachability.** `sharded_engine.zig:168` calls `shard_manifest_mod.readFromDir(...)` inside the sharded `open()`. `shard_manifest.json` is an attacker-writable on-disk artifact (data_types/threat_model).

**Attack scenario (non-destructive).** With write access to the graph root, replace `shard_manifest.json` with `{"version":"x"}` (string where int expected), or `[]` (array at top level), or `{"version":99999999999}` (out-of-u32 range), or omit a key. On the next sharded open: safe build → process panic (DoS); ReleaseFast → wrong-tag union read / out-of-range cast = undefined behavior on the open path before any integrity gate runs.

**Impact.** Denial of service on every sharded open (the manifest is read before the algorithm-hash/shard-count checks at `:103-105`). In ReleaseFast, UB with unpredictable consequences. Note the *value* checks (`version`, `shard_count`, `algorithm_hash`) are correct and fail-closed — the bug is purely that **type/presence is assumed, not validated**, before those checks execute.

**Root cause.** Dynamic JSON parsed into `std.json.Value` and consumed with unchecked field accessors instead of tag checks or a typed `parseFromSlice(StructType, ...)`.

**Remediation.** Either (preferred) parse into a typed struct so the parser enforces shape:

```zig
const Parsed = struct { version: u32, shard_count: u32, algorithm_hash: u64, per_shard_uuids: [][]const u8 };
var parsed = std.json.parseFromSlice(Parsed, allocator, bytes, .{}) catch return error.InvalidShardManifest;
```

or guard every access:

```zig
const root_v = parsed.value;
if (root_v != .object) return error.InvalidShardManifest;
const v_node = root_v.object.get("version") orelse return error.InvalidShardManifest;
if (v_node != .integer or v_node.integer < 0 or v_node.integer > std.math.maxInt(u32)) return error.InvalidShardManifest;
const version: u32 = @intCast(v_node.integer);
```

Apply the same to `shard_count`, the `algorithm_hash` branch, `per_shard_uuids` (`!= .array`), and each `item` (`!= .string`). Consider also adding a CRC/HMAC to the manifest so a tamper is rejected before JSON parsing (ties to SEC-0043 reasoning under TDE).

**Regression tests.** Add cases feeding: non-object root (`"5"`, `"[]"`), missing `version`, string-typed `version`, negative and `>2^32` integers, non-array `per_shard_uuids`, non-string array element, wrong-length hex — each must return a clean error, never panic. Run the suite under `-Doptimize=ReleaseSafe` to assert no illegal-behavior.

**Mappings.** OWASP A10; CWE-843, CWE-754, CWE-704. CIS Controls v8.1.2: 16.1 (secure SDLC — input validation), 16.11 (vetted parsing), 16.6 (severity rating of intake).

---

### SEC-NEW-02 — Unbounded allocation from untrusted snapshot counts (edge + property-chain index)

**Severity: Medium · Confidence: High · OWASP A10, secondary A08 · CWE-789 (memory allocation with excessive size), CWE-1284**

**Evidence.**

- `src/index_snapshot.zig:85-89` — `loadHeader` returns `item_count = readInt(u64, header[..])` and `payload_size` with **no upper bound** on `item_count`.
- `src/engine_index.zig:241` — `try engine.edge_index.ensureTotalCapacity(@intCast(snapshot.item_count));` (untrusted count, 32-byte entries).
- `src/property_chain_index.zig:229` — `try gop.value_ptr.entries.ensureTotalCapacity(self.allocator, entry_count);` where `entry_count` is a per-chain u32 read from the file at `:222`.
- `src/label_index.zig:211` — the same pattern (this is **SEC-0044**, already filed; included only to show the class).

Per-item *byte* reads use `readBounded` (`index_snapshot.zig:92-99`) which correctly caps against `remaining` (file size). The flaw is the **upfront `ensureTotalCapacity` reserves memory for a count that the file size does not actually contain** — the allocation happens before the bound is enforced by reading bytes.

**Reachability.** `engine.zig:308` `tryLoadDerivedIndexes() catch false` runs at every `open()` and invokes all three loaders. `.idx` files have no checksum (see SEC-NEW-05), so the count is fully attacker-controlled.

**Attack scenario (non-destructive).** Write an `edges.idx` of ~32 bytes whose header `item_count = 0x0000_0010_0000_0000`. At open, `ensureTotalCapacity` attempts to reserve ~`2^36 * 32` bytes. Same for `props.idx` with a large per-chain `entry_count`.

**Impact.** Denial of service. The error is caught (`catch false` → rebuild), so on systems that return `error.OutOfMemory` cleanly this degrades to a rebuild. But a single huge `ensureTotalCapacity` on an overcommit-enabled Linux host can trip the **OOM killer** (killing the host process or a co-tenant) before the allocator returns an error — so the `catch` does not fully neutralize it. Lower than SEC-0037/0040 because it is not memory corruption.

**Root cause.** Trusting a count field for capacity reservation without first bounding it against the available payload bytes.

**Remediation.** Bound the count by what the payload can hold *before* reserving:

```zig
// edge index: each item is 8+8+8+4+4 = 32 bytes
const max_items = snapshot.payload_size / 32;
if (snapshot.item_count > max_items) return error.InvalidFormat;
try engine.edge_index.ensureTotalCapacity(@intCast(snapshot.item_count));
```

For property-chain, bound `entry_count` by `remaining / min_entry_size` (min = 2 + 0 + 8 = 10 bytes) before `ensureTotalCapacity`. Apply the identical fix at `index_snapshot.zig` by exposing/validating `item_count <= payload_size / min_record_size`, and back-port to `label_index` (SEC-0044). Also cap snapshot file size in `loadHeader` (it currently only casts via `FileTooLarge`).

**Regression tests.** Craft each `.idx` with a tiny payload and a huge `item_count`/`entry_count`; assert `error.InvalidFormat` (not OOM, not a multi-GB reservation). Add an allocation-counting test allocator asserting reserved bytes ≤ file size.

**Mappings.** OWASP A10; CWE-789, CWE-1284. CIS v8.1.2: 16.1, 16.6.

---

### SEC-NEW-03 — Backup restore follows symlinks (no `resolve_beneath`/`O_NOFOLLOW`)

**Severity: Medium · Confidence: Medium · OWASP A08 (Software/Data Integrity), secondary A01 · CWE-59 (link following), CWE-22 (residual)**

**Evidence.** `src/backup.zig:306-316`:

```zig
const subdir_path = ...; try std.Io.Dir.cwd().createDirPath(io, subdir_path);   // :308
const file_path  = ...;                                                         // :311
const out_file = try std.Io.Dir.cwd().createFile(io, file_path, .{ .permissions = ...0o600 });  // :314
```

`isValidBackupFilename` (`:559-580`) correctly rejects empty, NUL, backslash, leading `/`, `..` segments, and empty segments — so classic traversal *via the archive name* is blocked (validated by the SEC-0002 tests). But the extraction `createFile` uses **default `CreateFileOptions`** — no `resolve_beneath`, no `exclusive`. Zig 0.16 `CreateFileOptions` (confirmed in `lib/std/Io/Dir.zig:585-628`) exposes `resolve_beneath` ("path resolution that would escape the directory instead returns `error.AccessDenied`") and `exclusive`; neither is set.

**Attack scenario (non-destructive).** The threat model grants the attacker write access to the data directory, which includes `target_dir`. Before a restore, the attacker plants a symlink `target_dir/nodes.store -> /home/victim/.ssh/authorized_keys` (or any file the engine UID can write). On restore, `createFile("nodes.store")` follows the symlink and `copyTrackedToFile` writes the archive's bytes through it. Filename validation never sees the link because the *name* `nodes.store` is legal. This compounds **SEC-0038**: files are written *during* extraction, before the CRC/HMAC check at `:322-339`, so the write happens even when the archive ultimately fails authentication.

**Impact.** Arbitrary-content write to any path the process can reach via a planted link inside `target_dir` — a write primitive usable for config/credential tampering. Scoped to attackers who can already write the data directory, hence Medium not High.

**Root cause.** Extraction trusts the directory entry not to be a symlink and does not constrain path resolution to beneath `target_dir`.

**Remediation.**

1. Open `target_dir` once as a `Dir` handle and create files **relative to that handle** with `resolve_beneath = true` and `exclusive = true` (so an existing symlink/file is refused):

   ```zig
   const out_file = try target.createFile(io, name, .{
       .truncate = true, .exclusive = true, .resolve_beneath = true,
       .permissions = Permissions.fromMode(owner_only_file_mode),
   });
   ```

   `exclusive` causes `error.PathAlreadyExists` on a pre-existing symlink/file (restore should be into a clean dir, or pre-delete validated paths); `resolve_beneath` blocks any escape if the platform supports it.
2. Defense in depth, ties to SEC-0038: stage extraction to a temp dir, verify CRC+HMAC, then atomically rename into place — so unauthenticated bytes never touch the real target.

**Regression tests.** Pre-create a symlink at `target_dir/nodes.store` → outside path; assert restore returns an error and the link target is untouched. Add a test that an existing regular file at the target name causes `error.PathAlreadyExists` (or is safely staged-and-renamed).

**Mappings.** OWASP A08/A01; CWE-59, CWE-22. CIS v8.1.2: 16.1, 11.x (data recovery integrity).

---

### SEC-NEW-04 — `labels.dict` loader: duplicate-key aliasing and verify-after-materialize

**Severity: Low (→ Medium in dup-id case) · Confidence: Medium · OWASP A08, secondary A10 · CWE-415 (double free) / CWE-401 (leak), CWE-345 (insufficient integrity verification of order)**

**Evidence.** `src/label_dict.zig:123-147`:

```zig
const owned = try self.allocator.alloc(u8, name_len);   // :127
try next.name_to_id.put(owned, id);                     // :134  owned used as KEY
try next.id_to_name.put(id, owned);                     // :135  same owned used as VALUE
...
if (stored_crc != crc.final()) return error.ChecksumMismatch;   // :142  CRC checked AFTER full build
self.deinit(); self.* = next;                           // :144-145
```

`deinit` (`:23-31`) frees **only** the keys of `name_to_id`. The two maps deliberately alias the same buffer so a single free suffices — but that invariant breaks on crafted input:

- **Duplicate name:** the second `name_to_id.put(owned2, id)` does not replace the existing key buffer (StringHashMap keeps the first key); `owned2` is still inserted into `id_to_name`. On `deinit`, `owned2` (a value in `id_to_name` that is *not* a `name_to_id` key) is never freed → **memory leak**.
- **Duplicate id:** `id_to_name.put(id, owned2)` overwrites the value pointer to the first entry's buffer; both buffers were inserted as distinct `name_to_id` keys, so `deinit` frees both — but the now-dangling first `id_to_name` association and the aliasing can, depending on map internals and subsequent `getOrAssign` reuse of `max_id`, produce a **use-after-free / double-free** path. At minimum it corrupts the id→name mapping.

`name_len` allocation is **bounded** by `readTracked`'s `if (buf.len > remaining.*)` guard (`:151`), so there is no OOM amplification beyond file size — good. The residual issue is the verify-after-materialize ordering (the dictionary is fully built before the CRC check) and the aliasing.

**Reachability.** `engine.zig:301` `label_dict.loadFromFile(...)` runs at every `open()`; `labels.dict` is attacker-writable.

**Impact.** On a crafted/corrupted `labels.dict`: memory leak (dup name) or memory-safety corruption of the label dictionary (dup id). Contained to a single load; not a direct RCE, hence Low/Medium.

**Root cause.** Insertion assumes file entries are unique and consistent across the two maps; no de-dup check, and CRC is validated only after the structure is built.

**Remediation.** Detect duplicates and verify integrity before mutating: (a) check `name_to_id.getOrPut`/`id_to_name.getOrPut` `found_existing` and reject with `error.InvalidData` (freeing `owned`) on any duplicate name or id; (b) move the CRC check so the loop's allocations are minimal before validation, or compute/verify the CRC in a first pass over the raw bytes before building the maps. Keep the single-owner aliasing invariant explicit with a comment and an assert.

**Regression tests.** Feed a `labels.dict` with two identical names; with two distinct names sharing one id; assert `error.InvalidData` and no leak (test allocator). Feed a byte-flipped file; assert `error.ChecksumMismatch` with no partial state retained.

**Mappings.** OWASP A08/A10; CWE-415, CWE-401, CWE-345. CIS v8.1.2: 16.1, 16.6.

---

### SEC-NEW-05 — Derived-index `.idx` snapshots have no checksum/HMAC

**Severity: Low · Confidence: Medium · OWASP A08 · CWE-353 (missing integrity check)**

**Evidence.** `index_snapshot.zig:30-46` writes only `magic(8) + checkpoint_counter(8) + item_count(8)` then raw payload; `loadHeader`/`loadFile` validate magic and size but compute **no CRC/HMAC**. `labels.idx`, `props.idx`, `edges.idx` are thus integrity-unprotected, unlike the primary stores (page CRC/TDE), WAL (CRC32C), manifest (CRC32), registry (CRC32), and `labels.dict` (CRC32). The load is gated by `checkpoint_counter == manifest.counter` (`engine_index.zig:162`), which detects *staleness* but not *content tampering* at the same counter.

**Attack scenario.** An attacker who can write the data dir edits `edges.idx` payload (keeping the counter equal to the manifest's) to inject/alter edge-index entries that diverge from the authoritative `adj_store`. The engine trusts the loaded index for lookups until the next rebuild. This is the integrity precondition that also makes SEC-NEW-02's count fully attacker-controlled.

**Impact.** Index/result inconsistency and the enabling condition for SEC-NEW-02. Low because the indexes are *derived* (rebuildable from primary stores) and a counter mismatch already forces rebuild; the window is "same counter, altered payload."

**Remediation.** Append a CRC32C (minimum) or, under TDE, an HMAC-SHA256 (consistent with backup V2 and the SEC-0043 direction) over the snapshot payload; verify on load and treat mismatch as "snapshot invalid → rebuild." This also lets the loader reject malformed counts cheaply.

**Regression tests.** Round-trip with checksum; flip one payload byte at a matching counter; assert load returns null/invalid and the engine rebuilds from primary stores.

**Mappings.** OWASP A08; CWE-353. CIS v8.1.2: 3.x (data integrity), 16.1.

---

### SEC-NEW-06 — Hardening: creation paths omit `resolve_beneath`/`exclusive`

**Severity: Informational · Confidence: High · OWASP A02 · CWE-59 (defense-in-depth)**

**Evidence.** `graph_dir.zig:39` (store-file create), `file_manager.zig:67` (`create_if_missing`), `manifest.zig:150` and `registry.zig:117` / `label_dict.zig:94` (tmp-file create) all use `createFile`/`createDirPath` with default options. None set `resolve_beneath` (available per Zig 0.16 `CreateFileOptions`). Permissions (0o600 files, 0o700 dirs) are correctly applied and tested. These paths use application-controlled, UUID-suffixed names (lower symlink risk than restore), so this is hardening, not an active exploit like SEC-NEW-03.

**Remediation.** Where the platform supports it, set `resolve_beneath = true` on creation/open of files under the graph dir, and prefer creating relative to a held `Dir` handle for the graph directory rather than re-resolving `cwd()`-relative composed paths each time (also reduces TOCTOU windows). Treat as a consistency follow-up to SEC-NEW-03.

**Mappings.** OWASP A02; CWE-59. CIS v8.1.2: 4.x (secure configuration), 16.1.

---

## 5. Secure Design Notes (positive controls observed)

- **Primary-store length parsing is consistently bounded.** `wal_record.deserialize` (`:125,148-149`) enforces `MIN_RECORD_SIZE`, `MAX_WAL_PAYLOAD (1 MiB)`, and `data.len < offset+payload_len+checksum` before copy. `property.decode`/`decodeView` (`:130-160,200-228`) check `bytes.len < total` before every slice/dupe. `registry.loadFromFile` (`:137-193`) verifies magic and CRC **first**, then bounds each `name_len` via `pos + name_len + 32 > data.len - 4`. `prop_store` legacy scan and iterator (`:195-211,263-273`) and `encodedSizeFromBytes` (`:621-642`) bounds-check before each step. `adj_store.readBlockHeader` (`:277`) rejects `count > entries_per_block`. `free_space.deserializeBounded` (`:175-200`) validates `total_pages`/`next_free_hint` ranges before resizing and re-asserts page-0 reserved — a model loader.
- **Recovery is fail-closed where it matters (Q2).** Malformed/checksum-invalid WAL records abort recovery for operator inspection (`recovery.zig:171-172`); `selectManifest` errors when both manifests are missing (`manifest.zig:181-186`); manifest deserialize validates magic + CRC before reading the body (`manifest.zig:84-95`); version/UUID mismatches return errors (`recovery.zig:115-133`). The `manifest_a/b ... catch null` (`:111-112`) is safe because `selectManifest` re-imposes the not-both-null invariant.
- **No secret/plaintext exposure (Q5).** `operation_result.zig`, `metrics.zig`, and `errors.zig` emit only counters, enum tag names, booleans, and UUID hex. A repo-wide grep for key/nonce/plaintext/payload in log/print/JSON paths returned nothing. `file_manager.deinit` (`:116-118`) and `PageEncryption.deinit` (`:25-27`) `secureZero` key material (SEC-0045 notes a residual *pager* copy not zeroed).
- **TDE construction is sound in isolation.** AES-256-GCM binds the page header as AAD and stores the tag in a reserved tail; wrong key/page_id/file_id/write_count all fail decryption (encryption.zig tests). The nonce *construction* is correct; the filed SEC-0037 is specifically about the write_count *counter management*, not the primitive.
- **Backup V2 uses HMAC-SHA256 with constant-time compare** (`backup.zig:336` `timing_safe.eql`) and enforces UUID match and size caps; restore filename validation blocks classic traversal (SEC-0002 tests). The residual gaps are ordering (SEC-0038) and symlinks (SEC-NEW-03).
- **Supply chain pinning is good.** `build.zig.zon` pins every dependency by content hash and commit SHA; `uuid`/`thread_pool` use bare immutable commits, `wal`/`otel` pin `ref=vX` + commit (the commit makes the mutable tag irrelevant for fetch integrity). CI verifies the Zig tarball SHA-256 from `ziglang.org/download/index.json` (transit-integrity; the TOFU-on-origin limitation is acknowledged in the threat model).

---

## 6. Coverage Gaps and Questions

- **No dynamic analysis.** All conclusions are static. The UB claims for SEC-NEW-01/02 in `ReleaseFast` are inferred from Zig language semantics, not observed. Recommend running the existing fuzz harness with crafted `shard_manifest.json`, `*.idx`, and `labels.dict` corpora under `ReleaseSafe` to convert these to deterministic panics and confirm the fix.
- **`sharded_recovery.zig` / 2PC reconciliation** was reviewed only at the WAL-read boundary (SEC-0041 is filed). The cross-shard commit/abort state machine's replay-safety and partial-failure behavior were not exhaustively traced — recommend a dedicated pass.
- **`buffer_pool.zig` flush/eviction interaction with TDE write_count** (SEC-0037 root area) was treated as filed; I did not independently re-verify the counter regression at `recovery.zig:221`.
- **Windows/macOS filesystem semantics** for `resolve_beneath`/symlinks are platform-dependent and untested per the contract; the SEC-NEW-03 remediation's effectiveness on those platforms needs verification.
- **`btree.zig`, `index_catalog.zig`, `property_index.zig`, `maintenance.zig`, `migration.zig`** were not deeply parsed for untrusted-input paths in this pass; `migration.zig` is a stub. `index_catalog` persistence (if any on-disk format) merits a follow-up read.
- **Open question not fully answerable from source:** does the deployment actually run `ReleaseFast`, and is any host configured with `vm.overcommit_memory` such that SEC-NEW-02 reaches the OOM killer rather than a clean `error.OutOfMemory`? Both materially affect SEC-NEW-01/02 severity.

---

## 7. Prioritized Next Actions

1. **Fix SEC-NEW-01 (High).** Replace unchecked `std.json.Value` accesses in `shard_manifest.readFromDir` with typed parsing or per-field tag/range guards. Add malformed-JSON regression tests run under `ReleaseSafe`. This is the only High in the newly-found set and sits on the sharded `open()` path with ReleaseFast-UB potential.
2. **Fix SEC-NEW-02 (Medium).** Bound `item_count`/`entry_count` by `payload_size / min_record_size` before every `ensureTotalCapacity` in `engine_index.zig:241`, `property_chain_index.zig:229`, and the `loadHeader` count; back-port the same bound to the filed SEC-0044 (`label_index.zig:211`) for consistency.
3. **Fix SEC-NEW-03 (Medium), coordinated with SEC-0038.** Extract restores to a staging dir, verify CRC+HMAC, then atomically rename; set `exclusive`/`resolve_beneath` on extraction `createFile`. Resolves both the symlink primitive and the parse-then-verify window.
4. **Fix SEC-NEW-04 (Low/Med).** Reject duplicate names/ids in `label_dict.loadFromFile` and verify CRC before committing the rebuilt maps.
5. **Add integrity to `.idx` snapshots (SEC-NEW-05) and apply the `resolve_beneath` hardening (SEC-NEW-06)** as a single defense-in-depth follow-up; CRC/HMAC on snapshots also cheaply enables the SEC-NEW-02 bound check.
6. **Continue the filed-critical track first.** SEC-0037 (nonce reuse, Critical) and the High cluster SEC-0038/0039/0040/0041 remain the top program priorities; the new findings above are additive edge-case hardening, not a re-prioritization of those.
7. **Process:** add a fuzz target per untrusted on-disk artifact (shard manifest, each `.idx`, `labels.dict`, registry, free.store) to the existing `fuzz_regression.zig`, and gate CI to run the parser fuzz corpus under `ReleaseSafe` so future loaders inherit the "validate-before-allocate, verify-before-materialize" contract (CIS v8.1.2: 16.1, 16.6, 16.11).

---

*Defensive review only. No code was executed; no secrets were accessed or disclosed. Findings are evidence-bounded to the cited file:line locations; severities are conditioned on the stated `ReleaseFast` production build and filesystem-write threat model.*
