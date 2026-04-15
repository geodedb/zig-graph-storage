// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

const Import = std.Build.Module.Import;
const OptimizeMode = std.builtin.OptimizeMode;

const Deps = struct {
    wal_mod: *std.Build.Module,
    uuid_mod: *std.Build.Module,
    thread_pool_mod: *std.Build.Module,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const deps = loadDeps(b, target, optimize);

    const graph_storage_mod = b.addModule("graph_storage", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = allocImports(b, &.{
            .{ .name = "wal", .module = deps.wal_mod },
            .{ .name = "uuid", .module = deps.uuid_mod },
            .{ .name = "thread_pool", .module = deps.thread_pool_mod },
        }),
    });
    const seed_mod = b.addModule("seed", .{
        .root_source_file = b.path("tests/seed.zig"),
        .target = target,
        .optimize = optimize,
        .imports = allocImports(b, &.{
            .{ .name = "graph_storage", .module = graph_storage_mod },
        }),
    });

    addUnitTests(b, target, optimize, deps);
    addIntegrationTests(b, target, optimize, graph_storage_mod, seed_mod, deps);
    addExample(b, target, optimize, graph_storage_mod);
    addBenchmarks(b, target, graph_storage_mod, seed_mod, deps);
    addCheckStep(b, target, optimize, deps);
}

fn loadDeps(b: *std.Build, target: std.Build.ResolvedTarget, optimize: OptimizeMode) Deps {
    const wal_dep = b.dependency("wal", .{ .target = target, .optimize = optimize });
    const uuid_dep = b.dependency("uuid", .{ .target = target, .optimize = optimize });
    const thread_pool_dep = b.dependency("thread_pool", .{ .target = target, .optimize = optimize });

    return .{
        .wal_mod = wal_dep.module("wal"),
        .uuid_mod = uuid_dep.module("uuid"),
        .thread_pool_mod = thread_pool_dep.module("thread_pool"),
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
        .imports = allocImports(b, imports),
    });
}

fn addUnitTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: OptimizeMode, deps: Deps) void {
    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = createModule(b, "src/root.zig", target, optimize, &.{
            .{ .name = "wal", .module = deps.wal_mod },
            .{ .name = "uuid", .module = deps.uuid_mod },
            .{ .name = "thread_pool", .module = deps.thread_pool_mod },
        }),
    });
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
}

fn addCheckStep(b: *std.Build, target: std.Build.ResolvedTarget, optimize: OptimizeMode, deps: Deps) void {
    const check_step = b.step("check", "Check for compilation errors");
    const check = b.addTest(.{
        .root_module = createModule(b, "src/root.zig", target, optimize, &.{
            .{ .name = "wal", .module = deps.wal_mod },
            .{ .name = "uuid", .module = deps.uuid_mod },
            .{ .name = "thread_pool", .module = deps.thread_pool_mod },
        }),
    });
    check_step.dependOn(&check.step);
}
