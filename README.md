[![Build and test](https://github.com/diodesign/diosix/workflows/Build%20and%20test/badge.svg)](https://github.com/diodesign/diosix/actions?query=workflow%3A%22Build+and+test%22) [![License: MIT](https://img.shields.io/github/license/diodesign/diosix)](https://github.com/diodesign/diosix/blob/master/LICENSE) [![Language: Rust](https://img.shields.io/badge/language-rust-yellow.svg)](https://www.rust-lang.org/) ![Platform: riscv64](https://img.shields.io/badge/platform-riscv64-lightblue.svg)

## Table of contents

1. [Introduction](#intro)
1. [Quickstart using Google Cloud Run](#cloudrun)
1. [Building and running Diosix](#building)
1. [FAQ](#faq)
1. [Contact, security issue reporting, and code of conduct](#contact)
1. [Copyright, distribution, and license](#copyright)

### Introduction <a name="intro"></a>

Diosix strives to be a lightweight, fast, and secure multiprocessor bare-metal hypervisor written [in Rust](https://www.rust-lang.org/) for 64-bit [RISC-V](https://riscv.org/) computers. This project is a work in progress.

It can initialize a compatible RISC-V system, and run one or more Linux guest operating systems in hardware-isolated virtualized environments called capsules. System services also run in capsules. One such service provides a virtual console, allowing multiple guests to share the same terminal. Below is a recording of Diosix booting within Qemu, and loading and running the console service and a Linux guest OS. The user interacts with the guest OS via the console to log in and run programs, such as Micropython to print "hello world!"

[![asciicast](https://asciinema.org/a/395307.svg)](https://asciinema.org/a/395307)

The guest OS is shut down using the `poweroff` command.

### Quickstart using Google Cloud Run <a name="cloudrun"></a>

To build and run Diosix in Google Cloud using Google Cloud Run, click the button below.

[![Run on Google Cloud](https://deploy.cloud.run/button.svg)](https://deploy.cloud.run?git_repo=https://github.com/diodesign/diosix&dir=docker)

The Google Cloud Shell will open and ask you to select which Google Cloud project and region to use for these next steps. When selected, Google Cloud Run will then build a container image from the latest Diosix source code, and run it. In this environment, the container will not boot the hypervisor, and instead will start a web server that serves a page confirming the container was built successfully. Google Cloud Run will provide, in the Google Cloud Shell, a HTTPS URL to that server.

In the Cloud Shell, run `docker images` to see the newly built container image. The output should be similar to:

```
REPOSITORY                             TAG                 IMAGE ID            CREATED             SIZE
gcr.io/refreshing-park-100423/diosix   latest              3aba4a35e78e        43 minutes ago      2.15GB
```

To boot the hypervisor in this container in the Cloud Shell, run:

```
docker run --rm -ti `docker images | grep -o -E "(gcr\.io\/){1}([a-z0-9\-]+)\/(diosix){1}"`
```

The output should be similar to:

```
    Finished dev [unoptimized + debuginfo] target(s) in 1m 09s
     Running `qemu-system-riscv64 -bios none -nographic -machine virt -smp 4 -m 512M -kernel target/riscv64gc-unknown-none-elf/debug/hypervisor`
[?] CPU 0: Enabling RAM region 0x80ed4000, size 497 MB
[-] CPU 0: Welcome to diosix 2.0.0
[?] CPU 0: Debugging enabled, 4 CPU cores found
```

Press `Control-a` then `x` to exit the emulator and shut down the container.

Note: you will be [billed](https://cloud.google.com/run/pricing) by Google for any resources used to build and run this container beyond your free allowance. The Google Cloud Run documentation is [here](https://cloud.google.com/run).

### Build a Diosix Docker container <a name="container"></a>

If you do not wish to use GitHub Packages nor Google Cloud Run, you can build and run the container environment from the latest Diosix source code yourself by hand. Navigate to a suitable directory on your system, and use these commands to fetch, build, and run a Diosix Docker contaimer tagged `diosix`:

```
git clone --recurse-submodules https://github.com/diodesign/diosix.git
cd diosix
docker build . --file Dockerfile --tag diosix
docker run -ti --rm diosix
```

Press `Control-a` and `x` to exit to the emulator and shut down the container.

### Build Diosix from scratch <a name="fromscratch"></a>

To build and run Diosix completely from scratch, without any containerization, follow these steps:

1. [Building the toolchain](docs/toolchain.md)
1. [Using Buildroot to build a bootable Linux guest OS](docs/buildroot.md)
1. [Building and using Qemu to test the hypervisor](docs/qemu.md)
1. [Building and running the hypervisor](docs/building.md)

### Contact, security issue reporting, and code of conduct <a name="contact"></a>

Please send an [email](mailto:diosix@tuta.io) if you have any questions or issues to raise, wish to get involved, have source to contribute, or have [found a security flaw](docs/security.md). You can, of course, submit pull requests or raise issues via GitHub, though please consider disclosing security-related matters privately. You're more than welcome to use the [discussion boards](https://github.com/diodesign/diosix/discussions/) to ask questions and suggest features.

Please also observe the project's [code of conduct](docs/conduct.md) if you wish to participate.

### Copyright, distribution, and license <a name="copyright"></a>

Copyright &copy; Chris Williams, 2018-2021. See [LICENSE](https://github.com/diodesign/diosix/blob/master/LICENSE) for distribution and use of source code and binaries.
