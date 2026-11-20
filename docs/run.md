# Getting started and running Diosix

When Diosix boots, the machine-mode (M-mode) hypervisor sets up hardware memory
and CPU isolation and starts a privileged Linux virtual machine (VM) called the
root VM. From the root VM, you launch and manage isolated child VMs over SSH
and the serial console (while guests needing user interfaces serve web or
network services over the virtual switch).

This guide walks through booting Diosix in QEMU, connecting over SSH, and
provisioning a target disk.

---

## System requirements

* Physical target hardware or an emulator must provide a 64-bit RISC-V
  processor with either the RISC-V hypervisor (H) extension or physical memory
  protection (PMP), plus at least 256 MiB of RAM (512 MiB or more is
  recommended when running child VMs).
* Emulated runs require QEMU 10.0 or later. On Debian or Ubuntu, install it
  with `sudo apt install -y qemu-system-misc`; on Fedora, run
  `sudo dnf install -y qemu-system-riscv`.

---

## Booting Diosix in QEMU

### Running a prebuilt release bundle

If you downloaded an edition archive such as
`diosix-26.1-swarm-riscv64.tar.xz` (`core`, `swarm`, or `personal`) from GitHub
Releases, unpack it and run `run-diosix.sh` directly without installing any
compiler or Buildroot packages:

```bash
tar -xf diosix-26.1-swarm-riscv64.tar.xz
cd diosix-26.1-swarm-riscv64
sha256sum -c SHA256SUMS

# Boot the hypervisor and root VM headless (SSH forwarded on localhost:2222)
./run-diosix.sh

# Or boot straight into an interactive CLI RISC-V VM
./run-diosix.sh --cli
```

### Building and booting from source

