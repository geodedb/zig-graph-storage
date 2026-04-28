//! observability.zig — single-file otel seam for graph-storage.
//!
//! When `build_options.with_otel == false`, every public function in this
//! file collapses to a comptime-known no-op so the optimizer eliminates
//! the call site entirely. When true, calls forward to the appropriate
//! `otel.api.trace` / `otel.instrumentation.http` helper.
//!
//! INVARIANT: every emit is `catch {}`-discarded. A failing exporter
//! never reaches the caller — telemetry must never break storage
//! operations.
//!
//! NOTE: deviation from template — graph-storage operations don't fit
//! the HTTP `instrumentation.http.startClientSpan` shape (HTTP
//! method/url is lossy for a local storage engine). We expose the
//! generic `startClientSpan` / `startServerSpan` helpers for symmetry
//! with grpc-zig (and to keep the seam template-compatible), AND a
//! db-specific `startOperationSpan(operation)` helper that constructs a
//! span via `otel.api.trace.Tracer.startSpan` directly with a
//! db-shaped span name (`"db.{operation}"`) and the
//! `db.system="graph-storage"` / `db.operation` semantic conventions.

const std = @import("std");
const build_options = @import("build_options");

pub const enabled: bool = build_options.with_otel;

const otel = if (enabled) @import("otel") else struct {};

/// Opaque handle for an in-flight operation. When disabled, this is a
/// zero-sized struct the optimizer drops entirely. The no-op fallback's
/// `end` signature MUST match `otel.api.trace.Span.end(?u64) void` so
/// callers can write `span.end(null)` regardless of `enabled` state.
pub const Span = if (enabled) otel.api.trace.Span else struct {
    pub fn end(self: @This(), _: ?u64) void {
        _ = self;
    }
};

/// Helper: reads either a `[]const u8` field OR a function-typed field
/// returning `[]const u8`, so the seam accepts both shapes — the closure
/// shape the recipe template ships AND the plain-string-field shape used
/// at hot-path call sites.
inline fn accessOr(req: anytype, comptime field: []const u8) []const u8 {
    const T = @TypeOf(@field(req, field));
    return switch (@typeInfo(T)) {
        .pointer => @field(req, field),
        .@"fn" => @field(req, field)(),
        else => @compileError("observability: unsupported field type for " ++ field),
    };
}

/// Start a span for a generic outbound operation. Kept for template
/// symmetry; graph-storage hot paths use `startOperationSpan` instead.
pub fn startClientSpan(req: anytype) Span {
    if (!enabled) return Span{};
    const tracer = global.tracer orelse return Span{};
    const span = otel.instrumentation.http.startClientSpan(
        tracer.*,
        .empty(),
        .{
            .method = accessOr(req, "method"),
            .url = accessOr(req, "url"),
        },
    ) catch return Span{};
    return span;
}

pub fn endClientSpan(span: Span, status: u16) void {
    if (!enabled) return;
    otel.instrumentation.http.endClientSpan(span, .{ .status_code = status });
}

/// Start a span for a generic inbound operation. Kept for template
/// symmetry; graph-storage has no authoritative-server entry point.
pub fn startServerSpan(req: anytype) Span {
    if (!enabled) return Span{};
    const tracer = global.tracer orelse return Span{};
    const span = otel.instrumentation.http.startServerSpan(
        tracer.*,
        .empty(),
        .{
            .method = accessOr(req, "method"),
            .route = accessOr(req, "route"),
            .url = accessOr(req, "url"),
        },
    ) catch return Span{};
    return span;
}

pub fn endServerSpan(span: Span, status: u16) void {
    if (!enabled) return;
    otel.instrumentation.http.endServerSpan(span, status);
}

/// Start a span for a graph-storage engine operation.
///
/// Span shape:
///   - name: `"db.{operation}"` (e.g. `"db.put_node"`, `"db.get_node"`,
///     `"db.checkpoint"`)
///   - kind: `.client` (the storage engine acts as a client to its
///     underlying page/file subsystems; the OpenTelemetry `db.*`
///     semantic conventions specify `client` for the calling side of a
///     database interaction).
///   - attributes:
///       * `db.system = "graph-storage"`
///       * `db.operation = operation`
///
/// `operation` MUST be a string literal or a slice whose lifetime
/// outlives the span. The SDK dupes the span name into the span arena,
/// but the `db.operation` attribute is stored by reference at the
/// stringified value layer; using a stable string keeps the recorder
/// safe from dangling slices.
pub fn startOperationSpan(operation: []const u8) Span {
    if (!enabled) return Span{};
    const tracer = global.tracer orelse return Span{};
    // Compose the span name on the stack; the SDK dupes the name into
    // the span arena, so a pointer to a stack buffer is safe here.
    var name_buf: [128]u8 = undefined;
    const span_name = std.fmt.bufPrint(
        name_buf[0..],
        "db.{s}",
        .{operation},
    ) catch "db";
    const span = tracer.startSpan(.empty(), span_name, .{ .kind = .client }) catch return Span{};
    // Best-effort attribute attachment. Failures (OOM in the attribute
    // set) cannot block the storage operation — telemetry is non-fatal.
    span.setStringAttribute("db.system", "graph-storage") catch {};
    span.setStringAttribute("db.operation", operation) catch {};
    return span;
}

/// Close an operation span, recording success/failure.
///
/// On `ok = true` we set status `.ok`; on `ok = false` we set status
/// `.error_` with `error_msg` as the description, then end the span.
/// Callers typically pair this with `defer span.end(null)` at the call
/// site so the span is always ended regardless of which path is taken.
/// `setStatus` + `end` are idempotent for status reporting (only the
/// first status write wins; the deferred `end(null)` is a redundant
/// no-op).
pub fn endOperationSpan(span: Span, ok: bool, error_msg: []const u8) void {
    if (!enabled) return;
    if (ok) {
        span.setStatus(.ok, "");
    } else {
        // `StatusCode` uses `@"error"` (escaped keyword) for the
        // failure variant — see otel/src/api/trace.zig:35.
        span.setStatus(.@"error", error_msg);
    }
    span.end(null);
}

/// Set once at process start by `observability_init.Otel.installGlobals`.
/// Only referenced when `enabled == true`; otherwise the optimizer drops
/// the whole struct.
pub const global = if (enabled) struct {
    pub var tracer: ?*otel.api.trace.Tracer = null;
    pub var meter: ?*otel.api.metrics.Meter = null;
} else struct {};
