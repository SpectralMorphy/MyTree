# History and local storage

MyTree persists an append-only room journal, not the current screen or a replaceable tree snapshot. The journal carries legacy text, room metadata, roles, and family-tree operations. Local persistence and remote synchronization are separate guarantees.

The main boundaries are:

- [RoomDocument](../../lib/room_document.dart): immutable edit format, ordering, and text/metadata projection.
- [RoomHistory](../../lib/room_history.dart): optimistic state, durable state, pending writes, retries, and storage refreshes.
- [RoomStore](../../lib/storage/room_store.dart): platform persistence contract. [createRoomStore](../../lib/storage/create_room_store.dart) conditionally selects browser or native storage; it never silently substitutes memory after an error.
- [RoomSession](../../lib/room_session.dart): admission, network exchange, durable role/tree projections, and synchronization readiness.

## The immutable edit envelope

A `RoomEdit` has these fields:

| Field | Meaning |
| --- | --- |
| `id` | Immutable operation identity; identical retries deduplicate by this ID. |
| `author` | The issuing actor ID, not a displayed name or tree person ID. |
| `clock` | Existing logical projection stamp. A local edit uses the greater of wall-clock milliseconds and the previously observed clock plus one. Not the author-prefix sequence. |
| `createdAt` | Actual creation instant as UTC epoch milliseconds, fixed when the draft is created. It can go backward after a device-clock correction; it is neither a sequence nor a conflict-resolution key. |
| `text` | A string whose interpretation depends on `kind`. |
| `kind` | `text`, `participantName`, `roomName`, `participantRole`, `diskConnection`, or `tree`. Omitted when serializing legacy text. |
| `targetActor` | Required only for a role operation; identifies the subject rather than the author. Forbidden on other kinds. |
| `authorSequence` | Optional positive integer in `1..9007199254740991`. Present only with a complete author-proof envelope; absent on unchanged legacy entries and provisional local drafts. |
| `authorPrevious` | Required when `authorSequence` is present: explicit `null` for sequence 1, otherwise the immutable ID of that actor's immediately preceding sequenced edit. |
| `authorBase` | Required only for sequence 1: sorted, unique IDs of that actor's known legacy records, including an explicitly empty list when there are none. Forbidden on later sequences and legacy records. |

For example, a legacy record has no `kind`:

```json
{"id":"edit-1","author":"actor-a","clock":1,"createdAt":1,"text":"A note"}
```

A tree operation uses the same envelope, with **JSON encoded inside the `text` string**, not a nested payload object:

```json
{"id":"edit-2","author":"actor-a","clock":2,"createdAt":2,"kind":"tree","text":"{\"type\":\"bindActor\",\"personId\":\"person-1\",\"actorId\":\"actor-a\"}"}
```

This illustrates the encoding, not permission to issue an arbitrary binding: the session's command path additionally checks the actor and target person. Tree payloads are parsed and validated by [TreeOperation](../../lib/tree/tree_document.dart).

`decodeRoomHistory` validates the entire list's record syntax and immutable duplicates. IDs and authors must be nonempty strings of at most 128 characters; clocks and timestamps must be integers in `0..9007199254740991`, the exact common VM/JavaScript range. Unknown kinds, malformed proof fields, invalid canonical names, invalid roles/subjects, and invalid tree payloads are rejected. A missing `kind` means legacy text; explicit `text` is also accepted. Decoding alone intentionally allows incomplete proof subsets; `validateAuthorHistory` additionally checks complete predecessor/base closure at persistence, load, and refresh boundaries.

