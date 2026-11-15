// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const Allocator = std.mem.Allocator;

const buffer_pool_mod = @import("buffer_pool.zig");
const wal_mod = @import("wal.zig");
const manifest_mod = @import("manifest.zig");
const file_manager_mod = @import("file_manager.zig");
const graph_dir_mod = @import("graph_dir.zig");
const checkpoint_mod = @import("checkpoint.zig");
const wal_record_mod = @import("wal_record.zig");
const types = @import("types.zig");
const metrics_mod = @import("metrics.zig");
const config_mod = @import("config.zig");
const page_mod = @import("page.zig");
const node_mod = @import("node.zig");
const edge_mod = @import("edge.zig");
const encryption_mod = @import("encryption.zig");

const BufferPool = buffer_pool_mod.BufferPool;
const WalManager = wal_mod.WalManager;
const Manifest = manifest_mod.Manifest;
const FileManager = file_manager_mod.FileManager;
const GraphDir = graph_dir_mod.GraphDir;
const Checkpointer = checkpoint_mod.Checkpointer;
const WalRecord = wal_record_mod.WalRecord;
const WalRecordType = wal_record_mod.WalRecordType;
const FileId = types.FileId;
const ReplayFailure = wal_mod.ReplayFailure;

/// Transaction state during recovery.
const TxnRecoveryState = enum {
    active,
    committed,
    aborted,
};

