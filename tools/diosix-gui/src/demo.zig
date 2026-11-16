// Instant 1-Click & Boot-Time Dual-Guest Onboarding Coordinator for Diosix GUI.
//
// Parses kernel command-line onboarding flags (`diosix.demo=desktop|cli`,
// `diosix.mode=live`, `diosix.welcome=force`), launches the built-in Weston
// desktop (`linux-desktop.elf`) or interactive CLI (`linux-cli.elf`) guest VMs
// in the background via `dsx run`, and automatically opens the guest's
// VirtIO-GPU display or serial console pane once the VM is online.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const gui_mod = @import("gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const host_info = @import("host.zig");
const paths = @import("paths.zig");

pub const DESKTOP_DEMO_NAME: []const u8 = "desktop-demo";
pub const CLI_DEMO_NAME: []const u8 = "cli-demo";
pub const DESKTOP_DEMO_RAM: []const u8 = "512M";
pub const DESKTOP_DEMO_PCPU: []const u8 = "40";
pub const CLI_DEMO_RAM: []const u8 = "256M";
pub const CLI_DEMO_PCPU: []const u8 = "30";
pub const DEMO_VCPUS: []const u8 = "2";

const MAX_PROC_CMDLINE_BYTES: usize = 4096;

pub const DemoKind = enum {
    desktop,
    cli,

    pub fn instanceName(self: DemoKind) []const u8 {
        return switch (self) {
            .desktop => DESKTOP_DEMO_NAME,
            .cli => CLI_DEMO_NAME,
        };
    }

    pub fn imagePath(self: DemoKind) []const u8 {
        return switch (self) {
            .desktop => paths.DEFAULT_DESKTOP_IMAGE_PATH,
            .cli => paths.DEFAULT_CLI_IMAGE_PATH,
        };
    }
};

pub const BootAction = enum {
    none,
    open_welcome,
    launch_desktop,
    launch_cli,
};

pub const DemoState = struct {
    pending: ?DemoKind = null,
    task_id: ?u32 = null,
};

const BootCmdlineToken = enum {
    @"diosix.demo=desktop",
    @"diosix.demo=cli",
    @"diosix.welcome=force",
    @"diosix.mode=live",
};

pub fn parseBootActionFromCmdline(
    cmdline: []const u8,
    welcome_already_shown: bool,
) BootAction {
    var demo_override: ?BootAction = null;
    var force_welcome = false;
    var is_live = false;

    var it = std.mem.tokenizeAny(u8, cmdline, " \t\r\n");
    while (it.next()) |tok| {
        const parsed = std.meta.stringToEnum(BootCmdlineToken, tok) orelse
            continue;
        switch (parsed) {
            .@"diosix.demo=desktop" => demo_override = .launch_desktop,
            .@"diosix.demo=cli" => demo_override = .launch_cli,
            .@"diosix.welcome=force" => force_welcome = true,
            .@"diosix.mode=live" => is_live = true,
        }
    }

    if (demo_override) |act| {
        return if (welcome_already_shown) .none else act;
    }
    if (force_welcome) return .open_welcome;
    if (is_live and !welcome_already_shown) return .open_welcome;
    return .none;
}

fn hasWelcomeSentinel() bool {
    const rc = linux.open(
        paths.WELCOME_FLAG_PATH,
        .{ .ACCMODE = .RDONLY, .NOFOLLOW = true },
        0,
    );
    const signed_fd: isize = @bitCast(rc);
    if (signed_fd < 0) return false;
    _ = linux.close(@intCast(signed_fd));
    return true;
}

fn writeWelcomeSentinel() void {
    _ = linux.mkdir(paths.RUN_DIOSIX_DIR, 0o755);
    const flags = linux.O{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .NOFOLLOW = true,
    };
    const rc = linux.open(paths.WELCOME_FLAG_PATH, flags, 0o600);
    const signed_fd: isize = @bitCast(rc);
    if (signed_fd >= 0) {
        _ = linux.close(@intCast(signed_fd));
    }
}

