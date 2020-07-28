#!/bin/bash
#
# Set up for the containerized environment for running Diosix on Qemu
# syntax: entrypoint.sh <command>
#
# Author: Chris Williams <diodesign@tuta.io>
#
set -e

source $HOME/.cargo/env
export PATH=$PATH:/build/qemu/riscv64-softmmu
export PATH=$PATH:/build/qemu/riscv32-softmmu
export PATH=$PATH:/build/cross/bin

# run the supplied command
cd /build/diosix
exec $@

