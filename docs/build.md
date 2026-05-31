# Diosix build system architecture

The Diosix build pipeline uses the Zig build system to compile the hypervisor
and generate reproducible guest operating system images. This process
coordinates the build graph, target architecture configurations, declarative
hardware ports, and host metadata injection.

---

## Host build requirements

Before compiling Diosix, ensure your host system is configured with the
necessary development tools, and that you have cloned the source repository.

### Fetch the source repository

To clone the Diosix source code and enter its directory, run:

```bash
git clone https://github.com/diodesign/diosix.git
cd diosix
```

### Hypervisor toolchain

To compile the hypervisor, you must have the following installed:
*   **Zig:** Version 0.17.0 or later.
*   **Git:** Version 2.54 or later.

### Guest operating system build dependencies

The build system automatically downloads and compiles the guest Root Virtual
Machine (Root VM) using Buildroot. Building the guest requires standard
host-side compilation utilities. On minimal or server-oriented installations
(such as a fresh Ubuntu 22.04 environment), you must manually install these
dependencies.

To install the required tools on Debian or Ubuntu systems, run:

```bash
sudo apt update
sudo apt install -y build-essential rsync cpio unzip file bc findutils wget
```

On Fedora systems, run:

```bash
sudo dnf groupinstall "Development Tools"
sudo dnf install -y rsync cpio unzip bc wget
```

---

## Metadata injection and the wrapper script

At the entry point of the build process is a shell-based build wrapper located
at `scripts/build.sh`. This wrapper serves as the primary interface for
initiating compiles.

Because the Zig build system relies on a hermetic caching model to accelerate
build cycles, running subprocesses that query the host environment (such as `git`
or the system date) directly inside the build script (`build.zig`) can cause the
caching system to reuse stale binaries.

The wrapper script (`scripts/build.sh`) solves this by capturing environmental
metadata from the host system before compiling. It queries the local Git
repository for the current branch name and commit revision, and retrieves the
host system's date and time. These values are then passed directly to
`zig build` as explicit build options (using `-D` parameters). This ensures that
any change in the captured host environment correctly invalidates the cache,
resulting in accurate versioning.

---

## Use the build wrapper

The build wrapper script (`scripts/build.sh`) supports several commands and
options to compile, run, and test the hypervisor.

### Build the default target

To compile the hypervisor and generate the guest Root VM
payload without running the emulator, execute:

```bash
./scripts/build.sh
```

This compiles the codebase for the default target defined in `default.yaml` and
places the output Executable and Linkable Format (ELF) executable in
`./zig-out/bin/vmdiosix`.

### Run the emulator

To compile the codebase and automatically boot the system in a QEMU environment, run:

```bash
./scripts/build.sh run
```

### Run unit tests

To run the project's native unit tests on your host system:

```bash
./scripts/build.sh test
```

### Customize compilation options

You can pass standard Zig build options directly to the wrapper script. For
example, to override the target system port or compile an optimized release
build:

```bash
# Target a specific hardware port
./scripts/build.sh -Dsystem=qemu-virt-pmp

# Build with optimizations for release
./scripts/build.sh -Doptimize=ReleaseSafe
```

To list all available build targets, configuration parameters, and help
options, run:

```bash
./scripts/build.sh -h
```

---

## Declarative hardware ports via YAML configuration

To support modular hardware platforms, the build system uses declarative
YAML configurations to define how target boards
share assembly routines and linker scripts.

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

---

## Dynamic port discovery and target selection

During the configure phase, the `build.zig` script scans the target configuration
directory to discover available hardware ports and list them in the compiler
help options.

The build system determines the default target system by reading a global
configuration file located at `hypervisor/hw/ports/default.yaml`. This file
designates the fallback target when no specific architecture option is passed.

You can override the default target system using the `-Dsystem` parameter. The
build script loads the corresponding YAML file, allowing you to add new target
boards without modifying the core build script.

---

## Compilation and cached dependency tracking

Once a hardware port is configured, the build script registers each assembly
file individually. This prevents duplicate symbol collisions and allows the
linker script to control section ordering, such as placing the entry stage
at the base physical DRAM address.

To ensure that statically included files (like `consts.s`) are correctly
tracked, the build system declares them as explicit dependencies of the
compilation step. Modifying any dependent assembly file invalidates the
compiler cache, forcing a fresh compilation of the assembly sources.
