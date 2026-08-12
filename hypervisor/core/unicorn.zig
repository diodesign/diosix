// Unicorn Engine C API bindings and standard library glue.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("arch/riscv64/riscv.zig");
const atomic = @import("atomic.zig");
const debug = @import("debug.zig");
const pcore = @import("pcore.zig");

// Global lock to protect allocator operations across harts
var allocator_lock = atomic.NamedSpinLock.init("Unicorn Allocator Lock");

pub const TpGuard = struct {
    saved_tp: usize = 0,
    swapped: bool = false,

    pub fn init() TpGuard {
        if (comptime @import("builtin").is_test) return .{};
        var current: usize = undefined;
        asm volatile (
            \\mv %[current], tp
            : [current] "=r" (current),
        );
        if (riscv.isHostTp(current)) {
            return .{ .saved_tp = current, .swapped = false };
        } else {
            const host_tp = riscv.readSscratch();
            asm volatile (
                \\mv tp, %[host_tp]
                :
                : [host_tp] "r" (host_tp),
            );
            return .{ .saved_tp = current, .swapped = true };
        }
    }

    pub fn deinit(self: TpGuard) void {
        if (comptime @import("builtin").is_test) return;
        if (self.swapped) {
            asm volatile (
                \\mv tp, %[saved]
                :
                : [saved] "r" (self.saved_tp),
            );
        }
    }
};

const vcore = @import("vcore.zig");

pub const UCTpGuard = struct {
    saved_tp: usize = 0,
    pub fn init() UCTpGuard {
        if (comptime @import("builtin").is_test) return .{};
        var saved_tp: usize = undefined;
        var caller_ra: usize = undefined;
        asm volatile (
            \\mv %[saved], tp
            \\mv %[ra], ra
            : [saved] "=r" (saved_tp),
              [ra] "=r" (caller_ra),
        );
        const cpu = riscv.getCPUContext();
        if (cpu.active_vcore) |vc_raw| {
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
            riscv.writeSscratch(saved_tp);
            const tls = vc.exec_path.emulated.tls_pointer;
            if (tls != 0) {
                asm volatile (
                    \\mv tp, %[tls]
                    :
                    : [tls] "r" (tls),
                );
            }
        }
        return .{ .saved_tp = saved_tp };
    }
    pub fn deinit(self: UCTpGuard) void {
        if (comptime @import("builtin").is_test) return;
        asm volatile (
            \\mv tp, %[saved]
            :
            : [saved] "r" (self.saved_tp),
        );
    }
};

inline fn getSModeCPUContext() *riscv.CpuContext {
    return riscv.getCPUContext();
}

pub inline fn readSModeTime() u64 {
    return riscv.readTime();
}

// Mock TLS buffer
var tls_buffer: [8192]u8 = undefined;

// Standard C Allocation Header
const MallocHeader = struct {
    cpu_core_id: usize,
    size: usize,
};

// Export standard C memory allocation symbols for Unicorn to link against
pub export fn free(ptr: ?*anyopaque) callconv(.c) void {
    const p = ptr orelse return;

    if (@intFromPtr(p) % 16 != 0) return;

    const guard = TpGuard.init();
    defer guard.deinit();

    const lock_mstatus = allocator_lock.lock();
    defer allocator_lock.unlock(lock_mstatus);

    const header = @as(*align(1) MallocHeader, @ptrFromInt(@intFromPtr(p) - @sizeOf(MallocHeader)));
    if (header.cpu_core_id == std.math.maxInt(usize)) {
        const physmem = @import("physmem.zig");
        physmem.freePage(@intFromPtr(header));
        return;
    }

    if (header.cpu_core_id >= riscv.cpu_contexts.len) {
        return;
    }

    const cpu = riscv.cpu_contexts[header.cpu_core_id] orelse return;

    const slice = @as([*]u8, @ptrFromInt(@intFromPtr(header)))[0..(@sizeOf(MallocHeader) + header.size)];
    cpu.allocator.allocator().free(slice);
}

pub export fn malloc(size: usize) callconv(.c) ?*anyopaque {
    if (size == 0) return null;

    const guard = TpGuard.init();
    defer guard.deinit();

    const alloc_size = size + @sizeOf(MallocHeader);

    const physmem = @import("physmem.zig");
    // Calculate the buddy allocator order needed for this allocation size.
    // We round up to the nearest page size, then find the power of 2.
    const num_pages = (alloc_size + 4095) / 4096;
    const order = std.math.log2_int_ceil(usize, num_pages);

    if (physmem.allocPageSelection(order)) |phys_addr| {
        // Zero-fill the entire allocated block to ensure TCG structures are clean.
        const total_bytes = (@as(usize, 1) << @intCast(order)) * 4096;
        const dest = @as([*]u8, @ptrFromInt(phys_addr))[0..total_bytes];
        @memset(dest, 0);

        const header = @as(*MallocHeader, @ptrFromInt(phys_addr));
        header.* = .{
            .size = size,
            .cpu_core_id = std.math.maxInt(usize),
        };
        return @ptrFromInt(phys_addr + @sizeOf(MallocHeader));
    } else |_| {
        return null;
    }
}

pub export fn realloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    if (ptr == null) return malloc(size);
    if (size == 0) {
        free(ptr);
        return null;
    }

    const guard = TpGuard.init();
    defer guard.deinit();

    const p = ptr orelse return null;
    if (@intFromPtr(p) % 16 != 0) {
        return malloc(size);
    }

    const realloc_mstatus = allocator_lock.lock();
    const header = @as(*align(1) MallocHeader, @ptrFromInt(@intFromPtr(p) - @sizeOf(MallocHeader)));
    if (header.cpu_core_id >= riscv.cpu_contexts.len and header.cpu_core_id != std.math.maxInt(usize)) {
        allocator_lock.unlock(realloc_mstatus);
        return malloc(size);
    }
    const old_size = header.size;
    allocator_lock.unlock(realloc_mstatus);

    if (size <= old_size) return ptr;

    const new_ptr = malloc(size) orelse return null;
    @memcpy(@as([*]u8, @ptrCast(new_ptr))[0..old_size], @as([*]const u8, @ptrCast(ptr.?))[0..old_size]);
    free(ptr);
    return new_ptr;
}

pub export fn calloc(num: usize, size: usize) callconv(.c) ?*anyopaque {
    const total = num * size;
    const ptr = malloc(total) orelse return null;

    @memset(@as([*]u8, @ptrCast(ptr))[0..total], 0);
    return ptr;
}

// Export standard assertions and print redirection for debug purposes
pub export fn __assert_fail(assertion: [*:0]const u8, file: [*:0]const u8, line: c_uint, function: [*:0]const u8) callconv(.c) noreturn {
    const ra = riscv.readRA();
    const guard = TpGuard.init();
    _ = guard;
    debug.printf("Assertion failed: {s} ({s}:{d}: {s}), ra=0x{x}\n", .{ assertion, file, line, function, ra });
    while (true) {}
}

