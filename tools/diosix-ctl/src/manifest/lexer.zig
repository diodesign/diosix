// Diosix Hypervisor Manifest TOML Tokenizer.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const TokenTag = enum {
    string,
    ident,
    number,
    bracket_open,
    bracket_close,
    brace_open,
    brace_close,
    equals,
    comma,
    dot,
    newline,
    eof,
};

pub const Token = struct {
    tag: TokenTag,
    val: []const u8,
};

pub const ManifestLexer = struct {
    source: []const u8,
    cursor: usize = 0,

    pub fn init(source: []const u8) ManifestLexer {
        return .{ .source = source };
    }

    fn skipWhitespace(self: *ManifestLexer) void {
        while (self.cursor < self.source.len) {
            const c = self.source[self.cursor];
            if (c == ' ' or c == '\t' or c == '\r') {
                self.cursor += 1;
            } else if (c == '#') {
                while (self.cursor < self.source.len and
                    self.source[self.cursor] != '\n') : (self.cursor += 1)
                {}
            } else {
                break;
            }
        }
    }

    pub fn next(self: *ManifestLexer) Token {
        self.skipWhitespace();
        if (self.cursor >= self.source.len) {
            return .{ .tag = .eof, .val = "" };
        }

        const start = self.cursor;
        const c = self.source[self.cursor];

        switch (c) {
            '\n' => {
                self.cursor += 1;
                return .{ .tag = .newline, .val = "\n" };
            },
            '[' => {
                self.cursor += 1;
                return .{ .tag = .bracket_open, .val = "[" };
            },
            ']' => {
                self.cursor += 1;
                return .{ .tag = .bracket_close, .val = "]" };
            },
            '{' => {
                self.cursor += 1;
                return .{ .tag = .brace_open, .val = "{" };
            },
            '}' => {
                self.cursor += 1;
                return .{ .tag = .brace_close, .val = "}" };
            },
            '=' => {
                self.cursor += 1;
                return .{ .tag = .equals, .val = "=" };
            },
            ',' => {
                self.cursor += 1;
                return .{ .tag = .comma, .val = "," };
            },
            '.' => {
                self.cursor += 1;
                return .{ .tag = .dot, .val = "." };
            },
            '"', '\'' => {
                const quote = c;
                self.cursor += 1;
                const str_start = self.cursor;
                while (self.cursor < self.source.len and
                    self.source[self.cursor] != quote)
                {
                    if (self.source[self.cursor] == '\\' and
                        self.cursor + 1 < self.source.len)
                    {
                        self.cursor += 2;
                    } else {
                        self.cursor += 1;
                    }
                }
                const str_end = self.cursor;
                if (self.cursor < self.source.len and
                    self.source[self.cursor] == quote)
                {
                    self.cursor += 1;
                }
                return .{
                    .tag = .string,
                    .val = self.source[str_start..str_end],
                };
            },
            else => {},
        }

        while (self.cursor < self.source.len) {
            const ch = self.source[self.cursor];
            if (std.ascii.isAlphanumeric(ch) or
                ch == '_' or ch == '-' or ch == '.' or
                ch == '/' or ch == ':')
            {
                self.cursor += 1;
            } else {
                break;
            }
        }
        // Guarantee monotonic cursor progress on unexpected characters.
        if (self.cursor == start) self.cursor += 1;

        return .{ .tag = .ident, .val = self.source[start..self.cursor] };
    }
};

test "manifest/lexer: tokenizes sections, strings, and comments" {
    std.testing.refAllDecls(@This());
    var lex = ManifestLexer.init("# comment\n[system]\ndomain = \"diosix\"\n");
    try std.testing.expectEqual(TokenTag.newline, lex.next().tag);
    try std.testing.expectEqual(TokenTag.bracket_open, lex.next().tag);
    const sec = lex.next();
    try std.testing.expectEqual(TokenTag.ident, sec.tag);
    try std.testing.expectEqualStrings("system", sec.val);
    try std.testing.expectEqual(TokenTag.bracket_close, lex.next().tag);
    try std.testing.expectEqual(TokenTag.newline, lex.next().tag);
    try std.testing.expectEqualStrings("domain", lex.next().val);
    try std.testing.expectEqual(TokenTag.equals, lex.next().tag);
    const val = lex.next();
    try std.testing.expectEqual(TokenTag.string, val.tag);
    try std.testing.expectEqualStrings("diosix", val.val);
}
