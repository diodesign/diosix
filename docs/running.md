# Building and running Diosix

These instructions will walk you through building and running Diosix. They assume you are using a GNU/Linux system running [Debian Testing](https://www.debian.org/) or equivalent, and that you are comfortable using the command line to navigate your file system and run programs.

## Objectives

The outcome will involve booting one or more guest operating systems, such as Linux, on Diosix within a Qemu emulated environment. You can also just build the project to install its executable package on real hardware.

## Table of contents

1. [Getting started](#prep)
1. [Run Diosix in Qemu](#qemu)
   1. [Using the system console](#console)
1. [Run Diosix in Spike](#spike)
1. [Run Diosix on real hardware](#realhw)
1. [Build without running](#buildonly)
1. [Options for building and running](#opts)
   1. [Output build diagnostic messages](#opt_quiet)
   1. [Target a specific CPU architecture](#opt_target)
   1. [Build release-ready software](#opt_quality)
   1. [Set the number of emulated CPU cores](#opt_cpus)
   1. [Disable downloads of guest OSes](#opt_no_guest_fetch)

## Getting started <a name="prep"></a>

These steps will prepare your system for building and running Diosix using its latest source code.

1. Ensure you have the necessary dependencies installed:

   ```
   sudo apt update
   sudo apt -y install build-essential pkg-config git curl binutils-riscv64-linux-gnu qemu-system-misc libssl-dev
   ```

2. If you have not yet installed the Rust toolchain, follow [these instructions](https://www.rust-lang.org/tools/install) to do so. Make the `nightly` version of Rust the default toolchain:

   ```
   rustup default nightly
   ```

3. Install [`just`](https://github.com/casey/just), which Diosix uses to automate the steps needed to build and run the project:

   ```
   cargo install --force just
   ```

4. Fetch the Diosix source code and enter its directory:

   ```
   git clone --recurse-submodules https://github.com/diodesign/diosix.git
   cd diosix
   ```

## Run Diosix in Qemu <a name="qemu"></a>

Once you have completed the [preparatory steps](#prep), run Diosix in the Qemu RISC-V emulator:

```
just
```

This will check to see if Diosix needs to be built. If so, the project will automatically create an executable containing the hypervisor and a simple file-system containing the system services, a set of welcome text, and one or more guest OS binaries. The contents of this exccutable are specified by the project's [`manifest.toml`](../manifest.toml) configuration file.

Diosix is then booted in a Qemu RISC-V environment, and the hypervisor will start the included services and guests. To exit the emulator, press `Control-a` then `x`. The guest OSes provided by default are BusyBox-based Linux operating systems. To log in, use the username `root`. No password is required.

## Using the system console <a name="console"></a>

By default, Diosix will run a system service called `gooey` that provides a very simple user interface. This is accessed through the terminal when using Qemu, and on real hardware, through the system's first serial port.

`gooey` will show messages and information from the hypervisor in red, and assign other colors to individual guests. For example, the first guest will use yellow to output its text, blue for the second guest, and purple for the third. By default, Diosix includes one guest. To include more, edit the `manifest.toml` file to add extra guests, and run Diosix again.

Currently, `gooey` displays output text from all capsules, though when typing into it, either via Qemu or a real system's serial port, that input text is sent only to the first guest. The coloring of the input and output text can be temporarily altered by the guest, for example when listing files with `ls` and displaying executables in a special color. The exact colors seen may vary depending on the color scheme used by your terminal.

## Run Diosix in Spike <a name="spike"></a>

Once you have completed the [preparatory steps](#prep), run Diosix in the Spike RISC-V simulator:

```
just spike
```

Press `Control-c` to enter Spike's interactive debug mode. Instructions on how to use this mode are [here](https://github.com/riscv/riscv-isa-sim#interactive-debug-mode). Enter the command `q` or press `Control-c` again to quit the simulator from the debug mode. Note that support for Spike is not yet complete.

## Run Diosix on real hardware <a name="realhw"></a>

**Warning: Follow the next steps with care! The storage device specified below will be reformatted with a new GPT-based partitioning scheme, with the hypervisor and its dmfs image stored in partition 1. This will render any prior data on the device inaccessible. See [LICENSE](../LICENSE) for more information on the conditions and terms of use of this documentation**

Once you have completed the [preparatory steps](#prep), build Diosix and install it on an SD card or similar storage device for use in a physical system:

```
just disk=/dev/sdX install
```

Replace `/dev/sdX` with the path of the storage device you wish to install Diosix on. The installation process will require superuser privileges via `sudo`, and so your user account must be a `sudoer` for this just recipe to work. Once complete, the device can be used in a compatible computer. So far, this recipe supports:

* SiFive's [HiFive Unleashed](https://www.sifive.com/boards/hifive-unleashed). To run Diosix on this system:
  1. Ensure the Unleashed board's boot mode switches are all set to `1`.
  1. Insert a microSD card into the host building Diosix and run the above command, replacing `/dev/sdX` with the card's path to install the hypervisor to the card.
  1. Remove the microSD card and insert it into the Unleashed board.
  1. Connect the host to the Unleashed board's microUSB port via a suitable USB cable.
  1. Power on or reset the Unleashed board.
  1. Run the command `sudo screen /dev/ttyUSBX 115200` on the host to access the board's serial port console. You should replace `/dev/ttyUSBX` with the Unleashed's USB-to-serial interface. Typically, `X` is `1`.
  1. You should see Diosix's output in the serial port console.

Note that support for real hardware is not yet complete.

## Build without running <a name="buildonly"></a>

To build Diosix without running the software:

```
just build
```

This will create an executable package of the hypervisor, services, and guests, as described [above](#qemu), at `src/hypervisor/target/diosix`. On RISC-V targets, this executable can be loaded by a suitable bootloader as a machine-level OpenSBI implementation. It expects to be loaded at the start of RAM at physical address `0x80000000` with a pointer to a valid Device Tree describing the hardware in register `a1`. It communicates through the serial port as configured by the firmware.

Whether just building Diosix or building and running it, the build phase of the workflow will automatically use all available host CPU cores concurrently.

## Options for building and running <a name="opts"></a>

You can customize the processes of building and running Diosix by passing parameters to `just`.

The parameters are space separated and must follow `just` before any command, such as `build`, is given. For example, to just build an optimized, non-debug Diosix with output from the toolchain components enabled:

```
just quiet=no quality=release build
```

Below is a list of supported parameters.

### Output build diagnostic messages <a name="opt_quiet"></a>

By default, the output of Diosix's toolchain components, such as `mkdmfs` and `cargo`, are suppressed during the build process. To see their output during build, set the `quiet` parameter to `no`, as in:

```
just quiet=no
```

This parameter can be used with `just` and `just build`.

### Target a specific CPU architecture <a name="opt_target"></a>

By default, Diosix is built for general-purpose 64-bit RISC-V (RV64GC) processors. To build Diosix for a particular CPU architecture, use the table below to find the `target` parameter for the required supported architecture.

| Supported CPU architecture | `target` parameter value |
|----------|--------------------------------|
| RV64GC   | `riscv64gc-unknown-none-elf`   |
| RV64IMAC | `riscv64imac-unknown-none-elf` |

Then pass the `target` parameter to `just build` in the form of:

```
just target=<target parameter value>
```

For example, the RV64IMAC architecture's `target` parameter value is `riscv64imac-unknown-none-elf`. To build for that architecture, use:

```
just target=riscv64imac-unknown-none-elf
```

This parameter can be used with `just` and `just build`.

### Build release-ready software <a name="opt_quality"></a>

By default, an unoptimized debug version of Diosix is built that outputs diagnostic information to the virtual console. To build an optimized version of Diosix that does not output diagnostic messages, and may be suitable for general release, set the parameter `quality` to `release`, as in:

```
just quality=release
```

Diosix's portable code uses [macros](../src/hypervisor/src/debug.rs) to output information for the user. The table below describes which macros are active for a given build quality, and the common usage of each macro. These are the macros that should be used by other parts of the project.

| Macro | Usage | Debug | Release |
|-------|-------|-------|---------|
| `hvalert` | Critical messages from the hypervisor | Active | Active |
| `hvdebug` | Diagnostic messages from the hypervisor | Active | Inactive |
| `hvdebugraw` | `hvdebug` but without any context, such as CPU ID, nor an automatic newline | Active | Inactive |

This parameter can be used with `just` and `just build`.

### Set the number of emulated CPU cores <a name="opt_cpus"></a>

By default, Qemu runs Diosix on a four-core emulated system with 1GB of RAM. To override the number of CPU cores, set the `cpus` parameter to the number of cores required. For example, to boot Diosix on a dual-core emulated system:

```
just cpus=2
```

This parameter can be used with `just`. It has no effect with `just build`.

### Disable downloads of guest OSes <a name="opt_no_guest_fetch"></a>

By default, when Diosix's `manifest.toml` file specifies a guest OS that is not present in the build tree, it will fetch a copy of the guest from the internet so that it can be included in the final package. To prevent this from happening, set the parameter `guests-download` to `no`:

```
just guests-download=no
```

This will cause an error if a guest is required and not found in the build tree. This parameter can be used with `just` and `just build`.
