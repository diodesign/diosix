// Semantic IPC command intake and state export for the Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const gui_mod = @import("gui.zig");
const paths = @import("paths.zig");
const DiosixGui = gui_mod.DiosixGui;

const CMD_PATH = paths.GUI_CMD_PATH;
const STATE_PATH = paths.GUI_STATE_PATH;
const STATE_TMP_PATH = paths.GUI_STATE_TMP_PATH;

/// Slack for the whitespace (newline, CR, tabs) that may surround a command
/// written to the IPC file by a shell.
const IPC_CMD_WHITESPACE_SLACK_BYTES: usize = 16;

/// Capacity for one IPC command read: the longest valid semantic command
/// name plus whitespace slack. A read that fills it completely is rejected
/// as over-long rather than parsed as a truncated (possibly valid) command.
pub const MAX_IPC_CMD_BYTES: usize = blk: {
    var longest: usize = 0;
    for (std.meta.fieldNames(gui_mod.SemanticAction)) |name| {
        longest = @max(longest, name.len);
    }
    break :blk longest + IPC_CMD_WHITESPACE_SLACK_BYTES;
};

/// Maximum length of the cached semantic JSON state used to skip redundant
/// disk writes on frames where only the backdrop or uptime label changed.
const STATE_CACHE_BYTES: usize = 1024;
var last_exported_json: [STATE_CACHE_BYTES]u8 = undefined;
var last_exported_len: usize = 0;

pub fn checkSemanticIpcCommand(gui: *DiosixGui) void {
    const flags = linux.O{ .ACCMODE = .RDONLY, .NOFOLLOW = true };
    const cmd_fd_rc = linux.open(CMD_PATH, flags, 0);
    const cmd_fd_signed: isize = @bitCast(cmd_fd_rc);
    if (cmd_fd_signed < 0) return;

    const cmd_fd: i32 = @intCast(cmd_fd_signed);
    var cmd_buf: [MAX_IPC_CMD_BYTES]u8 = undefined;
    const rd_rc = linux.read(cmd_fd, &cmd_buf, cmd_buf.len);
    _ = linux.close(cmd_fd);
    _ = linux.unlink(CMD_PATH);
    const rd_signed: isize = @bitCast(rd_rc);
    if (rd_signed <= 0) return;

    const rd_len: usize = @intCast(rd_signed);
    if (rd_len == cmd_buf.len) {
        std.debug.print(
            "diosix-gui: Ignoring IPC command longer than {d} bytes.\n",
            .{MAX_IPC_CMD_BYTES},
        );
        return;
    }
    const trimmed_cmd = std.mem.trim(u8, cmd_buf[0..rd_len], " \t\r\n");
    if (trimmed_cmd.len > 0) {
        _ = gui.triggerSemanticAction(trimmed_cmd) catch {};
    }
}

pub fn exportSemanticStateFile(gui: *const DiosixGui) void {
    const allocator = std.heap.page_allocator;
    const state_json = gui.exportSemanticStateJson(allocator) catch |err| {
        std.debug.print("diosix-gui: State export failed: {}\n", .{err});
        return;
    };
    defer allocator.free(state_json);

    if (state_json.len == last_exported_len and
        std.mem.eql(u8, state_json, last_exported_json[0..last_exported_len]))
    {
        return;
    }

    const flags = linux.O{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .NOFOLLOW = true,
    };
    const st_fd_rc = linux.open(STATE_TMP_PATH, flags, 0o600);
    const st_signed: isize = @bitCast(st_fd_rc);
    if (st_signed < 0) {
        std.debug.print(
            "diosix-gui: Cannot open {s}.\n",
            .{std.mem.span(STATE_TMP_PATH)},
        );
        return;
    }
    const st_fd: i32 = @intCast(st_signed);
    const wr_rc = linux.write(st_fd, state_json.ptr, state_json.len);
    _ = linux.close(st_fd);
    const wr_signed: isize = @bitCast(wr_rc);
    if (wr_signed < 0 or @as(usize, @intCast(wr_signed)) != state_json.len) {
        _ = linux.unlink(STATE_TMP_PATH);
        std.debug.print(
            "diosix-gui: Short write to {s}.\n",
            .{std.mem.span(STATE_TMP_PATH)},
        );
        return;
    }
    _ = linux.rename(STATE_TMP_PATH, STATE_PATH);

    if (state_json.len <= last_exported_json.len) {
        @memcpy(last_exported_json[0..state_json.len], state_json);
        last_exported_len = state_json.len;
    } else {
        last_exported_len = 0;
    }
}

test "ipc: command buffer fits every semantic action plus slack" {
    for (std.meta.fieldNames(gui_mod.SemanticAction)) |name| {
        try std.testing.expect(
            name.len + IPC_CMD_WHITESPACE_SLACK_BYTES <= MAX_IPC_CMD_BYTES,
        );
    }
    try std.testing.expect(MAX_IPC_CMD_BYTES > "welcome.close".len);
}

test {
    std.testing.refAllDecls(@This());
}
