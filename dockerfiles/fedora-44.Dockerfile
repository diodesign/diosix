# Fedora 44 Build and Run environment for Diosix
FROM fedora:44

# Install core development tools, Buildroot host tools, and QEMU emulation
RUN dnf update -y && dnf install -y \
    @development-tools \
    curl \
    git \
    rsync \
    cpio \
    unzip \
    bc \
    file \
    findutils \
    wget \
    xz \
    qemu-system-riscv \
    && dnf clean all

# Install Zig version 0.17.0-dev.648+8d1b6e339
RUN curl -L https://ziglang.org/builds/zig-linux-x86_64-0.17.0-dev.648+8d1b6e339.tar.xz -o zig.tar.xz \
    && tar -xf zig.tar.xz -C /opt \
    && ln -s /opt/zig-linux-x86_64-0.17.0-dev.648+8d1b6e339/zig /usr/local/bin/zig \
    && rm zig.tar.xz

# Set up project workspace
WORKDIR /diosix
COPY . .

# Default command builds the default QEMU target system
CMD ["./scripts/build.sh"]
