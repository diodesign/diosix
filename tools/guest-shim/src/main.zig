// Diosix Freestanding S-Mode Guest Bootloader Shim Entry Point.
//
// Boots S/U-mode guest kernels (Linux, FreeBSD, OpenBSD, NetBSD, QNX, Haiku)
// from attached installer ISO media or local virtual disks.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
pub const boot_loader = @import("loader.zig");

const SBI_EXT_LEGACY_PUTCHAR: usize = 0x01;
const SBI_EXT_DIOSIX: usize = 0x0a000005;
const SBI_DIOSIX_FUNC_YIELD: usize = 1;
const SHIM_LINK_BASE: usize = 0xe000_0000;

const is_riscv_freestanding =
    (builtin.cpu.arch == .riscv64 and builtin.os.tag == .freestanding);

var efi_sys_table: boot_loader.EfiSystemTable64 = undefined;
var efi_boot_services: boot_loader.EfiBootServices64 = undefined;

comptime {
    if (is_riscv_freestanding) {
        asm (
            \\.section .text.entry, "ax"
            \\.global _start
            \\_start:
            \\    la sp, __stack_top
            \\    la t0, __bss_start
            \\    la t1, __bss_end
            \\1:
            \\    bgeu t0, t1, 2f
            \\    sd zero, 0(t0)
            \\    addi t0, t0, 8
            \\    j 1b
            \\2:
            \\    call shimMain
            \\3:
            \\    wfi
            \\    j 3b
        );
    }
}

fn sbiPutChar(ch: u8) void {
    if (is_riscv_freestanding) {
        _ = asm volatile ("ecall"
            : [ret] "={x10}" (-> usize),
            : [arg0] "{x10}" (@as(usize, ch)),
              [ext] "{x17}" (SBI_EXT_LEGACY_PUTCHAR),
            : .{ .memory = true });
    }
}

fn sbiPrint(msg: []const u8) void {
    for (msg) |ch| {
        sbiPutChar(ch);
    }
}

fn sbiYieldLoop() noreturn {
    if (is_riscv_freestanding) {
        while (true) {
            _ = asm volatile ("ecall"
                : [ret] "={x10}" (-> usize),
                : [func] "{x16}" (SBI_DIOSIX_FUNC_YIELD),
                  [ext] "{x17}" (SBI_EXT_DIOSIX),
                : .{ .memory = true });
            asm volatile ("wfi");
        }
    }
    unreachable;
}

fn handoffLoadedKernel(
    hart_id: usize,
    dtb_addr: usize,
    dest_base: usize,
    loaded: boot_loader.KernelLoadResult,
) noreturn {
    const entry_addr = dest_base + loaded.entry_offset;
    if (loaded.format == .pe32_plus_efi) {
        boot_loader.initMinimalEfiTables(&efi_sys_table, &efi_boot_services);
        jumpToGuestKernel(1, @intFromPtr(&efi_sys_table), entry_addr);
    } else {
        jumpToGuestKernel(hart_id, dtb_addr, entry_addr);
    }
}

fn relocateSlice(ram_base: usize, s: []const u8) []const u8 {
    const raw_ptr = @intFromPtr(s.ptr);
    const offset = if (raw_ptr >= SHIM_LINK_BASE)
        raw_ptr - SHIM_LINK_BASE
    else
        raw_ptr & 0x001f_ffff;
    const reloc_ptr: [*]const u8 = @ptrFromInt(ram_base + offset);
    return reloc_ptr[0..s.len];
}

fn sbiPrintReloc(ram_base: usize, msg: []const u8) void {
    sbiPrint(relocateSlice(ram_base, msg));
}

