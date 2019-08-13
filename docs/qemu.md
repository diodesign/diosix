## Building and using Qemu to test the hypervisor

Although booting Diosix on physical hardware is the project's primary goal, running the hypervisor in the emulator [Qemu](https://qemu.org) has its advantages. One, of course, is that it allows people without access to compatible hardware to try the software from the comfort of their desktop. More importantly, another advantage of using Qemu is that it allows contributors to pause execution, inspect the system's internal state, and debug the code.

While various operating systems provide prebuilt versions of Qemu via a package manager, these versions can be somewhat out of date as Qemu's RISC-V support is constantly improving. This guide will walk you through building the emulator from its latest source code to ensure you have the latest bug fixes and features. You can skip the [build instructions](#compiling), and install Qemu via your package manager, if you are confident it supports RISC-V and is reasonably up to date, and go straight to [running the emulator](#running) instead. Building from source is highly recommended.

## Table of contents

1. [Compiling Qemu](#compiling)
1. [Using Qemu](#running)
1. [Debugging with Qemu](#debugging)

### Compiling Qemu <a name="compiling"></a>

These instructions assume you know your way around a Linux or Unix-like system, are comfortable using your system's command-line interface, and are using a [Debian](https://www.debian.org/)-like GNU/Linux operating system. If you are using another Linux distribution, please adjust the `apt` package installation commands to suit your operating system's package manager.

To build Qemu, ensure you have all the necessary components installed. To do this, open a terminal and run the following:

```
sudo apt update
sudo apt -y install build-essential git libglib2.0-dev libfdt-dev libpixman-1-dev zlib1g-dev
```

Next, enter a directory in which to download the Qemu's source code, then fetch the code and build it. These commands will use `src` within your home directory, and build just 32-bit and 64-bit RISC-V system emulators:

```
mkdir -p $HOME/src
git clone git://git.qemu-project.org/qemu.git
cd qemu
./configure --target-list=riscv32-softmmu,riscv64-softmmu
make
```

When this is complete, two Qemu executable files will have been built: `riscv32-softmmu/qemu-system-riscv32` for emulating 32-bit RISC-V systems, and `riscv64-softmmu/qemu-system-riscv64` for 64-bit RISC-V systems, both within the Qemu source directory. Diosix assumes it can find `qemu-system-riscv32` and `qemu-system-riscv64` in your `PATH` environment variable. To ensure these executable files can be located and used in future shell sessions, you need to update your shell's configuration files so that `PATH` automatically includes the location of these system emulators when you open a new session.

For a discussion on editing your shell's configuration files to update `PATH`, see the [toolchain](toolchain.md) documentation. For now, this guide will keep it simple. If you are using Bash as your shell, you need to edit `.bashrc` in your home directory, or `.zshrc` if you are using Zsh. If you use another shell, check its manual for the location of its configuration file.

Open the appropriate configuration file in a text editor, and insert the following lines at the end of the file:

```
export PATH=$PATH:$HOME/src/qemu/riscv32-softmmu
export PATH=$PATH:$HOME/src/qemu/riscv64-softmmu
```

Save and close the file in your editor. Then close your terminal session using `exit`, and reopen a fresh one. To check `PATH` is defined correctly, the following commands should display version information about the Qemu RISC-V system emulators rather than error messages that the files could not be found:

```
qemu-system-riscv32 --version
qemu-system-riscv64 --version
```

If these commands work, then you are all set to build the hypervisor and run it within Qemu.

### Using Qemu <a name="running"></a>

The recommended method for invoking Qemu with Diosix is to use the `cargo run` commands described in the hypervisor's [build](building.md) documentation. This will run Qemu within the terminal, displaying the output of the system's serial port.

If you want to invoke Qemu directly, invoke `qemu-system-riscv32` for 32-bit targets or `qemu-system-riscv64` for 64-bit targets, and in the command line, specify `-bios none` to disable the loading of firmware, and load the hypervisor using the `-kernel <path to hypervisor>` parameter. The path to the hypervisor will be `target/<target triple>/release/hypervisor` after building Diosix using `cargo build --release --target <target triple>`. See the Qemu documentation for more command-line parameters, such as `-m` to specify the amount of physical RAM available, `-smp` for specifying the number of CPU cores, and `-machine` to specify the emulated hardware.

When Qemu is running, press `control-a` and then `c` to enter the emulator's console. Here, you can type in one of Qemu's built-in commands, and hit `enter` to run it. Here are some useful commands:

* `stop`: Pause execution of software within the emulator.
* `cont`: Continue execution within the emulator.
* `info cpus`: List the emulated CPU cores along with their ID numbers. The asterisked core is the currently selected core for other `info` commands.
* `cpu <N>`: Change the currently selected CPU core to core with the ID value `<N>`.
* `info registers`: Display the main control registers and general-purpose registers for the currently selected CPU core.
* `info registers -a`: Display the main control registers and general-purpose registers for all CPU cores.
* `xp /<N>i <addr>`: Disassemble `<N>` instructions starting from physical RAM address `<addr>`
* `xp /<N>xb <addr>`: Print the contents of the emulated system's memory, as `<N>` bytes in hexadecimal, starting from physical RAM address `<addr>`.
* `xp /<N>xw <addr>`: Print the contents of the emulated system's memory, as `<N>` 32-bit words in hexadecimal, starting from physical RAM address `<addr>`.
* `xp /<N>xg <addr>`: Print the contents of the emulated system's memory, as `<N>` 64-bit words in hexadecimal, starting from physical RAM address `<addr>`.

Press `control-a` and then `c` to leave the console and return to the emulator. Finally, use the command `quit`, or `q` for short, to terminate Qemu.

### Quick debugging with Qemu <a name="debugging"></a>

It is possible to connect the GNU debugger GDB to Qemu to debug a running hypervisor. For quick and easy troubleshooting, though, you can use the above Qemu console commands to investigate crashes and unexpected behavior.

For example, if the hypervisor hangs, you can enter the Qemu console by pressing `control-a` and then `c`, and then entering the command `stop` to pause the execution. Then you can use `info registers -a` to find each processor core's program counter (the `pc` register) and also inspect its control registers (such as `mstatus` on RISC-V) to determine its state. Then, in another terminal, you can use Binutils' objdump to see where in the hypervisor each core has become stuck. For a 64-bit RISC-V build of Diosix, with the project's source code directory in `src` within your home directory, you can use...

```
cd $HOME/src/diosix
riscv64-elf-objdump -d target/<target triple>/release/hypervisor | less
```

...to open a dissassembly of the hypervisor, for a given `<target triple>` (such as `riscv64gc-unknown-none-elf`), and then, in `less`, press `/` to start a search, enter the program counter address you want to inspect, and hit `enter` to jump to the instructions at that address. Press `q` to exit `less`.

For 32-bit RISC-V builds of Diosix, you should use `riscv32-elf-objdump`.
