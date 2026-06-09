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

The build system automatically downloads and compiles from source a guest Root Virtual
Machine (Root VM) using Buildroot. The Root VM helps the hypervisor manage the
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

This compiles the codebase for the default target defined in `hypervisor/hw/ports/default.yaml` and
places the output ELF executable in `./zig-out/bin/vmdiosix`. The default target is the QEMU Virt platform, suitable for QEMU versions 10 and later. The generated executable contains both the hypervisor and the root VM image, ready to be booted.

For more information on booting the built hypervisor, see [Run Diosix](run.md).

#### Customize compilation options

You can pass standard Zig build options and Diosix-specific build options to the wrapper
script to process. For example, to override the hardware target platform from the default,
compile an optimized build, or build for a legacy processor or emulator lacking newer RISC-V
extensions, see the following commands:

```bash
# Target a specific hardware port, such as the PMP-only QEMU Virt platform
./scripts/build.sh -Dsystem=qemu-virt-pmp

# Build with optimizations for release
./scripts/build.sh -Doptimize=ReleaseSafe

# Target a legacy CPU/emulator lacking modern RISC-V extensions
./scripts/build.sh -Dsystem=qemu-virt-legacy
```

To list all available build targets, configuration parameters, and help
options, run:

```bash
./scripts/build.sh -h
```

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

## Declarative hardware ports via YAML configuration

To support diverse hardware platforms, the build system uses declarative
YAML configurations to define how target boards share and use assembly routines
and linker scripts.

Every target platform is described by a dedicated YAML configuration file
located in the target configuration directory at `hypervisor/hw/ports/`. These
description files specify the target name, the linker script path, the
command-line arguments needed to execute the target in QEMU, the list of
assembly files to compile, and any static dependency assets.

The configuration is parsed by a custom YAML parser located at
`scripts/yaml_parser.zig`. Written specifically for this project, it parses
key-value pairs and arrays without external dependencies. This design avoids
reliance on external package managers or network downloads, maintaining build
speed and offline reliability.

### Dynamic port discovery and target selection

During the configure phase, the `build.zig` program scans the target configuration
directory to discover available hardware ports and, if necessary, lists them in
the compiler help options.

The build system determines the default target system by reading a global
configuration file located at `hypervisor/hw/ports/default.yaml`. This file
designates the fallback target when no specific architecture option is passed.

You can override the default target system using the `-Dsystem` parameter. The
build script loads the corresponding YAML file, allowing you to add new target
boards without modifying the core build script.

### Compilation and cached dependency tracking

Once a hardware port is selected, the build script registers each assembly
file individually. This prevents duplicate symbol collisions and allows the
linker script to control section ordering, such as placing the entry stage
at the base physical DRAM address.

To ensure that statically included files, like `consts.s`, are correctly
tracked, the build system declares them as explicit dependencies of the
compilation step. Modifying any dependent assembly file invalidates the
compiler cache, forcing a fresh compilation of the assembly sources.
