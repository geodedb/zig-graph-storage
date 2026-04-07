// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Reusable test data seeder that generates a realistic enterprise
//! identity/security graph matching the Geode data model.
//!
//! The seeder creates nodes (User, Device, Application, Group, Site,
//! Location, Drive, DriveItem, IPAddress) and edges (MEMBER_OF,
//! LOGGED_INTO, SIGNED_IN_FROM, SIGNED_IN_TO, CONTAINS, LOCATED_AT)
//! with realistic property values.
//!
//! Usage:
//! ```zig
//! const seed = @import("seed");
//! const result = try seed.populate(engine, .{ .users = 10, .devices = 20 });
//! ```

const std = @import("std");
const gs = @import("graph_storage");

const GraphEngine = gs.GraphEngine;
const NodeRec = gs.node.NodeRec;
const NodeId = gs.NodeId;
const EdgeId = gs.EdgeId;
const LabelId = gs.LabelId;
const PropertyValue = gs.PropertyValue;
const TxnId = gs.TxnId;

// ============================================================================
// Configuration
// ============================================================================

pub const SeedConfig = struct {
    // Node counts per type
    users: u32 = 100,
    devices: u32 = 200,
    applications: u32 = 50,
    groups: u32 = 30,
    sites: u32 = 10,
    locations: u32 = 20,
    drives: u32 = 50,
    drive_items: u32 = 500,
    ip_addresses: u32 = 100,

    // Edge density
    memberships_per_user: u32 = 3, // MEMBER_OF edges
    devices_per_user: u32 = 2, // LOGGED_INTO edges
    signins_per_user: u32 = 5, // SIGNED_IN_FROM + SIGNED_IN_TO
    items_per_drive: u32 = 10, // CONTAINS edges

    // Random seed for reproducibility
    random_seed: u64 = 42,

    /// Small config suitable for fast integration tests.
    pub fn tiny() SeedConfig {
        return .{
            .users = 10,
            .devices = 20,
            .applications = 5,
            .groups = 5,
            .sites = 2,
            .locations = 3,
            .drives = 5,
            .drive_items = 30,
            .ip_addresses = 10,
            .memberships_per_user = 2,
            .devices_per_user = 1,
            .signins_per_user = 2,
            .items_per_drive = 3,
            .random_seed = 42,
        };
    }

    /// Small scale profile (~50K entities).
    pub fn small() SeedConfig {
        return .{
            .users = 1_000,
            .devices = 2_000,
            .applications = 500,
            .groups = 200,
            .sites = 50,
            .locations = 100,
            .drives = 500,
            .drive_items = 10_000,
            .ip_addresses = 500,
            .memberships_per_user = 3,
            .devices_per_user = 2,
            .signins_per_user = 5,
            .items_per_drive = 10,
            .random_seed = 42,
        };
    }

    /// Medium scale profile (~500K entities).
    pub fn medium() SeedConfig {
        return .{
            .users = 10_000,
            .devices = 20_000,
            .applications = 5_000,
            .groups = 2_000,
            .sites = 500,
            .locations = 1_000,
            .drives = 5_000,
            .drive_items = 100_000,
            .ip_addresses = 5_000,
            .memberships_per_user = 3,
            .devices_per_user = 2,
            .signins_per_user = 5,
            .items_per_drive = 10,
            .random_seed = 42,
        };
    }

    /// Large scale profile (~2.5M entities).
    pub fn large() SeedConfig {
        return .{
            .users = 50_000,
            .devices = 100_000,
            .applications = 25_000,
            .groups = 5_000,
            .sites = 2_500,
            .locations = 5_000,
            .drives = 25_000,
            .drive_items = 500_000,
            .ip_addresses = 25_000,
            .memberships_per_user = 3,
            .devices_per_user = 2,
            .signins_per_user = 5,
            .items_per_drive = 10,
            .random_seed = 42,
        };
    }

    /// Total expected node count.
    pub fn totalNodes(self: SeedConfig) u64 {
        return @as(u64, self.users) +
            @as(u64, self.devices) +
            @as(u64, self.applications) +
            @as(u64, self.groups) +
            @as(u64, self.sites) +
            @as(u64, self.locations) +
            @as(u64, self.drives) +
            @as(u64, self.drive_items) +
            @as(u64, self.ip_addresses);
    }

    /// Total expected edge count (approximate).
    pub fn totalEdges(self: SeedConfig) u64 {
        const user_edges = @as(u64, self.users) *
            (@as(u64, self.memberships_per_user) +
                @as(u64, self.devices_per_user) +
                @as(u64, self.signins_per_user));
        const drive_edges = @as(u64, self.drives) * @as(u64, self.items_per_drive);
        return user_edges + drive_edges;
    }
};

