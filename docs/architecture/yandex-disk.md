# Yandex Disk Replica

[Architecture index](README.md) · [History and storage](history-and-storage.md) · [WebRTC synchronization](synchronization.md) · [User setup](../yandex-disk.md)

Yandex Disk is an optional second durable copy and an asynchronous exchange point for already admitted editors. It does not replace the local journal, WebRTC, or room admission. This page describes the implemented subset of the [future storage agreements](../future-storage-and-sync.md), not completion of their snapshot, attachment, or conflict-resolution proposals.

## Responsibilities

- [YandexDiskClient](../../lib/cloud/yandex_disk_client.dart) owns authenticated HTTP, application-folder paths, paginated directory listing, immutable uploads, read-back confirmation, deadlines, and sanitized errors. Its HTTP client can be substituted in tests. Small conditional [native/default](../../lib/cloud/yandex_http_stub.dart) and [browser](../../lib/cloud/yandex_http_web.dart) adapters isolate Fetch's referrer, cookie, redirect, and cancellation behavior.
- [RoomDiskSync](../../lib/cloud/room_disk_sync.dart) scans and validates batches, unions remote and local histories, uploads missing durable records, schedules retries/polling, and tracks acknowledgment of a frozen local history digest. It neither authors operations nor grants membership.
- [RoomDiskRetirements](../../lib/cloud/room_disk_retirements.dart) reconstructs and owns independent final-detach deliveries for old bindings, each with an archived credential, frozen predecessor-complete history cutoff, and its own `RoomDiskSync`. Replacement of the active binding does not cancel that queue.
- [DiskBinding](../../lib/cloud/disk_binding.dart) projects public connect/detach history into the active binding identity and owner actor. It contains no token.
- [RoomSession](../../lib/room_session.dart) checks durable editor/owner permissions, composes cloud work with the existing serialized history-merge queue, retains detach retries, and transfers credentials over ordinary negotiated editor RTC channels.
- [DiskCredentialExchange](../../lib/cloud/disk_credential_exchange.dart) owns the additional editor-only rendezvous peer/channel lifecycle and bounded credential handshake, enabled only when the ordinary ready room host is a guest. It never authors history or grants membership.
- [RoomStore](../../lib/storage/room_store.dart) persists credentials separately from the operation journal; [room dialogs](../../lib/ui/room_dialogs.dart) collect the token and confirmations. Local, WebRTC, and Disk status remain separate UI facts.

## Local-first flow and immutable layout

An edit follows the existing optimistic/atomic-authored/local-durability path. Disk reads only canonical durable history. A cloud outage does not roll back an edit, replace local data with an empty document, or prevent further local work. The local journal is also the durable retry source: no tab-close handler is needed to construct an upload queue.

Files are private application-folder resources:

```text
app:/mytree/<roomId>/<bindingId>/batches/<sha256>.json
```

`bindingId` is the immutable connect operation ID. Each JSON batch has `v: 1`, `roomId`, `bindingId`, and a `history` list containing the existing complete `RoomEdit` envelopes/proofs. Its filename is the lowercase SHA-256 of its actual UTF-8 bytes. Uploads use `overwrite=false`; an existing name is accepted only after confirming identical bytes. There is no shared mutable `tree.json`, manifest overwrite, or cloud compare-and-swap requirement.

A synchronization round:

1. Enumerates the entire batches directory, following every listing page rather than treating the first page as the complete cloud history.
2. Reads uncached batches and checks filename/hash, room and binding identity, record syntax, and immutable-ID conflicts. Unchanged content-addressed batches can be reused from the in-memory cache.
3. Unions remote records with the current durable local journal and validates the existing author predecessor/base proofs across that union before merging through the normal local persistence boundary. An individual file need not contain every predecessor: a partially uploaded sequence can be repaired from records retained locally, but an incomplete resulting author prefix cannot be accepted.
4. Compares durable local history with the scanned cloud inventory and uploads missing records in immutable batches. Reloading or retrying reconstructs this difference from local history and a fresh full cloud scan, including after a partially completed upload.
5. Records acknowledgment only for the frozen local set covered by confirmed cloud files. Edits made during the round remain pending until a later round; acknowledgment does not prove that no offline participant has an unseen tail.

