# Executive Summary

* Confirmed from input: the current implementation persists an in-memory graph built around hash maps and adjacency lists, with durability achieved through full snapshot rewrites; per-graph files exist, but graph state is still duplicated/co-mingled in memory and WAL semantics are not yet fully transactional. 
* Goal: implement a per-graph, disk-resident storage engine that uses a page store, buffer pool, transactional WAL, incremental checkpointing, and locality-friendly adjacency storage.
* Target users: storage/runtime engineers, query/indexing engineers, database operators/SREs, and enterprise users who need graph-level backup, restore, portability, and bounded restart behavior.
* Key scope guardrail: cross-graph queries remain out of scope by design; a single graph directory is the unit of storage, backup, restore, migration, and operational isolation.
* Biggest assumption: the file’s recommended “Option B” is the intended target architecture, with an initial bridge phase to introduce a `GraphStorage` abstraction and remove legacy global-map dependencies.
* Recommended delivery shape: phase the work into storage isolation, page-store foundation, WAL/recovery, core indexes, migration/tooling, and benchmark-driven hardening. Specialist Review Needed: pager/WAL/recovery design should receive independent database-internals review before enterprise durability claims are made. 

# Requirements Specification

## Problem Statement

Confirmed from input: the current storage layer is optimized around in-memory hash maps and full-file snapshots, while the docs describe a page-based engine that is not reflected in the actual persistence path. This creates a mismatch between product claims and implementation, and it introduces bottlenecks in traversal locality, checkpoint cost, restart behavior, graph isolation, and operational portability. Proposed interpretation for implementation: replace the current authoritative persistence path with the file’s recommended per-graph page-store architecture, while preserving existing logical graph semantics and keeping cross-graph querying out of scope. 

## Objectives

1. Establish per-graph physical and logical isolation so each graph can be backed up, restored, moved, and verified independently.
2. Replace full-snapshot checkpointing as the primary durability mechanism with transactional WAL plus dirty-page checkpointing.
3. Improve traversal performance by storing adjacency in locality-friendly disk structures instead of hash-map-driven indirection.
4. Bound open/restart work to catalog loading plus WAL replay since the last checkpoint, rather than full-graph deserialization.
5. Preserve the existing logical graph model and current property value types during migration.
6. Provide core index support for labels and selective property lookups, with extension points for specialized index types later.
7. Support migration from both current persistence formats with verification and a controlled compatibility window.
8. Provide benchmark, verification, and operational tooling sufficient to validate enterprise-readiness claims.

## In Scope

* Per-graph authoritative storage directories keyed by graph UUID.
* A minimal global graph registry for name-to-UUID resolution and lightweight metadata.
* A storage abstraction boundary used by query execution, mutation, and admin paths.
* Removal of global backfilled node/edge maps as an active source of truth.
* Versioned A/B manifests or equivalent superblocks per graph.
* Pager and buffer pool with explicit page I/O as the default access path.
* Fixed-record node storage.
* Graph-local outgoing and incoming adjacency stores.
* Slotted-page property storage plus overflow/variable-length value storage.
* Free-space tracking and reuse.
* Segmented WAL with real transaction boundaries and recovery semantics.
* Incremental checkpointing and deterministic recovery.
* Integrity validation, corruption detection, and verify tooling.
* Core indexes for label access and opt-in B+tree property indexes.
* Per-graph index catalog and online/offline index build flows.
* Migration tooling from `graph_store.dat` and current per-graph `.dat` files.
* Per-graph maintenance operations: backup, restore, verify, checkpoint, rebuild.
* Metrics, events, and benchmark harnesses needed to validate the design.

## Out of Scope

* Cross-graph query planning, execution, or shared logical collections.
* A single shared data file containing durable state for multiple graphs.
* Replacing the logical query language or changing user-visible graph semantics beyond storage behavior.
* A log-structured primary graph store as the default architecture.
* An analytics-first CSR/columnar primary representation.
* Mandatory implementation of every specialized index type in the first delivery.
* New regulatory/compliance controls not specified in the source material.
* Broad platform/control-plane features unrelated to storage, indexing, durability, or migration.

## Users / Actors

* Storage engine developers
* Query planner/executor
* Transaction manager / MVCC subsystem
* Index builder and index catalog manager
* Database operators / SREs
* Migration and upgrade tooling
* Backup/restore tooling
* Security/key-management provider
* QA / performance engineering
* Application clients using the existing graph APIs and query surfaces

## Functional Requirements

1. **ID:** FR-001
   **Requirement:** The system shall store each graph in an independent, authoritative graph directory containing all graph-specific durable state.
   **Rationale:** This enforces graph isolation and makes backup/restore/move operations graph-local.
   **Priority:** P0
   **Acceptance Criteria:**

   * Given a graph is created, when storage is initialized, then a unique graph UUID directory is created as the authoritative location for that graph’s durable state.
   * Given a graph directory is copied to another environment and a valid registry entry exists, when the graph is opened, then no unrelated graph files are required.
   * Given multiple graphs exist, when one graph is deleted, backed up, restored, or verified, then no other graph directory is modified.

2. **ID:** FR-002
   **Requirement:** The system shall maintain a minimal global graph registry that maps graph name to graph UUID and stores only lightweight metadata.
   **Rationale:** The registry should remain the only cross-graph structure and should not become a shared query surface.
   **Priority:** P0
   **Acceptance Criteria:**

   * Given a graph is created or renamed, when the registry is updated, then graph data files do not need to be rewritten.
   * Given the registry is inspected, then it contains graph identity and lightweight metadata only, not shared node/edge data.
   * Given a registry entry is missing or corrupt, when an operator provides the graph UUID directory directly, then the underlying graph files remain independently valid.

3. **ID:** FR-003
   **Requirement:** The system shall provide a `GraphStorage` abstraction used by all production query, mutation, and admin paths.
   **Rationale:** This decouples the execution layer from the current in-memory maps and enables backend replacement without planner rewrites.
   **Priority:** P0
   **Acceptance Criteria:**

   * Given production code paths are analyzed, when storage access is traced, then reads and writes go through the abstraction rather than directly through legacy `store.nodes` / `store.edges`.
   * Given a storage backend is swapped behind the abstraction, when the planner/executor runs unchanged, then graph operations continue to function.

