// Self-contained YAML parser for Diosix hardware configurations
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const ArrayList = std.ArrayList;

pub const PortConfig = struct {
    name: []const u8,
    linker_script: []const u8,
    run_cmd: [][]const u8,
    assembly_files: [][]const u8,
    dependencies: [][]const u8,

    pub fn deinit(self: PortConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.linker_script);
        for (self.run_cmd) |arg| allocator.free(arg);
        allocator.free(self.run_cmd);
        for (self.assembly_files) |file| allocator.free(file);
        allocator.free(self.assembly_files);
        for (self.dependencies) |dep| allocator.free(dep);
        allocator.free(self.dependencies);
    }
};

fn stripQuotes(value: []const u8) []const u8 {
    var val = std.mem.trim(u8, value, " \t\r\n");
    if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
        val = val[1 .. val.len - 1];
    } else if (val.len >= 2 and val[0] == '\'' and val[val.len - 1] == '\'') {
        val = val[1 .. val.len - 1];
    }
    return val;
}

pub fn parse(allocator: std.mem.Allocator, content: []const u8) !PortConfig {
    var name: ?[]const u8 = null;
    var linker_script: ?[]const u8 = null;
    var run_cmd = ArrayList([]const u8).empty;
    var assembly_files = ArrayList([]const u8).empty;
    var dependencies = ArrayList([]const u8).empty;

    errdefer {
        if (name) |n| allocator.free(n);
        if (linker_script) |l| allocator.free(l);
        for (run_cmd.items) |item| allocator.free(item);
        run_cmd.deinit(allocator);
        for (assembly_files.items) |item| allocator.free(item);
        assembly_files.deinit(allocator);
        for (dependencies.items) |item| allocator.free(item);
        dependencies.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    var current_list: enum { none, run_cmd, assembly_files, dependencies } = .none;

    while (lines.next()) |raw_line| {
        // Find comment starting position
        var comment_idx: ?usize = null;
        for (raw_line, 0..) |char, idx| {
            if (char == '#') {
                comment_idx = idx;
                break;
            }
        }

        // Remove comments
        const line_no_comment = if (comment_idx) |idx| raw_line[0..idx] else raw_line;
        const trimmed = std.mem.trim(u8, line_no_comment, " \t\r\n");
        if (trimmed.len == 0) continue;

        // Check if list item
        if (std.mem.startsWith(u8, trimmed, "-")) {
            const val_raw = std.mem.trim(u8, trimmed[1..], " \t");
            const val = try allocator.dupe(u8, stripQuotes(val_raw));
            switch (current_list) {
                .run_cmd => try run_cmd.append(allocator, val),
                .assembly_files => try assembly_files.append(allocator, val),
                .dependencies => try dependencies.append(allocator, val),
                .none => return error.InvalidYamlListItemOutsideList,
            }
            continue;
        }

        // Parse key-value or key-list start
        if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_idx| {
            const key = std.mem.trim(u8, trimmed[0..colon_idx], " \t");
            const value_raw = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " \t");

            if (std.mem.eql(u8, key, "name")) {
                current_list = .none;
                name = try allocator.dupe(u8, stripQuotes(value_raw));
            } else if (std.mem.eql(u8, key, "linker_script")) {
                current_list = .none;
                linker_script = try allocator.dupe(u8, stripQuotes(value_raw));
            } else if (std.mem.eql(u8, key, "run_cmd")) {
                current_list = .run_cmd;
            } else if (std.mem.eql(u8, key, "assembly_files")) {
                current_list = .assembly_files;
            } else if (std.mem.eql(u8, key, "dependencies")) {
                current_list = .dependencies;
            } else {
                current_list = .none;
            }
        }
    }

    return PortConfig{
        .name = name orelse return error.MissingNameField,
        .linker_script = linker_script orelse return error.MissingLinkerScriptField,
        .run_cmd = try run_cmd.toOwnedSlice(allocator),
        .assembly_files = try assembly_files.toOwnedSlice(allocator),
        .dependencies = try dependencies.toOwnedSlice(allocator),
    };
}

pub fn parseDefault(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        var comment_idx: ?usize = null;
        for (raw_line, 0..) |char, idx| {
            if (char == '#') {
                comment_idx = idx;
                break;
            }
        }
        const line_no_comment = if (comment_idx) |idx| raw_line[0..idx] else raw_line;
        const trimmed = std.mem.trim(u8, line_no_comment, " \t\r\n");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_idx| {
            const key = std.mem.trim(u8, trimmed[0..colon_idx], " \t");
            const value_raw = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " \t");
            if (std.mem.eql(u8, key, "default_system")) {
                return try allocator.dupe(u8, stripQuotes(value_raw));
            }
        }
    }
    return error.MissingDefaultSystemField;
}

