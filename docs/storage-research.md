# Geode Storage, Indexing, and Persistence: Code-First Architecture Review and Enterprise-Grade Redesign

## Executive summary

**Fact (verified in code + docs)**: The current “storage engine” in the repository is primarily an **in-memory graph** implemented with `std.AutoHashMap` for nodes and edges plus in-memory label/adjacency indexes, with durability achieved via **full snapshot rewrites** to a flat file (legacy `graph_store.dat`) or to **per-graph flat files** (one `.dat` per graph UUID) plus a small `graph_registry.dat`. citeturn26view0turn29view0turn30view0turn59view1

**Fact (verified in docs/README)**: The public docs and README describe a **page-based, memory-mapped I/O engine with buffer pool, 8KB slotted pages, page types, and MVCC** as the core storage architecture. citeturn62view0turn61view1turn64view0

**Fact (misalignment)**: The repository code paths that persist graph state (`src/graph_store.zig`) implement neither a pager nor an mmap-based page cache; persistence is implemented as **streaming serialization of hash maps** to a temp file + CRC32 + optional file-level encryption + atomic rename. citeturn29view1turn57view1turn35view2

**Inference**: For high-performance single-graph OLTP workloads, the current design will bottleneck on (a) pointer-chasing + allocator overhead in the hot traversal path, (b) lack of disk-resident, locality-friendly adjacency layout, and (c) snapshot-based write amplification and restart/open time that scale with total graph size rather than working set. This inference follows directly from the in-memory hash-map layout and full-snapshot checkpointing strategy. citeturn26view0turn52view2turn35view3turn37view0

**Recommendation (high-level)**: Move to a **per-graph directory** as the unit of storage and operations, and adopt a realistic enterprise-grade target: a **page store + buffer pool + WAL + incremental checkpointing**, with a **graph-local adjacency access path** (edge blocks / adjacency pages) and carefully-scoped secondary indexes (B+tree/LSM only where they pay). Keep cross-graph querying permanently out-of-scope by construction: no shared physical files or shared logical collections across graphs. citeturn62view0turn51search0turn51search2turn65search4

## Verified current storage and indexing architecture map

### Persisted state: what files/directories make up durable storage

**Fact**: The code currently supports **two persistence modes** for graph state:

1. **Legacy single-file snapshot**:
   - Path is derived from `GEODE_DATA_DIR` (or override) with fallback behavior; the default final filename is `graph_store.dat`. citeturn26view0turn29view1
   - The file header uses magic `"GEODGST1"` and includes counters (`next_node_id`, `next_edge_id`) and counts; the payload is a serialized dump of graphs/nodes/edges, protected by a CRC32 stored in the header. citeturn29view1turn57view1

2. **Per-graph snapshot files + registry**:
   - `graph_registry.dat` in `data_dir` stores `(graph_name -> uuid, node_count, edge_count)` plus global `next_node_id/next_edge_id`, with CRC validation and optional TDE. citeturn30view0turn29view0
   - Individual graph snapshot files are stored under `data_dir/graphs/` and named as `<uuid_v7_string>.dat`. citeturn29view0turn27view3
   - Each per-graph file uses magic `"GEODGRF1"` and includes the expected graph UUID in the header to prevent file-swap attacks; CRC mismatches and UUID mismatches are explicitly tested. citeturn59view1turn27view1

**Fact**: Additional persistence artifacts exist outside the core graph snapshot:

- **WAL log**: `geode_wal.log` in the data directory (or `/tmp` fallback), implemented by `src/wal.zig` as a wrapper around an external library `@import("wal")`. citeturn36view0turn36view3
- **CLI undo-log persistence**: `geode_undo_log.bin` in `GEODE_DATA_DIR` (or `/tmp`) implementing a binary undo log for CLI transaction rollback persistence. citeturn41view0
- **CLI “transaction session” persistence**: `geode_transaction_session.txt` storing transaction session state across CLI invocations. citeturn42view0

**Fact**: File-level encryption (“TDE”) is implemented as **AES-256-GCM with a magic prefix** and key material from `GEODE_TDE_KEY`; storage modules call into this to encrypt/decrypt whole files. citeturn35view2turn30view0

### Data model on disk: nodes, edges, properties, labels, graph catalogs

**Fact**: In the **legacy single-file** snapshot format (`src/graph_store.zig`):

- The payload begins by writing the **graph registry as names** (length-prefixed strings). citeturn57view1
- Each node record includes:
  - `node_id`,
  - label count + each label string,
  - property count + properties (`key` + typed value),
  - `graph_name` string (persisted explicitly). citeturn57view1turn58view1
- Each edge record includes:
  - `edge_id`, `from_id`, `to_id`,
  - `label` string,
  - property count + properties,
  - `graph_name` string. citeturn57view1turn58view1
- Property values are serialized with a `val_type` tag, including `String/Int/Float/Bool/Null/ExtValue/Decimal`. citeturn58view1turn26view0

**Fact**: In the **per-graph** snapshot format:

- Graph identity is implicit from the file itself; `graph_name` is **not stored per node/edge**. citeturn59view1turn29view0
- The per-graph header binds the file to a UUID (`graph_uuid`) and includes node/edge counts and CRC. citeturn59view1turn27view1
- Nodes and edges are serialized similarly (IDs, labels, properties), but without graph_name. citeturn59view1turn29view0

**Fact**: The “graph catalog” (name→uuid mapping) in per-graph mode is the `graph_registry.dat` file, with its own CRC and optional TDE pipeline. citeturn30view0turn29view0

### In-memory storage layout and “indexes”

**Fact**: The active runtime data structure is the global `GraphStore`:

- Nodes and edges stored in `std.AutoHashMap(u64, Node)` and `std.AutoHashMap(u64, Edge)`. citeturn26view0
- `Node` includes `labels: [][]const u8`, `properties: StringHashMap(PropertyValue)`, and `graph_name: []const u8`. citeturn26view0
- `Edge` includes `from_id`, `to_id`, `label: []const u8`, `properties`, and `graph_name`. citeturn26view0

**Fact**: “Indexes” in this storage layer are currently:

- **Label index**: `label_index: StringHashMap(ArrayList(u64))`, with keys formed as a composite `"graph_name:label"` to enforce graph isolation. citeturn26view0turn24view1
- **Adjacency indexes**:
  - `outgoing_edges: AutoHashMap(u64, ArrayList(u64))` mapping node→edge IDs,
  - `incoming_edges: AutoHashMap(u64, ArrayList(u64))`. citeturn26view0turn24view1

**Fact**: The per-graph container `GraphHandle` duplicates the same pattern per graph:

- its own `nodes`, `edges`, `label_index`, `outgoing_edges`, `incoming_edges`, and `rebuildIndexes()` which rebuilds these indexes by scanning node/edge hash maps. citeturn55view0turn55view1

**Fact (important operational detail)**: In per-graph mode, `loadPerGraphFiles()` repopulates the **legacy global maps** (`store.nodes`, `store.edges`) from each `GraphHandle` “for backward compatibility”. That makes per-graph storage not “single source of truth” today—data is duplicated in memory. citeturn29view0turn26view0

### WAL/checkpointing: reality in code

**Fact**: The WAL module defines redo-style logical records: create node/edge, set/remove properties, delete, add/remove labels, etc. citeturn36view0turn36view3
**Fact**: WAL operations are captured via a mutation callback hooked into `GraphStore` (rather than being emitted by the transaction layer). citeturn60view1turn37view1
**Fact**: The mutation callback appends WAL records with **`txn_id = 0`** today, suggesting WAL is not yet integrated with real transaction IDs/commit ordering. citeturn37view1
**Fact**: WAL checkpointing is effectively:

1) `store.saveToFile()` (full snapshot), then
2) `wal.compact()`/truncate up to checkpoint LSN. citeturn36view1turn37view0
**Fact**: Default checkpoint triggers are byte- and time-based thresholds (`16MB`, `60s`) installed as hooks into the store persistence loop. citeturn37view0turn60view5

### Hot query path: MATCH/Expand/IndexSeek to storage reads

**Fact**: For multi-node MATCH scanning, `executeMultiNodeMatch` uses `store.getNodesByLabels(filter_graph, node_pattern.labels)` and then fetches node pointers from `store.nodes`—explicitly noting “label_index for O(1) lookup instead of full scan”. citeturn52view2turn26view0
**Fact**: Other paths still do brute-force scans. For example, `executeMatchCallQuery` iterates `store.nodes.iterator()` and filters by `node.graph_name`, labels, and per-node properties. citeturn54view1turn26view0

**Inference**: The hot traversal (“Expand”) path almost certainly follows the adjacency maps `outgoing_edges`/`incoming_edges` (node→edgeIDs) and then resolves edge records from `store.edges`, because these are the only explicit adjacency accelerators in the storage struct. This is structured O(deg(v)) but memory-random due to hash lookups + per-edge heap allocations. citeturn26view0turn24view1

### Native vs third-party libraries

**Fact**: WAL durability is delegated to an external Zig WAL library (`@import("wal")`), with Geode only providing record serialization and callback integration. citeturn36view0turn36view1
**Fact**: File-level encryption is implemented in-repo (`src/storage/tde_file_encryption.zig`) and is shared across persistent files. citeturn35view2turn30view0

## Verified bottlenecks and design risks

### Doc/README vs code: storage-engine claims appear unimplemented in this repo slice

**Fact**: The official “Storage Engine Architecture” doc claims:

- a page-based architecture,
- 8KB pages,
- slotted-page layout,
- explicit page types,
- a buffer pool and LRU,
- **memory-mapped files** via `std.posix.mmap`. citeturn62view0turn61view1

**Fact**: The repository persistence implementation we inspected is:

- streaming serialization of hash maps to a temp file,
- CRC32 over the payload,
- optional whole-file encryption,
- atomic rename. citeturn29view1turn57view1turn35view2

