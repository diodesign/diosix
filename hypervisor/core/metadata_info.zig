// Compile-time generated metadata exported as linker symbols to avoid rebuild invalidation.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const metadata = @import("metadata");

export const banner: [*:0]const u8 = metadata.banner ++ "\x00";
export const project_version: [*:0]const u8 = metadata.project_version ++ "\x00";
export const git_branch: [*:0]const u8 = metadata.git_branch ++ "\x00";
export const git_revision: [*:0]const u8 = metadata.git_revision ++ "\x00";
export const build_date: [*:0]const u8 = metadata.build_date ++ "\x00";
export const build_user: [*:0]const u8 = metadata.build_user ++ "\x00";
export const build_hostname: [*:0]const u8 = metadata.build_hostname ++ "\x00";
export const zig_version: [*:0]const u8 = metadata.zig_version ++ "\x00";
export const cpu_arch: [*:0]const u8 = metadata.cpu_arch ++ "\x00";
