# Rooms, Identity, and Permissions

[Architecture index](README.md) · [Synchronization](synchronization.md) · [Local tabs](local-tabs.md)

## Ownership and Source Map

- [room_identity.dart](../../lib/room_identity.dart): ID generation/validation, invitation roles, immutable optional `RoomDiskAccess`, URL/QR serialization, and strict invitation/public-share validation.
- [room_session.dart](../../lib/room_session.dart): admission, local command guards, durable role/binding projections, and participant views.
- [room_document.dart](../../lib/room_document.dart): participant names, room name, and monotonic role projection.
- [room_page.dart](../../lib/ui/room_page.dart): name prompts, create/join/restore navigation, and successful-exit handling.

Identity is not authentication. These contracts make ordinary trusted clients consistent; they do not establish a malicious-client security boundary.

## Distinct Identities

| Identity | Lifetime and purpose |
| --- | --- |
| Room ID | Stable room identifier: 128 random bits encoded as 32 lowercase hexadecimal digits. Invitations contain this ID. |
| Actor ID | Persistent local client identity used for operation authorship, names, roles, and membership. Shared-origin tabs can share it; another browser/profile normally does not. |
| Signaling ID | Runtime transport identity. An eligible participant may claim `mytree-room-<roomId>`; a follower uses a random runtime ID. Neither is a tree person. |
| Tree person ID | Stable domain identity. The virtual `root` exists even before any tree operation is written. |
| Operation ID | Immutable identity for deduplication, validation, retry, and convergence. |
| Local ownership term | A tab-coordination term, not a room membership or an external participant identity. |

`createRoomId()` generates secure random IDs for several of these uses. `isValidRoomActor()` is a bounded identity-string validator, not proof that the caller owns that identity.

