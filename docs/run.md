# Run Diosix

This page describes how to boot Diosix in emulation or on physical
hardware, configure custom targets, and control emulator execution.

When Diosix runs, it starts an included trusted guest Virtual Machine (VM)
called the Root VM. The Root VM then launches and manages additional guest
VMs. You can interact with the Root VM and guest VMs via the serial console
or graphical desktop to run programs and configure and monitor the system.

---

## System requirements

The target system must meet the following hardware requirements:

* One or more 64-bit RVA20 RV64GC RISC-V processor cores.
* Support for either the RISC-V Hypervisor (H) extension or Physical Memory
  Protection (PMP).
* For QEMU-emulated runs, we recommend version 10.1.5 or later of the QEMU
  emulator. Earlier versions, such as 6.2, should suffice.

---

## Run Diosix in emulation

The simplest way to run and test Diosix is inside the QEMU emulator. Emulation
lets you iterate on hypervisor and guest development and debug
platform-specific drivers without needing physical target hardware.

### Prerequisites

Before you can run Diosix using the wrapper script in this section, follow the
steps in [Build Diosix](build.md) to install the required dependencies and
fetch the project source code. Then, you can use the wrapper script to build
and run the hypervisor and the Root VM.

### Install QEMU

If you haven't already installed a 64-bit RISC-V QEMU emulator on your build
machine, install it before running Diosix in emulation.

The following commands install QEMU on Debian or Ubuntu systems:

```bash
sudo apt update
sudo apt install -y qemu-system-misc
```

On Fedora systems, run:

```bash
sudo dnf install -y qemu-system-riscv
```

### Run Diosix using the build wrapper

To run Diosix inside QEMU in headless serial mode, run the build wrapper script
as follows:

```bash
./scripts/build.sh run
```

To boot Diosix in QEMU with a graphical desktop (`virtio-gpu-device`,
`virtio-keyboard-device`, and `virtio-tablet-device`) launching `diosix-gui`:

```bash
./scripts/build.sh run-gui
```

These commands build the platform-agnostic, universal hypervisor binary and
boot it in a standard RISC-V 64-bit QEMU `virt` machine environment.

The build script also generates the native Root VM image and boots the
hypervisor and the Root VM in QEMU. In local developer emulation
(`diosix.mode=dev`), you can log in on the serial console using `root` (and
developer SSH keys are auto-enrolled in `/var/lib/diosix/keys/`).

Rebooting the Root VM reboots the hypervisor.

### Run as an ephemeral live instance or system installer

To boot Diosix in QEMU with the full GUID Partition Table (GPT) live release
image (`zig-out/diosix-live-riscv64.img`) attached as primary `virtio-blk`
block storage:

```bash
# Headless serial ephemeral live mode (diosix.mode=live)
./scripts/build.sh run-live

# Graphical desktop ephemeral live mode (diosix.mode=live)
./scripts/build.sh run-live-gui
```

When you build the live image (`./scripts/build.sh live-image`), the build
system also generates a standalone launcher script at `zig-out/run-qemu.sh`
that runs the packaged release artifacts directly without invoking the build
system:

```bash
./zig-out/run-qemu.sh [--gui] [--smp 4] [--mem 2G] \
    [--mode live|install|persistent|dev]
```

In ephemeral live (`diosix.mode=live`) and installer (`diosix.mode=install`)
modes, the Root VM mounts the live data partition read-only, stages the
pre-seeded guest images (`/var/lib/diosix/images/diosix-base-linux.elf`) and
system manifest (`/etc/diosix/system.toml`) into a RAM-backed `tmpfs` at
`/var/lib/diosix`, and unmounts the physical block device. This ensures:

*   All runtime state during a live session is strictly **ephemeral in RAM**
    and never mutates the boot media.
*   The underlying block device (`/dev/vda`, `/dev/sda`, or `/dev/nvme0n1`) is
    left unmounted so `dsx host install` can partition, format (`DIOSIX_BOOT`,
    `DIOSIX_STATE`, `DIOSIX_DATA`), and install Diosix onto target storage.
*   When subsequently booted in persistent mode (`--mode persistent` or the
    `diosix-persistent` boot menu entry), the Root VM mounts `DIOSIX_DATA`
    read-write at `/var/lib/diosix` and applies the configured hostname from
    `/var/lib/diosix/state/hostname`.

---

## Interactive hypervisor tour

Once you have logged into the Root VM console, you can explore Diosix's
virtualization, isolation, and lifecycle management features using the `dsx`
(`diosix-ctl`) utility. A verbatim terminal recording of this workflow is
included at [`docs/diosix-demo.cast`](diosix-demo.cast) (replayable with
`asciinema play docs/diosix-demo.cast`).

### 1. Inspect host hardware and Root VM capabilities

Query the M-mode hypervisor for physical CPU features (such as the RISC-V H
extension, `Sstc`, `Smstateen`, and `VirtIO-vsock`) and inspect the Root VM's
own capability handle (`CID 1`):

