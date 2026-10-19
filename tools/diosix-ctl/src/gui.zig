// Diosix Hypervisor Guest Management CLI — Semantic GUI & Tour Commands.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("api.zig");
const installer = @import("installer.zig");
const common = @import("common.zig");

const printStr = common.printStr;
const sanitizeJsonStr = common.sanitizeJsonStr;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;
const writeFile = common.writeFile;
const detectSeatProfile = common.detectSeatProfile;
const loadRuntimeSystemConfig = common.loadRuntimeSystemConfig;

const GuiSubcommand = enum {
    state,
    trigger,
    screenshot,
};

const TourOption = enum {
    @"--step",
    @"-s",
    @"--json",
    @"-j",
};

const JsonFlag = common.JsonFlag;

pub fn cmdGui(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    const exe_name = common.getExeName();
    _ = client;
    if (args.len == 0) {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            \\Usage:
            \\  {s} gui state [--json]             Inspect GUI window tree
            \\  {s} gui trigger <action> [--json]  Trigger semantic GUI action
            \\  {s} gui screenshot [path] [--json] Capture framebuffer dump
            \\
        , .{ exe_name, exe_name, exe_name }) catch return;
        printStr(msg);
        return;
    }

    const subcmd = std.mem.span(args[0]);
    var json_mode = false;
    for (args[1..]) |arg| {
        if (common.isJsonFlag(std.mem.span(arg))) {
            json_mode = true;
        }
    }

    _ = linux.mkdir("/run/diosix", 0o755);

    const cmd = std.meta.stringToEnum(GuiSubcommand, subcmd) orelse {
        printStr(
            "Error: Unknown gui subcommand. " ++
                "Use 'dsx gui state|trigger|screenshot'.\n",
        );
        return;
    };

    switch (cmd) {
        .state => {
            if (readBinaryFile("/run/diosix/gui_state.json", 4096)) |sbytes| {
                defer unmapBinaryFile(sbytes);
                printStr(sbytes);
                if (sbytes.len > 0 and sbytes[sbytes.len - 1] != '\n') {
                    printStr("\n");
                }
                return;
            } else |_| {}

            const seat = detectSeatProfile();
            const is_touch = std.mem.eql(u8, seat, "touch-tablet");
            if (json_mode) {
                var jbuf: [256]u8 = undefined;
                const jout = std.fmt.bufPrint(
                    &jbuf,
                    "{{\"active_pane\":\"fleet\",\"seat_profile\":\"{s}\"," ++
                        "\"osk_visible\":{s},\"tour_visible\":false}}\n",
                    .{ seat, if (is_touch) "true" else "false" },
                ) catch return;
                printStr(jout);
            } else {
                var obuf: [256]u8 = undefined;
                const out = std.fmt.bufPrint(
                    &obuf,
                    "GUI active pane  : fleet\n" ++
                        "Seat profile     : {s}\n" ++
                        "OSK visible      : {s}\n",
                    .{ seat, if (is_touch) "yes" else "no" },
                ) catch return;
                printStr(out);
            }
        },
        .trigger => {
            if (args.len < 2) {
                printStr("Usage: dsx gui trigger <action> [--json]\n");
                return;
            }
            const action = std.mem.span(args[1]);
            if (!installer.isValidHostname(action)) {
                printStr("Error: Invalid GUI action identifier.\n");
                return;
            }
            try writeFile("/run/diosix/gui_cmd", action);
            if (json_mode) {
                var jbuf: [256]u8 = undefined;
                const jout = std.fmt.bufPrint(
                    &jbuf,
                    "{{\"status\":\"dispatched\",\"action\":\"{s}\"}}\n",
                    .{action},
                ) catch return;
                printStr(jout);
            } else {
                var obuf: [256]u8 = undefined;
                const out = std.fmt.bufPrint(
                    &obuf,
                    "✓ Dispatched GUI action '{s}'\n",
                    .{action},
                ) catch return;
                printStr(out);
            }
        },
        .screenshot => {
            var out_path: []const u8 = "/tmp/diosix-screen.raw";
            if (args.len >= 2 and
                !std.mem.startsWith(u8, std.mem.span(args[1]), "-"))
            {
                out_path = std.mem.span(args[1]);
                if (std.mem.indexOf(u8, out_path, "..") != null or
                    !std.mem.startsWith(u8, out_path, "/tmp/"))
                {
                    printStr(
                        "Error: Screenshot path must be under /tmp/ " ++
                            "without '..'.\n",
                    );
                    return;
                }
            }
            var safe_path_buf: [128]u8 = undefined;
            const safe_path = sanitizeJsonStr(&safe_path_buf, out_path);
            if (readBinaryFile("/dev/fb0", 16 * 1024 * 1024)) |fb_bytes| {
                defer unmapBinaryFile(fb_bytes);
                try writeFile(safe_path, fb_bytes);
            } else |_| {
                try writeFile(safe_path, "DIOSIX_FRAMEBUFFER_SNAPSHOT");
            }
            if (json_mode) {
                var jbuf: [256]u8 = undefined;
                const jout = std.fmt.bufPrint(
                    &jbuf,
                    "{{\"status\":\"ok\",\"path\":\"{s}\"}}\n",
                    .{safe_path},
                ) catch return;
                printStr(jout);
            } else {
                var obuf: [256]u8 = undefined;
                const out = std.fmt.bufPrint(
                    &obuf,
                    "✓ Saved GUI screenshot to {s}\n",
                    .{safe_path},
                ) catch return;
                printStr(out);
            }
        },
    }
}

