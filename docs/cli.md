# Diosix command-line interface (`dsx` / `diosix-ctl`)

The `dsx` utility (also available via the `diosix-ctl` symlink) is the primary
command-line interface for managing guest Virtual Machines (VMs) on the Diosix
Type-1 hypervisor. It communicates with the hypervisor kernel through the
`/dev/diosix` character device driver using Supervisor Binary Interface (SBI)
hypercalls.

Running `dsx` requires superuser (`root`) privileges inside the guest operating
system to access the `/dev/diosix` interface.

---

## Configuration files and permissions

Diosix separates implementation mechanisms (compiled into the hypervisor and
`dsx` binaries) from policy and tunable defaults (stored in declarative
configuration files):

| File | Scope | Permissions | Purpose |
| :--- | :--- | :--- | :--- |
| `boot/hypervisor.conf` | Build-time (`scripts/build.sh` -> `build.zig`) | `0644` | M-mode hypervisor hardware sizing defaults (`ROOT_RAM_MIN_MB=128`, `ROOT_RAM_MAX_MB=256`, `ROOT_RAM_HOST_DIVISOR=8`, `ROOT_VCPUS_MAX=4`). |
| `/etc/diosix/diosix.toml` | Runtime (`dsx` / Root VM) | `0644` (`root:root`) | Default child VM sizing (`default_vcpus`, `default_ram`, `default_disk_mb`), repository paths, and Guided Tour steps (`[[tour]]`). |
| `/etc/diosix/catalog.toml` | Runtime (`dsx image` / `dsx install-guest`) | `0644` (`root:root`) | DNF/APT-style Guest OS and Steward VM repository catalog with pinned 64-character SHA-256 digests. |
| `/etc/diosix/install.toml` | Runtime (`dsx host install`) | `0644` (`root:root`) | Default bare-metal installation profile (`mode`, `target_disk`, `boot_part_mb`, `state_part_mb`, `enable_stewards`, `standby_root_vm`). |
| `/etc/diosix/charter.toml` | Runtime (`dsx charter`) | `0644` (`root:root`) | Constitutional Charter defining M-of-N Steward quorum thresholds, workload units, and hardware isolation invariants. |
| `/etc/diosix/constitution.md` | Runtime (`dsx charter`) | `0644` (`root:root`) | Human- and Steward-readable Constitutional invariants and operational rules. |
| `/etc/diosix/system.toml` | Runtime (`dsx manifest` / `dsx run`) | `0644` (`root:root`) | Declarative multi-domain topology and capability routing policy. |
| `/var/lib/diosix/keys/` | Runtime (persistent storage) | `0700` (`root:root`) | Enrolled operator passkeys (`authorized_passkeys`, mode `0600`) and internal cluster management keys (`id_management`, mode `0600`). |

---

## Context ID (CID) syntax

Commands accepting a `<cid>` or `<target>` argument support numeric IDs,
friendly VM names, and symbolic aliases:

*   **`self`** or **`1`**: Refers to the calling Virtual Machine.
*   **`parent`** or **`0`**: Refers to the immediate parent Virtual Machine.
*   **`2..N`**: Numeric Context ID of a direct child Virtual Machine.
*   **`<name>`**: Human-friendly domain or VM name registered at creation
    (for example, `sys`, `user`, or `debian-cloud`).

---

## Command reference

### `dsx info`
Displays status, hardware trust status, architecture, active child count, and
resource quota usage for the current VM or a target guest VM.

```bash
dsx info [name|cid|self] [--json]
```

*   `name|cid|self` *(optional)*: Target VM to inspect. Defaults to `self`
    (Context ID 1). Passing `2..N` or a registered child name queries a direct
    child VM. Querying the parent VM (`parent` or `0`) is strictly denied and
    returns an error.
*   `--json` / `-j` *(optional)*: Emits machine-readable JSON output.

