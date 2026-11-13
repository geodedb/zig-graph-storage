# Binary Format Specification

> Graph Storage Engine -- On-Disk and Wire Format Reference
>
> Source of truth: `src/*.zig` in this repository.
> All multi-byte integers are **little-endian** unless stated otherwise.
> Checksums use **CRC32C** (iSCSI variant, polynomial 0x1EDC6F41) via
> `std.hash.crc.Crc32Iscsi`.

---

## 1. Page Format

**Source:** `src/page.zig`

Every data file is divided into fixed-size pages. The default page size is
**8192 bytes** (`DEFAULT_PAGE_SIZE`). Each page begins with a 32-byte header
(`PAGE_HEADER_SIZE = 32`).

### 1.1 PageHeader (32 bytes, `extern struct`)

| Offset | Size | Field        | Type   | Description                                      |
|--------|------|--------------|--------|--------------------------------------------------|
| 0      | 8    | `page_id`    | u64    | Unique page identifier within the file            |
| 8      | 8    | `lsn`        | u64    | Log Sequence Number of the last write             |
| 16     | 4    | `checksum`   | u32    | CRC32C over the page body (bytes after header)    |
| 20     | 1    | `page_type`  | u8     | PageType enum value (see below)                   |
| 21     | 1    | `flags`      | u8     | PageFlags packed bit field                        |
| 22     | 2    | `item_count` | u16    | Number of items stored in this page               |
| 24     | 2    | `free_start` | u16    | Start of free space (slotted pages)               |
| 26     | 2    | `free_end`   | u16    | End of free space (slotted pages)                 |
| 28     | 3    | `write_count`| u24 LE | Per-page AES-GCM nonce counter (encrypted mode)   |
| 31     | 1    | `_reserved`  | [1]u8  | Reserved padding, must be zero                    |

**Compile-time assertion:** `@sizeOf(PageHeader) == 32`.

### 1.2 PageType Enum (u8)

| Value | Name             | Description                          |
|-------|------------------|--------------------------------------|
| 0     | `free`           | Unallocated / available page         |
| 1     | `node_data`      | Fixed-size node records              |
| 2     | `adj_block`      | Adjacency edge block                 |
| 3     | `prop_slotted`   | Slotted property storage             |
| 4     | `var_overflow`    | Variable-length overflow data        |
| 5     | `free_bitmap`    | Free space bitmap metadata           |
| 6     | `label_posting`  | Label posting list index page        |
| 7     | `btree_internal` | B-tree internal node                 |
| 8     | `btree_leaf`     | B-tree leaf node                     |
| 9     | `manifest`       | Manifest data page                   |

### 1.3 PageFlags (packed u8)

| Bit | Name        | Description                       |
|-----|-------------|-----------------------------------|
| 0   | `dirty`     | Page has uncommitted modifications|
| 1   | `encrypted` | On disk only: header-tag AES-GCM envelope (§1.5) |
| 2   | `compressed`| Page body is compressed           |
| 3-7 | `_reserved` | Reserved, must be zero            |

### 1.4 Checksum Computation

```text
checksum = CRC32C(page_body)
```

Where `page_body` is all bytes from offset 32 to `page_size - 1` (i.e., the
entire page excluding the header). Computed via `std.hash.crc.Crc32Iscsi.hash()`.
Plaintext mode only. A page whose 32 header bytes are all zero is a page that
was never written only if its body is zero too (or, in plaintext mode, its
body's CRC32C is 0); otherwise the read fails.

### 1.5 Encrypted Pages (AES-256-GCM)

With `GraphConfig.encryption_key` set, the pager encrypts every page it
writes. The nonce is `page_id (u64 LE) | file_id (u8) | write_count (u24 LE)`,
taken from the pager and the header's `write_count` (offset 28, u24 LE, plain
text, incremented on every write). The CRC32C is not used.

Current envelope (`flags.encrypted` = 1):

| Bytes       | Content                                               |
|-------------|-------------------------------------------------------|
| 0..16       | AES-GCM tag (replaces `page_id`/`lsn`, which no store uses) |
| 16..32      | Rest of the header, plain text: additional authenticated data |
| 32..page end| The whole page body, encrypted                        |

The pager zeroes bytes 0..16 and clears `flags.encrypted` when it reads a page
into memory, so a cached page never carries the envelope.

Legacy envelope (`flags.encrypted` = 0, written before SONNY-6441): the AAD is
the whole 32-byte header and the tag occupies the LAST 16 body bytes; whatever
a layout stored there was never persisted. These pages stay readable (their
last 16 body bytes read as zero) and move to the current envelope on their
next write. A binary that only knows the legacy envelope fails to
authenticate current-envelope pages (`error.DecryptionFailed`).

