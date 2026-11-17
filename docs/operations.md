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
and loads the index catalog. The derived indexes (label, property chain,
edge, edge existence) are loaded or rebuilt on first use.

Crash recovery replays the committed WAL tail, flushes and fsyncs the pages,
writes both manifests with the advanced `last_checkpoint_lsn`, fsyncs the
graph directory and then truncates the WAL (since 0.4.22, SONNY-6599; before,
the replayed tail stayed on disk until the shard was next written and
checkpointed). The WAL is left in place when it holds cross-shard 2PC records
(the sharded reconcile reads them after every shard has opened) or a record
that does not decode; the next checkpoint truncates it.

---

## Transactions

Every mutation runs in a transaction. The plain calls (`putNode`, `addEdge`,
`putProperty`, ...) begin and commit one of their own; the `*Txn` variants
join a transaction the caller holds:

```zig
const txn = try engine.beginTxn();
errdefer engine.abortTxn(txn) catch {};
const id = try engine.allocNode();
try engine.putNodeTxn(id, rec, txn);
_ = try engine.addEdgeColocatedTxn(id, other_id, rel_type, txn);
try engine.commitTxn(txn);
```

If a transaction is not committed it will be discarded during recovery.

Writes are applied to the pages in memory as they happen, so readers see
them before the commit, and a transaction is not isolated from another one
running at the same time on the same engine (the caller serializes writes).

`abortTxn` undoes the transaction's writes (SONNY-6529, releases after
0.4.15): each engine write records its inverse, and the abort applies them
in reverse order, logs their page images in the aborting transaction and
ends it with a COMMIT record, so a crash before that record recovers the
state before the transaction and a crash after it replays the undo. Undone:

- node create (`allocNode` + `putNodeTxn` into an empty slot): the slot is
  emptied, the count given back, and the id too when nothing was allocated
  after it;
- `putNodeTxn` on an existing node changing `prop_head` (to a chain the
  transaction created), `flags` or `txn_stamp`;
- `deleteNodeTxn`;
- `addLabelTxn`, `removeLabelTxn` (a re-added label goes to the end of the
  node's list);
- `putPropertyTxn` / `putPropertyLegacyTxn` on a new chain (`owner == 0`) or
  a chain the transaction created (the chain is retired);
- `putPropertyTxn` / `removeProperty` on a slab-packed chain that existed
  before the transaction, in place or moved: the chain's bytes are copied
  before the write and written back (refused, failing closed, if another
  live chain has taken those bytes since);
- `addEdgeTxn`, `addEdgeColocatedTxn*` (edge id given back when last);
- `removeEdgeTxn` (the entry is re-inserted with its id, type, property
  head and public id; its position in the chain may change; an edge added
  through the legacy `addEdgeTxn` also gets its `adj_in` entry back);
- `setEdgePropertyTxn` giving an edge its first property.

Space the undone writes took (a new chain, a moved run) is not reused until
compaction. A value stored in an overflow chain that a write replaces or
removes is freed when the transaction commits, not by the write, so such a
write is undone too (0.4.22, SONNY-6558). Not undoable: a property change on
a legacy (non-slab) chain that existed before the transaction, a
`putNodeTxn` that changes
`out_head`, `in_head`, `label_head` or `label_count` of an existing node, a
page the caller imaged itself (`logPagePublic`, `zeroPageLogged`), and a
transaction past 1,048,576 writes. Such a transaction is aborted instead by
discarding its pages (SONNY-6657): since no-steal they were never written,
so every page it held gets back its latest committed WAL image after the
checkpoint frontier, or is reloaded from its store file (what crash
recovery would rebuild); the node and edge counts as of its begin, the
stores' in-memory cursors and the derived indexes (rebuilt, O(graph)) are
restored, and the ABORT record is written (`Metrics.txn_aborts_discarded`).
Pages freed while a transaction is open stay allocated until it ends, so
a discarded free never happened. Allocated ids are not given back. A crash
at any step recovers the state before the transaction. This needs that no
other transaction was open at any time while it was (a held page could
carry the other's bytes) and no cross-shard 2PC record in the WAL tail;
otherwise, with `GraphConfig.abort_undo = .fail_closed` (default),
aborting such a transaction returns `error.AbortNotUndone`, and every later
write, commit and checkpoint on that engine fails the same way: the aborted
writes are in memory and must never reach a checkpoint. `close` then syncs
the WAL, skips its checkpoint and returns the error; reopen the store to
continue from its committed state. `.keep_writes` keeps the older behaviour
for such transactions (the writes stay and are checkpointed).

When one of the engine's auto-commit calls (`putNode`, `addEdge`,
`putProperty`, ...) fails after it changed something, it undoes the change
the same way, in memory only (no other transaction can have committed in
between, so nothing durable carries it), which also works when the failure
was running out of memory.

An open transaction's bytes never reach the store files (no-steal, 0.4.23,
SONNY-6648). Recovery redoes committed transactions only and has no undo, so
while any transaction is open on an engine:

