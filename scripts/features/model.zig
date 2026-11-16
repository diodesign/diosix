// Data model and Markdown anchor parser for the Diosix feature graph.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Layer = enum {
    m_mode,
    interface,
    s_mode_emulation,
    rootvm_kernel,
    rootvm_init,
    guest_firmware,
    u_mode_cli,
    u_mode_gui,
    build_infra,

    pub fn heading(self: Layer) []const u8 {
        return switch (self) {
            .m_mode => "Machine-mode hypervisor",
            .interface => "Shared interface and ABI",
            .s_mode_emulation => "Supervisor-mode emulation " ++
                "and virtual devices",
            .rootvm_kernel => "Root VM kernel driver",
            .rootvm_init => "Root VM init and runtime configuration",
            .guest_firmware => "Guest bootloader firmware",
            .u_mode_cli => "User-mode management CLI",
            .u_mode_gui => "User-mode desktop compositor",
            .build_infra => "Build, image, and test infrastructure",
        };
    }
};

pub const Status = enum {
    active,
    partial,
    unintegrated,

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .active => "Active",
            .partial => "Partial",
            .unintegrated => "Unintegrated",
        };
    }
};

pub const FeatureNode = struct {
    id: []const u8,
    name: []const u8,
    layer: Layer,
    status: Status,
    files: []const []const u8,
    summary: []const u8,
    activated_by: []const []const u8 = &.{},
    docs: []const []const u8 = &.{},
};

pub const FeatureManifest = struct {
    roots: []const []const u8,
    tracked_dirs: []const []const u8,
    tracked_files: []const []const u8,
    matrix_path: []const u8,
    checked_docs: []const []const u8,
    meta_doc_sections: []const []const u8 = &.{},
    markdown_dirs: []const []const u8 = &.{},
    markdown_files: []const []const u8 = &.{},
    feature_files: []const []const u8 = &.{},
    features: []const FeatureNode = &.{},
};

pub const DocHeading = struct {
    level: u8,
    slug: []const u8,
    parent_h2_slug: ?[]const u8,
};

fn stripHeadingLinks(allocator: Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, raw, i + 1, ']')) |close_br| {
                if (close_br + 1 < raw.len and raw[close_br + 1] == '(') {
                    if (std.mem.indexOfScalarPos(
                        u8,
                        raw,
                        close_br + 2,
                        ')',
                    )) |close_par| {
                        try out.appendSlice(allocator, raw[i + 1 .. close_br]);
                        i = close_par + 1;
                        continue;
                    }
                }
            }
        }
        try out.append(allocator, raw[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Converts a Markdown heading title into a GitHub-compatible anchor slug.
/// Caller owns the returned slice.
pub fn slugifyHeading(allocator: Allocator, raw: []const u8) ![]u8 {
    const unlinked = try stripHeadingLinks(allocator, raw);
    defer allocator.free(unlinked);
    const trimmed = std.mem.trim(u8, unlinked, " \t\r");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (trimmed) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try out.append(allocator, std.ascii.toLower(c));
        } else if (c == '_' or c == '-') {
            try out.append(allocator, c);
        } else if (c == ' ') {
            try out.append(allocator, '-');
        }
    }
    return out.toOwnedSlice(allocator);
}

pub const FenceState = struct {
    ch: u8 = 0,
    len: usize = 0,
};

pub fn detectFence(line: []const u8) ?FenceState {
    const trimmed_left = std.mem.trimStart(u8, line, " ");
    if (line.len - trimmed_left.len > 3) return null;
    if (trimmed_left.len < 3) return null;
    const ch = trimmed_left[0];
    if (ch != '`' and ch != '~') return null;

    var count: usize = 0;
    while (count < trimmed_left.len and trimmed_left[count] == ch) {
        count += 1;
    }
    if (count < 3) return null;
    return .{ .ch = ch, .len = count };
}

pub fn isClosingFence(line: []const u8, active: FenceState) bool {
    const cand = detectFence(line) orelse return false;
    if (cand.ch != active.ch or cand.len < active.len) return false;
    const trimmed_left = std.mem.trimStart(u8, line, " ");
    const rest = std.mem.trim(u8, trimmed_left[cand.len..], " \t\r");
    return rest.len == 0;
}

