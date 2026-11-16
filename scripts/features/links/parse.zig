// Low-level Markdown link, reference, and relative-path parsing helpers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("../model.zig");

pub const Scheme = enum {
    https,
    http,
    mailto,
    disallowed,
    relative,
};

pub fn classifyScheme(target: []const u8) Scheme {
    if (std.mem.startsWith(u8, target, "https://")) return .https;
    if (std.mem.startsWith(u8, target, "http://")) return .http;
    if (std.mem.startsWith(u8, target, "mailto:")) return .mailto;

    const colon_idx = std.mem.indexOfScalar(u8, target, ':') orelse
        return .relative;
    if (colon_idx == 0) return .disallowed;
    for (target[0..colon_idx], 0..) |c, i| {
        if (i == 0 and !std.ascii.isAlphabetic(c)) return .relative;
        if (!std.ascii.isAlphanumeric(c) and
            c != '+' and c != '-' and c != '.')
        {
            return .relative;
        }
    }
    return .disallowed;
}

pub fn hasWhitespaceOrAngle(s: []const u8) bool {
    for (s) |c| {
        if (std.ascii.isWhitespace(c) or c == '<' or c == '>') return true;
    }
    return false;
}

pub fn normalizeRefLabel(allocator: Allocator, raw: []const u8) ![]u8 {
    const collapsed = try model.collapseWhitespace(allocator, raw);
    defer allocator.free(collapsed);
    const out = try allocator.alloc(u8, collapsed.len);
    for (collapsed, 0..) |c, i| {
        out[i] = std.ascii.toLower(c);
    }
    return out;
}

/// Resolves `rel_target` against `from_doc`'s parent directory within the
/// repository root. Returns `null` if `..` escapes above the repository root.
pub fn resolveRelativePath(
    allocator: Allocator,
    from_doc: []const u8,
    rel_target: []const u8,
) !?[]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    if (rel_target.len == 0 or rel_target[0] != '/') {
        if (std.fs.path.dirname(from_doc)) |dir_part| {
            var base_it = std.mem.tokenizeScalar(u8, dir_part, '/');
            while (base_it.next()) |seg| {
                if (std.mem.eql(u8, seg, ".")) continue;
                try parts.append(allocator, seg);
            }
        }
    }

    var rel_it = std.mem.tokenizeScalar(u8, rel_target, '/');
    while (rel_it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len == 0) return null;
            _ = parts.pop();
            continue;
        }
        try parts.append(allocator, seg);
    }

    if (parts.items.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (parts.items, 0..) |seg, i| {
        if (i > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, seg);
    }
    return try out.toOwnedSlice(allocator);
}

pub fn stripDestinationTitle(raw_dest: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_dest, " \t\r");
    if (trimmed.len >= 2 and trimmed[0] == '<') {
        if (std.mem.indexOfScalarPos(u8, trimmed, 1, '>')) |end_ang| {
            return trimmed[1..end_ang];
        }
    }
    for (trimmed, 0..) |c, i| {
        if (std.ascii.isWhitespace(c)) {
            const rest = std.mem.trimStart(u8, trimmed[i..], " \t");
            if (rest.len > 0 and
                (rest[0] == '"' or rest[0] == '\'' or rest[0] == '('))
            {
                return trimmed[0..i];
            }
            break;
        }
    }
    return trimmed;
}

pub const RefDef = struct {
    label: []const u8,
    target: []const u8,
};

pub fn parseRefDefinitionLine(line: []const u8) ?RefDef {
    const trimmed_left = std.mem.trimStart(u8, line, " ");
    if (line.len - trimmed_left.len > 3) return null;
    if (trimmed_left.len < 4 or trimmed_left[0] != '[') return null;
    if (trimmed_left[1] == '^') return null;

    var i: usize = 1;
    while (i < trimmed_left.len) : (i += 1) {
        if (trimmed_left[i] == '\\' and i + 1 < trimmed_left.len) {
            i += 1;
            continue;
        }
        if (trimmed_left[i] == '[') return null;
        if (trimmed_left[i] == ']') break;
    }
    if (i >= trimmed_left.len or i == 1) return null;
    if (i + 1 >= trimmed_left.len or trimmed_left[i + 1] != ':') return null;

    const label = std.mem.trim(u8, trimmed_left[1..i], " \t");
    if (label.len == 0) return null;

    const rest = std.mem.trim(u8, trimmed_left[i + 2 ..], " \t\r");
    if (rest.len == 0) return null;

    return .{
        .label = label,
        .target = stripDestinationTitle(rest),
    };
}

