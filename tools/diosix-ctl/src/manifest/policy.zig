// Diosix Manifest Attenuation, Serialization, Validation, and Routing Policy.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const manifest_mod = @import("../manifest.zig");

const ServiceOffer = manifest_mod.ServiceOffer;
const ServiceRequirement = manifest_mod.ServiceRequirement;
const SystemManifest = manifest_mod.SystemManifest;
const ChildManifest = manifest_mod.ChildManifest;
const ManifestLexer = manifest_mod.ManifestLexer;
const Token = manifest_mod.Token;

/// Match wildcard patterns like "net.*", "gui.*", or "*".
pub fn matchPattern(pattern: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.mem.endsWith(u8, pattern, ".*")) {
        const prefix = pattern[0 .. pattern.len - 1]; // Includes '.'.
        return std.mem.startsWith(u8, value, prefix);
    }
    return std.mem.eql(u8, pattern, value);
}

fn parseChildReqTable(
    allocator: std.mem.Allocator,
    lexer: *ManifestLexer,
    manifest: *ChildManifest,
    key: []const u8,
) !void {
    const ReqKey = enum { as, target_cid, target_domain, channel, mode };
    const s_name = try manifest.addString(key);
    var req: ServiceRequirement = .{ .service = s_name, .as_alias = s_name };
    while (true) {
        const sub_k = lexer.next();
        if (sub_k.tag == .brace_close or sub_k.tag == .eof) break;
        if (sub_k.tag == .comma or sub_k.tag == .newline) continue;
        if (lexer.next().tag != .equals) continue;
        const sub_v = lexer.next();
        if (std.meta.stringToEnum(ReqKey, sub_k.val)) |rk| switch (rk) {
            .as => req.as_alias = try manifest.addString(sub_v.val),
            .target_cid => {
                req.target_cid = std.fmt.parseInt(usize, sub_v.val, 10) catch 0;
            },
            .target_domain => {
                req.target_domain = try manifest.addString(sub_v.val);
            },
            .channel => req.channel = try manifest.addString(sub_v.val),
            .mode => req.mode = try manifest.addString(sub_v.val),
        };
    }
    try manifest.required.append(allocator, req);
}

fn parseChildProvideTable(
    allocator: std.mem.Allocator,
    lexer: *ManifestLexer,
    manifest: *ChildManifest,
    key: []const u8,
) !void {
    const ProvKey = enum { channel, type };
    var offer: ServiceOffer = .{ .service = try manifest.addString(key) };
    while (true) {
        const sub_k = lexer.next();
        if (sub_k.tag == .brace_close or sub_k.tag == .eof) break;
        if (sub_k.tag == .comma or sub_k.tag == .newline) continue;
        if (lexer.next().tag != .equals) continue;
        const sub_v = lexer.next();
        if (std.meta.stringToEnum(ProvKey, sub_k.val)) |pk| switch (pk) {
            .channel => offer.channel = try manifest.addString(sub_v.val),
            .type => offer.type_name = try manifest.addString(sub_v.val),
        };
    }
    try manifest.provided.append(allocator, offer);
}