// ============================================================================
// Labels -- mirrors Geode node types
// ============================================================================

pub const Labels = struct {
    user: LabelId,
    device: LabelId,
    application: LabelId,
    group: LabelId,
    site: LabelId,
    location: LabelId,
    drive: LabelId,
    drive_item: LabelId,
    ip_address: LabelId,
};

// ============================================================================
// Relationship types -- mirrors Geode edge types
// ============================================================================

pub const RelType = struct {
    pub const MEMBER_OF: u32 = 1;
    pub const LOGGED_INTO: u32 = 2;
    pub const SIGNED_IN_FROM: u32 = 3;
    pub const SIGNED_IN_TO: u32 = 4;
    pub const CONTAINS: u32 = 5;
    pub const LOCATED_AT: u32 = 6;
    pub const OWNS: u32 = 7;
    pub const RISK_DETECTED: u32 = 8;
};

// ============================================================================
// Seed result
// ============================================================================

pub const NodeRange = struct {
    start: NodeId,
    end: NodeId, // exclusive

    pub fn count(self: NodeRange) u64 {
        return self.end - self.start;
    }
};

pub const SeedResult = struct {
    node_count: u64,
    edge_count: u64,
    property_count: u64,
    labels: Labels,

    // Node ID ranges for each type (start inclusive, end exclusive)
    users: NodeRange,
    devices: NodeRange,
    applications: NodeRange,
    groups: NodeRange,
    sites: NodeRange,
    locations: NodeRange,
    drives: NodeRange,
    drive_items: NodeRange,
    ip_addresses: NodeRange,
};

const MutationBatch = struct {
    engine: *GraphEngine,
    limit: u32,
    txn: ?TxnId = null,
    used: u32 = 0,

    fn init(engine: *GraphEngine, limit: u32) MutationBatch {
        return .{
            .engine = engine,
            .limit = limit,
        };
    }

    fn acquire(self: *MutationBatch) !TxnId {
        if (self.txn == null or self.used >= self.limit) {
            try self.flush();
            self.txn = try self.engine.beginTxn();
            self.used = 0;
        }

        self.used += 1;
        return self.txn.?;
    }

    fn flush(self: *MutationBatch) !void {
        if (self.txn) |txn| {
            try self.engine.commitTxn(txn);
            self.txn = null;
            self.used = 0;
        }
    }

    fn deinit(self: *MutationBatch) void {
        if (self.txn) |txn| {
            self.engine.abortTxn(txn) catch {};
            self.txn = null;
            self.used = 0;
        }
    }
};

// ============================================================================
// Trust levels and network zones (Geode common properties)
// ============================================================================

const trust_levels = [_][]const u8{ "unknown", "low", "medium", "high" };
const net_zones = [_][]const u8{ "unknown", "internal", "external", "dmz" };
const departments = [_][]const u8{ "Engineering", "Sales", "Marketing", "Finance", "HR", "Legal", "IT", "Operations" };
const job_titles = [_][]const u8{ "Engineer", "Manager", "Director", "VP", "Analyst", "Admin", "Architect", "Lead" };

// ============================================================================
// Seeder implementation
// ============================================================================