What the legacy tail held, per store (SONNY-6461). Prop, var and slab
adjacency blocks reserve the tail (`tail_reserve`), so they lost nothing.

| Store | Page size | Lost |
|-------|-----------|------|
| `nodes` | 8 KiB | slot 169 of 170: `label_count`, `flags`, `_pad`, `txn_stamp` |
| `nodes` | 4, 16, 32, 64 KiB | nothing (records end at or before the tail) |
| `adj_in_dir` | every size | the last two heads of each page |
| v1 chain block (24 B) | 8 KiB, 32 KiB | last slot of a full block (338 / 1362): entry bytes 16..24, `rel_type` and `prop_head` |
| v2 chain block (32 B) | every size | nothing (a full block ends exactly at the tail) |
| v3 chain block (40 B) | 4 KiB, 64 KiB | last slot of a full block (100 / 1636): bytes 32..40, high half of `prop_head` |
| v3 chain block (40 B) | 32 KiB | last slot of a full block (817): bytes 24..40, `public_id` and high half of `prop_head` |

`edge.legacyTailLoss(page_size, entry_format)` computes the adjacency rows.
`neighbor` and `edge_id` are never lost, and every edge is stored in both
directions (`adj_out` and `in_idx`, or `adj_in` for edges written by the
legacy `addEdge` path), so `GraphEngine.repairAdjTailEntries` restores a lost
entry from its other-direction copy and reports the entries it cannot
restore. A node delete is recorded only in `NodeRec.flags` (there is no other
durable record of it), so whether a damaged 8 KiB slot-169 node had been
deleted cannot be derived from the store.

---

## 2. Node Record

**Source:** `src/node.zig`

Node records are stored in pages of type `node_data` (PageType = 1).
Records are packed contiguously after the 32-byte page header with no
inter-record gaps.

### 2.1 NodeRec (40 bytes, `extern struct`)

| Offset | Size | Field       | Type | Description                                        |
|--------|------|-------------|------|----------------------------------------------------|
| 0      | 8    | `out_head`  | u64  | PageId of first outgoing adjacency block (0 = none)|
| 8      | 8    | `in_head`   | u64  | PageId of first incoming adjacency block (0 = none)|
| 16     | 8    | `prop_head` | u64  | Property page/slot reference                       |
| 24     | 4    | `label_set` | u32  | Label bitmap or dictionary reference (LabelId)     |
| 28     | 2    | `flags`     | u16  | Bit field (see below)                              |
| 30     | 2    | `_pad`      | u16  | Alignment padding, must be zero                    |
| 32     | 8    | `txn_stamp` | u64  | Transaction stamp (creation TxnId, MVCC reserved)  |

**Compile-time assertion:** `@sizeOf(NodeRec) == 40`.

### 2.2 Node Flags (u16 bit field)

| Bit  | Constant               | Value  | Description                      |
|------|------------------------|--------|----------------------------------|
| 0    | `NODE_FLAG_DELETED`    | 0x0001 | Node is logically deleted        |
| 1    | `NODE_FLAG_HAS_OVERFLOW`| 0x0002| Node has overflow data           |
| 2-15 | --                     | --     | Reserved                         |

### 2.3 Nodes Per Page

```text
nodes_per_page = (page_size - 32) / 40
```

For the default 8192-byte page: `(8192 - 32) / 40 = 204` nodes per page.

An all-zero 40-byte record indicates an unallocated (empty) slot.

---

## 3. Edge Entry

**Source:** `src/edge.zig`

Edge records are stored in pages of type `adj_block` (PageType = 2).
Each adjacency block page contains an `EdgeBlockHeader` followed by a
contiguous array of `EdgeEntry` records.

### 3.1 EdgeEntry (24 bytes, `extern struct`)

| Offset | Size | Field      | Type | Description                                    |
|--------|------|------------|------|------------------------------------------------|
| 0      | 8    | `neighbor` | u64  | Target (or source) node ID                     |
| 8      | 8    | `edge_id`  | u64  | Unique edge identifier                         |
| 16     | 4    | `rel_type` | u32  | Relationship type (LabelId)                    |
| 20     | 4    | `prop_head`| u32  | Property page/slot reference (lower 32 bits)   |

**Compile-time assertion:** `@sizeOf(EdgeEntry) == 24`.

### 3.2 EdgeBlockHeader (16 bytes, `extern struct`)

