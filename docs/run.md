# Run Diosix

Diosix compiles for a variety of target systems, ranging from software-emulated
environments to real physical silicon. This page describes how to run the
hypervisor, customize running parameters, and control the execution.

---

## Run Diosix in emulation

The easiest way to boot, run, and test the Diosix hypervisor is inside a
software emulator using Quick Emulator (QEMU). Emulation allows you to quickly
iterate on guest development and debug low-level hardware drivers.

To run Diosix inside QEMU, execute the build wrapper script with the `run`
action:

```bash
./scripts/build.sh run
```

This command automatically builds the hypervisor for the default target board,
generates a guest Root Virtual Machine (Root VM) operating system image, starts
the QEMU emulator, and boots the entire platform.

---

## Control the emulator console

By default, the emulator runs in a non-graphical terminal mode. The hypervisor
routes early-boot logging and diagnostic messages directly to the emulated
serial console, which is redirected to your standard terminal output.

To interact with the running guest operating system, you can type directly into
your terminal window once the system boots.

To control the QEMU emulator container, use the standard escape sequences:
*  **Quit the emulator:** Press `Ctrl-a` followed by `x` to instantly terminate
   and shut down the QEMU process.
*  **Switch to QEMU monitor:** Press `Ctrl-a` followed by `c` to drop into the
   QEMU monitor shell. This shell lets you inspect registers, query device state,
   and control emulation parameters. Press `Ctrl-a` followed by `c` again to
   return to the hypervisor output.

---

## Customize running options

Diosix uses target configuration files to describe different hardware environments
and emulator flags. Available systems are defined using YAML-formatted target
files located in `hypervisor/hw/ports/`.

You can instruct the build script to compile and run for a specific target port
by passing the `-Dsystem` parameter. For example, to run the hypervisor on a
simulated core using S-mode Physical Memory Protection (PMP) isolation instead of
hardware nested virtualization, specify:

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

To boot Diosix on real physical hardware, you must compile the hypervisor for
your specific target board and load the resulting executable payload.

### The hypervisor payload
The build process generates a freestanding executable payload located at
`./zig-out/bin/vmdiosix`. This executable contains the compiled hypervisor binary
statically linked with an embedded guest payload (the Root VM).

### Load the hypervisor
Since Diosix operates at supervisor privilege under RISC-V assembly boot, it requires
a machine-mode bootloader or firmware provider (such as OpenSBI) to perform early
hardware initialization, set up physical trap handling, and transition execution to
the hypervisor entry point. 

To deploy on a physical target:
1.  Configure your bootloader or machine-mode firmware payload to point to the
    `vmdiosix` ELF executable entry point.
2.  Provide the physical hardware Device Tree Blob (DTB) address in the `a1`
    register upon entry, allowing the hypervisor to dynamically discover all
    on-board peripheral registers.
3.  Flash or load the combined payload onto your target system's boot media.
