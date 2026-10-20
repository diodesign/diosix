// GDB Remote Serial Protocol (RSP) packet framing and hexadecimal helpers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const debug = @import("../debug.zig");
const vcore = @import("../vcore.zig");

pub const HEX_DIGITS = "0123456789abcdef";
pub const RSP_MAX_PACKET_BYTES: usize = 2048;
pub const RSP_MAX_MEM_READ_BYTES: usize = 256;
pub const RSP_REG_HEX_BUF_LEN: usize = 544;
pub const RSP_STOP_PACKET_LEN: usize = 32;
pub const RSP_HEX_OUTPUT_BUF_LEN: usize = 1024;

pub const PacketState = enum {
    idle,
    reading_payload,
    reading_checksum_hi,
    reading_checksum_lo,
};

pub fn writeSerialByte(ch: u8) void {
    debug.hw_putchar(ch);
}

pub fn readSerialByte() i16 {
    return debug.hw_getchar();
}

pub fn sendAck(ack: bool) void {
    writeSerialByte(if (ack) '+' else '-');
}

/// Compute modulo 256 sum of payload slice.
pub fn computeChecksum(payload: []const u8) u8 {
    var sum: u8 = 0;
    for (payload) |b| sum = sum +% b;
    return sum;
}

pub const calcChecksum = computeChecksum;

/// Parse a single hexadecimal character into its 4-bit value.
pub fn hexVal(ch: u8) ?u8 {
    return std.fmt.charToDigit(ch, 16) catch null;
}

/// Encode a single byte into 2 lowercase hexadecimal characters in `dst`.
pub fn encodeHexByte(b: u8, dst: *[2]u8) void {
    dst[0] = HEX_DIGITS[(b >> 4) & 0xf];
    dst[1] = HEX_DIGITS[b & 0xf];
}

/// Encode raw bytes into lowercase hexadecimal characters in `dst`.
pub fn encodeHexBytes(src: []const u8, dst: []u8) usize {
    for (src, 0..) |b, idx| {
        encodeHexByte(b, dst[idx * 2 ..][0..2]);
    }
    return src.len * 2;
}

/// Decode `dst.len` bytes from `hex_payload` (2 hex chars per byte).
pub fn decodeHexBytes(hex_payload: []const u8, dst: []u8) bool {
    if (hex_payload.len < dst.len * 2) return false;
    for (dst, 0..) |*out, idx| {
        out.* = parseHexByte(hex_payload[idx * 2 .. idx * 2 + 2]) orelse
            return false;
    }
    return true;
}

/// Send formatted GDB RSP packet: `$[payload]#[checksum_hex_2bytes]`.
pub fn sendPacket(payload: []const u8) void {
    writeSerialByte('$');
    for (payload) |ch| writeSerialByte(ch);
    writeSerialByte('#');

    const sum = computeChecksum(payload);
    writeSerialByte(HEX_DIGITS[(sum >> 4) & 0xf]);
    writeSerialByte(HEX_DIGITS[sum & 0xf]);
}

/// Send hex-encoded text string response inside an 'O' packet.
pub fn sendOutputPacket(text: []const u8) void {
    var hex_buf: [RSP_HEX_OUTPUT_BUF_LEN]u8 = undefined;
    const max_text_len = (hex_buf.len - 1) / 2;
    if (text.len > max_text_len) return;

    hex_buf[0] = 'O';
    const hex_len = encodeHexBytes(text, hex_buf[1..]);
    sendPacket(hex_buf[0 .. 1 + hex_len]);
}

pub fn encodeHexLE(comptime T: type, val: T, buf: []u8) usize {
    const size = @sizeOf(T);
    var offset: usize = 0;
    var i: usize = 0;
    while (i < size) : (i += 1) {
        const shift: std.math.Log2Int(T) = @intCast(i * 8);
        const byte: u8 = @truncate(val >> shift);
        encodeHexByte(byte, buf[offset..][0..2]);
        offset += 2;
    }
    return offset;
}