pub export fn abort() callconv(.c) noreturn {
    const ra = riscv.readRA();
    const guard = TpGuard.init();
    _ = guard;
    debug.printf("Unicorn called abort(), ra=0x{x}\n", .{ra});
    while (true) {}
}

fn printVa(format: [*:0]const u8, ap: *std.builtin.VaList) callconv(.c) void {
    const fmt = std.mem.span(format);
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '%') {
            i += 1;
            if (i >= fmt.len) break;
            switch (fmt[i]) {
                '%' => debug.putchar('%'),
                's' => {
                    const s = @cVaArg(ap, [*:0]const u8);
                    debug.printf("{s}", .{s});
                },
                'd', 'i' => {
                    const d = @cVaArg(ap, c_int);
                    debug.printf("{d}", .{d});
                },
                'x' => {
                    const x = @cVaArg(ap, c_uint);
                    debug.printf("{x}", .{x});
                },
                'p' => {
                    const p = @cVaArg(ap, ?*anyopaque);
                    debug.printf("{?}", .{p});
                },
                'c' => {
                    const c = @cVaArg(ap, c_int);
                    debug.putchar(@intCast(c));
                },
                else => {
                    debug.putchar('%');
                    debug.putchar(fmt[i]);
                },
            }
        } else {
            debug.putchar(fmt[i]);
        }
        i += 1;
    }
}

pub export fn printf(format: [*:0]const u8, ...) callconv(.c) c_int {
    const guard = TpGuard.init();
    defer guard.deinit();
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    printVa(format, &ap);
    return 0;
}

pub export fn fprintf(stream: ?*anyopaque, format: [*:0]const u8, ...) callconv(.c) c_int {
    const guard = TpGuard.init();
    defer guard.deinit();
    _ = stream;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    printVa(format, &ap);
    return 0;
}

pub export fn usleep(usec: c_uint) callconv(.c) c_int {
    const guard = TpGuard.init();
    defer guard.deinit();
    debug.printf("unicorn_glue: usleep({d})\n", .{usec});
    const start = readSModeTime();
    // 10MHz frequency means 10 ticks per microsecond
    const ticks = @as(u64, usec) * 10;
    while (readSModeTime() - start < ticks) {}
    return 0;
}

pub export fn clock_gettime(clk_id: c_int, tp: ?*anyopaque) callconv(.c) c_int {
    const guard = TpGuard.init();
    defer guard.deinit();
    _ = clk_id;
    const TimeSpec = struct {
        tv_sec: i64,
        tv_nsec: i64,
    };
    const t = @as(*align(1) TimeSpec, @ptrCast(tp orelse return -1));
    const time_ticks = readSModeTime();
    // 10MHz frequency means 1 tick = 100ns
    const total_ns = time_ticks * 100;
    t.tv_sec = @as(i64, @intCast(total_ns / 1_000_000_000));
    t.tv_nsec = @as(i64, @intCast(total_ns % 1_000_000_000));
    return 0;
}

pub export fn gettimeofday(tv: ?*anyopaque, tz: ?*anyopaque) callconv(.c) c_int {
    const guard = TpGuard.init();
    defer guard.deinit();
    _ = tz;
    const TimeVal = struct {
        tv_sec: i64,
        tv_usec: i64,
    };
    const t = @as(*align(1) TimeVal, @ptrCast(tv orelse return -1));
    const time_ticks = readSModeTime();
    // 10MHz frequency means 10 ticks per microsecond
    const total_us = time_ticks / 10;
    t.tv_sec = @as(i64, @intCast(total_us / 1_000_000));
    t.tv_usec = @as(i64, @intCast(total_us % 1_000_000));
    return 0;
}

pub export fn __tls_get_addr(ti: ?*anyopaque) callconv(.c) ?*anyopaque {
    const guard = TpGuard.init();
    defer guard.deinit();
    const TlsIdx = struct {
        module: usize,
        offset: usize,
    };
    const idx = @as(*align(1) const TlsIdx, @ptrCast(ti orelse return null));
    return &tls_buffer[idx.offset % 8192];
}

pub export fn getpid() callconv(.c) c_int {
    return 1;
}

pub export fn getppid() callconv(.c) c_int {
    return 1;
}

pub export fn getpagesize() callconv(.c) c_int {
    return 4096;
}

pub export fn posix_memalign(memptr: ?*?*anyopaque, alignment: usize, size: usize) callconv(.c) c_int {
    const guard = TpGuard.init();
    defer guard.deinit();
    _ = alignment;
    const ptr = malloc(size);
    if (ptr == null) return 12; // ENOMEM
    memptr.?.* = ptr;
    return 0;
}

pub export fn sprintf(str: [*:0]u8, format: [*:0]const u8, ...) callconv(.c) c_int {
    const guard = TpGuard.init();
    defer guard.deinit();
    var ap = @cVaStart();
    defer @cVaEnd(&ap);

    const fmt = std.mem.span(format);
    if (std.mem.eql(u8, fmt, "D%d") or std.mem.eql(u8, fmt, "A%d")) {
        const val = @cVaArg(&ap, c_int);
        const prefix = format[0];
        const res = std.fmt.bufPrint(str[0..16], "{c}{d}", .{ prefix, val }) catch return -1;
        str[res.len] = 0;
        return @intCast(res.len);
    } else if (std.mem.eql(u8, fmt, "ACC%d")) {
        const val = @cVaArg(&ap, c_int);
        const res = std.fmt.bufPrint(str[0..16], "ACC{d}", .{val}) catch return -1;
        str[res.len] = 0;
        return @intCast(res.len);
    }
    str[0] = 0;
    return 0;
}

pub export fn qsort(base: ?*anyopaque, nitems: usize, size: usize, compar: ?*const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int) callconv(.c) void {
    if (base == null or nitems <= 1 or size == 0 or compar == null) return;
    const cmp = compar.?;
    const ptr = @as([*]u8, @ptrCast(base.?));

    var i: usize = 0;
    while (i < nitems - 1) : (i += 1) {
        var j: usize = 0;
        while (j < nitems - 1 - i) : (j += 1) {
            const elem1 = ptr + (j * size);
            const elem2 = ptr + ((j + 1) * size);
            if (cmp(elem1, elem2) > 0) {
                var k: usize = 0;
                while (k < size) : (k += 1) {
                    const temp = elem1[k];
                    elem1[k] = elem2[k];
                    elem2[k] = temp;
                }
            }
        }
    }
}

pub export fn pow(x: f64, y: f64) callconv(.c) f64 {
    _ = x;
    _ = y;
    return 0.0;
}

pub export fn atan2(y: f64, x: f64) callconv(.c) f64 {
    _ = y;
    _ = x;
    return 0.0;
}

pub export fn pthread_exit(retval: ?*anyopaque) callconv(.c) noreturn {
    _ = retval;
    while (true) {}
}

pub export fn pthread_join(thread: usize, retval: ?*?*anyopaque) callconv(.c) c_int {
    _ = thread;
    _ = retval;
    debug.printf("unicorn_glue: pthread_join called\n", .{});
    return 0;
}

