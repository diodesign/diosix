[![Diosix continuous integration][ci-badge]][ci-url]
[![Language: Zig][zig-badge]](https://ziglang.org/)
[![Platform: riscv64][rv64-badge]](https://riscv.org/)

[ci-badge]: https://github.com/diodesign/diosix/actions/workflows/ci.yml/badge.svg
[ci-url]: https://github.com/diodesign/diosix/actions/workflows/ci.yml
[zig-badge]: https://img.shields.io/badge/language-zig-darkorange.svg
[rv64-badge]: https://img.shields.io/badge/platform-riscv64-lightblue.svg

# Diosix

Diosix is a bare-metal type-1 hypervisor written in Zig for multi-core 64-bit
RISC-V systems. It organizes guests into a self-organizing, symmetric tree of
hardware-isolated virtual machines (VMs) while keeping the machine-mode
(M-mode) hypervisor core small, leaving device drivers, filesystems, and
network stacks inside guest VMs.

```text
M-mode Hypervisor (Stage-2 / PMP isolation, quotas, L2 virtual switch)
 `-- Top-level VM (CID 1, parent: hypervisor, initial hardware passthrough)
      |-- Child VM (CID 2 to parent -> sees self as CID 1, parent as CID 0)
      |    `-- Grandchild VM (opaque to grandparents; own nested switch)
      `-- Child VM (CID 3 to parent -> sees self as CID 1, parent as CID 0)
```

Every VM runs with the same structural interfaces: it inspects its device tree
for its hardware environment and its manifest for role and capability bounds,
addresses its parent as `CID 0`, itself as `CID 1`, and its direct children as
`CID 2..N`, and delegates slices of its own CPU and RAM quota downward. Child
subtrees remain opaque to ancestors, providing a recursive foundation for
autonomous workloads.

## What makes Diosix different

* **Symmetric VM tree:** Every VM starts with the same hypervisor ABI and
  userspace tooling (`dsx`, `diosix-gui`, and `guest-shim`). The first VM booted
  by the hypervisor starts with `parent: hypervisor`, full system quota, and
  inheritable hardware trust, then partitions resources down the tree.
* **Mixed RISC-V execution:** Native 64-bit RISC-V guests boot from ELF
  kernels, flat kernel images, installer ISOs, or seeded virtual disks, and
  single-core 32-bit RISC-V guests run via dynamic binary recompilation.
* **Zero-copy guest desktops:** Parent VMs view and control child Wayland
  desktops through Tier 1 Stage-2 read-only scanout mapping with dirty-rect
  invalidation and hardware cursor overlays alongside virtual terminals and
  serial consoles.
* **Default-isolated recursive networking:** Each parent runs a `diosix0`
  virtual subnet for direct children (`10.0.3.x`, `10.0.4.x`, and upward) while
  children see an upstream `eth0` interface with SSH passwords disabled and
  outbound access gated by parent firewall rules.
* **Charter governance:** Critical deployments can seal a charter hash and
  quorum policy in M-mode to protect steward VMs, confidential guest memory,
  and standby failover.

---

## Quickstart

You can try Diosix in QEMU on Linux either by downloading a prebuilt release
bundle (no compilation required) or by building from source.

### Run a prebuilt release bundle

1. Install QEMU 10.0 or later (`qemu-system-riscv64`) on your Linux machine.
2. Download and unpack the standalone release archive from GitHub Releases and
   launch a graphical Wayland desktop VM, an interactive CLI VM, or the root VM
   desktop supervisor:

   ```bash
   tar -xf diosix-26.1-riscv64.tar.xz
   cd diosix-26.1-riscv64
   sha256sum -c SHA256SUMS

   # Boot straight into the Wayland desktop RISC-V VM
   ./run-diosix.sh --desktop

   # Boot straight into an interactive CLI RISC-V VM
   ./run-diosix.sh --cli

   # Or open the root VM graphical desktop and welcome launcher
   ./run-diosix.sh --gui
   ```

### Build and run from source

1. Install the [build dependencies][build-deps] (Zig 0.17 or later, QEMU 10.0
   or later, and standard Buildroot host packages).

[build-deps]: docs/build.md#build-process-and-dependencies

2. Clone the repository and launch a graphical Wayland desktop VM, an
   interactive CLI VM, or the root VM supervisor:

   ```bash
   git clone https://github.com/diodesign/diosix.git
   cd diosix

   # Boot straight into the Wayland desktop RISC-V VM
   ./scripts/build.sh run-desktop

   # Boot straight into an interactive CLI RISC-V VM
   ./scripts/build.sh run-cli

   # Or boot the root VM graphical desktop or headless serial console
   ./scripts/build.sh run-gui
   ./scripts/build.sh run
   ```

### Run inside Docker

If you prefer not to install build packages on your machine, use the included
Docker build environment:

```bash
git clone https://github.com/diodesign/diosix.git
cd diosix

docker build -f dockerfiles/ubuntu-26.04.Dockerfile -t diosix-ubuntu .
docker run -it --rm diosix-ubuntu ./scripts/build.sh run
```

### First commands to try inside Diosix

When QEMU finishes booting in developer mode, it logs into the root VM with
your local SSH public key ready to use. Try these `dsx` commands:

```bash
# 1. Run the 5-step interactive tour and check host capabilities
dsx tour
dsx host info

# 2. Launch an isolated CLI VM or a Wayland desktop VM
dsx run linux-cli --name work-vm --vcpus 2 --ram 256M
dsx run linux-desktop --name desk-vm --vcpus 2 --ram 512M
dsx list

# 3. Run a command inside the CLI VM over key-based SSH
dsx ssh work-vm -- uname -a

# 4. Save an in-memory RAM checkpoint of the child VM
dsx snapshot save work-vm clean-boot

# 5. Browse SHA-256-verified guest images in the catalog
dsx image catalog
```

In a headless QEMU terminal session, press `Ctrl-a` then `x` to exit QEMU, or
press `Ctrl-a` then `c` to switch to and from the QEMU monitor.

Here is a terminal recording ([play the local cast](docs/diosix-demo.cast) with
`asciinema play docs/diosix-demo.cast`) showing Diosix booting and managing
guest VMs, quotas, and snapshots:

[![asciicast of Diosix running](https://asciinema.org/a/1214657.svg)](https://asciinema.org/a/1214657)

---

## Documentation

Documentation is split into two tracks depending on what you want to do:

### User guides

| Guide | What it covers |
| :--- | :--- |
| [Getting started and running Diosix](docs/run.md) | Booting in QEMU, exploring the interactive tour and graphical desktop, and provisioning target disks. |
| [Deploying and provisioning guest VMs](docs/guests.md) | Running built-in sandboxes, booting installer ISOs, seeding disk images, booting custom kernels, and managing quotas and RAM checkpoints. |
| [Security, networking, and governance](docs/security.md) | Default guest network isolation, chaining VMs through a firewall VM, managing SSH passkeys, and sealing a charter. |
| [CLI and configuration reference](docs/cli.md) | Full command reference for `dsx` and runtime configuration files in `/etc/diosix/`. |

### Technical reference

| Reference | What it covers |
| :--- | :--- |
| [Hypervisor architecture](docs/architecture.md) | Design rationale behind the symmetric self-organizing VM tree, M-mode resource model, Stage-2 zero-copy scanout, dynamic recompilation, and standby failover. |
| [Shared interface and ABI](docs/interface.md) | Supervisor binary interface (SBI) hypercalls, C application binary interface (ABI) structures, Linux kernel driver calls, and the virtual MMIO bus map. |
| [GUI architecture](docs/gui-architecture.md) | Internals of the direct rendering manager (DRM) and kernel mode setting (KMS) host desktop, guest display windows, terminal multiplexer, and JSON control plane. |
| [Feature support matrix](docs/support-matrix.md) | Generated map of every hypervisor, emulation, kernel driver, CLI, GUI, and build feature alongside its source files, callers, and documentation links. |
| [Build system, porting, and debugging](docs/build.md) | Build pipeline caching, declarative layout manifests, position-independent M-mode bootstrap, physical board deployment, and GNU debugger (GDB) remote debugging. |
| [Contributor guide](docs/development.md) & [Style guide](docs/style-guide.md) | Memory ownership, concurrency rules, unit and integration testing, calendar versioning (CalVer), and code and prose conventions. |

Community expectations are outlined in the [Code of conduct](docs/conduct.md).

---

## Legal

Unless otherwise stated, Diosix source code and provided binaries are
distributed under the terms of the MIT License. See [LICENSE.md](LICENSE.md)
for the full text and [CONTRIBUTORS.md](CONTRIBUTORS.md) for the list of
copyright holders.

All product names, logos, brands, trademarks, and registered trademarks are
property of their respective owners. Company, product, and service names used
in this repository are for identification purposes only and do not imply
endorsement.
