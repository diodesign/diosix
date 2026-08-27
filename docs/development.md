# Develop Diosix

We welcome contributions to the Diosix project. To maintain a consistent
standard across both code and documentation, contributors must follow the
guidelines and coding standards described below.

---

## Memory ownership and allocation

The hypervisor manages memory explicitly to prevent leaks and runtime failures.
Function callers are responsible for tracking and freeing heap allocations
returned by functions that require an allocator. You must use the provided
allocator for resource deallocations and handle cleanups under failure states
using Zig's `defer` and `errdefer` mechanisms.

---

## Testing and verification

Diosix maintains two tiers of automated tests: fast host-native unit tests
and a full-stack live QEMU integration test suite.

### Unit testing

All new core logic must include unit tests. The test suite compiles and runs
natively on the host development machine without requiring an emulator. 

To run the unit test suite, use the build wrapper script:

```bash
./scripts/build.sh test
```

### Full-stack integration testing

For changes affecting the SBI hypercall interface, the `/dev/diosix` driver,
manifest attenuation, or the `dsx` command-line utility, run the live QEMU
integration test harness:

```bash
# Compile the hypervisor and run the 11-stage live guest integration suite
./scripts/build.sh
./scripts/test_manifest_integration.py
```

This automated test boots QEMU, logs into the Root VM, and validates all
hypercalls, quotas, manifest attenuation rules, service resolution, IPC
messaging loops, and guest-initiated shutdown.

Ensure both unit tests and integration tests pass before submitting changes
for review.

---

## Coding style and standards

Code contributions must follow standard Zig naming conventions, such as PascalCase
for types and camelCase for functions. Format all Zig files using `zig fmt`
before committing.

For technical documentation, follow the guidelines in the [style guide](style-guide.md),
including wrapping prose at approximately 80 characters, using sentence-case
headings, and spelling out abbreviations on first use.

---

## Versioning and branching model

Diosix manages development and releases using a staging-to-release workflow.

### Calendar Versioning

We use the Calendar Versioning (CalVer) standard in the `YY.MINOR` format. Even-numbered
minor versions indicate stable, production-ready releases suitable for
deployment. Odd-numbered minor versions indicate development builds representing
active, ongoing changes.

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
