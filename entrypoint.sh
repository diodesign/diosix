#!/bin/bash
#
# Set up for the containerized environment for running Diosix on Qemu
# syntax: entrypoint.sh <command>
#
# Author: Chris Williams <diodesign@tuta.io>
#
set -e

# locate rust toolchain
source $HOME/.cargo/env

# run the supplied command in the diosix context
cd /build/diosix
exec $@
