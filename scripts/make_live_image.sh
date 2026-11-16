#!/usr/bin/env bash
#
# make_live_image.sh: Generate bootable hybrid GPT live & installer disk image.
#
# Usage: make_live_image.sh [hypervisor_bin] [kernel_elf] [out_img] [size_mb]
#
# Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/buildroot_common.sh
. "${SCRIPT_DIR}/lib/buildroot_common.sh"

HYPERVISOR_BIN="${1:-zig-out/guest-riscv64/bin/vmdiosix}"
KERNEL_ELF="${2:-zig-out/guest-riscv64/bin/rootvm.elf}"
OUT_IMG="${3:-zig-out/diosix-live-riscv64.img}"
IMAGE_SIZE_MB="${4:-640}"

log_banner "Live Image Builder"

# 1. Dependency checks.
for tool in sfdisk mkfs.vfat mcopy mmd mke2fs truncate dd; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo -e "${YELLOW}Error: Missing host utility: '$tool'${RESET}" >&2
        echo "Install dosfstools, mtools, util-linux, and e2fsprogs." >&2
        exit 1
    fi
done

if [ ! -f "$HYPERVISOR_BIN" ]; then
    echo -e "${YELLOW}Error: Missing binary at $HYPERVISOR_BIN${RESET}" >&2
    echo "Run './scripts/build.sh' first to compile the hypervisor." >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT_IMG")"
TMP_DIR=$(mktemp -d -p "$(dirname "$OUT_IMG")")
trap 'rm -rf "$TMP_DIR"' EXIT

ESP_IMG="$TMP_DIR/esp.img"
DATA_IMG="$TMP_DIR/data.img"
ESP_SIZE_MB=240
DATA_SIZE_MB=384

# 2. Build Partition 1: ESP / Boot (FAT32).
log_step "[1/4] Generating EFI System Partition (FAT32, ${ESP_SIZE_MB}MB)..."
truncate -s "${ESP_SIZE_MB}M" "$ESP_IMG"
mkfs.vfat -F 32 -n "ESP_BOOT" "$ESP_IMG" >/dev/null

mmd -i "$ESP_IMG" "::/extlinux" "::/boot" "::/EFI" "::/EFI/BOOT"

# Create standard extlinux.conf with Live, Demo, Installer, and Host entries.
EXTLINUX_CONF="$TMP_DIR/extlinux.conf"
DEMO_DT_ARGS="diosix.mode=live diosix.intro=skip diosix.demo=desktop"
DEMO_DT_ARGS="${DEMO_DT_ARGS} console=ttyS0,115200 earlycon"
DEMO_CLI_ARGS="diosix.mode=live diosix.demo=cli console=ttyS0,115200 earlycon"
cat <<EOF > "$EXTLINUX_CONF"
menu title Diosix Hypervisor Boot Menu
timeout 30
default diosix-live

label diosix-live
    menu label Diosix Bare-Metal Hypervisor (Ephemeral Live System)
    kernel /boot/vmdiosix.elf
    append diosix.mode=live console=ttyS0,115200 earlycon

label diosix-live-desktop
    menu label Diosix Instant Wayland Desktop VM (Live Test-Drive)
    kernel /boot/vmdiosix.elf
    append ${DEMO_DT_ARGS}

label diosix-live-cli
    menu label Diosix Instant Linux CLI VM (Live Test-Drive)
    kernel /boot/vmdiosix.elf
    append ${DEMO_CLI_ARGS}

label diosix-install
    menu label Diosix System Installer (Guided / Declarative)
    kernel /boot/vmdiosix.elf
    append diosix.mode=install console=ttyS0,115200 earlycon

label diosix-persistent
    menu label Diosix Persistent Host Supervisor
    kernel /boot/vmdiosix.elf
    append console=ttyS0,115200 earlycon
EOF

mcopy -i "$ESP_IMG" "$EXTLINUX_CONF" "::/extlinux/extlinux.conf"
mcopy -i "$ESP_IMG" "$HYPERVISOR_BIN" "::/boot/vmdiosix.elf"
mcopy -i "$ESP_IMG" "$HYPERVISOR_BIN" "::/EFI/BOOT/BOOTRISCV64.EFI"

# Extract flat M-mode binary (vmdiosix.bin) and U-Boot SPL FIT descriptor
# (vmdiosix.its / u-boot.itb) so U-Boot SPL on physical RISC-V boards
# (VisionFive 2, Unmatched, SpacemiT K1) boots vmdiosix directly in M-mode.
OBJCOPY_TOOL=""
for cand in llvm-objcopy riscv64-unknown-elf-objcopy \
    riscv64-linux-gnu-objcopy objcopy; do
    if command -v "$cand" >/dev/null 2>&1; then
        OBJCOPY_TOOL="$cand"
        break
    fi