/// Crash recovery via manifest + WAL replay.
///
/// Recovery loads the latest valid manifest (A/B), then replays committed
/// WAL transactions from the last checkpoint LSN to restore the database
/// to a consistent state.
pub const Recovery = struct {
    allocator: Allocator,
    /// Count of WAL records skipped due to checksum mismatch during recovery.
    skipped_checksum_failures: u64 = 0,
    /// Encryption key for WAL access. Must match the key used when writing.
    encryption_key: ?[32]u8 = null,
    /// Optional metrics sink for recording recovery_duration_ns.
    metrics: ?*metrics_mod.Metrics = null,
    /// Optional log callback for structured event emission.
    log_fn: ?*const fn (level: config_mod.LogLevel, msg: []const u8) void = null,
    /// Policy for handling legacy (V1) graph formats.
    legacy_policy: config_mod.LegacyPolicy = .reject,
    /// Set to true when recovery opened a V1 graph in read-only mode.
    read_only: bool = false,
    /// Details about the last fail-closed WAL rejection, when present.
    last_failure: ?ReplayFailure = null,
    /// GAP-ENT-0011: true when recovery APPLIED at least one committed
    /// page-image from the WAL tail. The persisted free.store is written at
    /// checkpoint time only, so in this case it is STALE with respect to the
    /// pages just replayed+flushed (pages allocated after the checkpoint are
    /// still marked FREE in it) and MUST NOT be trusted by the open path —
    /// engine.open rebuilds the free-space bitmaps from on-disk file sizes
    /// instead of loading the checkpoint-era snapshot.
    applied_committed_pages: bool = false,
    /// WAL-recovery counter staleness: the manifest id counters
    /// (`next_node_id`, `next_edge_id`, `next_txn_id`) are persisted at
    /// CHECKPOINT time only, so after replaying a committed WAL tail they
    /// lag the replayed records — counter-bounded scans miss them and, far
    /// worse, `allocNode`/`allocEdge` RE-ISSUE their ids (silent overwrite
    /// of committed data). Recovery therefore tracks the maximum node id /
    /// edge id observed in the committed page images it APPLIES (replay
    /// already visits every one of them, so this is O(replayed bytes) with
    /// zero extra I/O — a post-replay store page-scan would be O(store
    /// size) and defeat the fast-restart work) plus the maximum txn id seen
    /// anywhere in the tail, and re-derives the counters BEFORE persisting
    /// the advanced `last_checkpoint_lsn`. Counters and LSN travel in the
    /// SAME atomic A/B manifest write, so no crash can leave "advanced LSN
    /// + stale counters" on disk (the invariant the free.store
    /// truncate-signal protects for its separate file holds here by
    /// construction: heal-then-write, both slots).
    max_replayed_node_id: u64 = 0,
    max_replayed_edge_id: u64 = 0,
    max_seen_txn_id: u64 = 0,
    /// Id-allocation stride: 1 for a standalone engine, SHARD_COUNT for a
    /// sharded member (node/edge ids are residue-classed per shard, so the
    /// healed counter must advance by the stride to keep `shardOfNode`
    /// routing correct — every id observed in this shard's stores carries
    /// the shard's residue, so `max + stride` preserves it). Set by the
    /// engine open path before `recover` runs.
    id_stride: u64 = 1,
    /// The shard's residue class mod `id_stride` (0 for a standalone
    /// engine). Every id this shard's allocator ever mints is ≡ this value,
    /// so the harvest FILTERS on it: a LEGACY pre-co-location `.adj_in`
    /// image can carry edge ids allocated on the SOURCE shard (a foreign
    /// residue class); healing from one would move `next_edge_id` into the
    /// foreign class permanently and `shardOfNode(edge_id)` routing would
    /// misroute every edge subsequently created here (silent getEdge loss).
    /// Foreign-residue ids are owned — and healed — by their owning shard's
    /// own images, so skipping them here is exact, not lossy. The same
    /// guard applies to node ids for symmetry (same invariant). Set by the
    /// engine open path alongside `id_stride`.
    shard_residue: u64 = 0,
    /// GAP-ENT-0025: stats-count healing. `manifest.node_count`/`edge_count`
    /// are persisted at CHECKPOINT time only (like the id counters above), so
    /// after replaying a committed WAL tail they misreport until the next
    /// checkpoint. These signed deltas accumulate the net change in LIVE
    /// records (non-empty, non-deleted node slots; adjacency out-entries)
    /// across the committed page images replay APPLIES: each applied image is
    /// censused against the page's previous state — the pre-replay on-disk
    /// page on first touch, the previously applied image thereafter — so the
    /// per-image differences telescope to final-vs-pre-replay per page. The
    /// deltas are folded into the manifest counts BEFORE the advanced-LSN
    /// manifest write, so counts and LSN travel in the same atomic A/B image.
    /// STATS-ONLY (no slot-allocation or scan-bound consumer reads these
    /// counts) and best-effort by design; see `trackReplayedCountDeltas` for
    /// the honest precision statement.
    replayed_node_delta: i64 = 0,
    replayed_edge_delta: i64 = 0,

    /// WAL-aware derived-index durability Phase 3 (tail reconcile): the set of
    /// (file_id, page_id) pairs this recovery APPLIED via committed page_update
    /// records — the bounded tail-affected page set. The engine copies it out
    /// at OPEN and, at first-access derived-index hydration, reconciles ONLY
    /// these pages into the loaded snapshot instead of rebuilding O(graph).
    /// Keyed `(file_id << 64) | page_id`; deduplicated; bounded by the tail LSN
    /// range. `affected_pages_overflow` latches on an OOM insert so the engine
    /// falls back to a full rebuild (a partial set would reconcile incorrectly).
    affected_pages: std.AutoHashMapUnmanaged(u128, void) = .empty,
    affected_pages_overflow: bool = false,
    /// The DURABLE committed frontier (`manifest.last_checkpoint_lsn`) as it
    /// stood in the selected manifest BEFORE this recovery replayed anything —
    /// i.e. the LSN this Recovery instance STARTED replaying from (start_lsn-1).
    /// The tail reconcile is only valid when the on-disk derived-index
    /// snapshot's `covered_lsn` EQUALS this: then the ONLY committed records
    /// past the snapshot are THIS session's recovery slice, which
    /// `affected_pages` captured completely. If a PRIOR recovery advanced the
    /// frontier past the snapshot WITHOUT re-persisting it (multi-crash, no
    /// checkpoint between), the snapshot's covered_lsn is < this and the
    /// captured set is only the LATEST slice → the engine must full-rebuild, not
    /// partial-reconcile (else the earlier tail's committed mutations are
    /// silently dropped from the derived indexes though they are durable in the
    /// primary stores).
    pre_recovery_last_checkpoint_lsn: u64 = 0,
    /// Opt-in: only the standalone engine open path (which reconciles the tail
    /// into its loaded derived-index snapshot) sets this true and `deinit()`s
    /// the map. Every other recover() caller (unit tests, sharded/other paths
    /// that rebuild) leaves it false → no allocation, no ownership to free.
    capture_affected_pages: bool = false,

    pub fn init(allocator: Allocator, encryption_key: ?[32]u8) Recovery {
        return .{
            .allocator = allocator,
            .skipped_checksum_failures = 0,
            .encryption_key = encryption_key,
            .last_failure = null,
        };
    }

    /// Securely zero the encryption key material. Must be called when the
    /// Recovery instance is no longer needed to avoid leaving key material
    /// in memory.
    pub fn deinit(self: *Recovery) void {
        if (self.encryption_key) |*key| {
            // fips-exempt: non-security — defensive key-material zeroing on
            // teardown, not a cryptographic algorithm operation.
            std.crypto.secureZero(u8, key);
        }
        self.affected_pages.deinit(self.allocator);
    }

    /// Phase 3 tail reconcile: record a (file_id, page_id) that replay applied
    /// from a committed page_update. Best-effort — an OOM latches
    /// `affected_pages_overflow` so the engine rebuilds instead of reconciling
    /// from an incomplete set (an under-count would leave stale index entries).
    fn recordAffectedPage(self: *Recovery, file_id: FileId, page_id: u64) void {
        if (!self.capture_affected_pages) return;
        const key: u128 = (@as(u128, @intFromEnum(file_id)) << 64) | page_id;
        self.affected_pages.put(self.allocator, key, {}) catch {
            self.affected_pages_overflow = true;
        };
    }

    /// Number of distinct tail-affected pages (test/observability).
    pub fn affectedPageCount(self: *const Recovery) usize {
        return self.affected_pages.count();
    }

    /// True when (file_id, page_id) is in the tail-affected set (test helper).
    pub fn hasAffectedPage(self: *const Recovery, file_id: FileId, page_id: u64) bool {
        const key: u128 = (@as(u128, @intFromEnum(file_id)) << 64) | page_id;
        return self.affected_pages.contains(key);
    }

    /// Recover a graph from its directory.
    /// 1. Read manifest A and B, select valid one with highest counter
    /// 2. Open store files
    /// 3. Read WAL from last_checkpoint_lsn
    /// 4. Classify transactions (scan for BEGIN/COMMIT/ABORT)
    /// 5. Replay committed page_update records into buffer pool
    /// 6. Discard uncommitted transaction records
    /// 7. Flush buffer pool
    /// 8. Write fresh checkpoint
    /// Returns the recovered manifest.
    pub fn recover(
        self: *Recovery,
        graph_dir: *const GraphDir,
        buffer_pool: *BufferPool,
        file_manager: *FileManager,
    ) !Manifest {
        config_mod.emitEvent(self.log_fn, .recovery_start);

        const io = std.Io.Threaded.global_single_threaded.io();
        const start_ts = std.Io.Clock.Timestamp.now(io, .awake);
        defer {
            const end_ts = std.Io.Clock.Timestamp.now(io, .awake);
            const elapsed = start_ts.durationTo(end_ts);
            if (self.metrics) |m| {
                m.recovery_duration_ns = @intCast(elapsed.raw.toNanoseconds());
            }
            config_mod.emitEvent(self.log_fn, .recovery_end);
        }

        // 1. Read manifest A and B, select valid one with highest counter
        const path_a = try graph_dir.manifestPath(self.allocator, .a);
        defer self.allocator.free(path_a);
        const path_b = try graph_dir.manifestPath(self.allocator, .b);
        defer self.allocator.free(path_b);

        // SEC-0043: under TDE (key configured) the manifest is HMAC-authenticated.
        // A forged manifest (e.g. rolled-back last_checkpoint_lsn) is rejected here.
        // SONNY-6616: a store written under another key is EncryptionKeyMismatch.
        var m = try Manifest.readSelected(self.allocator, path_a, path_b, self.encryption_key);
        if (!std.mem.eql(u8, &m.graph_uuid, &graph_dir.graph_uuid)) {
            return error.UuidMismatch;
        }

        // Tail-reconcile validity: record the durable committed frontier BEFORE
        // this recovery advances it (line ~572). The reconcile is only correct
        // when the snapshot's covered_lsn == this value (see the field doc); a
        // prior un-checkpointed recovery would leave covered_lsn strictly below
        // it, and our captured affected-page set would be only the latest slice.
        self.pre_recovery_last_checkpoint_lsn = m.last_checkpoint_lsn;

        // Validate manifest format version compatibility
        var upgraded_from_v2 = false;
        // SONNY-6590: V5 has the V4 layout (it records sealed side files).
        if (m.format_version != manifest_mod.MANIFEST_VERSION and
            m.format_version != manifest_mod.MANIFEST_VERSION_SEALED_SIDE_FILES)
        {
            if (m.format_version == manifest_mod.MANIFEST_VERSION_V1) {
                if (self.legacy_policy == .read_only) {
                    std.log.warn("V1 graph format detected — opening in read-only mode (mutations will be rejected)", .{});
                    self.read_only = true;
                    // Continue opening; actual mutation enforcement is in engine.zig
                } else {
                    std.log.warn("V1 graph format detected — data directory must be recreated for V2 (40-byte NodeRec is incompatible with 48-byte V2 layout)", .{});
                    return error.IncompatibleVersion;
                }
            } else if (m.format_version == manifest_mod.MANIFEST_VERSION_V2) {
                // GAP-ENT-0024 downgrade gate: a V2 store (v0.2.23 and earlier)
                // is fully readable by this binary — accept it and upgrade the
                // manifest to V3 in place. The rewrite of both manifest slots at
                // the end of `recover` persists the bump, so a pre-v0.2.24
                // binary pointed at this store afterwards fails loudly here
                // (IncompatibleVersion) instead of misparsing 32 B v2 adjacency
                // entries at its 24 B stride and durably corrupting them.
                std.log.info("V2 store format detected — upgrading manifest to V3 (inline edge public-id era; pre-v0.2.24 binaries will refuse this store)", .{});
                m.format_version = manifest_mod.MANIFEST_VERSION;
                upgraded_from_v2 = true;
            } else {
                return error.IncompatibleVersion;
            }
        }

        // 2. Open store files
        _ = try file_manager.openFile(.nodes, .open_existing);
        _ = try file_manager.openFile(.adj_out, .open_existing);
        _ = try file_manager.openFile(.adj_in, .open_existing);
        _ = try file_manager.openFile(.props, .open_existing);
        _ = try file_manager.openFile(.var_store, .open_existing);
        _ = try file_manager.openFile(.free, .open_existing);
        // Edge co-location (Phase A): the incoming-adjacency chain bodies +
        // directory ride page-image redo, so their pagers must be registered
        // BEFORE replay can pinNew their pages. ADDITIVE: a pre-co-location
        // graph has no such files, so create-if-missing (an old graph simply has
        // no committed in_idx/in_dir pages to replay).
        _ = try file_manager.openFile(.in_idx, .create_if_missing);
        _ = try file_manager.openFile(.in_dir, .create_if_missing);

        // Register pagers with buffer pool
        if (file_manager.getPager(.nodes)) |p| buffer_pool.registerPager(.nodes, p);
        if (file_manager.getPager(.adj_out)) |p| buffer_pool.registerPager(.adj_out, p);
        if (file_manager.getPager(.adj_in)) |p| buffer_pool.registerPager(.adj_in, p);
        if (file_manager.getPager(.props)) |p| buffer_pool.registerPager(.props, p);
        if (file_manager.getPager(.var_store)) |p| buffer_pool.registerPager(.var_store, p);
        if (file_manager.getPager(.free)) |p| buffer_pool.registerPager(.free, p);
        if (file_manager.getPager(.in_idx)) |p| buffer_pool.registerPager(.in_idx, p);
        if (file_manager.getPager(.in_dir)) |p| buffer_pool.registerPager(.in_dir, p);

        // 3. Open WAL and read from last_checkpoint_lsn
        const wal_dir_path = try std.fmt.allocPrint(self.allocator, "{s}/wal", .{graph_dir.path});
        defer self.allocator.free(wal_dir_path);

        var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
        defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

        var wal = try WalManager.init(
            self.allocator,
            wal_dir,
            graph_dir.graph_uuid,
            m.last_checkpoint_lsn,
            .{ .encryption_key = self.encryption_key },
        );
        defer wal.deinit();

        const start_lsn = if (m.last_checkpoint_lsn > 0) m.last_checkpoint_lsn + 1 else 1;
        var saw_records = false;
        // SONNY-6424: highest graph-storage LSN among the records replayed.
        // A store written before the WAL sequence anchor can hold replayed
        // records whose inner LSN restarted below the frontier while their own
        // LSN is above it; the advanced frontier must cover them too.
        var max_record_lsn: u64 = 0;
        self.last_failure = null;

        // 4. Classify transactions. Any malformed or checksum-invalid record
        // aborts recovery so the operator can inspect the damaged WAL.
        var txn_states = std.AutoHashMap(u64, TxnRecoveryState).init(self.allocator);
        defer txn_states.deinit();

        const ClassifyCtx = struct {
            recovery: *Recovery,
            txn_states: *std.AutoHashMap(u64, TxnRecoveryState),
            saw_records: *bool,
            max_record_lsn: *u64,

            fn visit(ctx: *@This(), rec: *const WalRecord) !void {
                ctx.saw_records.* = true;
                if (rec.lsn > ctx.max_record_lsn.*) ctx.max_record_lsn.* = rec.lsn;

                // Counter healing: txn ids appear on EVERY record type, so
                // the classify pass (which already reads them all) is the
                // cheapest complete source for the txn-id watermark.
                if (rec.txn_id > ctx.recovery.max_seen_txn_id) {
                    ctx.recovery.max_seen_txn_id = rec.txn_id;
                }

                switch (rec.record_type) {
                    .begin_txn => try ctx.txn_states.put(rec.txn_id, .active),
                    .commit_txn => try ctx.txn_states.put(rec.txn_id, .committed),
                    .abort_txn => try ctx.txn_states.put(rec.txn_id, .aborted),
                    .page_update, .checkpoint_marker => {},
                    // Cross-shard 2PC records are collected and reconciled
                    // by sharded_recovery.reconcilePendingPrepares after
                    // per-shard recovery completes. Skipped here.
                    .cross_shard_prepare, .cross_shard_commit, .cross_shard_abort => {},
                }
            }
        };

        var classify_ctx = ClassifyCtx{
            .recovery = self,
            .txn_states = &txn_states,
            .saw_records = &saw_records,
            .max_record_lsn = &max_record_lsn,
        };
        try wal.forEachFromStrict(start_lsn, self.allocator, &self.last_failure, &classify_ctx, ClassifyCtx.visit);

        if (!saw_records) {
            // Clean recovery: no WAL records to replay.
            // GAP-ENT-0024: a V2 → V3 manifest upgrade must be durable at OPEN,
            // not merely at the next checkpoint — otherwise the window between
            // this binary's first committed v2 adjacency write and its first
            // checkpoint leaves a version-2 manifest on disk that a pre-v0.2.24
            // binary would happily open (and misparse). Persist the bump to
            // both slots now; everything else about the clean path (no counter
            // semantics change beyond the A/B freshness bump) is unchanged.
            if (upgraded_from_v2) {
                m.counter += 1;
                const upath_a = try graph_dir.manifestPath(self.allocator, .a);
                defer self.allocator.free(upath_a);
                try m.writeToFileWithKey(self.allocator, upath_a, self.encryption_key);
                const upath_b = try graph_dir.manifestPath(self.allocator, .b);
                defer self.allocator.free(upath_b);
                try m.writeToFileWithKey(self.allocator, upath_b, self.encryption_key);
            }
            return m;
        }

        // GAP-ENT-0025: per-page previous-census state for the stats-count
        // heal. Key packs (file_id, page_id); value is the live-record census
        // of the LAST image applied to that page (seeded from the pre-replay
        // on-disk page on first touch). The scratch buffer holds that one
        // on-disk read; sized from the pool because replay frames are
        // pool-sized (== pager-sized on every reachable path — SEC-0010
        // rejects a page-size mismatch right after recovery).
        var census_prev = std.AutoHashMap(u128, u64).init(self.allocator);
        defer census_prev.deinit();
        const census_scratch = try self.allocator.alloc(u8, buffer_pool.page_size);
        defer self.allocator.free(census_scratch);

        // SONNY-6473: LSN of the image last applied to each (file_id, page_id).
        // Log order is not LSN order: a GAP-0900 batch numbers its page images
        // when they are made but writes them at its txn's commit, so a txn
        // overlapping it on the same TxnManager can log a NEWER image of a page
        // before the batched txn's OLDER one. Each image is a full page taken
        // at the moment its LSN was assigned, so the highest-LSN committed
        // image is the page's latest committed state; replay applies an image
        // only when its LSN is above the one already applied to that page.
        // Logs of this shape already exist on disk (0.4.12/0.4.13), so the
        // ordering has to be enforced here, not only by the writer.
        var applied_lsn = std.AutoHashMap(u128, u64).init(self.allocator);
        defer applied_lsn.deinit();

        // 5. Replay committed page_update records into buffer pool.
        const ReplayCtx = struct {
            txn_states: *const std.AutoHashMap(u64, TxnRecoveryState),
            buffer_pool: *BufferPool,
            file_manager: *FileManager,
            recovery: *Recovery,
            /// GAP-ENT-0011: set when a committed page image is applied, so
            /// the open path knows the checkpoint-era free.store is stale.
            applied_committed_pages: *bool,
            /// GAP-ENT-0025: see above.
            census_prev: *std.AutoHashMap(u128, u64),
            census_scratch: []u8,
            /// SONNY-6473: see `applied_lsn` above.
            applied_lsn: *std.AutoHashMap(u128, u64),

            fn visit(ctx: *@This(), rec: *const WalRecord) !void {
                if (rec.record_type != .page_update) return;

                const state = ctx.txn_states.get(rec.txn_id) orelse return;
                if (state != .committed) return;
                ctx.applied_committed_pages.* = true;

                const file_id: FileId = std.enums.fromInt(FileId, rec.file_id) orelse return error.InvalidFormat;

                // Phase 3 tail reconcile: record the applied (file_id, page_id)
                // so the engine can reconcile ONLY the tail-touched pages into
                // the loaded derived-index snapshot at first-access hydration.
                ctx.recovery.recordAffectedPage(file_id, rec.page_id);

                // SONNY-6473: never let an older image overwrite a newer one.
                // Fallible on purpose: without the map replay cannot order
                // images, so an OOM fails recovery instead of losing writes.
                const key: u128 = (@as(u128, @intFromEnum(file_id)) << 64) | rec.page_id;
                const gop = try ctx.applied_lsn.getOrPut(key);
                if (gop.found_existing and gop.value_ptr.* >= rec.lsn) {
                    // Superseded. Its ids were still durably committed once,
                    // so the counter heal sees them (it must never re-issue a
                    // committed id); the stats census follows the page as it
                    // ends up and skips this image.
                    if (rec.payload.len == ctx.buffer_pool.page_size) {
                        ctx.recovery.trackReplayedIdMaxima(file_id, rec.page_id, rec.payload);
                    }
                    return;
                }
                gop.value_ptr.* = rec.lsn;

                const frame = try ctx.buffer_pool.pinNew(file_id, rec.page_id);
                const frame_idx = ctx.buffer_pool.frameIndex(frame);
                const data = frame.dataSlice();

                // SONNY-6461: the image is applied verbatim, its last 16 bytes
                // included. An image logged by graph_storage <= 0.4.11 of a
                // page it had read from an encrypted store holds AES-GCM tag
                // bytes there, but nothing in the image or the record tells
                // it from an image logged by 0.4.12+, where those bytes may be
                // a committed record (test-tde-page-tail's crash test), so the
                // tail is never zeroed here. Upgrading such a store requires a
                // clean shutdown of the old binary (docs/operations.md).
                const copy_len = @min(rec.payload.len, data.len);
                if (copy_len > 0) {
                    @memcpy(data[0..copy_len], rec.payload[0..copy_len]);
                }

                // SEC-0037: pinNew zeroes the frame and the WAL payload carries
                // the write_count as of log time, which may be LOWER than the
                // write_count already persisted to the on-disk page by a flush
                // that happened after the record was logged (then crashed). A
                // later flush would otherwise reuse a nonce already used on disk
                // with different plaintext. Seed the replayed frame's write_count
                // to max(on-disk, logged) so the AES-GCM nonce counter never
                // regresses. write_count stays plaintext in the header, so it can
                // be read from the raw on-disk bytes without decrypting.
                if (copy_len >= page_mod.WRITE_COUNT_OFFSET + 3) {
                    if (ctx.file_manager.getPager(file_id)) |pager_ptr| {
                        const on_disk_wc = pager_ptr.readWriteCountOnDisk(rec.page_id) catch 0;
                        const logged_wc = page_mod.readWriteCount(data);
                        page_mod.writeWriteCount(data, @max(on_disk_wc, logged_wc));
                    }
                }

                // Counter healing: harvest the id maxima from the image just
                // applied while it is pinned anyway (O(replayed bytes)).
                ctx.recovery.trackReplayedIdMaxima(file_id, rec.page_id, data);

                // GAP-ENT-0025: stats-count healing — census the applied
                // image against the page's previous state (O(replayed bytes)
                // plus one pread per DISTINCT replayed page). Infallible:
                // the count heal must never turn a replayable WAL into a
                // failed recovery.
                ctx.recovery.trackReplayedCountDeltas(
                    ctx.census_prev,
                    ctx.file_manager,
                    ctx.census_scratch,
                    file_id,
                    rec.page_id,
                    data,
                );

                ctx.buffer_pool.unpin(frame_idx, true);
            }
        };

        var replay_ctx = ReplayCtx{
            .txn_states = &txn_states,
            .buffer_pool = buffer_pool,
            .file_manager = file_manager,
            .recovery = self,
            .applied_committed_pages = &self.applied_committed_pages,
            .census_prev = &census_prev,
            .census_scratch = census_scratch,
            .applied_lsn = &applied_lsn,
        };
        try wal.forEachFromStrict(start_lsn, self.allocator, &self.last_failure, &replay_ctx, ReplayCtx.visit);

        // 7. Flush buffer pool to disk
        try buffer_pool.flushAll();

        // 8. Write fresh checkpoint
        try file_manager.syncAll();

        // GAP-ENT-0011 (review F-1): when committed tail images were applied,
        // the persisted checkpoint-era free.store is STALE with respect to the
        // pages just replayed. The open path rebuilds + re-persists it (step
        // 5b), but that happens AFTER this function returns — and this function
        // is about to persist the ADVANCED last_checkpoint_lsn to both
        // manifests. A crash (or an error-abort + retry of open) between the
        // manifest write and step 5b would leave: advanced LSN + stale bitmap
        // → the NEXT open sees an empty WAL tail, takes the clean path, and
        // silently trusts the stale file (double allocation of live pages).
        //
        // Make an EMPTY free.store the crash-safe signal: truncate it to zero
        // (+ fsync so the truncate is durable) BEFORE the advanced manifests
        // land. loadFreeStore already treats a zero-length file as "no
        // persisted bitmap" (returns false → rebuild fallback), so any
        // crash/error anywhere in the rest of open leaves the stale bitmap
        // GONE and the next open rebuilds. Truncate rather than unlink:
        // free.store doubles as the registered `.free` store file, which this
        // very function (and the next open) opens with `open_existing` — the
        // file must keep existing. Correctness no longer depends on step 5b
        // completing; `applied_committed_pages` stays as the fast-path signal
        // for the current open. ftruncate is atomic: a crash mid-way leaves
        // either the old content (WAL tail unchanged → recovery repeats and
        // truncates again) or the empty file (rebuild), never a torn bitmap.
        if (self.applied_committed_pages) {
            const free_store_path = try std.fmt.allocPrint(self.allocator, "{s}/free.store", .{graph_dir.path});
            defer self.allocator.free(free_store_path);
            const free_file = try std.Io.Dir.cwd().openFile(io, free_store_path, .{ .mode = .read_write });
            defer free_file.close(io);
            try free_file.setLength(io, 0);
            try free_file.sync(io);
        }

        // Counter healing: re-derive the manifest id counters from the ids
        // actually observed in the replayed committed images (+ the WAL
        // tail's txn-id watermark) so records replayed from the tail are
        // scan-visible and their slots are NEVER re-issued. This MUST happen
        // before the advanced-LSN manifest writes below: they are the same
        // atomic A/B write, so a crash anywhere either repeats replay (old
        // manifest, old LSN) or lands healed counters together with the
        // advanced LSN — "advanced LSN + stale counters" is unrepresentable.
        //
        // `max + stride` (not `max + 1`) keeps sharded id residues intact;
        // every id observed in this shard's stores carries the shard's
        // residue, so the healed counter stays in the shard's id class.
        // Over-shoot is impossible: every observed id was durably allocated.
        if (self.max_replayed_node_id != 0 and m.next_node_id <= self.max_replayed_node_id) {
            m.next_node_id = self.max_replayed_node_id + self.id_stride;
        }
        if (self.max_replayed_edge_id != 0 and m.next_edge_id <= self.max_replayed_edge_id) {
            m.next_edge_id = self.max_replayed_edge_id + self.id_stride;
        }
        // Txn ids advance by 1 regardless of sharding (TxnManager.begin).
        if (self.max_seen_txn_id != 0 and m.next_txn_id <= self.max_seen_txn_id) {
            m.next_txn_id = self.max_seen_txn_id + 1;
        }

        // GAP-ENT-0025: stats-count healing — fold the live-record deltas
        // observed across the applied committed images into the checkpoint-era
        // counts, in the SAME atomic A/B manifest write as the id counters and
        // the advanced LSN ("advanced LSN + stale counts" is unrepresentable,
        // and the double-crash case reads the healed values back for free).
        // Saturating arithmetic: a (defensive, should-be-impossible) negative
        // overshoot clamps at 0 instead of wrapping — these are stats, never
        // slot/scan inputs, so clamping is safe and wrapping never is.
        //
        // PRECISION — exact in the common case, honest about three gaps:
        //  * EXACT when every replayed page's pre-replay on-disk content is
        //    its checkpoint-era content or the page is new (the checkpoint
        //    flushed everything, so this holds unless the crashed run wrote
        //    the page to disk again AFTER the checkpoint).
        //  * UNDER-counts records that a post-checkpoint dirty-page EVICTION
        //    (or a checkpoint that crashed between flush and manifest write)
        //    already flushed to disk: the before-census sees them, the
        //    checkpoint-era count does not.
        //  * OVER-counts when the before-read of a torn/unreadable on-disk
        //    page falls back to census 0 (the checkpoint-era live records of
        //    that page are counted twice), and UNDER-counts checkpoint-era
        //    stale content of a freed-then-reused adjacency page.
        // Node counts census non-empty, non-DELETED slots; edge counts census
        // `.adj_out` out-entries only (every edge has exactly one; `.adj_in` /
        // `.in_idx` in-entries would double-count and legacy `.adj_in` images
        // can carry foreign shards' edges). Unlike the id heal there is NO
        // residue filter: the counts describe THIS shard's store contents
        // (what getStorageStats scans), not the id allocator's class.
        if (self.replayed_node_delta >= 0) {
            m.node_count +|= @abs(self.replayed_node_delta);
        } else {
            m.node_count -|= @abs(self.replayed_node_delta);
        }
        if (self.replayed_edge_delta >= 0) {
            m.edge_count +|= @abs(self.replayed_edge_delta);
        } else {
            m.edge_count -|= @abs(self.replayed_edge_delta);
        }

        m.counter += 1;
        // Everything replayed above is flushed and synced, so the frontier
        // advances past every record seen under either numbering. The engine's
        // WalManager then anchors the inner log at this value (SONNY-6424).
        m.last_checkpoint_lsn = @max(wal.currentLsn(), max_record_lsn);

        // Write to both slots for a clean state after recovery
        const manifest_path_a = try graph_dir.manifestPath(self.allocator, .a);
        defer self.allocator.free(manifest_path_a);
        try m.writeToFileWithKey(self.allocator, manifest_path_a, self.encryption_key);

        const manifest_path_b = try graph_dir.manifestPath(self.allocator, .b);
        defer self.allocator.free(manifest_path_b);
        try m.writeToFileWithKey(self.allocator, manifest_path_b, self.encryption_key);

        return m;
    }

    /// Counter healing: extract the maximum node id / edge id present in a
    /// committed page image being applied by replay.
    ///
    /// * `.nodes` pages are fixed 48-byte NodeRec slots; a non-empty slot at
    ///   (page, slot) IS the allocation of node id `page * npp + slot`
    ///   (deleted-but-flagged records still count — their id was issued).
    /// * `.adj_out` / `.adj_in` / `.in_idx` pages are adjacency edge blocks;
    ///   every entry carries the internal edge id inline. Every edge has an
    ///   out-entry, so `.adj_out` alone covers all post-checkpoint edges —
    ///   the in-side blocks are harvested too because it is free and guards
    ///   any future write path that images only the in-side. BOTH adjacency
    ///   shapes are parsed: legacy v1/v2 block-chain blocks (entries at the
    ///   block's own stride) AND slab blocks (GAP adjacency slab packing —
    ///   `entry_format == ENTRY_FORMAT_SLAB`, many chains' v2-entry runs
    ///   behind a backward-growing slot directory). Slab runs MUST be
    ///   harvested: ids living only in a replayed slab image would otherwise
    ///   escape the counter heal and be re-issued (the exact staleness class
    ///   this heal closes).
    ///
    /// Defensive on shape: an image that does not parse as a valid block
    /// contributes nothing (the maxima are a lower-bound harvest; replay
    /// itself never validated payload shape and this pass must not turn a
    /// previously replayable WAL into a failed recovery). For slab images
    /// that is per-SLOT: a malformed slot is skipped, well-formed siblings
    /// still contribute.
    fn trackReplayedIdMaxima(self: *Recovery, file_id: FileId, page_id: u64, data: []const u8) void {
        switch (file_id) {
            .nodes => {
                if (data.len <= node_mod.PAGE_HEADER_SIZE) return;
                const npp: u64 = node_mod.nodesPerPage(@intCast(data.len));
                const body = data[node_mod.PAGE_HEADER_SIZE..];
                var slot: u64 = 0;
                while (slot < npp) : (slot += 1) {
                    const off: usize = @intCast(slot * @sizeOf(node_mod.NodeRec));
                    const rec = std.mem.bytesToValue(node_mod.NodeRec, body[off..][0..@sizeOf(node_mod.NodeRec)]);
                    if (node_mod.isEmpty(&rec)) continue;
                    const node_id = page_id * npp + slot;
                    // Residue guard (I1): never harvest an id outside this
                    // shard's residue class — see `shard_residue`.
                    if (node_id % self.id_stride != self.shard_residue) continue;
                    if (node_id > self.max_replayed_node_id) {
                        self.max_replayed_node_id = node_id;
                    }
                }
            },
            .adj_out, .adj_in, .in_idx => {
                const hdr_off = page_mod.PAGE_HEADER_SIZE;
                const bh_size = @sizeOf(edge_mod.EdgeBlockHeader);
                if (data.len < hdr_off + bh_size) return;
                const bh = std.mem.bytesToValue(edge_mod.EdgeBlockHeader, data[hdr_off..][0..bh_size]);
                // GAP-0060: slab-v2 AND slab-v3 blocks route to the slab harvest.
                if (bh.entry_format == edge_mod.ENTRY_FORMAT_SLAB or
                    bh.entry_format == edge_mod.ENTRY_FORMAT_SLAB_V3)
                {
                    self.harvestSlabAdjImage(data, bh);
                    return;
                }
                // Chain harvest handles v1/v2/v3; any other byte is not a chain
                // layout we understand — skip (never misparse at a guessed stride).
                if (bh.entry_format != edge_mod.ENTRY_FORMAT_V1 and
                    bh.entry_format != edge_mod.ENTRY_FORMAT_V2 and
                    bh.entry_format != edge_mod.ENTRY_FORMAT_V3) return;
                const cap = edge_mod.entriesPerBlock(@intCast(data.len), bh.entry_format);
                if (bh.count > cap) return;
                const esz = edge_mod.entrySize(bh.entry_format);
                const entries = data[hdr_off + bh_size ..];
                var i: u32 = 0;
                while (i < bh.count) : (i += 1) {
                    // edge_id is at byte offset 8 of v1/v2/v3 entries.
                    const off: usize = @intCast(i * esz + 8);
                    const edge_id = std.mem.readInt(u64, entries[off..][0..8], .little);
                    // Residue guard (I1): legacy pre-co-location `.adj_in`
                    // images can carry SOURCE-shard (foreign-residue) edge
                    // ids — healing from one permanently misroutes getEdge.
                    // See `shard_residue`.
                    if (edge_id % self.id_stride != self.shard_residue) continue;
                    if (edge_id > self.max_replayed_edge_id) {
                        self.max_replayed_edge_id = edge_id;
                    }
                }
            },
            else => {},
        }
    }

    /// GAP-ENT-0025: stats-count healing — accumulate the net live-record
    /// delta contributed by one applied committed page image.
    ///
    /// Only `.nodes` (node count) and `.adj_out` (edge count — every edge has
    /// exactly one out-entry) pages participate; in-side files are excluded
    /// (double-count, and legacy `.adj_in` images can carry foreign shards'
    /// edges, which are counted by their source shard's own images).
    ///
    /// Per page the diffs telescope: the first image is censused against the
    /// pre-replay ON-DISK page (checkpoint-era in the common case — see the
    /// precision note at the heal site in `recover`), later images against
    /// the previous image, so the page's total contribution is exactly
    /// final-applied-census minus pre-replay-census.
    ///
    /// INFALLIBLE by contract: a failed map insert (OOM), unreadable on-disk
    /// before-image, or unparseable image degrades the estimate (documented)
    /// but must never turn a previously replayable WAL into a failed
    /// recovery — same discipline as `trackReplayedIdMaxima`.
    fn trackReplayedCountDeltas(
        self: *Recovery,
        census_prev: *std.AutoHashMap(u128, u64),
        file_manager: *FileManager,
        scratch: []u8,
        file_id: FileId,
        page_id: u64,
        data: []const u8,
    ) void {
        switch (file_id) {
            .nodes, .adj_out => {},
            else => return,
        }
        const key: u128 = (@as(u128, @intFromEnum(file_id)) << 64) | page_id;
        const gop = census_prev.getOrPut(key) catch return; // OOM: best-effort stats, skip.
        if (!gop.found_existing) {
            // First tail image of this page: seed from the pre-replay on-disk
            // page. Any read failure (page beyond EOF = allocated after the
            // checkpoint, torn page, hostile id) counts as an empty page.
            gop.value_ptr.* = blk: {
                const pager_ptr = file_manager.getPager(file_id) orelse break :blk 0;
                if (scratch.len != pager_ptr.page_size) break :blk 0; // defensive
                pager_ptr.readPage(page_id, scratch) catch break :blk 0;
                break :blk self.liveRecordCensus(file_id, scratch);
            };
        }
        const new_census = self.liveRecordCensus(file_id, data);
        const delta = @as(i64, @intCast(new_census)) - @as(i64, @intCast(gop.value_ptr.*));
        switch (file_id) {
            .nodes => self.replayed_node_delta += delta,
            .adj_out => self.replayed_edge_delta += delta,
            else => unreachable,
        }
        gop.value_ptr.* = new_census;
    }

    /// Count the LIVE records in a `.nodes` or `.adj_out` page image.
    /// Defensive on shape (mirrors `trackReplayedIdMaxima`): an image that
    /// does not parse as a valid page contributes zero.
    ///
    /// Handles BOTH adjacency shapes, exactly like the id harvest: legacy
    /// v1/v2 chain blocks (`count` IS the census — swap-compaction keeps
    /// them dense) AND slab blocks (`censusSlabAdjImage`). `self` is read
    /// only for the slab tail rule (`encryption_key`), never mutated.
    fn liveRecordCensus(self: *const Recovery, file_id: FileId, data: []const u8) u64 {
        switch (file_id) {
            .nodes => {
                if (data.len <= node_mod.PAGE_HEADER_SIZE) return 0;
                const npp: u64 = node_mod.nodesPerPage(@intCast(data.len));
                const body = data[node_mod.PAGE_HEADER_SIZE..];
                var live: u64 = 0;
                var slot: u64 = 0;
                while (slot < npp) : (slot += 1) {
                    const off: usize = @intCast(slot * @sizeOf(node_mod.NodeRec));
                    const rec = std.mem.bytesToValue(node_mod.NodeRec, body[off..][0..@sizeOf(node_mod.NodeRec)]);
                    // Unlike the id harvest, a DELETED-flagged slot is NOT
                    // live: its id was issued but the node is gone.
                    if (node_mod.isEmpty(&rec)) continue;
                    if (node_mod.isDeleted(&rec)) continue;
                    live += 1;
                }
                return live;
            },
            .adj_out => {
                const hdr_off = page_mod.PAGE_HEADER_SIZE;
                const bh_size = @sizeOf(edge_mod.EdgeBlockHeader);
                if (data.len < hdr_off + bh_size) return 0;
                const bh = std.mem.bytesToValue(edge_mod.EdgeBlockHeader, data[hdr_off..][0..bh_size]);
                if (bh.entry_format == edge_mod.ENTRY_FORMAT_SLAB or
                    bh.entry_format == edge_mod.ENTRY_FORMAT_SLAB_V3)
                {
                    // 0025 count heal × adjacency slab packing: slab out-runs
                    // ARE this page's out-entries, so the census counts them
                    // — through the SAME parse the id harvest uses (see
                    // `censusSlabAdjImage`). If slab images censused 0, every
                    // post-slab crash replay would diff 0-minus-before and
                    // walk the healed edge_count BACKWARD. GAP-0060: slab-v2 and
                    // slab-v3 both route here.
                    return self.censusSlabAdjImage(data, bh);
                }
                if (bh.entry_format != edge_mod.ENTRY_FORMAT_V1 and
                    bh.entry_format != edge_mod.ENTRY_FORMAT_V2 and
                    bh.entry_format != edge_mod.ENTRY_FORMAT_V3) return 0;
                const cap = edge_mod.entriesPerBlock(@intCast(data.len), bh.entry_format);
                if (bh.count > cap) return 0;
                // Entry removal swap-compacts the block (AdjStore.removeEdge),
                // so `count` IS the live out-entry census — no tombstones.
                return bh.count;
            },
            else => return 0,
        }
    }

    /// 0025 stats-count healing × adjacency slab packing: census the live
    /// out-entries of a SLAB adjacency image — the sum of `entry_count`
    /// across the LIVE, bounds-valid slots of the slot directory.
    ///
    /// Validation is deliberately IDENTICAL, guard for guard, to
    /// `harvestSlabAdjImage` (keep the two in lockstep): unchained header,
    /// directory in bounds under the same tail rule, per-slot tombstone and
    /// bounds defensiveness — a malformed slot contributes zero without
    /// aborting its well-formed siblings. The run entries themselves need no
    /// inspection: slab removal compacts the run (mirroring the chain
    /// blocks' swap-compaction), so a live slot's `entry_count` IS its live
    /// census — and unlike the id harvest there is NO residue filter (the
    /// census counts THIS shard's store contents, not id-allocator classes;
    /// see the heal-site comment in `recover`).
    fn censusSlabAdjImage(self: *const Recovery, data: []const u8, bh: edge_mod.EdgeBlockHeader) u64 {
        if (bh.next_block != 0) return 0;
        const tail_reserve: u32 = if (self.encryption_key != null) encryption_mod.TAG_SIZE else 0;
        const dir_bytes = @as(u64, bh.count) * edge_mod.SLAB_DIR_ENTRY_SIZE;
        if (edge_mod.SLAB_RUNS_OFFSET + dir_bytes + tail_reserve > data.len) return 0;
        const dir_start = edge_mod.slabDirStart(data.len, tail_reserve, bh.count);

        // GAP-0060: stride at the block's own width (slab-v2 32B or slab-v3 40B).
        const stride = edge_mod.slabEntrySize(bh.entry_format);
        var live: u64 = 0;
        var s: u32 = 0;
        while (s < bh.count) : (s += 1) {
            const slot = edge_mod.readSlabSlot(data, tail_reserve, s);
            if (slot.offset == edge_mod.SLAB_SLOT_TOMBSTONE) continue;
            if (slot.offset < edge_mod.SLAB_RUNS_OFFSET) continue;
            const run_end = @as(u64, slot.offset) + @as(u64, slot.entry_count) * stride;
            if (run_end > dir_start) continue;
            live += slot.entry_count;
        }
        return live;
    }

    /// Harvest edge-id maxima from a SLAB adjacency image (GAP adjacency slab
    /// packing): iterate the slot directory, and for every LIVE, bounds-valid
    /// slot walk its contiguous run at the block's stride (slab-v2 32 B or
    /// GAP-0060 slab-v3 40 B). Defensive per slot:
    /// tombstoned, truncated, or out-of-bounds slots contribute nothing and
    /// never abort the harvest of well-formed siblings. The layout (incl. the
    /// AES-GCM tail reservation mirrored from the slab writer) lives in
    /// edge.zig's SLAB section.
    fn harvestSlabAdjImage(self: *Recovery, data: []const u8, bh: edge_mod.EdgeBlockHeader) void {
        // Slab blocks are never chained; a nonzero next_block is not a slab
        // block we understand — contribute nothing.
        if (bh.next_block != 0) return;
        // Same tail rule as the slab writer: the slot directory grows
        // backward from (page end - tag reserve) when at-rest encryption is
        // configured (WAL payloads are plaintext frames, but the LAYOUT
        // reserves the tail whenever a key is configured).
        const tail_reserve: u32 = if (self.encryption_key != null) encryption_mod.TAG_SIZE else 0;
        const dir_bytes = @as(u64, bh.count) * edge_mod.SLAB_DIR_ENTRY_SIZE;
        if (edge_mod.SLAB_RUNS_OFFSET + dir_bytes + tail_reserve > data.len) return;
        const dir_start = edge_mod.slabDirStart(data.len, tail_reserve, bh.count);
        // GAP-0060: stride at the block's own width (slab-v2 32B or slab-v3 40B).
        const stride = edge_mod.slabEntrySize(bh.entry_format);

        var s: u32 = 0;
        while (s < bh.count) : (s += 1) {
            const slot = edge_mod.readSlabSlot(data, tail_reserve, s);
            if (slot.offset == edge_mod.SLAB_SLOT_TOMBSTONE) continue;
            if (slot.offset < edge_mod.SLAB_RUNS_OFFSET) continue;
            const run_end = @as(u64, slot.offset) + @as(u64, slot.entry_count) * stride;
            if (run_end > dir_start) continue;

            var i: u32 = 0;
            while (i < slot.entry_count) : (i += 1) {
                // edge_id is at byte offset 8 of every v2/v3 run entry.
                const off: usize = @intCast(@as(u64, slot.offset) + @as(u64, i) * stride + 8);
                const edge_id = std.mem.readInt(u64, data[off..][0..8], .little);
                // Residue guard (I1): same rule as the block-chain harvest.
                if (edge_id % self.id_stride != self.shard_residue) continue;
                if (edge_id > self.max_replayed_edge_id) {
                    self.max_replayed_edge_id = edge_id;
                }
            }
        }
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;
const pager_module = @import("pager.zig");
const Pager = pager_module.Pager;

fn setupTestGraph(allocator: Allocator) !struct {
    tmp_dir: testing.TmpDir,
    graph_dir: GraphDir,
} {
    var tmp_dir = testing.tmpDir(.{});
    const dir_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(dir_path);

    const uuid = [_]u8{0xBB} ** 16;
    const gd = try GraphDir.create(allocator, dir_path, uuid);

    // Create WAL directory
    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{gd.path});
    defer allocator.free(wal_dir_path);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), wal_dir_path);

    return .{
        .tmp_dir = tmp_dir,
        .graph_dir = gd,
    };
}

