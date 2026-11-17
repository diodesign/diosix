# Diosix shared interface and ABI

The Diosix hypervisor defines a shared application binary interface (ABI) and
supervisor binary interface (SBI) for communication between machine mode
(M-mode), guest OS kernels, and userland tools. For the list of source files
implementing each interface layer, see the
[Feature support matrix](support-matrix.md).

---

## Calling convention and registers

Diosix follows the RISC-V SBI calling convention. Guest kernels execute an
`ecall` instruction from supervisor mode (S-mode) with arguments in `a0`
through `a5` and the extension and function selectors in `a7` and `a6`:

| Register | ABI role |
| :--- | :--- |
| `a7` (`x17`) | Extension ID (EID) |
| `a6` (`x16`) | Function ID (FID) |
| `a0` (`x10`) | Argument 0 / return error code |
| `a1` (`x11`) | Argument 1 / return value |
| `a2` (`x12`) | Argument 2 |
| `a3` (`x13`) | Argument 3 |
| `a4` (`x14`) | Argument 4 |
| `a5` (`x15`) | Argument 5 |

### SBI return error codes

| Constant | Value | Meaning |
| :--- | :--- | :--- |
| `SBI_SUCCESS` | `0` | Completed without error. |
| `SBI_ERR_FAILED` | `-1` | Operation failed. |
| `SBI_ERR_NOT_SUPPORTED` | `-2` | Extension or function not supported. |
| `SBI_ERR_INVALID_PARAM` | `-3` | Invalid parameter or size. |
| `SBI_ERR_DENIED` | `-4` | Permission or quota check failed. |
| `SBI_ERR_INVALID_ADDRESS` | `-5` | Invalid or unmapped guest physical address (GPA). |
| `SBI_ERR_ALREADY_AVAILABLE` | `-6` | Resource already active. |

---

## Relative context ID addressing

Guest virtual machines (VMs) never use global hypervisor IDs. Every inter-VM
hypercall addresses targets using relative context IDs (CIDs) scoped to the
calling VM:

| CID | Constant | Meaning |
| :--- | :--- | :--- |
| `0` | `CID_PARENT` | The caller's immediate parent VM. |
| `1` | `CID_SELF` | The calling VM itself. |
| `2..N` | `CID_FIRST_CHILD`+ | Direct child VMs created by the caller. |

A guest VM cannot address siblings, grandparents, or unrelated VM branches.

---

## Standard SBI extensions

Diosix implements seven RISC-V SBI v2.0 extensions alongside legacy SBI v0.1
(`0x00` through `0x08`):

| Extension | EID | Purpose |
| :--- | :--- | :--- |
| `BASE` | `0x10` | Probes supported SBI extensions, reports the SBI specification version, and returns the Diosix implementation ID (`5`). |
| `TIMER` | `0x54494d45` | Programs the guest timer comparator for timer interrupts. |
| `IPI` | `0x735049` | Sends inter-processor interrupts across guest virtual CPU (vCPU) cores. |
| `RFENCE` | `0x52464e43` | Executes remote instruction-cache and page-table fences across guest vCPUs. |
| `SRST` | `0x53525354` | Reboots or powers off the host (restricted to the top-level VM with no parent VM; triggers standby failover if that VM exits abnormally). |
| `HSM` | `0x48534d` | Starts, stops, and queries secondary vCPU cores via hart state management. |
| `DBCN` | `0x4442434e` | Reads and writes debug console bytes over M-mode console rings. |

---

## Diosix custom SBI extension

Extension `0x0a000005` provides VM lifecycle control, ELF and device tree blob
(DTB) loading, memory-mapped input/output (MMIO) trust management, subtree
quotas, inter-VM networking, console rings, guest desktop streaming, and M-mode
charter governance.

### Function summary