pub fn selfCheck() !void {
    var buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    // Test 1: Standard YAML parsing with comments, quotes, and spacing
    const content =
        \\# Test configuration
        \\name: "test-system" # comment here
        \\linker_script: 'path/to/linker.ld'
        \\
        \\run_cmd:
        \\  - "cmd1"
        \\  - 'cmd2'
        \\  - cmd3
        \\
        \\assembly_files:
        \\  - file1.s
        \\  - file2.s
        \\
        \\dependencies:
        \\  - dep1.s
    ;
    var config = try parse(allocator, content);
    defer config.deinit(allocator);

    if (!std.mem.eql(u8, config.name, "test-system")) return error.SelfCheckFailedName;
    if (!std.mem.eql(u8, config.linker_script, "path/to/linker.ld")) return error.SelfCheckFailedLinkerScript;
    if (config.run_cmd.len != 3) return error.SelfCheckFailedRunCmdLen;
    if (!std.mem.eql(u8, config.run_cmd[0], "cmd1")) return error.SelfCheckFailedRunCmd0;
    if (!std.mem.eql(u8, config.run_cmd[1], "cmd2")) return error.SelfCheckFailedRunCmd1;
    if (!std.mem.eql(u8, config.run_cmd[2], "cmd3")) return error.SelfCheckFailedRunCmd2;
    if (config.assembly_files.len != 2) return error.SelfCheckFailedAssemblyFilesLen;
    if (!std.mem.eql(u8, config.assembly_files[0], "file1.s")) return error.SelfCheckFailedAssemblyFiles0;
    if (!std.mem.eql(u8, config.assembly_files[1], "file2.s")) return error.SelfCheckFailedAssemblyFiles1;
    if (config.dependencies.len != 1) return error.SelfCheckFailedDependenciesLen;
    if (!std.mem.eql(u8, config.dependencies[0], "dep1.s")) return error.SelfCheckFailedDependencies0;

    // Reset allocator for next test
    fba.reset();

    // Test 2: Default YAML parsing
    const default_content =
        \\# Default target configuration
        \\default_system: "test-system"
    ;
    const default_sys = try parseDefault(allocator, default_content);
    if (!std.mem.eql(u8, default_sys, "test-system")) return error.SelfCheckFailedDefaultSystem;

    // Reset allocator for next test
    fba.reset();

    // Test 3: Missing name field error
    const invalid_content =
        \\linker_script: path/to/linker.ld
    ;
    if (parse(allocator, invalid_content)) |_| {
        return error.SelfCheckFailedMissingNameNotCaught;
    } else |err| {
        if (err != error.MissingNameField) return err;
    }
}

test "yaml parser - comprehensive test suite" {
    const testing = std.testing;

    // Test standard config parsing
    const standard_yaml =
        \\# A comment line
        \\name: "qemu-virt"
        \\linker_script: 'hypervisor/hw/qemu/linker.ld'
        \\
        \\run_cmd:
        \\  - qemu-system-riscv64
        \\  - -nographic
        \\
        \\assembly_files:
        \\  - hypervisor/hw/qemu/entry.s
        \\  - hypervisor/hw/qemu/xint.s
        \\
        \\dependencies:
        \\  - hypervisor/hw/qemu/consts.s
    ;
    var config = try parse(testing.allocator, standard_yaml);
    defer config.deinit(testing.allocator);

    try testing.expectEqualStrings("qemu-virt", config.name);
    try testing.expectEqualStrings("hypervisor/hw/qemu/linker.ld", config.linker_script);
    try testing.expectEqual(2, config.run_cmd.len);
    try testing.expectEqualStrings("qemu-system-riscv64", config.run_cmd[0]);
    try testing.expectEqualStrings("-nographic", config.run_cmd[1]);
    try testing.expectEqual(2, config.assembly_files.len);
    try testing.expectEqualStrings("hypervisor/hw/qemu/entry.s", config.assembly_files[0]);
    try testing.expectEqualStrings("hypervisor/hw/qemu/xint.s", config.assembly_files[1]);
    try testing.expectEqual(1, config.dependencies.len);
    try testing.expectEqualStrings("hypervisor/hw/qemu/consts.s", config.dependencies[0]);

    // Test default parser
    const default_yaml =
        \\# comment
        \\default_system: qemu-virt
    ;
    const default_sys = try parseDefault(testing.allocator, default_yaml);
    defer testing.allocator.free(default_sys);
    try testing.expectEqualStrings("qemu-virt", default_sys);

    // Test error handling: missing name
    const missing_name_yaml =
        \\linker_script: hypervisor/hw/qemu/linker.ld
    ;
    try testing.expectError(error.MissingNameField, parse(testing.allocator, missing_name_yaml));

    // Test error handling: missing linker script
    const missing_linker_yaml =
        \\name: qemu-virt
    ;
    try testing.expectError(error.MissingLinkerScriptField, parse(testing.allocator, missing_linker_yaml));

    // Test error handling: missing default system
    const missing_default_yaml =
        \\name: qemu-virt
    ;
    try testing.expectError(error.MissingDefaultSystemField, parseDefault(testing.allocator, missing_default_yaml));
}
