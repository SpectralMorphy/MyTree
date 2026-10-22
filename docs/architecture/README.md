# MyTree Architecture

This directory documents the **implemented** application for contributors. It describes ownership, contracts, data flow, and failure boundaries, not a proposal to introduce additional layers. Follow the [development rules](../../CLAUDE.md) when changing these boundaries.

## Subsystems

| Document | Responsibility |
| --- | --- |
| [Application and UI](ui.md) | Composition, room navigation, editor lifecycle, surname/biography forms, search, existing-person picking, photos, and presentation state. |
| [Rooms and identity](rooms-and-identity.md) | Room admission, invitations, actors versus people, optional aliases, roles, presence, and releasable person bindings. |
| [Tree model](tree-model.md) | People, parent/sibling/marriage relationships, birth/current surnames and chronological family history, computed patronymics and room overrides, anchored text, ordered lists, atomic fields, and deterministic projection. |
| [Tree layout](tree-layout.md) | Generation ranking, sibling blocks, trunk modes, placement, and the boundary with viewport geometry. |
| [History and storage](history-and-storage.md) | Immutable cores and author-prefix proofs, optimistic versus canonical durable state, atomic authored storage, retries, and refresh. |
| [Synchronization](synchronization.md) | WebRTC capability gates, predecessor-complete batches, proof-aware inventories, durable checkpoints, entry barriers, chunking, and recovery. |
| [Yandex Disk](yandex-disk.md) | Optional local-first replica, immutable batches/read-back acknowledgment, validated-history invitations, consented public guest reads, editor credentials, binding ownership, and detach retries. |
| [Networking](networking.md) | Temporary participant hubs, signaling adapters, fallback/election, ICE/TURN, and public-service limits. |
| [Local tabs](local-tabs.md) | Shared-origin ownership, Web Locks, local state proofs, and safe handover. |
| [Testing and delivery](testing.md) | Test boundaries, real-browser drivers, release serving, and verification caveats. |

## Dependency and Ownership Map

```text
main.dart                         application composition and theme
  └─ RoomPage                     room/menu navigation and visible entry gate
       ├─ TreeEditor              selection, scrolling, rendering, picker route
       │    ├─ TreeLayout         pure generation/block geometry
       │    ├─ TreePersonSearch   matching and compact suggestion overlay
       │    └─ PersonBiography    forms/media input; picker callback, no canvas import
       ├─ room dialogs            invitations, participants, settings, journal
       └─ RoomSession             room lifecycle and command/network coordinator
            ├─ TreeDocument       optimistic and durable domain projections
            ├─ RoomHistory        append/retry/refresh and persistence evidence
            │    ├─ RoomDocument  room-level immutable records and metadata
            │    └─ RoomStore     web/native/memory storage boundary
            ├─ room_protocol      validation, inventories, framing and decoding
            ├─ SignalingPeer      PeerJS + MQTT fallback and RTC channels
            ├─ RoomDiskSync       optional immutable cloud replica and acknowledgment
            ├─ RoomDiskReadSync   bounded read-only public guest polling
            ├─ readDiskRoomHistory  validated read-only admission snapshot
            ├─ YandexDiskClient   shared private/public HTTP and consented publication
            ├─ RoomDiskRetirements  independent frozen final-detach replicas
            ├─ DiskBinding        public journal projection, no credential
            ├─ DiskCredentialExchange  editor RTC fallback only behind ready guest hub
            └─ RoomTabs           optional same-origin ownership coordination
```

`TreeDocument` and `TreeLayout` are plain Dart and do not depend on Flutter, sockets, or disk. The layout consumes the model's immutable sibling-group map for computed full siblings and active explicit components; historical surname-family keys remain separate. The purpose-specific search module accepts an immutable people map and an ID callback; forms receive a narrow picker callback rather than importing the canvas. `RoomHistory` owns persistence state; a widget is not an alternative storage layer. `RoomSession` composes these responsibilities, rather than making the domain model aware of transport or platform APIs.