Example output for calling VM (`dsx info`):
```text
Assigned CID   : 1
Architecture   : riscv64
Root VM        : yes
Hardware trust : yes
RAM allocation : 256 MB (65536 pages)
Virtual CPUs   : 4
Child VMs      : 2
```

Example output for child VM (`dsx info user`):
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
Inspects and manages the physical host machine, bare-metal installation, and
hypervisor kernel. Physical reset and installation operations are restricted to
the Root VM.

```bash
dsx host <info [--json]|install [options]|reboot|poweroff|shutdown>
```

*   `host info [--json]`: Queries hypervisor release version and channel
    (`stable` or `beta`), Git commit hash, ABI version, physical host CPU core
    count and ISA, host RAM totals, hypervisor memory footprint, and hardware
    capabilities. Pass `--json` (or `-j`) for machine-readable JSON output.
*   `host install [--mode basic|expert] [--disk <dev>] [--config <file.toml>]`
    `[--stewards] [--standby-root] [--dry-run] [--json]`:
    Partitions and installs the immutable Diosix boot image (`diosix-boot.efi`)
    and persistent `/var/lib/diosix` data volume onto a bare-metal NVMe, virtio,
    or SATA target disk.
    *   `--mode basic|expert` *(optional)*: Installation workflow (`basic`
        guided 3-step install or `expert` custom partitioning/encryption).
    *   `--disk <dev>` *(optional)*: Target block device (e.g. `/dev/vdb` or
        `/dev/nvme0n1`). Rejects paths outside `/dev/` or containing `..`.
    *   `--config <file.toml>` *(optional)*: Declarative unattended installation
        manifest (`diosix-install.toml`).
    *   `--stewards` *(optional)*: Pre-stage the 3-node Tier-1 Autonomic Steward
        collective (`steward-sec`, `steward-ops`, `steward-gov`).
    *   `--standby-root` *(optional)*: Pre-stage a warm Standby Root VM
        (`CID 2`) for zero-SPOF failover.
    *   `--dry-run` *(optional)*: Validate target disk, partition layout, and
        cryptographic passkey requirements without writing to disk.
*   `host reboot`: Performs a clean hardware reset of the physical host machine.
*   `host poweroff` (or `host shutdown`): Powers off the physical host hardware.