4. **ID:** FR-004
   **Requirement:** The active storage backend shall have exactly one in-memory source of truth per graph and shall not backfill global node/edge maps in the new mode.
   **Rationale:** Duplicate state increases memory use and raises the risk of cross-graph leakage and stale reads.
   **Priority:** P0
   **Acceptance Criteria:**

   * Given a graph is opened using the new backend, when memory is inspected, then node/edge data is not duplicated into a separate global compatibility map.
   * Given a mutation occurs, when subsequent reads are served, then they are resolved from the graph-local authoritative structures only.

5. **ID:** FR-005
   **Requirement:** Each graph shall maintain versioned A/B manifests (or equivalent superblocks) containing format version, graph UUID, page size, last checkpoint LSN, root pointers/high-water marks, and checksums.
   **Rationale:** Dual manifests enable atomic metadata updates and safer crash recovery.
   **Priority:** P0
   **Acceptance Criteria:**

   * Given a checkpoint completes, when metadata is committed, then the graph can be reopened using the latest valid manifest.
   * Given the most recent manifest copy is corrupted, when the graph opens, then the engine falls back to the previous valid copy or fails safely.
   * Given an incompatible format version is encountered, when open is attempted, then the engine returns an explicit upgrade/compatibility error.

6. **ID:** FR-006
   **Requirement:** The system shall implement a pager and buffer pool with configurable page size and explicit page I/O as the default access path.
   **Rationale:** The target architecture depends on disk-resident pages rather than whole-graph in-memory reconstruction; the source recommends explicit I/O over assuming mmap everywhere.
   **Priority:** P0
   **Acceptance Criteria:**

   * Given a graph larger than available RAM, when the graph opens, then only metadata and active pages are loaded into memory.
   * Given a page is read or modified, when the access path is traced, then it goes through the buffer pool with dirty-page tracking.
   * Given optional mmap support exists, when enabled, then it is restricted to approved read-mostly or immutable scenarios and is not the default write path.

7. **ID:** FR-007
   **Requirement:** The system shall store nodes in a fixed-record node store addressable by node ID or by a stable node-ID mapping table if remapping is chosen.
   **Rationale:** Direct node addressing removes hash-map lookup overhead and supports predictable storage access.
   **Priority:** P0
   **Acceptance Criteria:**

   * Given a node ID is known, when the node is fetched, then the engine can resolve the node record without scanning a hash map.
   * Given a node is created, updated, or deleted, when the graph is reopened, then the node record state is preserved according to committed transactions.
   * Given sparse legacy IDs are migrated, when migration policy is applied, then the chosen preserve/remap behavior is explicit and verifiable.

8. **ID:** FR-008
   **Requirement:** The system shall store outgoing and incoming adjacency in graph-local adjacency stores optimized for traversal locality.
   **Rationale:** Traversal is a hot path; adjacency needs to be read as localized blocks/pages instead of chained hash-map lookups.
   **Priority:** P0
   **Acceptance Criteria:**

   * Given `expandOut(node_id)` is executed, when the engine reads storage, then it traverses graph-local adjacency blocks/pages rather than a hash-map of edge IDs plus edge lookups.
   * Given `expandIn(node_id)` is executed, then the engine can resolve inbound adjacency without a full graph scan.
   * Given a relationship-type filter is present, when expansion occurs, then the engine can apply the filter without scanning unrelated edges.

9. **ID:** FR-009
   **Requirement:** The system shall store node and edge properties in a slotted-page property store, with large or variable-length values placed in an overflow/variable store.
   **Rationale:** Typed property storage needs to preserve current logical behavior while avoiding per-record hash-map overhead.
   **Priority:** P0
   **Acceptance Criteria:**

   * Given a property value of type string, int, float, bool, null, ext-value, or decimal, when persisted and reopened, then the logical value is preserved.
   * Given a large string or blob-like value, when persisted, then the primary property record contains a stable reference into the variable-length store.
   * Given a property update or delete, when committed and recovered, then the resulting state matches the committed transaction.

10. **ID:** FR-010
    **Requirement:** The system shall implement free-space management for all durable files, including page-level reuse and slotted-page free-space tracking.
    **Rationale:** Space reuse is required to avoid relying on full snapshot rewrites as the primary compaction mechanism.
    **Priority:** P0
    **Acceptance Criteria:**

    * Given records are deleted or moved, when future allocations occur, then reusable free space is discoverable without scanning the full file set.
    * Given page allocation and reuse occur, when the free-space manager is inspected, then it tracks free pages/extents and slotted-page free space.
    * Given optional vacuum/defragment runs, when completed, then logical graph contents are unchanged.

11. **ID:** FR-011
    **Requirement:** The system shall implement a segmented WAL per graph with record headers containing graph identity, sequence ordering, transaction identity, record type, and integrity checks.
    **Rationale:** WAL is the durability backbone for bounded recovery and transactional correctness.
    **Priority:** P0
    **Acceptance Criteria:**

    * Given a graph mutation occurs, when the write path executes, then WAL records are appended to a graph-local WAL segment before commit is acknowledged.
    * Given WAL segments roll, when the graph continues running, then new segments are created without losing sequence continuity.
    * Given WAL is inspected, then each segment and record can be associated with exactly one graph and validated for integrity.

12. **ID:** FR-012
    **Requirement:** The WAL shall integrate with the transaction manager using real transaction IDs and explicit begin/commit/abort semantics.
    **Rationale:** The source identifies current `txn_id = 0` behavior as insufficient for enterprise guarantees.
    **Priority:** P0
    **Acceptance Criteria:**

    * Given a transaction commits, when recovery runs after a crash, then committed changes are visible.
    * Given a transaction aborts or crashes before commit, when recovery runs, then those changes are not visible.
    * Given multiple transactions commit in order, when recovery replays WAL, then commit ordering is preserved.

13. **ID:** FR-013
    **Requirement:** The system shall implement incremental checkpointing that writes only dirty pages and truncates WAL only after a successful durable checkpoint.
    **Rationale:** This replaces full-graph snapshot rewrites and bounds checkpoint cost and restart time.
    **Priority:** P0
    **Acceptance Criteria:**

    * Given a checkpoint runs, when I/O is measured, then only dirty pages plus control metadata are written, not a full graph rewrite.
    * Given a checkpoint succeeds, when manifests are updated, then WAL truncation advances only after the checkpoint becomes durable.
    * Given a crash occurs during checkpoint, when the graph reopens, then needed WAL for recovery is still present.

