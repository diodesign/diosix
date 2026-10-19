// Embedded Multi-Target GDB Remote Serial Protocol (RSP) debugging engine.
//
// Provides interactive, multi-context debugging across the hypervisor core,
// native RISC-V guests, and emulated non-native guests (x86_64, AArch64, RV32).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const debug = @import("../debug.zig");
const vcore = @import("../vcore.zig");
const physmem = @import("../physmem.zig");
const bp_mod = @import("breakpoints.zig");

pub const X86_64_TARGET_XML = bp_mod.X86_64_TARGET_XML;
pub const STATIC_BREAKPOINTS = bp_mod.STATIC_BREAKPOINTS;
pub const DYNAMIC_HASH_BUCKETS = bp_mod.DYNAMIC_HASH_BUCKETS;
pub const MAX_DYNAMIC_BREAKPOINTS = bp_mod.MAX_DYNAMIC_BREAKPOINTS;
pub const SwBreakpoint = bp_mod.SwBreakpoint;
pub const BreakpointTable = bp_mod.BreakpointTable;
pub const sw_breakpoints = &bp_mod.sw_breakpoints;

const HEX_DIGITS = "0123456789abcdef";

pub var active_thread: usize = 1;
pub var active_vc: ?*vcore.VirtualCore = null;
pub var gdb_connected: bool = false;

fn writeSerialByte(ch: u8) void {
    debug.hw_putchar(ch);
}

pub fn readSerialByte() i16 {
    return debug.hw_getchar();
}

/// Compute modulo 256 sum of payload slice.
pub fn calcChecksum(payload: []const u8) u8 {
    var sum: u8 = 0;
    for (payload) |b| sum = sum +% b;
    return sum;
}

/// Encode raw bytes into lowercase hexadecimal characters in `dst`.
pub fn encodeHexBytes(src: []const u8, dst: []u8) usize {
    for (src, 0..) |b, idx| {
        dst[idx * 2] = HEX_DIGITS[(b >> 4) & 0xf];
        dst[idx * 2 + 1] = HEX_DIGITS[b & 0xf];
    }
    return src.len * 2;
}

/// Decode `dst.len` bytes from `hex_payload` (2 hex chars per byte).
fn decodeHexBytes(hex_payload: []const u8, dst: []u8) bool {
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

    const sum = calcChecksum(payload);
    writeSerialByte(HEX_DIGITS[(sum >> 4) & 0xf]);
    writeSerialByte(HEX_DIGITS[sum & 0xf]);
}

/// Send hex-encoded text string response inside an 'O' packet.
pub fn sendOutputPacket(text: []const u8) void {
    var hex_buf: [1024]u8 = undefined;
    const max_text_len = (hex_buf.len - 1) / 2;
    if (text.len > max_text_len) return;

    hex_buf[0] = 'O';
    const hex_len = encodeHexBytes(text, hex_buf[1..]);
    sendPacket(hex_buf[0 .. 1 + hex_len]);
}

