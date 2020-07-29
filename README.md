[![Build and test](https://github.com/diodesign/diosix/workflows/Build%20and%20test/badge.svg)](https://github.com/diodesign/diosix/actions?query=workflow%3A%22Build+and+test%22) [![License: MIT](https://img.shields.io/github/license/diodesign/diosix)](https://github.com/diodesign/diosix/blob/master/LICENSE) [![Language: Rust](https://img.shields.io/badge/language-rust-yellow.svg)](https://www.rust-lang.org/) ![Platform: riscv32, riscv64](https://img.shields.io/badge/platform-riscv32%20%7C%20riscv64-lightgray.svg)

## Table of contents

1. [Introduction](#intro)
1. [Quickstart](#quickstart)
1. [Next on the todo list](#todo)
1. [Development branches](#branches)
1. [Contact, security issue reporting, and code of conduct](#contact)
1. [Copyright, license, and thanks](#copyright)

### Introduction <a name="intro"></a>

Diosix 2.0 strives to be a lightweight, fast, and secure multiprocessor bare-metal hypervisor for 32-bit and 64-bit [RISC-V](https://riscv.org/) computers. It is written [in Rust](https://www.rust-lang.org/), which is a C/C++-like systems programming language focused on memory and thread safety as well as performance and reliability.

The ultimate goal is to build fully open-source packages that configure FPGA-based systems with custom RISC-V cores and peripheral controllers to run software stacks designed for particular tasks, all generated on demand if necessary. This software should also run on supported system-on-chips.

Right now, Diosix is a work in progress. It can bring up a RISC-V system, load a Linux guest OS with minimal filesystem into a virtualized environment called a capsule, and begin executing it.

### Quickstart <a name="quickstart"></a>

You can build and run Diosix within a convenient containerized environment. These instructions assume you are comfortable using Docker and the command-line interface on a Linux-like system. First, open a terminal, navigate to a suitable directory, and check out the Diosix source code:

```
git clone --recurse-submodules https://github.com/diodesign/diosix.git
cd diosix
```

Next, build a Docker image, with the tag `testenv`, that contains all the necessary toolchains, guest OS binaries, and source code to build and run Diosix:

```
docker build . --file Dockerfile --tag diosix:testenv
```

When the image is successfully built, use it to boot Diosix on the Qemu emulator within a temporary container:

```
docker run --rm diosix:testenv cargo run
```

Press `Control-C` to exit. The output should appear similar to the following, indicating Diosix running on quad-core 64-bit RISC-V machine with 512MiB of RAM:

```
Compiling diosix v2.0.0 (/build/diosix)
    Finished dev [unoptimized + debuginfo] target(s) in 41.20s
     Running `qemu-system-riscv64 -bios none -nographic -machine virt -smp 4 -m 512M -kernel target/riscv64gc-unknown-none-elf/debug/hypervisor`
[?] CPU 0: Enabling RAM region 0x80ed4000, size 497 MB
[-] CPU 0: Welcome to diosix 2.0.0
[?] CPU 0: Debugging enabled, 4 CPU cores found
[?] CPU 0: Translated supervisor virtual entry point 0xffffffe000000000 to 0x80ed4000 in physical RAM
[?] CPU 0: Loading supervisor ELF program area: 0x8004dc00 size 0x1e620 into 0x80ed4000
[?] CPU 0: Loading supervisor ELF program area: 0x8006cc00 size 0xa2c0bc into 0x80ef3000
[?] CPU 0: Physical CPU core RV64IMAFDC (Qemu/Unknown) ready to roll
[?] CPU 1: Physical CPU core RV64IMAFDC (Qemu/Unknown) ready to roll
[?] CPU 2: Physical CPU core RV64IMAFDC (Qemu/Unknown) ready to roll
[?] CPU 3: Physical CPU core RV64IMAFDC (Qemu/Unknown) ready to roll
[?] CPU 0: Running vcore 0 in capsule 1
[?] CPU 0: Granting ReadWriteExecute access to 0x80ed4000, 134217728 bytes
[!] CPU 0: Fatal exception in Supervisor: Breakpoint at 0x80ed68c8, stack 0x817f9ff0
[?] CPU 0: Tearing down capsule 0x80cdb000
```

There are other ways to invoke Diosix. For example, to start the hypervisor within an interactive environment, run:

```
docker run --rm -ti diosix:testenv cargo run
```

Press `Control-a` then `c` to enter Qemu's debugging monitor. Run the monitor command `info registers -a` to list the CPU core states. Use `quit` to end the session. Further instructions on how to use this monitor [are here](https://www.qemu.org/docs/master/system/monitor.html).

To perform the runtime unit tests, run:

```
docker run --rm diosix:testenv
```

This command should complete with the exit code 0 indicating all tests passed.

Append `--target riscv32imac-unknown-none-elf` to the above `docker` commands to run Diosix on a 32-bit RISC-V Qemu host. Append `--release` to build and run an optimized, non-debug, less-verbose version of Diosix.

To build and run Diosix from scratch, follow these steps:

1. [Building the toolchain](docs/toolchain.md)
1. [Using Buildroot to build a bootable Linux guest OS](docs/buildroot.md)
1. [Building and using Qemu to test the hypervisor](docs/qemu.md)
1. [Building and running the hypervisor](docs/building.md)

### Next on the todo list <a name="todo"></a>

As stated above, Diosix can load a Linux kernel into a virtualized environment called the boot capsule, and start executing it. However, this kernel will soon crash. This is because Diosix needs to describe to Linux the environment it was loaded into, and transparently trap and virtualize any attempts by this guest kernel to access hardware peripherals.

Therefore, the immediate todo list is as follows:
1. Implement a device tree generator to describe to the Linux kernel its virtualized environment.
1. Virtualize hardware access attempts by the Linux kernel.
1. Once Linux is booting successfully, develop user-land and hypervisor-level code that can launch and manage further virtualized environments.

The boot capsule is expected to provide a user interface through which more capsules containing applications can be loaded from storage and executed. On embedded devices or servers, the boot capsule could start services and programs automatically. In any case, capsules are isolated from each other, preventing one from interfering with one another.

Diosix does not require a RISC-V CPU with the hypervisor ISA enabled to achieve this, though it will support that functionality as soon as it stabilizes. In the meantime, the hypervisor uses the processor cores' physical memory protection feature to enforce the separation of capsules. Eventually, Diosix will use the hypervisor ISA and fall back to physical memory protection if needed.

### Development branches <a name="branches"></a>

The `master` branch contains the latest bleeding-edge code that people can work on and develop further; it should at least build, though it may crash. It is not for production use. Official releases will be worked on in designated release branches. Work-in-progress releases may be created from tagged `master` commits.

The `x86` branch holds an early port of the Diosix microkernel for Intel-compatible PC systems. The `x86hypervisor` branch holds an early attempt to build hypervisor features into the `x86` branch. You're welcome to update these so they catch up with `master`, however the focus for now will be on the RISC-V port. Other branches contain work-in-progress experimental work that may not even build.

### Contact, security issue reporting, and code of conduct <a name="contact"></a>

Please send an [email](mailto:diosix@tuta.io) if you have any questions or issues to raise, wish to get involved, have source to contribute, or have [found a security flaw](docs/security.md). You can, of course, submit pull requests or raise issues via GitHub, though please consider disclosing security-related matters privately. Please also observe the project's [code of conduct](docs/conduct.md) if you wish to participate.

### Copyright, license, and thanks <a name="copyright"></a>

Copyright &copy; Chris Williams, 2018-2020. See [LICENSE](https://github.com/diodesign/diosix/blob/master/LICENSE) for distribution and use of source code and binaries.

Many thanks to [David Craven](https://github.com/dvc94ch), [Alex Bradbury](https://github.com/asb), [Vadim Kaushan](https://github.com/Disasm), and everyone else who brought Rust, LLVM, and RISC-V together; the RISC-V world for designing the CPU cores and system-on-chips in the first place; [Michael Clark](https://github.com/michaeljclark) and everyone else who worked on [Qemu](https://github.com/riscv/riscv-qemu) and other RISC-V emulators; Philipp Oppermann for his guide to writing [kernel-level Rust code](https://os.phil-opp.com/); and to the OSdev community for its [notes and documentation](https://wiki.osdev.org/Main_Page).

Also, thanks to the Rust language developers, the LLVM and GNU teams, Microsoft for GitHub and Visual Studio Code, the developers of various crates imported by this project, the worldwide [Linux kernel](https://kernel.org/) effort, and no doubt many other folks.

Finally, if it is of interest: an [earlier iteration](https://github.com/diodesign/diosix-legacy) of Diosix exists. This is a working microkernel operating system, written in C and assembly, primarily for 32-bit SMP x86 and Arm-powered computers.