/// Populate the given engine with a realistic enterprise identity graph.
///
/// Returns a `SeedResult` describing all created entities for test assertions.
pub fn populate(engine: *GraphEngine, cfg: SeedConfig) !SeedResult {
    var rng = std.Random.DefaultPrng.init(cfg.random_seed);
    const random = rng.random();

    // 1. Register labels via the label dictionary
    const labels = Labels{
        .user = try engine.getOrAssignLabel("User"),
        .device = try engine.getOrAssignLabel("Device"),
        .application = try engine.getOrAssignLabel("Application"),
        .group = try engine.getOrAssignLabel("Group"),
        .site = try engine.getOrAssignLabel("Site"),
        .location = try engine.getOrAssignLabel("Location"),
        .drive = try engine.getOrAssignLabel("Drive"),
        .drive_item = try engine.getOrAssignLabel("DriveItem"),
        .ip_address = try engine.getOrAssignLabel("IPAddress"),
    };

    var total_edges: u64 = 0;
    var total_props: u64 = 0;
    var node_batch = MutationBatch.init(engine, 128);
    defer node_batch.deinit();

    // 2. Create nodes for each type
    // Track the first NodeId for each type so we can compute ranges.
    // Nodes are allocated sequentially by allocNode().

    const user_start = try createNodes(engine, &node_batch, cfg.users, labels.user, "user", random, &total_props);
    const device_start = try createNodes(engine, &node_batch, cfg.devices, labels.device, "device", random, &total_props);
    const app_start = try createNodes(engine, &node_batch, cfg.applications, labels.application, "application", random, &total_props);
    const group_start = try createNodes(engine, &node_batch, cfg.groups, labels.group, "group", random, &total_props);
    const site_start = try createNodes(engine, &node_batch, cfg.sites, labels.site, "site", random, &total_props);
    const location_start = try createNodes(engine, &node_batch, cfg.locations, labels.location, "location", random, &total_props);
    const drive_start = try createNodes(engine, &node_batch, cfg.drives, labels.drive, "drive", random, &total_props);
    const drive_item_start = try createNodes(engine, &node_batch, cfg.drive_items, labels.drive_item, "drive_item", random, &total_props);
    const ip_start = try createNodes(engine, &node_batch, cfg.ip_addresses, labels.ip_address, "ip_address", random, &total_props);
    try node_batch.flush();

    // Compute end markers (exclusive)
    const user_end = user_start + @as(u64, cfg.users);
    const device_end = device_start + @as(u64, cfg.devices);
    const app_end = app_start + @as(u64, cfg.applications);
    const group_end = group_start + @as(u64, cfg.groups);
    const location_end = location_start + @as(u64, cfg.locations);
    const drive_end = drive_start + @as(u64, cfg.drives);
    const drive_item_end = drive_item_start + @as(u64, cfg.drive_items);
    const ip_end = ip_start + @as(u64, cfg.ip_addresses);

    // 3. Create edges following realistic patterns
    var edge_batch = MutationBatch.init(engine, 256);
    defer edge_batch.deinit();

    // MEMBER_OF: User -> Group
    if (cfg.groups > 0) {
        for (0..cfg.users) |i| {
            const user_id = user_start + @as(u64, @intCast(i));
            for (0..cfg.memberships_per_user) |j| {
                const group_idx = (i + j) % cfg.groups;
                const group_id = group_start + @as(u64, @intCast(group_idx));
                const txn = try edge_batch.acquire();
                _ = try engine.addEdgeTxn(user_id, group_id, RelType.MEMBER_OF, txn);
                total_edges += 1;
            }
        }
    }

    // LOGGED_INTO: User -> Device
    if (cfg.devices > 0) {
        for (0..cfg.users) |i| {
            const user_id = user_start + @as(u64, @intCast(i));
            for (0..cfg.devices_per_user) |j| {
                const dev_idx = (i * 2 + j) % cfg.devices;
                const dev_id = device_start + @as(u64, @intCast(dev_idx));
                const txn = try edge_batch.acquire();
                _ = try engine.addEdgeTxn(user_id, dev_id, RelType.LOGGED_INTO, txn);
                total_edges += 1;
            }
        }
    }

    // SIGNED_IN_FROM: User -> IPAddress  (half the signins)
    // SIGNED_IN_TO: User -> Application  (other half)
    if (cfg.ip_addresses > 0 and cfg.applications > 0) {
        for (0..cfg.users) |i| {
            const user_id = user_start + @as(u64, @intCast(i));
            const from_count = cfg.signins_per_user / 2;
            const to_count = cfg.signins_per_user - from_count;

            for (0..from_count) |j| {
                const ip_idx = (i + j * 3) % cfg.ip_addresses;
                const ip_id = ip_start + @as(u64, @intCast(ip_idx));
                const txn = try edge_batch.acquire();
                _ = try engine.addEdgeTxn(user_id, ip_id, RelType.SIGNED_IN_FROM, txn);
                total_edges += 1;
            }

            for (0..to_count) |j| {
                const app_idx = (i + j * 7) % cfg.applications;
                const app_id = app_start + @as(u64, @intCast(app_idx));
                const txn = try edge_batch.acquire();
                _ = try engine.addEdgeTxn(user_id, app_id, RelType.SIGNED_IN_TO, txn);
                total_edges += 1;
            }
        }
    }

    // CONTAINS: Drive -> DriveItem
    if (cfg.drive_items > 0 and cfg.drives > 0) {
        var item_cursor: u32 = 0;
        for (0..cfg.drives) |i| {
            const drive_id = drive_start + @as(u64, @intCast(i));
            for (0..cfg.items_per_drive) |_| {
                if (item_cursor >= cfg.drive_items) break;
                const item_id = drive_item_start + @as(u64, item_cursor);
                const txn = try edge_batch.acquire();
                _ = try engine.addEdgeTxn(drive_id, item_id, RelType.CONTAINS, txn);
                total_edges += 1;
                item_cursor += 1;
            }
        }
    }

    // LOCATED_AT: Device -> Location (each device at one location)
    if (cfg.locations > 0) {
        for (0..cfg.devices) |i| {
            const dev_id = device_start + @as(u64, @intCast(i));
            const loc_idx = i % cfg.locations;
            const loc_id = location_start + @as(u64, @intCast(loc_idx));
            const txn = try edge_batch.acquire();
            _ = try engine.addEdgeTxn(dev_id, loc_id, RelType.LOCATED_AT, txn);
            total_edges += 1;
        }
    }
    try edge_batch.flush();

    const total_nodes = cfg.totalNodes();

    return SeedResult{
        .node_count = total_nodes,
        .edge_count = total_edges,
        .property_count = total_props,
        .labels = labels,
        .users = .{ .start = user_start, .end = user_end },
        .devices = .{ .start = device_start, .end = device_end },
        .applications = .{ .start = app_start, .end = app_end },
        .groups = .{ .start = group_start, .end = group_end },
        .sites = .{ .start = site_start, .end = site_start + @as(u64, cfg.sites) },
        .locations = .{ .start = location_start, .end = location_end },
        .drives = .{ .start = drive_start, .end = drive_end },
        .drive_items = .{ .start = drive_item_start, .end = drive_item_end },
        .ip_addresses = .{ .start = ip_start, .end = ip_end },
    };
}

