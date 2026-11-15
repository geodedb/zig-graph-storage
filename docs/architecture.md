# Architecture Guide

This document describes the internal architecture of the graph-storage engine,
how its modules connect, how data flows from API calls to disk, and how the
design relates to the requirements in
[storage-requirements.md](storage-requirements.md) and the research in
[storage-research.md](storage-research.md).

---

## Module Dependency Graph

```mermaid
graph TD
    GE["GraphEngine<br/><i>engine.zig</i>"]

    subgraph Storage["Record Stores"]
        NS["NodeStore<br/><i>node_store.zig</i>"]
        AO["AdjStore (out)<br/><i>adj_store.zig</i>"]
        AI["AdjStore (in)<br/><i>adj_store.zig</i>"]
        PS["PropStore<br/><i>prop_store.zig</i>"]
        VS["VarStore<br/><i>var_store.zig</i>"]
        LS["LabelStore<br/><i>label_store.zig</i>"]
        LD["LabelDictionary<br/><i>label_dict.zig</i>"]
    end

    subgraph CacheIO["Buffer Pool & I/O"]
        BP["BufferPool<br/><i>buffer_pool.zig</i>"]
        PF["PageFrame<br/><i>page_frame.zig</i>"]
        FM["FileManager<br/><i>file_manager.zig</i>"]
        PG["Pager ×8<br/><i>pager.zig</i>"]
        GD["GraphDir<br/><i>graph_dir.zig</i>"]
        FSM["FreeSpaceManager ×5<br/><i>free_space.zig</i>"]
    end

    subgraph WALRecovery["WAL & Recovery"]
        WM["WalManager<br/><i>wal.zig</i>"]
        WR["WalRecord<br/><i>wal_record.zig</i>"]
        CK["Checkpointer<br/><i>checkpoint.zig</i>"]
        MN["Manifest<br/><i>manifest.zig</i>"]
        RC["Recovery<br/><i>recovery.zig</i>"]
    end

    subgraph Indexes["Indexing"]
        LI["LabelIndex<br/><i>label_index.zig</i>"]
        PCI["PropertyChainIndex<br/><i>property_chain_index.zig</i>"]
        SNAP["Index Snapshots<br/><i>index_snapshot.zig</i>"]
        BT["BPlusTree Helpers<br/><i>btree.zig</i>"]
    end

    subgraph Txn["Transactions"]
        TM["TxnManager<br/><i>txn.zig</i>"]
    end

    subgraph Security["Security & Integrity"]
        EN["Encryption<br/><i>encryption.zig</i>"]
        VF["Verify<br/><i>verify.zig</i>"]
        IG["Integrity<br/><i>integrity.zig</i>"]
    end

    subgraph Ops["Operations"]
        BK["Backup<br/><i>backup.zig</i>"]
        MT["Maintenance<br/><i>maintenance.zig</i>"]
        MG["Migration<br/><i>migration.zig</i>"]
    end

    ME["Metrics<br/><i>metrics.zig</i>"]

    GE --> NS & AO & AI & PS & VS & LS & LD
    GE --> BP & FM & FSM
    GE --> WM & CK & MN & RC
    GE --> LI & PCI & SNAP
    GE --> TM
    GE --> EN & ME
    GE --> BK & MT & MG

    NS & AO & AI & PS & VS --> BP
    BP --> PF
    BP --> FM
    FM --> PG
    FM --> GD
    PG -.-> EN

    TM --> WM
    WM --> WR
    CK --> BP & FM & MN & WM
    RC --> MN & WM & BP

    PI --> BT
    LI --> LS
```

---

## Data Flow

### Write Path (mutation to durable commit)

```mermaid
sequenceDiagram
    participant App as Application
    participant GE as GraphEngine
    participant TM as TxnManager
    participant WAL as WalManager
    participant Store as Store (Node/Adj/Prop)
    participant BP as BufferPool
    participant PG as Pager
    participant Disk as Disk

    App->>GE: beginTxn()
    GE->>TM: allocate TxnId
    TM->>WAL: append BEGIN record
    WAL->>Disk: write to WAL segment

    App->>GE: putNode(id, rec)
    GE->>Store: write to slot
    Store->>BP: pin(file_id, page_id)
    alt Cache hit
        BP-->>Store: return cached frame
    else Cache miss
        BP->>PG: readPage(page_id)
        PG->>Disk: pread
        PG-->>BP: page data
        BP-->>Store: new frame
    end
    Store->>Store: memcpy record into frame
    Store->>BP: unpin(dirty=true)

    App->>GE: commitTxn(txn_id)
    GE->>TM: mark committed
    TM->>WAL: append COMMIT record
    WAL->>Disk: fsync WAL segment
    Note right of Disk: Transaction is now durable
```

