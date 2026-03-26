// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const wal_dep = b.dependency("wal", .{
        .target = target,
        .optimize = optimize,
    });
    const uuid_dep = b.dependency("uuid", .{
        .target = target,
        .optimize = optimize,
    });

    const wal_mod = wal_dep.module("wal");
    const uuid_mod = uuid_dep.module("uuid");

    // Main library module
    const module = b.addModule("graph_storage", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wal", .module = wal_mod },
            .{ .name = "uuid", .module = uuid_mod },
        },
    });

    // Seed module (reusable test data generator)
    const seed_mod = b.addModule("seed", .{
        .root_source_file = b.path("tests/seed.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "graph_storage", .module = module },
        },
    });

    // Unit tests (run tests defined in the module itself)
    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wal", .module = wal_mod },
                .{ .name = "uuid", .module = uuid_mod },
            },
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // Integration tests (separate test file with module import)
    const integration_step = b.step("test-integration", "Run integration tests");
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "graph_storage", .module = module },
                .{ .name = "seed", .module = seed_mod },
                .{ .name = "wal", .module = wal_mod },
                .{ .name = "uuid", .module = uuid_mod },
            },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    integration_step.dependOn(&run_integration_tests.step);

    // Example executable
    const example = b.addExecutable(.{
        .name = "basic-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "graph_storage", .module = module },
            },
        }),
    });
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(b.getInstallStep());
    const run_step = b.step("run-example", "Run the basic usage example");
    run_step.dependOn(&run_example.step);

    // Benchmark executable
    const bench_step = b.step("bench", "Run performance benchmarks");
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "graph_storage", .module = module },
                .{ .name = "wal", .module = wal_mod },
                .{ .name = "uuid", .module = uuid_mod },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&run_bench.step);

    // Heavy-load benchmark executable (uses seed module)
    const load_bench_step = b.step("load-bench", "Run heavy-load benchmarks with Geode-model seeder");
    const load_bench_exe = b.addExecutable(.{
        .name = "load-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/load_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "graph_storage", .module = module },
                .{ .name = "seed", .module = seed_mod },
                .{ .name = "wal", .module = wal_mod },
                .{ .name = "uuid", .module = uuid_mod },
            },
        }),
    });
    const run_load_bench = b.addRunArtifact(load_bench_exe);
    if (b.args) |args| {
        run_load_bench.addArgs(args);
    }
    load_bench_step.dependOn(&run_load_bench.step);

    // Incremental scale benchmark executable
    const scale_bench_step = b.step("scale-bench", "Run incremental scale benchmarks with JSON output");
    const scale_bench_exe = b.addExecutable(.{
        .name = "scale-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/scale_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "graph_storage", .module = module },
                .{ .name = "seed", .module = seed_mod },
                .{ .name = "wal", .module = wal_mod },
                .{ .name = "uuid", .module = uuid_mod },
            },
        }),
    });
    b.installArtifact(scale_bench_exe);
    const run_scale_bench = b.addRunArtifact(scale_bench_exe);
    if (b.args) |args| {
        run_scale_bench.addArgs(args);
    }
    scale_bench_step.dependOn(&run_scale_bench.step);

    // Benchmark comparison tool
    const compare_bench_step = b.step("compare-bench", "Compare benchmark results against a baseline");
    const compare_bench_exe = b.addExecutable(.{
        .name = "compare-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/compare.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const run_compare_bench = b.addRunArtifact(compare_bench_exe);
    if (b.args) |args| {
        run_compare_bench.addArgs(args);
    }
    compare_bench_step.dependOn(&run_compare_bench.step);

    // Check step for IDE integration (fast syntax validation)
    const check_step = b.step("check", "Check for compilation errors");
    const check = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wal", .module = wal_mod },
                .{ .name = "uuid", .module = uuid_mod },
            },
        }),
    });
    check_step.dependOn(&check.step);
}
