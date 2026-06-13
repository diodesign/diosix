# Diosix architecture

Diosix is a bare-metal hypervisor that manages Virtual Machines (VMs) using a
hierarchical model. Rather than managing guests in a flat list, the hypervisor
organizes them into a tree-like lineage.

---

## Hierarchical forking model

The first VM loaded by the hypervisor at boot is known as the Root VM. This VM
acts as the progenitor for all other guests, similar to how the `init` process
functions in Unix-like operating systems.

Any guest VM, starting with the Root VM, can fork itself or manage its direct
children, including starting, stopping, killing, or rebooting them. A parent VM is
entirely responsible for the lifecycle and resources of its descendants. This
recursive structure delegates resource management to the parent VMs rather than
maintaining a global state in the hypervisor.

---

## Root VM image generation

Diosix cross-compiles the Root VM guest environment from source using
Buildroot. This process builds a native RISC-V Linux kernel, a BusyBox-based
userspace, and early initialization scripts entirely from source, ensuring
that all privileged guest code is built from origin.

The generated kernel image is embedded directly into the hypervisor executable
payload as an Executable and Linkable Format (ELF) segment. At runtime, the
hypervisor unpacks and boots this payload as the Root VM.

---

## Multi-architecture emulation layer

To allow running non-native guest VMs alongside native 64-bit RISC-V workloads,
Diosix integrates a transparent, cross-architecture virtual CPU core emulation layer.

### Generic virtual core interface

To support multiple execution paths, the hypervisor relies on a generic virtual
CPU core interface (`vcore.VirtualCore`) that acts as an architecture-independent
abstraction layer. This tagged-union struct isolates whether the core is a
physical host core running a native guest, or a software-emulated core running
a cross-architecture binary. When the scheduler selects a core to run, the
physical core context wrapper performs the appropriate privilege transitions.

### Supported guest architectures

The hypervisor inspects the ELF machine headers of a guest VM's binary to identify
its target instruction set architecture:

*   64-bit RISC-V (`riscv64`) guest VMs run directly on the host physical CPU at
    native speeds using the host processor's hardware virtualization extension or
    the Physical Memory Protection (PMP) fallback mode.
*   32-bit RISC-V, 64-bit Arm, and 64-bit x86 (`riscv32`, `aarch64`, `x86_64`)
    guest VMs run transparently using software just-in-time (JIT) emulation.

### Unicorn Engine integration