### Checkpoint Path (dirty pages to disk)

```mermaid
sequenceDiagram
    participant GE as GraphEngine
    participant CK as Checkpointer
    participant BP as BufferPool
    participant FM as FileManager
    participant MN as Manifest
    participant WAL as WalManager
    participant Disk as Disk

    GE->>CK: doCheckpoint()
    CK->>CK: record current LSN

    CK->>BP: flushAll()
    loop Each dirty frame
        BP->>FM: writePage(file_id, page_id, data)
        FM->>Disk: pwriteAll at page offset
    end

    CK->>FM: syncAll()
    FM->>Disk: fsync all store files

    CK->>MN: increment counter
    CK->>MN: write to alternate slot (A↔B)
    MN->>Disk: write tmp + fsync + rename

    CK->>WAL: truncate(checkpoint_lsn)
    WAL->>Disk: remove old segments
```

### Read Path (query to page fetch)

```mermaid
sequenceDiagram
    participant App as Application
    participant GE as GraphEngine
    participant Store as Store
    participant BP as BufferPool
    participant PG as Pager
    participant ENC as Encryption
    participant Disk as Disk

    App->>GE: getNode(node_id)
    GE->>Store: resolve page_id + slot from node_id
    Store->>BP: pin(file_id, page_id)

    alt Cache hit
        BP-->>Store: cached frame
    else Cache miss
        BP->>PG: readPage(page_id)
        PG->>Disk: pread(offset = page_id × page_size)
        opt Encryption enabled
            PG->>ENC: decryptPage()
        end
        PG->>PG: verify CRC32C checksum
        PG-->>BP: page data
        BP-->>Store: new frame
    end

    Store->>Store: extract NodeRec from slot offset
    Store-->>GE: NodeRec
    GE-->>App: NodeRec
    Store->>BP: unpin()
```

---

## Recovery Process

Recovery restores the engine to a consistent state after a crash by replaying
committed WAL records from the last checkpoint.

```mermaid
flowchart TD
    A["Engine.open()"] --> B["Read manifest.a and manifest.b"]
    B --> C{"Both valid?"}
    C -->|"Yes"| D["Select manifest with higher counter"]
    C -->|"One valid"| D2["Use the valid one"]
    C -->|"Neither valid"| E["Return NoManifest error"]

    D --> F{"format_version == 2?"}
    D2 --> F
    F -->|"No (v1)"| G["Return version incompatibility error"]
    F -->|"Yes"| H["Open store files via FileManager"]

    H --> I["Initialize BufferPool"]
    I --> J["Open WAL, seek to last_checkpoint_lsn"]
    J --> K["Scan WAL: classify BEGIN/COMMIT/ABORT"]
    K --> L["Build set of committed TxnIds"]
    L --> M["Replay page_update records<br/>for committed transactions only"]
    M --> N{"Decode / checksum error?"}
    N -->|"Yes"| X["Abort open and report WAL failure"]
    N -->|"No"| O["Discard records for<br/>uncommitted transactions"]
    O --> P["Flush BufferPool to disk"]
    P --> Q["Write fresh checkpoint<br/>(new manifest + WAL truncate)"]
    Q --> R["Load or rebuild derived snapshots<br/>(labels.idx / props.idx / edges.idx)"]
    R --> S["Engine ready for queries"]
```

This design satisfies **FR-012** (real transaction IDs with BEGIN/COMMIT/ABORT)
and **FR-013** (incremental checkpointing with bounded recovery).

---

## Buffer Pool

The buffer pool is the central caching layer between stores and disk I/O.

```mermaid
graph TB
    subgraph BufferPool
        PT["Page Table<br/>HashMap(file_id+page_id → frame_idx)"]
        Frames["Frame Array<br/>contiguous 4KB-aligned allocation"]
        LRU["LRU List<br/>doubly-linked (head ↔ tail)"]
        FL["Free List<br/>unused frame indices"]
        MTX["Mutex<br/>thread-safe pin/unpin"]
    end

    subgraph Frame["PageFrame"]
        Data["data: [page_size]u8"]
        Meta["file_id, page_id<br/>pin_count, dirty flag<br/>lru_prev, lru_next"]
    end

    Pin["pin(file_id, page_id)"] --> PT
    PT -->|"hit"| Frames
    PT -->|"miss"| Evict["Evict LRU frame<br/>(flush if dirty)"]
    Evict --> Load["Load page from Pager"]
    Load --> Frames

    Unpin["unpin(frame_idx, dirty)"] --> LRU
```

**Key properties:**

- Pin/unpin reference counting prevents eviction of in-use pages
- Dirty flag tracks frames needing write-back at checkpoint
- LRU eviction ensures the working set stays in memory
- Auto-sizing: buffer pool can scale from manifest page counts (1024--65536 frames)

