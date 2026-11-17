#!/usr/bin/env bash
#
# package_release.sh: Build standalone Diosix release bundle (.tar.xz).
#
# Usage: package_release.sh [arch] [out_dir]
#
# Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib/buildroot_common.sh
. "${SCRIPT_DIR}/lib/buildroot_common.sh"

ARCH="${1:-riscv64}"
RELEASE_ROOT="${2:-zig-out/release}"
VERSION_STR="$(tr -d ' \t\r\n' < VERSION)"
BUNDLE_NAME="diosix-${VERSION_STR}-${ARCH}"
STAGE_DIR="${RELEASE_ROOT}/${BUNDLE_NAME}"
ARCHIVE_PATH="${RELEASE_ROOT}/${BUNDLE_NAME}.tar.xz"

HV_BIN="zig-out/guest-${ARCH}/bin/vmdiosix"
ROOTVM_ELF="zig-out/guest-${ARCH}/bin/diosix-node.elf"
LIVE_IMG="zig-out/diosix-live-${ARCH}.img"

log_banner "Release Packager (${BUNDLE_NAME})"

if [ ! -f "$HV_BIN" ] || [ ! -f "$ROOTVM_ELF" ]; then
    log_err "Missing build artifacts ($HV_BIN). Run './scripts/build.sh' first."
    exit 1
fi

log_step "Building hybrid GPT live image ($LIVE_IMG)..."
bash "${SCRIPT_DIR}/make_live_image.sh" "$HV_BIN" "$ROOTVM_ELF" "$LIVE_IMG"

log_step "[1/3] Staging release bundle in ${STAGE_DIR}..."
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

cp "$HV_BIN" "${STAGE_DIR}/vmdiosix"
cp "$LIVE_IMG" "${STAGE_DIR}/diosix-live-${ARCH}.img"

cat <<'EOF' > "${STAGE_DIR}/run-diosix.sh"
#!/usr/bin/env bash
# Launch Diosix in QEMU with 1-command Desktop VM, CLI VM, or Host GUI modes.
#
# Usage:
#   ./run-diosix.sh --desktop   # Instant Wayland desktop RISC-V VM
#   ./run-diosix.sh --cli       # Instant terminal CLI RISC-V VM
#   ./run-diosix.sh --gui       # Diosix host supervisor GUI + Welcome modal
#   ./run-diosix.sh             # Auto-selects --gui on desktop hosts or --cli

set -eo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL="${DIR}/vmdiosix"
IMG="${DIR}/diosix-live-riscv64.img"

if ! command -v qemu-system-riscv64 >/dev/null 2>&1; then
    echo "Error: 'qemu-system-riscv64' is not installed." >&2
    echo "Install it via your package manager:" >&2
    echo "  Ubuntu / Debian : sudo apt install qemu-system-misc" >&2
    echo "  Fedora          : sudo dnf install qemu-system-riscv" >&2
    echo "  macOS (Homebrew): brew install qemu" >&2
    exit 1
fi

SMP=4
MEM="2G"
MODE=""
EXTRA=()

while [ $# -gt 0 ]; do
    case "$1" in
        --desktop) MODE="desktop"; shift ;;
        --cli) MODE="cli"; shift ;;
        --gui) MODE="gui"; shift ;;
        --smp) SMP="$2"; shift 2 ;;
        --mem) MEM="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) EXTRA+=("$1"); shift ;;
    esac
done

if [ -z "$MODE" ]; then
    if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ] || \
       [ "$(uname -s)" = "Darwin" ]; then
        MODE="gui"
    else
        MODE="cli"
    fi
fi

APPEND="diosix.mode=live"
USE_GUI=0
case "$MODE" in
    desktop)
        USE_GUI=1
        APPEND="diosix.mode=live diosix.intro=skip diosix.demo=desktop"
        ;;
    gui)
        USE_GUI=1
        APPEND="diosix.mode=live"
        ;;
    cli)
        USE_GUI=0
        APPEND="diosix.mode=live diosix.demo=cli"
        ;;
esac

