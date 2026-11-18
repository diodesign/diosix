// TOML, Secret File, and Environ Parsers for Autonomous Agent Config.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const cfg_mod = @import("../config.zig");
const common = @import("../../common.zig");
const net_http = @import("../../net/http.zig");
const sysconfig = @import("../../sysconfig.zig");

const AgentConfig = cfg_mod.AgentConfig;
const AgentProvider = cfg_mod.AgentProvider;
const AgentUserMode = cfg_mod.AgentUserMode;

const Section = enum {
    agent,
    tiers,
};

const AgentKey = enum {
    enabled,
    user_mode,
    poll_interval_sec,
    provider,
    default_thinking,
    model,
    endpoint,
    proxy_port,
    max_tokens,
    root_token_budget,
    root_cost_budget_micros,
    tokens_per_min,
    requests_per_min,
};

const TierKey = enum {
    minimal_model,
    minimal_in_micros_1k,
    minimal_out_micros_1k,
    low_model,
    low_in_micros_1k,
    low_out_micros_1k,
    medium_model,
    medium_in_micros_1k,
    medium_out_micros_1k,
    high_model,
    high_in_micros_1k,
    high_out_micros_1k,
};

fn parseU64Or(val: []const u8, fallback: u64) u64 {
    return std.fmt.parseInt(u64, val, 10) catch fallback;
}

fn applyTierKey(cfg: *AgentConfig, key: []const u8, val: []const u8) void {
    const tk = std.meta.stringToEnum(TierKey, key) orelse return;
    switch (tk) {
        .minimal_model => common.setFixedBuf(
            &cfg.tiers[0].model_buf,
            &cfg.tiers[0].model_len,
            val,
        ),
        .minimal_in_micros_1k => cfg.tiers[0].in_micros_1k =
            parseU64Or(val, cfg.tiers[0].in_micros_1k),
        .minimal_out_micros_1k => cfg.tiers[0].out_micros_1k =
            parseU64Or(val, cfg.tiers[0].out_micros_1k),
        .low_model => common.setFixedBuf(
            &cfg.tiers[1].model_buf,
            &cfg.tiers[1].model_len,
            val,
        ),
        .low_in_micros_1k => cfg.tiers[1].in_micros_1k =
            parseU64Or(val, cfg.tiers[1].in_micros_1k),
        .low_out_micros_1k => cfg.tiers[1].out_micros_1k =
            parseU64Or(val, cfg.tiers[1].out_micros_1k),
        .medium_model => common.setFixedBuf(
            &cfg.tiers[2].model_buf,
            &cfg.tiers[2].model_len,
            val,
        ),
        .medium_in_micros_1k => cfg.tiers[2].in_micros_1k =
            parseU64Or(val, cfg.tiers[2].in_micros_1k),
        .medium_out_micros_1k => cfg.tiers[2].out_micros_1k =
            parseU64Or(val, cfg.tiers[2].out_micros_1k),
        .high_model => common.setFixedBuf(
            &cfg.tiers[3].model_buf,
            &cfg.tiers[3].model_len,
            val,
        ),
        .high_in_micros_1k => cfg.tiers[3].in_micros_1k =
            parseU64Or(val, cfg.tiers[3].in_micros_1k),
        .high_out_micros_1k => cfg.tiers[3].out_micros_1k =
            parseU64Or(val, cfg.tiers[3].out_micros_1k),
    }
}

fn applyAgentKey(cfg: *AgentConfig, key: []const u8, val: []const u8) void {
    const k = std.meta.stringToEnum(AgentKey, key) orelse return;
    switch (k) {
        .enabled => cfg.enabled = std.mem.eql(u8, val, "true"),
        .user_mode => cfg.user_mode =
            std.meta.stringToEnum(AgentUserMode, val) orelse .sudoer,
        .poll_interval_sec => {
            const s = std.fmt.parseInt(u32, val, 10) catch 5;
            cfg.poll_interval_sec = std.math.clamp(s, 1, 3600);
        },
        .provider => cfg.provider =
            std.meta.stringToEnum(AgentProvider, val) orelse .auto,
        .default_thinking => cfg.default_thinking =
            cfg_mod.parseThinkingLevel(val) orelse .low,
        .model => common.setFixedBuf(&cfg.model_buf, &cfg.model_len, val),
        .endpoint => common.setFixedBuf(
            &cfg.endpoint_buf,
            &cfg.endpoint_len,
            val,
        ),
        .proxy_port => {
            const p = std.fmt.parseInt(u16, val, 10) catch
                sysconfig.DEFAULT_LLM_PROXY_PORT;
            if (p > 0) cfg.proxy_port = p;
        },
        .max_tokens => {
            const t = std.fmt.parseInt(u32, val, 10) catch 512;
            cfg.max_tokens = std.math.clamp(t, 32, 8192);
        },
        .root_token_budget => cfg.root_token_budget =
            parseU64Or(val, cfg.root_token_budget),
        .root_cost_budget_micros => cfg.root_cost_budget_micros =
            parseU64Or(val, cfg.root_cost_budget_micros),
        .tokens_per_min => cfg.tokens_per_min =
            std.fmt.parseInt(u32, val, 10) catch cfg.tokens_per_min,
        .requests_per_min => cfg.requests_per_min =
            std.fmt.parseInt(u32, val, 10) catch cfg.requests_per_min,
    }
}

