// Diosix Hypervisor Manifest Parser, Validator, and Attenuation Engine
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const MAX_SERVICE_NAME_LEN: usize = 64;
pub const MAX_ALIAS_LEN: usize = 64;
pub const MAX_CHANNEL_LEN: usize = 32;
pub const MAX_MODE_LEN: usize = 16;
pub const MAX_MANIFEST_SIZE: usize = 64 * 1024; // 64 KiB

pub const ServiceOffer = struct {
    service: []const u8,
    channel: []const u8 = "ipc",
    type_name: []const u8 = "generic",
};

pub const ServiceRequirement = struct {
    service: []const u8,
    as_alias: []const u8,
    target_cid: usize = 0,
    target_domain: []const u8 = "",
    channel: []const u8 = "ipc",
    mode: []const u8 = "rw",
};

pub const DomainRoute = struct {
    require_pattern: []const u8,
    resolve_to: []const u8,
};

pub const DomainSpec = struct {
    name: []const u8,
    image: []const u8 = "",
    vcpus: usize = 1,
    ram: []const u8 = "",
    pci_devices: std.ArrayList([]const u8) = std.ArrayList([]const u8).empty,
    can_provide: std.ArrayList([]const u8) = std.ArrayList([]const u8).empty,
    can_require: std.ArrayList([]const u8) = std.ArrayList([]const u8).empty,
    provides: std.ArrayList(ServiceOffer) = std.ArrayList(ServiceOffer).empty,
    routes: std.ArrayList(DomainRoute) = std.ArrayList(DomainRoute).empty,

    pub fn init(name: []const u8) DomainSpec {
        return .{
            .name = name,
        };
    }

    pub fn deinit(self: *DomainSpec, allocator: std.mem.Allocator) void {
        self.pci_devices.deinit(allocator);
        self.can_provide.deinit(allocator);
        self.can_require.deinit(allocator);
        self.provides.deinit(allocator);
        self.routes.deinit(allocator);
    }
};

pub const SystemManifest = struct {
    version: []const u8 = "1.0",
    domain: []const u8 = "diosix.local",
    domains: std.StringHashMap(DomainSpec),
    strings: std.ArrayList([]const u8) = std.ArrayList([]const u8).empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SystemManifest {
        return .{
            .domains = std.StringHashMap(DomainSpec).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SystemManifest) void {
        var iter = self.domains.valueIterator();
        while (iter.next()) |d| {
            d.deinit(self.allocator);
        }
        self.domains.deinit();

        for (self.strings.items) |str| {
            self.allocator.free(str);
        }
        self.strings.deinit(self.allocator);
    }

    pub fn addString(self: *SystemManifest, str: []const u8) ![]const u8 {
        const duped = try self.allocator.dupe(u8, str);
        try self.strings.append(self.allocator, duped);
        return duped;
    }
};

pub const ChildManifest = struct {
    version: []const u8 = "1.0",
    name: []const u8 = "",
    cid: usize = 0,
    parent_cid: usize = 0,
    vcpus: usize = 1,
    ram: []const u8 = "",
    required: std.ArrayList(ServiceRequirement) = std.ArrayList(ServiceRequirement).empty,
    provided: std.ArrayList(ServiceOffer) = std.ArrayList(ServiceOffer).empty,
    strings: std.ArrayList([]const u8) = std.ArrayList([]const u8).empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) ChildManifest {
        return .{
            .name = name,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ChildManifest) void {
        self.required.deinit(self.allocator);
        self.provided.deinit(self.allocator);
        for (self.strings.items) |str| {
            self.allocator.free(str);
        }
        self.strings.deinit(self.allocator);
    }

    pub fn addString(self: *ChildManifest, str: []const u8) ![]const u8 {
        const duped = try self.allocator.dupe(u8, str);
        try self.strings.append(self.allocator, duped);
        return duped;
    }
};

/// Match wildcard patterns like "net.*", "gui.*", or "*"
pub fn matchPattern(pattern: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.mem.endsWith(u8, pattern, ".*")) {
        const prefix = pattern[0 .. pattern.len - 1]; // includes '.'
        return std.mem.startsWith(u8, value, prefix);
    }
    return std.mem.eql(u8, pattern, value);
}

