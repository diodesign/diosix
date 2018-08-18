# diosix

This is a lightweight and secure multiprocessor microkernel operating system written in Rust for 32-bit and 64-bit RISC-V systems.

It is a work in progress: I'm starting from scratch after [previously writing](https://github.com/diodesign/diosix-legacy)
a working microkernel for 32-bit SMP x86 computers in C and assembly.

I learned a lot from that first iteration, and this is the second iteration of diosix, codenamed Menchi. Crucially,
it will be written [in Rust](https://www.rust-lang.org/), a C/C++-like programming language that has a fierce emphasis
on guaranteed memory safety, threads without data races, and other security features. I chose [RISC-V](https://riscv.org/) because it's interesting new ground to explore, whereas there are countless x86 and Arm operating system kernels out there.

Check out [the wiki for documentation](https://github.com/diodesign/diosix/wiki) on how it all works internally.

### Branches

All current development work is done in `master`. The `x86` branch holds an early port of the Rust microkernel to Intel-compatible PC systems. The `x86hypervisor` branch holds an early attempt to build hypervisor features into the `x86` branch. You're welcome to update these so they catch up with `master`, however my focus will be on the RISC-V port.

### Contact

Feel free to [email me](mailto:diodesign@gmail.com), Chris Williams, if you have any questions, want to get involved, have source to contribute, or found a security flaw. You can also find me, diodesign, on [Freenode IRC](https://freenode.net/irc_servers.shtml) in the #osdev channel, or [on Twitter](https://twitter.com/diodesign).

### Copyright, license, and thanks

&copy; Chris Williams and contributors, 2018. See LICENSE for source code and binary distribution and use.

With thanks to Philipp Oppermann for his guide to [linking Rust code](https://os.phil-opp.com/) to low-level bare-metal assembly, and to the OSdev community for its [notes and documentation](http://wiki.osdev.org/Main_Page).

