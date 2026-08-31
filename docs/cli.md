# Diosix command-line interface (`dsx` / `diosix-ctl`)

The `dsx` utility (also available as `diosix-ctl`) is the userspace 
command-line tool for managing guest Virtual Machines (VMs) on the Diosix 
hypervisor. It communicates with the hypervisor through the `/dev/diosix` 
character device driver using standard Supervisor Binary Interface (SBI) 
hypercalls.

Running `dsx` requires root privileges inside the guest operating system 
to access `/dev/diosix`.


---

## Context ID (CID) syntax

Commands that accept a `<cid>` argument support both numeric identifiers and 
symbolic aliases:

*   **`self`** or **`1`**: Refers to the calling VM.
*   **`parent`** or **`0`**: Refers to the immediate parent VM.
*   **`2..N`**: Refers to a specific direct child VM created by the calling VM.

---

## Command reference

### `diosix-ctl info`
Displays status, Context ID (CID), hardware trust status, architecture, 
active child count, and resource quota usage for the calling VM.

```bash
diosix-ctl info [--host]
```

*   `--host` / `-h` *(optional)*: Queries hypervisor release version, ABI 
    version, host physical hardware metrics, and active capability flags.

Default guest VM info output:
```text
=== Diosix guest VM info ===
Context ID     : 1
Parent CID     : 0
Architecture   : riscv64
Root VM        : yes
Hardware trust : yes
RAM allocation : 64 MB (16384 pages)
Virtual CPUs   : 1
Child VMs      : 2
```

Host hypervisor info output (`diosix-ctl info --host`):
```text
=== Diosix hypervisor information ===
Diosix version  : 26.1 (Commit b3d4773)
ABI version     : 0.2.0
Host cores      : 1 physical hart(s)
Host RAM        : 2048 MB total / 1536 MB free
Timer frequency : 10000000 Hz
Capabilities    :
  [x] Hardware H-extension (nested virtualization)
  [x] Stage-2 Sv39x4 paging
  [x] Cross-arch JIT dynamic recompilation
  [x] VirtIO-vsock (AF_VSOCK in-hypervisor networking)
```

---

### `diosix-ctl run`
Launches an unprivileged or privileged child VM in the background with private SSH 
networking and optional manifest attenuation.

```bash
diosix-ctl run <elf_path> [options]
diosix-ctl run --manifest <system.toml> --domain <domain_name> [options]
```

*   `elf_path`: Absolute or relative path to the guest ELF binary.
*   `--name <name>` *(optional)*: Friendly name for the VM (defaults to domain name or binary filename).
*   `--domain <name>` *(optional)*: Attenuates and stages domain configuration from the system manifest.
*   `--manifest <path>` *(optional)*: Path to system manifest (defaults to `/etc/diosix/system.toml`).
*   `--vcpus <N>` *(optional)*: Virtual CPU limit (default: 1).
*   `--ram <size>` *(optional)*: Memory allocation limit (e.g. `256M`, `2GiB`).
*   `--ip <address>` *(optional)*: Private static IP address (default: `10.0.3.<cid>`).
*   `--trusted` *(optional)*: Grants physical host MMIO and hardware interrupt access. Default is unprivileged/sandboxed (`untrusted`).
*   `--arch <arch>` *(optional)*: Target architecture (`riscv64`, `riscv32`, `aarch64`, `x86_64`).

Examples:
```bash
# Launch a sandboxed user VM with 2 vCPUs and 256 MB RAM
diosix-ctl run /boot/vmlinux.elf --name user --vcpus 2 --ram 256M

# Launch directly from system manifest domain definition
diosix-ctl run --manifest /etc/diosix/system.toml --domain user
```

---

### `diosix-ctl list` / `diosix-ctl ps`
Lists all active virtual machines within the domain hierarchy, including resource 
quotas, status, trust level, and connection endpoints.

```bash
diosix-ctl list
diosix-ctl ps
```

Example output:
```text
=== Diosix guest VMs ===
CID   Name             vCPUs   RAM       Status    Trust       IP / Endpoint
1     root (self)      4       512 MB    running   trusted     local
2     user             2       256 MB    running   untrusted   10.0.3.3 (ssh)
```

---

### `diosix-ctl login` / `diosix-ctl ssh`
Establishes a secure, passwordless SSH session into a running child VM using the 
pre-shared Diosix internal ED25519 keypair.

```bash
diosix-ctl login <name|cid> [-- [command...]]
diosix-ctl ssh <name|cid> [-- [command...]]
```

*   `name|cid`: Friendly VM name (e.g. `user`) or Context ID (e.g. `2`).
*   `command` *(optional)*: Remote command to execute non-interactively.

