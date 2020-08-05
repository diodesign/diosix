[![Build and test](https://github.com/diodesign/diosix/workflows/Build%20and%20test/badge.svg)](https://github.com/diodesign/diosix/actions?query=workflow%3A%22Build+and+test%22) [![License: MIT](https://img.shields.io/github/license/diodesign/diosix)](https://github.com/diodesign/diosix/blob/master/LICENSE) [![Language: Rust](https://img.shields.io/badge/language-rust-yellow.svg)](https://www.rust-lang.org/) ![Platform: riscv32, riscv64](https://img.shields.io/badge/platform-riscv32%20%7C%20riscv64-lightgray.svg)

## Table of contents

1. [Introduction](#intro)
1. [Quickstart using Docker](#quickstart)
1. [Quickstart using Google Cloud Run](#cloudrun)
1. [Build a Diosix Docker container](#container)
1. [Build Diosix from scratch](#fromscratch)
1. [Contact, security issue reporting, and code of conduct](#contact)
1. [Copyright, distribution, and license](#copyright)

### Introduction <a name="intro"></a>

Diosix 2.0 strives to be a lightweight, fast, and secure multiprocessor bare-metal hypervisor written [in Rust](https://www.rust-lang.org/) for 32-bit and 64-bit [RISC-V](https://riscv.org/) computers. A long-term goal is to build open-source Diosix packages that configure FPGAs with custom RISC-V cores and peripheral controllers to accelerate specific tasks, on the fly if necessary. This software should also run on supported system-on-chips.

Right now, Diosix is a work in progress. It can bring up a RISC-V system, load a Linux guest OS with minimal filesystem into a virtualized environment called a capsule, and begin executing it. The next step is to provide the guest a Device Tree Blob describing its virtualized environment so that it can successfully boot.

### Quickstart using Docker <a name="quickstart"></a>

You can build and run Diosix in a convenient containerized environment. These instructions assume you are comfortable using Docker and the command-line interface on a Linux-like system.

First, you must authenticate with GitHub Packages. If you have not yet done so, [create a personal access token](https://docs.github.com/en/github/authenticating-to-github/creating-a-personal-access-token) that grants read-only access to GitHub Packages, and [pass this token](https://docs.github.com/en/packages/using-github-packages-with-your-projects-ecosystem/configuring-docker-for-use-with-github-packages#authenticating-to-github-packages) to Docker.

Next, fetch a prebuilt Diosix Docker container image from GitHub. Available images are listed [here](https://github.com/diodesign/diosix/releases). For example, to fetch the latest released image, run:

```
docker pull docker.pkg.github.com/diodesign/diosix/wip:lightweight-docker-2
```

Use this image to create and run a temporary container that boots Diosix within the Qemu emulator:

```
docker run -ti --rm docker.pkg.github.com/diodesign/diosix/wip:lightweight-docker-2
```

The output from the hypervisor should be similar to the following, indicating Diosix running on a quad-core 64-bit RISC-V machine with 512MiB of RAM:

```
Compiling diosix v2.0.0 (/build/diosix)
    Finished dev [unoptimized + debuginfo] target(s) in 41.20s
     Running `qemu-system-riscv64 -bios none -nographic -machine virt -smp 4 -m 512M -kernel target/riscv64gc-unknown-none-elf/debug/hypervisor`
[?] CPU 0: Enabling RAM region 0x80ed4000, size 497 MB
[-] CPU 0: Welcome to diosix 2.0.0
[?] CPU 0: Debugging enabled, 4 CPU cores found
[?] CPU 0: Translated supervisor virtual entry point 0xffffffe000000000 to 0x80ed4000 in physical RAM
[?] CPU 0: Loading supervisor ELF program area: 0x8004dc00 size 0x1e620 into 0x80ed4000
[?] CPU 0: Loading supervisor ELF program area: 0x8006cc00 size 0xa2c0bc into 0x80ef3000
[?] CPU 0: Physical CPU core RV64IMAFDC (Qemu/Unknown) ready to roll
[?] CPU 1: Physical CPU core RV64IMAFDC (Qemu/Unknown) ready to roll
[?] CPU 2: Physical CPU core RV64IMAFDC (Qemu/Unknown) ready to roll
[?] CPU 3: Physical CPU core RV64IMAFDC (Qemu/Unknown) ready to roll
[?] CPU 0: Running vcore 0 in capsule 1
[?] CPU 0: Granting ReadWriteExecute access to 0x80ed4000, 134217728 bytes
[!] CPU 0: Fatal exception in Supervisor: Breakpoint at 0x80ed68c8, stack 0x817f9ff0
[?] CPU 0: Tearing down capsule 0x80cdb000
```

Press `Control-a` then `c` to escape to the Qemu monitor. Run the monitor command `info registers -a` to list the CPU core states. You should see output similar to the following:

```
QEMU 5.0.91 monitor - type 'help' for more information
(qemu) info registers -a

CPU#0
 pc       000000008000004c
 mhartid  0000000000000000
 mstatus  0000000000000088
```

Run the monitor command `quit` to exit the emulation and the container. Further instructions on how to use Qemu's monitor [are here](https://www.qemu.org/docs/master/system/monitor.html).

### Quickstart using Google Cloud Run <a name="cloudrun"></a>

To build and run Diosix in Google Cloud using Google Cloud Run, click the button below.

[![Run on Google Cloud](https://deploy.cloud.run/button.svg)](https://deploy.cloud.run?git_repo=https://github.com/diodesign/diosix)

The Google Cloud Shell will open and ask you to select which Google Cloud project and region to use for these next steps. Google Cloud Run will then build a container image from the latest Diosix source code, and run it. In this environment, the container will not boot the hypervisor, and instead will start a web server that serves a page confirming it was built successfully. Google Cloud Run will provide, in the Google Cloud Shell, a HTTPS URL to that server.

In the Cloud Shell, run `docker images` to see the newly built container. The output should be similar to:

```
REPOSITORY                             TAG                 IMAGE ID            CREATED             SIZE
gcr.io/refreshing-park-100423/diosix   latest              3aba4a35e78e        43 minutes ago      2.15GB
```

To boot the hypervisor in this container in the Cloud Shell, run:

```
docker run --rm -ti `docker images --format "{{.Repository}}:{{.Tag}}" | grep -E "(gcr\.io\/){1}([a-z0-9\-]+)\/(diosix:latest){1}"`
```

The output should be similar to:

```
    Finished dev [unoptimized + debuginfo] target(s) in 1m 09s
     Running `qemu-system-riscv64 -bios none -nographic -machine virt -smp 4 -m 512M -kernel target/riscv64gc-unknown-none-elf/debug/hypervisor`
[?] CPU 0: Enabling RAM region 0x80ed4000, size 497 MB
[-] CPU 0: Welcome to diosix 2.0.0
[?] CPU 0: Debugging enabled, 4 CPU cores found
```

Press `Control-a` then `c` to escape to the Qemu monitor. Run the monitor command `quit` to shutdown the emulator and the container.

Note: you will be [billed](https://cloud.google.com/run/pricing) by Google for any resources used to build and run this container beyond your free allowance. The Google Cloud Run documentation is [here](https://cloud.google.com/run).

### Build a Diosix Docker container <a name="container"></a>

If you do not wish to use GitHub Packages nor Google Cloud Run, you can build and run the container environment from the latest Diosix source code yourself by hand. Navigate to a suitable directory on your system, and use these commands to fetch, build, and run a Diosix Docker contaimer tagged `diosix`:

```
git clone --recurse-submodules https://github.com/diodesign/diosix.git
cd diosix
docker build . --file Dockerfile --tag diosix
docker run -ti --rm diosix
```

Press `Control-a` and `c` to escape to the emulator. Run the monitor command `quit` to exit the simulation and destroy the container.

### Build Diosix from scratch <a name="fromscratch"></a>

To build and run Diosix completely from scratch, without any containerization, follow these steps:

1. [Building the toolchain](docs/toolchain.md)
1. [Using Buildroot to build a bootable Linux guest OS](docs/buildroot.md)
1. [Building and using Qemu to test the hypervisor](docs/qemu.md)
1. [Building and running the hypervisor](docs/building.md)

### Contact, security issue reporting, and code of conduct <a name="contact"></a>

Please send an [email](mailto:diosix@tuta.io) if you have any questions or issues to raise, wish to get involved, have source to contribute, or have [found a security flaw](docs/security.md). You can, of course, submit pull requests or raise issues via GitHub, though please consider disclosing security-related matters privately. Please also observe the project's [code of conduct](docs/conduct.md) if you wish to participate.

### Copyright, distribution, and license <a name="copyright"></a>

Copyright &copy; Chris Williams, 2018-2020. See [LICENSE](https://github.com/diodesign/diosix/blob/master/LICENSE) for distribution and use of source code and binaries.
