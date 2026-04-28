//! Verifies one operation span lands in an in-memory recorder when
//! `-Dwith_otel=true`. Skips under the disabled build.
//!
//! NOTE: deviation from template — we exercise the seam directly via
//! the in-memory recorder rather than driving a real engine operation.
//! Engine paths require a temp data directory + full subsystem
//! bootstrap; the seam's behaviour is identical:
//! `startOperationSpan` -> `endOperationSpan` enters and leaves one
//! tracer span.
//!
//! The `otel` module is only added to this test root when
//! `-Dwith_otel=true`. To compile cleanly under both flag values we
//! gate the otel-namespace identifiers behind `comptime if (enabled)`
//! and stub the alias to an empty struct when the flag is off — that
//! branch is dead code in the disabled build but the import resolves.

const std = @import("std");
const build_options = @import("build_options");
const graph_storage = @import("graph_storage");

const otel = if (build_options.with_otel) @import("otel") else struct {};

test "one db.* operation span recorded when otel enabled" {
    if (!graph_storage.observability.enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(allocator);
    defer resource.deinit();
    try resource.attributes.putString(otel.semconv.service_name, "graph-storage-test");

    var recorder = otel.exporters.in_memory.Recorder.init(allocator);
    defer recorder.deinit();
    var tp = try otel.sdk.trace.TracerProvider.init(allocator, .{
        .resource = &resource,
        .default_exporter = recorder.spanExporter(),
    });
    defer tp.deinit();

    var tracer = tp.tracer(.{ .name = "graph-storage-test" });
    graph_storage.observability.global.tracer = &tracer;
    defer graph_storage.observability.global.tracer = null;

    const span = graph_storage.observability.startOperationSpan("test");
    graph_storage.observability.endOperationSpan(span, true, "");

    try tp.forceFlush(1_000);
    try std.testing.expectEqual(@as(usize, 1), recorder.spans.items.len);

    // Verify span name shape: "db.{operation}".
    const recorded = recorder.spans.items[0];
    try std.testing.expectEqualStrings("db.test", recorded.name);

    // Verify the db.system attribute landed on the span. The in-memory
    // recorder stores attributes as `[]KV` (string-stringified
    // key/value pairs) — see otel/src/exporters/in_memory.zig:30.
    var found_system: ?[]const u8 = null;
    var found_op: ?[]const u8 = null;
    for (recorded.attribute_kv) |kv| {
        if (std.mem.eql(u8, kv.key, "db.system")) {
            found_system = kv.value;
        } else if (std.mem.eql(u8, kv.key, "db.operation")) {
            found_op = kv.value;
        }
    }
    const system_value = found_system orelse return error.MissingDbSystemAttribute;
    try std.testing.expectEqualStrings("graph-storage", system_value);
    const op_value = found_op orelse return error.MissingDbOperationAttribute;
    try std.testing.expectEqualStrings("test", op_value);
}
