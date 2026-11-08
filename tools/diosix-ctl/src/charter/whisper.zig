// Whisper Mesh BFT Consensus Framing & CLI Handler.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
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

/// Maximum Whisper payload carried in a frame. This is a fixed field width of
/// the Whisper wire format, so longer payloads are truncated when parsed.
pub const WHISPER_PAYLOAD_MAX: usize = 128;
pub const MAX_WHISPER_FRAME_BYTES: usize = 1536;
const ASCII_PRINTABLE_MIN: u8 = 0x20;
const ASCII_DEL: u8 = 0x7f;

pub const WhisperFrame = struct {
    msg_type: WhisperMessageType,
    sender_cid: usize,
    target_cid: usize,
    payload_buf: [WHISPER_PAYLOAD_MAX]u8 = @splat(0),
    payload_len: usize = 0,

    pub fn payload(self: *const WhisperFrame) []const u8 {
        return self.payload_buf[0..self.payload_len];
    }
};

/// Format a deterministic Whisper Mesh consensus frame
/// (`whisper:v1:<type>:<sender_cid>:<target_cid>:<payload>`). The caller owns
/// the returned slice.
pub fn formatWhisperFrame(
    allocator: std.mem.Allocator,
    msg_type: WhisperMessageType,
    sender_cid: usize,
    target_cid: usize,
    payload_str: []const u8,
) ![]u8 {
    for (payload_str) |c| {
        if (c < ASCII_PRINTABLE_MIN or c == ASCII_DEL) {
            return error.InvalidWhisperPayload;
        }
    }
    return allocator.print("whisper:v1:{s}:{d}:{d}:{s}", .{
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
    const allocator = std.heap.page_allocator;
    var w_op: WhisperOp = .recv;
    if (arg_start < args.len) {
        const s = std.mem.span(args[arg_start]);
        if (!std.mem.startsWith(u8, s, "-")) {
            w_op = std.meta.stringToEnum(WhisperOp, s) orelse .recv;
        }
    }
    switch (w_op) {
        .send => {
            var client = api.DiosixClient.init();
            defer client.deinit();
            var sender_cid: usize = if (client.getInfo(1)) |info|
                (if (info.assigned_cid >= 2) info.assigned_cid else 2)
            else |_|
                2;
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

            const frame = formatWhisperFrame(
                allocator,
                msg_type,
                sender_cid,
                target_cid,
                payload,
            ) catch |err| {
                switch (err) {
                    error.InvalidWhisperPayload => common.printStr(
                        "Error: Whisper payload contains control " ++
                            "characters.\n",
                    ),
                    else => common.printApiError("Whisper send", err),
                }
                return;
            };
            defer {
                std.crypto.secureZero(u8, frame);
                allocator.free(frame);
            }
            if (client.dev_fd != null) {
                _ = client.whisperSend(target_cid, frame) catch {};
            }
            if (json_mode) {
                // Sanitizing only drops bytes, so the frame length bounds it.
                const safe_buf = allocator.alloc(u8, frame.len) catch |err| {
                    common.printApiError("Whisper send", err);
                    return;
                };
                defer allocator.free(safe_buf);
                const safe_frame = common.sanitizeJsonStr(safe_buf, frame);
                common.printFmt(
                    "{{\"status\":\"formatted\",\"frame\":\"{s}\"}}\n",
                    .{safe_frame},
                );
            } else {
                common.printFmt("✓ Whisper frame: {s}\n", .{frame});
            }
        },
        .recv => {
            var client = api.DiosixClient.init();
            defer client.deinit();
            const rx_buf = allocator.alloc(u8, MAX_WHISPER_FRAME_BYTES) catch {
                common.printStr("Error: Out of memory receiving Whisper.\n");
                return;
            };
            defer {
                std.crypto.secureZero(u8, rx_buf);
                allocator.free(rx_buf);
            }
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
            if (raw_frame.len == 0 and client.dev_fd != null) {
                const n = client.whisperRecv(rx_buf) catch 0;
                if (n > 0) raw_frame = rx_buf[0..n];
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
            if (json_mode) {
                // Sanitizing only drops bytes, so the payload length bounds it.
                const safe_buf = allocator.alloc(
                    u8,
                    parsed.payload().len,
                ) catch |err| {
                    common.printApiError("Whisper receive", err);
                    return;
                };
                defer allocator.free(safe_buf);
                const safe_payload = common.sanitizeJsonStr(
                    safe_buf,
                    parsed.payload(),
                );
                common.printFmt(
                    "{{\"status\":\"received\",\"type\":\"{s}\"," ++
                        "\"sender_cid\":{d},\"target_cid\":{d}," ++
                        "\"payload\":\"{s}\"}}\n",
                    .{
                        parsed.msg_type.toStr(),
                        parsed.sender_cid,
                        parsed.target_cid,
                        safe_payload,
                    },
                );
            } else {
                common.printFmt(
                    "Whisper [{s}] CID {d} -> CID {d}: {s}\n",
                    .{
                        parsed.msg_type.toStr(),
                        parsed.sender_cid,
                        parsed.target_cid,
                        parsed.payload(),
                    },
                );
            }
        },
    }
}

test "charter/whisper: Whisper Mesh consensus framing roundtrip" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const raw = try formatWhisperFrame(
        testing.allocator,
        .ratify,
        2,
        3,
        "sha256:abcdef",
    );
    defer testing.allocator.free(raw);
    try testing.expectEqualStrings("whisper:v1:ratify:2:3:sha256:abcdef", raw);

    const parsed = try parseWhisperFrame(raw);
    try testing.expectEqual(WhisperMessageType.ratify, parsed.msg_type);
    try testing.expectEqual(@as(usize, 2), parsed.sender_cid);
    try testing.expectEqual(@as(usize, 3), parsed.target_cid);
    try testing.expectEqualStrings("sha256:abcdef", parsed.payload());
}

test "charter/whisper: control characters in payloads are rejected" {
    const result = formatWhisperFrame(
        std.testing.allocator,
        .heartbeat,
        2,
        3,
        "bad\npayload",
    );
    try std.testing.expectError(error.InvalidWhisperPayload, result);
}