/// Create `count` nodes of the given kind, assign the label, and set
/// common properties (display_name, node_kind, trust_level, net_zone).
///
/// Returns the NodeId of the first allocated node.
fn createNodes(
    engine: *GraphEngine,
    batch: *MutationBatch,
    count: u32,
    label: LabelId,
    kind: []const u8,
    random: std.Random,
    total_props: *u64,
) !NodeId {
    if (count == 0) return engine.manifest.next_node_id;

    const first_id = try createNode(engine, batch, label, kind, 0, random, total_props);

    var i: u32 = 1;
    while (i < count) : (i += 1) {
        _ = try createNode(engine, batch, label, kind, i, random, total_props);
    }

    return first_id;
}

fn createNode(
    engine: *GraphEngine,
    batch: *MutationBatch,
    label: LabelId,
    kind: []const u8,
    index: u32,
    random: std.Random,
    total_props: *u64,
) !NodeId {
    const txn = try batch.acquire();
    const node_id = try engine.allocNode();
    var rec = makeNode(label);
    try engine.putNodeTxn(node_id, rec, txn);
    try engine.addLabelTxn(node_id, label, txn);
    try setNodePropertiesTxn(engine, node_id, &rec, kind, index, random, total_props, txn);
    return node_id;
}

/// Create a NodeRec with no labels (labels are added via engine.addLabel).
fn makeNode(label: LabelId) NodeRec {
    _ = label;
    return NodeRec{
        .out_head = 0,
        .in_head = 0,
        .prop_head = 0,
        .label_head = 0,
        .label_count = 0,
        .flags = 0,
        ._pad = .{ 0, 0, 0, 0 },
        .txn_stamp = 1,
    };
}