pub fn skipBacktickSpan(s: []const u8, start: usize) usize {
    var ticks: usize = 0;
    while (start + ticks < s.len and s[start + ticks] == '`') : (ticks += 1) {}
    var j = start + ticks;
    while (j < s.len) {
        if (s[j] == '`') {
            var close_ticks: usize = 0;
            while (j + close_ticks < s.len and s[j + close_ticks] == '`') {
                close_ticks += 1;
            }
            if (close_ticks == ticks) return j + close_ticks;
            j += close_ticks;
            continue;
        }
        j += 1;
    }
    return start + ticks;
}

pub fn findMatchingBracket(s: []const u8, open_idx: usize) ?usize {
    var depth: usize = 1;
    var i = open_idx + 1;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 2;
            continue;
        }
        if (s[i] == '`') {
            i = skipBacktickSpan(s, i);
            continue;
        }
        if (s[i] == '[') {
            depth += 1;
        } else if (s[i] == ']') {
            depth -= 1;
            if (depth == 0) return i;
        }
        i += 1;
    }
    return null;
}

pub fn findMatchingParen(s: []const u8, open_idx: usize) ?usize {
    if (open_idx + 1 < s.len and s[open_idx + 1] == '<') {
        if (std.mem.indexOfScalarPos(u8, s, open_idx + 2, '>')) |ang_end| {
            if (std.mem.indexOfScalarPos(u8, s, ang_end + 1, ')')) |par_end| {
                return par_end;
            }
        }
    }
    var depth: usize = 1;
    var i = open_idx + 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            continue;
        }
        if (s[i] == '(') {
            depth += 1;
        } else if (s[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

pub const NonFencedLine = struct {
    line_no: usize,
    text: []const u8,
};

pub const NonFencedLineIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    fence: ?model.FenceState = null,
    line_no: usize = 0,

    pub fn init(markdown: []const u8) NonFencedLineIterator {
        return .{ .lines = std.mem.splitScalar(u8, markdown, '\n') };
    }

    pub fn next(self: *NonFencedLineIterator) ?NonFencedLine {
        while (self.lines.next()) |raw_line| {
            self.line_no += 1;
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (self.fence) |f| {
                if (model.isClosingFence(line, f)) self.fence = null;
                continue;
            }
            if (model.detectFence(line)) |f| {
                self.fence = f;
                continue;
            }
            return .{ .line_no = self.line_no, .text = line };
        }
        return null;
    }
};

test "parse: resolves relative paths and rejects root escapes" {
    std.testing.refAllDecls(@This());
    const gpa = std.testing.allocator;

    const p1 = (try resolveRelativePath(gpa, "docs/run.md", "../build.zig")).?;
    defer gpa.free(p1);
    try std.testing.expectEqualStrings("build.zig", p1);

    const p2 = (try resolveRelativePath(gpa, "docs/run.md", "cli.md")).?;
    defer gpa.free(p2);
    try std.testing.expectEqualStrings("docs/cli.md", p2);

    const escaped = try resolveRelativePath(
        gpa,
        "docs/run.md",
        "../../etc/passwd",
    );
    try std.testing.expect(escaped == null);

    try std.testing.expectEqual(.https, classifyScheme("https://diosix.org"));
    try std.testing.expectEqual(.mailto, classifyScheme("mailto:a@b.org"));
    try std.testing.expectEqual(.disallowed, classifyScheme("file:///tmp/x"));
    try std.testing.expectEqual(.relative, classifyScheme("docs/cli.md#dsx"));
}
