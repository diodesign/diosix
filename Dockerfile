#
# Containerized environment for building, running, and testing Diosix
# This container targets RV64GC only
#
# Author: Chris Williams <diodesign@tuta.io>
#

# Establish base OS
FROM debian:stable

# Bring in the necessary tools
RUN apt update
RUN apt -y install build-essential git curl binutils-riscv64-linux-gnu qemu-system-misc

# Bring in the environment setup script
COPY ./entrypoint.sh /

# Define where we'll work
WORKDIR /build

# Install Rust, import pre-built guest OS images
RUN curl https://sh.rustup.rs -sSf | sh -s -- --default-toolchain nightly -y \
	&& . $HOME/.cargo/env \
	&& rustup target install riscv64gc-unknown-none-elf \
	&& git clone --recurse-submodules https://github.com/diodesign/diosix.git \
	&& cd diosix \
	&& mkdir -p boot/binaries/riscv64gc \
	&& curl -L -o boot/binaries/riscv64gc/supervisor https://github.com/diodesign/diosix/raw/boot-binaries/boot/binaries/riscv64gc/supervisor

# Define the environment in which we'll run commands
ENTRYPOINT [ "/entrypoint.sh" ]

# Default command: boot the hypervisor as normal. Use 'cargo test' to run unit tests
CMD [ "cargo", "run" ]
