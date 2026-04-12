# Diosix shared interface

The Diosix hypervisor provides a shared interface for constants and 
definitions that are common to both the hypervisor and guest operating 
systems. This "source of truth" ensures compatibility for binary interfaces 
like the Supervisor Binary Interface (SBI) and Executable and Linkable 
Format (ELF) loading.

The interface is located in the `hypervisor/interface/` directory and is 
structured as a Zig module named `interface`.

## RISC-V architecture

The hypervisor defines low-level RISC-V constants to replace magic 
numbers in context switching and SBI handling. These include a named register 
enum for general-purpose registers (`a0`-`a7`, `ra`, `sp`, etc.), standard 
privilege levels (`user`, `supervisor`, `machine`), and bitmasks for 
Machine Instruction Set Architecture (MISA) register extensions. We also 
standardize exception and interrupt codes relevant to the hypervisor and its 
guests.

## Supervisor Binary Interface

Diosix follows the 
[RISC-V SBI specification](https://github.com/riscv-non-isa/riscv-sbi-doc/releases/download/v3.0/riscv-sbi.pdf) 
to standardize communication between guests and the hypervisor. Diosix is 
officially assigned **Implementation ID 5**.

We support standard SBI extensions such as `BASE`, `TIMER`, `SRST` 
(System Reset), and `DBCN` (Debug Console). Additionally, we provide the Diosix 
extension 
(EID `0x0A000005`) for custom features. This extension includes `YIELD` to 
surrender the current Virtual CPU (VCPU), `FORK` to clone the current 
Virtual Machine (VM), `DROP_TRUST` to permanently relinquish hardware access, 
and `EXIT` to terminate the VM and its entire descendant subtree.

## ELF specifications

The manual ELF loader uses standardized definitions for parsing guest images. 
These include magic values, header offsets for the Executable and Linkable 
Format header (EHDR) and Program Header (PHDR) structures, and machine 
identifiers for 64-bit RISC-V systems.

## Usage in the hypervisor

Within the hypervisor core, the interface is imported as a named module to 
ensure consistency across the codebase:

```zig
const interface = @import("interface");
const riscv = interface.riscv;
const sbi = interface.sbi;
```

## Usage in the guest OS

Guest Kernels or drivers should include these definitions or port them 
to their own build systems. Using the shared interface ensures that guests 
use the correct SBI extension IDs and register mappings to interact with 
the Diosix hypervisor smoothly.
