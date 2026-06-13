#!/usr/bin/env bash
# BuildRoot integration script for Diosix
#
# Usage: build_rootvm.sh <path_to_config> <path_to_output_binary> <path_to_buildroot_dir>

set -e

CONFIG_FILE="$1"
OUT_FILE="$2"
BUILDROOT_DIR="$3"
BUILDROOT_URL="https://gitlab.com/buildroot.org/buildroot.git"
BUILDROOT_BRANCH="2026.02.x"

if [ -z "$CONFIG_FILE" ] || [ -z "$OUT_FILE" ] || [ -z "$BUILDROOT_DIR" ]; then
    echo "Usage: $0 <config_file> <out_file> <buildroot_dir> [guest_arch]"
    exit 1
fi

GUEST_ARCH="${4:-riscv64}"

HASH_FILE="${OUT_FILE}.sha256"
CURRENT_HASH=$(sha256sum "$CONFIG_FILE" "$0" | sha256sum | cut -d' ' -f1)

# Check if a rebuild is necessary using the configuration hash.
if [ -f "$OUT_FILE" ] && [ -f "$HASH_FILE" ]; then
    RECORDED_HASH=$(cat "$HASH_FILE")
    if [ "$CURRENT_HASH" = "$RECORDED_HASH" ]; then
        echo "Root VM binary is up to date. Skipping BuildRoot."
        exit 0
    fi
fi


echo "Root VM binary missing or outdated. Running BuildRoot..."

# Get BuildRoot
if [ ! -d "$BUILDROOT_DIR/.git" ]; then
    echo "Cloning BuildRoot ($BUILDROOT_BRANCH) into $BUILDROOT_DIR..."
    git clone --depth 1 -b "$BUILDROOT_BRANCH" "$BUILDROOT_URL" "$BUILDROOT_DIR"
fi

# Need to provide absolute path for defconfig if it's outside
ABS_CONFIG=$(realpath "$CONFIG_FILE")

# Configure BuildRoot, tracking version changes to trigger clean rebuilds
if [ -f "$BUILDROOT_DIR/.config" ]; then
    cp "$BUILDROOT_DIR/.config" "$BUILDROOT_DIR/.config.old"
fi

echo "Configuring BuildRoot..."
make -C "$BUILDROOT_DIR" BR2_DEFCONFIG="$ABS_CONFIG" defconfig

# Enforce the use of the appropriate console for the root login prompt
GETTY_PORT="hvc0"
if [ "$GUEST_ARCH" = "aarch64" ]; then
    GETTY_PORT="ttyAMA0"
elif [ "$GUEST_ARCH" = "x86_64" ]; then
    GETTY_PORT="ttyS0"
fi
echo "BR2_TARGET_GENERIC_GETTY_PORT=\"$GETTY_PORT\"" >> "$BUILDROOT_DIR/.config"

# Fixup step for modern buildroot: olddefconfig updates the config for new versions silently
make -C "$BUILDROOT_DIR" olddefconfig

if [ -f "$BUILDROOT_DIR/.config.old" ]; then
    OLD_KV=$(grep -E '^BR2_LINUX_KERNEL_VERSION=' "$BUILDROOT_DIR/.config.old" | cut -d'"' -f2)
    NEW_KV=$(grep -E '^BR2_LINUX_KERNEL_VERSION=' "$BUILDROOT_DIR/.config" | cut -d'"' -f2)
    if [ "$OLD_KV" != "$NEW_KV" ] && [ -n "$OLD_KV" ]; then
        echo "Linux kernel version changed from '$OLD_KV' to '$NEW_KV'. Cleaning old kernel build..."
        make -C "$BUILDROOT_DIR" linux-dirclean linux-headers-dirclean
    fi
    rm "$BUILDROOT_DIR/.config.old"
fi

# Detect wget2 (e.g. Fedora 39+) which dropped --passive-ftp support.
# BuildRoot's download rules pass --passive-ftp by default and will fail
# if the system wget is actually wget2. Override BR2_WGET in that case.
WGET_EXTRA_ARGS=""
if wget --version 2>&1 | head -1 | grep -q "Wget2"; then
    echo "Detected wget2: overriding BR2_WGET to drop --passive-ftp..."
    WGET_EXTRA_ARGS='BR2_WGET="wget -nd -t 3"'
fi

# Build it
echo "Building Root VM (this may take a while)..."
eval make -C "$BUILDROOT_DIR" -j"$(nproc)" $WGET_EXTRA_ARGS

# Ensure the output directory exists
mkdir -p "$(dirname "$OUT_FILE")"

# The output from a RISC-V buildroot Linux build with BR2_LINUX_KERNEL_VMLINUX=y is usually output/images/vmlinux
IMAGE_PATH="$BUILDROOT_DIR/output/images/vmlinux"
if [ ! -f "$IMAGE_PATH" ]; then
    echo "Error: BuildRoot finished but expected output image '$IMAGE_PATH' was not found!"
    exit 1
fi

echo "Copying built image to $OUT_FILE..."
cp "$IMAGE_PATH" "$OUT_FILE"
echo "$CURRENT_HASH" > "$HASH_FILE"

echo "Root VM build complete!"


