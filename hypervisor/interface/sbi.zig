// RISC-V SBI definitions shareable between hypervisor and guests
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

pub const SPEC_VERSION: usize = 0x00000002; // v0.2
pub const IMPL_ID: usize = 5; // Diosix official implementation ID
pub const IMPL_VERSION: usize = 1;

// SBI Error Codes
pub const SUCCESS: isize = 0;
pub const ERR_FAILED: isize = -1;
pub const ERR_NOT_SUPPORTED: isize = -2;
pub const ERR_INVALID_PARAM: isize = -3;
pub const ERR_DENIED: isize = -4;
pub const ERR_INVALID_ADDRESS: isize = -5;
pub const ERR_ALREADY_AVAILABLE: isize = -6;

// SBI Extension IDs
pub const EXT = struct {
    pub const BASE = 0x10;
    pub const TIMER = 0x54494d45;
    pub const RFENCE = 0x52464e43;
    pub const HSM = 0x48534d;
    pub const SRST = 0x53525354;
    pub const DBCN = 0x4442434e;
    pub const DIOSIX = 0x0A000005;

    // Legacy Extensions
    pub const LEGACY_SET_TIMER = 0x0;
    pub const LEGACY_CONSOLE_PUTCHAR = 0x1;
    pub const LEGACY_CONSOLE_GETCHAR = 0x2;
    pub const LEGACY_SHUTDOWN = 0x8;
};

// Base Extension Function IDs
pub const BASE = struct {
    pub const GET_SPEC_VERSION = 0;
    pub const GET_IMPL_ID = 1;
    pub const GET_IMPL_VERSION = 2;
    pub const PROBE_EXTENSION = 3;
    pub const GET_MVENDORID = 4;
    pub const GET_MARCHID = 5;
    pub const GET_MIMPID = 6;
};

// Diosix Extension Function IDs
pub const DIOSIX = struct {
    pub const EXIT = 0;
    pub const YIELD = 1;
    pub const FORK = 2;
    pub const DROP_TRUST = 3;
};

// Debug Console Extension Function IDs
pub const DBCN = struct {
    pub const CONSOLE_WRITE = 0;
    pub const CONSOLE_READ = 1;
    pub const CONSOLE_WRITE_BYTE = 2;
};

// SBI Call Result
pub const Result = struct {
    err: isize,
    value: usize,
};
