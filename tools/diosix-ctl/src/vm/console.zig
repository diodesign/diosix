// Guest Serial Console (SBI DBCN / hvc0) CLI Attachment and Log Dumper.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("../api.zig");
const common = @import("../common.zig");

pub const DETACH_KEY_CTRL_BRACKET: u8 = 0x1d;
const CONSOLE_POLL_TIMEOUT_MS: i32 = 20;
const CONSOLE_READ_CHUNK_BYTES: usize = 1024;
const STDIN_READ_CHUNK_BYTES: usize = 64;

const TCGETS: u32 = 0x5401;
const TCSETS: u32 = 0x5402;

const RawTermiosGuard = struct {
    saved: linux.termios = undefined,
    active: bool = false,

    pub fn enter() RawTermiosGuard {
        var guard = RawTermiosGuard{};
        const rc = linux.ioctl(
            linux.STDIN_FILENO,
            TCGETS,
            @intFromPtr(&guard.saved),
        );
        if (@as(isize, @bitCast(rc)) < 0) return guard;

        var raw = guard.saved;
        // Disable canonical mode, echo, and signal generation so Ctrl+C /
        // arrow keys / Enter pass directly to the guest's hvc0 console.
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        const set_rc = linux.ioctl(
            linux.STDIN_FILENO,
            TCSETS,
            @intFromPtr(&raw),
        );
        if (@as(isize, @bitCast(set_rc)) == 0) {
            guard.active = true;
        }
        return guard;
    }

    pub fn restore(self: *RawTermiosGuard) void {
        if (!self.active) return;
        _ = linux.ioctl(
            linux.STDIN_FILENO,
            TCSETS,
            @intFromPtr(&self.saved),
        );
        self.active = false;
    }
};

pub const ResolvedConsoleTarget = struct {
    cid: usize,
    name: []const u8,
};

pub fn resolveConsoleTarget(
    allocator: std.mem.Allocator,
    target_str: []const u8,
) !?ResolvedConsoleTarget {
    const SelfAlias = enum { root, self };
    const resolved_cid: usize = common.parseCid(target_str) catch 0;
    if (std.meta.stringToEnum(SelfAlias, target_str) != null or
        resolved_cid == common.CID_SELF)
    {
        return .{ .cid = common.CID_SELF, .name = "root" };
    }

    if (common.readBinaryFile(
        common.GUEST_REGISTRY_PATH,
        common.MAX_MANIFEST_SIZE,
    )) |content| {
        defer common.unmapBinaryFile(content);
        var iter = common.GuestRegistryIter.init(content);
        while (iter.next()) |e| {
            if (common.matchTarget(target_str, resolved_cid, e.cid, e.name)) {
                return .{
                    .cid = e.cid,
                    .name = try allocator.dupe(u8, e.name),
                };
            }
        }
    } else |_| {}

    if (resolved_cid >= common.CID_FIRST_CHILD) {
        return .{ .cid = resolved_cid, .name = target_str };
    }
    return null;
}

pub const DetachScan = struct {
    forward_len: usize,
    should_detach: bool,
};

pub fn scanForDetachKey(input: []const u8) DetachScan {
    if (std.mem.indexOfScalar(u8, input, DETACH_KEY_CTRL_BRACKET)) |idx| {
        return .{ .forward_len = idx, .should_detach = true };
    }
    return .{ .forward_len = input.len, .should_detach = false };
}

fn drainConsoleOutput(client: *api.DiosixClient, cid: usize) !usize {
    var total: usize = 0;
    var buf: [CONSOLE_READ_CHUNK_BYTES]u8 = undefined;
    while (true) {
        const n = try client.consoleRead(cid, &buf);
        if (n == 0) break;
        _ = linux.write(linux.STDOUT_FILENO, &buf, n);
        total += n;
        if (n < buf.len) break;
    }
    return total;
}