14. **ID:** FR-014
    **Requirement:** The system shall validate manifests, pages, WAL segments, and graph UUID bindings during open, recovery, and explicit verify operations.
    **Rationale:** Fine-grained corruption detection must replace coarse whole-file-only validation.
    **Priority:** P0
    **Acceptance Criteria:**

    * Given a page or WAL segment is corrupted, when open/recovery/verify is run, then the graph fails safely and reports the affected artifact.
    * Given a file-swap or graph UUID mismatch occurs, when the graph opens, then the mismatch is detected and the graph is not mounted silently.
    * Given a verify command is run, then it returns machine-readable results identifying pass/fail status and affected pages/files.

15. **ID:** FR-015
    **Requirement:** The system shall provide native node-ID addressability and mandatory per-graph label posting lists, with relationship-type postings configurable.
    **Rationale:** Label lookups are already a proven optimization in the current system and should become first-class, graph-local indexes.
    **Priority:** P0
    **Acceptance Criteria:**

    * Given a label-based node match is executed, when a label posting list exists, then the engine retrieves candidate node IDs from the posting list rather than scanning all nodes.
    * Given relationship-type postings are enabled, when a type-filtered expansion runs, then the engine can use them to reduce scan work.
    * Given the graph is restarted, when indexes are reopened, then posting lists remain consistent with committed data.

16. **ID:** FR-016
    **Requirement:** The system shall support opt-in per-graph B+tree property indexes for equality and range predicates.
    **Rationale:** Selective property predicates should not require full scans once an index is defined.
    **Priority:** P1
    **Acceptance Criteria:**

    * Given a property index is defined for a label/property combination, when matching predicates are executed, then the planner/executor can obtain candidate node IDs from the index.
    * Given indexed properties are inserted, updated, or deleted, when the transaction commits and the graph recovers, then the index reflects committed state.
    * Given no index exists, when a query runs, then the engine falls back to the non-indexed path without incorrect results.

17. **ID:** FR-017
    **Requirement:** The system shall maintain a per-graph index catalog and support online/offline index build and rebuild flows.
    **Rationale:** Index state must be durable, resumable, and isolated per graph.
    **Priority:** P1
    **Acceptance Criteria:**

    * Given an index is created, when the catalog is inspected, then it records index definition, build state, root pointers, and last-built LSN or equivalent state.
    * Given an online index build starts, when background catch-up finishes, then the index becomes active only after validation against the WAL tail.
    * Given a crash occurs during build, when the graph reopens, then the index remains resumable or inactive, never partially active.

18. **ID:** FR-018
    **Requirement:** The system shall provide migration tooling that imports both legacy single-file snapshots and current per-graph snapshot files into the new store.
    **Rationale:** Adoption requires a reliable path from existing durable formats.
    **Priority:** P0
    **Acceptance Criteria:**

    * Given `graph_store.dat` or the current per-graph snapshot format is provided, when migration runs, then a new graph directory is produced in the target format.
    * Given migration completes, when verification runs, then counts, IDs/mappings, labels, properties, and edge connectivity match the migration policy.
    * Given dry-run validation is requested, when run before cutover, then discrepancies are reported without altering the source data.

19. **ID:** FR-019
    **Requirement:** The system shall support a controlled compatibility window in which startup prefers the new store, but legacy formats can still be migrated or opened read-only under explicit policy.
    **Rationale:** A staged rollout reduces operational risk during cutover.
    **Priority:** P1
    **Acceptance Criteria:**

    * Given both new and legacy stores exist, when startup occurs, then the new store is preferred unless an explicit legacy override is configured.
    * Given only legacy data exists, when startup occurs during the compatibility window, then the system can either invoke migration or open legacy data read-only with an explicit warning.
    * Given the compatibility window ends, when legacy-only startup is attempted, then the system returns a clear upgrade-required error.

20. **ID:** FR-020
    **Requirement:** The system shall provide per-graph maintenance operations for backup, restore, verify, checkpoint, and index rebuild, with optional vacuum/defragment support.
    **Rationale:** Enterprise operations require graph-scoped maintenance and recovery tooling.
    **Priority:** P1
    **Acceptance Criteria:**

    * Given an operator invokes backup, restore, verify, checkpoint, or rebuild for one graph, when the operation completes, then only that graph’s files are affected.
    * Given a backup is restored elsewhere with valid configuration, when the graph opens, then integrity verification passes before the graph is made writable.
    * Given an operation fails, when the result is returned, then it includes graph identity, operation phase, and actionable status.

21. **ID:** FR-021
    **Requirement:** The core storage and index catalog shall support extension points for specialized index modules such as full-text, vector, and spatial indexes.
    **Rationale:** The file recommends keeping specialized indexes modular rather than coupling them to the core graph store.
    **Priority:** P2
    **Acceptance Criteria:**

    * Given a specialized index type is registered, when the index is created, then its metadata is persisted in the per-graph catalog and its files are stored under that graph’s index area.
    * Given a specialized index module is absent, degraded, or rebuilding, when the graph opens, then the core graph store still opens safely and marks the module state explicitly.
    * Given a specialized index is rebuilt, when complete, then the catalog reflects the new active state without changing core graph file formats.

## Non-Functional Requirements

### Security

1. **ID:** NFR-SEC-001
   **Requirement:** The system shall support encryption at rest for graph and index files using the existing key-management entry point or an approved equivalent, implemented without full-file plaintext buffering during checkpoint or finalization.
   **Rationale:** The source identifies current whole-file encryption as a memory-spike risk.
   **Priority:** P0
   **Acceptance Criteria:**

   * Given encryption is enabled, when checkpoint or backup runs, then storage memory usage does not scale with total file size solely because of whole-file plaintext buffering.
   * Given the key is missing or incorrect, when the graph opens, then the system fails safely with an explicit error.

2. **ID:** NFR-SEC-002
   **Requirement:** Manifests, pages, WAL segments, and graph identity bindings shall be integrity-checked during open, recovery, verify, and restore workflows.
   **Rationale:** Enterprise storage must detect tampering, corruption, and file-swap conditions early.
   **Priority:** P0
   **Acceptance Criteria:**

   * Given a durable artifact is modified outside the engine, when open/recovery/verify runs, then integrity failure is detected before serving writes.
   * Given a graph file is paired with the wrong UUID/manifest, when the graph opens, then the system rejects it.