Once you have the [build dependencies](build.md#build-process-and-dependencies)
installed (or are inside one of the Docker containers in `dockerfiles/`), run
`./scripts/build.sh` to compile and boot Diosix:

```bash
# Boot headless serial console with SSH forwarded on host port 2222
./scripts/build.sh run

# Select a different edition before building or booting (core|swarm|personal)
./scripts/build.sh -Dedition=core

# Boot two networked QEMU hosts for multi-host swarm collaboration
./scripts/build.sh run-swarm

# Optionally build and boot the standalone CLI demo VM
./scripts/build.sh run-cli
```

### How boot modes work

Diosix adjusts its startup behavior across four boot modes (`diosix.mode=`),
three editions (`/etc/diosix/edition`), and runtime kernel command-line flags:

| Boot mode | Kernel flag | Root & storage lifecycle |
| :--- | :--- | :--- |
| **Emulated** | `diosix.mode=dev` | Stages your build machine's SSH public keys into a temporary overlay and mounts `zig-out/storage.img` read-write for immediate QEMU SSH access on port `2222`. |
| **Live** | `diosix.mode=live` | Copies pre-loaded guest images into a 768 MiB RAM-backed filesystem and leaves physical disks unmounted so you can run `dsx host install`. |
| **Installed** | `diosix.mode=persistent` | Mounts the ext4 `DIOSIX_DATA` and `DIOSIX_STATE` volumes read-write to retain SSH keys, guest images, virtual disks, `/var/lib/diosix/state/edition`, and `/var/lib/diosix/etc/personal.toml` across reboots. |
| **Diskless** | `diosix.mode=diskless` | Stages verified payloads into `tmpfs` over HTTP from a Trivial File Transfer Protocol (TFTP) or HTTP boot server without touching local storage. |

* Installing onto storage (`dsx host install`) transitions a **Live** host to
  **Installed**, partitioning the target disk and writing the persistent edition
  override and Personal profile configuration.
* Selecting `Diosix Swarm` (`-Dedition=swarm`) or passing `diosix.swarm=1` or
  `diosix.swarm_ip=<cidr>` activates the parent message board (`diosix0:8485`),
  large language model (LLM) proxy (`diosix0:8081`), `dsx agent`, and
  multi-host `dsx swarm` daemons alongside optional `diosix.swarm_peers=` and
  `diosix.agent_mode=<off|root|sudoer|non-sudoer>` flags.
* Passing `diosix.demo=cli` spawns the built-in interactive CLI VM at boot and
  attaches directly to its serial console.

To try the 640 MiB hybrid GPT live image in QEMU:

```bash
# Headless serial live session with SSH forwarded on port 2222
./scripts/build.sh run-live
```

Building the live image with `./scripts/build.sh live-image` also generates a
standalone launcher script so you can re-run the packaged image without
invoking the build system:

```bash
./zig-out/run-qemu.sh [--cli] [--ssh-port 2222] [--smp 4] [--mem 2G] \
    [--mode live|install|persistent|dev]
```

### Controlling QEMU from your terminal

In headless serial mode, press `Ctrl-a` then `x` to exit QEMU, or press
`Ctrl-a` then `c` to switch to the QEMU monitor (press `Ctrl-a` then `c` again
to return to the Diosix console).

---

## Managing hosts and guests over SSH

Mainline Diosix runs headless so the hypervisor and root VM expose only a
minimal control surface:

```bash
# Connect from your host machine once QEMU boots in developer mode
ssh -p 2222 root@127.0.0.1

# Inspect host telemetry and launch a child node VM
dsx host info
dsx run diosix-node --name worker --vcpus 2 --ram 256M

# Jump into the child over SSH or run a single remote command
dsx ssh worker -- apk info
```

Any guest VM requiring a user interface can bind a web server or remote service
inside its own isolated virtual network (`10.0.3.x`), and `dsx port` / parent
routing policies control which ports reach the host LAN. Teams needing the
legacy local VirtIO-GPU compositor (`diosix-gui`) can check out the `gui`
branch (`git checkout gui`).

---

## Provisioning a target disk

From a live session, `dsx host install` partitions an NVMe, VirtIO, or SATA
disk with GPT boot, state, and data partitions and initializes the persistent
data volume. To flash a bootable standalone image onto raw media for physical
boards, see [Booting on physical RISC-V boards][phys-boards].

[phys-boards]: build.md#booting-on-physical-risc-v-boards

1. Preview the planned partition layout without modifying the disk:

   ```bash
   dsx host install --mode basic --disk /dev/vda --dry-run
   ```

2. Apply the partition layout and data-volume setup interactively or from an
   installation manifest:

   ```bash
   dsx host install --mode basic --disk /dev/vda --hostname my-diosix-host
   dsx host install --mode basic --disk /dev/vda --edition personal \
       --personal-image /var/lib/diosix/images/desktop.img --dma-trusted \
       --auto-start
   dsx host install --mode expert --config /etc/diosix/install.toml --json
   ```

---

## Running diskless and hardware-lab tests

Diskless boot keeps all guest storage in RAM so physical RISC-V boards can run
automated test cycles without writing to local flash or SD cards. Pass these
kernel command-line parameters from the bootloader or flattened device tree
(FDT) `/chosen/bootargs`:

* `diosix.mode=diskless`: Mounts `/var/lib/diosix` purely on `tmpfs` without
  formatting or touching local block devices.
* `diosix.boot_server=http://<host>:8090`: Instructs
  `/usr/sbin/diosix-stage-storage` to download `SHA256SUMS`, strictly verify
  payload digests, and stage `images/diosix-node.elf` into RAM before booting
  children or serving upstream Alpine packages from `${BOOT_SERVER}/apk`.
* `diosix.dev_keys=1`: Opts in to staging development Secure Shell (SSH) keys
  (`keys/dev_authorized_keys`) from the boot server for unattended test runs.

For Raspberry Pi and Shelly smart-plug hardware-in-the-loop (HIL) labs:

1. Copy [`scripts/hil/lab.example.toml`](../scripts/hil/lab.example.toml) and
   fill in each board's serial device, build flags, and Shelly Gen1/Gen2+ plug
   IP address or hostnames.
2. Start or run the orchestrator (or verify the full workflow in QEMU without
   block devices using `--self-test`):

   ```bash
   python3 -B scripts/hil/runner.py --self-test
   python3 -B scripts/hil/runner.py --config lab.toml --board spacemit-k3
   ```

---

## Next steps

* [Deploying and provisioning guest VMs](guests.md) covers launching quick
  sandboxes, booting installer ISOs, seeding disk images, booting custom
  kernels, and managing quotas.
* [Security, networking, and governance](security.md) covers guest network
  modes, chaining VMs through a firewall VM, enrolling SSH passkeys, and
  sealing a charter.
* [CLI and configuration reference](cli.md) documents every command, flag, and
  runtime configuration file.