| Offset | Size | Field          | Type | Description                                |
|--------|------|----------------|------|--------------------------------------------|
| 0      | 8    | `next_block`   | u64  | PageId of next overflow block (0 = none)   |
| 8      | 2    | `count`        | u16  | Number of entries in this block             |
| 10     | 1    | `kind`         | u8   | Block kind: 0 = mixed, 1 = single rel_type |
| 11     | 1    | `_reserved`    | u8   | Reserved, must be zero                     |
| 12     | 2    | `payload_size` | u16  | Used bytes in the payload area             |
| 14     | 2    | `checksum`     | u16  | CRC16 integrity check over entry data      |

**Compile-time assertion:** `@sizeOf(EdgeBlockHeader) == 16`.

### 3.3 Adjacency Block Page Layout

```text
+--------------------+  offset 0
| PageHeader (32 B)  |
+--------------------+  offset 32
| EdgeBlockHeader    |
|   (16 B)           |
+--------------------+  offset 48
| EdgeEntry[0] (24B) |
| EdgeEntry[1] (24B) |
| ...                |
| EdgeEntry[N-1]     |
+--------------------+
| (unused space)     |
+--------------------+  offset page_size
```

### 3.4 Entries Per Block

```text
entries_per_block = (page_size - 32 - 16) / 24
```

For the default 8192-byte page: `(8192 - 32 - 16) / 24 = 339` entries per block.

---

## 3.5 Property Page Layout

**Source:** `src/prop_store.zig`

Property pages use page type `prop_slotted` (PageType = 3). Each page stores
a sequential list of property entries with an optional per-page key directory
for O(1) lookup.

### 3.5.1 Page Structure

```text
+---------------------+  offset 0
| PageHeader (32 B)   |
+---------------------+  offset 32
| next_page (8 B)     |  u64 LE -- pointer to overflow property page (0 = none)
| entry_count (4 B)   |  u32 LE -- number of property entries on this page
+---------------------+  offset 44 (PROP_DATA_OFFSET)
| Entry[0]            |
| Entry[1]            |
| ...                 |
| Entry[N-1]          |
+---------------------+
| (free space)        |
+---------------------+
| DirEntry[M-1] (4 B) |  ← directory grows backward
| ...                 |
| DirEntry[0] (4 B)  |
+---------------------+  offset page_size - tail_reserve - 2
| dir_count (2 B)     |  u16 LE -- number of directory entries
+---------------------+  offset page_size - tail_reserve
| (reserved)          |  tail_reserve bytes (encrypted mode only; 0 in plaintext)
+---------------------+  offset page_size
```

**Encrypted-mode tail reservation (`tail_reserve`):** When at-rest encryption
is enabled (`GraphConfig.encryption_key != null`), `PropStore` reserves
`tail_reserve` bytes at the physical end of every property page, where the
legacy envelope (§1.5) stored the AES-GCM tag. The current envelope keeps the
tag in the header, but the reservation stays part of the encrypted layout
because existing stores' directories sit at that offset. The slotted-page
directory (`dir_count` footer and all `DirEntry` records) therefore grows
backward from the **logical** page end at `page_size - tail_reserve`, not
from the physical end. In plaintext mode `tail_reserve == 0` and the layout
collapses to the diagram as written, preserving full backward compatibility.
The constant is sourced from `src/prop_store.zig` (`PropStore.tail_reserve`).

### 3.5.2 Property Entry (variable length)

| Offset | Size    | Field       | Type   | Description                   |
|--------|---------|-------------|--------|-------------------------------|
| 0      | 2       | `key_len`   | u16 LE | Length of property key string |
| 2      | key_len | `key`       | [N]u8  | Property key name (UTF-8)    |
| 2+N    | varies  | `value`     | bytes  | Encoded property value (see Section 4) |

**Value overflow (tag 7).** An entry must fit within a single page's entry
budget (`page_size - PROP_DATA_OFFSET - dir_count footer - one directory
entry - tail_reserve`). When the encoded value alone pushes the entry past
that budget, the value is written to a **legacy var-store page chain** and the
entry's `value` field holds a fixed **13-byte overflow stub** instead:

| Offset | Size | Field         | Type   | Description                                    |
|--------|------|---------------|--------|------------------------------------------------|
| 0      | 1    | `tag`         | u8     | `7` (`Tag.overflow`)                            |
| 1      | 4    | `encoded_len` | u32 LE | Length of the ORIGINAL encoded value            |
| 5      | 8    | `var_ref`     | u64 LE | Var-store ref (`first_page << 16`) of the chain |

Notes:

- The stub is **fixed size**, so every entry-walking routine skips exactly 13
  bytes; the value's true length never affects on-page layout.
