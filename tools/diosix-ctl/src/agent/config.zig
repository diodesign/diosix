// Autonomous Agent Configuration Types, Tier Rates & Provider Resolver.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const common = @import("../common.zig");
const sysconfig = @import("../sysconfig.zig");
pub const parser = @import("config/parser.zig");

pub const parseAgentToml = parser.parseAgentToml;
pub const applySecretFileContent = parser.applySecretFileContent;
pub const writeSecretKeyFile = parser.writeSecretKeyFile;
pub const applyEnvironBufferWithPolicy = parser.applyEnvironBufferWithPolicy;

pub const AgentProvider = enum {
    auto,
    policy,
    parent,
    openrouter,
    opencode,
    local,
};

pub const ThinkingLevel = enum(u8) {
    minimal = 0,
    low = 1,
    medium = 2,
    high = 3,
};

pub const AgentUserMode = enum {
    off,
    root,
    sudoer,
    @"non-sudoer",
};

pub const DEFAULT_OPENROUTER_URL =
    "https://openrouter.ai/api/v1/chat/completions";
pub const DEFAULT_OPENCODE_URL =
    "https://api.opencode.ai/v1/chat/completions";
pub const DEFAULT_PARENT_LLM_URL =
    "http://diosix-parent:8081/v1/chat/completions";
pub const DEFAULT_PARENT_INFER_URL =
    "http://diosix-parent:8081/v1/infer";
pub const DEFAULT_LOCAL_LLM_URL =
    "http://10.0.2.2:11434/v1/chat/completions";

pub const TierSpec = struct {
    model_buf: [128]u8 = @splat(0),
    model_len: usize = 0,
    in_micros_1k: u64 = 150,
    out_micros_1k: u64 = 600,

    pub fn model(self: *const TierSpec) []const u8 {
        if (self.model_len == 0) return "openai/gpt-4o-mini";
        return self.model_buf[0..self.model_len];
    }
};

fn initTierSpec(m: []const u8, in_u: u64, out_u: u64) TierSpec {
    var spec = TierSpec{ .in_micros_1k = in_u, .out_micros_1k = out_u };
    common.setFixedBuf(&spec.model_buf, &spec.model_len, m);
    return spec;
}

pub const AgentConfig = struct {
    enabled: bool = false,
    user_mode: AgentUserMode = .sudoer,
    poll_interval_sec: u32 = 5,
    provider: AgentProvider = .auto,
    resolved_provider: AgentProvider = .policy,
    default_thinking: ThinkingLevel = .low,
    model_buf: [128]u8 = @splat(0),
    model_len: usize = 0,
    endpoint_buf: [256]u8 = @splat(0),
    endpoint_len: usize = 0,
    api_key_buf: [256]u8 = @splat(0),
    api_key_len: usize = 0,
    proxy_port: u16 = sysconfig.DEFAULT_LLM_PROXY_PORT,
    max_tokens: u32 = 512,
    root_token_budget: u64 = 10_000_000,
    root_cost_budget_micros: u64 = 50_000_000,
    tokens_per_min: u32 = 120_000,
    requests_per_min: u32 = 60,
    tiers: [4]TierSpec = .{
        initTierSpec("openai/gpt-4o-mini", 150, 600),
        initTierSpec("openai/gpt-4o-mini", 150, 600),
        initTierSpec("anthropic/claude-3.5-sonnet", 3000, 15000),
        initTierSpec("openai/o3", 10000, 40000),
    },
    has_openrouter_key: bool = false,
    has_opencode_key: bool = false,

    pub fn initDefaults() AgentConfig {
        return .{};
    }

    pub fn deinit(self: *AgentConfig) void {
        std.crypto.secureZero(u8, &self.api_key_buf);
        self.api_key_len = 0;
    }

    pub fn model(self: *const AgentConfig) []const u8 {
        if (self.model_len > 0) return self.model_buf[0..self.model_len];
        return self.tiers[@backingInt(self.default_thinking)].model();
    }

    pub fn tierSpec(self: *const AgentConfig, lvl: ThinkingLevel) TierSpec {
        var spec = self.tiers[@backingInt(lvl)];
        if (self.model_len > 0) {
            common.setFixedBuf(
                &spec.model_buf,
                &spec.model_len,
                self.model_buf[0..self.model_len],
            );
        }
        return spec;
    }

    pub fn computeCostMicros(
        self: *const AgentConfig,
        lvl: ThinkingLevel,
        in_tok: u64,
        out_tok: u64,
    ) u64 {
        const spec = self.tierSpec(lvl);
        const in_cost = if (in_tok == 0 or spec.in_micros_1k == 0)
            0
        else
            ((in_tok *| spec.in_micros_1k) +| 999) / 1000;
        const out_cost = if (out_tok == 0 or spec.out_micros_1k == 0)
            0
        else
            ((out_tok *| spec.out_micros_1k) +| 999) / 1000;
        return in_cost +| out_cost;
    }

    pub fn endpoint(self: *const AgentConfig) []const u8 {
        return self.endpoint_buf[0..self.endpoint_len];
    }

    pub fn apiKey(self: *const AgentConfig) []const u8 {
        return self.api_key_buf[0..self.api_key_len];
    }
};