pub export var stdout: ?*anyopaque = null;

pub export fn fflush(stream: ?*anyopaque) callconv(.c) c_int {
    _ = stream;
    return 0;
}

pub export fn raise(sig: c_int) callconv(.c) c_int {
    _ = sig;
    return 0;
}

pub export fn strncmp(s1: [*:0]const u8, s2: [*:0]const u8, n: usize) callconv(.c) c_int {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c1 = s1[i];
        const c2 = s2[i];
        if (c1 != c2 or c1 == 0) {
            return @as(c_int, c1) - @as(c_int, c2);
        }
    }
    return 0;
}

pub export fn fopen(filename: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*anyopaque {
    _ = filename;
    _ = mode;
    return null;
}

pub export fn setvbuf(stream: ?*anyopaque, buf: ?[*]u8, mode: c_int, size: usize) callconv(.c) c_int {
    _ = stream;
    _ = buf;
    _ = mode;
    _ = size;
    return 0;
}

pub export fn fread(ptr: ?*anyopaque, size: usize, nmemb: usize, stream: ?*anyopaque) callconv(.c) usize {
    _ = ptr;
    _ = size;
    _ = nmemb;
    _ = stream;
    return 0;
}

pub export fn fclose(stream: ?*anyopaque) callconv(.c) c_int {
    _ = stream;
    return 0;
}

// Bindings to Unicorn Engine C API
pub const uc_err = enum(c_int) {
    UC_ERR_OK = 0,
    UC_ERR_NOMEM,
    UC_ERR_ARCH,
    UC_ERR_HANDLE,
    UC_ERR_MODE,
    UC_ERR_VERSION,
    UC_ERR_READ_UNMAPPED,
    UC_ERR_WRITE_UNMAPPED,
    UC_ERR_FETCH_UNMAPPED,
    UC_ERR_HOOK,
    UC_ERR_INSN_INVALID,
    UC_ERR_MAP,
    UC_ERR_WRITE_PROT,
    UC_ERR_READ_PROT,
    UC_ERR_FETCH_PROT,
    UC_ERR_ARG,
    UC_ERR_READ_UNALIGNED,
    UC_ERR_WRITE_UNALIGNED,
    UC_ERR_FETCH_UNALIGNED,
    UC_ERR_HOOK_EXIST,
    UC_ERR_RESOURCE,
    UC_ERR_EXCEPTION,
};

pub const uc_arch = enum(c_int) {
    UC_ARCH_ARM = 1,
    UC_ARCH_ARM64,
    UC_ARCH_MIPS,
    UC_ARCH_X86,
    UC_ARCH_PPC,
    UC_ARCH_SPARC,
    UC_ARCH_M68K,
    UC_ARCH_RISCV,
    UC_ARCH_S390X,
    UC_ARCH_TRICORE,
    UC_ARCH_MAX,
};

pub const uc_mode = c_int;
pub const UC_MODE_LITTLE_ENDIAN: uc_mode = 0;
pub const UC_MODE_BIG_ENDIAN: uc_mode = 1 << 30;
pub const UC_MODE_ARM: uc_mode = 0;
pub const UC_MODE_16: uc_mode = 1 << 1;
pub const UC_MODE_32: uc_mode = 1 << 2;
pub const UC_MODE_64: uc_mode = 1 << 3;
pub const UC_MODE_RISCV32: uc_mode = 1 << 2;
pub const UC_MODE_RISCV64: uc_mode = 1 << 3;

pub const uc_mem_type = enum(c_int) {
    UC_MEM_READ = 16,
    UC_MEM_WRITE,
    UC_MEM_FETCH,
    UC_MEM_READ_UNMAPPED,
    UC_MEM_WRITE_UNMAPPED,
    UC_MEM_FETCH_UNMAPPED,
    UC_MEM_WRITE_PROT,
    UC_MEM_READ_PROT,
    UC_MEM_FETCH_PROT,
    UC_MEM_READ_AFTER,
};

pub const uc_prot = struct {
    pub const UC_PROT_NONE = 0;
    pub const UC_PROT_READ = 1;
    pub const UC_PROT_WRITE = 2;
    pub const UC_PROT_EXEC = 4;
    pub const UC_PROT_ALL = 7;
};

// Register IDs for Unicorn Engine targets
pub const uc_riscv_reg = enum(c_int) {
    UC_RISCV_REG_INVALID = 0,
    UC_RISCV_REG_X0,
    UC_RISCV_REG_X1,
    UC_RISCV_REG_X2,
    UC_RISCV_REG_X3,
    UC_RISCV_REG_X4,
    UC_RISCV_REG_X5,
    UC_RISCV_REG_X6,
    UC_RISCV_REG_X7,
    UC_RISCV_REG_X8,
    UC_RISCV_REG_X9,
    UC_RISCV_REG_X10,
    UC_RISCV_REG_X11,
    UC_RISCV_REG_X12,
    UC_RISCV_REG_X13,
    UC_RISCV_REG_X14,
    UC_RISCV_REG_X15,
    UC_RISCV_REG_X16,
    UC_RISCV_REG_X17,
    UC_RISCV_REG_X18,
    UC_RISCV_REG_X19,
    UC_RISCV_REG_X20,
    UC_RISCV_REG_X21,
    UC_RISCV_REG_X22,
    UC_RISCV_REG_X23,
    UC_RISCV_REG_X24,
    UC_RISCV_REG_X25,
    UC_RISCV_REG_X26,
    UC_RISCV_REG_X27,
    UC_RISCV_REG_X28,
    UC_RISCV_REG_X29,
    UC_RISCV_REG_X30,
    UC_RISCV_REG_X31,
    UC_RISCV_REG_PC = 190,
    UC_RISCV_REG_PRIV = 191,
};

pub const uc_arm64_reg = enum(c_int) {
    UC_ARM64_REG_INVALID = 0,
    // X29 and X30 come first in Unicorn's enum (before general-purpose X0-X28).
    UC_ARM64_REG_X29 = 1, // FP
    UC_ARM64_REG_X30 = 2, // LR
    UC_ARM64_REG_NZCV = 3,
    UC_ARM64_REG_SP = 4,
    // General-purpose registers X0-X28 start at 199.
    UC_ARM64_REG_X0 = 199,
    UC_ARM64_REG_X1 = 200,
    UC_ARM64_REG_X2 = 201,
    UC_ARM64_REG_X3 = 202,
    UC_ARM64_REG_X4 = 203,
    UC_ARM64_REG_X5 = 204,
    UC_ARM64_REG_X6 = 205,
    UC_ARM64_REG_X7 = 206,
    UC_ARM64_REG_X8 = 207,
    UC_ARM64_REG_X9 = 208,
    UC_ARM64_REG_X10 = 209,
    UC_ARM64_REG_X11 = 210,
    UC_ARM64_REG_X12 = 211,
    UC_ARM64_REG_X13 = 212,
    UC_ARM64_REG_X14 = 213,
    UC_ARM64_REG_X15 = 214,
    UC_ARM64_REG_X16 = 215,
    UC_ARM64_REG_X17 = 216,
    UC_ARM64_REG_X18 = 217,
    UC_ARM64_REG_X19 = 218,
    UC_ARM64_REG_X20 = 219,
    UC_ARM64_REG_X21 = 220,
    UC_ARM64_REG_X22 = 221,
    UC_ARM64_REG_X23 = 222,
    UC_ARM64_REG_X24 = 223,
    UC_ARM64_REG_X25 = 224,
    UC_ARM64_REG_X26 = 225,
    UC_ARM64_REG_X27 = 226,
    UC_ARM64_REG_X28 = 227,
    // Program counter and system registers.
    UC_ARM64_REG_PC = 260,
    UC_ARM64_REG_CPACR_EL1 = 261,
    UC_ARM64_REG_TPIDR_EL0 = 263,
    UC_ARM64_REG_TPIDRRO_EL0 = 264,
    UC_ARM64_REG_TPIDR_EL1 = 265,
    UC_ARM64_REG_PSTATE = 266,
    UC_ARM64_REG_ELR_EL0 = 268,
    UC_ARM64_REG_ELR_EL1 = 269,
    UC_ARM64_REG_ELR_EL2 = 270,
    UC_ARM64_REG_ELR_EL3 = 271,
    UC_ARM64_REG_SP_EL0 = 273,
    UC_ARM64_REG_SP_EL1 = 274,
    UC_ARM64_REG_SP_EL2 = 275,
    UC_ARM64_REG_SP_EL3 = 276,
    UC_ARM64_REG_TTBR0_EL1 = 278,
    UC_ARM64_REG_TTBR1_EL1 = 279,
    UC_ARM64_REG_ESR_EL0 = 280,
    UC_ARM64_REG_ESR_EL1 = 281,
    UC_ARM64_REG_ESR_EL2 = 282,
    UC_ARM64_REG_ESR_EL3 = 283,
    UC_ARM64_REG_FAR_EL0 = 284,
    UC_ARM64_REG_FAR_EL1 = 285,
    UC_ARM64_REG_FAR_EL2 = 286,
    UC_ARM64_REG_FAR_EL3 = 287,
    UC_ARM64_REG_MAIR_EL1 = 289,
    UC_ARM64_REG_VBAR_EL0 = 290,
    UC_ARM64_REG_VBAR_EL1 = 291,
    UC_ARM64_REG_VBAR_EL2 = 292,
    UC_ARM64_REG_VBAR_EL3 = 293,
    // Coprocessor register access (for timer regs via UC_ARM64_REG_CP_REG).
    UC_ARM64_REG_CP_REG = 294,
    UC_ARM64_REG_FPCR = 295,
    UC_ARM64_REG_FPSR = 296,
};

// Matches C typedef: uc_arm64_cp_reg { uint32_t crn, crm, op0, op1, op2; uint64_t val; }
pub const uc_arm64_cp_reg = extern struct {
    crn: u32 = 0,
    crm: u32 = 0,
    op0: u32 = 0,
    op1: u32 = 0,
    op2: u32 = 0,
    val: u64 = 0,
};

pub const uc_x86_reg = enum(c_int) {
    UC_X86_REG_INVALID = 0,
    UC_X86_REG_RAX = 35,
    UC_X86_REG_RBP = 36,
    UC_X86_REG_RBX = 37,
    UC_X86_REG_RCX = 38,
    UC_X86_REG_RDI = 39,
    UC_X86_REG_RDX = 40,
    UC_X86_REG_RIP = 41,
    UC_X86_REG_RSI = 43,
    UC_X86_REG_RSP = 44,
    UC_X86_REG_CR0 = 50,
    UC_X86_REG_CR2 = 52,
    UC_X86_REG_CR3 = 53,
    UC_X86_REG_CR4 = 54,
    UC_X86_REG_R8 = 106,
    UC_X86_REG_R9 = 107,
    UC_X86_REG_R10 = 108,
    UC_X86_REG_R11 = 109,
    UC_X86_REG_R12 = 110,
    UC_X86_REG_R13 = 111,
    UC_X86_REG_R14 = 112,
    UC_X86_REG_R15 = 113,
    UC_X86_REG_CS = 11,
    UC_X86_REG_SS = 49,
    UC_X86_REG_DS = 17,
    UC_X86_REG_ES = 28,
    UC_X86_REG_FS = 32,
    UC_X86_REG_GS = 33,
    UC_X86_REG_EFLAGS = 25,
    UC_X86_REG_IDTR = 242,
    UC_X86_REG_GDTR = 243,
    UC_X86_REG_LDTR = 244,
    UC_X86_REG_TR = 245,
    UC_X86_REG_MSR = 248,
    UC_X86_REG_FS_BASE = 250,
    UC_X86_REG_GS_BASE = 251,
};

pub const uc_x86_mmr = extern struct {
    selector: u16 = 0,
    base: u64 = 0,
    limit: u32 = 0,
    flags: u32 = 0,
};

pub const uc_x86_msr = extern struct {
    rid: u32,
    value: u64,
};

// Raw C API function prototypes linked from libunicorn.a
const is_test = @import("builtin").is_test;
const raw_uc_version = if (is_test) struct {
    fn impl(major: ?*c_int, minor: ?*c_int) callconv(.c) c_uint {
        _ = major; _ = minor; return 0;
    }
}.impl else struct {
    pub extern fn uc_version(major: ?*c_int, minor: ?*c_int) c_uint;
}.uc_version;

pub fn uc_version(major: ?*c_int, minor: ?*c_int) c_uint {
    const guard = UCTpGuard.init();
    defer guard.deinit();
    return raw_uc_version(major, minor);
}

const raw_uc_open = if (is_test) struct {
    fn impl(arch: uc_arch, mode: uc_mode, engine: *?*anyopaque) callconv(.c) uc_err {
        _ = arch; _ = mode; _ = engine; return .UC_ERR_OK;
    }
}.impl else struct {
    extern fn uc_open(arch: uc_arch, mode: uc_mode, engine: *?*anyopaque) uc_err;
}.uc_open;

pub fn uc_open(arch: uc_arch, mode: uc_mode, engine: *?*anyopaque) uc_err {
    const guard = UCTpGuard.init();
    defer guard.deinit();
    return raw_uc_open(arch, mode, engine);
}

const raw_uc_ctl = if (is_test) struct {
    fn impl(engine: ?*anyopaque, control: c_uint, arg: usize) callconv(.c) uc_err {
        _ = engine; _ = control; _ = arg; return .UC_ERR_OK;
    }
}.impl else struct {
    extern fn uc_ctl(engine: ?*anyopaque, control: c_uint, arg: usize) uc_err;
}.uc_ctl;

pub fn uc_ctl(engine: ?*anyopaque, control: c_uint, arg: usize) uc_err {
    const guard = UCTpGuard.init();
    defer guard.deinit();
    return raw_uc_ctl(engine, control, arg);
}

const raw_uc_close = if (is_test) struct {
    fn impl(engine: ?*anyopaque) callconv(.c) uc_err {
        _ = engine; return .UC_ERR_OK;
    }
}.impl else struct {
    extern fn uc_close(engine: ?*anyopaque) uc_err;
}.uc_close;

pub fn uc_close(engine: ?*anyopaque) uc_err {
    const guard = UCTpGuard.init();
    defer guard.deinit();
    return raw_uc_close(engine);
}

const raw_uc_emu_start = if (is_test) struct {
    fn impl(engine: ?*anyopaque, begin: u64, until: u64, timeout: u64, count: u64) callconv(.c) uc_err {
        _ = engine; _ = begin; _ = until; _ = timeout; _ = count; return .UC_ERR_OK;
    }
}.impl else struct {
    extern fn uc_emu_start(engine: ?*anyopaque, begin: u64, until: u64, timeout: u64, count: u64) uc_err;
}.uc_emu_start;

pub fn uc_emu_start(engine: ?*anyopaque, begin: u64, until: u64, timeout: u64, count: u64) uc_err {
    const guard = UCTpGuard.init();
    defer guard.deinit();
    return raw_uc_emu_start(engine, begin, until, timeout, count);
}

const raw_uc_emu_stop = if (is_test) struct {
    fn impl(engine: ?*anyopaque) callconv(.c) uc_err {
        _ = engine; return .UC_ERR_OK;
    }
}.impl else struct {
    extern fn uc_emu_stop(engine: ?*anyopaque) uc_err;
}.uc_emu_stop;

pub fn uc_emu_stop(engine: ?*anyopaque) uc_err {
    const guard = UCTpGuard.init();
    defer guard.deinit();
    return raw_uc_emu_stop(engine);
}

const raw_uc_reg_write = if (is_test) struct {
    fn impl(engine: ?*anyopaque, regid: c_int, value: ?*const anyopaque) callconv(.c) uc_err {
        _ = engine; _ = regid; _ = value; return .UC_ERR_OK;
    }
}.impl else struct {
    extern fn uc_reg_write(engine: ?*anyopaque, regid: c_int, value: ?*const anyopaque) uc_err;
}.uc_reg_write;

pub fn uc_reg_write(engine: ?*anyopaque, regid: c_int, value: ?*const anyopaque) uc_err {
    const guard = UCTpGuard.init();
    defer guard.deinit();
    return raw_uc_reg_write(engine, regid, value);
}

const raw_uc_reg_read = if (is_test) struct {
    fn impl(engine: ?*anyopaque, regid: c_int, value: ?*anyopaque) callconv(.c) uc_err {
        _ = engine; _ = regid; _ = value; return .UC_ERR_OK;
    }
}.impl else struct {
    extern fn uc_reg_read(engine: ?*anyopaque, regid: c_int, value: ?*anyopaque) uc_err;
}.uc_reg_read;

pub fn uc_reg_read(engine: ?*anyopaque, regid: c_int, value: ?*anyopaque) uc_err {
    const guard = UCTpGuard.init();
    defer guard.deinit();
    return raw_uc_reg_read(engine, regid, value);
}

const raw_uc_context_alloc = if (is_test) struct {
    fn impl(engine: ?*anyopaque, context: *?*anyopaque) callconv(.c) uc_err {
        _ = engine; _ = context; return .UC_ERR_OK;
    }
}.impl else struct {
    extern fn uc_context_alloc(engine: ?*anyopaque, context: *?*anyopaque) uc_err;
}.uc_context_alloc;

pub fn uc_context_alloc(engine: ?*anyopaque, context: *?*anyopaque) uc_err {
    const guard = UCTpGuard.init();
    defer guard.deinit();
    return raw_uc_context_alloc(engine, context);
}

const raw_uc_context_save = if (is_test) struct {
    fn impl(engine: ?*anyopaque, context: ?*anyopaque) callconv(.c) uc_err {
        _ = engine; _ = context; return .UC_ERR_OK;
    }
}.impl else struct {
    extern fn uc_context_save(engine: ?*anyopaque, context: ?*anyopaque) uc_err;
}.uc_context_save;

pub fn uc_context_save(engine: ?*anyopaque, context: ?*anyopaque) uc_err {
    const guard = UCTpGuard.init();
    defer guard.deinit();
    return raw_uc_context_save(engine, context);
}

const raw_uc_context_restore = if (is_test) struct {
    fn impl(engine: ?*anyopaque, context: ?*anyopaque) callconv(.c) uc_err {
        _ = engine; _ = context; return .UC_ERR_OK;
    }
}.impl else struct {
    extern fn uc_context_restore(engine: ?*anyopaque, context: ?*anyopaque) uc_err;
}.uc_context_restore;

pub fn uc_context_restore(engine: ?*anyopaque, context: ?*anyopaque) uc_err {
    const guard = UCTpGuard.init();
    defer guard.deinit();
    return raw_uc_context_restore(engine, context);
}

const raw_uc_context_free = if (is_test) struct {
    fn impl(context: ?*anyopaque) callconv(.c) uc_err {
        _ = context; return .UC_ERR_OK;
    }
}.impl else struct {
    extern fn uc_context_free(context: ?*anyopaque) uc_err;
}.uc_context_free;

pub fn uc_context_free(context: ?*anyopaque) uc_err {
    const guard = UCTpGuard.init();
    defer guard.deinit();
    return raw_uc_context_free(context);
}

const raw_uc_mem_map = if (is_test) struct {
    fn impl(engine: ?*anyopaque, address: u64, size: u64, perms: u32) callconv(.c) uc_err {
        _ = engine; _ = address; _ = size; _ = perms; return .UC_ERR_OK;
    }
}.impl else struct {
    extern fn uc_mem_map(engine: ?*anyopaque, address: u64, size: u64, perms: u32) uc_err;
}.uc_mem_map;

pub fn uc_mem_map(engine: ?*anyopaque, address: u64, size: u64, perms: u32) uc_err {
    const guard = UCTpGuard.init();
    defer guard.deinit();
    return raw_uc_mem_map(engine, address, size, perms);
}

const raw_uc_mem_map_ptr = if (is_test) struct {
    fn dummy_uc_mem_map_ptr(engine: ?*anyopaque, address: u64, size: u64, perms: u32, ptr: ?*anyopaque) uc_err {
        _ = engine; _ = address; _ = size; _ = perms; _ = ptr; return .UC_ERR_OK;
    }
}.dummy_uc_mem_map_ptr else struct {
    extern fn uc_mem_map_ptr(engine: ?*anyopaque, address: u64, size: u64, perms: u32, ptr: ?*anyopaque) uc_err;
}.uc_mem_map_ptr;

pub fn uc_mem_map_ptr(engine: ?*anyopaque, address: u64, size: u64, perms: u32, ptr: ?*anyopaque) uc_err {
    const guard = UCTpGuard.init();
    defer guard.deinit();
    return raw_uc_mem_map_ptr(engine, address, size, perms, ptr);
}

const raw_uc_mem_read = if (is_test) struct {
    fn dummy_uc_mem_read(engine: ?*anyopaque, address: u64, bytes: [*]u8, size: usize) uc_err {
        _ = engine; _ = address; _ = bytes; _ = size; return .UC_ERR_OK;
    }
}.dummy_uc_mem_read else struct {
    extern fn uc_mem_read(engine: ?*anyopaque, address: u64, bytes: [*]u8, size: usize) uc_err;
}.uc_mem_read;

pub fn uc_mem_read(engine: ?*anyopaque, address: u64, bytes: [*]u8, size: usize) uc_err {
    const guard = UCTpGuard.init();
    defer guard.deinit();
    return raw_uc_mem_read(engine, address, bytes, size);
}

const raw_uc_mem_write = if (is_test) struct {
    fn dummy_uc_mem_write(engine: ?*anyopaque, address: u64, bytes: [*]const u8, size: usize) uc_err {
        _ = engine; _ = address; _ = bytes; _ = size; return .UC_ERR_OK;
    }
}.dummy_uc_mem_write else struct {
    extern fn uc_mem_write(engine: ?*anyopaque, address: u64, bytes: [*]const u8, size: usize) uc_err;
}.uc_mem_write;

pub fn uc_mem_write(engine: ?*anyopaque, address: u64, bytes: [*]const u8, size: usize) uc_err {
    const guard = UCTpGuard.init();
    defer guard.deinit();
    return raw_uc_mem_write(engine, address, bytes, size);
}

const raw_uc_mem_unmap = if (is_test) struct {
    fn impl(engine: ?*anyopaque, address: u64, size: u64) callconv(.c) uc_err {
        _ = engine; _ = address; _ = size; return .UC_ERR_OK;
    }
}.impl else struct {
    extern fn uc_mem_unmap(engine: ?*anyopaque, address: u64, size: u64) uc_err;
}.uc_mem_unmap;

pub fn uc_mem_unmap(engine: ?*anyopaque, address: u64, size: u64) uc_err {
    const guard = UCTpGuard.init();
    defer guard.deinit();
    return raw_uc_mem_unmap(engine, address, size);
}

// Hook API
pub const uc_cb_eventmem_t = *const fn (uc: ?*anyopaque, mem_type: uc_mem_type, address: u64, size: c_int, value: i64, user_data: ?*anyopaque) callconv(.c) bool;
pub const uc_hook = ?*anyopaque;
pub const UC_HOOK_MEM_UNMAPPED = 112; // 1<<4 | 1<<5 | 1<<6
pub const UC_HOOK_INTR: c_int = 1; // 1<<0
pub const UC_HOOK_CODE: c_int = 4; // 1<<2
pub const UC_HOOK_BLOCK: c_int = 8; // 1<<3
pub const UC_HOOK_MEM_WRITE: c_int = 1 << 11; // 2048
pub const UC_HOOK_MEM_READ: c_int = 1 << 10; // 1024
pub const UC_HOOK_INSN: c_int = 2;
pub const UC_X86_INS_SYSCALL: c_int = 699;
pub const UC_X86_INS_IN: c_int = 218;
pub const UC_X86_INS_OUT: c_int = 500;
pub const UC_X86_INS_CPUID: c_int = 114;
pub const UC_X86_INS_RDMSR: c_int = 604;
pub const UC_X86_INS_WRMSR: c_int = 1305;

pub const uc_cb_hookintr_t = *const fn (uc: ?*anyopaque, intno: u32, user_data: ?*anyopaque) callconv(.c) void;

// UC_CTL control codes for cache management.
pub const UC_CTL_FLUSH_TLB: c_uint = 0x4000000b; // UC_CTL_WRITE(UC_CTL_TLB_FLUSH=11, 0)
pub const UC_CTL_FLUSH_TB: c_uint = 0x4000000a; // UC_CTL_WRITE(UC_CTL_TB_FLUSH=10, 0)

// UC_HOOK_INSN_INVALID fires when Unicorn encounters an instruction it
// cannot handle (e.g., rdtime with no rdtime_fn callback). The hook runs
// inside the emulation loop; returning true continues execution without
// the stop/restart overhead of UC_ERR_EXCEPTION.
pub const UC_HOOK_INSN_INVALID: c_int = 1 << 14;

pub const uc_hook_add = if (is_test) struct {
    fn impl(engine: ?*anyopaque, hh: *uc_hook, type_mask: c_int, callback: ?*const anyopaque, user_data: ?*anyopaque, begin: u64, end: u64, ...) callconv(.c) uc_err {
        _ = engine; _ = hh; _ = type_mask; _ = callback; _ = user_data; _ = begin; _ = end; return .UC_ERR_OK;
    }
}.impl else struct {
    extern fn uc_hook_add(engine: ?*anyopaque, hh: *uc_hook, type_mask: c_int, callback: ?*const anyopaque, user_data: ?*anyopaque, begin: u64, end: u64, ...) uc_err;
}.uc_hook_add;

pub const uc_hook_del = if (is_test) struct {
    fn impl(engine: ?*anyopaque, hh: uc_hook) callconv(.c) uc_err {
        _ = engine; _ = hh; return .UC_ERR_OK;
    }
}.impl else struct {
    extern fn uc_hook_del(engine: ?*anyopaque, hh: uc_hook) uc_err;
}.uc_hook_del;

// Remaining C/POSIX stubs required by Unicorn Engine:
pub export var stderr: ?*anyopaque = null;

pub export fn getenv(name: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    _ = name;
    return null;
}

pub export fn munmap(addr: ?*anyopaque, length: usize) callconv(.c) c_int {
    _ = length;
    if (addr) |ptr| {
        free(ptr);
    }
    return 0;
}

pub export fn perror(s: [*:0]const u8) callconv(.c) void {
    const guard = TpGuard.init();
    defer guard.deinit();
    debug.printf("perror: {s}\n", .{s});
}

pub export fn exit(status: c_int) callconv(.c) noreturn {
    const guard = TpGuard.init();
    _ = guard;
    const ra = riscv.readRA();
    debug.printf("exit called with status {}, return address 0x{x}\n", .{ status, ra });
    while (true) {}
}

pub export fn snprintf(str: [*]u8, size: usize, format: [*:0]const u8, ...) callconv(.c) c_int {
    if (size == 0) return 0;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);

    var write_idx: usize = 0;
    var fmt_idx: usize = 0;

    while (format[fmt_idx] != 0 and write_idx < size - 1) {
        if (format[fmt_idx] == '%') {
            fmt_idx += 1;
            if (format[fmt_idx] == 0) break;
            if (format[fmt_idx] == '%') {
                str[write_idx] = '%';
                write_idx += 1;
                fmt_idx += 1;
                continue;
            }

            if (format[fmt_idx] == 's') {
                const s = @cVaArg(&ap, [*:0]const u8);
                const s_span = std.mem.span(s);
                for (s_span) |char| {
                    if (write_idx >= size - 1) break;
                    str[write_idx] = char;
                    write_idx += 1;
                }
                fmt_idx += 1;
            } else if (format[fmt_idx] == 'd' or format[fmt_idx] == 'i') {
                const val = @cVaArg(&ap, c_int);
                var buf: [32]u8 = undefined;
                const formatted = std.fmt.bufPrint(&buf, "{d}", .{val}) catch "";
                for (formatted) |char| {
                    if (write_idx >= size - 1) break;
                    str[write_idx] = char;
                    write_idx += 1;
                }
                fmt_idx += 1;
            } else if (format[fmt_idx] == 'u') {
                const val = @cVaArg(&ap, c_uint);
                var buf: [32]u8 = undefined;
                const formatted = std.fmt.bufPrint(&buf, "{d}", .{val}) catch "";
                for (formatted) |char| {
                    if (write_idx >= size - 1) break;
                    str[write_idx] = char;
                    write_idx += 1;
                }
                fmt_idx += 1;
            } else if (format[fmt_idx] == 'x') {
                const val = @cVaArg(&ap, c_uint);
                var buf: [32]u8 = undefined;
                const formatted = std.fmt.bufPrint(&buf, "{x}", .{val}) catch "";
                for (formatted) |char| {
                    if (write_idx >= size - 1) break;
                    str[write_idx] = char;
                    write_idx += 1;
                }
                fmt_idx += 1;
            } else {
                str[write_idx] = '%';
                write_idx += 1;
                if (write_idx < size - 1) {
                    str[write_idx] = format[fmt_idx];
                    write_idx += 1;
                }
                fmt_idx += 1;
            }
        } else {
            str[write_idx] = format[fmt_idx];
            write_idx += 1;
            fmt_idx += 1;
        }
    }
    str[write_idx] = 0;
    return @intCast(write_idx);
}

