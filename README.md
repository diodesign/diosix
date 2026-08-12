[![Diosix continuous integration](https://github.com/diodesign/diosix/actions/workflows/ci.yml/badge.svg)](https://github.com/diodesign/diosix/actions/workflows/ci.yml) [![Language: Zig](https://img.shields.io/badge/language-zig-darkorange.svg)](https://ziglang.org/) [![Platform: riscv64](https://img.shields.io/badge/platform-riscv64-lightblue.svg)](https://riscv.org/)

# About Diosix

Diosix is a type-1 bare-metal hypervisor written in the Zig programming language
for multi-core 64-bit RISC-V systems. It allows machines large and small to run
multiple hardware-isolated guest operating systems simultaneously.

The hypervisor seamlessly supports 64-bit Arm and x86 guests, as well as 32-bit and
64-bit RISC-V guests.

This project is an ongoing work-in-progress. By using Zig, we aim to innovate and
iterate quickly while maintaining a strict focus on safety, security, and
robustness. We target RISC-V for its open, modular, and extensible nature.

---

## Quickstart

The simplest way to run and test Diosix is inside the QEMU emulator. The
following instructions assume you are using a Linux build machine and are
comfortable using a command-line interface.

You can use Docker to avoid installing and managing the project's build
dependencies manually, or you can install them yourself by hand:

<p>
<details markdown="1">
<summary><strong>Use a Docker container</strong></summary>

To use Docker to build and run Diosix, follow these steps.
  
1. Make sure you have Docker installed and running on your system.
   We recommend version 29.5.2 or later.
  
1. Clone the Diosix source code, and enter its directory:
  
   ```bash
   git clone https://github.com/diodesign/diosix.git
   cd diosix
   ```
   
1. Build a container image of your preferred distribution:
  
   ```bash
   # For Ubuntu 22.04
   docker build -f dockerfiles/ubuntu-22.04.Dockerfile -t diosix-ubuntu .
       
   # For Fedora 44
   docker build -f dockerfiles/fedora-44.Dockerfile -t diosix-fedora .
   ``` 
  
1. Use the build wrapper script to compile and run Diosix within the container:
  
   ```bash
   # For Ubuntu 22.04
   docker run -it --rm diosix-ubuntu ./scripts/build.sh run
   
   # For Fedora 44
   docker run -it --rm diosix-fedora ./scripts/build.sh run
   ```

</details>
</p>

<p>
<details markdown="1">
<summary><strong>Use the manual method</strong></summary>
  
To install the build dependencies, and compile and run Diosix manually,
follow these steps:
  
1. Make sure you have the following installed:
  
   * The hypervisor and guest operating system [build dependencies](docs/build.md).
   * QEMU version 10 or later. Earlier versions, such as 6.2, may suffice.
  
1. Clone the Diosix source code, and enter its directory:
  
   ```bash
   git clone https://github.com/diodesign/diosix.git
   cd diosix
   ```
  
1. Use the build wrapper script to compile and run Diosix:
  
   ```bash
   ./scripts/build.sh run
   ```

</details>
</p>

The build process automatically compiles from source a trusted 64-bit RISC-V Linux guest
virtual machine (VM) called the Root VM, which assists the hypervisor in
managing the host hardware and running other guests.

Once the build completes, QEMU boots the hypervisor, which then automatically
boots and runs the included Root VM.

The hypervisor outputs debug and diagnostic information to the terminal, and you
can interact with the running Root VM via the terminal, too.

To log in to the Root VM, use the username `root` with no password. If the Root VM is powered
off, the hypervisor will automatically restart.

To control the emulator process from your terminal:

*  Exit the emulator by pressing `Ctrl-a` followed by `x` to terminate QEMU.
*  Enter the QEMU monitor shell by pressing `Ctrl-a` followed by `c`. Press
   `Ctrl-a` and `c` again to return to the hypervisor console.

The following is a recording of a user building and running Diosix, and then
logging into and interacting with the Root VM running on the hypervisor.

[![asciicast of Diosix running](https://asciinema.org/a/1214657.svg)](https://asciinema.org/a/1214657)

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
*  **[Develop Diosix](docs/development.md):** View the project's programming
   guidelines, memory ownership rules, unit testing commands, Git
   branching workflows, and CalVer release versioning.

For more information about the technology used by the hypervisor, see the
following external documentation:

*  [Learn about Zig](https://ziglang.org/learn/).
*  [RISC-V for developers](https://riscv.org/developers/).

---

## Legal stuff

Diosix source code and binaries are distributed under the terms of the MIT License. See [LICENSE.md](LICENSE.md) for the full text and [CONTRIBUTORS.md](CONTRIBUTORS.md) for the list of copyright holders.

The diosix.org website illustration is a combination of artwork provided by
[Katerina Limpitsouni](https://undraw.co/license) and
[RISC-V International](https://riscv.org/about/risc-v-branding-guidelines/).

All product names, logos, brands, trademarks, and registered trademarks are
property of their respective owners. All company, product, and service names used
by the Diosix project are for identification purposes only.
Use of these names, logos, and brands does not imply endorsement.
