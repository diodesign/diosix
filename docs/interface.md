# Diosix shared interface and ABI

The Diosix hypervisor provides a standardized Application Binary Interface 
(ABI) and Supervisor Binary Interface (SBI) to facilitate communication 
between the hypervisor, guest operating system kernels, and userspace tools. 

The hypervisor core exposes these definitions through the `interface` module 
located in `hypervisor/interface/`.

---

## Calling convention and registers

Diosix implements the standard RISC-V SBI specification. Guest operating 
systems execute an `ecall` instruction from S-mode (Supervisor mode) to 
invoke hypervisor services.

Register assignments follow the standard SBI calling convention:

*   **`a7` (`x17`)**: Extension ID (EID)
*   **`a6` (`x16`)**: Function ID (FID)
*   **`a0` (`x10`)**: Argument 0 / Return error code
*   **`a1` (`x11`)**: Argument 1 / Return value or output
*   **`a2` (`x12`)**: Argument 2
*   **`a3` (`x13`)**: Argument 3
*   **`a4` (`x14`)**: Argument 4
*   **`a5` (`x15`)**: Argument 5

### SBI return error codes

*   `SBI_SUCCESS` (`0`): Completed successfully.
*   `SBI_ERR_FAILED` (`-1`): Operation failed.
*   `SBI_ERR_NOT_SUPPORTED` (`-2`): Extension or function not supported.
*   `SBI_ERR_INVALID_PARAM` (`-3`): Invalid parameter or argument.
*   `SBI_ERR_DENIED` (`-4`): Permission or capability denied.
*   `SBI_ERR_INVALID_ADDRESS` (`-5`): Invalid memory address or unmapped GPA.
*   `SBI_ERR_ALREADY_AVAILABLE` (`-6`): Resource already initialized or active.

---

## Relative Context ID (CID) architecture

To maintain strict tenant isolation, guest Virtual Machines (VMs) do not 
address each other using global IDs. Instead, all inter-VM operations use 
relative **Context IDs (CIDs)** scoped to the calling VM:

*   **`CID 0` (`CID_PARENT` / `parent`)**: The direct parent VM of the caller.
*   **`CID 1` (`CID_SELF` / `self`)**: The calling VM itself.
*   **`CID 2..N` (`CID_FIRST_CHILD` and above)**: Direct child handles 
    allocated when the calling VM executes a `FORK` operation.

A guest VM cannot reference siblings, grandparents, or unrelated VM subtrees.

---

## Standard SBI extensions

Diosix supports the following standard RISC-V SBI extensions:

*   **`BASE` (`0x10`)**: Probes available SBI extensions, retrieves the SBI 
    specification version, and reports the Diosix hypervisor Implementation 
    ID (`5`).
*   **`TIMER` (`0x54494D45`)**: Programs the timer comparator register for 
    guest timer interrupts.
*   **`SRST` (`0x53525354`)**: System Reset Extension for powering off or 
    rebooting the host system (restricted to the Root VM).
*   **`HSM` (`0x48534D`)**: Hart State Management for starting, stopping, and 
    querying the status of secondary Virtual CPU (VCPU) cores.
*   **`DBCN` (`0x4442434E`)**: Debug Console Extension for early character and 
    string I/O over the console.

---

## Diosix custom SBI extension (`0x0A000005`)

The custom Diosix extension (`EID 0x0A000005`) provides hypervisor-level 
lifecycle management, resource quota controls, inter-VM communication, and 
event notifications.

### Function summary

| Function | FID | Description |
| :--- | :--- | :--- |
| `TERMINATE` | `0` | Terminate self (`CID 1`) or child (`CID >= 2`) with an exit code |
| `YIELD` | `1` | Voluntarily yield the remaining VCPU execution quantum |
| `FORK` | `2` | Clone calling VM with Copy-on-Write (COW) memory (returns new CID) |
| `DROP_TRUST` | `3` | Irrevocably surrender hardware trust and MMIO access |
| `SPAWN` | `4` | Load a new guest binary and DTB into a child VM and start it |
| `GET_INFO` | `5` | Retrieve VM metadata, quotas, architecture, and child count |
| `SET_QUOTA` | `6` | Set or clamp RAM, VCPU, and descendant quotas |
| `IPC_SEND` | `7` | Send a message payload to parent (`CID 0`) or child (`CID >= 2`) |
| `IPC_RECV` | `8` | Read a message payload from the caller's inbox |
| `POLL_EVENT` | `9` | Pop the oldest asynchronous event from the VM's event queue |
| `GET_HV_INFO` | `10` | Retrieve hypervisor version, ABI version, host specs, and capabilities |

---

### Function details

