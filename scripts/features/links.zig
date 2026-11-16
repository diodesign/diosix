// Offline Markdown link and section-anchor verifier for Diosix documentation.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const verify = @import("verify.zig");
pub const parse = @import("links/parse.zig");

const DocHeading = model.DocHeading;
const FeatureManifest = model.FeatureManifest;

pub const MarkdownDoc = struct {
    path: []const u8,
    content: []const u8,
};

pub const WorkspaceProbe = struct {
    dir: std.Io.Dir,
    io: std.Io,
};

const ValidatorCtx = struct {
    arena: Allocator,
    doc_path: []const u8,
    existing_paths: *std.StringHashMapUnmanaged(void),
    doc_headings: *std.StringHashMapUnmanaged([]const DocHeading),
    workspace: ?WorkspaceProbe,
    ref_defs: *const std.StringHashMapUnmanaged([]const u8),
    errors: *std.ArrayList([]const u8),

    fn addErr(
        self: *ValidatorCtx,
        line_no: usize,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const detail = try self.arena.print(fmt, args);
        try self.errors.append(
            self.arena,
            try self.arena.print(
                "{s}:{d}: {s}",
                .{ self.doc_path, line_no, detail },
            ),
        );
    }

    fn pathExists(self: *ValidatorCtx, resolved: []const u8) !bool {
        if (self.existing_paths.contains(resolved)) return true;
        const ws = self.workspace orelse return false;

        const found = if (ws.dir.statFile(ws.io, resolved, .{})) |_|
            true
        else |_| blk: {
            var sub = ws.dir.openDir(ws.io, resolved, .{}) catch
                break :blk false;
            sub.close(ws.io);
            break :blk true;
        };

        if (found) {
            try self.existing_paths.put(
                self.arena,
                try self.arena.dupe(u8, resolved),
                {},
            );
        }
        return found;
    }

    fn getHeadings(
        self: *ValidatorCtx,
        resolved: []const u8,
    ) !?[]const DocHeading {
        if (self.doc_headings.get(resolved)) |h| return h;
        if (!std.mem.endsWith(u8, resolved, ".md")) return null;
        const ws = self.workspace orelse return null;

        const raw = verify.readTextFileAllocSentinel(
            ws.dir,
            ws.io,
            self.arena,
            resolved,
        ) catch return null;
        const parsed = try model.parseMarkdownHeadings(self.arena, raw);
        const key = try self.arena.dupe(u8, resolved);
        try self.doc_headings.put(self.arena, key, parsed);
        return parsed;
    }

    fn validateTarget(
        self: *ValidatorCtx,
        line_no: usize,
        raw_target: []const u8,
    ) !void {
        const target = parse.stripDestinationTitle(raw_target);
        if (target.len == 0) {
            try self.addErr(line_no, "empty link target", .{});
            return;
        }

        switch (parse.classifyScheme(target)) {
            .https, .http => {
                const sep = std.mem.indexOf(u8, target, "://").? + 3;
                if (sep >= target.len or
                    parse.hasWhitespaceOrAngle(target[sep..]))
                {
                    try self.addErr(line_no, "malformed URL '{s}'", .{target});
                }
                return;
            },
            .mailto => {
                const addr = target["mailto:".len..];
                const at_idx = std.mem.indexOfScalar(u8, addr, '@') orelse {
                    try self.addErr(
                        line_no,
                        "malformed mailto link '{s}'",
                        .{target},
                    );
                    return;
                };
                if (at_idx == 0 or
                    at_idx + 1 >= addr.len or
                    parse.hasWhitespaceOrAngle(addr))
                {
                    try self.addErr(
                        line_no,
                        "malformed mailto link '{s}'",
                        .{target},
                    );
                }
                return;
            },
            .disallowed => {
                try self.addErr(
                    line_no,
                    "disallowed link scheme in '{s}'",
                    .{target},
                );
                return;
            },
            .relative => {},
        }

        if (parse.hasWhitespaceOrAngle(target)) {
            try self.addErr(
                line_no,
                "invalid whitespace in link target '{s}'",
                .{target},
            );
            return;
        }

        const hash_idx = std.mem.indexOfScalar(u8, target, '#');
        const path_part = if (hash_idx) |h| target[0..h] else target;
        const anchor_opt = if (hash_idx) |h| target[h + 1 ..] else null;

        const resolved = if (path_part.len == 0)
            self.doc_path
        else
            (try parse.resolveRelativePath(
                self.arena,
                self.doc_path,
                path_part,
            )) orelse {
                try self.addErr(
                    line_no,
                    "link target '{s}' escapes repository root",
                    .{target},
                );
                return;
            };

        if (!(try self.pathExists(resolved))) {
            try self.addErr(
                line_no,
                "broken link target '{s}' (missing '{s}')",
                .{ target, resolved },
            );
            return;
        }

        if (anchor_opt) |anchor| {
            if (anchor.len == 0) {
                try self.addErr(
                    line_no,
                    "empty '#anchor' fragment in '{s}'",
                    .{target},
                );
                return;
            }
            const headings = (try self.getHeadings(resolved)) orelse {
                try self.addErr(
                    line_no,
                    "anchor '#{s}' targets non-Markdown file '{s}'",
                    .{ anchor, resolved },
                );
                return;
            };
            for (headings) |h| {
                if (std.mem.eql(u8, h.slug, anchor)) return;
            }
            try self.addErr(
                line_no,
                "broken anchor '#{s}' in '{s}'",
                .{ anchor, resolved },
            );
        }
    }

    fn scanSegment(
        self: *ValidatorCtx,
        line_no: usize,
        seg: []const u8,
    ) !void {
        var i: usize = 0;
        while (i < seg.len) {
            if (seg[i] == '\\' and i + 1 < seg.len) {
                i += 2;
                continue;
            }
            if (seg[i] == '`') {
                i = parse.skipBacktickSpan(seg, i);
                continue;
            }
            if (seg[i] == '[') {
                const close_br = parse.findMatchingBracket(seg, i) orelse {
                    i += 1;
                    continue;
                };
                const inner = seg[i + 1 .. close_br];
                try self.scanSegment(line_no, inner);

                if (close_br + 1 < seg.len and seg[close_br + 1] == '(') {
                    const close_par = parse.findMatchingParen(
                        seg,
                        close_br + 1,
                    ) orelse {
                        try self.addErr(
                            line_no,
                            "unclosed '(' in Markdown link",
                            .{},
                        );
                        return;
                    };
                    try self.validateTarget(
                        line_no,
                        seg[close_br + 2 .. close_par],
                    );
                    i = close_par + 1;
                    continue;
                }

                if (close_br + 1 < seg.len and seg[close_br + 1] == '[') {
                    const ref_end_opt =
                        parse.findMatchingBracket(seg, close_br + 1);
                    if (ref_end_opt) |ref_end| {
                        const raw_ref = seg[close_br + 2 .. ref_end];
                        const chosen =
                            if (raw_ref.len == 0) inner else raw_ref;
                        const norm =
                            try parse.normalizeRefLabel(self.arena, chosen);
                        if (!self.ref_defs.contains(norm)) {
                            try self.addErr(
                                line_no,
                                "undefined link reference '[{s}]'",
                                .{chosen},
                            );
                        }
                        i = ref_end + 1;
                        continue;
                    }
                }

                i = close_br + 1;
                continue;
            }
            i += 1;
        }
    }
};