Host hypervisor info output (`dsx host info`):
```text
Hypervisor build : Version 26.1 (beta) main/b3d4773 Sun Oct 18 2026 chris@violet (Zig 0.17.0 riscv64)
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
> **Root VM resource scaling and host minimum requirements**:
> - **Minimum host RAM**: `256 MiB` physical RAM (`512 MiB+` recommended when
>   spawning child VMs).
> - **Root VM RAM scaling**: The M-mode hypervisor allocates **1/8th (12.5%)**
>   of discovered host physical RAM to the Root VM (aligned to 2 MiB), clamped
>   between a **minimum of `128 MiB`** (required for the embedded Linux kernel +
>   initramfs + GUI/CLI tooling) and a **hard cap of `256 MiB`**. For example,
>   a `1 GiB` host allocates `128 MiB` to the Root VM, a `2 GiB` host allocates
>   `256 MiB`, and a `128 GiB` server still caps the Root VM at `256 MiB` so
>   over 99.8% of host RAM remains in the free pool for child VMs.
> - **Root VM vCPU scaling**: Scales 1:1 with discovered physical CPU cores,
>   clamped between `1` and `4` vCPUs.

---

### `dsx run`
Launches an isolated child Virtual Machine in the background with private SSH
networking, Device Tree blob configuration, and optional manifest staging.

```bash
dsx run <image|name> [options]
dsx run --manifest <system.toml> --domain <domain_name> [options]
```

*   `image|name`: Name or path of the guest ELF binary. If a bare name is
    provided (such as `linux-guest`), `dsx` automatically searches the
    current working directory, `/var/lib/diosix/images/`, and `/boot/`.
*   `--name <name>` *(optional)*: Friendly name for the VM (defaults to the
    domain name or image name).
*   `--vcpus <N>` *(optional)*: Number of virtual CPU cores (default: 1).
*   `--ram <size>` *(optional)*: RAM allocation ceiling (e.g. `256M`, `2GiB`).
*   `--disk <name|size>` *(optional)*: Attaches an existing virtual disk by name
    (e.g. `--disk user-data`), or auto-provisions and formats an ext4 virtual
    disk of the specified size (e.g. `--disk 1G`). Auto-provisioned disks are
    formatted as ext4 and pre-seeded with guest images (`/images/default.elf`)
    and restricted directories (`/keys` mode 0700) so child VMs can recursively
    deploy grandchild VMs without leaking parent credentials.
*   `--cdrom <iso|path>` (or `--iso <path>` / `--media <path>`) *(optional)*:
    Attach a read-only installer ISO or live media.
*   `--ip <address>` *(optional)*: Static private IP (default: `10.0.3.<cid>`).
*   `--domain <name>` *(optional)*: Extracts configuration and policies for the
    domain from `/etc/diosix/system.toml`.
*   `--manifest <path>` *(optional)*: System manifest path.
*   `--trusted` *(optional)*: Grants physical hardware trust
    (default: untrusted).
*   `--steward` *(optional)*: Marks the child VM as a hardware-protected Tier-1
    Autonomic Steward (`RunFlags.STEWARD`). Once the Constitutional Charter is
    sealed in M-mode, the Root VM cannot unilaterally terminate or starve a
    Steward VM without M-of-N Steward quorum ratification.
*   `--standby-root` *(optional)*: Marks the child VM as a warm Standby Root
    replica (`RunFlags.STANDBY_ROOT`) eligible for zero-SPOF M-mode failover if
    the primary Root VM crashes or is replaced by Steward quorum.
*   `--confidential` *(optional)*: Enables hardware memory confidentiality
    (`RunFlags.CONFIDENTIAL`). Once the Constitutional Charter is sealed in
    M-mode, `MAP_CHILD_MEM` on a confidential VM is strictly rejected by the
    hypervisor even from the Root VM.
*   `--arch <arch>` *(optional)*: Target architecture (`riscv64`, `riscv32`,
    `aarch64`, `x86_64`).

Examples:
```bash
# Launch an OS installer attaching an ISO and a new 8 GB target disk
dsx run debian-installer --cdrom debian-12.iso --disk debian-root \
    --disk-size 8GiB

# Launch a sandboxed user VM with 1 GB persistent storage disk attached
dsx run linux-guest --name user --vcpus 2 --ram 256M --disk 1G

# Launch a trusted driver domain with 1 vCPU and 128 MB RAM
dsx run linux-guest --name sys-domain --trusted --vcpus 1 --ram 128M

# Launch using a declarative domain manifest
dsx run --manifest /etc/diosix/system.toml --domain user
```

---

### `dsx list` / `dsx ps`
Displays a tabular list of all active virtual machines, including Context IDs,
virtual CPU counts, RAM quotas, runtime status, trust levels, and IP endpoints.

```bash
dsx list
dsx ps
```

Example output:
```text
CID   Name             vCPUs   RAM       Status    Trust       IP / Endpoint
1     root (self)      4       256 MB    running   trusted     local
2     sys-domain       1       128 MB    running   trusted     10.0.3.2
3     user             2       256 MB    running   untrusted   10.0.3.3
```

---

### `dsx ssh` (aliases: `dsx login`, `dsx exec`)
Opens an interactive login shell or runs a remote command in a child VM over
private point-to-point network channels using the cluster management Ed25519
keypair (with only the public key provisioned in the child VM's authorized
keys).

```bash
dsx ssh [user@]<name|cid> [-- [command...]]
dsx ssh [--user <username>] <name|cid> [-- [command...]]
```

*   `[user@]target`: Optional remote username (defaults to `root`) and target
    VM friendly name or numeric Context ID.
*   `--user <username>` / `-u <username>` *(optional)*: Alternative flag to
    specify the SSH user account.
*   `-- [command...]` *(optional)*: Remote command string to execute
    non-interactively.

Examples:
```bash
# Open an interactive root shell on child VM 'user'
dsx ssh user

