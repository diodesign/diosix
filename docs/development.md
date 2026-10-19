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
*   Externalize tunable defaults into `/etc/diosix/*.toml` configuration files
    rather than hardcoding magic values in source code.
*   Format all Zig files using `zig fmt` and verify that documentation in
    `docs/` matches the implementation before committing.

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
