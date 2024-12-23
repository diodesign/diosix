[![License: MIT](https://img.shields.io/github/license/diodesign/diosix)](https://github.com/diodesign/diosix/blob/main/LICENSE) [![Language: Zig](https://img.shields.io/badge/language-zig-darkorange.svg)](https://ziglang.org/) [![Platform: riscv64](https://img.shields.io/badge/platform-riscv64-lightblue.svg)](https://riscv.org/)

## Welcome guide

1. [About this project](#intro)
1. [Build Diosix](#build)
1. [Run Diosix](#run)
1. [Contact, contributions, security, and code of conduct](#contact)
1. [Copyright, distribution, and license](#copyright)

## About this project <a name="intro"></a>

Diosix strives to be a lightweight, reliable, and secure multi-core bare-metal hypervisor written [in Zig](https://ziglang.org/) for 64-bit [RISC-V](https://riscv.org/developers/) computers. It is aimed at systems that may be small, or even large, yet have a need to run multiple hardware-isolated operating systems at the same time.

This is very much a work-in-progress as it is essentially a restart of the Rust-written project this time using Zig to iterate and innovate faster while maintaining a focus on safety, security, and robustness. Diosix is designed to be simple to install and self-contained, with a provided privileged guest virtual machine for managing the host hardware and other guests. Porting to 32-bit RISC-V or non-RISC-V systems should be possible, though would be maintained as separate per-port branches rather than complicating the codebase with multiple targets in one branch.

Instructions on this page assume you are using a Linux-compatible command-line environment.

## Build Diosix <a name="build"></a>

Before building Diosix, it is recommended you have at least version 0.13.0 of the [Zig toolchain](https://ziglang.org/download/) and Git version 2.47.1 installed. Both should be available via your package manager.

To build Diosix, download the latest source from GitHub and enter its directory:

```
git clone --branch zig https://github.com/diodesign/diosix.git
cd diosix
```

Next, start the build process:

```
zig build
```

This should complete without errors, and generate the hypervisor executable file `./zig-out/bin/vmdiosix`.

By default, Diosix is built to run on the [Qemu](https://www.qemu.org/) hardware emulator. To select another system to build for, use the `-Dsystem` parameter with `zig build`. For a list of supported systems, consult `zig build -h`.

## Run Diosix <a name="run"></a>

To run Diosix on Qemu, it is recommended you have at least version 9.1.2 of Qemu installed including its 64-bit RISC-V system emulator. This should be available via your package manager.

Run Diosix on four virtual CPU cores with 2GB of RAM in Qemu, using Qemu's `virt` hardware environment:

```
qemu-system-riscv64 -nographic -machine virt -smp 4 -m 2G -bios none -kernel zig-out/bin/vmdiosix
```

The hypervisor will output to the serial port by default, which is displayed in the terminal by Qemu. Press `control-a` then `x` to exit, or `control-a` then `c` to enter the emulator's debugging console. Use the command `quit` to exit the emulator from the console.

## Contact, contributions, security issues, and code of conduct <a name="contact"></a>

Email [hello@diosix.org](mailto:hello@diosix.org) if you have any questions or issues to raise, wish to get involved, or have source to contribute. If you have found a security flaw, please follow [these steps](docs/security.md) to report the bug. You can also submit pull requests or raise issues via GitHub, though please consider disclosing security-related matters privately.

Please observe the project's [code of conduct](docs/conduct.md) when participating.

## Copyright, distribution, and license <a name="copyright"></a>

Copyright &copy; Chris Williams, 2024. See [LICENSE](LICENSE) for distribution and use of source code, binaries, and documentation.

The diosix.org [illustration](docs/logo.png) is a combination of artwork provided by [Katerina Limpitsouni](https://undraw.co/license) and [RISC-V International](https://riscv.org/about/risc-v-branding-guidelines/). The use of any trademarks by this project is for identification purposes only and does not imply endorsement or ownership of such trademarks.