**Inference**: Either (a) the docs describe a target/future architecture not present in the current code paths, or (b) the page store exists elsewhere but is not on the hot path for graph persistence. In either case, for an enterprise redesign you should treat the docs as an aspirational spec, not as a verified implementation. citeturn62view0turn26view0

### Read amplification and CPU locality issues in the hot path

**Fact**: Nodes, edges, labels, and property keys/values are represented as heap-allocated strings and hash maps (`StringHashMap(PropertyValue)`), and adjacency is maintained as `ArrayList(u64)` lists behind `AutoHashMap(node_id -> list)`. citeturn26view0turn24view1turn55view1

**Inference**: This implies high CPU cache miss rates (pointer chasing among hash buckets, string keys, and variable-length allocations) and allocator overhead under traversal-heavy workloads—especially for degree-skew (“power-law”) graphs where adjacency lists resize frequently. citeturn26view0turn55view1

**Fact**: Some MATCH code paths still scan the entire node map and evaluate predicates per node. citeturn54view1turn26view0
**Inference**: For real OLTP workloads with selective predicates, this will dominate latency unless secondary indexes (property indexes) exist and are used consistently.

### Write amplification, checkpoint cost, and restart/open time

**Fact**: Checkpointing is “snapshot rewrite”: per checkpoint, the store serializes all nodes and edges (and all properties/labels) to a new file. citeturn57view1turn29view1turn36view1

**Fact**: The snapshot pipeline (“compaction”) simply calls `saveToFile()` again after a configurable number of checkpoints—this is a second full rewrite, not page-level vacuum. citeturn35view3turn29view1

**Inference**: For large graphs, this creates **O(|V|+|E|+|P|)** write amplification per checkpoint, producing:

- long checkpoint stalls,
- high disk bandwidth consumption,
- and potentially long exposure windows where WAL grows until checkpoint completes. citeturn36view1turn35view3

### WAL integration risks

**Fact**: WAL records are emitted via a mutation callback mechanism and are logically “redo post-images”. citeturn37view1turn36view0
**Fact**: WAL checkpoint truncation is guarded in per-graph mode: `savePerGraphFiles()` returns an error if any per-graph save fails (“WAL truncation blocked”). citeturn29view0turn36view1
**Fact**: The mutation callback currently appends records with transaction ID 0. citeturn37view1

**Inference**: Without transaction boundaries (begin/commit markers) and durable commit ordering, the WAL is closer to “best-effort redo logging” than a strict ACID durability mechanism. That may still work in a single-writer prototype, but it is a hard blocker for enterprise guarantees under concurrency and crash scenarios.

### Graph isolation: directionally correct, but incomplete operationally

**Fact**: The design encodes `graph_name` into node/edge records and uses composite keys in the label index (e.g., `"graph:label"`) to maintain isolation in memory. citeturn26view0turn24view1turn52view2
**Fact**: The per-graph file layout is graph-isolated on disk (`graphs/<uuid>.dat` and registry mapping). citeturn29view0turn30view0
**Fact**: However, per-graph mode still backfills the global `store.nodes`/`store.edges` for compatibility, so memory remains co-mingled. citeturn29view0turn26view0

**Inference**: This increases risk that some code paths will “forget to filter by graph” and accidentally scan/operate across graphs; it also makes per-graph backup/restore and memory sizing more complex than necessary.

### Encryption and memory spikes

**Fact**: When TDE is enabled, finalization reads the entire plaintext temp file into memory (`readFileAlloc(..., 1 << 30)`) before writing the encrypted output. citeturn57view1turn35view2
**Inference**: This creates large transient memory spikes during checkpointing and can reintroduce OOM behavior for large databases even though serialization itself was changed to “streaming” to avoid OOM. citeturn29view1turn57view1

## Comparative review of relevant database/storage research and production systems

This section focuses on what is directly relevant to Geode’s **single-graph** OLTP target and what it would cost to implement in Zig in this codebase.

### entity["organization","SQLite","embedded relational db"] WAL + pager model

**Fact**: SQLite WAL mode separates the append-only WAL from the main database file and uses checkpointing to transfer committed content back, balancing read/write concurrency and restart behavior. citeturn51search0turn51search4
**Relevance to Geode**: Geode already has a WAL + snapshot scheme, but today the snapshot is “entire graph rewrite”. Emulating the SQLite pattern at a **page/frame** level (not at whole-graph file level) is the shortest path to:

- faster incremental checkpoints,
- bounded restart time,
- and reduced write amplification. citeturn36view1turn62view0
**Complexity in Zig**: Medium. You need a pager abstraction, page headers (LSN + checksum), and “frame” records in WAL; you do not necessarily need full ARIES if you accept a simpler page-frame WAL checkpoint cycle. citeturn62view0turn51search0

### entity["organization","LMDB","mmap btree kv store"] copy-on-write B+tree

