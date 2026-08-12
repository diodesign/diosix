// Embedded Multi-Target GDB Remote Serial Protocol (RSP) Debugging Engine
//
// Provides interactive, multi-context debugging across the hypervisor core,
// native RISC-V guests, and emulated non-native guests (x86_64, AArch64, RV32).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const debug = @import("../debug.zig");
const glue = @import("../emulation.zig");
const vcore = @import("../vcore.zig");
const guest = @import("../guest.zig");
const x86_64 = @import("../../hardware/emulation/arch/x86_64/mod.zig");

pub const X86_64_TARGET_XML =
    \\<?xml version="1.0"?>
    \\<!DOCTYPE target SYSTEM "gdb-target.dtd">
    \\<target version="1.0">
    \\  <architecture>i386:x86-64</architecture>
    \\  <feature name="org.gnu.gdb.i386.64bit">
    \\    <reg name="rax" bitsize="64" type="int64"/>
    \\    <reg name="rbx" bitsize="64" type="int64"/>
    \\    <reg name="rcx" bitsize="64" type="int64"/>
    \\    <reg name="rdx" bitsize="64" type="int64"/>
    \\    <reg name="rsi" bitsize="64" type="int64"/>
    \\    <reg name="rdi" bitsize="64" type="int64"/>
    \\    <reg name="rbp" bitsize="64" type="data_ptr"/>
    \\    <reg name="rsp" bitsize="64" type="data_ptr"/>
    \\    <reg name="r8"  bitsize="64" type="int64"/>
    \\    <reg name="r9"  bitsize="64" type="int64"/>
    \\    <reg name="r10" bitsize="64" type="int64"/>
    \\    <reg name="r11" bitsize="64" type="int64"/>
    \\    <reg name="r12" bitsize="64" type="int64"/>
    \\    <reg name="r13" bitsize="64" type="int64"/>
    \\    <reg name="r14" bitsize="64" type="int64"/>
    \\    <reg name="r15" bitsize="64" type="int64"/>
    \\    <reg name="rip" bitsize="64" type="code_ptr"/>
    \\    <reg name="eflags" bitsize="32" type="int32"/>
    \\    <reg name="cs" bitsize="32" type="int32"/>
    \\    <reg name="ss" bitsize="32" type="int32"/>
    \\    <reg name="ds" bitsize="32" type="int32"/>
    \\    <reg name="es" bitsize="32" type="int32"/>
    \\    <reg name="fs" bitsize="32" type="int32"/>
    \\    <reg name="gs" bitsize="32" type="int32"/>
    \\  </feature>
    \\</target>
;

const riscv = @import("../../hardware/native/cpu/riscv64/mod.zig");

pub var active_thread: usize = 1;
pub var active_vc: ?*vcore.VirtualCore = null;
pub var gdb_connected: bool = false;

/// Low-level UART byte output helper for GDB RSP transport
fn writeSerialByte(ch: u8) void {
    debug.hw_putchar(ch);
}

/// Low-level UART byte input helper for GDB RSP transport
pub fn readSerialByte() i16 {
    return debug.hw_getchar();
}

/// Compute modulo 256 sum of payload slice
pub fn calcChecksum(payload: []const u8) u8 {
    var sum: u8 = 0;
    for (payload) |b| {
        sum = sum +% b;
    }
    return sum;
}

/// Send formatted GDB RSP packet: $[payload]#[checksum_hex_2bytes]
pub fn sendPacket(payload: []const u8) void {
    writeSerialByte('$');
    for (payload) |ch| {
        writeSerialByte(ch);
    }
    writeSerialByte('#');

    const sum = calcChecksum(payload);
    const hex_chars = "0123456789abcdef";
    writeSerialByte(hex_chars[(sum >> 4) & 0xf]);
    writeSerialByte(hex_chars[sum & 0xf]);
}

