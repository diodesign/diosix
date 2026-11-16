# Ubuntu 26.04 LTS build and test environment for Diosix.
FROM ubuntu:26.04

# Avoid interactive prompts during apt package installation and allow Buildroot
# to configure host packages as root inside the container.
ENV DEBIAN_FRONTEND=noninteractive
ENV FORCE_UNSAFE_CONFIGURE=1

# Install compilers, Linux kernel and Buildroot host packages, disk-image
# utilities, QEMU (>= 10.0), and integration test dependencies.
RUN apt-get update && apt-get install -y --no-install-recommends \
    bc \
    bison \
    build-essential \
    ca-certificates \
    cmake \
    cpio \
    curl \
    dosfstools \
    e2fsprogs \
    fdisk \
    file \
    findutils \
    flex \
    gawk \
    git \
    libelf-dev \
    libssl-dev \
    mtools \
    ninja-build \
    openssh-client \
    pkg-config \
    procps \
    python3 \
    python3-pexpect \
    qemu-system-riscv \
    rsync \
    u-boot-tools \
    unzip \
    util-linux \
    wget \
    xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && qemu-system-riscv64 --version \
    && python3 -c "import pexpect" \
    && for cmd in sfdisk mkfs.vfat mcopy mmd mke2fs mkimage ssh-keygen pkill; \
       do command -v "$cmd" >/dev/null; done

# Install pinned Zig 0.17.0 with SHA-256 verification.
ARG ZIG_VERSION=0.17.0
RUN case "$(uname -m)" in \
      x86_64) \
        ZIG_ARCH="x86_64"; \
        SHA="1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026" \
        ;; \
      aarch64) \
        ZIG_ARCH="aarch64"; \
        SHA="9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8" \
        ;; \
      riscv64) \
        ZIG_ARCH="riscv64"; \
        SHA="18ff032ac6cecf746a84259f6463264f13160ff88bc3b80722ce06f9479b82ed" \
        ;; \
      *) \
        echo "Unsupported host architecture: $(uname -m)" >&2; \
        exit 1 \
        ;; \
    esac \
    && ZIG_TAR="zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
    && ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TAR}" \
    && curl -fsSL "$ZIG_URL" -o zig.tar.xz \
    && echo "${SHA}  zig.tar.xz" | sha256sum -c - \
    && tar -xf zig.tar.xz -C /opt \
    && ZIG_DIR=$(tar -tf zig.tar.xz | head -1 | cut -f1 -d"/") \
    && ln -s "/opt/${ZIG_DIR}/zig" /usr/local/bin/zig \
    && rm zig.tar.xz \
    && zig version

# Set up project workspace.
WORKDIR /diosix
COPY . .

# Default command builds the default QEMU target system.
CMD ["./scripts/build.sh"]