test "clean recovery: no WAL records, manifest loaded correctly" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write an initial manifest to slot A
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .next_node_id = 10,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    // Run recovery
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 16);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    const recovered = try recovery.recover(&setup.graph_dir, &pool, &fm);

    // Manifest should match what was written (clean recovery doesn't increment counter
    // because there are no records to replay)
    try testing.expectEqual(@as(u64, 10), recovered.next_node_id);
    try testing.expectEqual([_]u8{0xBB} ** 16, recovered.graph_uuid);
}

test "GAP-0032: recovery rejects manifests whose graph UUID mismatches the graph directory" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    const initial = Manifest{
        .graph_uuid = [_]u8{0xAA} ** 16,
        .page_size = 4096,
        .counter = 1,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 16);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    try testing.expectError(error.UuidMismatch, recovery.recover(&setup.graph_dir, &pool, &fm));
}

test "recovery with committed transaction: changes visible after recovery" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write initial manifest
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    // Write WAL records simulating a committed transaction
    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{});

    // BEGIN txn 1
    var begin_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .begin_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&begin_rec);

    // PAGE_UPDATE for txn 1 (write some data to nodes file, page 1)
    var page_data: [4096]u8 = undefined;
    @memset(&page_data, 0xAB); // recognizable pattern
    var update_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .page_update,
        .file_id = 0, // nodes
        .page_id = 1,
        .payload = &page_data,
        .checksum = 0,
    };
    _ = try wal.appendRecord(&update_rec);

    // COMMIT txn 1
    var commit_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .commit_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&commit_rec);

    try wal.sync();
    wal.deinit();

    // Now run recovery
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 32);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    const recovered = try recovery.recover(&setup.graph_dir, &pool, &fm);

    // The recovered manifest should have a bumped counter
    try testing.expectEqual(@as(u64, 2), recovered.counter);

    // Verify the committed page data was applied: read the page from disk
    const pager_ptr = fm.getPager(.nodes).?;
    var read_buf: [4096]u8 = undefined;
    pager_ptr.readPage(1, &read_buf) catch {
        // Page might not exist on disk yet if flush didn't extend file
        // This is acceptable for the test
        return;
    };

    // Check if data was written (the page should have our 0xAB pattern)
    // The buffer pool flush may have computed checksums, so check body area
    var all_match = true;
    for (read_buf[page_mod.PAGE_HEADER_SIZE..]) |byte| {
        if (byte != 0xAB) {
            all_match = false;
            break;
        }
    }
    // The data should match since we wrote the full page
    try testing.expect(all_match);
}