export fn shimMain(hart_id: usize, dtb_addr: usize) callconv(.c) noreturn {
    const pc = if (is_riscv_freestanding)
        asm ("auipc %[ret], 0"
            : [ret] "=r" (-> usize),
        )
    else
        SHIM_LINK_BASE;
    const ram_base = pc & ~@as(usize, 0x001f_ffff);

    sbiPrintReloc(
        ram_base,
        "[diosix-shim] S-mode universal guest bootloader starting...\r\n",
    );

    if (is_riscv_freestanding and dtb_addr != 0) {
        const safe_window =
            if (dtb_addr > ram_base) (dtb_addr - ram_base) else 0;

        if (safe_window > boot_loader.SHIM_KERNEL_DEST_OFFSET + 0x0010_0000) {
            const hdr_ptr: [*]const u8 =
                @ptrFromInt(ram_base + boot_loader.SHIM_HEADER_OFFSET);
            const magic = std.mem.readInt(u64, hdr_ptr[0..8], .little);
            const raw_off = std.mem.readInt(u64, hdr_ptr[8..16], .little);
            const raw_len = std.mem.readInt(u64, hdr_ptr[16..24], .little);

            var payload_off: usize = 0x0040_0000;
            var payload_len: usize = 0;

            if (magic == boot_loader.SHIM_HEADER_MAGIC) {
                const cast_off = std.math.cast(usize, raw_off) orelse 0;
                const cast_len = std.math.cast(usize, raw_len) orelse 0;
                if (cast_off > boot_loader.SHIM_KERNEL_DEST_OFFSET and
                    cast_off < safe_window)
                {
                    payload_off = cast_off;
                    payload_len = @min(cast_len, safe_window - cast_off);
                }
            } else if (safe_window > 0x0040_0000) {
                payload_off = 0x0040_0000;
                payload_len = safe_window - 0x0040_0000;
            }

            if (payload_len > 0 and
                payload_off > boot_loader.SHIM_KERNEL_DEST_OFFSET)
            {
                const payload_ptr: [*]const u8 =
                    @ptrFromInt(ram_base + payload_off);
                const payload_slice = payload_ptr[0..payload_len];
                const dest_max =
                    payload_off - boot_loader.SHIM_KERNEL_DEST_OFFSET;
                const dest_ptr: [*]u8 =
                    @ptrFromInt(ram_base + boot_loader.SHIM_KERNEL_DEST_OFFSET);
                const dest_slice = dest_ptr[0..dest_max];

                // 1. Check if an ISO9660 volume is staged in payload window.
                const fmt = boot_loader.detectStorageFormat(payload_slice);
                if (fmt == .iso9660) {
                    sbiPrintReloc(
                        ram_base,
                        "[diosix-shim] ISO9660 boot media detected.\r\n",
                    );
                    if (boot_loader.parseIso9660Volume(payload_slice)) |vol| {
                        const candidate_paths = .{
                            "kernel.elf",
                            "vmlinux.elf",
                            "Image",
                            "boot/vmlinux.elf",
                            "boot/vmlinuz",
                            "boot/Image",
                            "boot/kernel/kernel",
                            "boot/loader.efi",
                            "efi/boot/bootriscv64.efi",
                            "bootriscv64.efi",
                            "loader.efi",
                        };
                        inline for (candidate_paths) |cpath_lit| {
                            const cpath = relocateSlice(ram_base, cpath_lit);
                            if (boot_loader.findIso9660Path(
                                payload_slice,
                                vol,
                                cpath,
                            )) |ext| {
                                const file_off = std.math.mul(
                                    usize,
                                    ext.extent_lba,
                                    boot_loader.ISO_SECTOR_SIZE,
                                ) catch 0;
                                const file_end = std.math.add(
                                    usize,
                                    file_off,
                                    ext.data_length,
                                ) catch 0;
                                if (file_end > file_off and
                                    file_end <= payload_slice.len)
                                {
                                    const img_slice =
                                        payload_slice[file_off..file_end];
                                    if (boot_loader.loadKernelAuto(
                                        img_slice,
                                        dest_slice,
                                    )) |loaded| {
                                        sbiPrintReloc(
                                            ram_base,
                                            "[diosix-shim] Booting kernel " ++
                                                "from ISO9660 volume...\r\n",
                                        );
                                        handoffLoadedKernel(
                                            hart_id,
                                            dtb_addr,
                                            @intFromPtr(dest_ptr),
                                            loaded,
                                        );
                                    } else |_| {}
                                }
                            } else |_| {}
                        }
                    } else |_| {}
                }

                // 2. Check if a kernel image (ELF, flat RISC-V Image, or PE32+
                // EFI) is staged directly.
                if (boot_loader.loadKernelAuto(
                    payload_slice,
                    dest_slice,
                )) |loaded| {
                    sbiPrintReloc(
                        ram_base,
                        "[diosix-shim] Direct guest kernel loaded; " ++
                            "jumping to S-mode entry.\r\n",
                    );
                    handoffLoadedKernel(
                        hart_id,
                        dtb_addr,
                        @intFromPtr(dest_ptr),
                        loaded,
                    );
                } else |_| {}
            }
        }
    }

    sbiPrintReloc(ram_base, "\n[diosix-guest] Nested VM online!\r\n");
    sbiYieldLoop();
}

fn jumpToGuestKernel(arg0: usize, arg1: usize, entry_addr: usize) noreturn {
    if (is_riscv_freestanding) {
        asm volatile (
            \\fence.i
            \\mv a0, %[a0_val]
            \\mv a1, %[a1_val]
            \\jr %[entry]
            :
            : [a0_val] "r" (arg0),
              [a1_val] "r" (arg1),
              [entry] "r" (entry_addr),
            : .{ .memory = true });
    }
    while (true) {}
}

test {
    _ = boot_loader;
    std.testing.refAllDecls(@This());
}
