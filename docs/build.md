# Diosix Build System Architecture

The Diosix build pipeline is designed to be highly automated, self-contained, and integrated with the host environment to guarantee reproducible and fresh builds.

The process coordinates the Zig build graph, target architecture configurations, declarative hardware port configurations, dynamic YAML asset discovery, and environment metadata injection to build the hypervisor and its associated components.

## Metadata injection and the wrapper script

At the entry point of the build process is a shell-based build wrapper located at `scripts/build.sh`. This wrapper serves as the primary developer interface for initiating compiles.

Because the Zig build system relies on a hermetic caching model to accelerate build cycles, executing side-effecting subprocesses (such as querying `git` or retrieving the system date) directly within the configuration phase of the build script (`build.zig`) is a significant anti-pattern. If these commands are run directly within the build script, Zig's cache cannot track the external, dynamic system state as explicit input dependencies. This omission causes the build system to reuse stale cached binaries even when the host environment has changed, and it can also cause background tools like the Zig Language Server (ZLS) to fail when executing the build graph.

The build wrapper (`scripts/build.sh`) solves this by dynamically capturing real-time environmental metadata from the build host operating system immediately before executing the compiler. It queries the local Git repository for the current branch name and commit revision, retrieves the host system's date, time, and hostname, and identifies the build user via shell utilities.

These values are then passed directly to `zig build` as command-line options. By defining these dynamic environmental variables as explicit build options (using `-D` options), the build script (`build.zig`) can declare them as proper inputs to the build graph. This ensures that any change in the captured host environment correctly invalidates the build configuration's cache keys, resulting in fresh, deterministic, and accurate versioning without polluting the hermeticity of the build script.

## Declarative Hardware Ports via YAML Configuration

To support a highly modular hardware architecture that allows different target boards (such as QEMU emulator models or physical SiFive silicon) to share common assembly routines without code duplication, symlink hacks, or complex code arrays, the build system employs a declarative YAML-based hardware configuration model.

Every target platform is described by a dedicated YAML configuration file located in the target configuration directory at `hypervisor/hw/ports/`. These description files specify the unique human-readable target name, the target linker script path, the command-line arguments needed to execute the target in its respective emulator, the explicit list of target-specific and shared assembly files to compile, and any static dependency assets.

At the core of the configuration loading process is a lightweight, zero-dependency, self-contained YAML parser module located at `scripts/yaml_parser.zig`. Written explicitly for Diosix, this custom parser operates completely offline and handles standard YAML constructs like key-value pairs and arrays. This design avoids any reliance on external package managers or network downloads, maintaining excellent build speed, supply-chain safety, and compiler version compatibility.

## Dynamic Port Discovery and Target Selection

During the configure phase of the build, the `build.zig` script automatically scans the target configuration directory to dynamically discover all available hardware ports. It ignores the default configuration metadata and collects all valid port configurations. This dynamic list is compiled into a text list displayed to the developer when querying compiler help options.

The build system determines the default target system by reading a global configuration metadata file located at `hypervisor/hw/ports/default.yaml`. This metadata file designates the fallback target when no specific architecture option is passed. Developers can explicitly override this default from the command line by using the `-Dsystem` parameter when executing the build wrapper. The build script dynamically loads, parses, and configures the corresponding target YAML file, ensuring that board additions require no modifications to the core build script.

## Compilation and Natively Cached Dependency Tracking

Once a hardware port is loaded and parsed, the build script registers each individual assembly file listed in the configuration file to the compilation unit using native compiler methods. Compiling the assembly files individually enables the compiler to translate them as separate units, preventing duplicate symbol linker collisions and allowing the target linker script to dictate the precise spatial section ordering, such as keeping the entry stage section at the baseline DRAM address.

To ensure that static files like `consts.s` (which are statically included inside other assembly files using assembly preprocessor directives) are correctly tracked, the build system implements a native cache invalidation mechanism. When the parsed configuration lists dependencies, the build system creates a files-writing step inside the build graph and adds the listed assets to it. By configuring the main compile step to depend directly on this tracking step, the build system establishes a formal dependency edge. Any subsequent modification to an assembly constant file immediately invalidates the cache keys for the main compile step, forcing the Zig build runner to execute a fresh recompilation of all target assembly files and link a perfectly updated hypervisor binary.
