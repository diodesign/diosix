#!/usr/bin/env bash
#
# create_storage_disk.sh: Generate ext4 storage disk image for Diosix VMs.
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

mkdir -p "$(dirname "$OUT_IMG")" .zig-cache
STAGING_DIR=".zig-cache/storage-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/images" "$STAGING_DIR/manifests" \
    "$STAGING_DIR/keys"
chmod 700 "$STAGING_DIR/keys"
MGT_KEY="$STAGING_DIR/keys/id_management"
if command -v dropbearkey >/dev/null 2>&1; then
    dropbearkey -t ed25519 -f "$MGT_KEY" >/dev/null 2>&1 || true
    chmod 600 "$MGT_KEY" 2>/dev/null || true
    dropbearkey -y -f "$MGT_KEY" 2>/dev/null | \
        grep "^ssh-" > "${MGT_KEY}.pub" || true
    chmod 644 "${MGT_KEY}.pub" 2>/dev/null || true
fi

# Zero-toil developer passkey auto-enrollment for diosix.mode=dev.
DEV_KEY=".zig-cache/dev_id_ed25519"
if [ ! -f "$DEV_KEY" ] && command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -t ed25519 -N "" -f "$DEV_KEY" \
        -C "dev@diosix-host" >/dev/null 2>&1 || true
fi

DEV_AUTH="$STAGING_DIR/keys/dev_authorized_keys"
PASS_AUTH="$STAGING_DIR/keys/authorized_passkeys"
touch "$DEV_AUTH" "$PASS_AUTH"
for pubkey in "${DEV_KEY}.pub" \
    "$HOME/.ssh/id_ed25519_sk.pub" \
    "$HOME/.ssh/id_ecdsa_sk.pub" \
    "$HOME/.ssh/id_ed25519.pub"; do
    if [ -f "$pubkey" ] && [ -r "$pubkey" ]; then
        cat "$pubkey" >> "$DEV_AUTH" 2>/dev/null || true
        cat "$pubkey" >> "$PASS_AUTH" 2>/dev/null || true
    fi
done
sort -u "$DEV_AUTH" -o "$DEV_AUTH" 2>/dev/null || true
sort -u "$PASS_AUTH" -o "$PASS_AUTH" 2>/dev/null || true
chmod 600 "$DEV_AUTH" "$PASS_AUTH" 2>/dev/null || true

# Copy kernel image to standard locations on the storage disk.
if [ -f "$KERNEL_ELF" ]; then
    STRIP_TOOL="strip"
    BR_STRIP="zig-out/buildroot-riscv64/output/host/bin"
    BR_STRIP="${BR_STRIP}/riscv64-buildroot-linux-gnu-strip"
    if command -v riscv64-buildroot-linux-gnu-strip >/dev/null 2>&1; then
        STRIP_TOOL="riscv64-buildroot-linux-gnu-strip"
    elif [ -x "$BR_STRIP" ]; then
        STRIP_TOOL="$BR_STRIP"
    fi
    "$STRIP_TOOL" -s "$KERNEL_ELF" \
        -o "$STAGING_DIR/images/diosix-base-linux.elf" 2>/dev/null || \
        cp "$KERNEL_ELF" "$STAGING_DIR/images/diosix-base-linux.elf"
    ln -sf diosix-base-linux.elf "$STAGING_DIR/images/default.elf"
fi

# Copy system manifest to storage disk.
if [ -f "tools/overlay-common/etc/diosix/system.toml" ]; then
    cp "tools/overlay-common/etc/diosix/system.toml" \
        "$STAGING_DIR/manifests/system.toml"
fi

cat <<'TXT' > "$STAGING_DIR/README.txt"
=== Diosix Persistent Storage Datastore ===
This filesystem provides persistent guest image storage and state volumes for
the Diosix hypervisor and Root VM (trusted host supervisor), mounted canonically
at /var/lib/diosix.

Directory structure:
  /var/lib/diosix/images/    - Base guest OS images (diosix-base-linux.elf, steward)
  /var/lib/diosix/manifests/ - Declarative domain manifests (system.toml)
  /var/lib/diosix/keys/      - Enrolled FIDO2/TPM passkeys and management keys
  /var/lib/diosix/disks/     - Persistent guest VM storage disks
TXT

# Build the ext4 filesystem directly from the staging directory in user space.
if command -v mke2fs >/dev/null 2>&1; then
    rm -f "$OUT_IMG"
    mke2fs -F -q -t ext4 -d "$STAGING_DIR" -L "DIOSIX_DATA" \
        "$OUT_IMG" "$DISK_SIZE"
    echo "Generated $OUT_IMG ($DISK_SIZE ext4 volume at /var/lib/diosix)."
else
    echo "Warning: mke2fs not found on host. Storage image skipped."
fi
