// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! SONNY-6524: the label dictionaries of a ShardedGraphEngine.
//!
//! Every shard keeps its own `labels.dict`. Shard 0 is the authority: it
//! chooses the id of a new name, and every id the facade hands out is shard
//! 0's. The other shards record the same (name, id) pairs.
//!
//! * `getOrAssignLabel` names a new label on shard 0 first (durable before
//!   anything else happens), then on shards 1..N-1 in parallel, each with
//!   shard 0's id. On disk every shard's dictionary is therefore a subset of
//!   shard 0's at every instant, whatever a crash interrupts.
//! * `reconcileAtOpen` brings shards 1..N-1 back to shard 0's dictionary at
//!   open: a shard missing names (a crash or a failed write part-way through
//!   a broadcast) is filled in; a shard that gives an id a different meaning
//!   (geode's old ORDER BY path named a label in shard 0's dictionary only,
//!   so the next name got a lower id on the other shards) is rewritten only
//!   when none of its records uses that id, and otherwise refused
//!   (`GraphConfig.label_dict_divergence`).

const std = @import("std");

const config_mod = @import("config.zig");
const engine_mod = @import("engine.zig");
const engine_persist = @import("engine_persist.zig");
const label_dict_mod = @import("label_dict.zig");
const sharded_engine_mod = @import("sharded_engine.zig");
const types = @import("types.zig");

const GraphEngine = engine_mod.GraphEngine;
const LabelDictionary = label_dict_mod.LabelDictionary;
const ShardedGraphEngine = sharded_engine_mod.ShardedGraphEngine;
const LabelId = types.LabelId;
const NodeId = types.NodeId;
const EdgeId = types.EdgeId;
const SHARD_COUNT = sharded_engine_mod.SHARD_COUNT;

/// One shard's share of a broadcast: record `name` under `id`.
const BroadcastWorker = struct {
    shard: *GraphEngine,
    index: usize,
    name: []const u8,
    id: LabelId,
    caller: std.Thread.Id,
    err: ?anyerror = null,

    fn run(w: *BroadcastWorker) void {
        sharded_engine_mod.label_broadcast_stats.record(w.caller);
        w.shard.assignLabelId(w.name, w.id) catch |e| {
            w.err = e;
        };
    }
};

/// See `ShardedGraphEngine.getOrAssignLabel`.
pub fn getOrAssignLabel(self: *ShardedGraphEngine, name: []const u8) !LabelId {
    // Shard 0 first: it chooses the id and its labels.dict is durable before
    // any other shard records the name.
    const id = try self.shards[0].getOrAssignLabel(name);

    var workers: [SHARD_COUNT]BroadcastWorker = undefined;
    var n: usize = 0;
    const caller = std.Thread.getCurrentId();
    for (self.shards[1..], 1..) |eng, k| {
        if (eng.label_dict.getId(name)) |have| {
            if (have != id) {
                std.log.warn("graph-storage: label '{s}' has id {d} on shard 0 but {d} on shard {d}; refusing to assign it (SONNY-6524)", .{ name, id, have, k });
                if (self.shards[0].config.label_dict_report) |r| r.emit(.{
                    .kind = .name_id_conflict,
                    .action = .refused,
                    .shard = @intCast(k),
                    .label_id = id,
                    .shard_label_id = have,
                    .label = name,
                });
                return error.LabelDictionaryDiverged;
            }
            continue;
        }
        workers[n] = .{ .shard = eng, .index = k, .name = name, .id = id, .caller = caller };
        n += 1;
    }
    if (n == 0) return id;

    // Shards 1..N-1 in parallel: one thread per shard still missing the
    // name, the caller doing the first itself. Each worker touches exactly
    // one shard engine (its label_dict, its graph directory, its dirty flag),
    // so no two workers share any state. The caller blocks here until every
    // worker has joined, so whatever serializes the caller's writes to this
    // graph is held across the whole parallel section, exactly as it was
    // across the old serial loop. A failed spawn runs that shard inline.
    var threads: [SHARD_COUNT]?std.Thread = [_]?std.Thread{null} ** SHARD_COUNT;
    for (workers[1..n], 1..) |*w, i| {
        threads[i] = std.Thread.spawn(.{}, BroadcastWorker.run, .{w}) catch null;
    }
    workers[0].run();
    for (workers[1..n], 1..) |*w, i| {
        if (threads[i]) |t| t.join() else w.run();
    }

    // Lowest shard index wins. Shards that failed left the name unassigned
    // in memory (GraphEngine.assignLabelId undoes it); shards that succeeded
    // keep shard 0's pair. A retry completes the missing shards with the
    // same id, and an open after a crash fills them in (reconcileAtOpen).
    for (workers[0..n]) |w| {
        const e = w.err orelse continue;
        if (e == error.LabelIdConflict) {
            // The name was absent on this shard (checked above), so the id
            // names a different label there.
            const other = w.shard.label_dict.getName(id) orelse "<no name>";
            std.log.warn("graph-storage: label '{s}' has id {d} on shard 0, but shard {d} gives id {d} to '{s}'; refusing to assign it (SONNY-6524)", .{ name, id, w.index, id, other });
            if (self.shards[0].config.label_dict_report) |r| r.emit(.{
                .kind = .id_name_conflict,
                .action = .refused,
                .shard = @intCast(w.index),
                .label_id = id,
                .shard_label_id = id,
                .label = name,
                .shard_label = w.shard.label_dict.getName(id),
            });
            return error.LabelDictionaryDiverged;
        }
        return e;
    }
    return id;
}

/// Records on one shard that carry a label id.
const Uses = struct {
    nodes: u64 = 0,
    edges: u64 = 0,
    indexes: u64 = 0,

    fn total(u: Uses) u64 {
        return u.nodes + u.edges + u.indexes;
    }
};