// Simple zero-dependency TOML / Manifest Tokenizer and Parser
const TokenTag = enum {
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

const Token = struct {
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
                // skip comment until newline
                while (self.cursor < self.source.len and self.source[self.cursor] != '\n') {
                    self.cursor += 1;
                }
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

        if (c == '\n') {
            self.cursor += 1;
            return .{ .tag = .newline, .val = "\n" };
        }
        if (c == '[') {
            self.cursor += 1;
            return .{ .tag = .bracket_open, .val = "[" };
        }
        if (c == ']') {
            self.cursor += 1;
            return .{ .tag = .bracket_close, .val = "]" };
        }
        if (c == '{') {
            self.cursor += 1;
            return .{ .tag = .brace_open, .val = "{" };
        }
        if (c == '}') {
            self.cursor += 1;
            return .{ .tag = .brace_close, .val = "}" };
        }
        if (c == '=') {
            self.cursor += 1;
            return .{ .tag = .equals, .val = "=" };
        }
        if (c == ',') {
            self.cursor += 1;
            return .{ .tag = .comma, .val = "," };
        }
        if (c == '.') {
            self.cursor += 1;
            return .{ .tag = .dot, .val = "." };
        }

        // Quoted string
        if (c == '"' or c == '\'') {
            const quote = c;
            self.cursor += 1;
            const str_start = self.cursor;
            while (self.cursor < self.source.len and self.source[self.cursor] != quote) {
                if (self.source[self.cursor] == '\\' and self.cursor + 1 < self.source.len) {
                    self.cursor += 2;
                } else {
                    self.cursor += 1;
                }
            }
            const str_end = self.cursor;
            if (self.cursor < self.source.len and self.source[self.cursor] == quote) {
                self.cursor += 1;
            }
            return .{ .tag = .string, .val = self.source[str_start..str_end] };
        }

        // Identifiers or numbers or keys
        while (self.cursor < self.source.len) {
            const ch = self.source[self.cursor];
            if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.' or ch == '/' or ch == ':') {
                self.cursor += 1;
            } else {
                break;
            }
        }

        const span = self.source[start..self.cursor];
        return .{ .tag = .ident, .val = span };
    }
};

