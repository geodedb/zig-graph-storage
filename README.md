# graph-storage

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.15.1+-orange.svg)](https://ziglang.org/)

A high-performance, disk-resident graph storage engine written in Zig. Designed
for single-graph OLTP workloads with crash-safe durability, incremental
checkpointing, and locality-friendly adjacency traversal.

## Architecture Overview

```mermaid
graph TB
    App["Application / Query Engine"]

    subgraph GraphEngine["GraphEngine (engine.zig)"]
        direction TB
        API["GraphStorage Interface<br/>getNode · putNode · expandOut · expandIn<br/>addEdge · getProperty · putProperty<br/>addLabel · scanLabel · beginTxn · commitTxn"]

        subgraph Stores["Record Stores"]
            NS["NodeStore<br/>nodes.store<br/>48B fixed records"]
            AO["AdjStore (out)<br/>adj_out.store<br/>24B edge entries"]
            AI["AdjStore (in)<br/>adj_in.store<br/>24B edge entries"]
            PS["PropStore<br/>props.store<br/>TLV slotted pages"]
            VS["VarStore<br/>var.store<br/>overflow data"]
            LS["LabelStore<br/>labels.dict<br/>LabelId ↔ string"]
        end

        subgraph Caching["Buffer Pool & Paging"]
            BP["BufferPool<br/>LRU page cache<br/>pin/unpin + dirty tracking"]
            FM["FileManager<br/>8 Pagers (one per FileId)"]
            FS["FreeSpaceManager<br/>bitmap per store"]
        end

        subgraph Durability["WAL & Checkpointing"]
            WAL["WalManager<br/>append-only log<br/>page_update · begin · commit · abort"]
            CK["Checkpointer<br/>flush dirty pages<br/>A/B manifest switch"]
            MF["Manifest<br/>manifest.a / manifest.b<br/>160-byte metadata"]
            REC["Recovery<br/>replay committed txns<br/>from last checkpoint LSN"]
        end

        subgraph Indexing["Indexes"]
            LI["LabelIndex<br/>LabelId → sorted NodeId[]"]
            PI["PropertyIndex<br/>B+tree on hash(value)"]
            IC["IndexCatalog<br/>persistent index metadata"]
        end

        TXN["TxnManager<br/>begin / commit / abort"]
        ENC["Encryption<br/>AES-256-CTR per page"]
        MET["Metrics<br/>counters & histograms"]
    end

    App --> API
    API --> NS & AO & AI & PS & VS
    NS & AO & AI & PS & VS --> BP
    BP --> FM
    FM -->|"read/write pages"| Disk["Disk Files"]
    API --> TXN
    TXN --> WAL
    WAL --> Disk
    CK --> BP & FM & MF
    MF --> Disk
    REC --> WAL & BP
    API --> LI & PI
    FM -.->|"optional"| ENC
```

## Data Model

The engine stores a **labeled property graph** where nodes and edges carry
key-value properties and zero or more labels.

```mermaid
erDiagram
    NODE {
        u64 node_id PK
        u64 out_head "→ first outgoing adj block"
        u64 in_head "→ first incoming adj block"
        u64 prop_head "→ property chain"
        u64 label_head "→ label block in var.store"
        u16 label_count
        u16 flags "DELETED | HAS_OVERFLOW"
        u64 txn_stamp "creation TxnId"
    }

    EDGE_ENTRY {
        u64 edge_id PK
        u64 neighbor "target or source NodeId"
        u32 rel_type "LabelId"
        u32 prop_head "→ property chain"
    }

    PROPERTY {
        string key
        PropertyValue value "null|bool|int|float|string|decimal|ext"
    }

    LABEL {
        u32 label_id PK
        string name "UTF-8 label string"
    }

    NODE ||--o{ EDGE_ENTRY : "out_head / in_head"
    NODE ||--o{ PROPERTY : "prop_head"
    NODE ||--o{ LABEL : "label_head"
    EDGE_ENTRY ||--o{ PROPERTY : "prop_head"
    EDGE_ENTRY }o--|| LABEL : "rel_type"
```

## Write Path

```mermaid
sequenceDiagram
    participant App as Application
    participant Eng as GraphEngine
    participant Txn as TxnManager
    participant WAL as WalManager
    participant Store as NodeStore/AdjStore
    participant BP as BufferPool
    participant Pager as Pager
    participant Disk as Disk

    App->>Eng: beginTxn()
    Eng->>Txn: allocate TxnId
    Txn->>WAL: append BEGIN record

    App->>Eng: putNode(id, rec)
    Eng->>Store: write record
    Store->>BP: pin(file_id, page_id)
    BP-->>Store: page frame (cache hit or disk read)
    Store->>Store: memcpy into frame slot
    Store->>BP: unpin(dirty=true)

    App->>Eng: commitTxn(txn_id)
    Eng->>Txn: commit
    Txn->>WAL: append COMMIT record
    WAL->>Disk: fsync WAL segment

    Note over BP,Disk: Later: checkpoint trigger
    Eng->>BP: flushAll() dirty pages
    BP->>Pager: writePage() per dirty frame
    Pager->>Disk: pwriteAll()
    Eng->>Disk: write manifest (A/B switch)
    Eng->>WAL: truncate up to checkpoint LSN
```

## Crash Recovery

```mermaid
flowchart TD
    Start["Engine.open()"] --> ReadManifest["Read manifest.a & manifest.b"]
    ReadManifest --> SelectManifest{"Select higher counter<br/>(skip corrupt)"}
    SelectManifest -->|"Both corrupt"| Fail["Return NoManifest error"]
    SelectManifest -->|"Valid manifest found"| CheckVersion{"format_version == 2?"}
    CheckVersion -->|"v1"| MigrationError["Return version error<br/>(requires recreation)"]
    CheckVersion -->|"v2"| OpenFiles["Open all store files<br/>via FileManager"]
    OpenFiles --> ReadWAL["Read WAL from<br/>last_checkpoint_lsn"]
    ReadWAL --> ClassifyTxn["Classify transactions<br/>BEGIN/COMMIT/ABORT"]
    ClassifyTxn --> Replay["Replay committed<br/>page_update records"]
    Replay --> DiscardUncommitted["Discard uncommitted<br/>transaction data"]
    DiscardUncommitted --> FlushBP["Flush buffer pool"]
    FlushBP --> FreshCheckpoint["Write fresh checkpoint<br/>(new baseline)"]
    FreshCheckpoint --> RebuildIndexes["Rebuild label index<br/>from LabelStore"]
    RebuildIndexes --> Ready["Engine ready"]
```

## On-Disk Layout

```mermaid
graph LR
    subgraph DataDir["data/graphs/<uuid_hex>/"]
        MA["manifest.a<br/>160 bytes"]
        MB["manifest.b<br/>160 bytes"]
        NS["nodes.store<br/>fixed 48B records"]
        AO["adj_out.store<br/>edge blocks"]
        AI["adj_in.store<br/>edge blocks"]
        PS["props.store<br/>slotted TLV pages"]
        VS["var.store<br/>overflow pages"]
        LD["labels.dict<br/>LabelId ↔ name"]
        WAL["graph.wal/<br/>segment-0, segment-1, ..."]
    end
```

### Page Format (all stores)

```
┌──────────────────────────────────────────┐
│  PageHeader (32 bytes)                   │
│  ┌─────────┬─────────┬──────┬──────────┐ │
│  │page_id  │  lsn    │crc32c│page_type │ │
│  │  (u64)  │ (u64)   │(u32) │  (u8)    │ │
│  ├─────────┴─────────┴──────┴──────────┤ │
│  │flags(u8)│item_count│free_start/end  │ │
│  │         │  (u16)   │   (u16/u16)    │ │
│  └─────────┴──────────┴───────────────┘ │
├──────────────────────────────────────────┤
│  Page Body (page_size - 32 bytes)        │
│  (store-specific layout)                 │
└──────────────────────────────────────────┘
```

## Features

- **Page-Based Storage**: 8KB pages with CRC32C integrity, LRU buffer pool
- **WAL Durability**: Write-ahead logging with real transaction boundaries (BEGIN/COMMIT/ABORT)
- **Crash Recovery**: Replay committed transactions from last checkpoint LSN
- **Incremental Checkpointing**: Flush only dirty pages, A/B manifest switching
- **Locality-Friendly Adjacency**: Edge blocks with 339 entries per page, overflow chaining
- **Typed Properties**: TLV encoding for null, bool, int, float, string, decimal, ext
- **Label Dictionary**: Bidirectional LabelId-to-string mapping, persisted to `labels.dict`
- **Secondary Indexes**: Label posting lists, optional B+tree property indexes
- **Optional Encryption**: AES-256-CTR per-page encryption with key zeroization
- **Authenticated Backup**: Self-contained archives with CRC32C + optional HMAC-SHA256
- **Free Space Reuse**: Bitmap-based page allocation with O(1) amortized alloc
- **Minimal Dependencies**: Only [wal](https://gitlab.com/devnw/zig/wal) and [uuid](https://gitlab.com/devnw/zig/uuid)
- **Cross-Platform**: Linux, macOS, Windows support

## Installation

### Using Zig Package Manager

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .graph_storage = .{
        .url = "https://gitlab.com/devnw/zig/graph_storage/-/archive/v0.1.0/graph_storage-v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const graph_storage = b.dependency("graph_storage", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("graph_storage", graph_storage.module("graph_storage"));
```

## Quick Start

```zig
const std = @import("std");
const gs = @import("graph_storage");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const graph_uuid = [_]u8{0} ** 16; // use a real UUID in production
    const cfg = gs.GraphConfig{};

    // Create a new graph (or use GraphEngine.open() for an existing one)
    const engine = try gs.GraphEngine.create(allocator, "data", graph_uuid, cfg);
    defer engine.close() catch {};

    // Allocate a node and add a label
    const node_id = try engine.allocNode();
    const label_id = engine.labelDict().getOrAssign("Person");
    try engine.addLabel(node_id, label_id);

    // Set a property
    _ = try engine.putProperty(node_id, "name", .{ .string = "Alice" });

    // Add an edge
    const other = try engine.allocNode();
    const knows = engine.labelDict().getOrAssign("KNOWS");
    _ = try engine.addEdge(node_id, other, knows);

    // Traverse outgoing edges
    var iter = try engine.expandOut(node_id, null);
    defer iter.deinit();
    while (try iter.next()) |entry| {
        std.debug.print("edge {} -> neighbor {}\n", .{ entry.edge_id, entry.neighbor });
    }

    // Checkpoint to persist
    try engine.checkpoint();
}
```

## Configuration

```zig
const cfg = gs.GraphConfig{
    .page_size = 8192,                          // bytes per page
    .buffer_pool_pages = 1024,                  // frames in LRU cache
    .buffer_pool_auto_size = true,              // auto-size from manifest
    .wal_segment_size = 16 * 1024 * 1024,       // 16 MB WAL segments
    .checkpoint_byte_threshold = 16 * 1024 * 1024, // checkpoint after 16 MB WAL
    .checkpoint_time_threshold_ms = 60_000,     // checkpoint every 60s
    .encryption_key = null,                     // optional 32-byte AES key
};
```

## Requirements

- Zig 0.15.1 or later

## Building

```bash
# Build the library
make build

# Run tests
make test

# Quick development iteration
make dev

# Full CI pipeline
make ci
```

## Documentation

See the [docs](docs/) directory for detailed documentation:

- **[Architecture Guide](docs/architecture.md)** -- Module structure, data flow, concurrency
- **[Binary Format Specification](docs/format-spec.md)** -- On-disk page/record layouts
- **[Storage Requirements](docs/storage-requirements.md)** -- Functional requirements (FR-001 through FR-030+)
- **[Storage Research](docs/storage-research.md)** -- Design rationale, bottleneck analysis, prior-art review

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Security

See [SECURITY.md](SECURITY.md) for security policy and vulnerability reporting.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.