test "Phase 3 Task 3.1: replay records the tail-affected (file_id,page_id) set" {
    // A committed 3-page tail → recovery's affected-page set == exactly those
    // 3 pages (dedup, bounded by the tail). The engine copies this at OPEN and
    // reconciles only these pages into the loaded derived-index snapshot at
    // first access, instead of an O(graph) rebuild.
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{});

    var begin_rec = WalRecord{ .lsn = 0, .txn_id = 3, .record_type = .begin_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&begin_rec);

    var page_data: [4096]u8 = undefined;
    @memset(&page_data, 0xAB);
    // Three distinct pages on the nodes file: 1, 2, 3. Page 2 is written TWICE
    // to prove dedup (the affected set counts distinct pages, not records).
    const page_ids = [_]u64{ 1, 2, 2, 3 };
    for (page_ids) |pid| {
        var update_rec = WalRecord{ .lsn = 0, .txn_id = 3, .record_type = .page_update, .file_id = @intFromEnum(FileId.nodes), .page_id = pid, .payload = &page_data, .checksum = 0 };
        _ = try wal.appendRecord(&update_rec);
    }

    var commit_rec = WalRecord{ .lsn = 0, .txn_id = 3, .record_type = .commit_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&commit_rec);
    try wal.sync();
    wal.deinit();

    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();
    var pool = try BufferPool.init(allocator, 4096, 32);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    defer recovery.deinit();
    recovery.capture_affected_pages = true;
    _ = try recovery.recover(&setup.graph_dir, &pool, &fm);

    // Exactly 3 DISTINCT pages, all on the nodes file, no overflow.
    try testing.expect(!recovery.affected_pages_overflow);
    try testing.expectEqual(@as(usize, 3), recovery.affectedPageCount());
    try testing.expect(recovery.hasAffectedPage(.nodes, 1));
    try testing.expect(recovery.hasAffectedPage(.nodes, 2));
    try testing.expect(recovery.hasAffectedPage(.nodes, 3));
    // A page NOT in the tail is absent.
    try testing.expect(!recovery.hasAffectedPage(.nodes, 4));
    try testing.expect(!recovery.hasAffectedPage(.props, 1));
}

test "GAP-0030: recovery replays a large committed WAL tail" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{});
    defer wal.deinit();

    var begin_rec = WalRecord{
        .lsn = 0,
        .txn_id = 7,
        .record_type = .begin_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&begin_rec);

    var payload: [4096]u8 = undefined;
    for (0..payload.len) |i| payload[i] = @intCast(i % 251);

    var page_id: u64 = 1;
    while (page_id <= 512) : (page_id += 1) {
        var update_rec = WalRecord{
            .lsn = 0,
            .txn_id = 7,
            .record_type = .page_update,
            .file_id = @intFromEnum(FileId.nodes),
            .page_id = page_id,
            .payload = &payload,
            .checksum = 0,
        };
        _ = try wal.appendRecord(&update_rec);
    }

    var commit_rec = WalRecord{
        .lsn = 0,
        .txn_id = 7,
        .record_type = .commit_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&commit_rec);
    try wal.sync();

    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 64);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    const recovered = try recovery.recover(&setup.graph_dir, &pool, &fm);

    try testing.expect(recovered.counter > initial.counter);
    try testing.expect(recovery.last_failure == null);
}

test "recovery with uncommitted transaction: changes discarded" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write initial manifest
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    // Write WAL records: uncommitted transaction (no COMMIT)
    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{});

    // BEGIN txn 1
    var begin_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .begin_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&begin_rec);

    // PAGE_UPDATE for txn 1 (uncommitted)
    var page_data: [4096]u8 = undefined;
    @memset(&page_data, 0xCD);
    var update_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .page_update,
        .file_id = 0, // nodes
        .page_id = 2,
        .payload = &page_data,
        .checksum = 0,
    };
    _ = try wal.appendRecord(&update_rec);

    // No COMMIT - transaction is uncommitted
    try wal.sync();
    wal.deinit();

    // Run recovery
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 32);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    const recovered = try recovery.recover(&setup.graph_dir, &pool, &fm);
    _ = recovered;

    // The uncommitted page should NOT have been written to disk.
    // Page 2 in the nodes file should either not exist or be all zeros.
    const pager_ptr = fm.getPager(.nodes).?;
    var read_buf: [4096]u8 = undefined;
    pager_ptr.readPage(2, &read_buf) catch {
        // Page doesn't exist on disk - uncommitted data was correctly discarded
        return;
    };

    // If the page exists, verify it's NOT our uncommitted 0xCD pattern
    var has_uncommitted_data = true;
    for (read_buf[page_mod.PAGE_HEADER_SIZE..]) |byte| {
        if (byte != 0xCD) {
            has_uncommitted_data = false;
            break;
        }
    }
    try testing.expect(!has_uncommitted_data);
}

