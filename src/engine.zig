// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const builtin = @import("builtin");
const tp = @import("thread_pool");
const observability = @import("observability");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const config_mod = @import("config.zig");
const interface_mod = @import("interface.zig");
const manifest_mod = @import("manifest.zig");
const graph_dir_mod = @import("graph_dir.zig");
const file_manager_mod = @import("file_manager.zig");
const buffer_pool_mod = @import("buffer_pool.zig");
const wal_mod = @import("wal.zig");
const txn_mod = @import("txn.zig");
const node_store_mod = @import("node_store.zig");
const adj_store_mod = @import("adj_store.zig");
const in_head_dir_mod = @import("in_head_dir.zig");
const prop_store_mod = @import("prop_store.zig");
const property_mod = @import("property.zig");
const var_store_mod = @import("var_store.zig");
const free_space_mod = @import("free_space.zig");
const label_dict_mod = @import("label_dict.zig");
const checkpoint_mod = @import("checkpoint.zig");
const recovery_mod = @import("recovery.zig");
const label_index_mod = @import("label_index.zig");
const property_chain_index_mod = @import("property_chain_index.zig");
const label_store_mod = @import("label_store.zig");
const metrics_mod = @import("metrics.zig");
const node_mod = @import("node.zig");
const edge_mod = @import("edge.zig");
const engine_edge_props = @import("engine_edge_props.zig");
const engine_integrity = @import("engine_integrity.zig");
const engine_index = @import("engine_index.zig");
const engine_persist = @import("engine_persist.zig");
const engine_property_index = @import("engine_property_index.zig");
const engine_adj_repair = @import("engine_adj_repair.zig");
const edge_exist_index_mod = @import("edge_exist_index.zig");
const edge_index_map_mod = @import("edge_index_map.zig");
const ordered_property_index_mod = @import("ordered_property_index.zig");

const NodeId = types.NodeId;
const EdgeId = types.EdgeId;
const TxnId = types.TxnId;
const LabelId = types.LabelId;
const FileId = types.FileId;
const PropertyValue = types.PropertyValue;
const GraphConfig = config_mod.GraphConfig;
const GraphStorage = interface_mod.GraphStorage;
const Manifest = manifest_mod.Manifest;
const GraphDir = graph_dir_mod.GraphDir;
const FileManager = file_manager_mod.FileManager;
const BufferPool = buffer_pool_mod.BufferPool;
const WalManager = wal_mod.WalManager;
const TxnManager = txn_mod.TxnManager;
const NodeStore = node_store_mod.NodeStore;
const AdjStore = adj_store_mod.AdjStore;
const InHeadDir = in_head_dir_mod.InHeadDir;
const PropStore = prop_store_mod.PropStore;
const VarStore = var_store_mod.VarStore;
const FreeSpaceManager = free_space_mod.FreeSpaceManager;
const LabelDictionary = label_dict_mod.LabelDictionary;
const Checkpointer = checkpoint_mod.Checkpointer;
const Recovery = recovery_mod.Recovery;
const LabelIndex = label_index_mod.LabelIndex;
const PropertyChainIndex = property_chain_index_mod.PropertyChainIndex;
const PropRevIndex = @import("prop_rev_index.zig").PropRevIndex;
const LabelStore = label_store_mod.LabelStore;
const Metrics = metrics_mod.Metrics;
const NodeRec = node_mod.NodeRec;
const EdgeEntry = edge_mod.EdgeEntry;
const PropertyIndexSet = engine_property_index.PropertyIndexSet;
const OrderedPropertyIndex = ordered_property_index_mod.OrderedPropertyIndex;

/// In-memory index entry for O(1) edge lookup by EdgeId.
/// GAP warm-reopen P1: definition moved to edge_index_map.zig (re-exported
/// here so every existing `engine_mod.EdgeIndexEntry` reference keeps working).
pub const EdgeIndexEntry = edge_index_map_mod.EdgeIndexEntry;
pub const AdjTailRepairReport = engine_adj_repair.AdjTailRepairReport;
pub const AdjTailIssue = engine_adj_repair.AdjTailIssue;

/// WAL-aware derived-index durability Phase 3: one tail-affected primary page,
/// captured by recovery and consumed by the first-access tail reconcile.
pub const TailPage = struct { file_id: types.FileId, page_id: u64 };

/// TEST/introspection: order-independent content digest of the four derived
/// indexes. Two equal digests ⇒ the indexes are key-for-key equal (negligible
/// collision probability). Used to assert a WAL-tail reconcile == a full
/// rebuild over the same store.
pub const DerivedDigests = struct {
    label: u64,
    property: u64,
    edge: u64,
    edge_exist: u64,

    pub fn eql(a: DerivedDigests, b: DerivedDigests) bool {
        return a.label == b.label and a.property == b.property and
            a.edge == b.edge and a.edge_exist == b.edge_exist;
    }
};

/// Default worker count for the owned (no-`external_thread_pool`) path.
/// Sized for the only consumer — `BufferPool.flushAllParallel`, capped at
/// `MAX_CHUNKS = 64` short-lived I/O tasks per checkpoint. Four workers
/// saturate any one shard's flush bandwidth; larger graphs that need more
/// throughput inject a caller-owned pool via `GraphConfig.external_thread_pool`.
/// See docs/2026-04-25-shared-engine-thread-pool.md §5.2 and §9.
pub const default_owned_pool_max_threads: u32 = 4;

