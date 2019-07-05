# Building and running diosix

Here's a gentle guide to creating a build environment for diosix, and running the kernel. If you have any updates
or feedback to add, please submit a pull request.

### Setting up your build environment

To build diosix for 64-bit and/or 32-bit RISC-V systems, make sure you've cross-compiled and installed the latest RISC-V port of
[GNU binutils](https://github.com/riscv/riscv-binutils-gdb) as the kernel requires this toolkit. You'll next need to
use [rustup](https://rustup.rs/) to install the `nightly` toolchain of Rust. The default target must be the build
host's architecture (likely x86_64) and you must install the `riscv32imac-unknown-none-elf` and `riscv64gc-unknown-none-elf`
targets, too.

If in doubt, below is a list of steps to create your 64-bit and 32-bit RISC-V Rust cross-compiler toolchain for diosix on a GNU/Linux
Debian-like system. It compiles the toolchain, first for 32-bit then for 64-bit RISC-V, within a subdirectory called `src` in your
home directory, and installs the resulting executables in a subdirectory called `cross` in your home directory.

```
sudo apt-get update
sudo apt-get install flex bison m4 sed texinfo build-essential
mkdir $HOME/cross
mkdir $HOME/src
cd $HOME/src
git clone https://github.com/riscv/riscv-binutils-gdb.git
cd riscv-binutils-gdb
./configure --prefix $HOME/cross --target=riscv32-elf
make
make install
make clean
find . -type f -name "config.cache" -exec rm {} \;
./configure --prefix $HOME/cross --target=riscv64-elf
make
make install
cd
rustup toolchain install nightly
rustup default nightly
rustup target install riscv32imac-unknown-none-elf
```

You're almost ready to build diosix. Next, to make sure your paths are always set up to find Rust and Cargo, add two lines
below to your shell's `rc` file in your home directory. For example, if you Bash, then add the lines to your `.bashrc` file:

```
source $HOME/.cargo/env
export PATH=$PATH:$HOME/cross/bin
```

Close your terminal and open a new one to load the changes.
Now you're ready to clone the source code for `diosix` to compile it. Follow these instructions...

```
cd $HOME/src
git clone https://github.com/diodesign/diosix.git
cd diosix
```

...and follow the instructions below to build and run it.

### Building and running

diosix is designed to detect the type of hardware it is running on when booted, and utilize it as needed,
whether it's emulated hardware, such as with Qemu, or on real hardware, such as a SiFive board. All you need
to do is build diosix for the correct CPU architecture. All the hardware needs to do is pass a device-tree
structure to the kernel.

To compile the operating system for a specific CPU architecture, run Rust's `cargo` with the `--target` paramter
defining the required CPU architecture, in the form:

`cargo build --release --target <CPU architecture>`

So far, diosix supports the following CPU architure targets:
* `riscv32imac-unknown-none-elf`
* `riscv64gc-unknown-none-elf`

Once built, the compiled kernel executable can be found in `target/<CPU architecture>/release/kernel` for the given
`<CPU architecture>`. So, for example,

```
cargo build --release --target riscv32imac-unknown-none-elf
qemu-system-riscv32 -machine virt -kernel target/riscv32imac-unknown-none-elf/release/kernel -nographic
```

...will build diosix for machines powered by 32-bit RISC-V CPUs (those with support for IMAC features, specifically),
and run it in the Qemu emulator. Press `Ctrl-a` then `c` to escape to the Qemu monitor, then `q` to quit. To do the same on
64-bit RISC-V, try:

```
cargo build --release --target riscv64gc-unknown-none-elf
qemu-system-riscv64 -machine virt -kernel target/riscv64gc-unknown-none-elf/release/kernel -nographic
```

To change the amount of memory allocated to diosix in Qemu, add a `-m <RAM size>` paramter to the command line, eg `-m 256M` to boot diosix
with 256MB of physical RAM. To change the number of CPU cores available, add a `-smp <N>` paramter to the command line, eg `-smp 4` to boot diosix
with 4 separate CPU cores alocated. Check out the Qemu manual for more settings.

Note that Qemu has separate qemu-system executables for 32-bit and 64-bit RISC-V emulation. If you don't have Qemu on your system,
then install it from your prefered system package manager, or build it yourself: see the instructionson its website, [qemu.org](https://www.qemu.org/).