3. **ID:** NFR-SEC-003
   **Requirement:** Commit durability shall guarantee that once a commit is acknowledged, the committed state survives process crash and restart.
   **Rationale:** This is the minimum enterprise durability bar.
   **Priority:** P0
   **Acceptance Criteria:**

   * Given a commit is acknowledged, when the process crashes immediately after, then recovery restores the committed state.
   * Given a crash occurs before commit acknowledgement, when recovery runs, then those changes are not exposed as committed.

### Privacy

4. **ID:** NFR-PRI-001
   **Requirement:** Graph data shall remain isolated in memory and on disk, with no shared node/edge data structures across graphs beyond the minimal registry.
   **Rationale:** The source explicitly wants cross-graph concerns removed by construction.
   **Priority:** P0
   **Acceptance Criteria:**

   * Given two graphs contain similar labels, IDs, or values, when queries and maintenance operations are run against one graph, then no data from the other graph is returned or modified.
   * Given storage internals are inspected, when the new backend is active, then graph data is not co-mingled in shared node/edge structures.

### Performance

5. **ID:** NFR-PERF-001
   **Requirement:** Graph open and restart behavior shall depend on metadata loading plus WAL replay since the last checkpoint, not full-graph deserialization.
   **Rationale:** Bounded open/recovery time is a core reason for the redesign.
   **Priority:** P0
   **Acceptance Criteria:**

   * Given a graph larger than RAM, when it opens, then the engine does not reconstruct the entire graph in memory as a prerequisite to serving requests.
   * Given WAL since checkpoint is small, when restart occurs, then recovery work is correspondingly small.

6. **ID:** NFR-PERF-002
   **Requirement:** Checkpointing shall write dirty pages only and shall not perform full-graph rewrites as the normal checkpoint path.
   **Rationale:** This addresses the current snapshot write-amplification problem.
   **Priority:** P0
   **Acceptance Criteria:**

   * Given a small dirty working set, when checkpoint runs, then I/O is limited to dirty pages and control metadata.
   * Given no pages are dirty, when checkpoint runs, then no full data-file rewrite occurs.

7. **ID:** NFR-PERF-003
   **Requirement:** Traversal expansion shall use adjacency-local reads and avoid global hash-map scans in the hot path.
   **Rationale:** Traversal locality is the primary performance win condition identified in the source.
   **Priority:** P0
   **Acceptance Criteria:**

   * Given outbound or inbound expansion is profiled, when the path is inspected, then it resolves through adjacency pages/blocks rather than scanning or reconstructing all edges.
   * Given a relationship-type filter is present, when expansion executes, then the path reduces work using adjacency-local data structures.

8. **ID:** NFR-PERF-004
   **Requirement:** Storage memory usage shall be bounded primarily by configured buffer/cache budgets plus bounded metadata overhead.
   **Rationale:** The new engine must operate on graphs that do not fit entirely in memory.
   **Priority:** P0
   **Acceptance Criteria:**

   * Given a buffer-pool size is configured, when steady-state workloads run, then storage memory stays within the configured budget plus documented overhead.
   * Given the graph size increases beyond RAM, when read/write operations continue, then the engine remains functional by paging on demand.

### Reliability

9. **ID:** NFR-REL-001
   **Requirement:** Metadata updates shall be atomic, and WAL truncation shall occur only after a durable checkpoint.
   **Rationale:** Crash safety requires a recoverable metadata/WAL boundary.
   **Priority:** P0
   **Acceptance Criteria:**

   * Given a crash occurs mid-checkpoint, when the graph reopens, then at least one valid manifest exists and needed WAL is still available.
   * Given checkpoint succeeds, when WAL truncation happens, then replay from the retained WAL plus active manifest restores committed state.

10. **ID:** NFR-REL-002
    **Requirement:** The system shall fail fast on checksum, UUID, version, or manifest-consistency errors and shall not continue in degraded silent-corruption mode.
    **Rationale:** Fast, explicit failure is safer than silent divergence.
    **Priority:** P0
    **Acceptance Criteria:**

    * Given any integrity or compatibility mismatch exists, when open/recovery/restore is attempted, then the operation stops with an actionable error.
    * Given verify is run, when failures are found, then the failure report identifies graph, file, and affected region.

### Scalability

11. **ID:** NFR-SCL-001
    **Requirement:** The storage engine shall support graphs whose durable size exceeds available memory.
    **Rationale:** A disk-resident design is required for enterprise scale.
    **Priority:** P0
    **Acceptance Criteria:**

    * Given a dataset exceeds available RAM, when the graph is opened and queried, then the engine remains operational by paging data.
    * Given the workload hot set is smaller than the dataset, when the buffer pool warms, then the engine serves the hot set without full dataset load.

12. **ID:** NFR-SCL-002
    **Requirement:** Backup, restore, copy, verify, and migration shall scale at graph granularity rather than database-global granularity.
    **Rationale:** Per-graph portability is a central design goal.
    **Priority:** P0
    **Acceptance Criteria:**

    * Given multiple graphs exist, when one graph is moved or backed up, then other graphs are not blocked by shared data-file coupling.
    * Given graph-local operations run in parallel on separate graphs, when resources permit, then they can proceed independently.

### Accessibility

13. **ID:** NFR-ACC-001
    **Requirement:** Operator-facing CLI/API outputs, errors, and runbooks shall be understandable, structured, and suitable for automation.
    **Rationale:** Operational tooling must be usable by humans and systems.
    **Priority:** P1
    **Acceptance Criteria:**

    * Given an admin operation succeeds or fails, when output is returned, then it includes graph identity, operation phase, status, and machine-readable fields.
    * Given recovery, verify, or migration documentation is reviewed, when a new operator follows it, then the workflow is executable without source-code inspection.

### Observability

14. **ID:** NFR-OBS-001
    **Requirement:** The system shall emit metrics for page reads/writes, buffer hit rate, WAL growth, checkpoint duration, recovery duration, fragmentation, and index build progress.
    **Rationale:** These metrics are required to tune, support, and validate the storage engine.
    **Priority:** P1
    **Acceptance Criteria:**

    * Given the engine is running, when metrics are scraped or exported, then the listed storage metrics are available per graph where feasible.
    * Given performance issues are investigated, when dashboards are reviewed, then checkpoint, WAL, recovery, and buffer-pool behavior are visible.

