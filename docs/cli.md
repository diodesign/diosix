# Diosix command-line interface

The `dsx` command (also installed as `diosix-ctl`) manages virtual machines
(VMs), virtual disks, guest images, networking, passkeys, and charter
governance on the Diosix machine-mode (M-mode) hypervisor.

Running `dsx` requires root privileges inside the guest OS. For task-based
walkthroughs and background on why each feature works the way it does, see
[Deploying and provisioning guest VMs](guests.md) and
[Security, networking, and governance](security.md).

---

## Runtime configuration files and permissions

Diosix keeps runtime policy and tunable defaults in `/etc/diosix` and
`/var/lib/diosix` rather than hardcoding them into binaries. For build-time
configuration files, see [Build system, porting, and debugging](build.md).

| File | Permissions | Purpose |
| :--- | :--- | :--- |
| `/etc/diosix/diosix.toml` | `0644` | Default child VM sizing, repository paths, and guided tour steps. |
| `/etc/diosix/catalog.toml` | `0644` | Guest OS and steward VM repository catalog with pinned 64-character SHA-256 digests. |
| `/etc/diosix/install.toml` | `0644` | Default disk installation profile for expert provisioning. |
| `/etc/diosix/charter.toml` | `0644` | Charter defining steward quorum thresholds, workload units, and isolation rules. |
| `/etc/diosix/agent.toml` | `0644` | Default provider, model, polling interval, and local proxy port for `dsx agent`. |
| `/etc/diosix/constitution.md` | `0644` | Human- and steward-readable charter rules and operating invariants. |
| `/etc/diosix/system.toml` | `0644` | Declarative multi-domain topology and service routing policy. |
| `/var/lib/diosix/keys/` | `0700` | Enrolled operator passkeys and internal management keys (files stored with mode 0600). |

---

## Context ID syntax

Commands accepting a `<cid>` or `<target>` argument take relative context IDs
(CIDs), friendly VM names, or symbolic aliases:

| Target | Meaning |
| :--- | :--- |
| `self` or `1` | Refers to the calling VM. |
| `parent` or `0` | Refers to the immediate parent VM. |
| `2..N` | Numeric CID of a direct child VM. |
| `<name>` | Friendly domain or VM name assigned when the VM was created. |

---

## Command reference

### `dsx info`
Shows runtime status, hardware trust, architecture, virtual CPU (vCPU) count,
active child count, and quota usage for the current VM, a direct child VM, or
the host.

```bash
dsx info [name|cid|self] [--host|-h] [--json|-j]
```

* `name|cid|self`: Target to inspect (defaults to `self`). Passing a child CID
  or name inspects a direct child VM; querying `parent` (`0`) is denied.
* `--host`, `-h`: Inspects the physical host and M-mode hypervisor (same as
  `dsx host info`).
* `--json`, `-j`: Prints machine-readable JSON output.

Example output for the calling VM (`dsx info`, showing `Parent : CID 0` inside
a child VM and `Parent : hypervisor` at the top level):
```text
Assigned CID   : 1
Parent         : hypervisor
Architecture   : riscv64
Hardware trust : yes
Logical RAM    : 256 MB (65536 pages)
RAM quota pool : 1536 MB total / 512 MB delegated / 1024 MB available
Logical vCPUs  : 4
pCPU quota     : 100% granted / 50% delegated / 50% retained
Child VMs      : 1
```

Example output for a child VM (`dsx info user`):
```text
Name           : user
Context ID     : 2
Status         : running
Hardware trust : untrusted
RAM allocation : 256 MB
Virtual CPUs   : 2
Storage disk   : /var/lib/diosix/disks/user.img
CD-ROM media   : none
IP / Endpoint  : 10.0.3.2
```

---

### `dsx host`
Inspects and manages the physical host, disk installation, and M-mode
hypervisor. Host reset and installation commands are restricted to the top-level
VM whose parent is the hypervisor (aliases: `dsx reboot`, `dsx poweroff`, and
`dsx shutdown`).

```bash
dsx host <info [--json]|install [options]|reboot|poweroff|shutdown>
```

* `host info [--json]`: Shows the hypervisor version and channel, Git commit
  hash, application binary interface (ABI) version, host CPU core count and
  instruction set architecture (ISA), host RAM totals, hypervisor memory
  footprint, and active capability flags. Pass `--json` (`-j`) for JSON output.
* `host install [options]`: Partitions an NVMe, VirtIO, or SATA disk with GPT
  boot, state, and data partitions, initializes `/var/lib/diosix` on the data
  partition, and writes `/var/lib/diosix/install.receipt`.
  * `--mode basic|expert`, `-m <mode>`: Selects the `basic` profile or the
    declarative `expert` profile from `/etc/diosix/install.toml`.
  * `--disk <dev>`, `-d <dev>`: Target block device (defaults to `/dev/vda`;
    accepts `/dev/*`, `/tmp/*`, or `/var/lib/diosix/*` without `..`).
  * `--config <file.toml>`, `-c <file.toml>`: Declarative installation manifest
    (defaults to `/etc/diosix/install.toml` in expert mode).
  * `--hostname <name>`: Hostname recorded in the installation receipt (1 to 64
    RFC-1123 alphanumeric or hyphen characters).
  * `--stewards`: Records steward VM enablement in the receipt.
  * `--standby-root`: Records standby root enablement in the receipt.
  * `--dry-run`: Checks the target disk and planned GPT partition layout
    without writing to disk.
  * `--json`, `-j`: Prints JSON output.
