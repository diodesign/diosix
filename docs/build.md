# Build system, porting, and debugging

The Diosix build pipeline pairs the Zig build system with a cached Buildroot
workspace to compile the machine-mode (M-mode) hypervisor, userland management
and desktop tools, the guest bootloader shim, and the embedded Linux root
virtual machine (VM) from source.

This reference covers host dependencies, build-time configuration files,
incremental caching, physical board deployment, and remote GNU debugger (GDB)
debugging.

---

## Build process and dependencies

### Host build machine dependencies

To build Diosix on a Linux build machine, install Zig 0.17.0 or later, Git 2.54
or later, QEMU 10.0 or later (for emulated runs), and standard Buildroot host
packages.

On Debian or Ubuntu (such as Ubuntu 26.04 LTS):

```bash
sudo apt update
sudo apt install -y \
    bc bison build-essential cpio dosfstools e2fsprogs fdisk file \
    findutils flex gawk git libelf-dev libssl-dev mtools openssh-client \
    procps python3 python3-pexpect qemu-system-gui qemu-system-riscv \
    rsync u-boot-tools unzip util-linux wget xz-utils
```

On Fedora (such as Fedora 44):

```bash
sudo dnf group install -y development-tools
sudo dnf install -y \
    bc bison cpio dosfstools e2fsprogs elfutils-libelf-devel file \
    findutils flex gawk gcc-c++ git mtools openssh-clients openssl-devel \
    perl-English perl-ExtUtils-MakeMaker perl-FindBin perl-IPC-Cmd \
    perl-Thread-Queue perl-open procps-ng python3 python3-passlib \
    python3-pexpect qemu-system-riscv rsync uboot-tools unzip util-linux \
    wget which xz
```

### Containerized builds with Docker

If you want a self-contained build environment without installing packages on
your build machine, use the Dockerfiles in `dockerfiles/`:

```bash
# Build the Ubuntu 26.04 LTS or Fedora 44 container image
docker build -f dockerfiles/ubuntu-26.04.Dockerfile -t diosix-ubuntu .
docker build -f dockerfiles/fedora-44.Dockerfile -t diosix-fedora .

# Compile the hypervisor and root VM inside the container
docker run -it --rm diosix-ubuntu ./scripts/build.sh

# Run the unit test suite inside the container
docker run -it --rm diosix-ubuntu ./scripts/build.sh test --summary all
```

### Build wrapper targets

Run builds through `./scripts/build.sh` so Git commit metadata, calendar
versioning (CalVer) numbers, and hardware sizing defaults are passed cleanly to
Zig:

| Command | Description |
| :--- | :--- |
| `./scripts/build.sh` | Compiles userland tools, the guest shim, the Linux root VM, the built-in CLI and Wayland desktop guest images, and the M-mode hypervisor binary. |
| `./scripts/build.sh test --summary all` | Runs all host-native unit test suites and verifies the feature graph, Markdown links, and support matrix. |
| `./scripts/build.sh features` | Verifies the feature graph and Markdown links and regenerates `docs/support-matrix.md`. |
| `./scripts/build.sh test-integration` | Builds the system and runs the live 4-hart QEMU integration suite. |
| `./scripts/build.sh run` | Builds and boots Diosix in QEMU headless serial mode. |
| `./scripts/build.sh run-gui` | Builds and boots Diosix in QEMU with the graphical desktop. |
| `./scripts/build.sh run-desktop` | Builds and boots straight into the built-in Weston Wayland desktop RISC-V guest VM. |
| `./scripts/build.sh run-cli` | Builds and boots straight into an interactive CLI RISC-V guest VM over the serial console. |
| `./scripts/build.sh run-tpm` | Builds and boots the graphical desktop in QEMU with an emulated trusted platform module (TPM) 2.0. |
| `./scripts/build.sh live-image` | Builds the 640 MiB hybrid GPT live disk image, flat M-mode binary, U-Boot image source, and `zig-out/run-qemu.sh`. |
| `./scripts/build.sh run-live` / `run-live-gui` | Builds and boots the hybrid GPT live image in QEMU (serial or graphical). |
| `./scripts/build.sh release` | Packages `zig-out/release/diosix-26.1-riscv64.tar.xz` with `vmdiosix`, the hybrid GPT live image, `run-diosix.sh`, quickstart notes, and `SHA256SUMS`. |
| `./scripts/build.sh -h` | Lists all build targets and build-time `-D` options. |

### Build-time configuration options

Pass Zig build flags directly to `./scripts/build.sh`:

```bash
# Test physical memory protection (PMP) fallback (disable H-extension)
./scripts/build.sh run -Dpmp=true

# Target CPUs or emulators without Sstc or Smstateen extensions
./scripts/build.sh run -Dlegacy-cpu=true

# Build with ReleaseSafe optimizations
./scripts/build.sh -Doptimize=ReleaseSafe

# Change QEMU symmetric multiprocessing (SMP) core count and host RAM
./scripts/build.sh run -Dsmp=8 -Dmem=4G
```

---

## Build architecture and configuration files

### Declarative build configuration

Diosix keeps repository layout, feature-to-documentation mappings, and hardware
sizing defaults in declarative files outside the build logic:

