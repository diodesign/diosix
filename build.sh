#!/bin/bash

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
# sifive_e (SiFive-E series)
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

# break the build triple into an array so we can get the CPU architecture
IFS='-' read -r -a TRIPLE_ARRAY <<< ${TRIPLE}

# sanity check
if [[ ${TRIPLE} == "" || ${PLATFORM} == "" || ${TRIPLE_ARRAY[0]} == "" ]]; then
  echo "syntax: ./build.sh --triple [build triple] --platform [target platform]"
  exit 1
fi;

# we can't do this from cargo, have to set it outside the toolchain
set RUSTFLAGS = "-C link-arg=-Tsrc/platform/${TRIPLE_ARRAY[0]}/${PLATFORM}/link.ld"

# invoke the compiler toolchain
cargo build --release --target ${TRIPLE} --features ${PLATFORM}
