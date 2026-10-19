// Whisper Mesh BFT Consensus Framing & CLI Handler.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const common = @import("../common.zig");

const WhisperOp = enum { send, recv };
const WhisperSendOption = enum {
    @"--to",
    @"--from",
    @"--type",
    @"--payload",
};
const WhisperRecvOption = enum { @"--frame" };

pub const WhisperMessageType = enum {
    heartbeat,
    propose,
    ratify,
    reset_vote,
    failover_vote,

    pub fn toStr(self: WhisperMessageType) []const u8 {
        return switch (self) {
            .heartbeat => "heartbeat",
            .propose => "propose",
            .ratify => "ratify",
            .reset_vote => "reset-vote",
            .failover_vote => "failover-vote",
        };
    }

    pub fn fromStr(s: []const u8) ?WhisperMessageType {
        const WireType = enum {
            heartbeat,
            propose,
            ratify,
            @"reset-vote",
            @"failover-vote",
        };
        const parsed = std.meta.stringToEnum(WireType, s) orelse return null;
        return switch (parsed) {
            .heartbeat => .heartbeat,
            .propose => .propose,
            .ratify => .ratify,
            .@"reset-vote" => .reset_vote,
            .@"failover-vote" => .failover_vote,
        };
    }
};

pub const WhisperFrame = struct {
    msg_type: WhisperMessageType,
    sender_cid: usize,
    target_cid: usize,
    payload_buf: [128]u8 = @splat(0),
    payload_len: usize = 0,

    pub fn payload(self: *const WhisperFrame) []const u8 {
        return self.payload_buf[0..self.payload_len];
    }
};

/// Format a deterministic Whisper Mesh consensus frame
/// (`whisper:v1:<type>:<sender_cid>:<target_cid>:<payload>`).
pub fn formatWhisperFrame(
    out_buf: []u8,
    msg_type: WhisperMessageType,
    sender_cid: usize,
    target_cid: usize,
    payload_str: []const u8,
) ![]const u8 {
    for (payload_str) |c| {
        if (c < 0x20 or c == 0x7f) return error.InvalidWhisperPayload;
    }
    return std.fmt.bufPrint(out_buf, "whisper:v1:{s}:{d}:{d}:{s}", .{
        msg_type.toStr(),
        sender_cid,
        target_cid,
        payload_str,
    });
}

/// Parse and validate a Whisper Mesh consensus frame.
pub fn parseWhisperFrame(raw: []const u8) !WhisperFrame {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    var it = std.mem.splitScalar(u8, trimmed, ':');
    const prefix = it.next() orelse return error.InvalidWhisperFrame;
    const ver = it.next() orelse return error.InvalidWhisperFrame;
    if (!std.mem.eql(u8, prefix, "whisper") or !std.mem.eql(u8, ver, "v1")) {
        return error.InvalidWhisperFrame;
    }
    const type_str = it.next() orelse return error.InvalidWhisperFrame;
    const msg_type = WhisperMessageType.fromStr(type_str) orelse
        return error.InvalidWhisperFrame;
    const sender_str = it.next() orelse return error.InvalidWhisperFrame;
    const target_str = it.next() orelse return error.InvalidWhisperFrame;
    const payload_str = it.rest();

    const sender_cid = try std.fmt.parseInt(usize, sender_str, 10);
    const target_cid = try std.fmt.parseInt(usize, target_str, 10);

    var frame = WhisperFrame{
        .msg_type = msg_type,
        .sender_cid = sender_cid,
        .target_cid = target_cid,
    };
    common.setFixedBuf(&frame.payload_buf, &frame.payload_len, payload_str);
    return frame;
}

