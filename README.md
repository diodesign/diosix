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

* **Symmetric VM tree:** Every VM boots from the same unified Alpine-based
  `diosix-node.elf` image with identical hypervisor ABIs and `dsx` tooling.
  The initial top-level VM starts with `parent: hypervisor`, full system quota,
  and inheritable hardware trust, then partitions resources down the tree.
* **Anti-collusion isolation and boards:** M-mode blocks lateral sibling
  network frames, sockets, and whispers, so agents coordinate strictly along
  parent-child edges through parent-moderated `dsx board` message boards.
* **Recursive package attenuation:** Children lack direct internet access by
  default and install Alpine packages recursively from their parent via
  `dsx pkg`, bounded monotonically by manifest allow and deny lists.
* **Mixed RISC-V execution:** Native 64-bit RISC-V guests boot from ELF
  kernels, flat kernel images, installer ISOs, or seeded virtual disks, and
  single-core 32-bit RISC-V guests run via dynamic binary recompilation.
* **Headless editions and C/Zig SDK:** Build **Diosix Core**
  (`-Dedition=core`), **Diosix Swarm** (`-Dedition=swarm`), or **Diosix
  Personal** (`-Dedition=personal`), manage guests over SSH and serial consoles
  (or web services hosted inside VMs), and link userland tools against
  `libdiosix`. The legacy `diosix-gui` compositor lives on the `gui` branch.
* **Default-isolated recursive networking:** Each parent runs a `diosix0`
  virtual subnet for direct children (`10.0.3.x`, `10.0.4.x`, and upward) while
  children see an upstream `eth0` interface with SSH passwords disabled and
  outbound access gated by parent firewall rules.
* **Charter governance:** Critical deployments can seal a charter hash and
  quorum policy in M-mode to protect steward VMs, confidential guest memory,
  and standby failover.
* **Principal-signed mission consensus:** Owners sign `charter.toml`
  deployments and runtime `[spec]` updates with Edwards-curve digital
  signature algorithm (Ed25519) keys. Amendments require both a valid principal
  signature and a conserved physical-RAM quota-stake supermajority across the VM
  tree, while machine mode (M-mode) and node agents deterministically veto
  ransomware transitions (such as dropping replicas to zero and encrypting
  volumes).
* **Autonomous agents and thinking gateway:** Nodes run `dsx agent` (with
  optional `diosix-agent-start` root, `sudoer`, or `non-sudoer` startup hygiene)
  against a generic thinking gateway (`POST /v1/infer` on `diosix0:8081` with
  `minimal`, `low`, `medium`, and `high` tiers). Upstream application
  programming interface (API) keys remain strictly on the root VM while parents
  enforce conserved token and micro-USD (`cost_micros_usd`) budgets, M-mode
  contains arbitrary leaf workload VMs (`--leaf`) externally, and children
  authenticate over media access control (MAC)-bound bridges.
* **Multi-host swarm fleet:** Separate hosts collaborate over transmission
  control protocol (TCP) port `8486` (`dsx swarm` or
  `./scripts/build.sh run-swarm`) with Ed25519 peer identities, fleet-wide
  mission dissemination, stake tallying, and deterministic replica sharding.

---

## Quickstart

You can try Diosix in QEMU on Linux either by downloading a prebuilt release
bundle (no compilation required) or by building from source.

### Run a prebuilt release bundle

1. Install QEMU 10.0 or later (`qemu-system-riscv64`) on your Linux machine.
2. Download and unpack an edition release archive (`core`, `swarm`, or
   `personal`) from GitHub Releases and boot it with QEMU's SSH port forwarded
   to host port `2222`:

   ```bash
   tar -xf diosix-26.1-swarm-riscv64.tar.xz
   cd diosix-26.1-swarm-riscv64
   sha256sum -c SHA256SUMS

   # Boot the hypervisor and root VM headless (SSH forwarded on localhost:2222)
   ./run-diosix.sh

   # Or boot straight into an interactive CLI RISC-V VM
   ./run-diosix.sh --cli
   ```

### Build and run from source

1. Install the [build dependencies][build-deps] (Zig 0.17 or later, QEMU 10.0
   or later, and standard Buildroot host packages).

[build-deps]: docs/build.md#build-process-and-dependencies

2. Clone the repository, select an edition (`core`, `swarm`, or `personal`),
   and boot headless in QEMU:

   ```bash
   git clone https://github.com/diodesign/diosix.git
   cd diosix

   # Boot the default swarm edition over headless serial console + SSH :2222
   ./scripts/build.sh run

   # Or build Diosix Core or Diosix Personal and build the C/Zig libdiosix SDK
   ./scripts/build.sh -Dedition=core
   ./scripts/build.sh sdk
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
# 1. Inspect host hardware and running hypervisor state
dsx host info

# 2. Launch an isolated Alpine node child VM with constrained packages
dsx run diosix-node --name worker --vcpus 2 --ram 256M --packages doas
dsx list

# 3. Post to the parent board and install a permitted package over SSH
dsx board post "begin task" --to worker --topic ops
dsx ssh worker -- apk add doas

# 4. Save an in-memory RAM checkpoint of the child VM
dsx snapshot save work-vm clean-boot

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
