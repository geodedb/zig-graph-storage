// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! CRC32C (Castagnoli, iSCSI) with the CPU's CRC instruction where there is
//! one: SSE4.2 `crc32` on x86_64, the CRC extension's `crc32c*` on aarch64.
//! Bit-identical to `std.hash.crc.Crc32Iscsi`, which is the fallback.
//!
//! SONNY-6461: the page checksum ran the standard library's byte-at-a-time
//! table on every plaintext buffer-pool miss and flush (about 16 us per
//! 8 KiB page), which made plaintext cold reads slower than encrypted ones.
//!
//! Selection: the instruction is used unconditionally when the target's CPU
//! features include it at compile time. Otherwise it is used after a run-time
//! check (x86_64 CPUID leaf 1 ECX bit 20; aarch64 Linux AT_HWCAP bit 7; every
//! Apple silicon Mac has it), except where the compiler cannot assemble the
//! instruction for a target that lacks the feature (Zig's self-hosted x86_64
//! backend, used for Debug builds), which keeps the table.

const std = @import("std");
const builtin = @import("builtin");

// fips-exempt: non-security — CRC32C corruption checks only.
const Software = std.hash.crc.Crc32Iscsi;

const arch = builtin.cpu.arch;

const comptime_hw: bool = switch (arch) {
    .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .sse4_2),
    .aarch64 => std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc) or builtin.os.tag == .macos,
    else => false,
};

/// Whether the instruction can be emitted behind a run-time check.
const runtime_hw_possible: bool = switch (arch) {
    // The self-hosted backend's assembler rejects `crc32` unless the target
    // feature set has SSE4.2; LLVM assembles it for any x86_64 target.
    .x86_64 => builtin.zig_backend == .stage2_llvm,
    .aarch64 => builtin.os.tag == .linux and builtin.zig_backend == .stage2_llvm,
    else => false,
};

const Probe = enum(u8) { unknown, hardware, software };
var probe: std.atomic.Value(Probe) = .init(.unknown);

/// True when `hash` uses the CPU instruction on this machine.
pub fn hardwareAccelerated() bool {
    if (comptime_hw) return true;
    if (!runtime_hw_possible) return false;
    return switch (probe.load(.monotonic)) {
        .hardware => true,
        .software => false,
        .unknown => blk: {
            const has = detect();
            probe.store(if (has) .hardware else .software, .monotonic);
            break :blk has;
        },
    };
}

fn detect() bool {
    switch (arch) {
        .x86_64 => {
            var ecx: u32 = 0;
            var eax: u32 = 1;
            var ebx: u32 = undefined;
            var edx: u32 = undefined;
            asm volatile ("cpuid"
                : [_] "={eax}" (eax),
                  [_] "={ebx}" (ebx),
                  [_] "={ecx}" (ecx),
                  [_] "={edx}" (edx),
                : [_] "{eax}" (eax),
                  [_] "{ecx}" (ecx),
            );
            return (ecx >> 20) & 1 == 1;
        },
        .aarch64 => {
            if (builtin.os.tag != .linux) return false;
            const hwcap_crc32: usize = 1 << 7;
            return std.os.linux.getauxval(std.elf.AT_HWCAP) & hwcap_crc32 != 0;
        },
        else => return false,
    }
}

/// CRC32C of `bytes` (initial value and final xor 0xFFFFFFFF, reflected).
pub fn hash(bytes: []const u8) u32 {
    if (comptime comptime_hw or runtime_hw_possible) {
        if (hardwareAccelerated()) return ~hardwareUpdate(0xFFFF_FFFF, bytes);
    }
    return Software.hash(bytes);
}

/// The table implementation, exposed for tests and benchmarks.
pub fn hashSoftware(bytes: []const u8) u32 {
    return Software.hash(bytes);
}

fn hardwareUpdate(start: u32, bytes: []const u8) u32 {
    var crc = start;
    var i: usize = 0;
    while (i + 8 <= bytes.len) : (i += 8) {
        crc = step64(crc, std.mem.readInt(u64, bytes[i..][0..8], .little));
    }
    while (i < bytes.len) : (i += 1) {
        crc = step8(crc, bytes[i]);
    }
    return crc;
}

inline fn step64(crc: u32, v: u64) u32 {
    switch (arch) {
        .x86_64 => {
            var x: u64 = crc;
            asm ("crc32q %[v], %[x]"
                : [x] "+r" (x),
                : [v] "r" (v),
            );
            return @truncate(x);
        },
        .aarch64 => return asm (
            \\.arch_extension crc
            \\crc32cx %[out:w], %[c:w], %[v:x]
            : [out] "=r" (-> u32),
            : [c] "r" (crc),
              [v] "r" (v),
        ),
        else => unreachable,
    }
}

inline fn step8(crc: u32, b: u8) u32 {
    switch (arch) {
        // The self-hosted backend does not encode `crc32b` with a byte
        // register, so the (at most 7) trailing bytes take the table step.
        .x86_64 => return softwareStep8(crc, b),
        .aarch64 => return asm (
            \\.arch_extension crc
            \\crc32cb %[out:w], %[c:w], %[v:w]
            : [out] "=r" (-> u32),
            : [c] "r" (crc),
              [v] "r" (@as(u32, b)),
        ),
        else => unreachable,
    }
}

/// One reflected CRC32C byte step (polynomial 0x82F63B78).
fn softwareStep8(crc: u32, b: u8) u32 {
    var c = crc ^ b;
    inline for (0..8) |_| c = (c >> 1) ^ (0x82F6_3B78 & (0 -% (c & 1)));
    return c;
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "crc32c check value" {
    try testing.expectEqual(@as(u32, 0xE306_9283), hash("123456789"));
    try testing.expectEqual(@as(u32, 0), hash(""));
}

test "crc32c matches the table implementation for random lengths and alignments" {
    var prng = std.Random.DefaultPrng.init(0x6461_C32C);
    const r = prng.random();
    var buf: [16384 + 64]u8 = undefined;
    r.bytes(&buf);
    // Every length 0..256 at every alignment 0..15, then random spans.
    for (0..16) |off| {
        for (0..257) |len| {
            const s = buf[off..][0..len];
            try testing.expectEqual(hashSoftware(s), hash(s));
        }
    }
    for (0..2000) |_| {
        const off = r.uintLessThan(usize, 64);
        const len = r.uintLessThan(usize, 16384);
        const s = buf[off..][0..len];
        try testing.expectEqual(hashSoftware(s), hash(s));
    }
    // Whole pages, as the pager hashes them.
    for ([_]usize{ 4096, 8192, 16384 }) |ps| {
        try testing.expectEqual(hashSoftware(buf[32..ps]), hash(buf[32..ps]));
    }
}

test "crc32c software byte step matches the table" {
    var crc: u32 = 0xFFFF_FFFF;
    for ("123456789") |b| crc = softwareStep8(crc, b);
    try testing.expectEqual(@as(u32, 0xE306_9283), ~crc);
}

test "crc32c reports whether the instruction is in use" {
    // On the x86_64 and aarch64 machines CI runs on, the instruction exists;
    // this pins that the fast path is actually taken there.
    if (comptime_hw) try testing.expect(hardwareAccelerated());
    _ = hardwareAccelerated();
}
