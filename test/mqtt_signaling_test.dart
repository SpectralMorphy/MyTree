import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mytree_webrtc_demo/signaling/mqtt_signaling.dart';
import 'package:mytree_webrtc_demo/signaling/signaling.dart';

const _runtimeId = '0123456789abcdef0123456789abcdef';

void main() {
  test(
    'constructor is inert, default endpoint is TLS, and invalid TLS is rejected',
    () {
      final hub = _Broker();
      final bus = hub.bus();
      final peer = MqttSignalingPeer(id: 'host', config: {}, bus: bus);
      expect(bus.clientId, isNull);
      expect(peer.endpoint, Uri.parse('wss://test.mosquitto.org:8081/mqtt'));
      expect(peer.open, isFalse);
      peer.dispose();
      peer.start();
      expect(bus.clientId, isNull);
      expect(
        () => MqttSignalingPeer(
          id: 'host',
          config: {},
          endpoint: Uri.parse('ws://localhost/mqtt'),
        ),
        throwsArgumentError,
      );
    },
  );

  testWidgets(
    'discovery covers subscription acknowledgements and the complete claim',
    (tester) async {
      final hub = _Broker();
      final bus = hub.bus();
      final subscription = Completer<void>();
      bus.subscribeGates[_presence('room')] = subscription;
      final peer = _peer('room', 'local', bus);
      addTearDown(peer.dispose);
      final coverage = <bool>[];
      var done = false;
      peer.onDiscoveryChanged.listen(
        (_) => coverage.add(peer.discoveryComplete),
        onDone: () => done = true,
      );
      expect(peer.discoveryComplete, isFalse);
      peer.start();
      await tester.pump(const Duration(seconds: 2));
      expect(peer.discoveryComplete, isFalse);
      expect(coverage, [false]);
      subscription.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 999));
      expect(peer.discoveryComplete, isFalse);
      await tester.pump(const Duration(milliseconds: 1));
      expect(peer.discoveryComplete, isTrue);
      expect(coverage, [false, true]);
      peer.dispose();
      expect(peer.discoveryComplete, isFalse);
      await tester.pump();
      expect(coverage, [false, true, false]);
      expect(done, isTrue);
      await tester.pump(const Duration(seconds: 10));
      expect(coverage, [false, true, false]);
    },
  );

  testWidgets(
    'opted-in runtime ID probes for 500ms and opens after 100ms claim',
    (tester) async {
      final hub = _Broker();
      final peer = _peer(
        _runtimeId,
        'runtime',
        hub.bus(),
        ephemeralIdentity: true,
      );
      addTearDown(peer.dispose);
      final opens = <String?>[];
      peer.onOpen.listen(opens.add);
      peer.start();
      await tester.pump();
      expect(hub.packets.map((packet) => packet['type']), ['probe']);
      await tester.pump(const Duration(milliseconds: 499));
      expect(peer.open, isFalse);
      expect(hub.packets.map((packet) => packet['type']), ['probe']);
      await tester.pump(const Duration(milliseconds: 1));
      expect(hub.packets.map((packet) => packet['type']), ['probe', 'claim']);
      await tester.pump(const Duration(milliseconds: 99));
      expect(peer.open, isFalse);
      expect(opens, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(peer.open, isTrue);
      expect(opens, [_runtimeId]);
      expect(hub.packets.map((packet) => packet['type']), [
        'probe',
        'claim',
        'owner',
      ]);
      peer.dispose();
      await tester.pump(const Duration(seconds: 4));
      expect(hub.published, hasLength(3));
    },
  );

  testWidgets('default runtime IDs and opted-in aliases retain the 1s claim', (
    tester,
  ) async {
    final hub = _Broker();
    final peers = [
      _peer(_runtimeId, 'default', hub.bus()),
      _peer('room-alias', 'alias', hub.bus(), ephemeralIdentity: true),
    ];
    for (final peer in peers) {
      addTearDown(peer.dispose);
      peer.start();
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 100));
    expect(peers.every((peer) => !peer.open), isTrue);
    await tester.pump(const Duration(milliseconds: 899));
    expect(peers.every((peer) => !peer.open), isTrue);
    await tester.pump(const Duration(milliseconds: 1));
    expect(peers.every((peer) => peer.open), isTrue);
    for (final peer in peers) {
      peer.dispose();
    }
    await tester.pump();
  });

  testWidgets('simultaneous ephemeral claims still elect the lowest instance', (
    tester,
  ) async {
    final hub = _Broker();
    final winner = _peer(_runtimeId, 'a', hub.bus(), ephemeralIdentity: true);
    final loser = _peer(_runtimeId, 'z', hub.bus(), ephemeralIdentity: true);
    addTearDown(winner.dispose);
    addTearDown(loser.dispose);
    final failures = <SignalingFailure>[];
    loser.onError.listen(failures.add);
    winner.start();
    loser.start();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 100));
    expect(winner.open, isTrue);
    expect(loser.open, isFalse);
    expect(failures.single.kind, SignalingFailureKind.idTaken);
    winner.dispose();
    loser.dispose();
    await tester.pump();
  });

  testWidgets('confirmed ephemeral owner defeats a fresh lower-ID contender', (
    tester,
  ) async {
    final hub = _Broker();
    final owner = _peer(_runtimeId, 'z', hub.bus(), ephemeralIdentity: true);
    final contender = _peer(
      _runtimeId,
      'a',
      hub.bus(),
      ephemeralIdentity: true,
    );
    addTearDown(owner.dispose);
    addTearDown(contender.dispose);
    owner.start();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 100));
    expect(owner.open, isTrue);
    final failures = <SignalingFailure>[];
    final opens = <String?>[];
    contender.onError.listen(failures.add);
    contender.onOpen.listen(opens.add);
    contender.start();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(owner.open, isTrue);
    expect(contender.open, isFalse);
    expect(opens, isEmpty);
    expect(failures.single.kind, SignalingFailureKind.idTaken);
    owner.dispose();
    contender.dispose();
    await tester.pump();
  });

  testWidgets('late occupied challenge revokes fast-opened ephemeral peer', (
    tester,
  ) async {
    final hub = _Broker();
    final peer = _peer(_runtimeId, 'a', hub.bus(), ephemeralIdentity: true);
    addTearDown(peer.dispose);
    final failures = <SignalingFailure>[];
    final closes = <void>[];
    peer.onError.listen(failures.add);
    peer.onClose.listen(closes.add);
    peer.start();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 100));
    expect(peer.open, isTrue);
    hub.inject(_presence(_runtimeId), {
      'v': 1,
      'type': 'occupied',
      'from': _runtimeId,
      'instance': 'z-incumbent',
      'recipient': 'a',
    });
    await tester.pump();
    expect(peer.open, isFalse);
    expect(failures.single.kind, SignalingFailureKind.idTaken);
    expect(closes, hasLength(1));
    final publishes = hub.published.length;
    await tester.pump(const Duration(seconds: 4));
    expect(hub.published, hasLength(publishes));
    peer.dispose();
    await tester.pump();
    expect(closes, hasLength(1));
  });

  for (final pendingTopic in ['mailbox', 'presence']) {
    testWidgets(
      'parallel subscribe waits for pending $pendingTopic acknowledgement',
      (tester) async {
        final hub = _Broker();
        final bus = hub.bus();
        final mailbox = Completer<void>();
        final presence = Completer<void>();
        bus.subscribeGates[_mailbox(_runtimeId)] = mailbox;
        bus.subscribeGates[_presence(_runtimeId)] = presence;
        final peer = _peer(_runtimeId, 'runtime', bus, ephemeralIdentity: true);
        addTearDown(peer.dispose);
        peer.start();
        await tester.pump();
        expect(bus.topics, {_mailbox(_runtimeId), _presence(_runtimeId)});
        (pendingTopic == 'mailbox' ? presence : mailbox).complete();
        await tester.pump(const Duration(seconds: 2));
        expect(peer.open, isFalse);
        expect(hub.published, isEmpty);
        (pendingTopic == 'mailbox' ? mailbox : presence).complete();
        await tester.pump();
        expect(hub.packets.map((packet) => packet['type']), ['probe']);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 100));
        expect(peer.open, isTrue);
        peer.dispose();
        await tester.pump();
      },
    );
  }

  testWidgets(
    'disposal before both subscribe acknowledgements aborts fast admission',
    (tester) async {
      final hub = _Broker();
      final bus = hub.bus();
      final pending = Completer<void>();
      bus.subscribeGates[_presence(_runtimeId)] = pending;
      final peer = _peer(_runtimeId, 'runtime', bus, ephemeralIdentity: true);
      final opens = <String?>[];
      peer.onOpen.listen(opens.add);
      peer.start();
      await tester.pump();
      expect(bus.topics, {_mailbox(_runtimeId), _presence(_runtimeId)});
      peer.dispose();
      pending.complete();
      await tester.pump(const Duration(seconds: 4));
      expect(bus.closed, isTrue);
      expect(peer.open, isFalse);
      expect(opens, isEmpty);
      expect(hub.published, isEmpty);
    },
  );

  testWidgets('simultaneous alias claims elect one deterministic instance', (
    tester,
  ) async {
    final hub = _Broker();
    final firstBus = hub.bus();
    final secondBus = hub.bus();
    final first = _peer('shared/#alias', 'a', firstBus);
    final second = _peer('shared/#alias', 'b', secondBus);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final firstOpens = <String?>[];
    final secondOpens = <String?>[];
    final errors = <SignalingFailure>[];
    first.onOpen.listen(firstOpens.add);
    second.onOpen.listen(secondOpens.add);
    second.onError.listen(errors.add);
    first.start();
    second.start();
    await _admit(tester);
    expect(first.open, isTrue);
    expect(second.open, isFalse);
    expect(firstOpens, ['shared/#alias']);
    expect(secondOpens, isEmpty);
    expect(errors.single.kind, SignalingFailureKind.idTaken);
    expect(firstBus.clientId, isNot(secondBus.clientId));
    expect(firstBus.clientId, isNot(first.id));
    expect(firstBus.topics.every((topic) => !topic.contains('#')), isTrue);
    // Replies must not recursively bounce claim packets between contenders.
    expect(hub.published.length, lessThan(15));
    first.dispose();
    second.dispose();
    await tester.pump();
  });

  testWidgets('a confirmed owner beats a later lexically smaller contender', (
    tester,
  ) async {
    final hub = _Broker();
    final owner = _peer('room', 'z', hub.bus());
    final contender = _peer('room', 'a', hub.bus());
    addTearDown(owner.dispose);
    addTearDown(contender.dispose);
    owner.start();
    await _admit(tester);
    final errors = <SignalingFailure>[];
    final opens = <String?>[];
    contender.onError.listen(errors.add);
    contender.onOpen.listen(opens.add);
    contender.start();
    await _admit(tester);
    expect(owner.open, isTrue);
    expect(contender.open, isFalse);
    expect(opens, isEmpty);
    expect(errors.single.kind, SignalingFailureKind.idTaken);
    owner.dispose();
    contender.dispose();
    await tester.pump();
  });

  testWidgets('a delayed occupied reply revokes a newly opened contender', (
    tester,
  ) async {
    final hub = _Broker();
    final peer = _peer('room', 'a', hub.bus());
    addTearDown(peer.dispose);
    final failures = <SignalingFailure>[];
    final closes = <void>[];
    final coverage = <bool>[];
    peer.onError.listen(failures.add);
    peer.onClose.listen(closes.add);
    peer.onDiscoveryChanged.listen((_) => coverage.add(peer.discoveryComplete));
    peer.start();
    await _admit(tester);
    expect(peer.open, isTrue);
    expect(peer.discoveryComplete, isTrue);
    hub.inject(_presence('room'), {
      'v': 1,
      'type': 'occupied',
      'from': 'room',
      'instance': 'z-incumbent',
      'recipient': 'a',
    });
    await tester.pump();
    expect(peer.open, isFalse);
    expect(peer.discoveryComplete, isFalse);
    expect(coverage, [false, true, false]);
    expect(failures.single.kind, SignalingFailureKind.idTaken);
    expect(closes, hasLength(1));
    peer.dispose();
    await tester.pump();
    expect(closes, hasLength(1));
  });

  testWidgets('untrusted, retained and oversized offers cannot allocate RTC', (
    tester,
  ) async {
    final hub = _Broker();
    final rtc = _RtcNetwork();
    final peer = _peer('room', 'local', hub.bus(), rtc: rtc);
    addTearDown(peer.dispose);
    final incoming = <RoomChannel>[];
    peer.onConnection.listen(incoming.add);
    peer.start();
    await _admit(tester);
    final offer = <String, dynamic>{
      'v': 1,
      'type': 'offer',
      'from': 'remote',
      'instance': 'remote-instance',
      'to': 'room',
      'recipient': 'local',
      'connection': 'connection',
      'sdp': 'offer',
    };
    hub.inject(_mailbox('room'), offer, retained: true);
    hub.inject(_mailbox('room'), {...offer, 'recipient': 'previous-instance'});
    hub.inject(_mailbox('room'), {...offer, 'to': 'elsewhere'});
    hub.inject(_mailbox('room'), {...offer, 'connection': 'invalid/token'});
    hub.inject(_mailbox('room'), {...offer, 'sdp': 'x' * (128 * 1024)});
    hub._deliver(MqttSignalingMessage(_mailbox('room'), '{'));
    await tester.pump();
    expect(incoming, isEmpty);
    expect(rtc.peers, isEmpty);
    expect(peer.open, isTrue);
    peer.dispose();
    await tester.pump();
  });

  testWidgets(
    'retained stale identity is ignored and disposal aborts admission',
    (tester) async {
      final hub = _Broker();
      final bus = hub.bus();
      final peer = _peer('room', 'local', bus);
      addTearDown(peer.dispose);
      final opens = <String?>[];
      peer.onOpen.listen(opens.add);
      peer.start();
      await tester.pump();
      hub.inject(_presence('room'), {
        'v': 1,
        'type': 'owner',
        'from': 'room',
        'instance': 'stale',
      }, retained: true);
      await _admit(tester);
      expect(peer.open, isTrue);
      final stoppedBus = hub.bus();
      final stopped = _peer('other', 'gone', stoppedBus);
      stopped.onOpen.listen(opens.add);
      stopped.start();
      await tester.pump();
      stopped.dispose();
      await tester.pump(const Duration(seconds: 2));
      expect(stopped.open, isFalse);
      expect(opens, ['room']);
      expect(stoppedBus.closed, isTrue);
      peer.dispose();
      await tester.pump();
    },
  );

  testWidgets('late broker connect completion cannot start after disposal', (
    tester,
  ) async {
    final hub = _Broker();
    final bus = hub.bus()..connectGate = Completer<void>();
    final peer = _peer('room', 'instance', bus);
    final opens = <String?>[];
    peer.onOpen.listen(opens.add);
    peer.start();
    await tester.pump();
    peer.dispose();
    bus.connectGate!.complete();
    await tester.pump(const Duration(seconds: 3));
    expect(bus.topics, isEmpty);
    expect(hub.published, isEmpty);
    expect(opens, isEmpty);
  });

  testWidgets('SDP precedes ICE, early ICE queues through RTC factory and SDP', (
    tester,
  ) async {
    final hub = _Broker();
    final rtc = _RtcNetwork(gateIncoming: true);
    final host = _peer('host', 'host-instance', hub.bus(), rtc: rtc);
    final guest = _peer('guest', 'guest-instance', hub.bus(), rtc: rtc);
    addTearDown(host.dispose);
    addTearDown(guest.dispose);
    final incoming = <RoomChannel>[];
    final received = <Object?>[];
    host.onConnection.listen((channel) {
      incoming.add(channel);
      channel.onData.listen(received.add);
    });
    host.start();
    guest.start();
    await _admit(tester);
    final channel = guest.connect('host');
    final opens = <void>[];
    final errors = <Object>[];
    channel.onOpen.listen(opens.add);
    channel.onError.listen(errors.add);
    await tester.pump();
    expect(incoming, hasLength(1));
    expect(rtc.peers, hasLength(2));
    expect(rtc.peers[1].remoteDescription, isNull);
    expect(rtc.peers[1].addedCandidates, isEmpty);
    final offerPackets = hub.packets
        .where((packet) => packet['from'] == 'guest')
        .toList();
    expect(
      offerPackets.map((packet) => packet['type']),
      containsAllInOrder(['offer', 'candidate']),
    );
    final candidate = hub.packets.firstWhere(
      (packet) => packet['from'] == 'guest' && packet['type'] == 'candidate',
    );
    // Duplicate QoS1 delivery and foreign-instance/stale-recipient ICE are ignored.
    hub.inject(_mailbox('host'), candidate);
    hub.inject(_mailbox('host'), {...candidate, 'instance': 'old-instance'});
    hub.inject(_mailbox('host'), {...candidate, 'recipient': 'old-host'});
    rtc.factoryGate!.complete();
    await tester.pump();
    expect(rtc.peers[1].remoteDescription, isNull);
    expect(rtc.peers[1].addedCandidates, isEmpty);
    rtc.descriptionGate!.complete();
    await tester.pump();
    expect(channel.open, isTrue);
    expect(incoming.single.open, isTrue);
    expect(opens, hasLength(1));
    expect(errors, isEmpty);
    expect(rtc.peers[1].addedCandidates, hasLength(1));
    expect(rtc.peers[1].candidateBeforeSdp, isFalse);
    expect(rtc.peers[0].addedCandidates, hasLength(1));
    expect(rtc.peers[0].channelInit!.ordered, isTrue);
    expect(rtc.peers[0].channelInit!.maxRetransmits, -1);
    expect(rtc.peers[0].channelInit!.maxRetransmitTime, -1);
    expect(rtc.configuration, everyElement({'iceServers': <dynamic>[]}));
    final publishCount = hub.published.length;
    const editorPacket = {
      't': 'patch',
      'body': 'private history текст',
      'n': 42,
    };
    await channel.send(editorPacket);
    await tester.pump();
    expect(received, [editorPacket]);
    expect(rtc.peers[0].dc!.sent.single.text, jsonEncode(editorPacket));
    expect(hub.published.length, publishCount);
    expect(
      hub.published.any(
        (message) => message.payload.contains('private history'),
      ),
      isFalse,
    );
    // Retired connection IDs cannot recreate channels after their channel closes.
    final offer = hub.packets.firstWhere((packet) => packet['type'] == 'offer');
    incoming.single.dispose();
    hub.inject(_mailbox('host'), offer);
    await tester.pump();
    expect(incoming, hasLength(1));
    host.dispose();
    guest.dispose();
    await tester.pump();
  });

  testWidgets(
    'broker failure preserves open RTC and cached health owns callbacks',
    (tester) async {
      final hub = _Broker();
      final rtc = _RtcNetwork();
      final hostBus = hub.bus();
      final guestBus = hub.bus();
      final host = _peer('host', 'host-instance', hostBus, rtc: rtc);
      final guest = _peer('guest', 'guest-instance', guestBus, rtc: rtc);
      addTearDown(host.dispose);
      addTearDown(guest.dispose);
      final received = <Object?>[];
      host.onConnection.listen(
        (channel) => channel.onData.listen(received.add),
      );
      host.start();
      guest.start();
      await _admit(tester);
      final channel = guest.connect('host');
      final health = <ChannelConnectivity>[];
      channel.onConnectivity.listen(health.add);
      await tester.pump();
      expect(channel.open, isTrue);
      final failures = <SignalingFailure>[];
      final disconnected = <void>[];
      final coverage = <bool>[];
      guest.onError.listen(failures.add);
      guest.onDisconnected.listen(disconnected.add);
      guest.onDiscoveryChanged.listen(
        (_) => coverage.add(guest.discoveryComplete),
      );
      expect(guest.discoveryComplete, isTrue);
      guestBus.loseConnection();
      await tester.pump();
      expect(guest.open, isFalse);
      expect(guest.discoveryComplete, isFalse);
      expect(coverage, [false]);
      expect(guest.disconnected, isTrue);
      expect(failures.single.kind, SignalingFailureKind.unavailable);
      expect(disconnected, hasLength(1));
      expect(channel.open, isTrue);
      expect(channel.disposed, isFalse);
      expect(() => guest.connect('another'), throwsA(isA<SignalingFailure>()));
      await channel.send({'t': 'still-private'});
      await tester.pump();
      expect(received, [
        {'t': 'still-private'},
      ]);
      final pc = rtc.peers.first;
      expect(pc.onIceConnectionState, isNotNull);
      expect(pc.onConnectionState, isNotNull);
      pc.ice = RTCIceConnectionState.RTCIceConnectionStateDisconnected;
      // No callback: health polling must update the cached enum even when PC is connected.
      await tester.pump(const Duration(seconds: 2));
      expect(channel.connectivity, ChannelConnectivity.disconnected);
      expect(health.last, ChannelConnectivity.disconnected);
      pc.ice = RTCIceConnectionState.RTCIceConnectionStateConnected;
      pc.onIceConnectionState!(pc.ice);
      await tester.pump();
      expect(channel.connectivity, ChannelConnectivity.connected);
      guest.dispose();
      await tester.pump();
      expect(channel.disposed, isTrue);
      expect(pc.onIceCandidate, isNull);
      expect(pc.onIceConnectionState, isNull);
      expect(pc.onConnectionState, isNull);
      expect(pc.onDataChannel, isNull);
      expect(pc.closed, isTrue);
      expect(pc.released, isTrue);
      host.dispose();
      await tester.pump();
    },
  );

  testWidgets('discovery retries find a host still claiming its alias', (
    tester,
  ) async {
    final hub = _Broker();
    final rtc = _RtcNetwork();
    final guest = _peer('guest', 'guest-instance', hub.bus(), rtc: rtc);
    final host = _peer('host', 'host-instance', hub.bus(), rtc: rtc);
    addTearDown(guest.dispose);
    addTearDown(host.dispose);
    final incoming = <RoomChannel>[];
    final errors = <Object>[];
    host.onConnection.listen(incoming.add);
    guest.start();
    await _admit(tester);
    host.start();
    await tester.pump();
    final channel = guest.connect('host');
    channel.onError.listen(errors.add);
    await tester.pump();
    expect(host.open, isFalse);
    expect(channel.open, isFalse);
    expect(hub.packets.where((p) => p['type'] == 'discover'), hasLength(1));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 650));
    }
    expect(host.open, isTrue);
    expect(channel.open, isTrue);
    expect(incoming, hasLength(1));
    final probes = hub.packets.where((p) => p['type'] == 'discover').toList();
    expect(probes.length, inInclusiveRange(2, 5));
    expect(probes.map((p) => p['request']).toSet(), hasLength(1));
    expect(hub.packets.where((p) => p['type'] == 'offer'), hasLength(1));
    await tester.pump(const Duration(seconds: 7));
    expect(
      hub.packets.where((p) => p['type'] == 'discover'),
      hasLength(probes.length),
    );
    expect(channel.open, isTrue);
    expect(errors, isEmpty);
    guest.dispose();
    host.dispose();
    await tester.pump();
  });

  testWidgets('discovery retries retain the original six-second deadline', (
    tester,
  ) async {
    final hub = _Broker();
    final guest = _peer('guest', 'guest-instance', hub.bus());
    addTearDown(guest.dispose);
    guest.start();
    await _admit(tester);
    final channel = guest.connect('missing');
    final errors = <Object>[];
    channel.onError.listen(errors.add);
    await tester.pump();
    for (var i = 0; i < 11; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.pump(const Duration(milliseconds: 499));
    expect(channel.disposed, isFalse);
    expect(errors, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(channel.disposed, isTrue);
    expect(
      (errors.single as SignalingFailure).kind,
      SignalingFailureKind.remoteUnavailable,
    );
    final probes = hub.packets.where((p) => p['type'] == 'discover').toList();
    expect(probes.length, inInclusiveRange(4, 5));
    expect(probes.map((p) => p['request']).toSet(), hasLength(1));
    await tester.pump(const Duration(seconds: 10));
    expect(
      hub.packets.where((p) => p['type'] == 'discover'),
      hasLength(probes.length),
    );
    guest.dispose();
    await tester.pump();
  });

  for (final stop in ['channel', 'peer', 'broker']) {
    testWidgets('discovery retry is cancelled on $stop retirement', (
      tester,
    ) async {
      final hub = _Broker();
      final bus = hub.bus();
      final guest = _peer('guest', 'guest-instance', bus);
      addTearDown(guest.dispose);
      guest.start();
      await _admit(tester);
      final channel = guest.connect('missing');
      final errors = <Object>[];
      channel.onError.listen(errors.add);
      guest.onError.listen(errors.add);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      final before = hub.packets.where((p) => p['type'] == 'discover').length;
      expect(before, 2);
      switch (stop) {
        case 'channel':
          channel.dispose();
        case 'peer':
          guest.dispose();
        case 'broker':
          bus.loseConnection();
      }
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      expect(channel.disposed, isTrue);
      expect(
        hub.packets.where((p) => p['type'] == 'discover'),
        hasLength(before),
      );
      guest.dispose();
      await tester.pump();
    });
  }

  testWidgets('unavailable remote and malformed RTC data emit typed failures', (
    tester,
  ) async {
    final hub = _Broker();
    final rtc = _RtcNetwork();
    final first = _peer('first', 'first-instance', hub.bus(), rtc: rtc);
    final second = _peer('second', 'second-instance', hub.bus(), rtc: rtc);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    first.start();
    second.start();
    await _admit(tester);
    final missing = first.connect('missing');
    final missingErrors = <Object>[];
    missing.onError.listen(missingErrors.add);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(
      (missingErrors.single as SignalingFailure).kind,
      SignalingFailureKind.remoteUnavailable,
    );
    expect(missing.disposed, isTrue);
    expect(
      first.discoveryComplete,
      isTrue,
      reason: 'Remote discovery timeout does not invalidate local registration',
    );
    final channel = first.connect('second');
    final errors = <Object>[];
    channel.onError.listen(errors.add);
    await tester.pump();
    rtc.peers.first.dc!.onMessage!(RTCDataChannelMessage('not-json'));
    rtc.peers.first.dc!.onMessage!(RTCDataChannelMessage('[1,2]'));
    await tester.pump();
    expect(errors, hasLength(2));
    expect(errors, everyElement(isA<SignalingFailure>()));
    expect(channel.open, isTrue);
    first.dispose();
    second.dispose();
    await tester.pump();
  });

  testWidgets(
    'disposal while RTC factory is pending releases its late handle',
    (tester) async {
      final hub = _Broker();
      final gate = Completer<RTCPeerConnection>();
      final pc = _FakeRtc(_RtcNetwork(), 'late');
      final host = _peer('host', 'host-instance', hub.bus());
      final guest = MqttSignalingPeer(
        id: 'guest',
        config: {},
        bus: hub.bus(),
        instanceId: 'guest-instance',
        rtcFactory: (_) => gate.future,
      );
      addTearDown(host.dispose);
      addTearDown(guest.dispose);
      host.start();
      guest.start();
      await _admit(tester);
      final channel = guest.connect('host');
      await tester.pump();
      guest.dispose();
      gate.complete(pc);
      await tester.pump();
      expect(channel.disposed, isTrue);
      expect(pc.closed, isTrue);
      expect(pc.released, isTrue);
      expect(hub.packets.where((packet) => packet['type'] == 'offer'), isEmpty);
      host.dispose();
      await tester.pump();
    },
  );
}

MqttSignalingPeer _peer(
  String id,
  String instance,
  _Bus bus, {
  _RtcNetwork? rtc,
  bool ephemeralIdentity = false,
}) => MqttSignalingPeer(
  id: id,
  config: {'iceServers': <dynamic>[]},
  bus: bus,
  instanceId: instance,
  rtcFactory: rtc?.create,
  ephemeralIdentity: ephemeralIdentity,
);

Future<void> _admit(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(seconds: 1));
}

