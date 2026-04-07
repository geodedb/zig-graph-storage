// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

pub const OperationKind = enum {
    backup,
    restore,
    verify,
    migration,
    force_checkpoint,
    rebuild_indexes,
    flush_dirty_pages,
    storage_stats,

    pub fn label(self: OperationKind) []const u8 {
        return @tagName(self);
    }
};

pub const OperationStatus = enum {
    ok,
    warning,
    blocked,

    pub fn label(self: OperationStatus) []const u8 {
        return @tagName(self);
    }
};

pub const GraphOperationSummary = struct {
    operation: OperationKind,
    status: OperationStatus = .ok,
    graph_uuid: ?[16]u8 = null,
    items_processed: u64 = 0,
    bytes_processed: u64 = 0,
    issue_count: u64 = 0,
    changed: bool = false,

    pub fn writeJsonFields(self: *const GraphOperationSummary, writer: anytype) !void {
        try writer.print(
            "\"operation\":\"{s}\",\"status\":\"{s}\",\"items_processed\":{d},\"bytes_processed\":{d},\"issue_count\":{d},\"changed\":{}",
            .{
                self.operation.label(),
                self.status.label(),
                self.items_processed,
                self.bytes_processed,
                self.issue_count,
                self.changed,
            },
        );
        try writer.writeAll(",\"graph_uuid\":");
        if (self.graph_uuid) |uuid| {
            try writer.writeByte('"');
            try writeUuidHex(writer, uuid);
            try writer.writeByte('"');
        } else {
            try writer.writeAll("null");
        }
    }
};

pub fn writeUuidHex(writer: anytype, graph_uuid: [16]u8) !void {
    for (graph_uuid) |byte| {
        try writer.print("{x:0>2}", .{byte});
    }
}
