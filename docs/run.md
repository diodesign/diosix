# Run Diosix

This page describes how to boot Diosix in emulation or on physical
hardware, configure custom targets, and control emulator execution.

When Diosix runs, it starts an included trusted guest virtual machine (VM)
called the Root VM. The Root VM then launches and manages additional guest
VMs. You can interact with the Root VM and guest VMs via the serial console
to run programs, and configure and monitor the system.

---

## System requirements

The target system must meet the following hardware requirements:

* One or more 64-bit RVA20 RV64GC RISC-V processor cores.
* Support for either the RISC-V Hypervisor (H) extension or Physical Memory
  Protection (PMP).
* For QEMU-emulated runs, we recommend version 10.1.5 or later of the QEMU emulator.
  Earlier versions, such as 6.2, should suffice.

---

## Run Diosix in emulation

The simplest way to run and test Diosix is inside the QEMU emulator. Emulation
lets you iterate on hypervisor and guest development and debug platform-specific
drivers without needing physical target hardware.

### Prerequisites

Before you can run Diosix using the wrapper script in this section, you must follow the steps in [Build Diosix](build.md) to install the required dependencies and fetch the project source code. Then, you can use the wrapper script to build and run the hypervisor and the Root VM.

### Install QEMU

If you haven't already installed a 64-bit RISC-V QEMU emulator on
your build machine, you must do so before running Diosix in emulation.

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

To run Diosix inside QEMU, run the build wrapper script as follows:

```bash
./scripts/build.sh run
```

This command automatically builds the platform-agnostic, universal hypervisor binary and boots it in a standard RISC-V 64-bit QEMU virt machine environment.

The build script also generates the native Root VM image, and boots the hypervisor and
the Root VM in QEMU for you to interact with and use. By default, the Root VM
is a Linux-powered guest. You can log in using the username `root` with no
password.

Rebooting the Root VM reboots the hypervisor.

### Run with live storage media

To boot Diosix in QEMU with the full GUID Partition Table (GPT) live storage image attached as primary virtio-blk block storage:

```bash
./scripts/build.sh run-live
```

In this mode, the Root VM automatically detects and mounts the persistent guest storage partition at `/var/lib/diosix`. The storage partition provides:
*   Pre-seeded base guest OS images at `/var/lib/diosix/images/` (such as `linux-guest.elf`).
*   System domain manifests at `/var/lib/diosix/manifests/` (such as `system.toml`).
*   Persistent disk space for stateful guest virtual machines.

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

The emulator runs in a non-graphical terminal mode. The hypervisor routes debug
and diagnostic logging to the serial port, which it also uses to provide
interactive console access to Root and guest VMs. QEMU displays this serial
interface directly in your terminal, allowing you to interact with VMs once they
boot.

To control the QEMU process, use standard escape sequences. Press `Ctrl-a`
followed by `x` to terminate the emulator. Press `Ctrl-a` followed by `c` to
enter the QEMU monitor shell to inspect registers and query hardware state.
Press `Ctrl-a` followed by `c` again to return to the hypervisor console.

---

## Remote debugging with GDB

Diosix includes an embedded GNU Debugger (GDB) Remote Serial Protocol (RSP)
stub for real-time inspection of hypervisor execution and guest Virtual Machine
(VM) state.

The embedded GDB RSP stub communicates over a UART serial interface.

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
# Debug an x86_64 guest VM in QEMU
./scripts/build.sh run -Dguest-arch=x86_64 --debug

# Debug with Physical Memory Protection (PMP) isolation
./scripts/build.sh run -Dpmp=true --debug
```

### Connect GDB in QEMU emulation

When running inside QEMU with `--debug`, the build wrapper automatically
redirects the emulated serial console to a local TCP socket listening on port
`1234` (`-serial tcp::1234,server,nowait`).

Connect using `gdb` targeting the host TCP socket and appropriate guest ELF payload:

```bash
# For an x86_64 guest VM in QEMU
gdb zig-out/guest-x86_64/bin/rootvm.elf -ex "target remote localhost:1234"

# For a 64-bit RISC-V guest VM in QEMU
gdb zig-out/guest-riscv64/bin/rootvm.elf -ex "target remote localhost:1234"
```

### Connect GDB on physical target hardware

When booting on physical hardware compiled with `-Dgdb=true`, the hypervisor's
GDB RSP stub listens directly on the physical serial port (UART). Connect `gdb`
over the host machine's serial interface (such as `/dev/ttyUSB0` or `/dev/ttyACM0`):

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
    gdb -batch -ex "target remote localhost:1234" -ex "bt" -ex "info registers" zig-out/guest-x86_64/bin/rootvm.elf
    ```

---

## Target hardware configurations

Diosix compiles to a universal binary that runs on various physical and emulated RISC-V hardware systems, discovering its environment dynamically at boot using the Device Tree Blob (DTB) and registering corresponding device drivers.

You can customize the QEMU emulation parameters directly using build options passed to the runner:

*   To disable the Hypervisor (H) extension in QEMU and force Diosix to use Physical Memory Protection (PMP) isolation instead:
    ```bash
    ./scripts/build.sh run -Dpmp=true
    ```
*   To disable Sstc and Smstateen extension features inside the hypervisor and the emulated QEMU CPU model:
    ```bash
    ./scripts/build.sh run -Dlegacy-cpu=true
    ```
*   To change the number of SMP CPU cores emulated by QEMU (default is 4):
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

To boot on physical hardware, compile the hypervisor for the target board,
flatten the executable to a raw binary, and load it onto physical media.

### The hypervisor payload

The build process generates a freestanding Executable and Linkable Format (ELF)
payload at an output directory based on the guest Root VM architecture (for example,
`./zig-out/guest-riscv64/bin/vmdiosix`, `./zig-out/guest-riscv32/bin/vmdiosix`, or `./zig-out/guest-aarch64/bin/vmdiosix`).
The payload contains both the hypervisor and the guest Root VM.

### Flatten the payload

Most physical bootloaders expect a flat binary instead of an ELF file. Convert the ELF payload to a flat binary using `llvm-objcopy` (included with Zig) or `riscv64-unknown-elf-objcopy`, replacing `guest-riscv64` with the architecture of your Root VM:

```bash
llvm-objcopy -O binary ./zig-out/guest-riscv64/bin/vmdiosix ./zig-out/guest-riscv64/bin/vmdiosix.bin
```

### Load the hypervisor

Diosix runs in Machine-mode (M-mode) and must be loaded by the early bootloader
or firmware:

1. Write `vmdiosix.bin` directly to the physical boot media (such as an SD card
   partition or Flash ROM).
2. Configure the M-mode bootloader to load the binary into RAM (typically
   starting at `0x80000000`) and jump to its entry point.
3. Ensure the bootloader passes the physical address of the Device Tree Blob
   (DTB) in the RISC-V `a1` register.
4. Boot the system. Diosix will start and communicate via the serial port.