const EdgeCounter = struct {
    id: LabelId,
    n: u64 = 0,

    fn visit(c: *EdgeCounter, from: NodeId, rel_type: u32, to: NodeId, edge_id: EdgeId) anyerror!void {
        _ = from;
        _ = to;
        _ = edge_id;
        if (rel_type == c.id) c.n += 1;
    }
};

/// Nodes labelled `id`, edges typed `id` (on the shard that stores the edge,
/// its source's), and declared property / ordered indexes on label `id`.
fn countUses(eng: *GraphEngine, id: LabelId) !Uses {
    try eng.ensureDerivedHydrated();
    var u: Uses = .{ .nodes = eng.label_index.count(id) };
    var ec: EdgeCounter = .{ .id = id };
    try eng.edge_exist_index.forEachRecord(&ec, EdgeCounter.visit);
    u.edges = ec.n;
    for (eng.property_index_set.catalog.indexes.items) |d| {
        if (d.label_id == id) u.indexes += 1;
    }
    for (eng.ordered_property_index.entries.items) |e| {
        if (e.label_id == id) u.indexes += 1;
    }
    return u;
}

/// `a` and `b` hold exactly the same (name, id) pairs.
fn sameDict(a: *const LabelDictionary, b: *const LabelDictionary) bool {
    if (a.count() != b.count()) return false;
    var it = a.name_to_id.iterator();
    while (it.next()) |e| {
        const have = b.getId(e.key_ptr.*) orelse return false;
        if (have != e.value_ptr.*) return false;
    }
    return true;
}

/// Bring every shard's label dictionary to shard 0's at open. Runs after all
/// shards opened and before anything else writes; checks every shard before
/// it rewrites any, so a refusal changes nothing on disk.
///
/// After the rewrite, shard k's ids mean what shard 0's mean. The ids whose
/// meaning changes on shard k are those shard k names differently from
/// shard 0 or names while shard 0 does not; an id shard k does not name
/// gains shard 0's name, which is what the facade meant by it. If no record
/// on shard k uses a changing id the rewrite touches nothing but the
/// dictionary. If one does, renaming would change what that record says, so
/// the open is refused (`.reject`, default) or the caller's assertion that
/// shard 0's name is the right one is taken (`.adopt_shard0`).
///
/// SONNY-6527: every finding also goes to `report` (when set) as a
/// `LabelDictDiagnostic`, so a consumer whose release build filters
/// `std.log.warn` still gets the shard, id, both names and record counts.
pub fn reconcileAtOpen(
    self: *ShardedGraphEngine,
    policy: config_mod.LabelDictDivergencePolicy,
    report: ?config_mod.LabelDictReport,
) !void {
    const d0 = &self.shards[0].label_dict;
    var repair = [_]bool{false} ** SHARD_COUNT;
    var refused = false;

    for (self.shards[1..], 1..) |eng, k| {
        const dk = &eng.label_dict;
        if (sameDict(d0, dk)) continue;
        repair[k] = true;
        var it = dk.id_to_name.iterator();
        while (it.next()) |e| {
            const id = e.key_ptr.*;
            const name_k = e.value_ptr.*;
            const name_0 = d0.getName(id);
            if (name_0) |n0| {
                if (std.mem.eql(u8, n0, name_k)) continue;
            }
            const uses = try countUses(eng, id);
            if (uses.total() == 0) continue;
            const action = switch (policy) {
                .reject => "refusing to open",
                .adopt_shard0 => "renaming it from shard 0 (label_dict_divergence = .adopt_shard0)",
            };
            std.log.warn("graph-storage: shard {d} labels.dict names label id {d} '{s}' but shard 0 names it '{s}', and {d} node(s), {d} edge(s) and {d} index(es) on shard {d} use id {d}: {s} (SONNY-6524)", .{
                k, id, name_k, name_0 orelse "<no name>", uses.nodes, uses.edges, uses.indexes, k, id, action,
            });
            if (report) |r| r.emit(.{
                .kind = .id_in_use_diverged,
                .action = switch (policy) {
                    .reject => .refused,
                    .adopt_shard0 => .renamed_from_shard0,
                },
                .shard = @intCast(k),
                .label_id = id,
                .shard_label_id = id,
                .label = name_k,
                .shard0_label = name_0,
                .nodes = uses.nodes,
                .edges = uses.edges,
                .indexes = uses.indexes,
            });
            if (policy == .reject) refused = true;
        }
    }
    if (refused) return error.LabelDictionaryDiverged;

    for (self.shards[1..], 1..) |eng, k| {
        if (!repair[k]) continue;
        const before = eng.label_dict.count();
        var copy = try d0.clone(eng.allocator);
        std.mem.swap(LabelDictionary, &eng.label_dict, &copy);
        // `copy` now holds the shard's previous dictionary.
        if (!eng.read_only) {
            engine_persist.saveLabelDictionaryDurable(eng) catch |err| {
                std.mem.swap(LabelDictionary, &eng.label_dict, &copy);
                copy.deinit();
                return err;
            };
        }
        copy.deinit();
        std.log.warn("graph-storage: shard {d} labels.dict disagreed with shard 0 ({d} names vs {d}); rewrote it from shard 0{s} (SONNY-6524)", .{
            k, before, d0.count(), if (eng.read_only) " in memory only (read-only open)" else "",
        });
        if (report) |r| r.emit(.{
            .kind = .rewritten,
            .action = if (eng.read_only) .rewritten_in_memory else .rewritten,
            .shard = @intCast(k),
            .label_id = 0,
            .shard_label_id = 0,
            .shard_names = before,
            .shard0_names = d0.count(),
        });
    }
}