/// Parses a TOML child / guest manifest.
pub fn parseChildManifest(
    allocator: std.mem.Allocator,
    toml_str: []const u8,
) !ChildManifest {
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

            current_section = try manifest.addString(sec_name.items);
            continue;
        }

        if (token.tag == .ident or token.tag == .string) {
            const key = token.val;
            if (lexer.next().tag != .equals) continue;
            const val_tok = lexer.next();
            const sec = current_section orelse continue;

            const ChildSection = enum {
                vm,
                require,
                @"services.require",
                provide,
                @"services.provide",
            };
            const csec = std.meta.stringToEnum(ChildSection, sec) orelse
                continue;
            switch (csec) {
                .vm => {
                    const VmKey = enum {
                        name,
                        cid,
                        parent_cid,
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
                    };
                    if (std.meta.stringToEnum(VmKey, key)) |vk| switch (vk) {
                        .name => {
                            manifest.name = try manifest.addString(val_tok.val);
                        },
                        .cid => {
                            manifest.cid = std.fmt.parseInt(
                                usize,
                                val_tok.val,
                                10,
                            ) catch 0;
                        },
                        .parent_cid => {
                            manifest.parent_cid = std.fmt.parseInt(
                                usize,
                                val_tok.val,
                                10,
                            ) catch 0;
                        },
                        .vcpus, .harts => {
                            manifest.vcpus = std.fmt.parseInt(
                                usize,
                                val_tok.val,
                                10,
                            ) catch 1;
                        },
                        .ram => {
                            manifest.ram = try manifest.addString(val_tok.val);
                        },
                        .disk => {
                            manifest.disk = try manifest.addString(val_tok.val);
                        },
                        .storage_size, .storage, .disk_size => {
                            manifest.storage_size =
                                try manifest.addString(val_tok.val);
                        },
                        .cdrom, .iso, .media => {
                            manifest.cdrom =
                                try manifest.addString(val_tok.val);
                        },
                        .ip, .address => {
                            manifest.ip = try manifest.addString(val_tok.val);
                        },
                    };
                },
                .require, .@"services.require" => {
                    if (val_tok.tag == .brace_open) {
                        try parseChildReqTable(
                            allocator,
                            &lexer,
                            &manifest,
                            key,
                        );
                    }
                },
                .provide, .@"services.provide" => {
                    if (val_tok.tag == .brace_open) {
                        try parseChildProvideTable(
                            allocator,
                            &lexer,
                            &manifest,
                            key,
                        );
                    }
                },
            }
        }
    }

    return manifest;
}