---

## Adjacency Storage

Edges are stored in **adjacency blocks** -- one chain for outgoing edges, one
for incoming edges. Each node's `out_head` / `in_head` points to its first
block.

```mermaid
graph LR
    Node["NodeRec<br/>out_head=PageA"]

    subgraph BlockA["Adjacency Block (Page A)"]
        HA["EdgeBlockHeader<br/>count=339, next=PageB"]
        E1["EdgeEntry[0]"]
        E2["EdgeEntry[1]"]
        EN["EdgeEntry[338]"]
    end

    subgraph BlockB["Overflow Block (Page B)"]
        HB["EdgeBlockHeader<br/>count=42, next=0"]
        F1["EdgeEntry[0]"]
        F2["EdgeEntry[41]"]
    end

    Node -->|"out_head"| HA
    HA --> E1 --> E2 --> EN
    HA -->|"next_block"| HB
    HB --> F1 --> F2
```

**Capacity:** `(page_size - 32 - 16) / 24` entries per block.
At 8KB pages: **339 entries per block**.

New edges are **head-inserted** for O(1) addition. Relationship-type filtering
reads `rel_type` per entry without materializing unrelated edges, satisfying
**FR-008**.

---

## Property Storage

Properties use a **slotted-page** layout with TLV (tag-length-value) encoding.

```mermaid
graph TD
    subgraph PropPage["Property Page"]
        PH["PageHeader (32B)"]
        NP["next_page: u64 (overflow chain)"]
        EC["entry_count: u32"]
        subgraph Entries["Variable-length entries"]
            E1["key_len(u16) + key + TLV value"]
            E2["key_len(u16) + key + TLV value"]
            E3["..."]
        end
    end

    subgraph TLV["TLV Encoding"]
        T0["0x00: null (1B)"]
        T1["0x01: bool (2B)"]
        T2["0x02: int i64 (9B)"]
        T3["0x03: float f64 (9B)"]
        T4["0x04: string u32_len + data"]
        T5["0x05: decimal i128 + scale (18B)"]
        T6["0x06: ext type_tag + len + data"]
    end
```

Large values that don't fit in a property page spill to **VarStore** overflow
pages, which chain via `next_page` pointers. This satisfies **FR-009**.

---

## Transaction Lifecycle

```mermaid
stateDiagram-v2
    [*] --> Active: beginTxn()
    Active --> Active: read / write operations
    Active --> Committed: commitTxn()
    Active --> Aborted: abortTxn()
    Committed --> [*]
    Aborted --> [*]

    state Committed {
        [*] --> WAL_COMMIT: append COMMIT record
        WAL_COMMIT --> Durable: fsync WAL
    }

    state Aborted {
        [*] --> WAL_ABORT: append ABORT record
        WAL_ABORT --> Discarded: recovery ignores
    }
```

---

## Checkpoint & Manifest A/B Switching

The manifest uses a double-copy strategy for crash-safe metadata updates.

```mermaid
sequenceDiagram
    participant CK as Checkpointer
    participant MA as manifest.a
    participant MB as manifest.b

    Note over MA,MB: Startup: read both, select higher counter

    CK->>CK: Checkpoint #1 (counter=1)
    CK->>MA: write manifest (counter=1)

    CK->>CK: Checkpoint #2 (counter=2)
    CK->>MB: write manifest (counter=2)

    CK->>CK: Checkpoint #3 (counter=3)
    CK->>MA: write manifest (counter=3)

    Note over MA,MB: If crash during write to MA,<br/>MB (counter=2) is still valid
```

Each manifest write is atomic: write to `.tmp`, `fsync`, then `rename`.
This satisfies **FR-005**.

---

## Encryption Flow

When an encryption key is configured, page I/O is transparently encrypted.

```mermaid
flowchart LR
    subgraph Write["Write Path"]
        WP["Page data"] --> WE["AES-256-GCM<br/>encrypt"] --> WC["Compute<br/>checksum"] --> WD["Write to disk"]
    end

    subgraph Read["Read Path"]
        RD["Read from disk"] --> RC["Verify<br/>checksum"] --> RE["AES-256-GCM<br/>decrypt"] --> RP["Page data"]
    end
```

- Per-page encryption (not whole-file)
- The side files holding schema names or indexed values (`labels.dict`,
  `props.idx`, `ordered_propidx.snap`, `props.catalog`, `propidx_*.btree`)
  are sealed whole with a key derived from the same key (SONNY-6590,
  `docs/format-spec.md` §1.6); id-only snapshots stay plaintext
