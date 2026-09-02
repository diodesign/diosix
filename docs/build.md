# Build Diosix

The Diosix build pipeline uses the Zig build system to compile the hypervisor
and generate reproducible guest operating system images. This process
coordinates the build graph, target architecture configurations, declarative
hardware ports, and build machine metadata injection.

---

## Build process

This section details the dependencies needed to compile the hypervisor and a guest OS, and the steps to clone the project repository and build the complete system.

### Hypervisor build dependencies

To compile the hypervisor, you must have the following installed:

*   Zig version 0.17.0 or later.
*   Git version 2.54 or later.
*   For Docker-based builds, Docker version 29.5.2 or later.

### Guest operating system build dependencies

The build system automatically downloads and compiles from source a 64-bit RISC-V guest
Root Virtual Machine (Root VM) using Buildroot. The Root VM helps the hypervisor manage the
host hardware and other VMs.

Building this guest requires standard compilation utilities on the build machine. On minimal
or server-oriented installations, such as a fresh Ubuntu 22.04 environment, you must 
manually install these dependencies before you can use Buildroot.

To install the required tools on Debian or Ubuntu systems, run:

```bash
sudo apt update
sudo apt install -y \
    build-essential git rsync cpio unzip file bc findutils \
    wget xz-utils python3
```

On Fedora systems, run:

```bash
sudo dnf groupinstall "Development Tools"
sudo dnf install -y \
    gcc-c++ \
    perl-English perl-ExtUtils-MakeMaker perl-Thread-Queue perl-FindBin perl-IPC-Cmd perl-open \
    python3-passlib \
    git rsync cpio unzip bc wget xz python3 which
```

### Fetch the source repository

To clone the Diosix source code, and enter its directory, run:

```bash
git clone https://github.com/diodesign/diosix.git
cd diosix
```

### Use the build wrapper

Use the build wrapper script (`scripts/build.sh`) to compile and test the
hypervisor. It supports several commands and options to control the build
process.

#### Build the default target

To compile the hypervisor and generate the Root VM payload,
run the build wrapper script:

```bash
./scripts/build.sh
```

This compiles the codebase to produce a platform-agnostic, universal hypervisor binary. While the hypervisor target architecture is always 64-bit RISC-V, the build process
places the output ELF executable in a directory based on the architecture of the guest Root VM (for example, `./zig-out/guest-riscv64/bin/vmdiosix`, `./zig-out/guest-riscv32/bin/vmdiosix`, or `./zig-out/guest-aarch64/bin/vmdiosix`). The target is position independent and runs on any standard 64-bit RISC-V platform. The generated executable contains both the hypervisor and the root VM image, ready to be booted.

For more information on booting the built hypervisor, see [Run Diosix](run.md).

#### Customize compilation options

You can pass standard Zig build options and Diosix-specific build options to the wrapper
script to process. For example, to override the hardware target platform from the default,
compile an optimized build, or build for a legacy processor or emulator lacking newer RISC-V
extensions, see the following commands:

```bash
# Target a specific hardware configuration, such as PMP fallback mode (disable Hypervisor extension)
./scripts/build.sh -Dpmp=true

# Build with optimizations for release
./scripts/build.sh -Doptimize=ReleaseSafe

# Target a legacy CPU/emulator lacking modern RISC-V extensions (e.g. QEMU 6.x)
./scripts/build.sh -Dlegacy-cpu=true
```

#### Build the live media and installer disk image

To generate a bootable GUID Partition Table (GPT) disk image containing the Extensible Firmware Interface (EFI) System Partition, hypervisor, Root VM, and persistent guest storage datastore, run:

```bash
./scripts/build.sh live-image
```

The output image is saved to `zig-out/diosix-live-riscv64.img`.

To list all available build targets, configuration parameters, and help
options, run:

```bash
./scripts/build.sh -h
```

---

## Incremental build caching

To ensure responsive development cycles, the build system leverages multi-tier
caching:

*   **Hypervisor core**: Zig caches compiled objects in `.zig-cache/`. Recompiling
    hypervisor source changes takes ~1 second.