#### `TERMINATE` (`FID 0`)
Terminates a target VM and recursively tears down all of its descendants.
*   `a0`: Target CID (`1` for self, `2..N` for a direct child).
*   `a1`: Exit code (reported to the parent's event queue).
*   **Returns**: Does not return if terminating self (`CID 1`). Returns 
    `SBI_SUCCESS` upon terminating a child.

#### `YIELD` (`FID 1`)
Relinquishes the current VCPU's time slice to allow other ready VCPUs to run.
*   **Returns**: `SBI_SUCCESS` (`0`).

#### `FORK` (`FID 2`)
Clones the calling VM's address space using Stage-2 Copy-on-Write (COW) page 
tables and duplicates its primary VCPU state.
*   `a0` *(optional)*: Flags bitmask (`FORK_FLAG_UNTRUSTED = 1 << 0`). Passing 
    `1` causes the child VM to immediately drop hardware trust before running.
*   **Returns**: Error code in `a0`, new child Context ID (`>= 2`) in `a1`.

#### `DROP_TRUST` (`FID 3`)
Irrevocably revokes hardware trust for the calling VM, unmapping host physical 
memory-mapped I/O (MMIO) and blocking direct interrupt routing.
*   **Returns**: `SBI_SUCCESS` (`0`).

#### `SPAWN` (`FID 4`)
Loads an Executable and Linkable Format (ELF) binary and an optional Device 
Tree Blob (DTB) into a child VM's address space, resetting its primary VCPU 
to the entry point.
*   `a0`: Guest Physical Address (GPA) pointing to `SpawnArgs` struct.
*   **Behavior**: When `child_id == 0`, the hypervisor atomically allocates a 
    new child VM and boots the image directly. When `child_id >= 2`, the 
    hypervisor resets and reboots the specified existing child VM.
*   **Hardware Trust**: Spawned guest VMs are untrusted by default. Passing 
    `SPAWN_FLAG_TRUSTED (1 << 0)` in `SpawnArgs.flags` grants hardware MMIO 
    access if and only if the caller is hardware-trusted. Untrusted callers 
    requesting trust receive `SBI_ERR_DENIED`.
*   **Returns**: `SBI_SUCCESS` (`0`) in `a0` on success with the child CID in 
    `a1`, or an error code on failure.



#### `GET_INFO` (`FID 5`)
Queries execution state, resource limits, and metadata for the calling VM.
*   `a0`: GPA pointer to a destination `GuestInfo` struct.
*   `a1`: Size of the `GuestInfo` buffer in bytes.
*   **Returns**: `SBI_SUCCESS` (`0`) on success.

#### `SET_QUOTA` (`FID 6`)
Applies resource ceilings to a target VM.
*   `a0`: GPA pointer to a `QuotaArgs` struct.
*   **Permissions**: A VM may set quotas on direct children (`CID >= 2`) up 
    to its own ceiling, or lower its own quotas (`CID 1`) to sandbox itself. 
    Calls targeting `CID 0` (parent) return `SBI_ERR_DENIED`.

#### `IPC_SEND` (`FID 7`)
Transfers an Inter-Process Communication (IPC) message payload directly into 
the inbox of a target VM.
*   `a0`: GPA pointer to an `IpcSendArgs` struct.
*   **Returns**: `SBI_SUCCESS` on delivery. Enqueues an `ipc_message` event in 
    the recipient VM's event queue.

#### `IPC_RECV` (`FID 8`)
Retrieves an incoming IPC message from the caller's inbox ring buffer.
*   `a0`: GPA pointer to an `IpcRecvArgs` struct.
*   **Returns**: `value = 1` in `a1` if a message was retrieved, `value = 0` 
    if the inbox was empty.

#### `POLL_EVENT` (`FID 9`)
Pops the oldest pending event from the VM's event queue.
*   `a0`: GPA pointer to a destination `Event` struct.
*   `a1`: Size of the `Event` buffer in bytes.
*   **Returns**: `value = 1` in `a1` if an event was popped, `value = 0` if 
    the event queue was empty.

#### `GET_HV_INFO` (`FID 10`)
Retrieves hypervisor build metadata, ABI semantic version, host physical 
hardware specifications, and feature capability flags.
*   `a0`: GPA pointer to a destination `HypervisorInfo` struct.
*   `a1`: Size of the `HypervisorInfo` buffer in bytes.
*   **Returns**: `SBI_SUCCESS` (`0`) on success.

---

## Data structure layouts

All structures passed across the hypercall boundary use standard C ABI 
alignment.

### `GuestInfo`
```c
struct guest_info {
    unsigned long guest_id;       /* Context ID (1 for caller) */
    unsigned long parent_id;      /* Parent Context ID (0) */
    unsigned char is_trusted;     /* 1 if trusted for MMIO, 0 otherwise */
    unsigned char is_root;        /* 1 if Root VM, 0 otherwise */
    unsigned char target_arch;    /* 0=rv64, 1=rv32, 2=aarch64, 3=x86_64 */
    unsigned char _reserved;      /* Padding byte */
    unsigned long used_ram_pages; /* Physical 4 KB pages currently mapped */
    unsigned long max_ram_pages;  /* Maximum 4 KB page ceiling */
    unsigned long used_vcpus;     /* Active VCPUs */
    unsigned long max_vcpus;      /* Maximum VCPUs allowed */
    unsigned long child_count;    /* Number of active child VMs */
};
```

### `HypervisorInfo`
```c
struct hypervisor_info {
    uint16_t abi_version_major;   /* e.g., 0 */
    uint16_t abi_version_minor;   /* e.g., 2 */
    uint16_t abi_version_patch;   /* e.g., 0 */
    uint16_t version_major;       /* Diosix release major (e.g. 26) */
    uint16_t version_minor;       /* Diosix release minor (e.g. 1) */
    uint16_t _reserved0;
    uint32_t _reserved1;
    char     build_commit[16];    /* Null-terminated git commit revision */
    uint64_t features;            /* Feature capability bitmask */
    uint32_t host_physical_cores; /* Number of physical host harts */
    uint32_t host_timer_freq_hz;  /* Hardware timer frequency in Hz */
    uint64_t host_total_ram_kb;   /* Total physical host RAM in KB */
    uint64_t host_free_ram_kb;    /* Available physical host RAM in KB */
};
```

### Capability Feature Flags
*   `CAP_HARDWARE_VIRT` (`1 << 0`): Hardware RISC-V H-extension active.
*   `CAP_STAGE2_PAGING` (`1 << 1`): Nested Stage-2 Sv39x4 hardware paging active.
*   `CAP_COW_FORK` (`1 << 2`): Instant Copy-on-Write memory cloning enabled.
*   `CAP_DYNAREC` (`1 << 3`): Transparent JIT cross-architecture emulation available.
*   `CAP_INTER_VM_IPC` (`1 << 4`): Hypervisor-routed fast zero-copy IPC supported.
*   `CAP_IOMMU` (`1 << 5`): Hardware Stage-2 DMA / IOMMU protection active.

### `SpawnArgs`
```c
struct spawn_args {
    unsigned long child_id;    /* Target child Context ID (0 = new child, >= 2 = reload) */
    unsigned long elf_ptr;     /* GPA pointer to ELF binary buffer */
    unsigned long elf_size;    /* Size of ELF binary in bytes */
    unsigned long dtb_ptr;     /* GPA pointer to DTB buffer (or 0) */
    unsigned long dtb_size;    /* Size of DTB in bytes */
    unsigned long target_arch; /* Target architecture enum */
    unsigned long flags;       /* Flags: SPAWN_FLAG_TRUSTED (1 << 0) */
};
```


### `QuotaArgs`
```c
struct quota_args {
    unsigned long target_cid;       /* 1 for self, >= 2 for child */
    unsigned long max_ram_pages;    /* RAM ceiling in 4 KB pages (0 = unchanged) */
    unsigned long max_vcpus;        /* VCPU limit (0 = unchanged) */
    unsigned long max_child_depth;  /* Maximum nesting depth (0 = unchanged) */
    unsigned long max_descendants;  /* Total descendant limit (0 = unchanged) */
};
```

### `IpcSendArgs` and `IpcRecvArgs`
```c
struct ipc_send_args {
    unsigned long target_cid; /* 0 for parent, >= 2 for child */
    unsigned long data_ptr;   /* GPA pointer to payload buffer */
    unsigned long data_len;   /* Length of payload (up to 4096 bytes) */
};

struct ipc_recv_args {
    unsigned long sender_cid;         /* 0 for any, or specific sender CID */
    unsigned long data_ptr;           /* GPA pointer to destination buffer */
    unsigned long max_len;            /* Capacity of destination buffer */
    unsigned long actual_len;         /* Output: Received payload size */
    unsigned long actual_sender_cid;  /* Output: Sender CID */
};
```

### `Event` and `EventType`
```c
enum event_type {
    EVENT_NONE             = 0,
    EVENT_CHILD_TERMINATED = 1,
    EVENT_CHILD_STOPPED    = 2,
    EVENT_CHILD_SPAWNED    = 3,
    EVENT_IPC_MESSAGE      = 4,
};

struct diosix_event {
    unsigned long cid;         /* Source Context ID */
    uint32_t      event_type;  /* Value from enum event_type */
    uint32_t      exit_code;   /* Exit code or IPC message length */
    uint64_t      _reserved;   /* Alignment padding */
};
```

---

## Linux kernel driver interface (`/dev/diosix`)

Inside Linux guest VMs, the `diosix` character device driver bridges userspace 
calls to hypervisor SBI extensions via standard `ioctl` numbers:

| IOCTL Name | Value | Description |
| :--- | :--- | :--- |
| `IOCTL_FORK` | `0x1001` | Forks current VM |
| `IOCTL_DROP_TRUST` | `0x1002` | Relinquishes hardware trust |
| `IOCTL_SPAWN` | `0x1003` | Loads ELF and boots child VM |
| `IOCTL_GET_INFO` | `0x1004` | Queries current VM info |
| `IOCTL_SET_QUOTA` | `0x1005` | Updates resource quotas |
| `IOCTL_TERMINATE` | `0x1006` | Terminates self or child VM |
| `IOCTL_WAIT_EVENT` | `0x1008` | Blocks/polls for asynchronous events |
| `IOCTL_IPC_SEND` | `0x1009` | Transmits an IPC message |
| `IOCTL_IPC_RECV` | `0x100A` | Receives an IPC message |
| `IOCTL_GET_HV_INFO` | `0x100B` | Queries hypervisor and host system info |