test "recovery rejects WAL records with corrupted checksums" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write initial manifest
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    // Open WAL directory and create WAL
    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{});

    // BEGIN txn 1 (correct checksum, via appendRecord)
    var begin_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .begin_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&begin_rec);

    // PAGE_UPDATE with intentionally WRONG checksum.
    // Write raw serialized bytes directly to the inner WAL to bypass
    // appendRecord's automatic checksum computation.
    var page_data: [4096]u8 = undefined;
    @memset(&page_data, 0xEE);
    var bad_update = WalRecord{
        .lsn = 2,
        .txn_id = 1,
        .record_type = .page_update,
        .file_id = 0,
        .page_id = 1,
        .payload = &page_data,
        .checksum = 0,
    };
    const bad_bytes = try bad_update.serialize(allocator);
    defer allocator.free(bad_bytes);
    // Corrupt the checksum in the serialized bytes (last 4 bytes)
    @memcpy(bad_bytes[bad_bytes.len - 4 ..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, 0xDEADBEEF))));
    _ = try wal.inner.append(bad_bytes);
    wal.current_lsn = 2;

    // COMMIT txn 1 (correct checksum, via appendRecord)
    var commit_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .commit_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&commit_rec);

    try wal.sync();
    wal.deinit();

    // Run recovery
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 32);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    const result = recovery.recover(&setup.graph_dir, &pool, &fm);
    try testing.expectError(error.ChecksumMismatch, result);
    try testing.expect(recovery.last_failure != null);
    try testing.expectEqual(@as(u64, 2), recovery.last_failure.?.lsn);
    try testing.expectEqual(wal_mod.ReplayFailureKind.checksum_mismatch, recovery.last_failure.?.kind);
}

test "recovery rejects manifest with incompatible format_version" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write a manifest with a future/incompatible format_version
    var bad_manifest = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    bad_manifest.format_version = 999; // incompatible version

    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try bad_manifest.writeToFile(allocator, path_a);

    // Run recovery -- should fail with IncompatibleVersion
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 16);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    const result = recovery.recover(&setup.graph_dir, &pool, &fm);
    try testing.expectError(error.IncompatibleVersion, result);
}

test "GAP-ENT-0024 F1: version-2 manifest opens fine and is upgraded to version 3 on disk" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // A store exactly as v0.2.23 left it: format_version 2.
    var v2_manifest = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .next_node_id = 42,
    };
    v2_manifest.format_version = manifest_mod.MANIFEST_VERSION_V2;
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try v2_manifest.writeToFile(allocator, path_a);

    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();
    var pool = try BufferPool.init(allocator, 4096, 16);
    defer pool.deinit();

    // Opens WITHOUT error (accept-and-upgrade, not reject) and every other
    // manifest field survives the upgrade untouched.
    var recovery = Recovery.init(allocator, null);
    const recovered = try recovery.recover(&setup.graph_dir, &pool, &fm);
    try testing.expectEqual(manifest_mod.MANIFEST_VERSION, recovered.format_version);
    try testing.expectEqual(@as(u64, 42), recovered.next_node_id);
    try testing.expect(!recovery.read_only);

    // The upgrade must be durable at OPEN (clean path included): BOTH slots on
    // disk now carry version 3, so a pre-v0.2.24 binary refuses this store.
    const on_disk_a = (try Manifest.readFromFile(allocator, path_a)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(manifest_mod.MANIFEST_VERSION, on_disk_a.format_version);
    const path_b = try setup.graph_dir.manifestPath(allocator, .b);
    defer allocator.free(path_b);
    const on_disk_b = (try Manifest.readFromFile(allocator, path_b)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(manifest_mod.MANIFEST_VERSION, on_disk_b.format_version);
    // And the A/B counter moved forward so the upgraded slots win selection.
    try testing.expect(on_disk_a.counter > v2_manifest.counter);
}

test "downgrade gate: recovery rejects a v3-format manifest (v4 required)" {
    // The checkpoint_epoch field bumped MANIFEST_VERSION 3 -> 4. A store whose
    // manifest still declares format_version 3 (a pre-v0.2.29 binary's output)
    // is NOT a v4 store and must be refused at the version gate — the same
    // read-only-or-IncompatibleVersion policy the v2/v1 branches use.
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    var v3_manifest = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    v3_manifest.format_version = manifest_mod.MANIFEST_VERSION_V3;

    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try v3_manifest.writeToFile(allocator, path_a);

    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();
    var pool = try BufferPool.init(allocator, 4096, 16);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    const result = recovery.recover(&setup.graph_dir, &pool, &fm);
    try testing.expectError(error.IncompatibleVersion, result);
}

test "GAP-0053 v3-upgrade integration: a real 176-byte V3 store opens and migrates to V4 on checkpoint" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // A store EXACTLY as a pre-v0.2.29 (V3) binary left it: a 176-byte manifest
    // with no checkpoint_epoch. graph_uuid MUST match the graph dir or recovery
    // rejects it with UuidMismatch before the version gate is reached.
    var v3 = Manifest{
        .graph_uuid = setup.graph_dir.graph_uuid,
        .page_size = 4096,
        .counter = 5,
        .next_node_id = 4242,
        .node_count = 77,
    };
    v3.format_version = manifest_mod.MANIFEST_VERSION_V3;

    // Write the RAW V3 bytes (writeToFile would emit the 184-byte V4 layout —
    // we need the real on-disk V3 format the old binary produced).
    const v3_bytes = try manifest_mod.serializeV3Legacy(allocator, v3, null);
    defer allocator.free(v3_bytes);
    try testing.expectEqual(@as(usize, 176), v3_bytes.len);

    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    {
        const io = std.Io.Threaded.global_single_threaded.io();
        const f = try std.Io.Dir.cwd().createFile(io, path_a, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, v3_bytes);
        try f.sync(io);
        try testing.expectEqual(@as(u64, 176), try f.length(io));
    }

    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();
    var pool = try BufferPool.init(allocator, 4096, 16);
    defer pool.deinit();

    // 1) The graph OPENS (the brick is fixed) and the V3 manifest is upgraded:
    //    version bumped to V4, every field preserved, checkpoint_epoch = 0.
    var recovery = Recovery.init(allocator, null);
    var recovered = try recovery.recover(&setup.graph_dir, &pool, &fm);
    try testing.expectEqual(manifest_mod.MANIFEST_VERSION, recovered.format_version);
    try testing.expectEqual(@as(u64, 4242), recovered.next_node_id);
    try testing.expectEqual(@as(u64, 77), recovered.node_count);
    try testing.expectEqual(@as(u64, 0), recovered.checkpoint_epoch);

    // 2) A checkpoint MIGRATES the store to V4 on disk. Drive TWO checkpoints so
    //    BOTH A/B slots flip (each checkpoint writes the alternate slot).
    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());
    var wal = try WalManager.init(allocator, wal_dir, setup.graph_dir.graph_uuid, 0, .{});
    defer wal.deinit();

    var cp = Checkpointer.init(allocator, &pool, &wal, &recovered, &fm, &setup.graph_dir);
    try cp.doCheckpoint(); // writes slot .b as V4 (last_slot starts at .a)
    try cp.doCheckpoint(); // writes slot .a as V4

    // BOTH slots are now valid 184-byte V4 manifests with the fields preserved.
    for ([_]GraphDir.ManifestSlot{ .a, .b }) |slot| {
        const p = try setup.graph_dir.manifestPath(allocator, slot);
        defer allocator.free(p);
        const io = std.Io.Threaded.global_single_threaded.io();
        const f = try std.Io.Dir.cwd().openFile(io, p, .{});
        defer f.close(io);
        try testing.expectEqual(@as(u64, 184), try f.length(io));
        const on_disk = (try Manifest.readFromFile(allocator, p)) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(manifest_mod.MANIFEST_VERSION, on_disk.format_version);
        try testing.expectEqual(@as(u64, 4242), on_disk.next_node_id);
    }
    // Epoch advanced 0 -> 1 -> 2 across the two checkpoints (never false-matches
    // a pre-upgrade derived snapshot, which had no epoch stamp at all).
    try testing.expectEqual(@as(u64, 2), recovered.checkpoint_epoch);
}

test "GAP-ENT-0024 F1: freshly written manifests carry version 4" {
    const allocator = testing.allocator;
    // The constant itself is the downgrade gate: a pre-v0.2.29 binary rejects
    // any value other than 3 (and the V2/V1 legacy paths), so 4 fails loudly
    // there.
    try testing.expectEqual(@as(u32, 4), manifest_mod.MANIFEST_VERSION);

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir_path = try tmp_dir.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(dir_path);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/manifest_v3_roundtrip", .{dir_path});
    defer allocator.free(file_path);

    // A default-constructed manifest (what create() persists) round-trips as 4.
    const fresh = Manifest{ .graph_uuid = [_]u8{0xCC} ** 16 };
    try fresh.writeToFile(allocator, file_path);
    const on_disk = (try Manifest.readFromFile(allocator, file_path)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 4), on_disk.format_version);
}

test "GAP-0005a: torn/truncated WAL record fails recovery closed" {
    // A truncated record at the end of the WAL must stop recovery so the
    // operator can inspect the damaged WAL instead of silently dropping data.
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write initial manifest
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    // Create WAL with a valid committed txn followed by a truncated record
    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{});

    // BEGIN txn 1
    var begin_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .begin_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&begin_rec);

    // PAGE_UPDATE for txn 1 with recognizable data
    var page_data: [4096]u8 = undefined;
    @memset(&page_data, 0xF1);
    var update_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .page_update,
        .file_id = 0,
        .page_id = 1,
        .payload = &page_data,
        .checksum = 0,
    };
    _ = try wal.appendRecord(&update_rec);

    // COMMIT txn 1
    var commit_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .commit_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&commit_rec);

    // Write a truncated/garbage record directly into the WAL log.
    // This simulates a torn write (crash mid-write).
    const truncated_bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 }; // too short to be valid
    _ = try wal.inner.append(&truncated_bytes);

    try wal.sync();
    wal.deinit();

    // Run recovery -- truncated records must fail recovery closed
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 32);
    defer pool.deinit();

    var recovery_inst = Recovery.init(allocator, null);
    const result = recovery_inst.recover(&setup.graph_dir, &pool, &fm);
    try testing.expectError(error.InvalidFormat, result);
    try testing.expect(recovery_inst.last_failure != null);
    try testing.expectEqual(wal_mod.ReplayFailureKind.deserialize_failed, recovery_inst.last_failure.?.kind);
}

test "GAP-0005b: manifest A corrupt, B valid -- recovery uses B" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write a VALID manifest to slot B with distinctive values
    const valid_manifest = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 5,
        .next_node_id = 42,
        .last_checkpoint_lsn = 0,
    };
    const path_b = try setup.graph_dir.manifestPath(allocator, .b);
    defer allocator.free(path_b);
    try valid_manifest.writeToFile(allocator, path_b);

    // Write CORRUPT data to slot A (invalid magic/CRC)
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    {
        const corrupt_file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), path_a, .{});
        defer corrupt_file.close(std.Io.Threaded.global_single_threaded.io());
        var garbage: [148]u8 = undefined;
        @memset(&garbage, 0xFF); // total garbage, invalid magic + CRC
        try corrupt_file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), &garbage);
    }

    // Run recovery -- should use manifest B
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 16);
    defer pool.deinit();

    var recovery_inst = Recovery.init(allocator, null);
    const recovered = try recovery_inst.recover(&setup.graph_dir, &pool, &fm);

    // Recovered manifest should be from slot B
    try testing.expectEqual(@as(u64, 42), recovered.next_node_id);
    // Counter should be >= 5 (the value from B; recovery may increment it)
    try testing.expect(recovered.counter >= 5);
}

