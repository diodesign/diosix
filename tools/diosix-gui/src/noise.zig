// Fractal Brownian Motion (fBm) Periodic Noise Engine for Diosix GUI.
// Generates seamless, tiling 2D cloud textures using integer fixed-point math.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const MAX_NOISE_DIM: usize = 256;
pub const FP16_SHIFT: u5 = 16;
pub const FP16_SCALE: usize = 1 << FP16_SHIFT;
pub const FP8_SHIFT: u5 = 8;
pub const FP8_SCALE: i32 = 1 << FP8_SHIFT;
pub const FP8_MASK: usize = 0xff;
pub const GRAD_SHIFT: u5 = 7;
pub const GRAD_MASK: u32 = 0x07;

// 8 standard 2D unit/diagonal gradients scaled to ~128 (7-bit fixed point).
// Axis vectors: 128. Diagonal vectors: 90 (90 * sqrt(2) ~= 127.3).
const GRAD_X = [8]i32{ 128, -128, 0, 0, 90, -90, 90, -90 };
const GRAD_Y = [8]i32{ 0, 0, 128, -128, 90, 90, -90, -90 };

// Deterministic integer hash to pick gradient index in [0..7] with wrap.
pub inline fn getGradientIndex(
    x: usize,
    y: usize,
    freq: usize,
    seed: u32,
) usize {
    if (freq == 0) return 0;
    const wx: u32 = @intCast(x % freq);
    const wy: u32 = @intCast(y % freq);
    var h: u32 = wx *% 374761393 +% wy *% 668265263 +% seed;
    h = (h ^ (h >> 13)) *% 1274126177;
    h = h ^ (h >> FP16_SHIFT);
    return @intCast(h & GRAD_MASK);
}

// Fixed-point smoothstep polynomial: s(t) = t^2 * (3 - 2t).
// t is in [0..256] (8.8 fixed point), returns [0..256].
pub inline fn smoothstep8(t: i32) i32 {
    const clamped = std.math.clamp(t, 0, FP8_SCALE);
    return (clamped * clamped * (3 * FP8_SCALE - 2 * clamped)) >> FP16_SHIFT;
}

// Evaluates a single octave of 2D periodic gradient noise at integer pixel
// (x, y) within texture dimension dim, using fixed-point integer arithmetic.
pub fn evaluatePeriodicGradientNoise(
    x: usize,
    y: usize,
    dim: usize,
    freq: usize,
    seed: u32,
) i32 {
    if (dim == 0 or freq == 0) return 0;
    const step_fp: usize = (freq * FP16_SCALE) / dim;

    const x_fp = x * step_fp;
    const y_fp = y * step_fp;

    const x0 = (x_fp >> FP16_SHIFT) % freq;
    const x1 = (x0 + 1) % freq;
    const y0 = (y_fp >> FP16_SHIFT) % freq;
    const y1 = (y0 + 1) % freq;

    const fx: i32 = @intCast((x_fp >> FP8_SHIFT) & FP8_MASK);
    const fy: i32 = @intCast((y_fp >> FP8_SHIFT) & FP8_MASK);

    const sx = smoothstep8(fx);
    const sy = smoothstep8(fy);

    // Distance vectors from cell corners in [-128..127].
    const dx0 = fx >> 1;
    const dx1 = (fx - FP8_SCALE) >> 1;
    const dy0 = fy >> 1;
    const dy1 = (fy - FP8_SCALE) >> 1;

    const g00 = getGradientIndex(x0, y0, freq, seed);
    const g10 = getGradientIndex(x1, y0, freq, seed);
    const g01 = getGradientIndex(x0, y1, freq, seed);
    const g11 = getGradientIndex(x1, y1, freq, seed);

    const d00 = (dx0 * GRAD_X[g00] + dy0 * GRAD_Y[g00]) >> GRAD_SHIFT;
    const d10 = (dx1 * GRAD_X[g10] + dy0 * GRAD_Y[g10]) >> GRAD_SHIFT;
    const d01 = (dx0 * GRAD_X[g01] + dy1 * GRAD_Y[g01]) >> GRAD_SHIFT;
    const d11 = (dx1 * GRAD_X[g11] + dy1 * GRAD_Y[g11]) >> GRAD_SHIFT;

    const top = d00 + (((d10 - d00) * sx) >> FP8_SHIFT);
    const bot = d01 + (((d11 - d01) * sx) >> FP8_SHIFT);
    return top + (((bot - top) * sy) >> FP8_SHIFT);
}

// Generates a seamless, tiling 2D cloud texture buffer of size dim x dim
// using standard Fractal Brownian Motion (fBm) with periodic boundary wrap.
pub fn generatePeriodicFbm(
    out: []u8,
    dim: usize,
    octaves: usize,
    base_freq: usize,
    seed: u32,
) void {
    if (dim == 0 or base_freq == 0) return;
    std.debug.assert(dim <= MAX_NOISE_DIM);
    std.debug.assert(out.len >= dim * dim);

    const accum = std.heap.page_allocator.alloc(i32, dim * dim) catch return;
    defer std.heap.page_allocator.free(accum);
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
                const val = evaluatePeriodicGradientNoise(
                    x,
                    y,
                    dim,
                    freq,
                    oct_seed,
                );
                accum[row_off + x] += val * amp;
            }
        }
        amp = @max(1, amp >> 1);
        freq *= 2;
    }

    // Find min and max for normalization.
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
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(@as(i32, 0), smoothstep8(0));
    try std.testing.expectEqual(@as(i32, 128), smoothstep8(128));
    try std.testing.expectEqual(@as(i32, 256), smoothstep8(256));
    try std.testing.expectEqual(@as(i32, 256), smoothstep8(300));
    try std.testing.expectEqual(@as(i32, 0), smoothstep8(-10));
}

test "noise: gradient periodic wrapping" {
    const freq: usize = 4;
    const seed: u32 = 42;
    try std.testing.expectEqual(
        getGradientIndex(0, 0, freq, seed),
        getGradientIndex(freq, 0, freq, seed),
    );
    try std.testing.expectEqual(
        getGradientIndex(1, 2, freq, seed),
        getGradientIndex(1 + freq, 2, freq, seed),
    );
    try std.testing.expectEqual(
        getGradientIndex(3, 3, freq, seed),
        getGradientIndex(3, 3 + freq, freq, seed),
    );
}

test "noise: fBm seamless tessellation and zero boundary seam jumps" {
    const dim = 256;
    var tex: [dim * dim]u8 = undefined;
    generatePeriodicFbm(&tex, dim, 5, 3, 0x193e36cc);

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

    try std.testing.expect(max_jump_x <= 20);
    try std.testing.expect(max_jump_y <= 20);
}
