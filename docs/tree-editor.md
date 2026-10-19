# Tree Editor Documentation

The implemented tree editor is documented by subsystem under [architecture](architecture/README.md), rather than duplicated in this file.

- [Tree model and merge semantics](architecture/tree-model.md): people, atomic explicit sibling creation, shared incomplete parents, anchored text, ordered facts/photos, atomic fields, parent cycles, and first-claim bindings.
- [Tree layout](architecture/tree-layout.md): generations, sibling blocks, trunk modes, priority parents, and signed coordinates.
- [Application and UI](architecture/ui.md): independent scroll views, alignment, avatar connections, biographies, media input, and journal presentation.
- [Rooms and identity](architecture/rooms-and-identity.md): guests/editors, admission, participant presence, and **This Is Me**.
- [History and storage](architecture/history-and-storage.md): immutable records, durable writes, errors/retry, and platform storage limits.
- [Synchronization](architecture/synchronization.md): compatibility, full-history exchange, durable checkpoints, and recovery.

The family-tree editor was introduced on October 16, 2026. Old persistent text-demo records remain in the journal; they are not automatically converted into biographies or relationships. The virtual `root` person does not require an initial write.

Photos currently reside in the shared immutable journal. Full-history transfer is limited to 8 MiB, and local browser quotas may be reached sooner. Deleting a photo does not reclaim its historical storage. There is no independent cloud backup, Yandex Disk/token integration, full offline/PWA installation, or unlimited media archive.

See [verification records and manual checks](verification.md) for dated evidence and [future storage agreements](future-storage-and-sync.md) for proposals that are not yet implemented. The current real-browser driver is [check_tree_ui.cjs](../tool/check_tree_ui.cjs); text-demo drivers need adaptation for the new screen.