test "GAP-0005c: multiple concurrent transactions -- only committed data survives" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write initial manifest
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    // Create WAL with 3 interleaved transactions:
    //   txn 1 = committed (page 1, data 0xAA)
    //   txn 2 = uncommitted / still active (page 2, data 0xBB)
    //   txn 3 = aborted (page 3, data 0xCC)
    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{});

    // BEGIN all three
    var begin1 = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .begin_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&begin1);
    var begin2 = WalRecord{ .lsn = 0, .txn_id = 2, .record_type = .begin_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&begin2);
    var begin3 = WalRecord{ .lsn = 0, .txn_id = 3, .record_type = .begin_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&begin3);

    // PAGE_UPDATE for txn 1 (committed data)
    var data1: [4096]u8 = undefined;
    @memset(&data1, 0xAA);
    var upd1 = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .page_update, .file_id = 0, .page_id = 1, .payload = &data1, .checksum = 0 };
    _ = try wal.appendRecord(&upd1);

    // PAGE_UPDATE for txn 2 (uncommitted data)
    var data2: [4096]u8 = undefined;
    @memset(&data2, 0xBB);
    var upd2 = WalRecord{ .lsn = 0, .txn_id = 2, .record_type = .page_update, .file_id = 0, .page_id = 2, .payload = &data2, .checksum = 0 };
    _ = try wal.appendRecord(&upd2);

    // PAGE_UPDATE for txn 3 (aborted data)
    var data3: [4096]u8 = undefined;
    @memset(&data3, 0xCC);
    var upd3 = WalRecord{ .lsn = 0, .txn_id = 3, .record_type = .page_update, .file_id = 0, .page_id = 3, .payload = &data3, .checksum = 0 };
    _ = try wal.appendRecord(&upd3);

    // COMMIT txn 1
    var commit1 = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .commit_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&commit1);

    // ABORT txn 3
    var abort3 = WalRecord{ .lsn = 0, .txn_id = 3, .record_type = .abort_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&abort3);

    // txn 2 has no commit or abort -- simulates in-flight crash

    try wal.sync();
    wal.deinit();

    // Run recovery
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 64);
    defer pool.deinit();

    var recovery_inst = Recovery.init(allocator, null);
    _ = try recovery_inst.recover(&setup.graph_dir, &pool, &fm);

    // Verify: committed txn 1 page data (page 1) was applied
    const pager_ptr = fm.getPager(.nodes).?;

    var read_buf1: [4096]u8 = undefined;
    pager_ptr.readPage(1, &read_buf1) catch {
        return error.TestUnexpectedResult;
    };
    // Check committed data is present
    var committed_ok = true;
    for (read_buf1[page_mod.PAGE_HEADER_SIZE..]) |byte| {
        if (byte != 0xAA) {
            committed_ok = false;
            break;
        }
    }
    try testing.expect(committed_ok);

    // Verify: uncommitted txn 2 page data (page 2) was NOT applied
    var read_buf2: [4096]u8 = undefined;
    pager_ptr.readPage(2, &read_buf2) catch {
        // Page doesn't exist = correct, uncommitted data discarded
        return;
    };
    var uncommitted_present = true;
    for (read_buf2[page_mod.PAGE_HEADER_SIZE..]) |byte| {
        if (byte != 0xBB) {
            uncommitted_present = false;
            break;
        }
    }
    try testing.expect(!uncommitted_present);

    // Verify: aborted txn 3 page data (page 3) was NOT applied
    var read_buf3: [4096]u8 = undefined;
    pager_ptr.readPage(3, &read_buf3) catch {
        // Page doesn't exist = correct, aborted data discarded
        return;
    };
    var aborted_present = true;
    for (read_buf3[page_mod.PAGE_HEADER_SIZE..]) |byte| {
        if (byte != 0xCC) {
            aborted_present = false;
            break;
        }
    }
    try testing.expect(!aborted_present);
}

test "GAP-0005d: recovery with many pages (>100 page updates in WAL)" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write initial manifest
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{});

    // BEGIN txn 1
    var begin_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .begin_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&begin_rec);

    // Write 120 page_update records, each to a distinct page.
    // Each page gets a unique byte pattern based on its page index.
    const num_pages: u64 = 120;
    for (0..num_pages) |i| {
        var page_data: [4096]u8 = undefined;
        @memset(&page_data, @as(u8, @intCast(i % 256)));
        var upd = WalRecord{
            .lsn = 0,
            .txn_id = 1,
            .record_type = .page_update,
            .file_id = 0, // nodes
            .page_id = @intCast(i + 1), // pages 1..120
            .payload = &page_data,
            .checksum = 0,
        };
        _ = try wal.appendRecord(&upd);
    }

    // COMMIT txn 1
    var commit_rec = WalRecord{
        .lsn = 0,
        .txn_id = 1,
        .record_type = .commit_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&commit_rec);

    try wal.sync();
    wal.deinit();

    // Run recovery with enough buffer pool frames for all 120 pages
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 256);
    defer pool.deinit();

    var recovery_inst = Recovery.init(allocator, null);
    const recovered = try recovery_inst.recover(&setup.graph_dir, &pool, &fm);

    // Recovery should succeed and increment counter
    try testing.expectEqual(@as(u64, 2), recovered.counter);

    // Spot-check a sample of the 120 pages to verify data was applied correctly
    const pager_ptr = fm.getPager(.nodes).?;

    const check_pages = [_]u64{ 1, 50, 100, 119, 120 };
    for (check_pages) |pg| {
        var read_buf: [4096]u8 = undefined;
        pager_ptr.readPage(pg, &read_buf) catch {
            return error.TestUnexpectedResult;
        };
        const expected_byte: u8 = @intCast((pg - 1) % 256);
        var match = true;
        for (read_buf[page_mod.PAGE_HEADER_SIZE..]) |byte| {
            if (byte != expected_byte) {
                match = false;
                break;
            }
        }
        try testing.expect(match);
    }
}

test "deinit zeros encryption key" {
    const key = [_]u8{0xAA} ** 32;
    var recovery = Recovery.init(testing.allocator, key);

    // Before deinit, key should be present
    try testing.expect(recovery.encryption_key != null);
    try testing.expect(recovery.encryption_key.?[0] == 0xAA);

    recovery.deinit();

    // After deinit, key should be zeroed
    if (recovery.encryption_key) |k| {
        for (k) |byte| {
            try testing.expectEqual(@as(u8, 0), byte);
        }
    }
}

test "deinit with null encryption key does not panic" {
    var recovery = Recovery.init(testing.allocator, null);
    recovery.deinit(); // should not panic
}

test "SEC-0043: recovery rejects forged TDE manifest (rolled-back LSN, recomputed CRC)" {
    // Under TDE, an attacker with filesystem write access rolls back the
    // manifest's last_checkpoint_lsn and RECOMPUTES the CRC32 so the legacy
    // CRC-only check would pass. The keyed HMAC must catch the forgery and
    // recovery must fail closed instead of redirecting replay.
    const allocator = testing.allocator;
    // fips-exempt: non-security — CRC32C record-integrity (corruption detection)
    // for on-disk format; not authentication.
    const Crc32 = std.hash.crc.Crc32Iscsi;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    const key = [_]u8{0x43} ** 32;

    // Write an authenticated manifest to slot A with a real checkpoint LSN.
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 5,
        .last_checkpoint_lsn = 9000,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFileWithKey(allocator, path_a, key);

    // Forge slot A: roll back last_checkpoint_lsn to 0, recompute CRC32, but
    // leave the HMAC trailer (which no longer matches the tampered body).
    {
        const f = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path_a, .{ .mode = .read_write });
        defer f.close(std.Io.Threaded.global_single_threaded.io());
        const io = std.Io.Threaded.global_single_threaded.io();
        const flen = try f.length(io);
        const buf = try allocator.alloc(u8, @intCast(flen));
        defer allocator.free(buf);
        _ = try f.readPositionalAll(io, buf, 0);
        const lsn_offset: usize = 8 + 4 + 16 + 4 + 8; // magic+fmt+uuid+page_size+counter
        @memcpy(buf[lsn_offset..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, @as(u64, 0))));
        const crc_offset = manifest_mod.SERIALIZED_SIZE - 4;
        const new_crc = Crc32.hash(buf[0..crc_offset]);
        @memcpy(buf[crc_offset..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, new_crc)));
        try f.writePositionalAll(io, buf, 0);
    }

    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    fm.encryption_key = key;
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 16);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, key);
    defer recovery.deinit();
    // No valid manifest survives: slot A is forged (HMAC fails -> dropped) and
    // slot B was never written, so recovery has nothing authentic to load.
    // SONNY-6616: a slot that failed its HMAC makes that EncryptionKeyMismatch
    // (another key, or a modified manifest: the HMAC cannot tell them apart);
    // it was NoManifest.
    const result = recovery.recover(&setup.graph_dir, &pool, &fm);
    try testing.expectError(error.EncryptionKeyMismatch, result);
}

test "SEC-0043: TDE recovery round-trip — authenticated manifest loads cleanly" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    const key = [_]u8{0x43} ** 32;

    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 3,
        .next_node_id = 77,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFileWithKey(allocator, path_a, key);

    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    fm.encryption_key = key;
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 16);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, key);
    defer recovery.deinit();
    const recovered = try recovery.recover(&setup.graph_dir, &pool, &fm);
    try testing.expectEqual(@as(u64, 77), recovered.next_node_id);
    try testing.expectEqual([_]u8{0xBB} ** 16, recovered.graph_uuid);
}

test "recovery writes manifest to both slots A and B" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write initial manifest to slot A only
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    // Write a committed transaction so recovery writes a fresh manifest
    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{});
    var begin_rec = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .begin_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&begin_rec);
    var commit_rec = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .commit_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&commit_rec);
    try wal.sync();
    wal.deinit();

    // Run recovery
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();
    var pool = try BufferPool.init(allocator, 4096, 32);
    defer pool.deinit();
    var recovery = Recovery.init(allocator, null);
    defer recovery.deinit();
    _ = try recovery.recover(&setup.graph_dir, &pool, &fm);

    // Both slots should now have a valid manifest
    const slot_a_path = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(slot_a_path);
    const manifest_a = (try Manifest.readFromFile(allocator, slot_a_path)) orelse return error.TestUnexpectedResult;

    const slot_b_path = try setup.graph_dir.manifestPath(allocator, .b);
    defer allocator.free(slot_b_path);
    const manifest_b = (try Manifest.readFromFile(allocator, slot_b_path)) orelse return error.TestUnexpectedResult;

    // Both manifests should have the same counter
    try testing.expectEqual(manifest_a.counter, manifest_b.counter);
    try testing.expectEqual(manifest_a.last_checkpoint_lsn, manifest_b.last_checkpoint_lsn);
}

test "V1 format with reject policy returns IncompatibleVersion" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write a V1 manifest
    var v1_manifest = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
    };
    v1_manifest.format_version = manifest_mod.MANIFEST_VERSION_V1;
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try v1_manifest.writeToFile(allocator, path_a);

    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 16);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    recovery.legacy_policy = .reject;
    const result = recovery.recover(&setup.graph_dir, &pool, &fm);
    try testing.expectError(error.IncompatibleVersion, result);
}

test "V1 format with read_only policy succeeds and sets read_only flag" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write a V1 manifest
    var v1_manifest = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
    };
    v1_manifest.format_version = manifest_mod.MANIFEST_VERSION_V1;
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try v1_manifest.writeToFile(allocator, path_a);

    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 16);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    recovery.legacy_policy = .read_only;
    try testing.expect(!recovery.read_only);

    _ = try recovery.recover(&setup.graph_dir, &pool, &fm);

    // read_only flag should be set
    try testing.expect(recovery.read_only);
}

test "recovery records duration in metrics when wired" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write an initial manifest to slot A
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .next_node_id = 10,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 16);
    defer pool.deinit();

    var m = metrics_mod.Metrics{};
    try testing.expectEqual(@as(u64, 0), m.recovery_duration_ns);

    var recovery = Recovery.init(allocator, null);
    recovery.metrics = &m;
    _ = try recovery.recover(&setup.graph_dir, &pool, &fm);

    // Recovery should have recorded a non-zero duration
    try testing.expect(m.recovery_duration_ns > 0);
}

test "uncommitted transaction not applied during recovery" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Write initial manifest
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    // Open WAL directory and create WAL manager
    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{});

    // BEGIN txn 42
    var begin_rec = WalRecord{
        .lsn = 0,
        .txn_id = 42,
        .record_type = .begin_txn,
        .file_id = 0,
        .page_id = 0,
        .payload = &[_]u8{},
        .checksum = 0,
    };
    _ = try wal.appendRecord(&begin_rec);

    // PAGE_UPDATE for txn 42 -- write a page full of 0xAA
    var page_data: [4096]u8 = undefined;
    @memset(&page_data, 0xAA);
    var update_rec = WalRecord{
        .lsn = 0,
        .txn_id = 42,
        .record_type = .page_update,
        .file_id = 0, // nodes
        .page_id = 1,
        .payload = &page_data,
        .checksum = 0,
    };
    _ = try wal.appendRecord(&update_rec);

    // NO commit record -- simulate crash before commit
    try wal.sync();
    wal.deinit();

    // Run recovery
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 32);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    const m = try recovery.recover(&setup.graph_dir, &pool, &fm);
    _ = m;

    // The uncommitted page_update must NOT have been applied.
    // Pin the page and verify it is NOT filled with 0xAA.
    // Since the page was never written to the store, pinNew will give a
    // zero-initialized frame (no store file backing for page 1).
    // If recovery incorrectly replayed the uncommitted txn, the page would
    // contain 0xAA bytes.
    _ = try fm.openFile(.nodes, .create_if_missing);
    pool.registerPager(.nodes, &fm.pagers[@intFromEnum(FileId.nodes)].?);

    const frame = try pool.pinNew(.nodes, 1);
    const frame_idx = pool.frameIndex(frame);
    defer pool.unpin(frame_idx, false);
    const data = frame.dataSlice();

    // Verify the page is NOT filled with 0xAA (uncommitted data not applied)
    var found_aa = false;
    for (data[page_mod.PAGE_HEADER_SIZE..]) |byte| {
        if (byte == 0xAA) {
            found_aa = true;
            break;
        }
    }
    try testing.expect(!found_aa);
}

