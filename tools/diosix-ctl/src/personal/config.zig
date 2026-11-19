// Diosix Personal Desktop Profile Configuration (/etc/diosix/personal.toml).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const owned = @import("../vm/owned.zig");
const vm_passthrough = @import("../vm/passthrough.zig");

pub const MAX_PROFILES: usize = 8;

pub const DesktopProfile = struct {
    name: []const u8 = "desktop",
    image: []const u8 = "diosix-node",
    ram_mb: usize = 1024,
    vcpus: usize = 2,
    cpu_pct: usize = 0,
    dma_trusted: bool = false,
    cmdline: []const u8 = "",
    unbind_platform: []const u8 = "",
    mmio: [vm_passthrough.MAX_PASSTHROUGH_RANGES][]const u8 = @splat(""),
    mmio_count: usize = 0,
    irq: [vm_passthrough.MAX_PASSTHROUGH_IRQS][]const u8 = @splat(""),
    irq_count: usize = 0,
    keep_fdt: [vm_passthrough.MAX_KEEP_FDT_PREFIXES][]const u8 = @splat(""),
    keep_fdt_count: usize = 0,
};

pub const PersonalConfig = struct {
    strings: owned.OwnedStrings,
    default_profile: []const u8 = "desktop",
    auto_start: bool = false,
    desktop: DesktopProfile = .{},
    profiles: [MAX_PROFILES]DesktopProfile = @splat(.{}),
    profile_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) PersonalConfig {
        return .{ .strings = owned.OwnedStrings.init(allocator) };
    }

    pub fn deinit(self: *PersonalConfig) void {
        self.strings.deinit();
    }

    pub fn upsertProfile(
        self: *PersonalConfig,
        raw_name: []const u8,
    ) !*DesktopProfile {
        if (raw_name.len == 0 or std.mem.eql(u8, raw_name, "desktop")) {
            return &self.desktop;
        }
        for (self.profiles[0..self.profile_count]) |*p| {
            if (std.mem.eql(u8, p.name, raw_name)) return p;
        }
        if (self.profile_count >= MAX_PROFILES) return error.TooManyProfiles;
        const copy = try self.strings.dupe(raw_name);
        const slot = &self.profiles[self.profile_count];
        slot.* = .{ .name = copy };
        self.profile_count += 1;
        return slot;
    }

    pub fn findProfile(
        self: *const PersonalConfig,
        name_opt: ?[]const u8,
    ) ?DesktopProfile {
        const target = name_opt orelse self.default_profile;
        for (self.profiles[0..self.profile_count]) |p| {
            if (std.mem.eql(u8, p.name, target)) return p;
        }
        if (name_opt == null or std.mem.eql(u8, target, "desktop") or
            std.mem.eql(u8, target, self.desktop.name))
        {
            return self.desktop;
        }
        return null;
    }
};