/// Validates inline links, reference links, relative paths, and `#anchor`
/// fragments across all provided Markdown documents.
pub fn verifyMarkdownLinks(
    arena: Allocator,
    docs: []const MarkdownDoc,
    existing_paths: *std.StringHashMapUnmanaged(void),
    doc_headings: *std.StringHashMapUnmanaged([]const DocHeading),
    workspace: ?WorkspaceProbe,
) ![][]const u8 {
    var errors: std.ArrayList([]const u8) = .empty;

    for (docs) |doc| {
        var ref_defs: std.StringHashMapUnmanaged([]const u8) = .empty;
        var ctx: ValidatorCtx = .{
            .arena = arena,
            .doc_path = doc.path,
            .existing_paths = existing_paths,
            .doc_headings = doc_headings,
            .workspace = workspace,
            .ref_defs = &ref_defs,
            .errors = &errors,
        };

        var p1 = parse.NonFencedLineIterator.init(doc.content);
        while (p1.next()) |item| {
            if (parse.parseRefDefinitionLine(item.text)) |def| {
                const norm = try parse.normalizeRefLabel(arena, def.label);
                if (ref_defs.contains(norm)) {
                    try ctx.addErr(
                        item.line_no,
                        "duplicate link reference definition '[{s}]'",
                        .{def.label},
                    );
                } else {
                    try ref_defs.put(arena, norm, def.target);
                }
                try ctx.validateTarget(item.line_no, def.target);
            }
        }

        var p2 = parse.NonFencedLineIterator.init(doc.content);
        while (p2.next()) |item| {
            if (parse.parseRefDefinitionLine(item.text) != null) continue;
            try ctx.scanSegment(item.line_no, item.text);
        }
    }

    return errors.toOwnedSlice(arena);
}

