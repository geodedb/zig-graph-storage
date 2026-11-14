// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! ShardedGraphEngine — facade over N independent single-threaded
//! GraphEngine instances, one per shard. See
//! docs/superpowers/specs/2026-04-24-sharded-graph-engine-design.md.

const std = @import("std");
const builtin = @import("builtin");
const tp = @import("thread_pool");
const Allocator = std.mem.Allocator;

const config_mod = @import("config.zig");
const engine_mod = @import("engine.zig");
const interface_mod = @import("interface.zig");
const shard_count_mod = @import("shard_count.zig");
const shard_manifest_mod = @import("shard_manifest.zig");
const shard_uuid_mod = @import("shard_uuid.zig");
const types = @import("types.zig");
const node_mod = @import("node.zig");
const edge_mod = @import("edge.zig");
const metrics_mod = @import("metrics.zig");
const adj_store_mod = @import("adj_store.zig");
const label_index_mod = @import("label_index.zig");
const sharded_recovery = @import("sharded_recovery.zig");
const sharded_labels = @import("sharded_labels.zig");
const prop_store_mod = @import("prop_store.zig");

const GraphConfig = config_mod.GraphConfig;
const GraphEngine = engine_mod.GraphEngine;
const PropStore = prop_store_mod.PropStore;
const GraphStorage = interface_mod.GraphStorage;
const NodeId = types.NodeId;
const EdgeId = types.EdgeId;
const LabelId = types.LabelId;
const TxnId = types.TxnId;
const PropertyValue = types.PropertyValue;
const NodeRec = node_mod.NodeRec;
const EdgeEntry = edge_mod.EdgeEntry;
const Metrics = metrics_mod.Metrics;

pub const SHARD_COUNT = shard_count_mod.SHARD_COUNT;

/// Concurrency high-water gauge for the shard-open phase. A worker calls
/// `enter()` on entry to its `GraphEngine.open` body and `exit()` when it
/// returns; `enter()` records the running peak. With the SERIAL open loop the
/// peak is 1; once `open` spawns one worker per shard the peak rises to
/// `min(SHARD_COUNT, cpu)`. Exposed for the parallel-shard-open test to prove
/// the loop is actually N-wide. Single-graph-open scoped: `open` resets it on
/// entry, so a test that opens one graph at a time reads a clean value. Not a
/// production signal — purely test instrumentation.
pub const OpenConcurrencyGauge = struct {
    current: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    max: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn reset(self: *OpenConcurrencyGauge) void {
        if (!builtin.is_test) return;
        self.current.store(0, .seq_cst);
        self.max.store(0, .seq_cst);
    }

    pub fn enter(self: *OpenConcurrencyGauge) void {
        if (!builtin.is_test) return;
        const now = self.current.fetchAdd(1, .seq_cst) + 1;
        var prev = self.max.load(.seq_cst);
        while (now > prev) {
            prev = self.max.cmpxchgWeak(prev, now, .seq_cst, .seq_cst) orelse break;
        }
    }

    pub fn exit(self: *OpenConcurrencyGauge) void {
        if (!builtin.is_test) return;
        _ = self.current.fetchSub(1, .seq_cst);
    }

    pub fn maxObserved(self: *const OpenConcurrencyGauge) u32 {
        return self.max.load(.seq_cst);
    }
};

/// Process-global instrumentation for the most recent `ShardedGraphEngine.open`.
/// Reset at the start of every `open`. See `OpenConcurrencyGauge`.
pub var open_concurrency_gauge: OpenConcurrencyGauge = .{};

/// SONNY-6524: test instrumentation for `getOrAssignLabel`'s broadcast of a
/// new name to shards 1..N-1. Counts the shard assignments that ran on a
/// thread other than the caller's, so a test can tell a parallel broadcast
/// from a serial one without timing anything. Not a production signal.
pub const LabelBroadcastStats = struct {
    off_caller_thread: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn reset(self: *LabelBroadcastStats) void {
        if (!builtin.is_test) return;
        self.off_caller_thread.store(0, .seq_cst);
    }

    pub fn record(self: *LabelBroadcastStats, caller: std.Thread.Id) void {
        if (!builtin.is_test) return;
        if (std.Thread.getCurrentId() != caller) _ = self.off_caller_thread.fetchAdd(1, .seq_cst);
    }

    pub fn offCallerThread(self: *const LabelBroadcastStats) u32 {
        return self.off_caller_thread.load(.seq_cst);
    }
};

/// Process-global; see `LabelBroadcastStats`.
pub var label_broadcast_stats: LabelBroadcastStats = .{};