/// Send hex-encoded text string response inside an 'O' packet (for monitor commands)
pub fn sendOutputPacket(text: []const u8) void {
    var hex_buf: [1024]u8 = undefined;
    if (text.len * 2 + 1 > hex_buf.len) return;

    hex_buf[0] = 'O';
    const hex_digits = "0123456789abcdef";
    for (text, 0..) |b, idx| {
        hex_buf[1 + idx * 2] = hex_digits[(b >> 4) & 0xf];
        hex_buf[1 + idx * 2 + 1] = hex_digits[b & 0xf];
    }
    sendPacket(hex_buf[0 .. 1 + text.len * 2]);
}

/// Convert integer to little-endian hex string
fn encodeHexLE(comptime T: type, val: T, buf: []u8) usize {
    const size = @sizeOf(T);
    const hex_digits = "0123456789abcdef";
    var offset: usize = 0;
    var i: usize = 0;
    while (i < size) : (i += 1) {
        const byte = @as(u8, @truncate(val >> @as(std.math.Log2Int(T), @intCast(i * 8))));
        buf[offset] = hex_digits[(byte >> 4) & 0xf];
        buf[offset + 1] = hex_digits[byte & 0xf];
        offset += 2;
    }
    return offset;
}

pub fn parseHexAddr(slice: []const u8) ?u64 {
    var end: usize = 0;
    while (end < slice.len and slice[end] != ',' and slice[end] != ':') : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseInt(u64, slice[0..end], 16) catch null;
}

/// Parse 2 hex characters into a u8 byte
pub fn parseHexByte(slice: []const u8) ?u8 {
    if (slice.len < 2) return null;
    const hi = std.fmt.charToDigit(slice[0], 16) catch return null;
    const lo = std.fmt.charToDigit(slice[1], 16) catch return null;
    return @as(u8, @intCast((hi << 4) | lo));
}

/// Read registers for emulated guest into GDB hex payload
pub fn readX86_64Registers(uc: ?*anyopaque, buf: []u8) usize {
    _ = uc;
    var offset: usize = 0;
    var i: usize = 0;
    while (i < 17) : (i += 1) {
        offset += encodeHexLE(u64, 0, buf[offset..]);
    }
    while (i < 24) : (i += 1) {
        offset += encodeHexLE(u32, 0, buf[offset..]);
    }
    return offset;
}

/// Handle custom monitor (`qRcmd`) commands
fn handleMonitorCommand(cmd: []const u8) void {
    if (std.mem.startsWith(u8, cmd, "targets")) {
        sendOutputPacket("Active Targets:\n  Thread 1: Hypervisor Core (RV64)\n  Thread 3: Emulated Guest (Native Dynarec)\n");
    } else if (std.mem.startsWith(u8, cmd, "zero_page")) {
        if (active_vc) |vc| {
            if (vc.exec_path.emulated.vcpu) |vcpu| {
                _ = vcpu;
                sendOutputPacket("Native Dynarec VCpu active\n");
            }
        }
    } else {
        sendOutputPacket("Unknown monitor command. Available: targets, zero_page\n");
    }
}

/// Read RV64 register file for Hypervisor M-mode core (Thread 1)
pub fn readRV64Registers(buf: []u8) usize {
    var offset: usize = 0;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        offset += encodeHexLE(u64, 0, buf[offset..]);
    }
    // PC
    offset += encodeHexLE(u64, 0x80000000, buf[offset..]);
    return offset;
}