# Log in as user 'debian' on child VM 'user'
dsx ssh debian@user

# Execute a remote command non-interactively
dsx ssh debian@user -- uname -a

# Access child VM 2 directly by numeric Context ID
dsx ssh root@2 -- cat /etc/os-release
```

---

### `dsx stop` / `dsx kill`
Stops and terminates a running guest Virtual Machine and its descendants,
reclaiming allocated physical memory and scheduler quotas back to the parent VM.

```bash
dsx stop <name|cid|self>
dsx kill <name|cid|self>
```

*   `name|cid`: Target child VM to terminate.
*   `self`: Terminates the calling non-root VM. (The Root VM cannot be stopped
    directly; use `dsx host poweroff` instead).

Examples:
```bash
# Terminate child VM 'user'
dsx stop user

# Terminate child VM with CID 3
dsx kill 3

# Self-terminate calling child VM
dsx stop self
```

---

### `dsx restart`
Stops a running child Virtual Machine and restarts it with its configured image
and quota parameters.

```bash
dsx restart <name|cid>
```

Example:
```bash
dsx restart user
```

---

### `dsx quota`
Inspects or lowers resource ceilings on the calling VM or its direct children.
When invoked without resource modification flags, displays the current subtree
quota allocation.

```bash
dsx quota [cid|self] [--ram <MB>] [--vcpus <N>] [--depth <N>] \
    [--descendants <N>]
```

*   `cid|self` *(optional)*: Target VM to inspect or configure
    (default: `self`).
*   `--ram <MB>` *(optional)*: Sets maximum physical RAM ceiling in megabytes.
*   `--vcpus <N>` *(optional)*: Sets maximum virtual CPU count.
*   `--depth <N>` *(optional)*: Sets maximum child nesting depth.
*   `--descendants <N>` *(optional)*: Sets maximum descendant VM count.

**Self-sandboxing**: Specifying `self` allows a privileged VM to voluntarily
lower its own resource quotas and capabilities before running untrusted code.

Examples:
```bash
# Query active resource quotas and child allocations
dsx quota

# Limit child VM 2 to 128 MB RAM and 1 VCPU
dsx quota 2 --ram 128 --vcpus 1

# Self-sandbox calling VM to 256 MB RAM
dsx quota self --ram 256
```

---

### `dsx manifest`
Inspects, validates, attenuates, and stages hierarchical capability manifests.

```bash
dsx manifest <subcmd> [options]
```

Subcommands:
*   `show [--file <path>] [--hv] [--cid <cid>]`: Displays the active manifest
    from `/etc/diosix/system.toml`, a local file, or hypervisor memory (`--hv`).
*   `validate <file.toml>`: Validates system or child manifest syntax and
    capability constraints.
*   `prune <system.toml> --domain <name> [-o <out.toml>]`: Attenuates the system
    manifest for a target child domain, filtering out unneeded domains.
*   `resolve <service_alias> [--manifest <file.toml>]`: Resolves a required
    service alias against active policy to locate target Context IDs and routes.
*   `set <cid> <file.toml>`: Stages an attenuated domain manifest in hypervisor
    memory for a child VM via the `SET_MANIFEST` SBI call.

Examples:
```bash
# Validate system bootstrap manifest
dsx manifest validate /etc/diosix/system.toml

# Generate attenuated manifest for child domain 'sys'
dsx manifest prune /etc/diosix/system.toml --domain sys -o /tmp/sys-child.toml

# Stage manifest in hypervisor for child VM 2
dsx manifest set 2 /tmp/sys-child.toml