*   **Guest userland utilities (`diosix-ctl`)**: The `dsx` binary is compiled
    via `zig build-exe` directly against the shared `hypervisor/interface/` module
    and staged into the dynamic build overlay (`zig-out/buildroot-<arch>/overlay-dynamic/usr/sbin/`).
*   **Buildroot workspace**: Buildroot stores toolchains, source tarballs, and
    intermediate build objects under `zig-out/buildroot-<arch>/`. Once the initial
    Linux kernel and packages are built, subsequent invocations reuse the
    cached toolchain and objects, rebuilding only updated overlay files and
    packaging the final `rootvm.elf` in ~10–20 seconds.

---

## Containerized build process using Docker

For a highly reproducible and isolated build environment that automatically
manages all tools, including the required Zig compiler version and Buildroot
packages, you can use the provided Dockerfiles.

The configuration Dockerfiles are located in `dockerfiles/`:

*   `dockerfiles/ubuntu-22.04.Dockerfile`: Builds Diosix on Ubuntu 22.04.
*   `dockerfiles/fedora-44.Dockerfile`: Builds Diosix on Fedora 44.

We recommend you use Docker version 29.5.2 or later.

### Build a container image

To build a container image, navigate to the Diosix project root and build the image for your preferred distribution:

```bash
# For Ubuntu 22.04
docker build -f dockerfiles/ubuntu-22.04.Dockerfile -t diosix-ubuntu .

# For Fedora 44
docker build -f dockerfiles/fedora-44.Dockerfile -t diosix-fedora .
```

### Run compilation inside the container

To compile the codebase using the Docker environment, run the build wrapper command inside the container:

```bash
# Build the default target inside the Ubuntu environment
docker run -it --rm diosix-ubuntu ./scripts/build.sh

# Build the default target inside the Fedora environment
docker run -it --rm diosix-fedora ./scripts/build.sh
```

For more information on booting and running the built hypervisor, see [Run Diosix](run.md).

---

## Metadata injection and the wrapper script

The entry point of the build process is the shell-based build wrapper,
which invokes the `build.zig` program to carry out the compilation work.

To accelerate build cycles, Zig serializes and caches the build configuration
graph generated by `build.zig`. If `build.zig` remains unmodified and its
command-line parameters are identical, Zig bypasses executing `build.zig`
entirely. Executing subprocesses to query the build machine, such as `git` or the system
date, directly inside `build.zig` would therefore result in stale or missing
metadata, as Zig would reuse the cached configuration without re-querying the build machine.

The wrapper script solves this by capturing git and temporal metadata from the
host build machine before compiling. These values are passed to `zig build` as explicit
build options, using `-D` parameters, ensuring that any change in the build machine
environment correctly invalidates the build configuration cache.

---

## Platform-agnostic compilation and position independence

To support diverse hardware platforms, the build system compiles the hypervisor as a single, platform-agnostic universal binary. Rather than linking separate target configurations at compile time, all boot-strap, context switching, and trap management assembly code resides in the core RISC-V 64-bit architecture directory (`hypervisor/hardware/native/cpu/riscv64/`) and is compiled into the binary.

The entry point and early boot code are position-independent, relying on PC-relative addressing (`auipc`, `la`) to resolve structures dynamically.

### Dynamic runtime device drivers

Platform-specific MMIO differences are handled by a dynamic device driver subsystem (`hypervisor/core/drivers.zig`). Early during the hypervisor boot process, the main CPU core parses the Host Device Tree Blob (DTB) passed by the bootloader in register `a1`. 

Based on discovered peripherals and CPU extensions, the hypervisor registers and binds drivers at runtime:
*  Binds to the NS16550 UART driver for console IO if a compatible UART MMIO base is discovered.
*  Uses the RISC-V Sstc supervisor timer extension if supported by the CPU, or dynamically programs CLINT timer MMIO registers based on the discovered CLINT address.
*  Configures shutdown and reboot pathways via the discovered SiFive Test poweroff device.

### Compilation and cached dependency tracking

The build script compiles the generic assembly files (`entry.s`, `xint.s`, `util.s`) from the architecture directory. Statically included configuration parameters (such as `consts.s` and `config.s`) are registered as explicit dependencies of the compilation step. Modifying any of these dependent assembly header files correctly invalidates the build cache and triggers a fresh compilation of the assembly sources.
