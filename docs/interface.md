# Diosix Shared Interface

The Diosix hypervisor provides a shared interface for constants and definitions that are common to both the hypervisor and guest operating systems. This "source of truth" ensures compatibility for binary interfaces like SBI and ELF loading.

The interface is located in the `hypervisor/interface/` directory and is structured as a Zig module named `interface`.

## 1. RISC-V Architecture (`riscv.zig`)

Contains low-level RISC-V definitions:
- **Register Enum**: Named general-purpose registers (`a0`, `ra`, `sp`, etc.) to replace magic numbers in context switching and SBI handling.
- **Privilege Modes**: Standard RISC-V privilege levels (`user`, `supervisor`, `machine`).
- **ISA Extensions**: Bitmasks for MISA register extensions (e.g., `gc`, `h`).
- **Exception Causes**: Standard and guest-specific exception and interrupt codes.

## 2. Supervisor Binary Interface (`sbi.zig`)

Standardizes all communication between guests and the hypervisor:
- **SBI Spec Version**: Currently implements v0.2.
- **Implementation ID**: Diosix is officially assigned **Implementation ID 5**.
- **Standard Extensions**: Support for `BASE`, `TIMER`, and `SRST` (System Reset).
- **Diosix Extension (EID 0x0A000005)**: Custom extensions for hypervisor-specific features:
    - `YIELD`: Yield the current VCPU.
    - `FORK`: Fork the current guest (trusted guests only).
    - `DROP_TRUST`: Relinquish hardware access privileges.
    - `EXIT`: Terminate the guest and its descendants.

## 3. ELF Specifications (`elf.zig`)

Definitions for the manual ELF loader:
- **Magic Value**: `\x7fELF`.
- **Header Offsets**: Standardized offsets for `EHDR` and `PHDR` structures.
- **Machine IDs**: Correct identification for 64-bit RISC-V (`0xF3`).

## Usage in Hypervisor

Within the hypervisor core, the interface is imported as a named module:

```zig
const interface = @import("interface");
const riscv = interface.riscv;
const sbi = interface.sbi;
```

## Usage in Guest OS

Guest kernels or drivers should include these files or port the definitions to their own build systems to ensure they use the correct SBI extension IDs and register mappings for Diosix.
