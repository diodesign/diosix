// Build steps for verifying features.zon and generating support-matrix.md.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const layout = @import("../../build/layout.zon");

pub fn registerFeatureSteps(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
) void {
    const exe = b.addExecutable(.{
        .name = layout.features.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(layout.features.tool_root),
            .optimize = optimize,
            .target = b.graph.host,
        }),
    });

    const write_cmd = b.addRunArtifact(exe);
    write_cmd.setCwd(b.path("."));
    write_cmd.addArgs(&.{
        "--write",
        "--zon",
        layout.features.zon_path,
        "--tool",
        layout.features.tool_root,
    });
    write_cmd.has_side_effects = true;
    b.step(
        "features",
        "Verify features.zon and regenerate docs/support-matrix.md",
    ).dependOn(&write_cmd.step);

    const check_cmd = b.addRunArtifact(exe);
    check_cmd.setCwd(b.path("."));
    check_cmd.addArgs(&.{
        "--check",
        "--zon",
        layout.features.zon_path,
        "--tool",
        layout.features.tool_root,
    });
    check_cmd.has_side_effects = true;
    test_step.dependOn(&check_cmd.step);
}

test {
    std.testing.refAllDecls(@This());
}