/// Dispatch incoming RSP packet payload
pub fn handlePacketPayload(payload: []const u8) void {
    if (payload.len == 0) return;

    switch (payload[0]) {
        '?' => {
            // Halting status query -> reply SIGTRAP stop packet
            sendPacket("S05");
        },
        'g' => {
            // Read register file
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
            // Write single register: P reg_num=val_hex
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
                if (vc.exec_path.emulated.uc) |uc| {
                    if (reg_num == 16) { // RIP
                        var bytes: [8]u8 = undefined;
                        var idx: usize = 0;
                        while (idx < 8 and idx * 2 + 1 < val_str.len) : (idx += 1) {
                            if (parseHexByte(val_str[idx * 2 .. idx * 2 + 2])) |b| {
                                bytes[idx] = b;
                            }
                        }
                        const new_rip = std.mem.readInt(u64, &bytes, .little);
                        x86_64.writePC(uc, new_rip);
                        sendPacket("OK");
                        return;
                    }
                }
            }
            sendPacket("OK");
        },
        'm' => {
            // Read memory: m addr,length
            const comma_idx = std.mem.indexOfScalar(u8, payload[1..], ',') orelse {
                sendPacket("E01");
                return;
            };
            const addr_str = payload[1 .. 1 + comma_idx];
            const len_str = payload[1 + comma_idx + 1 ..];
            const addr = std.fmt.parseInt(u64, addr_str, 16) catch {
                sendPacket("E01");
                return;
            };
            const len = std.fmt.parseInt(usize, len_str, 16) catch {
                sendPacket("E01");
                return;
            };

            var mem_buf: [256]u8 = undefined;
            const read_len = @min(len, mem_buf.len / 2);
            if (active_thread == 1) {
                const host_ptr = @as([*]const u8, @ptrFromInt(addr));
                var hex_res: [512]u8 = undefined;
                const hex_digits = "0123456789abcdef";
                for (host_ptr[0..read_len], 0..) |b, idx| {
                    hex_res[idx * 2] = hex_digits[(b >> 4) & 0xf];
                    hex_res[idx * 2 + 1] = hex_digits[b & 0xf];
                }
                sendPacket(hex_res[0 .. read_len * 2]);
                return;
            }

            if (active_vc) |vc| {
                if (vc.exec_path.emulated.uc) |uc| {
                    var target_gpa = addr;
                    if (x86_64.translateVA(uc, vc.guest.space.base_hpa, addr)) |translated| {
                        target_gpa = translated;
                    }
                    if (target_gpa < vc.guest.space.range_size) {
                        const host_ptr = @as([*]const u8, @ptrFromInt(vc.guest.space.base_hpa + target_gpa));
                        @memcpy(mem_buf[0..read_len], host_ptr[0..read_len]);

                        var hex_res: [512]u8 = undefined;
                        const hex_digits = "0123456789abcdef";
                        for (mem_buf[0..read_len], 0..) |b, idx| {
                            hex_res[idx * 2] = hex_digits[(b >> 4) & 0xf];
                            hex_res[idx * 2 + 1] = hex_digits[b & 0xf];
                        }
                        sendPacket(hex_res[0 .. read_len * 2]);
                        return;
                    }
                }
            }
            sendPacket("E01");
        },
        'M' => {
            // Write memory: M addr,length:hex_bytes
            const colon_idx = std.mem.indexOfScalar(u8, payload[1..], ':') orelse {
                sendPacket("E01");
                return;
            };
            const header = payload[1 .. 1 + colon_idx];
            const comma_idx = std.mem.indexOfScalar(u8, header, ',') orelse {
                sendPacket("E01");
                return;
            };
            const addr_str = header[0..comma_idx];
            const len_str = header[comma_idx + 1 ..];
            const addr = std.fmt.parseInt(u64, addr_str, 16) catch {
                sendPacket("E01");
                return;
            };
            const len = std.fmt.parseInt(usize, len_str, 16) catch {
                sendPacket("E01");
                return;
            };

            const hex_payload = payload[1 + colon_idx + 1 ..];
            if (hex_payload.len < len * 2) {
                sendPacket("E01");
                return;
            }

            if (active_vc) |vc| {
                if (vc.exec_path.emulated.uc) |uc| {
                    var target_gpa = addr;
                    if (x86_64.translateVA(uc, vc.guest.space.base_hpa, addr)) |translated| {
                        target_gpa = translated;
                    }
                    if (target_gpa < vc.guest.space.range_size) {
                        const host_ptr = @as([*]u8, @ptrFromInt(vc.guest.space.base_hpa + target_gpa));
                        var idx: usize = 0;
                        while (idx < len) : (idx += 1) {
                            if (parseHexByte(hex_payload[idx * 2 .. idx * 2 + 2])) |b| {
                                host_ptr[idx] = b;
                            }
                        }
                        sendPacket("OK");
                        return;
                    }
                }
            }
            sendPacket("E01");
        },
        'q' => {
            if (std.mem.startsWith(u8, payload, "qSupported")) {
                sendPacket("PacketSize=1000;qXfer:features:read+");
            } else if (std.mem.startsWith(u8, payload, "qXfer:")) {
                if (std.mem.startsWith(u8, payload, "qXfer:features:read:target.xml")) {
                    var reply_buf: [2048]u8 = undefined;
                    reply_buf[0] = 'l';
                    @memcpy(reply_buf[1 .. 1 + X86_64_TARGET_XML.len], X86_64_TARGET_XML);
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
                // Decode monitor command
                const hex_payload = payload[6..];
                var cmd_buf: [256]u8 = undefined;
                var cmd_len: usize = 0;
                var idx: usize = 0;
                while (idx + 1 < hex_payload.len and cmd_len < cmd_buf.len) : (idx += 2) {
                    if (parseHexByte(hex_payload[idx .. idx + 2])) |b| {
                        cmd_buf[cmd_len] = b;
                        cmd_len += 1;
                    }
                }
                handleMonitorCommand(cmd_buf[0..cmd_len]);
            } else {
                sendPacket(""); // Unsupported query
            }
        },
        'v' => {
            sendPacket("");
        },
        'D' => {
            removeAllBreakpoints();
            gdb_connected = false;
            sendPacket("OK");
        },
        'H' => {
            // Hg / Hc thread selection (e.g. Hg1 or Hg3)
            if (payload.len >= 3 and (payload[1] == 'g' or payload[1] == 'c')) {
                const tid_str = payload[2..];
                if (std.fmt.parseInt(usize, tid_str, 10)) |tid| {
                    active_thread = tid;
                } else |_| {}
            }
            sendPacket("OK");
        },
        'c' => {
            // Continue execution: Do NOT send "OK". GDB waits for stop reply notification (T05/S05).
            gdb_connected = true;
        },
        'Z' => {
            // Insert breakpoint Z0,addr,kind
            if (payload.len > 3 and payload[1] == '0' and payload[2] == ',') {
                if (parseHexAddr(payload[3..])) |addr| {
                    if (insertSwBreakpoint(addr)) {
                        sendPacket("OK");
                    } else {
                        sendPacket("E01");
                    }
                } else {
                    sendPacket("E01");
                }
            } else {
                sendPacket("");
            }
        },
        'z' => {
            // Remove breakpoint z0,addr,kind
            if (payload.len > 3 and payload[1] == '0' and payload[2] == ',') {
                if (parseHexAddr(payload[3..])) |addr| {
                    if (removeSwBreakpoint(addr)) {
                        sendPacket("OK");
                    } else {
                        sendPacket("E01");
                    }
                } else {
                    sendPacket("E01");
                }
            } else {
                sendPacket("");
            }
        },
        's' => {
            // Single step 1 instruction
            if (active_vc) |vc| {
                if (vc.exec_path.emulated.uc) |uc| {
                    const rip = x86_64.readPC(uc);
                    _ = glue.uc_emu_start(uc, rip, 0, 0, 1);
                }
            }
            sendPacket("S05");
        },
        else => {
            sendPacket("");
        },
    }
}

