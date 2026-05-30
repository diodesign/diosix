[![License: MIT](https://img.shields.io/github/license/diodesign/diosix)](https://github.com/diodesign/diosix/blob/main/LICENSE) [![Language: Zig](https://img.shields.io/badge/language-zig-darkorange.svg)](https://ziglang.org/) [![Platform: riscv64](https://img.shields.io/badge/platform-riscv64-lightblue.svg)](https://riscv.org/)

## About this project

Diosix strives to be a lightweight, reliable, and secure multi-core bare-metal 
hypervisor written in [Zig](https://ziglang.org/) for 64-bit 
[RISC-V](https://riscv.org/developers/) computers. It is aimed at systems small and large that
have a need to run multiple hardware-isolated operating systems at the same time.

Below is a recording of a user logging into a RISC-V Linux guest OS on Diosix and running a few commands.

[![asciicast](https://asciinema.org/a/1161817.svg)](https://asciinema.org/a/1161817)

This project is a work-in-progress. By using Zig, we aim to iterate and innovate quickly 
while maintaining a strict focus on safety, security, and robustness.

Diosix is designed to be self-contained and simple to install. It includes a 
privileged Linux-based Root Virtual Machine (Root VM) for managing the host
hardware and orchestrating other guest workloads.

For a deeper dive into this type-1 hypervisor's design, see the 
[background information](docs/background.md) documentation.

### Supported hardware

Diosix runs on RVA20-compliant (RV64GC) systems, automatically adapting its isolation model based on whether the hypervisor (H) extension or physical memory protection (PMP) is available.

## Build Diosix

To build Diosix, you must have at least version 0.16.0 of the 
[Zig toolchain](https://ziglang.org/download/) and [Git](https://git.kernel.org/pub/scm/git/git.git/) version 2.54 installed.

Follow these steps to build the hypervisor from source:

1. Clone the repository and enter the project directory:

   ```bash
   git clone --branch zig https://github.com/diodesign/diosix.git
   cd diosix
   ```

2. Start the build process using the wrapper script:

   ```bash
   ./scripts/build.sh
   ```

To ensure the compiled hypervisor binary embeds accurate versioning and diagnostic info, `scripts/build.sh` captures fresh host metadata, such as the current git revision and build date, on every execution. This prevents the Zig build system from reusing stale cached values, which can happen if `zig build` is run directly.

For a detailed explanation of the compilation process, declarative hardware configuration, and the dependency caching system, see the [build system documentation](docs/build.md).

### Root VM image

The build process automatically downloads and cross-compiles [BuildRoot](https://buildroot.org/) if the Root VM image is missing or needs updating. Because we build everything 
from source for an absolute guarantee of provenance and security, this initial 
BuildRoot step can take significant time to compile the Linux kernel, a busybox 
userspace, and the cross-compiler toolchain. Subsequent builds rely on the 
cached output.

### Target hardware systems

Diosix relies on a modular, declarative hardware configuration model. Available hardware ports are defined inside target configuration YAML files located in `hypervisor/hw/ports/`, such as `qemu-virt.yaml`.

The default target system is specified in `hypervisor/hw/ports/default.yaml`, which defaults to `qemu-virt`. To compile for a different target hardware system, specify the target name using the `-Dsystem` parameter like so:

```bash
./scripts/build.sh -Dsystem=qemu-virt
```

You can view all dynamically discovered target hardware systems and build options by running:

```bash
./scripts/build.sh -h
```

### Output files

The hypervisor executable is generated at `./zig-out/bin/vmdiosix`.

## Run Diosix

Although the hypervisor compiles for physical hardware targets, the simplest way to run and test Diosix is inside an emulated environment using QEMU.

We recommend using at least version 10.1.5 of [QEMU](https://www.qemu.org/). Ensure the 64-bit RISC-V system emulator is installed on your host system.

To boot the hypervisor with four virtual CPU cores and 2GB of RAM using the 
emulated QEMU `virt` machine environment, run the following command:

```bash
./scripts/build.sh run
```

By default, the hypervisor sends its output to the serial port, which QEMU displays in the terminal. Exit and terminate the emulator by pressing `Ctrl-a` followed by `x`.
To enter the debug console, press `Ctrl-a` followed by `c`.

## Develop Diosix

We welcome contributions to the project and ask that you follow our established
development standards to ensure high-quality code and documentation.

When writing new code, please be mindful of ownership and memory management; 
function callers are responsible for freeing any pointers returned by functions 
that require an allocator. Always use the provided allocator for cleanup to 
avoid leaks.

We require comprehensive unit tests for all new core logic to verify correctness.
These tests run on the build host and must pass successfully before any Changes
are accepted into the codebase.

To execute the test suite, run the following command:

```bash
./scripts/build.sh test
```

All contributions must strictly adhere to the [Diosix style 
guide](docs/style-guide.md). This guide covers both our technical writing 
standards — such as defining abbreviations on first use and using sentence-case 
headings — and our idiomatic Zig coding conventions.

Finally, we use the 
[Calendar Versioning](https://calver.org/) (YY.MINOR) format for our releases, 
where even-numbered minor versions indicate stable releases and odd numbers 
represent development builds.

### ZLS integration

The [Zig Language Server](https://zigtools.org/zls/) (ZLS) works out-of-the-box with this project. During diagnostics and background checks, `build.zig` gracefully falls back to `"unknown"` placeholders for any missing environment-derived metadata, such as the current git revision or build date. This prevents background compilation failures and ensures autocomplete and diagnostics function perfectly without requiring any custom wrapper scripts or IDE configurations.

## Contact and community

If you have questions, wish to contribute, or need to report an issue, 
email [hello@diosix.org](mailto:hello@diosix.org). You can also submit pull 
requests or raise issues through this GitHub repository.

If you have discovered a security vulnerability, please follow the 
[security reporting process](docs/security.md#reporting-security-issues) to 
disclose the matter privately and responsibly.

All participants are expected to follow the project's 
[code of conduct](docs/conduct.md).

## Copyright and license

Copyright &copy; 2024-2026 Diosix contributors. This project is distributed under the terms of the MIT License. See [LICENSE](LICENSE) for the full text and [CONTRIBUTORS](CONTRIBUTORS) for the list of copyright holders.

The diosix.org illustration is a combination of artwork provided by 
[Katerina Limpitsouni](https://undraw.co/license) and 
[RISC-V International](https://riscv.org/about/risc-v-branding-guidelines/). 

All product names, logos, brands, trademarks, and registered trademarks are property of their respective owners. All company, product, and service names used by the Diosix project and its contributors are for identification purposes only. Use of these names, logos, and brands does not imply endorsement.