| Function | FID | Description |
| :--- | :--- | :--- |
| `TERMINATE` | `0` | Terminate self (`1`) or direct child (`>= 2`) |
| `YIELD` | `1` | Yield remaining vCPU time slice |
| `DROP_TRUST` | `3` | Permanently drop hardware trust and physical MMIO |
| `RUN` | `4` | Load guest ELF and DTB into child VM and start |
| `GET_INFO` | `5` | Query VM metadata, quotas, and child count |
| `SET_QUOTA` | `6` | Set or lower RAM, vCPU, and descendant quotas |
| `POLL_EVENT` | `9` | Pop oldest event from the caller's event queue |
| `GET_HV_INFO` | `10` | Query hypervisor version, ABI, and host hardware |
| `GET_MANIFEST` | `11` | Read staged capability manifest |
| `SET_MANIFEST` | `12` | Stage capability manifest for self or child VM |
| `MAP_CHILD_MEM` | `13` | Map child VM RAM into parent stage-2 GPA space |
| `UNMAP_CHILD_MEM` | `14` | Unmap foreign child RAM from parent GPA space |
| `START` | `15` | Boot child VM vCPUs at specified entry and DTB |
| `NET_SEND` | `16` | Send Ethernet frame to child, parent, or broadcast |
| `NET_RECV` | `17` | Read incoming Ethernet frame from RX ring |
| `NET_POLL` | `18` | Query queued incoming Ethernet frame count |
| `SEAL_CHARTER` | `19` | Seal or query charter hash and quorum in M-mode |
| `RATIFY_CHARTER` | `20` | Record steward quorum ratification vote in M-mode |
| `WHISPER_SEND` | `21` | Send steward whisper frame via M-mode ring |
| `WHISPER_RECV` | `22` | Read steward whisper frame from M-mode ring |
| `RESET_STEWARD` | `23` | Reset steward VM after steward quorum vote |
| `REQUEST_ROOT_FAILOVER` | `24` | Promote standby root VM after steward quorum vote |
| `CONSOLE_WRITE` | `25` | Write input bytes into child console RX ring |
| `CONSOLE_READ` | `26` | Read output bytes from VM console TX ring |
| `SET_NET_POLICY` | `27` | Configure child layer-2 (L2) isolation and router CID |
| `GPU_READ_SCANOUT` | `28` | Stream child VirtIO-GPU 2D scanout into parent GPAs |
| `INPUT_SEND_EVENT` | `29` | Inject Linux input events into child VirtIO-Input |
| `GPU_MAP_SCANOUT` | `30` | Map child VirtIO-GPU scanout read-only into parent GPA |
| `SEAL_MISSION` | `31` | Seal or amend Principal-signed Mission envelope (`MissionArgs`) |
| `VOTE_MISSION` | `32` | Cast conserved RAM quota-stake vote (`MissionVoteArgs`) |

---

### Function details

#### `TERMINATE` (`FID 0`)
Terminates the target VM and recursively tears down all of its descendants.
* `a0`: Target CID (`1` for self, `2..N` for a direct child).
* `a1`: Exit status code queued to the parent's event ring.

Does not return when terminating self (`1`). Returns `SBI_SUCCESS` when
terminating a child, or `SBI_ERR_DENIED` when targeting a protected steward VM
under a sealed charter without steward quorum ratification.

#### `YIELD` (`FID 1`) and `DROP_TRUST` (`FID 3`)
* `YIELD`: Gives up the current vCPU's remaining time slice so other runnable
  vCPUs can execute. Returns `SBI_SUCCESS`.
* `DROP_TRUST`: Permanently revokes hardware trust for the calling VM,
  unmapping host physical MMIO and disabling direct hardware interrupt routing.
  Returns `SBI_SUCCESS`.

#### `RUN` (`FID 4`)
Loads an ELF image into a child VM and resets its primary vCPU to the entry
point, passing `dtb_ptr` in `a1`. Register `a0` holds the GPA of
`struct run_args` (`RunArgs`).

When `child_id` is `0`, the hypervisor allocates a new child VM; when
`child_id` is `2` or higher, it resets and reloads that existing child VM. The
`target_arch` field accepts `0` (64-bit RISC-V) and `1` (32-bit RISC-V); `2`
and `3` return `SBI_ERR_NOT_SUPPORTED`.

The `flags` bitmask in `struct run_args` accepts:
* `RUN_FLAG_TRUSTED` (`1 << 0`): Grants hardware MMIO trust if the caller
  itself holds hardware trust.
* `RUN_FLAG_STEWARD` (`1 << 1`): Marks the child as a steward VM protected by
  M-mode charter quorum rules.
* `RUN_FLAG_STANDBY_ROOT` (`1 << 2`): Marks the child as a warm standby root VM
  eligible for failover promotion.
* `RUN_FLAG_CONFIDENTIAL` (`1 << 3`): Blocks parent `MAP_CHILD_MEM` access once
  a charter is sealed.
* `RUN_FLAG_NET_ISOLATED` (`1 << 4`): Air-gaps the child VM in M-mode so all
  Ethernet and virtual socket (vsock) frames are rejected.