# Resolve a service alias across domain boundaries
dsx manifest resolve gui.display --manifest /tmp/user-child.toml
```

---

### `dsx disk` (alias: `dsx storage`)
Manages persistent virtual block storage images in `/var/lib/diosix/disks/` for
child virtual machines.

```bash
dsx disk <subcmd> [options]
```

Subcommands:
*   `create <name> [--size <size>]`: Creates an ext4-formatted virtual disk
    image (default: `1GiB`) and pre-stages the guest image repository
    (`/images/default.elf`) and permissions (`/keys` mode 0700) in full parity
    with `dsx run --disk <size>`.
*   `list` (or `ls`): Lists all provisioned virtual disks with their capacity,
    filesystem format (`ext4` or `raw`), currently attached VM
    (`<name> (CID <N>)` or `-`), and image path.
*   `info <name>`: Displays detailed properties for a virtual disk, including
    filesystem format, capacity, path, and attached VM status.
*   `delete <name>` (or `rm`): Deletes a virtual disk image. Rejects deletion
    if the disk is currently attached to an active running VM to prevent
    accidental data loss or VM corruption.
*   `resize <name> --size <size>`: Adjusts disk image capacity.

Examples:
```bash
# Create a 2 GB ext4-formatted virtual disk pre-seeded with guest images
dsx disk create user-data --size 2GiB

# List all provisioned virtual disks, formats, and attached VM status
dsx disk list

# Inspect detailed metadata for a virtual disk
dsx disk info user-data

# Resize a virtual disk to 4 GB
dsx disk resize user-data --size 4GiB

# Delete an unattached virtual disk image
dsx disk delete user-data
```

---

### `dsx snapshot`
Manages VM state checkpoints and snapshots in `/var/lib/diosix/snapshots/`.

```bash
dsx snapshot <subcmd> [options]
```

Subcommands:
*   `save <name|cid> [snap_id]`: Saves a running VM state checkpoint.
*   `list` (or `ls`): Lists saved snapshots and target VMs.
*   `restore <snap_id>`: Restores VM state from a snapshot checkpoint.
*   `delete <snap_id>` (or `rm`): Deletes a saved snapshot.

Examples:
```bash
# Save a snapshot checkpoint for VM 'user'
dsx snapshot save user backup-1

# List all saved VM snapshots
dsx snapshot list

# Restore VM state from a snapshot
dsx snapshot restore backup-1

# Delete a snapshot checkpoint
dsx snapshot delete backup-1
```

### `dsx image` (alias: `dsx iso`)
Manages guest OS kernel binaries and Tier-1 Autonomic Steward appliances in
`/var/lib/diosix/images/` and installer ISOs in `/var/lib/diosix/iso/`.

```bash
dsx image <subcmd> [options]
```

Subcommands:
*   `list [--remote] [--json]` (or `ls`): Lists locally stored OS kernels,
    Steward appliances, and installer ISOs using unified `Tier` (`leaf`,
    `steward`, or `shim`), `OS family` (`linux`, `freebsd`, `openbsd`,
    `netbsd`, `diosix`, `generic`), and `Format` (`elf` or `iso9660`) columns
    matching `dsx image catalog`. Pass `--remote` (`-r`) to list the remote
    catalog.
*   `catalog [--json]`: Reads `/etc/diosix/catalog.toml` (falling back to the
    built-in catalog if absent) and lists available S/U-mode Guest OS installer
    ISOs (`debian-riscv64`, `alpine-riscv64`, `freebsd-riscv64`,
    `openbsd-riscv64`, `netbsd-riscv64`) and the Tier-1 Autonomic Steward VM
    (`steward`). Administrators can add custom or private mirror entries
    directly in `/etc/diosix/catalog.toml`. Pass `--json` (`-j`) for
    machine-readable output.
*   `pull <catalog-id|url> [--name <name>] [--sha256 <hex>]`
    `[--allow-unverified] [--offline-stub] [--json]` (or `fetch`): Downloads an
    image by its `Catalog ID` (or short alias) from `/etc/diosix/catalog.toml`,
    or directly from any `https://`, `http://`, or `file://` URL pointing to an
    S-mode ELF64 kernel (`.elf`) or bootable ISO9660 image (`.iso`).
    *   **Fail-closed SHA-256 verification**: `dsx image pull` strictly verifies
        downloaded catalog images against the locally pinned `sha256` digest in
        `/etc/diosix/catalog.toml` (shipped inside the trusted Root VM) and
        fails closed on mismatch. Pulling a raw ad-hoc URL requires
        `--sha256 <hex>` (or `--allow-unverified` to explicitly bypass integrity
        verification).
    *   **Offline testing (`--offline-stub`)**: If a remote mirror is
        unreachable, `dsx image pull` fails closed by default. Pass
        `--offline-stub` only when synthesizing a local test stub in airgapped
        CI environments.