var global_errno: c_int = 0;
pub export fn __errno_location() callconv(.c) *c_int {
    return &global_errno;
}

pub export fn madvise(addr: ?*anyopaque, length: usize, advice: c_int) callconv(.c) c_int {
    _ = addr;
    _ = length;
    _ = advice;
    return 0;
}

pub export fn mprotect(addr: ?*anyopaque, len: usize, prot: c_int) callconv(.c) c_int {
    _ = addr;
    _ = len;
    _ = prot;
    return 0;
}

pub export fn __riscv_flush_icache(start: ?*anyopaque, end: ?*anyopaque, flags: c_ulong) callconv(.c) void {
    _ = start;
    _ = end;
    _ = flags;
    riscv.flushIcache();
}

pub export fn bsearch(key: ?*const anyopaque, base: ?*const anyopaque, nitems: usize, size: usize, compar: ?*const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int) callconv(.c) ?*anyopaque {
    if (key == null or base == null or nitems == 0 or size == 0 or compar == null) return null;
    const cmp = compar.?;
    const ptr = @as([*]const u8, @ptrCast(base.?));

    var low: usize = 0;
    var high: usize = nitems;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const mid_ptr = ptr + (mid * size);
        const res = cmp(key.?, mid_ptr);
        if (res == 0) {
            return @as(?*anyopaque, @ptrCast(@constCast(mid_ptr)));
        } else if (res < 0) {
            high = mid;
        } else {
            low = mid + 1;
        }
    }
    return null;
}