- The overflow chain is always the **legacy** var-store layout, never a slab
  run (a slab head could not be freed without tombstoning a slot in a block
  shared with the label store).
- `encoded_len` is deliberately redundant with the chain. Readers cross-check
  the resolved chain length against it and report `DataCorruption` on any
  mismatch rather than decoding a plausible wrong value.
- The stub is resolved by the prop-store read path (`getProperty`,
  `getSlabProperty`, and both `PropIterator` paths) **before** decoding, so a
  decoder never observes tag 7. Property indexes therefore hash the real
  encoded value, identically to an inline one.
- A single value's encoded size is capped by
  `GraphConfig.max_property_value_bytes` (1 MiB default); larger values are
  rejected with `PropertyValueTooLarge`.
- Overflow entries are written into slab-packed blobs as readily as legacy
  chain pages; the 13-byte stub is just an ordinary value to the placement
  logic, and a slab→legacy migration copies it verbatim (the chain is
  untouched and the ref stays valid).

### 3.5.3 Per-Page Key Directory (PERF-0023)

The key directory is an optimization structure stored at the end of each
property page, growing backward from the `dir_count` footer. It enables
O(1) property lookup by key hash instead of O(n) linear scan.

**Directory entry (4 bytes):**

| Offset | Size | Field        | Type   | Description                          |
|--------|------|--------------|--------|--------------------------------------|
| 0      | 2    | `key_hash`   | u16 LE | FNV-1a hash of the key, truncated to 16 bits |
| 2      | 2    | `entry_offset` | u16 LE | Byte offset of the entry from page start |

**dir_count (2 bytes):** stored in the last 2 bytes of the page as u16 LE.

- When `dir_count > 0`: the directory is present and authoritative. Lookups
  hash the search key and scan the directory for matching hashes, then verify
  the actual key at the stored offset to handle collisions.
- When `dir_count == 0`: the page is in legacy format (no directory). Lookups
  fall back to linear scan of all entries.

The directory is rebuilt on every insert, replace, and remove operation.
Entry data grows forward from `PROP_DATA_OFFSET`; directory entries grow
backward from the `dir_count` footer. If the two regions would overlap,
the directory is disabled (`dir_count = 0`) and the page reverts to
linear-scan mode.

**Hash function:** FNV-1a with 32-bit state, truncated to u16:

```text
h = 2166136261
for each byte b in key:
    h ^= b
    h *= 16777619
return h[15:0]
```

---

## 4. Property Encoding

**Source:** `src/property.zig`

Properties are encoded as a tag-length-value (TLV) stream. Each encoded
property value begins with a 1-byte tag indicating the type, followed by
type-specific payload bytes. All multi-byte numeric values within property
encoding are **little-endian**.

### 4.1 Tag Enum (u8)

| Value | Name      | Description                 |
|-------|-----------|-----------------------------|
| 0     | `null`    | Null / no value             |
| 1     | `bool`    | Boolean                     |
| 2     | `int`     | 64-bit signed integer       |
| 3     | `float`   | 64-bit IEEE 754 float       |
| 4     | `string`  | Variable-length UTF-8 string|
| 5     | `decimal` | Fixed-point decimal         |
| 6     | `ext`     | Extension / opaque binary   |
| 7     | `overflow`| Overflow stub — the value lives in a var-store chain (see Section 3.5.2) |

Tag 7 is **not a `PropertyValue` variant**: it never appears in an encoded
value, only in a property *entry* whose value was spilled. Both decoders
(`decode`, `decodeView`) reject it with `UnresolvedOverflowValue`, because
reaching a decoder with an unresolved stub means the prop-store read path was
bypassed.

**Compatibility.** Tag 7 is a pure format ADDITION:

- A store that never writes an oversized value contains no tag-7 entry and is
  **byte-identical** to the pre-overflow layout. Such stores open unchanged on
  any reader, old or new.
- There is **no manifest/format-version bump** (`format_version` stays 4) — the
  same precedent as GAP-0060's wide adjacency entries: readers discriminate on
  the data itself, and a store only contains the new shape if it was written
  with the new feature.
- A reader built before tag 7 existed refuses it cleanly: the byte is not a
  member of its `Tag` enum, so `decode`/`decodeView`/`encodedSizeFromBytes`
  return `InvalidFormat` / `InvalidData`. It is a loud refusal at the single
  affected property, never a misparse or an out-of-bounds read.

### 4.2 Encoding Formats

#### null (1 byte)

| Offset | Size | Content    |
|--------|------|------------|
| 0      | 1    | Tag = 0x00 |

