# Develop Diosix

We welcome contributions to the Diosix project. To maintain a consistent
standard across both code and documentation, contributors must follow the
guidelines and coding standards described below.

---

## Memory ownership and allocation

The hypervisor and userland tools manage memory explicitly to prevent leaks,
buffer truncations, and runtime failures. During early Machine-mode (M-mode)
boot before a heap allocator is available, static pre-allocated structures are
used. Once an allocator is initialized — whether the per-core heap allocator
in M-mode or dynamic allocators in User-mode (U-mode) tools — code must
allocate and resize buffers dynamically rather than guessing fixed static
buffer limits.

Function callers are responsible for tracking and freeing heap allocations
returned by functions that accept an allocator. Always release resources with
the same allocator using Zig's `defer` and `errdefer` mechanisms, and verify
that no pointer or slice is used after it is freed or invalidated by a
reallocation.

---

## Testing and verification

Diosix maintains two tiers of automated tests: fast host-native unit tests
and multi-component integration tests.

### Unit testing (co-located in source files)

All core logic must include unit tests placed directly inside the same `.zig`
source file as the code they test. Module test blocks should also call
`std.testing.refAllDecls(@This())` to ensure all public functions undergo
compile-time semantic analysis. The unit test suite compiles and runs natively
on the host build machine without requiring an emulator.

To run the unit test suite, use the build wrapper script:

```bash
./scripts/build.sh test --summary all
```

### Integration testing (dedicated `tests` folders)

Integration tests that exercise multiple components together live in separate
`tests` folders, complemented by the full-stack live QEMU integration test
harness. For changes affecting the Supervisor Binary Interface (SBI) hypercall
ABI, the `/dev/diosix` driver, manifest attenuation, or the `dsx` command-line
utility, run the live QEMU integration suite:

```bash
# Compile the hypervisor and run the live guest integration suite
./scripts/build.sh
./scripts/test_manifest_integration.py
```

### Live media generation and testing

To build a standalone, bootable hybrid GUID Partition Table (GPT) disk image
suitable for flashing to SD cards/eMMC or booting directly in QEMU:

```bash
# Build the bootable hybrid GPT live disk image
# (zig-out/diosix-live-riscv64.img)
./scripts/build.sh live-image

# Boot QEMU with the live disk image attached as primary storage
./scripts/build.sh run-live
```

Ensure both unit tests and integration tests pass before submitting changes
for review.

---

## Coding style and pre-commit review

Code contributions must follow the [style guide](style-guide.md):

*   Keep source files under 500 lines and wrap all code and prose at 80
    characters or fewer.
*   Use concise `snake_case` filenames without redundant prefixes, `PascalCase`
    for types, and `camelCase` for functions.
*   Use `std.meta.stringToEnum` and `switch` for command, flag, and key
    dispatch rather than `if`/`else if` string comparison chains.
*   Externalize build layout paths, hardware sizing defaults, and runtime
    tunables into `build/layout.zon`, `boot/hypervisor.conf`, and
    `/etc/diosix/*.toml` rather than hardcoding paths or magic values in code.
*   Never swallow `std.fmt.bufPrint` errors with `catch ""` or use unnamed stack
    buffer sizes; use dynamic allocation or named capacity constants with
    centralized truncation helpers.
*   Format all Zig files using `zig fmt` and verify that documentation in
    `docs/` matches the implementation before committing.

---

## Develop with AI agents