Platform-specific address, connectivity, storage, MQTT-client, and tab adapters use conditional imports. Browser APIs stay on the platform side of these boundaries. Small adapters are intentional; extracting a file for each trivial helper is not.

## End-to-End Change Flow

1. A form creates a typed tree operation using its current field snapshot. A UI gesture changes local selection/scroll state without writing an operation.
2. `RoomSession` checks command permissions and local structural invariants, then delegates to `RoomHistory`.
3. History fixes the draft's immutable ID/core/clock/UTC time, exposes the optimistic projection, and immediately invokes authoring with its ordered outstanding backlog. Storage assigns proofs only inside its asynchronous journal lock/queue; failed appends remain visible and retryable under their original cores.
4. Only canonical durable records enter outbound messages, expanded to recursive author predecessor/base closure. Checkpoints freeze logical IDs/cores, flush, then resolve saved proofs. A successful transport send is not a persistence acknowledgment.
5. Remote peers validate the envelope, immutable IDs, and complete resulting author prefixes before persistence, projection, or durable ACK. Old all-legacy history remains readable without automatic renumbering.
6. Same-origin followers obtain records from shared storage; local messages carry ownership/state proofs rather than drafts or a second database.
7. For a connected editor, Disk independently unions immutable cloud batches with the local durable journal and uploads missing records. Cloud acknowledgment requires confirmed remote bytes; it is not a WebRTC send/ACK or a new local-save guarantee.
8. A Disk-enabled invitation can instead import a bounded validated history and role-permitted access before membership, without a live peer. Its initial readiness is distinct from a peer ACK or globally latest history; ordinary RTC reconciliation continues. A public-link guest polls read-only updates, never uploads.

Details and exceptions belong to the subsystem documents above.

## Cross-Cutting Invariants

- **Do not confuse identities.** A room ID, local actor ID, runtime signaling ID, tree person ID, and local ownership term have different lifetimes. A displayed participant may group several actors without merging their permissions or authorship.
- **Do not confuse readiness with authority.** Admission, readable local history, initial synchronization, network availability, and editor permission are separate facts.
- **Do not replace immutable history.** New fields and operations must preserve old record decoding, digest compatibility, retry behavior, and the journal needed by an offline peer. Author prefixes seal only the known legacy baseline; they cannot prove an unknown older past or silently absorb unexpected same-author legacy records afterward.
- **Keep ordering contracts separate.** Author sequences order each actor's journal prefix, not actual wall time or existing room/tree conflict stamps. Canonical proof assignment must not change an optimistic core or text anchor.
- **Do not claim synchronization from a hint.** Browser `online`, a recent-host hint, an open socket, a welcome, or a latest-text preview alone does not establish a complete durable exchange.
- **Preserve failure visibility.** Storage errors, incomplete checkpoints, and service outages must not become successful saves, verified solo status, or blank replacement documents.
- **Keep local presentation local.** Trunk mode, main-node selection, zoom/scroll positions, search, generation hover, an open biography, and picker browsing/confirmation are not shared tree edits. Only the relative dialog's Add action establishes the chosen relationship.

## Current Scope and Limits

The app uses public signaling and STUN/TURN; users do not need to operate their own servers. This does not remove availability or privacy limitations. The trusted-client role model is not cryptographic authorization.

The full-history transfer limit is currently 8 MiB; browser storage quotas can be reached sooner. Photo deletion does not reclaim immutable history. The optional [Yandex Disk replica](yandex-disk.md) is an additional private copy/asynchronous exchange point, not an unlimited media archive or a replacement for admission/local persistence. Full offline/PWA installation is not implemented.

For remaining future work, read [storage and synchronization agreements](../future-storage-and-sync.md) and the [interface palette reference](../future-interface.md). The Disk subset is documented separately above; those broader agreements are not declarations that every proposed feature is implemented or instructions to implement them immediately. [Verification records](../verification.md) are dated evidence, not timeless guarantees or service SLAs.
