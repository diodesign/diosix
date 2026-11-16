#!/usr/bin/env bash
#
# create_storage_disk.sh: Generate ext4 storage disk image for Diosix VMs.
#
# Usage: create_storage_disk.sh <kernel_elf> <out_img> [size] [extra_iso_dir]
#
# Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/buildroot_common.sh
. "${SCRIPT_DIR}/lib/buildroot_common.sh"

KERNEL_ELF="$1"
OUT_IMG="$2"
DISK_SIZE="${3:-1024M}"
EXTRA_ISO_DIR="${4:-}"

if [ -z "$KERNEL_ELF" ] || [ -z "$OUT_IMG" ]; then
    echo "Usage: $0 <kernel_elf> <out_img> [size] [extra_iso_dir]"
    exit 1
fi

mkdir -p "$(dirname "$OUT_IMG")" .zig-cache
STAGING_DIR=".zig-cache/storage-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/images" "$STAGING_DIR/manifests" \
    "$STAGING_DIR/keys"
chmod 700 "$STAGING_DIR/keys"

# Zero-toil developer passkey staging for diosix.mode=dev (never written into
# production authorized_passkeys at build time).
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
    fi
done
sort -u "$DEV_AUTH" -o "$DEV_AUTH" 2>/dev/null || true
chmod 600 "$DEV_AUTH" "$PASS_AUTH" 2>/dev/null || true

# Copy kernel, built-in guest images, and stamped manifests onto storage disk.
stage_builtin_guest_images "$KERNEL_ELF" "$STAGING_DIR"

# Stage optional ISO media directory into /var/lib/diosix/iso.
CATALOG_TOML="tools/overlay-common/etc/diosix/catalog.toml"
if [ -n "$EXTRA_ISO_DIR" ] && [ -d "$EXTRA_ISO_DIR" ]; then
    mkdir -p "$STAGING_DIR/iso"
    for iso_file in "$EXTRA_ISO_DIR"/*.iso; do
        [ -f "$iso_file" ] || continue
        iso_base="$(basename "$iso_file")"
        if [ -f "$CATALOG_TOML" ] && command -v sha256sum >/dev/null 2>&1; then
            exp_hash="$(awk -v fn="\"$iso_base\"" '
                $1 == "filename" && $3 == fn { found = 1 }
                found && $1 == "sha256" {
                    gsub(/"/, "", $3); print $3; exit
                }
            ' "$CATALOG_TOML")"
            if [ -n "$exp_hash" ]; then
                got_hash="$(sha256sum "$iso_file" | awk '{print $1}')"
                if [ "$got_hash" != "$exp_hash" ]; then
                    echo "Error: SHA-256 mismatch for $iso_file" >&2
                    exit 1
                fi
            fi
        fi
        cp "$iso_file" "$STAGING_DIR/iso/"
    done
fi

cat <<'TXT' > "$STAGING_DIR/README.txt"
=== Diosix Persistent Storage Datastore ===
This filesystem provides persistent guest image storage and state volumes for
the Diosix hypervisor and Root VM (trusted host supervisor), mounted at
/var/lib/diosix.

Directory structure:
  /var/lib/diosix/images/    - Built-in guest OS images (diosix-base-linux.elf,
                               linux-cli.elf, linux-desktop.elf)
  /var/lib/diosix/iso/       - Guest OS installer and live ISO images
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
