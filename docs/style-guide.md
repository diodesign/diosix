# Diosix style guide

This guide sets the writing and coding standards for the Diosix repository so
documentation and source code stay clear, accurate, and easy to read.

## Technical documentation style

Diosix documentation is split into two tracks for two distinct audiences:

* User guides serve beginners and operators booting Diosix, exploring the
  guided tour, running virtual machines (VMs), and configuring system or
  charter policies. They focus on low-friction workflows, explaining both how
  to use a feature and why it works that way.
* Technical references serve developers and maintainers building, testing,
  debugging, and extending the machine-mode (M-mode) hypervisor,
  supervisor-mode (S-mode) emulation layer, and user-mode (U-mode) tools. They
  focus on internal mechanics, invariants, and design decisions.

### Voice, tone, and plain English

Write documentation and code comments in American English with sound grammar
and verified spelling. Keep the tone neutral yet casually friendly: write
directly to the reader, avoid stiff bureaucracy or marketing hype, and do not
over-promise or make grandiose claims. At the same time, do not downplay what
Diosix does—describe supported capabilities plainly and matter-of-factly.

Prefer plain English over academic or systems jargon in introductions,
overviews, and user guides. For example, telling a new reader that Diosix has a
"small trusted computing base" means nothing unless they already speak formal
security jargon; say instead that device drivers, filesystems, and network
stacks run outside the highest CPU privilege level so a driver bug cannot
compromise the whole machine. Reserve specialist terms such as trusted
computing base (TCB) for deep architectural sections where they are explained
in context.

