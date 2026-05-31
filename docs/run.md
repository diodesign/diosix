# Run Diosix

This page describes how to boot and run Diosix in emulation or on physical
hardware, configure custom targets, and control emulator execution.

---

## System requirements

To run Diosix, the target system, physical or emulated, must meet the following
requirements:
*   One or more 64-bit RISC-V (RV20 / RV64GC) processor cores.
*   Support for either the RISC-V hypervisor (H) extension or physical memory protection (PMP).
*   For QEMU emulated runs, version 10.1.5 or later of the QEMU emulator.

---

## Run Diosix in emulation

The simplest way to run and test Diosix is inside QEMU.
Emulation allows you to iterate on guest development and debug
platform-specific drivers without physical hardware.

To compile and run Diosix inside QEMU, use the build wrapper script:

```bash
./scripts/build.sh run
```

This command automatically builds the hypervisor for the default target system,
generates the guest Root Virtual Machine (Root VM) image, and boots QEMU.

---

## Control the emulator console

The emulator runs in a non-graphical terminal mode. The hypervisor routes debug
and diagnostic logging to the serial port, which it also uses to provide
interactive console access to guest Virtual Machines (VMs). QEMU displays this
serial interface directly in your terminal, allowing you to interact with the
guest once it boots.

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

---

## Run Diosix on physical hardware

To boot on physical hardware, compile the hypervisor for your specific target
board, flatten the executable to a raw binary, and load it onto physical
media.

### The hypervisor payload

The build process generates a freestanding Executable and Linkable Format (ELF)
payload located at `./zig-out/bin/vmdiosix`. This executable contains the
compiled hypervisor binary statically linked with the guest Root VM payload.

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
