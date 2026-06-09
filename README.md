[![License: MIT](https://img.shields.io/github/license/diodesign/diosix)](https://github.com/diodesign/diosix/blob/main/LICENSE) [![Language: Zig](https://img.shields.io/badge/language-zig-darkorange.svg)](https://ziglang.org/) [![Platform: riscv64](https://img.shields.io/badge/platform-riscv64-lightblue.svg)](https://riscv.org/)

# About this project

Diosix is a type-1 bare-metal hypervisor written in the Zig programming language
for 64-bit RISC-V systems. It allows systems large and small to run multiple
hardware-isolated operating systems at the same time.

This project is an ongoing work-in-progress. By using Zig, we aim to innovate and
iterate quickly while maintaining a strict focus on safety, security, and
robustness. We target RISC-V for its open, modular, and extensible nature.

---

## Quickstart

The simplest way to run and test Diosix is inside the QEMU emulator. The
following instructions assume you are using a Linux host system and are
comfortable using a command-line interface.

Before you begin, make sure you have the following installed:

* [Build dependencies](docs/build.md): Package dependencies and tools required
  to compile Diosix.
* QEMU 10 or later. See [Run Diosix](docs/run.md) for more information
  about supported platforms.

To compile and run the complete system:

1. Clone the repository, and enter the project directory:

   ```bash
   git clone https://github.com/diodesign/diosix.git
   cd diosix
   ```

1. Compile the hypervisor, and boot the system inside QEMU:

   ```bash
   ./scripts/build.sh run
   ```

   The build process automatically compiles from source a trusted Linux guest
   virtual machine (VM) called the Root VM, which assists the hypervisor in
   managing the host hardware and running other guests. Once compilation completes,
   QEMU boots the hypervisor, which then automatically starts and runs this Root VM.

   The hypervisor outputs debug and diagnostic information directly to your
   terminal. You can interact with the running Root VM via the terminal, too.

1. To log in to the Root VM, use the username `root` with no password.

   If the Root VM is powered off, the hypervisor will automatically restart.

To control the emulator process from your terminal:

*  Exit the emulator by pressing `Ctrl-a` followed by `x` to terminate
   the emulation.
*  Enter the QEMU monitor shell by pressing `Ctrl-a` followed by `c`. Press
   `Ctrl-a` and `c` again to return to the hypervisor console.

The following is a recording of a user building and running Diosix, and then
logging into and interacting with the Root VM running on the hypervisor.

[![asciicast](https://asciinema.org/a/1161817.svg)](https://asciinema.org/a/1161817)

---

## More information

For more information about Diosix, see the following documentation:

*  **[Diosix architecture](docs/architecture.md):** Learn about the hypervisor's
   hierarchical forking model, privileged Root VM design, security boundary rules,
   and memory address space terminology.
*  **[Build Diosix](docs/build.md):** Learn about the build system, build commands,
   and incremental build caching.
*  **[Run Diosix](docs/run.md):** Learn how to run the hypervisor, use target
   emulators, customize boot parameters, and load the software onto physical
   hardware targets.
*  **[Develop for Diosix](docs/development.md):** View the project's programming
   guidelines, memory ownership rules, unit testing commands, Git
   branching workflows, and CalVer release versioning.

For more information about the technology used by the hypervisor, see the
following external documentation:

*  [Learn about Zig](https://ziglang.org/learn/).
*  [RISC-V for developers](https://riscv.org/developers/).

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
by the Diosix project are for identification purposes only.
Use of these names, logos, and brands does not imply endorsement.