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
    allocated when the calling VM creates child VMs.

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
| `DROP_TRUST` | `3` | Irrevocably surrender hardware trust and MMIO access |
| `RUN` | `4` | Load a new guest binary and DTB into a child VM and start it |
| `GET_INFO` | `5` | Retrieve VM metadata, quotas, architecture, and child count |
| `SET_QUOTA` | `6` | Set or clamp RAM, VCPU, and descendant quotas |
| `POLL_EVENT` | `9` | Pop the oldest asynchronous event from the VM's event queue |
| `GET_HV_INFO` | `10` | Retrieve hypervisor version, ABI version, host specs, and capabilities |
| `GET_MANIFEST` | `11` | Retrieve the staged capability manifest for self (`CID 1`) or child (`CID >= 2`) |
| `SET_MANIFEST` | `12` | Stage an attenuated capability manifest for a child VM (`CID >= 2`) |
| `MAP_CHILD_MEM` | `13` | Map a child VM's physical RAM region into parent Stage-2 GPA space for direct zero-copy access |
| `UNMAP_CHILD_MEM` | `14` | Revoke foreign memory mapping from parent Stage-2 page tables |
| `START` | `15` | Boot child VM virtual cores at specified entry point and DTB GPA |
| `NET_SEND` | `16` | Transmit an Ethernet frame to a target child VM (`CID >= 2`), parent (`CID 0`), or broadcast (`CID 0` destination) |
| `NET_RECV` | `17` | Retrieve an incoming Ethernet frame from the VM's receive ring buffer |
| `NET_POLL` | `18` | Query the number of queued incoming Ethernet frames |

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

#### `DROP_TRUST` (`FID 3`)
Irrevocably revokes hardware trust for the calling VM, unmapping host physical 
memory-mapped I/O (MMIO) and blocking direct interrupt routing.
*   **Returns**: `SBI_SUCCESS` (`0`).

#### `RUN` (`FID 4`)
Loads an Executable and Linkable Format (ELF) binary and an optional Device 
Tree Blob (DTB) into a child VM's address space, resetting its primary VCPU 
to the entry point.
*   `a0`: Guest Physical Address (GPA) pointing to `RunArgs` struct.
*   **Behavior**: When `child_id == 0`, the hypervisor atomically allocates a 
    new child VM and boots the image directly. When `child_id >= 2`, the 
    hypervisor resets and reboots the specified existing child VM.
*   **Hardware Trust**: Guest VMs are untrusted by default. Passing 
    `RUN_FLAG_TRUSTED (1 << 0)` in `RunArgs.flags` grants hardware MMIO 
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

#### `GET_MANIFEST` (`FID 11`)
Retrieves the staged capability manifest string from hypervisor memory for the
calling VM (`CID 1`) or a direct child VM (`CID >= 2`).
*   `a0`: GPA pointer to a `struct manifest_args`.
*   **Returns**: `SBI_SUCCESS` (`0`) on success, with `actual_len` populated in
    the argument structure.

#### `SET_MANIFEST` (`FID 12`)
Stages an attenuated capability manifest string in hypervisor memory for a
direct child VM (`CID >= 2`).
*   `a0`: GPA pointer to a `struct manifest_args`.
*   **Returns**: `SBI_SUCCESS` (`0`) on success, `SBI_ERR_DENIED` if not a direct
    parent, or `SBI_ERR_INVALID_PARAM` if the manifest exceeds 64 KiB.

#### `MAP_CHILD_MEM` (`FID 13`)
Maps a direct child VM's physical RAM region into the parent VM's Stage-2 GPA address
space for zero-copy binary staging or direct shared-memory IPC.
*   `a0`: Target child Context ID (`CID >= 2`).
*   `a1`: Base GPA in child address space.
*   `a2`: Destination GPA in parent address space.
*   `a3`: Mapping size in bytes.
*   `a4`: Permission flags.
*   **Returns**: `SBI_SUCCESS` (`0`) on success, or an error code on failure.

#### `UNMAP_CHILD_MEM` (`FID 14`)
Revokes a foreign child memory mapping from the parent VM's Stage-2 address space.
*   `a0`: Parent GPA base address to unmap.
*   `a1`: Unmapping size in bytes.
*   **Returns**: `SBI_SUCCESS` (`0`) on success.

#### `START` (`FID 15`)
Starts execution of a child VM's virtual cores at a specified entry point and DTB.
*   `a0`: Target child Context ID (`CID >= 2`).
*   `a1`: Initial entry point GPA.
*   `a2`: Initial Device Tree Blob (DTB) GPA.
*   **Returns**: `SBI_SUCCESS` (`0`) on success.