Local changes schedule cloud work; periodic scans and manual synchronization also pick up another editor's files. Already admitted editors with a retained valid credential can exchange changes asynchronously without overlapping online sessions. A first-time join still needs an online room participant and the ordinary compatible admission/durable handshake. Guests receive tree history through WebRTC, not through a published Disk folder or a cloud read token.

## Acknowledgment and failures

An upload link, completed HTTP send, or HTTP `202 Accepted` is not cloud durability evidence. The client reads back the actual remote bytes and compares them with the intended upload, with bounded confirmation retries. Existing-file conflicts also require byte equality. API/transport timeouts and failed confirmation remain failures, not successful copies.

Authenticated API requests and upload PUTs reject redirects. Only anonymous signed-download GETs follow redirects: Disk normally redirects downloads to a storage host. Initial signed URLs and the final response URL exposed by the production transports must match the HTTPS/443 Yandex-domain allowlist, with no userinfo or fragment; unexpected final destinations are rejected before consuming the response body. OAuth is sent only to the fixed API endpoint, never to a transfer URL. On web, a scoped Fetch adapter uses `referrerPolicy: no-referrer` and `credentials: omit`: the observed Disk download hosts reject requests carrying the application's Referer with HTTP 403 lacking CORS headers. This does not change the application's global referrer policy or disable CORS. Fetch follows redirects using its browser-defined hop cap; it does not expose intermediate destinations or honor the native client's five-hop setting. Redirects therefore carry no OAuth, cookies, application referrer, or request body; final URL checks and batch/content verification remain mandatory. Each request is abortable: deadline expiry cancels Fetch/native I/O rather than leaving a timed-out body buffering in the background. Closing the owned HTTP client also aborts its pending requests.

The cloud coordinator keeps a digest of the local set acknowledged by successful listing/download/upload confirmation. **Копия на Диске подтверждена** applies to that current known durable set, not global consensus, an independent backup retention policy, or the local/WebRTC saving indicator. A changed local digest invalidates that positive status. Error text is sanitized: response bodies, signed download/upload URLs, authorization headers, and raw platform exceptions must not enter UI or diagnostics.

## Binding, ownership, and offline races

The journal stores `kind: diskConnection` with JSON in `text`: `{action: connect}` or `{action: disconnect, bindingId: ...}`. The token and remote file contents never enter these operations. Binding projection replays connect/detach records in deterministic `(clock, id)` order: the first available connect remains active until a detach referencing that exact binding ID. A detach cannot remove a later replacement binding.

Only an editor can connect when there is no active binding. Disconnect is available to the original owner actor, or another editor actively bound to the same durable tree person as that owner. A shared person is a trusted-client ownership convenience, not a merge of actor journals or credentials. Guests have neither Disk commands/credentials nor **This Is Me** binding rights.

Two disconnected editors can both connect before learning of each other. Their local command guards are not a global lock. On union, deterministic replay chooses the surviving connect; a later arrival may change the projected winner. Ignored claims remain in immutable history, but a later claim does not simply replace an active one. No atomic cross-device reservation or globally serialized connection is promised.

### Independent detach retirement

Disconnect first persists the exact detach in the local journal. `RoomDiskRetirements` retains a separate delivery for that old binding: its archived credential, an independent `RoomDiskSync`, and a frozen predecessor-complete eligible history prefix. It first validates the full canonical history, then walks author-topological order, including only records at or before the detach's `(clock, id)` cutoff whose `authorPrevious` and sealed `authorBase` are already included. An old-clock draft that acquired a post-cutoff predecessor during late persistence is **excluded**, not recursively expanded into newer-binding data. If the detach itself cannot fit this closed prefix, retirement reports a visible queue error and starts no retired upload. Later active-binding edits must not leak to the old directory.

On restart or history refresh, the retirement coordinator scans historical disconnects, resolves their binding-scoped credentials, and reconstructs those frozen deliveries. A new active binding B does not reconfigure or cancel retirement A. The active replica and each retirement share the session-owned HTTP adapter with child disposal explicitly not closing it; disposing one finished retirement must not break another replica's HTTP work.

Once no binding is active, an eligible editor may connect a replacement **without waiting for old retirements to succeed**. An expired/revoked old token or failed old provider must not deadlock replacement setup. This permission does not erase or acknowledge the old queue: offline/error retries and pending-retirement status remain independent, including when the new active copy succeeds. Only read-back acknowledgment of an old delivery's frozen set permits binding-scoped removal of its credential and retirement entry; cleanup must preserve the new binding's archive/pointer. A locally saved detach or a newly connected Disk is not confirmation of the old final upload.