Total: **1 byte**.

#### bool (2 bytes)

| Offset | Size | Content                     |
|--------|------|-----------------------------|
| 0      | 1    | Tag = 0x01                  |
| 1      | 1    | 0x00 = false, 0x01 = true   |

Total: **2 bytes**.

#### int (9 bytes)

| Offset | Size | Content                      |
|--------|------|------------------------------|
| 0      | 1    | Tag = 0x02                   |
| 1      | 8    | i64, little-endian           |

Total: **9 bytes**.

#### float (9 bytes)

| Offset | Size | Content                      |
|--------|------|------------------------------|
| 0      | 1    | Tag = 0x03                   |
| 1      | 8    | f64, IEEE 754, little-endian |

Total: **9 bytes**.

#### string (1 + 4 + N bytes)

| Offset | Size | Content                  |
|--------|------|--------------------------|
| 0      | 1    | Tag = 0x04               |
| 1      | 4    | Length N as u32 LE       |
| 5      | N    | UTF-8 string data        |

Total: **5 + N bytes**.

#### decimal (18 bytes)

| Offset | Size | Content                          |
|--------|------|----------------------------------|
| 0      | 1    | Tag = 0x05                       |
| 1      | 16   | Coefficient as i128, little-endian|
| 17     | 1    | Scale (u8): number of decimal places|

Total: **18 bytes**.

The represented value is `coeff * 10^(-scale)`.

#### ext (1 + 2 + 4 + N bytes)

| Offset | Size | Content                   |
|--------|------|---------------------------|
| 0      | 1    | Tag = 0x06                |
| 1      | 2    | type_tag as u16 LE        |
| 3      | 4    | Data length N as u32 LE   |
| 7      | N    | Opaque binary data        |

Total: **7 + N bytes**.

---

## 5. Manifest Format

**Source:** `src/manifest.zig`

The manifest stores graph-level metadata and counters. Two copies are
maintained on disk (`manifest.a` and `manifest.b`) using an A/B switching
strategy for crash-safe updates.

### 5.1 Constants

| Name               | Value                        |
|--------------------|------------------------------|
| `MANIFEST_MAGIC`   | `GEOMNF01` (8 bytes ASCII)   |
| `MANIFEST_VERSION` | 1 (u32)                      |
| `FIELD_SIZE`       | 148 bytes                    |
| `SERIALIZED_SIZE`  | 160 bytes (8 + 148 + 4)      |

### 5.2 Serialized Layout (160 bytes)

| Offset | Size | Field                  | Type    | Description                              |
|--------|------|------------------------|---------|------------------------------------------|
| 0      | 8    | magic                  | [8]u8   | `GEOMNF01`                               |
| 8      | 4    | `format_version`       | u32 LE  | Currently 1                              |
| 12     | 16   | `graph_uuid`           | [16]u8  | Graph UUID (128-bit)                     |
| 28     | 4    | `page_size`            | u32 LE  | Page size in bytes (default 8192)        |
| 32     | 8    | `counter`              | u64 LE  | Monotonic counter for A/B selection      |
| 40     | 8    | `last_checkpoint_lsn`  | u64 LE  | LSN of last completed checkpoint         |
| 48     | 8    | `node_high_water`      | u64 LE  | Highest allocated node page              |
| 56     | 8    | `edge_high_water`      | u64 LE  | Highest allocated edge page              |
| 64     | 8    | `next_node_id`         | u64 LE  | Next node ID to allocate                 |
| 72     | 8    | `next_edge_id`         | u64 LE  | Next edge ID to allocate                 |
| 80     | 8    | `next_txn_id`          | u64 LE  | Next transaction ID to allocate          |
| 88     | 4    | `label_count`          | u32 LE  | Number of distinct labels                |
| 92     | 8    | `nodes_pages`          | u64 LE  | Total pages in nodes store               |
| 100    | 8    | `adj_out_pages`        | u64 LE  | Total pages in outgoing adjacency store  |
| 108    | 8    | `adj_in_pages`         | u64 LE  | Total pages in incoming adjacency store  |
| 116    | 8    | `props_pages`          | u64 LE  | Total pages in property store            |
| 124    | 8    | `var_pages`            | u64 LE  | Total pages in variable-length store     |
| 132    | 8    | `free_pages`           | u64 LE  | Total free pages across all stores       |
| 140    | 8    | `node_count`           | u64 LE  | Total number of nodes in the graph       |
| 148    | 8    | `edge_count`           | u64 LE  | Total number of edges in the graph       |
| 156    | 4    | checksum               | u32 LE  | CRC32C over bytes [0..156)              |