fn encodeHexLE(comptime T: type, val: T, buf: []u8) usize {
    const size = @sizeOf(T);
    var offset: usize = 0;
    var i: usize = 0;
    while (i < size) : (i += 1) {
        const shift: std.math.Log2Int(T) = @intCast(i * 8);
        const byte: u8 = @truncate(val >> shift);
        buf[offset] = HEX_DIGITS[(byte >> 4) & 0xf];
        buf[offset + 1] = HEX_DIGITS[byte & 0xf];
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
    const hi = std.fmt.charToDigit(slice[0], 16) catch return null;
    const lo = std.fmt.charToDigit(slice[1], 16) catch return null;
    return @as(u8, @intCast((hi << 4) | lo));
}

pub fn readX86_64Registers(uc: ?*anyopaque, buf: []u8) usize {
    _ = uc;
    var offset: usize = 0;
    var i: usize = 0;
    while (i < 17) : (i += 1) offset += encodeHexLE(u64, 0, buf[offset..]);
    while (i < 24) : (i += 1) offset += encodeHexLE(u32, 0, buf[offset..]);
    return offset;
}

fn handleMonitorCommand(cmd: []const u8) void {
    if (std.mem.startsWith(u8, cmd, "targets")) {
        sendOutputPacket(
            "Active Targets:\n" ++
                "  Thread 1: Hypervisor Core (RV64)\n" ++
                "  Thread 3: Emulated Guest (Native Dynarec)\n",
        );
    } else if (std.mem.startsWith(u8, cmd, "zero_page")) {
        if (active_vc) |vc| {
            if (vc.exec_path.emulated.vcpu != null) {
                sendOutputPacket("Native Dynarec VCpu active\n");
            }
        }
    } else {
        sendOutputPacket(
            "Unknown monitor command. Available: targets, zero_page\n",
        );
    }
}

pub fn readRV64Registers(buf: []u8) usize {
    var offset: usize = 0;
    var i: usize = 0;
    while (i < 32) : (i += 1) offset += encodeHexLE(u64, 0, buf[offset..]);
    offset += encodeHexLE(u64, 0x80000000, buf[offset..]);
    return offset;
}

fn parseAddrAndLen(slice: []const u8) ?struct { addr: u64, len: usize } {
    const comma_idx = std.mem.indexOfScalar(u8, slice, ',') orelse return null;
    const addr = std.fmt.parseInt(u64, slice[0..comma_idx], 16) catch
        return null;
    const len = std.fmt.parseInt(usize, slice[comma_idx + 1 ..], 16) catch
        return null;
    return .{ .addr = addr, .len = len };
}

fn handleMemoryRead(payload: []const u8) void {
    const parsed = parseAddrAndLen(payload[1..]) orelse {
        sendPacket("E01");
        return;
    };
    var mem_buf: [256]u8 = undefined;
    var hex_res: [512]u8 = undefined;
    const read_len = @min(parsed.len, mem_buf.len / 2);

    if (active_thread == 1) {
        const host_addr = std.math.cast(usize, parsed.addr) orelse {
            sendPacket("E01");
            return;
        };
        if (!physmem.isRam(host_addr, read_len)) {
            sendPacket("E01");
            return;
        }
        const host_ptr = @as([*]const u8, @ptrFromInt(host_addr));
        const hex_len = encodeHexBytes(host_ptr[0..read_len], &hex_res);
        sendPacket(hex_res[0..hex_len]);
        return;
    }

    if (active_vc) |vc| {
        const gpa = std.math.cast(usize, parsed.addr) orelse {
            sendPacket("E01");
            return;
        };
        const dst = mem_buf[0..read_len];
        if (vc.guest.space.copyFromGuest(dst, gpa)) |_| {
            const hex_len = encodeHexBytes(dst, &hex_res);
            sendPacket(hex_res[0..hex_len]);
            return;
        } else |_| {}
    }
    sendPacket("E01");
}

fn handleMemoryWrite(payload: []const u8) void {
    const colon_idx = std.mem.indexOfScalar(u8, payload[1..], ':') orelse {
        sendPacket("E01");
        return;
    };
    const parsed = parseAddrAndLen(payload[1 .. 1 + colon_idx]) orelse {
        sendPacket("E01");
        return;
    };
    const hex_payload = payload[1 + colon_idx + 1 ..];
    if (parsed.len > hex_payload.len / 2) {
        sendPacket("E01");
        return;
    }

    var write_buf: [256]u8 = undefined;
    const write_len = @min(parsed.len, write_buf.len);
    if (!decodeHexBytes(hex_payload, write_buf[0..write_len])) {
        sendPacket("E01");
        return;
    }

    if (active_thread == 1) {
        const host_addr = std.math.cast(usize, parsed.addr) orelse {
            sendPacket("E01");
            return;
        };
        if (!physmem.isRam(host_addr, write_len) or
            physmem.isHypervisorMemory(host_addr, write_len))
        {
            sendPacket("E01");
            return;
        }
        const host_ptr = @as([*]u8, @ptrFromInt(host_addr));
        @memcpy(host_ptr[0..write_len], write_buf[0..write_len]);
        sendPacket("OK");
        return;
    }

    if (active_vc) |vc| {
        const gpa = std.math.cast(usize, parsed.addr) orelse {
            sendPacket("E01");
            return;
        };
        const src = write_buf[0..write_len];
        if (vc.guest.space.copyToGuest(gpa, src)) |_| {
            sendPacket("OK");
            return;
        } else |_| {}
    }
    sendPacket("E01");
}

fn handleQuery(payload: []const u8) void {
    if (std.mem.startsWith(u8, payload, "qSupported")) {
        sendPacket("PacketSize=1000;qXfer:features:read+");
    } else if (std.mem.startsWith(u8, payload, "qXfer:")) {
        if (std.mem.startsWith(u8, payload, "qXfer:features:read:target.xml")) {
            var reply_buf: [2048]u8 = undefined;
            reply_buf[0] = 'l';
            @memcpy(
                reply_buf[1 .. 1 + X86_64_TARGET_XML.len],
                X86_64_TARGET_XML,
            );
            sendPacket(reply_buf[0 .. 1 + X86_64_TARGET_XML.len]);
        } else {
            sendPacket("");
        }
    } else if (std.mem.startsWith(u8, payload, "qfThreadInfo")) {
        sendPacket("m1,3");
    } else if (std.mem.startsWith(u8, payload, "qsThreadInfo")) {
        sendPacket("l");
    } else if (std.mem.startsWith(u8, payload, "qAttached")) {
        sendPacket("1");
    } else if (std.mem.startsWith(u8, payload, "qOffsets")) {
        sendPacket("Text=0;Data=0;Bss=0");
    } else if (std.mem.startsWith(u8, payload, "qC")) {
        sendPacket("QC1");
    } else if (std.mem.startsWith(u8, payload, "qRcmd,")) {
        const hex_in = payload[6..];
        var cmd_buf: [256]u8 = undefined;
        var cmd_len: usize = 0;
        var idx: usize = 0;
        while (idx + 1 < hex_in.len and cmd_len < cmd_buf.len) : (idx += 2) {
            if (parseHexByte(hex_in[idx .. idx + 2])) |b| {
                cmd_buf[cmd_len] = b;
                cmd_len += 1;
            }
        }
        handleMonitorCommand(cmd_buf[0..cmd_len]);
    } else {
        sendPacket("");
    }
}

/// Dispatch incoming RSP packet payload.
pub fn handlePacketPayload(payload: []const u8) void {
    if (payload.len == 0) return;

    switch (payload[0]) {
        '?' => sendPacket("S05"),
        'g' => {
            var reg_buf: [512]u8 = undefined;
            if (active_thread == 1) {
                const len = readRV64Registers(&reg_buf);
                sendPacket(reg_buf[0..len]);
                return;
            }
            if (active_vc) |vc| {
                if (vc.exec_path.emulated.vcpu) |vcpu| {
                    const len = readX86_64Registers(vcpu, &reg_buf);
                    sendPacket(reg_buf[0..len]);
                    return;
                }
            }
            sendPacket("E01");
        },
        'P' => {
            const eq_idx = std.mem.indexOfScalar(u8, payload[1..], '=') orelse {
                sendPacket("E01");
                return;
            };
            const reg_str = payload[1 .. 1 + eq_idx];
            const val_str = payload[1 + eq_idx + 1 ..];
            const reg_num = std.fmt.parseInt(usize, reg_str, 16) catch {
                sendPacket("E01");
                return;
            };
            if (active_vc) |vc| {
                if (vc.exec_path == .emulated and reg_num == 16) {
                    if (vc.exec_path.emulated.vcpu) |vcpu| {
                        var bytes: [8]u8 = @splat(0);
                        _ = decodeHexBytes(
                            val_str,
                            bytes[0..@min(8, val_str.len / 2)],
                        );
                        vcpu.pc = @truncate(
                            std.mem.readInt(u64, &bytes, .little),
                        );
                    }
                }
            }
            sendPacket("OK");
        },
        'm' => handleMemoryRead(payload),
        'M' => handleMemoryWrite(payload),
        'q' => handleQuery(payload),
        'v' => sendPacket(""),
        'D' => {
            removeAllBreakpoints();
            gdb_connected = false;
            sendPacket("OK");
        },
        'H' => {
            if (payload.len >= 3 and (payload[1] == 'g' or payload[1] == 'c')) {
                if (std.fmt.parseInt(usize, payload[2..], 10)) |tid| {
                    active_thread = tid;
                } else |_| {}
            }
            sendPacket("OK");
        },
        'c' => gdb_connected = true,
        'Z', 'z' => {
            if (payload.len > 3 and payload[1] == '0' and payload[2] == ',') {
                if (parseHexAddr(payload[3..])) |addr| {
                    const ok = if (payload[0] == 'Z')
                        bp_mod.insertSwBreakpoint(active_vc, addr)
                    else
                        bp_mod.removeSwBreakpoint(active_vc, addr);
                    sendPacket(if (ok) "OK" else "E01");
                } else {
                    sendPacket("E01");
                }
            } else {
                sendPacket("");
            }
        },
        's' => {
            if (active_vc) |vc| {
                if (vc.exec_path == .emulated and
                    vc.exec_path.emulated.vcpu != null)
                {
                    if (vc.exec_path.emulated.engine) |eng| _ = eng.step();
                }
            }
            sendPacket("S05");
        },
        else => sendPacket(""),
    }
}

pub fn removeAllBreakpoints() void {
    bp_mod.removeAllBreakpoints(active_vc);
}

pub fn notifyTrap(sig: u8) void {
    if (!gdb_connected) return;
    var buf: [32]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "T{x:0>2}thread:3;", .{sig}) catch
        "T05thread:3;";
    sendPacket(msg);
}