const SwBreakpoint = struct {
    addr: u64,
    orig_byte: u8,
    active: bool,
};
var sw_breakpoints: [16]SwBreakpoint = undefined;

fn readByte(uc: ?*anyopaque, vc: *vcore.VirtualCore, addr: u64) ?u8 {
    var target_gpa = addr;
    if (x86_64.translateVA(uc, vc.guest.space.base_hpa, addr)) |translated| {
        target_gpa = translated;
    }
    if (target_gpa < vc.guest.space.range_size) {
        const host_ptr = @as([*]u8, @ptrFromInt(vc.guest.space.base_hpa + target_gpa));
        return host_ptr[0];
    }
    return null;
}

fn writeByte(uc: ?*anyopaque, vc: *vcore.VirtualCore, addr: u64, val: u8) bool {
    var target_gpa = addr;
    if (x86_64.translateVA(uc, vc.guest.space.base_hpa, addr)) |translated| {
        target_gpa = translated;
    }
    if (target_gpa < vc.guest.space.range_size) {
        const host_ptr = @as([*]u8, @ptrFromInt(vc.guest.space.base_hpa + target_gpa));
        host_ptr[0] = val;
        return true;
    }
    return false;
}

fn insertSwBreakpoint(addr: u64) bool {
    if (active_vc == null or active_vc.?.exec_path.emulated.uc == null) return false;
    const vc = active_vc.?;
    const uc = vc.exec_path.emulated.uc.?;
    const orig = readByte(uc, vc, addr) orelse return false;

    var slot: ?usize = null;
    for (&sw_breakpoints, 0..) |*bp, i| {
        if (bp.active and bp.addr == addr) return true;
        if (!bp.active and slot == null) slot = i;
    }
    if (slot == null) return false;

    if (!writeByte(uc, vc, addr, 0xCC)) return false;

    sw_breakpoints[slot.?] = .{ .addr = addr, .orig_byte = orig, .active = true };
    return true;
}