**Fact**: MDB/LMDB is a memory-mapped, read-optimized B+tree store using copy-on-write pages and a freelist. citeturn51search1turn51search9
**Relevance to Geode**: LMDB-style COW is excellent for:

- metadata catalogs (small writes, heavy reads),
- schema/index catalogs,
- and potentially some secondary indexes. citeturn51search1turn30view0
**Why it may hurt Geode’s OLTP graph workload**: A property-graph mutation touches adjacency, properties, and secondary indexes. COW B+tree pages can yield high write amplification and single-writer constraints for high-throughput update workloads unless carefully staged. citeturn51search1turn51search9
**Implementation cost**: High if built from scratch in Zig; moderate if used as an embedded dependency (but the requirement here is not “just use LMDB” as the entire engine).

### entity["organization","RocksDB","lsm kv store"] / entity["organization","Pebble","lsm kv store"] LSM for write-optimized components

**Fact**: In classic LSM engines, writes land in a WAL + memtable and later flush/compact into sorted runs, trading write amplification vs read amplification by compaction strategy. citeturn51search10turn51search14turn51search2
**Relevance to Geode**: LSM is usually the wrong default for **primary adjacency traversal**, but can be the right choice for:

- high-update secondary indexes (some property indexes),
- full-text inverted indexes,
- and “append-heavy” analytics event logging. citeturn51search2turn65search2
**Complexity in Zig**: High if you implement a full LSM; moderate if you implement a narrow LSM only for specific index types.

### entity["company","Neo4j","graph database vendor"] record stores and relationship chaining

**Fact**: Neo4j’s documented store formats include fixed-size records and store files; node records reference relationship chains and property records. citeturn65search4turn65search0
**Relevance to Geode**: This directly addresses Geode’s current hottest problems:

- ID→record offset becomes O(1) (no hash map),
- adjacency expansion becomes “follow chain / read blocks” instead of “hash lookup edgeIDs then hash lookup edges”,
- properties moved to a dedicated structure rather than per-node hash maps. citeturn65search4turn26view0
**Complexity in Zig**: Medium-to-high, but tractable because the core is “fixed record files + variable property store + freelist”.

### entity["company","Memgraph","graph database vendor"] durability via snapshots + WAL

**Fact**: Memgraph documents durability as built from snapshots plus WAL; durability files live in `snapshots/` and `wal/` folders in the data directory. citeturn65search2turn65search6
**Relevance to Geode**: Geode’s current approach (WAL + full snapshot) is conceptually similar, but enterprise readiness depends on:

- efficient snapshot cadence,
- bounded restore time,
- and robust transactional WAL semantics. citeturn36view1turn37view1
**Key warning for Geode**: Memgraph-style full snapshots can be acceptable if (a) snapshots are well-managed operationally and (b) WAL replay is fast. In Geode, snapshot rewriting is also being used as “compaction”, which implies unbounded I/O costs as the primary space-reclaim tool. citeturn35view3turn65search6

### entity["organization","WiredTiger","mongodb storage engine"] logging + checkpoints

**Fact**: WiredTiger describes a write-ahead log (optional) used to recover changes since the last checkpoint. citeturn65search3turn65search15
**Relevance to Geode**: The combination “checkpoint + log replay” is the right mental model, but the checkpoint must be incremental (dirty pages) rather than “rewrite everything” to meet enterprise recovery/open-time expectations. citeturn36view1turn62view0

### entity["organization","TigerBeetle","financial ledger database"]: checksum-first engineering

**Fact**: TigerBeetle documents an append-only log approach and describes on-disk state as a collection of LSM trees in its architecture docs. citeturn51search3
**Relevance to Geode**: Two exportable principles:

- aggressive checksumming and corruption detection as a first-class design goal,
- deterministic, testable recovery paths. citeturn51search3turn35view2
**Complexity**: Medium, but mostly in engineering discipline (checksums everywhere, fail-fast), not only in algorithmics.

### entity["organization","Kuzu","graph database system"]: CSR/columnar adjacency for analytical workloads

**Fact**: The CIDR paper for Kùzu discusses a columnar storage model with adjacency stored in columnar structures (CSR-like). citeturn65search5
**Relevance to Geode**: CSR is outstanding for scan-heavy analytics and some bounded traversals, but pure CSR is painful for OLTP updates. The relevant takeaway is not “be CSR”, but:

- represent adjacency in large contiguous regions for locality,
- optionally maintain snapshot adjacency structures for read-mostly phases. citeturn65search5turn26view0

## Ranked redesign options with tradeoffs

Constraints honored explicitly:

- **Cross-graph queries permanently out of scope** (design must not pay costs for cross-graph execution).
- **Storage cleanly separated per graph** (backup/restore/move a graph independently).

### Option A: Least invasive evolution of the current design

**What it is**: Keep the in-memory `GraphStore` API and internal maps for now, but make disk durability enterprise-usable by tightening per-graph isolation and reducing checkpoint pain.

**On-disk layout**

