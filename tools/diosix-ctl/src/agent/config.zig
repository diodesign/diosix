// Autonomous Agent Configuration Parser & Provider Resolver.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("../api.zig");
const common = @import("../common.zig");
const net_http = @import("../net/http.zig");
const sysconfig = @import("../sysconfig.zig");

pub const AgentProvider = enum {
    auto,
    policy,
    parent,
    openrouter,
    opencode,
    local,
};

pub const DEFAULT_OPENROUTER_URL =
    "https://openrouter.ai/api/v1/chat/completions";
pub const DEFAULT_OPENCODE_URL =
    "https://api.opencode.ai/v1/chat/completions";
pub const DEFAULT_PARENT_LLM_URL =
    "http://diosix-parent:8081/v1/chat/completions";

pub const AgentConfig = struct {
    enabled: bool = false,
    poll_interval_sec: u32 = 5,
    provider: AgentProvider = .auto,
    resolved_provider: AgentProvider = .policy,
    model_buf: [128]u8 = @splat(0),
    model_len: usize = 0,
    endpoint_buf: [256]u8 = @splat(0),
    endpoint_len: usize = 0,
    api_key_buf: [256]u8 = @splat(0),
    api_key_len: usize = 0,
    proxy_port: u16 = sysconfig.DEFAULT_LLM_PROXY_PORT,
    max_tokens: u32 = 512,
    has_openrouter_key: bool = false,
    has_opencode_key: bool = false,

    pub fn initDefaults() AgentConfig {
        var cfg = AgentConfig{};
        common.setFixedBuf(
            &cfg.model_buf,
            &cfg.model_len,
            "openai/gpt-4o-mini",
        );
        return cfg;
    }

    pub fn deinit(self: *AgentConfig) void {
        std.crypto.secureZero(u8, &self.api_key_buf);
        self.api_key_len = 0;
    }

    pub fn model(self: *const AgentConfig) []const u8 {
        if (self.model_len == 0) return "openai/gpt-4o-mini";
        return self.model_buf[0..self.model_len];
    }

    pub fn endpoint(self: *const AgentConfig) []const u8 {
        return self.endpoint_buf[0..self.endpoint_len];
    }

    pub fn apiKey(self: *const AgentConfig) []const u8 {
        return self.api_key_buf[0..self.api_key_len];
    }
};

const TomlKey = enum {
    enabled,
    poll_interval_sec,
    provider,
    model,
    endpoint,
    proxy_port,
    max_tokens,
};

pub fn parseAgentToml(content: []const u8) AgentConfig {
    var cfg = AgentConfig.initDefaults();
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = common.trimWhitespace(raw_line);
        if (line.len == 0 or line[0] == '#' or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = common.trimWhitespace(line[0..eq]);
        const val = common.unquoteToml(line[eq + 1 ..]);
        const k = std.meta.stringToEnum(TomlKey, key) orelse continue;
        switch (k) {
            .enabled => cfg.enabled = std.mem.eql(u8, val, "true"),
            .poll_interval_sec => {
                const s = std.fmt.parseInt(u32, val, 10) catch 5;
                cfg.poll_interval_sec = std.math.clamp(s, 1, 3600);
            },
            .provider => {
                cfg.provider =
                    std.meta.stringToEnum(AgentProvider, val) orelse .auto;
            },
            .model => common.setFixedBuf(&cfg.model_buf, &cfg.model_len, val),
            .endpoint => {
                common.setFixedBuf(&cfg.endpoint_buf, &cfg.endpoint_len, val);
            },
            .proxy_port => {
                const p = std.fmt.parseInt(u16, val, 10) catch
                    sysconfig.DEFAULT_LLM_PROXY_PORT;
                if (p > 0) cfg.proxy_port = p;
            },
            .max_tokens => {
                const t = std.fmt.parseInt(u32, val, 10) catch 512;
                cfg.max_tokens = std.math.clamp(t, 32, 8192);
            },
        }
    }
    return cfg;
}