done

VMDIOSIX_FLAT="$TMP_DIR/vmdiosix.bin"
if [ -n "$OBJCOPY_TOOL" ] && \
   "$OBJCOPY_TOOL" -O binary "$HYPERVISOR_BIN" "$VMDIOSIX_FLAT" \
   2>/dev/null; then
    mcopy -i "$ESP_IMG" "$VMDIOSIX_FLAT" "::/boot/vmdiosix.bin"
else
    cp "$HYPERVISOR_BIN" "$VMDIOSIX_FLAT"
    mcopy -i "$ESP_IMG" "$VMDIOSIX_FLAT" "::/boot/vmdiosix.bin"
fi

FIT_ITS="$TMP_DIR/vmdiosix.its"
cat <<'EOF' > "$FIT_ITS"
/dts-v1/;

/ {
    description = "Diosix M-Mode Bare-Metal Hypervisor FIT Image";
    #address-cells = <2>;

    images {
        opensbi {
            description = "Diosix M-Mode Hypervisor (vmdiosix.bin)";
            data = /incbin/("vmdiosix.bin");
            type = "firmware";
            os = "opensbi";
            arch = "riscv";
            compression = "none";
            load = <0x0 0x80000000>;
            entry = <0x0 0x80000000>;
        };
    };

    configurations {
        default = "config-1";
        config-1 {
            description = "Diosix M-Mode Boot Configuration";
            firmware = "opensbi";
        };
    };
};
EOF
mcopy -i "$ESP_IMG" "$FIT_ITS" "::/boot/vmdiosix.its"
OUT_DIR="$(dirname "$OUT_IMG")"
cp "$VMDIOSIX_FLAT" "$OUT_DIR/guest-riscv64/bin/vmdiosix.bin" \
    2>/dev/null || true
cp "$FIT_ITS" "$OUT_DIR/vmdiosix.its"

if command -v mkimage >/dev/null 2>&1; then
    if (cd "$TMP_DIR" && \
        mkimage -f vmdiosix.its u-boot.itb >/dev/null 2>&1); then
        mcopy -i "$ESP_IMG" "$TMP_DIR/u-boot.itb" "::/u-boot.itb"
        cp "$TMP_DIR/u-boot.itb" "$OUT_DIR/u-boot.itb"
    fi
fi

log_ok "ESP partition populated (vmdiosix.elf, vmdiosix.bin, vmdiosix.its)."

# 3. Build Partition 2: Persistent Storage Pool (ext4).
log_step "[2/4] Generating Persistent Storage (ext4, ${DATA_SIZE_MB}MB)..."
STAGING_DIR="$TMP_DIR/staging"
mkdir -p "$STAGING_DIR/images" "$STAGING_DIR/manifests" \
    "$STAGING_DIR/keys" "$STAGING_DIR/disks"
chmod 700 "$STAGING_DIR/keys"

stage_builtin_guest_images "$KERNEL_ELF" "$STAGING_DIR"

cat <<'EOF' > "$STAGING_DIR/README.txt"
=== Diosix Persistent Storage Datastore ===
This filesystem provides persistent guest image storage and state volumes for
the Diosix hypervisor and Root VM (trusted host supervisor), mounted canonically
at /var/lib/diosix.

Directory structure:
  /var/lib/diosix/images/    - Built-in guest OS images (diosix-base-linux.elf,
                               linux-cli.elf, linux-desktop.elf)
  /var/lib/diosix/manifests/ - Declarative domain manifests (system.toml)
  /var/lib/diosix/keys/      - Enrolled FIDO2/TPM passkeys and management keys
  /var/lib/diosix/disks/     - Persistent guest VM storage disks
EOF

truncate -s "${DATA_SIZE_MB}M" "$DATA_IMG"
mke2fs -F -q -t ext4 -d "$STAGING_DIR" -L "DIOSIX_DATA" \
    "$DATA_IMG" "${DATA_SIZE_MB}M"
log_ok "Storage partition created (guest images, system manifest, README)."

# 4. Assemble Hybrid GPT Disk Image.
log_step "[3/4] Assembling GPT Disk Image (${IMAGE_SIZE_MB}MB)..."
truncate -s "${IMAGE_SIZE_MB}M" "$OUT_IMG"