/// Parses a TOML system manifest into a structured SystemManifest
pub fn parseSystemManifest(allocator: std.mem.Allocator, toml_str: []const u8) !SystemManifest {
    var manifest = SystemManifest.init(allocator);
    errdefer manifest.deinit();

    var lexer = ManifestLexer.init(toml_str);
    var current_section: ?[]const u8 = null;
    var current_domain_name: ?[]const u8 = null;

    while (true) {
        const token = lexer.next();
        if (token.tag == .eof) break;
        if (token.tag == .newline) continue;

        if (token.tag == .bracket_open) {
            var sec_name = std.ArrayList(u8).empty;
            defer sec_name.deinit(allocator);

            while (true) {
                const sec_tok = lexer.next();
                if (sec_tok.tag == .bracket_close or sec_tok.tag == .eof) break;
                try sec_name.appendSlice(allocator, sec_tok.val);
            }

            const sec_str = try manifest.addString(sec_name.items);
            current_section = sec_str;

            if (std.mem.startsWith(u8, sec_str, "domains.") or std.mem.startsWith(u8, sec_str, "subtrees.")) {
                const dot_pos = std.mem.indexOf(u8, sec_str, ".").?;
                const dname = sec_str[dot_pos + 1 ..];
                current_domain_name = dname;
                if (!manifest.domains.contains(dname)) {
                    try manifest.domains.put(dname, DomainSpec.init(dname));
                }
            } else {
                current_domain_name = null;
            }
            continue;
        }

        // Key = Value
        if (token.tag == .ident or token.tag == .string) {
            const key = token.val;
            const eq_tok = lexer.next();
            if (eq_tok.tag != .equals) continue;

            const val_tok = lexer.next();

            if (current_domain_name) |dname| {
                if (manifest.domains.getPtr(dname)) |dom| {
                    if (std.mem.eql(u8, key, "name")) {
                        dom.name = try manifest.addString(val_tok.val);
                    } else if (std.mem.eql(u8, key, "image")) {
                        dom.image = try manifest.addString(val_tok.val);
                    } else if (std.mem.eql(u8, key, "vcpus") or std.mem.eql(u8, key, "harts")) {
                        if (val_tok.tag == .ident or val_tok.tag == .number) {
                            dom.vcpus = std.fmt.parseInt(usize, val_tok.val, 10) catch 1;
                        } else if (val_tok.tag == .bracket_open) {
                            var count: usize = 0;
                            while (true) {
                                const el = lexer.next();
                                if (el.tag == .bracket_close or el.tag == .eof) break;
                                if (el.tag != .comma and el.tag != .newline) {
                                    count += 1;
                                }
                            }
                            dom.vcpus = if (count > 0) count else 1;
                        }
                    } else if (std.mem.eql(u8, key, "ram")) {
                        dom.ram = try manifest.addString(val_tok.val);
                    } else if (std.mem.eql(u8, key, "pci_devices") or std.mem.eql(u8, key, "grant_devices")) {
                        if (val_tok.tag == .bracket_open) {
                            while (true) {
                                const el = lexer.next();
                                if (el.tag == .bracket_close or el.tag == .eof) break;
                                if (el.tag != .comma and el.tag != .newline) {
                                    const dev = try manifest.addString(el.val);
                                    try dom.pci_devices.append(allocator, dev);
                                }
                            }
                        }
                    } else if (std.mem.eql(u8, key, "can_provide")) {
                        if (val_tok.tag == .bracket_open) {
                            while (true) {
                                const el = lexer.next();
                                if (el.tag == .bracket_close or el.tag == .eof) break;
                                if (el.tag != .comma and el.tag != .newline) {
                                    const pat = try manifest.addString(el.val);
                                    try dom.can_provide.append(allocator, pat);
                                }
                            }
                        }
                    } else if (std.mem.eql(u8, key, "can_require")) {
                        if (val_tok.tag == .bracket_open) {
                            while (true) {
                                const el = lexer.next();
                                if (el.tag == .bracket_close or el.tag == .eof) break;
                                if (el.tag != .comma and el.tag != .newline) {
                                    const pat = try manifest.addString(el.val);
                                    try dom.can_require.append(allocator, pat);
                                }
                            }
                        }
                    } else if (std.mem.eql(u8, key, "provides")) {
                        if (val_tok.tag == .bracket_open) {
                            while (true) {
                                const el = lexer.next();
                                if (el.tag == .bracket_close or el.tag == .eof) break;
                                if (el.tag == .brace_open) {
                                    var offer: ServiceOffer = .{ .service = "" };
                                    while (true) {
                                        const sub_k = lexer.next();
                                        if (sub_k.tag == .brace_close or sub_k.tag == .eof) break;
                                        if (sub_k.tag == .comma or sub_k.tag == .newline) continue;
                                        const sub_eq = lexer.next();
                                        if (sub_eq.tag != .equals) continue;
                                        const sub_v = lexer.next();

                                        if (std.mem.eql(u8, sub_k.val, "service")) {
                                            offer.service = try manifest.addString(sub_v.val);
                                        } else if (std.mem.eql(u8, sub_k.val, "channel")) {
                                            offer.channel = try manifest.addString(sub_v.val);
                                        } else if (std.mem.eql(u8, sub_k.val, "type")) {
                                            offer.type_name = try manifest.addString(sub_v.val);
                                        }
                                    }
                                    if (offer.service.len > 0) {
                                        try dom.provides.append(allocator, offer);
                                    }
                                }
                            }
                        }
                    } else if (std.mem.eql(u8, key, "routes")) {
                        if (val_tok.tag == .bracket_open) {
                            while (true) {
                                const el = lexer.next();
                                if (el.tag == .bracket_close or el.tag == .eof) break;
                                if (el.tag == .brace_open) {
                                    var route: DomainRoute = .{ .require_pattern = "", .resolve_to = "" };
                                    while (true) {
                                        const sub_k = lexer.next();
                                        if (sub_k.tag == .brace_close or sub_k.tag == .eof) break;
                                        if (sub_k.tag == .comma or sub_k.tag == .newline) continue;
                                        const sub_eq = lexer.next();
                                        if (sub_eq.tag != .equals) continue;
                                        const sub_v = lexer.next();

                                        if (std.mem.eql(u8, sub_k.val, "require")) {
                                            route.require_pattern = try manifest.addString(sub_v.val);
                                        } else if (std.mem.eql(u8, sub_k.val, "resolve_to")) {
                                            route.resolve_to = try manifest.addString(sub_v.val);
                                        }
                                    }
                                    if (route.require_pattern.len > 0) {
                                        try dom.routes.append(allocator, route);
                                    }
                                }
                            }
                        }
                    }
                }
            } else if (current_section) |sec| {
                if (std.mem.eql(u8, sec, "system")) {
                    if (std.mem.eql(u8, key, "version")) {
                        manifest.version = try manifest.addString(val_tok.val);
                    } else if (std.mem.eql(u8, key, "domain")) {
                        manifest.domain = try manifest.addString(val_tok.val);
                    }
                }
            }
        }
    }

    return manifest;
}

