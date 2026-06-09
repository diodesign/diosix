# Diosix style guide

This guide defines the standards for contributing to the Diosix project, 
ensuring consistency across both documentation and the codebase. All 
contributors must follow these guidelines to maintain the project's high 
standard of quality.

## Technical documentation style

Diosix documentation is written for a technical audience and prioritizes 
clarity, precision, and professional prose. All documentation must be 
comprehensive while remaining as concise as possible.

### Voice and tone

Maintain a professional and direct tone that avoids marketing hype, jargon, 
and unnecessary waffle. Every sentence should provide tangible value to 
the reader. Use the active voice and present tense whenever possible, 
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
    or SoC that runs the compiled hypervisor.
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
for multi-step procedures. To maintain readability in terminal-based 
environments, wrap all text at approximately 80 characters.

## Coding style

Diosix follows idiomatic Zig conventions to ensure the codebase remains 
accessible and maintainable for the wider community.

### Naming conventions

For functions and variables, use `camelCase`. Types, structs, and enums 
must use `PascalCase`. Constants should use `snake_case` or 
`SCREAMING_SNAKE_CASE` depending on their scope and intended usage. All 
source files must use `snake_case` filenames.

### Comments and documentation

All comments must follow standard sentence structure, beginning with a 
capital letter and ending with a period. The code should be largely 
self-documenting; use comments to explain the "why" behind a design 
decision rather than the "what," unless the logic is particularly 
intricate. Maintain a professional tone and avoid technical jargon where 
a simpler explanation suffices.

### Idiomatic Zig usage

Be explicit about memory management and allocations, and consistently use 
`errdefer` to ensure proper resource cleanup during failures. Use 
descriptive error sets and avoid swallowing errors. All code must be 
formatted using `zig fmt` before it is submitted for review.