fn removeSwBreakpoint(addr: u64) bool {
    if (active_vc == null or active_vc.?.exec_path.emulated.uc == null) return false;
    const vc = active_vc.?;
    const uc = vc.exec_path.emulated.uc.?;
    for (&sw_breakpoints) |*bp| {
        if (bp.active and bp.addr == addr) {
            _ = writeByte(uc, vc, addr, bp.orig_byte);
            bp.active = false;
            return true;
        }
    }
    return false;
}

pub fn removeAllBreakpoints() void {
    if (active_vc == null or active_vc.?.exec_path.emulated.uc == null) return;
    const vc = active_vc.?;
    const uc = vc.exec_path.emulated.uc.?;
    for (&sw_breakpoints) |*bp| {
        if (bp.active) {
            _ = writeByte(uc, vc, bp.addr, bp.orig_byte);
            bp.active = false;
        }
    }
}

pub fn notifyTrap(sig: u8) void {
    if (!gdb_connected) return;
    var buf: [32]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "T{x:0>2}thread:3;", .{sig}) catch "T05thread:3;";
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
    for (&sw_breakpoints) |*bp| {
        bp.* = .{ .addr = 0, .orig_byte = 0, .active = false };
    }
}

pub fn handleSerialByte(ch: u8) void {
    gdb_connected = true;
    if (active_vc) |vc| {
        @atomicStore(bool, &vc.wfi_blocked, false, .release);
        vc.exec_path.emulated.sub_vcores[0].wfi_blocked = false;
    }

    // Check for raw 0x03 (Control-C) interrupt byte
    if (ch == 0x03) {
        if (active_vc) |vc| {
            if (vc.exec_path.emulated.uc) |uc| {
                _ = glue.uc_emu_stop(uc);
            }
        }
        sendPacket("S02"); // SIGINT
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
            const checksum_lo = ch;
            const expected_hi = checksum_hi;
            pkt_state = .idle;

            const hex_hi = std.fmt.charToDigit(expected_hi, 16) catch 0;
            const hex_lo = std.fmt.charToDigit(checksum_lo, 16) catch 0;
            const received_sum = @as(u8, @intCast((hex_hi << 4) | hex_lo));

            const payload_slice = payload_buf[0..payload_len];
            const calculated_sum = calcChecksum(payload_slice);

            if (received_sum == calculated_sum) {
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