* `RUN_FLAG_NET_UPSTREAM_SHIFT` (`16`, mask `0xffff`): Optional sibling router
  CID (`>= 2`) through which the child's L2 network and vsock traffic flows.

Returns `SBI_SUCCESS` in `a0` and the child CID in `a1`, or a negative error
code.

#### `GET_INFO` (`FID 5`)
Queries runtime state, quotas, and child counts for the calling VM or a direct
child VM.
* `a0`: Target CID (`1` for self, `2..N` for a direct child; `0` returns
  `SBI_ERR_DENIED`).
* `a1`: GPA pointer to `struct guest_info` (`GuestInfo`).
* `a2`: Destination buffer size in bytes.

Returns `SBI_SUCCESS` on success, `SBI_ERR_DENIED` if `a0` is `0`,
`SBI_ERR_INVALID_PARAM` if the CID is invalid or buffer too small, or
`SBI_ERR_INVALID_ADDRESS` on an unmapped GPA.

#### `SET_QUOTA` (`FID 6`)
Updates physical or logical resource quotas on a target VM, taking a GPA
pointer to `struct quota_args` (`QuotaArgs`) in `a0`:

* A parent VM can update physical quotas (`pcpu_quota_pct` and `max_ram_pages`)
  on direct children (`>= 2`) at any time, or lower its own quotas (`1`) to
  sandbox itself. Targeting `0` returns `SBI_ERR_DENIED`.
* A parent VM can delegate up to 90% (`MAX_CHILD_PCPU_QUOTA_PCT`) of its own
  physical CPU quota across all direct children combined, retaining at least
  10% for itself.
* On RISC-V hypervisor (H) extension hosts with Sv39x4 paging, physical RAM
  pages are allocated on demand from `max_ram_pages`. If faulted pages exceed
  `max_ram_pages`—or if a parent lowers `max_ram_pages` below a child's current
  usage—the hypervisor queues a memory-pressure event (`4`) and terminates the
  child. Under physical memory protection (PMP) fallback, RAM usage equals
  `logical_ram_pages` up front.

#### `POLL_EVENT` (`FID 9`)
Pops the oldest pending lifecycle event from the caller's event queue.
* `a0`: GPA pointer to `struct diosix_event` (`Event`).
* `a1`: Buffer size in bytes.
* `a2`: Child CID filter (`0` for any child, or `>= 2` for a specific child).

Returns `SBI_SUCCESS` in `a0`, with `1` in `a1` if the hypervisor popped an
event or `0` if no matching event was queued.

#### `GET_HV_INFO` (`FID 10`)
Reads hypervisor version numbers, ABI version, host core and RAM totals, and
capability flags.
* `a0`: GPA pointer to `struct hypervisor_info` (`HypervisorInfo`).
* `a1`: Buffer size in bytes.

Returns `SBI_SUCCESS` on success.

#### `GET_MANIFEST` (`FID 11`) and `SET_MANIFEST` (`FID 12`)
Read or stage a capability manifest buffer in hypervisor memory for self (`1`)
or a direct child (`>= 2`), taking a GPA pointer to `struct manifest_args`
(`ManifestArgs`) in `a0`.

`GET_MANIFEST` returns `SBI_SUCCESS` in `a0` and the copied byte count in `a1`
(populating `actual_len`). `SET_MANIFEST` returns `SBI_SUCCESS` on success,
`SBI_ERR_DENIED` if unauthorized, or `SBI_ERR_INVALID_PARAM` if empty or larger
than 1 MiB (1,048,576 bytes).

#### `MAP_CHILD_MEM` (`FID 13`) and `UNMAP_CHILD_MEM` (`FID 14`)
Map or unmap a direct child VM's physical RAM inside the parent VM's stage-2
GPA space for image loading or shared-memory inter-process communication (IPC):
* `MAP_CHILD_MEM`: `a0` points to `struct map_child_mem_args`
  (`MapChildMemArgs`). Returns `SBI_SUCCESS` and mapped byte count in `a1`, or
  `SBI_ERR_DENIED` if the child is confidential under a sealed charter.
* `UNMAP_CHILD_MEM`: `a0` points to `struct unmap_child_mem_args`
  (`UnmapChildMemArgs`). Returns `SBI_SUCCESS` on success.

#### `START` (`FID 15`)
Starts a child VM's vCPUs at a given entry GPA and DTB GPA, taking a GPA
pointer to `struct start_args` (`StartArgs`) in `a0`. Returns `SBI_SUCCESS` in
`a0` and the started child CID in `a1`.

