#!/usr/bin/env bash
#
# make_live_image.sh: Generate bootable hybrid GPT live & installer disk image for Diosix
#
# Usage: make_live_image.sh [hypervisor_bin] [kernel_elf] [output_img] [image_size_mb]
#
# Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

set -eo pipefail

HYPERVISOR_BIN="${1:-zig-out/guest-riscv64/bin/vmdiosix}"
KERNEL_ELF="${2:-zig-out/guest-riscv64/bin/rootvm.elf}"
OUT_IMG="${3:-zig-out/diosix-live-riscv64.img}"
IMAGE_SIZE_MB="${4:-512}"

# Terminal Formatting
BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
CYAN="\033[36m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

log_banner() {
    echo -e "${BOLD}${BLUE}=== Diosix Live & Installer Image Builder ===${RESET}"
}

log_step() {
    echo -e "${BOLD}${CYAN}==>${RESET} ${BOLD}$1${RESET}"
}

log_info() {
    echo -e "    ${DIM}->${RESET} $1"
}

log_ok() {
    echo -e "    ${GREEN}✓${RESET} $1"
}

log_warn() {
    echo -e "    ${YELLOW}!${RESET} $1"
}

log_banner

# 1. Dependency checks
for tool in sfdisk mkfs.vfat mcopy mmd mke2fs truncate dd; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo -e "${YELLOW}Error: Missing required host utility: '$tool'${RESET}" >&2
        echo "Please install dosfstools, mtools, util-linux, and e2fsprogs." >&2
        exit 1
    fi
done

if [ ! -f "$HYPERVISOR_BIN" ]; then
    echo -e "${YELLOW}Error: Hypervisor binary not found at $HYPERVISOR_BIN${RESET}" >&2
    echo "Run './scripts/build.sh' first to compile the hypervisor." >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT_IMG")"
TMP_DIR=$(mktemp -d -p "$(dirname "$OUT_IMG")")
trap 'rm -rf "$TMP_DIR"' EXIT

ESP_IMG="$TMP_DIR/esp.img"
DATA_IMG="$TMP_DIR/data.img"
ESP_SIZE_MB=128
DATA_SIZE_MB=256

# 2. Build Partition 1: ESP / Boot (FAT32)
log_step "[1/4] Generating EFI System & Boot Partition (FAT32, ${ESP_SIZE_MB}MB)..."
truncate -s "${ESP_SIZE_MB}M" "$ESP_IMG"
mkfs.vfat -F 32 -n "ESP_BOOT" "$ESP_IMG" >/dev/null

mmd -i "$ESP_IMG" "::/extlinux" "::/boot" "::/EFI" "::/EFI/BOOT"

# Create standard extlinux.conf
EXTLINUX_CONF="$TMP_DIR/extlinux.conf"
cat <<'EOF' > "$EXTLINUX_CONF"
menu title Diosix Hypervisor Boot Menu
timeout 30
default diosix-live

label diosix-live
    menu label Diosix Bare-Metal Hypervisor (Live System)
    kernel /boot/vmdiosix.elf
    append console=ttyS0,115200 earlycon
EOF

mcopy -i "$ESP_IMG" "$EXTLINUX_CONF" "::/extlinux/extlinux.conf"
mcopy -i "$ESP_IMG" "$HYPERVISOR_BIN" "::/boot/vmdiosix.elf"
mcopy -i "$ESP_IMG" "$HYPERVISOR_BIN" "::/EFI/BOOT/BOOTRISCV64.EFI"
log_ok "ESP partition populated (extlinux.conf, vmdiosix.elf, BOOTRISCV64.EFI)."

# 3. Build Partition 2: Persistent Storage Pool (ext4)
log_step "[2/4] Generating Persistent Storage Volume (ext4, ${DATA_SIZE_MB}MB)..."
STAGING_DIR="$TMP_DIR/staging"
mkdir -p "$STAGING_DIR/images" "$STAGING_DIR/manifests"

