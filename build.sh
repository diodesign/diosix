#!/bin/bash
#
# (c) Chris Williams, 2018. See LICENSE for usage and copying terms.

# setup the build environment for the given target. we can't do this
# entirely from within cargo due to crucial missing features.
# see this thread for more information:
# https://users.rust-lang.org/t/does-target-cfg-in-cargo-config-not-support-user-supplied-features/20275

# syntax: ./build.sh --triple [build triple] --platform [target platform]
#
# eg: ./build.sh --triple riscv32imac-unknown-none-elf --platform sifive_e
#
# supported build triples:
# riscv32imac-unknown-none-elf (32bit RISC-V integer-only with atomics)
#
# supported target platforms:
# sifive_e (SiFive-E300 series)
# spike (Spike emulator)

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
esac
done

# sanity chacks...
if [[ $TRIPLE == "" || $PLATFORM == "" ]]; then
  echo "Usage: build.sh --triple [build triple] --platform [target platform]"
  exit 1
fi

# ...and also tidy up triples to CPU_ARCH directory
case $TRIPLE in
  riscv32*)
  CPU_ARCH=riscv32
  ;;
  riscv64*)
  CPU_ARCH=riscv64
  ;;
  *)
  echo "[-] Bad build triple '${TRIPLE}'"
  exit 1
esac

case $PLATFORM in
  sifive_e300*)
  echo "[+] Building for ${CPU_ARCH} SiFive Freedom E300 series"
  ;;
  spike*)
  echo "[+] Building for ${CPU_ARCH} Spike emulator"
  ;;
  *)
  echo "[-] Bad platform '${PLATFORM}'"
  exit 1
esac

# we can't do this from cargo, have to set it outside the toolchain
export RUSTFLAGS="-C link-arg=-Tsrc/platform/${CPU_ARCH}/${PLATFORM}/link.ld"

# invoke the compiler toolchain
cargo build --release --target $TRIPLE --features $PLATFORM
