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

# Dynamically install the latest master development version of Zig (0.17.0-dev)
RUN ZIG_URL=$(curl -s https://ziglang.org/download/index.json | grep -A 5 '"x86_64-linux"' | head -n 5 | grep -o 'https://ziglang.org/builds/zig-x86_64-linux-[^"]*') \
    && echo "Downloading Zig from: $ZIG_URL" \
    && curl -L "$ZIG_URL" -o zig.tar.xz \
    && tar -xf zig.tar.xz -C /opt \
    && ZIG_DIR=$(tar -tf zig.tar.xz | head -1 | cut -f1 -d"/") \
    && ln -s "/opt/$ZIG_DIR/zig" /usr/local/bin/zig \
    && rm zig.tar.xz

# Set up project workspace
WORKDIR /diosix
COPY . .

# Default command builds the default QEMU target system
CMD ["./scripts/build.sh"]