QEMU_ARGS=(
    -M virt -cpu rv64,h=true,smstateen=true,sstc=true,v=true
    -smp "$SMP" -m "$MEM" -bios none -kernel "$KERNEL"
    -append "$APPEND"
    -drive "file=${IMG},format=raw,id=hd0,if=none"
    -device virtio-blk-device,drive=hd0
    -netdev user,id=net0 -device virtio-net-device,netdev=net0
)

if [ "$USE_GUI" -eq 1 ]; then
    DISP_BACKEND="gtk,zoom-to-fit=off"
    if [ "$(uname -s)" = "Darwin" ]; then
        DISP_BACKEND="cocoa"
    fi
    QEMU_ARGS+=(
        -display "$DISP_BACKEND"
        -device virtio-gpu-pci,xres=1280,yres=800
        -device virtio-keyboard-pci -device virtio-tablet-pci
        -serial mon:stdio
    )
else
    QEMU_ARGS+=(-nographic)
fi

exec qemu-system-riscv64 "${QEMU_ARGS[@]}" "${EXTRA[@]}"
EOF
chmod 0755 "${STAGE_DIR}/run-diosix.sh"

cat <<EOF > "${STAGE_DIR}/README-QUICKSTART.txt"
Diosix ${VERSION_STR} (${ARCH}) — Standalone Quickstart Bundle
==============================================================

Contents:
  vmdiosix                  M-mode Type-1 hypervisor + embedded Root VM
  diosix-live-${ARCH}.img   Bootable GPT live & installer disk image containing:
                              - diosix-node.elf (Unified Alpine node VM image)
                              - Alpine riscv64 .apk seed mirror + manifests
  run-diosix.sh             One-command QEMU launcher
  SHA256SUMS                SHA-256 integrity manifest

1. Prerequisites
----------------
Install QEMU's 64-bit RISC-V system emulator (QEMU 8.2+ recommended):
  Ubuntu / Debian : sudo apt install qemu-system-misc
  Fedora          : sudo dnf install qemu-system-riscv
  macOS (Homebrew): brew install qemu

2. Instant Test-Drive in QEMU
-----------------------------
  * Launch a graphical RISC-V Wayland desktop VM (2D VirtIO-GPU scanout):
      ./run-diosix.sh --desktop

  * Launch a fast console-only RISC-V Linux CLI VM in your terminal:
      ./run-diosix.sh --cli
      (Log in as 'root' when prompted; press Ctrl+] to return to the Root VM.)

  * Launch the Diosix graphical host supervisor & interactive Welcome tour:
      ./run-diosix.sh --gui

3. Bare-Metal RISC-V Hardware
-----------------------------
Flash diosix-live-${ARCH}.img to a USB drive or SD card:
  sudo dd if=diosix-live-${ARCH}.img of=/dev/sdX bs=4M status=progress \
      conv=fsync

4. Integrity Verification
-------------------------
  sha256sum -c SHA256SUMS

Documentation: https://diosix.org
EOF

log_step "[2/3] Generating SHA256SUMS..."
(
    cd "$STAGE_DIR"
    sha256sum vmdiosix "diosix-live-${ARCH}.img" \
        run-diosix.sh README-QUICKSTART.txt > SHA256SUMS
)

log_step "[3/3] Compressing ${ARCHIVE_PATH}..."
rm -f "$ARCHIVE_PATH" "${ARCHIVE_PATH}.sha256"
XZ_OPT="-T0 -6" tar -C "$RELEASE_ROOT" -cJf "$ARCHIVE_PATH" "$BUNDLE_NAME"
(
    cd "$RELEASE_ROOT"
    sha256sum "$(basename "$ARCHIVE_PATH")" \
        > "$(basename "$ARCHIVE_PATH").sha256"
)

ARCHIVE_SZ="$(du -h "$ARCHIVE_PATH" | cut -f1)"
log_ok "Release archive ready: ${BOLD}${ARCHIVE_PATH}${RESET} (${ARCHIVE_SZ})"
log_info "Checksum file : ${ARCHIVE_PATH}.sha256"
