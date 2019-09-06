## Using Buildroot to build a bootable Linux kernel

When the Diosix hypervisor brings up a system, it creates, and schedules to run, a virtualized environment called the boot capsule that contains an operating system kernel and an initial filesystem of software. This boot capsule is expected to complete the system initialization, and provide a user interface for starting more capsules from storage memory. These capsules are expected to run applications on behalf of the user. For embedded devices and servers, the boot capsule could automatically start services and applications in capsules from storage. The capsules are isolated from each other by the hypervisor for security and reliability purposes.

The boot capsule's kernel and initial filesystem must be provided at build time so that they are incorporated into the final hypervisor executable. A single executable, containing the hypervisor, and its boot capsule kernel and initial filesystem, is generated to simplify booting: the bootloader needs to load and run just one file from storage to get the system going.

The Linux-compatible operating system kernel that will run inside the boot capsule should be named `supervisor` and placed in the directory path `boot/binaries/<architecture>/` within the root directory of the Diosix project. The name `supervisor` was chosen because the executable runs in supervisor mode above the Diosix hypervisor. The `<architecture>` component of the path refers to the CPU architecture of the machine this build of Diosix will bring up.

Below is a table of targets and their corresponding CPU architecture and boot capsule kernel paths. See the [Diosix build guide](building.md) for the full list of supported CPU architectures.

| Target                         | CPU architecture | Boot capsule kernel path               |
|:-------------------------------|:-----------------|:---------------------------------------|
| `riscv32imac-unknown-none-elf` | `riscv32imac`    | `boot/binaries/riscv32imac/supervisor` |
| `riscv64imac-unknown-none-elf` | `riscv64imac`    | `boot/binaries/riscv64imac/supervisor` |
| `riscv64gc-unknown-none-elf`   | `riscv64gc`      | `boot/binaries/riscv64gc/supervisor`   |


Note that Diosix defaults to building for `riscv64gc-unknown-none-elf` so if you use the default target, you must provide a `supervisor` kernel for that CPU architecture.

The `supervisor` kernel should be an ELF binary, and should include an initial filesystem that it automatically unpacks into memory. it is assumed to be a [Linux](https://www.kernel.org/)-like kernel, in that it will be started in an environment that Linux expects. Just as Diosix may in future support CPU architectures other than RISC-V, the hypervisor may well support non-Linux kernels.

You can either provide a `supervisor` binary yourself, and ensure a copy is placed within a suitable folder in `boot/binaries` as described above, or you can follow the steps below to use [Buildroot](https://buildroot.org/) and one or more of the supplied configuration files to generate one or more kernels, each with an initial filesystem. The instructions assume you know your way around a Linux or Unix-like system, are comfortable using your system's command-line interface, and are using a [Debian](https://www.debian.org/)-like GNU/Linux operating system. If you are using another Linux distribution, please adjust the `apt` package installation commands to suit your operating system's package manager.

### Using Buildroot

First, ensure you have the necessary tools on your system to run Buildroot. To do this, open a terminal and run the following:

```
sudo apt update
sudo apt install -y build-essential binutils wget unzip rsync cpio bc file python perl sed automake git
```

Next, enter a directory in which to download Buildroot's latest source code. These commands will use `src` within your home directory:

```
mkdir -p $HOME/src
cd $HOME/src
git clone https://github.com/buildroot/buildroot.git
cd buildroot
```

To build a Linux kernel for a particular CPU architecture, copy the supplied Buildroot configuration file for that architecture into the Buildroot source code directory. The supplied configuration files are in the `boot/buildroot/` directory within the Diosix project's root directory. Next, tell Buildroot to begin compiling. When it is complete, ensure the directory structure to store the built kernel exists within the Diosix project, and copy the generated kernel, located at `output/images/vmlinux` in the Buildroot source code directory, to the `boot/binary/<architecture>/supervisor` path.

Generically, and assuming Diosix is located at `src/diosix` in your home directory and your working directory is still the Buildroot source code directory, the commands needed to perform the above steps are:

```
cp $HOME/src/diosix/boot/buildroot/<architecture>.config .config
make
mkdir -p $HOME/src/diosix/boot/binaries/<architecture>
cp output/images/vmlinux $HOME/src/diosix/boot/binaries/<architecture>/supervisor
```

Replace `<architecture>` above with a supported CPU architecture. For example, for the target `riscv64gc-unknown-none-elf` and architecture `riscv64gc`, use the following commands:

```
cp $HOME/src/diosix/boot/buildroot/riscv64gc.config .config
make
mkdir -p $HOME/src/diosix/boot/binaries/riscv64gc
cp output/images/vmlinux $HOME/src/diosix/boot/binaries/riscv64gc/supervisor
```

Once you have built or provided one or more boot capsule kernels, and placed them in the correct path or paths in `boot/binaries`, you are ready to build and run Diosix.

### A note on Linux kernel versions

The supplied Buildroot configuration files specify the latest stable version of the Linux kernel for 64-bit RISC-V targets, version 5.2 at time of writing, and the latest long-term version, 4.19.66, for 32-bit RISC-V targets. This is due to broken support in the 5.x.x kernel series for 32-bit RISC-V targets.
