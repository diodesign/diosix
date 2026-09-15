// Fractal Brownian Motion (fBm) Periodic Noise Engine for Diosix GUI
// Generates seamless, tiling 2D cloud textures using pure integer fixed-point arithmetic.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

// 8 standard 2D unit/diagonal gradients scaled to ~128 (7-bit fixed point)
// Axis vectors: 128. Diagonal vectors: 90 (90 * sqrt(2) ~= 127.3)
const GRAD_X = [8]i32{ 128, -128, 0, 0, 90, -90, 90, -90 };
const GRAD_Y = [8]i32{ 0, 0, 128, -128, 90, 90, -90, -90 };

// Deterministic integer hash to pick gradient index in [0..7] with periodic boundary
pub inline fn getGradientIndex(x: usize, y: usize, freq: usize, seed: u32) usize {
    const wx: u32 = @intCast(x % freq);
    const wy: u32 = @intCast(y % freq);
    var h: u32 = wx *% 374761393 +% wy *% 668265263 +% seed;
    h = (h ^ (h >> 13)) *% 1274126177;
    h = h ^ (h >> 16);
    return @intCast(h & 7);
}

// Fixed-point smoothstep polynomial: s(t) = t^2 * (3 - 2t)
// t is in [0..256] (8.8 fixed point), returns [0..256]
pub inline fn smoothstep8(t: i32) i32 {
    const clamped = std.math.clamp(t, 0, 256);
    return (clamped * clamped * (768 - 2 * clamped)) >> 16;
}

// Evaluates a single octave of 2D periodic gradient noise at integer pixel (x, y)
// within texture dimension dim, using fixed-point integer arithmetic.
pub fn evaluatePeriodicGradientNoise(
    x: usize,
    y: usize,
    dim: usize,
    freq: usize,
    seed: u32,
) i32 {
    const step_fp: usize = (freq * 65536) / dim;

    const x_fp = x * step_fp;
    const y_fp = y * step_fp;

    const x0 = (x_fp >> 16) % freq;
    const x1 = (x0 + 1) % freq;
    const y0 = (y_fp >> 16) % freq;
    const y1 = (y0 + 1) % freq;

    const fx: i32 = @intCast((x_fp >> 8) & 0xFF);
    const fy: i32 = @intCast((y_fp >> 8) & 0xFF);

    const sx = smoothstep8(fx);
    const sy = smoothstep8(fy);

    // Distance vectors from cell corners in [-128..127]
    const dx0 = fx >> 1;
    const dx1 = (fx - 256) >> 1;
    const dy0 = fy >> 1;
    const dy1 = (fy - 256) >> 1;

    const g00 = getGradientIndex(x0, y0, freq, seed);
    const g10 = getGradientIndex(x1, y0, freq, seed);
    const g01 = getGradientIndex(x0, y1, freq, seed);
    const g11 = getGradientIndex(x1, y1, freq, seed);

    const d00 = (dx0 * GRAD_X[g00] + dy0 * GRAD_Y[g00]) >> 7;
    const d10 = (dx1 * GRAD_X[g10] + dy0 * GRAD_Y[g10]) >> 7;
    const d01 = (dx0 * GRAD_X[g01] + dy1 * GRAD_Y[g01]) >> 7;
    const d11 = (dx1 * GRAD_X[g11] + dy1 * GRAD_Y[g11]) >> 7;

    const top = d00 + (((d10 - d00) * sx) >> 8);
    const bot = d01 + (((d11 - d01) * sx) >> 8);
    return top + (((bot - top) * sy) >> 8);
}

// Generates a seamless, tiling 2D cloud texture buffer of size dim x dim
// using standard Fractal Brownian Motion (fBm) with periodic boundary conditions.
pub fn generatePeriodicFbm(
    out: []u8,
    dim: usize,
    octaves: usize,
    base_freq: usize,
    seed: u32,
) void {
    std.debug.assert(out.len >= dim * dim);

    var accum_buf: [256 * 256]i32 = undefined;
    const accum = accum_buf[0 .. dim * dim];
    @memset(accum, 0);

    var amp: i32 = 128;
    var freq: usize = base_freq;
    var oct: usize = 0;

    while (oct < octaves) : (oct += 1) {
        const oct_seed = seed +% @as(u32, @intCast(oct *% 1013));
        var y: usize = 0;
        while (y < dim) : (y += 1) {
            const row_off = y * dim;
            var x: usize = 0;
            while (x < dim) : (x += 1) {
                const val = evaluatePeriodicGradientNoise(x, y, dim, freq, oct_seed);
                accum[row_off + x] += val * amp;
            }
        }
        amp = @max(1, amp >> 1);
        freq *= 2;
    }

    // Find min and max for normalization
    var min_v: i32 = accum[0];
    var max_v: i32 = accum[0];
    for (accum) |v| {
        if (v < min_v) min_v = v;
        if (v > max_v) max_v = v;
    }

    const range = @max(1, max_v - min_v);
    for (accum, 0..) |v, i| {
        const normalized = @divTrunc((v - min_v) * 255, range);
        out[i] = @intCast(std.math.clamp(normalized, 0, 255));
    }
}

test "noise: smoothstep boundary conditions" {
    try std.testing.expectEqual(@as(i32, 0), smoothstep8(0));
    try std.testing.expectEqual(@as(i32, 128), smoothstep8(128));
    try std.testing.expectEqual(@as(i32, 256), smoothstep8(256));
    try std.testing.expectEqual(@as(i32, 256), smoothstep8(300));
    try std.testing.expectEqual(@as(i32, 0), smoothstep8(-10));
}

test "noise: gradient periodic wrapping" {
    const freq: usize = 4;
    const seed: u32 = 42;
    try std.testing.expectEqual(getGradientIndex(0, 0, freq, seed), getGradientIndex(freq, 0, freq, seed));
    try std.testing.expectEqual(getGradientIndex(1, 2, freq, seed), getGradientIndex(1 + freq, 2, freq, seed));
    try std.testing.expectEqual(getGradientIndex(3, 3, freq, seed), getGradientIndex(3, 3 + freq, freq, seed));
}

test "noise: fBm seamless tessellation and zero boundary seam jumps" {
    const dim = 256;
    var tex: [dim * dim]u8 = undefined;
    generatePeriodicFbm(&tex, dim, 5, 3, 0x193E36CC);

    var max_jump_x: u32 = 0;
    var y: usize = 0;
    while (y < dim) : (y += 1) {
        const p_left = @as(i32, tex[y * dim + 0]);
        const p_right = @as(i32, tex[y * dim + (dim - 1)]);
        const jump: u32 = @intCast(@abs(p_left - p_right));
        if (jump > max_jump_x) max_jump_x = jump;
    }

    var max_jump_y: u32 = 0;
    var x: usize = 0;
    while (x < dim) : (x += 1) {
        const p_top = @as(i32, tex[0 * dim + x]);
        const p_bot = @as(i32, tex[(dim - 1) * dim + x]);
        const jump: u32 = @intCast(@abs(p_top - p_bot));
        if (jump > max_jump_y) max_jump_y = jump;
    }

    std.debug.print("\n=== Seam Check: max_jump_x = {d}, max_jump_y = {d} ===\n", .{ max_jump_x, max_jump_y });
    try std.testing.expect(max_jump_x <= 20);
    try std.testing.expect(max_jump_y <= 20);
}
