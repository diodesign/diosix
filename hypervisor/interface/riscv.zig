// RISC-V definitions shareable between hypervisor and other software
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

pub const Register = enum(usize) {
    zero = 0,
    ra = 1,
    sp = 2,
    gp = 3,
    tp = 4,
    t0 = 5,
    t1 = 6,
    t2 = 7,
    s0 = 8,
    s1 = 9,
    a0 = 10,
    a1 = 11,
    a2 = 12,
    a3 = 13,
    a4 = 14,
    a5 = 15,
    a6 = 16,
    a7 = 17,
    s2 = 18,
    s3 = 19,
    s4 = 20,
    s5 = 21,
    s6 = 22,
    s7 = 23,
    s8 = 24,
    s9 = 25,
    s10 = 26,
    s11 = 27,
    t3 = 28,
    t4 = 29,
    t5 = 30,
    t6 = 31,
};

pub const PrivilegeMode = enum(u2) {
    user = 0,
    supervisor = 1,
    machine = 3,
};

pub const IsaExtension = struct {
    pub const a: usize = 1 << 0;
    pub const c: usize = 1 << 2;
    pub const d: usize = 1 << 3;
    pub const f: usize = 1 << 5;
    pub const i: usize = 1 << 8;
    pub const m: usize = 1 << 12;
    pub const s: usize = 1 << 18;
    pub const u: usize = 1 << 20;
    pub const h: usize = 1 << 7;

    pub const g: usize = i | m | a | f | d; // G = IMAFD
    pub const gc: usize = g | c;
};

// CSR Bit-fields
pub const MSTATUS = struct {
    pub const MPP_SHIFT = 11;
    pub const MPP_MASK = 0b11 << MPP_SHIFT;
    pub const MIE = 1 << 3;
    pub const SIE = 1 << 1;
    pub const MPV: u64 = 1 << 39;
};

pub const SSTATUS = struct {
    pub const SPP_SHIFT = 8;
    pub const SIE = 1 << 1;
};

pub const HSTATUS = struct {
    pub const GVA = 1 << 6;
    pub const SPV = 1 << 7;
    pub const SPVP = 1 << 8;
};

pub const Cause = enum(usize) {
    // Exceptions
    instruction_alignment = 0,
    instruction_access = 1,
    illegal_instruction = 2,
    breakpoint = 3,
    load_alignment = 4,
    load_access = 5,
    store_alignment = 6,
    store_access = 7,
    user_environment_call = 8,
    supervisor_environment_call = 9,
    virtual_supervisor_environment_call = 10,
    machine_environment_call = 11,
    instruction_page_fault = 12,
    load_page_fault = 13,
    store_page_fault = 15,
    guest_instruction_page_fault = 20,
    guest_load_page_fault = 22,
    guest_store_page_fault = 23,

    // Interrupts (marker bit set below)
    user_swi = (1 << 63) | 0,
    supervisor_swi = (1 << 63) | 1,
    machine_swi = (1 << 63) | 3,
    user_timer = (1 << 63) | 4,
    supervisor_timer = (1 << 63) | 5,
    machine_timer = (1 << 63) | 7,
    user_interrupt = (1 << 63) | 8,
    supervisor_interrupt = (1 << 63) | 9,
    machine_interrupt = (1 << 63) | 11,

    unknown = 0xffffffffffffffff,

    pub const INTERRUPT_BIT = 1 << 63;
};

pub fn toCause(val: usize) Cause {
    return switch (val) {
        0 => .instruction_alignment,
        1 => .instruction_access,
        2 => .illegal_instruction,
        3 => .breakpoint,
        4 => .load_alignment,
        5 => .load_access,
        6 => .store_alignment,
        7 => .store_access,
        8 => .user_environment_call,
        9 => .supervisor_environment_call,
        10 => .virtual_supervisor_environment_call,
        11 => .machine_environment_call,
        12 => .instruction_page_fault,
        13 => .load_page_fault,
        15 => .store_page_fault,
        20 => .guest_instruction_page_fault,
        22 => .guest_load_page_fault,
        23 => .guest_store_page_fault,

        (1 << 63) | 0 => .user_swi,
        (1 << 63) | 1 => .supervisor_swi,
        (1 << 63) | 3 => .machine_swi,
        (1 << 63) | 4 => .user_timer,
        (1 << 63) | 5 => .supervisor_timer,
        (1 << 63) | 7 => .machine_timer,
        (1 << 63) | 8 => .user_interrupt,
        (1 << 63) | 9 => .supervisor_interrupt,
        (1 << 63) | 11 => .machine_interrupt,

        else => .unknown,
    };
}
