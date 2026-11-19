# Develop Diosix

Contributions to Diosix are welcome. Following the guidelines below keeps the
hypervisor, userland tools, and documentation reliable and straightforward to
review.

---

## Memory ownership and allocation

The hypervisor and userland tools manage memory explicitly to prevent leaks,
silent buffer truncations, and runtime crashes. During early machine-mode
(M-mode) boot before a heap allocator is initialized, boot code uses static
pre-allocated structures. Once an allocator is ready—whether the per-core heap
in M-mode or dynamic allocators in user-mode (U-mode) tools—allocate and resize
buffers dynamically rather than guessing fixed stack sizes.

Callers own any heap memory returned by functions that accept an allocator.
Free allocations with the same allocator using `defer` and `errdefer`, and make
sure no pointer or slice is read after being freed or invalidated by a resize.

---

## Testing and verification

Diosix relies on two layers of automated tests: fast host-native unit tests and
full-stack QEMU integration tests.

### Unit testing

Place unit tests inside the same `.zig` file as the code they exercise so
public declarations go through compile-time semantic checks alongside their
behavioral assertions. Unit tests compile and run natively on your build
machine without starting an emulator, and also verify the feature graph,
Markdown links and section anchors, and the generated support matrix:

```bash
./scripts/build.sh test --summary all
```

Whenever you add, split, or remove source files or documentation headings,
update `build/features.zon` (and `build/features/*.zon`) and regenerate the
support matrix:

```bash
./scripts/build.sh features
```

### Integration testing

Multi-component integration tests live in dedicated `tests/` directories
alongside the live QEMU integration harness. When changing the supervisor
binary interface (SBI) hypercall application binary interface (ABI), the Linux
kernel driver, manifest pruning, or CLI workflows, run the live QEMU
integration suite after building:

```bash
./scripts/build.sh
./scripts/build.sh sdk
python3 -B scripts/test_manifest_integration.py
python3 -B scripts/run_swarm.py --hosts 2 --self-test
python3 -B scripts/test_live_llm_app.py --self-test
python3 -B scripts/hil/runner.py --self-test
```

### Live media builds and testing

To build and boot the standalone hybrid GPT live disk image:

```bash
# Build zig-out/diosix-live-riscv64.img or package a standalone release archive
./scripts/build.sh live-image
./scripts/build.sh release

# Boot QEMU with the live disk image attached as primary storage
./scripts/build.sh run-live
```

Make sure both unit and integration tests pass before opening a pull request.

---

## Coding style and pre-commit review

All code and documentation changes follow the
[Diosix style guide](style-guide.md):

* Keep source files at 500 lines or fewer, decomposing larger modules into
  cohesive subdirectories without dropping features or tests.
* Wrap code, comments, and documentation prose at 80 characters or fewer.
* Use concise snake-case filenames without redundant prefixes, PascalCase for
  types, and camelCase for functions.
* Parse commands, flags, and configuration keys into enums and dispatch with
  `switch` instead of chained string comparisons.
* Keep repository paths, hardware sizing defaults, and runtime policy in
  declarative configuration files rather than hardcoding paths or magic numbers
  in source logic.
* Format Zig code with `zig fmt` and update documentation in `docs/` whenever
  behavior, flags, or interfaces change.

---

## Developing with AI agents

If you use an AI coding agent to write, review, or document Diosix code,
install the project skills from the
[diosix-agent-skills](https://github.com/diodesign/diosix-agent-skills)
repository so drafts match project conventions on the first pass:

```sh
git clone https://github.com/diodesign/diosix-agent-skills.git
```

* The `developing-diosix` skill covers Zig 0.17 idioms, memory ownership,
  symmetric multiprocessing (SMP) concurrency rules, and RISC-V M-mode
  constraints.
* The `reviewing-diosix` skill provides a pre-commit and pre-merge audit
  covering security boundaries, pointer lifetimes, dead-code removal, and line
  and file limits.
* The `documenting-diosix` skill keeps `docs/` and `README.md` synchronized
  with the codebase and aligned with the [style guide](style-guide.md).

Agents still make mistakes, so you remain responsible for every change you
submit. Review generated code and prose carefully, run the test suite, and keep
personal agent configuration outside version control. Every contribution is
evaluated on the clarity, safety, and accuracy of the resulting code and
documentation.

---

## Compatibility and internal refactoring

Maintainers separate external contracts that users rely on from internal
plumbing that ships together in this repository:

* External contracts—including the SBI hypercall ABI, kernel driver structures,
  documented CLI commands and JSON schemas, and runtime configuration
  files—preserve backwards compatibility across minor releases.
* Co-versioned internal paths where both producer and consumer ship in this
  repository are updated atomically in the same commit rather than accumulating
  multi-path fallback probes.
* Persistent disk layout changes on the data volume are migrated once at boot
  or installation time rather than scattering legacy checks across tools.

---

## Versioning and branching model

### Calendar versioning

Diosix uses calendar versioning (CalVer) in year-and-minor format, with an
optional patch number (such as 26.1, 26.2, or 26.2.1):

* Odd minor numbers (26.1, 26.3) mark beta development series leading up to the
  next stable release.
* Even minor numbers (26.2, 26.4) mark stable releases.
* Optional patch numbers (26.2.1) carry security or bug fixes on a released
  series.

### Branching workflow

Development uses two long-lived branches—`devel` for ongoing integration and
`stable` for tagged releases—alongside dedicated topic and flavor branches (for
example, `gui` preserves the legacy native desktop compositor and VirtIO-GPU
emulation stack) plus short-lived task branches:

1. Branch off `devel` for your feature or fix.
2. Implement your change, add or update tests, and run
   `./scripts/build.sh test --summary all`.
3. Open a pull request against `devel` for review and continuous integration.
4. When `devel` stabilizes for a release cycle, maintainers merge `devel` into
   `stable` and tag the release.
5. Delete the merged topic branch locally and on the remote.
