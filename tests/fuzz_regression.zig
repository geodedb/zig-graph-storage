// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const gs = @import("graph_storage");

fn fr_io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const BufferPool = gs.buffer_pool.BufferPool;
const FreeSpaceManager = gs.free_space.FreeSpaceManager;
const Backup = gs.backup.Backup;
const BACKUP_MAGIC = gs.backup.BACKUP_MAGIC;
const BACKUP_VERSION = gs.backup.BACKUP_VERSION;
const Migration = gs.migration.Migration;
const PerGraphHeader = gs.migration.PerGraphHeader;
const serializePerGraphHeader = gs.migration.serializePerGraphHeader;
const PER_GRAPH_HEADER_SIZE = gs.migration.PER_GRAPH_HEADER_SIZE;
const WalRecord = gs.wal_record.WalRecord;
const PropStore = gs.prop_store.PropStore;
const VarStore = gs.var_store.VarStore;
const DualStoreEnv = gs.test_support.DualStoreEnv;
const PropertyValue = gs.PropertyValue;

// fips-exempt: non-security — type alias only; CRC32C record-integrity
// (corruption detection) for on-disk format, not authentication.
const Crc32 = std.hash.crc.Crc32Iscsi;

test "fuzz regression: free-space metadata with oversized page counts is rejected" {
    var pool = try BufferPool.init(std.testing.allocator, 4096, 4);
    defer pool.deinit();

    var free_space = try FreeSpaceManager.init(std.testing.allocator, &pool, .nodes);
    defer free_space.deinit();

    var buf: [24]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], std.math.maxInt(u64), .little);
    std.mem.writeInt(u64, buf[8..16], 0, .little);
    std.mem.writeInt(u64, buf[16..24], 1, .little);

    try std.testing.expectError(error.InvalidData, free_space.deserializeBounded(&buf, 128));
}

test "fuzz regression: migration rejects malformed per-graph headers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(fr_io(), &cwd_buf);
    const tmp_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..cwd_len], tmp.sub_path[0..] });
    defer std.testing.allocator.free(tmp_path);

    var header_buf: [PER_GRAPH_HEADER_SIZE]u8 = undefined;
    serializePerGraphHeader(PerGraphHeader{
        .version = 1,
        .graph_uuid = [_]u8{0xAB} ** 16,
        .node_count = 10,
        .edge_count = 20,
    }, &header_buf);
    header_buf[0] = 'X';

    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/legacy.dat", .{tmp_path});
    defer std.testing.allocator.free(path);

    const io = fr_io();
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, &header_buf, 0);

    const migration = Migration.init(std.testing.allocator);
    try std.testing.expectError(error.InvalidMagic, migration.validatePerGraphHeader(path));
}

test "fuzz regression: backup restore rejects path traversal filenames" {
    const allocator = std.testing.allocator;
    const malicious_name = "../../../etc/passwd";
    const file_data = "malicious content";

    const entry_size = 2 + malicious_name.len + 8 + file_data.len;
    const total_size = 26 + entry_size + 4;
    var buf: [total_size]u8 = undefined;

    @memcpy(buf[0..4], &BACKUP_MAGIC);
    @memcpy(buf[4..6], &std.mem.toBytes(std.mem.nativeToLittle(u16, BACKUP_VERSION)));
    @memset(buf[6..22], 0x42);
    @memcpy(buf[22..26], &std.mem.toBytes(std.mem.nativeToLittle(u32, 1)));

    var pos: usize = 26;
    @memcpy(buf[pos..][0..2], &std.mem.toBytes(std.mem.nativeToLittle(u16, @as(u16, malicious_name.len))));
    pos += 2;
    @memcpy(buf[pos..][0..malicious_name.len], malicious_name);
    pos += malicious_name.len;
    @memcpy(buf[pos..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, @as(u64, file_data.len))));
    pos += 8;
    @memcpy(buf[pos..][0..file_data.len], file_data);
    pos += file_data.len;

    const crc = Crc32.hash(buf[0..pos]);
    @memcpy(buf[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, crc)));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(fr_io(), &cwd_buf);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..cwd_len], tmp.sub_path[0..] });
    defer allocator.free(tmp_path);

    const backup_path = try std.fmt.allocPrint(allocator, "{s}/malicious.geob", .{tmp_path});
    defer allocator.free(backup_path);
    const restore_path = try std.fmt.allocPrint(allocator, "{s}/restored", .{tmp_path});
    defer allocator.free(restore_path);

    const io = fr_io();
    const file = try std.Io.Dir.cwd().createFile(io, backup_path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, &buf, 0);

    var backup = Backup.init(allocator);
    backup.setExpectedGraphUuid([_]u8{0x42} ** 16);
    backup.enableLegacyV1Restore();
    try std.testing.expectError(error.InvalidBackupFilename, backup.restoreBackup(backup_path, restore_path));
}

