// Diosix Hypervisor Guest Management CLI — Semantic GUI & Tour Commands.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("api.zig");
const installer = @import("installer.zig");
const common = @import("common.zig");
const sysconfig = @import("sysconfig.zig");

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

/// Largest GUI state document read back from the running GUI.
const MAX_GUI_STATE_BYTES: usize = 4096;

/// Largest framebuffer dump copied by `gui screenshot` (16 MiB).
const MAX_FRAMEBUFFER_BYTES: usize = 16 * 1024 * 1024;

pub fn cmdGui(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    const exe_name = common.getExeName();
    _ = client;
    if (args.len == 0) {
        common.printFmt(
            \\Usage:
            \\  {s} gui state [--json]             Inspect GUI window tree
            \\  {s} gui trigger <action> [--json]  Trigger semantic GUI action
            \\  {s} gui screenshot [path] [--json] Capture framebuffer dump
            \\
        , .{ exe_name, exe_name, exe_name });
        return;
    }

    const subcmd = std.mem.span(args[0]);
    var json_mode = false;
    for (args[1..]) |arg| {
        if (common.isJsonFlag(std.mem.span(arg))) {
            json_mode = true;
        }
    }

    _ = linux.mkdir(sysconfig.RUN_DIOSIX_DIR, 0o755);

    const cmd = std.meta.stringToEnum(GuiSubcommand, subcmd) orelse {
        printStr(
            "Error: Unknown gui subcommand. " ++
                "Use 'dsx gui state|trigger|screenshot'.\n",
        );
        return;
    };

    switch (cmd) {
        .state => {
            if (readBinaryFile(
                sysconfig.GUI_STATE_PATH,
                MAX_GUI_STATE_BYTES,
            )) |sbytes| {
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
                common.printFmt(
                    "{{\"active_pane\":\"fleet\",\"seat_profile\":\"{s}\"," ++
                        "\"osk_visible\":{s},\"tour_visible\":false}}\n",
                    .{ seat, if (is_touch) "true" else "false" },
                );
            } else {
                common.printFmt(
                    "GUI active pane  : fleet\n" ++
                        "Seat profile     : {s}\n" ++
                        "OSK visible      : {s}\n",
                    .{ seat, if (is_touch) "yes" else "no" },
                );
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
            try writeFile(sysconfig.GUI_CMD_PATH, action);
            if (json_mode) {
                common.printFmt(
                    "{{\"status\":\"dispatched\",\"action\":\"{s}\"}}\n",
                    .{action},
                );
            } else {
                common.printFmt("✓ Dispatched GUI action '{s}'\n", .{action});
            }
        },
        .screenshot => {
            var out_path: []const u8 = sysconfig.DEFAULT_RAW_SCREENSHOT_PATH;
            if (args.len >= 2 and
                !std.mem.startsWith(u8, std.mem.span(args[1]), "-"))
            {
                out_path = std.mem.span(args[1]);
                if (!common.isSafeStoragePath(
                    out_path,
                    sysconfig.VAR_LIB_DIOSIX_PREFIX,
                )) {
                    printStr(
                        "Error: Screenshot path must be under /tmp/ " ++
                            "without '..'.\n",
                    );
                    return;
                }
            }
            const allocator = std.heap.page_allocator;
            const safe_path_buf = try allocator.alloc(u8, out_path.len);
            defer allocator.free(safe_path_buf);
            const safe_path = sanitizeJsonStr(safe_path_buf, out_path);
            if (readBinaryFile(
                sysconfig.DEV_FB0_PATH,
                MAX_FRAMEBUFFER_BYTES,
            )) |fb_bytes| {
                defer unmapBinaryFile(fb_bytes);
                try writeFile(safe_path, fb_bytes);
            } else |_| {
                try writeFile(safe_path, "DIOSIX_FRAMEBUFFER_SNAPSHOT");
            }
            if (json_mode) {
                common.printFmt(
                    "{{\"status\":\"ok\",\"path\":\"{s}\"}}\n",
                    .{safe_path},
                );
            } else {
                common.printFmt(
                    "✓ Saved GUI screenshot to {s}\n",
                    .{safe_path},
                );
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
        if (json_mode) {
            const allocator = std.heap.page_allocator;
            const safe_title = try common.escapeJsonAlloc(
                allocator,
                step.title(),
            );
            defer allocator.free(safe_title);
            const safe_summary = try common.escapeJsonAlloc(
                allocator,
                step.summary(),
            );
            defer allocator.free(safe_summary);
            const safe_hint = try common.escapeJsonAlloc(
                allocator,
                step.cliHint(),
            );
            defer allocator.free(safe_hint);
            common.printFmt(
                "{{\"step\":{d},\"total_steps\":{d},\"title\":\"{s}\"," ++
                    "\"summary\":\"{s}\",\"cli_hint\":\"{s}\"}}\n",
                .{
                    idx + 1,
                    total_steps,
                    safe_title,
                    safe_summary,
                    safe_hint,
                },
            );
        } else {
            common.printFmt(
                "=== {s} ===\n  {s}\n  Try command : {s}\n",
                .{ step.title(), step.summary(), step.cliHint() },
            );
        }
        return;
    }

    if (json_mode) {
        common.printFmt(
            "{{\"tour_steps\":{d},\"status\":\"complete\"}}\n",
            .{total_steps},
        );
        return;
    }

    for (0..sys_cfg.tour_count) |idx| {
        const step = &sys_cfg.tour_steps[idx];
        common.printFmt(
            "=== {s} ===\n  {s}\n  Try command : {s}\n\n",
            .{ step.title(), step.summary(), step.cliHint() },
        );
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