/// Parses a TOML child / guest manifest
pub fn parseChildManifest(allocator: std.mem.Allocator, toml_str: []const u8) !ChildManifest {
    var manifest = ChildManifest.init(allocator, "guest");
    errdefer manifest.deinit();

    var lexer = ManifestLexer.init(toml_str);
    var current_section: ?[]const u8 = null;

    while (true) {
        const token = lexer.next();
        if (token.tag == .eof) break;
        if (token.tag == .newline) continue;

        if (token.tag == .bracket_open) {
            var sec_name = std.ArrayList(u8).empty;
            defer sec_name.deinit(allocator);

            while (true) {
                const sec_tok = lexer.next();
                if (sec_tok.tag == .bracket_close or sec_tok.tag == .eof) break;
                try sec_name.appendSlice(allocator, sec_tok.val);
            }

            const sec_str = try manifest.addString(sec_name.items);
            current_section = sec_str;
            continue;
        }

        if (token.tag == .ident or token.tag == .string) {
            const key = token.val;
            const eq_tok = lexer.next();
            if (eq_tok.tag != .equals) continue;

            const val_tok = lexer.next();

            if (current_section) |sec| {
                if (std.mem.eql(u8, sec, "vm")) {
                    if (std.mem.eql(u8, key, "name")) {
                        manifest.name = try manifest.addString(val_tok.val);
                    } else if (std.mem.eql(u8, key, "cid")) {
                        manifest.cid = std.fmt.parseInt(usize, val_tok.val, 10) catch 0;
                    } else if (std.mem.eql(u8, key, "parent_cid")) {
                        manifest.parent_cid = std.fmt.parseInt(usize, val_tok.val, 10) catch 0;
                    } else if (std.mem.eql(u8, key, "vcpus") or std.mem.eql(u8, key, "harts")) {
                        manifest.vcpus = std.fmt.parseInt(usize, val_tok.val, 10) catch 1;
                    } else if (std.mem.eql(u8, key, "ram")) {
                        manifest.ram = try manifest.addString(val_tok.val);
                    }
                } else if (std.mem.eql(u8, sec, "require") or std.mem.eql(u8, sec, "services.require")) {
                    if (val_tok.tag == .brace_open) {
                        const s_name = try manifest.addString(key);
                        var req: ServiceRequirement = .{
                            .service = s_name,
                            .as_alias = s_name,
                        };
                        while (true) {
                            const sub_k = lexer.next();
                            if (sub_k.tag == .brace_close or sub_k.tag == .eof) break;
                            if (sub_k.tag == .comma or sub_k.tag == .newline) continue;
                            const sub_eq = lexer.next();
                            if (sub_eq.tag != .equals) continue;
                            const sub_v = lexer.next();

                            if (std.mem.eql(u8, sub_k.val, "as")) {
                                req.as_alias = try manifest.addString(sub_v.val);
                            } else if (std.mem.eql(u8, sub_k.val, "target_cid")) {
                                req.target_cid = std.fmt.parseInt(usize, sub_v.val, 10) catch 0;
                            } else if (std.mem.eql(u8, sub_k.val, "target_domain")) {
                                req.target_domain = try manifest.addString(sub_v.val);
                            } else if (std.mem.eql(u8, sub_k.val, "channel")) {
                                req.channel = try manifest.addString(sub_v.val);
                            } else if (std.mem.eql(u8, sub_k.val, "mode")) {
                                req.mode = try manifest.addString(sub_v.val);
                            }
                        }
                        try manifest.required.append(allocator, req);
                    }
                } else if (std.mem.eql(u8, sec, "provide") or std.mem.eql(u8, sec, "services.provide")) {
                    if (val_tok.tag == .brace_open) {
                        var offer: ServiceOffer = .{ .service = try manifest.addString(key) };
                        while (true) {
                            const sub_k = lexer.next();
                            if (sub_k.tag == .brace_close or sub_k.tag == .eof) break;
                            if (sub_k.tag == .comma or sub_k.tag == .newline) continue;
                            const sub_eq = lexer.next();
                            if (sub_eq.tag != .equals) continue;
                            const sub_v = lexer.next();

                            if (std.mem.eql(u8, sub_k.val, "channel")) {
                                offer.channel = try manifest.addString(sub_v.val);
                            } else if (std.mem.eql(u8, sub_k.val, "type")) {
                                offer.type_name = try manifest.addString(sub_v.val);
                            }
                        }
                        try manifest.provided.append(allocator, offer);
                    }
                }
            }
        }
    }

    return manifest;
}