# Calculate partition sector ranges (512-byte sectors).
# 2MB offset for MBR/GPT header = sector 4096.
ESP_START=4096
ESP_SECTORS=$((ESP_SIZE_MB * 1024 * 1024 / 512))
DATA_START=$((ESP_START + ESP_SECTORS))
DATA_SECTORS=$((DATA_SIZE_MB * 1024 * 1024 / 512))
ESP_TYPE="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
DATA_TYPE="0FC63DE6-8442-43D4-BA40-5242857580A6"

ESP_LINE="start=${ESP_START}, size=${ESP_SECTORS}, type=${ESP_TYPE}"
ESP_LINE="${ESP_LINE}, name=\"ESP_BOOT\", bootable"
DATA_LINE="start=${DATA_START}, size=${DATA_SECTORS}, type=${DATA_TYPE}"
DATA_LINE="${DATA_LINE}, name=\"DIOSIX_DATA\""

SFDISK_SCRIPT=$(cat <<EOF
label: gpt
unit: sectors
sector-size: 512

${ESP_LINE}
${DATA_LINE}
EOF
)

printf "%s\n" "$SFDISK_SCRIPT" | sfdisk -q "$OUT_IMG" >/dev/null

log_step "[4/4] Writing partition slices to disk image..."
dd if="$ESP_IMG" of="$OUT_IMG" bs=512 seek="$ESP_START" \
    conv=notrunc status=none
dd if="$DATA_IMG" of="$OUT_IMG" bs=512 seek="$DATA_START" \
    conv=notrunc status=none
log_ok "Partitions successfully written to $OUT_IMG."

RUN_QEMU_SH="$(dirname "$OUT_IMG")/run-qemu.sh"
cat <<'EOF' > "$RUN_QEMU_SH"
#!/usr/bin/env bash
set -eo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL="${DIR}/guest-riscv64/bin/vmdiosix"
[ ! -f "$KERNEL" ] && KERNEL="${DIR}/vmdiosix"
IMG="${DIR}/diosix-live-riscv64.img"

SMP=4
MEM="2G"
MODE="live"
GUI=0
DEMO=""
EXTRA=()

while [ $# -gt 0 ]; do
    case "$1" in
        --desktop) GUI=1; DEMO="desktop"; shift ;;
        --cli) GUI=0; DEMO="cli"; shift ;;
        --gui) GUI=1; shift ;;
        --smp) SMP="$2"; shift 2 ;;
        --mem) MEM="$2"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        *) EXTRA+=("$1"); shift ;;
    esac
done

APPEND="diosix.mode=${MODE}"
if [ "$DEMO" = "desktop" ]; then
    APPEND="${APPEND} diosix.intro=skip diosix.demo=desktop"
elif [ "$DEMO" = "cli" ]; then
    APPEND="${APPEND} diosix.demo=cli"
fi

QEMU_ARGS=(
    -M virt -cpu rv64,h=true,smstateen=true,sstc=true,v=true
    -smp "$SMP" -m "$MEM" -bios none -kernel "$KERNEL"
    -append "$APPEND"
    -drive "file=${IMG},format=raw,id=hd0,if=none"
    -device virtio-blk-device,drive=hd0
    -netdev user,id=net0 -device virtio-net-device,netdev=net0
)

if [ "$GUI" -eq 1 ]; then
    QEMU_ARGS+=(
        -display gtk,zoom-to-fit=off
        -device virtio-gpu-pci,xres=1280,yres=800
        -device virtio-keyboard-pci -device virtio-tablet-pci
        -serial mon:stdio
    )
else
    QEMU_ARGS+=(-nographic)
fi

exec qemu-system-riscv64 "${QEMU_ARGS[@]}" "${EXTRA[@]}"
EOF
chmod +x "$RUN_QEMU_SH"

echo ""
echo -e "${BOLD}${GREEN}✓ Live & Installer disk image built!${RESET}"
IMG_SZ=$(du -h "$OUT_IMG" | cut -f1)
echo -e "    ${DIM}->${RESET} Output image  : ${BOLD}$OUT_IMG${RESET} ($IMG_SZ)"
FLASH_CMD="sudo dd if=$OUT_IMG of=/dev/sdX bs=4M status=progress conv=fsync"
echo -e "    ${DIM}->${RESET} Flash command : ${CYAN}${FLASH_CMD}${RESET}"
QEMU_CMD="./scripts/build.sh run-live"
echo -e "    ${DIM}->${RESET} QEMU test     : ${CYAN}${QEMU_CMD}${RESET}"
echo ""