- a page dirtied in that time stays in the buffer pool: eviction skips it,
  and it is written back once no transaction is open (after the commit, or
  after the abort's undo). A transaction can therefore dirty at most about
  `buffer_pool_pages` distinct pages; past that its next write fails with
  `error.BufferPoolFull`, and `abortTxn` restores what it wrote. The
  default pool (1,024 pages, auto-sized up to 65,536 on open) holds far
  more than one statement writes;
- `checkpoint` and `checkpointLight` do nothing and count
  `Metrics.checkpoints_deferred`; the next one after the transaction ends
  runs in full (committed writes are in the WAL meanwhile);
- `close` aborts the open transactions (newest first) and then closes
  normally; an abort that cannot be undone takes the `AbortNotUndone` path
  above.

A crash at any point before the COMMIT record, including in the middle of
an abort, so recovers the state before the transaction. After an abort that
could not be undone (`.fail_closed`) its pages are never written. Under
`sync_mode = .deferred` a committed page is written back only after the WAL
holding its COMMIT record is synced: eviction syncs it once the pool holds
nothing else it could evict (`Metrics.evict_wal_syncs`, also counting the
sync a checkpoint makes first), so disk never holds part of a transaction
the log lost.

A page has at most one open writer (SONNY-6659). The WAL holds full-page
images, so an image taken by one transaction carries every other open
transaction's bytes on that page, and recovery would replay them. A write by
a second open transaction to a page another open one has written therefore
fails with `error.WriteConflict` (`Metrics.write_conflicts`) before its image
is logged: that transaction cannot commit (`commitTxn` returns the same
error) and must be aborted, which undoes it in memory. While its bytes are on
the page, the first writer's writes to it are refused too, so abort the
refused transaction first; then end the first one (or let it continue) and
retry. A transaction that overlapped another is always aborted in memory
(nothing it wrote was committed or reached disk). There is no waiting: the
engine has one writer, so blocking would deadlock it.

Unrelated writes of concurrent transactions do not share pages: each open
transaction appends properties, labels and adjacency entries to slab fill
pages of its own (an ended one's partly filled pages are reused by the next),
and `allocNodeTxn` (also on `ShardedGraphEngine`, by transaction id) gives it
node ids from a node page of its own. Measured: 8 interleaved transactions
creating 40 nodes each with a property, a label and an edge used 40 pages
against 16 serially (3 more per transaction) and conflicted 0 times. What
still conflicts is a page that holds records of both transactions: two
updates of existing nodes on one node page (8 transactions updating random
nodes of a 100-page graph: 55 conflicts in 570 writes), an in-place update
of existing property or label chains in one slab block, an edge to or from
another transaction's node (it writes that node's record), co-located
in-edges whose destinations share an `in_dir` page, and nodes created with
plain `allocNode` while another transaction is open.

---

## Checkpoint

Checkpointing flushes dirty pages, syncs store files, and writes a fresh
manifest to the alternate A/B slot:

```zig
try engine.checkpoint();
```

While a transaction is open the checkpoint is deferred (it returns without
doing anything, `Metrics.checkpoints_deferred`): flushing would write that
transaction's bytes (SONNY-6648, see Transactions).

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

### Pages a consumer must image

The derived indexes (label, property chain, edge, edge existence) are
loaded from their checkpoint snapshots and the pages the committed WAL tail
touched are re-derived on first access. A consumer that writes store pages
itself (`logPagePublic`) must image every page it changed; the reconcile
then finds the affected nodes as follows:

- `.nodes` page: every node on it;
- `.props` slab page: every live chain on it;
- `.adj_out` page (releases after 0.4.15, SONNY-6529): the source node of
  every entry on it, through the loaded edge index. An in-place `prop_head`
  rewrite (`AdjStore.updateEdgePropHead`) therefore needs only its
  `.adj_out` and `.in_idx` pages and the property pages; the source's node
  page, which does not change, need not be imaged. Adding or removing an
  edge still images the source's node page: a removed entry is no longer on
  the adjacency page.

### Metrics

When a `Metrics` struct is wired into the `Recovery` instance,
`recovery_duration_ns` records the wall-clock time of the recovery operation.

---

## Encryption Key Management

### Setting a key

Pass a 32-byte key via `GraphConfig.encryption_key` when creating or opening
the graph. The key is used for AES-256-GCM page encryption and optionally for
HMAC-SHA256 backup integrity.

### What the key covers

Encrypted: every store page, the WAL, and (since SONNY-6590) the side files
that hold schema names or indexed values — `labels.dict`, `props.idx`,
`ordered_propidx.snap`, `props.catalog`, `propidx_*.btree` — and (since
SONNY-6616, 0.4.19) the topology snapshots `edges.idx` and `edges_exist.idx`
(`docs/format-spec.md` §1.6). A consumer that saves its `GraphRegistry` with
`saveToFileWith` gets `graph_registry.dat` (graph names) sealed too, under
the data directory's own identity (`registry.DataDirIdentity`,
`data_dir.identity`, since SONNY-6635): a sealed registry copied from
another data directory under the same key fails authentication. The
manifests are authenticated (HMAC-SHA256), not encrypted. File sizes and
modification times are visible.