- **Per graph directory** becomes authoritative:
  - `data_dir/graphs/<uuid>/graph.snapshot` (flat snapshot, similar to today’s per-graph `.dat`)
  - `data_dir/graphs/<uuid>/wal/00000001.wal` (segmented WAL)
  - `data_dir/graphs/<uuid>/meta.bin` (superblock: format version, last checkpoint LSN, counters)
- Global:
  - `data_dir/graph_registry.dat` remains name→uuid mapping (existing file format). citeturn30view0turn29view0

**Read/write path**

- Reads: still in-memory (load snapshot at startup).
- Writes: still mutate hash maps, but WAL becomes authoritative for durability:
  - add `BEGIN/COMMIT` markers + real txn_id (stop writing `txn_id=0`). citeturn37view1
  - group WAL sync (fsync batching).
- Checkpoint: still a snapshot rewrite, but now **per graph** and with strict WAL truncation rules already partially present. citeturn29view0turn36view1

**Graph isolation model**

- Remove the “legacy global maps” backfill in per-graph mode. Treat `GraphHandle` as the only in-memory owner to avoid co-mingling and duplication. (Requires refactoring callers that directly hit `store.nodes/edges`.) citeturn29view0turn26view0

**Expected wins**

- Immediate: per-graph portability improves (graph directory = unit of backup/restore).
- WAL durability becomes meaningful once txn boundaries exist.
- Memory reduces by eliminating duplicate global maps. citeturn29view0turn26view0

**Major risks**

- Still fundamentally a memory-resident DB: dataset must fit RAM; open time scales with graph size because snapshot must be read and reconstructed.
- Still full-snapshot write amplification; large graphs will remain painful.
- You still lack a disk-native adjacency layout; OS cache behavior cannot save you. citeturn57view1turn35view3turn62view0

**Migration complexity**

- Medium: largely internal refactors + on-disk directory reshaping.
- Backwards compatibility: maintain a one-time import path from existing `graphs/*.dat` or `graph_store.dat`. citeturn29view0turn29view1

**Why it’s not the best long-term choice**

- It does not address the central performance issue: adjacency and properties are in allocator-heavy heap structures, not cache-efficient record layouts. citeturn26view0turn55view1

### Option B: Medium refactor with highest near-term ROI

**What it is**: Implement the architecture the docs describe—**but for real**—as a per-graph page store with buffer pool, page checksums, WAL, and incremental checkpointing, and move the primary graph representation from hash maps to record/page layouts.

**On-disk layout (concrete)**
Per graph directory: `data_dir/graphs/<uuid>/`

- `manifest.a` / `manifest.b` (two superblocks, atomic switch)
  - format version
  - page size (start with 8192)
  - last_checkpoint_lsn
  - high-water marks for each file
  - root pointers for free map + catalogs
  - checksum
- `nodes.store` (fixed-size node records, addressable by node_id)
- `adj_out.store` (adjacency blocks/pages for outgoing edges)
- `adj_in.store` (adjacency blocks/pages for incoming edges)
- `props.store` (slotted pages for property records)
- `var.store` (variable-length blobs/strings)
- `free.store` (free space bitmap + per-file freelists)
- `wal/00000001.wal` (segmented WAL with rolling)
- `indexes/` (each index is its own file set)
  - `indexes/catalog.bin` (index definitions + root pointers + build state)
  - `indexes/btree_<id>.idx`
  - `indexes/hash_<id>.idx`
  - `indexes/fts_<id>.idx`
  - `indexes/hnsw_<id>.idx`
  - `indexes/rtree_<id>.idx`

Global:

- `graph_registry.dat` stays as the name→uuid mapping store (or becomes a small meta DB later). citeturn30view0

**Record/page shapes (concrete)**
Node record (fixed-size, 32–48 bytes; stored at offset = `node_id * NODE_REC_SIZE`):

```zig
const NodeRec = packed struct {
    out_head: u64,    // pointer to first out-edge block
    in_head:  u64,    // pointer to first in-edge block
    prop_head: u64,   // pointer to first property record / slotted-page handle
    label_set: u32,   // label bitmap/set-id (dictionary-based)
    flags:     u16,   // deleted, has_overflow, etc.
    _pad:      u16,
    // optional MVCC fields:
    begin_ts:  u64,
    end_ts:    u64,   // or txn-id; 0 = infinity
};
```

Adjacency block (stored in `adj_out.store` / `adj_in.store`), optimized for traversal locality:

```zig
const EdgeBlockHdr = packed struct {
    next: u64,        // next block in chain
    count: u16,
    kind:  u16,       // out/in; future: type partition id
    bytes: u32,       // payload bytes
    checksum: u32,    // block-local checksum (optional; page-level also exists)
};

const EdgeEntry = packed struct {
    neighbor: u64,    // to_id for out, from_id for in
    edge_id:  u64,
    rel_type: u32,    // dictionary id; enables type filtering in-block
    prop_head: u64,   // pointer into props.store
};
```

Property storage:

