[![Diosix continuous integration][ci-badge]][ci-url]
[![Language: Zig][zig-badge]](https://ziglang.org/)
[![Platform: riscv64][rv64-badge]](https://riscv.org/)

[ci-badge]: https://github.com/diodesign/diosix/actions/workflows/ci.yml/badge.svg
[ci-url]: https://github.com/diodesign/diosix/actions/workflows/ci.yml
[zig-badge]: https://img.shields.io/badge/language-zig-darkorange.svg
[rv64-badge]: https://img.shields.io/badge/platform-riscv64-lightblue.svg

# About Diosix

Diosix is a type-1 bare-metal hypervisor written in the Zig programming
language for multi-core 64-bit RISC-V systems. It allows machines large and
small to run multiple hardware-isolated guest operating systems simultaneously.

The hypervisor supports 64-bit RISC-V (`riscv64`) native guests and 32-bit
RISC-V (`riscv32`) guests via its freestanding dynamic binary recompiler
(`dynarec`), with 64-bit Arm (`aarch64`) and 64-bit x86 (`x86_64`) architecture
recognition for future cross-architecture emulation.

This project is an ongoing work-in-progress. By using Zig, we aim to innovate
and iterate quickly while maintaining a strict focus on safety, security, and
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

To use Docker to build and run Diosix, follow these steps:

1. Make sure you have Docker installed and running on your system.
   We recommend version 29.5.2 or later.

2. Clone the Diosix source code, and enter its directory:

   ```bash
   git clone https://github.com/diodesign/diosix.git
   cd diosix
   ```

3. Build a container image of your preferred distribution:

   ```bash
   # For Ubuntu 22.04
   docker build -f dockerfiles/ubuntu-22.04.Dockerfile -t diosix-ubuntu .

   # For Fedora 44
   docker build -f dockerfiles/fedora-44.Dockerfile -t diosix-fedora .
   ```

4. Use the build wrapper script to compile and run Diosix within the container:

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

   * The hypervisor and guest operating system
     [build dependencies](docs/build.md).
   * QEMU version 10 or later. Earlier versions, such as 6.2, may suffice.

2. Clone the Diosix source code, and enter its directory:

   ```bash
   git clone https://github.com/diodesign/diosix.git
   cd diosix
   ```

3. Use the build wrapper script to compile and run Diosix in headless serial
   mode or graphical desktop mode:

   ```bash
   # Headless serial console
   ./scripts/build.sh run

   # Graphical desktop (VirtIO-GPU + diosix-gui)
   ./scripts/build.sh run-gui
   ```

</details>
</p>

The build process automatically compiles from source a trusted 64-bit RISC-V
Linux guest Virtual Machine (VM) called the Root VM, which assists the
hypervisor in managing the host hardware and running other guests.

Once the build completes, QEMU boots the hypervisor, which then automatically
boots and runs the included Root VM.

In local developer emulation (`diosix.mode=dev`), log in to the Root VM serial
console using `root` (with developer SSH keys auto-enrolled). On live and
installed systems, password logins are disabled in favor of cryptographic
passkeys (`dsx auth`). If the Root VM is powered off, the hypervisor shuts down
or restarts the host cleanly.

### Explore hypervisor features

Once logged into the Root VM, expand the sections below to test Diosix's core
virtualization features, or follow the full
[interactive hypervisor tour](docs/run.md#interactive-hypervisor-tour):

<p>
<details markdown="1">
<summary><strong>Manage VMs, quotas, and snapshots with dsx</strong></summary>

Use the `dsx` (`diosix-ctl`) command-line utility inside the Root VM to inspect
hardware isolation, spawn child VMs, adjust live quotas, and capture snapshots:

```bash
# 1. Inspect M-mode hypervisor capabilities and Root VM status
dsx host info
dsx info

# 2. Spawn a trusted service VM and an untrusted (sandboxed) user VM
dsx run linux-guest --name sys-domain --trusted --vcpus 1 --ram 128M
dsx run linux-guest --name user-domain --vcpus 2 --ram 256M
dsx list

# 3. Adjust resource quotas and reserve 25% of physical CPU capacity
dsx quota self --ram 1024 --vcpus 4 --retained-pcpu 25

# 4. Save and list a live child VM memory + disk checkpoint
dsx snapshot save sys-domain clean-boot
dsx snapshot list

# 5. Browse SHA-256 verified guest OS images in the built-in catalog
dsx image catalog
```

</details>
</p>

<p>
<details markdown="1">
<summary><strong>Boot the live image and installer</strong></summary>

Build and boot the 512 MiB hybrid GUID Partition Table (GPT) release image in
headless serial mode (or with the experimental `diosix-gui` desktop):

```bash
# Build and boot the hybrid GPT live image in serial mode
./scripts/build.sh run-live

# Or boot the live image with the experimental graphical desktop
./scripts/build.sh run-live-gui
```

From the Root VM shell, you can also walk through the interactive system tour
and preview bare-metal host installation:

```bash
# View the 5-step interactive system tour
dsx tour

# Preview a guided bare-metal disk installation plan
dsx host install --mode basic --dry-run
```

</details>
</p>

To control the emulator process from your terminal:

*  Exit the emulator by pressing `Ctrl-a` followed by `x` to terminate QEMU.
*  Enter the QEMU monitor shell by pressing `Ctrl-a` followed by `c`. Press
   `Ctrl-a` and `c` again to return to the hypervisor console.

The following is a verbatim recording
([`docs/diosix-demo.cast`](docs/diosix-demo.cast), playable locally with
`asciinema play docs/diosix-demo.cast`) of booting Diosix and managing guest
VMs, quotas, and snapshots from the Root VM shell:

[![asciicast of Diosix running](https://asciinema.org/a/1214657.svg)](https://asciinema.org/a/1214657)

---

## More information

For more information about Diosix, see the following documentation:

*  **[Technical background](docs/background.md):** Understand the design
   philosophy, minimal Trusted Computing Base (TCB), and directory of
   deep-dive technical guides.
*  **[Diosix architecture](docs/architecture.md):** Learn about the
   hypervisor's hierarchical guest model, privileged Root VM design, security
   boundary rules, and memory address space terminology.
*  **[Interface and Application Binary Interface (ABI)](docs/interface.md):**
   Discover the hypervisor's Supervisor Binary Interface (SBI) extensions,
   Context ID (CID) capability model, and Linux driver interface.
*  **[Command-line interface](docs/cli.md):** Learn how to use the
   `diosix-ctl` (`dsx`) utility to run, control, and communicate with guest
   VMs.
*  **[Security model](docs/security.md):** Understand hardware-enforced
   isolation, tree-based segmentation, asymmetric credential management, and
   network containment.
*  **[Build Diosix](docs/build.md):** Learn about the build system, build
   commands, and incremental build caching.
*  **[Run Diosix](docs/run.md):** Learn how to run the hypervisor, use target
   emulators, customize boot parameters, and load the software onto physical
   hardware targets.
*  **[Develop Diosix](docs/development.md):** View the project's programming
   guidelines, memory ownership rules, unit testing commands, Git branching
   workflows, Calendar Versioning (CalVer) release model, and how to use the
   official
   [Diosix agent skills](https://github.com/diodesign/diosix-agent-skills)
   with AI coding agents.
*  **[GUI and system configuration architecture](docs/gui-architecture.md):**
   Explore the monolithic Direct Rendering Manager (DRM) and Kernel Mode
   Setting (KMS) desktop compositor (`diosix-gui`) and domain isolation model.
*  **[Release and Steward architecture](docs/release-architecture.md):**
   Learn about CalVer release channels, hardware seat profiles, the
   freestanding Supervisor-mode (S-mode) guest bootloader shim, passkey-only
   authentication, and the autonomic Steward VM collective.

For more information about the technology used by the hypervisor, see the
following external documentation:

*  [Learn about Zig](https://ziglang.org/learn/).
*  [RISC-V for developers](https://riscv.org/developers/).

---

## Legal stuff

Unless otherwise stated, Diosix source code and provided binaries are
distributed under the terms of the MIT License. See [LICENSE.md](LICENSE.md)
for the full text and [CONTRIBUTORS.md](CONTRIBUTORS.md) for the list of
copyright holders.

All product names, logos, brands, trademarks, and registered trademarks are
property of their respective owners. All company, product, and service names
used by the Diosix project are for identification purposes only. Use of these
names, logos, and brands does not imply endorsement.
