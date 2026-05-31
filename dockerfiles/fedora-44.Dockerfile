# Fedora 44 Build and Run environment for Diosix
FROM fedora:44

# Allow Buildroot to compile as root inside the container
ENV FORCE_UNSAFE_CONFIGURE=1

# Install core development tools, Buildroot host tools, and QEMU emulation
RUN dnf update -y && dnf install -y \
    @development-tools \
    gcc-c++ \
    perl-English \
    perl-ExtUtils-MakeMaker \
    perl-Thread-Queue \
    perl-FindBin \
    perl-IPC-Cmd \
    perl-open \
    python3-passlib \
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
    python3 \
    which \
    qemu-system-riscv \
    && dnf clean all

# Dynamically detect host CPU architecture and install the latest master version of Zig (0.17.0-dev)
RUN ARCH="$(uname -m)-linux" \
    && ZIG_URL=$(curl -s https://ziglang.org/download/index.json | python3 -c "import sys, json; print(json.load(sys.stdin)['master']['$ARCH']['tarball'])") \
    && echo "Downloading Zig for $ARCH from: $ZIG_URL" \
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