- `props.store` uses **slotted pages** (like the doc describes) for variable-length property entries (typed values + key_id); large strings and blobs go to `var.store`, referenced by pointer. citeturn62view0turn58view1

**Free-space strategy (concrete)**

- Page allocator per file:
  - `free.store` maintains a bitmap of free pages + a small set of “free extent lists” for quick allocation of runs (for adjacency blocks).
- Slotted page free space:
  - each slotted page tracks free-space pointer and slot directory (doc-aligned). citeturn62view0

**WAL record structure (concrete)**
Adopt a page-frame WAL model (SQLite-like mental model, but per-graph):

- WAL segment header:
  - magic, format version, graph_uuid, page_size, checksum
- Record:
  - `lsn (u64)`
  - `txn_id (u64)`
  - `record_type (u16)` (page_update / commit / abort / checkpoint)
  - `page_id (u64)` + `file_id (u16)` + `offset (u16)` (or “full page image”)
  - payload (delta or full frame)
  - `crc32c (u32)`

SQLite’s WAL documents the core idea: append WAL records and checkpoint later. citeturn51search0turn51search4

**Checkpoint cadence (concrete)**

- Trigger when either:
  - WAL bytes since checkpoint exceeds a configurable threshold (start at 256MB, not 16MB), or
  - time since last checkpoint exceeds a target (e.g., 30s–120s), or
  - clean shutdown.
(Geode already has byte/time checkpoint hooks; scale them up for production once incremental checkpoint exists.) citeturn37view0turn51search0

Checkpoint algorithm:

1. Flush dirty pages from buffer pool back to base stores, in LSN order.
2. Atomically write new superblock (`manifest.b` then switch pointer).
3. Truncate WAL segments up to `last_checkpoint_lsn`.

**I/O strategy**

- Default to `pread/pwrite` with an explicit buffer pool (predictable under container/cloud I/O limits).
- Allow optional `mmap` read-only mappings for archived immutable segments or for analytics snapshots, but do not assume mmap is always safe/performance-optimal in enterprise deployments. (This directly addresses the “mmap assumptions” anti-pattern.) citeturn62view0turn61view1

**Graph isolation model**

- A graph is an independent directory: all files belong to exactly one graph UUID.
- `graph_registry.dat` is the only cross-graph structure—and it is just a “name service”, not a query surface. citeturn29view0turn30view0

**Expected wins**

- Node lookup by id becomes O(1) record addressing (no hash map).
- Out/in expansion becomes sequential page reads of adjacency blocks (dramatic reduction in random memory accesses and allocator churn vs `HashMap + ArrayList + HashMap`). citeturn26view0turn55view1turn65search4
- Checkpoint time becomes proportional to dirty working set, not whole graph size.
- Recovery time becomes proportional to WAL since last checkpoint (bounded by policy).

**Major risks**

- Implementing a correct pager/WAL/checkpoint stack is non-trivial and is where systems fail.
- Requires reworking query execution to not assume everything is in-memory pointers. citeturn54view1turn62view0

**Migration complexity**

- Medium-to-high, but manageable with a compatibility layer that reads the old per-graph `.dat` into the new page store via a bulk loader.

**Why this is likely best**

- It matches the product’s stated architecture while making it real, and it directly targets traversal-locality and operational characteristics required for enterprise OLTP. citeturn62view0turn26view0

### Option C: More radical redesign (only if clearly justified)

**What it is**: A hybrid log-structured core where **graph mutations append to segments**, with background compaction producing traversal-optimized adjacency blocks, while metadata and some indexes remain page/B+tree based.

**On-disk layout**

- `segments/seg_000001.log` (append-only mutations, per graph)
- `adj_snapshots/adj_000123.csr` (compacted adjacency snapshot)
- `meta/` (page store for catalogs + freelists)
- `indexes/` (LSM where justified)

**Read/write path**

- Writes are append-only (high throughput).
- Reads consult latest compacted adjacency snapshot + recent delta segments (read amplification risk).

**Why it helps**

- Extremely fast ingest/bulk load and good SSD write patterns, borrowing principles seen in LSM and log-first systems. citeturn51search2turn51search3turn65search19

**Why it’s risky for OLTP graph queries**

- Traversals that touch many nodes will repeatedly merge “base adjacency + deltas,” increasing tail latency unless compaction keeps up.
- Complexity is significantly higher than Option B (you’re building a custom LSM-like system *and* a traversal engine). citeturn51search14turn65search19

**Migration complexity**

- Highest, because it changes mental model and requires new tooling for compaction correctness.

## Recommended target architecture

Recommendation: **Option B** (page store + buffer pool + page-frame WAL + adjacency blocks) with a narrow “Option A” bridge to get there safely.

### Core design goals

1. **Per-graph physical isolation** is non-negotiable: per-graph directory contains *all* durable state needed to move/backup/restore one graph.
2. **Traversal locality is the primary win condition**: adjacency expansion should touch as few cache lines and as few random I/Os as possible.
3. **Enterprise durability** means:
   - page checksums + fail-fast corruption detection,
   - bounded checkpoint and recovery behavior,
   - online backup story,
   - explicit upgrade/migration compatibility.