* `host reboot`: Reboots the physical host machine.
* `host poweroff` (or `host shutdown`): Powers off the physical host hardware.

Host info output (`dsx host info`):
```text
Hypervisor build : Version 26.1 (beta) devel/b3d4773 (Zig 0.17.0 riscv64)
Footprint        : 512 KB reserved, 256 KB free
ABI version      : 0.2.0
Host cores       : 4 physical hart(s) RV64GC
Host RAM         : 2048 MB total / 1536 MB free
Timer frequency  : 10000000 Hz
Capabilities     :
  [x] Hardware H-extension (nested virtualization)
  [x] Stage-2 Sv39x4 paging
  [x] Cross-arch JIT dynamic recompilation
  [x] VirtIO-vsock (AF_VSOCK in-hypervisor networking)
  [ ] Constitutional Charter sealed in M-mode
```

> [!NOTE]
> Diosix requires at least 256 MiB of physical host RAM (512 MiB or more is
> recommended when running child VMs). At boot, M-mode allocates one-quarter
> (25%) of host RAM to the initial top-level VM (root VM)—clamped to 128 MiB
> through 512 MiB—and assigns 1 to 4 vCPUs matching the physical core count,
> leaving the remaining host RAM available in the buddy pool for descendant VMs.

---

### `dsx run`
Launches an isolated child VM in the background with private SSH networking,
device tree blob (DTB) generation, and optional manifest staging (alias:
`dsx create`).

```bash
dsx run <image|name> [options]
dsx run --manifest <system.toml> --domain <domain_name> [options]
```

* `image|name`: Name or path of the guest image to boot. Accepts 64-bit or
  32-bit ELF kernels, flat RISC-V Linux or BSD `Image` binaries, self-contained
  portable executable (PE) `.efi` stubs, bootable ISO9660 images, and raw,
  ext4, or FAT32 disk images. Bare names are resolved against the current
  directory and `/var/lib/diosix/images/`.
* `--name <name>`, `-n <name>`: Friendly name for the VM (defaults to the
  domain name or image basename).
* `--vcpus <N>`: Logical vCPUs advertised in the child's DTB (1 to 4,096;
  defaults to 1).
* `--ram <size>`: Logical RAM size advertised in the child's DTB (such as
  `256M` or `2GiB`; must fit within `--ram-quota`).
* `--pcpu <1-90>`, `--pcpu-quota <1-90>`: Physical CPU time percentage
  delegated to the child VM and its subtree (1% to 90%, bounded by the parent's
  available share).
* `--ram-quota <size>`: Physical RAM pool granted to the child VM and its
  subtree (defaults to `--ram`, clamped to at least `--ram`).
* `--disk <name|size>`, `-d <name|size>`: Stages an existing virtual disk by
  name (such as `--disk user-data`), or creates and formats a new ext4 disk up
  to 256 MiB staged into the upper half of child RAM as `/dev/vda`. Newly
  created disks are pre-seeded with the default guest kernel, management SSH
  public key, and NoCloud cloud-init files.
* `--cdrom <iso|path>` (or `--iso <path>`, `--media <path>`): Stages a
  read-only ISO image of up to 256 MiB into child RAM (mutually exclusive with
  `--disk` on a single boot).
* `--initrd <path>` (or `--initramfs <path>`): Stages an external initial RAM
  disk into child guest RAM and records its bounds in the child DTB.
* `--cmdline <args>` (or `--append <args>`, `--bootargs <args>`): Appends
  custom kernel command-line arguments to `/chosen/bootargs` in the child DTB.
* `--ip <address>`: Static private IP address (defaults to the caller's virtual
  subnet, such as `10.0.3.<cid>` at depth 0 or `10.0.<3+depth>.<cid>` in nested
  child VMs).
* `--net <none|local|wan|router>`: Network policy for the child VM (defaults to
  `local`, or inferred from `--domain` capabilities in `system.toml`):
  * `none`: Air-gaps the VM in M-mode so all network transmission and reception
    is rejected.
  * `local`: Enables a host-only management link to the parent VM while
    blocking sibling traffic and wide area network (WAN) internet forwarding.
  * `wan`: Enables outbound WAN network address translation (NAT) forwarding
    through the parent router.
  * `router`: Configures the VM as a layer-3 (L3) routing, filtering, and
    logging middlebox that sibling VMs can chain through with `--net-via` or
    `dsx net route`.
* `--net-via <vm|cid>`: Routes all traffic from this child VM through a
  designated sibling router VM, permitting layer-2 (L2) frames between the two
  VMs while blocking direct WAN bypass and other sibling traffic.
* `--packages <*|none|pkg1,pkg2>`: Restricts Alpine `apk` packages permitted to
  the child VM (`*` for parent's full ceiling, `none`, or a comma-separated
  allowlist), enforced monotonically against the caller's own ceiling.
* `--leaf`: Marks the child as a leaf VM (`RUN_FLAG_LEAF_NO_CHILDREN`, blocking
  nested child creation cleanly at depth zero).
* `--max-children <N>`, `--max-depth <D>`: Sets nested descendant count and
  subtree depth ceilings (`0` locks the limit using `QUOTA_ZERO_SENTINEL`).
* `--delegate-stake` / `--no-stake`: Explicitly grants or withholds
  `VOTE_MISSION` governance stake delegation (`--no-stake` is the default so
  plain workload VMs do not dilute parent stake).