15. **ID:** NFR-OBS-002
    **Requirement:** The system shall emit structured events for checkpoint, recovery, migration, verify, backup/restore, and index lifecycle transitions.
    **Rationale:** Operators need time-correlated lifecycle signals, not just counters.
    **Priority:** P1
    **Acceptance Criteria:**

    * Given a lifecycle event occurs, when logs/events are examined, then graph identity, phase, duration, and result are present.
    * Given an operation is interrupted, when logs are reviewed, then the last durable phase can be determined.

### Maintainability

16. **ID:** NFR-MNT-001
    **Requirement:** All durable artifacts shall carry explicit format-version metadata and have documented compatibility and upgrade rules.
    **Rationale:** Versioned formats are required for safe evolution.
    **Priority:** P0
    **Acceptance Criteria:**

    * Given a durable artifact is inspected, when its header/manifest is read, then the format version is present.
    * Given a version mismatch occurs, when open or migration is attempted, then the compatibility rule is deterministic and documented.

17. **ID:** NFR-MNT-002
    **Requirement:** The storage engine shall have automated test coverage for migration, crash recovery, corruption handling, checkpoint/replay, and index build/rebuild behavior.
    **Rationale:** Storage correctness cannot rely on ad hoc testing.
    **Priority:** P0
    **Acceptance Criteria:**

    * Given CI runs, when storage-related changes are introduced, then the automated suite executes recovery, corruption, and migration tests.
    * Given a failure-injection scenario is added, when the suite runs, then the expected recovery outcome is asserted automatically.

### Compliance

18. **ID:** NFR-CMP-001
    **Requirement:** Before enterprise release, the implementation shall include documented operational controls for upgrade, backup/restore, rollback, recovery, and key handling, suitable for internal security/compliance review.
    **Rationale:** The source positions the redesign as enterprise-grade, but no specific regulatory regime is defined.
    **Priority:** P1
    **Acceptance Criteria:**

    * Given a release candidate is prepared, when readiness review occurs, then runbooks and control documentation exist for upgrade, restore, rollback, and key handling.
    * Given security/compliance reviewers assess the release, when they review the documentation, then all critical storage operations are traceable and documented.

## Data / Integrations

* **Primary durable inputs**

  * Existing `graph_store.dat` legacy snapshots
  * Current `graph_registry.dat`
  * Current per-graph snapshot files under `graphs/<uuid>.dat`
  * Runtime graph mutations from the query/execution layer
  * Transaction begin/commit/abort events from the transaction manager
  * Index definitions and rebuild requests
  * Encryption key/configuration from the existing key-management entry point

* **Target durable outputs**

  * Global: `graph_registry.dat` or equivalent minimal registry
  * Per graph:

    * `manifest.a` / `manifest.b`
    * `nodes.store`
    * `adj_out.store`
    * `adj_in.store`
    * `props.store`
    * `var.store`
    * `free.store`
    * `wal/`
    * `indexes/`

* **Data model to preserve**

  * Graph name ↔ UUID mapping
  * Node IDs and edge IDs, or an explicit mapping layer if remapped
  * Labels and relationship types
  * Current property types: string, int, float, bool, null, ext-value, decimal
  * Graph-local isolation semantics

* **Runtime integrations**

  * Query planner/executor must consume `GraphStorage`
  * Transaction manager/MVCC must supply real transaction identity and commit ordering
  * WAL/recovery subsystem must integrate with checkpointing
  * Index builder must use a consistent snapshot plus WAL tail for online build
  * Admin CLI/API must expose graph-scoped maintenance commands
  * Metrics/events pipeline must collect per-graph storage telemetry

* **Migration concerns**

  * Need a bulk loader from current snapshot formats
  * Need an explicit decision on ID preservation vs remapping
  * Need verification reports that compare source and target graph contents
  * Need a compatibility window with read-only legacy fallback or explicit upgrade tooling

* **Permissions / operational access**

  * Graph directories require filesystem read/write/rename/fsync permissions
  * Backup/restore locations require explicit operator access
  * Encryption key access must be available to open encrypted graphs

## Constraints / Dependencies

* Cross-graph queries are permanently out of scope.
* The global registry must not evolve into a shared query data plane.
* Existing logical graph semantics should remain stable for client-facing behavior.
* Current production code likely touches legacy `store.nodes` / `store.edges`, so executor refactoring is a prerequisite.
* Transaction manager integration is a hard dependency for real WAL semantics.
* Recovery correctness depends on atomic manifest switching and safe WAL retention.
* Migration depends on stable readers for both existing durable formats.
* Encryption redesign depends on compatibility with the current key-sourcing mechanism or a clearly approved replacement.
* Advanced index delivery depends on clarifying which index types are required in the first release.
* Benchmark claims depend on a representative workload corpus and failure-injection suite.
* No explicit regulatory framework was provided, so compliance requirements must stay limited to operational review readiness.

## Assumptions

* The recommended target architecture is the file’s Option B, not the more radical Option C.
* Existing public graph/query semantics are preserved unless explicitly changed later.
* The first release may use an explicit, controlled migration window rather than zero-downtime migration.
* The registry remains a small global metadata structure in the first release.
* Property value compatibility with current types must be preserved.
* Label posting lists are mandatory in the first release; specialized indexes are not.
* Property indexes are opt-in rather than automatic for every property.
* The existing transaction subsystem can provide durable transaction IDs and commit ordering, even if integration work is needed.
* The engine should default to explicit page I/O, with mmap optional and narrow.
* No numeric SLOs or hardware targets were provided, so performance acceptance is benchmark-relative rather than absolute.

## Open Questions

* Should legacy node/edge IDs be preserved exactly, or is remapping acceptable if a stable external mapping is maintained?
* Is the initial concurrency model single-writer, existing-concurrency-compatible, or expected to expand as part of this work?
* How should MVCC metadata be represented in node/edge/property records, and is MVCC required in the first storage cut?
* Are both incoming and outgoing adjacency stores required in MVP, or can one be derived in constrained deployments?
* Which index types are required in the first production release beyond label posting lists and B+tree property indexes?
* Should the current external WAL dependency be retained, wrapped differently, or replaced entirely?
* Is offline migration acceptable for first rollout, or is an online migration path required?
* What are the expected graph sizes, update rates, and recovery-time targets for the first enterprise deployments?
* What backup retention, WAL retention, and archival policies are expected operationally?
* Does encryption-at-rest need to remain file-oriented for compatibility, or can it move to page/segment-level implementation under the same key model?