```bash
dsx host info
dsx info
dsx tour
```

### 2. Spawn trusted and sandboxed child VMs

Launch multiple concurrent guest VMs from the pre-seeded `linux-guest` image.
Use `--trusted` for infrastructure domains (such as network or storage service
VMs) and omit `--trusted` to launch hardware-sandboxed leaf VMs:

```bash
# Launch a trusted system service VM (1 vCPU, 128 MiB RAM)
dsx run linux-guest --name sys-domain --trusted --vcpus 1 --ram 128M

# Launch an untrusted (sandboxed) user VM (2 vCPUs, 256 MiB RAM)
dsx run linux-guest --name user-domain --vcpus 2 --ram 256M

# Inspect the active VM hierarchy and isolated network assignments
dsx list

# Execute a command inside a child VM over key-authenticated SSH
dsx ssh root@user-domain -- uname -a
```

### 3. Attenuate resource quotas and physical CPU retention

Adjust the maximum RAM, vCPUs, tree depth, descendant count, and physical CPU
retention percentage (`--retained-pcpu`) for the Root VM or any child VM:

```bash
dsx quota self --ram 1024 --vcpus 4 --depth 4 --descendants 8 --retained-pcpu 25
```

### 4. Capture and restore live VM snapshots

Save a live VM's register state, guest physical RAM pages, and attached disk
state to `/var/lib/diosix/snapshots/`, then restore or delete the checkpoint:

```bash
dsx snapshot save sys-domain clean-boot
dsx snapshot list
dsx snapshot restore clean-boot
```

### 5. Manage virtual disks and verified guest OS images

Create and resize persistent `ext4` virtual disks, browse the built-in Guest OS
catalog (`/etc/diosix/catalog.toml`), and pull SHA-256 verified images:

```bash
dsx disk create app-data --size 256M
dsx disk resize app-data --size 512M
dsx disk list

dsx image catalog
dsx image list
```

### 6. Control the graphical desktop and bare-metal installer

When booted with `run-gui` or `run-live-gui`, you can inspect or drive the
monolithic DRM/KMS desktop compositor (`diosix-gui`) from the CLI and preview
bare-metal host installation:

```bash
# Query current GUI window state and trigger semantic navigation
dsx gui state
dsx gui trigger tour.start
dsx gui trigger menu.create_vm
dsx gui trigger menu.status

# Preview a guided bare-metal installation onto a target block device
dsx host install --mode basic --dry-run
```

For the complete reference of all subcommands and flags, see
[Command-line interface](cli.md).

---

## Run inside a Docker container

To run the compiled hypervisor inside the QEMU emulator using a Docker
container, follow the containerization steps in [Build Diosix](build.md).
Then run one of the following commands:

```bash
# For the Ubuntu environment
docker run -it --rm diosix-ubuntu ./scripts/build.sh run

# For the Fedora environment
docker run -it --rm diosix-fedora ./scripts/build.sh run
```

---

## Run unit tests

To run the project's native unit tests and parser checks on your build machine:

```bash
./scripts/build.sh test
```

To run the unit tests inside a Docker container:

```bash
# For the Ubuntu environment
docker run -it --rm diosix-ubuntu ./scripts/build.sh test

# For the Fedora environment
docker run -it --rm diosix-fedora ./scripts/build.sh test
```

---

## Control the emulator console

The emulator runs in a non-graphical terminal mode by default (`run`), or in
graphical mode with `run-gui`. The hypervisor routes debug and diagnostic
logging to the serial port, which it also uses to provide interactive console
access to the Root VM and guest VMs.

To control the QEMU process, use standard escape sequences. Press `Ctrl-a`
followed by `x` to terminate the emulator. Press `Ctrl-a` followed by `c` to
enter the QEMU monitor shell to inspect registers and query hardware state.
Press `Ctrl-a` followed by `c` again to return to the hypervisor console.

---

## Remote debugging with GDB

Diosix includes an embedded GNU Debugger (GDB) Remote Serial Protocol (RSP)
stub for real-time inspection of hypervisor execution and guest VM state.

The embedded GDB RSP stub communicates over a Universal Asynchronous
Receiver-Transmitter (UART) serial interface.

### Enable debug mode

To build with debug optimizations and activate the embedded GDB RSP stub, pass
the `--debug` flag to the build wrapper (or set `-Doptimize=Debug -Dgdb=true`
when invoking `zig build`):

```bash
./scripts/build.sh run --debug
```

You can combine `--debug` with custom guest target architectures or hardware
parameters:

```bash
# Debug a 32-bit RISC-V guest VM in QEMU
./scripts/build.sh run -Dguest-arch=riscv32 --debug

# Debug with Physical Memory Protection (PMP) isolation
./scripts/build.sh run -Dpmp=true --debug
```

### Connect GDB in QEMU emulation

When running inside QEMU with `--debug`, the build wrapper automatically
redirects the emulated serial console to a local TCP socket listening on port
`1234` (`-serial tcp::1234,server,nowait`).