Use the active voice and present tense whenever natural (for example, "The
hypervisor validates the request" rather than "The request will be validated
by the hypervisor"). Keep sentences concise and direct without compressing them
to the point where technical meaning becomes ambiguous.

### Inline code and technical references

Format text as inline code only when you expect or require the reader to type
it in—such as a command, CLI flag, file path, or configuration key inside a
procedural step or reference entry—or when defining literal application binary
interface (ABI) symbols in a dedicated technical reference.

Do not scatter inline code, daemon flags, source filenames, internal symbol
names, numeric quantities, or acronyms across introductions, high-level
overviews, headings, or conceptual explanations. When explaining concepts or
summarizing features, describe how the system behaves in plain English rather
than interrupting sentences with parenthetical command syntax or code objects
the reader is not about to run.

Avoid writing prose like this in overviews:

```markdown
* **Key-only SSH and default network isolation**: SSH password logins are
  disabled (`dropbear -s -g`) in favor of enrolled keys (`dsx auth`).
```

Write direct, plain sentences instead:

```markdown
* SSH password logins are disabled in favor of enrolled public keys, and new
  child VMs start isolated from sibling VMs and the outside internet until you
  grant access.
```

### Lists, headings, and line wrapping

Formatting should clarify structure rather than pad weak prose:

* Write bulleted list items as concise, complete sentences that go straight to
  the point. Do not start bullet items with bolded lead-in labels followed by a
  colon and a paragraph of explanation. Use Markdown tables when pairing short
  names or commands with descriptions, and reserve leading identifiers in lists
  strictly for CLI option or ABI field reference entries.
* Use numbered lists (`1.`, `2.`) only for sequential, step-by-step procedures
  or ordered lifecycle stages. Use bulleted lists (`*`) for unordered points.
* Use sentence case across headings, prose, and table cells, capitalizing only
  the first word and genuine proper nouns or acronyms (such as Diosix, RISC-V,
  Linux, Zig, or QEMU). Do not turn project concepts or roles—such as root VM,
  steward VM, standby root VM, charter, or guided tour—into mid-sentence proper
  nouns, and keep headings in plain English rather than appending parenthetical
  filenames or command flags.
* Wrap prose, list items, and code blocks at 80 characters or fewer per line
  (excluding Markdown table rows and long URLs) so files read cleanly in
  terminal splits and diffs.

### Abbreviations and canonical terminology

Spell out every non-universal abbreviation on its first use within a page,
followed by the abbreviation in parentheses. Keep the spelled-out words in
normal lowercase rather than capitalizing each word to match the acronym: write
"virtual machine (VM)" and "supervisor binary interface (SBI)," never "Virtual
Machine (VM)" or "Supervisor Binary Interface (SBI)." On all later mentions on
that same page, use only the abbreviation.

Universal computing terms—such as CPU, RAM, ROM, DRAM, OS, GUI, CLI, API, SSH,
ELF, ISO, SHA-256, USB, NVMe, SATA, FAT32, JSON, TOML, YAML, QEMU, GPT, UEFI,
BIOS, QR, and AI—do not need to be spelled out and should be written as plain
text rather than inline code.

Use these canonical terms consistently so build environments, physical
hardware, and guests are never conflated:

| Term | Meaning |
| :--- | :--- |
| Host build machine (or build machine) | The computer where source code is compiled and hypervisor or guest images are built. |
| Host hardware (or host system) | The physical machine, board, or system-on-chip (SoC) running the compiled hypervisor. |
| Target platform (or target system) | The board, CPU architecture, or emulator targeted by the build. |
| Guest VM | Any virtual machine running on the hypervisor. |
| Root VM | The initial VM booted by the hypervisor at startup with inherited hardware trust and system quotas (structurally identical to child VMs; written lowercase as "root VM" mid-sentence). |
| Host physical address (HPA) | A physical memory or device address on the host hardware. |
| Guest physical address (GPA) | A physical memory address from a guest VM's perspective. |
| Guest virtual address (GVA) | A virtual address translated by a guest OS kernel's page tables. |

For details on address translation, see
[Hypervisor architecture](architecture.md).

---

## Coding style

Diosix follows idiomatic Zig 0.17 conventions to keep the codebase safe,
readable, and maintainable.

### File organization and naming conventions

Keep source files focused on a single responsibility and at 500 lines or fewer
unless there is a clear architectural reason. When splitting a file that grows
past 500 lines, place its submodules in a cohesive subdirectory rather than
creating flat prefix-underscore files in the parent directory. Never drop live
features or unit tests when splitting files, and import each submodule in the
parent's test block so the test runner executes every co-located unit test.
Wrap all code and comments at 80 characters or fewer.

Use concise snake-case filenames without redundant project or directory
prefixes (for example, name an API module inside a tool `api.zig` rather than
`diosix_api.zig`). Share common primitives such as spinlocks, alignment
helpers, and path validators from shared modules instead of duplicating them
across files.

Follow standard Zig identifier casing: camelCase for functions and methods,
PascalCase for types, structs, unions, and enums, snake-case for variables and
fields, and screaming snake-case for module-level constants. Append units and
qualifiers in descending order of significance (such as `ram_bytes_max` or
`timeout_ms`).

### Comments

Write code comments as complete sentences starting with a capital letter and
ending with a period. Prefer self-explanatory code, and use comments to explain
why a design choice or invariant exists rather than restating what the next
line does.

### Idiomatic Zig usage and memory safety

Use Zig's type system and compile-time checks instead of repetitive control
flow:

* Parse CLI commands, flags, and configuration keys into enums with
  `std.meta.stringToEnum` and dispatch with `switch` rather than chained string
  comparisons.
* Write hexadecimal literals in lowercase (`0xfff`, never `0xFFF`), and replace
  magic numbers or unnamed bitmasks with named constants, enum tags, or inline
  helpers.
* Use explicit fixed-width integer types (`u64`, `u32`, `u16`, `u8`) in ABI
  structs and 64-bit guest register state rather than `usize`. Annotate local
  variables initialized from `@min` or `@max` with a literal so Zig does not
  infer a narrow integer type.
* Keep mechanism in Zig code and store repository paths, hardware sizing
  defaults, and runtime policy in declarative configuration files or dedicated
  path modules. Update co-versioned internal paths atomically across the
  repository rather than keeping multi-path fallback lists.

Manage memory and buffers explicitly. Static pre-allocated structures are
appropriate during early M-mode boot before a heap allocator is initialized.
Once an allocator is available, allocate and grow buffers dynamically instead
of guessing fixed stack sizes. Where a fixed-size buffer is required by an ABI
or lock-held hot path, size it with a named constant and use a truncation
helper rather than swallowing formatting errors. Pair every allocation with
`defer` and `errdefer`, never ignore error unions, and format code with
`zig fmt` before submitting changes.