## Risks

1. **Risk:** Pager/WAL/checkpoint logic is implemented incorrectly.
   **Impact:** Data loss, corruption, or unrecoverable restart failures.
   **Likelihood:** Medium-High.
   **Mitigation:** Independent specialist review, fault-injection tests, manifest A/B design, checksum enforcement, staged rollout.

2. **Risk:** Executor and admin code retain hidden dependencies on legacy global maps.
   **Impact:** Partial cutover, stale reads, graph co-mingling, difficult debugging.
   **Likelihood:** High.
   **Mitigation:** Introduce `GraphStorage` early, block direct legacy access in CI, refactor all production paths before core cutover.

3. **Risk:** Migration from current snapshot formats produces silent semantic mismatches.
   **Impact:** Incorrect graph contents after upgrade.
   **Likelihood:** Medium.
   **Mitigation:** Dry-run verification, source-vs-target count checks, sample-query diffing, preserved legacy backups until cutover is accepted.

4. **Risk:** Transaction/WAL integration with the existing transaction manager is deeper than expected.
   **Impact:** Schedule expansion, incomplete durability semantics, delayed enterprise readiness.
   **Likelihood:** Medium.
   **Mitigation:** Resolve transaction contract in Phase 0, prototype commit/recovery path early, keep release gates tied to crash-recovery proof.

5. **Risk:** Encryption redesign breaks compatibility or operational key handling.
   **Impact:** Inability to open data or unacceptable operational complexity.
   **Likelihood:** Medium.
   **Mitigation:** Preserve key-entry semantics where possible, test encrypted migration paths, document rollback and key-rotation behavior.

6. **Risk:** Advanced index scope grows before core durability is stable.
   **Impact:** Scope creep and delayed delivery of the storage foundation.
   **Likelihood:** High.
   **Mitigation:** Keep label and property indexes as the initial scope; move specialized indexes behind extension points and P2 prioritization.

7. **Risk:** Benchmarking happens too late and reveals that traversal or restart goals are not being met.
   **Impact:** Rework in late phases.
   **Likelihood:** Medium.
   **Mitigation:** Stand up benchmark harness and observability in parallel with core storage development, not at the end.

# Implementation Plan

## Recommended Approach

Implement the file’s recommended target architecture as the end state: per-graph directories, versioned manifests, pager/buffer pool, fixed-record node store, adjacency stores, slotted-page property storage, segmented WAL, and dirty-page checkpoints. Use a narrow bridge first: introduce a `GraphStorage` abstraction, route all execution/admin access through it, and remove global-map backfill before cutting over the durable backend. Deliver label posting lists and opt-in B+tree property indexes first; treat full-text, vector, and spatial indexes as modular follow-on work rather than blockers to core storage delivery. 

## Architecture / Components

* **Graph Registry**

  * Minimal global metadata service storing graph name → UUID and lightweight graph stats/flags.
  * No shared queryable data structures.

* **Graph Directory Manager**

  * Resolves a graph UUID to its authoritative directory and durable file set.
  * Owns graph-local lifecycle: create, open, close, backup, restore, verify, delete.

* **Manifest Manager**

  * Reads/writes `manifest.a` and `manifest.b`.
  * Tracks format version, graph UUID, page size, last checkpoint LSN, roots/high-water marks, checksum.

* **Pager / Buffer Pool**

  * Explicit `pread`/`pwrite` page I/O path.
  * Dirty-page tracking, pin/unpin, eviction, page checksums, configurable page size and cache sizes.

* **Node Store**

  * Fixed-size node records addressed by node ID or stable mapping.
  * Stores adjacency/property pointers and flags.

* **Adjacency Stores**

  * `adj_out.store` and `adj_in.store`.
  * Optimized for localized expansion and optional relationship-type filtering.

* **Property Store + Variable Store**

  * Slotted pages for typed property entries.
  * Overflow storage for large strings/blobs and dictionary-encoded values if adopted.

* **Free Space Manager**

  * Tracks reusable pages/extents and slotted-page free space.
  * Supports future vacuum/defragment workflows.

* **WAL Manager**

  * Segmented per-graph WAL with transaction identity, LSN sequencing, integrity checks, and rolling segments.

* **Checkpoint / Recovery Manager**

  * Flushes dirty pages, swaps manifests atomically, truncates WAL only after durable checkpoint, replays committed WAL on open.

* **Index Catalog + Core Index Engines**

  * Label posting lists, optional relationship-type postings, property B+tree indexes.
  * Persisted per graph with build state and last-built LSN.

* **Specialized Index Module Boundary**

  * Extension points for full-text, vector, and spatial indexes under graph-local `indexes/`.

* **Migration Loader / Verifier**

  * Reads legacy `graph_store.dat` and current `.dat` graph snapshots.
  * Emits target page-store graphs and verification reports.

* **Admin Operations Layer**

  * Backup, restore, verify, checkpoint, rebuild, vacuum.
  * Returns machine-readable results.

* **Observability Layer**

  * Metrics, structured events, dashboards, benchmark hooks, failure-injection instrumentation.

## Delivery Phases

**Phase 0 — Architecture lock and compatibility decisions**

* **Goal:** Finalize the minimum set of decisions that materially affect on-disk format and migration.
* **Major tasks:** Confirm Option B scope, decide ID preservation/remapping policy, define transaction/WAL contract, confirm initial index scope, define compatibility window behavior.
* **Dependencies:** Product/engineering agreement on target architecture.
* **Deliverables:** Architecture decision record, format RFC, migration policy, WAL contract.
* **Exit criteria:** Open questions that block file layout or recovery semantics are resolved.

**Phase 1 — Isolation boundary and execution decoupling**

* **Goal:** Remove legacy storage coupling so the new backend can be introduced without planner rewrites.
* **Major tasks:** Define `GraphStorage`; refactor query/mutation/admin paths; eliminate global-map backfill in new mode; make graph directory authoritative.
* **Dependencies:** Phase 0 decisions.
* **Deliverables:** Storage abstraction, refactored callers, graph-local in-memory ownership.
* **Exit criteria:** No P0 production path depends directly on legacy `store.nodes` / `store.edges` for graphs running on the new path.