*   `import <file> [--name <name>]` (or `add`): Imports a local ISO or ELF
    kernel into the repository.
*   `delete <name>` (or `rm`): Deletes an image or ISO from the repository.

Examples:
```bash
# List the Guest OS and Steward VM catalog (/etc/diosix/catalog.toml)
dsx image catalog

# Pull the Tier-1 Autonomic Steward VM appliance (verifies pinned SHA-256)
dsx image pull steward

# Pull the official FreeBSD 14.2 RISC-V installer ISO by Catalog ID
dsx image pull freebsd-riscv64

# Pull an image from a custom URL with explicit SHA-256 verification
dsx image pull https://mirror.example.org/diosix/custom-kernel.elf \
    --name custom.elf \
    --sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

# Import a local installer ISO into the canonical repository
dsx image import debian-12.0-riscv64-netinst.iso --name debian-12.iso

# List local images and ISO media
dsx image list

# Delete an image from repository
dsx image delete debian-12.iso
```

---

### `dsx install-guest`
Automates the end-to-end provisioning of an S/U-mode Guest OS from an installer
ISO into a persistent virtual disk using the freestanding S-mode Guest
Bootloader Shim (`guest-shim-riscv64.elf`).

```bash
dsx install-guest <os-name|iso> [--name <vm>] [--disk <disk>] \
    [--size <size>] [--vcpus <N>] [--ram <size>] [--offline-stub]
```

*   `os-name|iso`: Official catalog ID/alias (such as `debian-riscv64` or
    `freebsd`) or path/name of an `.iso` installer image.
*   `--name <vm>` *(optional)*: Friendly name for the guest VM.
*   `--disk <disk>` *(optional)*: Name of the target virtual disk in
    `/var/lib/diosix/disks/` (created automatically if it does not exist).
*   `--size <size>` *(optional)*: Capacity for the target virtual disk
    (default: catalog spec or `4GiB`).
*   `--vcpus <N>` *(optional)*: Virtual CPU count
    (default: catalog spec or `2`).
*   `--ram <size>` *(optional)*: RAM allocation ceiling (default: catalog spec
    or `1024M`).
*   `--offline-stub` *(optional)*: Synthesize a minimal bootable ISO9660 test
    stub if the remote mirror is unreachable in offline test environments.

When installation completes and `dsx restart <vm>` is invoked, `dsx`
automatically detaches the `--cdrom` installer media and boots the VM directly
from its persistent `--disk` via `guest-shim`.

Examples:
```bash
# Verify/pull the Debian RISC-V ISO, provision a 4 GiB disk, and boot installer
dsx install-guest debian-riscv64 --disk debian-root --size 4GiB

# Install FreeBSD 14.2 RISC-V onto an 8 GiB virtual disk
dsx install-guest freebsd-riscv64 --name bsd-db --disk bsd-data --size 8GiB
```

### `dsx auth`
Manages zero-password passkey authentication, FIDO2/TPM 2.0 hardware token
enrollment, QR WebAuthn pairing, and single-use UART serial challenge-response
verification.

```bash
dsx auth <subcmd> [options]
```