/// Parses ATX headings (`#` .. `######`) outside fenced code blocks,
/// deduplicating repeated slugs with `-1`, `-2`, and recording the enclosing
/// `##` section slug for nested subsections.
pub fn parseMarkdownHeadings(
    allocator: Allocator,
    markdown: []const u8,
) ![]DocHeading {
    var headings: std.ArrayList(DocHeading) = .empty;
    errdefer {
        for (headings.items) |h| allocator.free(h.slug);
        headings.deinit(allocator);
    }

    var seen: std.StringHashMapUnmanaged(u32) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit(allocator);
    }

    var active_fence: ?FenceState = null;
    var current_h2: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, markdown, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (active_fence) |f| {
            if (isClosingFence(line, f)) active_fence = null;
            continue;
        }
        if (detectFence(line)) |f| {
            active_fence = f;
            continue;
        }

        if (line.len == 0 or line[0] != '#') continue;
        var hashes: usize = 0;
        while (hashes < line.len and line[hashes] == '#') : (hashes += 1) {}
        if (hashes == 0 or hashes > 6) continue;
        if (hashes >= line.len or line[hashes] != ' ') continue;

        const title = std.mem.trim(u8, line[hashes + 1 ..], " \t");
        if (title.len == 0) continue;

        const base_slug = try slugifyHeading(allocator, title);
        const final_slug: []u8 = if (seen.getPtr(base_slug)) |cnt_ptr| blk: {
            const idx = cnt_ptr.*;
            cnt_ptr.* = idx + 1;
            defer allocator.free(base_slug);
            break :blk try allocator.print("{s}-{d}", .{ base_slug, idx });
        } else blk: {
            const key_copy = try allocator.dupe(u8, base_slug);
            errdefer allocator.free(key_copy);
            try seen.put(allocator, key_copy, 1);
            break :blk base_slug;
        };
        errdefer allocator.free(final_slug);

        const level: u8 = @intCast(hashes);
        if (level == 1) {
            current_h2 = null;
        } else if (level == 2) {
            current_h2 = final_slug;
        }

        try headings.append(allocator, .{
            .level = level,
            .slug = final_slug,
            .parent_h2_slug = if (level >= 2) current_h2 else null,
        });
    }

    return headings.toOwnedSlice(allocator);
}

/// Collapses newlines and consecutive whitespace into single spaces.
pub fn collapseWhitespace(allocator: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var prev_space = true;
    for (text) |c| {
        if (std.ascii.isWhitespace(c)) {
            if (!prev_space) {
                try out.append(allocator, ' ');
                prev_space = true;
            }
        } else {
            try out.append(allocator, c);
            prev_space = false;
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        _ = out.pop();
    }
    return out.toOwnedSlice(allocator);
}

test "model: slugifyHeading and parseMarkdownHeadings match GitHub rules" {
    std.testing.refAllDecls(@This());
    const gpa = std.testing.allocator;

    const s1 = try slugifyHeading(
        gpa,
        "Diosix custom SBI extension (`0x0a000005`)",
    );
    defer gpa.free(s1);
    try std.testing.expectEqualStrings(
        "diosix-custom-sbi-extension-0x0a000005",
        s1,
    );

    const sample_md =
        \\# Title
        \\## First section
        \\```bash
        \\## Ignored comment inside code block
        \\```
        \\### Child topic
        \\### Child topic
        \\## Second (`dsx` / `diosix-ctl`)
    ;
    const parsed = try parseMarkdownHeadings(gpa, sample_md);
    defer {
        for (parsed) |h| gpa.free(h.slug);
        gpa.free(parsed);
    }

    try std.testing.expectEqual(@as(usize, 5), parsed.len);
    try std.testing.expectEqualStrings("first-section", parsed[1].slug);
    try std.testing.expectEqualStrings("child-topic", parsed[2].slug);
    try std.testing.expectEqualStrings(
        "first-section",
        parsed[2].parent_h2_slug.?,
    );
    try std.testing.expectEqualStrings("child-topic-1", parsed[3].slug);
    try std.testing.expectEqualStrings(
        "second-dsx--diosix-ctl",
        parsed[4].slug,
    );
}