String _base(String id) =>
    'mytree/signaling/v1/${base64Url.encode(utf8.encode(id)).replaceAll('=', '')}';
String _presence(String id) => '${_base(id)}/presence';
String _mailbox(String id) => '${_base(id)}/mailbox';

class _Broker {
  final buses = <_Bus>[];
  final published = <MqttSignalingMessage>[];
  List<Map<String, dynamic>> get packets => published
      .map((message) => jsonDecode(message.payload) as Map<String, dynamic>)
      .toList();

  _Bus bus() {
    final bus = _Bus(this);
    buses.add(bus);
    return bus;
  }

  void publish(String topic, String payload) {
    final message = MqttSignalingMessage(topic, payload);
    published.add(message);
    _deliver(message);
  }

  void inject(
    String topic,
    Map<String, dynamic> packet, {
    bool retained = false,
  }) {
    _deliver(
      MqttSignalingMessage(topic, jsonEncode(packet), retained: retained),
    );
  }

  void _deliver(MqttSignalingMessage message) {
    for (final bus in buses) {
      if (!bus.closed && bus.topics.contains(message.topic)) {
        bus.incoming.add(message);
      }
    }
  }
}

class _Bus implements MqttSignalingBus {
  _Bus(this.broker);
  final _Broker broker;
  final incoming = StreamController<MqttSignalingMessage>.broadcast();
  final disconnects = StreamController<void>.broadcast();
  final topics = <String>{};
  final subscribeGates = <String, Completer<void>>{};
  String? clientId;
  Completer<void>? connectGate;
  bool closed = false;

