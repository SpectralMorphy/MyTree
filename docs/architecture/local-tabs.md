# Same-origin tabs and network ownership

Accepted browser tabs can share one room/actor network owner while each keeps its own UI and `RoomSession`. The shared journal remains the source of edit data. Tab coordination is a lifecycle and verification mechanism, **not membership, another database, or a second synchronization transport**.

Implementation boundaries:

- [RoomTabs and RoomTabState](../../lib/local/room_tabs.dart): narrow lifecycle interface and validated immutable checkpoint format.
- [Browser coordinator](../../lib/local/room_tabs_web.dart): Web Locks ownership and BroadcastChannel control messages.
- [Native stub](../../lib/local/room_tabs_stub.dart): no coordinator; conventional independent networking.
- [RoomSession](../../lib/room_session.dart): activates coordination, retires/starts networking, verifies durable inventories, and derives UI readiness/presence.
- [RoomHistory](../../lib/room_history.dart) and [WebRoomStore](../../lib/storage/web_room_store.dart): persist edits and refresh sibling writes. See [History and storage](history-and-storage.md).

## Scope: origin, room, and actor

The browser uses the same name for its exclusive Web Lock and BroadcastChannel:

```text
mytree.room-tabs.v1.<JSON encoding of [roomId, actorId]>
```

Web Locks and BroadcastChannel supply the browser origin boundary. Within that boundary, different rooms or different actors have different ownership scopes. This local leader is distinct from the network room's elected rendezvous host: a local owner can be a network host **or** a network follower.

The default [room-page wiring](../../lib/ui/room_page.dart) creates a coordinator only when `store.sharedAcrossTabs` is true. `WebRoomStore` opts in; native and memory/custom stores do not opt in by default. Sharing a factory name or having the same actor string is not enough when the actual durable data is not shared.

The stored browser client ID becomes `actorId`. Web storage settles its creation under a separate origin-wide identity lock before per-room ownership, so simultaneous cold starts need not create separate actors. A third, short **per-room journal lock**, `mytree.room-store.v1.journal.<encoded roomId>`, serializes authored allocation, incoming imports, and loads across store instances/tabs. It covers every actor in that stored room and is not held for a session's lifetime. The lifetime room/actor network-owner lock does not serialize edits by itself: a follower can author through shared storage while the owner networks.

A per-runtime `_tabId`, a leadership `term`, the Web Lock's browser `clientId`/owner, and the per-actor `authorSequence` are **different identifiers** with different jobs; none replaces the persisted actor ID. See [journal storage](history-and-storage.md#browser-storage-one-value-per-operation) for the critical-section and failure contract.

A tree `bindActor` operation can associate several editor actors with one visible person; an immutable `unbindActor` can release an actor's exact claim. The session groups active editor bindings in its participant list and `otherOnlineCount`, using an explicit actor alias or the durable person's name without surname, plus that person's avatar. Self groups use this actor's alias; other groups choose a nonempty alias by actor ID. It does not merge storage identities, edit authors/sequences, per-actor roles, memberships, or network-owner lock scopes. Same-actor tabs do share one author prefix across **all** operation kinds; actors bound to the same person do not. `onlineCount` still counts actor identities, not visible person groups or tabs. See [Rooms and identity](rooms-and-identity.md).

## Election uses a held lock, not a lease

Startup registers the channel listener before requesting ownership:

1. Request an exclusive Web Lock with `ifAvailable: true`.
2. If granted, query the held-lock inventory, obtain its observable owner, generate a fresh term, and announce leadership.
3. If unavailable, become a local follower, enqueue an ordinary exclusive request with an `AbortController`, and request the current owner's checkpoint.
4. Keep the granted lock callback's promise pending for the owner's lifetime. Startup waits for a separate role-decision future, not the lock's eventual release.

Only the owner runs the normal room networking after this decision; a follower retires its own peer/channels and requests local state instead. `_networkOwner` checks both the session's role and `roomTabs.isLeader`, guarding networking/publishing even before a queued role callback has run. A new local owner resets inherited proof and runs the ordinary remote entry checks; stored edits and membership are retained.

