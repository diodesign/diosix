# Diosix binaries and assorted files

This `binaries` branch contains a collection of files that, while related to [Diosix](https://diosix.org), do not need to be checked out from version control to build, run, test, or develop the project. The build system may fetch some of these files, such as the guest binaries, directly if they are needed. Below is a description of what you can find in this branch.

### Buildroot-built guest binaries

The `buildroot-guests` directory contains one or more Busybox-based Linux guest operating systems built using [Buildroot](https://buildroot.org). These are self-contained binaries featuring a kernel and user-space programs in an initrd file-system that are unpacked into RAM and run by the hypervisor in a virtualized environment.

To create a guest binary yourself, follow these steps on a Linux host system to configure and run Buildroot for the desired binary:
1. Check out the latest Buildroot source from its [Git repository](https://git.buildroot.net/buildroot) and enter its directory using:
```
git clone https://git.busybox.net/buildroot
cd buildroot
```
2. Copy the configuration file for the desired binary to `.config` inside the buildroot source directory. The configuration file is specified below for each binary file, and it is relative to the root directory of the `main` branch of the Diosix project. For example, to copy the configuration file for the binary `riscv64-linux-busybox`, use:
```
cp /path/to/diosix/boot/buildroot/riscv64.config .config
```
3. Run `make` to start the build. When it is complete, the file `output/images/vmlinux` will be the guest binary that can be used with Diosix. Copy it to the `boot/guests` directory in the Diosix project tree. To continue with the example of `riscv64-linux-busybox`, use:
```
cp output/images/vmlinux /path/to/diosix/boot/guests/riscv64-linux-busybox
```

Below is a table of the available guest binaries along with a description and configuration file path for each.

| Filename | Description | Built  | Configuration |
|----------|-------------|--------|---------------|
| riscv64-linux-busybox | RV64G (lp64d) Linux kernel version 5.10.13 with BusyBox 1.33.0 | Feb 21, 2021 | `boot/buildroot/riscv64.config` |

A guest binary contains third-party free software, listed below, built from unmodified source code using Buildroot. If you wish to obtain the source for these components, please follow the links in the table.

| Component | License | Source code |
|-----------|---------|-------------|
| Linux kernel 5.10.13 | [GPL 2.0 with Linux-syscall-note](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/COPYING?h=v5.10.18) | [git.kernel.org](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/?h=v5.10.18) |
| glibc 2.32 | [GPL 2.0](https://sourceware.org/git/?p=glibc.git;a=blob;f=COPYING;h=d159169d1050894d3ea3b98e1c965c4058208fe1;hb=3de512be7ea6053255afed6154db9ee31d4e557a) | [sourceware.org](https://sourceware.org/git/?p=glibc.git;a=tree;h=d90f4673165d16d37a4d6990b8accde272893479;hb=3de512be7ea6053255afed6154db9ee31d4e557a) |
| BusyBox 1.33.0 | [GPL 2.0](https://git.busybox.net/busybox/tree/LICENSE?h=1_33_stable) | [git.busybox.net](https://git.busybox.net/busybox/tree/?h=1_33_stable) |

### Presentations

In January 2021, Diosix developer Chris Williams gave a 30-minute overview of the project to the British Computer Society's Open Source Specialists group. The slides for this presentation are in `presentations/BCS-OpenSource-London-Jan-2021.pdf`, and you can watch a recording of the talk on YouTube by clicking on the preview below.

[![A slide from the BCS OSS group talk](https://img.youtube.com/vi/Czd9AspXWUc/0.jpg)](https://www.youtube.com/watch?v=Czd9AspXWUc)
