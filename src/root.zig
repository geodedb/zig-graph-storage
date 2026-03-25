// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! # graph-storage
//!
//! A high-performance graph storage engine built in Zig.

const std = @import("std");

pub const types = @import("types.zig");
pub const errors = @import("errors.zig");
pub const config = @import("config.zig");
pub const page = @import("page.zig");
pub const pager = @import("pager.zig");
pub const page_frame = @import("page_frame.zig");
pub const buffer_pool = @import("buffer_pool.zig");
pub const node = @import("node.zig");
pub const edge = @import("edge.zig");
pub const property = @import("property.zig");
pub const file_manager = @import("file_manager.zig");
pub const interface = @import("interface.zig");
pub const manifest = @import("manifest.zig");
pub const graph_dir = @import("graph_dir.zig");
pub const registry = @import("registry.zig");
pub const label_dict = @import("label_dict.zig");
pub const free_space = @import("free_space.zig");
pub const node_store = @import("node_store.zig");
pub const adj_store = @import("adj_store.zig");
pub const prop_store = @import("prop_store.zig");
pub const var_store = @import("var_store.zig");
pub const wal_record = @import("wal_record.zig");
pub const wal_segment = @import("wal_segment.zig");
pub const wal = @import("wal.zig");
pub const txn = @import("txn.zig");

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
