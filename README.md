[![Build](https://github.com/diodesign/diosix/workflows/Build/badge.svg)](https://github.com/diodesign/diosix/actions?query=workflow%3A%22Build%22) [![License: MIT](https://img.shields.io/github/license/diodesign/diosix)](https://github.com/diodesign/diosix/blob/main/LICENSE) [![Language: Rust](https://img.shields.io/badge/language-rust-yellow.svg)](https://www.rust-lang.org/) [![Platform: riscv64](https://img.shields.io/badge/platform-riscv64-lightblue.svg)](https://riscv.org/)

## Welcome guide

1. [About this project](#intro)
1. [Quickstart using Qemu](#qemu)
1. [Quickstart using Google Cloud Run](#cloudrun)
1. [Run Diosix from source in a container](#container)
1. [Run Diosix from source without a container](#nocontainer)
1. [Frequently anticipated questions](#faq)
1. [Contact, contributions, security, and code of conduct](#contact)
1. [Copyright, distribution, and license](#copyright)

## About this project <a name="intro"></a>

Diosix strives to be a lightweight, fast, and secure multiprocessor bare-metal hypervisor written [in Rust](https://www.rust-lang.org/) for 64-bit [RISC-V](https://riscv.org/) computers. Though this project is a work in progress, you can boot and use guest operating systems with it.

Below is a recording of a user logging into a RISC-V Linux guest OS on Diosix and using Micropython to print "hello world!"

[![asciicast](https://asciinema.org/a/395307.svg)](https://asciinema.org/a/395307)

## Quickstart using Qemu <a name="qemu"></a>

To run a prebuilt version of Diosix and a RISC-V Linux guest within Qemu, first ensure you have installed a 64-bit RISC-V-capable version of the emulator. This is included in the `qemu-system-misc` package on Debian 10, for example.

Next, fetch from the [`binaries`](https://github.com/diodesign/diosix/tree/binaries) branch an executable containing the hypervisor and its guest:

```
wget https://github.com/diodesign/diosix/raw/binaries/diosix/diosix-0.0.2-debug-20210307
```

Run Diosix on a dual-core Qemu system with 512MB of RAM:

```
qemu-system-riscv64 -bios none -nographic -machine virt -smp 2 -m 512M -kernel diosix-0.0.2-debug-20210307
```

Once booted, the hypervisor will start its included Linux guest OS. When you see the following prompt, log into the guest as `root` with no password:

```
Welcome to Busybox/Linux with Micropython
buildroot-guest login: 
```

Micropython, zsh, and less are provided as well as BusyBox. Press `Control-a` then `x` to exit the Qemu RISC-V emulator. Note: the guest instance is temporary, and any data saved inside it will be lost when you end the emulation.

## Quickstart using Google Cloud Run <a name="cloudrun"></a>

To run RISC-V Linux on Diosix from your browser using Google Cloud, click the button below.

[![Run on Google Cloud](https://deploy.cloud.run/button.svg)](https://deploy.cloud.run?git_repo=https://github.com/diodesign/diosix)

When prompted, confirm you trust the Diosix repository and allow Google Cloud Shell to make Google Cloud API calls. Cloud Shell will next ask you to choose which Google Cloud project and region to use for this process.

Once selected, Google Cloud Run will create a Docker container image of Diosix, built from its latest source code, with a prebuilt Linux guest OS.

To start this container, run this command in Cloud Shell:

```
docker run --rm -ti `docker images | grep -o -E "(gcr\.io\/){1}([a-z0-9\-]+)\/(diosix){1}"`
```

As with the Qemu quickstart guide, log into the guest using `root` as the username with no password. Press `Control-a` then `x` to exit the Qemu RISC-V emulator and shut down the container. Close the Cloud Shell to end the session.

Note: you will be [billed](https://cloud.google.com/run/pricing) by Google for any resources used to build and run this container beyond your free allowance. Cloud Run documentation is [here](https://cloud.google.com/run).

## Run Diosix from source in a container <a name="run"></a>

To build Diosix from source and boot it with a prebuilt guest OS within a Docker container on your own system, create a container image of the software:

```
git clone https://github.com/diodesign/diosix.git
cd diosix
docker build --tag diosix .
```

And start the container:

```
docker run -ti --rm diosix
```

As with Google Cloud Run, log into the provided guest Linux OS environment as `root` with no password. Press `Control-a` then `x` to exit the Qemu emulator and shut down and delete the container.

## Run Diosix from source without a container <a name="nocontainer"></a>

To build and run Diosix from its latest source code without using Docker, follow [these instructions](docs/running.md).

## Frequently anticipated questions <a name="faq"></a> <a name="todo"></a>

**Q. What can Diosix do right now?**

**A.** It initializes a compatible RISC-V system, and runs one or more guest operating systems in hardware-isolated virtualized environments called capsules. System services also run in capsules using a provided runtime. One such service offers a virtual console through which the user can interact with guest capsules.

Diosix supports systems with multiple CPU cores, and preemptively schedules capsules' virtual cores to run on their physical counterparts. It handles interrupts and exceptions, instruction emulation, serial IO, memory management and protection, and capsule and system service management.

It partially implements the [SBI specification](https://github.com/riscv/riscv-sbi-doc/blob/master/riscv-sbi.adoc) as implementation ID 5. It parses Device Tree configuration data from the motherboard firmware to discover the available hardware, and generates Device Tree structures describing virtualized environments for guest OSes to parse.

**Q. Will you support other processor architectures?**

**A.** Though the project is focused on RISC-V, Diosix is structured so that the hypervisor's core code is portable. Platform-specific code is kept separate and included during the build process: a port to another architecture would need to provide those platform-specific crates. If you want to contribute and maintain support for other architectures, please get in touch. Ports to other open hardware platforms, such as OpenPOWER, and architectures similar to RISC-V, such as Arm, would be welcome.

**Q. Why no support for 32-bit RISC-V processors?**

**A.** Diosix initally supported 32 and 64-bit RISC-V CPU cores. However, 32-bit support was dropped in March 2021 to prioritize fixing bugs, adding features, and updating documentation. If you wish to maintain RV32 support for Diosix, please get in touch.

**Q. Does Diosix rely on KVM, Qemu, or similar?**

**A.** No. Diosix is a strictly bare-metal, type-1 original hypervisor designed to run just above the ROM firmware level. It doesn't sit on top of any other virtualization library or layer, such as Linux's KVM, nor Xen. Qemu is used as a development environment, and it is not required to run Diosix on real hardware.

**Q. What are the minimum requirements to run Diosix?**

**A.** Diosix by default expects 256KB of RAM per CPU core plus space in memory to store itself, its data strucures, and its payload, and space to run guests. For example, a quad-core system with a 32MB Diosix payload (containing the hypervisor, a guest OS, console system service, and boot banners), running three guests instances with 128MB of memory each, would comfortably fit within 512MB of host RAM. The exact requirements are tunable: if your target hardware has limited RAM, Diosix's footprint can be scaled down as well as up.

## Contact, contributions, security issue reporting, and code of conduct <a name="contact"></a>

Email [hello@diosix.org](mailto:hello@diosix.org) if you have any questions or issues to raise, wish to get involved, or have source to contribute. If you have found a security flaw, please follow [these steps](docs/security.md) to report the bug.

You can also submit pull requests or raise issues via GitHub, though please consider disclosing security-related matters privately. You are more than welcome to use the [discussion boards](https://github.com/diodesign/diosix/discussions/) to ask questions and suggest features.

Please observe the project's [code of conduct](docs/conduct.md) when participating.

## Copyright, distribution, and license <a name="copyright"></a>

Copyright &copy; Chris Williams, 2018-2021. See [LICENSE](https://github.com/diodesign/diosix/blob/main/LICENSE) for distribution and use of source code, binaries, and documentation.

More information can be found [here](https://github.com/diodesign/diosix/blob/binaries/README.md) on the contents of the guest OS binaries used by Diosix. The diosix.org [illustration](docs/logo.png) is a combination of artwork kindly provided by [Katerina Limpitsouni](https://undraw.co/license) and [RISC-V International](https://riscv.org/about/risc-v-branding-guidelines/).