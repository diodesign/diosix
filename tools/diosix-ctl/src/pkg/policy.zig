// Diosix Hierarchical APK Package Policy and Monotonic Ceiling Enforcement.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
const common = @import("../common.zig");

pub const PKG_ALLOW_PREFIX = "# diosix-pkg-allow:";
pub const PKG_DENY_PREFIX = "# diosix-pkg-deny:";
pub const LEAF_POLICY_PREFIX = "# diosix-leaf:";
const MAX_PKG_NAME_LEN: usize = 128;

/// Reports whether the manifest marks the child VM as a child-free leaf.
pub fn isLeafManifest(raw: []const u8) bool {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |raw_line| {
        const line = common.trimWhitespace(raw_line);
        if (std.mem.startsWith(u8, line, LEAF_POLICY_PREFIX)) {
            const val = common.trimWhitespace(line[LEAF_POLICY_PREFIX.len..]);
            if (std.mem.eql(u8, val, "true")) return true;
        }
    }
    return false;
}

pub const PkgPolicy = struct {
    allow_all: bool = true,
    allow: std.ArrayList([]const u8) = .empty,
    deny: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *PkgPolicy, allocator: std.mem.Allocator) void {
        freeOwnedList(&self.allow, allocator);
        freeOwnedList(&self.deny, allocator);
    }
};

fn freeOwnedList(
    list: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
    list.* = .empty;
}

pub fn containsPkg(list: []const []const u8, name: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

pub fn isValidPkgName(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_PKG_NAME_LEN) return false;
    if (name[0] == '-' or name[0] == '.') return false;
    if (std.mem.eql(u8, name, "*") or std.mem.eql(u8, name, "none")) {
        return false;
    }
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or
            c == '.' or c == '_' or c == '+' or c == '-';
        if (!ok) return false;
    }
    return true;
}

pub fn isValidPkgListCsv(csv: []const u8, allow_wildcard: bool) bool {
    const trimmed = common.trimWhitespace(csv);
    if (trimmed.len == 0) return false;
    if (std.mem.eql(u8, trimmed, "*")) return allow_wildcard;
    if (std.mem.eql(u8, trimmed, "none")) return true;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |raw_tok| {
        const tok = common.trimWhitespace(raw_tok);
        if (!isValidPkgName(tok)) return false;
        count += 1;
    }
    return count > 0;
}

fn appendUniquePkg(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    name: []const u8,
) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    const owned = try allocator.dupe(u8, name);
    errdefer allocator.free(owned);
    try list.append(allocator, owned);
}

pub fn parseCsvIntoList(
    allocator: std.mem.Allocator,
    csv: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    freeOwnedList(out, allocator);
    const trimmed = common.trimWhitespace(csv);
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "none")) return;
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |raw_tok| {
        const tok = common.trimWhitespace(raw_tok);
        if (tok.len == 0 or !isValidPkgName(tok)) continue;
        try appendUniquePkg(allocator, out, tok);
    }
}

pub fn parsePolicy(
    allocator: std.mem.Allocator,
    manifest_bytes: []const u8,
) !PkgPolicy {
    var pol = PkgPolicy{};
    errdefer pol.deinit(allocator);

    var lines = std.mem.splitScalar(u8, manifest_bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = common.trimWhitespace(raw_line);
        if (std.mem.startsWith(u8, line, PKG_ALLOW_PREFIX)) {
            const val = common.trimWhitespace(line[PKG_ALLOW_PREFIX.len..]);
            if (std.mem.eql(u8, val, "*")) {
                pol.allow_all = true;
                freeOwnedList(&pol.allow, allocator);
            } else {
                pol.allow_all = false;
                try parseCsvIntoList(allocator, val, &pol.allow);
            }
        } else if (std.mem.startsWith(u8, line, PKG_DENY_PREFIX)) {
            const val = common.trimWhitespace(line[PKG_DENY_PREFIX.len..]);
            try parseCsvIntoList(allocator, val, &pol.deny);
        }
    }
    return pol;
}

pub fn formatCsv(
    allocator: std.mem.Allocator,
    items: []const []const u8,
    empty_word: []const u8,
) ![]u8 {
    if (items.len == 0) return allocator.dupe(u8, empty_word);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (items, 0..) |item, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, item);
    }
    return out.toOwnedSlice(allocator);
}

