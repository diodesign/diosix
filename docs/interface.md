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
*   **`TIMER` (`0x54494D45`)**: Programs the timer comparator register for
    guest timer interrupts.
*   **`SRST` (`0x53525354`)**: System Reset Extension for powering off or
    rebooting the host system (restricted to the Root VM).
*   **`HSM` (`0x48534D`)**: Hart State Management for starting, stopping, and
    querying the status of secondary Virtual CPU (VCPU) cores.
*   **`DBCN` (`0x4442434E`)**: Debug Console Extension for early character and
    string I/O over the console.

---

## Diosix custom SBI extension (`0x0A000005` / `0x0A000008`)

The custom Diosix extension provides hypervisor-level lifecycle management,
resource quota controls, inter-VM communication, event notifications, and
M-mode Constitutional Charter governance.

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
| `SET_MANIFEST` | `12` | Stage attenuated capability manifest for child VM |
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
Memory-Mapped Input/Output (MMIO) and blocking direct interrupt routing.
*   **Returns**: `SBI_SUCCESS` (`0`).

#### `RUN` (`FID 4`)
Loads an Executable and Linkable Format (ELF) binary and an optional Device
Tree Blob (DTB) into a child VM's address space, resetting its primary VCPU
to the entry point.
*   `a0`: GPA pointing to `RunArgs` struct.
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
*   `a1`: GPA pointer to a destination `GuestInfo` struct.
*   `a2`: Size of the `GuestInfo` buffer in bytes.
*   **Returns**: `SBI_SUCCESS` (`0`) on success, `SBI_ERR_DENIED` if `a0` is
    `0`, `SBI_ERR_INVALID_PARAM` if the target CID does not exist or the buffer
    is too small, or `SBI_ERR_INVALID_ADDRESS` if the GPA pointer is invalid.

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
*   **Returns**: `SBI_SUCCESS` (`0`) on success, `SBI_ERR_DENIED` if not a
    direct parent, or `SBI_ERR_INVALID_PARAM` if the manifest exceeds 64 KiB.

#### `MAP_CHILD_MEM` (`FID 13`)
Maps a direct child VM's physical RAM region into the parent VM's Stage-2 GPA
address space for zero-copy binary staging or direct shared-memory IPC.
*   `a0`: Target child CID (`CID >= 2`).
*   `a1`: Base GPA in child address space.
*   `a2`: Destination GPA in parent address space.
*   `a3`: Mapping size in bytes.
*   `a4`: Permission flags.
*   **Returns**: `SBI_SUCCESS` (`0`) on success, or `SBI_ERR_DENIED` if the
    child VM is marked `CONFIDENTIAL` and the Charter is sealed.

#### `UNMAP_CHILD_MEM` (`FID 14`)
Revokes a foreign child memory mapping from the parent VM's Stage-2 address
space.
*   `a0`: Parent GPA base address to unmap.
*   `a1`: Unmapping size in bytes.
*   **Returns**: `SBI_SUCCESS` (`0`) on success.

#### `START` (`FID 15`)
Starts execution of a child VM's virtual cores at a specified entry point and
DTB.
*   `a0`: Target child CID (`CID >= 2`).
*   `a1`: Initial entry point GPA.
*   `a2`: Initial DTB GPA.
*   **Returns**: `SBI_SUCCESS` (`0`) on success.

#### `NET_SEND` (`FID 16`), `NET_RECV` (`FID 17`), and `NET_POLL` (`FID 18`)
Transmit, receive, and poll raw Ethernet frames (up to 1536 bytes) across the
in-hypervisor virtual switch between parent and child VMs.

#### `SEAL_CHARTER` (`FID 19`) and `RATIFY_CHARTER` (`FID 20`)
*   `SEAL_CHARTER`: Seals or queries (`op == 0`) the 256-bit SHA-256 digest and
    M-of-N Steward quorum parameters of the Constitutional Charter in M-mode
    using `struct charter_args`.
*   `RATIFY_CHARTER`: Records a Steward VM's ratification vote in M-mode for a
    proposed Charter amendment, Steward termination/reset, or Root VM failover.
    Restricted strictly to Steward VMs (`CID 2..63`); the Root VM cannot vote.

#### `WHISPER_SEND` (`FID 21`) and `WHISPER_RECV` (`FID 22`)
Transmit and receive uncensorable Steward Whisper consensus messages (up to
512 bytes) across the M-mode Whisper ring buffer using `struct whisper_args`.

#### `RESET_STEWARD` (`FID 23`) and `REQUEST_ROOT_FAILOVER` (`FID 24`)
*   `RESET_STEWARD`: Resets a compromised or drifted Steward VM (`a0 = cid`)
    back to its initial entry point after M-of-N Steward ratification.
*   `REQUEST_ROOT_FAILOVER`: Promotes a warm Standby Root VM (`a0 = cid`) to
    become the active Root VM after M-of-N Steward ratification, re-parenting
    all surviving subtrees without rebooting the host.

---

## Data structure layouts

All structures passed across the 64-bit RISC-V hypercall boundary use standard
C ABI alignment with explicit fixed-width `uint64_t` (`u64`) fields.