fn trimAscii(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn unquoteToml(raw: []const u8) []const u8 {
    const t = trimAscii(raw);
    if (t.len >= 2 and
        ((t[0] == '"' and t[t.len - 1] == '"') or
            (t[0] == '\'' and t[t.len - 1] == '\'')))
    {
        return t[1 .. t.len - 1];
    }
    return t;
}

fn stripComment(raw: []const u8) []const u8 {
    var in_quote = false;
    var quote_ch: u8 = 0;
    for (raw, 0..) |ch, idx| {
        if (in_quote) {
            if (ch == quote_ch) in_quote = false;
        } else if (ch == '"' or ch == '\'') {
            in_quote = true;
            quote_ch = ch;
        } else if (ch == '#') {
            return trimAscii(raw[0..idx]);
        }
    }
    return trimAscii(raw);
}

pub fn setCsvList(
    strings: *owned.OwnedStrings,
    dst: [][]const u8,
    count: *usize,
    raw_val: []const u8,
) !void {
    count.* = 0;
    var body = trimAscii(raw_val);
    if (body.len >= 2 and body[0] == '[' and body[body.len - 1] == ']') {
        body = trimAscii(body[1 .. body.len - 1]);
    } else {
        body = unquoteToml(body);
    }
    if (body.len == 0) return;

    var it = std.mem.splitScalar(u8, body, ',');
    while (it.next()) |tok| {
        const clean = unquoteToml(tok);
        if (clean.len == 0) continue;
        if (count.* >= dst.len) break;
        dst[count.*] = try strings.dupe(clean);
        count.* += 1;
    }
}

const ProfileKey = enum {
    name,
    default_profile,
    auto_start,
    image,
    ram_mb,
    vcpus,
    cpu_pct,
    dma_trusted,
    cmdline,
    unbind_platform,
    mmio,
    irq,
    keep_fdt,
};

fn applyProfileKey(
    cfg: *PersonalConfig,
    prof: *DesktopProfile,
    is_desktop: bool,
    key_raw: []const u8,
    val_raw: []const u8,
) !void {
    const key = std.meta.stringToEnum(ProfileKey, key_raw) orelse return;
    const val = unquoteToml(val_raw);
    switch (key) {
        .default_profile => if (is_desktop and val.len > 0) {
            cfg.default_profile = try cfg.strings.dupe(val);
        },
        .auto_start => if (is_desktop) {
            cfg.auto_start = std.mem.eql(u8, val, "true");
        },
        .name => if (val.len > 0) {
            prof.name = try cfg.strings.dupe(val);
        },
        .image => if (val.len > 0) {
            prof.image = try cfg.strings.dupe(val);
        },
        .ram_mb => {
            prof.ram_mb = std.fmt.parseInt(usize, val, 10) catch prof.ram_mb;
        },
        .vcpus => {
            prof.vcpus = std.fmt.parseInt(usize, val, 10) catch prof.vcpus;
        },
        .cpu_pct => {
            prof.cpu_pct = std.fmt.parseInt(usize, val, 10) catch prof.cpu_pct;
        },
        .dma_trusted => {
            prof.dma_trusted = std.mem.eql(u8, val, "true");
        },
        .cmdline => prof.cmdline = try cfg.strings.dupe(val),
        .unbind_platform => prof.unbind_platform = try cfg.strings.dupe(val),
        .mmio => try setCsvList(&cfg.strings, &prof.mmio, &prof.mmio_count, val_raw),
        .irq => try setCsvList(&cfg.strings, &prof.irq, &prof.irq_count, val_raw),
        .keep_fdt => {
            try setCsvList(
                &cfg.strings,
                &prof.keep_fdt,
                &prof.keep_fdt_count,
                val_raw,
            );
        },
    }
}

pub fn parsePersonalConfig(
    allocator: std.mem.Allocator,
    content: []const u8,
) !PersonalConfig {
    var cfg = PersonalConfig.init(allocator);
    errdefer cfg.deinit();

    var cur_prof: *DesktopProfile = &cfg.desktop;
    var in_desktop = true;

    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |raw_line| {
        const line = stripComment(raw_line);
        if (line.len == 0) continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            const sec = trimAscii(line[1 .. line.len - 1]);
            if (std.mem.eql(u8, sec, "desktop")) {
                cur_prof = &cfg.desktop;
                in_desktop = true;
            } else if (std.mem.startsWith(u8, sec, "profile.")) {
                const pname = trimAscii(sec["profile.".len..]);
                if (pname.len > 0) {
                    cur_prof = try cfg.upsertProfile(pname);
                    in_desktop = false;
                }
            }
            continue;
        }
        if (std.mem.indexOfScalar(u8, line, '=')) |eq_idx| {
            const k = trimAscii(line[0..eq_idx]);
            const v = trimAscii(line[eq_idx + 1 ..]);
            try applyProfileKey(&cfg, cur_prof, in_desktop, k, v);
        }
    }
    return cfg;
}

fn appendListField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    key: []const u8,
    items: []const []const u8,
) !void {
    if (items.len == 0) return;
    const hdr = try allocator.print("{s} = [", .{key});
    defer allocator.free(hdr);
    try out.appendSlice(allocator, hdr);
    for (items, 0..) |item, idx| {
        const sep: []const u8 = if (idx > 0) ", " else "";
        const elem = try allocator.print("{s}\"{s}\"", .{ sep, item });
        defer allocator.free(elem);
        try out.appendSlice(allocator, elem);
    }
    try out.appendSlice(allocator, "]\n");
}

