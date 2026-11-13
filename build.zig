// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

const Import = std.Build.Module.Import;
const OptimizeMode = std.builtin.OptimizeMode;

const Deps = struct {
    wal_mod: *std.Build.Module,
    uuid_mod: *std.Build.Module,
    thread_pool_mod: *std.Build.Module,
    /// Shared `build_options` module so every consumer module resolves to
    /// the SAME instance. Required by the otel seam (`@import("build_options")`)
    /// and shared with the named `observability` module so the file
    /// doesn't get pulled into two module trees.
    build_options_mod: *std.Build.Module,
    /// Shared `observability` named module. Imported by the public
    /// `graph_storage` module + every test root that exercises the seam
    /// (so the source file stays in a single module tree).
    observability_mod: *std.Build.Module,
    /// Optional otel module. `null` when `-Dwith_otel=false`. When
    /// non-null, every consumer that wants telemetry imports it as
    /// `@import("otel")` — but call sites should generally go through
    /// the named `observability` seam instead.
    otel_mod: ?*std.Build.Module,
    /// Optional bootstrap helper module (`observability_init`). Only
    /// non-null when `-Dwith_otel=true`. The public `graph_storage`
    /// module imports this so the in-process init helper is reachable
    /// from caller binaries via `graph_storage.observability_init`.
    observability_init_mod: ?*std.Build.Module,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -Dwith_otel: compile in otel instrumentation. OFF by default;
    // when off the otel dependency is never resolved and the seam
    // collapses to a comptime-known no-op (verified by
    // otel/scripts/verify-consumer-noop.sh).
    const with_otel = b.option(
        bool,
        "with_otel",
        "Compile in otel instrumentation (off by default; zero overhead when off)",
    ) orelse false;

    const deps = loadDeps(b, target, optimize, with_otel);

    const graph_storage_mod = b.addModule("graph_storage", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = allocImports(b, &.{
            .{ .name = "wal", .module = deps.wal_mod },
            .{ .name = "uuid", .module = deps.uuid_mod },
            .{ .name = "thread_pool", .module = deps.thread_pool_mod },
            .{ .name = "observability", .module = deps.observability_mod },
            .{ .name = "build_options", .module = deps.build_options_mod },
        }),
    });
    if (deps.observability_init_mod) |init_mod| {
        graph_storage_mod.addImport("observability_init", init_mod);
    }
    if (deps.otel_mod) |otel_mod| {
        graph_storage_mod.addImport("otel", otel_mod);
    }

    const seed_mod = b.addModule("seed", .{
        .root_source_file = b.path("tests/seed.zig"),
        .target = target,
        .optimize = optimize,
        .imports = allocImports(b, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });

    const test_step = b.step("test", "Run unit tests");
    addUnitTests(b, target, optimize, deps, test_step);
    addObservabilityTests(b, target, optimize, graph_storage_mod, deps, test_step);
    addIntegrationTests(b, target, optimize, graph_storage_mod, seed_mod, deps);
    addExample(b, target, optimize, graph_storage_mod);
    addBenchmarks(b, target, graph_storage_mod, seed_mod, deps);
    addCheckStep(b, target, optimize, deps);
}

fn loadDeps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: OptimizeMode,
    with_otel: bool,
) Deps {
    const wal_dep = b.dependency("wal", .{ .target = target, .optimize = optimize });
    const uuid_dep = b.dependency("uuid", .{ .target = target, .optimize = optimize });
    const thread_pool_dep = b.dependency("thread_pool", .{ .target = target, .optimize = optimize });

    // Materialize ONE shared `build_options` module. Each consumer module
    // imports the SAME module instance via `addImport` to avoid Zig 0.16's
    // "file exists in modules X and X0" error when two independent
    // `addOptions` modules end up sharing a transitive file path.
    const build_options = b.addOptions();
    build_options.addOption(bool, "with_otel", with_otel);
    build_options.addOption([]const u8, "package_name", "graph-storage");
    const build_options_mod = build_options.createModule();

    // Observability seam (otel). Declared as a SHARED NAMED MODULE so
    // every consumer (lib, tests, example, benchmarks, plus the seam
    // tests) resolves to the same source file via
    // `@import("observability")`. Using relative
    // `@import("observability.zig")` from each module would trip Zig's
    // "file exists in modules X and Y" error because the file would be
    // pulled into multiple module trees. The seam's `enabled` flag
    // tracks `build_options.with_otel`; when off, every helper compiles
    // to a comptime-known no-op and the otel dependency is never
    // resolved. The optional `otel` import is wired below inside the
    // `if (with_otel)` block.
    const observability_mod = b.addModule("observability", .{
        .root_source_file = b.path("src/observability.zig"),
        .target = target,
        .optimize = optimize,
        .imports = allocImports(b, &.{
            .{ .name = "build_options", .module = build_options_mod },
        }),
    });

    // Gated otel dependency. The `lazy = true` entry in build.zig.zon
    // means Zig only fetches the package when this branch executes;
    // with the flag off the dependency is never resolved and the
    // produced artifacts contain zero otel symbols (verified by
    // otel/scripts/verify-consumer-noop.sh).
    var otel_mod: ?*std.Build.Module = null;
    var observability_init_mod: ?*std.Build.Module = null;
    if (with_otel) {
        if (b.lazyDependency("otel", .{
            .target = target,
            .optimize = optimize,
        })) |otel_dep| {
            const m = otel_dep.module("otel");
            otel_mod = m;
            // The seam itself imports `otel` when enabled.
            observability_mod.addImport("otel", m);

            // Bootstrap helper. Only registered when `-Dwith_otel=true`
            // so the disabled build never compiles otel-touching code.
            // Gated from root.zig via
            // `if (observability.enabled) @import("observability_init")`.
            observability_init_mod = b.addModule("observability_init", .{
                .root_source_file = b.path("src/observability_init.zig"),
                .target = target,
                .optimize = optimize,
                .imports = allocImports(b, &.{
                    .{ .name = "otel", .module = m },
                    .{ .name = "observability", .module = observability_mod },
                }),
            });
        }
    }

    return .{
        .wal_mod = wal_dep.module("wal"),
        .uuid_mod = uuid_dep.module("uuid"),
        .thread_pool_mod = thread_pool_dep.module("thread_pool"),
        .build_options_mod = build_options_mod,
        .observability_mod = observability_mod,
        .otel_mod = otel_mod,
        .observability_init_mod = observability_init_mod,
    };
}

fn allocImports(b: *std.Build, imports: []const Import) []Import {
    return b.allocator.dupe(Import, imports) catch @panic("out of memory");
}

fn createModule(
    b: *std.Build,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: OptimizeMode,
    imports: []const Import,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = allocImports(b, imports),
    });
}

