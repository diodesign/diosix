#!/usr/bin/env bash

# Build the Unicorn Engine static library using CMake.
#
# This script wraps the CMake configure + build steps with:
#   - Output redirection to a log file
#   - Clean status reporting (success/failure only)
#   - Incremental builds: configure only runs when CMakeCache.txt is
#     absent, and cmake --build only recompiles changed sources
#   - Stable compiler wrapper (only recreated when content changes)
#
# Usage: build_unicorn.sh <zig-exe-path> <build-dir>
#
# Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

ZIG_EXE="$1"
BUILD_DIR="$2"
SOURCE_DIR="third_party/unicorn"
LOG_FILE="${BUILD_DIR}/build.log"
ZIG_CC="zig-out/zig-cc"

if [ -z "$ZIG_EXE" ] || [ -z "$BUILD_DIR" ]; then
    echo "Usage: $0 <zig-exe-path> <build-dir>"
    exit 1
fi

mkdir -p zig-out "$BUILD_DIR"

# Create the zig-cc compiler wrapper only if it doesn't exist or its
# content has changed. Preserving the file's mtime prevents CMake from
# triggering a full recompile of every source file on each build run.
WRAPPER_CONTENT="#!/bin/sh
exec \"${ZIG_EXE}\" cc -target riscv64-linux-musl -fno-sanitize=all \"\$@\""

if [ ! -f "$ZIG_CC" ] || [ "$(cat "$ZIG_CC")" != "$WRAPPER_CONTENT" ]; then
    echo "$WRAPPER_CONTENT" > "$ZIG_CC"
    chmod +x "$ZIG_CC"
fi

ZIG_CC_ABS="$(realpath "$ZIG_CC")"

echo "Building Unicorn Engine..."

# Configure: only run if CMakeCache.txt does not exist (first build or
# after a clean). Unicorn's CMakeLists.txt runs expensive configure-time
# scripts that re-detect the compiler and regenerate build rules, so
# skipping this step on repeat builds avoids a full recompile.
if [ ! -f "${BUILD_DIR}/CMakeCache.txt" ]; then
    if ! cmake \
        -S "$SOURCE_DIR" \
        -B "$BUILD_DIR" \
        -DCMAKE_SYSTEM_NAME=Generic \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DCMAKE_C_COMPILER="$ZIG_CC_ABS" \
        -DCMAKE_C_FLAGS="-DUNICORN_NO_SYSTEM" \
        "-DUNICORN_ARCH=arm;aarch64;m68k;mips;ppc;riscv;s390x;sparc;tricore;x86" \
        -DUNICORN_BUILD_SHARED=OFF \
        -DUNICORN_BUILD_STATIC=ON \
        >> "$LOG_FILE" 2>&1; then
        echo "Unicorn Engine configure failed. See log: $LOG_FILE"
        exit 1
    fi
fi

# Build: cmake --build checks object file timestamps and only recompiles
# sources that changed since the last build.
if ! cmake \
    --build "$BUILD_DIR" \
    --config Release \
    --parallel \
    >> "$LOG_FILE" 2>&1; then
    echo "Unicorn Engine build failed. See log: $LOG_FILE"
    exit 1
fi

# Compile the Diosix-side glue file that bridges Unicorn's internal
# riscv_cpu_set_rdtime_fn API. This uses the same compiler and include
# paths as Unicorn's riscv32 target to ensure correct symbol naming.
GLUE_SRC="hypervisor/core/unicorn.c"
GLUE_OBJ="${BUILD_DIR}/unicorn_glue.o"
if [ "$GLUE_SRC" -nt "$GLUE_OBJ" ]; then
    if ! "$ZIG_CC_ABS" \
        -DNEED_CPU_H -DUNICORN_NO_SYSTEM \
        -include "${SOURCE_DIR}/qemu/riscv32.h" \
        -I "${BUILD_DIR}" \
        -I "${BUILD_DIR}/riscv32-softmmu" \
        -I "${SOURCE_DIR}/glib_compat" \
        -I "${SOURCE_DIR}/qemu" \
        -I "${SOURCE_DIR}/qemu/include" \
        -I "${SOURCE_DIR}/include" \
        -I "${SOURCE_DIR}/qemu/tcg" \
        -I "${SOURCE_DIR}/qemu/tcg/riscv" \
        -I "${SOURCE_DIR}/qemu/target/riscv" \
        -std=gnu11 -fPIC \
        -c "$GLUE_SRC" -o "$GLUE_OBJ" \
        >> "$LOG_FILE" 2>&1; then
        echo "Unicorn glue compilation failed. See log: $LOG_FILE"
        exit 1
    fi
fi

echo "Unicorn Engine build OK"

