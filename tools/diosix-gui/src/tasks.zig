// Background Task & Notification Progress Manager for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const MAX_TASKS: usize = 8;
pub const TASK_TITLE_CAP: usize = 64;
pub const TASK_MSG_CAP: usize = 160;
pub const TASK_LINE_CAP: usize = 256;
pub const MAX_TASK_ARGS: usize = 16;

pub const TaskState = enum {
    running,
    completed,
    failed,
};

pub const TaskEntry = struct {
    id: u32 = 0,
    active: bool = false,
    state: TaskState = .running,
    progress_pct: u8 = 0,
    title_buf: [TASK_TITLE_CAP]u8 = @splat(0),
    title_len: usize = 0,
    msg_buf: [TASK_MSG_CAP]u8 = @splat(0),
    msg_len: usize = 0,
    pid: i32 = -1,
    pipe_fd: i32 = -1,
    line_buf: [TASK_LINE_CAP]u8 = @splat(0),
    line_len: usize = 0,
    saw_error_line: bool = false,
    refresh_guests_on_done: bool = true,

    pub fn getTitle(self: *const TaskEntry) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn setTitle(self: *TaskEntry, title: []const u8) void {
        const n = @min(title.len, TASK_TITLE_CAP - 1);
        if (title.ptr != &self.title_buf) {
            std.mem.copyForwards(u8, self.title_buf[0..n], title[0..n]);
        }
        self.title_buf[n] = 0;
        self.title_len = n;
    }

    pub fn getMessage(self: *const TaskEntry) []const u8 {
        return self.msg_buf[0..self.msg_len];
    }

    pub fn setMessage(self: *TaskEntry, msg: []const u8) void {
        const n = @min(msg.len, TASK_MSG_CAP - 1);
        if (msg.ptr != &self.msg_buf) {
            std.mem.copyForwards(u8, self.msg_buf[0..n], msg[0..n]);
        }
        self.msg_buf[n] = 0;
        self.msg_len = n;
    }

    pub fn formatDisplayLabel(
        self: *const TaskEntry,
        buf: []u8,
    ) []const u8 {
        const title = self.getTitle();
        const msg = self.getMessage();
        return switch (self.state) {
            .running => if (msg.len > 0)
                std.fmt.bufPrint(buf, "{s}: {s}", .{ title, msg }) catch title
            else
                title,
            .completed => if (msg.len > 0)
                std.fmt.bufPrint(buf, "Done: {s}", .{msg}) catch msg
            else
                std.fmt.bufPrint(buf, "Done: {s}", .{title}) catch title,
            .failed => if (msg.len > 0)
                std.fmt.bufPrint(buf, "{s}", .{msg}) catch msg
            else
                std.fmt.bufPrint(buf, "Failed: {s}", .{title}) catch title,
        };
    }

    pub fn closePipe(self: *TaskEntry) void {
        if (self.pipe_fd >= 0) {
            _ = linux.close(self.pipe_fd);
            self.pipe_fd = -1;
        }
    }

    pub fn processOutputLine(self: *TaskEntry, raw_line: []const u8) bool {
        const trimmed = std.mem.trim(u8, raw_line, " \t\r\n");
        if (trimmed.len == 0) return false;

        if (trimmed[0] == '[') {
            if (std.mem.indexOf(u8, trimmed, "%]")) |end_idx| {
                const num_str = trimmed[1..end_idx];
                if (std.fmt.parseInt(u8, num_str, 10)) |pct| {
                    self.progress_pct = @min(@as(u8, 100), pct);
                } else |_| {}
                const rest = std.mem.trim(
                    u8,
                    trimmed[end_idx + 2 ..],
                    " \t",
                );
                if (rest.len > 0) self.setMessage(rest);
                return true;
            }
        }

        if (std.mem.startsWith(u8, trimmed, "Error:") or
            std.mem.startsWith(u8, trimmed, "error:"))
        {
            self.saw_error_line = true;
            self.setMessage(trimmed);
            return true;
        }

        if (std.mem.startsWith(u8, trimmed, "✓")) {
            const after = std.mem.trim(u8, trimmed["✓".len..], " \t");
            if (after.len > 0) self.setMessage(after);
            self.progress_pct = 100;
            return true;
        }

        if (!self.saw_error_line) {
            self.setMessage(trimmed);
            return true;
        }
        return false;
    }

    pub fn feedBytes(self: *TaskEntry, data: []const u8) bool {
        var changed = false;
        for (data) |ch| {
            if (ch == '\n' or ch == '\r') {
                if (self.line_len > 0) {
                    if (self.processOutputLine(
                        self.line_buf[0..self.line_len],
                    )) {
                        changed = true;
                    }
                    self.line_len = 0;
                }
            } else if (self.line_len + 1 < TASK_LINE_CAP) {
                self.line_buf[self.line_len] = ch;
                self.line_len += 1;
            }
        }
        return changed;
    }

    pub fn flushPendingLine(self: *TaskEntry) bool {
        if (self.line_len == 0) return false;
        const changed = self.processOutputLine(self.line_buf[0..self.line_len]);
        self.line_len = 0;
        return changed;
    }
};