pub fn applyBootPolicy(self: *DiosixGui) void {
    if (builtin.is_test) return;

    var buf: [MAX_PROC_CMDLINE_BYTES]u8 = undefined;
    const fd_rc = linux.open(
        paths.PROC_CMDLINE_PATH,
        .{ .ACCMODE = .RDONLY },
        0,
    );
    const signed_fd: isize = @bitCast(fd_rc);
    if (signed_fd < 0) return;
    const fd: i32 = @intCast(signed_fd);
    defer _ = linux.close(fd);

    const rd_rc = linux.read(fd, &buf, buf.len);
    const signed_rd: isize = @bitCast(rd_rc);
    if (signed_rd <= 0) return;
    const cmdline = buf[0..@intCast(signed_rd)];

    const act = parseBootActionFromCmdline(cmdline, hasWelcomeSentinel());
    if (act == .none) return;
    writeWelcomeSentinel();
    switch (act) {
        .none => {},
        .open_welcome => self.showWelcomeModal() catch {},
        .launch_desktop => launchDemoVm(self, .desktop),
        .launch_cli => launchDemoVm(self, .cli),
    }
}

fn matchDemoGuest(
    guests: []const host_info.RunningGuest,
    kind: DemoKind,
) ?u64 {
    const target_name = kind.instanceName();
    for (guests) |*g| {
        if (!g.isSelf() and g.cid >= 2 and
            std.mem.eql(u8, g.getInstanceName(), target_name))
        {
            return g.cid;
        }
    }
    return null;
}

fn findSampledDemoGuestCid(kind: DemoKind) ?u64 {
    var guests: [host_info.MAX_RUNNING_GUESTS]host_info.RunningGuest =
        undefined;
    const count = host_info.sampleRunningGuests(&guests);
    return matchDemoGuest(guests[0..count], kind);
}

fn findCachedDemoGuestCid(kind: DemoKind) ?u64 {
    var guests: [host_info.MAX_RUNNING_GUESTS]host_info.RunningGuest =
        undefined;
    const count = host_info.queryRunningGuests(&guests);
    return matchDemoGuest(guests[0..count], kind);
}

fn dismissDemoLaunchTask(self: *DiosixGui) void {
    if (self.demo_state.task_id) |tid| {
        self.demo_state.task_id = null;
        if (self.task_mgr.dismissTask(tid)) {
            self.syncTaskPanes();
        }
    }
}

fn openDemoPane(self: *DiosixGui, kind: DemoKind, cid: u64) void {
    switch (kind) {
        .desktop => self.openGuestDesktop(cid) catch {},
        .cli => self.openGuestTerminal(cid, .console) catch {},
    }
    self.completeNavAnimation();
}

pub fn launchDemoVm(self: *DiosixGui, kind: DemoKind) void {
    self.welcome_state.closeWelcome();
    self.welcome_state.closeTour();
    _ = self.destroyWindow(gui_mod.WIN_WELCOME_ID);
    _ = self.destroyWindow(gui_mod.WIN_TOUR_ID);
    self.markFullDirty();

    if (findSampledDemoGuestCid(kind)) |cid| {
        self.demo_state = .{};
        openDemoPane(self, kind, cid);
        return;
    }

    const dsx_bin = host_info.images.resolveDsxBinarySlice();
    const ram_s = switch (kind) {
        .desktop => DESKTOP_DEMO_RAM,
        .cli => CLI_DEMO_RAM,
    };
    const pcpu_s = switch (kind) {
        .desktop => DESKTOP_DEMO_PCPU,
        .cli => CLI_DEMO_PCPU,
    };
    const title_s = switch (kind) {
        .desktop => "Launching Desktop VM (desktop-demo)",
        .cli => "Launching CLI VM (cli-demo)",
    };
    const msg_s = switch (kind) {
        .desktop => "Starting Weston Wayland desktop guest...",
        .cli => "Starting interactive CLI Linux guest...",
    };
    const argv = [_][]const u8{
        dsx_bin,
        "run",
        kind.imagePath(),
        "--name",
        kind.instanceName(),
        "--vcpus",
        DEMO_VCPUS,
        "--ram",
        ram_s,
        "--pcpu",
        pcpu_s,
        "--ram-quota",
        ram_s,
    };
    const tid = self.spawnBackgroundTask(title_s, msg_s, &argv);
    self.demo_state = .{
        .pending = kind,
        .task_id = tid,
    };
}