If you use an Artificial Intelligence (AI) coding agent to write, review, or
document Diosix code, we strongly encourage you to install the official Diosix
agent skills from the
[diosix-agent-skills](https://github.com/diodesign/diosix-agent-skills)
repository. These are the same skills the maintainers use on this project, so
agent-generated changes follow the project's conventions from the first draft.

The repository provides three skills:

*   `developing-diosix`: Zig 0.17 idioms, memory and buffer rules, RISC-V
    M-mode constraints, and the architecture and style rules in this guide,
    including the backwards-compatibility policy below.
*   `reviewing-diosix`: A pre-commit and pre-merge audit covering magic
    numbers, borrow-checker and lifetime hazards, test coverage, the
    500-line and 80-column limits, and more.
*   `documenting-diosix`: The rules in the [style guide](style-guide.md) for
    keeping `docs/` and `README.md` synchronized with the implementation.

To use them, clone the repository and add the skills to your agent's skills
directory, following your agent's documentation. For example:

```sh
git clone https://github.com/diodesign/diosix-agent-skills.git
```

Agents make mistakes, so you remain responsible for every change you submit.
Review all agent-generated code and documentation, run
`./scripts/build.sh test --summary all`, and confirm that the change passes the
`reviewing-diosix` checks before you open a pull request. Keep personal agent
configuration out of the repository: the `.agents` directory is listed in
[`.gitignore`](../.gitignore) for this purpose.

Tooling choices are entirely up to you. The Diosix project treats AI assistants
like any other editor or compiler. What matters is the outcome. Every submission
is judged solely on the quality, correctness, and consistency of the resulting
code and documentation.

---

## Backwards compatibility and internal refactoring

Maintainers distinguish between external contracts that users depend on and
internal implementation details that ship together inside the repository:

*   **Preserve external contracts**: Maintain backwards compatibility for the
    SBI hypercall Application Binary Interface (ABI) in
    [`sbi.zig`](../hypervisor/interface/sbi.zig), Linux kernel driver `ioctl`
    structures in [`diosix.h`](../tools/driver/diosix.h), documented `dsx`
    commands and `--json` output schemas, and user-authored configuration files
    under `/etc/diosix/`. When an external flag or configuration key is
    superseded, keep the compatibility alias isolated in the parser layer and
    annotate it with a target removal version
    (`// DEPRECATED(26.1): remove in 27.0`).
*   **Update co-versioned internal plumbing atomically**: Never accumulate
    multi-path fallback arrays (such as probing multiple legacy directories in
    `/boot`, `/var/lib/diosix`, and `/usr/share/diosix`) when both the producer
    and consumer live in this repository. When changing an internal file path,
    build artifact location, or module interface, update all in-tree scripts,
    tools, and integration tests in the same commit so runtime code relies on a
    single canonical location.
*   **Migrate persistent disk state at the boundary**: If persistent storage on
    `/var/lib/diosix` may contain files created by an earlier release layout,
    perform a one-time migration or symlink update during boot initialization or
    `dsx host install` rather than probing legacy paths across userland tools at
    runtime.

---

## Versioning and branching model

Diosix manages development and releases using a staging-to-release workflow.

### Calendar versioning

We use the Calendar Versioning (CalVer) standard in the `YY.MINOR[.PATCH]`
format (for example, `26.1`, `26.2`, or `26.2.1`). Odd-numbered `MINOR`
versions (`26.1`, `26.3`) indicate beta development releases working directly
toward the next even-numbered `MINOR` version (`26.2`, `26.4`), which indicates
a stable, production-ready release. An optional `.PATCH` suffix is reserved for
critical security or breaking bug fixes on a released version.

### Branching strategy

The repository uses a staging-to-release branching model built around two
permanent, long-lived branches alongside short-lived, ephemeral branches:

- `devel`: The integration branch for active development. All new features,
  improvements, and bug fixes target this branch first.
- `stable`: The production-ready branch. Release tags are cut from `stable`,
  and it is used to build the official project website.
- Feature and bug-fix branches: Temporary, short-lived branches created to
  isolate individual tasks. Once a task is complete and merged, its branch
  is deleted.

#### Development workflow

1. Create a short-lived feature or bug-fix branch from `devel`.
2. Implement changes and run unit tests locally.
3. Submit a pull request to merge the changes into `devel` for
   collaborative review and continuous integration testing.
4. Periodically, after stabilization and verification, changes in
   `devel` are merged into `stable`. Releases are then tagged from `stable`.
5. Delete the completed feature or bug-fix branch from the remote
   and local repositories.