pub const PacketState = enum {
    idle,
    reading_payload,
    reading_checksum_hi,
    reading_checksum_lo,
};
var pkt_state: PacketState = .idle;
var payload_buf: [2048]u8 = undefined;
var payload_len: usize = 0;
var checksum_hi: u8 = 0;

pub fn init() void {
    pkt_state = .idle;
    payload_len = 0;
    bp_mod.sw_breakpoints.reset();
}

pub fn handleSerialByte(ch: u8) void {
    gdb_connected = true;
    if (active_vc) |vc| {
        @atomicStore(bool, &vc.wfi_blocked, false, .release);
    }

    if (ch == 0x03) {
        if (active_vc) |vc| {
            if (vc.exec_path == .emulated) {
                if (vc.exec_path.emulated.vcpu) |vcpu| vcpu.running = false;
            }
        }
        sendPacket("S02");
        pkt_state = .idle;
        return;
    }

    switch (pkt_state) {
        .idle => {
            if (ch == '$') {
                payload_len = 0;
                pkt_state = .reading_payload;
            }
        },
        .reading_payload => {
            if (ch == '#') {
                pkt_state = .reading_checksum_hi;
            } else if (payload_len < payload_buf.len) {
                payload_buf[payload_len] = ch;
                payload_len += 1;
            } else {
                pkt_state = .idle;
            }
        },
        .reading_checksum_hi => {
            checksum_hi = ch;
            pkt_state = .reading_checksum_lo;
        },
        .reading_checksum_lo => {
            const sum_chars = [2]u8{ checksum_hi, ch };
            pkt_state = .idle;

            const received_sum = parseHexByte(&sum_chars) orelse {
                writeSerialByte('-');
                return;
            };
            const payload_slice = payload_buf[0..payload_len];
            if (received_sum == calcChecksum(payload_slice)) {
                writeSerialByte('+');
                handlePacketPayload(payload_slice);
            } else {
                writeSerialByte('-');
            }
        },
    }
}

pub fn pollSerialInput() void {
    while (true) {
        const ch = readSerialByte();
        if (ch < 0) break;
        handleSerialByte(@as(u8, @intCast(ch)));
    }
}

pub inline fn onException(context: anytype) void {
    _ = context;
}

test {
    _ = bp_mod;
}