pub fn poll(self: *DiosixGui) void {
    const kind = self.demo_state.pending orelse return;

    if (findCachedDemoGuestCid(kind)) |cid| {
        dismissDemoLaunchTask(self);
        self.demo_state = .{};
        openDemoPane(self, kind, cid);
        return;
    }

    if (self.demo_state.task_id) |tid| {
        const entry = self.task_mgr.findById(tid);
        if (entry == null or entry.?.state != .running) {
            const maybe_cid = if (entry != null and entry.?.state == .completed)
                findSampledDemoGuestCid(kind)
            else
                null;
            if (maybe_cid) |cid| {
                dismissDemoLaunchTask(self);
                self.demo_state = .{};
                openDemoPane(self, kind, cid);
            } else {
                self.demo_state = .{};
            }
        }
    }
}

test "demo: parseBootActionFromCmdline precedence and sentinel rules" {
    std.testing.refAllDecls(@This());
    const expectEq = std.testing.expectEqual;

    try expectEq(
        BootAction.none,
        parseBootActionFromCmdline("console=hvc0 diosix.mode=dev\n", false),
    );
    try expectEq(
        BootAction.open_welcome,
        parseBootActionFromCmdline("console=hvc0 diosix.mode=live\n", false),
    );
    try expectEq(
        BootAction.none,
        parseBootActionFromCmdline("console=hvc0 diosix.mode=live\n", true),
    );
    try expectEq(
        BootAction.open_welcome,
        parseBootActionFromCmdline(
            "console=hvc0 diosix.mode=dev diosix.welcome=force\n",
            true,
        ),
    );
    try expectEq(
        BootAction.launch_desktop,
        parseBootActionFromCmdline(
            "console=hvc0 diosix.mode=live diosix.demo=desktop\n",
            false,
        ),
    );
    try expectEq(
        BootAction.launch_cli,
        parseBootActionFromCmdline(
            "console=hvc0 diosix.mode=live diosix.demo=cli\n",
            false,
        ),
    );
    try expectEq(
        BootAction.none,
        parseBootActionFromCmdline(
            "console=hvc0 diosix.mode=live diosix.demo=desktop\n",
            true,
        ),
    );
}

test "demo: launchDemoVm spawns task and poll opens desktop/terminal panes" {
    defer host_info.guests.mock_running_guests = null;
    defer host_info.resetGuestTelemetryCache();

    var gui = try DiosixGui.init(std.testing.allocator, 1280, 800);
    defer gui.deinit();

    // 1. Triggering welcome.try_desktop spawns a task and closes the modal.
    try gui.showWelcomeModal();
    try std.testing.expect(
        try gui.triggerSemanticAction("welcome.try_desktop"),
    );
    try std.testing.expect(!gui.welcome_state.welcome_visible);
    try std.testing.expectEqual(DemoKind.desktop, gui.demo_state.pending.?);
    const tid = gui.demo_state.task_id.?;

    // 2. Once desktop-demo appears and task completes, poll opens display pane.
    var mock_list: [2]host_info.RunningGuest = .{ .{}, .{} };
    mock_list[0].cid = 1;
    mock_list[0].is_self = true;
    mock_list[0].setInstanceName("local-vm");
    mock_list[1].cid = 2;
    mock_list[1].is_self = false;
    mock_list[1].setInstanceName("desktop-demo");
    mock_list[1].setImageName("Diosix Linux Desktop (Weston)");
    host_info.guests.mock_running_guests = &mock_list;

    _ = gui.task_mgr.completeTask(tid, "Done");
    poll(&gui);
    try std.testing.expect(gui.demo_state.pending == null);
    try std.testing.expect(gui.desktop.active);
    try std.testing.expectEqual(@as(u64, 2), gui.desktop.target_cid);

    // 3. When cli-demo is already running, try_cli opens its console directly.
    mock_list[1].cid = 3;
    mock_list[1].setInstanceName("cli-demo");
    mock_list[1].setImageName("Diosix Linux CLI");
    try std.testing.expect(try gui.triggerSemanticAction("welcome.try_cli"));
    try std.testing.expect(gui.demo_state.pending == null);
    try std.testing.expect(gui.terminal.active);
    try std.testing.expectEqual(@as(u64, 3), gui.terminal.target_cid);
    try std.testing.expectEqual(
        gui_mod.terminal_mod.TerminalMode.console,
        gui.terminal.mode,
    );
}
