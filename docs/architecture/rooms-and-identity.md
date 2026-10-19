# Rooms, Identity, and Permissions

[Architecture index](README.md) · [Synchronization](synchronization.md) · [Local tabs](local-tabs.md)

## Ownership and Source Map

- [room_identity.dart](../../lib/room_identity.dart): ID generation/validation, invitation roles, URL/QR serialization, and strict invitation parsing.
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

`createRoomLink()` preserves the current host, port, and application path. Room and role parameters are in the fragment rather than the HTTP path/query. Invitation links are bearer-like discovery information and must stay private; fragment use is not cryptographic authorization.

At web startup, `consumeRoomAddress()` captures the original URI and synchronously replaces the current browser history entry with its fragment-free form, before Flutter binding, storage, networking, or alias prompts. The original URI is passed to `RoomPage` for strict invitation parsing; invalid/cancelled invitations are scrubbed too. Hosting path and unrelated query parameters remain. The root Flutter route is always named `/`, never the invitation, and successful entry/menu navigation no longer writes room IDs into the address. Explicit Copy URL and QR still generate full role-aware invitations. Clean-address reload restores accepted membership through the existing last-room store; an unaccepted/cancelled invitation is not newly persisted just to survive refresh. Replacing this history entry does not erase external browsing history, revoke prior invitations, or protect local storage from someone with access to the browser profile.

The production UI uses `parseRoomInvitation()` / `roomInvitationFromUri()`. Missing roles mean guest; unknown or repeated roles are rejected. Raw IDs are guest invitations. Legacy JSON QR payloads and the old `#peer` syntax can be parsed, but parsing an old transport ID does not recreate an ephemeral room. The caller still validates the stable room ID.

QR codes contain an ordinary current-origin invitation URL when running on the web; native fallback QR data is JSON. There is no requirement for users to run a scanner service or connection server.

## Creation, First Admission, and Restore

1. `RoomPage` reads the client ID and last room, parses any incoming invitation, and checks saved membership.
2. If no participant alias is saved, the UI offers an optional name before creation/admission. Accepting an empty value is an explicit anonymous alias; canceling is distinct and does not create a room or write an unaccepted profile. A saved empty alias does not prompt again on restore.
3. Creating a new random room saves creator membership. Its creator is an editor and can explicitly establish the initial never-shared solo state.
4. A fresh join must receive a valid compatible welcome from an online participant. The production tree profile requires `familyTree`, `familySurnames`, `personalSurnames`, `explicitSiblings`, `authorHistory`, and `participantIdentity` even for an empty room; rejection precedes history/profile/membership import. Signaling registration and an open DataChannel alone do not grant membership.
5. Incoming entry history is validated for complete author prefixes before persistence; the participant's name/initial role use the same atomic authored-backlog path as other local edits. Admission rechecks that the channel/generation remains valid around asynchronous writes; then membership can be saved.
6. The initial durable exchange still controls when the normal editor opens. A welcome is not the completed checkpoint.

A failed membership write can leave already saved profile operations behind: storage is not a cross-record transaction with guaranteed rollback. Retry reads this residue, reuses immutable operations, and does not replace an existing explicit role or a later profile name.

An accepted saved member restores local history and can reconnect without being admitted as a new participant. The UI may offer an explicit local-copy mode if initial synchronization cannot be established. That mode does not grant membership to a fresh client and does not claim successful synchronization.

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
| Receive Disk credentials / manually synchronize with Disk | No | Yes, for the matching binding and available credential |
| Disconnect Yandex Disk | No | Owner actor, or editor bound to the same durable person as the owner |
| Host or relay ordinary room history | Yes | Yes |

`editable` means joined, readable local history and a non-disposed session. It is not editing authority; `canEdit` additionally requires the actor's effective editor role.

Effective roles come from the **durable** role projection. An optimistic promotion with a failed write must not grant commands or positive role evidence to another tab. Explicit editor roles win monotonically over guest records, regardless of replay order. Legacy accepted actors without explicit role records remain editors. Existing explicit guest membership is not promoted by reopening an editor URL.

Tree commands validate local structural invariants in addition to the editor guard: known people/items, no locally introduced parent cycle (checked against every active direct-sibling member), and own-actor binding/release ownership and exact current claim. Atomic `createSibling` requires an existing source and unused new identity; existing-person sibling linking is not a command. `unlinkSibling` requires the exact active direct claim, retains assigned parents, and cannot remove a computed-only sibling relationship. These commands use the usual single-edit optimistic/save/error/retry path. New surname commands are person-scoped; the deprecated family helper emits a personal command, and raw shared-family commands are rejected locally. Personal clears inherit the father's canonical surname rather than exposing a legacy shared value. Surname payloads remain strictly validated and bounded to 200 runes by the [tree model](tree-model.md#canonical-surnames). Remote concurrent operations still require deterministic projection, rather than pretending local validation proves a globally serialized order. History decoding/replay and queued immutable retries still accept valid historical family records even when their editing representative is absent or in another family. The independent `personalSurnames` capability prevents older shared-surname clients from silently interpreting the same history differently.

There is no demotion, removal, application-enforced access revocation, administrator hierarchy, signature chain, or authorization server. Roles do not imply that a Yandex Disk credential already exists, and guests must never receive one. The optional [Disk replica](yandex-disk.md) uses public connect/detach metadata and a separate editor-only secret exchange; it grants no new first-admission path.

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