pub fn cmdConsole(
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
) !void {
    const exe_name = common.getExeName();
    if (args.len == 0) {
        common.printFmt(
            "Usage: {s} console <name|cid> [--dump]\n",
            .{exe_name},
        );
        return;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const ConsoleOpt = enum { @"--dump", @"-d" };
    var target_arg: []const u8 = "";
    var dump_only = false;

    for (args) |arg| {
        const span = std.mem.span(arg);
        if (std.meta.stringToEnum(ConsoleOpt, span) != null) {
            dump_only = true;
        } else if (target_arg.len == 0 and !std.mem.startsWith(u8, span, "-")) {
            target_arg = span;
        } else {
            common.printFmt(
                "Error: Unknown option '{s}'. " ++
                    "Usage: {s} console <name|cid> [--dump]\n",
                .{ span, exe_name },
            );
            return;
        }
    }

    if (target_arg.len == 0) {
        common.printFmt(
            "Error: No target VM specified. " ++
                "Usage: {s} console <name|cid> [--dump]\n",
            .{exe_name},
        );
        return;
    }

    const target = (try resolveConsoleTarget(allocator, target_arg)) orelse {
        common.printFmt(
            "Error: Guest '{s}' not found. " ++
                "Use '{s} list' to view running guests.\n",
            .{ target_arg, exe_name },
        );
        return;
    };

    if (dump_only) {
        _ = drainConsoleOutput(client, target.cid) catch |err| {
            common.printApiError("Read guest console", err);
        };
        return;
    }

    common.printFmt(
        "Connected to guest '{s}' (CID {d}) serial console " ++
            "(press Ctrl+] to detach)...\n",
        .{ target.name, target.cid },
    );

    var term_guard = RawTermiosGuard.enter();
    defer term_guard.restore();

    var in_buf: [STDIN_READ_CHUNK_BYTES]u8 = undefined;
    while (true) {
        _ = drainConsoleOutput(client, target.cid) catch break;

        var pfds = [1]linux.pollfd{.{
            .fd = linux.STDIN_FILENO,
            .events = linux.POLL.IN,
            .revents = 0,
        }};
        const prc = linux.poll(&pfds, 1, CONSOLE_POLL_TIMEOUT_MS);
        const signed_prc: isize = @bitCast(prc);
        if (signed_prc > 0) {
            if ((pfds[0].revents & linux.POLL.IN) != 0) {
                const rrc = linux.read(
                    linux.STDIN_FILENO,
                    &in_buf,
                    in_buf.len,
                );
                const signed_rrc: isize = @bitCast(rrc);
                if (signed_rrc <= 0) break;
                const n: usize = @intCast(signed_rrc);
                const scan = scanForDetachKey(in_buf[0..n]);
                if (scan.forward_len > 0) {
                    _ = client.consoleWrite(
                        target.cid,
                        in_buf[0..scan.forward_len],
                    ) catch break;
                }
                if (scan.should_detach) {
                    common.printStr("\r\nDetached from serial console.\r\n");
                    break;
                }
            } else if ((pfds[0].revents &
                (linux.POLL.HUP | linux.POLL.ERR)) != 0)
            {
                break;
            }
        }
    }
}

test "console: scanForDetachKey and resolveConsoleTarget" {
    std.testing.refAllDecls(@This());
    const s1 = scanForDetachKey("ls -la\r");
    try std.testing.expectEqual(@as(usize, 7), s1.forward_len);
    try std.testing.expect(!s1.should_detach);

    const s2 = scanForDetachKey("abc\x1ddef");
    try std.testing.expectEqual(@as(usize, 3), s2.forward_len);
    try std.testing.expect(s2.should_detach);

    const res_self = (try resolveConsoleTarget(
        std.testing.allocator,
        "self",
    )).?;
    try std.testing.expectEqual(@as(usize, 1), res_self.cid);
    const res_cid = (try resolveConsoleTarget(
        std.testing.allocator,
        "2",
    )).?;
    try std.testing.expectEqual(@as(usize, 2), res_cid.cid);
}