/// Worker context for the PARALLEL shard-open phase. Threads pull shard indices
/// from a shared atomic counter and run the (fully independent) per-shard
/// `GraphEngine.open` body — recovery + derived-index rebuild — into distinct
/// `shards[s]` / `ok[s]` / `err_slots[s]` slots (no overlapping writes).
///
/// SAFETY: every cross-engine touch point in `GraphEngine.open` is read-only
/// (`shard_manifest`, `graph_root`, `shared_thread_pool` are read; per-shard
/// `labels.dict` is read; the global registry is lookup-only; std.Io positional
/// I/O is per-fd thread-safe). The shared thread pool is NOT used for the opens
/// themselves (dedicated `std.Thread` workers), so this cannot re-enter the
/// nested-submit / buffer-pool-pin surface. Requires a thread-safe injected
/// allocator (see the precondition at the call site).
const ShardOpenWorker = struct {
    self: *ShardedGraphEngine,
    allocator: Allocator,
    cfg: GraphConfig,
    next_index: *std.atomic.Value(usize),
    ok: *[SHARD_COUNT]bool,
    err_slots: *[SHARD_COUNT]?anyerror,

    fn run(ctx: *ShardOpenWorker) void {
        while (true) {
            const s = ctx.next_index.fetchAdd(1, .monotonic);
            if (s >= SHARD_COUNT) break;

            var per_shard_cfg = ctx.cfg;
            per_shard_cfg.base_shard_index = s;
            per_shard_cfg.buffer_pool_pages = @max(1, ctx.cfg.buffer_pool_pages / @as(u32, @intCast(SHARD_COUNT)));
            per_shard_cfg.external_thread_pool = ctx.self.shared_thread_pool;

            open_concurrency_gauge.enter();
            defer open_concurrency_gauge.exit();

            if (GraphEngine.open(
                ctx.allocator,
                ctx.self.graph_root,
                ctx.self.shard_manifest.per_shard_uuids[s],
                per_shard_cfg,
            )) |eng| {
                ctx.self.shards[s] = eng;
                ctx.ok[s] = true;
            } else |e| {
                ctx.err_slots[s] = e;
            }
        }
    }
};

// Encoded TxnId layout for the facade: high 8 bits = shard_index,
// low 56 bits = per-shard local txn id. Keeps the public TxnId shape
// a plain u64 so the GraphStorage vtable binding stays untouched.
const TXN_SHARD_SHIFT: u6 = 56;
const TXN_LOCAL_MASK: u64 = (@as(u64, 1) << 56) - 1;

fn encodeTxn(shard: usize, local: TxnId) TxnId {
    return (@as(TxnId, @intCast(shard)) << TXN_SHARD_SHIFT) | (local & TXN_LOCAL_MASK);
}

fn decodeTxn(txn: TxnId) struct { shard: usize, local: TxnId } {
    const shard = @as(usize, @intCast(txn >> TXN_SHARD_SHIFT));
    const local = txn & TXN_LOCAL_MASK;
    return .{ .shard = shard, .local = local };
}