/// Build the standard import list for any test/exe rooted at `src/root.zig`.
/// Centralised so the unit-test target, check step, and any other root.zig
/// consumer share the same wiring (including the observability seam).
fn rootImports(deps: Deps) [5]Import {
    return .{
        .{ .name = "wal", .module = deps.wal_mod },
        .{ .name = "uuid", .module = deps.uuid_mod },
        .{ .name = "thread_pool", .module = deps.thread_pool_mod },
        .{ .name = "observability", .module = deps.observability_mod },
        .{ .name = "build_options", .module = deps.build_options_mod },
    };
}

fn addUnitTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: OptimizeMode, deps: Deps, test_step: *std.Build.Step) void {
    const root_imports = rootImports(deps);
    const test_filter = b.option([]const u8, "test-filter", "Only run unit tests whose name contains this substring");
    const unit_tests = b.addTest(.{
        .root_module = createModule(b, "src/root.zig", target, optimize, &root_imports),
        .filters = if (test_filter) |f| b.dupeStrings(&.{f}) else &.{},
    });
    if (deps.observability_init_mod) |m| unit_tests.root_module.addImport("observability_init", m);
    if (deps.otel_mod) |m| unit_tests.root_module.addImport("otel", m);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // The benchmark gate's comparison logic (benchmarks/compare.zig) is
    // plain std code: unit-test it with the rest so CI's benchmark jobs
    // cannot silently gate on noise again.
    const compare_bench_tests = b.addTest(.{
        .root_module = createModule(b, "benchmarks/compare.zig", target, optimize, &.{}),
    });
    test_step.dependOn(&b.addRunArtifact(compare_bench_tests).step);
}

