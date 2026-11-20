[![Diosix continuous integration][ci-badge]][ci-url]
[![Language: Zig][zig-badge]](https://ziglang.org/)
[![Platform: riscv64][rv64-badge]](https://riscv.org/)

[ci-badge]: https://github.com/diodesign/diosix/actions/workflows/ci.yml/badge.svg
[ci-url]: https://github.com/diodesign/diosix/actions/workflows/ci.yml
[zig-badge]: https://img.shields.io/badge/language-zig-darkorange.svg
[rv64-badge]: https://img.shields.io/badge/platform-riscv64-lightblue.svg

# Diosix

Diosix is a bare-metal type-1 hypervisor written in Zig for multi-core 64-bit
RISC-V systems. It organizes guests into symmetric, hardware-isolated virtual
machine (VM) trees while keeping the machine-mode (M-mode) hypervisor core
small and confining device drivers, filesystems, and network stacks inside
guests.

For an architectural overview, interactive edition comparison, and direct live
media downloads, visit [diosix.org](https://diosix.org).

---

## Quickstart

Boot Diosix immediately using a prebuilt edition archive or compile from source
on Linux (or inside the provided Docker build containers).

### Obtain and run a live image

1. Install QEMU 10.0 or later (`qemu-system-riscv64`).
2. Download one of the three edition archives (`core`, `personal`, or `swarm`)
   from [GitHub Releases][releases], verify its digest, and boot in QEMU or
   flash `diosix-live-riscv64.img` to removable media:

[releases]: https://github.com/diodesign/diosix/releases/latest

   ```bash
   tar -xf diosix-26.1-swarm-riscv64.tar.xz
   cd diosix-26.1-swarm-riscv64
   sha256sum -c SHA256SUMS

   # Run the Emulated / Live QEMU launcher (SSH forwarded on localhost:2222)
   ./run-diosix.sh

   # Or boot directly into an interactive CLI RISC-V VM
   ./run-diosix.sh --cli

   # Or flash the 640 MiB hybrid GPT live image to a USB drive or SD card
   sudo dd if=diosix-live-riscv64.img of=/dev/sdX bs=4M status=progress \
       conv=fsync
   ```

### Fetch and build from source

1. Install the [build dependencies][build-deps] (Zig 0.17 or later, QEMU 10.0
   or later, and standard Buildroot host packages).

[build-deps]: docs/build.md#build-process-and-dependencies

2. Clone the repository, run host unit and feature-graph checks, build your
   chosen edition (`core`, `personal`, or `swarm`), and boot in QEMU:

   ```bash
   git clone https://github.com/diodesign/diosix.git
   cd diosix

   # Verify formatting, unit tests, and feature-to-doc links
   zig fmt --check build.zig build hypervisor tools scripts
   ./scripts/build.sh test --summary all

   # Build and boot the default Swarm edition in Emulated (QEMU) mode
   ./scripts/build.sh run

   # Or target Core / Personal editions, live images, and the C/Zig SDK
   ./scripts/build.sh -Dedition=core
   ./scripts/build.sh run-personal
   ./scripts/build.sh live-image
   ./scripts/build.sh sdk
   ```

If you prefer a reproducible container environment instead of installing host
packages, use the included Dockerfiles:

```bash
git clone https://github.com/diodesign/diosix.git
cd diosix

docker build -f dockerfiles/ubuntu-26.04.Dockerfile -t diosix-ubuntu .
docker run -it --rm diosix-ubuntu ./scripts/build.sh run
```

### Editions and boot modes

Diosix separates **what role the system runs** (edition) from **how the host
boots** (boot mode):

| Boot mode | Kernel flag | Storage and provisioning lifecycle | Core | Personal | Swarm |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Emulated** | `diosix.mode=dev` | QEMU evaluation with developer SSH keys and host-backed `storage.img` | Sandboxed VMs over SSH | `dsx personal` desktop swaps | Parent boards, thinking gateway, peer tests |
| **Live** | `diosix.mode=live` | Removable media running in RAM (run `dsx host install` to provision disks) | Live appliance recovery | Hardware discovery & desktop install | Live multi-host onboarding |
| **Installed** | `diosix.mode=persistent` | Post-install disk boot (`DIOSIX_BOOT` A/B, `DIOSIX_STATE`, `DIOSIX_DATA`) | Embedded or single-host hypervisor | `personal.toml` & `auto_start` desktop | Persistent autonomous fleet nodes |
| **Diskless** | `diosix.mode=diskless` | Stateless RAM netboot over HTTP from a boot server (no local disk writes) | Stateless embedded hardware tests | Diskless hardware passthrough tests | Ephemeral cluster & hardware-lab workers |

See [Diosix editions](docs/editions.md) and
[Getting started and running Diosix](docs/run.md) for full details.

### First commands to try inside Diosix

When QEMU finishes booting in Emulated (`dev`) mode, log in to the root VM as
`root` (or connect via `ssh -p 2222 root@127.0.0.1` with your staged host SSH
key) and inspect the tree with `dsx`:

```bash
# 1. Inspect host hardware and running hypervisor state
dsx host info

# 2. Launch an isolated Alpine node child VM with constrained packages
dsx run diosix-node --name worker --vcpus 2 --ram 256M --packages doas
dsx list

# 3. Post to the parent board and install a permitted package over SSH
dsx board post "begin task" --to worker --topic ops
dsx ssh worker -- apk add doas

# 4. Save an in-memory RAM checkpoint of the child VM
dsx snapshot save worker clean-boot

# 5. Browse SHA-256-verified guest images in the catalog
dsx image catalog

# 6. Inspect autonomous agent and multi-host swarm tools
dsx agent status
dsx swarm status
```

In a headless QEMU terminal session, press `Ctrl-a` then `x` to exit QEMU, or
press `Ctrl-a` then `c` to switch to and from the QEMU monitor.

Here is a terminal recording ([play the local cast](docs/diosix-demo.cast) with
`asciinema play docs/diosix-demo.cast`) showing Diosix booting and managing
guest VMs, quotas, and snapshots:

[![asciicast of Diosix running](https://asciinema.org/a/1214657.svg)](https://asciinema.org/a/1214657)

---

## What makes Diosix different

Every VM runs with the same structural interfaces: it reads its device tree for
virtual hardware and its manifest for role bounds, addresses its immediate
parent as context ID (CID) `0`, itself as `CID 1`, and direct children as
`CID 2..N`, and delegates slices of its own CPU and RAM quota downward. Child
subtrees remain opaque to ancestors.

```text
M-mode Hypervisor (Stage-2 / PMP isolation, quotas, L2 virtual switch)
 `-- Top-level VM (CID 1, parent: hypervisor, initial hardware passthrough)
      |-- Child VM (CID 2 to parent -> sees self as CID 1, parent as CID 0)
      |    `-- Grandchild VM (opaque to grandparents; own nested switch)
      `-- Child VM (CID 3 to parent -> sees self as CID 1, parent as CID 0)
```

* Every VM boots from the same unified Alpine-based `diosix-node.elf` image with
  identical hypervisor application binary interfaces (ABIs) and `dsx` tooling,
  partitioning full system physical memory protection (PMP) or Stage-2 quotas
  and layer-2 (L2) virtual switching down the hierarchy.
* Machine mode (M-mode) blocks lateral sibling network frames, sockets, and
  whispers, so autonomous agents coordinate strictly along parent-child edges
  through parent-moderated `dsx board` message boards.
* Child VMs start without internet access by default and install Alpine
  packages recursively from their immediate parent via `dsx pkg`, attenuated
  monotonically by manifest allow and deny lists.
* Native 64-bit RISC-V guests boot from ELF kernels, flat kernel images,
  installer ISOs, or seeded virtual disks, while single-core 32-bit RISC-V
  guests execute via dynamic binary recompilation.
* **Diosix Core** (`-Dedition=core`), **Diosix Swarm** (`-Dedition=swarm`), and
  **Diosix Personal** (`-Dedition=personal`) share a headless M-mode core
  managed over SSH and serial consoles alongside the C99 and Zig `libdiosix`
  software development kit (SDK). Personal adds scoped host hardware
  passthrough with contiguous direct memory access (DMA) allocation and physical
  interrupt forwarding gated on explicit DMA trust when no input-output memory
  management unit (IOMMU) is present; the legacy `diosix-gui` compositor lives
  on the `gui` branch.
* Each parent runs an isolated `diosix0` virtual switch (`10.0.3.x`, `10.0.4.x`,
  and upward) with passwordless SSH key distribution, private-key isolation,
  and parent-gated firewall policies.
* Operators seal `charter.toml` deployments and runtime `[spec]` updates with
  Edwards-curve digital signature algorithm (Ed25519) principal keys. Runtime
  amendments require both a valid principal signature and conserved
  physical-RAM quota-stake supermajority approval, while M-mode and node agents
  deterministically veto ransomware transitions such as zero-replica step-downs
  or unratified volume encryption.
* Nodes run `dsx agent` against a generic thinking gateway (`POST /v1/infer` on
  `diosix0:8081`) that isolates upstream application programming interface (API)
  keys strictly inside the root VM while parents enforce conserved token and
  micro-USD budgets over media access control (MAC)-authenticated links.
* Separate hosts collaborate over transmission control protocol (TCP) port
  `8486` (`dsx swarm`) with Ed25519 peer identities, fleet-wide mission
  dissemination, stake tallying, and deterministic replica sharding.

---

## Documentation

Documentation is split into two tracks depending on what you want to do:

### User guides

| Guide | What it covers |
| :--- | :--- |
| [Diosix editions](docs/editions.md) | SSH-first workflows and choosing between Diosix Core, Diosix Swarm, and Diosix Personal editions. |
| [Getting started and running Diosix](docs/run.md) | Booting in QEMU, managing hosts and guests over SSH, running diskless and Shelly hardware-in-the-loop (HIL) tests, and provisioning target disks. |
| [Deploying and provisioning guest VMs](docs/guests.md) | Running built-in sandboxes, booting installer ISOs, seeding disk images, booting custom kernels, and managing quotas and RAM checkpoints. |
| [Security, networking, and governance](docs/security.md) | Default guest network isolation, chaining VMs through a firewall VM, DMA passthrough security, managing SSH passkeys, Principal-signed Mission consensus, and sealing a charter. |
| [CLI and configuration reference](docs/cli.md) | Full command reference for `dsx` (including `agent`, `swarm`, `charter`, `pkg`, and `board`) and runtime configuration files in `/etc/diosix/`. |

### Technical reference

| Reference | What it covers |
| :--- | :--- |
| [Hypervisor architecture](docs/architecture.md) | Design rationale behind the symmetric self-organizing VM tree, M-mode resource model, headless VirtIO devices, dynamic recompilation, multi-host swarm collaboration, and standby failover. |
| [Shared interface and ABI](docs/interface.md) | Supervisor binary interface (SBI) hypercalls, C and Zig `libdiosix` API, Linux kernel driver calls, and the virtual MMIO bus map. |
| [Feature support matrix](docs/support-matrix.md) | Generated map of every hypervisor, emulation, kernel driver, CLI, SDK, and build feature alongside its source files, callers, and documentation links. |
| [Build system, porting, and debugging](docs/build.md) | Build pipeline caching, declarative layout manifests, position-independent M-mode bootstrap, physical board and network deployment, and GNU debugger (GDB) remote debugging. |
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