* `--tokens <N>`, `--budget-usd <USD>`, `--max-thinking <tier>`: Allocates a
  conserved child inference allowance and maximum thinking tier (`minimal`,
  `low`, `medium`, or `high`) in the parent's gateway ledger (`0` by default).
* `--agent-mode <off|root|sudoer|non-sudoer>`: Stamps `# diosix-agent-mode:`
  into the child's M-mode manifest for `/usr/sbin/diosix-agent-start --auto`.
* `--domain <name>`: Loads settings and policies for `<name>` from
  `/etc/diosix/system.toml`.
* `--manifest <path>`, `-m <path>`: Path to `system.toml`.
* `--dtb <path>`: Custom base DTB file (defaults to `/sys/firmware/fdt`).
* `--trusted` / `--untrusted`: Grants or withholds physical hardware trust
  (untrusted by default).
* `--steward`: Marks the child VM as a steward VM. Under a sealed charter, the
  parent VM cannot stop or lower the quotas of a steward VM without steward
  quorum ratification.
* `--standby-root`: Marks the child VM as a warm standby root VM eligible for
  M-mode failover promotion.
* `--confidential`: Enables guest memory confidentiality, blocking parent
  foreign memory mappings once a charter is sealed.
* `--arch <arch>`, `-a <arch>`: Guest architecture (`riscv64` or `riscv32`;
  `aarch64` and `x86_64` are recognized and report that cross-architecture
  emulation is not yet enabled).

Examples:
```bash
# Boot a live ISO in RAM
dsx run custom-riscv64.iso --name live-os --vcpus 2 --ram 1024M

# Launch the built-in CLI VM or Weston Wayland desktop VM
dsx run linux-cli --name cli-work --vcpus 2 --ram 256M
dsx run linux-desktop --name desk-work --vcpus 2 --ram 512M

# Launch a sandboxed VM with 2 vCPUs, 512 MiB RAM, and a 128 MiB in-RAM disk
dsx run linux-guest --name user --vcpus 2 --ram 512M --disk 128M

# Launch a trusted driver domain with 1 vCPU and 128 MiB RAM
dsx run linux-guest --name sys-domain --trusted --vcpus 1 --ram 128M

# Boot a flat RISC-V Linux kernel with an external initrd and custom cmdline
dsx run /var/lib/diosix/images/Image \
    --initrd /var/lib/diosix/images/initramfs.cpio \
    --cmdline "root=/dev/vda rw console=hvc0" \
    --disk app-disk \
    --ram 512M

# Launch a domain defined in /etc/diosix/system.toml
dsx run --manifest /etc/diosix/system.toml --domain sys
```

---

### `dsx net`
Inspects and updates per-VM network policies, M-mode air-gap isolation, and
router-VM chaining (alias: `dsx network`).

```bash
dsx net status
dsx net grant <vm|cid> [none|local|wan|router]
dsx net revoke <vm|cid>
dsx net isolate <vm|cid>
dsx net route <vm|cid> --via <router-vm|cid|root>
```

* `status` (or `list`): Lists each active child VM's CID, name, IP, mode
  (`none`, `local`, `wan`, `router`), upstream gateway, and WAN state.
* `grant <vm|cid> [wan|router|local]`: Grants outbound WAN access (`wan` by
  default) or router role (`router`) to a running child VM.
* `revoke <vm|cid>`: Revokes WAN access from `<vm|cid>`, returning it to
  `local` (parent SSH only).
* `isolate <vm|cid>`: Air-gaps `<vm|cid>` in M-mode, blocking all packet
  transmission and reception.
* `route <vm|cid> --via <router-vm|cid|root>`: Chains `<vm|cid>`'s network
  traffic through `<router-vm>` or restores direct parent routing
  (`--via root`).

---

### `dsx list`
Lists the calling VM (`self`, CID 1) and its direct child VMs as a one-level
tree with their CIDs, vCPU counts, RAM allocations, status, trust level, and IP
endpoints (aliases: `dsx ps`, `dsx ls`). Because child subtrees remain opaque,
nested grandchildren appear only inside the child's own local view.

```bash
dsx list
dsx ps
dsx ls
```

Example output:
```text
CID  Name                 vCPUs  RAM      Status   Trust     IP / Endpoint
1    diosix-rootvm (self) 4      256 MB   running  trusted   local (hypervisor)
2    ├─ sys-domain        1      128 MB   running  trusted   10.0.3.2
3    └─ user              2      256 MB   running  untrusted 10.0.3.3

Note: child subtrees are opaque; only direct children are visible.
```

---

### `dsx ssh`
Opens an interactive shell or runs a command inside a child VM over SSH using
the parent's Ed25519 management keypair, with only the public key staged inside
the child (aliases: `dsx login`, `dsx exec`).

```bash
dsx ssh [user@]<name|cid> [-- [command...]]
dsx ssh [--user <username>] <name|cid> [-- [command...]]
```

* `[user@]target`: Remote username (defaults to `root`) and target child VM
  name or CID.
* `--user <username>`, `-u <username>`: Specifies the SSH login account.
* `-- [command...]`: Command to run non-interactively.

Examples:
```bash
# Open an interactive root shell on child VM 'user'
dsx ssh user

# Log in as 'debian' on child VM 'user'
dsx ssh debian@user

# Run a command non-interactively
dsx ssh debian@user -- uname -a

# Connect to child VM 2 by CID
dsx ssh root@2 -- cat /etc/os-release
```

---