Examples:
```bash
# Open interactive login shell into child VM 'user'
diosix-ctl login user

# Execute command non-interactively on child VM 2
diosix-ctl login 2 -- uname -a
```

---

### `diosix-ctl stop` / `diosix-ctl kill`
Terminates and tears down a running child VM.

```bash
diosix-ctl stop <name|cid>
```

Example:
```bash
diosix-ctl stop user
```

---

### `diosix-ctl quota`
Applies or lowers resource ceilings on the calling VM or its direct children.

```bash
diosix-ctl quota <cid|self> [--ram <MB>] [--vcpus <N>] [--depth <N>] [--descendants <N>]
```

*   `--ram <MB>`: Sets maximum RAM capacity in megabytes.
*   `--vcpus <N>`: Sets maximum number of VCPUs.
*   `--depth <N>`: Sets maximum child nesting depth.
*   `--descendants <N>`: Sets maximum total descendant VMs.

**Self-sandboxing**: Passing `self` allows a VM to voluntarily ratchet down 
its own quotas before running untrusted workloads.

Examples:
```bash
# Limit child VM 2 to 128 MB RAM and 2 VCPUs
diosix-ctl quota 2 --ram 128 --vcpus 2

# Self-sandbox the current VM to 256 MB RAM
diosix-ctl quota self --ram 256
```

### `diosix-ctl terminate`
Terminates a target virtual machine (the calling VM or a direct child VM) along with all of its descendants.

```bash
diosix-ctl terminate [cid|self] [exit_code]
```

Examples:
```bash
# Terminate child VM 2 with exit code 0
diosix-ctl terminate 2 0

# Terminate calling VM with exit code 42
diosix-ctl terminate self 42
```

---

### `diosix-ctl exit`
Convenience alias to terminate the current non-root VM.

```bash
diosix-ctl exit [exit_code]
```

*Note: The Root VM cannot terminate itself; use `poweroff` or `reboot`.*

---

### `diosix-ctl drop-trust`
Irrevocably revokes hardware trust for the calling VM. Once dropped, the 
hypervisor unmaps host physical memory-mapped I/O (MMIO) regions and disables 
direct interrupt routing for the VM.

```bash
diosix-ctl drop-trust
```

---

### `diosix-ctl manifest`
Manages system-wide bootstrap manifests (`/etc/diosix/system.toml`), validates
syntax, generates attenuated least-privilege child VM manifests, and stages
manifests in hypervisor memory.

```bash
diosix-ctl manifest <show|validate|prune|set> [options]
```

*   `show [--file <path>] [--hv] [--cid <cid>]`: Displays the active manifest from
    the local filesystem (`/etc/diosix/system.toml` or `/etc/diosix/manifest.toml`),
    an explicit file path, or queries hypervisor staging memory (`--hv`).
*   `validate <path/to/manifest.toml>`: Validates a system or child manifest
    against the schema, verifying domain declarations, route patterns, and channel
    modes.
*   `prune <system.toml> --domain <name> [-o <out.toml>]`: Extracts and attenuates
    the system manifest for a specific child domain, resolving its capability
    routes and stripping out unrelated domain definitions.
*   `set <cid> <path/to/manifest.toml>`: Uploads and stages an attenuated child
    manifest into hypervisor memory for the specified child VM CID using the
    `SET_MANIFEST` hypercall.

Examples:
```bash
# Validate system bootstrap manifest
diosix-ctl manifest validate /etc/diosix/system.toml

# Generate attenuated manifest for child domain 'sys'
diosix-ctl manifest prune /etc/diosix/system.toml --domain sys -o /tmp/sys-child.toml

# Stage attenuated manifest in hypervisor for child VM 2
diosix-ctl manifest set 2 /tmp/sys-child.toml

# Inspect manifest staged in hypervisor for child VM 2
diosix-ctl manifest show --cid 2 --hv
```

---

### `diosix-ctl resolve`
Resolves a required service alias against the VM's active manifest to discover
target Context IDs, routing domains, network endpoints, and access modes.

```bash
diosix-ctl resolve <service_alias> [--manifest <file.toml>]
```

*   `service_alias`: Required capability or alias (for example, `gui.display` or
    `net.wan`).
*   `--manifest` / `-m` *(optional)*: Explicit manifest file to resolve against.
    Defaults to `/etc/diosix/manifest.toml` or the hypervisor-staged manifest.

Example output:
```text
Service resolution:
  Service : gui.display
  Alias   : gui.wayland
  CID     : 0
  Domain  : sys
  Mode    : rw
```

---

### `diosix-ctl poweroff` and `diosix-ctl reboot`
Powers off or restarts the host hardware machine. This command is restricted 
exclusively to the Root VM via the SBI System Reset (`SRST`) extension.

```bash
diosix-ctl poweroff
diosix-ctl reboot
```
