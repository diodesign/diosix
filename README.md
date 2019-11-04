[![Build Status](https://travis-ci.org/diodesign/diosix.svg?branch=master)](https://travis-ci.org/diodesign/diosix) [![License: MIT](https://img.shields.io/github/license/diodesign/diosix)](https://github.com/diodesign/diosix/blob/master/LICENSE) [![Language: Rust](https://img.shields.io/badge/language-rust-yellow.svg)](https://www.rust-lang.org/)

## Table of contents

1. [Introduction](#intro)
1. [Building and running Diosix](#buildrun)
1. [Next on the todo list](#todo)
1. [Further documentation](#wiki)
1. [Development branches](#branches)
1. [Contact, security issue reporting, and code of conduct](#contact)
1. [Copyright, license, and thanks](#copyright)

### Introduction <a name="intro"></a>

Diosix 2.0 strives to be a lightweight, fast, and secure multiprocessor hypervisor for 32-bit and 64-bit [RISC-V](https://riscv.org/) systems. It is written [in Rust](https://www.rust-lang.org/), which is a C/C++-like systems programming language fiercely focused on memory and thread safety as well as performance and reliability.

The ultimate goal is to build fully open-source packages containing everything needed to configure FPGA-based systems with RISC-V cores and peripheral controllers, and boot a stack of software customized for a particular task, all generated on demand if necessary. This software should also run on supported ASICs and system-on-chips.

Right now, Diosix is a work in progress. It can bring up a RISC-V system, load a Linux kernel and minimal filesystem into a virtualized environment called a capsule, and begin executing it.  

### Building and running <a name="buildrun"></a>

To build and run Diosix, you need to follow a few steps, which are documented here:

1. [Building the toolchain](docs/toolchain.md)
1. [Using Buildroot to build a bootable Linux kernel](docs/buildroot.md)
1. [Building and using Qemu to test the hypervisor](docs/qemu.md)
1. [Building and running the hypervisor](docs/building.md)

Once you have everything in place, you can run Diosix in Qemu, or on real hardware, to start a Linux-based virtual environment. Below is debug output from the hypervisor bringing up a four-core 64-bit RISC-V system with 512MiB of RAM within the Qemu emulator, using a device tree to ascertain the hardware's configuration, loading a Linux kernel and its bundled filesystem into a virtualized environment, and executing it:

```
$ cargo run --release
   Compiling diosix v2.0.0 (/home/build/src/diosix)
    Finished release [optimized] target(s) in 2.50s
     Running `qemu-system-riscv64 -bios none -nographic -machine virt -smp 4 -m 512M -kernel target/riscv64gc-unknown-none-elf/release/hypervisor`
[-] CPU 0: Welcome to diosix 2.0.0 ... using device tree at 0x1020
[-] CPU 0: Available physical RAM: 498 MiB, physical CPU cores: 4
[-] CPU 0: Created capsule: ID 1, physical RAM base 0x80d95000, size 128 MiB
[-] CPU 0: loading ELF program area: 0x8000f7b0 size 0x1e620 into 0x80d95000
[-] CPU 0: loading ELF program area: 0x8002e7b0 size 0xa2c0bc into 0x80db4000
[-] CPU 0: Supervisor kernel entry: 0x80d96000
[-] CPU 0: Physical CPU core ready to roll, type: 64-bit RISC-V, ext: acdfimsu
[-] CPU 3: Physical CPU core ready to roll, type: 64-bit RISC-V, ext: acdfimsu
[-] CPU 2: Physical CPU core ready to roll, type: 64-bit RISC-V, ext: acdfimsu
[-] CPU 1: Physical CPU core ready to roll, type: 64-bit RISC-V, ext: acdfimsu
```

### Next on the todo list <a name="todo"></a>

As stated above, Diosix can load a Linux kernel into a virtualized environment called the boot capsule, and start executing it. However, this kernel will soon crash. This is because Diosix needs to describe to Linux the environment it was loaded into, and transparently trap and virtualize any attempts by the kernel to access hardware peripherals. Without this support, the loaded kernel will flail in the dark and crash.

Therefore, the immediate todo list is as follows:
1. Implement a device tree generator to describe to the Linux kernel its virtualized environment.
1. Virtualize hardware access attempts by the Linux kernel.
1. Once Linux is booting successfully, develop user-land and hypervisor-level code that can launch and manage further virtualized environments.

The boot capsule is expected to provide a user interface through which more capsules containing applications can be loaded from storage and executed. On embedded devices or servers, the boot capsule could start services and programs automatically. In any case, capsules are isolated from each other, preventing one from interfering with one another.

Diosix does not require a RISC-V CPU with the hypervisor ISA enabled to achieve this, though it will support that functionality as soon as it stabilizes. In the meantime, the hypervisor uses the processor cores' physical memory protection feature to enforce the separation of capsules. Eventually, Diosix will use the hypervisor ISA and fall back to physical memory protection if needed.

### Further documentation <a name="wiki"></a>

The above documentation describes the process of building and running Diosix. For more details on how it works under the hood, please consult the project's [work-in-progress wiki](https://github.com/diodesign/diosix/wiki).

### Development branches <a name="branches"></a>

The `master` branch contains the latest bleeding-edge code that people can work on and develop further; it should at least build, though it may crash. It is not for production use. Releases will be worked on in designated release branches. 

The `x86` branch holds an early port of the Rust microkernel for Intel-compatible PC systems. The `x86hypervisor` branch holds an early attempt to build hypervisor features into the `x86` branch. You're welcome to update these so they catch up with `master`, however the focus for now will be on the RISC-V port. Other branches contain work-in-progress experimental work that may not even build.

### Contact, security issue reporting, and code of conduct <a name="contact"></a>

Please [email](mailto:diosix@tuta.io) project lead Chris Williams if you have any questions or issues to raise, wish to get involved, have source to contribute, or have [found a security flaw](docs/security.md). You can, of course, submit pull requests or issues via GitHub, though please consider disclosing security-related matters privately. Please also observe the project's [code of conduct](docs/conduct.md) if you wish to participate.

### Copyright, license, and thanks <a name="copyright"></a>

Copyright &copy; Chris Williams, 2018-2019. See [LICENSE](https://github.com/diodesign/diosix/blob/master/LICENSE) for distribution and use of source code and binaries.

Many thanks to [David Craven](https://github.com/dvc94ch), [Alex Bradbury](https://github.com/asb), [Vadim Kaushan](https://github.com/Disasm), and everyone else who brought Rust, LLVM, and RISC-V together; the RISC-V world for designing the CPU cores and system-on-chips in the first place; [Michael Clark](https://github.com/michaeljclark) and everyone else who worked on [Qemu](https://github.com/riscv/riscv-qemu) and other RISC-V emulators; Philipp Oppermann for his guide to writing [kernel-level Rust code](https://os.phil-opp.com/); and to the OSdev community for its [notes and documentation](https://wiki.osdev.org/Main_Page).

Also, thanks to the Rust language developers, the LLVM and GNU teams, Microsoft for GitHub and Visual Studio Code, the developers of various crates imported by this project, the worldwide [Linux kernel](https://kernel.org/) effort, and no doubt many other folks.

Finally, if it is of interest: an [earlier iteration](https://github.com/diodesign/diosix-legacy) of Diosix exists. This is a working microkernel operating system, written in C and assembly, primarily for 32-bit SMP x86 and Arm-powered computers.
