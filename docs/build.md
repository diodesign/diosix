# Diosix build system architecture

The Diosix build pipeline uses the Zig build system to compile the hypervisor
and generate reproducible guest operating system images. This process
coordinates the build graph, target architecture configurations, declarative
hardware ports, and host metadata injection.

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