pub const PollResult = struct {
    ui_changed: bool = false,
    guests_changed: bool = false,
};

pub const TaskManager = struct {
    entries: [MAX_TASKS]TaskEntry = @splat(.{}),
    next_id: u32 = 1,

    pub fn activeCount(self: *const TaskManager) usize {
        var count: usize = 0;
        for (&self.entries) |*e| {
            if (e.active) count += 1;
        }
        return count;
    }

    pub fn hasRunningTasks(self: *const TaskManager) bool {
        for (&self.entries) |*e| {
            if (e.active and e.state == .running) return true;
        }
        return false;
    }

    pub fn findById(self: *TaskManager, task_id: u32) ?*TaskEntry {
        for (&self.entries) |*e| {
            if (e.active and e.id == task_id) return e;
        }
        return null;
    }

    fn allocSlot(self: *TaskManager) *TaskEntry {
        for (&self.entries) |*e| {
            if (!e.active) return e;
        }
        // Evict oldest finished task first; otherwise evict slot 0.
        for (&self.entries) |*e| {
            if (e.state != .running) {
                e.closePipe();
                e.* = .{};
                return e;
            }
        }
        self.entries[0].closePipe();
        self.entries[0] = .{};
        return &self.entries[0];
    }

    pub fn startTask(
        self: *TaskManager,
        title: []const u8,
        initial_msg: []const u8,
        initial_pct: u8,
    ) u32 {
        const slot = self.allocSlot();
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;

        slot.* = .{
            .id = id,
            .active = true,
            .state = .running,
            .progress_pct = @min(@as(u8, 100), initial_pct),
        };
        slot.setTitle(title);
        slot.setMessage(initial_msg);
        return id;
    }

    pub fn updateProgress(
        self: *TaskManager,
        task_id: u32,
        pct: u8,
        msg: ?[]const u8,
    ) bool {
        const e = self.findById(task_id) orelse return false;
        e.progress_pct = @min(@as(u8, 100), pct);
        if (msg) |m| e.setMessage(m);
        return true;
    }

    pub fn completeTask(
        self: *TaskManager,
        task_id: u32,
        msg: ?[]const u8,
    ) bool {
        const e = self.findById(task_id) orelse return false;
        e.closePipe();
        e.pid = -1;
        e.state = .completed;
        e.progress_pct = 100;
        if (msg) |m| e.setMessage(m);
        return true;
    }

    pub fn failTask(
        self: *TaskManager,
        task_id: u32,
        err_msg: []const u8,
    ) bool {
        const e = self.findById(task_id) orelse return false;
        e.closePipe();
        e.pid = -1;
        e.state = .failed;
        e.saw_error_line = true;
        e.setMessage(err_msg);
        return true;
    }

    pub fn dismissTask(self: *TaskManager, task_id: u32) bool {
        for (0..MAX_TASKS) |i| {
            if (self.entries[i].active and self.entries[i].id == task_id) {
                self.entries[i].closePipe();
                // Compact remaining active tasks to preserve stacking order.
                var j = i;
                while (j + 1 < MAX_TASKS) : (j += 1) {
                    self.entries[j] = self.entries[j + 1];
                }
                self.entries[MAX_TASKS - 1] = .{};
                return true;
            }
        }
        return false;
    }

    pub fn spawnCommand(
        self: *TaskManager,
        title: []const u8,
        initial_msg: []const u8,
        argv_slices: []const []const u8,
        mock_mode: bool,
    ) u32 {
        const task_id = self.startTask(title, initial_msg, 5);
        if (builtin.is_test or mock_mode) {
            return task_id;
        }
        const slot = self.findById(task_id) orelse return task_id;

        var pipe_fds: [2]i32 = .{ -1, -1 };
        const pipe_rc = linux.pipe2(
            &pipe_fds,
            .{ .NONBLOCK = true, .CLOEXEC = true },
        );
        if (linux.errno(pipe_rc) != .SUCCESS) {
            _ = self.failTask(task_id, "Error: Failed to create task pipe.");
            return task_id;
        }

        const fork_rc = linux.fork();
        if (linux.errno(fork_rc) != .SUCCESS) {
            _ = linux.close(pipe_fds[0]);
            _ = linux.close(pipe_fds[1]);
            _ = self.failTask(
                task_id,
                "Error: Failed to spawn background process.",
            );
            return task_id;
        }

        if (fork_rc == 0) {
            _ = linux.close(pipe_fds[0]);
            _ = linux.dup2(pipe_fds[1], 1);
            _ = linux.dup2(pipe_fds[1], 2);
            if (pipe_fds[1] > 2) _ = linux.close(pipe_fds[1]);

            var arg_buf: [512]u8 = undefined;
            var arg_ptrs: [MAX_TASK_ARGS:null]?[*:0]const u8 = @splat(null);
            var offset: usize = 0;
            var argc: usize = 0;
            for (argv_slices) |s| {
                if (argc >= MAX_TASK_ARGS - 1) break;
                if (offset + s.len + 1 > arg_buf.len) break;
                @memcpy(arg_buf[offset .. offset + s.len], s);
                arg_buf[offset + s.len] = 0;
                arg_ptrs[argc] = @ptrCast(arg_buf[offset .. offset + s.len :0]);
                offset += s.len + 1;
                argc += 1;
            }
            arg_ptrs[argc] = null;
            const envp = [_:null]?[*:0]const u8{
                "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME=/root",
            };
            if (arg_ptrs[0]) |cmd0| {
                _ = linux.execve(cmd0, &arg_ptrs, &envp);
            }
            _ = linux.write(2, "Error: Failed to execute dsx command.\n", 38);
            linux.exit_group(1);
        }

        _ = linux.close(pipe_fds[1]);
        slot.pipe_fd = pipe_fds[0];
        slot.pid = @intCast(fork_rc);
        return task_id;
    }

    pub fn poll(self: *TaskManager) PollResult {
        var res = PollResult{};
        for (&self.entries) |*e| {
            if (!e.active or e.state != .running) continue;

            if (e.pipe_fd >= 0) {
                var read_buf: [256]u8 = undefined;
                while (true) {
                    const rc = linux.read(
                        e.pipe_fd,
                        &read_buf,
                        read_buf.len,
                    );
                    const err = linux.errno(rc);
                    if (err == .SUCCESS) {
                        if (rc == 0) {
                            e.closePipe();
                            break;
                        }
                        if (e.feedBytes(read_buf[0..rc])) {
                            res.ui_changed = true;
                        }
                    } else if (err == .AGAIN) {
                        break;
                    } else {
                        e.closePipe();
                        break;
                    }
                }
            }

            if (e.pid > 0) {
                var status: i32 = 0;
                const wrc = linux.waitpid(e.pid, &status, linux.W.NOHANG);
                if (linux.errno(wrc) == .SUCCESS and
                    wrc == @as(usize, @intCast(e.pid)))
                {
                    if (e.flushPendingLine()) res.ui_changed = true;
                    e.closePipe();
                    e.pid = -1;
                    const raw_status: u32 = @bitCast(status);
                    const exit_code = (raw_status >> 8) & 0xff;
                    const sig = raw_status & 0x7f;
                    if (sig == 0 and exit_code == 0 and !e.saw_error_line) {
                        e.state = .completed;
                        e.progress_pct = 100;
                        if (e.msg_len == 0) {
                            e.setMessage("Completed successfully.");
                        }
                    } else {
                        e.state = .failed;
                        if (!e.saw_error_line and e.msg_len == 0) {
                            e.setMessage("Error: Task failed.");
                        }
                    }
                    res.ui_changed = true;
                    if (e.refresh_guests_on_done) res.guests_changed = true;
                }
            }
        }
        return res;
    }
};

