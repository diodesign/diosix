# Diosix command-line interface (`dsx` / `diosix-ctl`)

The `dsx` utility (also available via the `diosix-ctl` symlink) is the primary
command-line interface for managing guest Virtual Machines (VMs) on the Diosix
Type-1 hypervisor. It communicates with the hypervisor kernel through the
`/dev/diosix` character device driver using Supervisor Binary Interface (SBI)
hypercalls.

Running `dsx` requires superuser (`root`) privileges inside the guest operating
system to access the `/dev/diosix` interface.

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
Displays status, Context ID (CID), hardware trust status, architecture,
active child count, and resource quota usage for the current VM or a target
guest VM.

```bash
dsx info [name|cid|self]
```

*   `name|cid|self` *(optional)*: Target VM to inspect. Defaults to `self`.

Example output for calling VM (`dsx info`):
```text
Context ID     : 1
Parent CID     : 0
Architecture   : riscv64
Root VM        : yes
Hardware trust : yes
RAM allocation : 512 MB (131072 pages)
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
IP / Endpoint  : 10.0.3.2
```

---

### `dsx host`
Inspects and manages the physical host machine and hypervisor kernel. Physical
reset operations are restricted exclusively to the Root VM via the SBI System
Reset (`SRST`) extension.

```bash
dsx host <info|reboot|poweroff|shutdown>
```

*   `host info`: Queries hypervisor release version, Git commit hash, ABI
    version, physical host CPU core count, host RAM totals, and hardware
    virtualization capabilities.
*   `host reboot`: Performs a clean hardware reset of the physical host machine.
*   `host poweroff` (or `host shutdown`): Powers off the physical host hardware.

Host hypervisor info output (`dsx host info`):
```text
Diosix version  : 26.1 (Commit b3d4773)
ABI version     : 0.2.0
Host cores      : 4 physical hart(s)
Host RAM        : 2048 MB total / 1536 MB free
Timer frequency : 10000000 Hz
Capabilities    :
  [x] Hardware H-extension (nested virtualization)
  [x] Stage-2 Sv39x4 paging
  [x] Cross-arch JIT dynamic recompilation
  [x] VirtIO-vsock (AF_VSOCK in-hypervisor networking)
```

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
*   `--disk <name|size>` *(optional)*: Attach an existing virtual disk image or auto-provision sparse capacity.
*   `--cdrom <iso|path>` (or `--iso <path>` / `--media <path>`) *(optional)*: Attach a read-only installer ISO or live media.
*   `--ip <address>` *(optional)*: Static private IP (default: `10.0.3.<cid>`).
*   `--domain <name>` *(optional)*: Extracts configuration and policies for the
    domain from `/etc/diosix/system.toml`.
*   `--manifest <path>` *(optional)*: System manifest path.
*   `--trusted` *(optional)*: Grants physical hardware trust (default: untrusted).
*   `--arch <arch>` *(optional)*: Target architecture (`riscv64`, `riscv32`,
    `aarch64`, `x86_64`).

Examples:
```bash
# Launch an OS installer attaching an installation ISO and a new 8 GB target disk
dsx run debian-installer --cdrom debian-12.iso --disk debian-root --disk-size 8GiB

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
1     root (self)      4       512 MB    running   trusted     local
2     sys-domain       1       128 MB    running   trusted     10.0.3.2
3     user             2       256 MB    running   untrusted   10.0.3.3
```

---

### `dsx ssh` (aliases: `dsx login`, `dsx exec`)
Opens an interactive login shell or runs a remote command in a child VM over
private point-to-point network channels using pre-shared ED25519 authentication.

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
dsx quota [cid|self] [--ram <MB>] [--vcpus <N>] [--depth <N>] [--descendants <N>]
```

*   `cid|self` *(optional)*: Target VM to inspect or configure (default: `self`).
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
*   `create <name> [--size <size>]`: Creates a sparse virtual disk image (default: `1GiB`).
*   `list` (or `ls`): Lists all available virtual disk images, capacities, and paths.
*   `delete <name>` (or `rm`): Deletes a virtual disk image.
*   `resize <name> --size <size>`: Adjusts disk image capacity.

Examples:
```bash
# Create a 2 GB virtual disk for a child VM
dsx disk create user-data --size 2GiB

# List all provisioned virtual disk images
dsx disk list

# Resize a virtual disk to 4 GB
dsx disk resize user-data --size 4GiB

# Delete a virtual disk image
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
Manages guest OS kernel binaries in `/var/lib/diosix/images/` and installer ISOs in `/var/lib/diosix/iso/`.

```bash
dsx image <subcmd> [options]
```

Subcommands:
*   `list` (or `ls`): Lists all available OS kernels, installer ISOs, file formats, and paths.
*   `import <file> [--name <name>]` (or `add`): Imports a downloaded ISO or ELF kernel into the repository.
*   `delete <name>` (or `rm`): Deletes an image or ISO from the repository.

Examples:
```bash
# Import a downloaded Debian installer ISO into the canonical repository
dsx image import debian-12.0-riscv64-netinst.iso --name debian-12.iso

# List available images and ISO media
dsx image list

# Delete an image from repository
dsx image delete debian-12.iso
```

---

### `dsx drop-trust`
Irrevocably revokes hardware trust for the calling Virtual Machine. Once
dropped, the hypervisor unmaps host physical memory-mapped I/O (MMIO) pages and
disables direct interrupt routing for the VM.

```bash
dsx drop-trust
```

