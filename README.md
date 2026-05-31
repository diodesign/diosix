[![License: MIT](https://img.shields.io/github/license/diodesign/diosix)](https://github.com/diodesign/diosix/blob/main/LICENSE) [![Language: Zig](https://img.shields.io/badge/language-zig-darkorange.svg)](https://ziglang.org/) [![Platform: riscv64](https://img.shields.io/badge/platform-riscv64-lightblue.svg)](https://riscv.org/)

# Diosix

Diosix is a type-1 bare-metal hypervisor written in the [Zig](https://ziglang.org/)
programming language for 64-bit [RISC-V](https://riscv.org/developers/) systems.
It allows systems small and large to run multiple hardware-isolated operating
systems at the same time.

This project is an ongoing work-in-progress. By using Zig, we aim to innovate and
iterate quickly while maintaining a strict focus on safety, security, and
robustness.

---

## Quick start

The simplest way to run and test Diosix is inside an emulated environment using
the QEMU emulator. The following instructions assume you are using a Linux host
system and are comfortable using a command-line terminal.

Before you begin, ensure you have the following software installed on your host:
*  [QEMU](https://www.qemu.org/) version 10.1.5 or later.
*  [Git](https://git-scm.com/) version 2.54 or later.
*  [Zig](https://ziglang.org/download/) version 0.17.0 or later.

To build, compile, and run the complete system:

1.  **Clone the repository and enter the project directory:**
    ```bash
    git clone --branch stable https://github.com/diodesign/diosix.git
    cd diosix
    ```
2.  **Compile the hypervisor and boot the system inside QEMU:**
    ```bash
    ./scripts/build.sh run
    ```

By default, the hypervisor sends its output to the serial port, which QEMU
displays directly in your terminal. You can exit and terminate the emulator at
any time by pressing `Ctrl-a` followed by `x`. To enter the QEMU debug monitor,
press `Ctrl-a` followed by `c`.

Below is a recording of a user logging into and interacting with a Linux guest
Virtual Machine (VM) running on Diosix.

[![asciicast](https://asciinema.org/a/1161817.svg)](https://asciinema.org/a/1161817)

---

## More information

For deep-dives into configuration, custom deployment, and contributing to the
project, please see our dedicated documentation guides:

*  **[Diosix architecture](docs/architecture.md):** Learn about our hierarchical
   forking model, privileged Root VM design, security boundary rules, and memory
   address space terminology.
*  **[Build Diosix](docs/build.md):** Read about our automated build system,
   host environment metadata injection, declarative hardware target ports, and
   incremental build caching.
*  **[Run Diosix](docs/run.md):** Learn how to run the hypervisor, use target
   emulators, customize boot parameters, and load payloads onto physical
   hardware targets.
*  **[Develop for Diosix](docs/development.md):** View our programming
   guidelines, memory ownership rules, unit testing commands, contribution
   branching workflows, and CalVer release versioning.

---

## Copyright and license

Copyright &copy; 2024-2026 Diosix contributors. This project is distributed
under the terms of the MIT License. See [LICENSE](LICENSE) for the full text and
[CONTRIBUTORS](CONTRIBUTORS) for the list of copyright holders.

The diosix.org website illustration is a combination of artwork provided by
[Katerina Limpitsouni](https://undraw.co/license) and
[RISC-V International](https://riscv.org/about/risc-v-branding-guidelines/).

All product names, logos, brands, trademarks, and registered trademarks are
property of their respective owners. All company, product, and service names used
by the Diosix project and its contributors are for identification purposes only.
Use of these names, logos, and brands does not imply endorsement.