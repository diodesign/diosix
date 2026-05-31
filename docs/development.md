# Develop for Diosix

We welcome and encourage contributions to the Diosix project. To maintain high
standards of quality, safety, and maintainability across both documentation and
prose, all contributors must follow our established development guidelines and
coding standards.

---

## Memory ownership and allocation

Diosix prioritizes predictable, robust memory management to prevent leaks,
corruption, and runtime failures:
*  **Caller responsibility:** Function callers are strictly responsible for
   tracking and freeing any heap allocation pointers returned by functions that
   require a memory allocator.
*  **Consistent cleanup:** Always use the provided system allocator for resource
   deallocations. Proactively handle cleanups under failure states by using
   Zig's `errdefer` mechanism.

---

## Unit testing

We require comprehensive unit tests for all new core logic and system components
to verify correctness before changes are integrated into the repository. All
unit tests compile and execute natively on the host development machine.

To compile and execute the complete test suite, run the build wrapper script:

```bash
./scripts/build.sh test
```

Ensure all host-side tests pass successfully and output clean reports before
submitting your changes for code review.

---

## Coding style and standards

To ensure the codebase remains accessible, readable, and consistent for the
wider systems programming community, all submissions must conform to the project
standards:
*  **Coding style:** We follow idiomatic Zig coding conventions (such as
   PascalCase for types and camelCase for functions). Ensure your code is fully
   formatted by running the compiler's formatter (`zig fmt`) before committing.
*  **Technical documentation:** Follow the standards defined in the project
   [style guide](style-guide.md). Wrap all documentation text hard at
   approximately 80 characters, use sentence-case headings, and spell out every
   abbreviation on its first use.

---

## Versioning and branching model

Diosix uses a staging-to-release workflow to orchestrate active development and
guarantee stable releases.

### Calendar Versioning
We use the Calendar Versioning (CalVer) standard in the format of `YY.MINOR` for our
releases. In this system:
*  **Stable releases:** Indicated by even-numbered minor versions. These are
   production-ready builds suitable for deployment.
*  **Development builds:** Indicated by odd-numbered minor versions. These are
   pre-release staging builds reflecting ongoing active work.

### Staging branches
The Git repository maintains two primary branches to coordinate changes:
*  **`stable`**: The branch representing production-ready code. Releases are
   created directly from this branch, and it serves as the source branch for
   building the official project website, [diosix.org](https://diosix.org/).
*  **`devel`**: The active staging branch for development and ongoing feature
   additions.

All development workflows must target the `devel` branch. Changes are only merged
from `devel` into `stable` after completing rigorous testing, quality control, and
validation.
