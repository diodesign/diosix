[![License: MIT](https://img.shields.io/github/license/diodesign/diosix)](https://github.com/diodesign/diosix/blob/main/LICENSE) [![Language: Zig](https://img.shields.io/badge/language-zig-darkorange.svg)](https://ziglang.org/) [![Platform: riscv64](https://img.shields.io/badge/platform-riscv64-lightblue.svg)](https://riscv.org/)

## About this project

Diosix strives to be a lightweight, reliable, and secure multi-core bare-metal 
hypervisor written in [Zig](https://ziglang.org/) for 64-bit 
[RISC-V](https://riscv.org/developers/) computers. It is aimed at systems that 
may be small, or even large, yet have a need to run multiple hardware-isolated 
operating systems at the same time.

This project is a work-in-progress and represents a restart of the original 
Rust-based implementation. By using Zig, we aim to iterate and innovate faster 
while maintaining a strict focus on safety, security, and robustness.

Diosix is designed to be self-contained and simple to install. It includes a 
privileged Linux-based Root Virtual Machine (Root VM) for managing the host
hardware and orchestrating other guest workloads. While currently focused
on 64-bit RISC-V, the codebase is structured to allow for future ports to
other architectures.

For a deeper dive into the hypervisor's design, see the 
[background information](docs/background.md) documentation.

## Build Diosix

To build Diosix, you must have at least version 0.16.0 of the 
[Zig toolchain](https://ziglang.org/download/) and Git version 2.53 installed. 
Both are typically available through standard system package managers.

Follow these steps to build the hypervisor from source:

1. Clone the repository and enter the project directory:
   ```bash
   git clone --branch zig https://github.com/diodesign/diosix.git
   cd diosix
   ```

2. Start the build process using the Zig build system:
   ```bash
   zig build
   ```

This process automatically downloads and cross-compiles [BuildRoot](https://buildroot.org/) 
if the Root VM image is missing or needs updating. Because we build everything 
from source for an absolute guarantee of provenance and security, this initial 
BuildRoot step can take significant time to compile the Linux kernel, a busybox 
userspace, and the cross-compiler toolchain. Subsequent builds rely on the 
cached output.

The hypervisor executable is generated at `./zig-out/bin/vmdiosix`. By 
default, Diosix targets the [QEMU](https://www.qemu.org/) hardware emulator. To 
target a different system, use the `-Dsystem` parameter. You can view all 
available build options by running `zig build -h`.

## Run Diosix

We recommend using at least version 10.1.5 of QEMU to run Diosix. Ensure you have 
the 64-bit RISC-V system emulator installed.

To boot the hypervisor with four virtual CPU cores and 2GB of RAM using the 
QEMU `virt` machine environment, run the following command:

```bash
zig build run
```

By default, the hypervisor sends its output to the serial port, which QEMU 
displays in your terminal. You can exit the emulator by pressing `Ctrl+a` 
then `x`, or enter the debug console with `Ctrl+a` then `c`.

## Develop Diosix

We welcome contributions to the project and ask that you follow our established
development standards to ensure high-quality code and documentation. When 
writing new code, please be mindful of ownership and memory management; 
function callers are responsible for freeing any pointers returned by functions 
that require an allocator. Always use the provided allocator for cleanup to 
avoid leaks.

We require comprehensive unit tests for all new core logic to verify correctness.
These tests run on the build host and must pass successfully before any Changes
are accepted into the codebase. You can execute the test suite by running
`zig build test`.

All contributions must strictly adhere to the [Diosix style 
guide](docs/style-guide.md). This guide covers both our technical writing 
standards — such as defining abbreviations on first use and using sentence-case 
headings — and our idiomatic Zig coding conventions.

Finally, we use the 
[Calendar Versioning](https://calver.org/) (YY.MINOR) format for our releases, 
where even-numbered minor versions indicate stable releases and odd numbers 
represent development builds.

## Contact and community

If you have questions, wish to contribute, or need to report an issue, please 
email [hello@diosix.org](mailto:hello@diosix.org). You can also submit pull 
requests or raise issues through our GitHub repository.

If you have discovered a security vulnerability, please follow our 
[security reporting process](docs/security.md#reporting-security-issues) to 
disclose the matter privately and responsibly.

All participants are expected to follow the project's 
[code of conduct](docs/conduct.md).

## Copyright and license

Copyright &copy; Chris Williams, 2024, 2025, 2026. This project is distributed 
under the terms of the MIT License. See the [LICENSE](LICENSE) file for the 
full text.

The diosix.org illustration is a combination of artwork provided by 
[Katerina Limpitsouni](https://undraw.co/license) and 
[RISC-V International](https://riscv.org/about/risc-v-branding-guidelines/). 
Any trademarks used are for identification purposes only.
