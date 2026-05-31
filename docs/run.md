# Run Diosix

This page describes how to boot and run Diosix in emulation or on physical
hardware, configure custom targets, and control emulator execution.

---

## Run Diosix in emulation

The simplest way to run and test Diosix is inside the QEMU emulator. Emulation
allows you to iterate on guest development and debug platform-specific drivers
without physical hardware.

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
interactive console access to guest VMs. QEMU displays this serial interface
directly in your terminal, allowing you to interact with the guest once it boots.

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
using S-mode Physical Memory Protection (PMP) isolation instead of the default
virtualization extensions, run:

```bash
./scripts/build.sh run -Dsystem=qemu-virt-pmp
```

For a list of all dynamically discovered systems and available running parameters
on your host, run:

```bash
./scripts/build.sh -h
```

---

## Run Diosix on physical hardware

To boot on physical hardware, compile the hypervisor for your specific target
board and load the resulting binary payload.

### The hypervisor payload
The build process generates a freestanding executable payload located at
`./zig-out/bin/vmdiosix`. This executable contains the compiled hypervisor binary
statically linked with an embedded guest payload (the Root VM).

### Load the hypervisor
Since Diosix operates at supervisor privilege, it requires a machine-mode
bootloader or firmware provider (such as OpenSBI) to initialize the hardware and
transfer execution to the hypervisor.

To deploy on a physical target:

1.  Configure the bootloader to point to the `vmdiosix` ELF executable entry
    point.
2.  Pass the hardware Device Tree Blob (DTB) address in the `a1` register to
    enable peripheral auto-discovery.
3.  Load the combined payload onto the target system's boot media.