There is **no heartbeat lease, timeout-based takeover, `steal`, or visibility-based release** in this coordinator. Hiding or suspending the owner does not make a visible follower steal its lock. `RoomSession.setForeground(false)` records a background timestamp. A qualifying resume of a confirmed follower requests a correlated live recheck from its owner; the owner starts a new verification round instead of returning cached readiness. Visibility alone proves neither a live peer nor completed synchronization. A suspended owner can still delay followers until it resumes or its lock is actually released; the code does not promise immediate visible-tab failover.

Disposing a queued follower aborts its pending request. A tab disposed during startup cannot later become an active owner.

## BroadcastChannel carries checkpoints, not edits

`RoomTabState` contains:

- room and actor IDs;
- online count, explicit network availability, and an optional actor roster;
- initial-sync readiness, the distinct local-copy flag, and status/error strings;
- an **immutable inventory** mapping edit IDs to SHA-256 content digests;
- optional `completedResyncs`, at most 64 unique live-recheck request IDs, validated separately from readiness.

There is no history array, editor text, participant-name map, tree payload, or photo body in the checkpoint. The digest implementation in [room_protocol.dart](../../lib/room_protocol.dart) uses a fixed field order over the edit envelope, including non-text kind, role subject, and author proof when present. Legacy digest bytes are unchanged. Equal IDs with different payloads or proofs are not considered synchronized.

The checkpoint does not negotiate semantic capabilities such as `personalSurnames` or `explicitSiblings`. Equal inventories do not prove that an older owner tab and a newer follower interpret those records identically; the remote handshake cannot protect tabs sharing that local owner. After an application update, **reload all open tabs on every device**. Mixed-version same-origin tabs are not covered by the remote capability gate.

The state decoder checks the version, room/actor identifiers, booleans, bounded strings/counts, digest syntax, and roster consistency. When a roster is present and networking is available, its unique actors must match the count and include the local actor; an offline roster must be empty. Missing `networkAvailable` defaults to false for older states. Browser control messages are bounded to **8 MiB of UTF-8 JSON**; state publication leaves room for the enclosing control message. This is a control-message limit, not a localStorage quota guarantee.

The actual edit path is storage-first:

```text
Follower gesture -> immediate optimistic draft with fixed ID/payload/clock/time
Short journal lock -> canonical proof allocation + predecessor-first shared-store append
Owner storage refresh -> validated durable prefix -> ordinary remote exchange
Sibling storage refresh -> its own validated projection
```

Every authored attempt supplies the tab's ordered outstanding backlog. The locked store rereads persisted history, reuses already committed IDs/proofs, and returns full canonical history, including other tabs' predecessors. Concurrent tabs sharing an actor therefore extend one prefix without changing their optimistic cores; commits from those tabs can interleave. A failed predecessor cannot be skipped by a later dependent draft. Network batches include recursive predecessor/base closure even if an inventory already claims those records.

A BroadcastChannel message never supplies a draft to be appended. The append API starts immediately, but waiting for the journal lock is asynchronous; it does not guarantee a localStorage write before returning. Saving/errors must remain visible, and controlled exit must await flush. Neither tab closure nor network-owner handover saves an uncommitted draft. A follower's successful append does not itself prove that the owner has relayed it or that a remote peer saved it.

## Owner, term, and request guards

The browser coordinator does not accept a ready snapshot just because it arrived on the correct channel:

1. An owner announces `leader`, or advertises `changed` after caching a new checkpoint. The latter is only a change notification, not an unsolicited ready snapshot.
2. An unknown follower sends `discover`; it selects an announced term/owner only after `navigator.locks.query()` confirms that owner currently holds the scoped exclusive lock.
3. It sends a **fresh directed request** for that term, carrying its tab ID and a new request ID. A discovery reply itself cannot satisfy entry readiness.
4. The owner returns its cached `state`, addressed to that tab and request, with the term and owner attached.
5. Before delivery, the follower checks the destination, outstanding request, selected/requested term, state scope/schema, and the actual held owner again.

Control revisions invalidate asynchronous owner queries that have been superseded. `bye` for the selected term/owner clears the selection and inherited transient proof. Stale replies for a previous owner, another tab's request, or an earlier term are ignored.