/// The central GraphEngine that wires everything together and implements
/// the GraphStorage vtable.
///
/// The engine owns all component structs and coordinates their interactions.
/// It supports creating new graphs and opening existing ones with crash recovery.
pub const GraphEngine = struct {
    allocator: Allocator,
    config: GraphConfig,
    graph_uuid: [16]u8,
    graph_dir: GraphDir,
    file_manager: FileManager,
    buffer_pool: BufferPool,
    wal: WalManager,
    txn_manager: TxnManager,
    node_store: NodeStore,
    adj_out: AdjStore,
    adj_in: AdjStore,
    /// Edge co-location (Phase A): incoming-adjacency chain bodies for edges
    /// whose SOURCE hashes to this shard, keyed (via `in_head_dir`) by dst node
    /// id. Mirrors `adj_in`'s AdjStore shape; page-backed (FileId `in_idx`) so
    /// durability rides logPage/flushAll/syncDirty exactly like adj_in.
    adj_in_remote: AdjStore,
    /// Edge co-location (Phase A): page-backed dst-node-id -> chain-head
    /// directory for `adj_in_remote` (FileId `in_dir`). Rides page-image redo
    /// (no snapshot/rebuild) so a crash restores it crash-consistently with the
    /// chain bodies it indexes.
    in_head_dir: InHeadDir,
    prop_store: PropStore,
    var_store: VarStore,
    free_space_nodes: FreeSpaceManager,
    free_space_adj_out: FreeSpaceManager,
    free_space_adj_in: FreeSpaceManager,
    free_space_in_idx: FreeSpaceManager,
    free_space_in_dir: FreeSpaceManager,
    free_space_props: FreeSpaceManager,
    free_space_var: FreeSpaceManager,
    label_dict: LabelDictionary,
    label_store: LabelStore,
    label_index: LabelIndex,
    property_index: PropertyChainIndex,
    /// PHASE G reverse map: prop_head -> node_id, so a crash-reopen exact-index
    /// reconcile resolves a tail PROPS-page slab slot to its owning node. Built
    /// by the hydration scan, kept current on the record-write path
    /// (putNode/deleteNode, when hydrated), persisted with the other derived
    /// snapshots (epoch + covered_lsn stamped), reconciled from the nodes-page
    /// tail. See prop_rev_index.zig.
    prop_rev_index: PropRevIndex,
    /// GAP warm-reopen P1: overlay hashmap + optional immutable mmap base
    /// (see edge_index_map.zig). Resident mode (no base) behaves exactly like
    /// the previous `std.AutoHashMap(EdgeId, EdgeIndexEntry)`.
    edge_index: edge_index_map_mod.EdgeIndexMap,
    /// PHASE 3 (edge-engine-direct): durable, derived edge-EXISTENCE index
    /// mapping (from, rel_type, to) -> edge_id(s) for O(1) MERGE dedup. Same
    /// crash-safety lifecycle as `edge_index` (snapshot at checkpoint; rebuilt
    /// from durable out-adjacency on recovery when stale/absent).
    edge_exist_index: edge_exist_index_mod.EdgeExistenceIndex,
    /// GAP-0027 / FR-016 / FR-017: opt-in B+tree property indexes plus the
    /// per-graph index catalog. Empty unless an index is declared via
    /// `createPropertyIndex`; a graph with no declared index writes no catalog
    /// file and behaves exactly as before.
    property_index_set: PropertyIndexSet,
    /// H3-P1: per-(label,key) value-ordered secondary index. Empty unless an
    /// ordered index is declared via `createOrderedIndex`; a graph with none
    /// writes no snapshot file and behaves exactly as before. Crash-safety
    /// mirrors the derived indexes (Lever B): counter-gated load on open, save
    /// on full checkpoint, rebuild from scan when the snapshot is stale.
    ordered_property_index: OrderedPropertyIndex,
    checkpointer: Checkpointer,
    manifest: Manifest,
    wal_dir_handle: std.Io.Dir,
    /// Pointer to the active pool. Either points into `owned_thread_pool`
    /// (engine created it) or to a caller-supplied pool from
    /// `GraphConfig.external_thread_pool`. Always non-null after init.
    thread_pool: *tp.ThreadPool,
    /// Backing storage for the owned-pool path. `null` when the engine is
    /// borrowing an external pool. Never reassigned after init — that would
    /// invalidate `thread_pool`.
    owned_thread_pool: ?tp.ThreadPool,
    /// Thread-pool submitter slot, lazily registered on first flush. The
    /// engine owns the pool, so we claim a per-engine slot and release
    /// it in cleanupResources. Left `null` if registerSubmitter fails —
    /// the default submit path still works, just without the per-
    /// submitter descriptor cache.
    submitter_slot: ?usize = null,
    metrics: Metrics = .{},
    read_only: bool = false,
    persistence_dirty: bool = false,
    label_index_dirty: bool = true,
    property_index_dirty: bool = true,
    /// PHASE G reverse map: set when a record write moved/added/removed a
    /// prop_head->node mapping since the last persist, so the next checkpoint
    /// re-saves the reverse-map snapshot (and a clean one is restamped).
    prop_rev_index_dirty: bool = false,
    edge_index_dirty: bool = true,
    /// PHASE 3: set when the edge-existence index changed since the last persist,
    /// so the next checkpoint/close writes its snapshot. Tracked in lock-step
    /// with `edge_index_dirty` (both move on every edge add/remove).
    edge_exist_index_dirty: bool = true,
    /// GAP-0027: set when the index catalog or a declared B+tree property index
    /// has changed since the last persist, so the next checkpoint/close writes
    /// the catalog + tree snapshots.
    property_catalog_dirty: bool = false,
    /// H3-P1: set when a registered ordered-index tree changed since the last
    /// persist, so the next FULL checkpoint re-saves the snapshot stamped at the
    /// current manifest.counter (the light path skips it, staying O(dirty)).
    ordered_index_dirty: bool = false,
    /// H3-P4: set by every write that can change an indexed value or label
    /// membership; cleared only by a successful `rebuildOrderedIndex`. While
    /// set, the value-ordered trees may not reflect committed state, so the
    /// planner must NOT serve the ORDER BY fast path (see `orderedIndexFresh`).
    ordered_index_stale: bool = false,

    /// Phase A (engine early-ready): lazy derived-index materialization latch.
    /// `open` returns query-READY WITHOUT building the O(nodes+edges) derived
    /// indexes (label_index / property_index chain / edge_index /
    /// edge_exist_index). The FIRST accessor of any of those indexes — read OR
    /// write — calls `ensureDerivedHydrated`, which runs the SAME counter-gated
    /// load-or-rebuild exactly once (atomic fast-path + mutex slow-path); all
    /// other concurrent first-accesses block until it completes. Point lookups
    /// (getNode, and the node/adjacency stores) need NO derived index and serve
    /// immediately after open. A fresh `create` starts already hydrated (empty
    /// derived indexes are the correct state for an empty graph). CRASH-SAFETY
    /// is UNCHANGED: the counter gate (snapshot.counter == manifest.counter ?
    /// load : rebuild) just runs at first-access instead of at open; WAL replay
    /// stays in `open` (recovery).
    derived_hydrated: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    derived_hydrate_mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Test/observability: number of times the materialize BODY actually ran.
    /// MUST be exactly 1 across any number of concurrent first-accesses.
    derived_materialize_runs: u32 = 0,

    /// GAP warm-reopen P2: TRUE when the invariant "every gated derived
    /// snapshot (label/prop/edge/edge-exist) whose dirty flag is FALSE is
    /// content-identical to its in-memory index" is KNOWN to hold. Only
    /// under this invariant may a full checkpoint cheaply RE-STAMP a clean
    /// snapshot's counter to the new manifest.counter (restampClean-
    /// DerivedSnapshots) instead of leaving it counter-stale.
    ///
    /// Transitions:
    ///   * create(): true — all four dirty flags start true, so the
    ///     invariant holds vacuously (the first full checkpoint SAVES all
    ///     four, making it hold materially).
    ///   * open(): FALSE — the dirty flags start clean but the on-disk
    ///     snapshots are UNKNOWN: after a crash restart they are stale
    ///     (recovery bumped manifest.counter past their stamp) even though
    ///     nothing in this session dirtied them. Restamping here would
    ///     bless crash-stale indexes = silent data loss. A page-only
    ///     session that never hydrates therefore never restamps (its
    ///     snapshots stay counter-stale → next open rebuilds, exactly the
    ///     pre-P2 behavior).
    ///   * materializeDerivedIndexes(): true — LOAD branch: memory :=
    ///     snapshot with all flags clean (holds materially); REBUILD
    ///     branch: all four flags set dirty (holds vacuously; the next full
    ///     checkpoint saves them).
    ///   * full checkpoint that saved ALL FOUR (all were dirty): true.
    /// Mutations never clear it. Instead, the invariant is an OBLIGATION on
    /// every derived-index mutation entry point: set that index's dirty flag
    /// at the mutation point, which removes the index from the invariant's
    /// scope until the next save. Any mutator that forgets converts the next
    /// full checkpoint's restamp into a blessing of a stale snapshot =
    /// silent durable data loss (re-review F1/F2 were exactly this shape:
    /// engine_edge_props.setEdgeProperty's updatePropHead and
    /// sharded_recovery's dangling-2PC edge_index.put replay). Audited
    /// mutation sites that uphold it: label add/remove → label_index_dirty;
    /// property chain writes (refreshPropertyChainIndex/removeChain) →
    /// property_index_dirty; edge add/remove and setEdgeProperty's
    /// prop_head update → edge_index_dirty; existence-index put/remove
    /// (including 2PC recovery replay) → edge_exist_index_dirty; a full
    /// rebuild sets all four.
    derived_snapshots_trusted: bool = false,

    /// WAL-aware derived-index durability Phase 3 (tail reconcile): the
    /// tail-affected primary pages recovery applied at OPEN, copied out of the
    /// (soon-deinit) Recovery for the DEFERRED first-access reconcile. Null
    /// means "no bounded tail to reconcile" — either a clean reopen, or the
    /// capture was unavailable/overflowed → materializeDerivedIndexes rebuilds
    /// (always safe). Owned; freed and nulled once the reconcile consumes it
    /// (or in cleanupResources on an un-hydrated teardown).
    tail_affected_pages: ?[]TailPage = null,

    /// WAL-aware derived-index durability Phase 3 (multi-recovery guard): the
    /// durable committed frontier as it stood BEFORE this session's recovery ran
    /// (recovery's `pre_recovery_last_checkpoint_lsn`). The first-access tail
    /// reconcile is valid ONLY when a snapshot's `covered_lsn` == this value —
    /// otherwise a PRIOR un-checkpointed recovery advanced the frontier past the
    /// snapshot and `tail_affected_pages` is only the latest recovery slice, so
    /// the gate forces a full rebuild instead of a (silently-incomplete) partial
    /// reconcile. 0 on a freshly created graph (no recovery, never gated).
    tail_pre_recovery_lsn: u64 = 0,

    /// Create a new graph.
    pub fn create(allocator: Allocator, data_dir: []const u8, graph_uuid: [16]u8, cfg: GraphConfig) !*GraphEngine {
        const self = try allocator.create(GraphEngine);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.config = cfg;
        self.graph_uuid = graph_uuid;
        self.read_only = false;
        self.persistence_dirty = false;
        self.label_index_dirty = true;
        self.property_index_dirty = true;
        self.edge_index_dirty = true;
        self.edge_exist_index_dirty = true;
        self.property_catalog_dirty = false;
        self.ordered_index_dirty = false;
        self.ordered_index_stale = false;
        // A fresh graph's derived indexes start empty == correct: mark hydrated
        // so no lazy materialization is ever attempted (there is no snapshot to
        // load and nothing to rebuild from).
        self.derived_hydrated = std.atomic.Value(bool).init(true);
        self.derived_hydrate_mutex = std.Io.Mutex.init;
        self.derived_materialize_runs = 0;
        // P2: all four dirty flags are true → the clean-snapshot invariant
        // holds vacuously (see the field doc).
        self.derived_snapshots_trusted = true;
        self.tail_affected_pages = null; // fresh graph: no WAL tail to reconcile
        self.tail_pre_recovery_lsn = 0;
        self.submitter_slot = null;
        self.owned_thread_pool = null;

        // 1. Create graph directory
        self.graph_dir = try GraphDir.create(allocator, data_dir, graph_uuid);
        errdefer self.graph_dir.deinit();

        // 2. Init manifest with defaults
        self.manifest = Manifest{
            .graph_uuid = graph_uuid,
            .page_size = cfg.page_size,
            .counter = 0,
            .last_checkpoint_lsn = 0,
            .next_node_id = 1,
            .next_edge_id = 1,
            .next_txn_id = 1,
        };

        if (cfg.base_shard_index) |base| {
            // Id 0 is reserved as a sentinel (null out_head / in_head / prop_head / edge_id).
            // Shard 0's base would collide, so skip ahead by one stride: shard 0 allocates
            // `N, 2N, 3N, ...` (still 0 mod N) while other shards start at `base`.
            const stride: u64 = @intCast(@import("sharded_store.zig").SHARD_COUNT);
            const start: u64 = if (base == 0) stride else @intCast(base);
            self.manifest.next_node_id = start;
            self.manifest.next_edge_id = start;
            self.manifest.next_txn_id = start;
        }

        // 3. Write initial manifest to slot A
        // SEC-0043: HMAC-authenticate the manifest under TDE so the very first
        // open/recovery verifies it instead of trusting a forgeable CRC32.
        const path_a = try self.graph_dir.manifestPath(allocator, .a);
        defer allocator.free(path_a);
        try self.manifest.writeToFileWithKey(allocator, path_a, cfg.encryption_key);

        // 4. Open all store files via FileManager
        self.file_manager = FileManager.init(allocator, self.graph_dir.path, cfg.page_size);
        self.file_manager.encryption_key = cfg.encryption_key;
        _ = try self.file_manager.openFile(.nodes, .create_if_missing);
        _ = try self.file_manager.openFile(.adj_out, .create_if_missing);
        _ = try self.file_manager.openFile(.adj_in, .create_if_missing);
        _ = try self.file_manager.openFile(.props, .create_if_missing);
        _ = try self.file_manager.openFile(.var_store, .create_if_missing);
        _ = try self.file_manager.openFile(.free, .create_if_missing);
        _ = try self.file_manager.openFile(.label_idx, .create_if_missing);
        _ = try self.file_manager.openFile(.prop_idx, .create_if_missing);
        _ = try self.file_manager.openFile(.edge_idx, .create_if_missing);
        _ = try self.file_manager.openFile(.edge_exist_idx, .create_if_missing);
        // Edge co-location (Phase A): incoming-adjacency chain bodies + directory.
        _ = try self.file_manager.openFile(.in_idx, .create_if_missing);
        _ = try self.file_manager.openFile(.in_dir, .create_if_missing);

        // 5. Create buffer pool, register pagers
        // PERF-0051: size the pool with the same auto-size logic open() uses
        // instead of taking cfg.buffer_pool_pages verbatim. A freshly created
        // graph has an empty manifest (0 pages), so this applies the auto-size
        // floor rather than leaving the pool at a tiny configured default.
        const create_pages = cfg.effectiveBufferPoolPages(0);
        self.buffer_pool = try BufferPool.init(allocator, cfg.page_size, create_pages);
        errdefer self.buffer_pool.deinit();
        // PERF-0051: reserve a floor of frames for the hot node store so cold
        // prop/var/adj scans cannot evict every cached node page.
        self.buffer_pool.setReservedFrames(.nodes, reservedNodeFrames(create_pages));
        self.registerDataPagers();

        // 6. Init all shared subsystems (free space, WAL, txn, stores, labels, checkpointer)
        var bootstrap_cfg = cfg;
        bootstrap_cfg.allow_create_missing_artifacts = true;
        try self.initSubsystems(allocator, graph_uuid, bootstrap_cfg, 0);
        // QUAL-0042: initSubsystems' internal errdefers only cover failures
        // inside that call; they discharge once it returns. Cover the steps
        // that run afterwards (e.g. initThreadPool) so they cannot leak the
        // subsystems and the WAL directory handle.
        errdefer self.cleanupSubsystems();

        // 7. Wire metrics and thread pool into buffer pool
        self.metrics = .{};
        self.wireMetricsCounters();
        self.buffer_pool.setMetrics(&self.metrics);
        // Initialize owned-or-borrowed thread pool (see initThreadPool).
        try self.initThreadPool(allocator, cfg);
        self.buffer_pool.setThreadPool(self.thread_pool);
        self.persistence_dirty = false;

        return self;
    }

    /// PERF: compute the buffer-pool capacity to allocate up front when OPENING
    /// an existing graph, so the pool is sized ONCE rather than allocated small
    /// and then re-created larger after recovery. Peeks the persisted manifest's
    /// page counts and applies the SAME auto-size policy
    /// (`effectiveBufferPoolPages`) recovery uses. On any manifest-read error it
    /// returns the configured default and the post-recovery guard re-sizes if the
    /// authoritative manifest disagrees (safety net).
    fn openInitialPoolPages(allocator: Allocator, graph_dir: *const GraphDir, cfg: *const GraphConfig) u32 {
        const total = peekManifestTotalPages(allocator, graph_dir, cfg.encryption_key) orelse
            return cfg.buffer_pool_pages;
        return cfg.effectiveBufferPoolPages(total);
    }

    /// Read the persisted manifest (A/B, the same slot selection recovery uses)
    /// and return the sum of its store page counts — or null on any read or
    /// selection error so the caller falls back to the configured default. This
    /// is a cheap header read; recovery re-reads the manifest authoritatively.
    fn peekManifestTotalPages(allocator: Allocator, graph_dir: *const GraphDir, key: ?[32]u8) ?u64 {
        const path_a = graph_dir.manifestPath(allocator, .a) catch return null;
        defer allocator.free(path_a);
        const path_b = graph_dir.manifestPath(allocator, .b) catch return null;
        defer allocator.free(path_b);
        const ma = Manifest.readFromFileWithKey(allocator, path_a, key) catch null;
        const mb = Manifest.readFromFileWithKey(allocator, path_b, key) catch null;
        const m = Manifest.selectManifest(ma, mb) catch return null;
        return m.nodes_pages + m.adj_out_pages + m.adj_in_pages +
            m.in_idx_pages + m.in_dir_pages + m.props_pages +
            m.var_pages + m.free_pages;
    }

    /// Open an existing graph (with recovery).
    pub fn open(allocator: Allocator, data_dir: []const u8, graph_uuid: [16]u8, cfg: GraphConfig) !*GraphEngine {
        const self = try allocator.create(GraphEngine);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.config = cfg;
        self.graph_uuid = graph_uuid;
        self.read_only = false;
        self.persistence_dirty = false;
        self.label_index_dirty = false;
        self.property_index_dirty = false;
        self.edge_index_dirty = false;
        self.edge_exist_index_dirty = false;
        self.property_catalog_dirty = false;
        self.ordered_index_dirty = false;
        self.ordered_index_stale = false;
        // Phase A: open returns READY without building the derived indexes; the
        // first accessor materializes them via `ensureDerivedHydrated`.
        self.derived_hydrated = std.atomic.Value(bool).init(false);
        self.derived_hydrate_mutex = std.Io.Mutex.init;
        self.derived_materialize_runs = 0;
        // P2: the on-disk snapshots are UNKNOWN until the counter gate runs
        // (they may be crash-stale behind clean dirty flags) — restamping is
        // forbidden until materializeDerivedIndexes establishes the invariant.
        self.derived_snapshots_trusted = false;
        self.tail_affected_pages = null; // set from recovery's captured set below
        self.tail_pre_recovery_lsn = 0; // set from recovery below
        self.submitter_slot = null;
        self.owned_thread_pool = null;

        // 1. Open graph directory
        self.graph_dir = try GraphDir.open(allocator, data_dir, graph_uuid);
        errdefer self.graph_dir.deinit();

        // 2. Open store files
        self.file_manager = FileManager.init(allocator, self.graph_dir.path, cfg.page_size);
        self.file_manager.encryption_key = cfg.encryption_key;

        // 3. Create buffer pool.
        // PERF: size the pool ONCE up front from the persisted manifest's page
        // counts (applying the SAME auto-size policy recovery applies below) so
        // we don't allocate a small pool and then re-create a larger one after
        // recovery (a second allocation). On any manifest-peek error this falls
        // back to the configured default; the post-recovery guard below remains
        // as a safety net should the peek and the authoritative manifest ever
        // disagree.
        const initial_pool_pages = openInitialPoolPages(allocator, &self.graph_dir, &cfg);
        self.buffer_pool = try BufferPool.init(allocator, cfg.page_size, initial_pool_pages);
        errdefer self.buffer_pool.deinit();

        // 4. Run recovery (loads manifest, replays WAL)
        var recovery = Recovery.init(allocator, cfg.encryption_key);
        recovery.legacy_policy = cfg.legacy_policy;
        // Counter healing (WAL-recovery counter staleness): a sharded member
        // allocates node/edge ids at SHARD_COUNT stride, so recovery must
        // re-derive counters in the same residue class (see Recovery.id_stride).
        recovery.id_stride = if (cfg.base_shard_index != null)
            @intCast(@import("sharded_store.zig").SHARD_COUNT)
        else
            1;
        // Residue guard (I1): the harvest must skip legacy foreign-residue
        // ids (pre-co-location `.adj_in` images carry source-shard edge ids)
        // or the healed counter leaves the shard's id class and shardOfNode
        // routing breaks for every subsequently created edge.
        recovery.shard_residue = if (cfg.base_shard_index) |base|
            @as(u64, @intCast(base)) % recovery.id_stride
        else
            0;
        // WAL-aware derived-index durability Phase 3: capture the tail-affected
        // (file_id,page_id) set so first-access hydration can reconcile ONLY the
        // bounded tail into the loaded snapshot instead of an O(graph) rebuild.
        recovery.capture_affected_pages = true;
        defer recovery.deinit();
        self.manifest = try recovery.recover(&self.graph_dir, &self.buffer_pool, &self.file_manager);
        self.read_only = recovery.read_only;

        _ = try self.file_manager.openFile(.label_idx, .open_existing);
        _ = try self.file_manager.openFile(.prop_idx, .open_existing);
        _ = try self.file_manager.openFile(.edge_idx, .open_existing);
        // PHASE 3: the edge-existence snapshot is ADDITIVE. A pre-Phase-3 graph
        // has no `edges_exist.idx`; create it if missing so the load path sees an
        // empty file (→ rebuild from adjacency) instead of failing to open.
        _ = try self.file_manager.openFile(.edge_exist_idx, .create_if_missing);
        // Edge co-location (Phase A): ADDITIVE like the existence index. A
        // pre-co-location graph has no adj_in_remote/adj_in_dir files; create
        // them if missing so open() succeeds (empty → no co-located in-edges
        // until Phase B migration). The pages are restored by WAL page-image
        // redo (registered below), so recovery needs no special handling.
        _ = try self.file_manager.openFile(.in_idx, .create_if_missing);
        _ = try self.file_manager.openFile(.in_dir, .create_if_missing);

        // SEC-0010: Validate page_size matches manifest after recovery
        if (cfg.page_size != self.manifest.page_size) {
            return error.PageSizeMismatch;
        }

        // PERF-0008: Auto-size buffer pool based on manifest page counts
        const total_pages = self.manifest.nodes_pages +
            self.manifest.adj_out_pages +
            self.manifest.adj_in_pages +
            self.manifest.in_idx_pages +
            self.manifest.in_dir_pages +
            self.manifest.props_pages +
            self.manifest.var_pages +
            self.manifest.free_pages;
        const effective = cfg.effectiveBufferPoolPages(total_pages);
        if (effective > self.buffer_pool.capacity) {
            // SAFETY NET: the pool was already sized to this `effective` value up
            // front (see `openInitialPoolPages` at step 3), so in the normal path
            // this branch does not run. It only fires if the up-front manifest
            // peek failed (fell back to the default) or disagreed with the
            // authoritative manifest — re-create with the correct capacity,
            // re-register pagers. With the anon-mmap backing this re-create no
            // longer pays an eager zero-fill either.
            //
            // LOCK-FREE POOL LIFETIME INVARIANT (GAP-ENT-0018): the buffer pool's
            // `page_table` metadata base and frame array MUST NOT be freed or
            // moved while any thread can call `pin` — the PERF-0058 lock-free
            // fast path reads that backing store WITHOUT the pool mutex, so a
            // free-under-reader is an immediate use-after-free segfault (the
            // `page_table.get` dereferences a dangling `metadata` base). This
            // re-create is safe ONLY because it runs on the open path BEFORE
            // `open` returns `self` — the engine is not yet published, so no
            // reader exists. recovery.recover already `flushAll`ed, so the old
            // (clean) pool can be discarded without data loss. Do NOT introduce a
            // pool deinit+recreate (or any metadata-moving grow) on a path where
            // reads may be in flight.
            //
            // CORRECTNESS (double-free on OOM): build the replacement BEFORE
            // tearing down the old pool. If `init` fails (OOM), `self.buffer_pool`
            // still points at the valid old pool, so the `errdefer` registered at
            // step 3 frees it EXACTLY ONCE. The prior order (deinit then assign)
            // left `self.buffer_pool` referencing freed memory on an init failure,
            // and the errdefer double-freed it.
            const resized_pool = try BufferPool.init(allocator, cfg.page_size, effective);
            self.buffer_pool.deinit();
            self.buffer_pool = resized_pool;
            self.registerDataPagers();
        }
        // PERF-0051: reserve a floor of frames for the hot node store so cold
        // prop/var/adj scans cannot evict every cached node page.
        self.buffer_pool.setReservedFrames(.nodes, reservedNodeFrames(self.buffer_pool.capacity));

        // 5. Init all shared subsystems (free space, WAL, txn, stores, labels, checkpointer)
        try self.initSubsystems(allocator, graph_uuid, cfg, self.manifest.last_checkpoint_lsn);
        // QUAL-0042: initSubsystems' internal errdefers only cover failures
        // inside that call; they discharge once it returns. Cover the steps
        // that run afterwards (loadFreeStore, rebuildFreeSpaceFromDisk,
        // label_dict.loadFromFile, rebuildDerivedIndexes, initThreadPool) so a
        // failure there cannot leak the subsystems and the WAL directory handle.
        errdefer self.cleanupSubsystems();

        // 5b. Restore free space bitmaps. Prefer the persisted free.store
        // file which accurately tracks freed pages. Fall back to rebuilding
        // from on-disk file sizes (lossy — freed pages appear allocated).
        //
        // GAP-ENT-0011 (free-space map vs WAL tail): free.store is written at
        // CHECKPOINT time only. When recovery just replayed (and flushed)
        // committed WAL-tail page images, pages allocated AFTER that
        // checkpoint are still marked FREE in the persisted bitmap. Loading
        // it would (1) hide recovered nodes — NodeStore.getNode/scanNodes
        // gate on isAllocated — and (2) let allocPage hand a LIVE page to the
        // next writer (double allocation → pinNew zeroes and overwrites
        // committed data). So on a crash restart the persisted bitmap is
        // untrusted: rebuild from on-disk file sizes (recovery flushAll'ed
        // the replayed pages, so the files cover them). The rebuild is
        // O(total pages) bit-sets — negligible next to the derived-index
        // rebuild a crash restart already pays (the derived-snapshot load
        // gate is counter-excluded on this same path). Then persist the
        // rebuilt bitmap IMMEDIATELY: recovery already advanced
        // last_checkpoint_lsn past the replayed tail, so a second crash
        // before the next checkpoint would otherwise take the clean path on
        // the NEXT open and trust the stale checkpoint-era file.
        // WAL-aware derived-index durability Phase 3 (multi-recovery guard):
        // record the durable frontier as it stood BEFORE this recovery ran. The
        // first-access reconcile gate compares each snapshot's covered_lsn to
        // this: covered < this ⇒ a prior un-checkpointed recovery advanced the
        // frontier and the captured set below is only the latest slice ⇒ rebuild.
        self.tail_pre_recovery_lsn = recovery.pre_recovery_last_checkpoint_lsn;

        // WAL-aware derived-index durability Phase 3: copy the tail-affected
        // page set out of `recovery` (about to deinit) for the DEFERRED
        // first-access reconcile. Only when a committed tail was applied and the
        // capture is COMPLETE — an overflow (OOM mid-capture) or an empty set
        // leaves it null so materializeDerivedIndexes rebuilds (always safe; a
        // partial set would leave stale index entries).
        if (recovery.applied_committed_pages and
            !recovery.affected_pages_overflow and
            recovery.affected_pages.count() > 0)
        {
            const n = recovery.affected_pages.count();
            const buf = try allocator.alloc(TailPage, n);
            var it = recovery.affected_pages.keyIterator();
            var i: usize = 0;
            while (it.next()) |k| : (i += 1) {
                buf[i] = .{
                    .file_id = @enumFromInt(@as(u8, @intCast(k.* >> 64))),
                    .page_id = @truncate(k.*),
                };
            }
            self.tail_affected_pages = buf;
        }

        if (recovery.applied_committed_pages) {
            try self.rebuildFreeSpaceFromDisk();
            try self.saveFreeStore();
        } else {
            const loaded_free_store = try self.loadFreeStore();
            if (!loaded_free_store) {
                try self.rebuildFreeSpaceFromDisk();
            }
        }

        // 6. Load persisted label dictionary if it exists
        const labels_path = try std.fmt.allocPrint(allocator, "{s}/labels.dict", .{self.graph_dir.path});
        defer allocator.free(labels_path);
        self.label_dict.loadFromFile(labels_path) catch |err| switch (err) {
            error.FileNotFound => {}, // Expected on fresh graphs
            else => return err,
        };
        // SONNY-6491: graph_storage <= 0.4.13 saved labels.dict after the
        // manifest; a crash in between leaves fewer names than the manifest
        // counted. The lost names cannot be re-derived (label blocks hold only
        // ids), so report it; ids without a name read back as unnamed.
        if (self.label_dict.count() < self.manifest.label_count) {
            std.log.warn("labels.dict holds {d} label names but the manifest recorded {d}: names assigned before a crash during a <= 0.4.13 checkpoint are lost", .{ self.label_dict.count(), self.manifest.label_count });
        }

        // 7. Phase A (engine early-ready): the O(nodes+edges) derived-index
        // build (label/property-chain/edge/edge-existence) is DEFERRED out of
        // the open path. It is the dominant open cost at scale, and point
        // lookups (getNode and the node/adjacency stores) need none of it, so
        // open returns query-READY here. The FIRST accessor of any derived
        // index calls `ensureDerivedHydrated`, which runs the SAME counter-gated
        // `tryLoadDerivedIndexes` (clean restart) or `rebuildDerivedIndexes`
        // (crash/stale) exactly once. Crash-safety is unchanged: the counter
        // gate just decides at first-access instead of at open.

        // 7b. GAP-0027: load the opt-in index catalog and rehydrate declared
        // B+tree property indexes. A missing catalog means "no indexes"
        // (backward compat). Snapshots that fail verification are rebuilt.
        try engine_property_index.load(self);

        // 7c. GAP-0050: load the per-(label,key) ordered index on the SAME Path B
        // `(checkpoint_epoch, covered_lsn)` reload contract the 4 engine derived
        // indexes use (engine_index.tryLoadDerivedIndexes). The snapshot records
        // the registered (label,key) pairs AND the trees, stamped with the
        // durable freshness token at checkpoint time:
        //   * epoch == manifest.checkpoint_epoch AND covered_lsn ==
        //     manifest.last_checkpoint_lsn  -> LOAD (clean reopen: epoch current
        //     AND no committed WAL tail past the snapshot). ORDER BY reopen is
        //     then O(snapshot), not the O(graph) rebuild.
        //   * epoch mismatch (a checkpoint ran after the snapshot) OR a tail
        //     (covered_lsn < last_checkpoint_lsn: recovery replayed committed
        //     records the snapshot predates) -> the registration is kept (already
        //     loaded) but the trees are REBUILT from a live scan. checkpoint_epoch
        //     advances ONLY at checkpoint (never by a WAL-tail recovery), so a
        //     clean shutdown reloads instead of the counter gate's forced rebuild.
        //   * no snapshot file (or old/corrupt -> error) -> no ordered index.
        // The btree tail-reconcile the derived indexes do (Path B Phase 3) is OUT
        // OF SCOPE (needs a node->old-ordered-key reverse map the PropRevIndex
        // does not carry — GAP-0050 crash-leg follow-up); the tail leg REBUILDS.
        var ordered_loaded = false;
        const ordered_snapshot_stamp = self.ordered_property_index.loadFromFile(self.graph_dir.path) catch null;
        if (ordered_snapshot_stamp) |stamp| {
            if (stamp.epoch == self.manifest.checkpoint_epoch and
                stamp.covered_lsn == self.manifest.last_checkpoint_lsn)
            {
                ordered_loaded = true;
            } else {
                try self.rebuildOrderedIndex();
                self.ordered_index_dirty = true;
            }
        }

        // 8. Wire metrics and thread pool into buffer pool
        self.metrics = .{};
        self.wireMetricsCounters();
        // Phase A: the derived-index load-vs-rebuild observability
        // (derived_index_loads / derived_index_rebuilds) is now set inside
        // `materializeDerivedIndexes` at first-access, not here — the build is
        // deferred out of open.
        // H3-P1: same observability for the ordered index — record load vs
        // rebuild for THIS open (only meaningful when an ordered index exists).
        if (self.ordered_property_index.count() > 0) {
            if (ordered_loaded) {
                self.metrics.ordered_index_loads = 1;
            } else {
                self.metrics.ordered_index_rebuilds = 1;
            }
        }
        self.buffer_pool.setMetrics(&self.metrics);
        // Initialize owned-or-borrowed thread pool (see initThreadPool).
        try self.initThreadPool(allocator, cfg);
        self.buffer_pool.setThreadPool(self.thread_pool);
        self.persistence_dirty = false;

        return self;
    }

    /// PERF-0051: Number of frames reserved for the hot node store.
    ///
    /// Point lookups (`getNode`) and most graph traversals touch a node page
    /// first. Cold prop/var/adj scans walk far more pages than the node store
    /// has, so without a floor they evict every cached node page and turn each
    /// post-seed `getNode` into a disk read. Reserving a quarter of the pool
    /// (capped so it never starves the other stores) keeps the hot node working
    /// set resident. The reservation is a *soft* floor: eviction still succeeds
    /// when the reserved class is the only source of evictable frames, so it can
    /// never deadlock or return BufferPoolFull spuriously.
    fn reservedNodeFrames(capacity: u32) u32 {
        // Reserve at most one quarter of the pool for node pages.
        return capacity / 4;
    }

    /// Register the six data-store pagers (nodes/adj_out/adj_in/props/var_store/free)
    /// with the buffer pool. The label/prop/edge index pagers are managed
    /// separately, so they are intentionally excluded here.
    fn registerDataPagers(self: *GraphEngine) void {
        if (self.file_manager.getPager(.nodes)) |p| self.buffer_pool.registerPager(.nodes, p);
        if (self.file_manager.getPager(.adj_out)) |p| self.buffer_pool.registerPager(.adj_out, p);
        if (self.file_manager.getPager(.adj_in)) |p| self.buffer_pool.registerPager(.adj_in, p);
        if (self.file_manager.getPager(.props)) |p| self.buffer_pool.registerPager(.props, p);
        if (self.file_manager.getPager(.var_store)) |p| self.buffer_pool.registerPager(.var_store, p);
        if (self.file_manager.getPager(.free)) |p| self.buffer_pool.registerPager(.free, p);
        // Edge co-location (Phase A): the incoming-adjacency chain bodies + the
        // dst->head directory are page-backed data stores, registered like the
        // other data pagers so logPage/flush/pin/recovery treat them uniformly.
        if (self.file_manager.getPager(.in_idx)) |p| self.buffer_pool.registerPager(.in_idx, p);
        if (self.file_manager.getPager(.in_dir)) |p| self.buffer_pool.registerPager(.in_dir, p);
    }

    fn initSubsystems(self: *GraphEngine, allocator: Allocator, graph_uuid: [16]u8, cfg: GraphConfig, wal_start_lsn: u64) !void {
        return engine_persist.initSubsystems(self, allocator, graph_uuid, cfg, wal_start_lsn);
    }

    /// GAP-0026: Wire metrics counters that were previously TODO stubs.
    fn wireMetricsCounters(self: *GraphEngine) void {
        // wal_segment_count: single-file WAL always has 1 segment.
        self.metrics.wal_segment_count = 1;

        // fragmentation_ratio: fraction of allocated-but-unused pages across
        // all stores, as fixed-point x10000.
        const total = self.free_space_nodes.total_pages +
            self.free_space_adj_out.total_pages +
            self.free_space_adj_in.total_pages +
            self.free_space_in_idx.total_pages +
            self.free_space_in_dir.total_pages +
            self.free_space_props.total_pages +
            self.free_space_var.total_pages;
        if (total > 0) {
            const free = self.free_space_nodes.freeCount() +
                self.free_space_adj_out.freeCount() +
                self.free_space_adj_in.freeCount() +
                self.free_space_in_idx.freeCount() +
                self.free_space_in_dir.freeCount() +
                self.free_space_props.freeCount() +
                self.free_space_var.freeCount();
            self.metrics.fragmentation_ratio = (free * 10000) / total;
        }

        // index_rebuild_progress: 10000 = 100% (rebuild complete).
        self.metrics.index_rebuild_progress = 10000;
    }

    fn ensureWritable(self: *const GraphEngine) !void {
        if (self.read_only) return error.ReadOnlyMode;
    }

    fn markDirty(self: *GraphEngine) void {
        self.persistence_dirty = true;
    }

    /// GAP-0027: public alias of markDirty used by the property-index module so
    /// that declaring/building/dropping a B+tree property index makes the next
    /// checkpoint persist the catalog and tree snapshots.
    pub fn markPersistenceDirty(self: *GraphEngine) void {
        self.persistence_dirty = true;
    }

    fn markClean(self: *GraphEngine) void {
        self.persistence_dirty = false;
    }

    // ── Persistence helpers (delegated to engine_persist.zig) ─────────

    fn saveFreeStore(self: *GraphEngine) !void {
        return engine_persist.saveFreeStore(self);
    }

    fn loadFreeStore(self: *GraphEngine) !bool {
        return engine_persist.loadFreeStore(self);
    }

    fn rebuildFreeSpaceFromDisk(self: *GraphEngine) !void {
        return engine_persist.rebuildFreeSpaceFromDisk(self);
    }

    // ── Index operations (delegated to engine_index.zig) ──────────────

    pub fn refreshPropertyChainIndex(self: *GraphEngine, prop_head: u64) !void {
        if (prop_head == 0) {
            return;
        }

        var iter = self.prop_store.getAllProperties(prop_head);
        defer iter.deinit();
        try self.property_index.refreshFromIterator(prop_head, &iter);
        self.property_index_dirty = true;
    }

    fn rebuildDerivedIndexes(self: *GraphEngine) !void {
        try engine_index.rebuildDerivedIndexes(self);
        // A direct rebuild fully populates the derived indexes from the primary
        // stores, so the engine is hydrated afterward — prevent a later
        // first-access from clobbering this state with another materialize.
        self.derived_hydrated.store(true, .release);
    }

    /// Phase A: ensure the deferred derived indexes (label_index /
    /// property_index chain / edge_index / edge_exist_index) are materialized
    /// before the caller touches any of them. Exactly-once under concurrent
    /// first-access: an atomic fast-path returns immediately once hydrated; the
    /// first caller takes the mutex and runs `materializeDerivedIndexes` while
    /// any concurrent callers block on the mutex and then observe the flag set.
    ///
    /// MUST be called at the top of EVERY read and write accessor that touches a
    /// deferred index, BEFORE the index is read or mutated — materializing as
    /// the first touch keeps the counter gate valid (no write has mutated the
    /// resident index yet, so a clean snapshot still matches manifest.counter).
    ///
    /// Re-entrancy: `materializeDerivedIndexes` calls only the load/rebuild
    /// helpers (which touch the index structures directly, never a guarded
    /// accessor of the same index), so this never recurses or deadlocks.
    pub fn ensureDerivedHydrated(self: *GraphEngine) !void {
        if (self.derived_hydrated.load(.acquire)) return;
        const io = std.Io.Threaded.global_single_threaded.io();
        self.derived_hydrate_mutex.lockUncancelable(io);
        defer self.derived_hydrate_mutex.unlock(io);
        // Double-check under the lock: a racing caller may have hydrated while
        // we waited for the mutex.
        if (self.derived_hydrated.load(.acquire)) return;
        try self.materializeDerivedIndexes();
        // Publish only on success; on error the flag stays false so a later
        // accessor retries (and a crash mid-build leaves the counter-gated
        // on-disk snapshot to re-decide on the next open).
        self.derived_hydrated.store(true, .release);
    }

    /// The body moved out of `open` step 7: run the counter-gated load-or-
    /// rebuild for the derived index set exactly once. Caller holds
    /// `derived_hydrate_mutex`.
    fn materializeDerivedIndexes(self: *GraphEngine) !void {
        self.derived_materialize_runs += 1;
        // WAL-aware derived-index durability: the load gate returns one of three
        // outcomes. On any load error, fall back to a rebuild (safe).
        const outcome = self.tryLoadDerivedIndexes() catch engine_index.LoadOutcome.rebuild;
        switch (outcome) {
            .rebuild => {
                try engine_index.rebuildDerivedIndexes(self);
                self.markDerivedIndexesDirty();
                self.metrics.derived_index_rebuilds = 1;
            },
            .loaded_clean => {
                // Snapshot covers the durable frontier — served directly, no tail.
                // PHASE G: load the reverse-map snapshot (or scan-rebuild it if
                // its stamp lags, e.g. a light checkpoint left it un-restamped).
                try self.hydratePropRevIndex();
                self.metrics.derived_index_loads = 1;
            },
            .loaded_needs_reconcile => {
                // Epoch matched AND a committed tail exists beyond covered_lsn.
                // Reconcile ONLY the bounded tail-affected pages (captured by
                // recovery at OPEN) into the loaded snapshot — O(tail), not
                // O(graph). If the captured set is unavailable (overflow / a
                // path that did not capture), rebuild (safe).
                // PHASE G: load the reverse-map BASE (as of covered_lsn) BEFORE
                // the tail reconcile — reconcileOneNode updates it for the
                // nodes-page tail set (adds inserts/relocations, drops deletes).
                try self.hydratePropRevIndex();
                try self.reconcileOrRebuildTail();
            },
        }
        // P2: either branch establishes the clean-snapshot invariant — LOAD:
        // memory := snapshot with all dirty flags clean (holds materially);
        // REBUILD/RECONCILE: all four flags went dirty (a rebuild vacuously; a
        // reconcile because the loaded snapshot no longer matches the tail-
        // advanced store) and the next full checkpoint's save makes it material.
        // From here on, a full checkpoint may restamp clean snapshots.
        self.derived_snapshots_trusted = true;
    }

    /// WAL-aware derived-index durability Phase 3: on the epoch-matched
    /// tail-present path, reconcile the captured tail-affected pages into the
    /// loaded snapshot; rebuild if the captured set is unavailable or the
    /// reconcile cannot decode a page exactly. Consumes tail_affected_pages.
    fn reconcileOrRebuildTail(self: *GraphEngine) !void {
        if (self.tail_affected_pages) |pages| {
            defer {
                self.allocator.free(pages);
                self.tail_affected_pages = null;
            }
            const result = engine_index.reconcileDerivedIndexesFromTail(self, pages) catch blk: {
                // A reconcile error (unexpected decode/IO): the safe recovery is
                // a full rebuild, which clears any partially reconciled state.
                try engine_index.rebuildDerivedIndexes(self);
                break :blk engine_index.ReconcileResult.rebuilt;
            };
            // The reconciled/rebuilt indexes differ from the on-disk (covered_lsn)
            // snapshots → mark dirty so the next checkpoint persists them.
            self.markDerivedIndexesDirty();
            switch (result) {
                .reconciled => {
                    self.metrics.derived_index_loads = 1;
                    self.metrics.derived_index_reconciles = 1;
                },
                .rebuilt => {
                    self.metrics.derived_index_rebuilds = 1;
                },
            }
        } else {
            // No captured tail set (overflow / non-capturing path): rebuild. The
            // loaded bases are released by rebuildDerivedIndexes' clears.
            try engine_index.rebuildDerivedIndexes(self);
            self.markDerivedIndexesDirty();
            self.metrics.derived_index_rebuilds = 1;
        }
    }

    /// Mark all four derived-index dirty flags so the next checkpoint persists
    /// them (used after a rebuild or a tail reconcile — the resident indexes no
    /// longer match the on-disk snapshots).
    fn markDerivedIndexesDirty(self: *GraphEngine) void {
        self.label_index_dirty = true;
        self.property_index_dirty = true;
        self.edge_index_dirty = true;
        self.edge_exist_index_dirty = true;
        // PHASE G: a rebuild/reconcile also changed the reverse map vs the
        // on-disk snapshot → persist it on the next checkpoint.
        self.prop_rev_index_dirty = true;
    }

    /// PHASE G: bring the reverse map (prop_head -> node_id) in-memory to its
    /// covered_lsn BASE for the load/reconcile hydration branches. Loads the
    /// epoch-stamped snapshot when it is current; if it is absent or its stamp
    /// lags the manifest epoch (e.g. a light checkpoint did not restamp it),
    /// rebuild it from a live node scan (O(nodes), safe). On the reconcile
    /// branch the caller then applies the nodes-page tail on top of this base.
    fn hydratePropRevIndex(self: *GraphEngine) !void {
        if (self.prop_rev_index.loadFromFile(self.graph_dir.path) catch null) |stamp| {
            if (stamp.epoch == self.manifest.checkpoint_epoch) return;
        }
        try engine_index.buildPropRevIndexFromScan(self);
    }

    fn rebuildEdgeIndex(self: *GraphEngine) !void {
        return engine_index.rebuildEdgeIndex(self);
    }

    fn tryLoadDerivedIndexes(self: *GraphEngine) !engine_index.LoadOutcome {
        return engine_index.tryLoadDerivedIndexes(self);
    }

    /// TEST/introspection: order-independent content digest of the four derived
    /// indexes (label / property-chain / edge / edge-existence). Hydrates first.
    /// Two engines over the same store with equal digests are key-for-key
    /// identical — the assertion the WAL-tail reconcile == full-rebuild property
    /// test rests on.
    pub fn debugDerivedDigests(self: *GraphEngine) !DerivedDigests {
        try self.ensureDerivedHydrated();
        var d = DerivedDigests{ .label = 0, .property = 0, .edge = 0, .edge_exist = 0 };

        // label: sum over every (label_id, node_id) posting.
        var lit = self.label_index.index.iterator();
        while (lit.next()) |e| {
            var nit = e.value_ptr.keyIterator();
            while (nit.next()) |n| {
                var buf: [16]u8 = undefined;
                std.mem.writeInt(u64, buf[0..8], e.key_ptr.*, .little);
                std.mem.writeInt(u64, buf[8..16], n.*, .little);
                d.label +%= std.hash.Wyhash.hash(0xA1, &buf);
            }
        }

        // property: sum over every (prop_head, key, value_hash) chain entry.
        var cit = self.property_index.chains.iterator();
        while (cit.next()) |e| {
            const ph = e.key_ptr.*;
            for (e.value_ptr.entries.items) |entry| {
                var h = std.hash.Wyhash.init(0xB2);
                h.update(std.mem.asBytes(&ph));
                h.update(entry.key);
                h.update(std.mem.asBytes(&entry.value_hash));
                d.property +%= h.final();
            }
        }

        // edge: sum over every live edge_index record.
        const EC = struct { total: *u64 };
        var ec = EC{ .total = &d.edge };
        try self.edge_index.forEachLive(&ec, struct {
            fn f(c: *EC, edge_id: u64, e: EdgeIndexEntry) anyerror!void {
                var h = std.hash.Wyhash.init(0xC3);
                h.update(std.mem.asBytes(&edge_id));
                h.update(std.mem.asBytes(&e.from));
                h.update(std.mem.asBytes(&e.neighbor));
                h.update(std.mem.asBytes(&e.rel_type));
                h.update(std.mem.asBytes(&e.prop_head));
                h.update(std.mem.asBytes(&e.public_id));
                c.total.* +%= h.final();
            }
        }.f);

        // edge_exist: sum over every live (from, rel, to, edge_id) record.
        const XC = struct { total: *u64 };
        var xc = XC{ .total = &d.edge_exist };
        try self.edge_exist_index.forEachRecord(&xc, struct {
            fn f(c: *XC, from: u64, rel_type: u32, to: u64, edge_id: u64) anyerror!void {
                var buf: [28]u8 = undefined;
                std.mem.writeInt(u64, buf[0..8], from, .little);
                std.mem.writeInt(u32, buf[8..12], rel_type, .little);
                std.mem.writeInt(u64, buf[12..20], to, .little);
                std.mem.writeInt(u64, buf[20..28], edge_id, .little);
                c.total.* +%= std.hash.Wyhash.hash(0xD4, &buf);
            }
        }.f);

        return d;
    }

    /// TEST: force a full O(graph) rebuild of the derived indexes IN PLACE over
    /// the current store (releases any adopted mmap bases). Lets a test compare
    /// a tail-reconciled index against the ground-truth rebuild on the SAME
    /// on-disk pages. Does not touch metrics (the reconcile-open counters stay
    /// as observed).
    pub fn rebuildDerivedForTest(self: *GraphEngine) !void {
        try self.ensureDerivedHydrated();
        try engine_index.rebuildDerivedIndexes(self);
    }

    fn saveDerivedIndexes(self: *GraphEngine, covered_lsn: u64) !void {
        return engine_index.saveDerivedIndexes(self, covered_lsn);
    }

    /// Initializes `thread_pool` to either the caller-supplied pool (when
    /// `cfg.external_thread_pool` is set — borrowed) or a fresh
    /// `default_owned_pool_max_threads`-worker pool stored in
    /// `owned_thread_pool`. Both `create` and `open` route through this.
    fn initThreadPool(self: *GraphEngine, allocator: Allocator, cfg: GraphConfig) !void {
        if (cfg.external_thread_pool) |ext| {
            self.owned_thread_pool = null;
            self.thread_pool = ext;
            return;
        }
        // Pin .work_stealing explicitly and propagate init errors instead of
        // panicking — GraphEngine.create/open already return error unions, and
        // pool-init failure (OOM, spawn-failure) is a recoverable condition the
        // caller can retry or surface.
        self.owned_thread_pool = try tp.ThreadPool.init(allocator, .{
            .scheduler_variant = .work_stealing,
            // One submitter slot for the per-engine registerSubmitter
            // adoption (ensureSubmitterRegistered). Without this,
            // registerSubmitter returns error.NoSubmitterSlots because the
            // library default is 0.
            .max_submitter_queues = 1,
            .max_threads = default_owned_pool_max_threads,
        });
        self.thread_pool = &self.owned_thread_pool.?;
    }

    /// Lazily register the calling thread as a submitter. Idempotent at
    /// the Engine level — once `submitter_slot` is populated, repeated
    /// calls are no-ops.
    ///
    /// **Precondition:** callers must hold engine-level write serialization
    /// (checkpoint path or `close()` dirty-flush branch). The load-then-
    /// store sequence below is not synchronized, so concurrent entry
    /// from two threads would race and could leak a slot until pool
    /// deinit. The existing hot-flush paths (`engine_persist.checkpoint`
    /// and `close` when `persistence_dirty`) are single-writer by
    /// construction, which satisfies this.
    ///
    /// The first caller wins and that thread owns the slot lifecycle for
    /// descriptor-cache drain purposes. If that thread never calls a
    /// submit path again, the pool's deinit will drain residual cache
    /// entries.
    pub fn ensureSubmitterRegistered(self: *GraphEngine) void {
        if (self.submitter_slot != null) return;
        self.submitter_slot = self.thread_pool.registerSubmitter() catch null;
    }

    /// Clean up the graph engine and its storage resources.
    pub fn deinit(self: *GraphEngine) void {
        self.cleanupResources(self.allocator);
    }

    /// QUAL-0042: Free exactly the subsystems that `initSubsystems` allocated.
    ///
    /// `initSubsystems`' own `errdefer` guards only protect against a failure
    /// *inside* `initSubsystems`; they discharge once it returns successfully.
    /// The steps that run afterwards in `create`/`open` (initThreadPool,
    /// loadFreeStore, rebuildFreeSpaceFromDisk, label_dict.loadFromFile,
    /// rebuildDerivedIndexes) are therefore uncovered. This helper is installed
    /// via `errdefer self.cleanupSubsystems()` immediately after the
    /// `initSubsystems` call so those later failures no longer leak the WAL,
    /// txn manager, indexes, free-space managers, or the WAL directory handle.
    ///
    /// It deinits the same set, in the same order, as the corresponding portion
    /// of `cleanupResources`, but deliberately EXCLUDES the thread pool,
    /// buffer_pool, file_manager, graph_dir, key-zeroing, and `destroy(self)`:
    /// those are owned by the top-level `errdefer`s in `create`/`open` and
    /// freeing them here would double-free. The checkpointer holds no owned
    /// allocations of its own, mirroring `cleanupResources` which never deinits
    /// it.
    fn cleanupSubsystems(self: *GraphEngine) void {
        self.txn_manager.deinit();
        self.wal.deinit();
        self.wal_dir_handle.close(std.Io.Threaded.global_single_threaded.io());
        self.free_space_nodes.deinit();
        self.free_space_adj_out.deinit();
        self.free_space_adj_in.deinit();
        self.free_space_in_idx.deinit();
        self.free_space_in_dir.deinit();
        self.free_space_props.deinit();
        self.free_space_var.deinit();
        self.label_dict.deinit();
        self.label_index.deinit();
        self.property_index.deinit();
        self.prop_rev_index.deinit();
        self.edge_index.deinit();
        self.edge_exist_index.deinit();
        self.property_index_set.deinit();
        self.ordered_property_index.deinit();
    }

    /// Close the engine (flush, checkpoint, close files).
    ///
    /// Returns an error if the final checkpoint or label dictionary save fails.
    /// Resources are always cleaned up regardless of errors.
    pub fn close(self: *GraphEngine) !void {
        const allocator = self.allocator;

        // Persist current state
        self.manifest.next_txn_id = self.txn_manager.next_txn_id;
        self.manifest.label_count = self.label_dict.count();

        // Track the first error encountered during close
        var close_err: ?anyerror = null;

        if (self.persistence_dirty) {
            // Run a final synchronous checkpoint only when there are writes
            // that have not already been durably persisted.
            self.ensureSubmitterRegistered();
            // SONNY-6491: free.store is made durable inside the checkpoint,
            // before the manifest (engine_persist.checkpointSideFiles).
            engine_persist.refreshManifestCounters(self);
            self.checkpointer.doCheckpointWith(engine_persist.preManifestStep(self)) catch |err| {
                close_err = err;
            };
            // Phase A: only persist the derived-index snapshots when they were
            // materialized this session. If never hydrated, the resident indexes
            // are EMPTY and saving them would stamp empty snapshots at the
            // (checkpoint-advanced) manifest.counter — corrupting the next open's
            // clean-load. Skipping leaves the existing on-disk snapshots; the
            // counter gate on the next open detects the advance and rebuilds from
            // pages (correct, just not a fast clean-load). Any write this session
            // would have hydrated first, so a dirtied derived index is always
            // hydrated here.
            if (close_err == null and self.derived_hydrated.load(.acquire)) {
                // doCheckpoint above set manifest.last_checkpoint_lsn to the LSN
                // this checkpoint covered; stamp the snapshots with it as
                // covered_lsn (paired with the advanced checkpoint_epoch).
                self.saveDerivedIndexes(self.manifest.last_checkpoint_lsn) catch |err| {
                    if (close_err == null) close_err = err;
                };
                if (close_err == null) {
                    self.checkpointer.faultPoint(.post_derived) catch |err| {
                        close_err = err;
                    };
                }
            }
            if (close_err == null) {
                // GAP-0027: persist catalog + B+tree property indexes on close.
                engine_property_index.save(self) catch |err| {
                    if (close_err == null) close_err = err;
                };
            }
        }

        // H3-P4 #1+#2: refresh + persist the value-ordered index on close
        // whenever a registered ordered index exists — even when
        // persistence_dirty is false. This block is INTENTIONALLY outside the
        // `if (self.persistence_dirty)` gate above:
        //   #2: a trailing checkpointLight clears persistence_dirty (and already
        //       bumped + persisted manifest.counter) but saves NO ordered
        //       snapshot; without this block the next open finds no snapshot and
        //       LOSES the registration (planner heap fallback).
        // The REBUILD runs BEFORE saveToFile (#1): close() must not persist a
        // snapshot stamped at the current (epoch, covered_lsn) that the next
        // clean open LOADS as fresh while it is empty/stale. The online
        // label/property hooks only mark the tree stale; in-place value drift is
        // corrected here. After a successful rebuild `ordered_index_stale` is
        // false and the snapshot reflects every committed write as of the last
        // checkpoint.
        //
        // GAP-0050: stamp `(manifest.checkpoint_epoch, manifest.last_checkpoint_lsn)`
        // — the durable freshness token the next open() gates on (LOAD iff both
        // match). If the dirty block above ran doCheckpoint it advanced +
        // persisted BOTH; if persistence_dirty was false, the prior checkpoint
        // (light or full) already persisted the manifest at these values and no
        // write has happened since, so the rebuilt trees reflect exactly the
        // covered_lsn state. Neither path here re-bumps the manifest.
        if (close_err == null and self.ordered_property_index.count() > 0) {
            // H3-P4: rebuild only when the tree has drifted since the last refresh
            // (ordered_index_stale ⇔ a write occurred). A clean/no-op close skips the
            // full node scan — important at 14.27M nodes — but the SAVE always runs so
            // registration + the fresh tree persist (durability fix #2).
            if (self.ordered_index_stale) {
                self.rebuildOrderedIndex() catch |err| {
                    if (close_err == null) close_err = err;
                };
            }
            if (close_err == null) {
                self.ordered_property_index.saveToFile(
                    self.graph_dir.path,
                    self.manifest.checkpoint_epoch,
                    self.manifest.last_checkpoint_lsn,
                ) catch |err| {
                    if (close_err == null) close_err = err;
                };
                self.ordered_index_dirty = false;
            }
        }

        // Cleanup all resources (always runs)
        self.cleanupResources(allocator);

        // Return the first error encountered
        if (close_err) |err| return err;
    }

    /// Internal cleanup of all engine resources. Always runs on close,
    /// even when errors have occurred.
    fn cleanupResources(self: *GraphEngine, allocator: Allocator) void {
        // Phase 3 tail reconcile: free the captured tail-affected page set if
        // the reconcile never consumed it (e.g. an engine closed before any
        // derived-index first-access).
        if (self.tail_affected_pages) |pages| {
            allocator.free(pages);
            self.tail_affected_pages = null;
        }
        // Release the submitter slot before draining the pool. The TLS-
        // owner check inside releaseSubmitter (F-005) handles the case
        // where the engine was torn down from a thread other than the one
        // that first called ensureSubmitterRegistered — it becomes a free-
        // mask CAS with no cache drain, which is correct because the
        // pool's deinit path will scrub any residual cache entries.
        //
        // For borrowed pools (owned_thread_pool == null) we MUST still
        // release the slot — the slot belongs to this engine's lifecycle,
        // not the pool's. The caller may keep using other slots after we
        // close.
        if (self.submitter_slot) |idx| {
            self.thread_pool.releaseSubmitter(idx);
            self.submitter_slot = null;
        }

        // Only shut down + deinit a pool we own. Borrowed pools belong to
        // the caller, who is responsible for their lifetime (must outlive
        // every engine that borrows them — see GraphConfig docs).
        if (self.owned_thread_pool != null) {
            self.thread_pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
            self.thread_pool.deinit();
            self.owned_thread_pool = null;
        }
        self.txn_manager.deinit();
        self.wal.deinit();
        self.wal_dir_handle.close(std.Io.Threaded.global_single_threaded.io());
        self.free_space_nodes.deinit();
        self.free_space_adj_out.deinit();
        self.free_space_adj_in.deinit();
        self.free_space_in_idx.deinit();
        self.free_space_in_dir.deinit();
        self.free_space_props.deinit();
        self.free_space_var.deinit();
        self.label_dict.deinit();
        self.label_index.deinit();
        self.property_index.deinit();
        self.prop_rev_index.deinit();
        self.edge_index.deinit();
        self.edge_exist_index.deinit();
        self.property_index_set.deinit();
        self.ordered_property_index.deinit();
        self.buffer_pool.deinit();
        self.file_manager.deinit();
        self.graph_dir.deinit();

        // SEC-0003: Zero encryption key material before freeing memory
        self.config.zeroKey();

        allocator.destroy(self);
    }

    // ========================================================================
    // PHASE G — crash-reopen exact-index reconcile: public API for an EXTERNAL
    // derived index (e.g. geode's prop_exact.idx) to reconcile the bounded WAL
    // tail instead of a full O(graph) rebuild after a crash reopen. ADDITIVE:
    // pure reads over already-recovered state; no behaviour change to any
    // existing path.
    // ========================================================================

    /// G2. The durable checkpoint epoch (manifest.checkpoint_epoch). Advances
    /// ONLY at checkpoint, NEVER by a WAL-tail recovery — so an external index
    /// snapshot stamped at epoch E stays valid-as-of its covered LSN across a
    /// crash reopen (a genuine mismatch means a checkpoint ran after it). On a
    /// sharded engine this is PER-SHARD; geode compares its per-graph
    /// prop_exact.idx against the owning shard's value
    /// (`sge.shard(s).checkpointEpoch()`).
    pub fn checkpointEpoch(self: *GraphEngine) u64 {
        return self.manifest.checkpoint_epoch;
    }

    /// G2. The durable committed frontier AFTER recovery
    /// (manifest.last_checkpoint_lsn): a checkpoint sets it to the checkpoint
    /// LSN; a WAL-tail recovery bumps it to the replayed tail end. An external
    /// index whose covered_lsn < this has a committed tail to reconcile.
    pub fn durableFrontierLsn(self: *GraphEngine) u64 {
        return self.manifest.last_checkpoint_lsn;
    }

    /// G2. The durable committed frontier as it stood BEFORE this session's
    /// recovery replayed (Path B's `tail_pre_recovery_lsn`). A sound
    /// single-recovery reconcile requires the on-disk snapshot's covered_lsn ==
    /// this value; if covered_lsn < this, a PRIOR un-checkpointed recovery
    /// advanced the frontier past the snapshot and the captured tail slice is
    /// incomplete → the external index must full-rebuild. Equals
    /// durableFrontierLsn() on a clean reopen (no tail replayed).
    pub fn preRecoveryFrontierLsn(self: *GraphEngine) u64 {
        return self.tail_pre_recovery_lsn;
    }

    /// G1. Resolve the recovery tail-affected PAGE set captured by Path B
    /// (`tail_affected_pages`) to the OWNING node ids, for an external derived
    /// index that reconciles the bounded WAL tail after a crash reopen.
    ///
    /// THREE-WAY signal (a thin pass-through of the core
    /// `resolveTailAffectedNodeIds`, kept distinct so "rebuild required" is
    /// never mistaken for "nothing to do"):
    ///   * `null`             — a full REBUILD is required: the affected-page
    ///     capture was unavailable / overflowed, or a tail props slot could not
    ///     be attributed to a node. The external index MUST rebuild wholesale.
    ///   * non-null EMPTY     — nothing to reconcile: a clean reopen, or a
    ///     committed tail that touched no node-owning pages. The external index
    ///     is already current.
    ///   * non-null non-empty — the resolved (super)set of affected node ids
    ///     (owned, ascending, deduped; caller frees with `allocator.free`).
    /// Collapsing `null` into an empty slice would let a caller read "rebuild
    /// required" as "nothing to do" ⇒ a stale external index ⇒ silently-wrong
    /// query results; the distinct `null` prevents exactly that. A non-null set
    /// is never a partial-but-complete-looking slice (empty-on-doubt mirrors
    /// Path B — genuine doubt returns `null`, never a truncated set).
    ///
    /// LIFECYCLE: reads `tail_affected_pages` without consuming it, but gs's
    /// own lazy derived hydration frees that set on first access — so the
    /// external reconcile MUST call this after open() and BEFORE the first
    /// accessor that triggers derived hydration.
    pub fn tailAffectedNodeIds(self: *GraphEngine, allocator: Allocator) !?[]NodeId {
        return self.resolveTailAffectedNodeIds(allocator);
    }

    /// G1 core (also the per-shard primitive the ShardedGraphEngine aggregate
    /// consumes). Three outcomes:
    ///   * `null`  — a full REBUILD is required: a committed tail advanced the
    ///     durable frontier but the affected-page capture is unavailable
    ///     (overflow / capture off → `tail_affected_pages` null while
    ///     `had_tail`), OR a tail props slab slot cannot be attributed to a node
    ///     (the reverse map was absent, or a non-slab legacy page — see below).
    ///   * non-null EMPTY — nothing to reconcile (a clean reopen: no committed
    ///     tail; or a tail that touched no node-owning pages).
    ///   * non-null non-empty — the resolved (super)set of affected node ids.
    /// The `null` vs empty distinction lets the sharded aggregate poison the
    /// whole result on any single shard that needs a rebuild without confusing
    /// it with a clean shard.
    ///
    /// SOUNDNESS. NODES-page entries decode directly to node ids by the SAME
    /// page→node slot arithmetic reconcileOneNode uses
    /// (`node_id = page_id*nodes_per_page + slot`); every allocated slot on an
    /// affected nodes page is included (live AND tombstoned — a deleted node's
    /// external postings must be evicted). A nodes page is shared by
    /// nodes_per_page nodes and the WAL granularity is the whole page, so the
    /// set is a harmless SUPERSET (re-deriving an unchanged page-mate is a
    /// no-op for the caller).
    ///
    /// PROPS pages (resolved via the reverse map). An IN-PLACE property value
    /// mutation rewrites ONLY the props page (putPropertyTxnImpl logs `.props`,
    /// never the node record) so the changed node is on NO tail nodes page; a
    /// slab props page is shared by many nodes and stores no owner. The
    /// `prop_head→node` reverse map (prop_rev_index.zig) inverts this: for every
    /// LIVE slab slot on a tail props page, if its head is already in N (a
    /// tail-new / relocated node) it is covered, else the reverse map resolves it
    /// to its EXISTING owner (the in-place-changed node, or a fill-page
    /// co-tenant added as a harmless superset). A slot resolvable by NEITHER
    /// (the reverse map was absent / not loaded) or a non-slab legacy chain page
    /// → `null` (rebuild — the safe fallback). This closes the in-place
    /// value-change and ingest checkpoint-boundary fill-page cases that the
    /// nodes-page pass alone could not. The reverse map is loaded on demand from
    /// its covered_lsn snapshot when this runs before hydration.
    pub fn resolveTailAffectedNodeIds(self: *GraphEngine, allocator: Allocator) !?[]NodeId {
        const had_tail = self.manifest.last_checkpoint_lsn > self.tail_pre_recovery_lsn;
        const pages = self.tail_affected_pages orelse {
            // No captured set: a committed tail with no capture (overflow /
            // off) → rebuild; a clean reopen (no tail) → nothing to reconcile.
            if (had_tail) return null;
            return try allocator.alloc(NodeId, 0);
        };

        // Pass 1 — nodes pages → node-id set N and the set of N's current
        // prop_heads (used to attribute tail props pages in pass 2).
        var node_set: std.AutoHashMapUnmanaged(NodeId, void) = .empty;
        defer node_set.deinit(allocator);
        var head_set: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer head_set.deinit(allocator);
        const npp = self.node_store.nodes_per_page;
        const max_node = self.manifest.next_node_id;
        for (pages) |p| {
            if (p.file_id != .nodes) continue;
            var slot: u64 = 0;
            while (slot < npp) : (slot += 1) {
                const node_id = p.page_id * npp + slot;
                if (node_id >= max_node) break;
                const rec = (try self.node_store.getRawSlot(node_id)) orelse continue;
                try node_set.put(allocator, node_id, {});
                if (rec.prop_head != 0) try head_set.put(allocator, rec.prop_head, {});
            }
        }

        // PHASE G resolution: a tail props-page slot resolves to its OWNING node
        // via the reverse map. Load its covered_lsn snapshot on demand when this
        // runs BEFORE hydration (the documented lifecycle); when already
        // hydrated the in-memory map is current — use it as-is. Only paid when
        // the tail actually touched a props page.
        var has_props = false;
        for (pages) |p| {
            if (p.file_id == .props) {
                has_props = true;
                break;
            }
        }
        if (has_props and !self.derived_hydrated.load(.acquire)) {
            _ = self.prop_rev_index.loadFromFile(self.graph_dir.path) catch {};
        }

        // Pass 2 — props pages: attribute every LIVE slab slot to a node. It is
        // already in N (tail-new / relocated → its head is in H_N), or the
        // reverse map resolves it to its existing owner (an in-place value change
        // or a fill-page co-tenant — added as a harmless superset; re-deriving an
        // unchanged co-tenant is a caller no-op). A slot resolvable by NEITHER
        // (reverse map absent / incomplete) or a non-slab legacy page → rebuild.
        for (pages) |p| {
            if (p.file_id != .props) continue;
            const Ctx = struct {
                heads: *std.AutoHashMapUnmanaged(u64, void),
                rev: *PropRevIndex,
                node_set: *std.AutoHashMapUnmanaged(NodeId, void),
                allocator: Allocator,
                ok: bool,
            };
            var ctx = Ctx{
                .heads = &head_set,
                .rev = &self.prop_rev_index,
                .node_set = &node_set,
                .allocator = allocator,
                .ok = true,
            };
            self.prop_store.forEachSlabSlotOnPage(p.page_id, &ctx, struct {
                fn f(c: *Ctx, prop_head: u64, live: bool) anyerror!void {
                    if (!live) return;
                    if (c.heads.contains(prop_head)) return; // already in N (tail-new/relocated)
                    if (c.rev.get(prop_head)) |owner| {
                        try c.node_set.put(c.allocator, owner, {}); // existing owner
                        return;
                    }
                    c.ok = false; // unresolvable → rebuild (safe fallback)
                }
            }.f) catch |e| switch (e) {
                error.NotSlabPage => return null, // legacy/undecodable page → rebuild
                else => return e,
            };
            if (!ctx.ok) return null;
        }

        const out = try allocator.alloc(NodeId, node_set.count());
        errdefer allocator.free(out);
        var it = node_set.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) out[i] = k.*;
        std.mem.sort(NodeId, out, {}, std.sort.asc(NodeId));
        return out;
    }

    /// Get a GraphStorage interface backed by this engine.
    pub fn storage(self: *GraphEngine) GraphStorage {
        return GraphStorage.init(GraphEngine, self);
    }

    // ── Integrity and stats (delegated to engine_integrity.zig) ────────

    pub const StorageStats = engine_integrity.StorageStats;
    pub const IntegrityReport = engine_integrity.IntegrityReport;

    pub fn getMetrics(self: *GraphEngine) *const Metrics {
        return engine_integrity.getMetrics(self);
    }

    pub fn getStorageStats(self: *GraphEngine) StorageStats {
        return engine_integrity.getStorageStats(self);
    }

    pub fn checkIntegrity(self: *GraphEngine) anyerror!IntegrityReport {
        return engine_integrity.checkIntegrity(self);
    }

    // ========================================================================
    // Internal: WAL page logging helper
    // ========================================================================

    /// Pin a page, log its current contents to the WAL, and unpin it.
    fn logPage(self: *GraphEngine, txn_id: u64, file_id: FileId, page_id: u64) anyerror!void {
        const frame = try self.buffer_pool.pin(file_id, page_id);
        const frame_idx = self.buffer_pool.frameIndex(frame);
        defer self.buffer_pool.unpin(frame_idx, false);
        _ = try self.txn_manager.logPageUpdate(txn_id, @intFromEnum(file_id), page_id, frame.dataSlice());
    }

    /// GAP adjacency slab packing (P2): WAL-image every page an AdjStore
    /// mutation dirtied. An addEdge return value is a chain HEAD, which is no
    /// longer always a page id (slab heads encode tag|block|slot) and one
    /// mutation can dirty several pages (a slab relocation tombstones the old
    /// block and appends to the fill block; a graduation additionally writes
    /// the fresh legacy chain). Logging the raw head would image a bogus page
    /// (slab) or under-log (multi-page). The store records the exact dirtied
    /// set; with slab packing off it is exactly the one block a legacy
    /// head-insert touched (== the returned head), so imaging is unchanged.
    fn logTouchedAdj(self: *GraphEngine, txn_id: u64, file_id: FileId, store: *const AdjStore) anyerror!void {
        for (store.touchedPages()) |p| try self.logPage(txn_id, file_id, p);
    }

    /// WAL-image every page of a var-store chain (labels live there).
    ///
    /// Found by the GAP-ENT-0011 acceptance test: a var-store `ref` is
    /// `first_page << 16`, NOT a page id. The label write paths used to log
    /// the raw ref, imaging a far-away (nonexistent) page and leaving the
    /// REAL label-block pages out of the WAL — so labels written since the
    /// last checkpoint silently vanished on crash recovery.
    fn logVarChain(self: *GraphEngine, txn_id: u64, ref: u64) anyerror!void {
        if (ref == 0) return;
        // GAP var-store slab packing (P2): a slab head packs (block, slot), NOT
        // a `first_page << 16` ref — the whole var-chain is ONE shared slab
        // block (never chained). Image that single block; walking it as a page
        // chain would trip the marker/data_len guard AND miss the real page.
        // This is the GAP-ENT-0030-critical decode: image the DECODED page id,
        // never the raw head. Must be slab-aware BEFORE any slab head is ever
        // persisted (landed ahead of the slab writer for exactly this reason).
        if (var_store_mod.isSlabHead(ref)) {
            const page_id = var_store_mod.slabHeadPageId(ref);
            if (page_id == 0) return error.DataCorruption; // page 0 reserved (F1)
            return self.logPage(txn_id, .var_store, page_id);
        }
        var current = var_store_mod.VarStore.refFirstPage(ref);
        var hops: u32 = 0;
        while (current != 0) : (hops += 1) {
            if (hops >= 100_000) return error.CircularChainDetected;
            try self.logPage(txn_id, .var_store, current);
            current = try self.var_store.nextChainPage(current);
        }
    }

    /// Edge co-location (Phase B): public `logPage` for the migration rebuild
    /// (`engine_index.migrateColocateInEdges`), which lives in a sibling module
    /// but must log dirty in-index pages under the migration txn exactly like the
    /// hot write path.
    pub fn logPagePublic(self: *GraphEngine, txn_id: u64, file_id: FileId, page_id: u64) anyerror!void {
        return self.logPage(txn_id, file_id, page_id);
    }

    /// Edge co-location (Phase B): zero a page (pin-or-create), mark it dirty and
    /// log it under `txn_id`. Used by the migration to wipe stale `in_dir`
    /// directory pages so a crashed prior migration cannot leave a stale
    /// dst->head mapping. Crash-durable because the zeroed image is WAL-logged.
    pub fn zeroPageLogged(self: *GraphEngine, txn_id: u64, file_id: FileId, page_id: u64) anyerror!void {
        const frame = try self.buffer_pool.pin(file_id, page_id);
        const frame_idx = self.buffer_pool.frameIndex(frame);
        @memset(frame.dataSlice(), 0);
        _ = try self.txn_manager.logPageUpdate(txn_id, @intFromEnum(file_id), page_id, frame.dataSlice());
        self.buffer_pool.unpin(frame_idx, true);
    }

    /// Edge co-location (Phase B): rebuild this shard's `adj_in_remote` from its
    /// out-adjacency (the authoritative, layout-independent edge set), making the
    /// shard's reverse-traversal source-of-truth co-located. Idempotent +
    /// crash-safe; see `engine_index.migrateColocateInEdges`. The CALLER stamps
    /// the manifest `layout_version` after a successful checkpoint.
    pub fn migrateColocateInEdges(self: *GraphEngine) anyerror!void {
        try self.ensureWritable();
        return engine_index.migrateColocateInEdges(self);
    }

    /// SONNY-6461: restore the adjacency entries graph_storage <= 0.4.11 lost
    /// to the AES-GCM tag of its page-encryption envelope (SONNY-6441, fixed in
    /// 0.4.12). The library owns the layout knowledge: which slot of which
    /// chain-block format lost which bytes at this page size
    /// (`edge.legacyTailLoss`). Every chain reachable from a node record or the
    /// co-located in-edge directory is walked; each entry in such a slot is
    /// matched by edge id to the same edge in the other direction (`in_idx`
    /// for an outgoing entry, else the destination's `adj_in`; the source's
    /// `adj_out` for an incoming entry) and, when that copy is intact and
    /// differs, the lost fields are copied back and WAL-logged. When outgoing
    /// entries change the derived edge indexes are rebuilt.
    ///
    /// Idempotent: a second call finds every entry consistent. A plaintext
    /// store returns at once (`encrypted == false`; nothing was lost). Entries
    /// it cannot restore are listed with the reason; nothing is guessed. The
    /// caller owns the report (`deinit`).
    ///
    /// Run it with the engine otherwise idle (no concurrent writers), right
    /// after opening a store last written by <= 0.4.11 and BEFORE any other
    /// write: a later `removeEdge` in the same block moves the damaged last
    /// entry into another slot, where it is no longer recognisable. It does
    /// not re-attach an incoming chain whose `in_dir` head was itself lost
    /// (`migrateColocateInEdges` rebuilds those from `adj_out`; run it after
    /// this repair so the rebuild copies repaired entries). Checkpoint after.
    pub fn repairAdjTailEntries(self: *GraphEngine, allocator: Allocator) anyerror!AdjTailRepairReport {
        return engine_adj_repair.repairAdjTailEntries(self, allocator);
    }

    /// Compute the page ID for a given node ID.
    fn nodePageId(self: *const GraphEngine, node_id: NodeId) u64 {
        return node_id / self.node_store.nodes_per_page;
    }

    // ========================================================================
    // VTable implementation methods (called via GraphStorage interface)
    // ========================================================================

    pub fn getNode(self: *GraphEngine, id: NodeId) anyerror!?NodeRec {
        var __obs_span = observability.startOperationSpan("get_node");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));
        const result = try self.node_store.getNode(id);
        observability.endOperationSpan(__obs_span, true, "");
        return result;
    }

    /// Put a node within an existing transaction (no auto-commit).
    pub fn putNodeTxn(self: *GraphEngine, id: NodeId, rec: NodeRec, txn: TxnId) anyerror!void {
        try self.ensureWritable();
        try self.node_store.putNode(id, rec);
        try self.logPage(txn, .nodes, self.nodePageId(id));
        // PHASE G reverse map: record this node's current prop_head -> id when the
        // derived indexes are hydrated (a fresh graph is hydrated from creation;
        // a reopened graph's pre-hydration writes are captured by the hydration
        // scan instead — so this never forces a hydration on the write path).
        // put() no-ops for prop_head==0; overwriting is exactly the rebuild
        // result for slab-slot reuse. In-memory only — no write amplification.
        if (rec.prop_head != 0 and self.derived_hydrated.load(.acquire)) {
            try self.prop_rev_index.put(rec.prop_head, id);
            self.prop_rev_index_dirty = true;
        }
        self.markDirty();
    }

    /// Put a node with auto-commit (backward compatible).
    pub fn putNode(self: *GraphEngine, id: NodeId, rec: NodeRec) anyerror!void {
        var __obs_span = observability.startOperationSpan("put_node");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        try self.putNodeTxn(id, rec, txn);

        try self.txn_manager.commit(txn);
        observability.endOperationSpan(__obs_span, true, "");
    }

    pub fn allocNode(self: *GraphEngine) anyerror!NodeId {
        var __obs_span = observability.startOperationSpan("alloc_node");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        try self.ensureWritable();
        const id = self.manifest.next_node_id;
        const stride: u64 = if (self.config.base_shard_index != null)
            @intCast(@import("sharded_store.zig").SHARD_COUNT)
        else
            1;
        self.manifest.next_node_id += stride;
        self.manifest.node_count += 1;
        self.metrics.nodes_created += 1;
        self.markDirty();
        observability.endOperationSpan(__obs_span, true, "");
        return id;
    }

    /// Delete a node within an existing transaction (no auto-commit).
    pub fn deleteNodeTxn(self: *GraphEngine, id: NodeId, txn: TxnId) anyerror!void {
        try self.ensureWritable();
        // H3-P1: before the record is gone, remove the node's entries from any
        // ordered index whose label it carries. Gated on a registered ordered
        // index existing, so the common path adds no extra read.
        if (self.ordered_property_index.count() > 0) {
            if (try self.node_store.getNode(id)) |rec| {
                try self.orderedIndexOnDeleteNode(id, rec);
            }
            // H3-P4: a delete changes index membership; the trees are stale
            // until the next rebuild at the durability boundary.
            self.ordered_index_stale = true;
        }
        // PHASE G reverse map: drop this node's prop_head -> id before the record
        // is tombstoned (deleteNode keeps prop_head, but read it now to be
        // explicit). Only when hydrated (see putNodeTxn). In-memory only.
        if (self.derived_hydrated.load(.acquire)) {
            if (try self.node_store.getRawSlot(id)) |rec| {
                if (rec.prop_head != 0) {
                    self.prop_rev_index.remove(rec.prop_head);
                    self.prop_rev_index_dirty = true;
                }
            }
        }
        try self.node_store.deleteNode(id);
        try self.logPage(txn, .nodes, self.nodePageId(id));

        if (self.manifest.node_count > 0) {
            self.manifest.node_count -= 1;
        }
        self.metrics.nodes_deleted += 1;
        self.markDirty();
    }

    /// Delete a node with auto-commit (backward compatible).
    pub fn deleteNode(self: *GraphEngine, id: NodeId) anyerror!void {
        var __obs_span = observability.startOperationSpan("delete_node");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        try self.deleteNodeTxn(id, txn);

        try self.txn_manager.commit(txn);
        observability.endOperationSpan(__obs_span, true, "");
    }

    /// Look up an edge by its ID using the in-memory edge index.
    /// Returns the EdgeEntry if found, null otherwise.
    pub fn getEdge(self: *GraphEngine, edge_id: EdgeId) anyerror!?EdgeEntry {
        var __obs_span = observability.startOperationSpan("get_edge");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        try self.ensureDerivedHydrated(); // Phase A: edge_index is deferred.
        const entry = (try self.edge_index.get(edge_id)) orelse {
            observability.endOperationSpan(__obs_span, true, "");
            return null;
        };
        observability.endOperationSpan(__obs_span, true, "");
        return EdgeEntry{
            .neighbor = entry.neighbor,
            .edge_id = edge_id,
            .rel_type = entry.rel_type,
            .prop_head = entry.prop_head,
            // P3: the edge_index-sourced route surfaces the SAME public_id the
            // adjacency-sourced routes (expand*/FanIn) yield for this edge.
            .public_id = entry.public_id,
        };
    }

    /// PHASE 3: O(1) edge-existence probe. Returns the COMPLETE set of edge ids
    /// whose tuple is exactly `(from, rel_type, to)`, copied into caller-owned
    /// `out`. Empty slice when none. The common one-edge tuple is a single
    /// hashmap lookup; a parallel-edge tuple returns all candidates so a higher
    /// layer (e.g. geode tenant disambiguation) preserves exact MERGE semantics.
    /// Cost is independent of the source node's out-degree — that is the
    /// throughput unlock that replaces the O(out-degree) adjacency dedup scan.
    pub fn probeEdge(self: *GraphEngine, from: NodeId, rel_type: u32, to: NodeId, out: []EdgeId) anyerror![]const EdgeId {
        try self.ensureDerivedHydrated(); // Phase A: edge_exist_index is deferred.
        return self.edge_exist_index.probe(from, rel_type, to, out);
    }

    /// Behavioral O(1) proof: candidate edge ids walked on the most recent
    /// `probeEdge` (== bucket size for the matched key, NOT the parent degree).
    pub fn lastProbeEntriesExamined(self: *const GraphEngine) usize {
        return self.edge_exist_index.last_probe_entries_examined;
    }

    /// Total (key, edge_id) records in the edge-existence index. Equals the
    /// number of edges it represents — used by tests to cross-check that the
    /// existence index agrees record-for-record with the edge_index (both are
    /// derived from the same adjacency scan, so they must match exactly).
    pub fn edgeExistRecordCount(self: *const GraphEngine) usize {
        // Phase A: edge_exist_index is deferred. This introspection helper has a
        // non-error const signature, so materialize via a mutable view and
        // ignore a (rare) materialize error — a failed build leaves the count 0,
        // and the error surfaces on the real query paths that return errors.
        @constCast(self).ensureDerivedHydrated() catch {};
        return self.edge_exist_index.recordCount();
    }

    /// Number of edges in the edge_index (the O(1) getEdge lookup map).
    pub fn edgeIndexCount(self: *const GraphEngine) usize {
        // Phase A: edge_index is deferred (see edgeExistRecordCount note).
        @constCast(self).ensureDerivedHydrated() catch {};
        return self.edge_index.count();
    }

    /// Zero-copy outgoing-edge iterator (no result-sized allocation). The
    /// returned `AdjEdgeIterator` borrows the source node's adjacency pages and
    /// pins the current page; the caller MUST call `deinit()` to unpin it.
    /// Yielded `EdgeEntry` values are copies and remain valid after `deinit()`.
    pub fn expandOutIter(self: *GraphEngine, id: NodeId, rel_type: ?u32) anyerror!AdjStore.AdjEdgeIterator {
        const rec = try self.node_store.getNode(id);
        return self.adj_out.expand(if (rec) |r| r.out_head else 0, rel_type);
    }

    /// Collect all outgoing edges into a heap-allocated slice.
    /// Caller owns the returned `[]EdgeEntry` and must free it with the same
    /// `allocator` passed in (e.g. `allocator.free(result)`). Each `EdgeEntry`
    /// is a plain value with no inner heap pointers, so freeing the slice is
    /// sufficient. For a zero-copy alternative that allocates no result slice,
    /// use `expandOutIter`.
    pub fn expandOut(self: *GraphEngine, id: NodeId, rel_type: ?u32, allocator: Allocator) anyerror![]EdgeEntry {
        var __obs_span = observability.startOperationSpan("expand_out");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        var iter = try self.expandOutIter(id, rel_type);
        defer iter.deinit();
        const result = try drainEdgeIterator(&iter, allocator);
        observability.endOperationSpan(__obs_span, true, "");
        return result;
    }

    /// Zero-copy incoming-edge iterator (no result-sized allocation).
    /// Ownership/lifetime rules match `expandOutIter`: the iterator pins a page
    /// and the caller MUST call `deinit()` to unpin it.
    pub fn expandInIter(self: *GraphEngine, id: NodeId, rel_type: ?u32) anyerror!AdjStore.AdjEdgeIterator {
        const rec = try self.node_store.getNode(id);
        return self.adj_in.expand(if (rec) |r| r.in_head else 0, rel_type);
    }

    /// Collect all incoming edges into a heap-allocated slice.
    /// Caller owns the returned `[]EdgeEntry` and must free it with the same
    /// `allocator` passed in. For a zero-copy alternative use `expandInIter`.
    pub fn expandIn(self: *GraphEngine, id: NodeId, rel_type: ?u32, allocator: Allocator) anyerror![]EdgeEntry {
        var __obs_span = observability.startOperationSpan("expand_in");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        var iter = try self.expandInIter(id, rel_type);
        defer iter.deinit();
        const result = try drainEdgeIterator(&iter, allocator);
        observability.endOperationSpan(__obs_span, true, "");
        return result;
    }

    /// Drain an AdjEdgeIterator into a heap-allocated slice.
    fn drainEdgeIterator(iter: *AdjStore.AdjEdgeIterator, allocator: Allocator) anyerror![]EdgeEntry {
        var list = try std.ArrayList(EdgeEntry).initCapacity(allocator, 16);
        errdefer list.deinit(allocator);
        while (try iter.next()) |entry| {
            try list.append(allocator, entry);
        }
        return list.toOwnedSlice(allocator);
    }

    /// Add an edge within an existing transaction (no auto-commit).
    pub fn addEdgeTxn(self: *GraphEngine, from: NodeId, to: NodeId, rel_type: u32, txn: TxnId) anyerror!EdgeId {
        try self.ensureWritable();
        // Phase A: this mutates edge_index + edge_exist_index — materialize them
        // first so the write lands on the fully-populated resident index.
        try self.ensureDerivedHydrated();
        const edge_id = self.manifest.next_edge_id;
        const stride: u64 = if (self.config.base_shard_index != null)
            @intCast(@import("sharded_store.zig").SHARD_COUNT)
        else
            1;
        self.manifest.next_edge_id += stride;

        const entry = EdgeEntry{
            .neighbor = to,
            .edge_id = edge_id,
            .rel_type = rel_type,
            .prop_head = 0,
            // Legacy (pre-public-id) API: 0 = no inline id by design. Callers
            // on this path persist the public id as the
            // `__geode_internal_edge_id` property; readers fall back to it for
            // public_id == 0 entries.
            .public_id = 0,
        };

        // Update source node's out adjacency list
        var from_rec = try self.node_store.getNode(from) orelse return error.NodeNotFound;
        const new_out_head = try self.adj_out.addEdge(from_rec.out_head, entry);
        // GAP-ENT-0022(b): a slab relocation/graduation inside addEdge already
        // tombstoned the old slot; if anything below errors the caller keeps
        // the old head, so roll the tombstone back to keep it referencing a
        // live run (no-op for legacy/in-slab writes).
        errdefer self.adj_out.undoLastSlabTombstone() catch {};
        from_rec.out_head = new_out_head;
        try self.node_store.putNode(from, from_rec);

        // Update target node's in adjacency list
        const in_entry = EdgeEntry{
            .neighbor = from,
            .edge_id = edge_id,
            .rel_type = rel_type,
            .prop_head = 0,
            .public_id = 0, // legacy path — see out-entry comment above
        };
        var to_rec = try self.node_store.getNode(to) orelse return error.NodeNotFound;
        const new_in_head = try self.adj_in.addEdge(to_rec.in_head, in_entry);
        errdefer self.adj_in.undoLastSlabTombstone() catch {};
        to_rec.in_head = new_in_head;
        try self.node_store.putNode(to, to_rec);

        // Log all dirty pages: adj_out page(s), adj_in page(s), from-node page,
        // to-node page. Adjacency heads are imaged via the store's touched set
        // (a head may be a slab (block,slot) ref; one write may dirty several).
        try self.logTouchedAdj(txn, .adj_out, &self.adj_out);
        try self.logTouchedAdj(txn, .adj_in, &self.adj_in);
        try self.logPage(txn, .nodes, self.nodePageId(from));
        // Avoid duplicate log if from and to share the same node page
        const to_page = self.nodePageId(to);
        if (to_page != self.nodePageId(from)) {
            try self.logPage(txn, .nodes, to_page);
        }

        // Maintain in-memory edge index for O(1) getEdge lookups
        try self.edge_index.put(edge_id, .{
            .from = from,
            .neighbor = to,
            .rel_type = rel_type,
            .prop_head = 0,
            // Legacy add path: no public id (matches the 0 written into the
            // adjacency entries above — readers use the property fallback).
            .public_id = 0,
        });
        self.edge_index_dirty = true;

        // PHASE 3: maintain the edge-EXISTENCE index in the SAME logical step as
        // the edge so a probe is crash-consistent with adjacency. Keyed on
        // (from, rel_type, to). Co-located with edge_index.put above.
        try self.edge_exist_index.put(from, rel_type, to, edge_id);
        self.edge_exist_index_dirty = true;

        self.manifest.edge_count += 1;
        self.metrics.edges_created += 1;
        self.markDirty();

        return edge_id;
    }

    /// Add an edge with auto-commit (backward compatible).
    pub fn addEdge(self: *GraphEngine, from: NodeId, to: NodeId, rel_type: u32) anyerror!EdgeId {
        var __obs_span = observability.startOperationSpan("add_edge");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        const edge_id = try self.addEdgeTxn(from, to, rel_type, txn);

        // GAP-ENT-0022(b): a COMMIT failure is the last window in which this op
        // errors after a slab relocation/graduation tombstoned an old slot
        // while the caller keeps the old head — roll both stores' tombstones
        // back (no-op for legacy writes). The aborted txn's images never replay.
        errdefer self.adj_out.undoLastSlabTombstone() catch {};
        errdefer self.adj_in.undoLastSlabTombstone() catch {};

        try self.txn_manager.commit(txn);
        observability.endOperationSpan(__obs_span, true, "");

        return edge_id;
    }

    /// Edge co-location (Phase A): add an edge whose SOURCE is on THIS shard,
    /// recording EVERYTHING on this shard so the write is a single-engine,
    /// single-txn (crash-consistent) operation — even when `to` lives on another
    /// shard. Unlike `addEdgeTxn`, this does NOT touch `to`'s node record (it is
    /// not resident here); the edge's incoming adjacency goes into THIS shard's
    /// `adj_in_remote` chain, whose head is held in `in_head_dir[to]` rather than
    /// in `to.in_head`. `ShardedGraphEngine.expandIn(to)` finds it by scattering
    /// the directory probe across all shards.
    ///
    /// One in-edge code path: even a same-shard edge (shard(from)==shard(to))
    /// routes its in-entry through `adj_in_remote`, not `to.in_head`, so reverse
    /// traversal has a single uniform source of truth (the legacy `NodeRec.in_head`
    /// field is left write-dead for new edges).
    pub fn addEdgeColocatedTxn(self: *GraphEngine, from: NodeId, to: NodeId, rel_type: u32, txn: TxnId) anyerror!EdgeId {
        return self.addEdgeColocatedTxnWithPublicId(from, to, rel_type, txn, 0);
    }

    /// GAP-ENT-0024 P2: co-located edge add carrying the caller's 64-bit
    /// PUBLIC edge id (geode-minted) INLINE in BOTH durable adjacency records
    /// (adj_out + adj_in_remote) — new blocks are v2 so the id persists, and
    /// AdjStore never truncates a real id into a legacy v1 tail block (it
    /// allocates a fresh v2 block instead). `public_id == 0` means "no public
    /// id" (legacy callers; readers fall back to the id property).
    ///
    /// CONTRACT — create-node-before-edge (GAP-ENT-0037, 0027-train review
    /// I2): `to` must already have been putNode'd DURABLY (its create
    /// committed to the WAL of the shard that owns it) before this call.
    /// This function deliberately never touches `to`'s node record (`to` may
    /// live on another shard), so nothing in the write itself can enforce
    /// or repair the invariant. If it is violated — `to` was allocNode'd but
    /// its putNode never became durable (caller skipped it, or a crash under
    /// deferred WAL lost shard(to)'s create while THIS shard's edge commit
    /// survived: the pre-existing cross-shard-atomicity gap) — then after a
    /// crash the id-counter heal cannot see `to` (no node record in any
    /// replayed image), recovery re-issues its id, and the surviving
    /// in-edge silently ALIASES onto whatever unrelated node is created
    /// under the re-issued id. geode always putNodes before edges; any new
    /// caller must do the same. Debug builds assert the resident-shard half
    /// of the contract below; the cross-shard half is uncheckable here by
    /// construction. No release-mode behavior change (stays fail-open —
    /// this is a documented contract, not a validation gate).
    pub fn addEdgeColocatedTxnWithPublicId(self: *GraphEngine, from: NodeId, to: NodeId, rel_type: u32, txn: TxnId, public_id: u64) anyerror!EdgeId {
        try self.ensureWritable();
        // Phase A: mutates edge_index + edge_exist_index — materialize first.
        try self.ensureDerivedHydrated();

        // GAP-ENT-0037: debug-only contract check (see doc comment). Only the
        // resident half is checkable: when `to` routes to THIS engine
        // (standalone, or `to`'s residue class is this shard's), its node
        // record must already exist. A cross-shard `to` is not resident here
        // and cannot be probed without breaking single-shard write locality.
        if (comptime builtin.mode == .Debug) {
            const to_resident = if (self.config.base_shard_index) |base|
                to % @as(u64, @intCast(@import("sharded_store.zig").SHARD_COUNT)) == @as(u64, @intCast(base))
            else
                true;
            if (to_resident) {
                const to_exists = ((self.node_store.getNode(to) catch null) != null);
                if (!to_exists) {
                    std.debug.panic(
                        "addEdgeColocatedTxnWithPublicId: `to`={d} has no node record on its owning shard — the create-node-before-edge contract was violated (putNode `to` durably before adding edges to it; a dangling in-edge would alias onto a re-issued node id after crash recovery)",
                        .{to},
                    );
                }
            }
        }
        const edge_id = self.manifest.next_edge_id;
        const stride: u64 = if (self.config.base_shard_index != null)
            @intCast(@import("sharded_store.zig").SHARD_COUNT)
        else
            1;
        self.manifest.next_edge_id += stride;

        // 1. Source out-adjacency + source node record (from IS resident here).
        const out_entry = EdgeEntry{
            .neighbor = to,
            .edge_id = edge_id,
            .rel_type = rel_type,
            .prop_head = 0,
            .public_id = public_id,
        };
        var from_rec = try self.node_store.getNode(from) orelse return error.NodeNotFound;
        const new_out_head = try self.adj_out.addEdge(from_rec.out_head, out_entry);
        // GAP-ENT-0022(b): roll back a slab tombstone if anything below errors
        // (no-op for legacy/in-slab writes) — the caller keeps the old head.
        errdefer self.adj_out.undoLastSlabTombstone() catch {};
        from_rec.out_head = new_out_head;
        try self.node_store.putNode(from, from_rec);

        // 2. Incoming adjacency into THIS shard's adj_in_remote, keyed by `to`
        //    via the page-backed directory. We do NOT read/write `to`'s NodeRec.
        const in_entry = EdgeEntry{
            .neighbor = from,
            .edge_id = edge_id,
            .rel_type = rel_type,
            .prop_head = 0,
            .public_id = public_id,
        };
        const old_in_head = try self.in_head_dir.getHead(to);
        const new_in_head = try self.adj_in_remote.addEdge(old_in_head, in_entry);
        errdefer self.adj_in_remote.undoLastSlabTombstone() catch {};
        const dir_page = try self.in_head_dir.setHead(to, new_in_head);

        // 3. Log every dirty page under the ONE txn: out-adj, from-node, in-adj
        //    body, in-dir page. No remote pages, no `to`-node page — strictly
        //    fewer pages than addEdgeTxn's two-node write. Adjacency heads are
        //    imaged via each store's touched set (a head may be a slab
        //    (block,slot) ref; one write may dirty several pages).
        try self.logTouchedAdj(txn, .adj_out, &self.adj_out);
        try self.logPage(txn, .nodes, self.nodePageId(from));
        try self.logTouchedAdj(txn, .in_idx, &self.adj_in_remote);
        try self.logPage(txn, .in_dir, dir_page);

        // 4. Derived in-memory indexes (same as addEdgeTxn — already source-shard).
        //    P3: the edge_index carries the SAME public_id as the durable
        //    adjacency entries so getEdge agrees with the adjacency routes.
        try self.edge_index.put(edge_id, .{
            .from = from,
            .neighbor = to,
            .rel_type = rel_type,
            .prop_head = 0,
            .public_id = public_id,
        });
        self.edge_index_dirty = true;
        try self.edge_exist_index.put(from, rel_type, to, edge_id);
        self.edge_exist_index_dirty = true;

        self.manifest.edge_count += 1;
        self.metrics.edges_created += 1;
        self.markDirty();

        return edge_id;
    }

    /// Edge co-location: auto-commit single-shard edge add. The
    /// ShardedGraphEngine routes BOTH same-shard and cross-endpoint edges here
    /// (on shard(from)); the cross-shard 2PC add path was removed in Phase C.
    pub fn addEdgeColocated(self: *GraphEngine, from: NodeId, to: NodeId, rel_type: u32) anyerror!EdgeId {
        return self.addEdgeColocatedWithPublicId(from, to, rel_type, 0);
    }

    /// GAP-ENT-0024 P2: auto-commit variant of
    /// `addEdgeColocatedTxnWithPublicId` — the geode adapter's target surface
    /// for new edges (inline id, NO `__geode_internal_edge_id` property).
    /// CONTRACT (review F4): `public_id == 0` is RESERVED = "no inline id"
    /// (legacy class; readers fall back to the id property, which this path
    /// does not write). Callers must pass a nonzero id for real edges.
    pub fn addEdgeColocatedWithPublicId(self: *GraphEngine, from: NodeId, to: NodeId, rel_type: u32, public_id: u64) anyerror!EdgeId {
        var __obs_span = observability.startOperationSpan("add_edge");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        const edge_id = try self.addEdgeColocatedTxnWithPublicId(from, to, rel_type, txn, public_id);

        // GAP-ENT-0022(b): roll back a slab tombstone on commit failure (the
        // last error window; no-op for legacy/in-slab writes).
        errdefer self.adj_out.undoLastSlabTombstone() catch {};
        errdefer self.adj_in_remote.undoLastSlabTombstone() catch {};

        try self.txn_manager.commit(txn);
        observability.endOperationSpan(__obs_span, true, "");

        return edge_id;
    }

    /// Edge co-location (Phase A): zero-copy incoming-edge iterator over THIS
    /// shard's `adj_in_remote` for `dst` (entries whose source is on this shard).
    /// The cross-shard union is built by `ShardedGraphEngine.FanInEdgeIterator`,
    /// which fans this over all shards. Ownership/lifetime match `expandInIter`.
    pub fn expandInRemoteIter(self: *GraphEngine, dst: NodeId, rel_type: ?u32) anyerror!AdjStore.AdjEdgeIterator {
        const head = try self.in_head_dir.getHead(dst);
        return self.adj_in_remote.expand(head, rel_type);
    }

    /// Remove an edge within an existing transaction (no auto-commit).
    ///
    /// Edge co-location (Phase C): a co-located edge `(from)-[r]->(to)` lives
    /// ENTIRELY on shard(from) — out-adjacency, edge_index, the existence index
    /// AND the incoming adjacency (in THIS shard's `adj_in_remote`, keyed by `to`
    /// via `in_head_dir`). So removal is a single-shard delete and never touches
    /// `to`'s node record (which is not resident here for a cross-endpoint edge).
    /// Idempotent: removing an absent edge_id is a no-op on every store.
    pub fn removeEdgeTxn(self: *GraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId, txn: TxnId) anyerror!void {
        try self.ensureWritable();
        // Phase A: reads/mutates edge_index + edge_exist_index — materialize
        // first so the dedup/count logic sees the true edge set.
        try self.ensureDerivedHydrated();
        // Remove from source node's out adjacency list (from IS resident here).
        const from_rec = try self.node_store.getNode(from) orelse return error.NodeNotFound;
        const out_mutated = try self.adj_out.removeEdge(from_rec.out_head, edge_id);

        // Remove from THIS shard's co-located incoming adjacency, keyed by `to`
        // via the page-backed directory. We do NOT read `to`'s NodeRec.
        const in_head = try self.in_head_dir.getHead(to);
        const in_mutated = try self.adj_in_remote.removeEdge(in_head, edge_id);

        // GAP-ENT-0032: WAL-image exactly the block each removal MUTATED.
        // The entry may live in ANY block of the chain (removeEdge is a
        // same-block swap-with-last + count--), not just the head — imaging
        // only the head let older WAL images of a deeper block resurrect a
        // committed delete (with its old public_id) on crash recovery, the
        // same under-logging class as the label logVarChain fix. The head
        // pointer itself never changes on remove, so the node record /
        // in-dir page need no image; a not-found removal (null) touched no
        // page and logs nothing.
        if (out_mutated) |p| try self.logPage(txn, .adj_out, p);
        if (in_mutated) |p| try self.logPage(txn, .in_idx, p);

        // WAL-aware derived-index durability Phase 3: also log `from`'s node
        // page. removeEdge leaves `from.out_head` unchanged, so this images an
        // UNCHANGED node record (harmless on replay: same bytes, zero census /
        // id-counter effect) — but it puts `from` in recovery's tail-affected
        // NODE set, which is what the first-access tail reconcile scans to find
        // the edges to re-derive. Without it, a crash right after a committed
        // removeEdge would leave the removed edge stale in the reloaded
        // edge_index/edge_exist snapshot (the adj_out page alone carries no
        // back-pointer to its owning node). Skipped when the removal was a
        // no-op (out_mutated == null): nothing changed, nothing to reconcile.
        if (out_mutated != null) try self.logPage(txn, .nodes, self.nodePageId(from));

        // PHASE 3: drop the edge-existence entry BEFORE removing the edge_index
        // record (we need its rel_type to form the key). No-op if absent.
        // `edge_present` gates the edge_count decrement so a no-op re-remove of
        // an already-deleted edge does NOT corrupt the count (idempotency).
        const idx_entry_opt = try self.edge_index.get(edge_id);
        const edge_present = idx_entry_opt != null;
        if (idx_entry_opt) |idx_entry| {
            try self.edge_exist_index.remove(from, idx_entry.rel_type, to, edge_id);
            self.edge_exist_index_dirty = true;
        }

        // Remove from in-memory edge index
        try self.edge_index.remove(edge_id);
        self.edge_index_dirty = true;

        if (edge_present and self.manifest.edge_count > 0) {
            self.manifest.edge_count -= 1;
        }
        self.metrics.edges_removed += 1;
        self.markDirty();
    }

    /// Remove an edge with auto-commit (backward compatible).
    pub fn removeEdge(self: *GraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId) anyerror!void {
        var __obs_span = observability.startOperationSpan("remove_edge");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        try self.removeEdgeTxn(from, to, edge_id, txn);

        try self.txn_manager.commit(txn);
        observability.endOperationSpan(__obs_span, true, "");
    }

    /// Look up a single property value by key.
    /// The returned `PropertyValue` is fully owned by the caller: `.string` and
    /// `.ext` payloads are heap-copied with `alloc`. Release them with
    /// `property.freeDecoded(alloc, value)` (scalar variants own no heap memory,
    /// so the call is a no-op for them). For a borrow-based, zero-copy path use
    /// `getAllProperties` together with `interface.wrapPropIteratorView`.
    pub fn getProperty(self: *GraphEngine, prop_head: u64, key: []const u8, alloc: Allocator) anyerror!?PropertyValue {
        var __obs_span = observability.startOperationSpan("get_property");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        // Read paths run concurrently; a plain `+= 1` here is a data race that
        // also loses counts. Same idiom as the buffer pool's lock-free hit path.
        _ = @atomicRmw(u64, &self.metrics.properties_read, .Add, 1, .monotonic);
        if (prop_head == 0) {
            observability.endOperationSpan(__obs_span, true, "");
            return null;
        }
        try self.ensureDerivedHydrated(); // Phase A: property_index chain is deferred.
        if (self.property_index.containsChain(prop_head) and !self.property_index.hasKey(prop_head, key)) {
            observability.endOperationSpan(__obs_span, true, "");
            return null;
        }
        const result = try self.prop_store.getProperty(prop_head, key, alloc);
        observability.endOperationSpan(__obs_span, true, "");
        return result;
    }

    /// H1-engine (cold-open): a sibling of `getProperty` that skips
    /// `ensureDerivedHydrated` and the `property_index` negative-lookup
    /// entirely. Intended for callers (e.g. loop1's per-node chain read at
    /// cold-open) that only ever look up keys known to be present on the
    /// chain — for those callers the derived property-chain index gives no
    /// benefit, and `ensureDerivedHydrated` is a full O(graph) index build
    /// that should not be paid just to serve a property read. Walking the
    /// chain via `prop_store.getProperty` directly is correct and sufficient;
    /// it returns byte-identical results to `getProperty` for any key that
    /// IS present on the chain. For a key that is ABSENT, `getProperty`'s
    /// negative-lookup may short-circuit via the (now possibly stale or
    /// unhydrated) derived index — callers needing that optimization, or a
    /// hydrated-index guarantee, should use `getProperty` instead.
    pub fn getPropertyNoDerived(self: *GraphEngine, prop_head: u64, key: []const u8, alloc: Allocator) anyerror!?PropertyValue {
        _ = @atomicRmw(u64, &self.metrics.properties_read, .Add, 1, .monotonic);
        if (prop_head == 0) return null;
        return try self.prop_store.getProperty(prop_head, key, alloc);
    }

    pub fn getAllProperties(self: *GraphEngine, prop_head: u64) anyerror!PropStore.PropIterator {
        var __obs_span = observability.startOperationSpan("get_all_properties");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        const iter = self.prop_store.getAllProperties(prop_head);
        observability.endOperationSpan(__obs_span, true, "");
        return iter;
    }

    /// Put a property within an existing transaction (no auto-commit).
    pub fn putPropertyTxn(self: *GraphEngine, owner: u64, key: []const u8, val: PropertyValue, txn: TxnId) anyerror!u64 {
        return self.putPropertyTxnImpl(owner, key, val, txn, true);
    }

    /// GAP prop-store slab packing (P5): the LEGACY-ONLY put for edge
    /// property chains. Identical to `putPropertyTxn` except a new chain is
    /// never slab-packed (see PropStore.putPropertyLegacyOnly): edge
    /// prop_heads are packed as u32 in adjacency entries and the edge index,
    /// which cannot represent a slab head. Every edge-property write path
    /// (engine_edge_props.setEdgeProperty here; geode's adapter edge sites
    /// once slab packing rolls out) must use this instead of putPropertyTxn.
    pub fn putPropertyLegacyTxn(self: *GraphEngine, owner: u64, key: []const u8, val: PropertyValue, txn: TxnId) anyerror!u64 {
        return self.putPropertyTxnImpl(owner, key, val, txn, false);
    }

    /// Auto-commit wrapper for `putPropertyLegacyTxn` (edge-prop chains).
    pub fn putPropertyLegacy(self: *GraphEngine, owner: u64, key: []const u8, val: PropertyValue) anyerror!u64 {
        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};
        const new_head = try self.putPropertyLegacyTxn(owner, key, val, txn);
        try self.txn_manager.commit(txn);
        return new_head;
    }

    fn putPropertyTxnImpl(self: *GraphEngine, owner: u64, key: []const u8, val: PropertyValue, txn: TxnId, allow_slab: bool) anyerror!u64 {
        try self.ensureWritable();
        // Phase A: reads/mutates the property_index chain — materialize first.
        try self.ensureDerivedHydrated();
        const new_head = if (allow_slab)
            try self.prop_store.putProperty(owner, key, val)
        else
            try self.prop_store.putPropertyLegacyOnly(owner, key, val);

        // GAP-ENT-0022(b): if anything below fails, this call reports an
        // error and OUR caller keeps the OLD head — but a slab relocation /
        // migration inside putProperty has already tombstoned the old slot.
        // Roll that tombstone back (best effort, allocation-free) so the
        // stored head still references a LIVE blob; the placed new blob is
        // merely leaked until compaction.
        //
        // Crash-consistency caveats (review 0022b I-1/I-2 — the pre-existing
        // no-undo-abort family, GAP-ENT-0022(a), NOT closed here):
        //  * An ABORTED txn's WAL images never replay, but the buffer pool's
        //    steal policy may have evict-FLUSHED the tombstoned page before
        //    this undo ran; if the process then crashes before the restored
        //    page re-flushes, the tombstone is durable and the head dangles.
        //    This fix strictly NARROWS the window (live process always
        //    restores; only steal+crash loses), it does not eliminate it.
        //  * CALLER-OWNED txns: a caller that receives an error from
        //    putPropertyTxn MUST abort the txn. Committing anyway durably
        //    logs a PARTIAL image set of a rolled-back op (the tombstoned
        //    page may be imaged while the new blob's page is not) → dangling
        //    head after crash-replay. Both in-repo callers abort; external
        //    callers inherit this contract.
        // No-op for legacy ops / in-place slab rewrites (no tombstone
        // recorded).
        errdefer self.prop_store.undoLastSlabTombstone() catch {};

        // P4 (GAP prop-store slab packing): WAL-image EVERY props page the
        // put dirtied. `new_head` is not necessarily a page id — a slab head
        // encodes tag|page|slot, so logging it raw would image a bogus page —
        // and one put can dirty several pages (slab relocation: old-page
        // tombstone + fill-page append; slab→legacy migration: tombstone +
        // every page of the new chain; legacy chain put: possibly a non-head
        // page). The store records the exact dirtied set.
        for (self.prop_store.touchedPages()) |touched_page| {
            try self.logPage(txn, .props, touched_page);
        }

        // Property-value OVERFLOW: a value too large for the per-page entry
        // budget lives in a var-store chain and the props page holds only a
        // 13-byte stub. Image that chain in the SAME txn as the props page —
        // otherwise crash replay restores a stub that references pages whose
        // contents were never logged (the exact under-logging class the label
        // logVarChain fix closed). Empty for every non-overflowing put.
        for (self.prop_store.touchedVarRefs()) |ref| {
            try self.logVarChain(txn, ref);
        }

        if (owner != 0 and owner != new_head) {
            self.property_index.removeChain(owner);
            self.property_index_dirty = true;
        }
        if (owner != 0 and new_head == owner and self.property_index.containsChain(owner)) {
            // PERF-0055: Encode into a stack buffer instead of allocating an
            // ArrayList. Fixed-size types fit in 32 bytes (decimal is the
            // largest at 18 bytes); variable-length types fall back to a
            // heap slice that is freed immediately after the hash is taken.
            var stack_buf: [32]u8 = undefined;
            const enc_size = property_mod.encodedSize(val);
            var heap_enc: ?[]u8 = null;
            const encoded_val: []const u8 = if (enc_size <= stack_buf.len) blk: {
                _ = property_mod.encodeInto(&stack_buf, val) catch unreachable;
                break :blk stack_buf[0..enc_size];
            } else blk: {
                const h = try self.allocator.alloc(u8, enc_size);
                _ = property_mod.encodeInto(h, val) catch unreachable;
                heap_enc = h;
                break :blk h;
            };
            defer if (heap_enc) |h| self.allocator.free(h);
            try self.property_index.upsertKey(owner, key, encoded_val);
            self.property_index_dirty = true;
        } else {
            try self.refreshPropertyChainIndex(new_head);
        }

        self.metrics.properties_written += 1;
        // H3-P4: an indexed property value may have changed; mark the ordered
        // trees stale (the write path is keyed by prop_head, not node_id, so it
        // cannot maintain the value-ordered trees in place).
        if (self.ordered_property_index.count() > 0) self.ordered_index_stale = true;
        self.markDirty();
        return new_head;
    }

    /// Put a property with auto-commit (backward compatible).
    pub fn putProperty(self: *GraphEngine, owner: u64, key: []const u8, val: PropertyValue) anyerror!u64 {
        var __obs_span = observability.startOperationSpan("put_property");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        const new_head = try self.putPropertyTxn(owner, key, val, txn);

        // GAP-ENT-0022(b): a COMMIT failure is the last window in which this
        // op errors after a slab relocation/migration tombstoned the old
        // slot while the caller keeps the old head — roll the tombstone back
        // (see putPropertyTxnImpl). The aborted txn's images never replay.
        errdefer self.prop_store.undoLastSlabTombstone() catch {};

        try self.txn_manager.commit(txn);
        observability.endOperationSpan(__obs_span, true, "");

        return new_head;
    }

    pub fn removeProperty(self: *GraphEngine, owner: u64, key: []const u8) anyerror!void {
        var __obs_span = observability.startOperationSpan("remove_property");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        try self.ensureWritable();
        // Phase A: reads/mutates the property_index chain — materialize first.
        try self.ensureDerivedHydrated();
        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        try self.prop_store.removeProperty(owner, key);

        // P4 (GAP prop-store slab packing): WAL-image every props page the
        // remove dirtied (see putPropertyTxn) — `owner` may be a slab head
        // (not a page id) and a legacy remove can dirty a non-head chain
        // page. A no-op remove (absent key / owner == 0) logs nothing.
        for (self.prop_store.touchedPages()) |touched_page| {
            try self.logPage(txn, .props, touched_page);
        }

        // Property-value OVERFLOW: symmetric with putPropertyTxnImpl. A remove
        // writes no new chain, so this set is normally empty — logging it keeps
        // the two paths identical and correct if that ever changes.
        for (self.prop_store.touchedVarRefs()) |ref| {
            try self.logVarChain(txn, ref);
        }

        try self.txn_manager.commit(txn);

        if (owner != 0 and self.property_index.containsChain(owner)) {
            self.property_index.removeKey(owner, key);
            self.property_index_dirty = true;
        } else {
            try self.refreshPropertyChainIndex(owner);
        }
        // H3-P4: removing an indexed property changes index contents; the
        // ordered trees are stale until the next rebuild.
        if (self.ordered_property_index.count() > 0) self.ordered_index_stale = true;
        self.markDirty();
        observability.endOperationSpan(__obs_span, true, "");
    }

    /// Add a label within an existing transaction (no auto-commit).
    pub fn addLabelTxn(self: *GraphEngine, node_id: NodeId, label: LabelId, txn: TxnId) anyerror!void {
        try self.ensureWritable();
        // Phase A: mutates label_index — materialize first.
        try self.ensureDerivedHydrated();
        var rec = try self.node_store.getNode(node_id) orelse return error.NodeNotFound;
        const old_head = rec.label_head;
        // GAP-ENT-0022(b): forget any prior op's tombstone before the label
        // store may write a new one below.
        self.var_store.resetSlabUndo();
        const result = try self.label_store.addLabel(rec.label_head, label, self.allocator);
        // GAP-ENT-0022(b): the label store writes the NEW block, then
        // tombstones the OLD slab slot (tombstone LAST). If anything below
        // fails, our caller keeps the OLD head — so revive that tombstoned slot
        // (best-effort, allocation-free) rather than leave the old head
        // dangling. No-op for legacy frees / first writes / dedup no-ops.
        errdefer self.var_store.undoLastSlabTombstone() catch {};
        if (result.count != rec.label_count or result.head != rec.label_head) {
            rec.label_head = result.head;
            rec.label_count = result.count;
            try self.node_store.putNode(node_id, rec);

            // WAL-image every var-store page the mutation dirtied. `result.head`
            // is a REF/slab head, NOT a page id — logVarChain decodes it (slab
            // block image vs legacy chain walk). The OLD head's block ALSO
            // needs imaging when it is a slab block, because the label store
            // tombstoned its old slot in the SAME op (a different block from
            // the new fill block, in general) — image it so the tombstone is
            // durable and the slot never resurrects on replay.
            try self.logVarChain(txn, result.head);
            if (var_store_mod.isSlabHead(old_head)) try self.logVarChain(txn, old_head);
            try self.logPage(txn, .nodes, self.nodePageId(node_id));
        }
        try self.label_index.addNode(label, node_id);
        self.label_index_dirty = true;
        // H3-P1: keep the value-ordered index current. Adding `label` makes this
        // node visible to any ordered index on (label, key); index its current
        // value for each such key. No-op unless an ordered index on `label`
        // exists (the hasLabel gate keeps the common path zero-cost).
        try self.orderedIndexOnAddLabel(node_id, label, rec.prop_head);
        // H3-P4: adding a label can change index membership; mark stale.
        if (self.ordered_property_index.count() > 0) self.ordered_index_stale = true;
        self.markDirty();
    }

    /// Add a label with auto-commit (backward compatible).
    pub fn addLabel(self: *GraphEngine, node_id: NodeId, label: LabelId) anyerror!void {
        var __obs_span = observability.startOperationSpan("add_label");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        try self.addLabelTxn(node_id, label, txn);

        // GAP-ENT-0022(b): a COMMIT failure is the last window where this op
        // errors after addLabelTxn tombstoned the old slab slot while the
        // caller keeps the old head — revive it. The aborted txn's images
        // never replay.
        errdefer self.var_store.undoLastSlabTombstone() catch {};

        try self.txn_manager.commit(txn);
        observability.endOperationSpan(__obs_span, true, "");
    }

    /// Remove a label within an existing transaction (no auto-commit).
    pub fn removeLabelTxn(self: *GraphEngine, node_id: NodeId, label: LabelId, txn: TxnId) anyerror!void {
        try self.ensureWritable();
        // Phase A: mutates label_index — materialize first.
        try self.ensureDerivedHydrated();
        var rec = try self.node_store.getNode(node_id) orelse return error.NodeNotFound;
        const old_head = rec.label_head;
        // GAP-ENT-0022(b): forget any prior op's tombstone before removeLabel
        // may write a new one.
        self.var_store.resetSlabUndo();
        const result = try self.label_store.removeLabel(rec.label_head, label, self.allocator);
        // GAP-ENT-0022(b): revive the old slab slot if a later step fails (see
        // addLabelTxn).
        errdefer self.var_store.undoLastSlabTombstone() catch {};
        rec.label_head = result.head;
        rec.label_count = result.count;
        try self.node_store.putNode(node_id, rec);
        self.label_index.removeNode(label, node_id);
        self.label_index_dirty = true;
        // H3-P1: removing `label` drops this node from any ordered index on
        // (label, key); remove its entry (read before the chain changes so the
        // value still matches the one used at insert). rec.prop_head is the
        // property chain, untouched by label removal.
        try self.orderedIndexOnRemoveLabel(node_id, label, rec.prop_head);
        // H3-P4: removing a label can change index membership; mark stale.
        if (self.ordered_property_index.count() > 0) self.ordered_index_stale = true;

        // Log dirty pages: the NEW var-store block/chain (if any — result.head
        // is a REF/slab head, not a page id; logVarChain decodes it), the OLD
        // slab block whose slot removeLabel tombstoned in this op (so the
        // tombstone is durable / never resurrects), and the node page.
        if (result.head != 0) try self.logVarChain(txn, result.head);
        if (var_store_mod.isSlabHead(old_head)) try self.logVarChain(txn, old_head);
        try self.logPage(txn, .nodes, self.nodePageId(node_id));
        self.markDirty();
    }

    /// Remove a label with auto-commit (backward compatible).
    pub fn removeLabel(self: *GraphEngine, node_id: NodeId, label: LabelId) anyerror!void {
        var __obs_span = observability.startOperationSpan("remove_label");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        const txn = try self.txn_manager.begin();
        errdefer self.txn_manager.abort(txn) catch {};

        try self.removeLabelTxn(node_id, label, txn);

        // GAP-ENT-0022(b): revive the tombstoned old slab slot on a commit
        // failure (see addLabel).
        errdefer self.var_store.undoLastSlabTombstone() catch {};

        try self.txn_manager.commit(txn);
        observability.endOperationSpan(__obs_span, true, "");
    }

    /// Return every node id carrying `label` as a heap-allocated slice.
    /// Caller owns the returned `[]NodeId` and must free it with the same
    /// `alloc` passed in (e.g. `alloc.free(result)`). For a streaming,
    /// zero-copy alternative that allocates no result slice, use `scanLabelIter`.
    pub fn scanLabel(self: *GraphEngine, label: LabelId, alloc: Allocator) anyerror![]NodeId {
        var __obs_span = observability.startOperationSpan("scan_label");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        try self.ensureDerivedHydrated(); // Phase A: label_index is deferred.
        // Delegate to label index for O(1) lookup instead of O(N) scan
        const result = try self.label_index.scan(label, alloc);
        observability.endOperationSpan(__obs_span, true, "");
        return result;
    }

    /// Streaming label scan. Returns a sorted Iterator that owns its backing
    /// slice; the caller must call deinit() to release it.  The vtable's
    /// scanLabelIter keeps an allocator parameter only to heap-box the
    /// type-erased iterator state; the posting-list slice itself is allocated
    /// on the engine allocator (PERF-0054).
    pub fn scanLabelIter(self: *GraphEngine, label: LabelId) !LabelIndex.Iterator {
        try self.ensureDerivedHydrated(); // Phase A: label_index is deferred.
        return self.label_index.iterator(label, self.allocator);
    }

    pub fn beginTxn(self: *GraphEngine) anyerror!TxnId {
        var __obs_span = observability.startOperationSpan("begin_txn");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        try self.ensureWritable();
        const txn_id = try self.txn_manager.begin();
        self.metrics.txn_begun += 1;
        observability.endOperationSpan(__obs_span, true, "");
        return txn_id;
    }

    pub fn commitTxn(self: *GraphEngine, txn: TxnId) anyerror!void {
        var __obs_span = observability.startOperationSpan("commit_txn");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        try self.txn_manager.commit(txn);
        self.metrics.txn_committed += 1;
        observability.endOperationSpan(__obs_span, true, "");
    }

    pub fn abortTxn(self: *GraphEngine, txn: TxnId) anyerror!void {
        var __obs_span = observability.startOperationSpan("abort_txn");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        try self.txn_manager.abort(txn);
        self.metrics.txn_aborted += 1;
        observability.endOperationSpan(__obs_span, true, "");
    }

    pub fn nodeCount(self: *GraphEngine) anyerror!u64 {
        return self.manifest.node_count;
    }

    pub fn edgeCount(self: *GraphEngine) anyerror!u64 {
        return self.manifest.edge_count;
    }

    pub fn checkpoint(self: *GraphEngine) anyerror!void {
        var __obs_span = observability.startOperationSpan("checkpoint");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        try self.ensureWritable();
        try engine_persist.checkpoint(self);
        observability.endOperationSpan(__obs_span, true, "");
    }

    /// GAP-0900 L2: incremental/bounded checkpoint. Does the memory-bounding
    /// work (flush dirty pages, sync, manifest, WAL truncate, free store, label
    /// dict, declared B+tree indexes) but SKIPS the O(graph-size) derived-index
    /// snapshot save. Recovery rebuilds derived indexes from the durable pages
    /// when the snapshots are stale, so this is safe and O(dirty). Use this for
    /// the periodic load-driven checkpoint; use checkpoint() (full) at clean
    /// shutdown so a restart loads fast without a rebuild.
    pub fn checkpointLight(self: *GraphEngine) anyerror!void {
        var __obs_span = observability.startOperationSpan("checkpoint_light");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        try self.ensureWritable();
        try engine_persist.checkpointLight(self);
        observability.endOperationSpan(__obs_span, true, "");
    }

    pub fn getOrAssignLabel(self: *GraphEngine, label: []const u8) !LabelId {
        var __obs_span = observability.startOperationSpan("get_or_assign_label");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        try self.ensureWritable();
        const is_new = self.label_dict.getId(label) == null;
        const id = try self.label_dict.getOrAssign(label);
        self.markDirty();
        // SONNY-6491: label assignment is not WAL-logged and labels.dict is the
        // only record of a name, so a new name is made durable (file fsync,
        // rename, directory fsync) before the id is returned and can reach a
        // committed record. A crash at any later point then finds the name.
        // New names are rare (schema-level); existing names cost nothing.
        if (is_new) try engine_persist.saveLabelDictionaryDurable(self);
        observability.endOperationSpan(__obs_span, true, "");
        return id;
    }

    // ── B+tree property indexes (delegated to engine_property_index.zig) ─

    /// GAP-0027 / FR-016: declare and build an opt-in B+tree property index on
    /// `(label, property_key)`. Records it in the per-graph index catalog,
    /// builds it offline from the primary stores, and persists it on the next
    /// checkpoint/close. Idempotent for an already-declared index.
    pub fn createPropertyIndex(self: *GraphEngine, label: LabelId, property_key: []const u8) anyerror!void {
        var __obs_span = observability.startOperationSpan("create_property_index");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        try self.ensureWritable();
        try engine_property_index.createPropertyIndex(self, label, property_key);
        observability.endOperationSpan(__obs_span, true, "");
    }

    /// GAP-0027 / FR-016: drop a declared B+tree property index. Returns true if
    /// it existed. Removes the catalog entry, the live tree, and the on-disk
    /// snapshot.
    pub fn dropPropertyIndex(self: *GraphEngine, label: LabelId, property_key: []const u8) anyerror!bool {
        try self.ensureWritable();
        return engine_property_index.dropPropertyIndex(self, label, property_key);
    }

    /// Report whether a B+tree property index is declared for `(label, key)`.
    pub fn hasPropertyIndex(self: *GraphEngine, label: LabelId, property_key: []const u8) bool {
        return self.property_index_set.catalog.findIndex(label, property_key) != null;
    }

    /// GAP-0027 / FR-017: equality lookup through a declared B+tree property
    /// index. Returns the matching node id, or null when no index is declared or
    /// no node carries that value.
    pub fn lookupPropertyIndex(self: *GraphEngine, label: LabelId, property_key: []const u8, value: PropertyValue) anyerror!?NodeId {
        var __obs_span = observability.startOperationSpan("lookup_property_index");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        const result = try engine_property_index.lookupPropertyIndex(self, label, property_key, value);
        observability.endOperationSpan(__obs_span, true, "");
        return result;
    }

    /// GAP-0027 / FR-017: range lookup over the declared index's hash-keyed
    /// B+tree. Caller owns the returned slice (free with `allocator`). See
    /// `engine_property_index.rangePropertyIndex` for hash-space ordering caveat.
    pub fn rangePropertyIndex(self: *GraphEngine, label: LabelId, property_key: []const u8, lo: u64, hi: u64, allocator: Allocator) anyerror![]NodeId {
        return engine_property_index.rangePropertyIndex(self, label, property_key, lo, hi, allocator);
    }

    // ── H3-P1: per-(label,key) value-ordered secondary index ───────────

    /// Declare and build a value-ordered index on `(label, property_key)`.
    /// Registers the (label,key) pair, builds the tree from a live scan of the
    /// current graph, and marks the ordered index dirty so the next FULL
    /// checkpoint/close persists it (stamped at manifest.counter for the Lever-B
    /// load gate). Idempotent registration; a rebuild always reflects current
    /// state. After this, incremental maintenance keeps the tree current via the
    /// label-mutation hooks (a property indexed on a node carrying `label` is
    /// inserted when the label is added and removed when the label is removed or
    /// the node is deleted).
    pub fn createOrderedIndex(self: *GraphEngine, label: LabelId, property_key: []const u8) anyerror!void {
        var __obs_span = observability.startOperationSpan("create_ordered_index");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        try self.ensureWritable();
        try self.ordered_property_index.registerIndex(label, property_key);
        try self.rebuildOrderedIndex();
        self.ordered_index_dirty = true;
        self.markPersistenceDirty();
        observability.endOperationSpan(__obs_span, true, "");
    }

    /// Report whether a value-ordered index is registered for `(label, key)`.
    pub fn hasOrderedIndex(self: *GraphEngine, label: LabelId, property_key: []const u8) bool {
        return self.ordered_property_index.isRegistered(label, property_key);
    }

    /// Report whether ORDER BY on `(label, key)` can be SAFELY served from the
    /// ordered index with full engine parity (no missing / mis-ordered rows).
    /// The planner consults this before serving ORDER BY from `openOrderedCursor`
    /// instead of the heap. False when no such ordered index is registered, OR
    /// when the column has a value that breaks parity (decimal/ext/NaN, bool/null,
    /// or mixed int+float). The flag reflects the current data: it is recomputed
    /// on every rebuild/refresh and restored from the snapshot on a clean load.
    pub fn isOrderedIndexEligible(self: *GraphEngine, label: LabelId, property_key: []const u8) bool {
        return self.ordered_property_index.isEligible(label, property_key);
    }

    /// Open a direction-aware cursor over the ordered index for `(label, key)`.
    /// Returns null when no such ordered index is registered. The cursor borrows
    /// the live tree; do not mutate the ordered index while iterating.
    pub fn openOrderedCursor(
        self: *GraphEngine,
        label: LabelId,
        property_key: []const u8,
        dir: OrderedPropertyIndex.Direction,
    ) ?OrderedPropertyIndex.Cursor {
        return self.ordered_property_index.openCursor(label, property_key, dir);
    }

    /// Rebuild EVERY registered ordered-index tree from a single live-node scan.
    /// Used by `createOrderedIndex` and by `open` when the persisted snapshot is
    /// stale-by-counter (crash restart). Clears the existing trees first but
    /// keeps the registered (label,key) set.
    pub fn rebuildOrderedIndex(self: *GraphEngine) !void {
        if (self.ordered_property_index.count() == 0) return;
        self.ordered_property_index.clearTrees();

        const Ctx = struct {
            engine: *GraphEngine,
            err: ?anyerror = null,

            fn callback(ctx: *@This(), node_id: NodeId, rec: NodeRec) void {
                if (ctx.err != null) return;
                if (rec.prop_head == 0 or rec.label_head == 0) return;
                ctx.engine.orderedIndexInsertForNode(node_id, rec) catch |e| {
                    ctx.err = e;
                };
            }
        };

        var ctx = Ctx{ .engine = self };
        try self.node_store.scanNodes(self.manifest.next_node_id, &ctx, Ctx.callback);
        if (ctx.err) |e| return e;
        // H3-P4: the trees now reflect every committed write; clear the stale
        // flag only after the scan completed successfully.
        self.ordered_index_stale = false;
    }

    /// True iff a registered ordered index exists AND its trees reflect every
    /// committed write since the last rebuild/refresh. The planner serves the
    /// value-ordered fast path ONLY when fresh; otherwise it must use the heap.
    pub fn orderedIndexFresh(self: *GraphEngine) bool {
        return self.ordered_property_index.count() > 0 and !self.ordered_index_stale;
    }

    /// For a single node, insert its indexed property values into every matching
    /// registered ordered tree (the node must carry the index's label and the
    /// indexed property). Used by the rebuild scan.
    fn orderedIndexInsertForNode(self: *GraphEngine, node_id: NodeId, rec: NodeRec) !void {
        const oidx = &self.ordered_property_index;
        if (rec.label_head == 0 or rec.prop_head == 0) return;
        const labels = try self.label_store.getLabels(rec.label_head, self.allocator);
        defer self.allocator.free(labels);
        for (oidx.entries.items) |*entry| {
            var has_label = false;
            for (labels) |l| {
                if (l == entry.label_id) {
                    has_label = true;
                    break;
                }
            }
            if (!has_label) continue;
            const val = (try self.prop_store.getProperty(rec.prop_head, entry.property_key, self.allocator)) orelse continue;
            defer property_mod.freeDecoded(self.allocator, val);
            try oidx.insert(entry.label_id, entry.property_key, val, node_id);
        }
    }

    /// Incremental maintenance: when `label` is added to `node_id`, insert the
    /// node's value for every property with a registered ordered index on
    /// `label`. Gated on `hasLabel` so the no-ordered-index path is zero-cost.
    /// `prop_head` is the node's property chain head.
    fn orderedIndexOnAddLabel(self: *GraphEngine, node_id: NodeId, label: LabelId, prop_head: u64) !void {
        const oidx = &self.ordered_property_index;
        if (prop_head == 0 or !oidx.hasLabel(label)) return;
        for (oidx.entries.items) |*entry| {
            if (entry.label_id != label) continue;
            const val = (try self.prop_store.getProperty(prop_head, entry.property_key, self.allocator)) orelse continue;
            defer property_mod.freeDecoded(self.allocator, val);
            try oidx.insert(label, entry.property_key, val, node_id);
            self.ordered_index_dirty = true;
        }
    }

    /// Incremental maintenance: when `label` is removed from `node_id`, remove
    /// the node's entry from every ordered tree registered on `label`. Reads the
    /// node's current property value (must match the value used at insert time).
    fn orderedIndexOnRemoveLabel(self: *GraphEngine, node_id: NodeId, label: LabelId, prop_head: u64) !void {
        const oidx = &self.ordered_property_index;
        if (prop_head == 0 or !oidx.hasLabel(label)) return;
        for (oidx.entries.items) |*entry| {
            if (entry.label_id != label) continue;
            const val = (try self.prop_store.getProperty(prop_head, entry.property_key, self.allocator)) orelse continue;
            defer property_mod.freeDecoded(self.allocator, val);
            try oidx.remove(label, entry.property_key, val, node_id);
            self.ordered_index_dirty = true;
        }
    }

    /// Incremental maintenance: when `node_id` is deleted, remove its entries
    /// from every ordered tree whose label the node carries. Gated on there
    /// being any registered ordered index.
    fn orderedIndexOnDeleteNode(self: *GraphEngine, node_id: NodeId, rec: NodeRec) !void {
        const oidx = &self.ordered_property_index;
        if (oidx.count() == 0 or rec.label_head == 0 or rec.prop_head == 0) return;
        const labels = try self.label_store.getLabels(rec.label_head, self.allocator);
        defer self.allocator.free(labels);
        for (oidx.entries.items) |*entry| {
            var has_label = false;
            for (labels) |l| {
                if (l == entry.label_id) {
                    has_label = true;
                    break;
                }
            }
            if (!has_label) continue;
            const val = (try self.prop_store.getProperty(rec.prop_head, entry.property_key, self.allocator)) orelse continue;
            defer property_mod.freeDecoded(self.allocator, val);
            try oidx.remove(entry.label_id, entry.property_key, val, node_id);
            self.ordered_index_dirty = true;
        }
    }

    // ── Edge property helpers (delegated to engine_edge_props.zig) ─────

    pub fn setEdgeProperty(self: *GraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId, key: []const u8, value: PropertyValue) anyerror!void {
        var __obs_span = observability.startOperationSpan("set_edge_property");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        try self.ensureWritable();
        try engine_edge_props.setEdgeProperty(self, from, to, edge_id, key, value);
        observability.endOperationSpan(__obs_span, true, "");
    }

    pub fn removeEdgeProperty(self: *GraphEngine, from: NodeId, edge_id: EdgeId, key: []const u8) anyerror!void {
        var __obs_span = observability.startOperationSpan("remove_edge_property");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        try self.ensureWritable();
        try engine_edge_props.removeEdgeProperty(self, from, edge_id, key);
        observability.endOperationSpan(__obs_span, true, "");
    }

    /// Look up a single edge property value by key.
    /// Ownership matches `getProperty`: the returned `PropertyValue`'s `.string`
    /// and `.ext` payloads are heap-copied with `allocator` and must be released
    /// with `property.freeDecoded(allocator, value)`.
    pub fn getEdgeProperty(self: *GraphEngine, from: NodeId, edge_id: EdgeId, key: []const u8, allocator: Allocator) anyerror!?PropertyValue {
        var __obs_span = observability.startOperationSpan("get_edge_property");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        const result = try engine_edge_props.getEdgeProperty(self, from, edge_id, key, allocator);
        observability.endOperationSpan(__obs_span, true, "");
        return result;
    }

    pub fn getAllEdgeProperties(self: *GraphEngine, from: NodeId, edge_id: EdgeId) anyerror!?PropStore.PropIterator {
        var __obs_span = observability.startOperationSpan("get_all_edge_properties");
        defer __obs_span.end(null);
        errdefer |err| observability.endOperationSpan(__obs_span, false, @errorName(err));

        const result = try engine_edge_props.getAllEdgeProperties(self, from, edge_id);
        observability.endOperationSpan(__obs_span, true, "");
        return result;
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("engine_test.zig");
    _ = @import("engine_edge_props.zig");
    _ = @import("engine_integrity.zig");
    _ = @import("engine_index.zig");
    _ = @import("engine_persist.zig");
    _ = @import("engine_property_index.zig");
    _ = @import("engine_adj_repair.zig");
}