### 5.3 Integrity

The CRC32C checksum at offset 156 covers all preceding bytes (magic through
the last field). On deserialization, the stored CRC is compared against a
freshly computed CRC over `data[0 .. SERIALIZED_SIZE - 4]`.

### 5.4 A/B Switching Strategy

Two files are maintained: `manifest.a` and `manifest.b`. On each checkpoint:

1. The `counter` field is incremented.
2. The manifest is serialized to a temporary file (`.tmp` suffix).
3. The temporary file is `fsync`-ed.
4. An atomic `rename` replaces the target manifest file.
5. The next checkpoint writes to the other file (alternating a/b).

On startup, both files are read. The manifest with the **higher `counter`**
value is selected. If one file is missing or corrupt, the other is used.
If both are missing, a `NoManifest` error is returned.

---

## 6. Backup Format

**Source:** `src/backup.zig`

Backups are self-contained archives of a single graph's data files.

### 6.1 Constants

| Name                 | Value                     |
|----------------------|---------------------------|
| `BACKUP_MAGIC`       | `GEOB` (4 bytes ASCII)    |
| `BACKUP_VERSION`     | 1 (u16) -- CRC32 only     |
| `BACKUP_VERSION_HMAC`| 2 (u16) -- CRC32 + HMAC   |

### 6.2 File Layout

```text
+-----------------------------+  offset 0
| Header (26 bytes)           |
+-----------------------------+
| File Entry 0                |
| File Entry 1                |
| ...                         |
| File Entry N-1              |
+-----------------------------+
| CRC32 (4 bytes)             |
+-----------------------------+
| HMAC-SHA256 (32 bytes)      |  <-- version 2 only
+-----------------------------+
```

### 6.3 Header (26 bytes)

| Offset | Size | Field         | Type   | Description                        |
|--------|------|---------------|--------|------------------------------------|
| 0      | 4    | magic         | [4]u8  | `GEOB`                            |
| 4      | 2    | version       | u16 LE | 1 (CRC only) or 2 (CRC + HMAC)   |
| 6      | 16   | `graph_uuid`  | [16]u8 | UUID of the backed-up graph       |
| 22     | 4    | `file_count`  | u32 LE | Number of file entries that follow|

### 6.4 File Entry (variable length)

Each file entry is serialized as:

| Offset       | Size       | Field          | Type   | Description                   |
|--------------|------------|----------------|--------|-------------------------------|
| 0            | 2          | `filename_len` | u16 LE | Length of the filename string  |
| 2            | filename_len| `filename`    | [N]u8  | Filename (e.g., `nodes.store`)|
| 2+N          | 8          | `file_size`    | u64 LE | Size of the file data in bytes|
| 10+N         | file_size  | `file_data`    | bytes  | Raw file contents             |

### 6.5 Backed-Up Files

Required files (always included if present):

- `manifest.a`, `manifest.b`
- `nodes.store`, `adj_out.store`, `adj_in.store`
- `props.store`, `var.store`, `free.store`
- `labels.dict`

Optional files (included if present):

- `labels.idx`, `props.idx`, `edges.idx`

### 6.6 Integrity: Version 1 (CRC32)

A 4-byte CRC32C checksum follows the last file entry, covering all preceding
bytes (header + all file entries).

Version 1 archives remain readable for validation, but restore is disabled by
default. Restoring a V1 archive requires both:

1. An authoritative expected graph UUID supplied by the caller.
2. An explicit compatibility opt-in (`enableLegacyV1Restore()`).

### 6.7 Integrity: Version 2 (CRC32 + HMAC-SHA256)

When an encryption key is provided, the backup uses version 2:

1. The CRC32C (4 bytes) is appended as in version 1.
2. An **HMAC-SHA256** tag (32 bytes) is appended, computed over all preceding
   bytes (header + file entries + CRC32) using the 32-byte encryption key.

The HMAC provides authenticated integrity -- a backup cannot be tampered with
without knowledge of the key.

Version 2 restore requires the HMAC key. Without it, restore fails rather than
falling back to CRC-only verification.

---

## 7. WAL Record Format

**Source:** `src/wal_record.zig`

The Write-Ahead Log (WAL) stores a sequential stream of records. Each record
has a fixed 30-byte header, a variable-length payload, and a 4-byte checksum
trailer.

### 7.1 Constants

| Name              | Value |
|-------------------|-------|
| `HEADER_SIZE`     | 30    |
| `CHECKSUM_SIZE`   | 4     |
| `MIN_RECORD_SIZE` | 34    |

### 7.2 WalRecordType Enum (u8)

