# Synchronization

This page describes the local-journal/WebRTC protocol. The separate [Yandex Disk replica](yandex-disk.md) reuses the durable journal and author-proof validation, but not the WebRTC checkpoint as its cloud acknowledgment.
[Networking](networking.md) covers discovery and transport; see also [history and storage](history-and-storage.md),
[rooms and identity](rooms-and-identity.md), [local tabs](local-tabs.md), and [UI](ui.md).

## Responsibilities and wire envelope

[room_protocol.dart](../../lib/room_protocol.dart) validates messages, computes fingerprints, and fragments/reassembles JSON.
[RoomSession](../../lib/room_session.dart) owns admission, serialized incoming merges, per-channel sending, deadlines,
and initial readiness. [RoomHistory](../../lib/room_history.dart) distinguishes known/optimistic operations from durable ones.
Neither signaling registration nor a completed `send()` proves that another device has saved anything.

Application messages use a version-1 JSON object with required `v: 1`, `roomId`, `type`, `actor`, and `history` fields.
Room and version must match; an established channel cannot change its actor. `history` is always a list, even when empty.

| Type | Purpose / additional fields |
| --- | --- |
| `hello` | Payload-free capability offer; current sessions send empty history before negotiation. |
| `welcome` | Hub's response; requires `online` and `hosting`; may include `onlineActors`. |
| `edits` | Immutable history records, including missing backfill and ordinary durable additions. |
| `presence` | Empty history; `online`, `hosting`, optional `onlineActors`; also ordinary heartbeat traffic. |
| `inventory` | Empty history; ID-to-record-digest map for negotiated fast synchronization; optional `recheckId` requests a fresh in-place read. |
| `checkpoint` | Empty history; `syncId`, `syncDigest`, optional inventory identifying a fixed contribution; optional `recheckId` echoes that read's request. |
| `syncAck` | Empty history; matching `syncId`/`syncDigest` and required Boolean `roomReady`. |
| `diskCredentials` | Empty history; exact `diskBindingId` and `diskToken`, only over an eligible negotiated editor-to-editor RTC channel. Never ordinary journal relay or guest traffic. |