fn addIntegrationTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: OptimizeMode,
    graph_storage_mod: *std.Build.Module,
    seed_mod: *std.Build.Module,
    deps: Deps,
) void {
    const integration_step = b.step("test-integration", "Run integration tests");
    const integration_tests = b.addTest(.{
        .root_module = createModule(b, "tests/integration.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
            .{ .name = "seed", .module = seed_mod },
            .{ .name = "wal", .module = deps.wal_mod },
            .{ .name = "uuid", .module = deps.uuid_mod },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    integration_step.dependOn(&run_integration_tests.step);

    const fuzz_regression_step = b.step("test-fuzz-regression", "Run deterministic fuzz-regression tests");
    const fuzz_regression_tests = b.addTest(.{
        .root_module = createModule(b, "tests/fuzz_regression.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_fuzz_regression = b.addRunArtifact(fuzz_regression_tests);
    fuzz_regression_step.dependOn(&run_fuzz_regression.step);

    // H3-P0: order-preserving value encoder — exhaustive all-pairs + fuzz
    // proving encode order == the engine's ORDER BY (entryLess) order.
    const ordered_encoding_step = b.step("test-ordered-encoding", "Run order-preserving value encoder ordering + fuzz tests (H3-P0)");
    const ordered_encoding_tests = b.addTest(.{
        .root_module = createModule(b, "tests/ordered_encoding_test.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_ordered_encoding = b.addRunArtifact(ordered_encoding_tests);
    ordered_encoding_step.dependOn(&run_ordered_encoding.step);

    // H3-P1 Task 1: byte-key ordered B+Tree with a lazy ASC/DESC cursor.
    // Own step so the data-structure correctness proofs (forward == std.sort
    // ascending, reverse == descending, seek-first->= , remove, serialize
    // round-trip, no-leak) run in isolation and can be looped.
    const ordered_btree_step = b.step("test-ordered-btree", "Run byte-key ordered B+Tree + lazy ASC/DESC cursor tests (H3-P1)");
    const ordered_btree_tests = b.addTest(.{
        .root_module = createModule(b, "tests/ordered_btree_test.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_ordered_btree = b.addRunArtifact(ordered_btree_tests);
    ordered_btree_step.dependOn(&run_ordered_btree.step);

    // H3-P1 Task 2: per-(label,key) ordered property index (register/insert/
    // remove/openCursor/save/load). Own step so the ASC/DESC ordering, skip-not-
    // orderable, and save->load round-trip proofs run in isolation.
    const ordered_property_index_step = b.step("test-ordered-property-index", "Run per-(label,key) ordered property index tests (H3-P1 Task 2)");
    const ordered_property_index_tests = b.addTest(.{
        .root_module = createModule(b, "tests/ordered_property_index_test.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_ordered_property_index = b.addRunArtifact(ordered_property_index_tests);
    ordered_property_index_step.dependOn(&run_ordered_property_index.step);

    // H3-P4 Task A1: ordered-index freshness signal. Own step so the
    // register/write/rebuild staleness proofs run in isolation.
    const ordered_freshness_step = b.step("test-ordered-freshness", "Run ordered-index freshness signal tests (stale until rebuilt at durability boundary) (H3-P4)");
    const ordered_freshness_tests = b.addTest(.{
        .root_module = createModule(b, "tests/ordered_freshness_test.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_ordered_freshness = b.addRunArtifact(ordered_freshness_tests);
    ordered_freshness_step.dependOn(&run_ordered_freshness.step);

    // H3-P4 Task A2/A3: ordered-index close() durability lifecycle. Own step so
    // the rebuild-before-save (#1) + persist-on-not-dirty (#2) proofs run in
    // isolation and can be looped.
    const ordered_lifecycle_step = b.step("test-ordered-lifecycle", "Run ordered-index close() durability lifecycle tests (rebuild-before-save + persist-on-light-ckpt) (H3-P4)");
    const ordered_lifecycle_tests = b.addTest(.{
        .root_module = createModule(b, "tests/ordered_lifecycle_test.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_ordered_lifecycle = b.addRunArtifact(ordered_lifecycle_tests);
    ordered_lifecycle_step.dependOn(&run_ordered_lifecycle.step);

    const cross_shard_step = b.step("test-cross-shard-recovery", "Run cross-shard 2PC crash recovery tests");
    const cross_shard_tests = b.addTest(.{
        .root_module = createModule(b, "tests/cross_shard_recovery.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_cross_shard = b.addRunArtifact(cross_shard_tests);
    cross_shard_step.dependOn(&run_cross_shard.step);

    // Lever B: a CLEAN restart LOADS the persisted derived-index snapshots
    // (no O(graph) rebuild) while a CRASH restart is STILL forced to rebuild.
    // Own step so the load-on-clean / rebuild-on-crash proofs run in isolation.
    const leverb_step = b.step("test-leverb-clean-restart", "Run Lever B clean-restart-loads / crash-restart-rebuilds derived-index tests");
    const leverb_tests = b.addTest(.{
        .root_module = createModule(b, "tests/leverb_clean_restart.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_leverb = b.addRunArtifact(leverb_tests);
    leverb_step.dependOn(&run_leverb.step);

    // Phase A (engine early-ready): open returns query-READY without building the
    // O(nodes+edges) derived indexes; first-access lazy materialization (load or
    // rebuild) exactly once, concurrency-safe, crash-safe. Own step.
    const early_ready_step = b.step("test-engine-early-ready", "Run Phase A engine early-ready + lazy derived-index materialization tests");
    const early_ready_tests = b.addTest(.{
        .root_module = createModule(b, "tests/engine_early_ready.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_early_ready = b.addRunArtifact(early_ready_tests);
    early_ready_step.dependOn(&run_early_ready.step);

    // TSan variant: validates the build-once latch (atomic done flag + Io.Mutex)
    // serialises concurrent first-accesses with zero data races. Debug optimize
    // so the optimiser does not elide instrumented accesses.
    const early_ready_tsan_step = b.step("test-engine-early-ready-tsan", "Run Phase A early-ready lazy-materialization suite under ThreadSanitizer (zero races expected)");
    const early_ready_tsan_tests = b.addTest(.{
        .root_module = createModule(b, "tests/engine_early_ready.zig", target, .Debug, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
        // Zig 0.16's self-hosted x86_64 backend (the Debug default) ignores
        // sanitize_thread, so without LLVM this step runs uninstrumented.
        .use_llvm = true,
    });
    early_ready_tsan_tests.root_module.sanitize_thread = true;
    const run_early_ready_tsan = b.addRunArtifact(early_ready_tsan_tests);
    early_ready_tsan_step.dependOn(&run_early_ready_tsan.step);

    // SONNY-6375: concurrent readers bump read counters; the bump must not be
    // a plain read-modify-write. The plain step proves no read is lost, the
    // TSan step (LLVM backend, Debug) proves there is no data race.
    const read_metrics_step = b.step("test-concurrent-read-metrics", "Run concurrent-reader metric counter regression (no lost reads)");
    const read_metrics_tests = b.addTest(.{
        .root_module = createModule(b, "tests/concurrent_read_metrics.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_read_metrics = b.addRunArtifact(read_metrics_tests);
    read_metrics_step.dependOn(&run_read_metrics.step);
    integration_step.dependOn(&run_read_metrics.step);

    const read_metrics_tsan_step = b.step("test-concurrent-read-metrics-tsan", "Run concurrent-reader metric counter regression under ThreadSanitizer (zero races expected)");
    const read_metrics_tsan_tests = b.addTest(.{
        .root_module = createModule(b, "tests/concurrent_read_metrics.zig", target, .Debug, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
        // Zig 0.16's self-hosted x86_64 backend (the Debug default) ignores
        // sanitize_thread, so without LLVM this step runs uninstrumented.
        .use_llvm = true,
    });
    read_metrics_tsan_tests.root_module.sanitize_thread = true;
    const run_read_metrics_tsan = b.addRunArtifact(read_metrics_tsan_tests);
    read_metrics_tsan_step.dependOn(&run_read_metrics_tsan.step);

    // H3-P1 Task 3: crash-safe engine integration of the value-ordered index.
    // Own step so the load-on-clean / rebuild-on-crash proofs (mirroring Lever B)
    // run in isolation and can be looped.
    const ordered_recovery_step = b.step("test-ordered-index-recovery", "Run ordered-index crash-safety (clean restart LOADS / crash restart REBUILDS) tests (H3-P1 Task 3)");
    const ordered_recovery_tests = b.addTest(.{
        .root_module = createModule(b, "tests/ordered_index_recovery_test.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_ordered_recovery = b.addRunArtifact(ordered_recovery_tests);
    ordered_recovery_step.dependOn(&run_ordered_recovery.step);

    // H3-P1: CHECKPOINT-REFRESH of the value-ordered index. Own step so the
    // stale-before / correct-after-full / clean-reload / light-no-refresh proofs
    // (mirroring engine_property_index.refreshLive) run in isolation.
    const ordered_refresh_step = b.step("test-ordered-index-refresh", "Run ordered-index checkpoint-refresh tests (in-place value drift corrected at FULL checkpoint)");
    const ordered_refresh_tests = b.addTest(.{
        .root_module = createModule(b, "tests/ordered_index_refresh_test.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_ordered_refresh = b.addRunArtifact(ordered_refresh_tests);
    ordered_refresh_step.dependOn(&run_ordered_refresh.step);

    // PHASE 3: engine edge-EXISTENCE index (durable O(1) MERGE-dedup probe).
    // Own step so the crash-recovery + idempotency + O(1)-not-O(degree) proofs
    // can be run in isolation under ReleaseSafe/Debug and looped.
    const edge_exist_step = b.step("test-edge-existence-index", "Run edge-existence-index tests (durable O(1) dedup probe; crash-recovery; idempotency)");
    const edge_exist_tests = b.addTest(.{
        .root_module = createModule(b, "tests/test_edge_existence_index.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_edge_exist = b.addRunArtifact(edge_exist_tests);
    edge_exist_step.dependOn(&run_edge_exist.step);

    const integration_sharded_step = b.step("test-integration-sharded", "Run sharded-engine integration tests");
    const integration_sharded_tests = b.addTest(.{
        .root_module = createModule(b, "tests/integration_sharded.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_integration_sharded = b.addRunArtifact(integration_sharded_tests);
    integration_sharded_step.dependOn(&run_integration_sharded.step);

    // Parallel shard-open recovery: correctness (rebuildDerivedIndexes on every
    // shard must reproduce ground-truth state) + the concurrent-openers gauge
    // proving the open loop is N-wide. Own step so it can be run in isolation
    // and looped under -Doptimize=ReleaseSafe/Debug.
    const parallel_open_step = b.step("test-parallel-shard-open", "Run parallel shard-open recovery correctness + concurrency-gauge test");
    const parallel_open_tests = b.addTest(.{
        .root_module = createModule(b, "tests/parallel_shard_open.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_parallel_open = b.addRunArtifact(parallel_open_tests);
    parallel_open_step.dependOn(&run_parallel_open.step);

    // TSan variant of the parallel-shard-open hardening suite. Runs the same
    // test file under ThreadSanitizer (sanitize_thread = true) compiled at
    // Debug optimize so races are not elided by the optimiser. Detects data
    // races in the parallel open loop (worker threads writing ok[]/err_slots[]
    // into distinct slots, gauge CAS, etc.). EXIT=0 and no race report = clean.
    const tsan_parallel_open_step = b.step("test-parallel-shard-open-tsan", "Run parallel shard-open hardening suite under ThreadSanitizer (zero races expected)");
    const tsan_parallel_open_tests = b.addTest(.{
        // Always Debug so the optimiser does not elide instrumented accesses.
        .root_module = createModule(b, "tests/parallel_shard_open.zig", target, .Debug, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
        // Zig 0.16's self-hosted x86_64 backend (the Debug default) ignores
        // sanitize_thread, so without LLVM this step runs uninstrumented.
        .use_llvm = true,
    });
    tsan_parallel_open_tests.root_module.sanitize_thread = true;
    const run_tsan_parallel_open = b.addRunArtifact(tsan_parallel_open_tests);
    tsan_parallel_open_step.dependOn(&run_tsan_parallel_open.step);

    // Edge co-location (Phase A): single-shard edge write + scatter expandIn +
    // page-image-redo recovery of the per-shard in-index. Own step so the
    // reverse-traversal correctness + recovery proofs run in isolation.
    const edge_colocation_step = b.step("test-edge-colocation", "Run edge co-location tests (single-shard write, scatter expandIn, recovery of the per-shard in-index)");
    const edge_colocation_tests = b.addTest(.{
        .root_module = createModule(b, "tests/edge_colocation.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_edge_colocation = b.addRunArtifact(edge_colocation_tests);
    edge_colocation_step.dependOn(&run_edge_colocation.step);

    // Edge co-location (Phase B): migration of a pre-co-location (legacy) graph.
    // Rebuilds adj_in_remote from adj_out on open when layout_version < 1, then
    // stamps the version. Own step so the migration + idempotency + crash-safety
    // proofs run in isolation.
    const edge_colocation_migration_step = b.step("test-edge-colocation-migration", "Run edge co-location MIGRATION tests (legacy-graph rebuild on open; idempotent; crash-safe)");
    const edge_colocation_migration_tests = b.addTest(.{
        .root_module = createModule(b, "tests/edge_colocation_migration.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_edge_colocation_migration = b.addRunArtifact(edge_colocation_migration_tests);
    edge_colocation_migration_step.dependOn(&run_edge_colocation_migration.step);

    // Concurrency regression for the buffer-pool dirty-eviction race. Its own
    // step so it can be run in isolation under -Doptimize=ReleaseSafe/Debug and
    // looped (--count) to shake the timing window.
    const evict_race_step = b.step("test-evict-race", "Run buffer-pool dirty-eviction race regression");
    const evict_race_tests = b.addTest(.{
        .root_module = createModule(b, "tests/buffer_pool_evict_race.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_evict_race = b.addRunArtifact(evict_race_tests);
    evict_race_step.dependOn(&run_evict_race.step);

    // Concurrency SCALING regression for the buffer-pool cache-HIT pin/unpin
    // path. Own step so it can be run under -Doptimize=ReleaseFast (clean
    // throughput signal) / ReleaseSafe (invariants armed) and looped.
    const pin_scaling_step = b.step("test-pin-scaling", "Run buffer-pool cache-hit pin/unpin scaling regression");
    const pin_scaling_tests = b.addTest(.{
        .root_module = createModule(b, "tests/buffer_pool_pin_scaling.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_pin_scaling = b.addRunArtifact(pin_scaling_tests);
    pin_scaling_step.dependOn(&run_pin_scaling.step);

    // FIX #2 (edge-ingest wedge): the pin slow path must NEVER deadlock under
    // high concurrency when the working set vastly exceeds the pool. Own step so
    // it can be looped (20x) under ReleaseSafe (invariants armed) / ReleaseFast.
    const pin_nodeadlock_step = b.step("test-pin-nodeadlock", "Run buffer-pool pin no-deadlock stress (working set >> pool, threads >> frames)");
    const pin_nodeadlock_tests = b.addTest(.{
        .root_module = createModule(b, "tests/buffer_pool_pin_nodeadlock.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_pin_nodeadlock = b.addRunArtifact(pin_nodeadlock_tests);
    pin_nodeadlock_step.dependOn(&run_pin_nodeadlock.step);

    // GAP-ENT-0018: the lock-free pin page-table read must stay safe against a
    // concurrent structural writer AND must never dereference a freed/moved
    // page-table backing store. Own step so it can be looped under ReleaseSafe
    // (invariants armed) / ReleaseFast.
    const recreate_uaf_step = b.step("test-recreate-uaf", "Run buffer-pool pin-vs-structural-write / page-table-free UAF regression");
    const recreate_uaf_tests = b.addTest(.{
        .root_module = createModule(b, "tests/buffer_pool_recreate_uaf.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_recreate_uaf = b.addRunArtifact(recreate_uaf_tests);
    recreate_uaf_step.dependOn(&run_recreate_uaf.step);

    // SONNY-6438: concurrent readers over a store far larger than the pool —
    // the lock-free pin fast path racing slow-path page-table inserts and
    // evictions (geode's parallel UNION shape). Every read is verified; the
    // TSan variant must report nothing.
    const concurrent_readers_step = b.step("test-buffer-pool-concurrent-readers", "Run concurrent readers over a store larger than the buffer pool (plaintext + encrypted), verifying every node and property read");
    const concurrent_readers_tests = b.addTest(.{
        .root_module = createModule(b, "tests/buffer_pool_concurrent_readers.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_concurrent_readers = b.addRunArtifact(concurrent_readers_tests);
    concurrent_readers_step.dependOn(&run_concurrent_readers.step);
    integration_step.dependOn(&run_concurrent_readers.step);

    const concurrent_readers_tsan_step = b.step("test-buffer-pool-concurrent-readers-tsan", "Run the buffer-pool concurrent-readers suite under ThreadSanitizer (zero races expected)");
    const concurrent_readers_tsan_tests = b.addTest(.{
        .root_module = createModule(b, "tests/buffer_pool_concurrent_readers.zig", target, .Debug, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
        // Zig 0.16's self-hosted x86_64 backend (the Debug default) ignores
        // sanitize_thread, so without LLVM this step runs uninstrumented.
        .use_llvm = true,
    });
    concurrent_readers_tsan_tests.root_module.sanitize_thread = true;
    const run_concurrent_readers_tsan = b.addRunArtifact(concurrent_readers_tsan_tests);
    concurrent_readers_tsan_step.dependOn(&run_concurrent_readers_tsan.step);

    // GAP-ENT-0020 Phase P0: prop-store slab-packing FOUNDATION — props-store
    // efficiency metric (one-page-per-node baseline), property-set parity oracle,
    // and the read-both parity skeleton (legacy half passing; slab half TODO for
    // P1). Own step so the baseline metric is easy to re-run and diff against as
    // the slab write path lands. No production format change in P0.
    const prop_store_slab_step = b.step("test-prop-store-slab", "Run prop-store slab-packing P0: efficiency metric + parity oracle + read-both skeleton");
    const prop_store_slab_tests = b.addTest(.{
        .root_module = createModule(b, "tests/prop_store_slab.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_prop_store_slab = b.addRunArtifact(prop_store_slab_tests);
    prop_store_slab_step.dependOn(&run_prop_store_slab.step);

    // Property-value OVERFLOW (tag 7): values larger than the per-page entry
    // budget spill into a LEGACY var-store chain and leave a 13-byte stub in
    // the property entry. Own step covering the round-trip/boundary/mixed-chain
    // matrix, overwrite + delete free discipline, slab-resident overflow and
    // slab→legacy relocation, property-index consistency, crash/WAL replay,
    // backward compatibility, and the error identities (PropertyKeyTooLong vs
    // PropertyValueTooLarge).
    const prop_store_overflow_step = b.step("test-prop-store-overflow", "Run property-value overflow tests: round-trip, boundary, free discipline, index, crash replay, compat");
    const prop_store_overflow_tests = b.addTest(.{
        .root_module = createModule(b, "tests/prop_store_overflow.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_prop_store_overflow = b.addRunArtifact(prop_store_overflow_tests);
    prop_store_overflow_step.dependOn(&run_prop_store_overflow.step);

    // GAP var-store slab packing P2 — WRITE-path acceptance gates: bytes/node
    // re-measure, slab-vs-legacy parity, on-disk reopen, WAL imaging
    // (logVarChain slab-aware), the crash gate (committed slab labels/strings
    // survive a deinit-crash; uncommitted is invisible; every var_head live),
    // clean-shutdown, and graduation-across-crash.
    const var_store_slab_step = b.step("test-var-store-slab", "Run var-store slab-packing P2: bytes/node, parity, reopen, WAL imaging, and crash/graduation gates");
    const var_store_slab_tests = b.addTest(.{
        .root_module = createModule(b, "tests/var_store_slab.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_var_store_slab = b.addRunArtifact(var_store_slab_tests);
    var_store_slab_step.dependOn(&run_var_store_slab.step);

    // GAP edge-inline-public-id P0/P1 — baseline oracle for the per-edge
    // `__geode_internal_edge_id` LEGACY property cost (one ≥8 KB props page
    // per edge) + parity oracle over full edge enumeration, and the v1/v2
    // adjacency-block read-both tests (per-block `entry_format`
    // discriminator). The baseline scenario stays green through all phases:
    // legacy stores keep working forever.
    const edge_inline_pubid_step = b.step("test-edge-inline-public-id", "Run inline-public-edge-id tests: legacy per-edge id-property baseline (bytes/edge lock-in + parity oracle) and v1/v2 adjacency block read-both");
    const edge_inline_pubid_tests = b.addTest(.{
        .root_module = createModule(b, "tests/edge_inline_public_id.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_edge_inline_pubid = b.addRunArtifact(edge_inline_pubid_tests);
    edge_inline_pubid_step.dependOn(&run_edge_inline_pubid.step);

    // GAP adjacency-slab-packing P0/P1 — baseline oracle for the
    // block-per-chain adjacency cost (~16.5 KB/edge for low-fanout graphs) +
    // enumeration parity both directions (out-chain walk + FanInEdgeIterator
    // scatter), and the slab-block read path (tagged bit-63 (block,slot) head
    // refs; slot-directory runs of v2 entries; recovery-harvest coverage).
    // The baseline scenario stays green through all phases: legacy chains
    // keep working forever.
    const adjacency_slab_step = b.step("test-adjacency-slab", "Run adjacency slab-packing tests: block-per-chain baseline lock-in (bytes/edge + parity oracle) and slab-block read-both (tagged heads, slot runs, harvest)");
    const adjacency_slab_tests = b.addTest(.{
        .root_module = createModule(b, "tests/adjacency_slab.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_adjacency_slab = b.addRunArtifact(adjacency_slab_tests);
    adjacency_slab_step.dependOn(&run_adjacency_slab.step);

    // GAP adjacency-slab-packing P3 — consumer sweep: every path that READS
    // adjacency stays slab-transparent. Backup/restore byte-copy round-trip,
    // derived edge-index rebuild from a slab adj_out, FanIn-source
    // (adj_in_remote) rebuild, and the integrity walk over slab chains.
    const adjacency_slab_consumers_step = b.step("test-adjacency-slab-consumers", "Run adjacency slab-packing P3 consumer sweep: backup/restore round-trip, derived edge-index rebuild, FanIn-source rebuild, integrity walk over slab chains");
    const adjacency_slab_consumers_tests = b.addTest(.{
        .root_module = createModule(b, "tests/adjacency_slab_consumers.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_adjacency_slab_consumers = b.addRunArtifact(adjacency_slab_consumers_tests);
    adjacency_slab_consumers_step.dependOn(&run_adjacency_slab_consumers.step);

    // GAP adjacency-slab-packing P4 — crash/WAL matrix for the hottest
    // structure: relocation, graduation, slab remove/update (tombstone),
    // deferred-WAL tail + harvest, and a mixed legacy+slab store. Each builds,
    // crashes (deinit without checkpoint — only the fsynced WAL survives),
    // reopens, and asserts full parity with no dangling head / no lost edge.
    const adjacency_slab_crash_step = b.step("test-adjacency-slab-crash", "Run adjacency slab-packing P4 crash matrix: relocation/graduation/tombstone/deferred-tail/mixed — kill+reopen parity, no dangling head");
    const adjacency_slab_crash_tests = b.addTest(.{
        .root_module = createModule(b, "tests/adjacency_slab_crash.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_adjacency_slab_crash = b.addRunArtifact(adjacency_slab_crash_tests);
    adjacency_slab_crash_step.dependOn(&run_adjacency_slab_crash.step);

    // GAP-ENT-0011 — free-space map vs WAL-tail allocations. Crash-restart
    // tests proving pages allocated after the last checkpoint and recovered
    // from the WAL tail are marked ALLOCATED in the restored free-space map
    // (no double allocation of live pages, no invisible recovered nodes),
    // including across a double crash before the next checkpoint.
    const free_space_wal_tail_step = b.step("test-free-space-wal-tail", "Run free-space WAL-tail crash-recovery tests: recovered pages stay allocated, aggressive post-reopen allocation preserves full pre-crash parity");
    const free_space_wal_tail_tests = b.addTest(.{
        .root_module = createModule(b, "tests/free_space_wal_tail.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_free_space_wal_tail = b.addRunArtifact(free_space_wal_tail_tests);
    free_space_wal_tail_step.dependOn(&run_free_space_wal_tail.step);

    // GAP-ENT-0032 — committed edge REMOVE in a non-head adjacency block must
    // stay deleted across a crash. removeEdgeTxn WAL-images the block the
    // removal actually mutated (same class as the GAP-ENT-0011 logVarChain
    // label fix), otherwise older WAL images of that page resurrect the edge
    // with its old public_id.
    const edge_remove_crash_step = b.step("test-edge-remove-crash", "Run edge-remove crash-recovery tests: a committed remove whose entry lives in a non-head adjacency block stays deleted after WAL replay (both directions, exact surviving public_ids)");
    const edge_remove_crash_tests = b.addTest(.{
        .root_module = createModule(b, "tests/edge_remove_crash.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_edge_remove_crash = b.addRunArtifact(edge_remove_crash_tests);
    edge_remove_crash_step.dependOn(&run_edge_remove_crash.step);

    // WAL-recovery counter staleness — recovery replays committed WAL-tail
    // page images but left manifest.next_node_id/next_edge_id/next_txn_id at
    // checkpoint-era values: replayed records invisible to counter-bounded
    // scans AND their slots re-issued to new writes (silent overwrite of
    // committed data). Crash-restart tests proving the counters are
    // re-derived from the replayed images, persisted crash-safely, and never
    // re-issue a live slot (single-engine + sharded stride).
    const wal_recovery_counters_step = b.step("test-wal-recovery-counters", "Run WAL-recovery counter-staleness crash tests: manifest id counters re-derived from the replayed tail, scans see every committed record, aggressive creates never re-issue a replayed slot, double-crash safe");
    const wal_recovery_counters_tests = b.addTest(.{
        .root_module = createModule(b, "tests/wal_recovery_counters.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_wal_recovery_counters = b.addRunArtifact(wal_recovery_counters_tests);
    wal_recovery_counters_step.dependOn(&run_wal_recovery_counters.step);

    // WAL sequence anchor (SONNY-6424) — a checkpoint that empties the WAL
    // followed by a process exit without close used to restart the inner log
    // numbering at 0 below last_checkpoint_lsn, so the next crash recovery
    // skipped (or tore) every record written after the reopen. Crash tests,
    // including an upgrade from a store already in that state on disk.
    const wal_lsn_anchor_step = b.step("test-wal-lsn-anchor-crash", "Run WAL sequence-anchor crash tests: checkpoint empties the WAL, exit without close, reopen, write, crash — every committed write survives (incl. upgrade of an already-renumbered WAL)");
    const wal_lsn_anchor_tests = b.addTest(.{
        .root_module = createModule(b, "tests/wal_lsn_anchor_crash.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
            .{ .name = "wal", .module = deps.wal_mod },
        }),
    });
    const run_wal_lsn_anchor = b.addRunArtifact(wal_lsn_anchor_tests);
    wal_lsn_anchor_step.dependOn(&run_wal_lsn_anchor.step);

    // At-rest encryption page tail (SONNY-6441) — the pager stores the AES-GCM
    // tag in the last 16 bytes of every encrypted page; fixed-record layouts
    // that reached the page end lost those bytes on every write + reload
    // (eviction, reopen, crash recovery): committed nodes read back missing.
    const tde_page_tail_step = b.step("test-tde-page-tail", "Run at-rest encryption page-tail tests: every committed node, property, incoming-edge head and adjacency entry survives eviction, reopen and crash recovery; a page failing authentication is an error, never a missing node");
    const tde_page_tail_tests = b.addTest(.{
        .root_module = createModule(b, "tests/tde_page_tail.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_tde_page_tail = b.addRunArtifact(tde_page_tail_tests);
    tde_page_tail_step.dependOn(&run_tde_page_tail.step);

    // SONNY-6461: restore the adjacency entries a <= 0.4.11 encrypted store
    // lost to the AES-GCM tag tail, from the same edge's other-direction copy.
    const adj_tail_repair_step = b.step("test-adj-tail-repair", "Run legacy TDE page-tail adjacency repair tests: entries lost by <= 0.4.11 encrypted stores (v3 at 4 KiB, v1 at 8 KiB) are restored from their mirror; unrepairable ones are reported");
    const adj_tail_repair_tests = b.addTest(.{
        .root_module = createModule(b, "tests/adj_tail_repair.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_adj_tail_repair = b.addRunArtifact(adj_tail_repair_tests);
    adj_tail_repair_step.dependOn(&run_adj_tail_repair.step);

    // SONNY-6461: page checksum on the CPU's CRC32C instruction, bit-identical
    // to the table implementation.
    const page_checksum_step = b.step("test-page-checksum", "Run page checksum tests: CRC32C uses the CPU instruction where present and stays bit-identical to the table");
    const page_checksum_tests = b.addTest(.{
        .root_module = createModule(b, "tests/page_checksum.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_page_checksum = b.addRunArtifact(page_checksum_tests);
    page_checksum_step.dependOn(&run_page_checksum.step);

    // SONNY-6461: offline (engine-less) reader for a graph's free.store.
    const free_store_offline_step = b.step("test-free-store-offline", "Run offline free.store reader tests: an engine-less tool reads every store's free-page bitmap, matching the engine's");
    const free_store_offline_tests = b.addTest(.{
        .root_module = createModule(b, "tests/free_store_offline.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_free_store_offline = b.addRunArtifact(free_store_offline_tests);
    free_store_offline_step.dependOn(&run_free_store_offline.step);

    // checkpoint_epoch invariant — the durable derived-index freshness token
    // must advance ONLY at checkpoint and stay UNCHANGED across a pure WAL-tail
    // recovery (unlike manifest.counter, which recovery bumps for A/B
    // freshness). This is the core invariant the WAL-aware derived-index
    // durability contract rests on.
    const checkpoint_epoch_step = b.step("test-checkpoint-epoch", "Run checkpoint_epoch invariant test: epoch advances only at checkpoint, never across WAL-tail recovery");
    const checkpoint_epoch_tests = b.addTest(.{
        .root_module = createModule(b, "tests/test_checkpoint_epoch.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_checkpoint_epoch = b.addRunArtifact(checkpoint_epoch_tests);
    checkpoint_epoch_step.dependOn(&run_checkpoint_epoch.step);

    // Label WAL imaging — regression guards for the raw-ref vs page-id
    // confusion on the label var-chain write paths (addLabelTxn /
    // removeLabelTxn image the FULL chain via logVarChain + the node page).
    // Crash tests: add+remove replay to the exact label set, last-label
    // removal replays label_head=0, MULTI-PAGE chains replay byte-exactly.
    const label_crash_replay_step = b.step("test-label-crash-replay", "Run label WAL-imaging crash tests: crash-window label add/remove (incl. multi-page var chains) replays to the exact label set");
    const label_crash_replay_tests = b.addTest(.{
        .root_module = createModule(b, "tests/label_crash_replay.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_label_crash_replay = b.addRunArtifact(label_crash_replay_tests);
    label_crash_replay_step.dependOn(&run_label_crash_replay.step);

    // Edge-prop-head WAL under-logging — setEdgeProperty rewrites prop_heads
    // in-place in possibly NON-HEAD adjacency blocks of BOTH chains; the
    // mutated pages must be WAL-imaged in the SAME txn as the property
    // write or the committed property silently vanishes on crash replay.
    const edge_prop_crash_step = b.step("test-edge-prop-crash", "Run edge-property crash tests: committed setEdgeProperty on non-head adjacency blocks (both directions) survives WAL replay, incl. older-image resurrection in the same tail");
    const edge_prop_crash_tests = b.addTest(.{
        .root_module = createModule(b, "tests/edge_prop_crash.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_edge_prop_crash = b.addRunArtifact(edge_prop_crash_tests);
    edge_prop_crash_step.dependOn(&run_edge_prop_crash.step);

    // GAP warm-reopen P1 — mmap-adopted edge-index snapshots (GSEIDX4/GSXIDX2):
    // clean-reopen adopt, checkpoint merge (base + overlay - tombstones),
    // dirty-gate no-op persist, crash-rebuild via counter gate, corrupt/
    // truncated-snapshot reject, lazy payload-CRC failure model, and the
    // 1M-edge load bench (legacy read+build vs mmap-adopt).
    const mmap_index_step = b.step("test-mmap-index-snapshot", "Run mmap-adopted edge-index snapshot tests: adopt-on-clean-reopen, checkpoint merge, dirty-gate, crash/corruption recovery, 1M-edge load bench");
    const mmap_index_tests = b.addTest(.{
        .root_module = createModule(b, "tests/mmap_index_snapshot.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_mmap_index = b.addRunArtifact(mmap_index_tests);
    mmap_index_step.dependOn(&run_mmap_index.step);

    // GAP warm-reopen P2 — cross-index checkpoint-counter restamp: an
    // edges-only session keeps every clean snapshot loadable (no O(graph)
    // rebuild on the next open), dirty-never-restamped, torn-restamp crash
    // window rejected, crash-stale + never-hydrated safety gate (no restamp
    // blessing of stale snapshots).
    const derived_restamp_step = b.step("test-derived-restamp", "Run derived-index counter-restamp tests: clean-snapshot restamp on full checkpoint, dirty-never-restamped, torn-restamp reject, crash-stale safety gate");
    const derived_restamp_tests = b.addTest(.{
        .root_module = createModule(b, "tests/derived_restamp.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_derived_restamp = b.addRunArtifact(derived_restamp_tests);
    derived_restamp_step.dependOn(&run_derived_restamp.step);

    // WAL-aware derived-index durability (Path B) Phase 2 — the epoch-gate
    // acceptance proofs: a no-tail clean reopen LOADS via the epoch (rebuild==0),
    // and a crash-tail reopen whose epoch MATCHES (not counter-rejected) is
    // counted as a tail-deferral and routed to a CORRECT rebuild (never stale).
    const epoch_gate_step = b.step("test-derived-epoch-gate", "Run WAL-aware derived-index epoch-gate tests: no-tail reload via epoch, tail-present epoch-match routed to a correct rebuild");
    const epoch_gate_tests = b.addTest(.{
        .root_module = createModule(b, "tests/derived_index_epoch_gate.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_epoch_gate = b.addRunArtifact(epoch_gate_tests);
    epoch_gate_step.dependOn(&run_epoch_gate.step);

    // WAL-aware derived-index durability (Path B) Phase 3 — the RELEASE GATE:
    // rebuild-equivalence of the bounded WAL-tail reconcile (insert / in-place
    // property VALUE change / DELETED node / removed edge) for a clean-shutdown
    // tail AND a kill-9 crash tail.
    const tail_reconcile_step = b.step("test-index-tail-reconcile", "Run WAL-aware derived-index tail-reconcile == full-rebuild property tests (clean + crash tail)");
    const tail_reconcile_tests = b.addTest(.{
        .root_module = createModule(b, "tests/test_index_tail_reconcile.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_tail_reconcile = b.addRunArtifact(tail_reconcile_tests);
    tail_reconcile_step.dependOn(&run_tail_reconcile.step);

    // Review F-5 (GAP-ENT-0011): CI runs `zig build test`, `test-integration`
    // and `test-fuzz-regression` only — standalone named steps never run
    // there. Silent-corruption crash-recovery regression guards must be gated,
    // so hang both suites under the `test-integration` umbrella as well (they
    // remain individually invokable via their named steps).
    integration_step.dependOn(&run_free_space_wal_tail.step);
    integration_step.dependOn(&run_edge_remove_crash.step);
    integration_step.dependOn(&run_tail_reconcile.step);
    // P1: the mmap-snapshot crash/corruption guards are the same class — gate
    // them under the integration umbrella too.
    integration_step.dependOn(&run_mmap_index.step);
    // P2: the restamp crash/staleness guards likewise.
    integration_step.dependOn(&run_derived_restamp.step);
    // Phase 2 epoch-gate acceptance (no-tail reload + tail-present correct rebuild).
    integration_step.dependOn(&run_epoch_gate.step);
    // WAL-recovery counter healing is the same silent-corruption class.
    integration_step.dependOn(&run_wal_recovery_counters.step);
    // The WAL sequence-anchor crash guards are the same silent-loss class.
    integration_step.dependOn(&run_wal_lsn_anchor.step);
    // The encrypted-page tail guards (SONNY-6441) likewise.
    integration_step.dependOn(&run_tde_page_tail.step);
    integration_step.dependOn(&run_adj_tail_repair.step);
    integration_step.dependOn(&run_page_checksum.step);
    // checkpoint_epoch recovery-invariance is the durability foundation the
    // WAL-aware derived-index contract rests on — gate it under integration.
    integration_step.dependOn(&run_checkpoint_epoch.step);
    // Label WAL-imaging crash guards likewise.
    integration_step.dependOn(&run_label_crash_replay.step);
    integration_step.dependOn(&run_var_store_slab.step);
    // Edge-prop-head under-logging crash guards likewise.
    integration_step.dependOn(&run_edge_prop_crash.step);
    // Adjacency-slab read-both + harvest coverage (silent-counter-staleness
    // class once slab writers land) likewise.
    integration_step.dependOn(&run_adjacency_slab.step);
    // P3 consumer sweep (backup/rebuild/integrity over slab chains) and P4
    // crash matrix (relocation/graduation/tombstone/deferred-tail/mixed) are
    // the release gate for the slab writer — gate both under the umbrella.
    integration_step.dependOn(&run_adjacency_slab_consumers.step);
    integration_step.dependOn(&run_adjacency_slab_crash.step);
    // SONNY-6438: these three rotted outside every gate — two kept asserting
    // pre-GAP-0060 formats, and ordered-index Test B asserted that a
    // committed post-checkpoint write was LOST after a crash.
    integration_step.dependOn(&run_prop_store_slab.step);
    integration_step.dependOn(&run_edge_inline_pubid.step);
    integration_step.dependOn(&run_ordered_recovery.step);
}

fn addExample(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: OptimizeMode,
    graph_storage_mod: *std.Build.Module,
) void {
    const example = b.addExecutable(.{
        .name = "basic-example",
        .root_module = createModule(b, "examples/basic.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(b.getInstallStep());
    const run_step = b.step("run-example", "Run the basic usage example");
    run_step.dependOn(&run_example.step);
}

fn addBenchmarks(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    graph_storage_mod: *std.Build.Module,
    seed_mod: *std.Build.Module,
    deps: Deps,
) void {
    const bench_optimize: OptimizeMode = .ReleaseFast;

    const bench_step = b.step("bench", "Run performance benchmarks");
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = createModule(b, "benchmarks/bench.zig", target, bench_optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
            .{ .name = "wal", .module = deps.wal_mod },
            .{ .name = "uuid", .module = deps.uuid_mod },
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&run_bench.step);

    const load_bench_step = b.step("load-bench", "Run heavy-load benchmarks with Geode-model seeder");
    const load_bench_exe = b.addExecutable(.{
        .name = "load-bench",
        .root_module = createModule(b, "benchmarks/load_bench.zig", target, bench_optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
            .{ .name = "seed", .module = seed_mod },
            .{ .name = "wal", .module = deps.wal_mod },
            .{ .name = "uuid", .module = deps.uuid_mod },
        }),
    });
    const run_load_bench = b.addRunArtifact(load_bench_exe);
    if (b.args) |args| run_load_bench.addArgs(args);
    load_bench_step.dependOn(&run_load_bench.step);

    // SONNY-6461: page checksum (CRC32C) and plaintext vs encrypted readPage.
    const checksum_bench_step = b.step("bench-checksum", "SONNY-6461 page checksum micro-benchmark: CRC32C per 8 KiB page and plaintext vs encrypted readPage (use -Doptimize=ReleaseFast)");
    const checksum_bench_exe = b.addExecutable(.{
        .name = "checksum-bench",
        .root_module = createModule(b, "benchmarks/checksum_bench.zig", target, bench_optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_checksum_bench = b.addRunArtifact(checksum_bench_exe);
    checksum_bench_step.dependOn(&run_checksum_bench.step);

    // GAP-0900: WAL-batch A/B microbench (deferred multi-page txns).
    const wal_batch_ab_step = b.step("bench-wal-batch-ab", "GAP-0900 WAL-batch A/B: deferred multi-page txn throughput + syscall count");
    const wal_batch_ab_exe = b.addExecutable(.{
        .name = "wal-batch-ab",
        .root_module = createModule(b, "benchmarks/wal_batch_ab.zig", target, bench_optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_wal_batch_ab = b.addRunArtifact(wal_batch_ab_exe);
    if (b.args) |args| run_wal_batch_ab.addArgs(args);
    wal_batch_ab_step.dependOn(&run_wal_batch_ab.step);

    const scale_bench_step = b.step("scale-bench", "Run incremental scale benchmarks with JSON output");
    const scale_bench_exe = b.addExecutable(.{
        .name = "scale-bench",
        .root_module = createModule(b, "benchmarks/scale_bench.zig", target, bench_optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
            .{ .name = "seed", .module = seed_mod },
            .{ .name = "wal", .module = deps.wal_mod },
            .{ .name = "uuid", .module = deps.uuid_mod },
        }),
    });
    b.installArtifact(scale_bench_exe);
    const run_scale_bench = b.addRunArtifact(scale_bench_exe);
    if (b.args) |args| run_scale_bench.addArgs(args);
    scale_bench_step.dependOn(&run_scale_bench.step);

    const compare_bench_step = b.step("compare-bench", "Compare benchmark results against a baseline");
    const compare_bench_exe = b.addExecutable(.{
        .name = "compare-bench",
        .root_module = createModule(b, "benchmarks/compare.zig", target, bench_optimize, &.{}),
    });
    const run_compare_bench = b.addRunArtifact(compare_bench_exe);
    if (b.args) |args| run_compare_bench.addArgs(args);
    compare_bench_step.dependOn(&run_compare_bench.step);

    // Shard distribution + put/get throughput vs std.AutoHashMap baseline.
    // See benchmarks/sharded_store_bench.zig for the output format.
    const sharded_bench_step = b.step("bench-sharded-store", "Run ShardedStore distribution + throughput benchmark");
    const sharded_bench_exe = b.addExecutable(.{
        .name = "sharded-store-bench",
        .root_module = createModule(b, "benchmarks/sharded_store_bench.zig", target, bench_optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_sharded_bench = b.addRunArtifact(sharded_bench_exe);
    sharded_bench_step.dependOn(&run_sharded_bench.step);

    // ShardedGraphEngine vs single-engine throughput (Task 16).
    const sharded_throughput_step = b.step("bench-sharded-throughput", "ShardedGraphEngine vs single-engine throughput");
    const sharded_throughput_exe = b.addExecutable(.{
        .name = "sharded-throughput-bench",
        .root_module = createModule(b, "benchmarks/sharded_throughput.zig", target, bench_optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_sharded_throughput = b.addRunArtifact(sharded_throughput_exe);
    sharded_throughput_step.dependOn(&run_sharded_throughput.step);
}

fn addCheckStep(b: *std.Build, target: std.Build.ResolvedTarget, optimize: OptimizeMode, deps: Deps) void {
    const check_step = b.step("check", "Check for compilation errors");
    const root_imports = rootImports(deps);
    const check = b.addTest(.{
        .root_module = createModule(b, "src/root.zig", target, optimize, &root_imports),
    });
    if (deps.observability_init_mod) |m| check.root_module.addImport("observability_init", m);
    if (deps.otel_mod) |m| check.root_module.addImport("otel", m);
    check_step.dependOn(&check.step);
}

// ============================================================================
// Observability seam tests
// ============================================================================
//
// Two test targets:
//
//   - `observability_disabled_test.zig` runs under BOTH flag values. Each
//     test inside it is skip-guarded via
//     `if (graph_storage.observability.enabled) return error.SkipZigTest;`
//     so the disabled-mode invariants only fire when the flag is off.
//
//   - `observability_enabled_test.zig` is registered under both flag
//     values too, but every test inside it skips when the flag is off.
//     The `otel` import is wired only when `with_otel = true`; the
//     stub branch in the test file (`const otel = if (build_options.with_otel) ...`)
//     ensures the file still compiles cleanly under the disabled build.
fn addObservabilityTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: OptimizeMode,
    graph_storage_mod: *std.Build.Module,
    deps: Deps,
    test_step: *std.Build.Step,
) void {
    // Disabled-mode no-op tests. Verifies `build_options.with_otel == false`
    // is the default and that the seam's public surface returns a
    // comptime-known no-op when otel is off.
    const disabled_tests = b.addTest(.{
        .root_module = createModule(b, "tests/observability_disabled_test.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
            .{ .name = "build_options", .module = deps.build_options_mod },
        }),
    });
    const run_disabled_tests = b.addRunArtifact(disabled_tests);
    test_step.dependOn(&run_disabled_tests.step);

    // Enabled-mode smoke test. Skips under -Dwith_otel=false; under
    // -Dwith_otel=true it installs an in-memory recorder, drives one
    // operation span through the seam, and asserts the recorder
    // captured it.
    const enabled_tests = b.addTest(.{
        .root_module = createModule(b, "tests/observability_enabled_test.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
            .{ .name = "build_options", .module = deps.build_options_mod },
        }),
    });
    if (deps.otel_mod) |m| enabled_tests.root_module.addImport("otel", m);
    const run_enabled_tests = b.addRunArtifact(enabled_tests);
    test_step.dependOn(&run_enabled_tests.step);
}