pub fn parseAgentToml(content: []const u8) AgentConfig {
    var cfg = AgentConfig.initDefaults();
    var section: Section = .agent;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = common.trimWhitespace(raw_line);
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            const hdr = common.trimWhitespace(line[1 .. line.len - 1]);
            section = std.meta.stringToEnum(Section, hdr) orelse .agent;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = common.trimWhitespace(line[0..eq]);
        const val = common.unquoteToml(line[eq + 1 ..]);
        switch (section) {
            .agent => applyAgentKey(&cfg, key, val),
            .tiers => applyTierKey(&cfg, key, val),
        }
    }
    return cfg;
}

const SecretKeyField = enum {
    provider,
    api_key,
    endpoint,
};

pub fn applySecretFileContent(cfg: *AgentConfig, raw: []const u8) void {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |raw_line| {
        const line = common.trimWhitespace(raw_line);
        if (line.len == 0 or line[0] == '#' or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = common.trimWhitespace(line[0..eq]);
        const val = common.unquoteToml(line[eq + 1 ..]);
        const fk = std.meta.stringToEnum(SecretKeyField, key) orelse continue;
        switch (fk) {
            .provider => {
                if (std.meta.stringToEnum(AgentProvider, val)) |p| {
                    cfg.provider = p;
                }
            },
            .api_key => if (val.len > 0) {
                common.setFixedBuf(&cfg.api_key_buf, &cfg.api_key_len, val);
                if (cfg.provider == .opencode) {
                    cfg.has_opencode_key = true;
                } else {
                    cfg.has_openrouter_key = true;
                }
            },
            .endpoint => if (val.len > 0) {
                common.setFixedBuf(&cfg.endpoint_buf, &cfg.endpoint_len, val);
            },
        }
    }
}

pub fn writeSecretKeyFile(
    allocator: std.mem.Allocator,
    provider: AgentProvider,
    api_key: []const u8,
    endpoint_opt: ?[]const u8,
) !void {
    net_http.ensureParentDir(sysconfig.LLM_SECRET_KEY_PATH);
    const ep = endpoint_opt orelse "";
    const content = try allocator.print(
        "provider = \"{s}\"\napi_key = \"{s}\"\nendpoint = \"{s}\"\n",
        .{ @tagName(provider), api_key, ep },
    );
    defer {
        std.crypto.secureZero(u8, content);
        allocator.free(content);
    }
    try common.writePrivateFile(sysconfig.LLM_SECRET_KEY_PATH, content);
}

pub fn readProcEnvironAlloc(allocator: std.mem.Allocator) ![]u8 {
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

pub fn applyEnvironBufferWithPolicy(
    cfg: *AgentConfig,
    env_bytes: []const u8,
    allow_secrets: bool,
) void {
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
            .DIOSIX_LLM_MODEL => common.setFixedBuf(
                &cfg.model_buf,
                &cfg.model_len,
                val,
            ),
            .DIOSIX_LLM_BASE_URL => common.setFixedBuf(
                &cfg.endpoint_buf,
                &cfg.endpoint_len,
                val,
            ),
            .OPENROUTER_API_KEY => if (allow_secrets) {
                cfg.has_openrouter_key = true;
                common.setFixedBuf(&cfg.api_key_buf, &cfg.api_key_len, val);
            },
            .OPENCODE_API_KEY => if (allow_secrets) {
                cfg.has_opencode_key = true;
                if (cfg.api_key_len == 0) {
                    common.setFixedBuf(&cfg.api_key_buf, &cfg.api_key_len, val);
                }
            },
            .OPENCODE_BASE_URL => if (cfg.endpoint_len == 0) {
                common.setFixedBuf(&cfg.endpoint_buf, &cfg.endpoint_len, val);
            },
        }
    }
}

test "agent/config/parser: TOML sections and secret parser compile" {
    std.testing.refAllDecls(@This());
    const cfg = parseAgentToml("[agent]\nrequests_per_min = 42\n");
    try std.testing.expectEqual(@as(u32, 42), cfg.requests_per_min);
}
