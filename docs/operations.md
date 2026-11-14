# Operations Guide

Practical reference for operating the graph-storage engine in production.

---

## Opening and Creating a Graph Database

### First-time creation

```zig
const cfg = GraphConfig{
    .page_size = 8192,
    .encryption_key = my_key,   // optional, [32]u8
    .data_dir = "/var/data/graphs",
};
var uuid: [16]u8 = undefined;
std.crypto.random.bytes(&uuid);

var engine = try GraphEngine.create(allocator, cfg.data_dir, uuid, cfg);
defer engine.close() catch {};
```

`GraphEngine.create()` initializes the directory layout, creates empty store
files, writes the initial manifest, and returns a ready-to-use engine.

### Opening an existing graph

```zig
var engine = try GraphEngine.open(allocator, "/var/data/graphs", uuid, cfg);
defer engine.close() catch {};
```

`GraphEngine.open()` reads the manifest (A/B), runs crash recovery if needed,
rebuilds the label index, and loads the index catalog.

---

## Transactions

All mutations require an explicit transaction:

```zig
const txn = try engine.beginTxn();
try engine.putNode(txn, node_id, &rec);
try engine.commitTxn(txn);
```

If a transaction is not committed it will be discarded during recovery.

---

## Checkpoint

Checkpointing flushes dirty pages, syncs store files, and writes a fresh
manifest to the alternate A/B slot:

```zig
try engine.checkpoint();
```

Each step is durable before the next one starts (SONNY-6491):

1. Flush dirty pages and fsync the store files they went to.
2. Write `free.store` (temp file, fsync, rename) and fsync the graph
   directory.
3. Write the manifest to the alternate slot (temp file, fsync, rename) and
   fsync the graph directory.
4. Truncate the WAL up to the checkpoint LSN.
5. Full checkpoints only: save the derived-index snapshots, each stamped with
   the new `(checkpoint_epoch, covered_lsn)`; then the catalog and ordered
   indexes, then restamp the clean snapshots.

A crash before step 3 completes leaves the previous manifest and a WAL that
still covers everything (recovery replays it and discards a `free.store`
newer than the manifest whenever it applies a committed page). A crash after
it leaves the new manifest with a `free.store` at least as new. Snapshots
that a crash leaves behind the manifest are rejected by their stamp and
rebuilt. `labels.dict` is not written by a checkpoint: label assignment is
not WAL-logged, so `getOrAssignLabel` makes every new name durable (file
fsync, rename, directory fsync) before it returns its id. If that write
fails, the name is not kept in memory: the call fails and the next one
assigns and writes it again (SONNY-6524).

### Label dictionaries on a sharded store

Each shard of a `ShardedGraphEngine` keeps its own `labels.dict`; shard 0
chooses every id. `getOrAssignLabel` with a new name writes shard 0's
dictionary first, then the other shards' in parallel with shard 0's id, so
one new name costs about two durable writes in sequence rather than one per
shard (`zig build bench-label-assign`). On disk each shard's dictionary is a
subset of shard 0's whatever a crash interrupts. A shard whose write failed
is left without the name; retrying, or reopening, completes it.

`ShardedGraphEngine.open` compares every shard's dictionary with shard 0's
before anything else writes:

- a shard missing names shard 0 has (a crash or a failed write during a new
  name), or naming an id that none of its records uses differently from
  shard 0, has its `labels.dict` rewritten from shard 0's, with a warning;