Dead space (SONNY-6692): a property write that does not fit its record's
slab slot moves the blob and tombstones the old slot with its bytes intact,
and a value larger than a property page spills to var-store pages that are
freed without being cleared, so a superseded value stays in `props.store` /
`var.store` (in the clear without a key) until its space is reused.
`scrubDeadSpace()` (on `GraphEngine` or `ShardedGraphEngine`) overwrites
it in one logged transaction while no transaction is open; checkpoint after
it to write the cleared pages and truncate the WAL that holds the old
images. Since SONNY-6700 it first proves ownership by walking every live
node (properties, labels) and out-edge (properties), following overflowed
values into the var store, and aborts unchanged if any reference does not
resolve. It then also clears freed runs in var-store slab blocks (labels,
small values), tombstones slab slots no live record references, and zeroes
and frees allocated pages no live record owns (leaks, crash leftovers). Run
it with every writer excluded: a head a writer has not yet stored in a
record is owned by nobody.

Not encrypted, and why (SONNY-6635):

- `labels.idx`: for each label *id*, the ids of the nodes that carry it.
  The names are in `labels.dict`, which is sealed; what is visible is which
  nodes share a label id and how many there are, which the sealed store
  pages' sizes and the node count already bound.
- `prop_rev.idx`: node id to property-chain position; no names or values.
- `free.store`: one bitmap of free pages per paged file; page numbers only.
- The manifests (`manifest.a`/`.b`): the graph uuid, counters, page counts
  and node and edge counts. Read at open before anything else, so they are
  authenticated, not encrypted: a forged or rolled-back manifest is refused
  (SEC-0043); its counts reveal no more than the store's file sizes.
- `wal/graph.uuid`: the graph's uuid, also in the directory name.

None of them holds a name, a property value or an edge's endpoints; sealing
them would hide only sizes the file system shows anyway.

Under a key the topology snapshots are decrypted into memory when a graph
opens instead of being memory-mapped: the open reads the whole file, and
the snapshot stays resident (about 44 bytes per relationship for
`edges.idx` and 28 for `edges_exist.idx`) rather than paged on demand.

**Wrong key.** Opening a store with a key other than the one it was written
with fails with `error.EncryptionKeyMismatch` (since 0.4.19; it used to be
`error.NoManifest`, which read as a missing store): no manifest slot
authenticates under the key. A store whose manifests are absent is still
`error.NoManifest`. A WAL whose records do not decode under the key
(another key's, or plaintext records in an encrypted store) refuses the
open with the same error and is left as it is (SONNY-6622); a WAL with a
bad record followed by valid ones is `error.WalCorrupted`. The offline
verify tool (`VerifyTool`) checks a private copy of the WAL under the key
and never modifies the store's. The copy is made in a new 0700 directory
inside the graph's directory (`.verify-wal-<random>`, files 0600) and
removed when the check ends (SONNY-6635: it was made under `$TMPDIR` or
`/tmp`, where without a key the log's copy was plaintext on another
filesystem). A process killed during the check can leave that directory;
it is safe to delete.

A sealed side file that fails authentication refuses the open (wrong key,
modified, or copied from another graph or shard: `error.SideFileAuthFailed`);
opening without the key fails with `error.SideFileEncrypted`. Derived
snapshots (`props.idx`, `propidx_*.btree`) that fail are rebuilt from the
pages instead, as a corrupt snapshot always was.

### Upgrading a store written by graph_storage <= 0.4.16 under a key

Those versions wrote the side files above in plaintext. Open the store with
>= the release carrying SONNY-6590 and the same key; no other step is needed.
The open:

1. removes a stale `labels.dict.tmp` (an older binary killed mid-save left
   the names there in plaintext);
2. rewrites `labels.dict` sealed (temp file, fsync, rename, directory fsync);
3. empties a plaintext `props.idx` (rebuilt from the pages on first use,
   saved sealed at the next full checkpoint);
4. rewrites `ordered_propidx.snap`, `props.catalog` and each declared
   `propidx_*.btree` sealed (temp file, fsync, rename, directory fsync);
5. records manifest format_version 5, written by the next checkpoint or
   `close()`.

Until 5 is written, a plaintext side file is still accepted, so a crash at
any step reopens and resumes (`tests/tde_schema_names.zig` kills the open
after each step). From 5 on, a plaintext side file is refused
(`error.SideFileNotSealed`): an older binary or an attacker can no longer
substitute a plaintext dictionary that remaps label ids.

The plaintext files are replaced, not scrubbed: their old blocks may persist
on the device (journal, snapshots, SSD remapping, backups taken before the
upgrade). Treat earlier backups and disk images as holding the names in
plaintext.

**Downgrade.** graph_storage <= 0.4.16 refuses a store whose manifest says
5 (`error.IncompatibleVersion`) and refuses a sealed `labels.dict` before
that (`error.InvalidData`: it reads an entry count of 0 followed by bytes it
does not expect). There is no supported downgrade of a sealed store.

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
