// Audio Player for Diosix GUI Intro Chime
// Parses WAV file and streams PCM to Linux sound devices (/dev/dsp, /dev/snd/pcm*)
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;

pub const INTRO_WAV_BYTES: []const u8 = @embedFile("intro.wav");

pub const WavInfo = struct {
    channels: u16,
    sample_rate: u32,
    bits_per_sample: u16,
    byte_rate: u32,
    block_align: u16,
    data_offset: usize,
    data_length: usize,
};

pub fn parseWav(wav_bytes: []const u8) ?WavInfo {
    if (wav_bytes.len < 44) return null;
    if (!std.mem.eql(u8, wav_bytes[0..4], "RIFF")) return null;
    if (!std.mem.eql(u8, wav_bytes[8..12], "WAVE")) return null;

    var pos: usize = 12;
    var channels: u16 = 2;
    var sample_rate: u32 = 48000;
    var bits_per_sample: u16 = 16;
    var byte_rate: u32 = 192000;
    var block_align: u16 = 4;
    var data_offset: usize = 0;
    var data_length: usize = 0;
    var found_fmt = false;
    var found_data = false;

    while (pos + 8 <= wav_bytes.len) {
        const chunk_id = wav_bytes[pos .. pos + 4];
        const chunk_size = std.mem.readInt(u32, wav_bytes[pos + 4 .. pos + 8][0..4], .little);
        pos += 8;

        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            if (chunk_size < 16 or pos + 16 > wav_bytes.len) return null;
            // audio_format must be 1 (PCM)
            const audio_format = std.mem.readInt(u16, wav_bytes[pos .. pos + 2][0..2], .little);
            if (audio_format != 1) return null;
            channels = std.mem.readInt(u16, wav_bytes[pos + 2 .. pos + 4][0..2], .little);
            sample_rate = std.mem.readInt(u32, wav_bytes[pos + 4 .. pos + 8][0..4], .little);
            byte_rate = std.mem.readInt(u32, wav_bytes[pos + 8 .. pos + 12][0..4], .little);
            block_align = std.mem.readInt(u16, wav_bytes[pos + 12 .. pos + 14][0..2], .little);
            bits_per_sample = std.mem.readInt(u16, wav_bytes[pos + 14 .. pos + 16][0..2], .little);
            found_fmt = true;
            pos += chunk_size;
        } else if (std.mem.eql(u8, chunk_id, "data")) {
            data_offset = pos;
            data_length = @min(chunk_size, wav_bytes.len - pos);
            found_data = true;
            pos += chunk_size;
            break;
        } else {
            pos += chunk_size;
        }
    }

    if (!found_fmt or !found_data) return null;

    return WavInfo{
        .channels = channels,
        .sample_rate = sample_rate,
        .bits_per_sample = bits_per_sample,
        .byte_rate = byte_rate,
        .block_align = block_align,
        .data_offset = data_offset,
        .data_length = data_length,
    };
}

// OSS constants
const SNDCTL_DSP_RESET: u32 = 0x00005000;
const SNDCTL_DSP_SPEED: u32 = 0xc0045002;
const SNDCTL_DSP_CHANNELS: u32 = 0xc0045006;
const SNDCTL_DSP_SETFMT: u32 = 0xc0045005;
const AFMT_S16_LE: u32 = 0x00000010;

fn getMilliTimestamp() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