`setSurname` uses that same `kind: tree` envelope and JSON-in-`text` encoding. A family change stores one atomic configuration and its frozen `familyKey`, not per-sibling copies or rendered/inherited names. Decoding/loading retains a valid family record even when its representative `personId` is unknown or deleted: the serialized family identity owns the register. Existing history needs no name migration, storage-key change, or snapshot rewrite; effective names are derived by [tree replay](tree-model.md#canonical-surnames).

Releasing an actor/person link likewise appends an ordinary tree record whose payload is `{type: unbindActor, personId, actorId, bindingId}`. `bindingId` references the immutable original claim; neither that claim nor its envelope is replaced. Old `bindActor` payloads remain unchanged and retain first-claim semantics until an explicit matching release. Empty participant aliases use existing `kind: participantName, text: ''` records, not a new kind, deleted metadata, or a synthetic Anonymous name. Their LWW clearing value is persisted and exchanged exactly like other names; room titles still require nonempty canonical text. These changes require no storage-key migration or history rewrite. The [participant-identity capability](synchronization.md#capability-compatibility) prevents incompatible peers from importing/sending the new semantics.

Immutability includes every durable envelope field, including kind, role subject, and author proof. Two records with the same ID and different content are an error, not competing versions of one edit. The sole finalization exception is a history-owned provisional local draft: storage adds its proof without changing any core field. This is not permission to replace an existing durable ID.

At the storage layer, [HistoryRecord](../../lib/storage/storage_codec.dart) takes a detached JSON snapshot and recursively sorts object keys, so map insertion order does not create a conflict. This does not normalize the JSON *inside* a tree payload string. Generic all-legacy storage callers retain their JSON/nonempty-ID contract. Once proof-bearing records occur, the adapters additionally decode and validate the complete room history before accepting a write or load; stored records are not rewritten to a new representation.

### Author-prefix proofs and the legacy boundary

Each room has an independent sequence **per issuing actor**, covering every operation kind: text, names, room settings, roles, Disk connect/detach metadata, and tree operations. A promotion belongs to its author's sequence, not its `targetActor`'s. A displayed person/name can group actors but cannot merge their sequences.

Sequence 1 seals exactly the same actor's legacy records known in the locked persistent journal. `authorBase` is an immutable, lexicographically sorted list of at most 200,000 unique IDs. Each listed record must exist, have that author, and have no proof. Subsequent records link to sequence `n - 1` through `authorPrevious`. Complete validation rejects missing starts, holes, cross-author/wrong-sequence links, forks, changed IDs, and a legacy set that differs from the sealed base. A batch is checked against existing durable history before its first write, not accepted incrementally until a bad tail is encountered.

Old all-legacy histories remain readable, with their original records, serialization, digests, and ordering. There is **no automatic renumbering or migration**. Sealing proves the known baseline, not the absence of unknown older records on an offline device. An unexpected same-author legacy record arriving after sealing is a visible baseline error; the app does not silently add it to the seal, drop it, or invent a historical sequence. This proof is structural, not a signature or proof of genealogy/authorship against modified clients.

### Journal order is not conflict resolution

`RoomDocument.history` uses a deterministic topological order: legacy-base records precede sequence 1, and sequenced predecessors precede their successors. Among currently ready records it chooses the existing `(clock, id)` key. Different authors can interleave, and no total real-time order between devices is claimed. Optimistic unproven drafts use the available dependencies until storage finalizes them.

Projection stamps are unchanged:

- Legacy text, the room title, and each actor's participant alias have separate last-writer-wins projections using `(clock, id)`, not `authorSequence` or `createdAt`. An explicit empty alias can win and clear an older name; missing and empty are distinct.
- Metadata never replaces the visible legacy text.
- Explicit editor promotion is monotonic: a delayed guest record cannot undo it. An actor without an explicit role retains the legacy editor default.
- Tree edits remain in the journal but are projected separately by `TreeDocument`, retaining **(clock, author, id)** stamps and its field-specific merge rules.
- `diskConnection` metadata remains in the journal without changing text, names, roles, or tree projection. [DiskBinding](../../lib/cloud/disk_binding.dart) replays it separately in ascending `RoomEdit.compareTo` order: `{"action":"connect"}` claims the first unbound slot using the edit ID and author as binding ID/owner; `{"action":"disconnect","bindingId":"..."}` clears only that exact active binding. Ignored competing connects remain recorded and do not automatically become active after a disconnect; reconnect requires a new connect. Full-set replay handles out-of-order arrival, while a logically earlier disconnect does not tombstone a future connect. Both payload shapes are exact, reject duplicate/extra keys, and contain no token. Authorization is a command-layer concern for trusted clients, not part of this projection.

Losing edits remain part of history. A successor can appear later in journal order without becoming an LWW winner; proof assignment neither repairs device clocks nor changes domain conflicts.

## Optimistic, known, and durable are different sets

`RoomHistory` maintains an optimistic `RoomDocument` alongside its persistence bookkeeping:

| View/bookkeeping | Includes | Appropriate use |
| --- | --- | --- |
| `changes` / displayed projection | Durable edits plus optimistic local edits | Immediate local display. |
| `knownEdits` | Also pending and failed appends, including remote attempts; local drafts may lack proofs | Immutable-ID/core validation and logical checkpoint cutoffs, never outbound history. |
| `durableHistory` | Canonical stored edits with complete, validated author prefixes | Network history, inventories, and durable projections. |
| `_drafts` | Ordered outstanding local core records, still without proofs | Supply the complete local backlog to atomic authoring. |
| `_unsaved` / `_writes` | Retry payloads / in-flight futures | Recover saving without generating replacement IDs. |

`durableHistory` reuses an immutable, author-topologically ordered snapshot. The history publishes a new snapshot only after accepting a fully validated stored batch; optimistic drafts and failed appends never enter it. Repeated consumers do not revalidate/reorder the whole journal, and previously returned snapshots remain unchanged. Empty incoming history has no records to import and does not rebuild this snapshot; nonempty batches retain complete immutable-ID/prefix validation.

Here, **durable means confirmed by the local store contract**. It does not mean another device received the edit. Remote checkpoint/ACK evidence is covered in [Synchronization](synchronization.md).

A local edit follows this sequence:

1. Validate/create an unproven draft and merge it into the optimistic document immediately. Its ID, author, payload/kind/subject, logical clock, and actual UTC creation instant are already fixed.
2. Immediately invoke `store.appendAuthoredHistory` with the **ordered complete outstanding local backlog**, not just the newest draft. Inputs are detached before waiting for storage.
3. Inside the store's journal critical section, reread/validate persisted history, reuse exact stored same-core IDs, assign proofs to new drafts in supplied order, and append predecessor-first. Proof allocation and persistence share the same critical section; there is no sequence reservation before locking.
4. Receive the **full canonical persisted history**, including records committed by another tab. Validate it, finalize only owned drafts with matching cores, and import its complete durable prefixes before exposing additions to synchronization.
5. On failure, retain optimistic drafts and retry payloads, return no broadcastable result from that failed call, and show the saving error.

**Starting the API immediately is not synchronous durability.** Browser journal locking and native queueing are asynchronous; `localStorage.setItem` is synchronous only once the browser lock callback runs. The old guarantee that every edit reaches localStorage before its API invocation returns no longer applies. A saving indicator/error and an awaited `flush()` on controlled exit are required; tab closure is never a save mechanism.

A failed predecessor cannot be skipped by persisting a later dependent draft: each attempt includes the outstanding backlog, and writing stops at the failed prefix. A failed call may nevertheless have committed complete prefix records. Retry reuses their exact IDs and proofs, and later refresh can recognize them as durable. A proof calculated but never committed or published is not reserved: another tab may advance the journal before retry, so that draft can receive a different proof while keeping its entire core unchanged. Shared-actor tabs may interleave commits; they must still form one canonical nonforking prefix.

Incoming remote batches take the other route: `merge` checks the **whole batch**, including conflicts against pending/failed IDs, duplicates inside the batch, and combined durable predecessor/base closure, before starting any append. The store repeats combined validation under its writer lock/queue. Remote edits enter the document only after successful persistence. A conflict late in a batch cannot cause an earlier new edit to be written first. This validation/serialization guarantee is not all-or-nothing rollback after later I/O failure.

The session also derives effective roles, person bindings/releases, and its `durableTree` from durable history. An optimistic promotion must not grant commands, and an unsaved binding or release must not regroup visible participants. Participant aliases keep their ordinary optimistic LWW path. An empty alias falls back to the durable bound person's `name` without surname, then Anonymous; the separate `boundPersonFullName` tooltip value uses the durable person's effective birth surname plus name. An optimistic/failed tree-name or surname edit must not leak into that durable person fallback/full-name/avatar view.

Surname writes share the ordinary optimistic/atomic-authored/error/retry path. A failed append can already change the optimistic sibling group while `durableTree` and remote peers retain the saved value. Retry flushes the **same ID, configuration, clock/time, and frozen family key**, even if the editing representative has since changed parents; only an as-yet-uncommitted proof is allocated at storage. It does not create a replacement command aimed at the representative's new family; the session's stale-family check applies to newly submitted commands, not retries of an already accepted immutable core.

## Failures, retry, and explicit flush

A failed local append leaves the optimistic edit visible and retains its immutable payload in `_unsaved`. Another successful append or storage refresh does not erase that error while unsaved edits remain. A failed store flush is separately remembered, so an unrelated successful append/refresh cannot disguise it.

`RoomHistory.flush()`:

1. Retries the ordered local draft backlog through atomic authored append, resolving canonical proofs and any already stored prefix.
2. Retries unsaved incoming records through ordinary complete-prefix append, reusing in-flight writes where applicable.
3. Notifies the session when retry has made history durable, then awaits `store.flush()`.
4. Repeats if an edit started while an earlier append/flush was pending.
5. Clears recovered error state on success; throws and retains failure state if saving still fails.

It does not replace a history snapshot. The [room page](../../lib/ui/room_page.dart)'s room-switch and menu-exit paths await this flush before disposing the current session; a failed exit flush leaves the room open and reports the failure.

Disposal cancels watching and notifications, **not an append already started**. It is not a substitute for flush and does not make an unsuccessful in-memory draft survive a tab/process exit. An immediate tab close while awaiting the Web Lock, or an OS kill before queued native I/O completes, can lose an edit.

## Watching and refreshing shared history

`WebRoomStore.watchHistory` listens for browser `storage` events for that room's operation and separate Disk-credential keys. The stream is only a void reload signal; it supplies no journal or credential payload. Native and memory stores expose an empty watch stream.

For an existing member, `RoomHistory.load()` validates and imports stored history, subscribes, then schedules another read to close the read/subscribe gap. During saved-alias restoration the page can pass its already decoded store snapshot through the session as `initialHistory`, avoiding a duplicate initial read; the history still validates the complete author prefix and retains that gap-closing refresh. A displayed name prompt discards the earlier snapshot so accepting the prompt reloads current storage. A fresh member enables watching only when the session accepts it via `watchAcceptedHistory()`. Neither a watch event nor an already present record grants membership or confirms synchronization.

Signals are coalesced with a 35 ms timer: an ongoing burst does not continually postpone the same scheduled read. In a session, the refresh is enqueued on the **same `_messages` queue** as remote history handling, membership/admission work, and local-tab checkpoint verification. Standalone histories use their own refresh queue.

A refresh decodes and checks the whole stored history, immutable IDs/cores, and complete author-prefix closure before merging it. It finalizes matching owned drafts from canonical proofs, marks validated records durable, removes matching unsaved records, and reports newly durable additions through `onDurableEdits`; it does not reappend those records or replace a snapshot. The network-owning session can relay these additions, including edits written by sibling tabs. Missing predecessors, late unexpected legacy records after sealing, and load/watch/refresh errors remain visible rather than replacing the room with an empty writable model. See [Local tabs](local-tabs.md) for the additional proof required before inheriting a sibling's readiness.

## Browser storage: one value per operation

[WebRoomStore](../../lib/storage/web_room_store.dart) uses `localStorage` under `mytree.room-store.v1.`. `K(value)` below means unpadded base64url of UTF-8, implemented by `encodeStoreKey`:

| Key suffix | Value |
| --- | --- |
| `client-id` | JSON string containing the stable browser client/actor ID. |
| `last-room` | JSON string containing the restore target. |
| `room.K(roomId).membership` | JSON string containing that room ID. |
| `room.K(roomId).operation.K(editId)` | One canonical JSON operation object. |
| `room.K(roomId).disk-credentials` | Latest plaintext credential pointer retained for compatibility; never a journal operation. |
| `room.K(roomId).disk-credentials.binding.K(bindingId)` | Binding-scoped plaintext credential archive, preserving staged connects and final-detach retries. |

A short exclusive **per-room journal Web Lock**, `mytree.room-store.v1.journal.K(roomId)`, protects authored appends, incoming imports, and loads across store instances/tabs. It is shared by all actors writing that room and distinct from the identity lock and lifetime network-owner lock. Inside it, the store scans the room, checks the complete combined history, and writes only new operation keys in predecessor-first order. Authored appends allocate proofs there and return the full canonical history. This reads the journal on append but does **not rewrite** the full room or change old records.

Loading validates JSON, ID/key correspondence, and complete proof-bearing histories, then returns detached records in author-topological order. Storage enumeration order is not chronological. Cooperating readers wait for the same lock rather than observing another locked batch midway through its writes.

A `setItem` quota/security failure propagates. A batch can persist a valid prefix before a later write fails; retry deduplicates those exact completed records/proofs. There is no batch rollback, memory fallback, or claim that browser quota equals the protocol's size limit. Without secure Web Locks, **new authored writes fail visibly** rather than fork an actor sequence; incoming writes involving proofs are also refused. Legacy storage reads and all-legacy imports remain available, not a guarantee that the current editor can save new edits in that browser.

Client-ID creation uses a separate **origin-wide Web Lock** when secure Web Locks are available: reread, validate, generate if missing, and persist all happen inside that critical section, before per-room tab election. This prevents simultaneous cold starts in different room tabs from choosing different actors. The unsupported-browser path still writes synchronously, but does not claim cross-tab atomic identity creation. Malformed stored identities are errors, not a reason to invent a replacement identity.

## Native storage: queued JSONL

[FileRoomStore](../../lib/storage/file_room_store.dart) normally uses `<application-support>/mytree-room-store-v1/`:

```text
client-id.json
last-room.json
member-K(roomId).json
history-K(roomId).jsonl
disk-credentials-K(roomId).json
disk-credentials-K(roomId).binding.H(bindingId).json
```

For native credential archives, `H(bindingId)` is 64 lowercase SHA-256 hex characters of the UTF-8 binding ID; the payload retains and validates the exact original ID. This bounds filename-component length even for the maximum valid Unicode identity. Browser archive suffixes still use `K(bindingId)`.

Metadata files contain JSON strings. Small metadata updates flush a temporary `.tmp` file and rename it into place. History is UTF-8 JSON Lines: one canonical operation object followed by `\n`, with no history snapshot rewritten on each append.

Use **one store instance per storage directory**. Its reads and writes share a queue; reads observe writes already queued. Inputs are detached before joining that queue. An authored append rereads the journal and performs proof allocation plus predecessor-first persistence in **one queue item**, returning full canonical history; it does not reserve a proof before enqueueing. Ordinary imports validate the complete combined prefix before writing. Completed records are flushed before success, with cache updates reflecting completed writes. A failure invalidates the cache and reaches that operation's caller but is absorbed by the queue tail so later reads/retries can still run. This in-process queue is not a cross-process filesystem lock.

A failed append invalidates the cached room history because disk may contain only part of the batch. The next read/retry deduplicates complete records and handles the final tail as follows:

| File condition | Recovery behavior |
| --- | --- |
| Complete valid final operation, missing only `\n` | Keep it and append/flush the missing newline. |
| Invalid JSON or invalid UTF-8 in the unterminated EOF tail | Truncate to the last complete line, flush, and **throw a recovery error** identifying removed bytes. Retry can then load intact edits. |
| Invalid complete line, valid JSON with an invalid storage record (not an object or no nonempty string ID), or conflicting contents for one ID | Report corruption; do not silently erase it. |

`FileRoomStore.flush()` waits for the queue as it currently stands. It does **not** replay errors from writes that already failed; callers must observe individual write futures. `RoomHistory` supplies the higher-level retained-error and retry behavior.

## Separate local Disk credentials

`RoomStore.loadDiskCredentials(roomId, {bindingId})` returns a detached `Map<String, dynamic>?`; `saveDiskCredentials(roomId, value, {bindingId})` snapshots its input before asynchronous work. The exact object shape is `{v: 1, bindingId: String, token: String}`: version 1, a valid room actor/edit ID, and a token of 1–4096 printable ASCII characters (`0x21`–`0x7e`, without spaces). These APIs require a canonical application room ID (32 lowercase hex characters), independently of the older generic history API's opaque nonempty-ID contract. An optional binding selector must be a valid actor/edit ID and must match any nonnull payload. Missing credentials return null; malformed JSON/schema, duplicate keys, and persistence failures throw without including secret data in diagnostics.

A scoped read checks that binding's archive first, falling back only to a matching legacy latest value. An unscoped read preserves the latest-value compatibility API. A nonnull save writes the payload's binding archive **before** replacing the latest pointer; an older latest-only credential is archived before replacement. A pointer-write failure remains visible without destroying another staged binding's credential. Browser replacement happens in a synchronous storage task; native operations use the shared queue and flushed temporary-file/rename pattern. This is recoverable archive-first ordering, not a transaction spanning every credential file/value.

Credentials may be staged before their connect edit exists, using the optional validated `RoomDocument.createEdit(..., id: bindingId)` ID. Binding-scoped archives preserve competing staged connects and old credentials needed for final-detach retries even if another binding becomes latest. [RoomDiskRetirements](../../lib/cloud/room_disk_retirements.dart) reconstructs an independent old-binding queue from historical detaches and these scoped archives; replacing the active binding does not discard that queue or authorize clearing another binding's credentials. Storage does not infer the active binding or automatically remove stale credentials. The base store throws `UnsupportedError` instead of silently holding an ephemeral token. `MemoryRoomStore` explicitly supports detached in-memory snapshots for tests.

Saving null **with** a binding selector removes only that archive and a matching latest pointer; null **without** a selector clears every credential archive/pointer for that room, including native interrupted temporary files. Neither operation removes membership, last room, journal, or tree. Credential keys/files are separate from journal keys, and old latest-only records remain readable without a journal migration. Browser `watchHistory` includes pointer/archive changes but emits only void reload signals. Cloud coordination and final-detach retention are documented in [Yandex Disk](yandex-disk.md).

All credentials have the same plain-JSON/local-origin or filesystem protection as current app storage, **not encryption or OS secret-vault guarantees**. They are never returned by `loadHistory`, projected into ordinary room records, or included in tree exports.

## Membership and storage identity

Both persistent stores write membership **before** updating `last-room`. A failure updating the latter may leave valid membership saved; the reverse ordering is forbidden. Reading a last-room reference without corresponding membership is an error. Missing data on first use is normal; malformed existing data is not silently treated as an empty room. Leaving the UI does not delete membership or clear the last room.

The stored client ID becomes the session's `actorId` and edit author. It is local storage identity, not an account login or tree person identity. A durable `bindActor` tree operation can associate several different actors with one person; only editor actors use active claims for visible participant grouping/name/avatar. An own `unbindActor` releases only its exact claim, leaving the other grouped actors and historical authors unchanged. Legacy guest claims remain persisted but are inactive until durable promotion, rather than being deleted or rewritten. Neither binding nor release merges actor roles/membership or changes the room/actor scope of [local tab ownership](local-tabs.md). See [Rooms and identity](rooms-and-identity.md).

## Storage growth, photos, and limits

Photos are **persisted payloads**, not temporary references or separate blobs: `addPhoto` embeds a base64 data URL in the tree operation, which is encoded into `RoomEdit.text`. `TreeOperation` accepts JPEG, PNG, or WebP payloads up to 700 KiB decoded, checking base64 and format signatures. Those bytes therefore travel and persist with history.

[Room protocol](../../lib/room_protocol.dart) bounds a UTF-8 JSON transfer at **8 MiB**; it does not silently truncate oversized history. The session's local tree-append path estimates the size of **all known edits**, including pending/failed ones, plus the proposed operation, with 32 KiB envelope headroom. Atomic authored preparation checks the full resulting canonical JSON journal against that same budget after proof/base allocation, before writing new additions. This is not a browser-quota reservation or a retroactive size rule for generic legacy imports; actual transfer encoding still has its own envelope bound.

There is currently no journal compaction or garbage collection. Removing a photo/fact or deleting a person hides it in the tree projection through another operation; original operations, image payloads, and actor binding claims remain persisted. A failed person-deletion append can already hide the optimistic person, but only a successful store append enters `durableTree` and outbound history. Retry flushes the same tombstone operation ID rather than issuing a replacement. Browser quota can be exhausted before the exchange bound, especially with base64 photos and accumulated history. Local persistence is plain JSON, not encryption or proof of a cloud copy. The optional [Yandex Disk replica](yandex-disk.md) reads this same durable journal, unions immutable cloud batches through the existing validation/persistence boundary, and retains the 8 MiB/inline-photo limits. Local saving, WebRTC durability, and Disk read-back acknowledgment are separate facts. [Future storage and sync](../future-storage-and-sync.md) retains the remaining snapshot/attachment and other agreements, not a claim that all future formats are implemented.

## Code and tests to read

These suites are executable references for the contracts above. Dated run results belong in the [verification record](../verification.md):

- [room_document_test.dart](../../test/room_document_test.dart): proof schema/immutability, exact legacy baselines, closure/fork validation, ready-set ordering versus unchanged projections, and actual UTC draft timestamps.
- [room_history_test.dart](../../test/room_history_test.dart): immediate optimistic/API start versus queued durability, failed-predecessor backlogs, partial-prefix retry, concurrent same-actor histories, stable cores, whole-batch checks, error retention, flush, and refresh.
- [room_store_test.dart](../../test/room_store_test.dart): detached snapshots, canonical authored retries/full-history results, complete-prefix imports, native queue behavior, partial-tail recovery, and metadata failures.
- [web_room_store_test.dart](../../test/web_room_store_test.dart): browser identity and journal locks, shared-actor allocation, read/import serialization, partial-write retry, missing-lock failures, and tab boundaries. Browser execution is distinct from successful compilation; see [testing](testing.md#historical-drivers-and-browser-harness-caveat).
- [tree_room_session_test.dart](../../test/tree_room_session_test.dart): persisted tree/surname payloads, shared-register reload, frozen-family retry after parent changes, durable bindings/releases/full names, optional alias fallback, and visible person grouping.

Related: [Local tabs](local-tabs.md), [Synchronization](synchronization.md), and [UI](ui.md).
