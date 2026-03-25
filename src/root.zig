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
pub const node = @import("node.zig");
pub const edge = @import("edge.zig");
pub const property = @import("property.zig");

// Re-export key types for convenience
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