pub const AudioPlayer = struct {
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    playback_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    device_available: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn start(self: *AudioPlayer) void {
        self.stop_flag.store(false, .release);
        self.playback_started.store(false, .release);
        self.device_available.store(false, .release);

        const thread = std.Thread.spawn(.{}, audioWorker, .{self}) catch |err| {
            std.debug.print("AudioPlayer: Failed to spawn playback thread: {}\n", .{err});
            return;
        };
        self.thread = thread;
    }

    pub fn stop(self: *AudioPlayer) void {
        self.stop_flag.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn runAlsaInit() void {
        const bin: [*:0]const u8 = "/usr/sbin/diosix-alsa-init";
        const access_rc = linux.access(bin, linux.R_OK | linux.X_OK);
        if (@as(isize, @bitCast(access_rc)) < 0) return;

        const pid_res = linux.fork();
        const signed_pid: isize = @bitCast(pid_res);
        if (signed_pid == 0) {
            const argv = [_:null]?[*:0]const u8{ bin, null };
            const envp = [_:null]?[*:0]const u8{null};
            _ = linux.execve(bin, &argv, &envp);
            linux.exit(0);
        } else if (signed_pid > 0) {
            var status: i32 = 0;
            _ = linux.wait4(@intCast(signed_pid), &status, 0, null);
        }
    }

    fn audioWorker(self: *AudioPlayer) void {
        runAlsaInit();

        const info = parseWav(INTRO_WAV_BYTES) orelse {
            std.debug.print("AudioPlayer: Failed to parse intro.wav\n", .{});
            return;
        };

        const dsp_paths = [_][*:0]const u8{ "/dev/dsp", "/dev/dsp0", "/dev/sound/dsp" };
        var fd: i32 = -1;
        var attempts: usize = 0;

        while (attempts < 20 and !self.stop_flag.load(.acquire)) : (attempts += 1) {
            for (dsp_paths) |path| {
                const rc = linux.open(path, .{ .ACCMODE = .WRONLY }, 0);
                const signed_rc: isize = @bitCast(rc);
                if (signed_rc >= 0) {
                    fd = @intCast(signed_rc);
                    break;
                }
            }
            if (fd >= 0) break;
            var ts = linux.timespec{ .sec = 0, .nsec = 15_000_000 }; // 15 ms
            _ = linux.nanosleep(&ts, null);
        }

        if (fd < 0) {
            std.debug.print("AudioPlayer: Could not open audio device after {d} attempts.\n", .{attempts});
            self.device_available.store(false, .release);
            return;
        }
        defer _ = linux.close(fd);

        self.device_available.store(true, .release);

        // Configure OSS: 16-bit little endian, stereo, 48000 Hz
        var fmt: u32 = AFMT_S16_LE;
        _ = linux.ioctl(fd, SNDCTL_DSP_SETFMT, @intFromPtr(&fmt));
        var ch: u32 = @intCast(info.channels);
        _ = linux.ioctl(fd, SNDCTL_DSP_CHANNELS, @intFromPtr(&ch));
        var spd: u32 = info.sample_rate;
        _ = linux.ioctl(fd, SNDCTL_DSP_SPEED, @intFromPtr(&spd));

        // Stream PCM data in chunks with real-time clock pacing
        const pcm_raw = INTRO_WAV_BYTES[info.data_offset .. info.data_offset + info.data_length];
        const bytes_per_sample = info.bits_per_sample / 8;
        const total_samples = info.data_length / (info.channels * bytes_per_sample);

        std.debug.print("AudioPlayer: Opened audio device (fd {d}). Streaming {d}Hz {d}ch PCM ({d} samples)...\n", .{ fd, info.sample_rate, info.channels, total_samples });

        self.playback_started.store(true, .release);

        // 16-bit conversion buffer (4096 stereo samples per chunk = 16384 bytes)
        var chunk_buf: [16384]u8 = undefined;
        const chunk_samples: usize = chunk_buf.len / (info.channels * 2);

        const stream_start_ms = getMilliTimestamp();
        var sample_idx: usize = 0;
        while (sample_idx < total_samples and !self.stop_flag.load(.acquire)) {
            // Real-time Clock Pacing: Maintain ~200ms of buffer ahead of real-time playback
            const scheduled_ms = @as(i64, @intCast((sample_idx * 1000) / info.sample_rate));
            const now_ms = getMilliTimestamp() - stream_start_ms;
            if (scheduled_ms > now_ms + 200) {
                const sleep_ms = @as(u64, @intCast(scheduled_ms - (now_ms + 200)));
                var ts = linux.timespec{
                    .sec = @intCast(sleep_ms / 1000),
                    .nsec = @intCast((sleep_ms % 1000) * 1_000_000),
                };
                _ = linux.nanosleep(&ts, null);
                if (self.stop_flag.load(.acquire)) break;
            }

            const count = @min(chunk_samples, total_samples - sample_idx);
            var out_idx: usize = 0;

            var i: usize = 0;
            while (i < count) : (i += 1) {
                var c: usize = 0;
                while (c < info.channels) : (c += 1) {
                    const src_offset = (sample_idx + i) * (info.channels * bytes_per_sample) + c * bytes_per_sample;
                    var s16: i16 = 0;
                    if (bytes_per_sample == 3) {
                        // 24-bit PCM: read 3 bytes signed LE, take top 16 bits
                        const b0 = @as(u32, pcm_raw[src_offset + 0]);
                        const b1 = @as(u32, pcm_raw[src_offset + 1]);
                        const b2 = @as(u32, pcm_raw[src_offset + 2]);
                        const sign_ext: u32 = if ((b2 & 0x80) != 0) 0xFF000000 else 0;
                        const val24: i32 = @bitCast((b0 | (b1 << 8) | (b2 << 16)) | sign_ext);
                        s16 = @intCast(val24 >> 8);
                    } else if (bytes_per_sample == 2) {
                        s16 = std.mem.readInt(i16, pcm_raw[src_offset .. src_offset + 2][0..2], .little);
                    }
                    std.mem.writeInt(i16, chunk_buf[out_idx .. out_idx + 2][0..2], s16, .little);
                    out_idx += 2;
                }
            }

            var written: usize = 0;
            while (written < out_idx and !self.stop_flag.load(.acquire)) {
                const write_res = linux.write(fd, chunk_buf[written..out_idx].ptr, out_idx - written);
                const signed_w: isize = @bitCast(write_res);
                if (signed_w <= 0) {
                    const e_again: isize = -@as(isize, @intFromEnum(linux.E.AGAIN));
                    const e_intr: isize = -@as(isize, @intFromEnum(linux.E.INTR));
                    if (signed_w == e_again or signed_w == e_intr) {
                        var ts = linux.timespec{ .sec = 0, .nsec = 5_000_000 };
                        _ = linux.nanosleep(&ts, null);
                        continue;
                    }
                    break;
                }
                written += @intCast(signed_w);
            }
            if (written == 0) break;

            sample_idx += count;
        }

        // Drain protection: Allow the tail buffer to finish playing in real-time before closing fd
        const total_audio_ms = @as(i64, @intCast((sample_idx * 1000) / info.sample_rate));
        while (!self.stop_flag.load(.acquire)) {
            const elapsed = getMilliTimestamp() - stream_start_ms;
            if (elapsed >= total_audio_ms) break;
            var ts = linux.timespec{ .sec = 0, .nsec = 25_000_000 }; // 25ms sleep
            _ = linux.nanosleep(&ts, null);
        }

        std.debug.print("AudioPlayer: Stream completed ({d}/{d} samples streamed, {d}ms).\n", .{ sample_idx, total_samples, getMilliTimestamp() - stream_start_ms });
    }
};

test "audio: parse intro.wav metadata" {
    const info = parseWav(INTRO_WAV_BYTES);
    try std.testing.expect(info != null);
    const w = info.?;
    try std.testing.expectEqual(@as(u16, 2), w.channels);
    try std.testing.expectEqual(@as(u32, 48000), w.sample_rate);
    try std.testing.expectEqual(@as(u16, 24), w.bits_per_sample);
    try std.testing.expect(w.data_length > 4_000_000);
}
