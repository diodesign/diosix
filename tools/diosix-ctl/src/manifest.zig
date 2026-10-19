// Diosix Hypervisor Manifest Types, Tokenizer, and System Manifest Parser.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const lexer_mod = @import("manifest/lexer.zig");
const policy = @import("manifest/policy.zig");

pub const TokenTag = lexer_mod.TokenTag;
pub const Token = lexer_mod.Token;
pub const ManifestLexer = lexer_mod.ManifestLexer;
pub const matchPattern = policy.matchPattern;
pub const parseChildManifest = policy.parseChildManifest;
pub const pruneSystemManifest = policy.pruneSystemManifest;
pub const serializeChildManifest = policy.serializeChildManifest;
pub const serializeCapabilitiesToml = policy.serializeCapabilitiesToml;
pub const validateSystemManifest = policy.validateSystemManifest;
pub const validateChildManifest = policy.validateChildManifest;
pub const resolveService = policy.resolveService;

pub const MAX_SERVICE_NAME_LEN: usize = 64;
pub const MAX_ALIAS_LEN: usize = 64;
pub const MAX_CHANNEL_LEN: usize = 32;
pub const MAX_MODE_LEN: usize = 16;
pub const MAX_MANIFEST_SIZE: usize = 1024 * 1024; // 1 MiB.

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
    disk: []const u8 = "",
    storage_size: []const u8 = "",
    cdrom: []const u8 = "",
    ip: []const u8 = "",
    pci_devices: std.ArrayList([]const u8) = .empty,
    can_provide: std.ArrayList([]const u8) = .empty,
    can_require: std.ArrayList([]const u8) = .empty,
    provides: std.ArrayList(ServiceOffer) = .empty,
    routes: std.ArrayList(DomainRoute) = .empty,

    pub fn init(name: []const u8) DomainSpec {
        return .{ .name = name };
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
    strings: std.ArrayList([]const u8) = .empty,
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
        errdefer self.allocator.free(duped);
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
    disk: []const u8 = "",
    storage_size: []const u8 = "",
    cdrom: []const u8 = "",
    ip: []const u8 = "",
    required: std.ArrayList(ServiceRequirement) = .empty,
    provided: std.ArrayList(ServiceOffer) = .empty,
    strings: std.ArrayList([]const u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
    ) ChildManifest {
        return .{ .name = name, .allocator = allocator };
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
        errdefer self.allocator.free(duped);
        try self.strings.append(self.allocator, duped);
        return duped;
    }
};

fn parseStringList(
    allocator: std.mem.Allocator,
    lexer: *ManifestLexer,
    manifest: *SystemManifest,
    list: *std.ArrayList([]const u8),
) !void {
    while (true) {
        const el = lexer.next();
        if (el.tag == .bracket_close or el.tag == .eof) break;
        if (el.tag != .comma and el.tag != .newline) {
            const item = try manifest.addString(el.val);
            try list.append(allocator, item);
        }
    }
}

fn parseDomainProvides(
    allocator: std.mem.Allocator,
    lexer: *ManifestLexer,
    manifest: *SystemManifest,
    dom: *DomainSpec,
) !void {
    const OfferKey = enum { service, channel, type };
    while (true) {
        const el = lexer.next();
        if (el.tag == .bracket_close or el.tag == .eof) break;
        if (el.tag != .brace_open) continue;
        var offer: ServiceOffer = .{ .service = "" };
        while (true) {
            const sub_k = lexer.next();
            if (sub_k.tag == .brace_close or sub_k.tag == .eof) break;
            if (sub_k.tag == .comma or sub_k.tag == .newline) continue;
            if (lexer.next().tag != .equals) continue;
            const sub_v = lexer.next();
            if (std.meta.stringToEnum(OfferKey, sub_k.val)) |ok| switch (ok) {
                .service => offer.service = try manifest.addString(sub_v.val),
                .channel => offer.channel = try manifest.addString(sub_v.val),
                .type => offer.type_name = try manifest.addString(sub_v.val),
            };
        }
        if (offer.service.len > 0) try dom.provides.append(allocator, offer);
    }
}

fn parseDomainRoutes(
    allocator: std.mem.Allocator,
    lexer: *ManifestLexer,
    manifest: *SystemManifest,
    dom: *DomainSpec,
) !void {
    const RouteKey = enum { require, resolve_to };
    while (true) {
        const el = lexer.next();
        if (el.tag == .bracket_close or el.tag == .eof) break;
        if (el.tag != .brace_open) continue;
        var route: DomainRoute = .{ .require_pattern = "", .resolve_to = "" };
        while (true) {
            const sub_k = lexer.next();
            if (sub_k.tag == .brace_close or sub_k.tag == .eof) break;
            if (sub_k.tag == .comma or sub_k.tag == .newline) continue;
            if (lexer.next().tag != .equals) continue;
            const sub_v = lexer.next();
            if (std.meta.stringToEnum(RouteKey, sub_k.val)) |rk| switch (rk) {
                .require => {
                    route.require_pattern = try manifest.addString(sub_v.val);
                },
                .resolve_to => {
                    route.resolve_to = try manifest.addString(sub_v.val);
                },
            };
        }
        if (route.require_pattern.len > 0) {
            try dom.routes.append(allocator, route);
        }
    }
}

