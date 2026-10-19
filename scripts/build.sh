#!/usr/bin/env bash

# Diosix build wrapper
#
# Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

# Exit immediately if a command exits with a non-zero status
set -e

# Gather metadata
GIT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "unknown")
GIT_REVISION=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
ZIG_VERSION=$(zig version 2>/dev/null || echo "unknown")
BUILD_USER=$(whoami 2>/dev/null || echo "unknown")
BUILD_HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
BUILD_DATE=$(date 2>/dev/null || echo "unknown")

# Load M-mode hypervisor build-time configuration defaults if present
if [ -f "boot/hypervisor.conf" ]; then
    # shellcheck source=/dev/null
    source "boot/hypervisor.conf"
fi

# Add optional QEMU CPU override from host environment
# Parse command line arguments for --debug
BUILD_ARGS=()
for arg in "$@"; do
    if [ "$arg" == "--debug" ]; then
        BUILD_ARGS+=("-Doptimize=Debug" "-Dgdb=true")
    else
        BUILD_ARGS+=("$arg")
    fi
done

# Forward to zig build with metadata and hypervisor.conf options
exec zig build \
  -Dgit_branch="$GIT_BRANCH" \
  -Dgit_revision="$GIT_REVISION" \
  -Dzig_version="$ZIG_VERSION" \
  -Dbuild_user="$BUILD_USER" \
  -Dbuild_hostname="$BUILD_HOSTNAME" \
  -Dbuild_date="$BUILD_DATE" \
  -Droot-ram-min-mb="${ROOT_RAM_MIN_MB:-128}" \
  -Droot-ram-max-mb="${ROOT_RAM_MAX_MB:-256}" \
  -Droot-ram-divisor="${ROOT_RAM_HOST_DIVISOR:-8}" \
  -Droot-vcpus-max="${ROOT_VCPUS_MAX:-4}" \
  "${BUILD_ARGS[@]}"
