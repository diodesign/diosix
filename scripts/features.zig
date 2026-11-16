// Diosix feature-graph verifier and support-matrix generator.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
pub const model = @import("features/model.zig");
pub const verify = @import("features/verify.zig");
pub const matrix = @import("features/matrix.zig");
pub const links = @import("features/links.zig");

const Mode = enum { check, write };

fn loadManifest(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    cwd: std.Io.Dir,
    io: std.Io,
    zon_path: []const u8,
) !model.FeatureManifest {
    const zon_src = try verify.readTextFileAllocSentinel(
        cwd,
        io,
        arena,
        zon_path,
    );

    var diagnostics: std.zon.parse.Diagnostics = undefined;
    var manifest = std.zon.parse.fromSlice(model.FeatureManifest, .{
        .gpa = gpa,
        .arena = arena,
        .source = zon_src,
        .diagnostics = &diagnostics,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => diagnostics.fatal(zon_path),
    };

    if (manifest.feature_files.len == 0) return manifest;

    var combined: std.ArrayList(model.FeatureNode) = .empty;
    try combined.appendSlice(arena, manifest.features);

    for (manifest.feature_files) |sub_path| {
        const sub_src = try verify.readTextFileAllocSentinel(
            cwd,
            io,
            arena,
            sub_path,
        );
        var sub_diag: std.zon.parse.Diagnostics = undefined;
        const nodes = std.zon.parse.fromSlice([]const model.FeatureNode, .{
            .gpa = gpa,
            .arena = arena,
            .source = sub_src,
            .diagnostics = &sub_diag,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseZon => sub_diag.fatal(sub_path),
        };
        try combined.appendSlice(arena, nodes);
    }

    manifest.features = combined.items;
    return manifest;
}

const CliOption = enum {
    @"--check",
    @"--write",
    @"--zon",
    @"--tool",
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    var arg_it = try std.process.Args.Iterator.initAllocator(
        init.minimal.args,
        gpa,
    );
    defer arg_it.deinit();
    _ = arg_it.skip();

    var mode: Mode = .check;
    var zon_opt: ?[]const u8 = null;
    var tool_opt: ?[]const u8 = null;

    while (arg_it.next()) |arg| {
        const opt = std.meta.stringToEnum(CliOption, arg) orelse {
            std.debug.print("features: unknown option '{s}'\n", .{arg});
            return error.InvalidArguments;
        };
        switch (opt) {
            .@"--check" => mode = .check,
            .@"--write" => mode = .write,
            .@"--zon" => {
                const next = arg_it.next() orelse return error.MissingZonPath;
                zon_opt = try arena.dupe(u8, next);
            },
            .@"--tool" => {
                const next = arg_it.next() orelse return error.MissingToolPath;
                tool_opt = try arena.dupe(u8, next);
            },
        }
    }

    const zon_path = zon_opt orelse return error.MissingZonPath;
    const tool_path = tool_opt orelse return error.MissingToolPath;

    const cwd = std.Io.Dir.cwd();
    const manifest = try loadManifest(gpa, arena, cwd, io, zon_path);

    try verify.verifyWorkspace(gpa, arena, cwd, io, manifest);

    const rendered = try matrix.renderSupportMatrix(
        arena,
        manifest,
        zon_path,
        tool_path,
    );

    try links.verifyWorkspaceLinks(
        gpa,
        arena,
        cwd,
        io,
        manifest,
        if (mode == .write) rendered else null,
    );

    switch (mode) {
        .write => {
            try cwd.writeFile(io, .{
                .sub_path = manifest.matrix_path,
                .data = rendered,
            });
        },
        .check => {
            const existing = verify.readTextFileAllocSentinel(
                cwd,
                io,
                arena,
                manifest.matrix_path,
            ) catch {
                std.debug.print(
                    "error: missing '{s}'; run './scripts/build.sh features'\n",
                    .{manifest.matrix_path},
                );
                return error.SupportMatrixMissing;
            };
            if (!std.mem.eql(u8, existing, rendered)) {
                std.debug.print(
                    "error: '{s}' is out of sync with '{s}'; " ++
                        "run './scripts/build.sh features'\n",
                    .{ manifest.matrix_path, zon_path },
                );
                return error.SupportMatrixStale;
            }
        },
    }
}

test {
    std.testing.refAllDecls(@This());
    _ = model;
    _ = verify;
    _ = matrix;
    _ = links;
}
