# Diosix style guide

This guide defines the standards for contributing to the Diosix project,
ensuring consistency across both documentation and the codebase. All
contributors must follow these guidelines to maintain the project's high
standard of quality.

## Technical documentation style

Diosix documentation is written for two distinct audiences:

*   **Users (beginners and experts)**: Operators booting Diosix, exploring the
    guided tour, launching Virtual Machines (VMs) with `dsx`, or configuring
    declarative system and charter manifests.
*   **Developers and maintainers**: Engineers building, testing, debugging, and
    maintaining the Machine-mode (M-mode) hypervisor, Supervisor-mode (S-mode)
    emulation layer, and User-mode (U-mode) system utilities.

All documentation must prioritize clarity, precision, and professional prose,
remaining comprehensive while as concise as possible.

### Voice and tone

Write all documentation and code comments in American English with verified
spelling and clear, correct grammar. Maintain a professional and direct tone
that avoids marketing hype, jargon, and unnecessary waffle. Every sentence
should provide tangible value to the reader without losing clarity through
over-compression. Use the active voice and present tense whenever possible,
such as "The hypervisor handles the request" rather than "The request is
being handled." Strive for conciseness and be as detailed as necessary to
explain complex designs.

### Abbreviations and terminology

Spell out every abbreviation on its first use within a given page, followed
by the abbreviation in brackets. For example, use "Virtual Machine (VM)" or
"Supervisor Binary Interface (SBI)" for the first mention. For all
subsequent mentions on that same page, use only the abbreviation.

Industry-wide terms, such as YAML, CPU, and RAM, do not need to be
spelled out. Familiar names of software and other products, such as QEMU,
do not need to be spelled out.

To avoid confusion between the compilation environment, the virtualization
environment, and physical hardware, adhere to the following terminology
definitions:

*   **Host build machine** (or **build machine**): The physical computer
    or development system where the source code is compiled and the
    executable binaries (the hypervisor and guest payloads) are built.
*   **Host hardware** (or **host system**): The physical machine, board,
    or System-on-Chip (SoC) that runs the compiled hypervisor.
*   **Target platform** (or **target system**): The board, CPU architecture
    configuration, or emulator machine designed to execute the compiled
    hypervisor.
*   **Guest VM**: A virtual machine running on the hypervisor.
*   **Host Physical Address (HPA)**: A physical memory address of the
    host hardware.
*   **Guest Physical Address (GPA)**: A physical memory address from
    the guest VM's perspective.

For more information on HPA and GPA, see [Diosix architecture](architecture.md).

### Structure and formatting

Use bulleted lists only for non-sequential items and numbered lists strictly
for multi-step procedures. Use sentence case for all headings. To maintain
readability in terminal-based environments, wrap all prose and code at a
maximum of 80 characters per line.

## Coding style

Diosix follows idiomatic Zig 0.17 conventions to ensure the codebase remains
safe, secure, accessible, and maintainable.

### File organization and naming conventions

Keep source files focused on a single responsibility and under 500 lines
unless there is a compelling architectural reason. When decomposing a file
that exceeds 500 lines, place its submodules in a dedicated subdirectory
(for example, `vm/run.zig`, `panes/modal.zig`, or `tests/gui.zig`) rather than
creating flat `prefix_subname.zig` files in the parent directory. Never
truncate functionality or unit tests when splitting files, and reference each
submodule in the parent file's `test` block (`_ = @import("vm/run.zig");`) so
`zig build test` executes all co-located unit tests. Wrap all lines of code
and comments at 80 characters or fewer.

All source files must use concise `snake_case` filenames without redundant
project, directory, or sibling prefixes. For example, name the Application
Programming Interface (API) module inside a Diosix tool `api.zig` rather than
`diosix_api.zig`, and name a VM submodule inside `vm/` `info.zig` rather than
`vm_info.zig`. Never duplicate shared primitives (such as `Spinlock`,
page-alignment math, or path validators) across files; import them from
`hypervisor/interface/`, `hypervisor/core/atomic.zig`, or `common.zig`.

For functions and methods, use `camelCase`. Types, structs, unions, and enums
must use `PascalCase`. Local variables and struct fields must use `snake_case`,
and constants should use `SCREAMING_SNAKE_CASE` or `snake_case` depending on
their scope. Append units and qualifiers in descending order of significance
(for example, `ram_bytes_max` or `timeout_ms`).

### Comments and documentation

All comments must follow standard sentence structure, beginning with a
capital letter and ending with a period. The code should be largely
self-documenting; use comments to explain the "why" behind a design
decision rather than the "what," unless the logic is particularly
intricate. Maintain a professional tone and avoid technical jargon where
a simpler explanation suffices.

### Idiomatic Zig usage and memory safety

Use Zig's type system and comptime features rather than repetitive control
flow. Parse commands, CLI flags, and configuration keys into type-safe `enum`
values using `std.meta.stringToEnum` and dispatch with `switch` rather than
chaining `if` and `else if` string comparisons. Write all hexadecimal literals
in lowercase (`0xfff`, `0x8000_0000`, `0xffff_ffff`, never `0xFFF` or
`0xFFFFFFFF`). Avoid magic numbers and unnamed bitmasks in expressions: if a
literal requires an inline comment to explain its meaning (such as
`return 15; // Store page fault.`) or pre-computes a derived mask (such as
`(vaddr & 0xfff) > 0xffc` or `(pte & 0xe) == 0`), replace it with a named
constant, `enum` tag, or self-documenting inline helper (`PAGE_OFFSET_MASK`,
`crossesPageBoundary(vaddr, @sizeOf(u32))`, `PTE.isPointer(pte)`). Use explicit
fixed-width integer types (`u64`, `u32`, `u16`, `u8`) in Application Binary
Interface (ABI) structs (`extern struct`, `packed struct`) and 64-bit guest
register state rather than `usize`, and explicitly annotate local variables
initialized from `@min` or `@max` with a comptime literal
(`const row_w: usize = @min(width, 1280);`).

Separate mechanism from policy: implement behavior in code and store tunable
parameters in configuration files under `/etc/diosix/` with appropriate
least-privilege file permissions. Avoid accumulating multi-path fallback arrays
for internal files or symbols that ship together in the repository; update all
in-tree producers, consumers, and tests atomically to reference a single
canonical path.

Be explicit about memory management and allocations. During early M-mode boot
before a heap allocator is initialized, static pre-allocated buffers are
appropriate for safety. As soon as an allocator is available — whether the
per-core heap allocator in M-mode or dynamic allocators in U-mode utilities —
allocate and grow buffers dynamically rather than guessing fixed stack buffer
sizes. Consistently pair allocations with `defer` and `errdefer` to guarantee
resource cleanup on all control-flow paths, and never discard error return
values. All code must be formatted using `zig fmt` before it is submitted for
review.
