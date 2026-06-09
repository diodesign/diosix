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

# Add optional QEMU CPU override from host environment
EXTRA_ARGS=()
if [ -n "$DIOSIX_QEMU_CPU" ]; then
    EXTRA_ARGS+=("-Dqemu-cpu=$DIOSIX_QEMU_CPU")
fi

# Forward to zig build with metadata options
exec zig build \
  -Dgit_branch="$GIT_BRANCH" \
  -Dgit_revision="$GIT_REVISION" \
  -Dzig_version="$ZIG_VERSION" \
  -Dbuild_user="$BUILD_USER" \
  -Dbuild_hostname="$BUILD_HOSTNAME" \
  -Dbuild_date="$BUILD_DATE" \
  "${EXTRA_ARGS[@]}" \
  "$@"