pub export fn mmap(addr: ?*anyopaque, length: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) callconv(.c) ?*anyopaque {
    _ = addr;
    _ = fd;
    _ = offset;
    _ = prot;
    _ = flags;

    const physmem = @import("physmem.zig");
    const max_alloc_size = (@as(usize, 1) << (physmem.max_order - 1)) * physmem.PageSize - @sizeOf(MallocHeader);

    if (length > max_alloc_size) {
        debug.printf("Unicorn mmap() failed: length {} exceeds maximum allocator capacity {}\n", .{ length, max_alloc_size });
        return @ptrFromInt(std.math.maxInt(usize));
    }

    if (malloc(length)) |ptr| {
        return ptr;
    }
    debug.printf("Unicorn mmap() (length: {}) failed!\n", .{length});
    return @ptrFromInt(std.math.maxInt(usize));
}

pub extern fn uc_strerror(error_code: uc_err) ?[*:0]const u8;

// Diosix glue: register an rdtime callback with Unicorn's internal QEMU CPU
// state so that guest rdtime instructions execute inside the JIT loop.
pub extern fn diosix_uc_set_rdtime_fn(uc: ?*anyopaque, fn_ptr: *const fn () callconv(.c) u64) void;

// Diosix glue: deliver an exception using QEMU's native riscv_cpu_do_interrupt.
// This bypasses uc_reg_read/write (which has JIT state sync issues) and lets
// QEMU properly set sepc, scause, stval, mstatus, and pc=stvec.
// The info struct is populated with pre/post interrupt state for debugging.
pub const InterruptInfo = extern struct {
    pre_priv: u32,
    pre_pc: u32,
    pre_stvec: u32,
    pre_mtvec: u32,
    pre_medeleg: u32,
    pre_badaddr: u32,
    pre_mstatus: u32,
    post_pc: u32,
    post_sepc: u32,
    post_scause: u32,
    post_stval: u32,
    post_priv: u32,
};
pub extern fn diosix_uc_do_interrupt(uc: ?*anyopaque, exception_index: c_int, info: ?*InterruptInfo) void;

