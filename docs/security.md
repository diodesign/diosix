# Diosix security model

The Diosix architecture prioritizes a minimal Trusted Computing Base (TCB) 
and enforces robust guest isolation through hierarchical management and 
hardware-level protections.

## Trusted computing base

The hypervisor and its progenitor **Root VM** (Unix init-equivalent) form
the core of the TCB. The hypervisor enforces memory separation and resource
quotas, while the Root VM manages the host's initial hardware and
orchestration.

## Hardware-enforced isolation

Diosix uses machine-level features of the [RISC-V architecture](https://riscv.github.io/riscv-isa-manual/snapshot/spec/) 
to enforce guest sandboxing. G-stage paging virtualizes physical memory, 
ensuring guests cannot access the hypervisor or other guests' memory spaces. 
On systems without hardware virtualization support (H-extension present),
Diosix uses RISC-V's Physical Memory Protection (PMP) as a fallback to
strictly bound guest access.

Any physical Memory-Mapped I/O (MMIO) mapping (e.g., for device drivers) or 
direct hardware interrupt routing requires the hardware trust flag. This 
privilege is only granted to the Root VM and its specifically designated 
descendants, preventing unauthorized guests from interacting with host 
hardware.

## Lineage isolation

Diosix enforces lineage isolation at the messaging layer. A guest Virtual 
Machine (VM) can only communicate with its immediate parent or its children. 
VMs that are not on the same branch of the hierarchical tree are completely 
invisible to each other, preventing cross-guest interference.

## Least privilege cycle

Parent VMs can manage their children’s lifecycle (starting, stopping, killing, 
or rebooting) regardless of their hardware trust status. This design enables 
a security-hardened workflow for deploying new guests:

1. A trusted Virtual Machine (such as the Root VM) creates a child VM with 
   specified resource quotas.
2. The child VM is instantiated from an isolated guest image loaded from storage 
   without physical host hardware access.
3. If hardware access is needed (e.g. for a dedicated hardware driver VM), 
   trust can be granted at startup; otherwise, guests run strictly untrusted.
4. A guest VM can irrevocably trigger the `DROP_TRUST` Supervisor Binary Interface (SBI) 
   function at any time to relinquish its hardware access.

## Reporting security issues <a name="reporting-security-issues"></a>

The project takes security bugs seriously. To privately and responsibly
report a security vulnerability, email 
[security@diosix.org](mailto:security@diosix.org) with further details.
We will investigate and respond to all reports promptly.