/// Set common properties on a node: display_name, node_kind, trust_level, net_zone.
fn setNodePropertiesTxn(
    engine: *GraphEngine,
    node_id: NodeId,
    rec: *NodeRec,
    kind: []const u8,
    index: u32,
    random: std.Random,
    total_props: *u64,
    txn: TxnId,
) !void {
    // Build display_name like "user_0042"
    var name_buf: [64]u8 = undefined;
    const display_name = std.fmt.bufPrint(&name_buf, "{s}_{d:0>4}", .{ kind, index }) catch "unknown";

    var prop_head = rec.prop_head;

    // display_name
    prop_head = try engine.putPropertyTxn(prop_head, "display_name", PropertyValue{ .string = display_name }, txn);
    total_props.* += 1;

    // node_kind
    prop_head = try engine.putPropertyTxn(prop_head, "node_kind", PropertyValue{ .string = kind }, txn);
    total_props.* += 1;

    // trust_level
    const tl = trust_levels[random.intRangeAtMost(usize, 0, trust_levels.len - 1)];
    prop_head = try engine.putPropertyTxn(prop_head, "trust_level", PropertyValue{ .string = tl }, txn);
    total_props.* += 1;

    // net_zone
    const nz = net_zones[random.intRangeAtMost(usize, 0, net_zones.len - 1)];
    prop_head = try engine.putPropertyTxn(prop_head, "net_zone", PropertyValue{ .string = nz }, txn);
    total_props.* += 1;

    // Write back prop_head
    rec.prop_head = prop_head;
    try engine.putNodeTxn(node_id, rec.*, txn);
}

// ============================================================================
// Unit-level tests for the seed module itself
// ============================================================================

test "SeedConfig.totalNodes returns correct sum" {
    const cfg = SeedConfig.tiny();
    const expected: u64 = 10 + 20 + 5 + 5 + 2 + 3 + 5 + 30 + 10;
    try std.testing.expectEqual(expected, cfg.totalNodes());
}

test "SeedConfig.totalEdges returns correct estimate" {
    const cfg = SeedConfig.tiny();
    // users*(memberships + devices + signins) + drives*items
    const user_edges: u64 = 10 * (2 + 1 + 2);
    const drive_edges: u64 = 5 * 3;
    try std.testing.expectEqual(user_edges + drive_edges, cfg.totalEdges());
}

test "SeedConfig presets have valid values" {
    const tiny = SeedConfig.tiny();
    try std.testing.expect(tiny.totalNodes() > 0);
    try std.testing.expect(tiny.totalEdges() > 0);

    const small = SeedConfig.small();
    try std.testing.expect(small.totalNodes() > tiny.totalNodes());

    const medium = SeedConfig.medium();
    try std.testing.expect(medium.totalNodes() > small.totalNodes());

    const large = SeedConfig.large();
    try std.testing.expect(large.totalNodes() > medium.totalNodes());
}

test "NodeRange.count works" {
    const r = NodeRange{ .start = 5, .end = 15 };
    try std.testing.expectEqual(@as(u64, 10), r.count());
}