#### `NET_SEND` (`FID 16`), `NET_RECV` (`FID 17`), and `NET_POLL` (`FID 18`)
Send, receive, and poll raw Ethernet frames (1 to 1,536 bytes) across the
M-mode virtual switch:
* `NET_SEND`: `a0` holds the frame GPA, `a1` the byte length, and `a2` the
  destination CID (`0` for broadcast, `1` for parent, `>= 2` for a child).
* `NET_RECV`: `a0` holds the destination buffer GPA and `a1` the maximum byte
  length; returns copied bytes in `a1`.
* `NET_POLL`: Returns queued incoming frame count in `a1`.

#### `SEAL_CHARTER` (`FID 19`) and `RATIFY_CHARTER` (`FID 20`)
* `SEAL_CHARTER`: Queries (`a1 = 0`) or seals (`a1 = 1`) the SHA-256 charter
  digest and steward quorum settings in `struct charter_args` (`a0`). Returns
  `is_sealed` (`1` or `0`) in `a1`.
* `RATIFY_CHARTER`: Records a steward VM's ratification vote for `target_cid`
  (`a0 = 1` for root failover or charter amendment, `>= 2` for a steward CID).
  Only steward VMs (CIDs 2 through 63) can call `RATIFY_CHARTER`; calls from
  CID 1 return `SBI_ERR_DENIED`. Returns current vote count in `a1`.

#### `WHISPER_SEND` (`FID 21`) and `WHISPER_RECV` (`FID 22`)
Send and receive steward whisper consensus messages (1 to 1,536 bytes) through
M-mode ring buffers:
* `WHISPER_SEND`: `a0` holds the message GPA, `a1` the byte length, and `a2`
  the destination CID (`0` broadcast to sibling stewards, `1` root VM, `>= 2`
  specific steward). Returns sent byte count in `a1`.
* `WHISPER_RECV`: `a0` holds the buffer GPA and `a1` the maximum length.
  Returns received byte count in `a1` (`0` when empty).

#### `RESET_STEWARD` (`FID 23`) and `REQUEST_ROOT_FAILOVER` (`FID 24`)
* `RESET_STEWARD`: Resets steward VM `a0` (`>= 2`) to entry GPA `a1` (`0` for
  its initial entry point) once a quorum of stewards ratifies the reset.
  Returns updated reset count in `a1`.
* `REQUEST_ROOT_FAILOVER`: Promotes standby root VM `a0` (`0` for first
  available, or `>= 2`) to active root VM after steward quorum ratification,
  reparenting surviving child VMs without rebooting the host. Returns
  incremented `failover_epoch` in `a1`.

#### Console rings, network policy, and guest desktop
* `CONSOLE_WRITE` (`FID 25`) and `CONSOLE_READ` (`FID 26`): Transfer serial
  console bytes between a parent VM and direct child VMs via per-guest M-mode
  rings (8 KiB transmit, 512-byte receive). `a0` points to
  `struct console_args` (`ConsoleArgs`); returns byte count in `a1`, or
  `SBI_ERR_DENIED` on confidential or steward VMs.
* `SET_NET_POLICY` (`FID 27`): Updates M-mode L2 isolation and router chaining
  for child `a0` (`>= 2`), with `a1` holding `NetPolicyFlags` (`1 << 0`
  isolates the VM) and `a2` holding the upstream sibling router CID (`0` for
  direct parent routing).
* `GPU_READ_SCANOUT` (`FID 28`): Probes or streams a direct child VM's active
  VirtIO-GPU 2D scanout (`XRGB8888`, including an alpha-composited 64x64
  hardware cursor) into an array of pinned parent GPAs (up to 4,096 pages), and
  optionally negotiates the child's preferred scanout resolution when
  `GpuScanoutFlags.SET_DISPLAY_SIZE` (`1 << 2`) is set. `a0` points to
  `struct gpu_scanout_args` (`GpuScanoutArgs`); returns `1` in `a1` when a new
  frame is available or copied (`0` if unchanged), or `SBI_ERR_DENIED` on
  confidential or steward VMs.
* `INPUT_SEND_EVENT` (`FID 29`): Pushes up to 32 Linux input events (`EV_KEY`,
  `EV_REL`, `EV_ABS`, `EV_SYN`) into a direct child VM's VirtIO-Input queue,
  asserts platform-level interrupt controller (PLIC) interrupt 3, and wakes
  idle vCPUs. `a0` points to `struct input_event_args` (`InputEventArgs`);
  returns delivered event count in `a1`, or `SBI_ERR_DENIED` on confidential or
  steward VMs.
