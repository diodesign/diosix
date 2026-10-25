# Diosix shared interface and ABI

The Diosix hypervisor provides a standardized Application Binary Interface
(ABI) and Supervisor Binary Interface (SBI) to facilitate communication
between the hypervisor, guest operating system kernels, and userspace tools.

The hypervisor core exposes these definitions through the `interface` module
located in `hypervisor/interface/`.

---

## Calling convention and registers

Diosix implements the standard RISC-V SBI specification. Guest operating
systems execute an `ecall` instruction from Supervisor mode (S-mode) to
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
*   `SBI_ERR_INVALID_ADDRESS` (`-5`): Invalid memory address or unmapped Guest
    Physical Address (GPA).
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
*   **`TIMER` (`0x54494d45`)**: Programs the timer comparator register for
    guest timer interrupts.
*   **`SRST` (`0x53525354`)**: System Reset Extension for powering off or
    rebooting the host system (restricted to the Root VM).
*   **`HSM` (`0x48534d`)**: Hart State Management for starting, stopping, and
    querying the status of secondary Virtual CPU (VCPU) cores.
*   **`DBCN` (`0x4442434e`)**: Debug Console Extension for early character and
    string Input/Output (I/O) over the console.

---

## Diosix custom SBI extension (`0x0a000005`)

The custom Diosix extension provides hypervisor-level lifecycle management,
Executable and Linkable Format (ELF) and Device Tree Blob (DTB) loading,
Memory-Mapped I/O (MMIO) trust control, resource quota controls, inter-VM
communication, event notifications, and Machine-mode (M-mode) Constitutional
Charter governance.

### Function summary

| Function | FID | Description |
| :--- | :--- | :--- |
| `TERMINATE` | `0` | Terminate self (`CID 1`) or child (`CID >= 2`) |
| `YIELD` | `1` | Voluntarily yield remaining VCPU quantum |
| `DROP_TRUST` | `3` | Irrevocably surrender hardware trust and MMIO |
| `RUN` | `4` | Load guest ELF and DTB into child VM and start |
| `GET_INFO` | `5` | Retrieve VM metadata, quotas, and child count |
| `SET_QUOTA` | `6` | Set or clamp RAM, VCPU, and descendant quotas |
| `POLL_EVENT` | `9` | Pop oldest event from the VM's event queue |
| `GET_HV_INFO` | `10` | Retrieve hypervisor version, ABI, and host specs |
| `GET_MANIFEST` | `11` | Retrieve staged capability manifest |
| `SET_MANIFEST` | `12` | Stage capability manifest for self or child VM |
| `MAP_CHILD_MEM` | `13` | Map child VM RAM into parent Stage-2 GPA space |
| `UNMAP_CHILD_MEM` | `14` | Revoke foreign memory mapping from parent GPA |
| `START` | `15` | Boot child VM VCPUs at specified entry and DTB |
| `NET_SEND` | `16` | Transmit Ethernet frame to child, parent, or all |
| `NET_RECV` | `17` | Retrieve incoming Ethernet frame from RX ring |
| `NET_POLL` | `18` | Query number of queued incoming Ethernet frames |
| `SEAL_CHARTER` | `19` | Seal Constitutional Charter hash in M-mode |
| `RATIFY_CHARTER` | `20` | Cast Steward M-of-N ratification vote in M-mode |
| `WHISPER_SEND` | `21` | Send Steward Whisper consensus frame via M-mode |
| `WHISPER_RECV` | `22` | Receive Steward Whisper frame from M-mode ring |
| `RESET_STEWARD` | `23` | Reset compromised Steward VM after M-of-N vote |
| `REQUEST_ROOT_FAILOVER` | `24` | Promote Standby Root VM after M-of-N vote |

---

### Function details