Unlinking does not delete cloud files, revoke OAuth, or remotely erase token copies already received by editors. Revocation must be performed manually in Yandex account/application access settings; it also stops other copies using that grant.

## Credentials and the trust boundary

There is no configured OAuth client ID or in-app browser authorization/token-issuance flow. The owner supplies an externally obtained token with `cloud_api:disk.app_folder` access. A personal owner account is supported without a broker or a mandatory separate account. Application-folder scope is **application-wide, not per tree**: sharing the token can expose other room subdirectories accessible to that OAuth application. The client does not publish folders or create public download access.

Credentials are versioned local metadata associated with a room and binding ID, stored separately in browser `localStorage` or native JSON sidecars. Binding-scoped archives are written before a compatible latest pointer, so concurrent staged connects or a newer pointer cannot overwrite the only credential retained for another binding's final-detach retry. Scoped cleanup removes only the targeted binding and any matching pointer; full room-credential cleanup is a separate operation. See the [storage contract](history-and-storage.md#separate-local-disk-credentials). They are **plaintext**, not an OS credential vault or encrypted storage. They are excluded from the room journal and its serialization/export, invitation URLs, QR payloads, public build values, and cloud batches. Anyone able to read the local application storage or inspect a running editor client may obtain the token.

The normal room path retains the separate `diskCredentials` RTC message with empty history and an exact binding identity, negotiated by `diskSync`. Sending/receiving requires explicit durable editor roles and a matching active binding; guest hubs must never receive or relay the secret.

Only when an editor's ordinary live, **ready host is durably a guest** does `RoomSession` enable `DiskCredentialExchange` for the joined network-owning editor tab. The helper registers an editor-specific rendezvous alias, connects only exact known durable-editor aliases, and uses its bounded `diskHello` / `diskAccess` handshake over direct RTC channels. The active binding is rechecked before accepting/persisting credentials. It stops its peer/channels when that fallback condition no longer holds; it is not a permanent parallel mesh or a replacement for normal negotiated `diskCredentials` delivery. This does not make the guest a credential broker. Local tab state messages and the public signaling channel are not token transports.

WebRTC protects transport, but room roles and actor/person claims still assume trusted family clients. Author proofs and SHA-256 content names detect structural disagreement; they are not signatures or cryptographic authorization. An editor can copy a token, and a modified client is outside the role model's security guarantee.

## Unchanged limits and remaining scope

- The full-history/transfer budget remains 8 MiB, including accumulated historical operations; cloud batching is not journal compaction or an unlimited archive.
- Photos remain inline data URLs in immutable tree history. PNG/JPEG/WebP processing limits remain 8 MiB input, at most 1024 px, and 700 KiB processed payload. Deleting a photo does not reclaim its historical bytes.
- No snapshots, separate attachment object store, history garbage collection, public guest cloud access, OAuth broker, or cryptographic membership system is introduced.
- Provider account setup, token issuance, real-account upload behavior, browser CORS, quotas, and revocation require their own operational checks. A description of implemented code is not a claim that a live Yandex account was exercised in this development session.

## Regression references

- [yandex_disk_client_test.dart](../../test/yandex_disk_client_test.dart): HTTP contracts, pagination, immutable writes/read-back, bounded failures, and credential-safe errors.
- [room_disk_sync_test.dart](../../test/room_disk_sync_test.dart): content-addressed union, retry reconstruction, validation, and truthful acknowledgment.
- [disk_binding_test.dart](../../test/disk_binding_test.dart) and [room_disk_session_test.dart](../../test/room_disk_session_test.dart): binding replay, permissions, local credential separation, and session lifecycle.
- [disk_credential_exchange_test.dart](../../test/disk_credential_exchange_test.dart): guest-host fallback lifecycle, editor/binding guards, credential persistence errors, and browser real-RTC/DTLS scenarios.
- [room_disk_retirements_test.dart](../../test/room_disk_retirements_test.dart): dirty/coalesced-update rescans and late-proof cutoff isolation, without expanding old delivery into newer-binding records.
- [room_dialogs_test.dart](../../test/room_dialogs_test.dart): private token input, explicit sharing/unlink confirmation, live roles, pending-state guards, safe error display, and readable token-free journal entries.

Dated verification results belong in the [verification record](../verification.md), not in this implementation contract.