* `GPU_MAP_SCANOUT` (`FID 30`): Maps a direct child VM's active VirtIO-GPU 2D
  scanout backing pages read-only (`Sv39x4` leaf PTEs without write, execute, or
  dirty bits) into one of two 16 MiB-per-slot Stage-2 aperture slots starting at
  GPA `0x2_1000_0000` (`SCANOUT_MAP_GPA_BASE`). `a0` points to a 104-byte
  `GpuMapScanoutArgs` descriptor; returns the frame sequence, dirty bounds,
  and extracted 64x64 hardware cursor pixels when active, or `SBI_ERR_DENIED` on
  confidential or steward VMs. M-mode unmaps all referencing scanout slots
  before tearing down either child or parent guest RAM.

#### `SEAL_MISSION` (`FID 31`) and `VOTE_MISSION` (`FID 32`)
* `SEAL_MISSION`: Reads, verifies, seals, or amends a Principal-signed
  `MissionArgs` descriptor (`176` bytes at GPA `a0`). When `a1` is `1` (seal or
  amend), M-mode verifies the Edwards-curve digital signature algorithm
  (Ed25519) signature over the canonical 92-byte mission header, enforces
  monotonic anti-rollback version numbers, rejects anti-ransomware threshold
  violations (zero-replica step-downs or unratified volume encryption/wipe
  flags), and—when amending an existing sealed Mission—requires both a valid
  signature and eligible physical-RAM stake supermajority approval. When `a1`
  is `0`, writes the active Mission state and vote tally for optional proposal
  hash `a2` into `a0`. Returns `SBI_SUCCESS` or `SBI_ERR_DENIED` on
  policy/signature rejection.
* `VOTE_MISSION`: Records a VM's approval or rejection against a candidate
  `MissionVoteArgs` proposal (`72` bytes at GPA `a0`), weighted by the VM's
  retained physical RAM pages (`max_ram_pages -| delegated_ram_pages`). Only VMs
  whose `guest_id <= proposal_cutoff_guest_id` can vote on a given proposal,
  preventing Sybil child-spawning attacks. Updates running stake totals in the
  descriptor and returns `SBI_SUCCESS`.

---

## Data structure layouts

Structures crossing the 64-bit RISC-V hypercall boundary use standard C
alignment and explicit fixed-width integer types (`uint64_t`, `uint32_t`,
`uint16_t`, `uint8_t`).

