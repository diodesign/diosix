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