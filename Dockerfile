#
# Containerized environment for building, running, and testing Diosix
# This container targets RV64GC only
#
# Author: Chris Williams <diodesign@tuta.io>
#

# Establish base OS
FROM debian:testing

# Bring in the necessary tools
RUN apt update && apt upgrade -y
RUN apt -y install python3 python3-flask build-essential pkg-config git curl binutils-riscv64-linux-gnu qemu-system-misc libssl-dev

# Bring in the environment runtime script
COPY ./docker/entrypoint.py /

# Bring in the project source code
COPY . /diosix

# Define where we'll work
WORKDIR /diosix

# Install necessary bits and pieces of Rust and just, pull in the submodules, and then build diosix
RUN curl https://sh.rustup.rs -sSf | sh -s -- --default-toolchain nightly -y \
    && . $HOME/.cargo/env \
    && cargo install --force just \
    && git submodule update --init --recursive \
    && just build

# Define the environment in which we'll run commands
ENTRYPOINT [ "/entrypoint.py" ]

# Default run command: boot the hypervisor as normal. Use 'just test' to run unit tests or 'just build' to test it builds
CMD [ "just" ]
