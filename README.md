[![License: MIT](https://img.shields.io/github/license/diodesign/diosix)](https://github.com/diodesign/diosix/blob/main/LICENSE) [![Language: Zig](https://img.shields.io/badge/language-zig-darkorange.svg)](https://ziglang.org/) [![Platform: riscv64](https://img.shields.io/badge/platform-riscv64-lightblue.svg)](https://riscv.org/)

# Diosix

Diosix strives to be a lightweight, reliable, and secure multi-core bare-metal hypervisor written in [Zig](https://ziglang.org/) for 64-bit [RISC-V](https://riscv.org/developers/) computers. It is aimed at systems small and large that have a need to run multiple hardware-isolated operating systems at the same time.

Below is a recording of a user logging into and interacting with a Linux guest OS running on Diosix.

[![asciicast](https://asciinema.org/a/1161817.svg)](https://asciinema.org/a/1161817)

This project is a work-in-progress. By using Zig, we aim to iterate and innovate quickly while maintaining a strict focus on safety, security, and robustness.

---

## Key architecture concepts

Diosix is a type-1 hypervisor, meaning it runs directly on the bare metal of the host system and is responsible for managing the hardware resources and orchestrating guest operating systems.

### Privileged Root VM

The hypervisor is designed to be self-contained and simple to install. It includes a privileged Linux-based Root Virtual Machine (Root VM) for managing the host hardware and orchestrating other guest workloads.

### Supported hardware and adaptive isolation
Diosix runs on RVA20-compliant (RV64GC) systems, automatically adapting its isolation model based on whether the hypervisor (H) extension or physical memory protection (PMP) is available:
- **Hypervisor (H) extension:** Uses hardware nested virtualization for maximum performance.
- **Physical memory protection (PMP):** Falls back to S-mode PMP isolation on cores lacking the H-extension.

For a deeper dive into this type-1 hypervisor's design, see the [technical documentation](docs/background.md).

---

## Quick start

Although the hypervisor compiles for physical hardware targets, the simplest way to run and test Diosix is inside an emulated environment using QEMU.

We recommend using at least version 10.1.5 of [QEMU](https://www.qemu.org/). Ensure the 64-bit RISC-V system emulator is installed on your host system.

Follow these simple steps to build and run Diosix immediately:

1. **Clone the repository and enter the project directory:**
   ```bash
   git clone --branch stable https://github.com/diodesign/diosix.git
   cd diosix
   ```

2. **Boot the hypervisor instantly inside QEMU:**
   ```bash
   ./scripts/build.sh run
   ```

By default, the hypervisor sends its output to the serial port, which QEMU displays in the terminal. Exit and terminate the emulator by pressing `Ctrl-a` followed by `x`. To enter the debug console, press `Ctrl-a` followed by `c`.

---

## Build custom target configurations

For more advanced builds or to deploy on hardware, you can customize the build using the Zig build system.

### Prerequisites
To build Diosix from source, you must have at least version 0.17.0 of the [Zig toolchain](https://ziglang.org/download/) and [Git](https://git.kernel.org/pub/scm/git/git.git/) version 2.54 installed.

### Root VM image
The build process automatically downloads and cross-compiles [BuildRoot](https://buildroot.org/) if the Root VM image is missing or needs updating. Because Diosix builds everything from source for an absolute guarantee of provenance and security, this initial BuildRoot step can take significant time to compile the Linux kernel, a busybox userspace, and the cross-compiler toolchain. Subsequent builds rely on the cached output.

### Target hardware platforms
Diosix relies on a modular, declarative hardware configuration model. Available hardware ports are defined inside target configuration YAML files located in `hypervisor/hw/ports/`, such as `qemu-virt.yaml`.

The default target system is specified in `hypervisor/hw/ports/default.yaml`, which defaults to `qemu-virt`. To compile for a different target hardware system, specify the target name using the `-Dsystem` parameter. For example, to target a PMP-only Qemu-simulated system, use:

```bash
./scripts/build.sh -Dsystem=qemu-virt-pmp
```

You can view all dynamically discovered target hardware systems and other build options by running:

```bash
./scripts/build.sh -h
```

For a detailed explanation of the compilation process, declarative hardware configuration, and the dependency caching system, see the [build system documentation](docs/build.md).

### Output files
The hypervisor executable is generated at `./zig-out/bin/vmdiosix`.

---

## Develop and contribute

We welcome contributions to the project and ask that you follow our established development standards to ensure high-quality code and documentation.

### Guidelines
* **Memory ownership:** When writing new code, please be mindful of ownership and memory management; function callers are responsible for freeing any pointers returned by functions that require an allocator. Always use the provided allocator for cleanup to avoid leaks.
* **Unit testing:** We require comprehensive unit tests for all new core logic to verify correctness. These tests run on the build host and must pass successfully before any changes are accepted into the codebase. To execute the test suite, run the following command:
  ```bash
  ./scripts/build.sh test
  ```
* **Style guide:** All contributions must strictly adhere to the [Diosix style guide](docs/style-guide.md). This covers both our technical writing standards — such as defining abbreviations on first use and using sentence-case headings — and our idiomatic Zig coding conventions.

### Versioning and branching model
We use the [Calendar Versioning](https://calver.org/) (YY.MINOR) format for our releases, where even-numbered minor versions indicate stable releases and odd numbers represent development builds.

The project maintains two primary branches to orchestrate development and releases:
* **`stable`**: The branch representing production-ready code. Releases are created directly from this branch, and it is also the source branch used to build the official project website, [diosix.org](https://diosix.org/).
* **`devel`**: The active staging branch for development and ongoing feature additions.

Development workflows should target the `devel` branch. Changes are only merged from `devel` into `stable` after completing rigorous testing, quality control, and validation.

---

## Contact and community

If you have questions, wish to contribute, or need to report an issue, email [hello@diosix.org](mailto:hello@diosix.org). You can also submit pull requests or raise issues through this GitHub repository.

If you have discovered a security vulnerability, please follow the [security reporting process](docs/security.md#reporting-security-issues) to disclose the matter privately and responsibly.

All participants are expected to follow the project's [code of conduct](docs/conduct.md).

---

## Copyright and license

Copyright &copy; 2024-2026 Diosix contributors. This project is distributed under the terms of the MIT License. See [LICENSE](LICENSE) for the full text and [CONTRIBUTORS](CONTRIBUTORS) for the list of copyright holders.

The diosix.org illustration is a combination of artwork provided by [Katerina Limpitsouni](https://undraw.co/license) and [RISC-V International](https://riscv.org/about/risc-v-branding-guidelines/). 

All product names, logos, brands, trademarks, and registered trademarks are property of their respective owners. All company, product, and service names used by the Diosix project and its contributors are for identification purposes only. Use of these names, logos, and brands does not imply endorsement.