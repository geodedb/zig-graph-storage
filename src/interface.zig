// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const types = @import("types.zig");
const metrics_mod = @import("metrics.zig");
const node_mod = @import("node.zig");
const edge_mod = @import("edge.zig");

const Allocator = std.mem.Allocator;
const NodeId = types.NodeId;
const EdgeId = types.EdgeId;
const PageId = types.PageId;
const Lsn = types.Lsn;
const TxnId = types.TxnId;
const LabelId = types.LabelId;
const PropertyValue = types.PropertyValue;
const Metrics = metrics_mod.Metrics;
const NodeRec = node_mod.NodeRec;
const EdgeEntry = edge_mod.EdgeEntry;

pub const PropertyEntry = struct {
    key: []const u8,
    value: PropertyValue,
};

pub const GraphStorage = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Node operations
        getNode: *const fn (ptr: *anyopaque, id: NodeId) anyerror!?NodeRec,
        putNode: *const fn (ptr: *anyopaque, id: NodeId, rec: NodeRec) anyerror!void,
        allocNode: *const fn (ptr: *anyopaque) anyerror!NodeId,
        deleteNode: *const fn (ptr: *anyopaque, id: NodeId) anyerror!void,
        // Edge operations
        getEdge: *const fn (ptr: *anyopaque, edge_id: EdgeId) anyerror!?EdgeEntry,
        expandOut: *const fn (ptr: *anyopaque, id: NodeId, rel_type: ?u32, allocator: Allocator) anyerror![]EdgeEntry,
        expandIn: *const fn (ptr: *anyopaque, id: NodeId, rel_type: ?u32, allocator: Allocator) anyerror![]EdgeEntry,
        addEdge: *const fn (ptr: *anyopaque, from: NodeId, to: NodeId, rel_type: u32) anyerror!EdgeId,
        removeEdge: *const fn (ptr: *anyopaque, from: NodeId, to: NodeId, edge_id: EdgeId) anyerror!void,
        // Properties (caller-owned return slices; caller must free)
        getProperty: *const fn (ptr: *anyopaque, prop_head: u64, key: []const u8, allocator: Allocator) anyerror!?PropertyValue,
        getAllProperties: *const fn (ptr: *anyopaque, prop_head: u64, allocator: Allocator) anyerror![]PropertyEntry,
        putProperty: *const fn (ptr: *anyopaque, owner: u64, key: []const u8, val: PropertyValue) anyerror!u64,
        removeProperty: *const fn (ptr: *anyopaque, owner: u64, key: []const u8) anyerror!void,
        // Labels
        addLabel: *const fn (ptr: *anyopaque, node_id: NodeId, label: LabelId) anyerror!void,
        removeLabel: *const fn (ptr: *anyopaque, node_id: NodeId, label: LabelId) anyerror!void,
        scanLabel: *const fn (ptr: *anyopaque, label: LabelId, allocator: Allocator) anyerror![]NodeId,
        // Transactions
        beginTxn: *const fn (ptr: *anyopaque) anyerror!TxnId,
        commitTxn: *const fn (ptr: *anyopaque, txn: TxnId) anyerror!void,
        abortTxn: *const fn (ptr: *anyopaque, txn: TxnId) anyerror!void,
        // Stats
        nodeCount: *const fn (ptr: *anyopaque) anyerror!u64,
        edgeCount: *const fn (ptr: *anyopaque) anyerror!u64,
        // Metrics / observability
        getMetrics: *const fn (ptr: *anyopaque) *const Metrics,
        // Lifecycle
        checkpoint: *const fn (ptr: *anyopaque) anyerror!void,
        close: *const fn (ptr: *anyopaque) anyerror!void,
    };

    // Convenience methods that delegate to vtable
    pub fn getNode(self: GraphStorage, id: NodeId) anyerror!?NodeRec {
        return self.vtable.getNode(self.ptr, id);
    }
    pub fn putNode(self: GraphStorage, id: NodeId, rec: NodeRec) anyerror!void {
        return self.vtable.putNode(self.ptr, id, rec);
    }
    pub fn allocNode(self: GraphStorage) anyerror!NodeId {
        return self.vtable.allocNode(self.ptr);
    }
    pub fn deleteNode(self: GraphStorage, id: NodeId) anyerror!void {
        return self.vtable.deleteNode(self.ptr, id);
    }
    pub fn getEdge(self: GraphStorage, edge_id: EdgeId) anyerror!?EdgeEntry {
        return self.vtable.getEdge(self.ptr, edge_id);
    }
    pub fn expandOut(self: GraphStorage, id: NodeId, rel_type: ?u32, allocator: Allocator) anyerror![]EdgeEntry {
        return self.vtable.expandOut(self.ptr, id, rel_type, allocator);
    }
    pub fn expandIn(self: GraphStorage, id: NodeId, rel_type: ?u32, allocator: Allocator) anyerror![]EdgeEntry {
        return self.vtable.expandIn(self.ptr, id, rel_type, allocator);
    }
    pub fn addEdge(self: GraphStorage, from: NodeId, to: NodeId, rel_type: u32) anyerror!EdgeId {
        return self.vtable.addEdge(self.ptr, from, to, rel_type);
    }
    pub fn removeEdge(self: GraphStorage, from: NodeId, to: NodeId, edge_id: EdgeId) anyerror!void {
        return self.vtable.removeEdge(self.ptr, from, to, edge_id);
    }
    pub fn getProperty(self: GraphStorage, prop_head: u64, key: []const u8, allocator: Allocator) anyerror!?PropertyValue {
        return self.vtable.getProperty(self.ptr, prop_head, key, allocator);
    }
    pub fn getAllProperties(self: GraphStorage, prop_head: u64, allocator: Allocator) anyerror![]PropertyEntry {
        return self.vtable.getAllProperties(self.ptr, prop_head, allocator);
    }
    pub fn putProperty(self: GraphStorage, owner: u64, key: []const u8, val: PropertyValue) anyerror!u64 {
        return self.vtable.putProperty(self.ptr, owner, key, val);
    }
    pub fn removeProperty(self: GraphStorage, owner: u64, key: []const u8) anyerror!void {
        return self.vtable.removeProperty(self.ptr, owner, key);
    }
    pub fn addLabel(self: GraphStorage, node_id: NodeId, label: LabelId) anyerror!void {
        return self.vtable.addLabel(self.ptr, node_id, label);
    }
    pub fn removeLabel(self: GraphStorage, node_id: NodeId, label: LabelId) anyerror!void {
        return self.vtable.removeLabel(self.ptr, node_id, label);
    }
    pub fn scanLabel(self: GraphStorage, label: LabelId, allocator: Allocator) anyerror![]NodeId {
        return self.vtable.scanLabel(self.ptr, label, allocator);
    }
    pub fn beginTxn(self: GraphStorage) anyerror!TxnId {
        return self.vtable.beginTxn(self.ptr);
    }
    pub fn commitTxn(self: GraphStorage, txn: TxnId) anyerror!void {
        return self.vtable.commitTxn(self.ptr, txn);
    }
    pub fn abortTxn(self: GraphStorage, txn: TxnId) anyerror!void {
        return self.vtable.abortTxn(self.ptr, txn);
    }
    pub fn nodeCount(self: GraphStorage) anyerror!u64 {
        return self.vtable.nodeCount(self.ptr);
    }
    pub fn edgeCount(self: GraphStorage) anyerror!u64 {
        return self.vtable.edgeCount(self.ptr);
    }
    pub fn getMetrics(self: GraphStorage) *const Metrics {
        return self.vtable.getMetrics(self.ptr);
    }
    pub fn doCheckpoint(self: GraphStorage) anyerror!void {
        return self.vtable.checkpoint(self.ptr);
    }
    pub fn close(self: GraphStorage) anyerror!void {
        return self.vtable.close(self.ptr);
    }

    /// Helper to create a GraphStorage from a typed implementation pointer.
    /// The implementation type T must have methods matching the vtable signatures.
    pub fn init(comptime T: type, impl: *T) GraphStorage {
        return .{
            .ptr = @ptrCast(impl),
            .vtable = &comptime .{
                .getNode = typeErasedFn(T, "getNode"),
                .putNode = typeErasedFn(T, "putNode"),
                .allocNode = typeErasedFn(T, "allocNode"),
                .deleteNode = typeErasedFn(T, "deleteNode"),
                .getEdge = typeErasedFn(T, "getEdge"),
                .expandOut = typeErasedFn(T, "expandOut"),
                .expandIn = typeErasedFn(T, "expandIn"),
                .addEdge = typeErasedFn(T, "addEdge"),
                .removeEdge = typeErasedFn(T, "removeEdge"),
                .getProperty = typeErasedFn(T, "getProperty"),
                .getAllProperties = typeErasedFn(T, "getAllProperties"),
                .putProperty = typeErasedFn(T, "putProperty"),
                .removeProperty = typeErasedFn(T, "removeProperty"),
                .addLabel = typeErasedFn(T, "addLabel"),
                .removeLabel = typeErasedFn(T, "removeLabel"),
                .scanLabel = typeErasedFn(T, "scanLabel"),
                .beginTxn = typeErasedFn(T, "beginTxn"),
                .commitTxn = typeErasedFn(T, "commitTxn"),
                .abortTxn = typeErasedFn(T, "abortTxn"),
                .nodeCount = typeErasedFn(T, "nodeCount"),
                .edgeCount = typeErasedFn(T, "edgeCount"),
                .getMetrics = typeErasedFn(T, "getMetrics"),
                .checkpoint = typeErasedFn(T, "checkpoint"),
                .close = typeErasedFn(T, "close"),
            },
        };
    }

    /// Comptime helper that generates a type-erased wrapper function for a vtable method.
    /// Casts `*anyopaque` back to `*T` and forwards the call to `T.<method_name>`.
    fn vtableFieldType(comptime field_name: []const u8) type {
        @setEvalBranchQuota(5000);
        for (std.meta.fields(VTable)) |f| {
            if (std.mem.eql(u8, f.name, field_name)) return f.type;
        }
        @compileError("Unknown vtable field: " ++ field_name);
    }

    fn typeErasedFn(comptime T: type, comptime method_name: []const u8) vtableFieldType(method_name) {
        const Wrapper = struct {
            fn getNodeFn(ptr: *anyopaque, id: NodeId) anyerror!?NodeRec {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{ self, id });
            }
            fn putNodeFn(ptr: *anyopaque, id: NodeId, rec: NodeRec) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{ self, id, rec });
            }
            fn allocNodeFn(ptr: *anyopaque) anyerror!NodeId {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{self});
            }
            fn deleteNodeFn(ptr: *anyopaque, id: NodeId) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{ self, id });
            }
            fn getEdgeFn(ptr: *anyopaque, edge_id: EdgeId) anyerror!?EdgeEntry {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{ self, edge_id });
            }
            fn expandOutFn(ptr: *anyopaque, id: NodeId, rel_type: ?u32, allocator: Allocator) anyerror![]EdgeEntry {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{ self, id, rel_type, allocator });
            }
            fn expandInFn(ptr: *anyopaque, id: NodeId, rel_type: ?u32, allocator: Allocator) anyerror![]EdgeEntry {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{ self, id, rel_type, allocator });
            }
            fn addEdgeFn(ptr: *anyopaque, from: NodeId, to: NodeId, rel_type: u32) anyerror!EdgeId {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{ self, from, to, rel_type });
            }
            fn removeEdgeFn(ptr: *anyopaque, from: NodeId, to: NodeId, edge_id: EdgeId) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{ self, from, to, edge_id });
            }
            fn getPropertyFn(ptr: *anyopaque, prop_head: u64, key: []const u8, allocator: Allocator) anyerror!?PropertyValue {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{ self, prop_head, key, allocator });
            }
            fn getAllPropertiesFn(ptr: *anyopaque, prop_head: u64, allocator: Allocator) anyerror![]PropertyEntry {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{ self, prop_head, allocator });
            }
            fn putPropertyFn(ptr: *anyopaque, owner: u64, key: []const u8, val: PropertyValue) anyerror!u64 {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{ self, owner, key, val });
            }
            fn removePropertyFn(ptr: *anyopaque, owner: u64, key: []const u8) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{ self, owner, key });
            }
            fn addLabelFn(ptr: *anyopaque, node_id: NodeId, label: LabelId) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{ self, node_id, label });
            }
            fn removeLabelFn(ptr: *anyopaque, node_id: NodeId, label: LabelId) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{ self, node_id, label });
            }
            fn scanLabelFn(ptr: *anyopaque, label: LabelId, allocator: Allocator) anyerror![]NodeId {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{ self, label, allocator });
            }
            fn beginTxnFn(ptr: *anyopaque) anyerror!TxnId {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{self});
            }
            fn commitTxnFn(ptr: *anyopaque, txn: TxnId) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{ self, txn });
            }
            fn abortTxnFn(ptr: *anyopaque, txn: TxnId) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{ self, txn });
            }
            fn nodeCountFn(ptr: *anyopaque) anyerror!u64 {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{self});
            }
            fn edgeCountFn(ptr: *anyopaque) anyerror!u64 {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{self});
            }
            fn getMetricsFn(ptr: *anyopaque) *const Metrics {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{self});
            }
            fn checkpointFn(ptr: *anyopaque) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{self});
            }
            fn closeFn(ptr: *anyopaque) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(T, method_name), .{self});
            }
        };

        // Map method names to wrapper functions
        const map = .{
            .{ "getNode", Wrapper.getNodeFn },
            .{ "putNode", Wrapper.putNodeFn },
            .{ "allocNode", Wrapper.allocNodeFn },
            .{ "deleteNode", Wrapper.deleteNodeFn },
            .{ "getEdge", Wrapper.getEdgeFn },
            .{ "expandOut", Wrapper.expandOutFn },
            .{ "expandIn", Wrapper.expandInFn },
            .{ "addEdge", Wrapper.addEdgeFn },
            .{ "removeEdge", Wrapper.removeEdgeFn },
            .{ "getProperty", Wrapper.getPropertyFn },
            .{ "getAllProperties", Wrapper.getAllPropertiesFn },
            .{ "putProperty", Wrapper.putPropertyFn },
            .{ "removeProperty", Wrapper.removePropertyFn },
            .{ "addLabel", Wrapper.addLabelFn },
            .{ "removeLabel", Wrapper.removeLabelFn },
            .{ "scanLabel", Wrapper.scanLabelFn },
            .{ "beginTxn", Wrapper.beginTxnFn },
            .{ "commitTxn", Wrapper.commitTxnFn },
            .{ "abortTxn", Wrapper.abortTxnFn },
            .{ "nodeCount", Wrapper.nodeCountFn },
            .{ "edgeCount", Wrapper.edgeCountFn },
            .{ "getMetrics", Wrapper.getMetricsFn },
            .{ "checkpoint", Wrapper.checkpointFn },
            .{ "close", Wrapper.closeFn },
        };

        inline for (map) |entry| {
            if (std.mem.eql(u8, entry[0], method_name)) {
                return entry[1];
            }
        }
        @compileError("Unknown vtable method: " ++ method_name);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "VTable has exactly 24 method fields" {
    const fields = std.meta.fields(GraphStorage.VTable);
    try std.testing.expectEqual(@as(usize, 24), fields.len);
}