### `GuestInfo`
```c
struct guest_info {
    uint64_t guest_id;       /* Context ID (1 for caller, or child CID) */
    uint64_t parent_id;      /* Parent Context ID (0 for caller's parent) */
    uint8_t  is_trusted;     /* 1 if trusted for MMIO, 0 otherwise */
    uint8_t  is_root;        /* 1 if Root VM, 0 otherwise */
    uint8_t  target_arch;    /* 0=rv64, 1=rv32, 2=aarch64, 3=x86_64 */
    uint8_t  assigned_cid;   /* Handle assigned to this VM by its parent */
    uint8_t  _pad[4];        /* Explicit 8-byte alignment padding */
    uint64_t vcpus;          /* VM's own active Virtual CPUs */
    uint64_t self_ram_pages; /* VM's own allocated 4 KB RAM pages */
    uint64_t used_vcpus;     /* Total subtree VCPUs consumed */
    uint64_t max_vcpus;      /* Maximum VCPUs quota ceiling */
    uint64_t used_ram_pages; /* Total subtree 4 KB RAM pages consumed */
    uint64_t max_ram_pages;  /* Maximum 4 KB RAM page quota ceiling */
    uint64_t child_count;    /* Number of active child VMs */
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
*   `CAP_DYNAREC` (`1 << 2`): Transparent JIT cross-arch emulation available.
*   `CAP_VIRTIO_VSOCK` (`1 << 3`): In-hypervisor VirtIO-vsock active.
*   `CAP_IOMMU` (`1 << 4`): Hardware Stage-2 DMA / IOMMU protection active.
*   `CAP_RELEASE_STABLE` (`1 << 5`): Running a Stable channel release
    (`version_minor % 2 == 0`); clear on Beta releases.
*   `CAP_CHARTER_SEALED` (`1 << 6`): Cryptographically signed Principal Charter
    sealed in M-mode.

### `RunArgs`, `QuotaArgs`, `ManifestArgs`, `CharterArgs`, and `WhisperArgs`
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

struct quota_args {
    uint64_t target_cid;      /* 1 for self, >= 2 for child */
    uint64_t max_ram_pages;   /* RAM ceiling in 4 KB pages (0 = unchanged) */
    uint64_t max_vcpus;       /* VCPU limit (0 = unchanged) */
    uint64_t max_child_depth; /* Maximum nesting depth (0 = unchanged) */
    uint64_t max_descendants; /* Total descendant limit (0 = unchanged) */
};

struct manifest_args {
    uint64_t target_cid;   /* 1 for self (GET only), >= 2 for child */
    uint64_t manifest_ptr; /* GPA pointer to manifest UTF-8 string */
    uint64_t manifest_len; /* Buffer capacity or string length (<= 64 KiB) */
    uint64_t actual_len;   /* Output: Staged manifest length */
};

struct charter_args {
    uint8_t  charter_hash[32]; /* SHA-256 digest of charter.toml */
    uint16_t quorum_required;  /* M required Steward votes */
    uint16_t quorum_total;     /* N total Steward nodes */
    uint16_t min_stewards;     /* Minimum protected Steward floor */
    uint16_t standby_replicas; /* Standby Root VM count */
    uint64_t flags;            /* Output: 1 if sealed, 0 otherwise */
    uint64_t ratify_mask;      /* Output: Bitmask of Steward ratifications */
    uint64_t failover_epoch;   /* Output: Standby Root failover epoch */
};

struct whisper_args {
    uint64_t target_cid;  /* 0 = broadcast to Stewards, >= 2 = target CID */
    uint64_t sender_cid;  /* Output on RECV: sender Steward CID */
    uint64_t msg_ptr;     /* GPA pointer to message buffer */
    uint64_t msg_len;     /* Message length in bytes (<= 512 bytes) */
    uint64_t msg_type;    /* Whisper message type (0=heartbeat, 1=propose...) */
};
```

---

## Linux kernel driver interface (`/dev/diosix`)

Inside Linux guest VMs, the `diosix` character device driver (`tools/driver/`)
bridges userspace calls to hypervisor SBI extensions via standard `ioctl`
numbers:

| IOCTL Name | Value | Description |
| :--- | :--- | :--- |
| `IOCTL_DROP_TRUST` | `0x1002` | Relinquishes hardware trust |
| `IOCTL_RUN` | `0x1003` | Loads ELF and boots child VM |
| `IOCTL_GET_INFO` | `0x1004` | Queries current or child VM info |
| `IOCTL_SET_QUOTA` | `0x1005` | Updates resource quotas |
| `IOCTL_TERMINATE` | `0x1006` | Terminates self or child VM |
| `IOCTL_WAIT_EVENT` | `0x1008` | Polls for asynchronous VM lifecycle events |
| `IOCTL_GET_HV_INFO` | `0x100B` | Queries hypervisor and host system info |
| `IOCTL_GET_MANIFEST` | `0x100C` | Reads staged manifest from the hypervisor |
| `IOCTL_SET_MANIFEST` | `0x100D` | Stages attenuated manifest for a child VM |
| `IOCTL_MAP_CHILD_MEM` | `0x100E` | Maps child VM memory into parent GPA space |
| `IOCTL_UNMAP_CHILD_MEM` | `0x100F` | Unmaps child VM foreign memory region |
| `IOCTL_START` | `0x1010` | Starts child VM at specified entry and DTB |
| `IOCTL_SEAL_CHARTER` | `0x1014` | Seals or queries Charter hash in M-mode |
| `IOCTL_RATIFY_CHARTER` | `0x1015` | Casts Steward ratification vote in M-mode |
| `IOCTL_WHISPER_SEND` | `0x1016` | Sends Steward Whisper frame via M-mode ring |
| `IOCTL_WHISPER_RECV` | `0x1017` | Receives Steward Whisper frame from M-mode |
| `IOCTL_RESET_STEWARD` | `0x1018` | Resets compromised Steward VM |
| `IOCTL_REQUEST_ROOT_FAILOVER` | `0x1019` | Promotes Standby Root VM on failover |