test "SEC-0037: recovery does not regress on-disk write_count below the persisted value" {
    // Models a crash where the on-disk page was flushed (advancing write_count
    // to N) AFTER the corresponding page_update was logged to the WAL (whose
    // payload carries a LOWER write_count). Naively replaying via pinNew would
    // reset write_count to the logged value and a later flush would reuse a
    // nonce already used on disk with different plaintext. Recovery must seed
    // the replayed frame to max(on-disk, logged) so the counter never regresses.
    const allocator = testing.allocator;

    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    const key = [_]u8{0x37} ** 32;

    // Write initial manifest. SEC-0043: under TDE the manifest must be
    // HMAC-authenticated with the same key recovery reads it with.
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFileWithKey(allocator, path_a, key);

    // Pre-flush the nodes store page 1 several times via an encryption-enabled
    // pager so the persisted on-disk write_count reaches a high value (N).
    // This simulates flushes that happened on the crashed run AFTER the
    // page_update below was appended to the WAL.
    const nodes_path = try std.fmt.allocPrint(allocator, "{s}/nodes.store", .{setup.graph_dir.path});
    defer allocator.free(nodes_path);
    const on_disk_write_count: u24 = blk: {
        const store = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), nodes_path, .{
            .read = true,
            .truncate = true,
        });
        defer store.close(std.Io.Threaded.global_single_threaded.io());

        var disk_pager = Pager.init(store, 4096);
        disk_pager.encryption = encryption_mod.PageEncryption.init(key);
        disk_pager.file_id = .nodes;

        var buf: [4096]u8 = undefined;
        @memset(&buf, 0);
        const header = page_mod.initHeader(1, .node_data, 4096);
        @memcpy(buf[0..page_mod.PAGE_HEADER_SIZE], page_mod.headerToBytes(&header));
        // Distinct on-disk content (NOT the WAL payload pattern).
        @memset(buf[page_mod.PAGE_HEADER_SIZE .. 4096 - encryption_mod.TAG_SIZE], 0x99);

        // Each writePage increments write_count; do it 5 times.
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            try disk_pager.writePage(1, &buf);
            // Re-stage plaintext for the next round (writePage encrypts in place).
            @memset(&buf, 0);
            @memcpy(buf[0..page_mod.PAGE_HEADER_SIZE], page_mod.headerToBytes(&header));
            @memset(buf[page_mod.PAGE_HEADER_SIZE .. 4096 - encryption_mod.TAG_SIZE], 0x99);
            // Carry forward the persisted write_count so the next write advances it.
            var raw: [4096]u8 = undefined;
            _ = try store.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), &raw, 4096); // page 1 offset
            page_mod.writeWriteCount(&buf, page_mod.readWriteCount(&raw));
        }

        var raw: [4096]u8 = undefined;
        _ = try store.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), &raw, 4096); // page 1 offset
        break :blk page_mod.readWriteCount(&raw);
    };
    try testing.expect(on_disk_write_count >= 5);

    // Build an encrypted WAL with a committed page_update for page 1. Its
    // payload header carries write_count = 0 (the value as of log time), which
    // is LOWER than the on-disk write_count established above.
    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{ .encryption_key = key });

    var begin_rec = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .begin_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&begin_rec);

    var page_data: [4096]u8 = undefined;
    @memset(&page_data, 0);
    const wal_header = page_mod.initHeader(1, .node_data, 4096);
    @memcpy(page_data[0..page_mod.PAGE_HEADER_SIZE], page_mod.headerToBytes(&wal_header));
    @memset(page_data[page_mod.PAGE_HEADER_SIZE..], 0xAB); // different from on-disk 0x99
    page_mod.writeWriteCount(&page_data, 0); // logged write_count is LOWER than on disk

    var update_rec = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .page_update, .file_id = 0, .page_id = 1, .payload = &page_data, .checksum = 0 };
    _ = try wal.appendRecord(&update_rec);

    var commit_rec = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .commit_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&commit_rec);
    try wal.sync();
    wal.deinit();

    // Run recovery with encryption enabled.
    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    fm.encryption_key = key;
    defer fm.deinit();

    var pool = try BufferPool.init(allocator, 4096, 32);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, key);
    defer recovery.deinit();
    _ = try recovery.recover(&setup.graph_dir, &pool, &fm);

    // The post-replay on-disk write_count must be >= the previously persisted
    // value (no regression). write_count is stored PLAINTEXT in the header, so
    // it can be read from the raw on-disk bytes without decrypting.
    const verify_pager = fm.getPager(.nodes).?;
    var verify_raw: [4096]u8 = undefined;
    _ = try verify_pager.file.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), &verify_raw, 4096); // page 1 offset
    const post_write_count = page_mod.readWriteCount(&verify_raw);
    try testing.expect(post_write_count >= on_disk_write_count);
}

test "0025 mechanism: replay heals manifest node/edge counts from applied images (telescoping, in-side and garbage excluded)" {
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    // Checkpoint-era manifest: 5 nodes, 7 edges persisted.
    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .node_count = 5,
        .edge_count = 7,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{});
    defer wal.deinit();

    var begin_rec = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .begin_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&begin_rec);

    const live_rec = node_mod.NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1, // non-empty ⇒ live
    };
    var deleted_rec = live_rec;
    deleted_rec.flags = node_mod.NODE_FLAG_DELETED; // issued id, NOT live

    const body_off = node_mod.PAGE_HEADER_SIZE;
    const rec_size = @sizeOf(node_mod.NodeRec);

    // Nodes page 3, image 1: one live slot (census 1).
    var node_img1: [4096]u8 = undefined;
    @memset(&node_img1, 0);
    @memcpy(node_img1[body_off..][0..rec_size], std.mem.asBytes(&live_rec));
    var up1 = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .page_update, .file_id = @intFromEnum(FileId.nodes), .page_id = 3, .payload = &node_img1, .checksum = 0 };
    _ = try wal.appendRecord(&up1);

    // Nodes page 3, image 2 (SUPERSEDES image 1): slots 0+2 live, slot 1
    // DELETED-flagged (census 2). The two per-image diffs must telescope to
    // +2 for this page — not +1+2=+3.
    var node_img2: [4096]u8 = undefined;
    @memset(&node_img2, 0);
    @memcpy(node_img2[body_off..][0..rec_size], std.mem.asBytes(&live_rec));
    @memcpy(node_img2[body_off + rec_size ..][0..rec_size], std.mem.asBytes(&deleted_rec));
    @memcpy(node_img2[body_off + 2 * rec_size ..][0..rec_size], std.mem.asBytes(&live_rec));
    var up2 = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .page_update, .file_id = @intFromEnum(FileId.nodes), .page_id = 3, .payload = &node_img2, .checksum = 0 };
    _ = try wal.appendRecord(&up2);

    // Adjacency block builder: v2 block with `n` entries.
    const mkAdj = struct {
        fn mk(buf: *[4096]u8, n: u16) void {
            @memset(buf, 0);
            const hdr_off = page_mod.PAGE_HEADER_SIZE;
            const bh = edge_mod.EdgeBlockHeader{
                .next_block = 0,
                .count = n,
                .kind = 0,
                .entry_format = edge_mod.ENTRY_FORMAT_V2,
                .payload_size = 0,
                .checksum = 0,
            };
            @memcpy(buf[hdr_off..][0..@sizeOf(edge_mod.EdgeBlockHeader)], std.mem.asBytes(&bh));
            var i: u16 = 0;
            while (i < n) : (i += 1) {
                const e = edge_mod.EdgeEntry{
                    .neighbor = 1,
                    .edge_id = 100 + i,
                    .rel_type = 1,
                    .prop_head = 0,
                    .public_id = 0,
                };
                edge_mod.encodeEntry(buf[hdr_off + @sizeOf(edge_mod.EdgeBlockHeader) + @as(usize, i) * 32 ..][0..32], e, edge_mod.ENTRY_FORMAT_V2);
            }
        }
    }.mk;

    // `.adj_out` page 9: 3 out-entries ⇒ +3 edges.
    var adj_out_img: [4096]u8 = undefined;
    mkAdj(&adj_out_img, 3);
    var up3 = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .page_update, .file_id = @intFromEnum(FileId.adj_out), .page_id = 9, .payload = &adj_out_img, .checksum = 0 };
    _ = try wal.appendRecord(&up3);

    // `.adj_in` page 4 (4 entries) and `.in_idx` page 2 (2 entries): in-side
    // copies — MUST NOT contribute (they would double-count the out-entries).
    var adj_in_img: [4096]u8 = undefined;
    mkAdj(&adj_in_img, 4);
    var up4 = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .page_update, .file_id = @intFromEnum(FileId.adj_in), .page_id = 4, .payload = &adj_in_img, .checksum = 0 };
    _ = try wal.appendRecord(&up4);
    var in_idx_img: [4096]u8 = undefined;
    mkAdj(&in_idx_img, 2);
    var up5 = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .page_update, .file_id = @intFromEnum(FileId.in_idx), .page_id = 2, .payload = &in_idx_img, .checksum = 0 };
    _ = try wal.appendRecord(&up5);

    // `.adj_out` page 11 with a GARBAGE block header (unknown entry_format,
    // nonzero count): contributes nothing and — the infallibility contract —
    // must not fail recovery.
    var garbage_img: [4096]u8 = undefined;
    @memset(&garbage_img, 0);
    const garbage_bh = edge_mod.EdgeBlockHeader{
        .next_block = 0,
        .count = 50, // would poison the edge delta if the format guard failed
        .kind = 0,
        .entry_format = 0xFF,
        .payload_size = 0,
        .checksum = 0,
    };
    @memcpy(garbage_img[page_mod.PAGE_HEADER_SIZE..][0..@sizeOf(edge_mod.EdgeBlockHeader)], std.mem.asBytes(&garbage_bh));
    var up6 = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .page_update, .file_id = @intFromEnum(FileId.adj_out), .page_id = 11, .payload = &garbage_img, .checksum = 0 };
    _ = try wal.appendRecord(&up6);

    var commit_rec = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .commit_txn, .file_id = 0, .page_id = 0, .payload = &[_]u8{}, .checksum = 0 };
    _ = try wal.appendRecord(&commit_rec);
    try wal.sync();

    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();
    var pool = try BufferPool.init(allocator, 4096, 32);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    const recovered = try recovery.recover(&setup.graph_dir, &pool, &fm);

    // 5 + 2 live node slots; 7 + 3 out-entries. In-side and garbage images
    // contributed nothing.
    try testing.expectEqual(@as(u64, 7), recovered.node_count);
    try testing.expectEqual(@as(u64, 10), recovered.edge_count);
    try testing.expectEqual(@as(i64, 2), recovery.replayed_node_delta);
    try testing.expectEqual(@as(i64, 3), recovery.replayed_edge_delta);

    // Healed counts are DURABLE: both manifest slots carry them (they rode
    // the same A/B write as the advanced LSN).
    const on_disk_a = (try Manifest.readFromFile(allocator, path_a)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 7), on_disk_a.node_count);
    try testing.expectEqual(@as(u64, 10), on_disk_a.edge_count);
    const path_b = try setup.graph_dir.manifestPath(allocator, .b);
    defer allocator.free(path_b);
    const on_disk_b = (try Manifest.readFromFile(allocator, path_b)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 7), on_disk_b.node_count);
    try testing.expectEqual(@as(u64, 10), on_disk_b.edge_count);
}

/// Build a minimal SLAB adjacency page image (GAP adjacency slab packing) for
/// the harvest unit tests below: header stamped ENTRY_FORMAT_SLAB with
/// `slot_count` directory entries; the caller fills runs + slots.
fn stampSlabHeader(img: []u8, slot_count: u16) void {
    const bh = edge_mod.EdgeBlockHeader{
        .next_block = 0,
        .count = slot_count,
        .kind = 0,
        .entry_format = edge_mod.ENTRY_FORMAT_SLAB,
        .payload_size = 0,
        .checksum = 0,
    };
    @memcpy(img[page_mod.PAGE_HEADER_SIZE..][0..@sizeOf(edge_mod.EdgeBlockHeader)], std.mem.asBytes(&bh));
}

fn slabRunEntry(edge_id: u64) edge_mod.EdgeEntry {
    return .{ .neighbor = 1, .edge_id = edge_id, .rel_type = 7, .prop_head = 0, .public_id = 0 };
}

/// GAP-0060: a SLAB-V3 (40 B stride) adjacency image header.
fn stampSlabHeaderV3(img: []u8, slot_count: u16) void {
    const bh = edge_mod.EdgeBlockHeader{
        .next_block = 0,
        .count = slot_count,
        .kind = 0,
        .entry_format = edge_mod.ENTRY_FORMAT_SLAB_V3,
        .payload_size = 0,
        .checksum = 0,
    };
    @memcpy(img[page_mod.PAGE_HEADER_SIZE..][0..@sizeOf(edge_mod.EdgeBlockHeader)], std.mem.asBytes(&bh));
}

test "GAP-0060: recovery harvest + census parse slab-V3 (40B) runs; ids never escape the heal" {
    // The silent-staleness landmine: a replayed slab-V3 edge run must be walked
    // at the 40 B stride. Had the harvest kept the 32 B stride, entry 1's
    // edge_id would be read from the middle of entry 0's record — NOT the true
    // max — and the healed edge-id counter would re-issue a live id after a
    // crash. This proves the stride + the slab-V3 dispatch are both correct.
    var rec = Recovery.init(testing.allocator, null);
    defer rec.deinit();
    rec.id_stride = 16;
    rec.shard_residue = 0;

    const img = try testing.allocator.alloc(u8, 4096);
    defer testing.allocator.free(img);
    @memset(img, 0);
    stampSlabHeaderV3(img, 2);

    const V3: u32 = edge_mod.ENTRY_SIZE_V3;
    const small: u64 = 16 * 3; // ≡ 0 (mod 16)
    const max: u64 = 16 * 700; // ≡ 0 — the value the heal must learn

    // Slot 0: a live 2-entry V3 run. Entry 0 carries a prop-store SLAB head
    // (bit 63) — only representable in a V3 record — to exercise the wide bytes.
    const run0: u32 = edge_mod.SLAB_RUNS_OFFSET;
    var e0 = slabRunEntry(small);
    e0.prop_head = (@as(u64, 1) << 63) | 0x1234;
    edge_mod.encodeEntry(img[run0 .. run0 + V3], e0, edge_mod.ENTRY_FORMAT_SLAB_V3);
    const e1 = slabRunEntry(max);
    edge_mod.encodeEntry(img[run0 + V3 .. run0 + 2 * V3], e1, edge_mod.ENTRY_FORMAT_SLAB_V3);
    edge_mod.writeSlabSlot(img, 0, 0, .{ .offset = run0, .entry_count = 2 });
    // Slot 1: tombstone — contributes nothing.
    edge_mod.writeSlabSlot(img, 0, 1, .{ .offset = edge_mod.SLAB_SLOT_TOMBSTONE, .entry_count = 0 });

    rec.trackReplayedIdMaxima(.adj_out, 60, img);
    try testing.expectEqual(max, rec.max_replayed_edge_id);
    // Census counts the 2 live V3 entries at the 40 B stride.
    try testing.expectEqual(@as(u64, 2), rec.liveRecordCensus(.adj_out, img));
}

