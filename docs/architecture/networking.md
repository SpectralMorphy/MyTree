# Networking

This page describes current discovery, WebRTC transport, and recovery boundaries. It does not describe a hosted room service.
See [synchronization](synchronization.md) for wire messages and durable readiness, [rooms and identity](rooms-and-identity.md)
for invitations, [history and storage](history-and-storage.md), [local tabs](local-tabs.md), and [UI](ui.md).

## A participant is the temporary hub

A permanent random room ID determines the rendezvous alias `mytree-room-<roomId>`. The alias holder is an online
participant running the same application, not an owned server or a permanent creator role. Other participants connect
to it over encrypted WebRTC DataChannels; it saves and relays journal additions in a hub-and-spoke topology.
Guest/editor permission is independent of this network role: a saved guest can host and relay without gaining edit rights.

Only accepted/saved members may attempt the alias. A fresh visitor registers a random runtime ID and connects to the
alias; lack of an online participant cannot create an empty replacement room or grant membership. An alias collision
makes a saved contender retry as a follower. Lost hubs/signaling eventually trigger normal saved-member election.
The creator has no special network privilege, and no signaling service stores the room journal for later offline delivery. The optional [Yandex Disk replica](yandex-disk.md) is a separate private HTTP data path, not a feature of signaling or hub election.

[RoomSession](../../lib/room_session.dart) validates the returned registration ID and admits incoming channels only while
it is a joined, signaling-ready hub. A recent-online hint can make a saved member try an existing hub first; it is only an
optimization, not membership or presence evidence. Same-origin local tabs normally share one external network owner;
a follower verifies shared durable storage and requests leader state rather than opening its own public connections.

## Editor-only Disk credential delivery

Ordinary hub election remains role-independent, and a guest hub can relay public journal history, including token-free Disk binding metadata. It must not receive or relay an OAuth token. The usual credential route remains the negotiated `diskCredentials` message over an eligible ordinary editor RTC channel, with `diskSync`, explicit durable editor roles, and a matching active binding.

Only when the ordinary live, ready host is durably a guest does the joined, network-owning editor tab enable [DiskCredentialExchange](../../lib/cloud/disk_credential_exchange.dart). That helper owns an additional editor rendezvous peer/channel lifecycle and bounded `diskHello` / `diskAccess` handshake against exact known durable-editor aliases. It stops when that condition no longer holds, rather than keeping a permanent parallel mesh. It neither grants membership nor turns the guest hub into a secret broker.