test "tasks: progress parsing, completion, failure, and dismissal" {
    std.testing.refAllDecls(@This());
    var mgr = TaskManager{};
    const id1 = mgr.startTask("Creating VM", "Starting...", 0);
    const id2 = mgr.startTask("Creating VM 2", "Starting...", 0);
    try std.testing.expectEqual(@as(usize, 2), mgr.activeCount());

    const t1 = mgr.findById(id1).?;
    try std.testing.expect(
        t1.feedBytes("[25%] Allocating child VM 'linux-1'...\n"),
    );
    try std.testing.expectEqual(@as(u8, 25), t1.progress_pct);
    try std.testing.expectEqualStrings(
        "Allocating child VM 'linux-1'...",
        t1.getMessage(),
    );

    try std.testing.expect(
        t1.feedBytes("✓ Child VM 'linux-1' started in background.\n"),
    );
    _ = mgr.completeTask(id1, null);
    try std.testing.expectEqual(TaskState.completed, t1.state);
    try std.testing.expectEqual(@as(u8, 100), t1.progress_pct);

    const t2 = mgr.findById(id2).?;
    try std.testing.expect(
        t2.feedBytes(
            "Error: Create child VM failed: vCPU quota exhausted (4/4).\n",
        ),
    );
    _ = mgr.failTask(id2, t2.getMessage());
    try std.testing.expectEqual(TaskState.failed, t2.state);

    try std.testing.expect(mgr.dismissTask(id1));
    try std.testing.expectEqual(@as(usize, 1), mgr.activeCount());
    try std.testing.expect(mgr.dismissTask(id2));
    try std.testing.expectEqual(@as(usize, 0), mgr.activeCount());
}