| File | Permissions | Purpose |
| :--- | :--- | :--- |
| [`build/layout.zon`](../build/layout.zon) | `0644` | Module roots, assembly source paths, and unit test suite definitions read by `build.zig`. |
| [`build/features.zon`](../build/features.zon) | `0644` | Directed feature graph mapping every tracked file from the M-mode entry point and build graph to its callers and documentation headings. |
| [`boot/hypervisor.conf`](../boot/hypervisor.conf) | `0644` | M-mode hypervisor hardware and emulation sizing defaults (root VM RAM bounds, vCPU ceiling, and emulation batch limits). |

### Metadata injection and multi-tier caching

* Zig caches the build graph across invocations, so running Git commands inside
  the build script itself would leave stale commit hashes when the build script
  has not changed. Instead, the wrapper script queries Git and the hypervisor
  configuration file up front and passes them as build options, recompiling
  only a small metadata object when the commit changes.
* Hypervisor source edits rebuild in seconds inside the Zig cache without
  recompiling Linux or userland packages.
* Cross-compiled userland tools are staged into a generated overlay directory
  under the build output folder rather than writing build artifacts into the
  tracked source tree.
* The Buildroot workspace retains the compiled Linux kernel, hypervisor
  character driver, and root filesystem packages across builds, repacking the
  root VM image only when staged overlay binaries change.

---

## Platform-agnostic M-mode bootstrap and hardware porting

Diosix compiles to a single position-independent M-mode binary that boots on
64-bit RISC-V system-on-chip (SoC) boards and emulators without board-specific
rebuilds.

### Early assembly bootstrap

* All early assembly uses program-counter-relative addressing so the hypervisor
  can execute from any 2 MiB-aligned DRAM base address.
* Rather than assuming hardware hart 0 is the boot processor—which fails on
  SoCs where hart 0 is a small monitor core and application cores start at hart
  1—the reset vector runs an atomic fetch-and-add lottery so the first hart
  claiming slot 0 initializes the system while secondary harts park until SMP
  startup completes.

### Runtime FDT hardware discovery

During early boot, the bootstrap hart parses the host device tree blob (DTB)
passed by firmware to locate memory-mapped input/output (MMIO) devices at
runtime:

* It discovers the host 16550-compatible or SiFive universal asynchronous
  receiver-transmitter (UART) base address for the M-mode debug console.
* It enables hardware timer comparator registers when advertised in the
  flattened device tree (FDT) instruction set architecture (ISA) string, or
  falls back to core-local interruptor (CLINT) MMIO timer registers.
* It reads the boot command line from the host DTB and forwards hypervisor and
  root VM boot parameters into the generated root VM DTB.

### Booting on physical RISC-V boards

Run `./scripts/build.sh live-image` to produce physical boot artifacts under
`zig-out/`:

1. Flash the hybrid GPT live image to an SD card, eMMC module, or USB drive:

   ```bash
   sudo dd if=zig-out/diosix-live-riscv64.img of=/dev/sdX \
       bs=4M status=progress conv=fsync
   ```

   Alternatively, copy `zig-out/guest-riscv64/bin/vmdiosix.bin` (or the U-Boot
   flattened image tree (FIT) image `zig-out/u-boot.itb`) onto your board's
   boot partition.
2. Configure the board's M-mode loader (such as U-Boot secondary program loader
   (SPL)) to load `vmdiosix.bin` at `0x80000000` and jump to its entry point in
   M-mode.
3. Pass the physical hart ID in register `a0` and the board's DTB host physical
   address (HPA) in register `a1`.

---

## Remote debugging with GDB

Diosix supports both QEMU's built-in GDB TCP server and an optional
freestanding GDB remote serial protocol (RSP) stub compiled into M-mode.

### Debugging in QEMU over TCP

Pass `--debug` to `./scripts/build.sh run` to compile with debug symbols and
wait for a GDB connection on `localhost:1234`:

```bash
# Start QEMU with unoptimized symbols and GDB listening on localhost:1234
./scripts/build.sh run --debug

# Or combine with PMP fallback or a minimal 32-bit guest profile
./scripts/build.sh run -Dpmp=true --debug
./scripts/build.sh run -Dguest-arch=riscv32 -Dguest-profile=minimal --debug
```

In a second terminal, attach `gdb` using `vmdiosix` for M-mode hypervisor
symbols or `rootvm.elf` for Linux root VM symbols:

```bash
gdb zig-out/guest-riscv64/bin/vmdiosix -ex "target remote localhost:1234"
```

### Debugging over serial RSP

When compiled with `-Dgdb=true`, the M-mode serial stub frames debug output as
RSP packets and polls the physical UART for incoming debugger commands:

```bash
gdb zig-out/guest-riscv64/bin/vmdiosix -ex "target remote /dev/ttyUSB0"
```

### Common GDB commands

| Task | Command |
| :--- | :--- |
| Inspect call stack | `bt` |
| Inspect CPU registers | `info registers` |
| Set breakpoint | `break start_kernel` or `break *0x80000000` |
| Single-step instruction | `stepi` or `nexti` |

To dump registers and a backtrace non-interactively:

```bash
gdb -batch -ex "target remote localhost:1234" \
    -ex "bt" -ex "info registers" \
    zig-out/guest-riscv64/bin/rootvm.elf
```