`online` is an integer from 1 to 100,000. An optional actor list contains at most 10,000 unique valid actors and must match
that count; a received hub list must include both the recipient and hub. Actors/edit IDs are nonempty strings of at most
128 characters. Histories are validated as a whole before appends: kinds/payloads, IDs, conflicting duplicates, and the
complete resulting author-prefix closure are checked against durable history. The decoder checks record/proof syntax;
complete-prefix validation belongs to the history/store boundary, not individual fragments or inventory subsets.
Clocks and timestamps must be nonnegative integers no greater than 9,007,199,254,740,991, preserving exact VM/JS values.
An optional `authorSequence` is positive in that exact range, with the predecessor/base contract documented in
[history and storage](history-and-storage.md#author-prefix-proofs-and-the-legacy-boundary).

## Digests and fast re-entry

`roomEditDigest` hashes UTF-8 JSON of a fixed-order array: ID, author, clock, creation time, text, non-text kind when present,
and target actor when present. Proof-bearing records append `[authorSequence, authorPrevious, authorBase]` as one array
component. Legacy records append nothing, preserving their original digest bytes and serialization. An inventory maps
every immutable ID to its lowercase 64-hex SHA-256 digest. `roomInventoryDigest` hashes sorted `[id, digest]` pairs; input
map order is irrelevant. The root covers **all** records and proofs: losing text versions, names, roles, and family-tree
operations, not just the currently visible projection. Record digests are weakly cached by immutable `RoomEdit` object identity, not edit ID: a new proof-bearing record or a conflicting same-ID record is hashed independently. This avoids repeatedly hashing large payloads without weakening conflict detection or retaining discarded records. The inventory/checkpoint/ACK message mechanism is unchanged.

`missingRoomEdits` validates every shared ID before returning a diff. Same ID/different content is an error, including a
collision with a pending or failed local append. Only durable records are transmitted. These hashes detect disagreement;
they are not signatures, participant authentication, or authorization.

A saved member offers `fastSync` with its full durable-history root but **empty hello history**. With negotiated
`authorHistory` (and in the production profile), a fast welcome also has empty history: a latest-text preview would omit
its required predecessors/base. A legacy-compatible direct session with no proof requirement can still send an old-style
single text preview to a peer lacking `authorHistory`; that exception is not the production tree-entry path.

Equal roots avoid inventories and bulk uploads. Different roots trigger reciprocal inventories after admission and `edits`
selected from missing durable records. Every outbound nonempty batch is expanded by `completeRoomAuthorHistory` to include
**all recursive author predecessors and sealed legacy-base records**, in predecessor-first order, including intervening
metadata/role/tree edits. A peer's inventory claim does not justify omitting those dependencies, so a diff can deliberately
resend already advertised records. The first received inventory is reciprocated even if an earlier handshake appeared
equal, covering writes completed during the exchange. Missing old/losing records are retained.

A fresh member never offers fast sync and rejects a fast welcome. It receives the hub's complete history before membership
is saved. A legacy fast preview may update the model early, but it never opens the editor or proves complete-history
readiness. Family-tree operations use the same complete journal, inventory, checkpoint, and transfer bounds as other records.

## Capability compatibility

Current clients advertise these extensions in `hello`/`welcome`; absence means unsupported, without changing `v: 1`.

| Capability | Contract |
| --- | --- |
| `fastSync` + `historyDigest` | Durable-root comparison and inventory/diff exchange; current author-aware handshakes omit text previews. |
| `durableSync` | Checkpoint/ACK protocol; new control types are never sent to peers lacking it. |
| `recheckSync` | Optional durable recheck on an admitted RTC channel; nonce-bearing inventory requests and checkpoint echoes. It grants no membership or semantic capability. |
| `roomMetadata` | Non-text operations such as participant names and room names. |
| `roomRoles` | Separate support for participant roles; metadata support alone is insufficient. |
| `familyTree` | Character-anchored tree text, people/relationships, and legacy `bindActor` participant/person claims. |
| `familySurnames` | Original `setSurname` schema support, including historical family/individual birth surnames and retained legacy maiden configurations. |
| `personalSurnames` | Per-person birth-surname commands; any individual register, including null clear, suppresses read-only historical shared-family fallback. Older surname-capable clients resolve clears differently. |
| `explicitSiblings` | Atomic new sibling creation, exact-claim unlink, component-wide parent set/clear, and deterministic retirement when both accepted parents become known. |
| `patronymics` | Computed patronymics and room-wide `setPatronymicOverride` dictionary entries, including explicit resets. |
| `lifeStatus` | Explicit living/unknown death mark, the `setValue` field `alive`. Older readers reject that field. |
| `marriageHistory` | Explicit and implied marriage episodes, per-partner surname choices, independent surname-history events, and pair suppression. |
| `authorHistory` | Per-actor sequence/predecessor/base proofs across all edit kinds, complete-prefix import, and proof-aware fingerprints. |
| `participantIdentity` | Explicit empty participant aliases and exact-claim `unbindActor` releases, allowing an editor to release and choose a person again. |
| `diskSync` | Public `diskConnection` journal operations and separate editor-only `diskCredentials` messages; no token in history or handshake payloads. |

`familySurnames`, `personalSurnames`, `explicitSiblings`, `patronymics`, `lifeStatus`, `marriageHistory`, `authorHistory`, `participantIdentity`, and `diskSync` are optional Boolean extensions, default false/omitted.
True is valid only on `hello`/`welcome`; current sessions advertise all nine on both handshakes. Non-Boolean values,
including explicit null, are invalid. They do not change wire version 1 or the inventory/checkpoint formats. The surname
and participant-identity capabilities alone change no edit fingerprint; author proofs extend only proof-bearing
fingerprints, leaving legacy bytes unchanged.

Before importing handshake history, the session rejects peers missing capabilities required by its profile, invitation,
or existing journal. The production `requireFamilyTree` profile requires **`familyTree`, `familySurnames`,
`personalSurnames`, `explicitSiblings`, `patronymics`, `marriageHistory`, `authorHistory`, and `participantIdentity`**, even for an empty room. A direct/legacy-compatible session also requires
both surname capabilities as soon as **any known** `setSurname` exists, author-history support for **any known proof-bearing edit**,
and participant-identity support for **any known empty `participantName` or `unbindActor`**. These checks include losing,
pending, and failed records, not just currently visible or durable winners. Pending entry-profile creation also requires
both author-history and participant-identity support before history/profile/membership import. Incompatibility is
reported with reload/update guidance; reload all open tabs on every device rather than assuming a blank room is compatible.

Incoming and outgoing operations are independently gated: `setSurname` requires both negotiated `familySurnames`
and `personalSurnames`; support for the original wire schema alone is insufficient. Proof-bearing history requires
`authorHistory` even when its payload is ordinary text or metadata, and blank aliases or `unbindActor` require
`participantIdentity`. An established legacy channel cannot silently continue after the room acquires a personal-surname,
explicit-sibling, patronymic, marriage/surname-history, author-proof, or participant-identity requirement. Any known `createSibling` or
`unlinkSibling`, including pending/failed operations or claims later retired, requires `explicitSiblings`.
Both new payloads and subsequent ordinary parent/history traffic are barred without that negotiated
capability; the same gate precedes handshake history import, profile writes, and membership. This changes
no room envelope version, fingerprint, storage schema, or checkpoint format. Unsupported records are rejected, not stripped of proof,
downgraded to text, interpreted as permanent old bindings, or dropped. An initial hello sends **no history payload**
before negotiation.

`marriageHistory` is required by the production tree profile even without explicit history: implied co-parent marriages
and current-name projections already have new semantics. A legacy-compatible direct session requires it as soon as
**any known** `addMarriage`, `setMarriageDates`, `setMarriageSurname`, `removeMarriage`, `addSurnameChange`,
`setSurnameChange`, or `removeSurnameChange` exists. Losing records, null date/choice resets, failed/pending drafts, and
removed episodes/events remain requirements. Both handshake directions reject missing support before any history/profile
or membership write; established inbound/outbound traffic is independently checked before import/send, including ordinary
history/control traffic after a new local requirement appears. Legacy test sessions without these operations retain their
previous text/tree compatibility.

These are person-scoped ordinary optimistic/durable tree commands. `RoomSession.addMarriage`, `updateMarriage`,
`setMarriageSurname`, `removeMarriage`, `addSurnameChange`, `updateSurnameChange`, and `removeSurnameChange` mirror the
[domain builders](tree-model.md) and require an editor through both typed and raw submission. An atomic `addMarriage`
can contain a `TreeNewMarriagePartner` snapshot; no separate orphan identity write is created. The session validates a live
initiator, unused new identities/items, and exact episode ownership/endpoints without recomputing frozen surname choices
or replacing the submitted immutable payload. Existing explicit episodes remain editable/removable by a live survivor
after the spouse is deleted; new marriages require an existing live identity or an unused atomic new partner. Date tuples
are one operation, and parallel date/choice submissions immediately observe earlier optimistic drafts. Save failure keeps
those exact records for `flush()` retry and never broadcasts unconfirmed drafts. All records reuse the existing complete
journal, Disk encoding, digests, inventory and checkpoint formats; wire version and storage envelope remain unchanged.

`lifeStatus` is advertised on every current hello/welcome but is **not** required for an empty room. Any known `setValue` whose field is `alive`, including a null clear and pending/failed writes, requires negotiated `lifeStatus` before handshake history import and on established channels. Later ordinary history cannot bypass that gate. A new hello remains payload-free. Older clients stay compatible until the journal contains that field.

Any known `setPatronymicOverride`, including losing overrides, pending/failed writes and resets with both forms null,
requires `patronymics`. The room requirement and every incoming/outgoing override are checked before handshake history
import and on established channels; later ordinary history/control traffic cannot bypass it. A new hello remains
payload-free. Older tree clients are rejected before membership/profile writes or history persistence rather than
silently losing the dictionary. `RoomSession.setPatronymicOverride(name, {required String? male, required String? female})`
and generic tree-operation submission are editor-only ordinary optimistic/durable journal commands. They require neither
a root nor any visible person: the room-scoped payload has no `personId`, uses a trim/lowercase/ё→е normalized `name`,
and contains both `male`/`female` strings or both null for an LWW reset. Computed person patronymics are projections, not
additional journal writes. The operation uses existing full-history WebRTC/Disk encoding without a storage-envelope,
fingerprint, wire-version, or checkpoint-format change.

Any known `diskConnection` record, including pending/failed or historical detached bindings, requires negotiated `diskSync` before history import and on established channels. Public connection metadata travels through the ordinary complete journal; tokens do not. `diskCredentials` remains the normal separate empty-history, exact-binding message restricted to explicit durable editors. Only a live, ready, durably guest host enables the additional [DiskCredentialExchange](../../lib/cloud/disk_credential_exchange.dart) fallback, whose private bounded `diskHello` / `diskAccess` protocol connects editors directly; it does not replace ordinary negotiated credential messages. The [Disk subsystem](yandex-disk.md#credentials-and-the-trust-boundary) owns the credential and cloud-acknowledgment contract; capability negotiation alone is neither a role grant nor access to a token.

Legacy-compatible direct sessions with all-legacy history can still exercise text exchange/preview, but a peer without
`durableSync` cannot establish initial readiness. A legacy non-fast welcome gets a full compatible durable local upload;
old text and tree records remain readable without migration. See [surname replay](tree-model.md#canonical-surnames) and
[the known legacy-baseline limit](history-and-storage.md#author-prefix-proofs-and-the-legacy-boundary).

## Saving before admission and acknowledgment

An ordinary fresh WebRTC join follows this order in `_handleMessage`:

1. Require an actually open outbound channel to `mytree-room-<roomId>` and a valid welcome with `hosting: true`.
2. Validate envelope, identity, capabilities, and the complete incoming history; merge it durably.
3. Save/flush the entry name and invitation role, if needed. An existing durable role wins over a newly opened invitation.
4. Recheck that the channel/session is still admissible, then persist membership. Only then set `joined` and watch storage.
5. Freeze/save the local checkpoint contribution and exchange the negotiated durability proof.

The hub likewise validates and saves any hello history before sending welcome or relaying additions; current hellos are
empty. Incoming merges, membership writes, and storage refreshes share the session's message queue. Whole combined prefix
validation occurs before persistence, and the store repeats it inside its journal lock/queue. Missing predecessors, forks,
or a late same-author legacy record outside a sealed base cannot be persisted as an accepted batch or checkpoint-ACKed.
Local drafts display and invoke authoring immediately, but proof allocation/durability await the writer critical section.
No failed/pending draft is broadcast or acknowledged. Save errors remain visible; `flush()` can throw. Membership is not
the final loading barrier: a durably admitted member may still be awaiting full checkpoint confirmation.

`_prepareCheckpoint` freezes the logical `knownEdits` **IDs and immutable cores** at admission, including already-started
writes, then calls `flush()` and resolves them against canonical durable records/proofs plus their predecessor/base closure.
It never fingerprints provisional unproven JSON as if it were the saved contribution. Another tab's required preceding
commits can enter that closure; later typing is ordinary durable broadcast, not an ever-moving logical cutoff.
A received checkpoint resolves to its explicit inventory, a matching prior inventory, or a retained equal-root snapshot.
The session sets `remoteImported` only when every expected ID/digest exists in its validated complete durable journal.
`_ackCheckpoint` then acknowledges that exact token/root. Stale ACKs cannot satisfy a superseding checkpoint;
`roomReady: false` can acknowledge saving while the hub's other initial imports are unfinished. A successful transport
write is never an ACK.

A binding-scoped [Disk invitation](yandex-disk.md) provides a separate initial-entry source. The session reads and validates the bounded cloud snapshot together with any durable local history, including batch hashes, exact room/binding identity, immutable records, complete author prefixes, the current binding, and its owner's explicit editor role. HTTP runs outside the message queue; the durable commit revalidates against the latest local union inside it. Accepted members start RTC in parallel and may finish loading through its unchanged checkpoint barrier while Disk is pending; solo discovery is not a substitute for that pending cloud check. Fresh members still attempt Disk admission before starting ordinary RTC. Cloud writes remain disabled until the entry attempt finishes. The session durably saves history, the entry profile and matching private/public access before membership. Existing durable participant roles win over the invitation. Failure never admits an empty room; the ordinary live-member path remains available.

Successful Disk entry opens the saved document with a distinct source status: history loaded from Disk, online reconciliation continuing. It creates no welcome, peer checkpoint, ACK, online participant, or discovery/solo evidence. A cloud snapshot is not proof that every offline editor has uploaded their latest changes. Subsequent RTC exchanges still use the unmodified capability, checkpoint, and cohort contracts below; guest periodic cloud reads do not acknowledge their own local metadata as cloud-saved.

## Finite initial cohort and solo evidence

The follower completes entry after importing the hub checkpoint and receiving its own matching ACK with `roomReady: true`.
The hub waits for the initial cohort's durable imports, its frozen local contribution to be saved, and a one-second quiet
interval. It can then send a final fixed checkpoint including other cohort members' imports, with missing records and an
inventory when the root changed. Its own completion additionally requires the cohort to ACK the local/final checkpoints.

A valid hello awaiting storage and a real bounded assembly count as initial contributions. Blank alternative-provider
channels do not hold an otherwise real cohort for their entire handshake timeout; with no admitted contribution, pending
transports still prevent claiming solo. A failed admitted round preserves evidence against absence for that entry attempt;
an actually opened outbound channel is also evidence even if it closes after hello but before welcome. A clean later
live cohort can complete. Connections are not merged or discarded merely because their actors match.

With no live peer, a restored room needs validated alias registration and complete discovery coverage from every configured
provider, durable local data, and the quiet interval. `onlineCount == 1`, a timeout, or a partially unavailable provider is
**not** proof of absence. Custom peers without `SignalingDiscovery` use validated registration as their weaker coverage
boundary. A newly created, saved, random, never-shared room is the explicit solo exception; restored membership is not.
A real durable peer exchange can complete despite another provider's outage. This is a finite entry barrier, not a room
census, distributed consensus, or proof that no partitioned/offline device has additional history.

## Bounded transfers and deadlines

These are current codec/session constants, not performance guarantees. Sizes refer to UTF-8 JSON, not Dart string length.

| Bound | Current value |
| --- | --- |
| Whole encoded message / receive transfer | 8 MiB (8,388,608 bytes), including the envelope |
| Unfragmented outgoing message | At most 12,000 bytes |
| Fragment payload | 8,000 raw bytes, base64 encoded; final fragment may be shorter |
| Incoming fragment metadata | Exact count/decoded lengths; base64 string at most 11,000 characters |
| Assemblies | One in-flight assembly per channel |

Chunks carry version, room, actor, transfer ID, index, count, total bytes, and data. Out-of-order chunks are accepted;
identical duplicates are ignored without renewing liveness. Changed duplicates, mixed transfers/actors, or invalid sizes
fail the channel. Final bytes must be strict UTF-8 JSON and the inner room/version/actor/history are validated again.
Encoding rejects oversize data before sending and generates fragments lazily; it never silently truncates the journal.

| Session deadline / interval | Current value and scope |
| --- | --- |
| Initial verification; fresh join | 30 s; fresh admission also has an overall network join cap |
| Logical signaling registration | 8 s |
| Channel hello/welcome admission | 12 s from attachment |
| Incomplete checkpoint round | 12 s; presence and repeated checkpoint packets do not renew it |
| Real assembly | Fixed 25 s from its first accepted fragment, replacing handshake wait |
| Incomplete checkpoint assembly allowance | Fixed 25 s across transfers in that unfinished round |
| Receive liveness / ordinary presence | 20 s silence / heartbeat every 5 s; silence revokes online evidence |
| Connectivity polling / disconnected ICE grace | Every 1 s / 5 s; failed or closed is terminal |
| Packet send | 5 s watchdog per packet, on the channel's serialized send queue |
| Established recheck-capable channel | The 5/12/20/25 s watchdogs are soft while native RTC remains usable; new admission retains its hard bounds |
| Stalled established recheck | 90 s of uninterrupted foreground execution; hidden/execution gaps restart the active window |

Accepted new fragments renew liveness, not the fixed assembly cap. A fresh join's overall 30 seconds remains in force.
A final superseding hub checkpoint starts a new bounded ACK round. Completing a round cancels its checkpoint timers.

## Recovery and truthful UI

Browser visibility/resume/pageshow events, Flutter lifecycle events and an online hint returning can request a
connectivity check. Elapsed hidden time (including an ordinary long Alt+Tab) is not suspension evidence: it uses the
nondestructive 200 ms / six-second receive-progress probe while retaining readiness and healthy channels. Flutter's
transient `inactive` state is not backgrounding. A session-wide five-second execution tick, including for local followers
and Disk-only copies, detects an actual wall-clock execution gap over 20 seconds independently of network heartbeats.

A real execution gap, observed loss of the last verified connection/network during backgrounding, or a failed last-peer
receive probe qualifies for fresh verification. It immediately clears an already-confirmed accepted copy's readiness and
shows loading, but keeps admitted usable RTC channels, their ordered sends, decoders and transport generation. With
negotiated `recheckSync` and `durableSync`, each channel gets a new local checkpoint token and independent `recheckId`:

1. Invalidate the whole old cohort's proof before any queued flush; freeze and durably resolve each new finite contribution.
2. Send its full inventory tagged with the fresh request nonce, plus its new ordinary checkpoint.
3. The receiver flushes and snapshots its current complete history, replies with an inventory/diff and a separate full
   checkpoint echoing that nonce. This response token does not replace its own tracked checkpoint in a simultaneous recheck.
4. Require both durable containment of the nonce-correlated response inventory and a matching ACK for the current tracked
   checkpoint. Old or unrelated echoes, ordinary presence, equal old roots and old ACK flags cannot release this barrier.

Repeated requests reuse the same nonce and fixed response snapshot without rotating tokens or starting reciprocal rounds.
A genuinely new execution suspension supersedes a pending attempt and its nonce; duplicate foreground/online hints do not
reset the fixed 30-second readiness budget. A serial-queue revision guard rejects a flush result from a superseded round.
Freshly admitted non-fast peers can recheck too. Peers without the optional capability retain reconnect-based verification.

After the coalesced 200 ms delay, missing/broken channels use normal discovery and matching Disk access starts a bounded
validated entry read, in parallel with retained RTC. Solo discovery is not a substitute for fresh durable peer proof or a
freshly validated and persisted Disk snapshot. An admitted cohort can recheck while public signaling is unavailable;
initial admission and solo inference still require their ordinary registration/discovery evidence.

Short connectivity hints during an unfinished entry or an explicitly opened local copy retain the conservative probe
path: terminal/dead channels drop immediately; admitted settled channels receive a presence probe and six seconds for
**received** heartbeat traffic. Connecting channels, a hello still saving, pending checkpoints and assemblies keep their
normal deadlines. A newly arriving handshake likewise prevents premature re-election.

For a previously established recheck-capable channel, missing packets or a soft send/checkpoint/assembly/ICE-disconnected
watchdog revoke positive online evidence and request verification, not immediate disposal. A native failed/closed channel,
real send error, integrity failure or unsupported old client still follows its appropriate failure path. A permanently
stalled recheck is replaced only after a 90-second foreground window without completion; hidden time and delayed execution
do not count. Ordinary heartbeats cannot indefinitely extend a blocked send/recheck. A soft send timeout never releases
the serialized queue ahead of the still-pending native send, preventing interleaved chunk transfers. An offline actor is
removed from other peers' rosters while its own directed heartbeat still names it, so waking does not violate roster checks.
Browsers/OSes can still freeze/discard pages or close native RTC; this policy cannot guarantee indefinite background survival.

With no remaining channels, recovery can bypass backoff and restart normal alias election. A nonfailed registration younger
than eight seconds is preserved. Ordinary reconnect delay is `min(8000, 400 * 2^min(attempt, 4)) + random(0..699)` ms;
a wake restart resets its attempt count. Generation/channel-identity guards ignore stale callbacks, sends, and ACKs;
retirement cancels timers/subscriptions and decoder state. A resumed local follower requests a correlated fresh proof from
its network owner instead of opening sockets or accepting the owner's cached ready state; its durable inventory still
must verify locally. Recovery preserves membership, the journal and an explicit local-copy choice. A confirmed copy
returns to loading only for a qualifying wake, not for each ordinary incoming edit. Timeout/errors retain Retry and the
explicit accepted-local-copy escape without claiming successful synchronization.

During initial entry, losing an admitted channel is not itself an immediate terminal verification error: the existing
backoff schedules a fresh transport on either side, including a hub that loses its last incoming initial participant.
Automatic peer generations retain the original 30-second verification deadline and evidence of the failed contribution;
they never call the explicit-retry reset path. Repeated recovery therefore cannot extend the loading period indefinitely
or reinterpret a failed exchange as successful solo discovery. Admission-started/capability-rejected and malformed
protocol/encoding failures, including a failed pre-admission history save, also block solo completion; blank losing incoming
provider hedges remain excluded from that evidence. Explicit capability, integrity, and storage failures retain the first
reported diagnosis rather than becoming generic transient loading.

If the fixed deadline expires, the failure/retry/local-copy UI remains truthful while ordinary background reconnection can
continue with capped backoff. Only a later complete durable checkpoint/ACK exchange can establish readiness and clear
that entry failure. No timer, socket, channel reopen, or online hint implicitly opens a local copy or validates history.

[RoomPage](../../lib/ui/room_page.dart) shows the editor only after completion or an explicit accepted-local-copy action.
That action is labeled synchronization-unconfirmed and leaves discovery/backfill running; it cannot admit a fresh device.
Connectivity/presence indicators are separate from local saving, checkpoint readiness, and the optional Disk copy. Disk has its own status/error in the room page and settings; its confirmed-copy state comes from the [cloud round's read-back evidence](yandex-disk.md#acknowledgment-and-failures), not a WebRTC checkpoint.

## Source and regression map

- [Protocol tests](../../test/room_protocol_test.dart): proof-aware digests with unchanged legacy fingerprints, handshake-only surname/patronymic/marriage-history/author/participant-identity capabilities, strict optional recheck capability/nonces and fragmented round trips, recursive author closure, immutable IDs, bounds, Unicode, malformed chunks.
- [Session tests](../../test/room_session_test.dart): empty capability offers/current fast welcomes, author/patronymic/marriage-history gates on empty production rooms and legacy channels, closure before persistence/ACK, frozen-core checkpoint resolution, same-actor tab relay, admission, finite cohorts, solo/partial outages, ACK timers, one-sided/crossed nonce rechecks, queued inventory and native-send races, active-only stalled recovery, and wake without RTC replacement.
- [Tree session tests](../../test/tree_room_session_test.dart) and [role tests](../../test/room_roles_test.dart): payload compatibility and durable admission, participant-identity gates before import and on established legacy channels, marriage/surname-history guest permissions, atomic new partners, implied materialization/suppression/re-entry and durable replay/reload, frozen-core retry and bidirectional capability gates; room dictionary permissions without visible people, durable dictionary exchange/concurrent reset/shuffled replay/reload and bidirectional patronymic gates, independent per-person surname convergence/reload, legacy history preservation without opening migration, person-target retry, and bidirectional wire/semantic surname capability gates.
- [History tests](../../test/room_history_test.dart), [page tests](../../test/room_page_test.dart), and the historical [headless recovery driver](../../tool/check_room_resume.cjs). The latter targets the old text-demo UI; see [testing](testing.md#historical-drivers-and-browser-harness-caveat) before reusing it.

[Yandex Disk](yandex-disk.md) documents the implemented optional cloud replica. [Future storage and synchronization](../future-storage-and-sync.md) remains the broader agreement for snapshots, separate attachments, and future formats. Current WebRTC checkpoints are wire durability proofs, not cloud acknowledgments or stored snapshots.
