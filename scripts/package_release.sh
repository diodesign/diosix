#!/usr/bin/env bash
#
# package_release.sh: Build standalone edition and libdiosix SDK bundles.
#
# Usage: package_release.sh [arch] [edition] [out_dir]
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
EDITION="${2:-swarm}"
RELEASE_ROOT="${3:-zig-out/release}"

case "$EDITION" in
    core|swarm|personal) ;;
    *)
        log_err "Invalid edition '$EDITION' (expected core|swarm|personal)."
        exit 1
        ;;
esac

VERSION_STR="$(tr -d ' \t\r\n' < VERSION)"
BUNDLE_NAME="diosix-${VERSION_STR}-${EDITION}-${ARCH}"
STAGE_DIR="${RELEASE_ROOT}/${BUNDLE_NAME}"
ARCHIVE_PATH="${RELEASE_ROOT}/${BUNDLE_NAME}.tar.xz"

SDK_SRC_DIR="zig-out/sdk-${ARCH}"
SDK_NAME="libdiosix-${VERSION_STR}-${ARCH}"
SDK_STAGE_DIR="${RELEASE_ROOT}/${SDK_NAME}"
SDK_ARCHIVE_PATH="${RELEASE_ROOT}/${SDK_NAME}.tar.xz"

HV_BIN="zig-out/guest-${ARCH}/bin/vmdiosix"
ROOTVM_ELF="zig-out/guest-${ARCH}/bin/diosix-node.elf"
LIVE_IMG="zig-out/diosix-live-${ARCH}.img"

log_banner "Release Packager (${BUNDLE_NAME})"

if [ ! -f "$HV_BIN" ] || [ ! -f "$ROOTVM_ELF" ]; then
    log_err "Missing artifacts ($HV_BIN). Run './scripts/build.sh' first."
    exit 1
fi

if [ ! -f "${SDK_SRC_DIR}/lib/libdiosix.a" ] || \
   [ ! -f "${SDK_SRC_DIR}/lib/libdiosix.so" ]; then
    log_step "Building libdiosix SDK (${SDK_SRC_DIR})..."
    ./scripts/build.sh sdk -Dguest-arch="${ARCH}"
fi

log_step "Building hybrid GPT live image ($LIVE_IMG)..."
bash "${SCRIPT_DIR}/make_live_image.sh" "$HV_BIN" "$ROOTVM_ELF" "$LIVE_IMG"

log_step "[1/4] Staging edition bundle in ${STAGE_DIR}..."
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

cp "$HV_BIN" "${STAGE_DIR}/vmdiosix"
cp "$LIVE_IMG" "${STAGE_DIR}/diosix-live-${ARCH}.img"

cat <<'EOF' > "${STAGE_DIR}/run-diosix.sh"
#!/usr/bin/env bash
# Launch headless Diosix in QEMU with SSH forwarded on localhost.
#
# Usage:
#   ./run-diosix.sh                 # Boot live supervisor (SSH on port 2222)
#   ./run-diosix.sh --cli           # Boot into interactive Linux CLI child VM
#   ./run-diosix.sh --ssh-port 2223 # Forward host TCP port 2223 to guest :22

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
SSH_PORT="2222"
MODE=""
EXTRA=()

while [ $# -gt 0 ]; do
    case "$1" in
        --cli) MODE="cli"; shift ;;
        --ssh-port) SSH_PORT="$2"; shift 2 ;;
        --smp) SMP="$2"; shift 2 ;;
        --mem) MEM="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) EXTRA+=("$1"); shift ;;
    esac
done

APPEND="diosix.mode=live"
if [ "$MODE" = "cli" ]; then
    APPEND="diosix.mode=live diosix.demo=cli"
fi

exec qemu-system-riscv64 \
    -M virt -cpu rv64,h=true,smstateen=true,sstc=true,v=true \
    -smp "$SMP" -m "$MEM" -nographic -bios none -kernel "$KERNEL" \
    -append "$APPEND" \
    -drive "file=${IMG},format=raw,id=hd0,if=none" \
    -device virtio-blk-device,drive=hd0 \
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
    -device virtio-net-device,netdev=net0 "${EXTRA[@]}"
EOF
chmod 0755 "${STAGE_DIR}/run-diosix.sh"

cat <<EOF > "${STAGE_DIR}/README-QUICKSTART.txt"
Diosix ${VERSION_STR} (${EDITION} / ${ARCH}) — Standalone Quickstart Bundle
======================================================================