| Value | Name                | Description                          |
|-------|---------------------|--------------------------------------|
| 1     | `page_update`       | Page data modification               |
| 2     | `begin_txn`         | Transaction begin marker             |
| 3     | `commit_txn`        | Transaction commit marker            |
| 4     | `abort_txn`         | Transaction abort/rollback marker    |
| 5     | `checkpoint_marker` | Checkpoint boundary marker           |

### 7.3 Record Layout

| Offset           | Size         | Field          | Type   | Description                       |
|------------------|--------------|----------------|--------|-----------------------------------|
| 0                | 8            | `lsn`          | u64 LE | Log Sequence Number               |
| 8                | 8            | `txn_id`       | u64 LE | Transaction identifier            |
| 16               | 1            | `record_type`  | u8     | WalRecordType enum value          |
| 17               | 1            | `file_id`      | u8     | Target file identifier (FileId)   |
| 18               | 8            | `page_id`      | u64 LE | Target page identifier            |
| 26               | 4            | `payload_len`  | u32 LE | Length of the payload in bytes     |
| 30               | payload_len  | payload        | bytes  | Record-type-specific data         |
| 30 + payload_len | 4            | `checksum`     | u32 LE | CRC32C over header + payload      |

**Total size:** `34 + payload_len` bytes.

### 7.4 Checksum Computation

The CRC32C checksum is computed incrementally over the serialized header fields
and payload, **excluding** the checksum itself:

```text
CRC32C(
    lsn[8] ||
    txn_id[8] ||
    record_type[1] ||
    file_id[1] ||
    page_id[8] ||
    payload_len[4] ||
    payload[payload_len]
)
```

### 7.5 FileId Enum (u8)

Used by WAL records and other subsystems to identify store files:

| Value | Name        | File              |
|-------|-------------|-------------------|
| 0     | `nodes`     | `nodes.store`     |
| 1     | `adj_out`   | `adj_out.store`   |
| 2     | `adj_in`    | `adj_in.store`    |
| 3     | `props`     | `props.store`     |
| 4     | `var_store` | `var.store`       |
| 5     | `free`      | `free.store`      |
| 6     | `label_idx` | Label index       |
| 7     | `prop_idx`  | Property index    |

---

## 8. Registry Format

**Source:** `src/registry.zig`

The graph registry is a catalog of all graphs managed by the storage engine.

### 8.1 Constants

| Name               | Value                        |
|--------------------|------------------------------|
| `REGISTRY_MAGIC`   | `GEODREG1` (8 bytes ASCII)   |
| `REGISTRY_VERSION` | 1 (u32)                      |

### 8.2 File Layout

```text
+-----------------------------+  offset 0
| Header (40 bytes)           |
+-----------------------------+
| Entry 0                     |
| Entry 1                     |
| ...                         |
| Entry N-1                   |
+-----------------------------+
| CRC32 (4 bytes)             |
+-----------------------------+
```

### 8.3 Header (40 bytes)

| Offset | Size | Field           | Type   | Description                        |
|--------|------|-----------------|---------|------------------------------------|
| 0      | 8    | magic           | [8]u8  | `GEODREG1`                        |
| 8      | 4    | version         | u32 LE | Currently 1                       |
| 12     | 4    | reserved        | u32 LE | Reserved, must be 0               |
| 16     | 8    | `next_node_id`  | u64 LE | Global next node ID               |
| 24     | 8    | `next_edge_id`  | u64 LE | Global next edge ID               |
| 32     | 8    | `graph_count`   | u64 LE | Number of graph entries            |

### 8.4 Entry (variable length)

Each graph entry is serialized as:

| Offset  | Size     | Field         | Type   | Description                     |
|---------|----------|---------------|--------|---------------------------------|
| 0       | 4        | `name_len`    | u32 LE | Length of graph name            |
| 4       | name_len | `name`        | [N]u8  | Graph name (UTF-8)             |
| 4+N     | 16       | `uuid`        | [16]u8 | Graph UUID (128-bit)           |
| 20+N    | 8        | `node_count`  | u64 LE | Number of nodes in this graph  |
| 28+N    | 8        | `edge_count`  | u64 LE | Number of edges in this graph  |

### 8.5 Integrity

The CRC32C (4 bytes) at the end of the file covers all preceding bytes
(header + all entry data). Write is atomic via `write-to-tmp + fsync + rename`.

---

## 9. Index Catalog Format

**Source:** `src/index_catalog.zig`

The index catalog persists definitions of all secondary indexes.

### 9.1 IndexType Enum (u8)