- a shard that names an id differently from shard 0 while one of its nodes,
  edges or declared indexes carries that id makes the open fail with
  `error.LabelDictionaryDiverged`. The warning logged names the shard, the
  id, both names and the record counts; nothing on disk is changed. Stores
  split by geode's old ORDER BY path (a label named in shard 0's dictionary
  only, so the next name got a lower id on the other shards) take this path
  when the other shards hold records of the first label.
  `GraphConfig.label_dict_divergence = .adopt_shard0` instead rewrites the
  shard from shard 0. Use it only when every label id written to any shard
  came from shard 0 (`ShardedGraphEngine.getOrAssignLabel`, or names read
  from shard 0's dictionary), as in geode.

Every one of these findings, and a `getOrAssignLabel` refused because a
shard holds the name under another id or gives shard 0's id to another
name, is also handed to `GraphConfig.label_dict_report` when it is set: one
`LabelDictDiagnostic` per finding (kind, action, shard, id, the shard's and
shard 0's names, the node/edge/index counts, the name counts of a rewrite),
on the calling thread, before the call returns. The warnings go through
`std.log.warn`, which a release build's `log_level` can filter out; log the
diagnostics at the level the deployment needs (geode: ERROR for `refused`).

Releases up to 0.4.13 wrote the manifest and truncated the WAL before saving
`free.store` and `labels.dict`. A store that crashed in that window opens
with a bitmap older than its manifest; the open detects it when a store has
fewer allocated pages than the manifest recorded or a written node page below
the highest issued node id is unallocated, and then rebuilds the bitmaps from
the store files (freed pages read as allocated until reused). A bitmap that
is stale only in which pages it marks is not detected. Label names lost in
that window cannot be recovered: the open logs a warning when `labels.dict`
holds fewer names than the manifest counted.

Automatic checkpointing can be triggered by monitoring
`GraphConfig.checkpoint_byte_threshold` and
`GraphConfig.checkpoint_time_threshold_ms`. The engine does not run an
automatic checkpoint timer internally; the application is responsible for
calling `checkpoint()` at appropriate intervals.

---

## Backup and Restore

### Creating a backup

```zig
const backup_mod = @import("backup.zig");
var backup = backup_mod.Backup.init(allocator);
// Or with HMAC integrity protection:
// var backup = backup_mod.Backup.initWithKey(allocator, encryption_key);

const result = try backup.createBackup(&graph_dir, "/backups/graph.geob");
// result.files_backed_up, result.total_bytes
```

The backup format is a self-contained archive containing manifests, all store
files, label dictionary, and index catalog. When an encryption key is provided,
the backup uses version 2 with an HMAC-SHA256 integrity tag.

### Restoring from backup

```zig
backup.setExpectedGraphUuid(graph_uuid);
try backup.restoreBackup("/backups/graph.geob", "/var/data/restored");
```

Restore extracts all files to the target directory. After restore, open the
graph normally with `GraphEngine.open()`.

For legacy CRC-only version-1 archives, restore is disabled by default. Opt in
explicitly only when you are handling a known-trusted historical archive:

```zig
backup.setExpectedGraphUuid(graph_uuid);
backup.enableLegacyV1Restore();
try backup.restoreBackup("/backups/legacy-v1.geob", "/var/data/restored");
```

**Important:** Always checkpoint before creating a backup to ensure the backup
reflects the latest committed state.

---

## Crash Recovery

Recovery is automatic during `GraphEngine.open()`. The process:

1. Read manifest.a and manifest.b; select the valid one with the highest counter
2. Open all store files
3. Open the WAL and read from the last checkpoint LSN
4. Classify transactions by scanning BEGIN/COMMIT/ABORT records
5. Replay committed page_update records into the buffer pool
6. Discard uncommitted transactions
7. Flush the buffer pool and write a fresh checkpoint

If WAL records fail decode or checksum validation, open now fails closed and
`Recovery.last_failure` identifies the offending `wal/graph.wal` LSN and
failure kind.

### Metrics

When a `Metrics` struct is wired into the `Recovery` instance,
`recovery_duration_ns` records the wall-clock time of the recovery operation.

---

## Encryption Key Management

### Setting a key

Pass a 32-byte key via `GraphConfig.encryption_key` when creating or opening
the graph. The key is used for AES-256-GCM page encryption and optionally for
HMAC-SHA256 backup integrity.

### Key zeroing

Call `GraphConfig.zeroKey()` during shutdown to securely clear the key from
memory. The engine's `close()` method handles this automatically.

### Key rotation

Key rotation is not yet supported as a built-in operation. To rotate:

1. Create a backup with the current key
2. Create a new graph with the new key
3. Restore data programmatically (re-insert nodes/edges/properties)

A future migration utility may automate this process.

### Upgrading an encrypted store written by graph_storage <= 0.4.11

Versions up to 0.4.11 wrote the AES-GCM tag over the last 16 bytes of every
encrypted page, so some records were never persisted (SONNY-6441, fixed in
0.4.12; `docs/format-spec.md` §1.5 lists what each store lost). Upgrade in
this order:

1. **Stop the old binary cleanly** (`close()`, which checkpoints and empties
   the WAL). Do not let a store written by <= 0.4.11 go through crash
   recovery under a newer binary. A WAL page image is a verbatim copy of the
   in-memory page, and the old binary's in-memory copy of a page it had read
   from disk held the tag bytes in its last 16 bytes; replaying it installs
   them as record data (node `flags`/`label_count`/`txn_stamp`, chain heads,
   adjacency fields). Recovery cannot tell those images apart: no version of
   the library stamps the page id, LSN, flags or checksum into a cached
   page, the WAL record carries no writer version, the manifest format did
   not change in 0.4.12, and a page logged by 0.4.12 or later may hold a
   committed record in those same bytes (a node created in slot 169 after
   the upgrade), which zeroing on replay would delete. If a store already
   crashed under <= 0.4.11, recover it once with the old binary and close it
   cleanly before upgrading.
2. **Open it with >= 0.4.13 and, before any other write, call
   `GraphEngine.repairAdjTailEntries`** on each engine (each shard of a
   `ShardedGraphEngine`), then `checkpoint()`. It restores adjacency entries
   from the edge's other-direction copy and reports what it cannot restore.
   A later `removeEdge` in a damaged block moves the damaged last entry to
   another slot, where it can no longer be recognised.

   **Known unrecoverable case.** The same move already happened if the old
   binary itself removed an edge from a damaged full block: it read the tag
   bytes as the last entry's fields (pages read by <= 0.4.11 kept them;
   0.4.12+ zero the legacy tail on read), swapped that entry into the freed
   slot and wrote the block back with one entry fewer. The block is no
   longer full and the damaged entry is no longer in the last slot, so the
   repair, which only inspects the last slot of full blocks, does not see it,
   and a scan cannot tell tag bytes from a real `rel_type` / `prop_head` /
   `public_id`. Such an entry reads back with wrong fields; only a comparison
   of every entry with its other-direction copy could find it, and the
   repair does not do one.
3. Re-attach incoming chains whose `adj_in_dir` head was lost with
   `migrateColocateInEdges` (after step 2, so it copies repaired entries).
4. A node record that lost its tail (8 KiB pages, slot 169) can be given its
   `label_count` back from its label block, but whether it had been deleted
   cannot be derived: a delete is recorded only in `NodeRec.flags` (the label
   index keeps deleted nodes' postings, `deleteNode` keeps the heads, and no
   log of deletes outlives a checkpoint).

Pages move to the current envelope on their next write; until then an
offline tool can recognise an old page without the key (flag clear, header
checksum not matching the body). It should skip pages `free.store` marks free
(`free_space.FreeStore`, no engine needed): their stale contents are not
records.

---

## Upgrading from V1 to V2 Format

V2 introduced a 48-byte NodeRec layout (V1 used 40 bytes). The formats are
incompatible at the page level.

### Reject mode (default)

By default, `GraphConfig.legacy_policy` is `.reject`. Opening a V1 graph
returns `error.IncompatibleVersion`.

### Read-only mode

Set `GraphConfig.legacy_policy = .read_only` to open a V1 graph in read-only
mode for data extraction:

```zig
const cfg = GraphConfig{
    .legacy_policy = .read_only,
};
var engine = try GraphEngine.open(allocator, data_dir, uuid, cfg);
// Read operations work; mutations are not permitted
```

### Full migration

1. Open the V1 graph in read-only mode
2. Create a new V2 graph
3. Iterate nodes and edges from V1, insert into V2
4. Verify the new graph with `VerifyTool`
5. Replace the old data directory

---

## Verification

Use `VerifyTool` to check graph integrity:

```zig
const verify_mod = @import("verify.zig");
var tool = verify_mod.VerifyTool.init(allocator);
var result = try tool.verifyGraph(&graph_dir, page_size);
defer result.deinit();

if (!result.isClean()) {
    // result.corrupted_pages, result.errors contain details
}
```

Verification checks manifest validity and page checksums across all store files.
It also validates required metadata snapshots, the label dictionary, and the
`wal/graph.uuid` plus `wal/graph.wal` artifacts for the target graph UUID.

---

## Monitoring

The `Metrics` struct provides counters for:

- Page I/O: `page_reads`, `page_writes`, `buffer_hits`, `buffer_misses`
- WAL: `wal_appends`, `wal_bytes_written`, `wal_segment_count`
- Transactions: `txn_begun`, `txn_committed`, `txn_aborted`
- Operations: `nodes_created`, `nodes_deleted`, `edges_created`, `edges_removed`
- Properties: `properties_written`, `properties_read`
- Checkpoint: `checkpoints_completed`, `last_checkpoint_duration_ns`
- Recovery: `recovery_duration_ns`
- Health: `fragmentation_ratio`, `index_rebuild_progress`

Use `Metrics.bufferHitRate()` to monitor cache effectiveness. A sustained hit
rate below 0.90 may indicate the buffer pool is undersized.

### Structured events

Set `GraphConfig.log_fn` to receive lifecycle events (checkpoint_start/end,
recovery_start/end, backup_start/end) as `StorageEvent` labels through the
callback.
