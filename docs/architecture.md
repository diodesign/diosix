# Diosix architecture

Diosix is a lightweight, secure-by-design hypervisor that uses a hierarchical 
management model for Virtual Machines (VMs). Unlike traditional hypervisors 
that use a flat structure for guest management, Diosix organizes VMs into 
a tree-like lineage.

## Hierarchical forking model

The first VM loaded by the hypervisor at boot is known as the **Root VM**. This 
VM acts as the progenitor for all other guests, similar to how the `init` 
process (PID 1) functions in a Unix-like operating system.

Any VM can fork itself or manage its direct children, including starting, 
stopping, killing, or rebooting them. A parent VM is entirely responsible 
for the lifecycle and resources of its descendants. This recursive management 
strategy eliminates the need for a complex, global hypervisor state.

## Root VM image generation

The hypervisor includes a pre-packaged implementation of a 
[BuildRoot](https://buildroot.org/) environment. When compiling the project 
from source, the build system automatically cross-compiles a complete 
RISC-V Linux kernel, a busybox-based userspace, and necessary scripting 
environments for the initial Root VM. This ensures an absolute guarantee of 
provenance by building all privileged guest code entirely from source.

The generated kernel image is embedded directly into the hypervisor 
executable payload as an Executable and Linkable Format (ELF) segment. 
At runtime, the hypervisor unpacks and boots this payload as the Root VM.

## Resource quotas

Diosix implements a subtree resource quota system to prevent 
Denial of Service (DoS) scenarios and ensure fair resource distribution across the 
system. A VM's quota defines the absolute maximum resources that it and its 
entire descendant tree can consume.


The hypervisor tracks several quotas to maintain system balance. Physical RAM 
is measured by the total number of physical memory pages allocated for guest 
RAM and page tables. Virtual CPU core (VCPU core) limits define the maximum 
number of VCPU cores allowed within a VM's specific subtree, while scheduling 
priority limits define the maximum priority any VCPU in that subtree can 
possess. Finally, Diosix enforces limits on the maximum child depth and the 
total number of descendants allowed within any branch of the hierarchy.

The Root VM begins with the maximum available system resources. Any guest 
can voluntarily decrease its own quota—a one-way operation—to sandbox 
itself and its future descendants.

## Communication and lineage isolation

Isolation is a fundamental pillar of the Diosix architecture. VMs 
are strictly limited to communicating with their immediate parent and their 
direct children. VMs that do not share a direct parent-child relationship are 
completely isolated from one another and cannot interact or detect each 
other's existence.

## Hardware trust

Diosix distinguishes between the management of children and the control of 
physical hardware. Only a VM that has its hardware trust flag set can map 
physical Memory-Mapped I/O (MMIO) space or route hardware interrupts directly 
to itself.

By default, the Root VM is initialized with hardware trust. A guest can 
permanently relinquish this privilege using the `DROP_TRUST` function provided 
by the [Diosix Supervisor Binary Interface (SBI) extension](interface.md).
This mechanism enables a "least privilege" workflow: a trusted loader forks a 
child VM, which inherits its trust. The child then populates its own memory 
with a guest image from storage before dropping its own trust and transitioning 
into a standard isolated guest.

## Termination and restart policy

The hypervisor enforces a cascading termination policy. If a VM 
terminates—either through the `EXIT` call defined in the 
[RISC-V SBI specification](https://github.com/riscv-non-isa/riscv-sbi-doc/releases/download/v3.0/riscv-sbi.pdf) 
or a fatal crash—the hypervisor recursively terminates all of its children and 
descendants. Orphans are not permitted.

If the top-level Root VM terminates or crashes, Diosix considers the system 
state to be finalized and initiates a restart of the physical host machine. 
This ensures the system remains in a known, stable state.

## Memory address space terminology

Diosix explicitly categorizes address spaces to guarantee absolute clarity and maintain separation of concerns throughout the codebase, debug outputs, and documentation:

*  **Host Physical Address (HPA)**. A physical memory address on the actual host hardware, such as physical DRAM, and memory-mapped peripheral registers (e.g., CLINT, PLIC, or UART).

*  **Guest Physical Address (GPA)**. A physical memory address as perceived by a guest virtual machine. In Hypervisor paging mode, GPAs are translated to HPAs via second-stage G-stage page tables (`sv39x4`). Under PMP fallback mode, GPAs are mapped contiguously to HPAs via bounds-checked identity offset translation.

*  **Guest Virtual Address (GVA)**. A virtual memory address managed within the guest virtual machine's own operating system supervisor context, via first-stage VS-stage translation.

These concepts are consistently referenced via their abbreviations (**HPA**, **GPA**, and **GVA**) across the hypervisor's source code and diagnostics.