| Value | Name              | Description                       |
|-------|-------------------|-----------------------------------|
| 0     | `btree_property`  | B-tree index on a property key    |
| 1     | `label_posting`   | Posting list index on a label     |

### 9.2 IndexState Enum (u8)

| Value | Name       | Description                          |
|-------|------------|--------------------------------------|
| 0     | `building` | Index is being constructed           |
| 1     | `active`   | Index is ready for queries           |
| 2     | `inactive` | Index is disabled                    |
| 3     | `failed`   | Index build failed                   |

### 9.3 File Layout

```text
+-----------------------------+  offset 0
| entry_count (4 bytes)       |
+-----------------------------+
| Entry 0                     |
| Entry 1                     |
| ...                         |
| Entry N-1                   |
+-----------------------------+
```

**Note:** The index catalog file does not include a magic number, version
field, or trailing checksum.

### 9.4 Entry (variable length)

| Offset  | Size    | Field          | Type   | Description                     |
|---------|---------|----------------|--------|---------------------------------|
| 0       | 4       | `entry_count`  | u32 LE | Total number of entries (file header only) |

Each entry:

| Offset  | Size    | Field          | Type   | Description                     |
|---------|---------|----------------|--------|---------------------------------|
| 0       | 4       | `label_id`     | u32 LE | Label this index applies to     |
| 4       | 1       | `index_type`   | u8     | IndexType enum value            |
| 5       | 1       | `state`        | u8     | IndexState enum value           |
| 6       | 2       | `key_len`      | u16 LE | Length of property key string   |
| 8       | key_len | `property_key` | [N]u8  | Property key name (UTF-8)       |

---

## 10. Free Space Bitmap

**Source:** `src/free_space.zig`

Free space tracking uses an **in-memory `DynamicBitSet`** (from the Zig
standard library). The bitmap is not directly persisted as a binary file
format -- it is rebuilt from store files on startup.

### 10.1 Design

- The bitmap has one bit per page. Bit set = page is allocated; bit unset =
  page is free.
- **Page 0 is always reserved** (bitmap metadata page) and is never freed.
- The initial capacity is **64 pages**. When all pages are exhausted, the
  bitmap doubles in size automatically.
- A `next_free_hint` cursor (initially 1) enables amortized O(1) allocation
  by remembering where the last allocation stopped.

### 10.2 Allocation Strategy

1. Scan forward from `next_free_hint` to the end of the bitmap.
2. If no free page is found, wrap around from page 1 to `next_free_hint`.
3. If still no free page, double the bitmap capacity and allocate from the
   newly available range.
4. When a page is freed and its index is before `next_free_hint`, the hint
   is moved back to enable immediate reuse.

---

## 11. Common Type Aliases

**Source:** `src/types.zig`

| Alias       | Zig Type | Size    | Description                    |
|-------------|----------|---------|--------------------------------|
| `NodeId`    | u64      | 8 bytes | Node identifier                |
| `EdgeId`    | u64      | 8 bytes | Edge identifier                |
| `PageId`    | u64      | 8 bytes | Page identifier                |
| `SlotId`    | u16      | 2 bytes | Slot within a slotted page     |
| `Lsn`       | u64      | 8 bytes | Log Sequence Number            |
| `TxnId`     | u64      | 8 bytes | Transaction identifier         |
| `LabelId`   | u32      | 4 bytes | Label / relationship type ID   |
| `GraphUuid` | [16]u8   | 16 bytes| 128-bit graph UUID             |

---

## Appendix A: Endianness and Alignment

- All serialized integers use **little-endian** byte order.
- `extern struct` layouts use C ABI alignment rules. The Zig compiler
  enforces exact sizes via `comptime` assertions.
- Deserialization functions use `std.mem.bytesToValue` or `std.mem.littleToNative`
  for alignment-safe reading from arbitrary byte offsets.

## Appendix B: Checksum Summary

| Format          | Algorithm   | Coverage                                      |
|-----------------|-------------|-----------------------------------------------|
| Page            | CRC32C      | Page body (all bytes after the 32-byte header) |
| Manifest        | CRC32C      | All bytes before the 4-byte checksum trailer   |
| Backup (v1)     | CRC32C      | Header + all file entries                      |
| Backup (v2)     | CRC32C + HMAC-SHA256 | CRC over header+entries; HMAC over header+entries+CRC |
| WAL Record      | CRC32C      | Header fields + payload (excludes checksum)    |
| Registry        | CRC32C      | All bytes before the 4-byte checksum trailer   |
| Edge Block      | CRC16       | Entry data within the block                    |
| Index Catalog   | None        | No checksum                                    |