fn appendProfileBody(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    p: DesktopProfile,
) !void {
    const body = try allocator.print(
        "image = \"{s}\"\n" ++
            "ram_mb = {d}\n" ++
            "vcpus = {d}\n" ++
            "cpu_pct = {d}\n" ++
            "dma_trusted = {s}\n",
        .{
            p.image,
            p.ram_mb,
            p.vcpus,
            p.cpu_pct,
            if (p.dma_trusted) "true" else "false",
        },
    );
    defer allocator.free(body);
    try out.appendSlice(allocator, body);
    if (p.cmdline.len > 0) {
        const ln = try allocator.print("cmdline = \"{s}\"\n", .{p.cmdline});
        defer allocator.free(ln);
        try out.appendSlice(allocator, ln);
    }
    if (p.unbind_platform.len > 0) {
        const ln = try allocator.print(
            "unbind_platform = \"{s}\"\n",
            .{p.unbind_platform},
        );
        defer allocator.free(ln);
        try out.appendSlice(allocator, ln);
    }
    try appendListField(allocator, out, "mmio", p.mmio[0..p.mmio_count]);
    try appendListField(allocator, out, "irq", p.irq[0..p.irq_count]);
    try appendListField(allocator, out, "keep_fdt", p.keep_fdt[0..p.keep_fdt_count]);
}

pub fn serializePersonalConfig(
    allocator: std.mem.Allocator,
    cfg: *const PersonalConfig,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const hdr = try allocator.print(
        "# Diosix Personal Desktop Configuration (/etc/diosix/personal.toml)\n" ++
            "[desktop]\n" ++
            "name = \"{s}\"\n" ++
            "default_profile = \"{s}\"\n" ++
            "auto_start = {s}\n",
        .{
            cfg.desktop.name,
            cfg.default_profile,
            if (cfg.auto_start) "true" else "false",
        },
    );
    defer allocator.free(hdr);
    try out.appendSlice(allocator, hdr);
    try appendProfileBody(allocator, &out, cfg.desktop);

    for (cfg.profiles[0..cfg.profile_count]) |p| {
        const sec = try allocator.print("\n[profile.{s}]\n", .{p.name});
        defer allocator.free(sec);
        try out.appendSlice(allocator, sec);
        try appendProfileBody(allocator, &out, p);
    }
    return out.toOwnedSlice(allocator);
}

test "personal/config: parse, lookup, and round-trip serialization" {
    const testing = std.testing;
    const sample =
        \\[desktop]
        \\name = "desktop"
        \\default_profile = "workstation"
        \\ram_mb = 512
        \\vcpus = 2
        \\dma_trusted = false
        \\auto_start = true
        \\
        \\[profile.workstation]
        \\image = "ubuntu-desktop"
        \\ram_mb = 1024
        \\vcpus = 2
        \\dma_trusted = true
        \\unbind_platform = "pci-host-generic:30000000.pci"
        \\mmio = ["0x30000000:0x100000", "0x40000000:0x200000"]
        \\irq = ["32", "33"]
        \\keep_fdt = ["pci@"]
        \\cmdline = "pci=nomsi"
    ;
    var cfg = try parsePersonalConfig(testing.allocator, sample);
    defer cfg.deinit();

    try testing.expect(cfg.auto_start);
    try testing.expectEqualStrings("workstation", cfg.default_profile);
    const prof = cfg.findProfile(null).?;
    try testing.expectEqualStrings("ubuntu-desktop", prof.image);
    try testing.expect(prof.dma_trusted);
    try testing.expectEqual(@as(usize, 2), prof.mmio_count);
    try testing.expectEqualStrings("0x40000000:0x200000", prof.mmio[1]);
    try testing.expectEqual(@as(usize, 2), prof.irq_count);
    try testing.expectEqualStrings("pci@", prof.keep_fdt[0]);

    const serialized = try serializePersonalConfig(testing.allocator, &cfg);
    defer testing.allocator.free(serialized);
    var cfg2 = try parsePersonalConfig(testing.allocator, serialized);
    defer cfg2.deinit();
    try testing.expectEqualStrings(
        "ubuntu-desktop",
        cfg2.findProfile("workstation").?.image,
    );
}
