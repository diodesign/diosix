#!/usr/bin/env bash
#
# create_storage_disk.sh: Generate ext4 storage disk image for Diosix secondary VM images
#
# Usage: create_storage_disk.sh <kernel_elf_path> <output_disk_img> [disk_size]
#
# Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

set -eo pipefail

KERNEL_ELF="$1"
OUT_IMG="$2"
DISK_SIZE="${3:-256M}"

if [ -z "$KERNEL_ELF" ] || [ -z "$OUT_IMG" ]; then
    echo "Usage: $0 <kernel_elf_path> <output_disk_img> [disk_size]"
    exit 1
fi

mkdir -p "$(dirname "$OUT_IMG")"
STAGING_DIR="$(dirname "$OUT_IMG")/storage-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/var/lib/diosix/images" "$STAGING_DIR/boot" "$STAGING_DIR/etc/diosix"

# Copy kernel image to standard locations on the storage disk (strip if possible)
if [ -f "$KERNEL_ELF" ]; then
    STRIP_TOOL="strip"
    if command -v riscv64-buildroot-linux-gnu-strip >/dev/null 2>&1; then
        STRIP_TOOL="riscv64-buildroot-linux-gnu-strip"
    elif [ -x "zig-out/buildroot-riscv64/output/host/bin/riscv64-buildroot-linux-gnu-strip" ]; then
        STRIP_TOOL="zig-out/buildroot-riscv64/output/host/bin/riscv64-buildroot-linux-gnu-strip"
    fi
    "$STRIP_TOOL" -s "$KERNEL_ELF" -o "$STAGING_DIR/var/lib/diosix/images/vmlinux.elf" 2>/dev/null || cp "$KERNEL_ELF" "$STAGING_DIR/var/lib/diosix/images/vmlinux.elf"
    cp "$STAGING_DIR/var/lib/diosix/images/vmlinux.elf" "$STAGING_DIR/boot/vmlinux.elf"
fi

# Copy system manifest to storage disk
if [ -f "tools/overlay-common/etc/diosix/system.toml" ]; then
    cp "tools/overlay-common/etc/diosix/system.toml" "$STAGING_DIR/etc/diosix/system.toml"
fi

cat <<'TXT' > "$STAGING_DIR/README.txt"
=== Diosix Virtual Storage Volume ===
This ext4 partition provides persistent guest image storage and shared volume
access for the Diosix Root VM (Domain 0) and unprivileged child VMs.

Default image repository path: /var/lib/diosix/images/
Default system manifest:       /etc/diosix/system.toml
TXT

# Use mke2fs -F -d to build the ext4 filesystem directly from staging directory in user space
if command -v mke2fs >/dev/null 2>&1; then
    rm -f "$OUT_IMG"
    mke2fs -F -q -t ext4 -d "$STAGING_DIR" "$OUT_IMG" "$DISK_SIZE"
    echo "Generated $OUT_IMG ($DISK_SIZE ext4 volume containing guest images)."
else
    echo "Warning: mke2fs not found on host. Storage image creation skipped."
fi