// ============================================================================
// QUAL-0044 T4: Deterministic fixed-seed fuzz targets for on-disk format decoders
//
// These tests throw thousands of random byte buffers at the format decoders and
// assert that the decoders NEVER panic or produce undefined behaviour — they may
// only return errors or valid results. The fixed seed guarantees determinism and
// CI safety. The bounded iteration count keeps the suite fast.
//
// Target decoders:
//   • property.decode / property.encodedSizeFromBytes (via prop_store)
//   • wal_record.WalRecord.deserialize
//   • prop_store page-directory reader (readDirCountChecked / readEntryCountChecked
//     / readDirEntry) — exercised indirectly via PropStore.getProperty on a page
//     whose bytes have been overwritten with random data.
// ============================================================================

/// Fixed seed shared across all T4 fuzz targets for reproducibility.
const FUZZ_SEED: u64 = 0xDEADBEEFCAFEBABE;

/// Number of random inputs to feed each decoder per test run.
const FUZZ_ITERATIONS: usize = 10_000;

test "QUAL-0044 T4: property.decode never panics on random bytes" {
    // property.decode must return either a valid DecodeResult or an error for
    // any byte sequence; it must never trap under -Doptimize=ReleaseSafe.
    //
    // We use a FixedBufferAllocator so that decode calls for string/ext types
    // that try to allocate based on the (random) embedded length field cannot
    // exhaust the test process address space. Allocation failures surface as
    // OutOfMemory errors, which are acceptable.
    var prng = std.Random.DefaultPrng.init(FUZZ_SEED);
    const rng = prng.random();

    var heap_buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&heap_buf);
    const alloc = fba.allocator();

    var iter: usize = 0;
    while (iter < FUZZ_ITERATIONS) : (iter += 1) {
        // Generate a random input length between 0 and 32 bytes.
        const len = rng.intRangeAtMost(usize, 0, 32);
        var buf: [32]u8 = undefined;
        rng.bytes(buf[0..len]);

        fba.reset();
        const result = gs.property.decode(alloc, buf[0..len]);
        if (result) |dr| {
            // If decode succeeded, free any heap allocation it made.
            gs.property.freeDecoded(alloc, dr.value);
        } else |_| {
            // Any error is acceptable; the important thing is no panic/trap.
        }
    }
}

test "QUAL-0044 T4: property.decode never panics on large-length string/ext fields" {
    // Specifically target the string and ext fast-reject paths: craft inputs
    // with valid tags but length fields that would overflow into OOB territory.
    var prng = std.Random.DefaultPrng.init(FUZZ_SEED ^ 0x1111);
    const rng = prng.random();

    var heap_buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&heap_buf);
    const alloc = fba.allocator();

    // Tag values for string (4) and ext (6).
    const variable_tags = [_]u8{
        @intFromEnum(gs.property.Tag.string),
        @intFromEnum(gs.property.Tag.ext),
    };

    for (variable_tags) |tag| {
        var iter: usize = 0;
        while (iter < FUZZ_ITERATIONS) : (iter += 1) {
            var buf: [32]u8 = undefined;
            buf[0] = tag;
            // Fill the rest with random bytes (random embedded length field).
            rng.bytes(buf[1..]);

            fba.reset();
            const result = gs.property.decode(alloc, &buf);
            if (result) |dr| {
                gs.property.freeDecoded(alloc, dr.value);
            } else |_| {}
        }
    }
}