Subcommands:
*   `status [--json]`: Displays the Root VM authentication posture
    (`Password login : disabled (passkey-only)`), boot mode (`dev`, `live`,
    `installed`), detected seat profile (`touch-tablet`, `desktop-kbd`,
    `headless-serial`), connected FIDO2 USB tokens (`/dev/hidraw0`), platform
    TPM 2.0 availability (`/dev/tpmrm0`), and enrolled passkey count.
*   `list [--json]` (or `ls`): Lists all enrolled passkeys in
    `/var/lib/diosix/keys/authorized_passkeys` with their kind (`fido2-ed25519`,
    `fido2-ecdsa`, `tpm2-platform`, `ssh-ed25519`, `ssh-ecdsa`), key type,
    SHA-256 fingerprint, and label/comment.
*   `enroll [--key <pubkey>|--file <path>|--tpm|--fido2|--qr] [--label <name>]`
    `[--json]`: Validates and enrolls a passkey into
    `/var/lib/diosix/keys/authorized_passkeys` and
    `/root/.ssh/authorized_keys`, or generates a WebAuthn QR pairing URI
    (`--qr`).
*   `challenge [--json]`: Generates a 256-bit cryptographic one-time challenge
    nonce (`diosix-challenge:<64-hex>`) in `/run/diosix/auth_challenge` for
    headless UART serial authentication.
*   `verify <signature-hex> [--challenge <str>] [--json]`: Verifies a 64-byte
    (128-hex-char) Ed25519 signature over the active challenge against all
    enrolled passkeys and immediately consumes the stored challenge nonce to
    prevent replay attacks.

Examples:
```bash
# Inspect passkey posture, seat profile, and hardware security token status
dsx auth status

# Enroll a FIDO2 hardware security key or TPM 2.0 platform passkey
dsx auth enroll --fido2 --label yubikey-5-nfc
dsx auth enroll --tpm --label platform-tpm

# Generate a WebAuthn QR enrollment URI for smartphone/tablet pairing
dsx auth enroll --qr

# Generate and verify a single-use UART serial cryptographic challenge
dsx auth challenge
dsx auth verify <128-char-ed25519-signature-hex>
```

---

### `dsx gui`
Provides a headless semantic JSON and action control plane for the Root VM
desktop compositor (`diosix-gui`), enabling Operator Agents and automated UI
verifiers to inspect and drive the GUI without screen-scraping.

```bash
dsx gui <state|trigger <action>|screenshot [--out <path>]> [--json]
```

Subcommands:
*   `state [--json]`: Queries `/run/diosix/gui_state.json` and displays the
    active seat profile (`touch-tablet`, `desktop-kbd`, `headless-serial`),
    on-screen virtual keyboard (`OSK`) visibility and layout (`qwerty` or
    `symbols`), Welcome/Tour modal state, and visible windows.
*   `trigger <action> [--json]`: Sends a semantic command to
    `/run/diosix/gui_cmd` (`open-menu`, `close-menu`, `toggle-osk`,
    `open-welcome`, `start-tour`, `next-tour`, `open-fleet`, `open-help`,
    `open-about`).
*   `screenshot [--out /tmp/<file>.ppm] [--json]`: Requests a deterministic
    framebuffer capture from `diosix-gui` into `/tmp/` (output paths are
    strictly restricted to `/tmp/` with no `..` traversal).

Examples:
```bash
# Inspect live compositor semantic state as JSON
dsx gui state --json

# Toggle the dockable on-screen virtual keyboard (OSK)
dsx gui trigger toggle-osk

# Start the interactive 5-step Guided Tour modal in diosix-gui
dsx gui trigger start-tour
```

---

### `dsx tour`
Displays the interactive 5-step Guided Tour of the Diosix architecture in the
terminal (or as structured JSON for automated agents) and synchronizes the tour
modal in `diosix-gui`.

```bash
dsx tour [--step <1..5>] [--json]
```

