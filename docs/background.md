# Diosix technical background

This guide provides an overview of the design philosophy and technical 
architecture of the Diosix hypervisor. Diosix is a bare-metal, multi-core 
hypervisor written in the Zig programming language, specifically for the 
64-bit RISC-V computing platform.

## Design philosophy

Diosix is built around three core principles that ensure it remains a 
lightweight and reliable system. We minimize the Trusted Computing Base 
(TCB) through hardware-enforced isolation, restricted communication paths, 
and explicit control over memory and errors in Zig. By implementing a 
recursive Virtual Machine (VM) management model (hierarchical governance), 
we eliminate the need for a complex, global hypervisor state and enable 
scalable guest orchestration.

## Technical documentation

To learn more about the internals of the hypervisor, explore our detailed 
technical guides:

- **[Hypervisor architecture](architecture.md)**: Describes the 
  hierarchical forking model, resource quotas, and guest VM lifecycles.
- **[Security model](security.md)**: Details the TCB, hardware isolation 
  mechanisms, and the "least privilege" workflow.
- **[Interface and ABI](interface.md)**: Documents the standardized 
  Supervisor Binary Interface (SBI) extensions, Context ID (CID) capability 
  model, data structures, and kernel driver interface.
- **[Command-line interface](cli.md)**: Provides a user guide and reference 
  for the `diosix-ctl` guest VM management utility.

---
*For contributors, refer to the [Diosix style guide](style-guide.md) 
before writing new documentation or code.*