There is another guard at the session layer: `_tabTerm` increments on role changes, and verification captures it before awaiting storage. The session rechecks follower status, the term counter, the exact current state object, disposal, and history errors after the read. An old owner's checkpoint cannot complete a pending storage verification across a handoff.

These are same-origin lifecycle/staleness checks, not cryptographic authorization against arbitrary same-origin code.

## Durable inventory verification before entry

An owner-issued `RoomTabState` is still only a claim until the receiving session checks its own durable journal:

1. Receive the scoped state and schedule one coalesced 35 ms verification task.
2. Enqueue that task on `_messages`, the same queue used for incoming remote messages, admission work, and watched storage refreshes.
3. Refresh history from `RoomStore`; decode it, check immutable IDs/cores, and validate complete author predecessors and sealed legacy bases before accepting it as durable. Do not import journal contents from the beacon.
4. Require accepted membership, loaded history, no current history/storage error, and an unchanged current term/state.
5. Require **every advertised `(edit ID, digest)`** to exist identically in the local durable inventory. Extra local durable edits are allowed; matching only the visible LWW winner or history length is insufficient.
6. Only then store `_verifiedTabState` and inherit the checkpoint's positive readiness/status evidence.

Local drafts, failed appends, and flush errors cannot be masked by a successful owner checkpoint. A missing losing edit, participant-name update, role, or tree operation can block verification even when the displayed document looks correct. Durable additions can recheck the current checkpoint; ordinary `onChanged` notifications do not recursively trigger reload/publish loops. Inventory calculation is cached by durable journal length, relying on immutable append-only contents.

### Membership is a separate prerequisite

An unaccepted fresh session does not enter local election or watch/admit itself from a sibling beacon. Ordinary online entry first validates the live-channel welcome, persists its history/profile, and saves membership under the session's admission guard; its full initial readiness additionally requires the durable checkpoint/ACK exchange described in [Synchronization](synchronization.md). A [Disk-enabled invitation](yandex-disk.md#offline-capable-invitations-publication-and-admission) is a separate source: bounded validated history/profile/access must be durable before membership and local coordination can start. A Disk-read readiness flag is not a peer checkpoint or a beacon's authority to admit a sibling.

When that fresh session completes normal entry, it can activate local coordination while retaining its verified network if it wins; if it loses, it retires that network. An accepted session can also explicitly open a local copy, which activates coordination without claiming verified synchronization. Neither path lets a beacon create membership.

The [room-page UI](../../lib/ui/room_page.dart) opens the room body only for `joined && (initialSyncComplete || localCopyOpened)`. `localCopyOpened` is an explicit unconfirmed-local-copy mode, not a successful sync result. For a local follower, ordinary confirmed entry therefore depends on the durable inventory proof above, not on receipt of `state` alone. See [UI](ui.md).

### Current entry proof versus an older UI latch

The owner's published `initialSyncComplete` comes from `_currentTabEntryReady`, not merely its already-latched UI flag. It reflects the current remote checkpoint/cohort barrier; a newly opened sibling cannot inherit old success while another initial contribution is still being imported. A freshly created, never-shared room has the session's separate explicit solo proof; a validated, persisted Disk entry retains its distinct Disk-source readiness.

Once an existing follower has completed entry, ordinary same-term snapshots do not clear that UI readiness latch. A new local role/term or explicit retry resets the attempt; coordination errors clear inherited readiness/local-copy proof but do not erase saved membership. A follower retry requests its owner's state rather than starting another peer.

A qualifying wake is stricter: optional `RoomTabsResync` sends a fresh request ID to the currently selected owner/term, preserving it across owner discovery. The adapter validates bounded IDs, deduplicates at most 64 requests and never answers a `resync` with cached readiness. The owner coalesces requests into a new durable verification round and publishes completed IDs only after fresh peer proof or a freshly verified Disk read. The resumed follower ignores ready/local-copy snapshots lacking its matching completion ID, and still verifies the advertised inventory against shared durable storage. Old-owner/wrong-request responses cannot release loading; timeout leaves an explicit local-copy escape rather than new sockets or lock stealing.

## Presence: revocation is faster than promotion

The session keeps the newest received state separately from the last durable-verified state. This permits conservative negative updates without treating an unverified newer journal as positive evidence:

- A newest state with `networkAvailable: false` makes the follower report no network immediately, before its scheduled disk verification. The browser's own offline hint also gates availability.
- With a current roster, visible online actors are the **intersection** of the last verified roster and the newest roster. Removed actors disappear immediately; newly advertised actors need verified checkpoint evidence before joining the set.
- Positive inherited connectivity/count/roster evidence comes from `_verifiedTabState`, not an unverified beacon. The latest state can restrict that evidence; it cannot introduce an unverified actor. Already verified evidence can remain while a newer checkpoint is pending.

Thus a failed local append or missing owner operation does not leave a newly revoked actor falsely online, and receiving new names/status text over the bus cannot manufacture a durable participant record. This presence logic does not turn `networkAvailable` into an Internet/cloud health check or a per-edit remote-save acknowledgment.

## Retirement before lock release

The session, rather than the lock adapter alone, owns transport shutdown ordering:

1. Mark the session disposed; invalidate tab verification and cancel timers/subscriptions/history watching.
2. `_retirePeer()` increments the network generation, detaches peer/connections, clears state, and queues their disposal outside synchronous transport emitters.
3. Queue `RoomTabs.dispose()` **after** those transport-disposal microtasks.
4. The adapter announces `bye` for its old term, closes/aborts local control resources, and resolves the held lock callback promise.
5. A queued successor can then acquire the lock, with no old session transport intentionally left active at release.

The generation/ownership checks also prevent late callbacks from a retired runtime from starting networking or publishing current proof. This ordering is independent of saving: the UI must successfully [flush](history-and-storage.md#failures-retry-and-explicit-flush) before intentionally disposing a session with drafts. A lock release or tab close is not a save mechanism.

## Unsupported browsers and advisory hints

`createRoomTabs` returns null for invalid scope or when a secure context, Web Locks `request` **and** `query`, BroadcastChannel, or AbortController is unavailable/blocked during capability setup. The application then uses conventional independent network sessions, still with the selected persistent store. Native uses the null stub. There is no localStorage/timer lease pretending to provide exclusivity, and browsers without secure Web Locks do not receive an atomic client-ID-creation guarantee.

This networking fallback is **not a writable author-prefix fallback**. `WebRoomStore` requires secure Web Locks `request` for new authored commits and rejects proof-bearing imports without that journal lock. A missing lock produces a visible saving failure, not an independent same-actor fork. A browser with the journal-lock facility but no BroadcastChannel/query-based owner coordination can still serialize journal writes while networking independently. Legacy data remains readable; native authoring uses its store queue instead of browser locks.

A lock request/query or control failure after startup is surfaced through the coordinator/session error path; it is not silently relabeled as successful ownership or synchronization.

The browser module also keeps an optional **tab-scoped `sessionStorage` recent-host hint**. It expires after 60 seconds and writes are throttled to once per five seconds. It is only a follower-first discovery optimization after observed live exchanges; it supplies no history, membership, readiness, or ownership. Blocked hint storage is ignored because the hint is optional, unlike failures of the durable `RoomStore`.

## Code and tests to read

These suites describe the coverage boundaries; dated run results belong in the [verification record](../verification.md):

- [room_tabs_test.dart](../../test/room_tabs_test.dart): checkpoint immutability/schema, roster validation, and the native stub.
- [web_room_store_test.dart](../../test/web_room_store_test.dart): browser identity/journal locks, concurrent same-actor store authoring, locked read/import ordering, partial-prefix retries, missing-lock errors, directed control-state validation, queued follower cancellation, and handoff without stealing. Compilation is not a browser pass; see [the harness caveat](testing.md#historical-drivers-and-browser-harness-caveat).
- [room_session_test.dart](../../test/room_session_test.dart): canonical same-actor prefix relay, full-inventory proof, stale awaited reads, fresh-member isolation, readiness latching, and transport retirement before release.
- [room_details_test.dart](../../test/room_details_test.dart): verified metadata/roster inheritance and immediate negative presence despite saving errors or an unverified inventory.
- [tree_room_session_test.dart](../../test/tree_room_session_test.dart): durable person bindings and visible grouping without actor-identity merging.

Related: [History and storage](history-and-storage.md), [Rooms and identity](rooms-and-identity.md), [Synchronization](synchronization.md), and [UI](ui.md).
