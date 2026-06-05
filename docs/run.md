# Run Diosix

This page describes how to boot and run Diosix in emulation or on physical
hardware, configure custom targets, and control emulator execution.

When Diosix runs, it boots a trusted guest virtual machine (VM) called the Root VM,
which launches and manages additional guest VMs. You can interact with the Root VM
and guest VMs via the serial console to run programs, and configure and monitor
the system.

---

## System requirements

To run Diosix, you must first compile the hypervisor and its Root VM. While you can build and run the system in a single step using the wrapper script commands described in this document, your build host machine must still meet all the compilation prerequisites. For details on build toolchains, host packages, and Docker container configurations, see [Build Diosix](build.md).

### Target system requirements

To execute the compiled hypervisor, the physical or emulated target system must meet the following hardware requirements:

* One or more 64-bit RV20 RV64GC RISC-V processor cores.
* Support for either the RISC-V hypervisor (H) extension or physical memory protection (PMP).
* For QEMU-emulated runs, version 10.1.5 or later of the QEMU emulator.

---

## Run Diosix in emulation

The simplest way to run and test Diosix is inside the QEMU emulator.
Emulation lets you iterate on hypervisor and guest development and debug
platform-specific drivers without needing physical target hardware.

### Install QEMU

Before running Diosix on emulation, ensure you have a QEMU RISC-V 64-bit emulator installed.

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

To compile Diosix and run it inside QEMU, run the build wrapper script as follows:

```bash
./scripts/build.sh run
```

This command automatically builds the hypervisor for the default target system, 
`qemu-virt`, which is defined in `hypervisor/hw/ports/default.yaml`. This target
is an emulated RISC-V 64-bit machine configured with 4 CPU cores and 2 GB of RAM.

The build script also generates the Root VM image and boots the hypervisor and the Root VM in QEMU for you to interact with and use. By default, the Root VM is a Linux-powered guest. You can login using the username `root` with no password.

Rebooting the Root VM reboots the hypervisor.

### Run inside a Docker container

If you are using containerized builds with Docker, you can run the compiled hypervisor inside the QEMU emulator by executing the build wrapper command through the container:

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

If you are using containerized builds with Docker, you can run the unit tests inside the container environment:

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
interactive console access to Root and guest VMs. QEMU displays this
serial interface directly in your terminal, allowing you to interact with VMs
once they boot.

To control the QEMU process, use the standard emulator escape sequences. Press
`Ctrl-a` followed by `x` to terminate the emulator. Press `Ctrl-a` followed by
`c` to enter the QEMU monitor shell, which lets you inspect registers and query
hardware state; press `Ctrl-a` followed by `c` again to return to the hypervisor
console.

---

## Customize running options

Available hardware targets are defined in YAML configuration files located in
`hypervisor/hw/ports/`. You can compile and run for a specific target by
passing the `-Dsystem` parameter. For example, to target a simulated system
using RISC-V's PMP isolation instead of the H extension, run:

```bash
./scripts/build.sh run -Dsystem=qemu-virt-pmp
```

For a list of all dynamically discovered target systems and available options,
pass the `-h` (or `--help`) parameter to the build wrapper script:

```bash
./scripts/build.sh -h
```

### Customizing QEMU CPU features and versions

To successfully run Diosix, the QEMU emulator must be launched with CPU flags that enable the necessary RISC-V extensions, such as the Hypervisor extension. Different QEMU versions expect different CPU properties, so you may need to override the default CPU flags:

*  **QEMU 10.x or newer (e.g., Fedora 44)**: Natively supports standard extensions, allowing you to run using the default target configuration:

   ```bash
   ./scripts/build.sh run
   ```

*  **QEMU 6.2.0 (e.g., Ubuntu 22.04 LTS)**: Requires experimental prefixes, such as `x-h=true` and `x-v=true`. Override the default CPU arguments by passing the `-Dqemu-cpu` flag:

   ```bash
   ./scripts/build.sh run -Dqemu-cpu="rv64,x-h=true,x-v=true"
   ```

The `-Dqemu-cpu` flag overrides the default `-cpu` parameters defined in the selected target hardware port configuration YAML file (for example, `hypervisor/hw/ports/qemu-virt.yaml`). This runtime flag only affects how QEMU is launched and has no impact on the compilation of the hypervisor binary.

#### Use the environment variable

Alternatively, you can set the `DIOSIX_QEMU_CPU` environment variable. The build wrapper automatically detects and forwards this variable as `-Dqemu-cpu`.

This is pre-configured in `dockerfiles/ubuntu-22.04.Dockerfile` to ensure that the containerized emulator launches with the correct experimental prefixes required by QEMU 6.2.0:

```dockerfile
# Configured in the Ubuntu 22.04 container environment
ENV DIOSIX_QEMU_CPU="rv64,x-h=true,x-v=true"
```

---

## Run Diosix on physical hardware

To boot on physical hardware, compile the hypervisor for your specific target
board, flatten the executable to a raw binary, and load it onto physical
media.

### The hypervisor payload

The build process generates a freestanding ELF payload located at
`./zig-out/bin/vmdiosix`. This executable contains the compiled hypervisor binary
statically linked with the guest Root VM payload.

### Flatten the payload

Physical bootloaders and firmware operating in Machine-mode (M-mode) typically
expect a raw, flat binary rather than an ELF file. You must convert the ELF
payload into a flat binary before deploying it.

To flatten the payload, use an `objcopy` utility suitable for your target
architecture, such as `llvm-objcopy` (which is included with the Zig toolchain)
or `riscv64-unknown-elf-objcopy`:

```bash
llvm-objcopy -O binary ./zig-out/bin/vmdiosix ./zig-out/bin/vmdiosix.bin
```

This generates `vmdiosix.bin`, a flattened raw binary.

### Load the hypervisor

Diosix operates at the M-mode level and must be executed directly by the target
system's early bootloader or firmware.

To deploy and boot on a physical target:

1.  Write the flattened raw binary (`vmdiosix.bin`) directly to your physical
    boot media. For example, copy it to a designated boot partition on an SD
    card, or write it directly into your target system's Flash ROM.
2.  Configure the target system's M-mode bootloader or firmware to load the binary
    payload directly into physical memory (typically starting at physical RAM
    address `0x80000000`) and jump to its entry point.
3.  Ensure the bootloader passes the physical address of a valid hardware
    Device Tree Blob (DTB) in the RISC-V `a1` register to enable peripheral
    auto-discovery.
4.  Power-on the physical hardware, and the bootloader should load and start
    Diosix. The hypervisor will communicate with you via the serial port.