/// Prunes a system-wide manifest into an attenuated child manifest for a specific domain
pub fn pruneSystemManifest(
    allocator: std.mem.Allocator,
    sys: *const SystemManifest,
    domain_name: []const u8,
    child_cid: usize,
    parent_cid: usize,
    domain_to_cid: ?*const std.StringHashMap(usize),
) !ChildManifest {
    var child = ChildManifest.init(allocator, domain_name);
    errdefer child.deinit();

    child.cid = child_cid;
    child.parent_cid = parent_cid;

    const dom_spec = sys.domains.get(domain_name) orelse return error.DomainNotFound;

    child.name = try child.addString(dom_spec.name);
    child.vcpus = dom_spec.vcpus;
    child.ram = try child.addString(dom_spec.ram);

    // 1. Export declared provided services if permitted by can_provide
    for (dom_spec.provides.items) |prov| {
        var permitted = false;
        if (dom_spec.can_provide.items.len == 0) {
            permitted = true;
        } else {
            for (dom_spec.can_provide.items) |pat| {
                if (matchPattern(pat, prov.service)) {
                    permitted = true;
                    break;
                }
            }
        }
        if (permitted) {
            try child.provided.append(allocator, .{
                .service = try child.addString(prov.service),
                .channel = try child.addString(prov.channel),
                .type_name = try child.addString(prov.type_name),
            });
        }
    }

    // 2. Resolve required services and routes
    for (dom_spec.routes.items) |route| {
        // Check if permitted by can_require
        var permitted = false;
        if (dom_spec.can_require.items.len == 0) {
            permitted = true;
        } else {
            for (dom_spec.can_require.items) |pat| {
                if (matchPattern(pat, route.require_pattern)) {
                    permitted = true;
                    break;
                }
            }
        }
        if (!permitted) continue;

        // Resolve destination domain and service
        const dot_pos = std.mem.indexOf(u8, route.resolve_to, ".");
        var target_dom: []const u8 = "";
        var target_svc: []const u8 = route.resolve_to;
        var target_cid_val: usize = 0;

        if (dot_pos) |pos| {
            target_dom = route.resolve_to[0..pos];
            target_svc = route.resolve_to[pos + 1 ..];
            if (domain_to_cid) |map| {
                if (map.get(target_dom)) |cid| {
                    target_cid_val = cid;
                }
            }
        }

        try child.required.append(allocator, .{
            .service = try child.addString(route.require_pattern),
            .as_alias = try child.addString(target_svc),
            .target_cid = target_cid_val,
            .target_domain = try child.addString(target_dom),
            .channel = "ipc",
            .mode = "rw",
        });
    }

    return child;
}