### How this answers the anti-patterns explicitly

- **One giant shared data file for all graphs**: eliminated by per-graph directory; `graph_registry.dat` is only name→uuid metadata. citeturn29view0turn30view0
- **Graph co-mingling**: eliminated on disk and in memory by removing global `store.nodes/edges` backfill. citeturn29view0turn26view0
- **Random I/O on relationship expansion**: adjacency blocks make expansion mostly sequential; optional partitioning by relationship type can tighten locality further.
- **Secondary indexes that require too many fetches**: indexes should map directly to `node_id` (O(1) node record address) and avoid “index→node pointer chasing”. citeturn65search4turn26view0
- **mmap assumptions**: default to buffer pool + pread; support mmap only in controlled read-mostly contexts. citeturn62view0turn61view1
- **WAL/checkpoint long restart times**: WAL page frames + incremental checkpoint keeps replay bounded like pager-based engines. citeturn51search0turn65search3turn36view1
- **Prototype-easy, evolution-hard formats**: superblock A/B + versioned catalogs allow online upgrade paths and backward compatibility windows.

### Indexing redesign (separate from primary storage)

**Fact**: Current query execution already uses a label index to avoid full scans in some paths. citeturn52view2turn54view1
**Recommendation**: Make indexing “boring and correct” first, then add specialized types as optional plugins.

**Mandatory core indexes (always on)**

- **ID addressing**: if `node_id` is dense, fixed-record addressing replaces the need for an ID index.
- **Label posting lists**: `label_id -> posting list of node_id` (compressed list or roaring bitmap).
- **(Optional) relationship type posting lists**: to accelerate type-constrained expansions.

**Secondary property indexes (opt-in, per graph)**

- Equality + range:
  - B+tree on `(label_id, property_id, value)` → posting list (or `node_id`).
- Why B+tree first:
  - simpler to implement with a pager,
  - predictable read path for point and range lookups. citeturn62view0turn65search4

**Specialized indexes (plugins / separate modules)**

- **Full-text**: inverted index (token→posting list) + BM25; keep update policy configurable (sync vs async). (Geode docs and optimizer already talk in these terms, so align the code to that design.) citeturn62view0turn48view0
- **Vector**: HNSW in its own file; integrate with WAL by logging vector insert/delete operations and supporting rebuild. citeturn64view0
- **Spatial**: R-tree file. citeturn61view1turn64view0

**Index catalog + online build/rebuild**

- Per-graph `indexes/catalog.bin` stores:
  - index id, type, schema (label/property/type), root page, build state, last built LSN, statistics.
- Online build:
  - build index from a consistent snapshot (read checkpoint LSN), then “tail” WAL from that LSN applying changes until caught up, then mark “active”.
This is a standard approach in systems with WAL + checkpoints. citeturn65search3turn51search0

## Migration plan

### Phase 0: Stabilize graph isolation and remove duplicated sources of truth

**Fact**: Per-graph mode currently backfills global maps for compatibility. citeturn29view0turn26view0
**Recommendation**: Introduce a storage abstraction boundary:

- `GraphStorage` interface:
  - `getNode(node_id)`, `scanLabel(label_id)`, `expandOut(node_id, rel_type?)`, `applyMutation(batch)`, etc.
- Route *all* execution code through this interface (stop touching `store.nodes` directly).

Deliverable: “new storage backend can exist without rewriting the planner/executor.”

### Phase 1: Write a bulk loader from existing snapshots into the new page store

Input sources (old):

- `graph_registry.dat` + `graphs/<uuid>.dat`, or legacy `graph_store.dat`. citeturn29view0turn29view1turn30view0

Bulk load algorithm (per graph):

1. Create new graph directory + empty manifest A/B.
2. Allocate node records densely:
   - if old IDs are sparse, either:
     - preserve sparse IDs with an ID→offset map (extra structure), or
     - remap to dense IDs and maintain a logical id mapping table (migration policy choice).
3. Build adjacency blocks from edges by grouping by `from_id` and `to_id`.
4. Load properties into props/var stores using dictionary encoding for keys and labels.
5. Build label posting lists.
6. Optionally build selected indexes offline.
7. Write a checkpoint (manifest update) and set `last_checkpoint_lsn = 0` for the new store.

### Phase 2: Compatibility window and upgrade path

**Recommendation**: Provide a one-release compatibility window:

- On startup:
  - if new store exists: open it.
  - else if old per-graph `.dat` exists: migrate (offline) or open read-only and emit “upgrade required”.
  - else if legacy `graph_store.dat` exists: migrate into per-graph directories.

Operationally, enterprise users prefer explicit upgrade tooling and predictable downtime windows.

### Phase 3: WAL semantics upgrade (must happen before “enterprise” claims are credible)