if [ -f "$KERNEL_ELF" ]; then
    STRIP_TOOL="strip"
    if command -v riscv64-buildroot-linux-gnu-strip >/dev/null 2>&1; then
        STRIP_TOOL="riscv64-buildroot-linux-gnu-strip"
    elif [ -x "zig-out/buildroot-riscv64/output/host/bin/riscv64-buildroot-linux-gnu-strip" ]; then
        STRIP_TOOL="zig-out/buildroot-riscv64/output/host/bin/riscv64-buildroot-linux-gnu-strip"
    fi
    "$STRIP_TOOL" -s "$KERNEL_ELF" -o "$STAGING_DIR/images/linux-guest.elf" 2>/dev/null || cp "$KERNEL_ELF" "$STAGING_DIR/images/linux-guest.elf"
    ln -sf "linux-guest.elf" "$STAGING_DIR/images/default.elf"
fi

if [ -f "tools/overlay-common/etc/diosix/system.toml" ]; then
    cp "tools/overlay-common/etc/diosix/system.toml" "$STAGING_DIR/manifests/system.toml"
fi

cat <<'EOF' > "$STAGING_DIR/README.txt"
=== Diosix Persistent Storage Datastore ===
This filesystem provides persistent guest image storage and state volumes for the
Diosix hypervisor and Root VM (Domain 0), mounted canonically at /var/lib/diosix.

Directory structure:
  /var/lib/diosix/images/      - Base guest OS images (e.g. linux-guest.elf)
  /var/lib/diosix/manifests/   - Declarative domain manifest files (system.toml)
  /var/lib/diosix/volumes/     - Persistent guest VM storage disks (upcoming)
EOF

truncate -s "${DATA_SIZE_MB}M" "$DATA_IMG"
mke2fs -F -q -t ext4 -d "$STAGING_DIR" -L "DIOSIX_DATA" "$DATA_IMG" "${DATA_SIZE_MB}M"
log_ok "Storage partition created (guest images, system manifest, README)."

# 4. Assemble Hybrid GPT Disk Image
log_step "[3/4] Assembling GUID Partition Table (GPT) Disk Image (${IMAGE_SIZE_MB}MB)..."
truncate -s "${IMAGE_SIZE_MB}M" "$OUT_IMG"

# Calculate partition sector ranges (512-byte sectors)
# 2MB offset for MBR/GPT header = sector 4096
ESP_START=4096
ESP_SECTORS=$((ESP_SIZE_MB * 1024 * 1024 / 512))
DATA_START=$((ESP_START + ESP_SECTORS))
DATA_SECTORS=$((DATA_SIZE_MB * 1024 * 1024 / 512))

SFDISK_SCRIPT=$(cat <<EOF
label: gpt
unit: sectors
sector-size: 512

start=${ESP_START}, size=${ESP_SECTORS}, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="ESP_BOOT", bootable
start=${DATA_START}, size=${DATA_SECTORS}, type=0FC63DE6-8442-43D4-BA40-5242857580A6, name="DIOSIX_DATA"
EOF
)

printf "%s\n" "$SFDISK_SCRIPT" | sfdisk -q "$OUT_IMG" >/dev/null

log_step "[4/4] Writing partition slices to disk image..."
dd if="$ESP_IMG" of="$OUT_IMG" bs=512 seek="$ESP_START" conv=notrunc status=none
dd if="$DATA_IMG" of="$OUT_IMG" bs=512 seek="$DATA_START" conv=notrunc status=none
log_ok "Partitions successfully written to $OUT_IMG."

echo ""
echo -e "${BOLD}${GREEN}✓ Live & Installer disk image built successfully!${RESET}"
echo -e "    ${DIM}->${RESET} Output image  : ${BOLD}$OUT_IMG${RESET} ($(du -h "$OUT_IMG" | cut -f1))"
echo -e "    ${DIM}->${RESET} Flash command : ${CYAN}sudo dd if=$OUT_IMG of=/dev/sdX bs=4M status=progress conv=fsync${RESET}"
echo -e "    ${DIM}->${RESET} QEMU test     : ${CYAN}./scripts/build.sh run-live${RESET}"
echo ""