#### `TERMINATE` (`FID 0`)
Terminates a target VM and recursively tears down all of its descendants.
*   `a0`: Target CID (`1` for self, `2..N` for a direct child).
*   `a1`: Exit code (reported to the parent's event queue).
*   **Returns**: Does not return if terminating self (`CID 1`). Returns
    `SBI_SUCCESS` upon terminating a child (or `SBI_ERR_DENIED` if targeting a
    protected Steward VM when the Charter is sealed without M-of-N quorum).

#### `YIELD` (`FID 1`)
Relinquishes the current VCPU's time slice to allow other ready VCPUs to run.
*   **Returns**: `SBI_SUCCESS` (`0`).

#### `DROP_TRUST` (`FID 3`)
Irrevocably revokes hardware trust for the calling VM, unmapping host physical
MMIO and blocking direct interrupt routing.
*   **Returns**: `SBI_SUCCESS` (`0`).

#### `RUN` (`FID 4`)
Loads an ELF binary and an optional DTB into a child VM's address space,
resetting its primary VCPU to the entry point.
*   `a0`: GPA pointing to `struct run_args` (`RunArgs`).
*   **Behavior**: When `child_id == 0`, the hypervisor atomically allocates a
    new child VM and boots the image directly. When `child_id >= 2`, the
    hypervisor resets and reboots the specified existing child VM.
*   **Flags (`RunArgs.flags`)**:
    *   `RUN_FLAG_TRUSTED` (`1 << 0`): Grants hardware MMIO access if and only
        if the caller is hardware-trusted.
    *   `RUN_FLAG_STEWARD` (`1 << 1`): Marks the child VM as a Tier-1 Autonomic
        Steward protected by M-mode Charter quorum rules.
    *   `RUN_FLAG_STANDBY_ROOT` (`1 << 2`): Marks the child VM as a warm
        Standby Root replica eligible for M-mode failover promotion.
    *   `RUN_FLAG_CONFIDENTIAL` (`1 << 3`): Protects the child VM's RAM from
        parent `MAP_CHILD_MEM` inspection once the Charter is sealed.
*   **Returns**: `SBI_SUCCESS` (`0`) in `a0` on success with the child CID in
    `a1`, or an error code on failure.

#### `GET_INFO` (`FID 5`)
Queries execution state, resource limits, and metadata for the calling VM or a
direct child VM.
*   `a0`: Target CID (`1` for self, `2..N` for a direct child). Target CID `0`
    (the caller's parent) is not inspectable and returns `SBI_ERR_DENIED`.
*   `a1`: GPA pointer to a destination `struct guest_info` (`GuestInfo`).
*   `a2`: Size of the `GuestInfo` buffer in bytes.
*   **Returns**: `SBI_SUCCESS` (`0`) on success, `SBI_ERR_DENIED` if `a0` is
    `0`, `SBI_ERR_INVALID_PARAM` if the target CID does not exist or the buffer
    is too small, or `SBI_ERR_INVALID_ADDRESS` if the GPA pointer is invalid.

#### `SET_QUOTA` (`FID 6`)
Applies or updates resource quotas on a target VM.
*   `a0`: GPA pointer to a `struct quota_args` (`QuotaArgs`).
*   **Permissions and physical vs. logical separation**:
    *   A parent VM may set or re-dial physical quotas (`pcpu_quota_pct` and
        `max_ram_pages`) on direct children (`CID >= 2`) at any time, or lower
        its own quotas (`CID 1`) to sandbox itself. Calls targeting `CID 0`
        (parent) return `SBI_ERR_DENIED`.
    *   A parent VM can allocate up to **90% total**
        (`MAX_CHILD_PCPU_QUOTA_PCT`) of its own pCPU quota across all of its
        direct children combined, retaining at least 10% (plus any unallocated
        share) for itself.
    *   For H-extension guests (`Sv39x4`), physical RAM is demand-paged from the
        quota pool; if faulted-in pages exceed `max_ram_pages` or if a parent
        dials `max_ram_pages` below the child's currently in-use pages, the
        hypervisor queues `child_memory_pressure` (`4`) and terminates the
        child. For Physical Memory Protection (PMP) guests, in-use memory is
        fixed at logical RAM size (`logical_ram_pages`), and exceeding available
        RAM quota at creation fails immediately with `SBI_ERR_DENIED`.

#### `POLL_EVENT` (`FID 9`)
Pops the oldest pending event from the VM's event queue.
*   `a0`: GPA pointer to a destination `struct diosix_event` (`Event`).
*   `a1`: Size of the `Event` buffer in bytes.
*   `a2`: Target CID filter (`0` for any source CID, or a specific child CID).
*   **Returns**: `SBI_SUCCESS` (`0`) in `a0`, with `value = 1` in `a1` if an
    event was popped or `value = 0` if no matching event was queued.

#### `GET_HV_INFO` (`FID 10`)
Retrieves hypervisor build metadata, ABI semantic version, host physical
hardware specifications, and feature capability flags.
*   `a0`: GPA pointer to a destination `struct hypervisor_info`
    (`HypervisorInfo`).
*   `a1`: Size of the `HypervisorInfo` buffer in bytes.
*   **Returns**: `SBI_SUCCESS` (`0`) on success.

#### `GET_MANIFEST` (`FID 11`)
Retrieves the staged capability manifest string from hypervisor memory for the
calling VM (`CID 1`) or a direct child VM (`CID >= 2`).
*   `a0`: GPA pointer to a `struct manifest_args` (`ManifestArgs`).
*   **Returns**: `SBI_SUCCESS` (`0`) in `a0` and the number of bytes copied in
    `a1`, with `actual_len` populated in the argument structure.

#### `SET_MANIFEST` (`FID 12`)
Stages a capability manifest string in hypervisor memory for the calling VM
(`CID 1`) or a direct child VM (`CID >= 2`).
*   `a0`: GPA pointer to a `struct manifest_args` (`ManifestArgs`).
*   **Returns**: `SBI_SUCCESS` (`0`) on success, `SBI_ERR_DENIED` if the caller
    is untrusted and not the target's parent, or `SBI_ERR_INVALID_PARAM` if the
    manifest is empty or exceeds `1 MiB` (`1048576` bytes).

#### `MAP_CHILD_MEM` (`FID 13`)
Maps a direct child VM's physical RAM region into the parent VM's Stage-2 GPA
address space for zero-copy binary staging or direct shared-memory
Inter-Process Communication (IPC).
*   `a0`: GPA pointer to a `struct map_child_mem_args` (`MapChildMemArgs`).
*   **Returns**: `SBI_SUCCESS` (`0`) in `a0` and the mapped byte count in `a1`
    on success, or `SBI_ERR_DENIED` if the child VM is marked `CONFIDENTIAL`
    and the Charter is sealed.

#### `UNMAP_CHILD_MEM` (`FID 14`)
Revokes a foreign child memory mapping from the parent VM's Stage-2 address
space.
*   `a0`: GPA pointer to a `struct unmap_child_mem_args` (`UnmapChildMemArgs`).
*   **Returns**: `SBI_SUCCESS` (`0`) on success.

#### `START` (`FID 15`)
Starts execution of a child VM's virtual cores at a specified entry point and
DTB.
*   `a0`: GPA pointer to a `struct start_args` (`StartArgs`).
*   **Returns**: `SBI_SUCCESS` (`0`) in `a0` and the started child CID in `a1`
    on success.

#### `NET_SEND` (`FID 16`), `NET_RECV` (`FID 17`), and `NET_POLL` (`FID 18`)
Transmit, receive, and poll raw Ethernet frames (up to 1536 bytes) across the
in-hypervisor virtual switch between parent and child VMs.
*   `NET_SEND`: `a0` = frame buffer GPA, `a1` = frame length in bytes
    (`1..1536`), `a2` = destination CID (`0` for broadcast, `1` for parent,
    `>= 2` for child).
*   `NET_RECV`: `a0` = destination buffer GPA, `a1` = maximum buffer length in
    bytes; returns copied byte count in `a1`.
*   `NET_POLL`: Returns the number of queued incoming frames in `a1`.

#### `SEAL_CHARTER` (`FID 19`) and `RATIFY_CHARTER` (`FID 20`)
*   `SEAL_CHARTER`: Seals or queries the 256-bit Secure Hash Algorithm 256
    (SHA-256) digest and M-of-N Steward quorum parameters of the Constitutional
    Charter in M-mode.
    *   `a0`: GPA pointer to `struct charter_args` (`CharterArgs`).
    *   `a1`: Operation mode (`0` to query current Charter state into `a0`, `1`
        to seal or amend the Charter in M-mode).
    *   **Returns**: `SBI_SUCCESS` (`0`) in `a0` and `is_sealed` (`1` or `0`) in
        `a1`.
*   `RATIFY_CHARTER`: Records a Steward VM's ratification vote in M-mode for a
    proposed Charter amendment, Steward termination or reset, or Root VM
    failover. Restricted strictly to Steward VMs (`CID 2..63`); the Root VM
    cannot vote.
    *   `a0`: Target CID being ratified (`1` for Root VM failover or Charter
        amendment, `>= 2` for a specific Steward CID).
    *   **Returns**: `SBI_SUCCESS` (`0`) in `a0` and the current vote count for
        `target_cid` in `a1`, or `SBI_ERR_DENIED` if the caller is not a
        Steward VM.

#### `WHISPER_SEND` (`FID 21`) and `WHISPER_RECV` (`FID 22`)
Transmit and receive uncensorable Steward Whisper consensus messages (up to
1536 bytes) across the M-mode Whisper ring buffer.
*   `WHISPER_SEND`:
    *   `a0`: Source message buffer GPA.
    *   `a1`: Message length in bytes (`1..1536`).
    *   `a2`: Destination CID (`0` to broadcast to all sibling Steward VMs, `1`
        for the Root VM, or `>= 2` for a specific Steward VM).
    *   **Returns**: `SBI_SUCCESS` (`0`) in `a0` and `msg_len` in `a1`.
*   `WHISPER_RECV`:
    *   `a0`: Destination message buffer GPA.
    *   `a1`: Maximum receive length in bytes (clamped to `1536`).
    *   **Returns**: `SBI_SUCCESS` (`0`) in `a0` and the received byte count in
        `a1` (`0` if the queue is empty).

#### `RESET_STEWARD` (`FID 23`) and `REQUEST_ROOT_FAILOVER` (`FID 24`)
*   `RESET_STEWARD`: Resets a compromised or drifted Steward VM back to its
    initial entry point after M-of-N Steward ratification.
    *   `a0`: Target Steward CID (`>= 2`).
    *   `a1`: Optional override entry point GPA (`0` to use the Steward VM's
        configured initial entry point).
    *   **Returns**: `SBI_SUCCESS` (`0`) in `a0` and the updated Steward reset
        count in `a1`.
*   `REQUEST_ROOT_FAILOVER`: Promotes a warm Standby Root VM to become the
    active Root VM after M-of-N Steward ratification, re-parenting all
    surviving subtrees without rebooting the host.
    *   `a0`: Target Standby Root CID (`0` for the first available Standby Root
        VM, or `>= 2` for a specific Standby Root CID).
    *   **Returns**: `SBI_SUCCESS` (`0`) in `a0` and the incremented
        `failover_epoch` in `a1`.

---

## Data structure layouts

All structures passed across the 64-bit RISC-V hypercall boundary use standard
C ABI alignment with explicit fixed-width `uint64_t` (`u64`) fields.

### `GuestInfo`
```c
struct guest_info {
    uint64_t guest_id;            /* Context ID (1 for caller, or child CID) */
    uint64_t parent_id;           /* Parent Context ID (0 for caller parent) */
    uint8_t  is_trusted;          /* 1 if trusted for MMIO, 0 otherwise */
    uint8_t  is_root;             /* 1 if Root VM, 0 otherwise */
    uint8_t  target_arch;         /* 0=rv64, 1=rv32, 2=aarch64, 3=x86_64 */
    uint8_t  assigned_cid;        /* Handle assigned to VM by its parent */
    uint8_t  _pad[4];             /* Explicit 8-byte alignment padding */
    uint64_t vcpus;               /* VM's own logical Virtual CPUs */
    uint64_t self_ram_pages;      /* VM's own logical 4 KB RAM pages */
    uint64_t used_vcpus;          /* Total subtree VCPUs consumed */
    uint64_t max_vcpus;           /* Maximum VCPUs quota ceiling */
    uint64_t used_ram_pages;      /* Total subtree 4 KB RAM pages faulted in */
    uint64_t max_ram_pages;       /* Physical 4 KB RAM page quota pool */
    uint64_t child_count;         /* Number of active child VMs */
    uint32_t pcpu_quota_pct;      /* Granted physical CPU time % (1..100) */
    uint32_t delegated_pcpu_pct;  /* Total pCPU % delegated to children */
    uint64_t delegated_ram_pages; /* Total 4 KB RAM pages granted to children */
};
```

### `HypervisorInfo`
```c
struct hypervisor_info {
    uint16_t abi_version_major;   /* e.g., 0 */
    uint16_t abi_version_minor;   /* e.g., 2 */
    uint16_t abi_version_patch;   /* e.g., 0 */
    uint16_t version_major;       /* Diosix release major (e.g., 26) */
    uint16_t version_minor;       /* Release minor (odd=Beta, even=Stable) */
    uint16_t version_patch;       /* Diosix release patch (e.g., 0, 1) */
    uint32_t _reserved1;
    char     build_commit[16];    /* Null-terminated git commit revision */
    uint64_t features;            /* Feature capability bitmask */
    uint32_t host_physical_cores; /* Number of physical host harts */
    uint32_t host_timer_freq_hz;  /* Hardware timer frequency in Hz */
    uint64_t host_total_ram_kb;   /* Total physical host RAM in KB */
    uint64_t host_free_ram_kb;    /* Available physical host RAM in KB */
    uint64_t hv_reserved_bytes;   /* Reserved M-mode hypervisor footprint */
    uint64_t hv_heap_free_bytes;  /* Available M-mode hypervisor heap */
    char     host_cpu_isa[32];    /* Null-terminated host ISA string */
    char     build_desc[192];     /* Null-terminated full build description */
};
```

### Capability feature flags
*   `CAP_HARDWARE_VIRT` (`1 << 0`): Hardware RISC-V H-extension active.
*   `CAP_STAGE2_PAGING` (`1 << 1`): Nested Stage-2 Sv39x4 paging active.
*   `CAP_DYNAREC` (`1 << 2`): Transparent Just-In-Time (JIT) cross-architecture
    emulation available.
*   `CAP_VIRTIO_VSOCK` (`1 << 3`): In-hypervisor VirtIO-vsock active.
*   `CAP_IOMMU` (`1 << 4`): Hardware Stage-2 Direct Memory Access (DMA) and
    Input-Output Memory Management Unit (IOMMU) protection active.
*   `CAP_RELEASE_STABLE` (`1 << 5`): Running a Stable channel release
    (`version_minor % 2 == 0`); clear on Beta releases.
*   `CAP_CHARTER_SEALED` (`1 << 6`): Cryptographically signed Principal Charter
    sealed in M-mode.

### Lifecycle, memory, manifest, and governance structures
```c
struct run_args {
    uint64_t child_id;    /* Target child CID (0 = new child, >= 2 = reload) */
    uint64_t elf_ptr;     /* GPA pointer to ELF binary buffer */
    uint64_t elf_size;    /* Size of ELF binary in bytes */
    uint64_t dtb_ptr;     /* GPA pointer to DTB buffer (or 0) */
    uint64_t dtb_size;    /* Size of DTB in bytes */
    uint64_t target_arch; /* Target architecture enum */
    uint64_t flags;       /* RunFlags bitmask (TRUSTED, STEWARD, etc.) */
};

struct terminate_args {
    uint64_t target_id; /* Target CID (1 for self, >= 2 for child) */
    uint64_t exit_code; /* Exit status code */
};

struct diosix_event {
    uint64_t cid;        /* Source child CID */
    uint32_t event_type; /* 0=none, 1=terminated, 2=stopped, 3=started, 4=oom */
    uint32_t exit_code;  /* Exit code or in-use page count on memory pressure */
    uint64_t _reserved;
};

struct wait_event_args {
    uint64_t            target_cid; /* 0 for any child, >= 2 for child CID */
    uint64_t            flags;      /* Bit 0: WAIT_EVENT_FLAG_NOHANG */
    struct diosix_event event;      /* Populated event output */
};

struct quota_args {
    uint64_t target_cid;        /* 1 for self, >= 2 for child */
    uint64_t max_ram_pages;     /* Physical RAM quota in 4 KB pages */
    uint64_t max_vcpus;         /* Logical VCPU count (0 = unchanged) */
    uint64_t max_child_depth;   /* Maximum nesting depth (0 = unchanged) */
    uint64_t max_descendants;   /* Total descendant limit (0 = unchanged) */
    uint64_t pcpu_quota_pct;    /* Physical CPU time % (1..90, 0 = unchanged) */
    uint64_t logical_ram_pages; /* Logical DTB RAM in 4 KB pages (0 = quota) */
};

struct manifest_args {
    uint64_t target_cid; /* 1 for self, >= 2 for child */
    uint64_t data_ptr;   /* GPA pointer to manifest UTF-8 buffer */
    uint64_t max_len;    /* Buffer capacity or string length (<= 1 MiB) */
    uint64_t actual_len; /* Output: Staged manifest length in bytes */
};

struct map_child_mem_args {
    uint64_t child_id;   /* Target child CID (>= 2) */
    uint64_t child_gpa;  /* Base GPA in child address space */
    uint64_t parent_gpa; /* Destination GPA in parent address space */
    uint64_t size;       /* Mapping size in bytes (page-aligned) */
    uint64_t flags;      /* Mapping permission flags */
};

struct unmap_child_mem_args {
    uint64_t parent_gpa; /* Parent GPA base address to unmap */
    uint64_t size;       /* Unmapping size in bytes (page-aligned) */
};

struct start_args {
    uint64_t child_id;    /* Target child CID (>= 2) */
    uint64_t entry_point; /* Initial entry point GPA */
    uint64_t dtb_ptr;     /* Initial DTB GPA */
};

struct charter_args {
    uint8_t  charter_hash[32];    /* SHA-256 digest of charter.toml */
    uint16_t quorum_required;     /* M required Steward votes */
    uint16_t quorum_total;        /* N total Steward nodes */
    uint16_t standby_replicas;    /* Standby Root VM count */
    uint8_t  is_sealed;           /* Output: 1 if sealed in M-mode, else 0 */
    uint8_t  _reserved;
    uint64_t ratified_mask;       /* Output: Bitmask of Steward votes */
    uint64_t approved_target_cid; /* Output: Target CID of latest vote */
    uint64_t failover_epoch;      /* Output: Standby Root failover epoch */
};
```

---

## Linux kernel driver interface (`/dev/diosix`)

Inside Linux guest VMs, the `diosix` character device driver (`tools/driver/`)
bridges userspace calls to hypervisor SBI extensions via standard Input/Output
Control (`ioctl`) command numbers:

| ioctl name | Value | Description |
| :--- | :--- | :--- |
| `IOCTL_DROP_TRUST` | `0x1002` | Relinquishes hardware trust |
| `IOCTL_RUN` / `IOCTL_SPAWN` | `0x1003` | Loads ELF and boots child VM |
| `IOCTL_GET_INFO` | `0x1004` | Queries current or child VM info |
| `IOCTL_SET_QUOTA` | `0x1005` | Updates resource quotas |
| `IOCTL_TERMINATE` / `IOCTL_EXIT` / `IOCTL_KILL` | `0x1006` | Terminates self or child VM |
| `IOCTL_YIELD` | `0x1007` | Yields remaining VCPU quantum |
| `IOCTL_WAIT_EVENT` | `0x1008` | Polls or waits for VM lifecycle events |
| `IOCTL_GET_HV_INFO` | `0x100b` | Queries hypervisor and host system info |
| `IOCTL_GET_MANIFEST` | `0x100c` | Reads staged manifest from the hypervisor |
| `IOCTL_SET_MANIFEST` | `0x100d` | Stages capability manifest for a VM |
| `IOCTL_MAP_CHILD_MEM` | `0x100e` | Maps child VM memory into parent GPA space |
| `IOCTL_UNMAP_CHILD_MEM` | `0x100f` | Unmaps child VM foreign memory region |
| `IOCTL_START` | `0x1010` | Starts child VM at specified entry and DTB |
| `IOCTL_SEAL_CHARTER` | `0x1011` | Seals Constitutional Charter hash in M-mode |
| `IOCTL_GET_CHARTER` | `0x1012` | Queries sealed Charter status from M-mode |
| `IOCTL_RATIFY_CHARTER` | `0x1013` | Casts Steward ratification vote in M-mode |
| `IOCTL_RESET_STEWARD` | `0x1014` | Resets compromised Steward VM |
| `IOCTL_REQUEST_ROOT_FAILOVER` | `0x1015` | Promotes Standby Root VM on failover |