fn lessThanPaths(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

/// Discovers Markdown files configured in `manifest` and validates every link
/// and section anchor against the repository workspace.
pub fn verifyWorkspaceLinks(
    gpa: Allocator,
    arena: Allocator,
    dir: std.Io.Dir,
    io: std.Io,
    manifest: FeatureManifest,
    matrix_override: ?[]const u8,
) !void {
    var existing_paths: std.StringHashMapUnmanaged(void) = .empty;
    var md_set: std.StringHashMapUnmanaged(void) = .empty;
    var md_paths: std.ArrayList([]const u8) = .empty;

    for (manifest.markdown_files) |mf| {
        if (!md_set.contains(mf)) {
            const copy = try arena.dupe(u8, mf);
            try md_set.put(arena, copy, {});
            try md_paths.append(arena, copy);
        }
    }
    for (manifest.markdown_dirs) |md_dir| {
        try existing_paths.put(arena, try arena.dupe(u8, md_dir), {});
        var sub_dir = try dir.openDir(io, md_dir, .{ .iterate = true });
        defer sub_dir.close(io);
        var walker = try sub_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            const rel = try arena.print("{s}/{s}", .{ md_dir, entry.path });
            try existing_paths.put(arena, rel, {});
            const is_md_file = entry.kind == .file and
                std.mem.endsWith(u8, entry.path, ".md");
            if (is_md_file and !md_set.contains(rel)) {
                try md_set.put(arena, rel, {});
                try md_paths.append(arena, rel);
            }
        }
    }

    std.mem.sort([]const u8, md_paths.items, {}, lessThanPaths);

    var docs: std.ArrayList(MarkdownDoc) = .empty;
    var doc_headings: std.StringHashMapUnmanaged([]const DocHeading) = .empty;

    for (md_paths.items) |doc_path| {
        const content: []const u8 = if (matrix_override != null and
            std.mem.eql(u8, doc_path, manifest.matrix_path))
            matrix_override.?
        else
            verify.readTextFileAllocSentinel(dir, io, arena, doc_path) catch {
                std.debug.print(
                    "markdown link error: missing configured doc '{s}'\n",
                    .{doc_path},
                );
                return error.InvalidMarkdownLinks;
            };

        try existing_paths.put(arena, doc_path, {});
        try docs.append(arena, .{ .path = doc_path, .content = content });
        const parsed = try model.parseMarkdownHeadings(arena, content);
        try doc_headings.put(arena, doc_path, parsed);
    }

    const errs = try verifyMarkdownLinks(
        arena,
        docs.items,
        &existing_paths,
        &doc_headings,
        .{ .dir = dir, .io = io },
    );
    if (errs.len > 0) {
        for (errs) |msg| {
            std.debug.print("markdown link error: {s}\n", .{msg});
        }
        return error.InvalidMarkdownLinks;
    }
}

test "links: validates badges, anchors, code fences, and broken targets" {
    std.testing.refAllDecls(@This());
    _ = parse;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const readme =
        \\[![CI][ci-badge]][ci-url]
        \\[ci-badge]: https://example.org/badge.svg
        \\[ci-url]: https://example.org/ci
        \\# Diosix
        \\See [Getting started](docs/run.md#booting) and `#ignored` or
        \\`[code](missing.md)`.
        \\```markdown
        \\[fenced](also-missing.md)
        \\```
        \\> [!NOTE]
        \\> Email [security](mailto:security@diosix.org).
    ;
    const run_md =
        \\# Run
        \\## Booting
        \\Back to [README](../README.md#diosix).
    ;

    var existing: std.StringHashMapUnmanaged(void) = .empty;
    try existing.put(arena, "README.md", {});
    try existing.put(arena, "docs/run.md", {});

    var headings: std.StringHashMapUnmanaged([]const DocHeading) = .empty;
    try headings.put(
        arena,
        "README.md",
        try model.parseMarkdownHeadings(arena, readme),
    );
    try headings.put(
        arena,
        "docs/run.md",
        try model.parseMarkdownHeadings(arena, run_md),
    );

    const ok_docs: []const MarkdownDoc = &.{
        .{ .path = "README.md", .content = readme },
        .{ .path = "docs/run.md", .content = run_md },
    };
    const ok_errs =
        try verifyMarkdownLinks(arena, ok_docs, &existing, &headings, null);
    try std.testing.expectEqual(@as(usize, 0), ok_errs.len);

    const bad_md =
        \\# Broken
        \\* [Typo](LICENSE,md)
        \\* [Bad anchor](docs/run.md#nope)
        \\* [Missing ref][ghost]
        \\* [Local scheme](file:///etc/hosts)
    ;
    try existing.put(arena, "BAD.md", {});
    try headings.put(
        arena,
        "BAD.md",
        try model.parseMarkdownHeadings(arena, bad_md),
    );
    const bad_errs = try verifyMarkdownLinks(
        arena,
        &.{.{ .path = "BAD.md", .content = bad_md }},
        &existing,
        &headings,
        null,
    );
    try std.testing.expectEqual(@as(usize, 4), bad_errs.len);
}