test "adjacency slab: counter harvest learns slab-block WAL images (ids in slab runs never escape the heal)" {
    // Plan hard requirement (GAP adjacency slab packing P1): the counter
    // harvest MUST parse slab adjacency images in the same phase that
    // introduces the slab layout. Before this, `entry_format == 2` fell into
    // the `> ENTRY_FORMAT_V2` skip — an edge id living ONLY in a replayed
    // slab run would escape the heal and be re-issued after a crash (the
    // exact silent-staleness class the counter heal closed for chain blocks).
    var rec = Recovery.init(testing.allocator, null);
    defer rec.deinit();
    rec.id_stride = 16;
    rec.shard_residue = 0;

    const img = try testing.allocator.alloc(u8, 4096);
    defer testing.allocator.free(img);
    @memset(img, 0);
    stampSlabHeader(img, 4);

    const in_class_small: u64 = 16 * 3; // ≡ 0 (mod 16)
    const in_class_max: u64 = 16 * 700; // ≡ 0 — the value the heal must learn
    const foreign_higher: u64 = 16 * 9000 + 5; // ≡ 5 — residue guard must skip

    // Slot 0: live 2-entry run [small, max] — both in-class.
    const run0: u32 = edge_mod.SLAB_RUNS_OFFSET;
    var e = slabRunEntry(in_class_small);
    edge_mod.encodeEntry(img[run0..][0..edge_mod.ENTRY_SIZE_V2], e, edge_mod.ENTRY_FORMAT_SLAB);
    e = slabRunEntry(in_class_max);
    edge_mod.encodeEntry(img[run0 + edge_mod.ENTRY_SIZE_V2 ..][0..edge_mod.ENTRY_SIZE_V2], e, edge_mod.ENTRY_FORMAT_SLAB);
    edge_mod.writeSlabSlot(img, 0, 0, .{ .offset = run0, .entry_count = 2 });

    // Slot 1: live run carrying a HIGHER foreign-residue id — skipped (I1).
    const run1: u32 = run0 + 2 * edge_mod.ENTRY_SIZE_V2;
    e = slabRunEntry(foreign_higher);
    edge_mod.encodeEntry(img[run1..][0..edge_mod.ENTRY_SIZE_V2], e, edge_mod.ENTRY_FORMAT_SLAB);
    edge_mod.writeSlabSlot(img, 0, 1, .{ .offset = run1, .entry_count = 1 });

    // Slot 2: tombstone — contributes nothing.
    edge_mod.writeSlabSlot(img, 0, 2, .{ .offset = edge_mod.SLAB_SLOT_TOMBSTONE, .entry_count = 0 });

    // Slot 3: malformed (run overruns the slot directory) — skipped
    // defensively WITHOUT aborting the well-formed siblings above.
    edge_mod.writeSlabSlot(img, 0, 3, .{ .offset = run0, .entry_count = 4000 });

    rec.trackReplayedIdMaxima(.adj_out, 60, img);
    try testing.expectEqual(in_class_max, rec.max_replayed_edge_id);

    // Sensitivity proof: restamp the SAME image with a genuinely UNKNOWN
    // format byte (0xFE — not v1/v2/v3/slab/slab-v3) — a fresh harvest learns
    // nothing. This fails loudly if slab images ever fall back into the
    // unknown-format skip. GAP-0060: format 3 is now v3 (a valid chain), so the
    // guard uses a value above every known format.
    var rec2 = Recovery.init(testing.allocator, null);
    defer rec2.deinit();
    rec2.id_stride = 16;
    rec2.shard_residue = 0;
    img[page_mod.PAGE_HEADER_SIZE + 11] = 0xFE;
    rec2.trackReplayedIdMaxima(.adj_out, 60, img);
    try testing.expectEqual(@as(u64, 0), rec2.max_replayed_edge_id);

    // A chained "slab" block is not a layout we understand — nothing learned
    // (slab blocks are never linked into chains).
    var rec3 = Recovery.init(testing.allocator, null);
    defer rec3.deinit();
    rec3.id_stride = 16;
    rec3.shard_residue = 0;
    img[page_mod.PAGE_HEADER_SIZE + 11] = edge_mod.ENTRY_FORMAT_SLAB;
    std.mem.writeInt(u64, img[page_mod.PAGE_HEADER_SIZE..][0..8], 99, .little); // next_block != 0
    rec3.trackReplayedIdMaxima(.adj_out, 60, img);
    try testing.expectEqual(@as(u64, 0), rec3.max_replayed_edge_id);
}

test "adjacency slab: harvest reads the slot directory above the AES-GCM tail reservation" {
    // With at-rest encryption configured the slab slot directory grows
    // backward from (page end - TAG_SIZE) — the pager owns the final tag
    // bytes. The harvest must mirror that base or it misparses every slot
    // (garbage offsets → nothing harvested → ids escape the heal).
    const key = [_]u8{0x42} ** 32;
    var rec = Recovery.init(testing.allocator, key);
    defer rec.deinit();
    // Standalone-engine defaults: id_stride 1, shard_residue 0.

    const img = try testing.allocator.alloc(u8, 4096);
    defer testing.allocator.free(img);
    @memset(img, 0);
    stampSlabHeader(img, 1);

    const eid: u64 = 424_242;
    const e = slabRunEntry(eid);
    edge_mod.encodeEntry(img[edge_mod.SLAB_RUNS_OFFSET..][0..edge_mod.ENTRY_SIZE_V2], e, edge_mod.ENTRY_FORMAT_SLAB);
    edge_mod.writeSlabSlot(img, encryption_mod.TAG_SIZE, 0, .{ .offset = edge_mod.SLAB_RUNS_OFFSET, .entry_count = 1 });

    rec.trackReplayedIdMaxima(.adj_out, 60, img);
    try testing.expectEqual(eid, rec.max_replayed_edge_id);
}

test "0025 x adjacency slab: edge census counts slab-run entries exactly as the harvest parses them" {
    // Merge coherence (0025 stats-count heal × adjacency slab packing): slab
    // out-runs ARE out-entries, so the census must count a replayed slab
    // image's live run entries through the same per-slot guards as the id
    // harvest. If a slab image censused 0, every post-slab crash replay
    // would diff 0-minus-before and walk the healed edge_count BACKWARD.
    var rec = Recovery.init(testing.allocator, null);
    defer rec.deinit();

    const img = try testing.allocator.alloc(u8, 4096);
    defer testing.allocator.free(img);
    @memset(img, 0);
    stampSlabHeader(img, 4);

    // Slot 0: live 2-entry run; slot 1: live 1-entry run — census 3.
    const run0: u32 = edge_mod.SLAB_RUNS_OFFSET;
    var e = slabRunEntry(100);
    edge_mod.encodeEntry(img[run0..][0..edge_mod.ENTRY_SIZE_V2], e, edge_mod.ENTRY_FORMAT_SLAB);
    e = slabRunEntry(101);
    edge_mod.encodeEntry(img[run0 + edge_mod.ENTRY_SIZE_V2 ..][0..edge_mod.ENTRY_SIZE_V2], e, edge_mod.ENTRY_FORMAT_SLAB);
    edge_mod.writeSlabSlot(img, 0, 0, .{ .offset = run0, .entry_count = 2 });
    const run1: u32 = run0 + 2 * edge_mod.ENTRY_SIZE_V2;
    e = slabRunEntry(102);
    edge_mod.encodeEntry(img[run1..][0..edge_mod.ENTRY_SIZE_V2], e, edge_mod.ENTRY_FORMAT_SLAB);
    edge_mod.writeSlabSlot(img, 0, 1, .{ .offset = run1, .entry_count = 1 });

    // Slot 2: tombstone; slot 3: malformed (run overruns the directory) —
    // both contribute zero WITHOUT discarding the live siblings above.
    edge_mod.writeSlabSlot(img, 0, 2, .{ .offset = edge_mod.SLAB_SLOT_TOMBSTONE, .entry_count = 0 });
    edge_mod.writeSlabSlot(img, 0, 3, .{ .offset = run0, .entry_count = 4000 });

    try testing.expectEqual(@as(u64, 3), rec.liveRecordCensus(.adj_out, img));

    // A chained "slab" header is not a layout we understand — census 0, the
    // same skip the harvest applies.
    std.mem.writeInt(u64, img[page_mod.PAGE_HEADER_SIZE..][0..8], 99, .little);
    try testing.expectEqual(@as(u64, 0), rec.liveRecordCensus(.adj_out, img));
}

test "SONNY-6473: replay keeps the highest-LSN committed image when an older one is logged after it" {
    // GAP-0900 batching numbers a record when it is made but writes it at the
    // owning txn's commit. Txn 1 batches an image of nodes page 3 (LSN n);
    // txn 2 then images the same page directly (LSN n+2) and commits; txn 1
    // flushes and commits last. The log holds the newer image FIRST. Logs of
    // this shape are already on disk from 0.4.12/0.4.13, so recovery itself
    // must order images by LSN.
    const allocator = testing.allocator;
    var setup = try setupTestGraph(allocator);
    defer {
        setup.graph_dir.deinit();
        setup.tmp_dir.cleanup();
    }

    const initial = Manifest{
        .graph_uuid = [_]u8{0xBB} ** 16,
        .page_size = 4096,
        .counter = 1,
        .last_checkpoint_lsn = 0,
    };
    const path_a = try setup.graph_dir.manifestPath(allocator, .a);
    defer allocator.free(path_a);
    try initial.writeToFile(allocator, path_a);

    const wal_dir_path = try std.fmt.allocPrint(allocator, "{s}/wal", .{setup.graph_dir.path});
    defer allocator.free(wal_dir_path);
    var wal_dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), wal_dir_path, .{});
    defer wal_dir.close(std.Io.Threaded.global_single_threaded.io());

    const live = node_mod.NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    };
    const body_off = node_mod.PAGE_HEADER_SIZE;
    const rec_size = @sizeOf(node_mod.NodeRec);
    const npp = node_mod.nodesPerPage(4096);

    // Older image (txn 1): slots 0 and 5 live, slot 0 with prop_head 111.
    var old_img: [4096]u8 = undefined;
    @memset(&old_img, 0);
    var old_rec = live;
    old_rec.prop_head = 111;
    @memcpy(old_img[body_off..][0..rec_size], std.mem.asBytes(&old_rec));
    @memcpy(old_img[body_off + 5 * rec_size ..][0..rec_size], std.mem.asBytes(&live));
    // Newer image (txn 2): slot 0 only, prop_head 222.
    var new_img: [4096]u8 = undefined;
    @memset(&new_img, 0);
    var new_rec = live;
    new_rec.prop_head = 222;
    @memcpy(new_img[body_off..][0..rec_size], std.mem.asBytes(&new_rec));

    {
        var wal = try WalManager.init(allocator, wal_dir, [_]u8{0xBB} ** 16, 0, .{});
        defer wal.deinit();

        var b1 = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .begin_txn, .file_id = 0, .page_id = 0, .payload = &.{}, .checksum = 0 };
        _ = try wal.appendRecord(&b1);
        try wal.beginBatch(1);
        var upd1 = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .page_update, .file_id = @intFromEnum(FileId.nodes), .page_id = 3, .payload = &old_img, .checksum = 0 };
        const old_lsn = try wal.appendRecord(&upd1);

        var b2 = WalRecord{ .lsn = 0, .txn_id = 2, .record_type = .begin_txn, .file_id = 0, .page_id = 0, .payload = &.{}, .checksum = 0 };
        _ = try wal.appendRecord(&b2);
        var upd2 = WalRecord{ .lsn = 0, .txn_id = 2, .record_type = .page_update, .file_id = @intFromEnum(FileId.nodes), .page_id = 3, .payload = &new_img, .checksum = 0 };
        const new_lsn = try wal.appendRecord(&upd2);
        var c2 = WalRecord{ .lsn = 0, .txn_id = 2, .record_type = .commit_txn, .file_id = 0, .page_id = 0, .payload = &.{}, .checksum = 0 };
        _ = try wal.appendRecord(&c2);
        try testing.expect(new_lsn > old_lsn);

        try wal.flushBatchFor(1);
        var c1 = WalRecord{ .lsn = 0, .txn_id = 1, .record_type = .commit_txn, .file_id = 0, .page_id = 0, .payload = &.{}, .checksum = 0 };
        _ = try wal.appendRecord(&c1);
        try wal.sync();
    }

    var fm = FileManager.init(allocator, setup.graph_dir.path, 4096);
    defer fm.deinit();
    var pool = try BufferPool.init(allocator, 4096, 32);
    defer pool.deinit();

    var recovery = Recovery.init(allocator, null);
    defer recovery.deinit();
    const recovered = try recovery.recover(&setup.graph_dir, &pool, &fm);

    var read_buf: [4096]u8 = undefined;
    try fm.getPager(.nodes).?.readPage(3, &read_buf);
    const slot0 = std.mem.bytesToValue(node_mod.NodeRec, read_buf[body_off..][0..rec_size]);
    const slot5 = std.mem.bytesToValue(node_mod.NodeRec, read_buf[body_off + 5 * rec_size ..][0..rec_size]);
    try testing.expectEqual(@as(u64, 222), slot0.prop_head);
    try testing.expect(node_mod.isEmpty(&slot5));

    // The stats heal censuses the page as it ends up (one live slot).
    try testing.expectEqual(@as(u64, 1), recovered.node_count);
    // Slot 5's id appears only in the superseded image, but it was durably
    // committed once: the id-counter heal must still never re-issue it.
    try testing.expect(recovered.next_node_id > 3 * npp + 5);
}

test {
    std.testing.refAllDecls(@This());
}