Author-prefix sequences are scoped to **(room, issuing actor)** across every edit kind, not a tree person, displayed participant name, field, or network-owner term. Same-origin tabs sharing an actor extend one canonical prefix through the shared journal lock; separate actors bound to one person retain separate prefixes. A role operation is ordered with its issuing actor's edits, not the subject's. Names, bindings, and network handovers never renumber existing records. Sequence proofs establish structural predecessor/base completeness for known history, not authenticated ownership or discovery of an unknown offline past; see [history and storage](history-and-storage.md#author-prefix-proofs-and-the-legacy-boundary).

## Invitations

A web invitation has the form:

```text
https://host/application/#room=<roomId>&role=guest
https://host/application/#room=<roomId>&role=editor
```

`createRoomLink()` preserves the current host, port, application path, and unrelated query. It replaces the original fragment completely. Room, role, and optional `disk` parameters stay in that fragment, not the HTTP path/query:

```text
https://host/application/#room=<roomId>&role=editor&disk=<base64url-payload>
https://host/application/#room=<roomId>&role=guest&disk=<base64url-payload>
```

`disk` is compact UTF-8 JSON encoded as base64url, not encryption. Its exact version-1 schema is either `{v: 1, bindingId, token}` for an editor, or `{v: 1, bindingId, publicUrl}` for a guest. `bindingId` is the immutable active Disk connect-operation ID and uses bounded actor/edit-ID validation, not the hexadecimal room-ID rule. A token is nonempty, at most 4096 characters, unchanged by trimming, and contains no controls. The access JSON is bounded to 32 KiB on decoding. Guest share validation accepts HTTPS/443 links under `/d/…` on exactly `disk.yandex.ru`, `disk.yandex.com`, or `yadi.sk`, without userinfo or a fragment; it is distinct from the HTTP client's signed-download URL allowlist.

Access and role must match; omitted roles mean guest and cannot carry an editor token. Unknown/mixed Disk fields, bad encoding/UTF-8, repeated fragment `room`/`peer`/`role`/`disk`, conflicting room aliases, and duplicate JSON security/access keys, including escaped keys, are rejected. Invalid access never degrades to a plain invitation or raw ID. Legacy unrelated JSON metadata remains permissive. The ID-only readers remain compatibility helpers, not admission validators. Validation failures do not quote the supplied URL, token, or JSON.

Invitations without access keep their previous serialized form. A Disk-enabled invitation is bearer-like access information: an editor invitation contains an OAuth token, while a guest invitation carries public read access. Keep both private; fragment placement avoids sending the invitation to the application host but provides neither encryption nor cryptographic authorization.

At web startup, `consumeRoomAddress()` captures the original URI and synchronously replaces the current browser history entry with its fragment-free form, before Flutter binding, storage, networking, or alias prompts. The original URI is passed to `RoomPage` for strict invitation parsing; invalid/cancelled invitations are scrubbed too. Hosting path and unrelated query parameters remain. The root Flutter route is always named `/`, never the invitation, and successful entry/menu navigation no longer writes room IDs into the address. Explicit Copy URL and QR still generate full role-aware invitations. Clean-address reload restores accepted membership through the existing last-room store; an unaccepted/cancelled invitation is not newly persisted just to survive refresh. Replacing this history entry does not erase external browsing history, revoke prior invitations, or protect local storage from someone with access to the browser profile.

The production UI uses `parseRoomInvitation()` / `roomInvitationFromUri()`. Missing roles mean guest; unknown or repeated roles are rejected. Raw IDs are guest invitations. Legacy JSON QR payloads and the old `#peer` syntax can be parsed, but parsing an old transport ID does not recreate an ephemeral room. The caller still validates the stable room ID.

QR codes contain a current-origin invitation URL on the web; native fallback QR data adds a nested `disk` object to the existing `{v: 1, peerId, role}` JSON when access is present. The invitation dialog's Copy Code action likewise includes the complete JSON invitation when Disk access is available; without it, Copy ID still copies only the ID. Long payloads can exceed QR capacity, so URL/code copying remains available. No scanner service or connection server is required. Editor-token sharing and first publication of guest access require separate explicit UI confirmations; opening or merely rendering the dialog does not publish a folder or expose the access value as selectable text.

## Creation, First Admission, and Restore

1. `RoomPage` reads the client ID and last room, parses any incoming invitation, and checks saved membership.
2. If no participant alias is saved, the UI offers an optional name before creation/admission. Accepting an empty value is an explicit anonymous alias; canceling is distinct and does not create a room or write an unaccepted profile. A saved empty alias does not prompt again on restore.
3. Creating a new random room saves creator membership. Its creator is an editor and can explicitly establish the initial never-shared solo state.
4. A fresh join using only an ID or a legacy/role-only invitation still requires a valid compatible welcome from an online participant. The production tree profile requires `familyTree`, `familySurnames`, `personalSurnames`, `explicitSiblings`, `authorHistory`, and `participantIdentity` even for an empty room; rejection precedes history/profile/membership import. Signaling registration and an open DataChannel alone do not grant membership. A valid Disk-enabled invitation supplies the separate bounded-history admission path below, without requiring another participant online.
5. Incoming entry history is validated for complete author prefixes before persistence; the participant's name/initial role use the same atomic authored-backlog path as other local edits. Admission rechecks the current channel/generation or Disk-entry attempt around asynchronous writes; then membership can be saved.
6. The normal editor opens after the applicable initial verification: a complete durable peer exchange, verified Disk admission, or explicit new-room solo initialization. A welcome alone is not a completed peer checkpoint.

A failed membership write can leave already saved profile operations behind: storage is not a cross-record transaction with guaranteed rollback. Before membership is accepted, retry reads this residue, reuses immutable operations, and does not replace its original explicit role or a later profile name. This is distinct from a previously accepted guest deliberately reopening an editor invitation.

An accepted saved member restores local history and can reconnect without being admitted as a new participant. Matching retained editor credentials or guest public access can revalidate Disk history on reload without another participant online. The UI may offer an explicit local-copy mode if initial verification cannot be established. That mode does not grant membership to a fresh client and does not claim successful synchronization.

### Admission from Disk

Before starting RTC or the write-capable Disk replica, `RoomSession` reads the invited binding through `readDiskRoomHistory()`, using the same serialized admission/history queue. The read checks content-addressed filenames and bytes, room/binding envelopes, immutable conflicts, complete author predecessor/base closure over the union with retained local history, and that the invited binding is still active. It is bounded by a deadline, at most 2048 candidate batches, and an 8 MiB aggregate download. Session admission additionally requires an **explicit durable editor role for the active binding's owner**; the legacy implicit-editor fallback is not sufficient evidence.

Only after validation does it merge/flush history, durably prepare the local alias/initial role, save the matching permitted access, and flush again. **Membership is committed last**, before the existing last-room pointer ordering. Attempt/generation and active-binding checks prevent late/cancelled work from accepting a stale entry. This is not a cross-record transaction: failure can leave valid history/profile/access residue, but that residue alone is not membership. Retry reuses it. A validated explicit editor invitation can durably promote an existing guest before retaining its matching editor token; a public guest invitation or saved-room restore without such an invitation cannot do either.

Successful Disk entry records `История загружена с Диска · онлайн-сверка продолжается` and opens the verified copy. It does not create a peer ACK, settle a live cohort, or manufacture local-tab readiness evidence. Ordinary RTC discovery/checkpoint exchange continues. The cloud inventory is the available validated copy, **not proof of the newest global history**: another offline editor can still have an unseen tail. “Without an online participant” still requires working access to Yandex Disk, not a device without Internet. Failed Disk reads/saves remain visible and can be retried or followed by ordinary online admission; no empty room or fabricated cloud success is substituted.

## Optional Participant Aliases

`normalizeParticipantName()` trims a single-line alias of at most 64 Unicode code points. It returns `''` for empty/whitespace-only input and `null` for invalid input, including controls or an excessive length. Wire/storage values must already be canonical. `normalizeRoomName()` still rejects empty titles; optional participant aliases do not make room names optional.

An empty `participantName` is an ordinary persisted LWW value, not a missing record: clearing the alias can supersede an older nonempty name and survives reload/synchronization. `RoomSession.participantName` exposes that raw alias, including `''`, separately from the displayed fallback. An omitted entry value (`null`) does not request a name write; an explicitly supplied `''` does. Alias changes use the normal optimistic save/error/retry path.

Display prefers the selected actor's nonempty alias, then the actively bound durable person's trimmed `TreePerson.name`, then **Аноним** (Anonymous). The person fallback excludes the separate birth surname; existing name text is not parsed into new fields. The full durable birth name is exposed separately for the bound-person tooltip. Guests never use a legacy person claim for this fallback.

## Roles and Command Guards

| Command | Guest | Editor |
| --- | --- | --- |
| Read the tree, biographies, and journal | Yes | Yes |
| Change own participant name | Yes | Yes |
| Bind own profile with `bindToPerson()` / release it with `unbindFromPerson()` | No | Yes |
| Edit tree fields (including per-person birth surnames), relationships, facts, or photos | No | Yes |
| Rename the room | No | Yes |
| Invite guests | Yes | Yes |
| Invite editors / promote an existing guest | No | Yes |
| Connect Yandex Disk when no binding is active | No | Yes |
| Receive an editor Disk token / manually synchronize with Disk | No | Yes, for the matching binding and available credential |
| Read/poll Disk through retained public access | Yes, read-only, for the matching active binding | Public access can be used for entry; editor replication requires a token |
| Publish the active binding folder for guest invitations | No | Explicit durable editor, matching credential, and publication consent |
| Disconnect Yandex Disk | No | Owner actor, or editor bound to the same durable person as the owner |
| Host or relay ordinary room history | Yes | Yes |

`editable` means joined, readable local history and a non-disposed session. It is not editing authority; `canEdit` additionally requires the actor's effective editor role.

Effective roles come from the **durable** role projection. An optimistic promotion with a failed write must not grant commands or positive role evidence to another tab. Explicit editor roles win monotonically over guest records, regardless of replay order. Legacy accepted actors without explicit role records remain editors. An explicit editor invitation promotes an existing guest by durably authoring an editor role for that same actor; ordinary saved-room restore, raw IDs and guest invitations do not promote a guest. Reopening an editor invitation after successful promotion does not author a duplicate role, and a guest invitation never demotes an editor. `RoomSession.invitationRole` remains nullable: omitted direct calls and the UI's guest-valued clean restore must not be replaced with an editor default for saved members. The upgrade uses the existing profile preparation/flush path; failed promotion stays guest until that same immutable role edit is saved on retry.

Tree commands validate local structural invariants in addition to the editor guard: known people/items, no locally introduced parent cycle (checked against every active direct-sibling member), and own-actor binding/release ownership and exact current claim. Atomic `createSibling` requires an existing source and unused new identity; existing-person sibling linking is not a command. `unlinkSibling` requires the exact active direct claim, retains assigned parents, and cannot remove a computed-only sibling relationship. These commands use the usual single-edit optimistic/save/error/retry path. New surname commands are person-scoped; the deprecated family helper emits a personal command, and raw shared-family commands are rejected locally. Personal clears inherit the father's canonical surname rather than exposing a legacy shared value. Surname payloads remain strictly validated and bounded to 200 runes by the [tree model](tree-model.md#canonical-surnames). Remote concurrent operations still require deterministic projection, rather than pretending local validation proves a globally serialized order. History decoding/replay and queued immutable retries still accept valid historical family records even when their editing representative is absent or in another family. The independent `personalSurnames` capability prevents older shared-surname clients from silently interpreting the same history differently.

There is no demotion, removal, application-enforced access revocation, administrator hierarchy, signature chain, or authorization server. Roles do not imply that a Yandex Disk credential already exists, and guests must never retain an editor token. The optional [Disk replica](yandex-disk.md) uses public connect/detach metadata, separate editor-only credential delivery, and explicitly shared invitations. Its validated-history admission path is for trusted family clients, not new cryptographic authorization; a guest's public link grants reading, not cloud writes.

## Releasable Person Binding

`bindToPerson()` records the local actor's choice as an ordinary `bindActor` tree operation. In deterministic **(clock, author, id)** order, the first claim remains active until an explicit matching release; a later bind alone cannot replace it. A pending optimistic binding blocks another choice. Old claim-only histories retain their earliest-claim behavior without migration.

`unbindFromPerson()` appends `unbindActor` with `{personId, actorId, bindingId}`, where `bindingId` freezes the exact immutable claim being released. Both the convenience API and raw tree-command path are editor-only and own-actor-only; stale/wrong-person releases are rejected locally. Domain replay additionally requires the release author to equal its actor and match the active claim. A release cannot clear another grouped actor's claim or a subsequent rebind, even to the same person. The target person may already be deleted. Releasing does not delete or rewrite old claims, authors, or journal records; after release, the actor can choose **This Is Me** again. See [tree replay](tree-model.md#parent-graph-and-actor-bindings).

Only editors see **This Is Me** / the bound-profile caption or can release a binding. **Change My Name** allows changing/clearing the alias and releasing the own binding. Completed binding/release state and participant grouping use `durableTree` and durable roles, not optimistic tree/role changes. An unsaved release leaves the durable identity active; failures remain visible and retry the original operation ID/core rather than issuing a replacement. `canBindToPerson` and `canUnbindFromPerson` expose the durable own-identity state alongside `canEdit`.

Legacy guest binding records remain in the immutable journal and domain projection, but are inactive in the room's displayed identity: guests keep their own actor/profile alias or Anonymous fallback, no tree-person avatar, and a separate participant/count even when they share a stored person ID with editors or other guests. `boundPersonId` returns no active binding for a guest. A durable promotion activates an unreleased legacy claim, or enables a new explicit claim for an unbound guest; a failed optimistic promotion enables neither binding nor grouping. Same-origin tabs still share one actor regardless of role—this editor-only policy concerns person-based grouping across actors, not local-tab identity.

Grouping editor actors by a shared active person ID is a **presentation projection**:

- one visible participant row, online if any grouped actor is online;
- self styling if the group includes this actor, using **this actor's** alias or own fallback, never another grouped actor's alias;
- for another group, choose the lexicographically first actor ID with a nonempty alias, or the first actor ID if none is named; online status does not affect that choice;
- an explicit alias wins over the bound person's name; otherwise use their durable `name` without surname, then Anonymous;
- the explicitly selected durable person avatar and a separate `boundPersonFullName` for tooltip display, regardless of the chosen alias; an absent/deleted person has no full-name/avatar value;
- bound groups contain only editors, so guest badges/profiles cannot be hidden inside an editor group;
- `otherOnlineCount` counts unique displayed identities and excludes this actor's displayed identity.

Actual command rights and operation authors remain actor-specific. Grouping does not merge stores, credentials, journals, transport sessions, or permissions. Disk unlink separately checks the editor's and owner actor's active **durable** person bindings to allow the same person on another editor device to act as owner; the displayed grouped row or alias is not that authority.

## Presence and Exit

The host derives a validated actor roster from ready live channels; followers use the host's validated roster. Same-origin followers additionally require local durable verification. A browser offline hint can revoke online evidence; browser online cannot supply positive proof by itself.

Internal transport counts/actor rosters remain separate from person-deduplicated display counts. Presence is an observation from the reachable session, not an absolute inventory across a network partition.

Exit to menu is navigation, not deletion of membership. `RoomPage` awaits successful `flush()` before retiring a session; a failed flush keeps the room and error visible. The next entry can restore the saved room. See [history and storage](history-and-storage.md) for the persistence contract and [networking](networking.md) for temporary hub election.

## Regression Anchors

- [room_identity_test.dart](../../test/room_identity_test.dart): strict invitation parsing, legacy forms, and role defaults.
- [room_roles_test.dart](../../test/room_roles_test.dart): admission order, role persistence, failed promotion, and guest-host behavior.
- [tree_room_session_test.dart](../../test/tree_room_session_test.dart): own-actor binding/release durability, exact-claim guards/rebinding, alias fallback and grouped selection, visible deduplication, and synchronized tree state.
- [room_details_test.dart](../../test/room_details_test.dart): names, participant rosters, and metadata.