Only discovery/negotiation uses the signaling providers. The token travels in a separate RTC control message without journal history, not an MQTT publish, signaling payload, invitation, journal edit, or local-tab state proof. With a retained valid token, an admitted editor subsequently talks to Yandex over HTTPS without another peer online. Details and the trusted-client limitation belong to the [Disk subsystem](yandex-disk.md#credentials-and-the-trust-boundary).

## Common transport boundaries

The small contracts in [signaling.dart](../../lib/signaling/signaling.dart) keep provider objects out of the session.

| Contract | Responsibility |
| --- | --- |
| `SignalingPeerFactory(id, rtcConfiguration)` | Construct a logical peer using the shared ICE configuration. |
| `SignalingPeer` | Registration, incoming/outgoing channels, open/error/disconnect/close events, and disposal. |
| `RoomChannel` | Peer/service identity, open/disposed/connectivity state, data/events, asynchronous send, disposal. |
| Optional `SignalingDiscovery` | Current registration coverage plus change notifications; stronger than `open`. |

`SignalingFailureKind` distinguishes `idTaken`, service `unavailable`, `remoteUnavailable`, and `negotiation` failure.
Discovery coverage says configured providers validated the logical ID without pending registration, failure, or conflict.
It is not a census of devices. A usable channel, validated room handshake, and durable checkpoint are separate milestones.

## PeerJS and multi-provider fallback

[PeerJsSignalingPeer](../../lib/signaling/peerjs_signaling.dart) wraps `peer_rtc`'s `Peer` and reliable `DataConnection`.
It normalizes package errors and RTC/ICE states, validates registration, and guards queued registration replay with an epoch.
Package automatic reconnect is disabled; the room session owns whole-peer reconnection. Adapter disposal cancels package
reconnect and releases its channels; a signaling error alone is not an instruction to dispose an established channel.

The production factory in [fallback_signaling.dart](../../lib/signaling/fallback_signaling.dart) constructs one
`FallbackSignalingPeer` with PeerJS preferred and MQTT secondary. Both register **the same logical ID concurrently**.
The standby remains discoverable while PeerJS works, allowing a PeerJS-blocked newcomer to find the existing hub via MQTT.
This is not two independently created rooms and is not a switch that registers MQTT only after primary failure.

- Registration announcement prefers PeerJS, with a bounded wait if MQTT becomes ready first; primary failure releases it early.
- An outgoing logical channel starts on the first ready provider in preference order, then hedges after 250 ms.
  A failed attempt starts alternatives immediately; a standby arriving after the hedge starts immediately when ready.
- The first valid open channel wins. Late/losing attempts are disposed; data and sends use only the winner, not duplicate paths.
- `remoteUnavailable` fails pending connection attempts, not the provider's valid registration.
- **`idTaken` is contention, not an outage.** Any backend's result, including a late/retry result, invalidates the logical peer
  and stops new races/recovery. The session applies alias election; it must not bypass occupancy in another provider namespace.

A failed backend that **never registered** can be replaced at most twice while another backend remains healthy. Old
subscriptions are released, a new epoch guards callbacks, and jittered backoff bounds retries. A backend that registered
at least once is retained even after signaling loss: it may own outgoing or incoming RTC links. It is not hot-replaced
or kept beside a duplicate registration. The working provider and established winner are not recreated by cold recovery.
When the whole wrapper loses service or is disposed/conflicted, its internal retries stop; the session owns the next peer.

A pending logical channel records provider failures against the registration epoch, not the persistent backend slot. A recovered cold registration can therefore join an already-pending race without restarting its healthy attempt. Duplicate readiness within the same epoch does not redial a failed attempt. Once that logical channel has reported exhaustion, later provider recovery cannot revive it; a new channel is required. Established winners remain unchanged.

| Fallback constant | Production value / meaning |
| --- | --- |
| Registration deadline per attempt | 3 s for preferred backend; 14 s for secondary |
| Secondary-ready preference delay | 250 ms for random runtime IDs; 3 s for room aliases |
| Outgoing channel hedge | 250 ms, independent of registration preference |
| Cold-backend retry | At most 2; first 500–750 ms, second 1,000–1,250 ms |

The secondary registration budget includes the MQTT adapter's complete bounded startup: up to 8 s connecting, 4 s for parallel subscription acknowledgments, then at most 1.5 s probing/claiming. It must not cut these valid stages off at the old 7 s boundary. This wrapper budget is not a new room-entry deadline: the session's independent 8 s registration, 12 s channel/handshake, and fixed 30 s fresh-admission limits still apply. It prevents premature cancellation when a valid fallback becomes ready before those session limits; it does not promise that every 13.5 s MQTT startup can complete fresh admission. Failed/expired visitors never become hosts or receive membership by timeout.

An established RTC link can survive one provider's loss while another maintains the logical peer. MQTT also preserves open
RTC links on its own signaling failure. This is not indefinite survival of a session-wide restart: the session keeps links
during reconnect backoff, then `_beginPeer` retires the old generation and its channels. Recovery does not migrate a channel
between providers; newly established channels perform the ordinary journal/checkpoint exchange. A genuinely closed
DataChannel cannot resume in place: recovery needs a new connection/PeerConnection. ICE `disconnected` is different and
can recover during the session's five-second grace period. The selected fallback channel does not automatically rerace
providers after closing; the session owns reconnection.

A generic **WebRTC channel closed** message describes transport state, not its cause. An incompatible peer can reject a
handshake locally with update/reload guidance and close the channel without sending a rejection reason to the other side.
That other side may therefore see only closure and the initial verification timeout. Reloading all devices is relevant
after capability changes, but the closure text alone does not establish either incompatibility or a network outage.

## MQTT discovery is best-effort, not consensus

[MqttSignalingPeer](../../lib/signaling/mqtt_signaling.dart) sends discovery, presence, SDP, and trickled ICE over TLS MQTT
WebSockets. An injected `MqttSignalingBus` and RTC factory support deterministic tests; browser/native client adapters share
that boundary. The logical peer alias is **not** the broker client ID: each connection uses `mytree-<random instance>`.

Topics are `mytree/signaling/v1/<base64url-without-padding logical ID>/{mailbox,presence}`. Startup uses a clean session,
subscribes to both topics in parallel, and waits for **both SUBACKs** before probing/claiming. Publishes use QoS 1 without
retention; retained incoming messages are ignored. Request, instance, recipient, and connection tokens route negotiations
and reject stale/wrong-recipient traffic. SDP is published before queued local ICE; early remote candidates wait for SDP.

An existing owner answers probes/claims with occupancy. Concurrent claimants compare instance IDs deterministically;
owner announcements and late occupied responses detect later conflicts, including after partitions. This is collision
detection, **not atomic reservation, distributed consensus, room authorization, or protection against hostile publishers**.
A successful claim only establishes this adapter's best-effort discovery state.

| MQTT bound / timer | Current value |
| --- | --- |
| Probe then claim | 500 ms probe; 1 s alias claim, or 100 ms for explicitly opted-in random runtime IDs |
| Owner announcement / remote discovery | Every 3 s / fixed 6 s timeout; bounded same-token retries |
| Channel negotiation | 30 s adapter deadline; the session's shorter handshake cap can win |
| Signaling packet / remote candidates | 128 KiB UTF-8 / at most 256 unique candidates per channel |
| Incoming offers / retired connection keys | New offers rejected at 64 tracked channels / 256 remembered keys |

Remote discovery sends an immediate request and at most four jittered retries (500–650 ms, then 1,000–1,150 ms, then 2,000–2,150 ms intervals, bounded by the original six-second deadline). Retries reuse the same token: a host still claiming its alias can answer a later request without restarting the entire session. Response, timeout, channel retirement, signaling loss, and disposal cancel retries. Discovery success only permits normal RTC negotiation; it is not membership or durable synchronization evidence.

Only explicitly marked, valid random runtime IDs receive the short claim window; room aliases retain the conservative
window and all occupancy checks. The MQTT data path is an ordered, reliable, DTLS-encrypted RTCDataChannel carrying JSON.
Editor text, tree payloads, and journal packets are **not MQTT publishes**. Broker loss fails unfinished negotiations but
leaves already-open RTC links intact until their own lifecycle or session disposal ends them.

## Current public services and ICE configuration

The application needs no operator-owned signaling/TURN server, but it does depend on external public infrastructure.
These are configured endpoints, not availability claims or a private archive service.

| Service | Current endpoint / use |
| --- | --- |
| PeerJS cloud | `wss://0.peerjs.com/peerjs?key=peerjs`, with runtime ID/token/version query fields; signaling only |
| Mosquitto | `wss://test.mosquitto.org:8081/mqtt`; independent discovery and SDP/ICE fallback |
| Google STUN | `stun:stun.l.google.com:19302`, `stun:stun1.l.google.com:19302`; address discovery |
| Masquerade guest TURN | `turn:turn.evan-brass.net`, `turn:turn.evan-brass.net?transport=tcp`, `turns:turn.evan-brass.net:443?transport=tcp` |

PeerJS host/path/key are defaults of the locked `peer_rtc` 1.1.0+1 dependency, selected by the
[adapter](../../lib/signaling/peerjs_signaling.dart) and [dependency lock](../../pubspec.lock), not application-host URLs.
[IceConfiguration](../../lib/ice_configuration.dart) explicitly supplies the same RTC configuration to both providers;
package-default TURN lists are not the application's preset.

The [Masquerade operator](https://github.com/Evan-Brass/masquerade) publishes `guest` / `password` for public use.
These are intentionally public guest credentials, not private keys. Default TURN routes are UDP/3478, TCP/3478, and
TLS/TCP/443 respectively. The RTC configuration uses `unified-plan` and allows direct or relay routes (`all`) by default.
TURN relays encrypted WebRTC traffic; it is neither signaling nor a plaintext journal store.

Build-time `TURN_URLS`, `TURN_USERNAME`, and `TURN_CREDENTIAL` can supply an authorized alternative. Defining **any one**
disables the whole guest preset; incomplete/invalid configuration is an error, not silent STUN-only fallback. Explicitly
empty `TURN_URLS` with no other credentials disables TURN. `TURN_FORCE_RELAY=true` selects relay-only diagnostics and
requires a complete TURN configuration. URLs must be valid comma-separated `turn:`/`turns:` addresses.

Client-build values are extractable. Never embed a provider's administrative/API key, private key, or a cloud OAuth token.
Providers requiring API-side credential minting/rotation or account restrictions need a separate authorized integration;
MyTree currently supplies static RTC credentials and implements no such credential service. Application guest/editor roles
do not authenticate a TURN account or MQTT publisher.

[Public Mosquitto](https://test.mosquitto.org/) is a test service with no application room ACL or availability guarantee.
Other subscribers can observe/forge signaling, including through wildcard topics; brokers/signaling providers can see
SDP/IP metadata. TLS and DTLS protect transport, not the asserted family identity against malicious signaling/clients.
Digests compare records, not identities. Current rooms use trusted-client roles, not cryptographic authorization;
public services and best-effort claims are insufficient for a hostile-network private family archive.

## Browser address, recovery, and diagnostics

Invitations derive from the current application URL, preserving its path/port and placing room/role in the fragment.
`localhost` or `127.0.0.1` on a laptop is not that laptop from a phone: the phone needs a reachable application URL,
typically HTTPS. A tunnel serves the web bundle; it does **not** replace TURN, repair ICE, or store the room.
Changing scheme/host/port changes browser storage origin, so a new temporary tunnel can appear to be a different device.

[Browser network hooks](../../lib/network_status_web.dart) watch online/offline and visibility/resume/pageshow;
[RoomPage](../../lib/ui/room_page.dart) also forwards Flutter lifecycle. `navigator.onLine` is only a hint: offline revokes
online display, while online/foreground is not proof of a reachable provider or peer. The [native stub](../../lib/network_status_stub.dart)
does not infer connectivity from an OS hint. A qualifying wake of a confirmed copy invalidates readiness and retires stale
channels, then starts fresh discovery after a 200 ms debounce rather than waiting for the old 20-second liveness timer.
Unfinished entry and explicit local-copy recovery still probe eligible settled links with six seconds for received
heartbeat traffic; connecting, checkpoint-pending and assembling links keep normal deadlines.
See [synchronization](synchronization.md#recovery-and-truthful-ui) for guards, backoff, and the full deadline table.

When diagnosing, distinguish registration (`signalingService`), an actually open channel, a validated welcome/online actor,
and a durable checkpoint/ACK. Complete provider coverage is needed to infer solo, not to finish a real live-peer exchange;
partial outage must not be shown as proof that nobody else exists. An accepted local copy can be opened explicitly with an
unconfirmed label. Storage failures stay separate from network errors; the participant/offline icon is not a cloud-backup indicator.

## Source and regression map

- [Fallback tests](../../test/fallback_signaling_test.dart): simultaneous registration, hedging, conflicts, cold retries, RTC preservation.
- [PeerJS tests](../../test/peerjs_signaling_test.dart), [MQTT tests](../../test/mqtt_signaling_test.dart), [ICE tests](../../test/ice_configuration_test.dart).
- [Session tests](../../test/room_session_test.dart) and [tab tests](../../test/room_tabs_test.dart): election, health, lifecycle, single local owner.
- Existing headless drivers: [tree exchange](../../tool/check_tree_ui.cjs), [room UI](../../tool/check_room_ui.cjs), [wake recovery](../../tool/check_room_resume.cjs).

The optional [Yandex Disk replica](yandex-disk.md) is implemented separately from this network stack: already admitted editors can use retained credentials for asynchronous cloud exchange without a simultaneous peer. It is not a public guest archive, first-admission service, signaling replacement, or provider-authentication service. [Future storage and synchronization](../future-storage-and-sync.md) keeps broader future agreements separate from that implemented subset.