/// Serializes a child manifest into standard TOML string
pub fn serializeChildManifest(allocator: std.mem.Allocator, child: *const ChildManifest) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var writer_buf: [256]u8 = undefined;

    try out.appendSlice(allocator, "# Diosix Attenuated Guest VM Manifest (Generated)\n[vm]\n");

    const name_line = try std.fmt.bufPrint(&writer_buf, "name = \"{s}\"\n", .{child.name});
    try out.appendSlice(allocator, name_line);

    const cid_line = try std.fmt.bufPrint(&writer_buf, "cid = {d}\n", .{child.cid});
    try out.appendSlice(allocator, cid_line);

    const parent_line = try std.fmt.bufPrint(&writer_buf, "parent_cid = {d}\n", .{child.parent_cid});
    try out.appendSlice(allocator, parent_line);

    const vcpus_line = try std.fmt.bufPrint(&writer_buf, "vcpus = {d}\n", .{child.vcpus});
    try out.appendSlice(allocator, vcpus_line);

    if (child.ram.len > 0) {
        const ram_line = try std.fmt.bufPrint(&writer_buf, "ram = \"{s}\"\n", .{child.ram});
        try out.appendSlice(allocator, ram_line);
    }
    try out.appendSlice(allocator, "\n");

    if (child.required.items.len > 0) {
        try out.appendSlice(allocator, "[services.require]\n");
        for (child.required.items) |req| {
            var line_buf = std.ArrayList(u8).empty;
            defer line_buf.deinit(allocator);

            const prefix = try std.fmt.allocPrint(allocator, "\"{s}\" = {{ as = \"{s}\"", .{ req.service, req.as_alias });
            defer allocator.free(prefix);
            try line_buf.appendSlice(allocator, prefix);

            if (req.target_cid > 0) {
                const cid_part = try std.fmt.allocPrint(allocator, ", target_cid = {d}", .{req.target_cid});
                defer allocator.free(cid_part);
                try line_buf.appendSlice(allocator, cid_part);
            }
            if (req.target_domain.len > 0) {
                const dom_part = try std.fmt.allocPrint(allocator, ", target_domain = \"{s}\"", .{req.target_domain});
                defer allocator.free(dom_part);
                try line_buf.appendSlice(allocator, dom_part);
            }
            const suffix = try std.fmt.allocPrint(allocator, ", channel = \"{s}\", mode = \"{s}\" }}\n", .{ req.channel, req.mode });
            defer allocator.free(suffix);
            try line_buf.appendSlice(allocator, suffix);

            try out.appendSlice(allocator, line_buf.items);
        }
        try out.appendSlice(allocator, "\n");
    }

    if (child.provided.items.len > 0) {
        try out.appendSlice(allocator, "[services.provide]\n");
        for (child.provided.items) |prov| {
            const prov_line = try std.fmt.allocPrint(allocator, "\"{s}\" = {{ channel = \"{s}\", type = \"{s}\" }}\n", .{ prov.service, prov.channel, prov.type_name });
            defer allocator.free(prov_line);
            try out.appendSlice(allocator, prov_line);
        }
        try out.appendSlice(allocator, "\n");
    }

    return out.toOwnedSlice(allocator);
}

/// Validates a SystemManifest ensuring all domains and routes are well-formed
pub fn validateSystemManifest(sys: *const SystemManifest) !void {
    if (sys.domains.count() == 0) {
        return error.NoDomainsDefined;
    }

    var iter = sys.domains.iterator();
    while (iter.next()) |entry| {
        const d = entry.value_ptr;
        if (d.name.len == 0) return error.MissingDomainName;

        // Check if route resolution targets exist
        for (d.routes.items) |route| {
            if (route.require_pattern.len == 0 or route.resolve_to.len == 0) {
                return error.InvalidRoute;
            }
        }
    }
}

/// Validates a ChildManifest ensuring it has a name and valid CIDs
pub fn validateChildManifest(child: *const ChildManifest) !void {
    if (child.name.len == 0) return error.MissingVmName;
    for (child.required.items) |req| {
        if (req.service.len == 0) return error.InvalidServiceRequirement;
    }
    for (child.provided.items) |prov| {
        if (prov.service.len == 0) return error.InvalidServiceOffer;
    }
}

