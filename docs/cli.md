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
*   **`2..N`**: Refers to a specific direct child VM created by `fork`.

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
=== Diosix Guest VM Info ===
Context ID     : 1
Parent CID     : 0
Architecture   : riscv64
Root VM        : yes
Hardware Trust : yes
RAM Allocation : 64 MB (16384 pages)
Virtual CPUs   : 1
Child VMs      : 2
```

Host hypervisor info output (`diosix-ctl info --host`):
```text
=== Diosix Hypervisor Information ===
Diosix Version  : 26.1 (Commit b3d4773)
ABI Version     : v0.2.0
Host Cores      : 1 Physical Hart(s)
Host RAM        : 2048 MB Total / 1536 MB Free
Timer Frequency : 10000000 Hz
Capabilities    :
  [x] Hardware H-Extension (Nested Virtualization)
  [x] Stage-2 Sv39x4 Paging
  [x] Copy-on-Write VM Forking
  [x] Cross-Arch JIT Dynamic Recompilation
  [x] Inter-VM Fast IPC
```

---


### `diosix-ctl spawn`
Atomically creates a new child VM and boots a guest Executable and Linkable 
Format (ELF) binary (and optional DTB). It can also reload an image into an 
existing child VM (`CID >= 2`).

```bash
diosix-ctl spawn <elf_path> [dtb_path] [arch] [--trusted]
diosix-ctl spawn <cid> <elf_path> [dtb_path] [arch] [--trusted]
```

*   `elf_path`: Absolute or relative path to the guest ELF binary.
*   `cid` *(optional)*: Existing child CID (`>= 2`) to reload. If omitted, a 
    brand new clean child VM is created and started.
*   `dtb_path` *(optional)*: Path to the guest device tree blob.
*   `arch` *(optional)*: Target architecture (`riscv64`, `riscv32`, `aarch64`, 
    `x86_64`). Defaults to `riscv64`.
*   `--trusted` *(optional)*: Grants the spawned VM physical host MMIO and 
    hardware interrupt access (only permitted from hardware-trusted parents). 
    By default, spawned guests are untrusted.

Examples:
```bash
# Atomically create and launch a sandboxed guest VM (default untrusted)
diosix-ctl spawn /root/app.elf /root/app.dtb riscv64

# Spawn a trusted hardware driver VM (Root VM only)
diosix-ctl spawn /root/driver.elf --trusted

# Reload a new binary into existing child VM 2
diosix-ctl spawn 2 /root/app_v2.elf
```

---

### `diosix-ctl fork`
Clones the calling VM's memory using Stage-2 Copy-on-Write (COW) page tables 
and duplicates its primary Virtual CPU (VCPU) state. Returns a new child CID.

```bash
diosix-ctl fork [--untrusted]
diosix-ctl fork --spawn <elf_path> [options]
```

*   `--untrusted` / `--drop-trust` *(optional)*: Drops hardware trust in the child 
    VM immediately before it executes.
*   `--spawn <elf_path>`: Alias for `diosix-ctl spawn <elf_path>` to create and 
    boot a new VM image in one step.

Example output:
```text
VM successfully forked. Child CID: 2
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

---

### `diosix-ctl send`
Sends an Inter-Process Communication (IPC) message payload to a target VM.

```bash
diosix-ctl send <cid|parent> <message>
```

*   `cid`: Destination Context ID (`parent` or `0` for parent, `>= 2` for a 
    child).
*   `message`: Text or payload string (up to 4096 bytes).

Example:
```bash
diosix-ctl send parent "PING"
diosix-ctl send 2 "START_WORKER"
```

---

### `diosix-ctl recv`
Receives an IPC message from the caller's inbox ring buffer.

```bash
diosix-ctl recv [cid|parent] [--nohang]
```

*   `cid` *(optional)*: Filters incoming messages for a specific sender CID.
*   `--nohang` / `-n` *(optional)*: Returns immediately without blocking if no 
    messages are present. By default, `recv` blocks until a message arrives.

Example:
```bash
diosix-ctl recv
```

Example output:
```text
[IPC Message from CID 2 (12 bytes)]:
START_WORKER
```

---

### `diosix-ctl wait`
Waits for state changes or exit events from child VMs.

```bash
diosix-ctl wait [cid|self] [--nohang]
```

*   `cid` *(optional)*: Specific child CID to wait on. Omit to wait for any 
    child event.
*   `--nohang` / `-n` *(optional)*: Checks for pending events without blocking.

Example:
```bash
diosix-ctl wait 2
```

Example output:
```text
Waiting for child VM (CID 2) event...
Child VM (CID 2) terminated with exit code 0.
```

---

### `diosix-ctl terminate`
Terminates a target VM and recursively tears down all of its descendants, 
reclaiming its memory and VCPU allocations.

```bash
diosix-ctl terminate [cid|self] [exit_code]
```

*   `cid`: `self` (or `1`) to terminate the current non-root VM, or `>= 2` to 
    terminate a child.
*   `exit_code` *(optional)*: Status code reported to the parent's event queue. 
    Defaults to `0`.

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

### `diosix-ctl poweroff` and `diosix-ctl reboot`
Powers off or restarts the host hardware machine. This command is restricted 
exclusively to the Root VM via the SBI System Reset (`SRST`) extension.

```bash
diosix-ctl poweroff
diosix-ctl reboot
```