test "PropertyEntry can be constructed" {
    const entry = PropertyEntry{
        .key = "name",
        .value = PropertyValue{ .string = "Alice" },
    };
    try std.testing.expectEqualStrings("name", entry.key);
    try std.testing.expectEqualStrings("Alice", entry.value.string);
}

test "GraphStorage with mock vtable dispatches close" {
    const Mock = struct {
        closed: bool = false,

        fn closeFn(ptr: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.closed = true;
        }
    };

    const stub_vtable = GraphStorage.VTable{
        .getNode = undefined,
        .putNode = undefined,
        .allocNode = undefined,
        .deleteNode = undefined,
        .getEdge = undefined,
        .expandOut = undefined,
        .expandIn = undefined,
        .addEdge = undefined,
        .removeEdge = undefined,
        .getProperty = undefined,
        .getAllProperties = undefined,
        .putProperty = undefined,
        .removeProperty = undefined,
        .addLabel = undefined,
        .removeLabel = undefined,
        .scanLabel = undefined,
        .beginTxn = undefined,
        .commitTxn = undefined,
        .abortTxn = undefined,
        .nodeCount = undefined,
        .edgeCount = undefined,
        .getMetrics = undefined,
        .checkpoint = undefined,
        .close = Mock.closeFn,
    };

    var mock = Mock{};
    const gs = GraphStorage{
        .ptr = @ptrCast(&mock),
        .vtable = &stub_vtable,
    };

    try gs.close();
    try std.testing.expect(mock.closed);
}

test {
    std.testing.refAllDecls(@This());
}