fn readProcEnvironAlloc(allocator: std.mem.Allocator) ![]u8 {
    const rc: isize = @bitCast(
        linux.open("/proc/self/environ", .{ .ACCMODE = .RDONLY }, 0),
    );
    if (rc < 0) return error.EnvironUnavailable;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer {
        std.crypto.secureZero(u8, out.items);
        out.deinit(allocator);
    }
    var buf: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &buf);
    while (true) {
        const rr: isize = @bitCast(linux.read(fd, &buf, buf.len));
        if (rr <= 0) break;
        const n: usize = @intCast(rr);
        if (out.items.len + n > 256 * 1024) break;
        try out.appendSlice(allocator, buf[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

const EnvVarKey = enum {
    DIOSIX_LLM_PROVIDER,
    DIOSIX_LLM_MODEL,
    DIOSIX_LLM_BASE_URL,
    OPENROUTER_API_KEY,
    OPENCODE_API_KEY,
    OPENCODE_BASE_URL,
};

pub fn applyEnvironBuffer(cfg: *AgentConfig, env_bytes: []const u8) void {
    var it = std.mem.splitScalar(u8, env_bytes, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const name = entry[0..eq];
        const val = entry[eq + 1 ..];
        if (val.len == 0) continue;
        const ek = std.meta.stringToEnum(EnvVarKey, name) orelse continue;
        switch (ek) {
            .DIOSIX_LLM_PROVIDER => {
                if (std.meta.stringToEnum(AgentProvider, val)) |p| {
                    cfg.provider = p;
                }
            },
            .DIOSIX_LLM_MODEL => {
                common.setFixedBuf(&cfg.model_buf, &cfg.model_len, val);
            },
            .DIOSIX_LLM_BASE_URL => {
                common.setFixedBuf(&cfg.endpoint_buf, &cfg.endpoint_len, val);
            },
            .OPENROUTER_API_KEY => {
                cfg.has_openrouter_key = true;
                common.setFixedBuf(&cfg.api_key_buf, &cfg.api_key_len, val);
            },
            .OPENCODE_API_KEY => {
                cfg.has_opencode_key = true;
                if (cfg.api_key_len == 0) {
                    common.setFixedBuf(&cfg.api_key_buf, &cfg.api_key_len, val);
                }
            },
            .OPENCODE_BASE_URL => {
                if (cfg.endpoint_len == 0) {
                    common.setFixedBuf(
                        &cfg.endpoint_buf,
                        &cfg.endpoint_len,
                        val,
                    );
                }
            },
        }
    }
}

pub fn resolveProvider(cfg: *AgentConfig, has_parent: bool) void {
    const eff: AgentProvider = switch (cfg.provider) {
        .auto => blk: {
            if (cfg.has_openrouter_key) break :blk .openrouter;
            if (cfg.has_opencode_key) break :blk .opencode;
            if (cfg.endpoint_len > 0) break :blk .local;
            if (has_parent) break :blk .parent;
            break :blk .policy;
        },
        else => |explicit| explicit,
    };
    cfg.resolved_provider = eff;
    if (cfg.endpoint_len == 0) {
        const def_ep: []const u8 = switch (eff) {
            .openrouter => DEFAULT_OPENROUTER_URL,
            .opencode => DEFAULT_OPENCODE_URL,
            .parent => DEFAULT_PARENT_LLM_URL,
            .local => "http://10.0.2.2:11434/v1/chat/completions",
            .policy, .auto => "",
        };
        if (def_ep.len > 0) {
            common.setFixedBuf(&cfg.endpoint_buf, &cfg.endpoint_len, def_ep);
        }
    }
}

pub fn loadAgentConfig(
    allocator: std.mem.Allocator,
    has_parent: bool,
) AgentConfig {
    var cfg = blk: {
        const raw = common.readBinaryFile(
            sysconfig.DEFAULT_AGENT_CONFIG_PATH,
            common.MAX_MANIFEST_SIZE,
        ) catch break :blk AgentConfig.initDefaults();
        defer common.unmapBinaryFile(raw);
        break :blk parseAgentToml(raw);
    };
    if (readProcEnvironAlloc(allocator)) |env_buf| {
        defer {
            std.crypto.secureZero(u8, env_buf);
            allocator.free(env_buf);
        }
        applyEnvironBuffer(&cfg, env_buf);
    } else |_| {}
    resolveProvider(&cfg, has_parent);
    return cfg;
}

test "agent/config: parses agent.toml and resolves providers" {
    std.testing.refAllDecls(@This());
    const t = std.testing;
    const toml =
        \\[agent]
        \\enabled = true
        \\poll_interval_sec = 7
        \\provider = "auto"
        \\model = "anthropic/claude-3.5-sonnet"
        \\proxy_port = 8081
    ;
    var cfg = parseAgentToml(toml);
    defer cfg.deinit();
    resolveProvider(&cfg, true);
    try t.expectEqual(AgentProvider.parent, cfg.resolved_provider);
    try t.expectEqualStrings(DEFAULT_PARENT_LLM_URL, cfg.endpoint());

    var cfg2 = parseAgentToml(toml);
    defer cfg2.deinit();
    applyEnvironBuffer(&cfg2, "OPENROUTER_API_KEY=sk-test\x00");
    resolveProvider(&cfg2, false);
    try t.expectEqual(AgentProvider.openrouter, cfg2.resolved_provider);
    try t.expectEqualStrings(DEFAULT_OPENROUTER_URL, cfg2.endpoint());
    try t.expectEqualStrings("sk-test", cfg2.apiKey());
}
