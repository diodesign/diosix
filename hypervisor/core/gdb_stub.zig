// Comptime wrapper for embedded GDB RSP stub
//
// In ReleaseSafe builds (or when enable_gdb is false), the GDB stub evaluates
// to zero-byte inline no-op functions, completely eliminating all packet parsing,
// string constants, and serial hooks from production binaries.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const config = @import("config");

pub const stub = if (config.enable_gdb)
    @import("gdb_rsp.zig")
else struct {
    pub var active_vc: ?*anyopaque = null;
    pub inline fn init() void {}
    pub inline fn handleSerialByte(byte: u8) void {
        _ = byte;
    }
    pub inline fn pollSerialInput() void {}
    pub inline fn onException(context: anytype) void {
        _ = context;
    }
};