  @override
  Stream<MqttSignalingMessage> get messages => incoming.stream;
  @override
  Stream<void> get onDisconnected => disconnects.stream;
  @override
  Future<void> connect(Uri endpoint, String clientId) async {
    this.clientId = clientId;
    await connectGate?.future;
  }

  @override
  Future<void> subscribe(String topic) async {
    if (closed) throw StateError('closed');
    topics.add(topic);
    await subscribeGates[topic]?.future;
  }

  @override
  void publish(String topic, String payload) {
    if (closed) throw StateError('closed');
    broker.publish(topic, payload);
  }

  void loseConnection() => disconnects.add(null);

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    topics.clear();
    await incoming.close();
    await disconnects.close();
  }
}

class _RtcNetwork {
  _RtcNetwork({bool gateIncoming = false}) {
    if (gateIncoming) {
      factoryGate = Completer<void>();
      descriptionGate = Completer<void>();
    }
  }
  final peers = <_FakeRtc>[];
  final configuration = <Map<String, dynamic>>[];
  Completer<void>? factoryGate;
  Completer<void>? descriptionGate;

  Future<RTCPeerConnection> create(Map<String, dynamic> config) async {
    configuration.add(config);
    final pc = _FakeRtc(this, 'rtc-${peers.length}');
    peers.add(pc);
    if (peers.length == 2) await factoryGate?.future;
    return pc;
  }
}

