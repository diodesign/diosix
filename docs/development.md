# Develop for Diosix

We welcome contributions to the Diosix project. To maintain a consistent
standard across both code and documentation, contributors must follow the
guidelines and coding standards described below.

---

## Memory ownership and allocation

The hypervisor manages memory explicitly to prevent leaks and runtime failures.
Function callers are responsible for tracking and freeing heap allocations
returned by functions that require an allocator. You must use the provided
allocator for resource deallocations and handle cleanups under failure states
using Zig's `errdefer` mechanism.

---

## Unit testing

All new core logic must include unit tests. The test suite compiles and runs
natively on the host development machine. 

To run the test suite, use the build wrapper script:

```bash
./scripts/build.sh test
```

Ensure all tests pass before submitting changes for review.

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

### Staging branches
The repository maintains two branches to coordinate changes. The `devel` branch
serves as the staging area for ongoing feature additions and active development.
The `stable` branch represents production-ready code, from which releases are
created and the project website is built.

All development workflows target the `devel` branch; changes are only merged
from `devel` into `stable` after completing testing and validation.
