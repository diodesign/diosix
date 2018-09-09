# diosix

This is a lightweight and secure multiprocessor microkernel operating system written in Rust for 32-bit and 64-bit RISC-V systems.

It is a work in progress: I'm starting from scratch after [previously writing](https://github.com/diodesign/diosix-legacy)
a working microkernel for 32-bit SMP x86 computers in C and assembly.

I learned a lot from that first iteration, and this is the second iteration of diosix. Crucially,
it will be written [in Rust](https://www.rust-lang.org/), a C/C++-like programming language that has a fierce emphasis
on guaranteed memory safety, threads without data races, and other security features. I chose [RISC-V](https://riscv.org/) because it's interesting new ground to explore, whereas there are countless x86 and Arm operating system kernels out there.

### Building and running

You must use the supplied `build.sh` script, which sets up Cargo to compile, assemble, and link the project. Its syntax is:

`build.sh --triple [build triple] --platform [target platform]`

Supported triples and platforms are listed in the file. The kernel executable can be found in `target/triple/release/kernel` for the given build triple. For example,

`build.sh --triple riscv32imac-unknown-none-elf --platform sifive_e`

...will build for a 32-bit RISC-V CPU on a SiFive E-series system. Then you can try running it using Qemu:

`qemu-system-riscv32 -machine sifive_e -kernel target/riscv32imac-unknown-none-elf/release/kernel -nographic`

### Branches

All current development work is done in `master` and targets RISC-V. The `x86` branch holds an early port of the Rust microkernel for Intel-compatible PC systems. The `x86hypervisor` branch holds an early attempt to build hypervisor features into the `x86` branch. You're welcome to update these so they catch up with `master`, however my focus will be on the RISC-V port.

### Contact

Feel free to [email me](mailto:diodesign@gmail.com), Chris Williams, if you have any questions, want to get involved, have source to contribute, or found a security flaw. You can also find me, diodesign, on [Freenode IRC](https://freenode.net/irc_servers.shtml) in the #osdev channel, or [on Twitter](https://twitter.com/diodesign).

### Copyright, license, and thanks

&copy; Chris Williams and contributors, 2018. See LICENSE for source code and binary distribution and use.

With thanks to Philipp Oppermann for his guide to writing [kernel-level Rust code](https://os.phil-opp.com/), [David Craven](https://github.com/dvc94ch) and everyone else who helped port Rust to RISC-V, and to the OSdev community for its [notes and documentation](http://wiki.osdev.org/Main_Page).
