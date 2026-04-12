# Top-level file for support assembly code for Qemu-compatible systems
#
# Copyright (c) 2024 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

.include "hypervisor/hw/qemu/entry.s"
.include "hypervisor/hw/qemu/xint.s"
.include "hypervisor/hw/qemu/util.s"
.include "hypervisor/hw/qemu/rootvm.s"