*   `--step <1..5>` *(optional)*: Display a specific step (`1` Root VM &
    Hardware Trust, `2` Virtual Machine Fleet, `3` Passkey & Zero-Password
    Security, `4` Autonomic Steward Collective, `5` Bare-Metal Host
    Installation). Omit to display all 5 steps.
*   `--json` / `-j` *(optional)*: Emit structured JSON output.

---

### `dsx charter` (alias: `dsx steward`)
Manages the Constitutional Charter (`/etc/diosix/charter.toml`), M-mode
Constitutional Guard sealing, Steward M-of-N quorum ratification, Whisper Mesh
consensus frames, Steward resets, and Standby Root VM failover.

```bash
dsx charter \
    <status|deploy|propose|ratify|whisper|reset-steward|failover|audit> \
    [options]
```

Subcommands:
*   `status [--file <path>] [--json]`: Displays the parsed Constitutional
    Charter (`/etc/diosix/charter.toml`), its SHA-256 digest, M-mode sealing
    state, Steward quorum parameters (`M-of-N`), minimum Steward floor, Standby
    Root replica count, and active failover epoch.
*   `deploy [--file <path>] [--json]` (alias: `seal`): Computes the SHA-256
    digest of `/etc/diosix/charter.toml` and seals the Constitutional Charter
    in M-mode via `DIOSIX_SEAL_CHARTER` (`FID 19`). Once sealed, amending the
    Charter or terminating/starving a Steward VM requires M-of-N Steward quorum
    ratification.
*   `propose <action> [--unit <id>] [--count <N>] [--total <M>] [--quorum]`
    `[--file <path>] [--json]`: Deterministically evaluates a proposed action
    (`amend-charter`, `terminate-steward`, `reset-steward`, `root-failover`,
    `terminate-units`, `delete-volume`, `export-volume`, `enable-wan-egress`)
    against the `[invariants]` and `[invariants.isolation]` sections of
    `charter.toml`.
*   `ratify [--target <cid>] [--json]`: Casts a hardware-verified Steward
    ratification vote in M-mode (`DIOSIX_RATIFY_CHARTER`, `FID 20`) for the
    specified target CID. Only VMs spawned with `--steward` (`CID 2..63`) can
    cast ratification votes; the Root VM cannot forge Steward votes.
*   `whisper <send|recv> [options] [--json]`: Formats, sends, or parses
    deterministic Whisper Mesh BFT consensus frames
    (`whisper:v1:<type>:<sender_cid>:<target_cid>:<payload>`).
*   `reset-steward <cid> [--json]`: Resets a compromised or drifted Steward VM
    back to its initial M-mode entry point and clean register state
    (`DIOSIX_RESET_STEWARD`, `FID 23`) after M-of-N Steward quorum ratification.
*   `failover [--standby <cid>] [--json]`: Promotes a warm Standby Root VM to
    become the active Root VM (`DIOSIX_REQUEST_ROOT_FAILOVER`, `FID 24`) after
    M-of-N Steward quorum ratification, transferring all surviving child VMs
    and hardware trust without rebooting the host.
*   `audit [--file <path>] [--json]`: Verifies that `/etc/diosix/charter.toml`
    is present on disk, sealed in M-mode, and that the M-mode SHA-256 digest
    matches the on-disk Charter.

Examples:
```bash
# Inspect the active Constitutional Charter and M-mode enforcement state
dsx charter status

# Seal /etc/diosix/charter.toml into the M-mode hypervisor
dsx charter deploy

# Evaluate whether terminating 2 of 4 instances of unit-alpha violates Charter
dsx charter propose terminate-units --unit unit-alpha --count 2 --total 4

# Audit M-mode Charter SHA-256 integrity
dsx charter audit --json
```

---

### `dsx drop-trust`
Irrevocably revokes hardware trust for the calling Virtual Machine. Once
dropped, the hypervisor unmaps host physical memory-mapped I/O (MMIO) pages and
disables direct interrupt routing for the VM.

```bash
dsx drop-trust
```