pub fn formatPolicyAllowValue(
    allocator: std.mem.Allocator,
    pol: *const PkgPolicy,
) ![]u8 {
    if (pol.allow_all) return allocator.dupe(u8, "*");
    return formatCsv(allocator, pol.allow.items, "none");
}

pub fn formatManifestWithPkgHeaders(
    allocator: std.mem.Allocator,
    existing: []const u8,
    allow_csv: ?[]const u8,
    deny_csv: ?[]const u8,
) ![]u8 {
    var cur_allow: ?[]const u8 = null;
    var cur_deny: ?[]const u8 = null;
    var scan = std.mem.splitScalar(u8, existing, '\n');
    while (scan.next()) |raw_line| {
        const t = common.trimWhitespace(raw_line);
        if (std.mem.startsWith(u8, t, PKG_ALLOW_PREFIX)) {
            cur_allow = common.trimWhitespace(t[PKG_ALLOW_PREFIX.len..]);
        } else if (std.mem.startsWith(u8, t, PKG_DENY_PREFIX)) {
            cur_deny = common.trimWhitespace(t[PKG_DENY_PREFIX.len..]);
        }
    }
    const eff_allow = allow_csv orelse cur_allow;
    const eff_deny = deny_csv orelse cur_deny;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (eff_allow) |a| {
        const hdr = try allocator.print("{s} {s}\n", .{ PKG_ALLOW_PREFIX, a });
        defer allocator.free(hdr);
        try out.appendSlice(allocator, hdr);
    }
    if (eff_deny) |d| {
        const hdr = try allocator.print("{s} {s}\n", .{ PKG_DENY_PREFIX, d });
        defer allocator.free(hdr);
        try out.appendSlice(allocator, hdr);
    }
    const hdr_len = out.items.len;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        const trimmed = common.trimWhitespace(line);
        if (std.mem.startsWith(u8, trimmed, PKG_ALLOW_PREFIX) or
            std.mem.startsWith(u8, trimmed, PKG_DENY_PREFIX))
        {
            continue;
        }
        if (line.len == 0 and out.items.len == hdr_len) continue;
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

pub fn loadGuestManifestPolicy(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    cid: usize,
) !PkgPolicy {
    const raw_buf = try allocator.alloc(u8, common.MAX_MANIFEST_SIZE);
    defer allocator.free(raw_buf);
    const len = client.getManifest(cid, raw_buf) catch 0;
    return parsePolicy(allocator, raw_buf[0..len]);
}

pub fn updateChildPkgHeaders(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    cid: usize,
    allow_csv: ?[]const u8,
    deny_csv: ?[]const u8,
) !void {
    const raw_buf = try allocator.alloc(u8, common.MAX_MANIFEST_SIZE);
    defer allocator.free(raw_buf);
    const len = client.getManifest(cid, raw_buf) catch 0;
    const updated = try formatManifestWithPkgHeaders(
        allocator,
        raw_buf[0..len],
        allow_csv,
        deny_csv,
    );
    defer allocator.free(updated);
    try client.setManifest(cid, updated);
}

pub fn isWithinParentCeiling(
    self_pol: *const PkgPolicy,
    req_allow_all: bool,
    req_allow: []const []const u8,
    req_deny: []const []const u8,
) bool {
    for (self_pol.deny.items) |d| {
        const re_denied = containsPkg(req_deny, d);
        const blocked_by_list = !req_allow_all and !containsPkg(req_allow, d);
        if (!re_denied and !blocked_by_list) return false;
    }
    if (!self_pol.allow_all) {
        if (req_allow_all) return false;
        for (req_allow) |pkg| {
            if (!containsPkg(self_pol.allow.items, pkg) or
                containsPkg(self_pol.deny.items, pkg))
            {
                return false;
            }
        }
    }
    return true;
}

pub fn mergeDenyCsv(
    allocator: std.mem.Allocator,
    a: []const []const u8,
    b: []const []const u8,
) ![]u8 {
    var merged: std.ArrayList([]const u8) = .empty;
    defer freeOwnedList(&merged, allocator);
    for (a) |item| try appendUniquePkg(allocator, &merged, item);
    for (b) |item| try appendUniquePkg(allocator, &merged, item);
    return formatCsv(allocator, merged.items, "none");
}

pub fn checkRunPackagesCeiling(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    packages_opt: ?[]const u8,
) !void {
    const pkg_csv = packages_opt orelse return;
    if (!isValidPkgListCsv(pkg_csv, true)) {
        common.printFmt(
            "Error: Invalid '--packages' list '{s}'.\n",
            .{pkg_csv},
        );
        return error.InvalidPackageList;
    }
    var req_pol = PkgPolicy{
        .allow_all = std.mem.eql(u8, common.trimWhitespace(pkg_csv), "*"),
    };
    defer req_pol.deinit(allocator);
    if (!req_pol.allow_all) {
        try parseCsvIntoList(allocator, pkg_csv, &req_pol.allow);
    }

    var self_pol = try loadGuestManifestPolicy(
        allocator,
        client,
        common.CID_SELF,
    );
    defer self_pol.deinit(allocator);
    if (!isWithinParentCeiling(
        &self_pol,
        req_pol.allow_all,
        req_pol.allow.items,
        req_pol.deny.items,
    )) {
        common.printStr(
            "Error: Requested '--packages' exceeds this VM's " ++
                "own package ceiling.\n",
        );
        return error.PermissionDenied;
    }
}

pub fn applyRunPackagesPolicy(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    child_cid: usize,
    packages_opt: ?[]const u8,
) void {
    var self_pol = loadGuestManifestPolicy(
        allocator,
        client,
        common.CID_SELF,
    ) catch return;
    defer self_pol.deinit(allocator);

    var owned_allow: ?[]u8 = null;
    defer if (owned_allow) |oa| allocator.free(oa);
    const allow_csv: ?[]const u8 = if (packages_opt) |p|
        common.trimWhitespace(p)
    else if (!self_pol.allow_all) blk: {
        owned_allow = formatCsv(
            allocator,
            self_pol.allow.items,
            "none",
        ) catch return;
        break :blk owned_allow.?;
    } else null;

    var owned_deny: ?[]u8 = null;
    defer if (owned_deny) |od| allocator.free(od);
    const deny_csv: ?[]const u8 = if (self_pol.deny.items.len > 0) blk: {
        owned_deny = formatCsv(
            allocator,
            self_pol.deny.items,
            "none",
        ) catch return;
        break :blk owned_deny.?;
    } else null;

    if (allow_csv != null or deny_csv != null) {
        updateChildPkgHeaders(
            allocator,
            client,
            child_cid,
            allow_csv,
            deny_csv,
        ) catch {};
    }
}

test "pkg/policy: header parsing, monotonic ceiling, and manifest update" {
    std.testing.refAllDecls(@This());
    const t = std.testing;
    const alloc = t.allocator;

    const m =
        \\# diosix-net-mode: local
        \\# diosix-pkg-allow: doas,chrony
        \\# diosix-pkg-deny: nmap
        \\[vm]
        \\name = "child-sup"
    ;
    var pol = try parsePolicy(alloc, m);
    defer pol.deinit(alloc);
    try t.expect(!pol.allow_all);
    try t.expectEqual(@as(usize, 2), pol.allow.items.len);
    try t.expect(containsPkg(pol.allow.items, "doas"));
    try t.expect(containsPkg(pol.deny.items, "nmap"));

    try t.expect(isWithinParentCeiling(&pol, false, &.{"doas"}, &.{"nmap"}));
    try t.expect(!isWithinParentCeiling(&pol, true, &.{}, &.{"nmap"}));
    try t.expect(!isWithinParentCeiling(&pol, false, &.{"wget"}, &.{"nmap"}));
    try t.expect(!isWithinParentCeiling(&pol, false, &.{"nmap"}, &.{}));

    var root_deny = try parsePolicy(alloc, "# diosix-pkg-deny: chrony\n");
    defer root_deny.deinit(alloc);
    try t.expect(!isWithinParentCeiling(&root_deny, false, &.{"chrony"}, &.{}));
    try t.expect(isWithinParentCeiling(&root_deny, false, &.{"doas"}, &.{}));

    const updated = try formatManifestWithPkgHeaders(
        alloc,
        m,
        "doas",
        null,
    );
    defer alloc.free(updated);
    var pol2 = try parsePolicy(alloc, updated);
    defer pol2.deinit(alloc);
    try t.expectEqual(@as(usize, 1), pol2.allow.items.len);
    try t.expect(containsPkg(pol2.allow.items, "doas"));
    try t.expect(containsPkg(pol2.deny.items, "nmap"));
    try t.expect(!isLeafManifest(m));
    try t.expect(isLeafManifest("# diosix-leaf: true\n[vm]\n"));
    try t.expect(!isLeafManifest("# diosix-leaf: false\n[vm]\n"));
}
