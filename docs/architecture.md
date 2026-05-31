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
Buildroot. This process builds the RISC-V Linux kernel, a BusyBox-based
userspace, and early initialization scripts entirely from source, ensuring
that all privileged guest code is built from origin.

The generated kernel image is embedded directly into the hypervisor executable
payload as an Executable and Linkable Format (ELF) segment. At runtime, the
hypervisor unpacks and boots this payload as the Root VM.

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

*  **Host Physical Address (HPA).** A physical memory address on the host hardware,
   such as physical DRAM, and memory-mapped peripheral registers (e.g., Core Local
   Interruptor (CLINT), Platform-Level Interrupt Controller (PLIC), or Universal
   Asynchronous Receiver-Transmitter (UART)).
*  **Guest Physical Address (GPA).** A physical memory address as perceived by a
   guest VM. In Hypervisor paging mode, GPAs are translated to HPAs via
   second-stage G-stage page tables (`sv39x4`). Under Physical Memory Protection
   (PMP) fallback mode, GPAs are mapped contiguously to HPAs via bounds-checked
   identity offset translation.
*  **Guest Virtual Address (GVA).** A virtual memory address managed within the
   guest VM's own operating system supervisor context, via first-stage VS-stage
   translation.