/// CLI handler for `dsx charter whisper <send|recv>`.
pub fn cmdCharterWhisper(
    args: []const [*:0]const u8,
    arg_start: usize,
    json_mode: bool,
) void {
    var w_op: WhisperOp = .recv;
    if (arg_start < args.len) {
        const s = std.mem.span(args[arg_start]);
        if (!std.mem.startsWith(u8, s, "-")) {
            w_op = std.meta.stringToEnum(WhisperOp, s) orelse .recv;
        }
    }
    switch (w_op) {
        .send => {
            var sender_cid: usize = 2;
            var target_cid: usize = 3;
            var msg_type: WhisperMessageType = .heartbeat;
            var payload: []const u8 = "ok";

            var i: usize = arg_start + 1;
            while (i < args.len) : (i += 1) {
                const span = std.mem.span(args[i]);
                if (std.meta.stringToEnum(WhisperSendOption, span)) |opt| {
                    if (i + 1 < args.len) {
                        i += 1;
                        const val = std.mem.span(args[i]);
                        switch (opt) {
                            .@"--to" => {
                                target_cid = common.parseCid(val) catch 3;
                            },
                            .@"--from" => {
                                sender_cid = common.parseCid(val) catch 2;
                            },
                            .@"--type" => {
                                msg_type =
                                    WhisperMessageType.fromStr(val) orelse
                                    .heartbeat;
                            },
                            .@"--payload" => payload = val,
                        }
                    }
                }
            }

            var frame_buf: [256]u8 = undefined;
            const frame = formatWhisperFrame(
                &frame_buf,
                msg_type,
                sender_cid,
                target_cid,
                payload,
            ) catch {
                common.printStr(
                    "Error: Whisper frame exceeds maximum buffer size.\n",
                );
                return;
            };
            var out_buf: [512]u8 = undefined;
            if (json_mode) {
                var safe_buf: [256]u8 = undefined;
                const safe_frame = common.sanitizeJsonStr(&safe_buf, frame);
                const jout = std.fmt.bufPrint(
                    &out_buf,
                    "{{\"status\":\"formatted\",\"frame\":\"{s}\"}}\n",
                    .{safe_frame},
                ) catch return;
                common.printStr(jout);
            } else {
                const out = std.fmt.bufPrint(
                    &out_buf,
                    "✓ Whisper frame: {s}\n",
                    .{frame},
                ) catch return;
                common.printStr(out);
            }
        },
        .recv => {
            var raw_frame: []const u8 = "";
            var i: usize = arg_start + 1;
            while (i < args.len) : (i += 1) {
                const span = std.mem.span(args[i]);
                if (std.meta.stringToEnum(WhisperRecvOption, span) != null and
                    i + 1 < args.len)
                {
                    i += 1;
                    raw_frame = std.mem.span(args[i]);
                }
            }
            if (raw_frame.len == 0) {
                if (json_mode) {
                    common.printStr("{\"status\":\"empty\"}\n");
                } else {
                    common.printStr(
                        "No Whisper frames pending in M-mode queue.\n",
                    );
                }
                return;
            }
            const parsed = parseWhisperFrame(raw_frame) catch {
                common.printStr("Error: Invalid Whisper frame.\n");
                return;
            };
            var out_buf: [512]u8 = undefined;
            if (json_mode) {
                var safe_payload_buf: [256]u8 = undefined;
                const safe_payload = common.sanitizeJsonStr(
                    &safe_payload_buf,
                    parsed.payload(),
                );
                const jout = std.fmt.bufPrint(
                    &out_buf,
                    "{{\"status\":\"received\",\"type\":\"{s}\"," ++
                        "\"sender_cid\":{d},\"target_cid\":{d}," ++
                        "\"payload\":\"{s}\"}}\n",
                    .{
                        parsed.msg_type.toStr(),
                        parsed.sender_cid,
                        parsed.target_cid,
                        safe_payload,
                    },
                ) catch return;
                common.printStr(jout);
            } else {
                const out = std.fmt.bufPrint(
                    &out_buf,
                    "Whisper [{s}] CID {d} -> CID {d}: {s}\n",
                    .{
                        parsed.msg_type.toStr(),
                        parsed.sender_cid,
                        parsed.target_cid,
                        parsed.payload(),
                    },
                ) catch return;
                common.printStr(out);
            }
        },
    }
}

test "charter/whisper: Whisper Mesh consensus framing roundtrip" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    const raw = try formatWhisperFrame(&buf, .ratify, 2, 3, "sha256:abcdef");
    try testing.expectEqualStrings("whisper:v1:ratify:2:3:sha256:abcdef", raw);

    const parsed = try parseWhisperFrame(raw);
    try testing.expectEqual(WhisperMessageType.ratify, parsed.msg_type);
    try testing.expectEqual(@as(usize, 2), parsed.sender_cid);
    try testing.expectEqual(@as(usize, 3), parsed.target_cid);
    try testing.expectEqualStrings("sha256:abcdef", parsed.payload());
}
