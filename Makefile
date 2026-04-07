# graph-storage - Zig Library Makefile
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 CodePros

.PHONY: all build test test-unit test-integration fuzz-regression clean check fmt help dev ci bench
.PHONY: test-release-safe test-release-fast test-release-small test-all-optimizations
.PHONY: pre-commit-install pre-commit pre-commit-run
.PHONY: scale-bench bench-save bench-compare bench-baseline bench-compare-10k bench-baseline-10k

# Default target: build and run tests
all: build test-unit
	@echo "✅ All builds and tests completed successfully!"

# Build the library
build:
	@echo "🔨 Building graph-storage..."
	@zig build

# Run all tests
test: test-unit test-integration fuzz-regression
	@echo "✅ All tests completed"

# Run unit tests only
test-unit:
	@echo "🧪 Running unit tests..."
	@zig build test --summary all

# Run integration tests only
test-integration:
	@echo "🔗 Running integration tests..."
	@zig build test-integration --summary all

# Run deterministic fuzz-regression tests
fuzz-regression:
	@echo "🧪 Running deterministic fuzz regressions..."
	@zig build test-fuzz-regression --summary all

# Run performance benchmarks
bench:
	@echo "Running benchmarks..."
	@zig build bench

# Incremental scale benchmark
scale-bench:
	@echo "Running incremental scale benchmark..."
	@zig build scale-bench 2>/dev/null

# Run scale bench and save results
bench-save:
	@echo "Running scale benchmark and saving results..."
	@zig build scale-bench 2>/dev/null > benchmarks/results/$$(git rev-parse --short HEAD).json
	@echo "Saved to benchmarks/results/$$(git rev-parse --short HEAD).json"

# Compare current results against baseline
bench-compare:
	@echo "Running CI-sized scale benchmark and comparing against baseline..."
	@zig build scale-bench -- 1K 2>/dev/null > /tmp/current-bench.json
	@zig build compare-bench -- benchmarks/results/ci-baseline.json /tmp/current-bench.json

# Save current results as the baseline
bench-baseline:
	@echo "Running CI-sized scale benchmark and saving as baseline..."
	@zig build scale-bench -- 1K 2>/dev/null > benchmarks/results/ci-baseline.json
	@echo "Saved to benchmarks/results/ci-baseline.json"

# Compare larger scheduled/manual tier results against the 10K baseline.
bench-compare-10k:
	@echo "Running scheduled/manual 10K benchmark gate and comparing against baseline..."
	@zig build scale-bench -- 10K 2>/dev/null > /tmp/current-bench-10k.json
	@zig build compare-bench -- benchmarks/results/ci-10k-baseline.json /tmp/current-bench-10k.json

# Save the scheduled/manual 10K benchmark baseline.
bench-baseline-10k:
	@echo "Running 10K benchmark gate and saving as baseline..."
	@zig build scale-bench -- 10K 2>/dev/null > benchmarks/results/ci-10k-baseline.json
	@echo "Saved to benchmarks/results/ci-10k-baseline.json"

# Clean build artifacts
clean:
	@echo "🧹 Cleaning build artifacts..."
	@rm -rf zig-cache zig-out .zig-cache

# Check for compilation errors (fast, no codegen)
check:
	@echo "🔍 Checking for compilation errors..."
	@zig build check

# Format source code
fmt:
	@echo "📝 Formatting code..."
	@zig fmt src/ tests/ benchmarks/ build.zig

# Quick development iteration loop
dev: fmt check test-unit
	@echo "✅ Development checks passed"

# Full CI pipeline (clean slate)
ci: clean build test
	@echo "✅ CI pipeline passed"

# Release optimization level tests
test-release-safe:
	@echo "🧪 Testing with ReleaseSafe..."
	@zig build test -Doptimize=ReleaseSafe --summary all

test-release-fast:
	@echo "🧪 Testing with ReleaseFast..."
	@zig build test -Doptimize=ReleaseFast --summary all

test-release-small:
	@echo "🧪 Testing with ReleaseSmall..."
	@zig build test -Doptimize=ReleaseSmall --summary all

test-all-optimizations: test-unit test-release-safe test-release-fast test-release-small
	@echo "✅ All optimization levels passed"

# Pre-commit hook management
# Future agent note: pre-commit is intentionally a fast local subset.
# `make ci` and GitLab CI remain the authoritative merge gates.
pre-commit-install:
	@echo "📦 Installing pre-commit hooks..."
	@pre-commit install
	@pre-commit install --hook-type commit-msg
	@pre-commit install --hook-type pre-push

pre-commit:
	@echo "🔍 Running pre-commit checks..."
	@pre-commit run --all-files

pre-commit-run: pre-commit

# Display help
help:
	@echo "graph-storage - Zig Library"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Development:"
	@echo "  all                  Build and run tests (default)"
	@echo "  build                Build the library"
	@echo "  dev                  Quick iteration: fmt + check + test"
	@echo "  ci                   Full CI: clean + build + test"
	@echo ""
	@echo "Testing:"
	@echo "  test                 Run all tests"
	@echo "  test-unit            Run unit tests only"
	@echo "  test-integration     Run integration tests only"
	@echo "  fuzz-regression      Run deterministic fuzz regressions"
	@echo "  test-release-safe    Test with ReleaseSafe"
	@echo "  test-release-fast    Test with ReleaseFast"
	@echo "  test-release-small   Test with ReleaseSmall"
	@echo "  test-all-optimizations  Test all optimization levels"
	@echo "  bench                Run performance benchmarks"
	@echo "  scale-bench          Run incremental scale benchmark"
	@echo "  bench-save           Run scale bench and save results"
	@echo "  bench-baseline       Save current results as baseline"
	@echo "  bench-baseline-10k   Save the scheduled/manual 10K baseline"
	@echo "  bench-compare        Compare current against baseline"
	@echo "  bench-compare-10k    Compare the 10K gate against its baseline"
	@echo ""
	@echo "Code Quality:"
	@echo "  fmt                  Format source code"
	@echo "  check                Check for compilation errors"
	@echo "  pre-commit           Run pre-commit hooks"
	@echo "  pre-commit-install   Install pre-commit hooks"
	@echo ""
	@echo "Maintenance:"
	@echo "  clean                Remove build artifacts"
	@echo "  help                 Show this help message"