### `GuestInfo`
```c
struct guest_info {
    uint64_t guest_id;            /* Context ID (1 for caller, or child CID) */
    uint64_t parent_id;           /* 0 for caller parent, or NO_PARENT_CID */
    uint8_t  is_trusted;          /* 1 if trusted for MMIO, 0 otherwise */
    uint8_t  has_parent;          /* 1 if parent VM exists, 0 for M-mode */
    uint8_t  target_arch;         /* 0=rv64, 1=rv32 (2..3 reserved) */
    uint8_t  assigned_cid;        /* Self CID handle (1 when querying self) */
    uint32_t cpu_khz_ticks;       /* Active vCPU runtime in 1,000-tick units */
    uint64_t vcpus;               /* VM's own logical vCPUs */
    uint64_t self_ram_pages;      /* VM's own logical 4 KB RAM pages */
    uint64_t used_vcpus;          /* Total subtree vCPUs consumed */
    uint64_t max_vcpus;           /* Maximum vCPUs quota ceiling */
    uint64_t used_ram_pages;      /* Total subtree 4 KB RAM pages faulted in */
    uint64_t max_ram_pages;       /* Physical 4 KB RAM page quota pool */
    uint64_t child_count;         /* Direct child count (0 for child queries) */
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
    uint16_t version_minor;       /* Release minor (odd=beta, even=stable) */
    uint16_t version_patch;       /* Diosix release patch (e.g., 0, 1) */
    uint32_t _reserved1;
    char     build_commit[16];    /* Null-terminated Git commit revision */
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
* `CAP_HARDWARE_VIRT` (`1 << 0`): Hardware RISC-V H-extension active.
* `CAP_STAGE2_PAGING` (`1 << 1`): Nested stage-2 Sv39x4 paging active.
* `CAP_DYNAREC` (`1 << 2`): Just-in-time (JIT) dynamic recompilation available.
* `CAP_VIRTIO_VSOCK` (`1 << 3`): In-hypervisor VirtIO-vsock active.
* `CAP_IOMMU` (`1 << 4`): Hardware stage-2 direct memory access (DMA) and
  input/output memory management unit (IOMMU) protection active.
* `CAP_RELEASE_STABLE` (`1 << 5`): Stable channel build
  (`version_minor % 2 == 0`); clear on beta builds.
* `CAP_CHARTER_SEALED` (`1 << 6`): Charter hash sealed in M-mode.

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
    uint64_t max_vcpus;         /* Logical vCPU count (0 = unchanged) */
    uint64_t max_child_depth;   /* Maximum nesting depth (0 = unchanged) */
    uint64_t max_descendants;   /* Total descendant limit (0 = unchanged) */
    uint64_t pcpu_quota_pct;    /* Physical CPU time % (1..90, 0 = unchanged) */
    uint64_t logical_ram_pages; /* Logical DTB RAM in 4 KB pages (0 = quota) */
};

struct manifest_args {
    uint64_t target_cid; /* 1 for self, >= 2 for child */
    uint64_t data_ptr;   /* GPA pointer to manifest UTF-8 buffer */
    uint64_t max_len;    /* Buffer capacity or string length (<= 1 MiB) */
    uint64_t actual_len; /* Output: staged manifest length in bytes */
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
    uint16_t quorum_required;     /* M required steward votes */
    uint16_t quorum_total;        /* N total steward nodes */
    uint16_t standby_replicas;    /* Standby root VM count */
    uint8_t  is_sealed;           /* Output: 1 if sealed in M-mode, else 0 */
    uint8_t  _reserved;
    uint64_t ratified_mask;       /* Output: bitmask of steward votes */
    uint64_t approved_target_cid; /* Output: target CID of latest vote */
    uint64_t failover_epoch;      /* Output: standby root failover epoch */
};

struct mission_args {
    uint8_t  charter_hash[32];     /* SHA-256 digest of canonical mission */
    uint8_t  principal_pubkey[32]; /* Ed25519 public key of principal */
    uint8_t  signature[64];        /* Ed25519 signature over 92-byte header */
    uint32_t version;              /* Monotonic anti-rollback sequence */
    uint32_t min_total_replicas;   /* Constitutional minimum total replicas */
    uint32_t flags;                /* Bitmask: enc, wipe, zero, unratified */
    uint8_t  stake_quorum_pct;     /* Supermajority percentage (default 67) */
    uint8_t  max_stepdown_pct;     /* Max replica drop percentage per step */
    uint8_t  is_sealed;            /* Output: 1 if sealed in M-mode */
    uint8_t  has_pubkey;           /* Output: 1 if principal key pinned */
    uint64_t eligible_stake_pages; /* Snapshot of eligible RAM stake pages */
    uint64_t approved_stake_pages; /* Accumulated approval stake pages */
    uint64_t rejected_stake_pages; /* Accumulated rejection stake pages */
    uint32_t voter_count;          /* Count of distinct VMs that voted */
    uint32_t _reserved;
};

struct mission_vote_args {
    uint8_t  proposal_hash[32];    /* SHA-256 of candidate charter proposal */
    uint8_t  decision;             /* 1 = approve, 2 = reject */
    uint8_t  _reserved[7];
    uint64_t caller_stake_pages;   /* Output: voter's conserved RAM pages */
    uint64_t eligible_stake_pages; /* Output: proposal cutoff eligible stake */
    uint64_t approved_stake_pages; /* Output: cumulative approval stake */
    uint64_t rejected_stake_pages; /* Output: cumulative rejection stake */
};

struct console_args {
    uint64_t target_cid; /* 1 for self, >= 2 for direct child */
    uint64_t data_ptr;   /* GPA pointer to console I/O buffer */
    uint64_t max_len;    /* Bytes to write or buffer capacity (<= 4096) */
    uint64_t actual_len; /* Output: bytes actually read or written */
};

struct net_policy_args {
    uint64_t target_cid;   /* Target child CID (>= 2) */
    uint64_t flags;        /* Bit 0: NetPolicyFlags.ISOLATED */
    uint64_t upstream_cid; /* Sibling router CID (>= 2) or 0 for parent */
};

struct gpu_scanout_args {
    uint64_t target_cid;        /* Target child CID (>= 2) */
    uint64_t pixels_ptr;        /* User VA (ioctl) or GPA page-list (SBI) */
    uint32_t page_count;        /* Pinned 4 KB page count (<= 4096) */
    uint32_t first_page_offset; /* Byte offset into first pinned page */
    uint32_t max_pixels;        /* Destination buffer capacity in pixels */
    uint32_t width;             /* In (SET_SIZE) / Out: scanout width (px) */
    uint32_t height;            /* In (SET_SIZE) / Out: scanout height (px) */
    uint32_t flags;             /* In: bit 2 = SET_SIZE; Out: 0=ACTIVE, 1=UPD */
    uint64_t frame_seq;         /* In/Out: monotonic scanout sequence number */
};

struct gpu_map_scanout_args {
    uint64_t target_cid;        /* Target child CID (>= 2), or 0 for UNMAP */
    uint64_t cursor_pixels_ptr; /* Optional 64x64 ARGB cursor buffer (16 KB) */
    uint32_t slot_offset_bytes; /* Mapped offset inside scanout aperture */
    uint32_t mapped_bytes;      /* Mapped scanout backing byte length */
    uint32_t width;             /* Scanout width in pixels (in/out) */
    uint32_t height;            /* Scanout height in pixels (in/out) */
    uint32_t stride_pixels;     /* Scanout pitch in pixels */
    uint32_t format;            /* Pixel format (VirtIO-GPU XRGB8888) */
    uint32_t dirty_x;           /* Queued damage box left coordinate */
    uint32_t dirty_y;           /* Queued damage box top coordinate */
    uint32_t dirty_w;           /* Queued damage box width in pixels */
    uint32_t dirty_h;           /* Queued damage box height in pixels */
    int32_t  cursor_x;          /* Hardware cursor X position */
    int32_t  cursor_y;          /* Hardware cursor Y position */
    uint32_t cursor_hot_x;      /* Hardware cursor hotspot X */
    uint32_t cursor_hot_y;      /* Hardware cursor hotspot Y */
    uint32_t cursor_w;          /* Hardware cursor width (up to 64 px) */
    uint32_t cursor_h;          /* Hardware cursor height (up to 64 px) */
    uint32_t flags;             /* In: SET_SIZE/UNMAP; Out: ZC/ACTIVE/CUR */
    uint32_t _reserved;
    uint64_t frame_seq;         /* In/Out: scanout frame sequence number */
    uint64_t cursor_seq;        /* In/Out: cursor sprite sequence number */
};

struct input_event_item {
    uint16_t type;  /* Linux evdev type (EV_SYN, EV_KEY, EV_REL, EV_ABS) */
    uint16_t code;  /* Linux evdev key, button, or axis code */
    uint32_t value; /* Event value (0/1/2, wheel delta, or 0..32767) */
};

struct input_event_args {
    uint64_t                target_cid; /* Target child CID (>= 2) */
    uint32_t                count;      /* Number of events (1..32) */
    uint32_t                _reserved;
    struct input_event_item events[32]; /* Batched evdev events */
};
```

