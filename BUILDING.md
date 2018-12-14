# Building and running diosix

Here's a gentle guide to creating a build environment for diosix, and running the kernel. If you have any updates
or feedback to add, please submit a pull request.

### Setting up your build environment

To build diosix for a 32-bit RISC-V system, make sure you've cross-compiled and installed the latest RISC-V port of
[GNU binutils](https://github.com/riscv/riscv-binutils-gdb) as the kernel requires this toolkit. You'll next need to
use [rustup](https://rustup.rs/) to install the `stable` toolchain of Rust. The default target must be the build
host's architecture (likely x86_64) and you must install the `riscv32imac-unknown-none-elf` target, too.
(Currently, Rust only supports 32-bit RISC-V. As soon as 64-bit support appears, I'll target that as well.)

If in doubt, here's a list of steps to create your RISC-V Rust cross-compiler toolchain for diosix on a GNU/Linux
Debian-like system:

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
rustup toolchain install stable
rustup default stable
rustup target install riscv32imac-unknown-none-elf
```

Make sure your paths are set up to find Rust and Cargo – I use this in my `~/.bashrc`:

```
source $HOME/.cargo/env
export PATH=$PATH:$HOME/cross/bin
```

Then you should be ready to clone `diosix`...

```
cd $HOME/src
git clone https://github.com/diodesign/diosix.git
cd diosix
```

...and follow the instructions below to build and run it.

### Building and running

You must use the supplied `build.sh` script, which sets up Cargo to compile, assemble, and link the project.
Its syntax is:

`./build.sh --triple [build triple] --platform [target platform]`

Supported triples and platforms are listed in the `build.sh`, although we'll list them here, too,
for convenience's sake:

* Supported triples:
 * `riscv32`: 32-bit RISC-V CPUs, specifically `riscv32imac`.
* Supported platforms:
 * `sifive_u34`: 32-bit single-core SiFive U34 system-on-chip.
 * `qemu32_virt`: 32-bit multi-core Qemu Virt hardware platform. Up to eight cores allowed.

Once built, the compiled kernel executable can be found in `target/triple/release/kernel` for the given
build triple. So, for example,

```
./build.sh --triple riscv32imac-unknown-none-elf --platform sifive_u34
qemu-system-riscv32 -machine sifive_u -kernel target/riscv32imac-unknown-none-elf/release/kernel -nographic
```

...will build a kernel for a 32-bit RISC-V CPU in a SiFive Freedom U34-compatible system in the
aforementioned directory, and run it in Qemu. Press `Ctrl-a` then `c` to escape to the Qemu monitor, then `q` to quit.

To build and run diosix on Qemu's multi-processor Virt hardware environment, try:

```
./build.sh --triple riscv32imac-unknown-none-elf --platform qemu32_virt
qemu-system-riscv32 -machine virt -kernel target/riscv32imac-unknown-none-elf/release/kernel -nographic -smp 8
```

More platforms will be added over time, and 64-bit RISC-V as soon as it lands in the backend LLVM project,
and the Rust toolchain.
