# Run Diosix

This page describes how to boot and run Diosix in emulation or on physical
hardware, configure custom targets, and control emulator execution.

When Diosix runs, it boots a trusted guest Virtual Machine (VM) called the
Root VM, which launches and manages additional guest VMs. You can interact
with the Root VM and guest VMs via the serial console to run programs, and
configure and monitor the system.

---

## System requirements

To run Diosix, you must first compile the hypervisor and its Root VM. While you
can build and run the system in a single step using the wrapper script commands
described in this document, your build host machine must still meet all the
compilation prerequisites. For details on build toolchains, host packages, and
Docker container configurations, see [Build Diosix](build.md).

### Target system requirements

To execute the compiled hypervisor, the physical or emulated target system must
meet the following hardware requirements:

* One or more 64-bit RVA20 RV64GC RISC-V processor cores.
* Support for either the RISC-V Hypervisor (H) extension or Physical Memory
  Protection (PMP).
* For QEMU-emulated runs, version 10.1.5 or later of the QEMU emulator.

---

## Run Diosix in emulation

The simplest way to run and test Diosix is inside the QEMU emulator. Emulation
lets you iterate on hypervisor and guest development and debug platform-specific
drivers without needing physical target hardware.

### Install QEMU

Before running Diosix in emulation, install a 64-bit RISC-V QEMU emulator on
your host system.

On Debian or Ubuntu systems, run:

```bash
sudo apt update
sudo apt install -y qemu-system-misc
```

On Fedora systems, run:

```bash
sudo dnf install -y qemu-system-riscv
```

### Run Diosix using the build wrapper

To compile Diosix and run it inside QEMU, run the build wrapper script as
follows:

```bash
./scripts/build.sh run
```

This command automatically builds the hypervisor for the default target system,
`qemu-virt`, which is selected in `hypervisor/hw/ports/default.yaml`. This target
is an emulated RISC-V 64-bit machine configured with 4 CPU cores and 2 GB of
RAM.

The build script also generates the Root VM image and boots the hypervisor and
the Root VM in QEMU for you to interact with and use. By default, the Root VM
is a Linux-powered guest. You can log in using the username `root` with no
password.

Rebooting the Root VM reboots the hypervisor.

### Run inside a Docker container

To run the compiled hypervisor inside the QEMU emulator using a Docker
container:

```bash
# For the Ubuntu environment
docker run -it --rm diosix-ubuntu ./scripts/build.sh run

# For the Fedora environment
docker run -it --rm diosix-fedora ./scripts/build.sh run
```

### Run unit tests

To run the project's native unit tests and parser checks on your host system:

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

Diosix supports running on various physical and emulated RISC-V hardware systems.

Target hardware platforms are defined by YAML configuration files in
`hypervisor/hw/ports/`. Select a target platform by passing the `-Dsystem`
parameter to the build script.

For example, to run using PMP isolation instead of the Hypervisor (H)
extension, target `qemu-virt-pmp`:

```bash
./scripts/build.sh run -Dsystem=qemu-virt-pmp
```

To list all discovered target systems, as well as other build and run-time options:

```bash
./scripts/build.sh -h
```

---

## Run Diosix on physical hardware

To boot on physical hardware, compile the hypervisor for the target board,
flatten the executable to a raw binary, and load it onto physical media.

### The hypervisor payload

The build process generates a freestanding Executable and Linkable Format (ELF)
payload at `./zig-out/bin/vmdiosix`, containing the hypervisor and guest
Root VM.

### Flatten the payload

Most physical bootloaders expect a flat binary instead of an ELF file. Convert
the ELF payload to a flat binary using `llvm-objcopy` (included with Zig) or
`riscv64-unknown-elf-objcopy`:

```bash
llvm-objcopy -O binary ./zig-out/bin/vmdiosix ./zig-out/bin/vmdiosix.bin
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