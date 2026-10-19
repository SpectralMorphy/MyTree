# Storage and Synchronization for the Future Family Tree

Agreements dated October 14, 2026. This remains a future-development agreement, not the current implementation specification. The local-first Yandex Disk replica, immutable batches, and trusted-editor credential sharing are now an implemented subset; see the [current Disk architecture](architecture/yandex-disk.md) and [user setup](yandex-disk.md). Snapshot/cache formats, separate attachments, semantic-history redesign, and the other proposals below are not all implemented. Statements below retain their agreement-stage context.

## Main Approach

- Each participant stores the complete history of **semantic changes** to the tree. At the first stage, we will not build a separate archival system or delete old history.
- The current state is saved locally as a cache. When opening, we load it and apply missing changes rather than necessarily replaying the entire history.
- Yandex Disk is an additional persistent copy and a point for asynchronous exchange, not the only source of data.
- Online participants exchange changes over WebRTC. Loss of cloud connectivity must not prevent local work.
- A new participant's initial join without cloud integration requires an online room participant. A device that has already joined must be able to open the local room without another invitation.

In genealogy, most actions add new information rather than repeatedly replacing a single field. Therefore, the complete semantic history may be comparable in size to the current state plus metadata. We make no promises about specific sizes or speeds: we will use realistic measurements before making storage more complicated.

## What to Record

An operation has a unique ID, an author, causal order/version information, an object, and a change. The history needs an information source and an optional comment.

- Adding a person, relationship, or field is a separate action.
- Adding a biography paragraph records the added text, not a new save of the entire biography.
- Correcting information records the old/new value and the source, where appropriate.
- Deletion, restoration, and conflict resolution also remain in the history.
- Not every character, cursor position, or intermediate movement needs to become a permanent event: we combine them into a complete semantic action.
- Photos, scans, and documents are stored separately, only once; operations contain references to attachments.

The displayed author is a participant in our application, not the owner of the Yandex OAuth token. When shared credentials are passed on, cloud access alone does not prove authorship.

## Snapshots and the Log

A snapshot is data about people, relationships, and fields, not an image. It also contains versions, unresolved conflicts, and metadata needed for further merging, indicating which operations are included.

Periodic snapshots speed up opening, but the up-to-date state is determined by the snapshot **together with subsequent operations**. Participants retain the complete history. Snapshots do not justify deleting data that a long-absent device needs for merging.

A log of complete text states is acceptable for the current text prototype. This simplification is not the final format for large biographies and the tree.

## Data Durability

Each edit is saved locally first; sending it to the network and cloud happens independently of snapshot creation. Small changes can be sent in batches. Local save and cloud acknowledgment statuses are distinct.

An edit cannot be guaranteed to be in the cloud if the tab is closed before the write is acknowledged. Unacknowledged changes remain in the local queue and are sent on the next launch. Browser storage can be cleared by the user or the browser: export and backups are needed. If all devices and cloud copies are lost, recovery is impossible.

## Yandex Disk Without a Broker

- The **owner's personal account** is preferred, with access limited to the application folder where the API supports this.
- A separate account exclusively for the project is a fallback, not a requirement.
- The group is small; all invited editors are explicitly trusted. Sharing owner-authorized OAuth tokens with them is acceptable.
- A serverless broker is not part of the design. Clients work with Disk directly; the owner does not need to be online as long as the credentials remain valid.
- An OAuth token must not be embedded in a public build or a standard QR code. It is sent separately to selected editors over a secure channel.
- A recipient can pass their token on to others. This is a deliberate trust boundary, not something that can be prevented with UI buttons.
- On October 15, 2026, a simple trust-based model was chosen for application roles: no signed permissions or protection against a modified client. In the future, the Disk write token can be synchronized among declared editors; guests do not need it. Room roles do not mean that token sharing or Disk integration has already been implemented.
- Restricting access to the application folder does not imply independent permissions for each tree within it. Providing read-only access to an individual folder by publishing it and granting access through OAuth scopes are different mechanisms. Publishing family data requires a separate privacy decision.
- Without verified support for conditional writes, we must not let everyone indiscriminately overwrite a single cloud file. We are considering immutable operation batches with unique names and snapshots.

The API, OAuth, browser CORS, token issuance/revocation, and quotas require separate verification during implementation. This document does not mean that an account has been created, a folder has been published, or cloud synchronization has already been connected.

## Conflicts and the Current Stage

The future tree must merge changes deterministically across all devices. Different fields are merged automatically; contradictory facts may retain multiple alternatives until a person explicitly resolves them. A possible foundation is CRDT with domain-specific rules, but no specific library has been chosen yet.

In the current text prototype, we retain simple last-write-wins, without semantic conflict resolution. Guest and editor roles restrict commands in the standard client, but do not introduce cryptographic authorization. The history preserves losing changes, but does not automatically make them correct.

