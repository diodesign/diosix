# Diosix Hypervisor: Full Implementation Plan

## Native & Non-Native Guest Execution to Login Prompt

*Revision 2 — August 2026*

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [System Overview](#2-system-overview)
3. [Physical Core Lifecycle](#3-physical-core-lifecycle)
4. [Guest VM Lifecycle](#4-guest-vm-lifecycle)
5. [Virtual Core Scheduling](#5-virtual-core-scheduling)
6. [Memory Management](#6-memory-management)
7. [Native Guest Execution (riscv64)](#7-native-guest-execution-riscv64)
8. [Non-Native Guest Execution (Dynarec)](#8-non-native-guest-execution-dynarec)
9. [SBI Firmware Interface](#9-sbi-firmware-interface)
10. [Device Emulation & I/O](#10-device-emulation--io)
11. [Interrupt Architecture](#11-interrupt-architecture)
12. [Serial Console & Guest Interaction](#12-serial-console--guest-interaction)
13. [Boot Sequence: Cold Start to Login Prompt](#13-boot-sequence-cold-start-to-login-prompt)
14. [Security Model](#14-security-model)
15. [Hierarchical VM Management](#15-hierarchical-vm-management)
16. [Guest State Serialization](#16-guest-state-serialization)
17. [Nested Virtualization](#17-nested-virtualization)
18. [Testing & Validation Strategy](#18-testing--validation-strategy)
19. [Future Architecture Support](#19-future-architecture-support)
20. [Implementation Phasing](#20-implementation-phasing)

---

## 1. Executive Summary

Diosix is a type-1 bare-metal hypervisor written in Zig, running in RISC-V machine mode (M-mode) on 64-bit RISC-V hosts. It supports two guest execution paths that are treated identically by the scheduler and interrupt system:

- **Native guests** (riscv64): Run at near-hardware speed using the RISC-V Hypervisor (H) extension for hardware-assisted virtualization, with a Physical Memory Protection (PMP) fallback for legacy CPUs.

- **Non-native guests** (riscv32, aarch64, x86_64): Run via a freestanding dynamic binary recompiler (dynarec) that JIT-compiles foreign instructions into host RV64 machine code. The translated code runs natively on the host CPU in supervisor mode (S-mode), sandboxed by PMP. Translated blocks chain together and execute continuously until a hardware interrupt (timer, IPI, external I/O) traps to M-mode — exactly as native guests do.

Both paths share a unified scheduler, memory manager, SBI firmware layer, and device model. The hypervisor does not distinguish between native and non-native guests for scheduling, interrupt delivery, or lifecycle management. A Linux guest of either kind reaches its `login:` prompt through identical interfaces.

### Design Principles

1. **Minimal TCB**: Only M-mode hypervisor code is trusted. Everything else — native guests, the dynarec, device drivers — runs with reduced privilege.
2. **Interrupt-driven execution**: Both native and translated guest code run on the host CPU until a hardware interrupt preempts them. There is no instruction-counting budget or periodic yield. The hardware timer is the sole preemption mechanism, just as it is for native guests.
3. **Guest-agnostic interfaces**: The SBI layer, device tree, and virtual hardware are identical regardless of guest architecture.
4. **Hierarchical isolation**: VMs form a lineage tree. Each VM can only communicate with its parent and direct children. Resource quotas cascade down the tree.
5. **No intermediate representations**: The dynarec translates guest instructions directly to host machine code without an IR pass, minimizing latency and complexity.
6. **Zig safety**: All hypervisor code leverages Zig's comptime checks, explicit error handling, and `defer`/`errdefer` patterns. No dynamic dispatch, no hidden allocations.

---

## 2. System Overview

### Privilege Levels and Execution Model

```
┌──────────────────────────────────────────────────────────────┐
│  M-mode (Machine) — THE HYPERVISOR                           │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  Diosix Hypervisor                                     │  │
│  │  - Trap handler (xint_machine_entry_handler)           │  │
│  │  - Work-stealing scheduler                             │  │
│  │  - Physical memory manager (buddy + slab allocators)   │  │
│  │  - SBI firmware implementation                         │  │
│  │  - Interrupt dispatch (timer, IPI, external)           │  │
│  │  - GDB stub (optional)                                 │  │
│  └────────────────────────────────────────────────────────┘  │
├──────────────────────────────────────────────────────────────┤
│  VS/S-mode (Supervisor) — GUEST CODE                         │
│  ┌─────────────────────┐  ┌───────────────────────────────┐  │
│  │ Native riscv64      │  │  Dynarec Translated Code      │  │
│  │ Guest (Linux)       │  │  (S-mode, PMP-sandboxed)      │  │
│  │ runs directly       │  │                               │  │
│  │ via H-ext / PMP     │  │  JIT'd host RV64 instructions │  │
│  │                     │  │  run natively until hardware   │  │
│  │ ← timer interrupt → │  │  interrupt traps to M-mode    │  │
│  │    traps to M-mode  │  │  ← timer interrupt →          │  │
│  │                     │  │     traps to M-mode            │  │
│  └─────────────────────┘  └───────────────────────────────┘  │
│                                                              │
│  Both paths: scheduled identically, interrupted identically  │
├──────────────────────────────────────────────────────────────┤
│  VU/U-mode (User)                                            │
│  Guest userspace applications                                │
└──────────────────────────────────────────────────────────────┘
```

The fundamental architectural insight is that both execution paths converge at the M-mode trap handler. A native guest runs in VS-mode until a trap; a non-native guest runs JIT'd RV64 code in S-mode until a trap. The trap handler does not need to know which kind of guest it interrupted — it handles timer, IPI, and external interrupts uniformly, then yields to the scheduler, which picks the next vcore (native or emulated) and dispatches it.

### Key Abstractions

| Abstraction | Purpose | Location |
|---|---|---|
| `PhysicalCore` (`CpuContext`) | Per-hart state: run queues, active vcore, trap stack | `hardware/native/cpu/riscv64/mod.zig` |
| `Guest` | VM container: lineage, quotas, memory space, vcore list | `core/guest.zig` |
| `VirtualCore` | Schedulable CPU unit with polymorphic execution path | `core/vcore.zig` |
| `exec_path.native` | Hardware context for H-extension or PMP execution | `core/vcore.zig` |
| `exec_path.emulated` | Dynarec engine + SoftTLB + virtual bus + JIT code buffer | `core/emulation.zig` |
| `GuestSpace` | G-stage page tables (Sv39x4) or PMP regions | `hardware/native/cpu/riscv64/sv39x4.zig` |
| `SoftTlb` | Software MMU for emulated guests (set-associative) | `hardware/emulation/softtlb.zig` |
| `Engine` | Block translator, chainer, and code cache manager | `hardware/emulation/engine/dynarec/engine.zig` |
| `SlabAllocator` | O(1) allocator for fixed-size hypervisor objects | `core/slab.zig` |
| `SerializedState` | Checkpoint/restore format for live migration | `core/serialize.zig` |

---

## 3. Physical Core Lifecycle

### 3.1 Boot Sequence

Each physical hart enters `_start` in `entry.s`:

1. **Atomic core ID assignment**: Each hart atomically increments a global counter to receive a linear `cpu_core_id` (0, 1, 2, …), independent of the hardware `mhartid`.
2. **Stack setup**: Each hart computes its private memory slab address at `__hypervisor_end + (cpu_core_id * CPU_CONTEXT_SIZE)`. The stack pointer (`sp`) is set to the top of this slab. `mscratch` is set to the exception stack within this slab.
3. **BSS clear**: Hart 0 zeros the `.bss` section.
4. **Jump to Zig**: All harts call `main(hartid, fdt_paddr)`.

### 3.2 Main Loop

After initialization, each physical core enters an infinite scheduling loop:

```
loop:
    if no active vcore:
        vcore = scheduler.pickNext()    // local queue, then steal from peers

    if vcore exists:
        program hardware timer to min(timeslice, vcore.next_timer_deadline)
        match vcore.exec_path:
            .native  → configure hgatp, sync VS-mode CSRs
            .emulated → configure tight PMP (guest RAM + JIT buffer only)
        hw_run_vcore()                  // mret into VS/S-mode
        // --- control returns here on trap to M-mode ---
        handle_trap()                   // timer → yield, ecall → SBI, etc.
    else:
        set timer to nearest blocked vcore deadline
        WFI (sleep until interrupt)
```

The critical point: **both paths use `hw_run_vcore()` followed by `mret`**. The hypervisor does not loop inside the emulation engine. It dispatches a vcore (native or emulated), the vcore runs on the physical CPU until hardware interrupts it, and the trap handler regains control. This is the same flow for both guest types.

### 3.3 Trap Entry and Return

`hw_run_vcore()` is an assembly routine that:

1. Saves the hypervisor's callee-saved registers to the M-mode stack.
2. Loads the vcore's `ThreadContext` (all 31 GPRs).
3. Programs `mepc` from `MachineState`.
4. Loads `mstatus`, and for native guests: `hstatus`, `hgatp`, `hedeleg`, `hideleg`.
5. Executes `mret` to drop privilege level and begin guest execution.

On trap, `xint_machine_entry_handler`:

1. Swaps `sp` and `mscratch` (switch to M-mode exception stack).
2. Saves all 31 guest GPRs to the exception stack.
3. Calls the Zig `xint_handler` / `dispatch` function.
4. On return: restores GPRs, swaps stacks, executes `mret` to re-enter the guest — or yields to the scheduler and dispatches a different vcore.

---

## 4. Guest VM Lifecycle

### 4.1 Creation

A `Guest` is created during boot (for the Root VM) or via the `RUN` SBI call:

1. **Allocate `Guest` struct** from the allocator.
2. **Assign unique VM ID** (`vmid`) via an atomic global counter. This ID is embedded into `hgatp` for TLB tagging.
3. **Initialize memory space**: Allocate fresh G-stage page tables (Sv39x4).
4. **Set quotas**: Inherit parent quotas, optionally reduced. Quotas cover RAM pages, vCPU count, and descendant depth.
5. **Create vcores**: Allocate `VirtualCore` structs and link them to the guest. The boot vcore (id=0) is initialized with the guest's entry point and device tree pointer.

### 4.2 States

```
Valid  →  Dying  →  (freed)
  ↕
Restarting → Valid
```

- **Valid**: Guest is executing normally.
- **Dying**: Cascading teardown in progress. All vcores are descheduled, children are recursively terminated, memory is reclaimed.
- **Restarting**: Guest is being rebooted.

### 4.3 Termination

`guest.terminate()` initiates a cascading shutdown:

1. Set guest state to `.dying`.
2. Recursively terminate all child VMs (depth-first).
3. For each vcore: set state to `.stopped`, clear `running_on_cpu`, send IPI to the physical core running it.
4. Release all physical pages.
5. For emulated vcores: deallocate JIT code buffer, SoftTLB, Engine, VCpu state.
6. Return quota to parent.
7. Return `Guest` struct to allocator.

### 4.4 Guest Execution (`RUN`)

The `RUN` SBI call instantiates and launches an isolated child VM from an image:

1. Create a clean child `Guest` under the calling guest's lineage.
2. Map the guest ELF binary into the child's Stage-2 memory space.
3. If provided, map the Device Tree Blob (DTB) into the child's space.
4. Set the child's primary vCPU program counter (`mepc`) to the ELF entry point, `a0` to hart ID, and `a1` to DTB guest physical address.
5. Apply parent-specified resource quotas.
6. Enroll the child's primary vcore into the scheduler (`.ready`).
7. Return the child's Context ID to the parent.

---

## 5. Virtual Core Scheduling

### 5.1 Work-Stealing Scheduler

The scheduler uses a **per-CPU work-stealing** design. There is no global run queue. Each physical core owns a local run queue, and idle cores steal work from busy peers.

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  CPU 0      │     │  CPU 1      │     │  CPU 2      │
│  Local Queue│     │  Local Queue│     │  Local Queue │
│ ┌────┐┌────┐│     │ ┌────┐      │     │  (empty)    │
│ │vc_0││vc_1││     │ │vc_2│      │     │             │
│ └────┘└────┘│     │ └────┘      │     │  ← steals   │
│             │     │             │     │    from 0    │
└─────────────┘     └─────────────┘     └─────────────┘
                                              │
                                        steal(cpu_0) → vc_1
```

### 5.2 Per-CPU Queue Operations

Each CPU's run queue is an intrusive doubly-linked list protected by a **per-queue** fine-grained spinlock. The lock only disables interrupts on the owning core — other cores' interrupt latency is unaffected.

- **`enqueue(vc)`**: Insert a vcore into the owning core's local queue. O(1).
- **`dequeue()`**: Remove and return the highest-priority vcore. O(1).
- **`steal(target_cpu)`**: Lock the target CPU's queue, remove one vcore, unlock. O(1). Only called when the local queue is empty.

### 5.3 Queuing Rules

- A vcore is only queued if it is in `ready` state.
- A vcore is never double-queued (`is_queued` atomic flag prevents duplicates).
- A vcore is never queued while it is actively `running_on_cpu`.
- Newly created vcores are inserted into the creating core's local queue.
- When a vcore is re-queued after yielding, it goes back to the same core's queue (affinity). The scheduler migrates vcores only via work-stealing.

### 5.4 Picking the Next Vcore

`pickNext()` on CPU N:

1. **Local dequeue**: Check CPU N's local queue for any vcore whose ISA requirements match the physical CPU's `misa`. O(1).
2. **Work-steal**: If local queue is empty, iterate over other CPUs (random start, round-robin) and attempt `steal()`. First successful steal wins.
3. **Idle**: If all queues are empty, return null. The core enters WFI.

There is no distinction between native and emulated vcores during scheduling. A native riscv64 vcore and an emulated riscv32 vcore are both just `VirtualCore` entries in the same queue.

### 5.5 Virtual Runtime Accounting

Each vcore maintains a `vruntime` counter:

```
vruntime += (wall_time_delta * NICE_0_WEIGHT) / vcore.weight
```

- Higher-priority vcores accumulate vruntime slower, getting more CPU time.
- When a vcore is re-queued after sleeping, its `vruntime` is snapped forward to `local_min_vruntime` to prevent starvation.

### 5.6 Timeslicing

Each execution quantum is bounded by `TIMESLICE_TICKS`. The physical timer is programmed to the minimum of:

1. The timeslice deadline.
2. The vcore's next virtual timer deadline (`vstimecmp` for native, `vcpu.vstimecmp` for emulated).
3. Any blocked vcore's pending timer on this physical CPU.

When the timer fires, the trap handler yields the current vcore back to the scheduler. This is identical for native and emulated vcores — the timer interrupt traps to M-mode in both cases.

### 5.7 Wait-For-Interrupt (WFI) Handling

When a guest executes WFI:

- **Native**: The instruction traps to M-mode (via `hstatus.VTW`). The vcore state transitions to `.blocked`. The scheduler removes it from the run queue and records its timer deadline.
- **Emulated**: The dynarec detects WFI during translation and emits an `ecall` to the M-mode hypervisor with a WFI indicator. The trap handler transitions the vcore to `.blocked`, identical to the native path.

In both cases, the physical core then picks the next available vcore. If no vcore is available, the core programs its timer to the nearest blocked vcore's deadline and enters physical WFI.

---

## 6. Memory Management

### 6.1 Physical Memory (Buddy Allocator)

The hypervisor manages all physical RAM using a buddy allocator:

- **Discovery**: RAM regions are parsed from the host device tree blob (DTB) during boot.
- **Reservation**: The hypervisor carves out its own footprint (`__hypervisor_end`), per-CPU slabs, page metadata arrays, and the Root VM's pre-allocated region.
- **Allocation**: Power-of-two page allocation (order 0 = 4KB, order 1 = 8KB, …). Large blocks are split to satisfy small requests. Adjacent free blocks are coalesced on free.
- **Reference counting**: Each `PageDescriptor` has an atomic refcount. Pages shared via CoW have refcount > 1. Freeing a page decrements the refcount; the page returns to the free list only at refcount 0.
- **Thread safety**: The physical memory state is protected by an interrupt-safe spinlock.

### 6.2 Slab Allocator

A slab allocator layer sits on top of the buddy allocator for fixed-size objects that are allocated and freed frequently:

| Object Type | Size | Allocation Pattern |
|---|---|---|
| `VirtualCore` | ~2KB | Allocated on HART_START, freed on terminate |
| `Guest` | ~1KB | Allocated on FORK, freed on terminate |
| `LinkedList.Node` | ~32B | Scheduler queue nodes, very high frequency |
| G-stage PTE pages | 4KB | Demand-paged, freed on guest teardown |
| JIT code blocks | 64KB | Per-engine, allocated on first translation |

**Implementation**:

- Each slab manages a page (or group of pages) divided into fixed-size slots.
- Free slots are tracked via a freelist embedded within the slots themselves (each free slot contains a pointer to the next free slot).
- `alloc()` pops from the freelist — O(1), zero fragmentation.
- `free()` pushes to the freelist — O(1).
- When a slab is exhausted, a new page is allocated from the buddy allocator and carved into slots.
- Per-CPU slab caches eliminate cross-core lock contention for common allocations.

### 6.3 Guest Physical Address Spaces

#### 6.3.1 Native Guests (G-Stage Paging — Sv39x4)

For native riscv64 guests with the H-extension:

- **Two-stage translation**: Guest virtual addresses are translated by the guest's own S-mode page tables (stage 1), then Guest Physical Addresses (GPAs) are translated to Host Physical Addresses (HPAs) by the hypervisor's G-stage page tables (stage 2).
- **Page table format**: Sv39x4 — 39-bit guest virtual addresses, 41-bit guest physical addresses, three-level page table with a 16KB root (4 contiguous pages).
- **`hgatp` programming**: The G-stage page table root physical address and the guest's `vmid` are encoded into `hgatp`. The CPU uses this for hardware-accelerated GPA→HPA translation.
- **Protection**: The hypervisor's own physical pages are never mapped into any guest's G-stage tables. MMIO regions are identity-mapped only for the Root VM (which holds hardware trust).
- **Dynamic Stage-2 Allocation**: The hypervisor dynamically allocates physical pages on demand when a guest physical address is faulted in, mapping it directly into the guest Stage-2 page table.
- **TLB management**: `hfence.gvma` flushes the G-stage TLB. A `gstage_dirty` flag tracks whether the tables were modified since the last flush, avoiding unnecessary flushes.

#### 6.3.2 Native Guests (PMP Fallback)

For CPUs without the H-extension:

- **No G-stage paging**: The guest runs in standard S-mode with its own `satp`-based page tables translating directly to physical addresses.
- **PMP enforcement**: The hypervisor uses Top-of-Range (TOR) PMP entries to grant the guest access only to its allocated RAM region and the current CPU's private slab. The hypervisor text/data is protected by PMP deny entries.
- **Limitations**: No hardware-enforced GPA→HPA translation; the guest must use physical addresses that map directly to its allocated region.

#### 6.3.3 Emulated Guests (SoftTLB)

For non-native guests:

- **Software MMU**: The `SoftTlb` module implements the guest's page table format in software (e.g., Sv32 for riscv32).
- **GPA→HPA mapping**: `translateGpaToHpa()` maps guest physical addresses to host physical addresses using the guest's allocated RAM region.
- **MMIO detection**: `isMmioAddr()` identifies accesses to device regions and routes them to the virtual device bus.
- **Set-associative cache**: See §6.4.
- **Page table walk**: Full page table walk with superpage support, privilege checking, and PTE flag validation.

### 6.4 Set-Associative SoftTLB

The SoftTLB uses a **4-way set-associative** cache instead of a direct-mapped cache, eliminating the conflict miss problem where two frequently-accessed addresses map to the same slot and thrash each other.

**Structure**:

```
256 sets × 4 ways = 1024 entries (same total as direct-mapped)

┌─────────────────────────────────────────────────────────┐
│ Set 0:   [Way 0] [Way 1] [Way 2] [Way 3] [LRU bits]   │
│ Set 1:   [Way 0] [Way 1] [Way 2] [Way 3] [LRU bits]   │
│ ...                                                     │
│ Set 255: [Way 0] [Way 1] [Way 2] [Way 3] [LRU bits]   │
└─────────────────────────────────────────────────────────┘

Each entry:
  - tag: upper bits of virtual page number
  - hpa_base: host physical address of the page
  - perms: read/write/execute permission bits
  - valid: entry is populated
```

**Lookup** (4 comparisons instead of 1):

```zig
fn lookup(vpn: u32) ?TlbEntry {
    const set_idx = vpn & 0xFF;  // lower 8 bits select set
    const tag = vpn >> 8;        // upper bits are the tag
    const set = &self.sets[set_idx];
    inline for (0..4) |way| {
        if (set.entries[way].valid and set.entries[way].tag == tag) {
            set.updateLru(way);
            return set.entries[way];
        }
    }
    return null;  // miss → full page table walk
}
```

**Eviction**: On a miss, the least-recently-used way in the set is evicted and replaced. LRU tracking uses a 3-bit pseudo-LRU encoding per set (standard for 4-way caches).

**MMIO bypass**: MMIO addresses are never cached. After a page table walk produces an HPA in an MMIO range, the result is returned directly without insertion into the cache.

---

## 7. Native Guest Execution (riscv64)

### 7.1 H-Extension Path

This is the primary, high-performance execution path for riscv64 guests on modern RISC-V CPUs.

#### 7.1.1 Entry to Guest

1. **Context switch** (`pcore.contextSwitch`): Apply G-stage page tables via `hgatp`.
2. **State sync** (`syncGuestStateToHardware`): Program VS-mode CSRs (`vsstatus`, `vsie`, `vstvec`, `vsscratch`, `vsepc`, `vscause`, `vstval`, `vsatp`, `vstimecmp`).
3. **Delegation setup**: Configure `hedeleg` and `hideleg` to delegate safe exceptions (page faults, breakpoints, illegal instructions) to VS-mode so the guest kernel handles them directly.
4. **Virtual interrupt injection**: Program `hvip` with pending virtual interrupts (timer, software, external).
5. **Timer setup**: Program physical timer to `min(timeslice, vstimecmp)`.
6. **Execute `mret`**: CPU transitions to VS-mode and begins executing guest code natively.

#### 7.1.2 Traps Back to Hypervisor

The guest runs at full speed until an un-delegated event traps to M-mode:

| Trap | `mcause` | Handler Action |
|---|---|---|
| Timer interrupt | `0x80000007` | Yield vcore to scheduler |
| Software interrupt (IPI) | `0x80000003` | Clear MSIP, check for vcore migrations |
| External interrupt | `0x8000000B` | PLIC claim, route to guest vPLIC |
| Supervisor ecall | `9` | Dispatch SBI call |
| Guest page fault (G-stage) | `20/21/23` | Demand-page or CoW fault resolution |
| Illegal instruction | `2` | Emulate CSR access |
| Virtual instruction | `22` | Guest tried hypervisor-level instruction |

#### 7.1.3 CSR Emulation

Some instructions trap because the guest accesses CSRs that require hypervisor mediation:

- **`stimecmp`/`vstimecmp`** (Sstc): If the CPU lacks Sstc or the guest accesses `stimecmp` while Sstc is disabled, the hypervisor intercepts and emulates it by programming the CLINT `mtimecmp` and injecting `VSTIP` via `hvip`.
- **`siselect`/`vsiselect`** (AIA): Trapped and emulated for interrupt file management.
- **`hstateen`/`sstateen`** (Smstateen): Controlled by the hypervisor to restrict guest access to specific state groups.

### 7.2 PMP Fallback Path

For legacy CPUs without the H-extension:

1. **PMP setup** (`pmp.zig`): Configure TOR-mode PMP entries granting the guest access only to its RAM region and the CPU slab. Deny all other regions.
2. **S-mode CSR sync**: Directly program `sstatus`, `sepc`, `stvec`, `satp`, `scause`, `stval`.
3. **Execute `mret`**: Drop to S-mode.
4. **Trap handling**: All S-mode ecalls trap to M-mode. The hypervisor handles SBI calls identically to the H-extension path.

### 7.3 SMP Boot for Native Guests

When the guest kernel calls SBI HSM `HART_START`:

1. **Locate target vcore** by hart ID in the guest's vcore list.
2. **Initialize target vcore state**: Set `mepc` to the start address, `a0` to hart ID, `a1` to opaque. Configure `mstatus` for VS-mode entry, `hstatus` with `SPV`/`VTW`, program `hgatp`, `hedeleg`/`hideleg`.
3. **Queue the vcore**: Allocate from slab, set state to `.ready`, insert into scheduler.
4. **Wake target physical core**: Send IPI via CLINT `msip`.

---

## 8. Non-Native Guest Execution (Dynarec)

### 8.1 Architectural Principle: Interrupt-Driven, Not Budget-Driven

The dynarec does **not** use an instruction-counting budget. It does **not** periodically return to a management loop to "check in." Translated guest code runs natively on the host CPU — as real RV64 machine instructions in S-mode — and is preempted exclusively by hardware interrupts, exactly like native guest code.

```
WRONG (budget model — what we avoid):
    loop:
        execute N guest instructions
        check timers, interrupts, yield?   ← artificial polling
        if budget exhausted: return to hypervisor

RIGHT (interrupt-driven — our architecture):
    translate block → chain blocks → run host code natively
    ← timer interrupt traps to M-mode →
    hypervisor handles trap (same path as native guests)
    mret back into translated code (or different vcore)
```

The only reasons translated code stops executing:

1. **Hardware timer interrupt**: The physical timer fires (timeslice expiry or guest timer deadline). Traps to M-mode. The hypervisor's trap handler yields the vcore to the scheduler.
2. **IPI (software interrupt)**: Another core sent an IPI (vcore migration, wake-up). Traps to M-mode.
3. **External interrupt**: A physical device (UART RX) needs attention. Traps to M-mode via PLIC.
4. **Explicit ecall from translated code**: The JIT emits an `ecall` for guest operations that require hypervisor involvement (SBI calls, WFI, halt).
5. **Untranslated block boundary**: The translated code reaches a branch target that hasn't been compiled yet. Returns to the S-mode translation dispatcher, which compiles the new block, chains it, and resumes execution.

Cases 1-4 trap to M-mode and are handled by the same `xint_machine_entry_handler` that handles native guest traps. Case 5 stays within S-mode — the translation dispatcher runs in the same privilege level as the translated code.

### 8.2 Execution Flow

```
M-mode hypervisor
    │
    │  mret (enter S-mode)
    ▼
S-mode Translation Dispatcher (emulatedRunnerSMode)
    │
    │  Is current guest PC translated?
    │
    ├─ YES: Jump to translated code
    │       │
    │       │  (runs natively as RV64 host instructions)
    │       │  (chained blocks execute sequentially)
    │       │
    │       ├─── Timer interrupt ───► M-mode trap handler
    │       │                          └─ yield to scheduler
    │       │
    │       ├─── Guest ecall ──────► ecall to M-mode
    │       │    (emitted by JIT)     └─ SBI dispatch
    │       │                          └─ mret back
    │       │
    │       ├─── MMIO access ──────► Device handler (S-mode)
    │       │    (detected by         └─ bus.read()/write()
    │       │     translated code)    └─ return to translated code
    │       │
    │       └─── Unchained branch ─► Return to dispatcher
    │            (target not yet       └─ translate new block
    │             compiled)            └─ chain it
    │                                  └─ jump to new block
    │
    └─ NO: Translate block
           │
           ├─ Decode guest instructions
           ├─ Emit host RV64 instructions into code buffer
           ├─ Execute fence.i (flush I-cache)
           ├─ Chain to previous blocks (patch jump targets)
           └─ Jump to translated code
```

### 8.3 The Translation Dispatcher

The translation dispatcher is a minimal S-mode function that manages the JIT code cache and serves as the "cold path" entry point. It is NOT an interpreter loop.

```zig
/// S-mode entry point for emulated vcores.
/// Called after mret from the hypervisor.
/// Never returns (re-enters M-mode only via traps).
pub fn emulatedRunnerSMode(vc: *VirtualCore) noreturn {
    const engine = vc.exec_path.emulated.engine;
    const vcpu = vc.exec_path.emulated.vcpu;

    while (true) {
        // Look up translated block for current guest PC
        const block = engine.code_cache.lookup(vcpu.pc);

        if (block) |b| {
            // Jump to translated code. This runs natively on the host CPU
            // until a trap (timer, ecall, unchained branch) brings us back.
            engine.executeBlock(b, vcpu);
        } else {
            // Translate the block at the current guest PC
            const new_block = engine.translateBlock(vcpu.pc);

            // Flush instruction cache so CPU sees the new code
            asm volatile ("fence.i");

            // Chain: patch any existing blocks that branch to this PC
            engine.code_cache.chainIncoming(vcpu.pc, new_block);

            // Execute the newly translated block
            engine.executeBlock(new_block, vcpu);
        }

        // If we reach here, the block ended at an unchained branch.
        // The vcpu.pc has been updated to the branch target.
        // Loop back to translate/lookup the next block.
    }
}
```

### 8.4 Block Translation

#### 8.4.1 Translation Pipeline

For each guest basic block:

1. **Fetch**: Read guest instruction bytes from the SoftTLB-translated HPA.
2. **Decode**: Parse using the architecture-specific decoder (e.g., `rv32.zig`). Compressed instructions (RVC) are decompressed to 32-bit equivalents.
3. **Emit**: Generate host RV64 instructions directly into the code buffer. No intermediate representation.
4. **Terminate**: End the block at any control flow change, privileged instruction, or MMIO-touching instruction.

#### 8.4.2 Inlined vs. Block Termination Actions

The dynarec maximizes basic block length by compiling all non-exiting instruction categories directly into host RV64 machine instructions:

| Guest Instruction Category | Dynarec Action |
|---|---|
| R-Type / I-Type Arithmetic (`add`, `sub`, `sll`, `slt`, `xor`, `srl`, `sra`, `or`, `and`, `addi`, etc.) | Emit direct RV64 word operations (`addw`, `subw`, `sllw`, `srlw`, `sraw`, `andi`, `ori`, `xori`, etc.) |
| M-Extension Multiply & Divide (`mul`, `div`, `divu`, `rem`, `remu`) | Emit direct RV64 32-bit hardware instructions (`mulw`, `divw`, `divuw`, `remw`, `remuw`) |
| M-Extension High-Half Multiply (`mulh`, `mulhu`, `mulhsu`) | Terminate block, fall back to interpreter (`executeDecoded`) for 64-bit precision without register clobbering |
| A-Extension Atomics (`lr.w`, `sc.w`, `amoswap.w`, `amoadd.w`, `amoxor.w`, `amoand.w`, `amoor.w`, `amomin.w`, `amomax.w`, `amominu.w`, `amomaxu.w`) | Emit native RV64 host atomic instructions with 512MB RAM windowing |
| Stack & Frame Loads/Stores (`lw`, `lh`, `lb`, `lhu`, `lbu`, `sw`, `sh`, `sb` on `sp`, `gp`, `s0`) | Emit direct-mapped RAM loads and stores (`(vaddr & 0x1FFFFFFF) + 0x00000000E0000000`) |
| Memory Barriers (`fence`, `fence.i`) | Emit host hardware barrier instructions |
| Timer & Cycle CSRs (`rdtime`, `rdtimeh`, `rdcycle`, `rdcycleh`) | Emit host CSR read (`0xC01` / `0xC00`) with word sign/zero extension |
| Conditional Branches (`beq`, `bne`, `blt`, `bge`, `bltu`, `bgeu`) | Terminate block, emit 2-way direct block chaining |
| Unconditional Jumps (`jal`, `jalr`) | Terminate block, update `vcpu.pc`, emit direct jump chaining |
| Privileged & System (`ecall`, `mret`, `sret`, `sfence.vma`, `wfi`, non-timer CSRs) | Terminate block, exit to M-mode hypervisor or SoftTLB |

#### 8.4.3 Host Code Emission & Direct Register Mapping

The emitter generates raw RV64 instruction words. Guest general-purpose registers `x1..x31` map directly 1-to-1 to host physical registers during basic block execution, yielding zero load/store overhead between operations.

- `stval` (CSR `0x143`): Preserves the `regs_ptr` base pointer across block boundaries.
- `sscratch` (CSR `0x140`): Saves/restores guest `t0` (`x5`) during scratch address computations.
- `scause` (CSR `0x142`): Saves/restores guest `t1` (`x6`) during scratch address computations.

Example: translating `add a0, a1, a2` (RV32) → RV64 host code:

```
addw a0, a1, a2    // Single native 32-bit arithmetic instruction!
```

### 8.5 Block Chaining

Block chaining is the most important optimization in the dynarec. It eliminates the dispatcher overhead for sequential execution by patching translated blocks to jump directly to each other.

#### 8.5.1 Direct Chaining

When Block A ends with a direct branch to address X, and Block X has already been translated:

```
Before chaining:
    Block A:
        ... translated code ...
        sd vcpu.pc, X          // update guest PC
        ret                    // return to dispatcher

After chaining:
    Block A:
        ... translated code ...
        j Block_X_code         // direct jump, no dispatcher
```

The dispatcher is bypassed entirely. Long chains of blocks execute as a single stream of host instructions.

#### 8.5.2 Conditional Branch Chaining

For conditional branches (`beq a0, a1, target`):

```
Block A:
    ... translated code ...
    beq host_a0, host_a1, .taken
    // fallthrough: next sequential block (chained or dispatcher)
    j Block_A_plus_4
.taken:
    // branch target (chained or dispatcher)
    j Block_target
```

Both the taken and not-taken paths can be independently chained as their targets are translated.

#### 8.5.3 Indirect Branch Handling

For `jalr` (register-indirect jumps, e.g., function returns via `ret`):

Indirect branches cannot be statically chained because the target depends on a register value. Two strategies:

1. **Inline cache (IBTC)**: At the branch site, emit a compare-and-jump for the most recently seen target:
   ```
   ld t0, vcpu.regs[ra]     // load guest return address
   li t1, LAST_TARGET        // last seen target (patched)
   beq t0, t1, Block_last   // hit: direct jump
   sd t0, vcpu.pc            // miss: update PC
   ret                       // return to dispatcher
   ```
   The `LAST_TARGET` and `Block_last` are patched each time the indirect branch is taken to a new target. This captures the common case where `ret` returns to the same call site repeatedly.

2. **Hash table lookup**: For polymorphic indirect branches, the code cache provides O(1) lookup by guest PC, allowing the translated code to resolve the target without returning to the dispatcher.

#### 8.5.4 Chain Invalidation

When the code cache is invalidated (due to `sfence.vma`, self-modifying code detection, or cache pressure), all chain links targeting invalidated blocks are **unlinked** — the jump instructions are patched back to `ret` (return to dispatcher). The dispatcher will then re-translate or re-chain as needed.

### 8.6 Code Cache Management

The code cache maps guest PCs to translated host code blocks:

```
┌─────────────────────────────────────────────┐
│ Code Cache (per-engine)                     │
│                                             │
│ Hash Map: guest_pc → TranslatedBlock        │
│                                             │
│ TranslatedBlock:                            │
│   - guest_pc: u32       (guest entry PC)    │
│   - host_code: [*]u8    (ptr into buffer)   │
│   - host_size: u32      (bytes of host code)│
│   - guest_size: u32     (bytes of guest code│
│   - chain_in: []ChainLink  (blocks → this)  │
│   - chain_out: []ChainLink (this → blocks)  │
│   - exec_count: u32     (for tiered compile)│
│   - tier: enum{interp, baseline, optimized} │
│                                             │
│ Code Buffer:                                │
│   [──────────────────────────────────────]   │
│   ^                  ^                  ^    │
│   block_0            block_1         write   │
│                                     cursor   │
└─────────────────────────────────────────────┘
```

**Buffer exhaustion**: When the code buffer is full:

1. Flush the entire cache (simple, effective for small buffers).
2. Or: evict cold blocks (blocks with low `exec_count`) and compact the buffer. This requires relocating surviving blocks and re-patching all chain links.

Strategy 1 is recommended initially for simplicity. The cache will re-warm quickly since hot code paths are retranslated immediately.

### 8.7 Tiered Compilation

Not all guest code deserves the same compilation effort. A kernel initialization function that runs once should not be JIT-compiled at all. A hot inner loop should get full register pinning.

#### 8.7.1 Three Tiers

| Tier | Trigger | Strategy | Cost |
|---|---|---|---|
| **Interpret** | First execution | Single-step interpreter (`step()`) | Lowest |
| **Baseline JIT** | Block executed ≥ 8 times | Direct translation, no optimization | Medium |
| **Optimized JIT** | Block executed ≥ 64 times | Register pinning, peephole opts | Highest |

#### 8.7.2 Interpretation Tier

On first encounter, a block is executed via the single-step interpreter. An `exec_count` is incremented for the block's guest PC. This avoids wasting JIT compilation time on cold code (which dominates kernel boot — device probing, one-time initialization, etc.).

The interpreter still participates in the interrupt-driven model: the S-mode dispatcher runs the interpreter, which executes guest instructions one at a time. When a timer interrupt fires, the trap handler sees the interpreter's S-mode context and yields the vcore normally.

#### 8.7.3 Baseline JIT Tier

When a block's `exec_count` reaches 8, it is JIT-compiled with the basic emitter: guest register accesses go through loads/stores to `VCpu.regs[]`, no register allocation. The block is inserted into the code cache and chained.

#### 8.7.4 Optimized JIT Tier

When a block's `exec_count` reaches 64, it is recompiled with register pinning:

1. **Scan the block**: Count references to each guest register.
2. **Allocate host registers**: Pin the N most-referenced guest registers to dedicated host registers. With ~20 host registers available (after reserving the emitter's own), most blocks can pin all referenced registers.
3. **Emit prologue**: Load pinned guest registers from `VCpu.regs[]` into host registers.
4. **Emit body**: ALU operations use host registers directly. No memory traffic.
5. **Emit epilogue**: Store pinned guest registers back to `VCpu.regs[]`.

This eliminates 70-90% of memory loads/stores in hot loops.

**Re-chaining**: When a block is recompiled at a higher tier, all incoming chain links are patched to point to the new code. The old code is left in the buffer (it will be reclaimed on cache flush).

### 8.8 Cache Coherence and Self-Modifying Code

The dynarec generates RV64 instructions at runtime and must ensure the host CPU's instruction cache (I-cache) sees the new code. RISC-V has a weak memory model for instruction fetches — stores to the code buffer are not automatically visible to instruction fetch.

#### 8.8.1 fence.i After Translation

After writing translated instructions to the code buffer, the dispatcher executes `fence.i`:

```zig
// Write translated block to code buffer
@memcpy(code_buffer[offset..], translated_bytes);

// Ensure instruction cache sees the new code
asm volatile ("fence.i");

// Now safe to jump to the translated code
```

`fence.i` ensures that all prior stores to the code buffer are visible to subsequent instruction fetches on the same hart. This is required by the RISC-V ISA for correct execution of dynamically generated code.

#### 8.8.2 Multi-Core Cache Coherence

If block chaining patches a code buffer that might be executing on another physical core (e.g., when a vcore migrates between CPUs), the patching core must ensure the other core sees the patch. The sequence is:

1. Write the patch (e.g., replace `ret` with `j target`).
2. Execute `fence rw, rw` (store-to-store ordering).
3. Send IPI to the target core.
4. Target core's IPI handler executes `fence.i` before returning to translated code.

In practice, chain patching occurs within the same vcore context (the dispatcher patches its own code), so a local `fence.i` suffices. Cross-core patching is only needed for cache invalidation broadcasts.

#### 8.8.3 Guest Self-Modifying Code Detection

If a guest writes to a memory page that contains translated code, the translations for that page must be invalidated. Detection strategies:

1. **Write-protect translated pages**: When a guest page is translated for the first time, mark it read-only in the SoftTLB. A subsequent write by the guest will trigger a page fault. The fault handler invalidates all translations from that page, marks it writable, and retries the write. This is precise but has overhead for pages that are both code and data (rare in practice).

2. **sfence.vma as invalidation signal**: When the guest executes `sfence.vma` (which it must do after modifying code, per the RISC-V spec), the dynarec flushes the affected code cache entries. Well-behaved guests always execute `sfence.vma` after code modification, so this catches the common case without page-protection overhead.

Both strategies should be implemented: `sfence.vma`-triggered invalidation for correctness with well-behaved guests, and write-protection as a safety net for guests that don't follow the spec.

### 8.9 PMP Sandbox for Translated Code

Translated code runs in S-mode and must be strictly sandboxed. The hypervisor configures PMP entries that grant S-mode access to **only**:

| PMP Entry | Region | Access |
|---|---|---|
| 0-1 (TOR) | Guest RAM (`guest_hpa_base` to `+ guest_ram_size`) | R/W/X |
| 2-3 (TOR) | JIT code buffer | R/W/X |
| 4-5 (TOR) | Emulator stack + TLS slab | R/W |
| 6-7 (TOR) | VCpu state + SoftTLB data structures | R/W |
| 8-9 (TOR) | Hypervisor text/data | **DENY** |
| 10-11 (TOR) | Physical device MMIO | **DENY** |
| 14-15 (NAPOT) | Catch-all: everything else | **DENY** |

This means:
- A bug in the SoftTLB cannot leak other guests' memory.
- A bug in the JIT emitter cannot overwrite hypervisor code.
- The emulator cannot directly access physical devices.
- All hardware interaction goes through `ecall` to M-mode.

### 8.10 VCpu State

The virtual CPU state for an emulated guest:

```zig
pub const VCpu = struct {
    // General-purpose registers
    regs: [32]u32,          // x0-x31 (x0 is hardwired to 0)
    pc: u32,                // Program counter
    privilege_mode: u2,     // 0=User, 1=Supervisor, 3=Machine

    // Machine-mode CSRs
    mstatus: u32,
    medeleg: u32,
    mideleg: u32,
    mie: u32,
    mip: u32,
    mtvec: u32,
    mepc: u32,
    mcause: u32,
    mtval: u32,
    mscratch: u32,

    // Supervisor-mode CSRs
    sstatus: u32,           // view into mstatus
    sie: u32,               // view into mie
    sip: u32,               // view into mip
    stvec: u32,
    sepc: u32,
    scause: u32,
    stval: u32,
    sscratch: u32,
    satp: u32,              // Sv32 page table root

    // Timer
    vstimecmp: u64,         // virtual timer compare value

    // Floating-point (future)
    fregs: [32]u64,         // f0-f31 (double-precision)
    fcsr: u32,

    // Vector registers (future)
    vregs: [32]VReg,
    vl: u32,
    vtype: u32,

    // Exception injection
    pub fn injectException(self: *VCpu, cause: u32, fault_pc: u32, stval: u32) void { ... }
    pub fn checkPendingInterrupts(self: *VCpu) ?InterruptCause { ... }
};
```

### 8.11 Exception Injection

When the emulator detects a guest exception:

```zig
pub fn injectException(self: *VCpu, cause: u32, fault_pc: u32, stval: u32) void {
    // Check delegation: should this go to S-mode or M-mode?
    const delegate_to_s = (self.medeleg & (1 << cause) != 0) and
                          (self.privilege_mode < PRIV_MACHINE);

    if (delegate_to_s) {
        self.sepc = fault_pc;
        self.scause = cause;
        self.stval = stval;
        // sstatus.SPP = current privilege
        // sstatus.SPIE = sstatus.SIE
        // sstatus.SIE = 0
        self.privilege_mode = PRIV_SUPERVISOR;
        self.pc = self.stvec & ~@as(u32, 3); // BASE address
    } else {
        self.mepc = fault_pc;
        self.mcause = cause;
        self.mtval = stval;
        // mstatus.MPP = current privilege
        // mstatus.MPIE = mstatus.MIE
        // mstatus.MIE = 0
        self.privilege_mode = PRIV_MACHINE;
        self.pc = self.mtvec & ~@as(u32, 3);
    }
}
```

### 8.12 Interrupt Checking in Translated Code

Translated code must respond to pending interrupts (timer, IPI, external). Since the code runs natively, interrupt checking is integrated into the block structure:

1. **Hardware interrupts** (timer, IPI): These trap directly to M-mode. No special handling needed in translated code — the hardware takes care of it.

2. **Emulated interrupts** (guest `mip` bits set by device emulation): At the entry of each translated block, emit a check:
   ```
   // At block entry: check for pending emulated interrupts
   lw t0, offsetof(VCpu.mip)(s0)
   lw t1, offsetof(VCpu.mie)(s0)
   and t0, t0, t1
   bnez t0, .handle_interrupt    // branch to interrupt dispatch
   // ... rest of translated block ...
   .handle_interrupt:
   // Store current PC, call interrupt injection, return to dispatcher
   ```

   This adds ~4 instructions per block entry. For optimized-tier blocks in tight loops, this can be hoisted out of inner loops if the loop body doesn't touch `mip`/`mie`.

### 8.13 Multi-vCore Emulation (SMP)

Each emulated guest can have multiple virtual harts. Each emulated hart is a separate `VirtualCore` in the scheduler — **not** a sub-vcore managed within a single vcore.

This is a critical architectural decision: emulated harts are first-class vcores that are scheduled independently, exactly like native vcores. This means:

- An emulated 4-hart guest creates 4 `VirtualCore` entries, each schedulable on any physical core.
- Multiple emulated harts can run simultaneously on different physical cores (true parallelism).
- The scheduler treats them identically to native vcores.

Each emulated vcore has its own:
- `VCpu` state (registers, CSRs, privilege mode)
- `SoftTlb` instance
- `Engine` with its own JIT code cache
- PMP configuration

Shared state between emulated vcores of the same guest:
- Guest RAM (shared, same HPA mapping)
- Device bus (vUART, vCLINT, vPLIC) — protected by per-device spinlocks

#### 8.13.1 Atomic Operations

With emulated harts running on separate physical cores, guest atomic instructions (AMO, LR/SC) must provide real atomicity:

- **AMO instructions** (`amoadd.w`, `amoswap.w`, etc.): Translated to host RV64 atomic instructions operating on the guest's HPA. Since the guest RAM is physically shared between all emulated vcores, host atomics provide correct semantics.
   ```
   // Guest: amoadd.w a0, a1, (a2)
   // Host translation:
   ld t0, vcpu.regs[12]         // load guest address from a2
   call softtlb.translate(t0)   // GVA → HPA
   amoadd.w t1, a1_host, (hpa) // host atomic on physical memory
   sd t1, vcpu.regs[10]         // store result to guest a0
   ```

- **LR/SC pairs**: Translated to host LR/SC pairs on the HPA. The host's reservation mechanism provides the correct semantics.

### 8.14 Precise Fault Analysis

Instead of the blunt "terminate after 64 repeated traps" approach, the dynarec uses a fault classification system:

| Fault Type | Detection | Action |
|---|---|---|
| **Known-emulatable** (CSR access, MMIO) | Instruction successfully decoded and handled | Reset fault counter, continue |
| **Unknown instruction** | Decoder returns `.unknown` | Log with full context on first occurrence. Terminate after 3 consecutive unknowns at the same PC |
| **True infinite loop** | Same PC, same register state on consecutive traps | Terminate immediately (the guest is stuck) |
| **Progress stall** | Same PC but different register state | Allow up to 16 repetitions (guest might be polling a device) |
| **Page fault cascade** | Repeated page faults with the SoftTLB unable to resolve | Check if the guest's page tables are corrupt. Log and terminate |

```zig
const FaultTracker = struct {
    last_pc: u64,
    last_regs_hash: u64,    // hash of register file for cycle detection
    same_pc_count: u32,
    unknown_count: u32,

    pub fn recordFault(self: *FaultTracker, pc: u64, regs_hash: u64, fault_type: FaultType) Action {
        if (fault_type == .known_emulatable) {
            self.reset();
            return .continue_execution;
        }

        if (pc == self.last_pc and regs_hash == self.last_regs_hash) {
            return .terminate_infinite_loop;  // exact state cycle
        }

        if (pc == self.last_pc) {
            self.same_pc_count += 1;
            if (fault_type == .unknown and self.same_pc_count >= 3) {
                return .terminate_unknown_instruction;
            }
            if (self.same_pc_count >= 16) {
                return .terminate_progress_stall;
            }
        } else {
            self.same_pc_count = 0;
        }

        self.last_pc = pc;
        self.last_regs_hash = regs_hash;
        return .continue_execution;
    }
};
```

---

## 9. SBI Firmware Interface

### 9.1 Overview

The hypervisor presents an SBI v2.0-compliant firmware interface to all guests. For native guests, `ecall` traps directly to M-mode. For emulated guests, the JIT emits an `ecall` instruction that traps to M-mode — the hypervisor's SBI dispatcher receives both identically.

### 9.2 Supported Extensions

| EID | Name | Functions | Description |
|---|---|---|---|
| `0x10` | BASE | `GET_SPEC_VERSION`, `GET_IMP_ID`, `GET_IMP_VERSION`, `PROBE_EXT`, `GET_MVENDORID`, `GET_MARCHID`, `GET_MIMPID` | SBI capability discovery |
| `0x54494D45` | TIME | `SET_TIMER` | Guest timer programming |
| `0x735049` | IPI | `SEND_IPI` | Inter-processor interrupt delivery |
| `0x52464E43` | RFENCE | `REMOTE_FENCE_I`, `REMOTE_SFENCE_VMA`, `REMOTE_SFENCE_VMA_ASID` | Remote TLB/fence operations |
| `0x48534D` | HSM | `HART_START`, `HART_STOP`, `HART_GET_STATUS` | Hart State Management for SMP |
| `0x4442434E` | DBCN | `CONSOLE_WRITE`, `CONSOLE_READ`, `CONSOLE_WRITE_BYTE` | Debug Console |
| `0x53525354` | SRST | `SYSTEM_RESET` | System shutdown/reboot |
| `0x0A000005` | DIOSIX | `YIELD`, `FORK`, `DROP_TRUST`, `EXIT` | Custom VM management |

### 9.3 SBI Call Flow

For **native** guests:
```
Guest ecall (VS-mode) → trap to M-mode → SBI dispatch
    → read a7/a6/a0-a5 from ThreadContext
    → handle, set a0/a1
    → advance mepc += 4
    → mret back to VS-mode
```

For **emulated** guests:
```
JIT emits: store vcpu.regs to ThreadContext, ecall
    → trap to M-mode → SBI dispatch
    → read a7/a6/a0-a5 from ThreadContext
    → handle, set a0/a1 (writes to VCpu.regs via ThreadContext)
    → advance mepc (points back into dispatcher)
    → mret back to S-mode dispatcher
    → dispatcher updates vcpu.pc += 4
    → continues execution
```

The SBI dispatcher code is shared. The only difference is where the register values come from (hardware ThreadContext vs VCpu.regs mapped into ThreadContext).

### 9.4 Timer Programming (SET_TIMER)

When the guest calls SBI `SET_TIMER(stime)`:

1. **Native path**: Write `stime` to `vstimecmp`. Clear `VSTIP` in `hvip`. Reprogram physical timer.
2. **Emulated path**: Write `stime` to `vcpu.vstimecmp`. Clear `STIP` in `vcpu.mip`. Reprogram physical timer. The physical timer will fire when the deadline passes, trapping to M-mode, which injects the timer interrupt into the VCpu.

In both cases, the physical timer is the delivery mechanism. The hypervisor programs it to fire at `min(timeslice, guest_deadline)`.

### 9.5 IPI Delivery (SEND_IPI)

1. **Native path**: Write 1 to target hart's CLINT `msip`. Hardware traps to M-mode on the target core. Hypervisor injects `VSSIP` via `hvip`.
2. **Emulated path**: Set `SSIP` in target vcore's `vcpu.mip`. If the target vcore is blocked (WFI), wake it via `tryWake()` and re-queue it. If it's running on another physical core, send a physical IPI to that core so the timer handler notices the pending emulated interrupt.

### 9.6 Debug Console (DBCN)

The DBCN extension provides early boot console output:

- **CONSOLE_WRITE**: Read `num_bytes` from guest memory at `base_addr`. For native guests, use `hlv.bu` for safe guest memory access. For emulated guests, use the SoftTLB to translate guest VA to HPA, then read bytes directly. Output to hypervisor's physical UART.
- **CONSOLE_WRITE_BYTE**: Single-character output via `a0`.

---

## 10. Device Emulation & I/O

### 10.1 Device Tree Provisioning

Every guest receives a device tree blob (DTB) describing its virtual hardware:

- **Memory**: Single `/memory` node with the guest's RAM region.
- **CPUs**: One `/cpus/cpu@N` per virtual hart, with ISA string matching guest architecture.
- **Serial**: 16550-compatible UART at `0x10000000`, plus virtio-console at `0x10001000`.
- **Timer**: CLINT at `0x02000000`.
- **Interrupt controller**: PLIC at `0x0c000000`.
- **Virtio devices**: virtio-mmio transport at `0x10001000` onwards.
- **Chosen node**: Boot arguments (`console=hvc0 earlycon=sbi`).

The DTB is constructed by pruning the host's DTB or building one from scratch for non-RISC-V guests.

### 10.2 Virtual UART (16550)

**Register map** (base `0x10000000`, 8-byte stride):

| Offset | Register | Read | Write |
|---|---|---|---|
| `0x00` | RBR/THR/DLL | Receive buffer / Divisor LSB | Transmit holding / Divisor LSB |
| `0x01` | IER/DLM | Interrupt enable / Divisor MSB | Interrupt enable / Divisor MSB |
| `0x02` | IIR/FCR | Interrupt ID | FIFO control |
| `0x03` | LCR | Line control | Line control |
| `0x04` | MCR | Modem control | Modem control |
| `0x05` | LSR | Line status | — |
| `0x06` | MSR | Modem status | — |
| `0x07` | SCR | Scratch | Scratch |

- **THR writes**: Characters forwarded to hypervisor's physical UART.
- **LSR reads**: Always report `THRE | TEMT` (transmitter ready).
- **FCR**: Tracked to satisfy Linux 8250 driver's 16550A autoconfig probe.
- **Interrupts**: Wired to vPLIC for RX-ready notifications.

### 10.3 Virtual CLINT

- **`mtime`** (`0x0200BFF8`): Returns host `rdtime`.
- **`mtimecmp`** (`0x02004000 + hart_id * 8`): Per-hart timer deadline.
- **`msip`** (`0x02000000 + hart_id * 4`): Software interrupt pending.

### 10.4 Virtual PLIC

- **Priority** (`0x0c000000 + source * 4`): Per-source priority.
- **Pending** (`0x0c001000`): Pending interrupt bitmap.
- **Enable** (`0x0c002000 + context * 0x80`): Per-context enable bitmaps.
- **Threshold/Claim** (`0x0c200000 + context * 0x1000`): Priority threshold and claim/complete.

### 10.5 Virtio Devices

For production-quality I/O, virtio-mmio devices are implemented:

#### 10.5.1 Virtio Transport (virtio-mmio)

Each virtio device occupies a 4KB MMIO region:

| Offset | Register | Description |
|---|---|---|
| `0x000` | MagicValue | `0x74726976` ("virt") |
| `0x004` | Version | 2 (virtio 1.0+) |
| `0x008` | DeviceID | Device type (1=net, 2=blk, 3=console) |
| `0x00c` | VendorID | `0x0A000005` (diosix) |
| `0x010` | DeviceFeatures | Feature bits (page selected by DeviceFeaturesSel) |
| `0x020` | DriverFeatures | Guest-acknowledged features |
| `0x030` | QueueSel | Select active virtqueue |
| `0x034` | QueueNumMax | Max queue depth |
| `0x038` | QueueNum | Guest-configured queue depth |
| `0x044` | QueueReady | Queue ready flag |
| `0x050` | QueueNotify | Guest → host doorbell |
| `0x060` | InterruptStatus | Pending interrupt flags |
| `0x064` | InterruptACK | Interrupt acknowledgment |
| `0x070` | Status | Driver status (ACKNOWLEDGE, DRIVER, FEATURES_OK, DRIVER_OK) |
| `0x080` | QueueDescLow/High | Descriptor table physical address |
| `0x090` | QueueDriverLow/High | Available ring physical address |
| `0x0a0` | QueueDeviceLow/High | Used ring physical address |

#### 10.5.2 virtio-console (Device ID 3)

Replaces the 16550 as the primary console for full-featured bidirectional I/O:

- **Virtqueue 0 (RX)**: Guest posts receive buffers. Hypervisor fills them when UART input arrives.
- **Virtqueue 1 (TX)**: Guest posts transmit buffers. Hypervisor drains them to the physical UART.
- **Features**: `VIRTIO_CONSOLE_F_SIZE` (report terminal size), `VIRTIO_CONSOLE_F_MULTIPORT` (future: multiple consoles per guest).
- **Interrupt**: When RX data is available or TX buffers are consumed, the device sets `InterruptStatus` and asserts an interrupt to the guest via the vPLIC.

#### 10.5.3 virtio-blk (Device ID 2) — Future

Virtual block device backed by a memory region or host file:

- **Virtqueue 0**: Request queue (read/write/flush/discard).
- **Request format**: `{ type, ioprio, sector, data[], status }`.
- **Backing**: In-memory ramdisk (for initramfs-less boot) or host file I/O via SBI extension.

#### 10.5.4 virtio-net (Device ID 1) — Future

Virtual network device:

- **Virtqueue 0 (RX)**, **Virtqueue 1 (TX)**: Ethernet frame exchange.
- **Features**: `VIRTIO_NET_F_MAC`, `VIRTIO_NET_F_STATUS`.
- **Backend**: Inter-VM virtual switch (frames routed between sibling VMs) or host TAP device.

### 10.6 MMIO Routing

All MMIO accesses are routed through the virtual device bus:

```
Guest MMIO access
    │
    ▼
Bus.read() / Bus.write()
    │
    ├─ 0x10000000..0x100000FF → vUART (16550)
    ├─ 0x10001000..0x10001FFF → virtio-console
    ├─ 0x10002000..0x10002FFF → virtio-blk (future)
    ├─ 0x10003000..0x10003FFF → virtio-net (future)
    ├─ 0x02000000..0x0200FFFF → vCLINT
    ├─ 0x0C000000..0x0FFFFFFF → vPLIC
    └─ other → return 0 / ignore (unmapped device)
```

**For native guests**: MMIO traps occur on G-stage page faults. The hypervisor decodes the faulting load/store and routes through the bus.

**For emulated guests**: The SoftTLB detects MMIO addresses and the translated code calls the bus directly (in S-mode). No trap to M-mode needed for MMIO.

---

## 11. Interrupt Architecture

### 11.1 Physical Interrupt Flow

```
Hardware Event
    │
    ▼
RISC-V Interrupt Controller
    │
    ├─ Timer (MTIP) ──► M-mode trap handler
    │                    └─ Check: vcore timer expired?
    │                       ├─ Yes: Inject VSTIP/set vcpu.mip
    │                       └─ Timeslice expired: yield to scheduler
    │
    ├─ Software (MSIP) ──► M-mode trap handler
    │                       └─ Clear MSIP
    │                          └─ Check IPI reason, reschedule
    │
    └─ External (MEIP) ──► M-mode trap handler
                            └─ PLIC claim
                               └─ Route to guest vPLIC
```

### 11.2 Virtual Interrupt Injection

**For native guests** (H-extension): Set bits in `hvip` CSR. CPU delivers them automatically.

**For emulated guests**: Set bits in `vcpu.mip`. The translated code checks `mip & mie` at block entry (§8.12) and calls `injectException()` when pending.

**Unified path**: The M-mode timer handler doesn't need to distinguish. For native vcores, it sets `hvip`. For emulated vcores, it sets `vcpu.mip`. Both are accessed through the `VirtualCore.exec_path` union.

### 11.3 Timer Interrupt Lifecycle

1. Guest calls SBI `SET_TIMER(deadline)`.
2. Hypervisor programs physical timer to `min(timeslice, deadline)`.
3. Physical timer fires → M-mode trap.
4. Hypervisor checks: has the guest's deadline passed?
   - **Yes**: Inject timer interrupt. `mret` back to guest.
   - **No**: Timeslice expired. Yield vcore to scheduler.
5. Guest kernel handles timer, calls `SET_TIMER` again.

This is identical for native and emulated guests. The physical timer is the sole mechanism. No polling, no budget counting.

### 11.4 IOMMU Integration

On hardware with the RISC-V IOMMU (Ziommu), DMA-capable devices are restricted to accessing only their assigned guest's memory:

```
Physical Device (DMA)
    │
    ▼
RISC-V IOMMU
    │
    ├─ Check device → guest mapping
    ├─ Translate device DMA address → guest HPA via IOMMU page tables
    ├─ If out of range: block DMA, signal fault
    └─ If valid: allow DMA to guest RAM

IOMMU page tables are configured per-device:
    Device → Guest mapping table → HPA range (guest RAM only)
    Hypervisor memory: NEVER mapped in any device's IOMMU tables
```

**Initialization** (in `boot.zig`):

1. Parse DTB for IOMMU nodes (`compatible = "riscv,iommu"`).
2. For the Root VM: configure IOMMU to allow assigned devices to DMA only into Root VM's HPA range.
3. For child VMs: configure IOMMU when devices are assigned via a future `ASSIGN_DEVICE` SBI call.
4. Deny-by-default: devices without explicit IOMMU configuration cannot DMA anywhere.

---

## 12. Serial Console & Guest Interaction

### 12.1 Console Architecture

```
Guest Output:
    Guest kernel printk()
        └─ SBI DBCN (early boot) or 16550 THR write or virtio-console TX
            └─ Hypervisor debug.writeFromGuest()
                └─ ConsoleState multiplexer
                    └─ Physical NS16550 UART TX

Guest Input:
    Physical UART RX interrupt
        └─ Hypervisor UART ISR
            └─ ConsoleState input buffer
                └─ Guest reads vUART RBR or virtio-console RX
```

### 12.2 Console Multiplexing

- Each guest's output is tagged with ANSI color codes (Green: Root VM, White: hypervisor, others: children).
- Input is directed to the currently focused guest.
- GDB stub can hijack the UART when enabled.

### 12.3 Boot Console Stages

1. **SBI earlycon** (`earlycon=sbi`): Linux uses SBI DBCN for early boot messages.
2. **HVC0** (`console=hvc0`): SBI-backed console as primary.
3. **16550 driver** (`ttyS0`): Linux 8250 driver probes UART, detects 16550A.
4. **Login prompt**: `getty` opens `/dev/console`, displays `buildroot-guest login:`.

---

## 13. Boot Sequence: Cold Start to Login Prompt

### 13.1 Complete Timeline

```
t=0     Physical CPU reset. All harts enter _start.
t=0+    Hart 0: Assign CPU IDs, clear BSS, call main().
t=1     Hart 0: Parse DTB → discover RAM, UART, CLINT, PLIC, IOMMU.
        Audit CPU features (H-ext, Sstc, Smstateen).
        Initialize buddy allocator + slab allocator.
        Initialize per-CPU scheduler queues.
t=2     Hart 0: Load Root VM ELF from embedded .rootvm section.
        Detect guest architecture via ELF header.
        Allocate guest RAM.
        Build/prune guest DTB (including virtio device nodes).
t=3     Hart 0: Create Root VM Guest struct (slab alloc).
        Create vcores:
          - riscv64: native (H-ext or PMP)
          - others: emulated (alloc Engine, SoftTLB, Bus, VCpu, JIT buffer)
        Load ELF segments. Set boot vcore PC, a0, a1.
t=4     Hart 0: Release boot flag. All harts enter main loop.
t=5     Hart 0: Schedule boot vcore. Context switch. mret.
        Native: enters VS-mode, guest code runs.
        Emulated: enters S-mode, dispatcher translates first block,
                  chains it, runs it natively until timer interrupt.
t=6     Guest Linux: head.S, DTB parse, page tables.
        SBI BASE probe. Early messages via SBI DBCN.
t=7     Guest Linux: Memory init, VFS, RCU.
        SBI HSM HART_START for secondary CPUs.
t=8     Hypervisor: Creates secondary vcores (slab alloc).
        Enqueues them. IPIs wake idle physical cores.
t=9     Guest Linux: "smp: Brought up 1 node, N CPUs"
t=10    Guest Linux: 16550 driver probes UART, detects 16550A.
t=11    Guest Linux: Init process starts.
t=12    Guest Linux: "buildroot-guest login: "
```

### 13.2 Execution Path Comparison

| Aspect | Native (riscv64) | Emulated (riscv32, aarch64, x86_64) |
|---|---|---|
| Instruction execution | Hardware (full speed) | JIT translated → runs natively as RV64 |
| Preemption mechanism | Hardware timer interrupt | Hardware timer interrupt (identical) |
| Scheduling | VirtualCore in per-CPU queue | VirtualCore in per-CPU queue (identical) |
| Memory translation | Hardware G-stage (Sv39x4) | Software SoftTLB (set-associative) |
| Timer delivery | Hardware `vstimecmp` / `hvip` | Physical timer → `vcpu.mip` |
| IPI delivery | CLINT `msip` → `hvip VSSIP` | `vcpu.mip` SSIP + physical IPI |
| Console | SBI DBCN + 16550 + virtio | SBI DBCN + 16550 + virtio (identical) |
| SMP boot | Hardware harts via HSM | Independent vcores via HSM (identical) |
| PMP configuration | Guest RAM only (tight) | Guest RAM + JIT buffer (tight) |
| Privilege level | VS-mode | S-mode (translated code runs natively) |

---

## 14. Security Model

### 14.1 Trust Boundaries

```
┌───────────────────────────────────────────────────────────┐
│  TRUSTED (M-mode)                                         │
│  - Hypervisor core (scheduler, memory, SBI)               │
│  - Trap handler                                           │
│  - Physical device drivers                                │
│  - IOMMU configuration                                    │
├───────────────────────────────────────────────────────────┤
│  SEMI-TRUSTED (S/VS-mode, hardware trust)                 │
│  - Root VM (MMIO access via G-stage identity map)         │
│  - Dynarec translated code (PMP-sandboxed to guest RAM    │
│    + JIT buffer only)                                     │
├───────────────────────────────────────────────────────────┤
│  UNTRUSTED (VS/VU-mode or emulated S/U-mode)              │
│  - Child VMs (no hardware access)                         │
│  - Forked VMs after DROP_TRUST                            │
└───────────────────────────────────────────────────────────┘
```

### 14.2 Isolation Mechanisms

1. **H-extension G-stage paging**: Each native guest has its own G-stage page table. The hypervisor's HPA range is never mapped.
2. **Tight PMP for emulated guests**: S-mode code can only access guest RAM, JIT buffer, emulator stack, and VCpu state. Cannot access hypervisor memory, other guests, or physical devices.
3. **PMP for PMP-fallback native guests**: TOR-mode entries restrict S-mode to guest RAM and CPU slab.
4. **IOMMU**: DMA-capable devices are restricted to their assigned guest's HPA range. Hypervisor memory is never DMA-accessible.
5. **Lineage isolation**: VMs communicate only with parent and children.
6. **Resource quotas**: Hard limits on RAM, vCPUs, descendant depth.
7. **DROP_TRUST**: One-way revocation of hardware access.

### 14.3 Emulation Security

The dynarec runs in S-mode with tight PMP:

- Cannot access hypervisor data structures.
- Cannot access other guests' RAM.
- Cannot access physical device registers.
- All hardware interaction goes through `ecall` to M-mode.
- A bug in the SoftTLB or JIT can corrupt the guest's state but cannot escape the PMP sandbox.

### 14.4 JIT Security

Translated code executes in the JIT code buffer, which is both writable (for translation) and executable (for execution). This W^X violation is contained by PMP:

- Only the owning vcore's S-mode context can access the buffer.
- The hypervisor in M-mode never executes code from the buffer.
- The buffer is not mapped into any guest's address space.
- On vcore teardown, the buffer is zeroed and returned to the slab allocator.

---

## 15. Hierarchical VM Management

### 15.1 The Lineage Tree

```
                    ┌──────────┐
                    │ Root VM  │  (progenitor, hardware trust)
                    │  id: 0   │
                    └────┬─────┘
                         │
              ┌──────────┼──────────┐
              │                     │
        ┌─────┴─────┐        ┌─────┴─────┐
        │ Child A   │        │ Child B   │
        │  id: 1    │        │  id: 2    │
        └─────┬─────┘        └───────────┘
              │
        ┌─────┴─────┐
        │ Grandchild │
        │  id: 3     │
        └────────────┘
```

### 15.2 Fork Workflow

1. Root VM loads untrusted guest image.
2. SBI `FORK` → hypervisor creates child with CoW memory.
3. Child calls SBI `DROP_TRUST` → permanently revokes hardware access.
4. Child calls SBI `SRST` → reboots into untrusted image.
5. Child runs isolated, SBI-only communication with parent.

### 15.3 Resource Quota Cascade

```
Root VM: { ram: 100000, vcpus: 16, depth: 4 }
    ├─ Child A: { ram: 50000, vcpus: 8, depth: 3 }
    │   └─ Grandchild: { ram: 25000, vcpus: 4, depth: 2 }
    └─ Child B: { ram: 30000, vcpus: 4, depth: 3 }
```

Quotas are returned to the parent on child termination.

---

## 16. Guest State Serialization

### 16.1 Purpose

Serialization enables:

- **Checkpoint/restore**: Snapshot a running guest for later resumption or debugging.
- **Live migration**: Move a running guest between physical hosts.
- **Fast cloning**: Serialize parent → deserialize into child (alternative to CoW fork for small VMs).

### 16.2 Serialization Format

A serialized guest state is a self-contained binary blob:

```
SerializedGuest:
    header:
        magic: u32 = 0x44495853  ("DIXS")
        version: u32
        guest_arch: enum { riscv64, riscv32, aarch64, x86_64 }
        num_vcores: u32
        ram_size: u64
        checksum: u64
    vcores[]:
        for each vcore:
            exec_path: enum { native, emulated }
            state: enum { running, ready, stopped, blocked }
            if native:
                thread_context: ThreadContext (31 GPRs)
                machine_state: MachineState (mepc, mstatus, etc.)
                guest_state: GuestState (VS-mode CSRs)
            if emulated:
                vcpu: VCpu (regs, CSRs, pc, privilege_mode)
                // JIT code cache is NOT serialized — it re-warms on restore
    memory:
        page_bitmap: [ram_size / 4096]u1  // which pages are populated
        page_data: compressed page contents (only populated pages)
    devices:
        uart_state: vUART register snapshot
        clint_state: mtimecmp per hart
        plic_state: priority, pending, enable, threshold per context
        virtio_state[]: per-device queue descriptors, ring positions
    lineage:
        parent_id: ?u32
        children_ids: []u32
        quotas: QuotaSet
```

### 16.3 Checkpoint/Restore Flow

**Checkpoint**:
1. Pause all vcores (set state to `.stopped`, send IPIs).
2. Wait for all vcores to stop (spin on `running_on_cpu` flags).
3. Serialize vcore state, device state.
4. Serialize memory pages (compress with LZ4 or zstd for speed).
5. Write serialized blob to output (SBI call to parent, or memory-mapped output device).
6. Resume vcores (or keep stopped for snapshot-and-continue).

**Restore**:
1. Allocate new Guest struct and RAM.
2. Deserialize memory pages into the new Guest's RAM.
3. Deserialize vcore state, creating new VirtualCore structs.
4. Deserialize device state, reinitializing virtual devices.
5. Queue vcores into scheduler. The JIT code cache starts empty and re-warms as blocks are executed.

### 16.4 Live Migration

Live migration extends checkpoint/restore with iterative pre-copy:

1. **Pre-copy phase**: While the guest continues running, track dirty pages. Periodically send dirty pages to the destination host. Repeat until the dirty page set is small.
2. **Stop-and-copy**: Pause the guest. Send the final dirty pages and vcore state.
3. **Resume on destination**: Restore the guest on the new host. Resume execution.

Dirty page tracking integrates with the G-stage page tables (clear dirty bits, catch write faults) for native guests, and with the SoftTLB write tracking for emulated guests.

---

## 17. Nested Virtualization

### 17.1 Scenario

A native riscv64 guest wants to run its own hypervisor using the H-extension. The guest kernel accesses H-extension CSRs (`hstatus`, `hgatp`, `hedeleg`, etc.) which are not directly available in VS-mode.

### 17.2 Design

Nested virtualization requires the hypervisor to trap and emulate the guest's H-extension CSR accesses:

```
Guest Hypervisor (VS-mode)
    │
    │  csrw hgatp, ...   (virtual instruction trap)
    ▼
Diosix Hypervisor (M-mode)
    │
    ├─ Decode: guest accessing hgatp
    ├─ Shadow: maintain a "virtual hgatp" in vcore state
    ├─ Compose: merge guest's G-stage tables with diosix's G-stage
    │   (guest's GPA → guest's HPA → real HPA, two-level walk)
    └─ Program real hgatp with composed table
```

### 17.3 Shadow G-Stage Tables

The hypervisor maintains shadow G-stage page tables that compose the guest hypervisor's G-stage mapping with diosix's own mapping:

```
Guest's nested guest VA
    → Guest hypervisor's VS-stage tables (guest controls)
    → Guest Physical Address (GPA) in guest's view
    → Guest hypervisor's G-stage tables (virtual, emulated by diosix)
    → "Guest Host Physical Address" (what the guest thinks is HPA)
    → Diosix's G-stage tables (real, hardware-enforced)
    → Real Host Physical Address (HPA)
```

Diosix composes the guest's virtual G-stage tables with its own real G-stage tables into shadow tables that the hardware walks in a single stage.

### 17.4 Extensibility

The CSR emulation infrastructure in `xint.zig` (which already handles `stimecmp`, `siselect`, etc.) should be structured as a dispatch table so adding new emulated CSRs (the H-extension set) is a matter of adding entries:

```zig
const emulated_csrs = .{
    .{ 0x600, "hstatus",  handleHstatus  },
    .{ 0x680, "hgatp",    handleHgatp    },
    .{ 0x602, "hedeleg",  handleHedeleg  },
    .{ 0x603, "hideleg",  handleHideleg  },
    .{ 0x606, "hcounteren", handleHcounteren },
    .{ 0x60a, "henvcfg",  handleHenvcfg  },
    .{ 0x605, "hvip",     handleHvip     },
    // ... etc.
};
```

This is preparatory scaffolding. Full nested virtualization is a Phase 7 feature, but structuring the code now avoids a painful refactor later.

---

## 18. Testing & Validation Strategy

### 18.1 Unit Tests

Run via `./scripts/build.sh test`:

- Scheduler: queue insert/remove, work-stealing correctness, vruntime accounting.
- Slab allocator: alloc/free/exhaustion/new-slab.
- Buddy allocator: allocation/free/coalescing/refcount.
- SoftTLB: set-associative lookup, LRU eviction, MMIO bypass, page walk correctness.
- RV32 decoder: all instruction formats, compressed decompression.
- Block chaining: chain/unlink/invalidation.
- Code cache: lookup, eviction, buffer exhaustion.
- Device registers: read/write behavior for 16550, CLINT, PLIC, virtio.
- Serialization: round-trip serialize/deserialize for all state types.
- Fault tracker: classification accuracy for all fault types.

#### 18.1.1 Dynamic Binary Recompiler (Dynarec) Instruction Unit Test Suite

All dynamically translated instruction categories must be backed by comprehensive unit tests that verify bit-exact host RV64 code generation, register safety invariants, and architectural correctness against the reference interpreter.

| Instruction Suite | Coverage & Validation Requirements | Test Location |
|---|---|---|
| **RV32I Base Integer** | R-type arithmetic (`add`, `sub`, `sll`, `slt`, `sltu`, `xor`, `srl`, `sra`, `or`, `and`), I-type immediates (`addi`, `slli`, `srli`, `srai`, `andi`, `ori`, `xori`, `slti`, `sltiu`), upper immediates (`lui`, `auipc`). | `decoders/rv32.zig`, `dynarec/engine.zig` |
| **RV32M Multiply/Divide** | 32-bit hardware ops (`mulw`, `divw`, `divuw`, `remw`, `remuw`), high-half ops (`mulh`, `mulhu`, `mulhsu`) verified for clean fallback and 64-bit precision. | `decoders/rv32.zig`, `dynarec/engine.zig` |
| **RV32A Atomic Memory** | `lr.w`, `sc.w`, `amoswap.w`, `amoadd.w`, `amoxor.w`, `amoand.w`, `amoor.w`, `amomin.w`, `amomax.w`, `amominu.w`, `amomaxu.w` with 512MB RAM windowing and scratch CSR preservation (`sscratch`/`scause`). | `decoders/rv32.zig`, `dynarec/engine.zig` |
| **RV32C Compressed (RVC)** | Decompression for stack/register ops (`c.li`, `c.lui`, `c.addi`, `c.addi16sp`, `c.mv`, `c.jr`, `c.jalr`, `c.lwsp`, `c.swsp`, etc.). | `decoders/rv32.zig` |
| **Memory Operations** | Fast direct loads and stores (`lw`, `lh`, `lb`, `lhu`, `lbu`, `sw`, `sh`, `sb` on `sp`, `gp`, `s0`) with 35-bit shift 512MB DRAM bounds check (`0xE0000000..0xFFFFFFFF`). | `dynarec/engine.zig` |
| **Barriers & CSRs** | `fence`, `fence.i`, `rdtime`, `rdtimeh`, `rdcycle`, `rdcycleh` emission and register writeback. | `decoders/rv32.zig`, `dynarec/engine.zig` |
| **Control Flow & Chaining** | Conditional branch 2-way chaining (`beq`, `bne`, `blt`, `bge`, `bltu`, `bgeu`) and direct jump chaining (`jal`, `jalr`). | `dynarec/engine.zig` |

> [!IMPORTANT]
> **Mandatory Extension Policy**: Any newly added instruction or foreign architecture decoder (e.g. AArch64, x86_64) must provide matching decoder tests and dynarec emission unit tests before integration into the JIT engine.

### 18.2 Integration Tests (QEMU)

**Native riscv64 guest**:
```bash
./scripts/build.sh run -Dguest-arch=riscv64 -Doptimize=ReleaseFast
```
Expected: Linux boots to `login:` within ~30 seconds.

**Emulated riscv32 guest**:
```bash
./scripts/build.sh run -Dguest-arch=riscv32 -Doptimize=ReleaseFast
```
Expected: Linux boots to `login:`. With block chaining and tiered compilation, target < 5 minutes.

**PMP fallback mode**:
```bash
./scripts/build.sh run -Dguest-arch=riscv64 -Dpmp=true
```

**Legacy CPU mode**:
```bash
./scripts/build.sh run -Dguest-arch=riscv64 -Dlegacy-cpu=true
```

### 18.3 Validation Checkpoints

For each guest type:

1. ☐ Hypervisor initializes, discovers hardware.
2. ☐ Guest architecture detected from ELF header.
3. ☐ Boot vcore enters guest code.
4. ☐ SBI BASE probed successfully.
5. ☐ Early boot messages via SBI DBCN.
6. ☐ Guest page tables initialized.
7. ☐ Timer interrupts firing (SBI SET_TIMER).
8. ☐ Secondary CPUs online (HSM HART_START).
9. ☐ "smp: Brought up 1 node, N CPUs".
10. ☐ 16550 UART detected as 16550A.
11. ☐ "Freeing unused kernel image (initmem) memory".
12. ☐ Init process starts, services launch.
13. ☐ `buildroot-guest login:` prompt appears.

For emulated guests, additional checkpoints:

14. ☐ JIT code cache warming (blocks translated and chained).
15. ☐ Tiered compilation: cold blocks interpreted, hot blocks JIT'd.
16. ☐ `fence.i` executed after each translation (I-cache coherence).
17. ☐ Block chains valid (no stale jumps after invalidation).
18. ☐ PMP sandbox tight (guest RAM + JIT buffer only).

### 18.4 Performance Benchmarks

For emulated guests, track:

- **Blocks translated per second**: Measures JIT throughput.
- **Chain hit rate**: Percentage of block transitions that use direct chaining vs. returning to dispatcher.
- **SoftTLB hit rate**: Percentage of address translations served by the set-associative cache vs. full page walk.
- **Tier distribution**: Percentage of executed blocks at each compilation tier.
- **Boot time**: Wall-clock time from `mret` to `login:` prompt.

### 18.5 GDB Debugging

```bash
./scripts/build.sh run --debug -Dguest-arch=riscv32
# In another terminal:
riscv64-unknown-elf-gdb
(gdb) target remote :1234
(gdb) break *0xc0000000
(gdb) continue
```

---

## 19. Future Architecture Support

### 19.1 AArch64 (ARM 64-bit)

Building on the riscv32 dynarec framework:

- **Decoder**: `aarch64.zig` for A64 fixed 32-bit instruction encoding.
- **Register model**: X0-X30, SP, PC, PSTATE, NZCV, system registers.
- **MMU**: Software ARMv8 4-level page table walker.
- **DTB**: AArch64-specific device tree with GICv3, PL011 UART, generic timer.
- **PSCI**: ARM Power State Coordination Interface (analogous to SBI HSM).
- **JIT**: Same block chaining + tiered compilation infrastructure. Different decoder/emitter pair.

### 19.2 x86_64

The most complex target:

- **Decoder**: Variable-length x86 instruction decoding (1-15 bytes, prefixes, ModR/M, SIB).
- **Register model**: RAX-R15, RIP, RFLAGS, segment registers, CR0-CR4.
- **MMU**: x86-64 4-level page table walker (PML4, PDPT, PD, PT).
- **Mode transitions**: Real → protected → long mode boot sequence.
- **Devices**: i8259 PIC, IOAPIC, LAPIC, i8254 PIT, PS/2 keyboard.
- **BIOS/UEFI**: Minimal firmware stub.

### 19.3 Architecture-Agnostic Abstractions

Each guest architecture implements a common interface:

```zig
const ArchBackend = union(enum) {
    riscv64: void,          // native, no emulation needed
    riscv32: Rv32Backend,
    aarch64: Aarch64Backend,
    x86_64: X86_64Backend,

    // Every backend implements:
    pub fn decode(self: *ArchBackend, bytes: []const u8) DecodedInsn { ... }
    pub fn emit(self: *ArchBackend, insn: DecodedInsn, buf: []u8) usize { ... }
    pub fn translateAddr(self: *ArchBackend, va: u64) ?u64 { ... }
    pub fn injectException(self: *ArchBackend, cause: u64, pc: u64, val: u64) void { ... }
    pub fn handleSysCall(self: *ArchBackend, regs: *Regs) SbiResult { ... }
};
```

The dynarec engine, code cache, block chainer, and tiered compilation infrastructure are architecture-independent. Only the decoder, emitter, MMU walker, and system call handler are per-architecture.

#### 10.5.5 virtio-gpu (Device ID 16) — Disaggregated Desktop Display

Provides kernel-agnostic, zero-modification display capabilities for standard desktop OS images (Ubuntu, Fedora, Debian, Arch, Windows, FreeBSD):

- **Guest Driver**: Upstream Linux DRM/KMS `virtio-gpu` driver (`CONFIG_DRM_VIRTIO_GPU=y/m`), creating standard `/dev/dri/card0` and `/dev/dri/renderD128`.
- **Virtqueues**:
  - **Virtqueue 0 (Control)**: Display control commands (`VIRTIO_GPU_CMD_GET_DISPLAY_INFO`, `RESOURCE_CREATE_2D`, `RESOURCE_UNREF`, `SET_SCANOUT`, `RESOURCE_FLUSH`, `TRANSFER_TO_HOST_2D`, `RESOURCE_ATTACH_BACKING`, `RESOURCE_DETACH_BACKING`).
  - **Virtqueue 1 (Cursor)**: Hardware cursor updates (`VIRTIO_GPU_CMD_UPDATE_CURSOR`, `MOVE_CURSOR`).
- **Disaggregated Backend Architecture**:
  - The M-mode hypervisor enforces memory safety and routes control descriptors to the sandboxed **GUI System Domain (`sys.gui`)** via zero-copy shared memory (`shmem`).
  - The GUI domain imports the guest's scanout buffer directly via `dma-buf` / `EGLImage` and composites it into a Wayland surface/window without complex graphics decoding logic inside the M-mode TCB.

#### 10.5.6 virtio-input (Device ID 18) — Input Event Virtualization

Provides kernel-agnostic keyboard, mouse, and multi-touch tablet input:

- **Guest Driver**: Upstream `virtio-input` driver (`CONFIG_VIRTIO_INPUT=y/m`).
- **Virtqueues**:
  - **Virtqueue 0 (Event)**: Guest receives Linux `evdev` input events forwarded from the GUI domain (key presses, pointer motion, touch).
  - **Virtqueue 1 (Status)**: Host receives LED/keyboard status updates.

### 10.6 MMIO Routing

All MMIO accesses are routed through the virtual device bus:

```
Guest MMIO access
    │
    ▼
Bus.read() / Bus.write()
    │
    ├─ 0x10000000..0x100000FF → vUART (16550)
    ├─ 0x10001000..0x10001FFF → virtio-console
    ├─ 0x10002000..0x10002FFF → virtio-blk
    ├─ 0x10003000..0x10003FFF → virtio-net
    ├─ 0x10004000..0x10004FFF → virtio-gpu (display)
    ├─ 0x10005000..0x10005FFF → virtio-input (keyboard/pointer)
    ├─ 0x02000000..0x0200FFFF → vCLINT
    ├─ 0x0C000000..0x0FFFFFFF → vPLIC
```

---

## 20. Implementation Phasing

### Phase 1: Native riscv64 Guest ✓ COMPLETE

- [x] M-mode hypervisor boot on multi-core RISC-V.
- [x] H-extension guest execution with G-stage paging.
- [x] PMP fallback for legacy CPUs.
- [x] SBI v2.0 (BASE, TIME, IPI, HSM, DBCN, SRST).
- [x] CFS scheduler with local queues.
- [x] Buddy allocator for physical memory.
- [x] Device tree provisioning.
- [x] Linux riscv64 boots to `login:`.

### Phase 2: Interrupt-Driven Dynarec & riscv32 Guest

- [x] RV32IMAC instruction decoder.
- [x] Basic dynarec JIT (ALU, loads/stores).
- [x] SoftTLB with Sv32 page table walk.
- [x] Virtual UART, CLINT, PLIC.
- [x] SBI call interception.
- [x] Secondary vcore boot (HSM HART_START).
- [x] MMIO cache bypass in SoftTLB.
- [x] **Interrupt-driven execution model** (hardware timer preemption & time offset sync).
- [x] **Block chaining** (direct, conditional, indirect with inline cache).
- [x] **`fence.i` after translation** (I-cache coherence).
- [x] **Self-modifying code detection** (write-protect translated pages + `sfence.vma` hook).
- [x] **Emulated vcores as first-class scheduler entities** (not sub-vcores).
- [x] **Host atomic operations** for guest AMO/LR/SC.
- [ ] Linux riscv32 boots to `login:`.

### Phase 3: Performance & Hardening

- [ ] **4-way set-associative SoftTLB** (replace direct-mapped cache).
- [ ] **Tiered compilation** (interpret → baseline JIT → optimized JIT).
- [ ] **Hot-register pinning** in optimized JIT tier.
- [ ] **Code cache management** (eviction, compaction, invalidation).
- [ ] **Tight PMP sandbox** for emulated guests (guest RAM + JIT buffer only).
- [ ] **Precise fault analysis** (replace 64-iteration trap loop counter).
- [ ] **Slab allocator** for VirtualCore, Guest, LinkedList.Node, PTE pages.
- [ ] **Work-stealing scheduler** (per-CPU queues, no global lock).

### Phase 4: Production I/O & Isolation

- [ ] **virtio-console** (replace 16550 polling with ring-buffer I/O).
- [ ] **virtio-blk** (in-memory ramdisk backend).
- [ ] **virtio-net** (inter-VM virtual switch).
- [ ] **IOMMU support** (DMA isolation for physical devices).
- [ ] **PLIC interrupt routing** to guest vPLIC with virtio interrupt delivery.
- [ ] **DROP_TRUST** SBI implementation.
- [ ] **Resource quota enforcement** and cascading.

### Phase 5: Display Virtualization & GUI Management

- [x] **virtio-gpu**: MMIO model, 2D control virtqueue, host-side compositor support via shared memory (`hypervisor/hardware/emulation/devices/vgpu.zig`).
- [x] **virtio-input**: Keyboard/mouse forwarding via event virtqueue (`hypervisor/hardware/emulation/devices/vinput.zig`).
- [x] **GUI Domain Architecture (`sys.gui`)**: Dedicated DRM/KMS compositor VM specification and Buildroot profile (`boot/riscv64-linux-guivm.config`, `boot/linux-guivm-hardware.fragment`).
- [x] **Hypervisor Management Console (`dsx gui` / `dsx dashboard`)**: Live ANSI/Wayland interactive dashboard showing VM quotas, status, disks, and commands.
- [x] **GUI Routing Integration**: Wayland/EGL guest frame rendering route via sandboxed GUI domain (`[domains.gui]` in `system.toml`).

### Phase 6: Lifecycle, Migration & Child VM Storage Handling

- [x] **Child VM Persistent Storage Management**: `dsx disk create|list|delete|resize` raw virtual disk management in `/var/lib/diosix/disks/`.
- [x] **Declarative Storage Manifest Attachment**: Support for `disk` and `storage_size` in system manifests and `dsx run --disk <name|size>`.
- [x] **Guest state serialization & Snapshots**: `dsx snapshot save|list|restore|delete` VM state checkpointing in `/var/lib/diosix/snapshots/`.
- [x] **Child VM lifecycle**: Robust lifecycle tracking and control (`dsx run`, `dsx stop`, `dsx restart`, `dsx info`).
- [ ] **Live migration**: Iterative pre-copy with dirty page tracking.
- [ ] **Fast VM cloning** via serialization snapshot templates.

### Phase 7: AArch64 Emulation

- [ ] A64 instruction decoder.
- [ ] AArch64 register model and system register emulation.
- [ ] ARMv8 page table walker (SoftTLB backend).
- [ ] PSCI (Power State Coordination Interface).
- [ ] AArch64 device tree with GIC emulation.
- [ ] Block chaining + tiered compilation (reuse engine infrastructure).
- [ ] Linux aarch64 boots to `login:`.

### Phase 8: x86_64 Emulation & Nested Virtualization

- [ ] x86-64 variable-length instruction decoder.
- [ ] x86 register model, EFLAGS, control registers.
- [ ] x86-64 4-level page table walker.
- [ ] Real → protected → long mode transitions.
- [ ] Legacy PC device emulation.
- [ ] BIOS/UEFI stub.
- [ ] Linux x86_64 boots to `login:`.
- [ ] **Nested virtualization**: H-extension CSR trapping and shadow G-stage table composition.
- [ ] Extensible CSR dispatch table for future CSR emulation.

### Phase 9: Optimization & Verification

- [ ] **JIT peephole optimizations** (redundant load elimination, constant folding).
- [ ] **Trace-based compilation** (compile across basic block boundaries for hot paths).
- [ ] **Hardware performance counter virtualization**.
- [ ] **Fuzz testing** of instruction decoders (all architectures).
- [ ] **Security audit** of PMP, G-stage, IOMMU configurations.
- [ ] **Formal verification** of critical isolation invariants.

---

*This document is the authoritative reference for all development on the diosix hypervisor. It should be followed by human engineers and AI agents alike.*
