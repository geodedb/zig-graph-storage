# Sharded Graph Engine — Design Spec

> Status: **draft** · Date: 2026-04-24 · Item 1 of the "dramatic-ingest-perf" pair (pairs with `2026-04-24-per-shard-coordinator-wiring-design.md`)

## Goal

Replace the single-threaded `GraphEngine` in `gitlab.com/devnw/zig/graph-storage` with a **`ShardedGraphEngine`** facade that owns `N=16` independent single-threaded `GraphEngine` instances per logical graph. Operations route by `shardIndex(primary_node_id)`. Cross-shard operations use a small 2-phase protocol. This unlocks genuine N-way writer concurrency per graph while preserving every `GraphEngine`'s existing single-threaded correctness argument.

## Problem statement (measured)

The msft-graph 16-way parallel ingest against the current engine cascades to `40001` serial fallback on hub-node edge files. Root causes the 2026-04-23 session established:

1. **`GraphEngine` is single-threaded by charter.** Manifest counters (`next_node_id += 1` at `engine.zig:588`), auxiliary `std.AutoHashMap` indexes (`label_index`, `label_store`, `label_dict`, `property_chain_index`, `edge_index`), and `WalManager.current_lsn` are non-atomic and racy under concurrent writers.
2. **Attempts to parallelise *above* the engine** (Phase 2 Task 6 `ShardedCoordinator`, `210de668`) produced a **3–4× regression** vs the single-flusher baseline because `ManagedGraph.string_indexes_mutex` was held across the entire `createNodeWithReservedIdAndGraph` / `createEdgeWithGraph` path — N shard threads contended on one mutex per op.
3. **MVCC write-write conflict detection** (`src/transactions/manager.zig:209`) cascades to `40001: SerializationFailure` when two workers commit writes touching the same hub node (e.g. `edges_member_of` concentrates on group nodes). Phase 2.4's writer-preferred lock fix doesn't address this path.

Any design that parallelises writers *above* a shared single-threaded engine fights these constraints. A design that parallelises *inside* the engine (fine-grained locks on manifest / indexes / WAL) has a fraught correctness story against the checkpoint + WAL-before-data invariants. **Sharding the engine itself** sidesteps both.

## Non-goals

- **Not MVCC / snapshot-isolated reads** — readers still see live state per shard; read-only cross-shard consistency is handled by the existing geode-side per-graph rwlock snapshot (and by the parallel `2026-04-24-lock-free-merge-prop-index-snapshot.md` plan). Snapshot isolation across shards is a separate spec.
- **Not migrating single-engine graphs** — per project policy (see `MEMORY.md` "No migration path needed"), users nuke data dirs on upgrade. We ship sharded from day one on a major version bump; old data is incompatible.
- **Not changing the `GraphStorage` vtable shape** consumed by geode. The facade exposes the same interface; only routing and a 2-phase protocol are added.
- **Not adding third-party locking crates.** Only `std.Io.Mutex`, `std.atomic.Value`, and the existing `thread-pool` dependency.
- **Not changing crash-recovery semantics** per-shard. Recovery becomes *parallelisable* (one worker per shard) but each shard's algorithm is unchanged.

## Architecture

### Physical layout

Each logical graph becomes a directory containing N shard sub-directories plus a top-level shard manifest:

```
<data_dir>/
  <graph_uuid>/
    shard_manifest.json       ← new: N, shardIndex algorithm version, per-shard uuids
    shard_00/
      graph.uuid              ← derived: blake3(graph_uuid ++ "shard_00")[..16]
      manifest.a / manifest.b
      nodes.pg / adj_out.pg / adj_in.pg / props.pg / var_store.pg / free.pg
      label_idx.pg / prop_idx.pg / edge_idx.pg
      wal/graph.wal
    shard_01/
      …
    shard_15/
      …
```

Each `shard_XX/` is a complete, self-contained `GraphEngine` directory — the existing `GraphDir` layout unchanged.

### Shard routing

```
shard_of(node_id: u64) -> usize = splitmix64(node_id) % N
shard_of(edge_id: u64) -> usize = shard_of(edge.from_node_id)   // edges co-locate with source
shard_of(label_id: u32) -> usize = label_id % N                  // label dicts are per-shard
```

`splitmix64` reused from `graph_storage/src/sharded_store.zig:shardIndex` (`2dadc13`). Edges pin to their source node's shard so `expandOut` is intra-shard. `expandIn` may cross shards (see Cross-shard ops below).