// Diosix glue: inject an asynchronous interrupt (e.g., timer) using QEMU's
// native riscv_cpu_do_interrupt. Called from the run loop (not from hooks),
// so env->pc is already correct (no +4 undo needed).
pub extern fn diosix_uc_inject_interrupt(uc: ?*anyopaque, cause: c_int) void;

// Clear stale CPU exit flags after an asynchronous uc_emu_stop.
// Must be called after uc_emu_start returns and before re-entering.
pub extern fn diosix_uc_clear_stop(uc: ?*anyopaque) void;
pub extern fn diosix_uc_is_halted(uc: ?*anyopaque) c_int;

// ARM64 exception delivery: calls QEMU's arm_cpu_do_interrupt to handle
// the full EL1 exception entry (SPSR, ELR, ESR, VBAR vector dispatch).
pub extern fn diosix_uc_do_interrupt_arm64(uc: ?*anyopaque, exception_index: c_int) void;

// Disable QEMU's internal ARM64 MMU by clearing SCTLR_EL1.M (bit 0).
// Called when we detect the guest has enabled the MMU but QEMU's page
// table walk fails. Since we map VA ranges directly in Unicorn's flat
// memory, we don't need the MMU.
pub extern fn diosix_uc_disable_arm64_mmu(uc: ?*anyopaque) void;