Contents:
  vmdiosix                  M-mode Type-1 hypervisor + embedded Root VM
  diosix-live-${ARCH}.img   Bootable GPT live & installer disk image containing:
                              - diosix-node.elf (${EDITION} Alpine node image)
                              - Alpine riscv64 .apk seed mirror + manifests
  run-diosix.sh             Headless SSH-first QEMU launcher
  SHA256SUMS                SHA-256 integrity manifest

1. Prerequisites
----------------
Install QEMU's 64-bit RISC-V system emulator (QEMU 8.2+ recommended):
  Ubuntu / Debian : sudo apt install qemu-system-misc
  Fedora          : sudo dnf install qemu-system-riscv
  macOS (Homebrew): brew install qemu

2. Instant Test-Drive in QEMU (SSH & Serial Console)
----------------------------------------------------
  * Boot the live hypervisor & Root VM with SSH forwarded on port 2222:
      ./run-diosix.sh

  * Connect via SSH once booted (or manage on the serial console):
      ssh -p 2222 root@127.0.0.1

  * Boot directly into an interactive Linux CLI child VM on console:
      ./run-diosix.sh --cli

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

log_step "[2/4] Staging libdiosix SDK in ${SDK_STAGE_DIR}..."
rm -rf "$SDK_STAGE_DIR"
mkdir -p "${SDK_STAGE_DIR}/lib/pkgconfig" "${SDK_STAGE_DIR}/include" \
    "${SDK_STAGE_DIR}/examples"
cp -f "${SDK_SRC_DIR}/lib/libdiosix.a" "${SDK_STAGE_DIR}/lib/libdiosix.a"
cp -f "${SDK_SRC_DIR}/lib/libdiosix.so" "${SDK_STAGE_DIR}/lib/libdiosix.so"
cp -f "${SDK_SRC_DIR}/lib/pkgconfig/diosix.pc" \
    "${SDK_STAGE_DIR}/lib/pkgconfig/diosix.pc"
cp -f "${SDK_SRC_DIR}/include/diosix.h" "${SDK_STAGE_DIR}/include/diosix.h"
cp -f "${SDK_SRC_DIR}/examples/vm_info.c" \
    "${SDK_STAGE_DIR}/examples/vm_info.c"

cat <<EOF > "${SDK_STAGE_DIR}/README.txt"
libdiosix ${VERSION_STR} (${ARCH}-linux-musl) — Userland Hypervisor SDK
=====================================================================

Static and shared libraries for making SBI hypercalls via /dev/diosix
from C, C++, Zig, or FFI userland programs inside Diosix guests.

Compile and link the example statically:
  zig cc -target ${ARCH}-linux-musl -Iinclude \\
      examples/vm_info.c lib/libdiosix.a -o vm_info

Or dynamically inside a guest with libdiosix.so installed:
  cc \$(pkg-config --cflags --libs diosix) examples/vm_info.c -o vm_info
EOF

log_step "[3/4] Generating SHA256SUMS manifests..."
(
    cd "$STAGE_DIR"
    sha256sum vmdiosix "diosix-live-${ARCH}.img" \
        run-diosix.sh README-QUICKSTART.txt > SHA256SUMS
)
(
    cd "$SDK_STAGE_DIR"
    sha256sum include/diosix.h lib/libdiosix.a lib/libdiosix.so \
        lib/pkgconfig/diosix.pc examples/vm_info.c README.txt > SHA256SUMS
)

log_step "[4/4] Compressing release tarballs..."
rm -f "$ARCHIVE_PATH" "${ARCHIVE_PATH}.sha256" \
    "$SDK_ARCHIVE_PATH" "${SDK_ARCHIVE_PATH}.sha256"
XZ_OPT="-T0 -6" tar -C "$RELEASE_ROOT" -cJf "$ARCHIVE_PATH" "$BUNDLE_NAME"
XZ_OPT="-T0 -6" tar -C "$RELEASE_ROOT" -cJf "$SDK_ARCHIVE_PATH" "$SDK_NAME"
(
    cd "$RELEASE_ROOT"
    sha256sum "$(basename "$ARCHIVE_PATH")" \
        > "$(basename "$ARCHIVE_PATH").sha256"
    sha256sum "$(basename "$SDK_ARCHIVE_PATH")" \
        > "$(basename "$SDK_ARCHIVE_PATH").sha256"
)

ARCHIVE_SZ="$(du -h "$ARCHIVE_PATH" | cut -f1)"
SDK_SZ="$(du -h "$SDK_ARCHIVE_PATH" | cut -f1)"
log_ok "Edition archive : ${BOLD}${ARCHIVE_PATH}${RESET} (${ARCHIVE_SZ})"
log_ok "SDK archive     : ${BOLD}${SDK_ARCHIVE_PATH}${RESET} (${SDK_SZ})"