pub fn parseThinkingLevel(str: []const u8) ?ThinkingLevel {
    return std.meta.stringToEnum(ThinkingLevel, common.trimWhitespace(str));
}

pub fn applyEnvironBuffer(cfg: *AgentConfig, env_bytes: []const u8) void {
    applyEnvironBufferWithPolicy(cfg, env_bytes, true);
}

pub fn resolveProvider(cfg: *AgentConfig, has_parent: bool) void {
    const eff: AgentProvider = switch (cfg.provider) {
        .auto => blk: {
            if (has_parent) break :blk .parent;
            if (cfg.has_openrouter_key) break :blk .openrouter;
            if (cfg.has_opencode_key) break :blk .opencode;
            if (cfg.endpoint_len > 0) break :blk .local;
            break :blk .policy;
        },
        else => |explicit| explicit,
    };
    cfg.resolved_provider = eff;
    if (cfg.endpoint_len == 0) {
        const def_ep: []const u8 = switch (eff) {
            .openrouter => DEFAULT_OPENROUTER_URL,
            .opencode => DEFAULT_OPENCODE_URL,
            .parent => DEFAULT_PARENT_INFER_URL,
            .local => DEFAULT_LOCAL_LLM_URL,
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
    if (!has_parent) {
        if (common.readBinaryFile(sysconfig.LLM_SECRET_KEY_PATH, 4096)) |sr| {
            defer {
                if (sr.len > 0) std.crypto.secureZero(u8, sr);
                common.unmapBinaryFile(sr);
            }
            applySecretFileContent(&cfg, sr);
        } else |_| {}
    }
    if (parser.readProcEnvironAlloc(allocator)) |env_buf| {
        defer {
            std.crypto.secureZero(u8, env_buf);
            allocator.free(env_buf);
        }
        applyEnvironBufferWithPolicy(&cfg, env_buf, !has_parent);
    } else |_| {}
    resolveProvider(&cfg, has_parent);
    return cfg;
}

test "agent/config: parses tiers, secret files, and cost math" {
    _ = parser;
    std.testing.refAllDecls(@This());
    const t = std.testing;
    const toml =
        \\[agent]
        \\enabled = true
        \\user_mode = "non-sudoer"
        \\default_thinking = "medium"
        \\[tiers]
        \\low_model = "test/mini"
        \\low_in_micros_1k = 200
        \\low_out_micros_1k = 800
    ;
    var cfg = parseAgentToml(toml);
    defer cfg.deinit();
    try t.expectEqual(AgentUserMode.@"non-sudoer", cfg.user_mode);
    try t.expectEqual(ThinkingLevel.medium, cfg.default_thinking);
    try t.expectEqual(@as(u64, 1), cfg.computeCostMicros(.low, 1, 0));
    try t.expectEqual(@as(u64, 0), cfg.computeCostMicros(.low, 0, 0));
    try t.expectEqual(@as(u64, 1000), cfg.computeCostMicros(.low, 1000, 1000));

    resolveProvider(&cfg, true);
    try t.expectEqual(AgentProvider.parent, cfg.resolved_provider);
    try t.expectEqualStrings(DEFAULT_PARENT_INFER_URL, cfg.endpoint());

    var cfg2 = parseAgentToml(toml);
    defer cfg2.deinit();
    applySecretFileContent(
        &cfg2,
        "provider = \"openrouter\"\napi_key = \"sk\"\n",
    );
    resolveProvider(&cfg2, false);
    try t.expectEqual(AgentProvider.openrouter, cfg2.resolved_provider);
    try t.expectEqualStrings("sk", cfg2.apiKey());
}