/// Resolves a required service requirement by alias or full service name
pub fn resolveService(child: *const ChildManifest, alias_or_name: []const u8) ?ServiceRequirement {
    for (child.required.items) |req| {
        if (std.mem.eql(u8, req.as_alias, alias_or_name) or std.mem.eql(u8, req.service, alias_or_name) or matchPattern(req.service, alias_or_name)) {
            return req;
        }
    }
    return null;
}

// -----------------------------------------------------------------------------
// Unit Tests
// -----------------------------------------------------------------------------

test "manifest: TOML parsing and capability attenuation roundtrip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const sample_system_toml =
        \\# System bootstrap manifest
        \\[system]
        \\version = "1.0"
        \\domain = "diosix.local"
        \\
        \\[domains.sys]
        \\name = "sys-supervisor"
        \\image = "/boot/sys-supervisor.elf"
        \\harts = [0, 1]
        \\ram = "2GiB"
        \\grant_devices = ["0000:00:01.0", "0000:00:02.0"]
        \\can_provide = ["net.*", "gui.*", "fs.*"]
        \\provides = [
        \\  { service = "net.wan", channel = "shmem", type = "ethernet" },
        \\  { service = "gui.wayland", channel = "ipc", type = "display" }
        \\]
        \\
        \\[domains.user]
        \\name = "user-supervisor"
        \\image = "/boot/user-supervisor.elf"
        \\vcpus = 4
        \\ram = "14GiB"
        \\can_require = ["net.*", "gui.*", "fs.*"]
        \\routes = [
        \\  { require = "net.wan", resolve_to = "sys.net.wan" },
        \\  { require = "gui.display", resolve_to = "sys.gui.wayland" }
        \\]
    ;

    var sys = try parseSystemManifest(allocator, sample_system_toml);
    defer sys.deinit();

    try testing.expectEqualStrings("1.0", sys.version);
    try testing.expectEqualStrings("diosix.local", sys.domain);
    try testing.expect(sys.domains.contains("sys"));
    try testing.expect(sys.domains.contains("user"));

    const sys_dom = sys.domains.get("sys").?;
    try testing.expectEqual(@as(usize, 2), sys_dom.vcpus);
    try testing.expectEqualStrings("2GiB", sys_dom.ram);
    try testing.expectEqual(@as(usize, 2), sys_dom.provides.items.len);
    try testing.expectEqualStrings("net.wan", sys_dom.provides.items[0].service);

    const user_dom = sys.domains.get("user").?;
    try testing.expectEqual(@as(usize, 4), user_dom.vcpus);
    try testing.expectEqual(@as(usize, 2), user_dom.routes.items.len);

    // Map domain names to CIDs
    var cid_map = std.StringHashMap(usize).init(allocator);
    defer cid_map.deinit();
    try cid_map.put("sys", 2);
    try cid_map.put("user", 3);

    // Prune for user domain (CID 3)
    var child_user = try pruneSystemManifest(allocator, &sys, "user", 3, 1, &cid_map);
    defer child_user.deinit();

    try testing.expectEqualStrings("user-supervisor", child_user.name);
    try testing.expectEqual(@as(usize, 3), child_user.cid);
    try testing.expectEqual(@as(usize, 1), child_user.parent_cid);
    try testing.expectEqual(@as(usize, 2), child_user.required.items.len);

    // Verify service routing
    const gui_req = resolveService(&child_user, "gui.display").?;
    try testing.expectEqualStrings("gui.wayland", gui_req.as_alias);
    try testing.expectEqual(@as(usize, 2), gui_req.target_cid);
    try testing.expectEqualStrings("sys", gui_req.target_domain);

    // Test serialization
    const serialized = try serializeChildManifest(allocator, &child_user);
    defer allocator.free(serialized);

    try testing.expect(std.mem.indexOf(u8, serialized, "[vm]") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "name = \"user-supervisor\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "target_cid = 2") != null);

    // Parse back serialized child manifest
    var parsed_child = try parseChildManifest(allocator, serialized);
    defer parsed_child.deinit();

    try testing.expectEqualStrings("user-supervisor", parsed_child.name);
    try testing.expectEqual(@as(usize, 3), parsed_child.cid);
    try testing.expectEqual(@as(usize, 2), parsed_child.required.items.len);
}