- Key provided via `GraphConfig.encryption_key`
- `GraphConfig.zeroKey()` securely clears key material
- Backup format v2 adds HMAC-SHA256 authentication

---

## Backup Format

```mermaid
graph TD
    subgraph Backup["Backup Archive"]
        H["Header (26B)<br/>magic: GEOB<br/>version: 1 or 2<br/>graph_uuid<br/>file_count"]
        F1["File Entry 1<br/>filename_len + filename<br/>file_size + file_data"]
        F2["File Entry 2"]
        FN["File Entry N"]
        CRC["CRC32C (4B)<br/>over header + entries"]
        HMAC["HMAC-SHA256 (32B)<br/>v2 only, requires key"]
    end

    H --> F1 --> F2 --> FN --> CRC --> HMAC
```

**Included files:** manifest.a, manifest.b, nodes.store, adj_out.store,
adj_in.store, props.store, var.store, free.store, labels.dict, and
optionally indexes/catalog.bin.

---

## Indexing

### Label Index

In-memory posting lists mapping `LabelId` to sorted `[]NodeId`. Rebuilt from
the node store on startup. Snapshots are persisted to `labels.idx` at
checkpoint boundaries for faster warm restarts. Used by `scanLabel()` for
label-based node lookups.

### PropertyChainIndex

In-memory hash index that maps `(key_hash, value_hash)` pairs to sorted
`[]NodeId` lists. Built by scanning the property store on startup. Used for
fast exact-match property lookups without requiring a B+tree on disk.
Snapshots are persisted to `props.idx` at checkpoint boundaries for faster
warm restarts.

### Experimental Secondary-Index Modules

`property_index.zig`, `index_catalog.zig`, and `btree.zig` remain available as
standalone building blocks, but they are not part of the current
`GraphEngine.open()` / query / checkpoint hot path. The live runtime topology
uses `LabelIndex`, `PropertyChainIndex`, and persisted snapshot files instead.

---

## Relationship to Design Documents

| Module | Requirements | Research Reference |
|--------|-------------|-------------------|
| Per-graph directory layout | FR-001 (graph isolation) | storage-research.md §"Graph isolation" |
| Manifest A/B switching | FR-005 (versioned manifests) | storage-research.md §"WAL/checkpointing" |
| BufferPool + Pager | FR-006 (buffer pool, explicit I/O) | storage-research.md §"SQLite WAL + pager model" |
| NodeStore (fixed records) | FR-007 (fixed-record node store) | storage-research.md §"Read amplification" |
| AdjStore (edge blocks) | FR-008 (locality-friendly adjacency) | storage-research.md §"Hot query path" |
| PropStore (slotted pages) | FR-009 (slotted property store) | storage-research.md §"Data model on disk" |
| FreeSpaceManager | FR-010 (free-space management) | storage-research.md §"Write amplification" |
| WalManager (segmented WAL) | FR-011 (segmented WAL per graph) | storage-research.md §"WAL integration risks" |
| TxnManager (real txn IDs) | FR-012 (transaction boundaries) | storage-research.md §"WAL integration risks" |
| Checkpointer (incremental) | FR-013 (incremental checkpoint) | storage-research.md §"Checkpoint cost" |
| LabelIndex + PropertyChainIndex + snapshot persistence | FR-018+ (index support) | storage-research.md §"LMDB COW B+tree" |

---

## Concurrency Model

The current engine uses a **single-writer** model:

- **BufferPool mutex** guards frame table and LRU list (thread-safe pin/unpin)
- **TxnManager mutex** guards transaction ID allocation
- **WAL** provides serialization point for transaction ordering
- Readers can run concurrently via buffer pool caching
- Application is responsible for write serialization

Multi-writer support and full MVCC are reserved for future work (see
`txn_stamp` field in NodeRec).

---

## Type Reference

| Type | Zig Type | Size | Description |
|------|----------|------|-------------|
| `NodeId` | u64 | 8B | Node identifier |
| `EdgeId` | u64 | 8B | Edge identifier |
| `PageId` | u64 | 8B | Page identifier |
| `SlotId` | u16 | 2B | Slot within a page |
| `LabelId` | u32 | 4B | Label / relationship type |
| `TxnId` | u64 | 8B | Transaction identifier |
| `Lsn` | u64 | 8B | Log Sequence Number |
| `GraphUuid` | [16]u8 | 16B | 128-bit graph UUID |
| `NodeRec` | extern struct | 48B | Node record (v2) |
| `EdgeEntry` | extern struct | 24B | Edge adjacency entry |
| `EdgeBlockHeader` | extern struct | 16B | Adjacency block header |
| `PageHeader` | extern struct | 32B | Page header |
| `PropertyValue` | tagged union | varies | null/bool/int/float/string/decimal/ext |