class _FakeRtc extends RTCPeerConnection {
  _FakeRtc(this.network, this.key);
  final _RtcNetwork network;
  final String key;
  _FakeRtc? remote;
  _FakeDc? dc;
  RTCDataChannelInit? channelInit;
  RTCSessionDescription? remoteDescription;
  final addedCandidates = <RTCIceCandidate>[];
  bool candidateBeforeSdp = false;
  bool closed = false;
  bool released = false;
  RTCIceConnectionState ice = RTCIceConnectionState.RTCIceConnectionStateNew;
  RTCPeerConnectionState state =
      RTCPeerConnectionState.RTCPeerConnectionStateNew;

  @override
  RTCSignalingState? get signalingState =>
      RTCSignalingState.RTCSignalingStateStable;
  @override
  RTCIceGatheringState? get iceGatheringState =>
      RTCIceGatheringState.RTCIceGatheringStateComplete;
  @override
  RTCIceConnectionState? get iceConnectionState => ice;
  @override
  RTCPeerConnectionState? get connectionState => state;

  @override
  Future<RTCDataChannel> createDataChannel(
    String label,
    RTCDataChannelInit dataChannelDict,
  ) async {
    channelInit = dataChannelDict;
    return dc = _FakeDc();
  }

  @override
  Future<RTCSessionDescription> createOffer([
    Map<String, dynamic>? constraints,
  ]) async => RTCSessionDescription(key, 'offer');
  @override
  Future<RTCSessionDescription> createAnswer([
    Map<String, dynamic>? constraints,
  ]) async => RTCSessionDescription(key, 'answer');
  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    // Mimics browsers that emit ICE before setLocalDescription completes.
    onIceCandidate?.call(RTCIceCandidate('candidate-$key', '0', 0));
  }

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    if (key == 'rtc-1' && description.type == 'offer') {
      await network.descriptionGate?.future;
    }
    remoteDescription = description;
    remote = network.peers.firstWhere((pc) => pc.key == description.sdp);
    if (description.type == 'offer') {
      dc = _FakeDc();
      dc!.remote = remote!.dc;
      remote!.dc!.remote = dc;
      onDataChannel?.call(dc!);
    } else {
      _connected();
      remote!._connected();
      dc!.makeOpen();
      remote!.dc!.makeOpen();
    }
  }

  void _connected() {
    ice = RTCIceConnectionState.RTCIceConnectionStateConnected;
    state = RTCPeerConnectionState.RTCPeerConnectionStateConnected;
    onIceConnectionState?.call(ice);
    onConnectionState?.call(state);
  }

  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {
    if (remoteDescription == null) candidateBeforeSdp = true;
    addedCandidates.add(candidate);
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<void> dispose() async {
    released = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDc extends RTCDataChannel {
  _FakeDc? remote;
  final sent = <RTCDataChannelMessage>[];
  RTCDataChannelState _state = RTCDataChannelState.RTCDataChannelConnecting;
  @override
  RTCDataChannelState? get state => _state;
  @override
  int? get id => 0;
  @override
  String? get label => 'mytree';
  @override
  int? get bufferedAmount => 0;

  void makeOpen() {
    _state = RTCDataChannelState.RTCDataChannelOpen;
    onDataChannelState?.call(_state);
  }

  @override
  Future<void> send(RTCDataChannelMessage message) async {
    sent.add(message);
    remote!.onMessage?.call(message);
  }

  @override
  Future<void> close() async {
    _state = RTCDataChannelState.RTCDataChannelClosed;
    onDataChannelState?.call(_state);
  }
}