### ID allocation

Each shard has its own `manifest.next_node_id` / `next_edge_id`. To guarantee globally-unique ids without coordination:

- **Node IDs**: `next_node_id` within shard `s` is `s + k*N` for `k=0,1,2,…`. Shard 0 gets ids `0, 16, 32, …`; shard 1 gets `1, 17, 33, …`. Allocator = `@atomicRmw(.Add, &manifest.next_local, 1, .monotonic) * N + shard_index`. This has the happy property `shard_of(id) == s` for every allocated id.
- **Edge IDs**: Same scheme, shard-striped.
- **Txn IDs**: Shard-striped similarly. A logical transaction crossing shards uses a **coordinator-assigned global_txn_id** (see 2PC below) distinct from local shard txn ids.

### Cross-shard operations

Three classes:

**1. Edge create where source and target are in different shards.**

- Flow: allocate `edge_id` on source shard → write the outgoing adjacency on source shard → write the incoming adjacency on target shard. Two shard writes, both deterministically ordered (source-first). If target shard write fails, source shard rolls back via WAL undo.
- 2PC protocol: the `ShardedGraphEngine` facade issues a `prepare` WAL record on both shards, then a `commit` record on both, then an optional `finalize` to clean up prepare markers. If the process crashes between `prepare` and `commit`, recovery replays the prepare and checks both shards' state to decide commit vs abort (deterministic: if `prepare_source` has a commit record, continue; else abort).
- **Common case**: both endpoints in the same shard (ingest clusters by label). No 2PC path.

**2. `expandIn` — incoming adjacency scan.**

- For a node `v` in shard `s_v`, edges landing on `v` live in `s_v`'s `adj_in.pg` (that's the whole point of having an incoming adjacency store). `expandIn` is **intra-shard** by construction. No fan-out.

**3. Full-graph scans** (`scanNodes`, `expandAll`, global aggregates).

- Fan-out to all N shards, gather iterators, merge. The facade exposes a `FanOutIterator` that multiplexes N shard iterators. No coordination — each shard scan is independent.

### WAL and durability

Each shard has its own WAL file (`shard_XX/wal/graph.wal`). Writes:

- `appendRecord` is always on the local shard WAL — no contention across shards.
- `sync` is per-shard — but the Phase 3 `WalFlusher` design (from `2026-04-24-graph-sharding-and-wal-group-commit.md`) becomes one flusher thread *per shard*, batching within-shard commits. Cross-shard commits issue durability barriers on both shards' flushers; the facade blocks on both `durable` LSNs before acknowledging the commit to the caller.
- **Invariant**: WAL-before-data per shard. Unchanged from current engine.
- **Cross-shard commit durability**: for a 2PC commit, both shards must have the commit record durable before the caller sees success. The facade ensures this via per-shard `WalFlusher.waitDurable(lsn)`.

### Crash recovery

Per-shard recovery runs in parallel: one worker thread per shard replays that shard's WAL into its engine. Cross-shard 2PC records are reconciled in a second pass:

- Each shard's recovery identifies records with `record_type = cross_shard_prepare` / `cross_shard_commit` / `cross_shard_abort` and tags them with `global_txn_id`.
- A final pass (single-threaded, over the union of per-shard decisions) identifies dangling prepares — if any shard committed its half of a global txn, all shards must also commit; otherwise all shards abort.
- Worst case: one shard's recovery can stall briefly on 2PC reconciliation. For ingest workloads with rare cross-shard edges, this is <1% of records.

### Buffer pool

Per-shard — each shard has its own `BufferPool`. Memory is divided: `total_pool_pages / N` per shard. For msft-graph's ingest working set (~50k-entry indexes), this is fine — each shard's working set is 1/N of the total, and per-shard pool sizing matches.

Alternative considered: shared buffer pool with finer-grained locking. Rejected because it reintroduces the contention problem we're sharding to eliminate. Per-shard pool is the simpler correctness argument.

## Public API (the `ShardedGraphEngine` facade)

Preserves the `GraphStorage` vtable exactly. Internally:

```zig
pub const ShardedGraphEngine = struct {
    allocator: std.mem.Allocator,
    graph_uuid: [16]u8,
    graph_dir: GraphDir,
    shards: [SHARD_COUNT]*GraphEngine,
    shard_manifest: ShardManifest,
    coordinator_txn_counter: std.atomic.Value(u64),

    pub fn create(...) !*ShardedGraphEngine { … }
    pub fn open(...) !*ShardedGraphEngine { … }
    pub fn close(self: *ShardedGraphEngine) !void { … }
    pub fn deinit(self: *ShardedGraphEngine) void { … }

    // Vtable-shaped ops (route or fan-out)
    pub fn allocNode(self) !NodeId { … }
    pub fn putNode(self, id, rec) !void { … }
    pub fn getNode(self, id) !?NodeRec { … }
    pub fn createEdge(self, from, to, rel_type, props) !EdgeId { … }
    pub fn expandOutIter(self, id, rel_type) !AdjIterator { … }
    pub fn expandInIter(self, id, rel_type) !AdjIterator { … }
    pub fn scanNodes(self, opts) !FanOutScanIterator { … }
    // … full list in the implementation plan …
};
```

`ShardManifest` on disk is a small JSON file with version, shard count, per-shard uuids, and a hash of the shardIndex algorithm (so a version mismatch is detected at open).

## Shard-count choice

`N = 16`. Rationale:

- Matches msft-graph worker count (target workload).
- Powers of 2 avoid division in hot paths.
- Per-shard BufferPool at `total / 16` is still large enough for our working sets.
- On 32+ core hosts, 16 is a safe floor; 32 is a defensible upgrade once we see contention inside a shard. The `shard_manifest.json` version field lets us expand `N` in future by writing a migration tool. Until then, `N` is a build-time constant in `shard_count.zig`.

## Measurement / success criteria

1. **Unit and integration tests** for `ShardedGraphEngine` (creation, ops, cross-shard edges, crash recovery, scan merging) pass on `zig build test`.
2. **Microbench**: per-shard `allocNode` + `putNode` + `appendRecord` round-trip at ≥ 4× the single-engine throughput on 16 cores. Microbench lives in `graph-storage/benchmarks/sharded_throughput/`.
3. **System-level success** is demonstrated in Item 2's spec (below). This spec's own success bar is "N-way independent writer concurrency verified, correctness under crash recovery proven."

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Cross-shard 2PC bugs — classic distributed-txn correctness pitfalls | Keep 2PC scope tiny: only edge-create-across-shards uses it. Dedicated test file `test_cross_shard_recovery.zig` covering all crash-at-every-step permutations. |
| Per-shard BufferPool fragmentation for skewed workloads | `shardIndex` uses `splitmix64` (already good avalanche). Add per-shard size metrics; alert if max/min shard ratio > 4. |
| Shard-count bake-in makes future N change painful | Accept as a deliberate cost. `shard_manifest.json` records the algorithm version so a future resharding tool can convert. |
| Recovery slower than single-engine for tiny graphs | Per-shard recovery parallelism has fixed per-shard overhead. For graphs < 1000 nodes, single-engine recovery is faster. Acceptable: our target is large ingest workloads. |
| Increased open-file-descriptor count (N× per graph) | Each shard has 9 pg files + 1 WAL file = 10 FDs × 16 shards = 160 FDs per graph. Document `ulimit -n` guidance; most production Linux setups are fine. |

## Implementation plan pointer

The concrete task breakdown (build order, test-first, commit boundaries) is produced by `superpowers:writing-plans` from this spec and lands at `docs/superpowers/plans/2026-04-24-sharded-graph-engine.md`. That plan lives and executes in the `gitlab.com/devnw/zig/graph-storage` repo, then bumps the graph-storage dependency in geode's `build.zig.zon`.

## Open questions (to resolve during plan-writing)

1. **Label dictionary**: per-shard or global? Trade-off — per-shard means label ids diverge across shards (one `User` label can be id 7 in shard 0 and id 2 in shard 5); global means all shards coordinate on label-dict writes. **Recommendation**: per-shard with a common external `label_name → (shard, local_id)` index maintained by the facade. Writes to a new label register on one shard; reads going through the facade translate name → (shard, local_id). Needs confirmation once the enumeration of `label_id`-consuming paths is complete.
2. **`next_txn_id` scheme for cross-shard txns**: use the coordinator's global counter or a Lamport-style `(shard_id, local_ts)` tuple? **Recommendation**: global counter is simpler; contention on the atomic is negligible (one cross-shard txn per edge-across-shards, a minority of ingest).
3. **Checkpoint coordination**: today `Checkpointer.doCheckpoint()` is a whole-engine barrier. Sharded version: either N independent per-shard checkpoints, or a logical "graph checkpoint" that quiesces all shards briefly. **Recommendation**: per-shard checkpoints; the facade's `close()` awaits all N.
