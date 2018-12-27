# diosix

[![Build Status](https://travis-ci.org/diodesign/diosix.svg?branch=master)](https://travis-ci.org/diodesign/diosix) [![Gitter chat](https://badges.gitter.im/gitterHQ/gitter.png)](https://gitter.im/diosix/Lobby)

This is a lightweight, secure, and multithreaded multiprocessor hypervisor-microkernel
operating system written in Rust for 32-bit and 64-bit RISC-V systems.

It is a work in progress: I'm starting from scratch
after [previously writing](https://github.com/diodesign/diosix-legacy) a working microkernel for
32-bit SMP x86 computers in C and assembly.

I learned a lot from that foray, and so this is the second iteration of diosix. Crucially,
it will be written [in Rust](https://www.rust-lang.org/), a C/C++-like programming language that has a fierce emphasis
on guaranteed memory safety, threads without data races, and other security features.
I chose [RISC-V](https://riscv.org/) because it's interesting new ground to explore,
whereas there are countless x86 and Arm operating system kernels out there.

### Running and building

See the [build instructions](BUILDING.md) for step-by-step guides to compiling and running this project.
Here's a screenshot of the kernel booting in a 32-bit octo-core Qemu Virt hardware environment,
and writing some debug out to the virtual serial port:

[![Screenshot of SMP diosix in Qemu](https://raw.githubusercontent.com/diodesign/diosix/screenshots/docs/screenshots/diosix-early-riscv32-qemu_virt-smp.png)](https://raw.githubusercontent.com/diodesign/diosix/screenshots/docs/screenshots/diosix-early-riscv32-qemu_virt-smp.png)

The commands to build and run this code:

```
./build.sh --triple riscv32imac-unknown-none-elf --platform qemu32_virt
qemu-system-riscv32 -machine virt -kernel target/riscv32imac-unknown-none-elf/release/kernel -nographic -smp 8
```
Press `Ctrl-a` then `c` to escape to the Qemu monitor, then `q` to quit.

### Todo

There are a number of goals to hit before this can be considered a useful kernel and operating system.
Here's a non-complete todo list:

* Update wiki with relevant documentation
* Bring-up for RV32
* Bring-up for RV64
* Kernel level:
    * Physical RAM region management
    * Exception handling
    * Interrupt handling
    * CPU core scheduling
    * Supervisor environment management
* Supervisor level:
    * Physical RAM page management
    * Virtual page management
    * Exception handling
    * Interrupt handling
    * CPU core scheduling
    * ELF executable parsing and loading
    * User environment management

### Branches

All current development work is done in `master` and targets RISC-V. The `x86` branch holds an early port of the Rust microkernel for Intel-compatible PC systems. The `x86hypervisor` branch holds an early attempt to build hypervisor features into the `x86` branch. You're welcome to update these so they catch up with `master`, however my focus will be on the RISC-V port.

### Contact

Feel free to [email me](mailto:diodesign@gmail.com), Chris Williams, if you have any questions, want to get involved, have source to contribute, or found a security flaw. You can also find me, diodesign, on [Freenode IRC](https://freenode.net/irc_servers.shtml) in the #osdev channel, or [on Twitter](https://twitter.com/diodesign). Ultimately, you can submit pull requests or issues on GitHub.

### Copyright, license, and thanks

Copyright &copy; Chris Williams and contributors, 2018. See LICENSE for distribution and use of source code and binaries. A few software components have been imported, modified under license where needed to run within the diosix kernel context, and placed in the `src/contrib` directory. See the included licences for more details on usage. With thanks to:

src/contrib/hermit-dtb: Copyright &copy; 2018 Colin Finck, RWTH Aachen University.
src/contrib/lazy-static.rs: Copyright 2016 lazy-static.rs Developers. Copyright &copy; 2010 The Rust Project Developers.
src/contrib/spin-rs: Copyright &copy; 2014 Mathijs van de Nes.
src/contrib/spin-rs/src/atomic.rs: Reimplements Rust's MIT-licensed [core::sync::atomic](https://github.com/rust-lang/rust/blob/master/src/libcore/sync/atomic.rs) API. See Rust's [copyright](https://github.com/rust-lang/rust/blob/master/COPYRIGHT) documentation for more information.

And thanks to [David Craven](https://github.com/dvc94ch), [Alex Bradbury](https://github.com/asb), and everyone else who helped bring together Rust, LLVM, and RISC-V; the RISC-V world for designing the CPU cores and system-on-chips, and writing the emulators in the first place; Philipp Oppermann for his guide to writing [kernel-level Rust code](https://os.phil-opp.com/); and to the OSdev community for its [notes and documentation](http://wiki.osdev.org/Main_Page).