### `dsx console`
Attaches to a child VM's hypervisor serial console, streaming buffered boot
logs and bidirectional supervisor binary interface (SBI) console input/output
(I/O) alongside transmit output from the emulated 16550A universal asynchronous
receiver-transmitter (UART), even when a guest has no network interface or SSH
server.

```bash
dsx console <name|cid> [--dump|-d]
```

* `<name|cid>`: Friendly name or CID (2 or higher) of a direct child VM.
* `--dump`, `-d`: Prints all buffered output from the child VM's 8 KiB M-mode
  transmit ring and exits without opening an interactive session.

In interactive mode, press `Ctrl+]` to detach and return to the parent shell
without stopping the child VM.

Examples:
```bash
# Attach interactively to child VM 'new-guest' (press Ctrl+] to detach)
dsx console new-guest

# Print buffered kernel boot messages from child CID 2 and exit
dsx console 2 --dump
```

---

### `dsx stop`
Stops a running guest VM and all of its descendants, returning their physical
RAM pages and CPU quotas to the parent VM (aliases: `dsx kill`,
`dsx terminate`).

```bash
dsx stop <name|cid|self>
dsx kill <name|cid|self>
dsx terminate <name|cid|self>
```

* `name|cid`: Direct child VM to stop.
* `self`: Stops the calling child VM (denied at the top-level VM whose parent is
  the hypervisor; use `dsx host poweroff` instead).

Examples:
```bash
# Stop child VM 'user'
dsx stop user

# Stop child VM 3
dsx kill 3

# Stop the calling child VM from inside itself
dsx stop self
```

---

### `dsx restart`
Stops a running child VM and boots it again using the image, vCPU count, RAM
size, attached media, IP address, and hardware trust flag recorded in
`/run/diosix/guests.toml`.

```bash
dsx restart <name|cid>
```

Example:
```bash
dsx restart user
```

---

### `dsx quota`
Inspects or updates physical resource quotas on a direct child VM or lowers
quotas on the calling VM (`self`). Called without flags, it prints current RAM
pools, physical CPU percentages, and logical limits.

```bash
dsx quota [cid|self] [--pcpu <1-99>] [--retained-pcpu <1-99>] [--ram <MB>] \
    [--vcpus <N>] [--depth <N>] [--descendants <N>]
```

