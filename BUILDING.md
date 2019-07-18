# Building and running diosix

Here's a gentle guide to creating a build environment for diosix, and running the hypervisor. If you have any updates
or feedback to add, please submit a pull request.

### Setting up your build environment

To build diosix for 64-bit and/or 32-bit RISC-V systems, make sure you've cross-compiled and installed the latest RISC-V port of
[GNU binutils](https://github.com/riscv/riscv-binutils-gdb) as the hypervisor requires this toolkit. You'll next need to
use [rustup](https://rustup.rs/) to install the `nightly` toolchain of Rust. The default target must be the build
host's architecture (likely x86_64), and you must install at least one of the following RISC-V targets:
`riscv32imac-unknown-none-elf`, `riscv64imac-unknown-none-elf`, and/or `riscv64gc-unknown-none-elf`.

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
rustup target install riscv64imac-unknown-none-elf
rustup target install riscv64gc-unknown-none-elf
```

You're almost ready to build diosix. Next, to make sure your paths are always set up to find Rust and Cargo, add two lines
below to your shell's `rc` file in your home directory. For example, if you Bash, then add the lines to your `.bashrc` file:

```
source $HOME/.cargo/env
export PATH=$PATH:$HOME/cross/bin
```

Close your terminal, and open a new one, to load the changes.

### Setting up your runtime environment

If you plan to run diosix on physical hardware then you can skip this part, and instead build diosix as needed,
copy it to the hardware platform of your choice, and run it there. If you want to test and develop diosix in
[Qemu](https://www.qemu.org/), an emulator that is handy for debggging, then read on.

You can install Qemu from your prefered system package manager, although you may have to build it yourself
to include 32-bit and 64-bit RISC-V support. To do so, in a quick and easy way, clone the Qemu source code,
configure it to support RISC-V system emulation, build it, and add the resulting binaries to your path.
First, in your terminal, `cd` to a directory in which you'd like to build Qemu, such as `~/src/` then follow these instructions:

```
sudo apt-get install git libglib2.0-dev libfdt-dev libpixman-1-dev zlib1g-dev
git clone git://git.qemu-project.org/qemu.git
cd qemu
./configure --target-list=riscv32-softmmu,riscv64-softmmu
make
```

Then make sure the resulting Qemu binaries, `$HOME/src/qemu/riscv32-softmmu/qemu-system-riscv32`
and `$HOME/src/qemu/riscv64-softmmu/qemu-system-riscv64` are in your `$PATH`. For example, you could add the
following paths to your shell's `rc` file:

```
export PATH=$PATH:$HOME/src/qemu/riscv32-softmmu
export PATH=$PATH:$HOME/src/qemu/riscv64-softmmu
```

Exit the terminal, and reopen it, to pick up the changes. Now you're all set with a build and runtime environment.

### Building and running diosix

diosix is designed to detect the type of hardware it is running on when booted, and utilize it as needed,
whether it's emulated hardware, such as with Qemu, or on real hardware, such as a SiFive board. All you need
to do is build diosix for the correct CPU architecture. All the hardware needs to do is pass a device-tree
structure to the hypervisor so it can discover attached peripherals, controllers, and memory.

To get started, clone the `diosix` source into an appropriate place, such as `~/src` and enter the code. Here's one way of doing that:

```
cd $HOME/src
git clone https://github.com/diodesign/diosix.git
cd diosix
```

The default CPU architecture is `riscv64gc-unknown-none-elf`: this is chosen if you do not specify a CPU target.
To compile for a specific CPU architecture, run Rust's `cargo` with the `--target` paramter defining the required CPU architecture, in the form:

`cargo build --release --target <CPU architecture>`

So far, diosix supports the following CPU architure targets:
* `riscv32imac-unknown-none-elf`
* `riscv64imac-unknown-none-elf`
* `riscv64gc-unknown-none-elf`

Once built, the compiled hypervisor executable can be found in `target/<CPU architecture>/release/hypervisor` for the given
`<CPU architecture>`. If `qemu-system-riscv32` and `qemu-system-riscv32` are in your run path, you can build and
run diosix with one command. To build or rebuild diosix for 32-bit RISC-V targets and run it in Qemu, use the following:

```
cargo run --release --target riscv32imac-unknown-none-elf
```

Specifically, this targets 32-bit RISC-V CPUs that support IMAC features, specifically. Press `Ctrl-a` then `c`
to escape to the Qemu monitor, then `q` to quit. To do the same for 64-bit RISC-V, try:

```
cargo run --release --target riscv64gc-unknown-none-elf
```

The commands used to invoke Qemu are in `.cargo/config` in the diosix root folder, if you wish to run it by hand.
To change the amount of memory allocated to diosix in Qemu, add a `-m <RAM size>` paramter to the command line, eg `-m 256M` to boot diosix
with 256MB of physical RAM. To change the number of CPU cores available, add a `-smp <N>` paramter to the command line, eg `-smp 8` to boot diosix
with 8 separate CPU cores alocated. Check out the Qemu manual for more settings.

### Testing diosix

To perform the built-in unit tests, replace `run` for `test` in the above `cargo run` commands, eg:

```
cargo test --release --target riscv32imac-unknown-none-elf
cargo test --release --target riscv64gc-unknown-none-elf
```

These will complete with an exit code of 0 for success, or a failure code if a test failed. Unit testing is in its early stages. Feel free to help expand the test cases!