---

## Linux kernel driver interface

Inside Linux guest VMs, the built-in Diosix kernel driver registers the
`diosix0` virtual Ethernet network interface controller (NIC) and the
`/dev/diosix` character device (requiring `CAP_SYS_ADMIN` on `open`, `ioctl`,
and `mmap`), mapping userspace input/output control (`ioctl`) calls onto SBI
hypercalls:

| ioctl name | Value | Description |
| :--- | :--- | :--- |
| `IOCTL_DROP_TRUST` | `0x1002` | Drops hardware trust |
| `IOCTL_RUN` / `IOCTL_SPAWN` | `0x1003` | Loads ELF and boots child VM |
| `IOCTL_GET_INFO` | `0x1004` | Queries current or child VM info |
| `IOCTL_SET_QUOTA` | `0x1005` | Updates resource quotas |
| `IOCTL_TERMINATE` / `IOCTL_EXIT` / `IOCTL_KILL` | `0x1006` | Terminates self or child VM |
| `IOCTL_YIELD` | `0x1007` | Yields remaining vCPU time slice |
| `IOCTL_WAIT_EVENT` | `0x1008` | Polls or waits for VM lifecycle events |
| `IOCTL_GET_HV_INFO` | `0x100b` | Queries hypervisor and host info |
| `IOCTL_GET_MANIFEST` | `0x100c` | Reads staged manifest from M-mode |
| `IOCTL_SET_MANIFEST` | `0x100d` | Stages capability manifest for a VM |
| `IOCTL_MAP_CHILD_MEM` | `0x100e` | Maps child VM memory into parent GPA space |
| `IOCTL_UNMAP_CHILD_MEM` | `0x100f` | Unmaps foreign child memory region |
| `IOCTL_START` | `0x1010` | Starts child VM at given entry and DTB |
| `IOCTL_SEAL_CHARTER` | `0x1011` | Seals charter hash in M-mode |
| `IOCTL_GET_CHARTER` | `0x1012` | Queries sealed charter status from M-mode |
| `IOCTL_RATIFY_CHARTER` | `0x1013` | Casts steward ratification vote in M-mode |
| `IOCTL_RESET_STEWARD` | `0x1014` | Resets steward VM to initial entry after quorum |
| `IOCTL_REQUEST_ROOT_FAILOVER` | `0x1015` | Promotes standby root VM on failover |
| `IOCTL_CONSOLE_WRITE` | `0x1016` | Writes input bytes to child console RX ring |
| `IOCTL_CONSOLE_READ` | `0x1017` | Reads output bytes from VM console TX ring |
| `IOCTL_SET_NET_POLICY` | `0x1018` | Updates child VM M-mode L2 network policy |
| `IOCTL_WHISPER_SEND` | `0x1019` | Sends steward whisper frame (up to 1,536 bytes) |
| `IOCTL_WHISPER_RECV` | `0x101a` | Reads steward whisper frame (up to 1,536 bytes) |
| `IOCTL_GPU_READ_SCANOUT` | `0x101b` | Pins user pages and reads child VirtIO-GPU scanout |
| `IOCTL_INPUT_SEND_EVENT` | `0x101c` | Sends batched Linux input events to child VirtIO-Input |
| `IOCTL_GPU_MAP_SCANOUT` | `0x101d` | Maps child VirtIO-GPU scanout read-only and returns damage and cursor state |
| `IOCTL_SEAL_MISSION` | `0x101e` | Verifies Ed25519 signature, anti-ransomware guards, and seals Mission (`SEAL_MISSION`) |
| `IOCTL_GET_MISSION` | `0x101f` | Reads active M-mode Mission state and stake tally (`SEAL_MISSION`) |
| `IOCTL_VOTE_MISSION` | `0x1020` | Casts caller VM's conserved RAM quota-stake vote (`VOTE_MISSION`) |