/// Prunes a system-wide manifest into an attenuated child manifest for a
/// specific domain.
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

    const dom_spec = sys.domains.get(domain_name) orelse
        return error.DomainNotFound;

    child.name = try child.addString(dom_spec.name);
    child.vcpus = dom_spec.vcpus;
    child.ram = try child.addString(dom_spec.ram);
    if (dom_spec.disk.len > 0) child.disk = try child.addString(dom_spec.disk);
    if (dom_spec.storage_size.len > 0) {
        child.storage_size = try child.addString(dom_spec.storage_size);
    }
    if (dom_spec.cdrom.len > 0) {
        child.cdrom = try child.addString(dom_spec.cdrom);
    }
    if (dom_spec.ip.len > 0) child.ip = try child.addString(dom_spec.ip);

    for (dom_spec.provides.items) |prov| {
        var permitted = dom_spec.can_provide.items.len == 0;
        for (dom_spec.can_provide.items) |pat| {
            if (matchPattern(pat, prov.service)) {
                permitted = true;
                break;
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

    for (dom_spec.routes.items) |route| {
        var permitted = dom_spec.can_require.items.len == 0;
        for (dom_spec.can_require.items) |pat| {
            if (matchPattern(pat, route.require_pattern)) {
                permitted = true;
                break;
            }
        }
        if (!permitted) continue;

        const dot_pos = std.mem.indexOf(u8, route.resolve_to, ".");
        var target_dom: []const u8 = "";
        var target_svc: []const u8 = route.resolve_to;
        var target_cid_val: usize = 0;

        if (dot_pos) |pos| {
            target_dom = route.resolve_to[0..pos];
            target_svc = route.resolve_to[pos + 1 ..];
            if (domain_to_cid) |map| {
                if (map.get(target_dom)) |cid| target_cid_val = cid;
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

fn appendOptField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    key: []const u8,
    val: []const u8,
) !void {
    if (val.len == 0) return;
    const line = try allocator.print("{s} = \"{s}\"\n", .{ key, val });
    defer allocator.free(line);
    try out.appendSlice(allocator, line);
}

pub const serializeCapabilitiesToml = serializeChildManifest;

/// Serializes a child manifest into a standard TOML string.
pub fn serializeChildManifest(
    allocator: std.mem.Allocator,
    child: *const ChildManifest,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    const header = try allocator.print(
        "# Diosix attenuated guest VM manifest (generated)\n[vm]\n" ++
            "name = \"{s}\"\ncid = {d}\nparent_cid = {d}\nvcpus = {d}\n",
        .{ child.name, child.cid, child.parent_cid, child.vcpus },
    );
    defer allocator.free(header);
    try out.appendSlice(allocator, header);

    try appendOptField(allocator, &out, "ram", child.ram);
    try appendOptField(allocator, &out, "disk", child.disk);
    try appendOptField(allocator, &out, "storage_size", child.storage_size);
    try appendOptField(allocator, &out, "cdrom", child.cdrom);
    try appendOptField(allocator, &out, "ip", child.ip);
    try out.appendSlice(allocator, "\n");

    if (child.required.items.len > 0) {
        try out.appendSlice(allocator, "[services.require]\n");
        for (child.required.items) |req| {
            var line_buf = std.ArrayList(u8).empty;
            defer line_buf.deinit(allocator);

            const prefix = try allocator.print(
                "\"{s}\" = {{ as = \"{s}\"",
                .{ req.service, req.as_alias },
            );
            defer allocator.free(prefix);
            try line_buf.appendSlice(allocator, prefix);

            if (req.target_cid > 0) {
                const cid_part = try allocator.print(
                    ", target_cid = {d}",
                    .{req.target_cid},
                );
                defer allocator.free(cid_part);
                try line_buf.appendSlice(allocator, cid_part);
            }
            if (req.target_domain.len > 0) {
                const dom_part = try allocator.print(
                    ", target_domain = \"{s}\"",
                    .{req.target_domain},
                );
                defer allocator.free(dom_part);
                try line_buf.appendSlice(allocator, dom_part);
            }
            const suffix = try allocator.print(
                ", channel = \"{s}\", mode = \"{s}\" }}\n",
                .{ req.channel, req.mode },
            );
            defer allocator.free(suffix);
            try line_buf.appendSlice(allocator, suffix);

            try out.appendSlice(allocator, line_buf.items);
        }
        try out.appendSlice(allocator, "\n");
    }

    if (child.provided.items.len > 0) {
        try out.appendSlice(allocator, "[services.provide]\n");
        for (child.provided.items) |prov| {
            const prov_line = try allocator.print(
                "\"{s}\" = {{ channel = \"{s}\", type = \"{s}\" }}\n",
                .{ prov.service, prov.channel, prov.type_name },
            );
            defer allocator.free(prov_line);
            try out.appendSlice(allocator, prov_line);
        }
        try out.appendSlice(allocator, "\n");
    }

    return out.toOwnedSlice(allocator);
}

/// Validates a SystemManifest ensuring all domains and routes are well-formed.
pub fn validateSystemManifest(sys: *const SystemManifest) !void {
    if (sys.domains.count() == 0) return error.NoDomainsDefined;

    var iter = sys.domains.iterator();
    while (iter.next()) |entry| {
        const d = entry.value_ptr;
        if (d.name.len == 0) return error.MissingDomainName;

        for (d.routes.items) |route| {
            if (route.require_pattern.len == 0 or route.resolve_to.len == 0) {
                return error.InvalidRoute;
            }
        }
    }
}

/// Validates a ChildManifest ensuring it has a name and valid service specs.
pub fn validateChildManifest(child: *const ChildManifest) !void {
    if (child.name.len == 0) return error.MissingVmName;
    for (child.required.items) |req| {
        if (req.service.len == 0) return error.InvalidServiceRequirement;
    }
    for (child.provided.items) |prov| {
        if (prov.service.len == 0) return error.InvalidServiceOffer;
    }
}

/// Resolves a required service requirement by alias or full service name.
pub fn resolveService(
    child: *const ChildManifest,
    alias_or_name: []const u8,
) ?ServiceRequirement {
    for (child.required.items) |req| {
        if (std.mem.eql(u8, req.as_alias, alias_or_name) or
            std.mem.eql(u8, req.service, alias_or_name) or
            matchPattern(req.service, alias_or_name))
        {
            return req;
        }
    }
    return null;
}

test "manifest/policy: matchPattern and child manifest roundtrip" {
    std.testing.refAllDecls(@This());
    try std.testing.expect(matchPattern("*", "anything"));
    try std.testing.expect(matchPattern("net.*", "net.http"));
    try std.testing.expect(!matchPattern("net.*", "gui.wayland"));
}