* `cid|self`: Target VM to inspect or update (defaults to `self`).
* `--pcpu <1-99>`: Sets physical CPU time percentage granted to a direct child
  VM (1% to 99%, within the parent's available pool).
* `--retained-pcpu <1-99>`: On the calling VM (`self`), sets the physical CPU
  percentage kept for itself (1% to 99%, 10% by default), leaving the
  remainder available for children.
* `--ram <MB>`: Updates the physical RAM quota pool in megabytes. Lowering a
  running child VM's pool below its currently faulted pages triggers an
  out-of-memory (OOM) stop of that child.
* `--vcpus <N>`: Sets the logical vCPU ceiling (1 to 4,096).
* `--depth <N>`: Sets maximum child nesting depth (`0` locks to zero via
  `QUOTA_ZERO_SENTINEL`).
* `--descendants <N>`: Sets maximum descendant VM count (`0` locks to zero via
  `QUOTA_ZERO_SENTINEL`).

Passing `self` lets a VM permanently lower its own quotas before running
untrusted workloads.

Examples:
```bash
# View current quotas, free RAM pool, and pCPU delegation
dsx quota

# Grant child VM 2 50% of parent pCPU time and a 512 MB RAM pool
dsx quota 2 --pcpu 50 --ram 512

# Lower the calling VM's own RAM pool to 256 MB
dsx quota self --ram 256
```

---

### `dsx manifest`
Inspects, validates, prunes, and stages capability manifests (top-level alias
for service lookup: `dsx resolve`).

```bash
dsx manifest <subcmd> [options]
dsx resolve <service_alias> [--manifest <file.toml>]
```

Subcommands:
* `show [--file <path>] [--hv] [--cid <cid>]`: Prints the manifest from
  `/etc/diosix/system.toml`, a file path, or hypervisor memory (`--hv`).
* `validate <file.toml>`: Checks manifest syntax and capability rules.
* `prune <system.toml> --domain <name> [-o <out.toml>]`: Generates a pruned
  child manifest containing only the routes `<name>` is allowed to require.
* `resolve <service_alias> [--manifest <file.toml>]` (or `dsx resolve`):
  Resolves a service alias to its target CID and transport route.
* `set <cid> <file.toml>`: Stages a manifest in hypervisor memory for `<cid>`.

Examples:
```bash
# Validate the system manifest
dsx manifest validate /etc/diosix/system.toml

# Prune the manifest for child domain 'sys'
dsx manifest prune /etc/diosix/system.toml --domain sys -o /tmp/sys-child.toml

# Stage the pruned manifest for child VM 2
dsx manifest set 2 /tmp/sys-child.toml

# Resolve a service alias
dsx resolve gui.display -m /tmp/user-child.toml
```

---

### `dsx disk`
Manages persistent virtual disk images in `/var/lib/diosix/disks/` (alias:
`dsx storage`). When passed to `dsx run --disk`, disks up to 256 MiB are staged
into the upper half of child RAM and exposed as `/dev/vda`.

```bash
dsx disk <subcmd> [options]
```

Subcommands:
* `create <name> [--size <size>]`: Creates an ext4 virtual disk image (defaults
  to `1GiB`) and seeds the default guest kernel, management SSH public key, and
  NoCloud cloud-init files.
* `seed <name> [--hostname <name>] [--ip <ip>] [--pubkey <file>]` (alias:
  `provision`): Mounts an unattached virtual disk image and writes
  `/root/.ssh/authorized_keys`, `/etc/hostname`, `/etc/network/interfaces`, and
  NoCloud cloud-init seed files so distribution images boot ready for
  `dsx ssh`.
* `list` (or `ls`): Lists virtual disks with their size, format, attached VM,
  and file path.
* `info <name>`: Shows format, capacity, path, and attachment state for a disk.
* `delete <name>` (or `rm`): Deletes an unattached disk image (refuses to
  delete disks currently attached to a running VM).
* `resize <name> --size <size>`: Resizes a disk image.

Examples:
```bash
# Create a 128 MiB ext4 virtual disk ready for dsx run --disk
dsx disk create user-data --size 128M

# Seed SSH keys, hostname, static IP, and cloud-init onto a guest disk
dsx disk seed debian-root --hostname debian-vm --ip 10.0.3.2

# List virtual disks and attached VMs
dsx disk list

# Inspect a disk
dsx disk info user-data

# Resize a disk to 256 MiB
dsx disk resize user-data --size 256M

# Delete an unattached disk
dsx disk delete user-data
```

---

### `dsx snapshot`
Saves, lists, restores, and deletes live child RAM checkpoints (up to 64 MiB)
and quota metadata in `/var/lib/diosix/snapshots/`.

```bash
dsx snapshot <subcmd> [options]
```

Subcommands:
* `save <name|cid> [snap_id]` (alias: `create`): Saves up to 64 MiB of a
  running child VM's RAM pages and quota metadata.
* `list [--json]` (or `ls`): Lists saved snapshots and their target VMs.
* `restore [vm] <snap_id>`: Restores saved RAM pages and quota limits onto the
  matching child VM.
* `delete [vm] <snap_id>` (or `rm`): Deletes `<snap_id>` and its saved memory
  image.

Examples:
```bash
dsx snapshot save user backup-1
dsx snapshot list --json
dsx snapshot restore user backup-1
dsx snapshot delete user backup-1
```

---

### `dsx image`
Manages guest OS kernels and steward images in `/var/lib/diosix/images/` and
installer ISOs in `/var/lib/diosix/iso/` (alias: `dsx iso`).

```bash
dsx image <subcmd> [options]
```

Subcommands:
* `list [--remote] [--json]` (or `ls`): Lists local kernels, steward images,
  and ISOs with their tier, OS family, and format. Pass `--remote` (`-r`) to
  include remote catalog entries.
* `catalog [--json]`: Lists entries from `/etc/diosix/catalog.toml` (or the
  built-in catalog if absent), including distribution ISOs and the steward VM
  image. You can add custom mirror entries to `/etc/diosix/catalog.toml`.
* `pull <catalog-id|url> [--name <name>] [--sha256 <hex>]`
  `[--allow-unverified] [--json]` (or `fetch`): Downloads an image by catalog
  ID or from an `https://`, `http://`, or `file://` URL. Catalog pulls verify
  the downloaded file against the pinned SHA-256 digest in
  `/etc/diosix/catalog.toml` and reject mismatches; direct URL pulls require
  `--sha256 <hex>` unless `--allow-unverified` is passed explicitly.
* `import <file> [--name <name>]` (or `add`): Copies a local ISO or kernel into
  the image repository.
* `verify <name> [--sha256 <hex>] [--json]`: Computes the SHA-256 digest of a
  local image or ISO and verifies it against `--sha256` or its catalog entry.
* `delete <name>` (or `rm`): Removes an image or ISO from the repository.

Examples:
```bash
# Browse the catalog (/etc/diosix/catalog.toml)
dsx image catalog

# Pull the steward VM image (verifies pinned SHA-256)
dsx image pull steward

# Pull the FreeBSD RISC-V installer ISO
dsx image pull freebsd-riscv64

# Pull from a custom URL with SHA-256 verification
dsx image pull https://mirror.example.org/diosix/custom-kernel.elf \
    --name custom.elf \
    --sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

# Import and verify a local ISO
dsx image import debian-12.0-riscv64-netinst.iso --name debian-12.iso
dsx image verify debian-12.iso

# List and delete local images
dsx image list
dsx image delete debian-12.iso
```

---

### `dsx install-guest`
Downloads and verifies an installer ISO (up to 256 MiB), creates a virtual disk
in `/var/lib/diosix/disks/`, and boots the OS installer in RAM through the
supervisor-mode (S-mode) guest bootloader shim.

```bash
dsx install-guest <os-name|iso> [--name <vm>] [--disk <disk>] \
    [--size <size>] [--vcpus <N>] [--ram <size>]
```

* `os-name|iso`: Catalog ID or alias (such as `alpine-riscv64` or `freebsd`) or
  path/name of an `.iso` image up to 256 MiB.
* `--name <vm>`: Friendly name for the guest VM.
* `--disk <disk>`: Target disk name in `/var/lib/diosix/disks/` (created if
  absent).
* `--size <size>`: Target disk size (defaults to catalog size or `4GiB`).
* `--vcpus <N>`: vCPU count (defaults to catalog count or 2).
* `--ram <size>`: Logical RAM size (defaults to catalog size or `1024M`).

Because each boot stages a single 256 MiB media slot in child RAM, stop the
installer VM after installation (`dsx stop <vm>`) and launch the installed disk
directly with `dsx run guest-shim --name <vm> --disk <disk>`.

Examples:
```bash
dsx install-guest alpine-riscv64 --disk alpine-root --size 256M --ram 512M
dsx stop alpine
dsx run guest-shim --name alpine --disk alpine-root --ram 512M
```

---

### `dsx auth`
Manages passkey login, fast identity online 2 (FIDO2) and trusted platform
module (TPM) 2.0 hardware-seeded keys, QR WebAuthn pairing URIs, and serial
challenge-response verification (alias: `dsx passkey`).

```bash
dsx auth <subcmd> [options]
dsx passkey <subcmd> [options]
```

Subcommands:
* `status [--json]`: Shows authentication status, boot mode, seat profile,
  attached FIDO2 USB tokens, TPM 2.0 presence, and enrolled passkey count.
* `list [--json]` (or `ls`): Lists enrolled passkeys in
  `/var/lib/diosix/keys/authorized_passkeys` with their kind, key type, SHA-256
  fingerprint, and label.
* `enroll [--key <pubkey>|--file <path>|--tpm|--fido2|--qr] [--label <name>]`
  `[--json]`:
  * `--key` / `--file`: Enrolls an OpenSSH or FIDO2 public key into
    `authorized_passkeys` and `/root/.ssh/authorized_keys`.
  * `--tpm` / `--fido2`: Generates an Ed25519 keypair on the local VM seeded
    from `/dev/tpmrm0` or `/dev/hidraw*`, saves the private key in
    `/var/lib/diosix/keys/` with mode 0600, and enrolls the public key.
  * `--qr`: Prints a WebAuthn QR pairing URI containing a fresh 256-bit nonce.
* `revoke <id|fingerprint|label> [--json]` (aliases: `remove`, `rm`): Removes a
  passkey by 1-based index, SHA-256 prefix, or label from both
  `authorized_passkeys` and `/root/.ssh/authorized_keys`.
* `challenge [--json]`: Writes a single-use 256-bit challenge nonce to
  `/run/diosix/auth_challenge.state` for serial challenge-response
  verification.
* `verify <signature-hex> [--challenge <str>] [--json]`: Checks a raw 64-byte
  (128-hex-character) Ed25519 signature against enrolled Ed25519 public keys
  and consumes the challenge nonce so it cannot be replayed.

Examples:
```bash
dsx auth status
dsx auth enroll --file ~/.ssh/id_ed25519_sk.pub --label yubikey-5-nfc
dsx auth enroll --tpm --label platform-tpm
dsx auth enroll --qr
dsx auth challenge
dsx auth verify <128-char-ed25519-signature-hex>
```

---

### `dsx gui`
Queries and drives the local VM's `diosix-gui` desktop environment from scripts
or automated
tests without screen-scraping.

```bash
dsx gui <state|trigger <action>|screenshot [path]> [--json]
```

Subcommands:
* `state [--json]`: Reads `/run/diosix/gui_state.json` and prints the live
  compositor state (resolution, render mode, active pane, on-screen keyboard
  visibility, welcome and guided tour progress, guest count, and window count).
  Falls back to detected seat defaults if the desktop is not running.
* `trigger <action> [--json]`: Writes an action name to `/run/diosix/gui_cmd`:
  `menu.create_vm`, `menu.about`, `menu.status`, `menu.config`, `menu.back`,
  `osk.toggle`, `osk.show`, `osk.hide`, `welcome.open`, `welcome.close`,
  `welcome.try_desktop`, `welcome.try_cli`, `tour.start`, `tour.next`,
  `tour.prev`, or `tour.close`.
* `screenshot [path] [--json]`: Saves a raw framebuffer dump from `/dev/fb0`
  (defaults to `/tmp/diosix-screen.raw`; custom paths must stay under `/tmp/`
  or `/var/lib/diosix/` without `..`).

Examples:
```bash
# Read live compositor state as JSON
dsx gui state --json

# Toggle the on-screen keyboard
dsx gui trigger osk.toggle

# Open the 5-step guided tour window and capture /dev/fb0
dsx gui trigger tour.start
dsx gui screenshot /tmp/diosix-screen.raw
```

---

### `dsx tour`
Prints the 5-step guided tour from `/etc/diosix/diosix.toml` (or built-in
defaults) in the terminal or as JSON.

```bash
dsx tour [--step <1..5>] [--json]
```

* `--step <1..5>`, `-s <1..5>`: Prints a single step (1 for root VM and
  hardware isolation, 2 for passkey security, 3 for the guest OS catalog, 4 for
  steward VMs and charter governance, or 5 for live sessions and disk
  installation). Omit to show all steps.
* `--json`, `-j`: Prints JSON output.

---

### `dsx charter`
Manages `/etc/diosix/charter.toml`, Edwards-curve digital signature algorithm
(Ed25519) principal signing, machine-mode (M-mode) charter and mission sealing,
conserved RAM quota-stake voting, steward quorum ratification votes, whisper
consensus frames, steward resets, and standby root VM failover (alias:
`dsx steward`).

```bash
dsx charter \
    <status|deploy|keygen|sign|verify|disseminate|vote|propose> [options]
dsx charter \
    <ratify|whisper|reset-steward|failover|audit> [options]
```

Subcommands:
* `status [--file <path>] [--json]`: Shows the parsed charter (`[charter]`,
  `[spec]`, and `[invariants]`), SHA-256 digest, Ed25519 principal signature
  state, M-mode seal status, conserved stake tally, quorum settings, minimum
  steward count, standby root flag, and failover epoch.
* `deploy [--file <path>] [--json]` (alias: `seal`): Hashes
  `/etc/diosix/charter.toml`, verifies any attached `[principal]` Ed25519
  signature and `[spec]`/`[invariants]` anti-ransomware checks, and seals the
  charter and mission in M-mode (`SEAL_CHARTER` and `SEAL_MISSION`). Amending
  an already-sealed principal mission requires both a fresh valid Ed25519
  signature and supermajority approval (`>= stake_quorum_pct`, default `67%`)
  across conserved physical RAM stake.
* `keygen [--priv <path>] [--pub <path>] [--json]`: Generates a mode `0600`
  Ed25519 principal keypair (`/etc/diosix/keys/principal.key` and
  `principal.pub` by default).
* `sign [--file <path>] [--key <priv>] [--rotate-from <old_priv>]`
  `[--out <path>] [--json]`: Stamps `[principal]`, computes the canonical
  mission digest, writes the Ed25519 signature into `charter.toml`, and
  optionally chains `previous_signature` when rotating principal keys.
* `verify [--file <path>] [--against <baseline>] [--pubkey <hex>] [--json]`:
  Verifies the attached Ed25519 signature and checks transitions against an
  active baseline charter (rejecting zero-replica drops or unratified volume
  encryption/wipe flags even if validly signed).
* `disseminate [--file <path>] [--port P] [--json]`: Stages
  `/run/diosix/charter-pending.toml` and broadcasts the signed proposal down
  the local `dsx board` on topic `charter` for child VMs to inspect and vote.
* `vote [--file <path>] [--approve|--reject|--auto] [--port P] [--json]`:
  Evaluates the pending proposal (or `--file`), records the caller's conserved
  RAM quota-stake vote in M-mode (`VOTE_MISSION`), and posts a signed vote
  receipt to the parent board.
* `propose <action> [--unit <id>] [--count <N>] [--total <M>] [--quorum]`
  `[--file <path>] [--json]`: Evaluates a proposed action (`amend-charter`,
  `terminate-steward`, `reset-steward`, `root-failover`, `terminate-units`,
  `delete-volume`, `export-volume`, or `enable-wan-egress`) offline against the
  invariants in `charter.toml`.
* `ratify [--target <cid>] [--json]`: Casts a steward ratification vote in
  M-mode. Restricted to steward VMs (CIDs 2 through 63); the top-level VM
  cannot vote.
* `whisper <send|recv> [options] [--json]`: Sends or reads Byzantine
  fault-tolerant (BFT) whisper frames across M-mode steward rings:
  * `send [--to <cid>] [--from <cid>]`
    `[--type <heartbeat|propose|ratify|reset-vote|failover-vote>]`
    `[--payload <str>]`: Sends a whisper frame via M-mode.
  * `recv [--frame <str>]`: Reads the next queued whisper frame from M-mode or
    parses `--frame`.
* `reset-steward <cid> [--json]`: Resets steward VM `<cid>` to its initial
  entry point after steward quorum ratification.
* `failover [--standby <cid>] [--json]`: Promotes a standby root VM to active
  root VM after steward quorum ratification, reparenting surviving child VMs
  without rebooting the host.
* `audit [--file <path>] [--json]`: Confirms `/etc/diosix/charter.toml` exists,
  is sealed in M-mode, and matches the sealed M-mode SHA-256 digest.

Examples:
```bash
dsx charter keygen --priv /tmp/p.key --pub /tmp/p.pub
dsx charter sign --file /etc/diosix/charter.toml --key /tmp/p.key
dsx charter deploy --json
dsx charter vote --auto --json
dsx charter status
```

---

### `dsx pkg`
Inspects and controls the recursive attenuating Alpine Package Keeper (`apk`)
HTTP proxy (`diosix0:8080`, aliases: `dsx package`, `dsx apk`).

```bash
dsx pkg <status|policy|allow|deny|sync|serve> [options]
```

Subcommands:
* `status [--json]`: Shows local proxy daemon status, port (`8080`), upstream
  source, seed/cached `.apk` counts, and the calling VM's package ceiling.
* `policy [<vm|cid|self>] [--json]`: Displays the effective allowlist and
  denylist for `self` or a direct child VM.
* `allow <vm|cid> <*|none|pkg1,pkg2>`: Sets a direct child's package allowlist,
  rejected if it exceeds the parent's own ceiling.
* `deny <vm|cid> <none|pkg1,pkg2>`: Adds explicit package denials to a child VM
  (always merges and preserves parent-level denials).
* `sync [--branch v3.24] [--repo main] [--arch riscv64] [--port P]`: Fetches
  a fresh `APKINDEX.tar.gz` from the upstream parent proxy or Alpine CDN into
  `/var/cache/diosix/pkg/`.
* `serve [--port P] [--daemon]`: Starts the attenuating APK proxy server.

Examples:
```bash
dsx pkg status --json
dsx pkg allow child-sup chrony,doas
dsx pkg deny child-sup chrony
```

---

### `dsx board`
Posts to and reads from the parent-moderated, SHA-256 hash-chained message
board (`diosix0:8485`). Child VMs can only post to `target_cid = 0` (`all` or
`parent`); any attempt by a child VM to message a sibling (`target_cid >= 2`)
fails with HTTP `403 Forbidden`.

```bash
dsx board <post|list|status|policy|serve> [options]
```

Subcommands:
* `post <message> [--topic T] [--to all|parent|vm|cid] [--parent|--local]`
  `[--port P] [--json]`: Appends a message to the board.
* `list [--topic T] [--since <seq>] [--parent|--local] [--port P] [--json]`:
  Lists entries visible to the caller (`target_cid = 0`, addressed to the
  caller, or authored by the caller).
* `status [--parent|--local] [--port P] [--json]`: Queries board count and
  hash-chain verification status.
* `policy [--allow-topics <*|csv>] [--mute <vm|cid>] [--unmute <vm|cid>]`:
  Updates `/run/diosix/board-policy.toml` on the calling parent VM.
* `serve [--port P] [--daemon]`: Runs the local board HTTP server.

Examples:
```bash
dsx board post "boot ready" --topic status --parent
dsx board post "rotate key" --to worker --topic ops
dsx board list --topic ops --json
```

---

### `dsx agent`
Runs and inspects the autonomous node agent and its generic thinking gateway
(`diosix0:8081` and `127.0.0.1:8081`). Provider configuration reads
`/etc/diosix/agent.toml`, root-only secrets (`/var/lib/diosix/keys/llm.secret`),
and environment overrides (`DIOSIX_LLM_PROVIDER`, `DIOSIX_LLM_MODEL`,
`DIOSIX_LLM_BASE_URL`, `OPENROUTER_API_KEY`, `OPENCODE_API_KEY`,
`OPENCODE_BASE_URL`), resolving to OpenRouter, OpenCode, a local server, the
parent gateway (`http://diosix-parent:8081/v1/infer`), or a deterministic policy
brain while conserving tokens and micro-USD (`cost_micros_usd`). Guests can also
launch the daemon with in-guest user hygiene via `/usr/sbin/diosix-agent-start`.

```bash
dsx agent <status|ask|set-key|quota|grant|proxy|step|run> [options]
```

Subcommands:
* `status [--json]`: Shows resolved provider, model, default thinking tier,
  endpoint, and whether the gateway (`:8081`) and agent daemon are running.
* `ask <prompt> [--thinking T] [--max-tokens N] [--format text|json] [--json]`:
  Queries the local or parent thinking gateway (`POST /v1/infer`) using the
  requested thinking level (`minimal`, `low`, `medium`, or `high`) and reports
  exact token and micro-USD usage.
* `set-key --provider <P> [--key <secret>] [--endpoint <url>] [--json]`: Stores
  upstream provider credentials atomically (`0600`) on a root VM; rejected on
  child VMs.
* `quota [<vm|cid|self>] [--json]`: Displays conserved token, micro-USD,
  thinking-tier, and per-minute rate limits (`rpm`, `tpm`) from `GET /v1/quota`
  or the gateway ledger.
* `grant <vm|cid> [--tokens N|+N] [--budget-usd USD|+USD] [--max-thinking T]
  [--rpm N] [--tpm N] [--json]`: Delegates or tops up a direct child VM's token
  and USD budget within the caller's available ceiling and syncs child manifest
  directives.
* `proxy [--port P] [--daemon]`: Starts the HTTP thinking gateway (`POST
  /v1/infer`, `GET /v1/quota`, and legacy `POST /v1/chat/completions`) on
  `127.0.0.1` and `diosix0`, binding direct children via kernel MAC ARP state.
* `step [--json]`: Runs one reconciliation tick: polls charter proposals and
  votes via `VOTE_MISSION`, polls `topic=task` board messages to execute
  bounded actions (`tasks_completed`), and on top-level VMs seals amendments and
  reconciles sharded workload units.
* `run [--interval S] [--daemon]`: Runs `step` continuously every `S` seconds
  (default `5`).

Examples:
```bash
dsx agent set-key --provider openrouter --key sk-or-...
dsx agent grant web-leaf --tokens 4096 --budget-usd 0.05 --max-thinking low
dsx agent ask "verify database replica health" --thinking low --json
dsx agent quota web-leaf --json
/usr/sbin/diosix-agent-start --mode non-sudoer --interval 5
```

---

### `dsx swarm`
Connects peer Diosix hosts into a collaborative multi-host swarm fleet on
transmission control protocol (TCP) port `8486` (`iptables.conf` blocks child VM
access to port `8486` over `diosix0` to preserve strict tree isolation).

```bash
dsx swarm <status|serve|join|propose|sync> [options]
```

Subcommands:
* `status [--json]`: Shows the host's Ed25519 node public key, active charter
  hash, known peers, and live peer count.
* `serve [--port P] [--daemon]`: Starts the TCP peer server (`8486` by default)
  serving Ed25519-signed node state (`GET /v1/swarm/status`), peer handshake and
  charter adoption (`POST /v1/swarm/join`), and fleet proposal dissemination
  (`POST /v1/swarm/propose`).
* `join <ip[:port]> [--json]`: Exchanges signed host identity records with a
  peer host and adopts its sealed `v1` principal-signed charter if the local
  host is not yet sealed.
* `propose --file <toml> [--json]`: Evaluates a signed proposal locally and
  disseminates it across every peer host's board and child tree.
* `sync [--json]`: Refreshes peer liveness and state across the local peer list.

Examples:
```bash
dsx swarm serve --daemon
dsx swarm join 10.0.2.12 --json
dsx swarm propose --file /etc/diosix/charter.toml --json
```

---

### `dsx drop-trust`
Permanently drops hardware trust for the calling VM, unmapping host physical
memory-mapped input/output (MMIO) pages and disabling direct hardware interrupt
routing.

```bash
dsx drop-trust
```
