## Building the Diosix toolchain

Diosix, for now, targets RISC-V systems. Therefore, to compile this project, you will need to install a set of tools and compilers that can generate software for this CPU architecture. This process involves building and installing the GNU Binutils suite for RISC-V, and installing the Rust toolchain.

These instructions assume you are building Diosix on a [Debian](https://www.debian.org/)-like GNU/Linux operating system. If you are using another Linux distribution, please adjust the `apt` package installation commands to suit your operating system's package manager. This guide assumes you know your way around a Linux or Unix-like system, are comfortable using your system's command-line interface, and are using an interactive terminal session.

These instructions also assume you are cross-compiling Diosix on a non-RISC-V machine, such as on an Intel or AMD x86 computer. You can still follow these instructions on a RISC-V machine if you wish, though you may be able to install a prebuilt Binutils package via your operating system's package manager, and skip ahead to [installing Rust](#rust). If you do install a prebuilt RISC-V Binutils package, rather than build it from source, see the [caveats](#prebuilt) at the end of this document.

If in doubt, just follow the instructions below: they will ensure you build a toolchain that supports 32-bit and 64-bit RISC-V processors using the latest source code, and is prepared correctly to build Diosix.

## Table of contents

1. [Building GNU binutils for RISC-V](#binutils)
1. [Installing Rust](#rust)
1. [Using a prebuilt GNU binutils package](#prebuilt)

### Building GNU binutils for RISC-V <a name="binutils"></a>

GNU Binutils provides the necessary tools for linking and inspecting Diosix and its software components. First, ensure you have installed all the dependencies required for building Binutils. To do this, open a terminal and run the following:

```
sudo apt update
sudo apt -y install flex bison m4 sed texinfo build-essential git curl
```

Next, create directories in which to build and install Binutils. These instructions will use two parent directories in your home directory: `src` to compile Binutils, and `cross` in which to install the tools. To ensure these directories exist, run:

```
mkdir -p $HOME/src
mkdir -p $HOME/cross
```

Step into `src`, use Git to checkout the RISC-V port of Binutils, and step into the source code directory:

```
cd $HOME/src
git clone https://github.com/riscv/riscv-binutils-gdb.git
cd riscv-binutils-gdb
```

Next, configure Binutils to produce a set of tools for 32-bit RISC-V processors, and then build and install those tools in the aforementioned `cross` directory:

```
./configure --prefix $HOME/cross --target=riscv32-elf
make
make install
```

Now, onto 64-bit RISC-V processors. First, clean Binutils to remove all the previous intermediate files used to build the 32-bit RISC-V tools. These steps will not remove the executable files installed in `cross`:

```
make clean
find . -type f -name "config.cache" -exec rm {} \;
```

And configure Binutils to produce a set of tools for 64-bit RISC-V processors, and then build and install those tools in the `cross` directory:

```
./configure --prefix $HOME/cross --target=riscv64-elf
make
make install
```

Finally, for this stage, you need to update your `PATH` environment variable so that the newly installed RISC-V Binutils executable files can be found and used by Diosix. These executable files were installed into `cross/bin/` during the above steps. To temporarily update your `PATH` variable so that you can continue with building Diosix, use:

```
export PATH=$PATH:$HOME/cross/bin
```

This change to `PATH` will remain in effect until you close your terminal shell session. To ensure the Binutils executable files can be located and used in future shell sessions, you need to update your shell's configuration so that it automatically defines `PATH` as described above when you open a new session. There are a number of ways to do this; to keep it simple, these instructions will update your shell's `rc` file. If you wish to delve into this further, [this blogpost](https://shreevatsa.wordpress.com/2008/03/30/zshbash-startup-files-loading-order-bashrc-zshrc-etc/) explains which specific configuration files to update and why.

As stated above, this toolchain-building guide will keep it simple. If you use Bash, you should update `.bashrc`, and if you use Zsh, you should update `.zshrc`. Both files are located in your home directory. If you use another shell, check its manual for the location of its configuration file. Open `.bashrc`, `.zshrc`, or whichever configuration file is appropriate for you, in a text editor, and insert the following line at the end of the file:

```
export PATH=$PATH:$HOME/cross/bin
```

Save and close the file in your editor. Then close your terminal session using `exit`, and reopen a fresh one. To check everything is installed correctly, the following command should display some information about the readelf command rather than an error message that the file could not be found:

```
riscv32-elf-readelf --version
```

Now, onto installing Rust with support for RISC-V.

### Installing Rust <a name="rust"></a>

Start off in your home directory, and install Rust as per its documentation:

```
cd $HOME
curl https://sh.rustup.rs -sSf | sh
```

This fetches and runs Rust's installer. Press `2` and hit `enter` to customize the installation. Press `enter` to skip changing the default host triple. At the next question, type `nightly` and hit `enter` to select the overnight builds of Rust. This is needed to use features required by Diosix that are not yet available from the toolchain's `stable` release channel. Hit `enter` again to use the default setting for the `PATH` variable.

Press `1` and hit `enter` to begin the installation. The Rust toolchain stores its files and executables in the `.rustup` and `.cargo` directories in your home directory. Once this process is complete, install the tools that target the 32-bit and 64-bit RISC-V CPU architectures supported by Diosix:

```
rustup target install riscv32imac-unknown-none-elf
rustup target install riscv64imac-unknown-none-elf
rustup target install riscv64gc-unknown-none-elf
```

You should now be set. To make sure the Rust toolchain was installed correctly, exit your terminal session, open a fresh one, and try invoking the compiler:

```
rustc --version
```

This should display the version information for your Rust toolchain. If you get a file-not-found error, you need to add the toolchain to your `PATH` variable. Open your shell's configuration file, such as `.bashrc`, `.zshrc`, or similar as explained above, in a text editor, and insert the following line to the end of the file:

```
export PATH=$HOME/.cargo/bin:$PATH
```

Save and close the file in your editor, then close your terminal session, open a new one, and verify the above `rustc` command runs without any error.

Finally, you should keep Rust updated with the following command:

```
rustup update
```

Run this once a week, or at least before pulling the latest Diosix source code via Git and building the project to ensure you have all the features needed to generate a working build of the hypervisor.

### Using a prebuilt GNU binutils package <a name="prebuilt"></a>

If you install a prebuilt RISC-V-capable Binutils package on your RISC-V system, bear in mind the package may only support 32 or 64-bit RISC-V, depending on your machine's CPU architecture. If so, you will not be able to output a build of Diosix for the unsupported architecture. If you want to support both 32-bit and 64-bit RISC-V, follow the instructions for compiling Binutils from scratch.