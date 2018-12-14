#!/bin/bash
#
# (c) Chris Williams, 2018. See LICENSE for usage and copying terms.

# setup the build environment for the given target. we can't do this
# entirely from within cargo due to crucial missing features.
# see this thread for more information:
# https://users.rust-lang.org/t/does-target-cfg-in-cargo-config-not-support-user-supplied-features/20275

# syntax: ./build.sh [--debug] --triple [build triple] --platform [target platform]
#
# eg: ./build.sh --triple riscv32imac-unknown-none-elf --platform sifive_u34
#
# supported build triples:
# riscv32imac-unknown-none-elf (32bit RISC-V integer-only with atomics)
#
# supported target platforms:
# sifive_u34 (SiFive-U34 RV32 series)
# qemu_virt (Qemu Virt hardware environment)
#
# Debug mode: --debug switches to a debug build, otherwise a release build is created
# as well as adding extra debug info to the kernel executable, --debug also enables kdebug!() output
#

# process command line arguments
while [[ $# -gt 0 ]]
do
SETTING="$1"

case $SETTING in
    -t|--triple)
    TRIPLE="$2"
    shift # past argument
    shift # past value
    ;;
    -p|--platform)
    PLATFORM="$2"
    shift # past argument
    shift # past value
    ;;
    -d|--debug)
    DEBUG_MODE="(DEBUG ENABLED)"
    shift # past argument
    ;;
esac
done

# sanity chacks...
if [[ $TRIPLE == "" || $PLATFORM == "" ]]; then
  echo "Usage: build.sh [--debug] --triple [build triple] --platform [target platform]"
  exit 1
fi

# ...and also tidy up triples to CPU_ARCH directory
case $TRIPLE in
  riscv32*)
  CPU_ARCH=riscv32
  ;;
  *)
  echo "[-] Unsupported build triple '${TRIPLE}'"
  exit 1
esac

case $PLATFORM in
  sifive_u34)
  echo "[+] Building for ${CPU_ARCH} SiFive Freedom U34 series ${DEBUG_MODE}"
  ;;
  qemu32_virt)
  echo "[+] Building for ${CPU_ARCH} Qemu Virt environment ${DEBUG_MODE}"
  ;;
  *)
  echo "[-] Unsupported platform '${PLATFORM}'"
  exit 1
esac

# build correct Cargo manifest from common settings and platform config
cat cargoes/Cargo.toml.common cargoes/Cargo.toml.${PLATFORM} > Cargo.toml

# we can't do this from cargo, have to set it outside the toolchain
export RUSTFLAGS="-C link-arg=-Tsrc/platform/${CPU_ARCH}/${PLATFORM}/link.ld"

# invoke the compiler toolchain, enabling debug mode if required
if [[ -z $DEBUG_MODE ]]
then
  cargo build --release --target $TRIPLE --features $PLATFORM
else
  cargo build --target $TRIPLE --features $PLATFORM
fi