Connect using `gdb` targeting the host TCP socket and appropriate guest
Executable and Linkable Format (ELF) payload:

```bash
# For a 32-bit RISC-V guest VM in QEMU
gdb zig-out/guest-riscv32/bin/rootvm.elf -ex "target remote localhost:1234"

# For a 64-bit RISC-V guest VM in QEMU
gdb zig-out/guest-riscv64/bin/rootvm.elf -ex "target remote localhost:1234"
```

### Connect GDB on physical target hardware

When booting on physical hardware compiled with `-Dgdb=true`, the hypervisor's
GDB RSP stub listens directly on the physical serial port (UART). Connect `gdb`
over the host machine's serial interface (such as `/dev/ttyUSB0` or
`/dev/ttyACM0`):

```bash
# Connect to target hardware via physical serial device
gdb zig-out/guest-riscv64/bin/rootvm.elf -ex "target remote /dev/ttyUSB0"
```

### Useful GDB commands

*   **Inspect stack backtrace**: `bt`
*   **View register state**: `info registers` or `info r`
*   **Set breakpoints**: `break *0xffffffff816c860b` or `break start_kernel`
*   **Single-step instructions**: `stepi` or `nexti`
*   **Continue execution**: `continue` (or `c`)
*   **Batch execution non-interactively**:
    ```bash
    gdb -batch -ex "target remote localhost:1234" \
        -ex "bt" -ex "info registers" \
        zig-out/guest-riscv64/bin/rootvm.elf
    ```

---

## Target hardware configurations

Diosix compiles to a universal binary that runs on various physical and
emulated RISC-V hardware systems, discovering its environment dynamically at
boot using the Device Tree Blob (DTB) and registering corresponding device
drivers.

You can customize the QEMU emulation parameters directly using build options
passed to the runner:

*   To disable the Hypervisor (H) extension in QEMU and force Diosix to use
    PMP isolation instead:
    ```bash
    ./scripts/build.sh run -Dpmp=true
    ```
*   To disable `Sstc` and `Smstateen` extension features inside the hypervisor
    and the emulated QEMU CPU model:
    ```bash
    ./scripts/build.sh run -Dlegacy-cpu=true
    ```
*   To change the number of symmetric multiprocessing (SMP) CPU cores emulated
    by QEMU (default is 4):
    ```bash
    ./scripts/build.sh run -Dsmp=8
    ```
*   To change the host memory size emulated by QEMU (default is 2G):
    ```bash
    ./scripts/build.sh run -Dmem=1G
    ```

To list all available build and run-time parameter options, run:

```bash
./scripts/build.sh -h
```

---

## Run Diosix on physical hardware

To boot on physical hardware, build the hybrid live release image or flatten the
compiled M-mode hypervisor payload and load it onto physical media.

### Build the physical release artifacts

Run the live-image target to generate both the bootable disk image and the
flat M-mode firmware payloads:

```bash
./scripts/build.sh live-image
```

This command generates:

*   `zig-out/diosix-live-riscv64.img`: A 512 MiB hybrid GPT image containing
    the EFI System Partition (ESP), A/B boot slots, and persistent storage.
*   `zig-out/guest-riscv64/bin/vmdiosix.bin`: The flat M-mode hypervisor binary
    (extracted via `objcopy -O binary`) containing both the hypervisor and the
    embedded Root VM.
*   `zig-out/vmdiosix.its` (and `zig-out/u-boot.itb` when `mkimage` is
    installed): A U-Boot SPL Flattened Image Tree (FIT) descriptor that boots
    `vmdiosix.bin` as an M-mode firmware payload at `0x80000000`.

If you built a custom target (such as `guest-riscv32`) without running
`live-image`, you can also extract the flat binary manually:

```bash
llvm-objcopy -O binary \
    ./zig-out/guest-riscv64/bin/vmdiosix \
    ./zig-out/guest-riscv64/bin/vmdiosix.bin
```

### Load the hypervisor

Diosix runs in Machine mode (M-mode) and must be loaded directly by the early
bootloader (such as U-Boot SPL) or platform firmware:

1. Flash `zig-out/diosix-live-riscv64.img` to an SD card, eMMC module, or USB
   drive (`sudo dd if=zig-out/diosix-live-riscv64.img of=/dev/sdX bs=4M
   status=progress conv=fsync`), or write `vmdiosix.bin` / `u-boot.itb` to the
   board's firmware partition.
2. Configure the early M-mode bootloader (such as U-Boot SPL) to load
   `vmdiosix.bin` (or `u-boot.itb`) into RAM at `0x80000000` and jump to its
   entry point in M-mode.
3. Ensure the bootloader passes the physical address of the board's Device Tree
   Blob (DTB) in the RISC-V `a1` register (and the hart ID in `a0`).
4. Boot the system. Diosix discovers the board's CPU topologies, memory banks,
   interrupt controllers (PLIC/CLINT), and UART (NS16550/DesignWare or SiFive
   UART) from the FDT and launches the Root VM.