To support Tier 1 zero-copy displays, `/dev/diosix` also exposes
`IOCTL_GPU_MAP_SCANOUT` (invoking `GPU_MAP_SCANOUT`) and read-only `mmap()`
access to the Stage-2 scanout aperture at `DIOSIX_SCANOUT_MAP_BASE`
(`0x2_1000_0000`), releasing desktop ownership cleanly when the file descriptor
closes.

---

## Emulated virtual MMIO bus

For native and dynamically recompiled VMs running without host hardware
passthrough, the hypervisor exposes a standard virtual MMIO bus (unused
VirtIO slots 5, 6, and 7 in `0x10006000` through `0x10009000` return `0` for
`DEVICE_ID`):

| Base GPA | Size | IRQ | Device | Description |
| :--- | :--- | :--- | :--- | :--- |
| `0x00101000` | `0x1000` | - | `GoldfishRtc` | Goldfish real-time clock (`google,goldfish-rtc`) |
| `0x02000000` | `0x10000` | - | `CLINT` | Core-local interruptor (`msip`, `mtimecmp`, `mtime`) |
| `0x0c000000` | `0x04000000` | - | `PLIC` | Platform-level interrupt controller (interrupts 1..63) |
| `0x10000000` | `0x100` | - | `UART0` | Universal asynchronous receiver-transmitter (16550A, transmit-only) |
| `0x10001000` | `0x1000` | `1` | `VirtioVsock` | VirtIO 1.1 socket device (`VIRTIO_ID_VSOCK = 19`) |
| `0x10002000` | `0x1000` | `2` | `VirtioGpu` | VirtIO 1.1 2D GPU scanout and cursor (`VIRTIO_ID_GPU = 16`) |
| `0x10003000` | `0x1000` | `3` | `VirtioInput` | VirtIO 1.1 keyboard, mouse, and tablet (`VIRTIO_ID_INPUT = 18`) |
| `0x10004000` | `0x1000` | `4` | `VirtioBlk` | VirtIO 1.1 RAM-backed block device (`VIRTIO_ID_BLK = 2`) |
| `0x10005000` | `0x1000` | `5` | `VirtioNet` | VirtIO 1.1 Ethernet NIC (`VIRTIO_ID_NET = 1`) |