pub fn parseHexAddr(slice: []const u8) ?u64 {
    var end: usize = 0;
    while (end < slice.len and
        slice[end] != ',' and
        slice[end] != ':') : (end += 1)
    {}
    if (end == 0) return null;
    return std.fmt.parseInt(u64, slice[0..end], 16) catch null;
}

/// Parse 2 hex characters into a `u8` byte.
pub fn parseHexByte(slice: []const u8) ?u8 {
    if (slice.len < 2) return null;
    const hi = hexVal(slice[0]) orelse return null;
    const lo = hexVal(slice[1]) orelse return null;
    return (hi << 4) | lo;
}

pub fn parseAddrLen(slice: []const u8) ?struct { addr: u64, len: usize } {
    const comma_idx = std.mem.indexOfScalar(u8, slice, ',') orelse return null;
    const addr = std.fmt.parseInt(u64, slice[0..comma_idx], 16) catch
        return null;
    const len = std.fmt.parseInt(usize, slice[comma_idx + 1 ..], 16) catch
        return null;
    return .{ .addr = addr, .len = len };
}

pub const parseAddrAndLen = parseAddrLen;

pub fn readX86_64Registers(uc: ?*anyopaque, buf: []u8) usize {
    var offset: usize = 0;
    if (uc) |ptr| {
        const vcpu: *const @import("../emulation.zig").VCpu =
            @ptrCast(@alignCast(ptr));
        for (0..16) |i| {
            offset += encodeHexLE(u64, vcpu.regs[i], buf[offset..]);
        }
        offset += encodeHexLE(u64, vcpu.pc, buf[offset..]);
    } else {
        var i: usize = 0;
        while (i < 17) : (i += 1) {
            offset += encodeHexLE(u64, 0, buf[offset..]);
        }
    }
    var seg: usize = 0;
    while (seg < 7) : (seg += 1) {
        offset += encodeHexLE(u32, 0, buf[offset..]);
    }
    return offset;
}

pub fn readRV64RegistersForVcore(
    vc_opt: ?*const vcore.VirtualCore,
    buf: []u8,
) usize {
    var offset: usize = 0;
    if (vc_opt) |vc| {
        if (!vc.guest.is_confidential) {
            switch (vc.exec_path) {
                .native => {
                    for (0..32) |i| {
                        offset += encodeHexLE(
                            u64,
                            vc.context[i],
                            buf[offset..],
                        );
                    }
                    offset += encodeHexLE(
                        u64,
                        vc.machine.mepc,
                        buf[offset..],
                    );
                    return offset;
                },
                .emulated => |*emu| {
                    if (emu.vcpu) |vcpu| {
                        for (0..32) |i| {
                            offset += encodeHexLE(
                                u64,
                                vcpu.regs[i],
                                buf[offset..],
                            );
                        }
                        offset += encodeHexLE(u64, vcpu.pc, buf[offset..]);
                        return offset;
                    }
                },
            }
        }
    }
    var i: usize = 0;
    while (i < 32) : (i += 1) offset += encodeHexLE(u64, 0, buf[offset..]);
    offset += encodeHexLE(u64, 0x80000000, buf[offset..]);
    return offset;
}

test "RSP packet framing, checksum, hex encoding, and address parsing" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;

    try testing.expectEqual(@as(u8, 'O' + 'K'), computeChecksum("OK"));
    try testing.expectEqual(@as(?u8, 0xa), hexVal('a'));
    var hex_out: [4]u8 = undefined;
    const hex_len = encodeHexBytes("\xab\xcd", &hex_out);
    try testing.expectEqual(@as(usize, 4), hex_len);
    try testing.expectEqualStrings("abcd", &hex_out);
    try testing.expectEqual(@as(?u8, 0xab), parseHexByte("ab"));
    try testing.expectEqual(@as(?u64, 0x80001000), parseHexAddr("80001000,4"));
    const parsed = parseAddrLen("80001000,10").?;
    try testing.expectEqual(@as(u64, 0x80001000), parsed.addr);
    try testing.expectEqual(@as(usize, 0x10), parsed.len);
}