pub const ShardedGraphEngine = struct {
    allocator: Allocator,
    graph_uuid: [16]u8,
    graph_root: []u8, // owned, "<data_dir>/<graph_uuid_hex>"
    shards: [SHARD_COUNT]*GraphEngine,
    shard_manifest: shard_manifest_mod.ShardManifest,
    coordinator_txn_counter: std.atomic.Value(u64),
    aggregated_metrics: Metrics = .{},
    /// Shared across all sub-engines. Either points into
    /// `owned_shared_pool` (parent created it) or to a caller-supplied
    /// pool from `cfg.external_thread_pool`.
    shared_thread_pool: *tp.ThreadPool,
    /// Backing storage for the owned shared-pool path. `null` when the
    /// caller injected an external pool. Never reassigned after init.
    owned_shared_pool: ?tp.ThreadPool,

    pub fn create(
        allocator: Allocator,
        data_dir: []const u8,
        graph_uuid: [16]u8,
        cfg: GraphConfig,
    ) !*ShardedGraphEngine {
        const self = try allocator.create(ShardedGraphEngine);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.graph_uuid = graph_uuid;
        self.coordinator_txn_counter = std.atomic.Value(u64).init(0);

        const uuid_hex_buf = uuidHex(graph_uuid);
        self.graph_root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, uuid_hex_buf[0..] });
        errdefer allocator.free(self.graph_root);

        const io = std.Io.Threaded.global_single_threaded.io();
        try std.Io.Dir.cwd().createDirPath(io, self.graph_root);

        var per_shard: [SHARD_COUNT][16]u8 = undefined;
        for (&per_shard, 0..) |*u, s| {
            u.* = shard_uuid_mod.deriveShardUuid(graph_uuid, s);
        }

        self.shard_manifest = .{
            .version = shard_manifest_mod.SHARD_MANIFEST_VERSION,
            .shard_count = @intCast(SHARD_COUNT),
            .algorithm_hash = shard_manifest_mod.SHARD_ALGORITHM_HASH,
            .per_shard_uuids = per_shard,
            // Edge co-location (Phase B): a freshly created graph is co-located
            // from birth, so stamp the current layout version — no migration.
            .layout_version = shard_manifest_mod.CURRENT_LAYOUT_VERSION,
        };

        try shard_manifest_mod.writeToDir(allocator, self.graph_root, self.shard_manifest);

        // Init or borrow the shared thread pool BEFORE creating sub-engines.
        // The errdefer below is registered BEFORE the per-shard errdefer so
        // that Zig's LIFO ordering runs sub-engine closes first, then pool
        // teardown — never the other way around. Insert no errdefer between
        // these two registrations.
        self.owned_shared_pool = null;
        if (cfg.external_thread_pool) |ext| {
            self.shared_thread_pool = ext;
        } else {
            self.owned_shared_pool = try tp.ThreadPool.init(allocator, .{
                .scheduler_variant = .work_stealing,
                // One submitter slot per shard for THIS sharded graph.
                // Callers that share a single pool across N sharded graphs
                // must inject a pool with max_submitter_queues >= N *
                // SHARD_COUNT (the pool's hard cap is 64). See
                // GraphConfig.external_thread_pool docs and the design at
                // docs/2026-04-25-shared-engine-thread-pool.md §5.4.
                .max_submitter_queues = SHARD_COUNT,
                .max_threads = engine_mod.default_owned_pool_max_threads,
            });
            self.shared_thread_pool = &self.owned_shared_pool.?;
        }
        errdefer if (self.owned_shared_pool != null) {
            self.shared_thread_pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
            self.shared_thread_pool.deinit();
            self.owned_shared_pool = null;
        };

        var created: usize = 0;
        errdefer for (self.shards[0..created]) |e| e.close() catch {};

        for (0..SHARD_COUNT) |s| {
            var per_shard_cfg = cfg;
            per_shard_cfg.base_shard_index = s;
            per_shard_cfg.buffer_pool_pages = @max(1, cfg.buffer_pool_pages / @as(u32, @intCast(SHARD_COUNT)));
            per_shard_cfg.external_thread_pool = self.shared_thread_pool;
            self.shards[s] = try GraphEngine.create(allocator, self.graph_root, per_shard[s], per_shard_cfg);
            created += 1;
        }

        return self;
    }

    pub fn open(
        allocator: Allocator,
        data_dir: []const u8,
        graph_uuid: [16]u8,
        cfg: GraphConfig,
    ) !*ShardedGraphEngine {
        const self = try allocator.create(ShardedGraphEngine);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.graph_uuid = graph_uuid;
        self.coordinator_txn_counter = std.atomic.Value(u64).init(0);

        const uuid_hex_buf = uuidHex(graph_uuid);
        self.graph_root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, uuid_hex_buf[0..] });
        errdefer allocator.free(self.graph_root);

        self.shard_manifest = try shard_manifest_mod.readFromDir(allocator, self.graph_root);

        // Init or borrow the shared thread pool BEFORE opening sub-engines.
        // The errdefer below is registered BEFORE the per-shard errdefer so
        // that Zig's LIFO ordering runs sub-engine closes first, then pool
        // teardown — never the other way around. Insert no errdefer between
        // these two registrations.
        self.owned_shared_pool = null;
        if (cfg.external_thread_pool) |ext| {
            self.shared_thread_pool = ext;
        } else {
            self.owned_shared_pool = try tp.ThreadPool.init(allocator, .{
                .scheduler_variant = .work_stealing,
                // One submitter slot per shard for THIS sharded graph.
                // Callers that share a single pool across N sharded graphs
                // must inject a pool with max_submitter_queues >= N *
                // SHARD_COUNT (the pool's hard cap is 64). See
                // GraphConfig.external_thread_pool docs and the design at
                // docs/2026-04-25-shared-engine-thread-pool.md §5.4.
                .max_submitter_queues = SHARD_COUNT,
                .max_threads = engine_mod.default_owned_pool_max_threads,
            });
            self.shared_thread_pool = &self.owned_shared_pool.?;
        }
        errdefer if (self.owned_shared_pool != null) {
            self.shared_thread_pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
            self.shared_thread_pool.deinit();
            self.owned_shared_pool = null;
        };

        // PARALLEL shard-open. The 16 per-shard `GraphEngine.open` calls
        // (recovery + derived-index rebuild) are fully independent and are the
        // dominant restart cost, so we run them on dedicated `std.Thread`
        // workers and join ALL before serving — turning the ~serial restart
        // into a min(SHARD_COUNT, cpu)-wide one.
        //
        // ALLOCATOR PRECONDITION: `allocator` MUST be thread-safe — the workers
        // below call into it concurrently for 16 simultaneous opens. geode
        // injects `std.heap.smp_allocator` and tests use `std.testing.allocator`,
        // both thread-safe. A non-thread-safe injected allocator is a CALLER bug
        // (we deliberately do not silently wrap it).
        //
        // Workers do NOT use `shared_thread_pool` for the opens (that would
        // re-enter the nested-submit / buffer-pool-pin surface); the pool is
        // only passed through into each engine's config for post-open serving.
        //
        // PARTIAL-OPEN CLEANUP: parallel completion is not monotonic, so we
        // track per-shard `ok` / `err_slots` and, on any failure, close exactly
        // the shards that opened (by the bool array) and return the lowest-index
        // error. The earlier pool-teardown + `graph_root`/`self` errdefers then
        // fire in LIFO order. We NEVER return while a worker is live: join all
        // helpers first.
        var ok = [_]bool{false} ** SHARD_COUNT;
        var err_slots = [_]?anyerror{null} ** SHARD_COUNT;
        var next_index = std.atomic.Value(usize).init(0);

        open_concurrency_gauge.reset();

        var worker_ctx = ShardOpenWorker{
            .self = self,
            .allocator = allocator,
            .cfg = cfg,
            .next_index = &next_index,
            .ok = &ok,
            .err_slots = &err_slots,
        };

        const worker_count = @min(SHARD_COUNT, std.Thread.getCpuCount() catch SHARD_COUNT);
        var threads: [SHARD_COUNT]std.Thread = undefined;
        var spawned: usize = 0;
        // Spawn up to worker_count-1 helpers; the calling thread is itself the
        // worker_count-th worker. Pulling from the shared atomic counter means a
        // failed spawn never strands a shard — whatever threads exist (at least
        // the caller) drain all SHARD_COUNT indices.
        while (spawned + 1 < worker_count) : (spawned += 1) {
            threads[spawned] = std.Thread.spawn(.{}, ShardOpenWorker.run, .{&worker_ctx}) catch break;
        }
        worker_ctx.run();
        for (threads[0..spawned]) |t| t.join();

        // Aggregate AFTER every worker has joined. Lowest-index error wins.
        var first_err: ?anyerror = null;
        for (err_slots) |maybe| {
            if (maybe) |e| {
                first_err = e;
                break;
            }
        }
        if (first_err) |e| {
            for (ok, 0..) |opened_ok, s| {
                if (opened_ok) self.shards[s].close() catch {};
            }
            return e;
        }

        // Every shard opened. From here a failure in the serial post-open work
        // (reconcile / migration) must still close them; register the cleanup
        // AFTER the pool-teardown errdefer so Zig's LIFO closes shards first,
        // then tears down the pool — never the reverse.
        errdefer for (self.shards) |e| e.close() catch {};

        // SONNY-6524: before anything else writes, bring every shard's label
        // dictionary to shard 0's, or refuse a disagreement that records on
        // the disagreeing shard depend on.
        try sharded_labels.reconcileAtOpen(self, cfg.label_dict_divergence);

        _ = try sharded_recovery.reconcilePendingPrepares(self);

        // Edge co-location (Phase B): MIGRATE a pre-co-location (legacy) graph.
        // A graph whose shard-manifest `layout_version` is < CURRENT has its
        // cross-shard in-edges in the OLD location (dst shard's adj_in) and an
        // EMPTY adj_in_remote, so the scatter `expandIn` would silently miss
        // them. Rebuild each shard's adj_in_remote from its (authoritative,
        // layout-independent) adj_out, then stamp the version LAST. Idempotent +
        // crash-safe: a crash before the stamp re-runs cleanly; a crash after it
        // skips (the rebuilt pages are durable). adj_out is never mutated.
        if (self.shard_manifest.layout_version < shard_manifest_mod.CURRENT_LAYOUT_VERSION and !self.shards[0].read_only) {
            for (self.shards) |eng| {
                try eng.migrateColocateInEdges();
                // Durable per shard before we stamp: flush rebuilt pages +
                // truncate WAL so a crash after the stamp finds them on disk.
                try eng.checkpoint();
            }
            self.shard_manifest.layout_version = shard_manifest_mod.CURRENT_LAYOUT_VERSION;
            try shard_manifest_mod.writeToDir(self.allocator, self.graph_root, self.shard_manifest);
        }

        return self;
    }

    pub fn close(self: *ShardedGraphEngine) !void {
        var first_err: ?anyerror = null;
        for (self.shards) |eng| {
            eng.close() catch |err| {
                if (first_err == null) first_err = err;
            };
        }
        // Tear down the owned shared pool ONLY after every sub-engine has
        // released its submitter slot and stopped submitting. Borrowed
        // pools (owned_shared_pool == null) belong to the caller.
        if (self.owned_shared_pool != null) {
            self.shared_thread_pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
            self.shared_thread_pool.deinit();
            self.owned_shared_pool = null;
        }
        self.allocator.free(self.graph_root);
        self.allocator.destroy(self);
        if (first_err) |err| return err;
    }

    pub fn deinit(self: *ShardedGraphEngine) void {
        for (self.shards) |eng| eng.deinit();
        if (self.owned_shared_pool != null) {
            self.shared_thread_pool.shutdown(.drain, 5 * std.time.ns_per_s) catch {};
            self.shared_thread_pool.deinit();
            self.owned_shared_pool = null;
        }
        self.allocator.free(self.graph_root);
        self.allocator.destroy(self);
    }

    // ========================================================================
    // PHASE G — crash-reopen exact-index reconcile: public API for an EXTERNAL
    // derived index (e.g. geode's prop_exact.idx). ADDITIVE — pure reads over
    // already-recovered state; no behaviour change to any existing path.
    // ========================================================================

    /// Number of shards backing this graph. The G2 durable-frontier / epoch
    /// getters are PER-SHARD (each shard has its own manifest + recovery); an
    /// external per-graph index compares against the owning shard via
    /// `shard(s)` (geode already reads `shards[s].manifest`).
    pub fn shardCount(self: *ShardedGraphEngine) usize {
        _ = self;
        return SHARD_COUNT;
    }

    /// Per-shard engine accessor for the G2 getters
    /// (`shard(s).checkpointEpoch()` / `.durableFrontierLsn()` /
    /// `.preRecoveryFrontierLsn()`).
    pub fn shard(self: *ShardedGraphEngine, index: usize) *GraphEngine {
        return self.shards[index];
    }

    /// G1. Resolve the recovery tail-affected page set to the OWNING node ids
    /// across ALL shards, deduped and ascending (caller frees). THREE-WAY
    /// signal, matching `GraphEngine.tailAffectedNodeIds`:
    ///   * `null`             — a full REBUILD is required (some shard's capture
    ///     overflowed / was off, or its tail touched props pages it cannot
    ///     attribute). The external index MUST rebuild wholesale.
    ///   * non-null EMPTY     — nothing to reconcile (no shard had a
    ///     node-affecting committed tail).
    ///   * non-null non-empty — the unioned affected node ids.
    ///
    /// SOUNDNESS across shards: if ANY shard requires a rebuild the WHOLE
    /// result is `null` (never a partial cross-shard set, which would look
    /// complete and leave the external index silently stale on the
    /// un-reconciled shard). Shards with no committed tail contribute nothing
    /// (an empty, non-null per-shard result — not a rebuild signal).
    pub fn tailAffectedNodeIds(self: *ShardedGraphEngine, allocator: Allocator) !?[]NodeId {
        var set: std.AutoHashMapUnmanaged(NodeId, void) = .empty;
        defer set.deinit(allocator);
        for (self.shards) |eng| {
            const ids = (try eng.resolveTailAffectedNodeIds(allocator)) orelse
                // A shard needs a full rebuild → the external index must
                // rebuild wholesale; never return a partial cross-shard set.
                return null;
            defer allocator.free(ids);
            for (ids) |id| try set.put(allocator, id, {});
        }
        const out = try allocator.alloc(NodeId, set.count());
        errdefer allocator.free(out);
        var it = set.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) out[i] = k.*;
        std.mem.sort(NodeId, out, {}, std.sort.asc(NodeId));
        return out;
    }

    pub fn getNode(self: *ShardedGraphEngine, id: NodeId) anyerror!?NodeRec {
        return self.shards[shard_count_mod.shardOfNode(id)].getNode(id);
    }

    pub fn putNode(self: *ShardedGraphEngine, id: NodeId, rec: NodeRec) anyerror!void {
        return self.shards[shard_count_mod.shardOfNode(id)].putNode(id, rec);
    }

    pub fn allocNode(self: *ShardedGraphEngine) anyerror!NodeId {
        // Round-robin across shards so consumers that call allocNode in a
        // tight loop get balanced distribution. Deterministic routing keeps
        // tests reproducible.
        const idx = self.coordinator_txn_counter.fetchAdd(1, .monotonic) % SHARD_COUNT;
        return self.shards[idx].allocNode();
    }

    pub fn deleteNode(self: *ShardedGraphEngine, id: NodeId) anyerror!void {
        return self.shards[shard_count_mod.shardOfNode(id)].deleteNode(id);
    }

    pub fn getEdge(self: *ShardedGraphEngine, edge_id: EdgeId) anyerror!?EdgeEntry {
        // Edges live on their source node's shard. Edge id is shard-striped
        // (allocated on the source shard), so shardOfNode(edge_id) == source shard.
        return self.shards[shard_count_mod.shardOfNode(edge_id)].getEdge(edge_id);
    }

    pub fn expandOutIter(self: *ShardedGraphEngine, id: NodeId, rel_type: ?u32) anyerror!adj_store_mod.AdjStore.AdjEdgeIterator {
        return self.shards[shard_count_mod.shardOfNode(id)].expandOutIter(id, rel_type);
    }

    pub fn expandInIter(self: *ShardedGraphEngine, id: NodeId, rel_type: ?u32) anyerror!FanInEdgeIterator {
        // Edge co-location (Phase A): incoming adjacency for node v is now
        // FRAGMENTED across the shards of v's various sources (each source shard
        // recorded its own in-entry into its adj_in_remote keyed by v). Reverse
        // traversal therefore becomes a bounded SHARD_COUNT-way scatter-gather
        // over every shard's adj_in_remote + in_head_dir, instead of routing to
        // shardOfNode(v). Forward traversal (expandOutIter) stays single-shard.
        return .{
            .owner = self,
            .dst = id,
            .rel_type = rel_type,
            .shard_idx = 0,
            .current = null,
        };
    }

    // -------------------------------------------------------------------
    // Property ops — TWO surfaces (GAP prop-store slab packing, P5):
    //
    //  * HEAD-ROUTED (getProperty/putProperty/removeProperty/
    //    getAllProperties): the GraphStorage-vtable compatibility surface.
    //    It routes by `shardOfNode(prop_head)`, which is only meaningful for
    //    the legacy layout heads this facade itself hands out. A SLAB head
    //    (tag|page|slot) carries NO shard information — prop page ids are
    //    per-shard-sequential, not shard-striped, and the head CHANGES on
    //    relocation — so head-value routing would pin an arbitrary shard's
    //    page (silent wrong data). Slab heads are therefore REJECTED loudly
    //    here, and the head-routed create path is forced LEGACY so this
    //    surface never mints a slab head in the first place.
    //
    //  * OWNER-ROUTED (putNodeProperty/removeNodeProperty/getNodeProperty/
    //    getAllNodeProperties): the correct router. A node's property chain
    //    lives on the shard that owns the NODE (geode's adapter routes the
    //    same way), so ops route by the owning node id and work for both
    //    legacy and slab heads.
    // -------------------------------------------------------------------

    pub fn getProperty(self: *ShardedGraphEngine, prop_head: u64, key: []const u8, allocator: Allocator) anyerror!?PropertyValue {
        // Head-routed compatibility path: legacy heads only (see above).
        if (prop_store_mod.isSlabHead(prop_head)) return error.SlabHeadRequiresOwnerRouting;
        return self.shards[shard_count_mod.shardOfNode(prop_head)].getProperty(prop_head, key, allocator);
    }

    /// Owner-routed single-property read: routes by the owning node id.
    pub fn getNodeProperty(self: *ShardedGraphEngine, node_id: NodeId, prop_head: u64, key: []const u8, allocator: Allocator) anyerror!?PropertyValue {
        return self.shards[shard_count_mod.shardOfNode(node_id)].getProperty(prop_head, key, allocator);
    }

    pub fn nodeCount(self: *ShardedGraphEngine) anyerror!u64 {
        var total: u64 = 0;
        for (self.shards) |eng| total += try eng.nodeCount();
        return total;
    }

    pub fn edgeCount(self: *ShardedGraphEngine) anyerror!u64 {
        var total: u64 = 0;
        for (self.shards) |eng| total += try eng.edgeCount();
        return total;
    }

    pub fn addEdge(self: *ShardedGraphEngine, from: NodeId, to: NodeId, rel_type: u32) anyerror!EdgeId {
        // Edge co-location: EVERY edge — same-shard or cross-endpoint — is a
        // SINGLE-shard write on shard(from). Out-adjacency, edge body,
        // edge_index, the existence index AND the incoming adjacency (into
        // shard(from)'s adj_in_remote keyed by `to`) all live on one engine, so
        // the write is one WAL txn with no cross-shard 2PC (the old
        // `crossShardAddEdge` 2PC path was removed in Phase C). Reverse traversal
        // is served by the FanInEdgeIterator scatter.
        const s_from = shard_count_mod.shardOfNode(from);
        return self.shards[s_from].addEdgeColocated(from, to, rel_type);
    }

    /// GAP-ENT-0024 P2: co-located edge add carrying the geode-minted 64-bit
    /// PUBLIC edge id inline. Routes to shard(from) exactly like `addEdge` —
    /// one single-shard WAL txn; the id rides both durable adjacency records
    /// (adj_out + adj_in_remote) in v2 blocks, so the edge needs NO
    /// `__geode_internal_edge_id` property page. `addEdge` remains the
    /// legacy public_id==0 path.
    ///
    /// CONTRACT (review F4): `public_id == 0` is RESERVED — it means "no
    /// inline id" and silently degrades the edge to the legacy class (readers
    /// fall back to the `__geode_internal_edge_id` property, which THIS path
    /// does not write). A caller that stops writing the id property MUST NOT
    /// pass 0 for a real edge (geode mints nonzero time-based ids; its
    /// adapter must reject/handle 0 explicitly), otherwise the edge has no
    /// durable public id anywhere. A debug assert is impossible here — the
    /// legacy `addEdge`/`addEdgeColocated` delegates pass 0 by design.
    pub fn addEdgeColocatedWithPublicId(self: *ShardedGraphEngine, from: NodeId, to: NodeId, rel_type: u32, public_id: u64) anyerror!EdgeId {
        const s_from = shard_count_mod.shardOfNode(from);
        return self.shards[s_from].addEdgeColocatedWithPublicId(from, to, rel_type, public_id);
    }

    pub fn removeEdge(self: *ShardedGraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId) anyerror!void {
        // Edge co-location (Phase C): a co-located edge lives ENTIRELY on
        // shard(from) — out-adjacency, edge_index, existence index AND incoming
        // adjacency (shard(from).adj_in_remote keyed by `to`). So even a
        // cross-ENDPOINT remove is a single-shard delete; no 2PC, no
        // CrossShardEdgeUnsupported.
        const s_from = shard_count_mod.shardOfNode(from);
        return self.shards[s_from].removeEdge(from, to, edge_id);
    }

    pub fn putProperty(self: *ShardedGraphEngine, owner: u64, key: []const u8, val: PropertyValue) anyerror!u64 {
        // `owner == 0` means "create a new chain"; round-robin to a shard.
        // Forced LEGACY (P5): a slab head minted here would be unroutable by
        // every other head-routed op (see the surface note above); slab
        // packing is only reachable through owner-routed putNodeProperty.
        if (owner == 0) {
            const idx = self.coordinator_txn_counter.fetchAdd(1, .monotonic) % SHARD_COUNT;
            return self.shards[idx].putPropertyLegacy(owner, key, val);
        }
        if (prop_store_mod.isSlabHead(owner)) return error.SlabHeadRequiresOwnerRouting;
        return self.shards[shard_count_mod.shardOfNode(owner)].putProperty(owner, key, val);
    }

    /// Owner-routed property write: routes by the owning node id, so the
    /// chain (legacy or slab) co-locates with its node and every later
    /// owner-routed op finds it. Returns the (possibly new) prop_head; the
    /// caller must store it back into the node record exactly as with the
    /// single-engine API.
    pub fn putNodeProperty(self: *ShardedGraphEngine, node_id: NodeId, prop_head: u64, key: []const u8, val: PropertyValue) anyerror!u64 {
        return self.shards[shard_count_mod.shardOfNode(node_id)].putProperty(prop_head, key, val);
    }

    pub fn removeProperty(self: *ShardedGraphEngine, owner: u64, key: []const u8) anyerror!void {
        // Head-routed compatibility path: legacy heads only (see above).
        if (prop_store_mod.isSlabHead(owner)) return error.SlabHeadRequiresOwnerRouting;
        return self.shards[shard_count_mod.shardOfNode(owner)].removeProperty(owner, key);
    }

    /// Owner-routed property removal: routes by the owning node id.
    pub fn removeNodeProperty(self: *ShardedGraphEngine, node_id: NodeId, prop_head: u64, key: []const u8) anyerror!void {
        return self.shards[shard_count_mod.shardOfNode(node_id)].removeProperty(prop_head, key);
    }

    pub fn getAllProperties(self: *ShardedGraphEngine, prop_head: u64) anyerror!PropStore.PropIterator {
        // Head-routed compatibility path: legacy heads only (see above).
        if (prop_store_mod.isSlabHead(prop_head)) return error.SlabHeadRequiresOwnerRouting;
        return self.shards[shard_count_mod.shardOfNode(prop_head)].getAllProperties(prop_head);
    }

    /// Owner-routed all-properties iterator: routes by the owning node id.
    pub fn getAllNodeProperties(self: *ShardedGraphEngine, node_id: NodeId, prop_head: u64) anyerror!PropStore.PropIterator {
        return self.shards[shard_count_mod.shardOfNode(node_id)].getAllProperties(prop_head);
    }

    pub fn setEdgeProperty(self: *ShardedGraphEngine, from: NodeId, to: NodeId, edge_id: EdgeId, key: []const u8, val: PropertyValue) anyerror!void {
        return self.shards[shard_count_mod.shardOfNode(from)].setEdgeProperty(from, to, edge_id, key, val);
    }

    pub fn removeEdgeProperty(self: *ShardedGraphEngine, from: NodeId, edge_id: EdgeId, key: []const u8) anyerror!void {
        return self.shards[shard_count_mod.shardOfNode(from)].removeEdgeProperty(from, edge_id, key);
    }

    pub fn getEdgeProperty(self: *ShardedGraphEngine, from: NodeId, edge_id: EdgeId, key: []const u8, allocator: Allocator) anyerror!?PropertyValue {
        return self.shards[shard_count_mod.shardOfNode(from)].getEdgeProperty(from, edge_id, key, allocator);
    }

    pub fn getAllEdgeProperties(self: *ShardedGraphEngine, from: NodeId, edge_id: EdgeId) anyerror!?PropStore.PropIterator {
        return self.shards[shard_count_mod.shardOfNode(from)].getAllEdgeProperties(from, edge_id);
    }

    pub fn addLabel(self: *ShardedGraphEngine, node_id: NodeId, label: LabelId) anyerror!void {
        return self.shards[shard_count_mod.shardOfNode(node_id)].addLabel(node_id, label);
    }

    pub fn removeLabel(self: *ShardedGraphEngine, node_id: NodeId, label: LabelId) anyerror!void {
        return self.shards[shard_count_mod.shardOfNode(node_id)].removeLabel(node_id, label);
    }

    pub fn scanLabel(self: *ShardedGraphEngine, label: LabelId, allocator: Allocator) anyerror![]NodeId {
        var out: std.ArrayList(NodeId) = .empty;
        errdefer out.deinit(allocator);
        for (self.shards) |eng| {
            const slice = try eng.scanLabel(label, allocator);
            defer allocator.free(slice);
            try out.appendSlice(allocator, slice);
        }
        return out.toOwnedSlice(allocator);
    }

    /// Streaming fan-out iterator across all shards' label indexes.
    /// Two-argument form so `interface.GraphStorage.init` can bind it
    /// to the vtable via its `scanLabelIter(self, label)` detection.
    pub fn scanLabelIter(self: *ShardedGraphEngine, label: LabelId) !FanOutNodeIterator {
        return .{
            .owner = self,
            .label = label,
            .shard_idx = 0,
            .current = null,
        };
    }

    /// Label dictionary is global across shards: shard 0 assigns the id and
    /// makes it durable, then shards 1..N-1 record the same pair in parallel
    /// (SONNY-6524; see sharded_labels.zig). Hot-path addLabel(node, id) is
    /// single-shard; the broadcast only fires when a new name is registered.
    /// An existing name costs N hash lookups and no write.
    ///
    /// CONCURRENCY: as before, the caller serializes label assignment for
    /// this graph (geode: per-graph `string_indexes_mutex` or the graph
    /// lock); the call returns only after every per-shard worker has joined,
    /// so that serialization covers the parallel section and no other
    /// assignment can interleave a different id on any shard. Each worker
    /// writes only its own shard's dictionary and directory. The injected
    /// allocator must be thread-safe (the same precondition as `open`).
    ///
    /// ERRORS: if shard 0's write fails nothing is assigned anywhere. If a
    /// shard k >= 1 fails, the call fails, shard k has the name unassigned
    /// and the shards that succeeded keep shard 0's pair; retrying completes
    /// the missing shards with the same id, and `open` after a crash fills
    /// them in. `error.LabelDictionaryDiverged` when a shard already has the
    /// name under a different id, or the id under a different name.
    pub fn getOrAssignLabel(self: *ShardedGraphEngine, label_name: []const u8) !LabelId {
        return sharded_labels.getOrAssignLabel(self, label_name);
    }

    pub fn beginTxn(self: *ShardedGraphEngine) anyerror!TxnId {
        const idx = self.coordinator_txn_counter.fetchAdd(1, .monotonic) % SHARD_COUNT;
        const local = try self.shards[idx].beginTxn();
        return encodeTxn(idx, local);
    }

    pub fn commitTxn(self: *ShardedGraphEngine, txn: TxnId) anyerror!void {
        const d = decodeTxn(txn);
        return self.shards[d.shard].commitTxn(d.local);
    }

    pub fn abortTxn(self: *ShardedGraphEngine, txn: TxnId) anyerror!void {
        const d = decodeTxn(txn);
        return self.shards[d.shard].abortTxn(d.local);
    }

    pub fn checkpoint(self: *ShardedGraphEngine) anyerror!void {
        var first_err: ?anyerror = null;
        for (self.shards) |eng| {
            eng.checkpoint() catch |err| {
                if (first_err == null) first_err = err;
            };
        }
        if (first_err) |err| return err;
    }

    /// GAP-0900 L2: run the light (incremental/bounded) checkpoint on every
    /// shard. Mirrors checkpoint() but skips the O(graph-size) derived-index
    /// save on each shard. Use for the periodic load-driven trigger.
    pub fn checkpointLight(self: *ShardedGraphEngine) anyerror!void {
        var first_err: ?anyerror = null;
        for (self.shards) |eng| {
            eng.checkpointLight() catch |err| {
                if (first_err == null) first_err = err;
            };
        }
        if (first_err) |err| return err;
    }

    /// Aggregated metrics snapshot. Refreshes an internal buffer on each
    /// call and returns a pointer to it — valid until the next call.
    pub fn getMetrics(self: *ShardedGraphEngine) *const Metrics {
        self.aggregated_metrics = .{};
        inline for (std.meta.fields(Metrics)) |field| {
            if (@typeInfo(field.type) == .int) {
                var sum: field.type = 0;
                for (self.shards) |eng| {
                    sum += @field(eng.getMetrics().*, field.name);
                }
                @field(self.aggregated_metrics, field.name) = sum;
            }
        }
        return &self.aggregated_metrics;
    }

    /// Returns a GraphStorage vtable bound to this sharded engine, allowing
    /// external consumers (e.g. geode) to use ShardedGraphEngine through the
    /// standard GraphStorage interface with zero API changes.
    pub fn storage(self: *ShardedGraphEngine) GraphStorage {
        return GraphStorage.init(ShardedGraphEngine, self);
    }

    /// Drains expandOutIter into a caller-owned []EdgeEntry slice.
    pub fn expandOut(self: *ShardedGraphEngine, id: NodeId, rel_type: ?u32, allocator: Allocator) anyerror![]EdgeEntry {
        var iter = try self.expandOutIter(id, rel_type);
        defer iter.deinit();
        var list: std.ArrayList(EdgeEntry) = .empty;
        errdefer list.deinit(allocator);
        while (try iter.next()) |entry| try list.append(allocator, entry);
        return list.toOwnedSlice(allocator);
    }

    /// Drains expandInIter into a caller-owned []EdgeEntry slice.
    pub fn expandIn(self: *ShardedGraphEngine, id: NodeId, rel_type: ?u32, allocator: Allocator) anyerror![]EdgeEntry {
        var iter = try self.expandInIter(id, rel_type);
        defer iter.deinit();
        var list: std.ArrayList(EdgeEntry) = .empty;
        errdefer list.deinit(allocator);
        while (try iter.next()) |entry| try list.append(allocator, entry);
        return list.toOwnedSlice(allocator);
    }
};