The emulation layer is powered by [Unicorn Engine](https://github.com/unicorn-engine/unicorn), a lightweight multi-platform, multi-architecture CPU emulator framework based on QEMU.

Unicorn is compiled as a static library and linked directly into the hypervisor binary image. Since Unicorn is licensed under the GPL, the presence of Unicorn in a compiled Diosix binary means outbound binary distributions are [subject to the GPL](../LICENSE.md), whereas the standalone Diosix hypervisor source code remains under its permissive MIT license.

To prevent bugs or exploits in the emulator from compromising the hypervisor, the entire JIT emulation layer runs in RISC-V supervisor mode (S-mode) as opposed to the hypervisor's machine mode (M-mode).

The following sub-sections apply only to emulated guest VMs.

#### Supervisor-mode sandboxing

The emulator executes inside an S-mode wrapper function (`emulatedRunnerSMode`) with paging disabled (`satp = 0`). To prevent unauthorized access to the hypervisor and hardware devices, the hypervisor's M-mode scheduler dynamically configures RISC-V PMP entries on context switch:

*   Read/Execute (RX) access is granted only to the hypervisor's code and read-only data sections (`__hypervisor_start` to `__bss_start`) to run the Unicorn library and helpers.
*   Read/Write (RW) access is granted to the hypervisor's global data and BSS segments (`__bss_start` to `__hypervisor_end`).
*   Read/Write (RW) access is granted to the current physical core's private memory slab (including its stack and per-core heap) to service JIT allocations.
*   Read/Write (RW) access is granted to the guest's pre-allocated physical RAM region.

All other host memory (including private M-mode exception stacks, other cores' heap/stack slabs, and memory-mapped I/O blocks like CLINT or PLIC) is completely denied.

#### Memory management

The guest VM's allocated host physical memory is mapped directly into Unicorn's virtual address space contiguously via `uc_mem_map_ptr`. Accesses to unmapped memory locations (for example, peripheral registers or the UART console at `0x10000000`) are intercepted via a Unicorn memory exception hook (`UC_HOOK_MEM_UNMAPPED`). Reads and writes are emulated by the hypervisor; for example, guest console output is redirected to the hypervisor console via `putcharFromGuest`.

#### Dynamic allocator wrapper

Unicorn relies on standard C library allocation routines (`malloc`, `calloc`, `realloc`, and `free`). Since Diosix runs on bare metal without a standard C library, it implements these symbols using a thread-safe, spinlock-protected wrapper around the hypervisor's per-hart bare-metal `HeapAllocator`. 

To locate the per-hart allocator from S-mode (where the machine-only `mscratch` CSR is inaccessible), the scheduler maps the CPU's context pointer into the S-mode runner's thread pointer (`tp`) register on context switch. The stubs read `tp` directly to access their core's heap.

#### Interrupt handling and preemption

Emulation runs inside Unicorn's execution loop (`uc_emu_start`). To prevent a guest VM from hogging a physical core, the hypervisor handles preemption:

*   Host timer interrupts trap to the machine-mode interrupt handler (`xint_handler`).
*   If an interrupt fires while an emulated virtual core is running, the handler invokes `stop()` (which calls `uc_emu_stop()`) to immediately exit the Unicorn JIT loop.
*   The CPU resumes the S-mode runner, which exits the JIT loop and executes an environment call (`ECALL`).
*   The `ECALL` traps back to the hypervisor's M-mode handler, which yields the core, allowing other virtual cores to run.

#### System call interception

System calls made by a guest kernel to the hypervisor are caught via a Unicorn interrupt hook.

The hypervisor reads the guest's CPU registers, maps them into a mock supervisor context, executes the request via the native Supervisor Binary Interface (SBI) handler, writes the return values back to the guest's virtual registers, and advances the instruction pointer to resume execution.

### Native-vs-emulated guests

The differences between native and emulated execution paths in Diosix are summarized in the following table:

| Feature                      | Native guest (`riscv64`)                                                                                           | Emulated guest (`riscv32`, `aarch64`, `x86_64`)                                                        |
| :-----------------------------| :-------------------------------------------------------------------------------------------------------------------| :-------------------------------------------------------------------------------------------------------|
| CPU execution mode           | Runs directly on the host physical CPU at full hardware speed.                                                     | Runs in software via JIT binary translation using Unicorn.                                             |
| CPU execution privilege      | Runs in Virtual Supervisor (VS) and Virtual User (VU) modes (or host S/U modes under PMP fallback).                | Runs JIT translator in host S-mode. Guest code executes as virtual instructions in JIT space.          |
| Host virtualization hardware | Requires and utilizes the RISC-V H extension (or PMP fallback) for isolated guest execution.                       | Does not utilize host hardware virtualization features; isolated via host S-mode and PMP sandboxing.   |
| Memory allocation            | Dynamic and on-demand using G-stage page tables and Copy-on-Write (CoW) support (contiguous only in PMP fallback). | Pre-allocated as a single contiguous block, mapped statically in full via `uc_mem_map_ptr` at VM boot. |
| Context switching            | Handled via assembly register swap routines during M-mode entry/exit traps.                                        | Handled via standard scheduler context switch and supervisor environment call (`ECALL`) yield loops.   |
| System call interception     | Traps directly from guest VS-mode (or S-mode under PMP fallback) to hypervisor M-mode via `ECALL`.                 | Trapped via Unicorn software interrupt hooks, which copy registers into a mock thread context.         |

---

## Resource quotas

Diosix uses a subtree resource quota system to prevent resource exhaustion. A
VM's quota defines the maximum resources that the VM and its entire descendant
tree can consume.

The hypervisor tracks quotas for physical memory pages, virtual CPU cores,
scheduling priority, maximum child depth, and the total number of descendants
within any branch of the hierarchy.

The Root VM begins with the maximum available system resources. Any guest can
voluntarily decrease its own quota — a one-way operation — to sandbox itself
and its future descendants.

---

## Communication and lineage isolation

VMs are isolated and can only communicate with their immediate parent and
direct children. Guests that do not share a direct parent-child relationship
cannot interact or detect each other.

---

## Hardware trust

Diosix distinguishes between the management of children and the control of
physical hardware. Only a VM that has its hardware trust flag set can map
physical Memory-Mapped Input/Output (MMIO) space or route hardware interrupts
directly to itself.

By default, the Root VM has hardware trust. This is so that hardware drivers can be provided by the Root VM for the rest of the system, rather than the hypervisor itself. When a guest VM needs access to the underlying host, such as accessing storage or network resources, it must coordinate with the Root VM for that access.

A guest can relinquish this privilege using the `DROP_TRUST` call in the Supervisor Binary Interface (SBI) extension. This allows a trusted loader to fork a guest, write
the guest image, and drop trust before executing the guest code.

As such, the Root VM can fork to create a trusted child VM, which then loads in a guest image from storage, drops its trusted staus, and then acts as a normal, untrusted guest VM managed by its Root VM parent.

For more information, see [Diosix shared interface](interface.md).

---

## Termination and restart policy

When a VM terminates or crashes, the hypervisor recursively terminates all of
its descendants. Orphans are not permitted.

If the Root VM terminates, the hypervisor restarts the host machine to ensure
the system returns to a clean boot state.

The Root VM can also signal to the hypervisor to shutdown the host system.

---

## Memory address space terminology

Diosix uses distinct address space definitions across the codebase, debugging
logs, and documentation:

*  **Host physical address (HPA).** A physical memory address on the host hardware,
   such as physical DRAM, and memory-mapped peripheral registers (e.g., Core Local
   Interruptor (CLINT), Platform-Level Interrupt Controller (PLIC), or Universal
   Asynchronous Receiver-Transmitter (UART)).
*  **Guest physical address (GPA).** A physical memory address as perceived by a
   guest VM. In Hypervisor paging mode, GPAs are translated to HPAs via
   second-stage G-stage page tables (`sv39x4`). Under Physical Memory Protection
   (PMP) fallback mode, GPAs are mapped contiguously to HPAs via bounds-checked
   identity offset translation.
*  **Guest virtual address (GVA).** A virtual memory address managed within the
   guest VM's own operating system supervisor context, via first-stage VS-stage
   translation.