**Phase 2 — Page-store foundation**

* **Goal:** Establish the durable graph-local file layout and primary record stores.
* **Major tasks:** Implement manifests, pager/buffer pool, node store, adjacency stores, property/variable stores, free-space tracking.
* **Dependencies:** Phase 1 complete.
* **Deliverables:** Graph can be created, opened, read, and mutated through page-store-backed CRUD flows.
* **Exit criteria:** Core graph data persists without full snapshot rewrites.

**Phase 3 — Durability, recovery, and integrity**

* **Goal:** Make writes crash-safe and operationally recoverable.
* **Major tasks:** WAL format, transaction integration, checkpoint manager, recovery flow, checksums/UUID validation, verify tooling, encryption redesign.
* **Dependencies:** Phase 2 complete, transaction contract approved.
* **Deliverables:** Crash-recovery path, checksum enforcement, verify command, encrypted path.
* **Exit criteria:** Recovery tests prove committed-only replay and safe crash handling around checkpoint boundaries.

**Phase 4 — Indexing and query-path optimization**

* **Goal:** Replace full scans in the highest-value read paths.
* **Major tasks:** Label posting lists, relationship-type postings if enabled, property B+tree indexes, index catalog, online/offline build, executor adoption.
* **Dependencies:** Phase 3 stable enough to support index persistence and WAL tailing.
* **Deliverables:** Index-backed label/property lookup paths, index lifecycle commands.
* **Exit criteria:** Planner/executor can use label and property indexes correctly; build/rebuild survives restart.

**Phase 5 — Migration and graph operations**

* **Goal:** Make the new engine adoptable in real environments.
* **Major tasks:** Legacy readers, bulk loader, dry-run verification, compatibility window behavior, backup/restore/checkpoint/rebuild commands.
* **Dependencies:** Phases 2–4 sufficiently stable.
* **Deliverables:** Migration toolchain, upgrade workflow, graph-scoped maintenance operations.
* **Exit criteria:** Sample graphs migrate and verify cleanly; restored backups open and validate.

**Phase 6 — Hardening, benchmarks, and rollout**

* **Goal:** Prove enterprise characteristics and cut over safely.
* **Major tasks:** Benchmark suite, fault injection, observability, dashboards, canary rollout, rollback rehearsal, runbooks/training, specialist review.
* **Dependencies:** All prior phases.
* **Deliverables:** Benchmark report, dashboards, rollout runbooks, canary results, review sign-off.
* **Exit criteria:** P0 requirements are met, canary graphs are stable, and release gates are satisfied.

## Detailed Task Breakdown

Estimates are relative: S, M, L, XL.

| Task ID | Req IDs                                 | Workstream         | Task                                                                                     | Why It Matters                                             | Depends On                   | Owner Role                  | Estimate | Output                                   |
| ------- | --------------------------------------- | ------------------ | ---------------------------------------------------------------------------------------- | ---------------------------------------------------------- | ---------------------------- | --------------------------- | -------- | ---------------------------------------- |
| T-01    | FR-003, FR-004                          | Platform           | Define `GraphStorage` contract and inventory every direct legacy storage call site       | Makes backend replacement possible without planner rewrite | None                         | Backend architect           | M        | API contract and refactor plan           |
| T-02    | FR-001, FR-002, FR-004                  | Storage foundation | Make graph directory and registry authoritative; remove global backfill path in new mode | Establishes graph isolation and single source of truth     | T-01                         | Storage engineer            | M        | Graph directory/registry module          |
| T-03    | FR-005, NFR-MNT-001                     | On-disk format     | Write format RFC for manifests, page IDs, file IDs, checksums, compatibility rules       | Prevents rework and format drift                           | T-02                         | Storage architect           | M        | On-disk format specification             |
| T-04    | FR-006, NFR-PERF-004                    | Pager              | Implement buffer pool, dirty tracking, pin/unpin, eviction, explicit page I/O            | Enables disk-resident operation                            | T-03                         | Storage engineer            | L        | Pager/buffer-pool module                 |
| T-05    | FR-007                                  | Record store       | Implement fixed-record node store and ID-addressability strategy                         | Replaces node hash-map lookups                             | T-04                         | Storage engineer            | M        | `nodes.store` module                     |
| T-06    | FR-008, NFR-PERF-003                    | Record store       | Implement `adj_out.store` and `adj_in.store` with expansion APIs                         | Delivers traversal locality                                | T-04, T-05                   | Storage engineer            | L        | Adjacency store module                   |
| T-07    | FR-009, FR-010                          | Record store       | Implement property slotted pages, overflow store, and free-space manager                 | Preserves typed properties and space reuse                 | T-04                         | Storage engineer            | L        | `props.store`, `var.store`, `free.store` |
| T-08    | FR-011                                  | Durability         | Implement WAL segment format, writer, reader, rolling policy                             | Basis for recovery and bounded restart                     | T-03                         | Storage engineer            | M        | WAL subsystem                            |
| T-09    | FR-012, FR-013, NFR-SEC-003             | Transactions       | Integrate WAL with transaction manager, commit markers, recovery, checkpoint flow        | Establishes real durability semantics                      | T-08, T-04, T-05, T-06, T-07 | Runtime + storage engineers | XL       | Recovery/checkpoint pipeline             |
| T-10    | FR-014, NFR-SEC-002, NFR-REL-002        | Integrity          | Add page/manifest/WAL checksums, UUID validation, and verify command                     | Detects corruption and file-swap issues                    | T-03, T-08, T-09             | Storage + QA engineers      | M        | Integrity validation and verify tooling  |
| T-11    | NFR-SEC-001                             | Security           | Redesign TDE to be page/streaming-safe and remove whole-file buffering                   | Eliminates memory spikes and preserves encryption          | T-04, T-08                   | Security/storage engineer   | M        | Encryption integration                   |
| T-12    | FR-015                                  | Indexing           | Implement label posting lists and optional relationship-type postings                    | Removes common full-scan paths                             | T-05, T-06                   | Indexing engineer           | M        | Core posting-list indexes                |
| T-13    | FR-016, FR-017                          | Indexing           | Implement property B+tree indexes, index catalog, online/offline build                   | Enables selective property query performance               | T-12, T-09                   | Indexing engineer           | L        | Property index subsystem                 |
| T-14    | FR-018, FR-019                          | Migration          | Build legacy readers, bulk loader, dry-run verifier, compatibility policy handling       | Makes rollout feasible                                     | T-05, T-06, T-07, T-09       | Migration engineer          | L        | Migration tooling                        |
| T-15    | FR-020, NFR-ACC-001                     | Operations         | Implement graph-scoped backup, restore, checkpoint, rebuild, verify commands             | Provides essential operational controls                    | T-10, T-14                   | Platform engineer           | M        | Admin CLI/API                            |
| T-16    | NFR-OBS-001, NFR-OBS-002                | Observability      | Add metrics, structured events, dashboards, benchmark telemetry                          | Required for tuning and support                            | T-04, T-08, T-09, T-13       | SRE/platform engineer       | M        | Metrics/events package                   |
| T-17    | NFR-MNT-002, NFR-PERF-001, NFR-PERF-002 | Validation         | Build crash-recovery, corruption, benchmark, and failure-injection suite                 | Proves storage correctness and performance behavior        | T-09, T-12, T-13, T-14       | QA/performance engineer     | L        | Automated validation suite               |
| T-18    | FR-021                                  | Extensibility      | Add specialized-index plugin boundary and catalog registration hooks                     | Prevents future index types from coupling to core format   | T-13                         | Indexing architect          | M        | Extension-point framework                |
| T-19    | NFR-CMP-001                             | Enablement         | Produce upgrade, rollback, recovery, key-handling, and operator runbooks                 | Required for enterprise release readiness                  | T-15, T-16, T-17             | Tech writer + ops lead      | S        | Runbook/documentation package            |
| T-20    | All P0 release items                    | Release            | Execute canary rollout, rollback rehearsal, and final readiness review                   | De-risks production cutover                                | T-14, T-15, T-16, T-17, T-19 | Release manager             | M        | Go-live decision package                 |

