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
    const unit_tests = b.addTest(.{
        .root_module = createModule(b, "src/root.zig", target, optimize, &root_imports),
    });
    if (deps.observability_init_mod) |m| unit_tests.root_module.addImport("observability_init", m);
    if (deps.otel_mod) |m| unit_tests.root_module.addImport("otel", m);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
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

    const cross_shard_step = b.step("test-cross-shard-recovery", "Run cross-shard 2PC crash recovery tests");
    const cross_shard_tests = b.addTest(.{
        .root_module = createModule(b, "tests/cross_shard_recovery.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_cross_shard = b.addRunArtifact(cross_shard_tests);
    cross_shard_step.dependOn(&run_cross_shard.step);

    const integration_sharded_step = b.step("test-integration-sharded", "Run sharded-engine integration tests");
    const integration_sharded_tests = b.addTest(.{
        .root_module = createModule(b, "tests/integration_sharded.zig", target, optimize, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });
    const run_integration_sharded = b.addRunArtifact(integration_sharded_tests);
    integration_sharded_step.dependOn(&run_integration_sharded.step);

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