**Fact**: WAL mutation callback currently logs with `txn_id = 0`. citeturn37view1
**Recommendation**: Integrate WAL with the transaction manager:

- WAL must record `BEGIN(txn_id)`, data records, then `COMMIT(txn_id)` (or include commit markers).
- Recovery must only apply committed transactions after the last checkpoint.
- This also enables online index build (tail WAL).

### Phase 4: Decommission snapshot-as-compaction

**Fact**: Snapshot pipeline uses `saveToFile()` both for checkpoint and “compaction.” citeturn35view3
**Recommendation**: Replace with:

- incremental checkpoints (dirty pages),
- background vacuum for free-space consolidation (optional),
- per-graph compaction only for log-structured index components, not for the core graph store.

## Benchmark plan, success criteria, and open questions

### Benchmark suite design (required operations)

Each benchmark should run in:

- warm cache (after priming buffer pool),
- cold cache (drop page cache / restart process),
- and mixed workload (steady-state).

**Point node lookup by ID**

- `getNode(node_id)` p50/p95/p99
- target: single-digit microseconds warm, sub-millisecond cold for typical page cache sizes (hardware dependent; measure, don’t promise).

**Property lookup via secondary index**

- equality and range on a high-cardinality property
- measure amplification: index pages read + node pages read.

**Outgoing adjacency expansion**

- `expandOut(node_id)` for nodes with:
  - low degree (~10),
  - medium degree (~1k),
  - high degree (~100k).
- include type-filtered expansions.

**Incoming adjacency expansion**

- symmetrical to outgoing.

**Bounded variable-length traversal**

- `KNOWS*1..k` style expansions with `k=2,3,4`
- measure tail latency and memory usage.

**Node/relationship insert/update/delete**

- single inserts
- batched inserts
- property updates (small vs large values)
- deletes (tombstone + reclaim behavior)

**Bulk ingest**

- sustained edges/sec and nodes/sec
- compaction/vacuum impact (if any)

**Checkpoint**

- time, bytes written, impact on foreground p99
- WAL size growth with/without checkpoint

**Crash recovery / WAL replay**

- recovery time as function of WAL size since checkpoint
- verify correctness via checksums and invariants

**Cold start / open**

- time to open graph and execute first query
- memory footprint after open (buffer pool + catalogs only; not whole-graph load)

**Index build / rebuild**

- offline build time
- online build time with concurrent writes
- catch-up time from WAL tail

### Required metrics collection

For every benchmark, record:

- latency p50/p95/p99
- throughput
- read amplification (logical reads vs physical page reads)
- write amplification (logical bytes mutated vs bytes written to disk)
- space amplification (on-disk bytes vs logical graph size)
- page faults
- buffer pool hit rate
- checkpoint duration + bytes written
- startup time + recovery time
- index build time
- file count + size growth per graph
- fragmentation (free space %) and dead space

### Success criteria (enterprise-grade operational characteristics)

A design counts as “enterprise-grade” only if it can demonstrate:

- **Crash safety**: recover to the last committed transaction; detect torn/partial writes via per-page checksums. citeturn65search3turn51search19
- **Corruption detection**: checksums must fail fast and pinpoint file/page, not silently produce wrong results (current CRC32-on-whole-file helps but is too coarse for diagnosis). citeturn30view0turn59view1turn35view2
- **Predictable restart time**: bounded by WAL since checkpoint and by catalog size, not by total graph size. citeturn51search0turn36view1
- **Per-graph portability**: copy a graph directory and restore it elsewhere without dragging unrelated graphs (a current pain point in legacy single-file mode). citeturn29view1turn29view0

### Open questions / code areas needing deeper inspection

Because the repo contains many advanced subsystems, these areas should be validated next (and may change index recommendations):

**Fact**: The docs/README claim a sophisticated index system and MVCC engine. citeturn62view0turn64view0
**Open questions (verification needed in code paths not fully inspected here)**:

- How (and where) are “6 index types” actually integrated into query execution beyond label index usage in `MATCH`? citeturn52view2turn62view0turn64view0
- Does any production path use the MVCC manager in `src/server/txn/mvcc.zig`, or is it currently separate from graph storage mutations? citeturn43view0turn26view0
- What is the real on-disk format and maintenance pipeline for the index persistence modules under `src/index/*_persist.zig` (since TDE explicitly mentions index files as encrypted targets)? citeturn35view2turn61view1turn64view0
- What tests/benchmarks demonstrate storage startup, recovery, traversal expansion, and compaction behavior at scale, and do they reflect disk-resident behavior or only in-memory behavior? (The inspected code shows unit tests for per-graph persistence integrity and CRC/UUID checks, but this is not the same as end-to-end durability under crash.) citeturn27view1turn30view0turn36view1

**One explicitly non-goal reaffirmed**: cross-graph queries must remain out-of-scope, so any future architecture work should avoid shared table spaces, shared posting lists, or cross-graph planner features. The per-graph directory model enforces this mechanically. citeturn29view0turn30view0
