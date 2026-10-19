# MyTree Development Rules

## Proportionate Object Orientation and Modularity

Maintain a clear structure with enough object orientation, but no more than needed. The goal is to make behavior easy to change and test, not to maximize the number of classes or files.

- **A module groups related responsibilities.** Separate the UI, room state, network protocol, and platform storage. Do not combine everything in the entry point.
- **Do not create a file for every tiny helper.** For example, ID generation belongs alongside the other room identity/invitation operations, not in a separate single-function module.
- **Use a class for state, invariants, or a lifecycle.** Pure transformations and small helpers can remain functions. Do not use classes merely as namespaces.
- **Split large objects along real responsibility boundaries.** If a session manages connections, decodes packets, and assembles fragments, independent protocol logic can be extracted and tested separately. Do not move methods into neighboring files merely to reduce line counts.
- **Prefer composition to separate responsibilities.** A coordinator can use a journal object and a codec; do not introduce inheritance hierarchies or `part`/mixin splits solely to distribute methods across files.
- **Do not introduce abstractions without a need.** Additional factories, interfaces, proxy layers, universal managers, or dependency injection containers are unnecessary when they merely forward a single call. Interfaces for platform differences and substituting I/O in tests are justified.
- **Small platform adapters are an acceptable exception.** Conditional web/native imports establish platform boundaries and are not pointless fragmentation.
- **Do not impose artificial line limits.** Evaluate cohesion, readability, responsibilities, and dependencies. Large `main.dart` files and catch-all objects are reasons to review the structure, not to split it mechanically.
- **Keep the entry point simple.** It starts and composes the application; screen, storage, and messaging details belong in their respective modules.
- **Prefer explicit dependencies and narrow contracts.** Keep the model/protocol testable without Flutter UI, and the UI testable without real networking or disk access. Do not create circular dependencies.
- **Preserve behavior when refactoring.** Move and update tests with the code; do not combine structural changes with unrequested changes to the protocol, conflict resolution algorithm, or data format.

## Architecture Documentation

- The implemented architecture is documented in [docs/architecture/README.md](docs/architecture/README.md), with separate pages for each subsystem. Keep the relevant pages current when changing responsibilities, contracts, or invariants; do not collect the entire architecture in one file.
- Keep architectural internals out of the root README. It is for the product overview, setup, usage, limitations, and links to deeper documentation.
- Keep current implementation separate from future agreements and dated verification records. Do not present planned integrations or old benchmark results as current guarantees.

## Verification and Workflow

- Do not enter plan mode. If needed, use a subagent for research or planning, then implement directly.
- Run browser checks **headless**. Do not open windows or take focus away from the user's desktop unless explicitly asked.
- Run `flutter analyze`, tests, and a web build. Also verify UI/network changes in a real headless browser, not only with mocks.
- Do not hide saving errors or present unconfirmed network synchronization as successful. Do not rely on tab closure to save data.
- Future architectural agreements are documented in [docs/future-storage-and-sync.md](docs/future-storage-and-sync.md). They are not instructions to implement Yandex Disk or CRDT immediately.