// Synchronize ARM64 MMU state: syncs TTBR banked fields to el[] and
// rebuilds QEMU's internal hflags cache. Call after MMU-enable exceptions.
pub extern fn diosix_uc_arm64_sync_mmu_state(uc: ?*anyopaque) void;

// Callback passed to diosix_uc_set_rdtime_fn. Reads the real host timer
// from S-mode and returns it to Unicorn's JIT-compiled rdtime handler.
pub fn rdtimeCallback() callconv(.c) u64 {
    return readSModeTime();
}

pub export fn strerror(errnum: c_int) callconv(.c) [*:0]const u8 {
    _ = errnum;
    return "Unknown error";
}

pub export fn __fpclassifyl(x: f128) callconv(.c) c_int {
    _ = x;
    return 4; // FP_NORMAL
}

pub export fn pthread_attr_init(attr: ?*anyopaque) callconv(.c) c_int {
    _ = attr;
    return 0;
}

pub export fn pthread_attr_setdetachstate(attr: ?*anyopaque, state: c_int) callconv(.c) c_int {
    _ = attr;
    _ = state;
    return 0;
}

pub export fn sigfillset(set: ?*anyopaque) callconv(.c) c_int {
    _ = set;
    return 0;
}

pub export fn pthread_sigmask(how: c_int, set: ?*const anyopaque, oldset: ?*anyopaque) callconv(.c) c_int {
    _ = how;
    _ = set;
    _ = oldset;
    return 0;
}

