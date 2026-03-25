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
//! - **Indexing** (`label_index`, `btree`, `property_index`, `index_catalog`) —
//!   label posting lists, generic B+tree, composite property indexes, and a
//!   persistent catalog.
//! - **Encryption and integrity** (`encryption`, `integrity`, `verify`) —
//!   optional AES-256-CTR page encryption, CRC32C checksums, and full-store
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
pub const prop_store = @import("prop_store.zig");
pub const var_store = @import("var_store.zig");

// WAL and transactions
pub const wal_record = @import("wal_record.zig");
pub const wal = @import("wal.zig");
pub const txn = @import("txn.zig");

// Checkpoint and recovery
pub const checkpoint = @import("checkpoint.zig");
pub const recovery = @import("recovery.zig");

// Engine
pub const engine = @import("engine.zig");

// Indexing
pub const label_index = @import("label_index.zig");
pub const btree = @import("btree.zig");
pub const property_index = @import("property_index.zig");
pub const index_catalog = @import("index_catalog.zig");

// Encryption and integrity
pub const encryption = @import("encryption.zig");
pub const integrity = @import("integrity.zig");
pub const verify = @import("verify.zig");

// Migration and operations
pub const migration = @import("migration.zig");
pub const backup = @import("backup.zig");
pub const maintenance = @import("maintenance.zig");

pub const GraphEngine = engine.GraphEngine;

// Re-export key types for convenience
pub const GraphStorage = interface.GraphStorage;
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

pub const version = "0.1.0";

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
    try std.testing.expectEqualStrings("0.1.0", version);
}

test {
    std.testing.refAllDecls(@This());
}
