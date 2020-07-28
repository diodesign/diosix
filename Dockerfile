#
# Containerized environment for building, running, and testing Diosix
#
# Author: Chris Williams <diodesign@tuta.io>
#

# Establish base OS
FROM debian:stable

# Bring in the necessary tools
RUN apt update
RUN apt -y install flex bison m4 sed texinfo build-essential git curl wget libglib2.0-dev libfdt-dev libpixman-1-dev zlib1g-dev

# Bring in the environment setup script
COPY ./entrypoint.sh /

# Define where we'll work
WORKDIR /build

# Build Qemu and the GNU toolchain, install Rust, import pre-built guest OS images
RUN git clone https://github.com/qemu/qemu.git \
	&& cd qemu \
	&& ./configure --target-list=riscv64-softmmu,riscv32-softmmu \
	&& make -j$(nproc) \
	&& cd /build \
	&& mkdir cross \
	&& git clone --recurse-submodules https://github.com/riscv/riscv-binutils-gdb.git \
	&& cd riscv-binutils-gdb \
	&& ./configure --prefix /build/cross --target=riscv32-linux --disable-unit-tests \
	&& make -j$(nproc) && make -j$(nproc) install && make -j$(nproc) clean \
	&& find . -type f -name "config.cache" -exec rm {} \; \
	&& ./configure --prefix /build/cross --target=riscv64-linux --disable-unit-tests \
	&& make -j$(nproc) && make -j$(nproc) install && make -j$(nproc) clean \
	&& find . -type f -name "config.cache" -exec rm {} \; \
	&& cd /build \
	&& curl https://sh.rustup.rs -sSf | sh -s -- --default-toolchain nightly -y \
	&& . $HOME/.cargo/env \
	&& rustup target install riscv32imac-unknown-none-elf \
	&& rustup target install riscv64imac-unknown-none-elf \
	&& rustup target install riscv64gc-unknown-none-elf \
	&& git clone --recurse-submodules https://github.com/diodesign/diosix.git \
	&& cd diosix \
	&& mkdir -p boot/binaries/riscv64gc \
	&& mkdir -p boot/binaries/riscv64imac \
	&& mkdir -p boot/binaries/riscv32imac \
	&& wget https://github.com/diodesign/diosix/raw/boot-binaries/boot/binaries/riscv64gc/supervisor -O boot/binaries/riscv64gc/supervisor \
	&& wget https://github.com/diodesign/diosix/raw/boot-binaries/boot/binaries/riscv64imac/supervisor -O boot/binaries/riscv64imac/supervisor \
	&& wget https://github.com/diodesign/diosix/raw/boot-binaries/boot/binaries/riscv32imac/supervisor -O boot/binaries/riscv32imac/supervisor

# Define the environment in which we'll run commands
ENTRYPOINT [ "/entrypoint.sh" ]

# Default command - run unit tests. 'cargo run' boots the hypervisor as normal
CMD [ "cargo", "test" ]