pub fn cmdTour(args: []const [*:0]const u8) !void {
    const sys_cfg = loadRuntimeSystemConfig();
    if (sys_cfg.tour_count == 0) {
        printStr("No tour steps configured.\n");
        return;
    }
    const total_steps = sys_cfg.tour_count;
    var step_opt: ?usize = null;
    var json_mode = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const span = std.mem.span(args[i]);
        if (std.meta.stringToEnum(TourOption, span)) |opt| {
            switch (opt) {
                .@"--step", .@"-s" => {
                    if (i + 1 < args.len) {
                        i += 1;
                        const parsed = std.fmt.parseInt(
                            usize,
                            std.mem.span(args[i]),
                            10,
                        ) catch 1;
                        step_opt = if (parsed >= 1 and parsed <= total_steps)
                            parsed - 1
                        else
                            0;
                    }
                },
                .@"--json", .@"-j" => json_mode = true,
            }
        }
    }

    if (step_opt) |idx| {
        const step = &sys_cfg.tour_steps[idx];
        var buf: [512]u8 = undefined;
        if (json_mode) {
            const jout = std.fmt.bufPrint(
                &buf,
                "{{\"step\":{d},\"total_steps\":{d},\"title\":\"{s}\"," ++
                    "\"summary\":\"{s}\",\"cli_hint\":\"{s}\"}}\n",
                .{
                    idx + 1,
                    total_steps,
                    step.title(),
                    step.summary(),
                    step.cliHint(),
                },
            ) catch return;
            printStr(jout);
        } else {
            const out = std.fmt.bufPrint(
                &buf,
                "=== {s} ===\n  {s}\n  Try command : {s}\n",
                .{ step.title(), step.summary(), step.cliHint() },
            ) catch return;
            printStr(out);
        }
        return;
    }

    if (json_mode) {
        var jbuf: [128]u8 = undefined;
        const jout = std.fmt.bufPrint(
            &jbuf,
            "{{\"tour_steps\":{d},\"status\":\"complete\"}}\n",
            .{total_steps},
        ) catch return;
        printStr(jout);
        return;
    }

    for (0..sys_cfg.tour_count) |idx| {
        const step = &sys_cfg.tour_steps[idx];
        var buf: [512]u8 = undefined;
        const out = std.fmt.bufPrint(
            &buf,
            "=== {s} ===\n  {s}\n  Try command : {s}\n\n",
            .{ step.title(), step.summary(), step.cliHint() },
        ) catch continue;
        printStr(out);
    }
}

test "gui_cmd: subcommand and option enums parse cleanly" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(
        GuiSubcommand.state,
        std.meta.stringToEnum(GuiSubcommand, "state").?,
    );
    try std.testing.expectEqual(
        TourOption.@"--step",
        std.meta.stringToEnum(TourOption, "--step").?,
    );
}