#### `NET_SEND` (`FID 16`)
Transmits a raw Ethernet frame to a target child VM, parent VM, or broadcast.
*   `a0`: GPA pointer to packet payload buffer.
*   `a1`: Packet length in bytes (up to 1536 bytes).
*   `a2`: Destination Context ID (`0` for broadcast, `1` or `parent` for parent, `2..N` for child).
*   **Returns**: `SBI_SUCCESS` (`0`) on success.

#### `NET_RECV` (`FID 17`)
Retrieves the next pending Ethernet frame from the VM's receive ring buffer.
*   `a0`: GPA pointer to destination receive buffer.
*   `a1`: Capacity of destination receive buffer in bytes.
*   **Returns**: `SBI_SUCCESS` (`0`) on success with copied packet length in `a1`,
    or `0` in `a1` if the receive queue is empty.

#### `NET_POLL` (`FID 18`)
Queries the number of unread Ethernet frames in the VM's receive ring buffer.
*   **Returns**: `SBI_SUCCESS` (`0`) on success with unread packet count in `a1`.

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
*   `CAP_DYNAREC` (`1 << 2`): Transparent JIT cross-architecture emulation available.
*   `CAP_VIRTIO_VSOCK` (`1 << 3`): In-hypervisor zero-copy VirtIO-vsock (`AF_VSOCK`) socket networking active.
*   `CAP_IOMMU` (`1 << 4`): Hardware Stage-2 DMA / IOMMU protection active.

### `RunArgs`
```c
struct run_args {
    unsigned long child_id;    /* Target child Context ID (0 = new child, >= 2 = reload) */
    unsigned long elf_ptr;     /* GPA pointer to ELF binary buffer */
    unsigned long elf_size;    /* Size of ELF binary in bytes */
    unsigned long dtb_ptr;     /* GPA pointer to DTB buffer (or 0) */
    unsigned long dtb_size;    /* Size of DTB in bytes */
    unsigned long target_arch; /* Target architecture enum */
    unsigned long flags;       /* Flags: RUN_FLAG_TRUSTED (1 << 0) */
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

### `Event` and `EventType`
```c
enum event_type {
    EVENT_NONE             = 0,
    EVENT_CHILD_TERMINATED = 1,
    EVENT_CHILD_STOPPED    = 2,
    EVENT_CHILD_STARTED    = 3,
};

struct diosix_event {
    unsigned long cid;         /* Source Context ID */
    uint32_t      event_type;  /* Value from enum event_type */
    uint32_t      exit_code;   /* Exit code */
    uint64_t      _reserved;   /* Alignment padding */
};
```

### `ManifestArgs`
```c
struct manifest_args {
    unsigned long target_cid;   /* 1 for self (GET only), >= 2 for child */
    unsigned long manifest_ptr; /* GPA pointer to manifest UTF-8 string */
    unsigned long manifest_len; /* Buffer capacity or string length (up to 64 KiB) */
    unsigned long actual_len;   /* Output: Staged manifest length */
};
```

---

## Linux kernel driver interface (`/dev/diosix`)

Inside Linux guest VMs, the `diosix` character device driver bridges userspace 
calls to hypervisor SBI extensions via standard `ioctl` numbers:

| IOCTL Name | Value | Description |
| :--- | :--- | :--- |
| `IOCTL_DROP_TRUST` | `0x1002` | Relinquishes hardware trust |
| `IOCTL_RUN` | `0x1003` | Loads ELF and boots child VM |
| `IOCTL_GET_INFO` | `0x1004` | Queries current VM info |
| `IOCTL_SET_QUOTA` | `0x1005` | Updates resource quotas |
| `IOCTL_TERMINATE` | `0x1006` | Terminates self or child VM |
| `IOCTL_WAIT_EVENT` | `0x1008` | Blocks/polls for asynchronous events |
| `IOCTL_GET_HV_INFO` | `0x100B` | Queries hypervisor and host system info |
| `IOCTL_GET_MANIFEST` | `0x100C` | Reads the staged manifest from the hypervisor |
| `IOCTL_SET_MANIFEST` | `0x100D` | Stages an attenuated manifest for a child VM |
| `IOCTL_MAP_CHILD_MEM` | `0x100E` | Maps child VM memory into parent address space |
| `IOCTL_UNMAP_CHILD_MEM` | `0x100F` | Unmaps child VM foreign memory region |
| `IOCTL_START` | `0x1010` | Starts child VM at specified entry point and DTB |
