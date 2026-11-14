// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! # graph-storage
//!
//! A high-performance, page-based graph storage engine built in Zig for the
//! Geode graph database.
//!
//! ## Subsystems
//!
//! - **Storage engine** (`engine`) — `GraphEngine` wires all components together
//!   and implements the `GraphStorage` vtable interface.
//! - **Page I/O** (`pager`, `buffer_pool`, `page`, `page_frame`) — fixed-size
//!   page read/write with an LRU buffer pool and dirty-page tracking.
//! - **Record stores** (`node_store`, `adj_store`, `prop_store`, `var_store`,
//!   `free_space`) — fixed- and variable-length record storage on pages.
//! - **WAL and transactions** (`wal`, `wal_record`, `txn`) — write-ahead log
//!   with per-transaction isolation.
//! - **Checkpoint and recovery** (`checkpoint`, `recovery`) — incremental
//!   checkpoint with A/B manifest switching and crash recovery via WAL replay.
//! - **Indexing** (`label_index`, `property_chain_index`, `index_snapshot`) —
//!   label posting lists, persisted derived snapshots, and the in-memory
//!   property-chain digest index used by the runtime engine. Experimental
//!   B+tree helpers remain available as standalone modules.
//! - **Encryption and integrity** (`encryption`, `integrity`, `verify`) —
//!   optional AES-256-GCM page encryption, CRC32C checksums, and full-store
//!   verification.
//! - **Migration and operations** (`migration`, `backup`, `maintenance`) —
//!   legacy format detection, per-graph backup/restore, and administrative
//!   maintenance (force checkpoint, index rebuild, stats).

const std = @import("std");

// Core types and configuration
pub const types = @import("types.zig");
pub const errors = @import("errors.zig");
pub const config = @import("config.zig");

// Page I/O
pub const page = @import("page.zig");
pub const crc32c = @import("crc32c.zig");
pub const pager = @import("pager.zig");
pub const page_frame = @import("page_frame.zig");
pub const buffer_pool = @import("buffer_pool.zig");

// Record formats
pub const node = @import("node.zig");
pub const edge = @import("edge.zig");
pub const property = @import("property.zig");

// File and directory management
pub const file_manager = @import("file_manager.zig");
pub const interface = @import("interface.zig");
pub const manifest = @import("manifest.zig");
pub const graph_dir = @import("graph_dir.zig");
pub const registry = @import("registry.zig");
pub const label_dict = @import("label_dict.zig");
pub const free_space = @import("free_space.zig");

// Record stores
pub const node_store = @import("node_store.zig");
pub const adj_store = @import("adj_store.zig");
pub const in_head_dir = @import("in_head_dir.zig");
pub const edge_exist_index = @import("edge_exist_index.zig");
pub const edge_index_map = @import("edge_index_map.zig");
pub const sorted_index_snapshot = @import("sorted_index_snapshot.zig");
pub const prop_store = @import("prop_store.zig");
pub const var_store = @import("var_store.zig");
pub const label_store = @import("label_store.zig");

// WAL and transactions
pub const wal_record = @import("wal_record.zig");
pub const wal = @import("wal.zig");
pub const txn = @import("txn.zig");

// Checkpoint and recovery
pub const checkpoint = @import("checkpoint.zig");
pub const recovery = @import("recovery.zig");

// Metrics / observability
pub const metrics = @import("metrics.zig");

// otel observability seam. Surfaces `startOperationSpan` /
// `endOperationSpan` plus the `enabled` flag. When
// `-Dwith_otel=false` (the default), every helper collapses to a
// comptime no-op and the otel dependency is never resolved. The
// public API is reachable as `graph_storage.observability`.
pub const observability = @import("observability");

// Bootstrap helper for the enabled build. Only registered as a build
// import when `-Dwith_otel=true`; under the disabled build the
// reference resolves to a placeholder empty struct so the public root
// stays uniform.
pub const observability_init = if (observability.enabled)
    @import("observability_init")
else
    struct {};

// Engine
pub const engine = @import("engine.zig");

// Indexing
pub const label_index = @import("label_index.zig");
pub const btree = @import("btree.zig");
pub const property_index = @import("property_index.zig");
pub const property_chain_index = @import("property_chain_index.zig");
pub const prop_rev_index = @import("prop_rev_index.zig");
pub const index_catalog = @import("index_catalog.zig");
pub const index_snapshot = @import("index_snapshot.zig");
pub const engine_property_index = @import("engine_property_index.zig");

// Encryption and integrity
pub const encryption = @import("encryption.zig");
pub const integrity = @import("integrity.zig");
pub const verify = @import("verify.zig");

// Migration and operations
pub const migration = @import("migration.zig");
pub const backup = @import("backup.zig");
pub const maintenance = @import("maintenance.zig");
pub const operation_result = @import("operation_result.zig");
pub const ordered_encoding = @import("ordered_encoding.zig");
pub const ordered_btree = @import("ordered_btree.zig");
pub const ordered_property_index = @import("ordered_property_index.zig");
pub const test_support = @import("testing_support.zig");

// In-memory concurrency primitives (reusable utilities for consumers
// that layer concurrent in-memory structures on top of the engine).
pub const sharded_store = @import("sharded_store.zig");
pub const shard_count = @import("shard_count.zig");
pub const shard_uuid = @import("shard_uuid.zig");
pub const shard_manifest = @import("shard_manifest.zig");
pub const sharded_engine = @import("sharded_engine.zig");
pub const sharded_engine_2pc = @import("sharded_engine_2pc.zig");
pub const sharded_recovery = @import("sharded_recovery.zig");
pub const sharded_labels = @import("sharded_labels.zig");

pub const GraphEngine = engine.GraphEngine;
pub const ShardedGraphEngine = sharded_engine.ShardedGraphEngine;

// Re-export key types for convenience
pub const GraphStorage = interface.GraphStorage;
pub const NodeIterator = interface.NodeIterator;
pub const PropertyEntry = interface.PropertyEntry;
pub const NodeId = types.NodeId;
pub const EdgeId = types.EdgeId;
pub const PageId = types.PageId;
pub const Lsn = types.Lsn;
pub const TxnId = types.TxnId;
pub const LabelId = types.LabelId;
pub const GraphUuid = types.GraphUuid;
pub const FileId = types.FileId;
pub const PropertyValue = types.PropertyValue;
pub const StorageError = errors.StorageError;
pub const GraphConfig = config.GraphConfig;
pub const SyncMode = config.SyncMode;
pub const LabelDictDivergencePolicy = config.LabelDictDivergencePolicy;
pub const Metrics = metrics.Metrics;

pub const version = "0.4.14";

// ============================================================================
// Unit Tests
// ============================================================================

test "re-exported types match source types" {
    try std.testing.expect(NodeId == types.NodeId);
    try std.testing.expect(EdgeId == types.EdgeId);
    try std.testing.expect(PageId == types.PageId);
    try std.testing.expect(Lsn == types.Lsn);
    try std.testing.expect(TxnId == types.TxnId);
    try std.testing.expect(LabelId == types.LabelId);
    try std.testing.expect(GraphUuid == types.GraphUuid);
    try std.testing.expect(FileId == types.FileId);
    try std.testing.expect(PropertyValue == types.PropertyValue);
    try std.testing.expect(StorageError == errors.StorageError);
    try std.testing.expect(GraphConfig == config.GraphConfig);
}

test "version is set" {
    try std.testing.expectEqualStrings("0.4.14", version);
}

test {
    std.testing.refAllDecls(@This());
}