/// Streaming iterator across every shard's `LabelIndex` for a single
/// label. Advances one shard at a time; drops into the next shard's
/// inner iterator when the current one is exhausted. Value-typed so
/// `GraphStorage.init`'s `wrapNodeIterator` can heap-wrap it for the
/// vtable automatically.
pub const FanOutNodeIterator = struct {
    owner: *ShardedGraphEngine,
    label: LabelId,
    shard_idx: usize,
    current: ?label_index_mod.LabelIndex.Iterator,

    pub fn next(self: *FanOutNodeIterator) anyerror!?NodeId {
        while (true) {
            if (self.current) |*inner| {
                if (try inner.next()) |nid| return nid;
                // Exhausted — release the owned posting-list slice (PERF-0054).
                inner.deinit();
                self.current = null;
            }
            if (self.shard_idx >= SHARD_COUNT) return null;
            self.current = try self.owner.shards[self.shard_idx].scanLabelIter(self.label);
            self.shard_idx += 1;
        }
    }

    pub fn deinit(self: *FanOutNodeIterator) void {
        // Release the active shard's owned posting-list slice if iteration
        // was abandoned before the iterator was exhausted (PERF-0054).
        if (self.current) |*inner| inner.deinit();
        self.current = null;
    }
};

/// Edge co-location (Phase A): streaming reverse-adjacency iterator that fans a
/// single dst's incoming-edge read over EVERY shard's `adj_in_remote` (keyed by
/// `in_head_dir[dst]`), unioning the results. Modeled on `FanOutNodeIterator`:
/// it advances one shard at a time, draining that shard's `AdjEdgeIterator`
/// before opening the next shard's. Yielded `EdgeEntry` values are copies and
/// stay valid after `deinit()`. The per-page pin/unpin discipline is inherited
/// from `AdjStore.AdjEdgeIterator` (the same as the legacy single-shard path),
/// so concurrent readers stay SEGV-safe. Value-typed so `GraphStorage.init`'s
/// `wrapEdgeIterator` heap-boxes it for the vtable with no signature change.
pub const FanInEdgeIterator = struct {
    owner: *ShardedGraphEngine,
    dst: NodeId,
    rel_type: ?u32,
    shard_idx: usize,
    current: ?adj_store_mod.AdjStore.AdjEdgeIterator,

    pub fn next(self: *FanInEdgeIterator) anyerror!?EdgeEntry {
        while (true) {
            if (self.current) |*inner| {
                if (try inner.next()) |entry| return entry;
                // Exhausted this shard's chain — unpin its active page.
                inner.deinit();
                self.current = null;
            }
            if (self.shard_idx >= SHARD_COUNT) return null;
            // Open the next shard's adj_in_remote chain for dst (may be empty —
            // head 0 yields an iterator that returns null immediately).
            self.current = try self.owner.shards[self.shard_idx].expandInRemoteIter(self.dst, self.rel_type);
            self.shard_idx += 1;
        }
    }

    pub fn deinit(self: *FanInEdgeIterator) void {
        // Release the active shard's pinned page if iteration was abandoned
        // before exhaustion (mirrors AdjEdgeIterator/FanOutNodeIterator).
        if (self.current) |*inner| inner.deinit();
        self.current = null;
    }
};

pub fn uuidHex(uuid: [16]u8) [32]u8 {
    var out: [32]u8 = undefined;
    const hex = "0123456789abcdef";
    for (uuid, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0F];
    }
    return out;
}

test {
    _ = @import("sharded_engine_test.zig");
}