pub export fn pthread_create(thread: ?*usize, attr: ?*const anyopaque, start_routine: ?*const anyopaque, arg: ?*anyopaque) callconv(.c) c_int {
    _ = thread;
    _ = attr;
    _ = start_routine;
    _ = arg;
    debug.printf("unicorn_glue: pthread_create called, returning 0\n", .{});
    return 0;
}

pub export fn pthread_attr_destroy(attr: ?*anyopaque) callconv(.c) c_int {
    _ = attr;
    return 0;
}

pub export fn strcmp(s1: [*:0]const u8, s2: [*:0]const u8) callconv(.c) c_int {
    var i: usize = 0;
    while (true) : (i += 1) {
        const c1 = s1[i];
        const c2 = s2[i];
        if (c1 != c2 or c1 == 0) {
            return @as(c_int, c1) - @as(c_int, c2);
        }
    }
}

pub export fn strcpy(dest: [*]u8, src: [*:0]const u8) callconv(.c) [*]u8 {
    var i: usize = 0;
    while (true) : (i += 1) {
        dest[i] = src[i];
        if (src[i] == 0) break;
    }
    return dest;
}

pub export fn strdup(s: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    const len = std.mem.span(s).len;
    const ptr = malloc(len + 1) orelse return null;
    const dest = @as([*]u8, @ptrCast(ptr));
    @memcpy(dest[0..len], s[0..len]);
    dest[len] = 0;
    return @ptrCast(dest);
}

pub export fn vasprintf(strp: *?[*:0]u8, format: [*:0]const u8, ap: ?*anyopaque) callconv(.c) c_int {
    _ = ap;
    const fmt_span = std.mem.span(format);
    const ptr = malloc(fmt_span.len + 1) orelse return -1;
    const dest = @as([*]u8, @ptrCast(ptr));
    @memcpy(dest[0..fmt_span.len], fmt_span[0..fmt_span.len]);
    dest[fmt_span.len] = 0;
    strp.* = @ptrCast(dest);
    return @intCast(fmt_span.len);
}

pub export fn strncpy(dest: [*]u8, src: [*:0]const u8, n: usize) callconv(.c) [*]u8 {
    var i: usize = 0;
    var pad = false;
    while (i < n) : (i += 1) {
        if (pad) {
            dest[i] = 0;
        } else {
            dest[i] = src[i];
            if (src[i] == 0) pad = true;
        }
    }
    return dest;
}

pub export fn strcat(dest: [*:0]u8, src: [*:0]const u8) callconv(.c) [*:0]u8 {
    var dest_idx: usize = 0;
    while (dest[dest_idx] != 0) : (dest_idx += 1) {}

    var src_idx: usize = 0;
    while (true) : (src_idx += 1) {
        dest[dest_idx + src_idx] = src[src_idx];
        if (src[src_idx] == 0) break;
    }
    return dest;
}

pub export fn strstr(haystack: [*:0]const u8, needle: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const h_span = std.mem.span(haystack);
    const n_span = std.mem.span(needle);
    if (n_span.len == 0) return haystack;
    if (h_span.len < n_span.len) return null;

    var i: usize = 0;
    while (i <= h_span.len - n_span.len) : (i += 1) {
        if (std.mem.eql(u8, h_span[i..(i + n_span.len)], n_span)) {
            return @ptrCast(&haystack[i]);
        }
    }
    return null;
}

comptime {
    if (is_test) {
        @export(&diosix_uc_set_rdtime_fn_mock, .{ .name = "diosix_uc_set_rdtime_fn", .linkage = .strong });
        @export(&diosix_uc_do_interrupt_mock, .{ .name = "diosix_uc_do_interrupt", .linkage = .strong });
        @export(&diosix_uc_inject_interrupt_mock, .{ .name = "diosix_uc_inject_interrupt", .linkage = .strong });
        @export(&diosix_uc_clear_stop_mock, .{ .name = "diosix_uc_clear_stop", .linkage = .strong });
        @export(&diosix_uc_is_halted_mock, .{ .name = "diosix_uc_is_halted", .linkage = .strong });
        @export(&diosix_uc_do_interrupt_arm64_mock, .{ .name = "diosix_uc_do_interrupt_arm64", .linkage = .strong });
        @export(&diosix_uc_disable_arm64_mmu_mock, .{ .name = "diosix_uc_disable_arm64_mmu", .linkage = .strong });
        @export(&diosix_uc_arm64_sync_mmu_state_mock, .{ .name = "diosix_uc_arm64_sync_mmu_state", .linkage = .strong });

        const mock_val: u8 = 0;
        @export(&mock_val, .{ .name = "__rootvm_start", .linkage = .strong });
        @export(&mock_val, .{ .name = "__rootvm_end", .linkage = .strong });
    }
}

fn diosix_uc_set_rdtime_fn_mock(_: ?*anyopaque, _: *const fn () callconv(.c) u64) callconv(.c) void {}
fn diosix_uc_do_interrupt_mock(_: ?*anyopaque, _: c_int, _: ?*InterruptInfo) callconv(.c) void {}
fn diosix_uc_inject_interrupt_mock(_: ?*anyopaque, _: c_int) callconv(.c) void {}
fn diosix_uc_clear_stop_mock(_: ?*anyopaque) callconv(.c) void {}
fn diosix_uc_is_halted_mock(_: ?*anyopaque) callconv(.c) c_int {
    return 0;
}
fn diosix_uc_do_interrupt_arm64_mock(_: ?*anyopaque, _: c_int) callconv(.c) void {}
fn diosix_uc_disable_arm64_mmu_mock(_: ?*anyopaque) callconv(.c) void {}
fn diosix_uc_arm64_sync_mmu_state_mock(_: ?*anyopaque) callconv(.c) void {}