## QA and Validation Plan

* **Functional**

  * Validate create/open/close/delete for graph directories.
  * Validate CRUD for nodes, edges, labels, and properties across restarts.
  * Validate graph-local backup, restore, verify, checkpoint, and rebuild operations.
  * Validate migration from both legacy durable formats.
  * Validate index create/build/use/drop/rebuild flows.

* **Integration**

  * Validate planner/executor against `GraphStorage` without direct legacy map access.
  * Validate transaction manager integration for begin/commit/abort and recovery.
  * Validate WAL + checkpoint + manifest interactions under clean and crash scenarios.
  * Validate TDE/encryption path with backup/restore and migration.
  * Validate index build catch-up from WAL tail.

* **Regression**

  * Compare pre-migration and post-migration query results on representative graphs.
  * Run legacy semantics regression for label filters, property predicates, and traversal behavior.
  * Enforce CI checks that block new direct reads from legacy global maps in the new backend path.

* **Performance**

  * Benchmark:

    * point lookup by node ID
    * property lookup via index
    * `expandOut` / `expandIn` at low, medium, high degree
    * bounded variable-length traversal
    * insert/update/delete
    * bulk ingest
    * checkpoint
    * crash recovery / WAL replay
    * cold start / open
    * index build / rebuild
  * Record:

    * p50/p95/p99 latency
    * throughput
    * read amplification
    * write amplification
    * space amplification
    * buffer hit rate
    * page faults
    * checkpoint duration and bytes written
    * recovery time
    * fragmentation / free-space ratio

* **Security / Privacy**

  * Tamper page/WAL/manifest and verify fail-fast behavior.
  * Test wrong-key and missing-key encrypted open flows.
  * Validate graph UUID mismatch/file-swap rejection.
  * Validate graph isolation in memory and on disk.

* **Accessibility**

  * Validate CLI/API outputs are human-readable and machine-readable.
  * Review runbooks with operators unfamiliar with storage internals.
  * Confirm errors include graph identity, phase, and recovery guidance.

* **User Acceptance Testing**

  * Run migration and restore rehearsal on representative enterprise graphs.
  * Have storage, runtime, SRE, and security owners sign off on recovery, backup/restore, and rollback procedures.
  * Require specialist review of WAL/recovery design before calling the platform enterprise-ready.

## Rollout Plan

* Release behind a backend-selection feature flag or configuration gate at graph level.
* Provide an explicit migration tool with dry-run verification and pre-cutover backup.
* Prefer a controlled compatibility window:

  * open new store when present
  * otherwise migrate legacy formats or allow temporary read-only legacy mode under explicit policy
* Canary with non-critical graphs first, then scale to larger and higher-write graphs.
* Collect per-graph metrics for WAL growth, checkpoint duration, recovery behavior, and query latency during canary.
* Keep legacy backups and documented rollback procedures until cutover is accepted for each graph.
* Rehearse restore-from-backup and rollback before broad rollout.
* Publish operator documentation for upgrade, restore, rebuild, verify, and encryption-key handling.
* Staff support readiness with dashboards, alert thresholds, and named owners for storage, runtime, and operations. 

## Definition of Done

* All P0 functional and non-functional requirements are implemented and pass automated validation.
* No production new-backend path depends on legacy global node/edge maps.
* Crash-recovery tests prove committed-only recovery and safe checkpoint boundaries.
* Per-graph backup, restore, verify, and migration workflows work on representative datasets.
* Graphs larger than memory can be opened and queried without whole-graph deserialization.
* Label posting lists and property indexes function correctly and survive restart/recovery.
* Observability is in place for WAL, checkpoint, recovery, buffer pool, and index builds.
* Runbooks for upgrade, rollback, restore, recovery, and key handling are complete.
* Benchmark results demonstrate the intended behavioral improvements over full snapshot rewrite semantics.
* Specialist review is completed, or any exceptions are explicitly documented and accepted by responsible owners.

## Immediate Next Steps

1. Approve the target architecture as Option B with the bridge sequence through `GraphStorage`.
2. Resolve the blocking design decisions: ID preservation/remapping, WAL contract, initial index scope, and compatibility-window behavior.
3. Produce the on-disk format RFC covering manifests, page IDs, file IDs, checksums, and versioning.
4. Start Phase 1 refactoring to remove direct executor/admin dependence on legacy global maps.
5. Build the migration fixtures and benchmark corpus from current `graph_store.dat` and per-graph `.dat` samples.
6. Prototype the transaction-integrated WAL + checkpoint + recovery loop before broader implementation proceeds.