test "QUAL-0044 T4: WalRecord.deserialize never panics on random bytes" {
    // WalRecord.deserialize must return an error (InvalidFormat, WalRecordTooLarge,
    // OutOfMemory) for any input shorter than MIN_RECORD_SIZE or with an invalid
    // record_type / oversized payload_len; it must never trap.
    var prng = std.Random.DefaultPrng.init(FUZZ_SEED ^ 0x2222);
    const rng = prng.random();

    // Allocator for the deserialized payload copy; bounded to prevent OOM from
    // a random but plausible payload_len.
    var heap_buf: [2 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&heap_buf);
    const alloc = fba.allocator();

    var iter: usize = 0;
    while (iter < FUZZ_ITERATIONS) : (iter += 1) {
        // Vary input length: some below MIN_RECORD_SIZE (34), some above.
        const len = rng.intRangeAtMost(usize, 0, 128);
        var buf: [128]u8 = undefined;
        rng.bytes(buf[0..len]);

        fba.reset();
        const result = WalRecord.deserialize(alloc, buf[0..len]);
        if (result) |r| {
            r.record.deinit(alloc);
        } else |_| {}
    }
}

test "QUAL-0044 T4: WalRecord.deserialize never panics on oversized payload_len field" {
    // Specifically target the payload_len overflow path: craft buffers with a
    // valid header but a huge payload_len to ensure the guard fires cleanly.
    var prng = std.Random.DefaultPrng.init(FUZZ_SEED ^ 0x3333);
    const rng = prng.random();

    var heap_buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&heap_buf);
    const alloc = fba.allocator();

    var iter: usize = 0;
    while (iter < FUZZ_ITERATIONS) : (iter += 1) {
        // Build a 34-byte (MIN_RECORD_SIZE) buffer with a random record_type byte
        // at offset 16 and random payload_len at offset 26.
        var buf: [34]u8 = undefined;
        @memset(&buf, 0);
        buf[16] = rng.int(u8); // random record_type (most will be invalid)
        const payload_len = rng.int(u32);
        std.mem.writeInt(u32, buf[26..30], payload_len, .little);

        fba.reset();
        const result = WalRecord.deserialize(alloc, &buf);
        if (result) |r| {
            r.record.deinit(alloc);
        } else |_| {}
    }
}

test "QUAL-0044 T4: prop_store page-directory reader never panics on random page bytes" {
    // Exercise readDirCountChecked / readEntryCountChecked / readDirEntry and
    // the linear-scan path (encodedSizeFromBytes) indirectly by overwriting a
    // real property page's bytes with random data and then calling getProperty.
    //
    // The page-directory reader is expected to return DataCorruption (SEC-0039)
    // or null; it must never panic under -Doptimize=ReleaseSafe.
    var base = try DualStoreEnv.init(
        std.testing.allocator,
        .props,
        .props,
        "fuzz_props.store",
        .var_store,
        "fuzz_var.store",
        4096,
        32,
    );
    base.register();
    defer base.deinit();

    var vs = VarStore.init(&base.pool, &base.fsm, 4096);
    var store = PropStore.init(&base.pool, &base.fsm, &vs, 4096);

    // Create one real property page to get a valid page id.
    const head = try store.putProperty(0, "seed_key", .{ .int = 1 });

    var prng = std.Random.DefaultPrng.init(FUZZ_SEED ^ 0x4444);
    const rng = prng.random();

    var heap_buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&heap_buf);
    const alloc = fba.allocator();

    var iter: usize = 0;
    while (iter < FUZZ_ITERATIONS) : (iter += 1) {
        // Overwrite the page with random bytes, then call getProperty.
        // The reader must handle any garbage gracefully.
        {
            const frame = try base.pool.pin(.props, head);
            const frame_idx = base.pool.frameIndex(frame);
            rng.bytes(frame.dataSlice());
            base.pool.unpin(frame_idx, true);
        }

        fba.reset();
        const result = store.getProperty(head, "seed_key", alloc);
        if (result) |maybe_val| {
            if (maybe_val) |val| {
                gs.property.freeDecoded(alloc, val);
            }
        } else |_| {
            // DataCorruption, CircularChainDetected, etc. — all acceptable.
        }
    }
}
