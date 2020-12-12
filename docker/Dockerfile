#
# Containerized environment for building, running, and testing Diosix
# This container targets RV64GC only
#
# Author: Chris Williams <diodesign@tuta.io>
#

# Establish base OS
FROM debian:unstable

# Bring in the necessary tools
RUN apt update
RUN apt -y install python3 python3-flask build-essential git curl binutils-riscv64-linux-gnu qemu-system-misc

# Bring in the environment runtime script
COPY ./entrypoint.py /

# Define where we'll work
WORKDIR /build

# Build diosix
RUN cargo install --force just \
	&& git clone --recurse-submodules https://github.com/diodesign/diosix.git \
	&& just rustinstall \
	&& . $HOME/.cargo/env \
	&& just build

# Define the environment in which we'll run commands
ENTRYPOINT [ "/entrypoint.py" ]

# Default command: boot the hypervisor as normal. Use 'just test' to run unit tests
CMD [ "just", "qemu" ]