fn applyDomainKey(
    allocator: std.mem.Allocator,
    lexer: *ManifestLexer,
    manifest: *SystemManifest,
    dom: *DomainSpec,
    key: []const u8,
    val_tok: Token,
) !void {
    const DomainKey = enum {
        name,
        image,
        vcpus,
        harts,
        ram,
        disk,
        storage_size,
        storage,
        disk_size,
        cdrom,
        iso,
        media,
        ip,
        address,
        pci_devices,
        grant_devices,
        can_provide,
        can_require,
        provides,
        routes,
    };
    const dk = std.meta.stringToEnum(DomainKey, key) orelse return;
    switch (dk) {
        .name => dom.name = try manifest.addString(val_tok.val),
        .image => dom.image = try manifest.addString(val_tok.val),
        .vcpus, .harts => {
            if (val_tok.tag == .ident or val_tok.tag == .number) {
                dom.vcpus = std.fmt.parseInt(usize, val_tok.val, 10) catch 1;
            } else if (val_tok.tag == .bracket_open) {
                var count: usize = 0;
                while (true) {
                    const el = lexer.next();
                    if (el.tag == .bracket_close or el.tag == .eof) break;
                    if (el.tag != .comma and el.tag != .newline) count += 1;
                }
                dom.vcpus = if (count > 0) count else 1;
            }
        },
        .ram => dom.ram = try manifest.addString(val_tok.val),
        .disk => dom.disk = try manifest.addString(val_tok.val),
        .storage_size, .storage, .disk_size => {
            dom.storage_size = try manifest.addString(val_tok.val);
        },
        .cdrom, .iso, .media => {
            dom.cdrom = try manifest.addString(val_tok.val);
        },
        .ip, .address => dom.ip = try manifest.addString(val_tok.val),
        .pci_devices, .grant_devices => if (val_tok.tag == .bracket_open) {
            try parseStringList(allocator, lexer, manifest, &dom.pci_devices);
        },
        .can_provide => if (val_tok.tag == .bracket_open) {
            try parseStringList(allocator, lexer, manifest, &dom.can_provide);
        },
        .can_require => if (val_tok.tag == .bracket_open) {
            try parseStringList(allocator, lexer, manifest, &dom.can_require);
        },
        .provides => if (val_tok.tag == .bracket_open) {
            try parseDomainProvides(allocator, lexer, manifest, dom);
        },
        .routes => if (val_tok.tag == .bracket_open) {
            try parseDomainRoutes(allocator, lexer, manifest, dom);
        },
    }
}

/// Parses a TOML system manifest into a structured SystemManifest.
pub fn parseSystemManifest(
    allocator: std.mem.Allocator,
    toml_str: []const u8,
) !SystemManifest {
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
            if (std.mem.startsWith(u8, sec_str, "domains.") or
                std.mem.startsWith(u8, sec_str, "subtrees."))
            {
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
        if (token.tag == .ident or token.tag == .string) {
            const key = token.val;
            if (lexer.next().tag != .equals) continue;
            const val_tok = lexer.next();

            if (current_domain_name) |dname| {
                if (manifest.domains.getPtr(dname)) |dom| {
                    const l = &lexer;
                    const m = &manifest;
                    try applyDomainKey(allocator, l, m, dom, key, val_tok);
                }
            } else if (current_section) |sec| {
                if (std.mem.eql(u8, sec, "system")) {
                    const SystemKey = enum { version, domain };
                    if (std.meta.stringToEnum(SystemKey, key)) |sk| {
                        const v_str = try manifest.addString(val_tok.val);
                        switch (sk) {
                            .version => manifest.version = v_str,
                            .domain => manifest.domain = v_str,
                        }
                    }
                }
            }
        }
    }

    return manifest;
}

test "manifest: parses system manifest and manages string pool" {
    std.testing.refAllDecls(@This());
    _ = lexer_mod;
    _ = policy;
    _ = @import("tests/manifest.zig");

    var sys = try parseSystemManifest(
        std.testing.allocator,
        "[system]\nversion = \"1.0\"\ndomain = \"test.local\"\n" ++
            "[domains.web]\nram = \"256M\"\nvcpus = 2\n",
    );
    defer sys.deinit();
    try std.testing.expectEqualStrings("test.local", sys.domain);
    const web = sys.domains.get("web").?;
    try std.testing.expectEqual(@as(usize, 2), web.vcpus);
    try std.testing.expectEqualStrings("256M", web.ram);
}
