import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mytree_webrtc_demo/cloud/disk_credential_exchange.dart';
import 'package:mytree_webrtc_demo/signaling/signaling.dart';

const _room = '0123456789abcdef0123456789abcdef';
const _token = 'private-fixture-token';
const _binding = 'disk-binding';
const _configuration = <String, dynamic>{'iceServers': <dynamic>[]};
String _alias(String actor) => 'mytree-disk-$_room-$actor';

mixin _Events {
  final _events = <String, StreamController<dynamic>>{};

  Stream<T> on<T>(String event) => _events
      .putIfAbsent(event, () => StreamController<dynamic>.broadcast(sync: true))
      .stream
      .cast<T>();

  void emit<T>(String event, T value) => _events[event]?.add(value);

  Future<void> closeEvents() async {
    for (final controller in _events.values) {
      await controller.close();
    }
  }
}

class _Network {
  bool autoRegister = true;
  bool failFactory = false;
  final peers = <_Peer>[];
  final channels = <_Channel>[];
  final configurations = <Map<String, dynamic>>[];
  final registered = <String, _Peer>{};

  SignalingPeer create(String id, Map<String, dynamic> configuration) {
    configurations.add(configuration);
    if (failFactory) throw StateError('Unavailable');
    final peer = _Peer(this, id);
    peers.add(peer);
    return peer;
  }

  _Channel incoming(String local, String remote, {bool open = true}) {
    final channel = _Channel(remote);
    channels.add(channel);
    registered[_alias(local)]!.emit<RoomChannel>('connection', channel);
    if (open) channel.openChannel();
    return channel;
  }

  Iterable<_Channel> get accesses => channels.where(
    (channel) => channel.sent.any((packet) => packet['type'] == 'diskAccess'),
  );

  Future<void> close() async {
    for (final peer in peers) {
      peer.dispose();
      await peer.closeEvents();
    }
    for (final channel in channels) {
      channel.dispose();
      await channel.closeEvents();
    }
  }
}

class _Peer with _Events implements SignalingPeer {
  _Peer(this.network, this.id);
  final _Network network;
  @override
  final String id;
  final targets = <String>[];
  bool disposed = false;
  @override
  bool open = false;
  @override
  bool get disconnected => !open;
  @override
  String get service => 'fixture';
  @override
  Stream<String?> get onOpen => on<String?>('open');
  @override
  Stream<RoomChannel> get onConnection => on<RoomChannel>('connection');
  @override
  Stream<SignalingFailure> get onError => on<SignalingFailure>('error');
  @override
  Stream<void> get onDisconnected => on<void>('disconnected');
  @override
  Stream<void> get onClose => on<void>('close');

  @override
  void start() {
    if (network.autoRegister) scheduleMicrotask(register);
  }

  void register() {
    if (disposed) return;
    final occupied = network.registered[id];
    if (occupied != null && !occupied.disposed) {
      emit(
        'error',
        const SignalingFailure(SignalingFailureKind.idTaken, 'ID taken'),
      );
      return;
    }
    network.registered[id] = this;
    open = true;
    emit<String?>('open', id);
  }

  @override
  RoomChannel connect(String target) {
    if (!open || disposed) throw StateError('Not registered');
    targets.add(target);
    final outgoing = _Channel(target);
    network.channels.add(outgoing);
    final remote = network.registered[target];
    if (remote == null || remote.disposed) return outgoing;
    final incoming = _Channel(id);
    network.channels.add(incoming);
    incoming.other = outgoing;
    outgoing.other = incoming;
    scheduleMicrotask(() {
      if (disposed || remote.disposed || outgoing.disposed) return;
      remote.emit<RoomChannel>('connection', incoming);
      scheduleMicrotask(() {
        incoming.openChannel();
        outgoing.openChannel();
      });
    });
    return outgoing;
  }

  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    open = false;
    if (identical(network.registered[id], this)) network.registered.remove(id);
  }
}

class _Channel with _Events implements RoomChannel {
  _Channel(this.peer);
  @override
  final String peer;
  @override
  bool disposed = false;
  @override
  bool open = false;
  _Channel? other;
  Completer<void>? helloCompletion;
  bool failSend = false;
  final sent = <Map<String, dynamic>>[];
  @override
  String get service => 'fixture';
  @override
  ChannelConnectivity get connectivity => disposed
      ? ChannelConnectivity.closed
      : open
      ? ChannelConnectivity.connected
      : ChannelConnectivity.connecting;
  @override
  Stream<void> get onOpen => on<void>('open');
  @override
  Stream<Object?> get onData => on<Object?>('data');
  @override
  Stream<Object> get onError => on<Object>('error');
  @override
  Stream<void> get onClose => on<void>('close');
  @override
  Stream<ChannelConnectivity> get onConnectivity =>
      on<ChannelConnectivity>('connectivity');

  void openChannel() {
    if (disposed) return;
    open = true;
    emit<void>('open', null);
  }

  @override
  Future<void> send(Map<String, dynamic> packet) async {
    if (disposed || !open || failSend) throw StateError('Send failed');
    final snapshot = (jsonDecode(jsonEncode(packet)) as Map)
        .cast<String, dynamic>();
    sent.add(snapshot);
    final remote = other;
    if (remote != null) {
      scheduleMicrotask(() {
        if (remote.open && !remote.disposed) {
          remote.emit<Object?>('data', snapshot);
        }
      });
    }
    if (packet['type'] == 'diskHello') await helloCompletion?.future;
  }

  void receive(Object? packet) => emit<Object?>('data', packet);

  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    open = false;
    final remote = other;
    if (remote != null && !remote.disposed) {
      scheduleMicrotask(() => remote.emit<void>('close', null));
    }
  }
}

// Browser-only transport: the alias registry stays local, but messages traverse
// real RTCPeerConnections/SCTP/DTLS. Only SDP passes through the rendezvous.
class _RtcNetwork extends _Network {
  final connections = <RTCPeerConnection>[];
  final descriptions = <String>[];
  final failures = <Object>[];

  @override
  SignalingPeer create(String id, Map<String, dynamic> configuration) {
    final peer = _RtcPeer(this, id);
    peers.add(peer);
    return peer;
  }

  Future<RTCSessionDescription> _gather(
    RTCPeerConnection pc,
    RTCSessionDescription description,
  ) async {
    final gathered = Completer<void>();
    pc.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !gathered.isCompleted) {
        gathered.complete();
      }
    };
    await pc.setLocalDescription(description);
    if (pc.iceGatheringState !=
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      await gathered.future.timeout(const Duration(seconds: 5));
    }
    final result = (await pc.getLocalDescription())!;
    descriptions.add(result.sdp!);
    return result;
  }

  Future<void> negotiate(_RtcChannel outgoing, _RtcChannel incoming) async {
    final local = await createPeerConnection(_configuration);
    connections.add(local);
    final remote = await createPeerConnection(_configuration);
    connections.add(remote);
    remote.onDataChannel = incoming.attach;
    outgoing.attach(
      await local.createDataChannel(
        'disk-credentials',
        RTCDataChannelInit()..ordered = true,
      ),
    );
    final offer = await _gather(local, await local.createOffer());
    await remote.setRemoteDescription(offer);
    final answer = await _gather(remote, await remote.createAnswer());
    await local.setRemoteDescription(answer);
  }

  @override
  Future<void> close() async {
    await super.close();
    for (final pc in connections) {
      await pc.close();
      await pc.dispose();
    }
  }
}

class _RtcPeer extends _Peer {
  _RtcPeer(_RtcNetwork super.network, super.id);

  @override
  RoomChannel connect(String target) {
    targets.add(target);
    final rtc = network as _RtcNetwork;
    final outgoing = _RtcChannel(target);
    final incoming = _RtcChannel(id);
    rtc.channels.addAll([outgoing, incoming]);
    scheduleMicrotask(() {
      rtc.registered[target]!.emit<RoomChannel>('connection', incoming);
      unawaited(
        rtc.negotiate(outgoing, incoming).catchError((Object error) {
          rtc.failures.add(error);
        }),
      );
    });
    return outgoing;
  }
}

class _RtcChannel extends _Channel {
  _RtcChannel(super.peer);
  RTCDataChannel? _dc;

  void attach(RTCDataChannel dc) {
    _dc = dc;
    dc.onMessage = (message) => receive(jsonDecode(message.text));
    dc.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) openChannel();
    };
    if (dc.state == RTCDataChannelState.RTCDataChannelOpen) openChannel();
  }

  @override
  Future<void> send(Map<String, dynamic> packet) async {
    if (!open || disposed) throw StateError('Channel not open');
    sent.add(Map<String, dynamic>.from(packet));
    await _dc!.send(RTCDataChannelMessage(jsonEncode(packet)));
  }

  @override
  void dispose() {
    if (disposed) return;
    super.dispose();
    final dc = _dc;
    if (dc != null) {
      dc.onMessage = null;
      dc.onDataChannelState = null;
      unawaited(dc.close());
    }
  }
}

class _Client {
  _Client(this.network, this.actor, this.roles, {bool hasCredentials = false}) {
    if (hasCredentials) credentials = _credentials();
    exchange = DiskCredentialExchange(
      roomId: _room,
      actorId: actor,
      peerFactory: network.create,
      rtcConfiguration: _configuration,
      isEditor: roles.contains,
      readCredentials: () => credentials,
      activeBindingId: () => binding,
      onCredentials: (id, token) async {
        received.add((id, token));
        final save = saveCredentials;
        if (save != null) await save(id, token);
        if (binding == id && enabled && roles.contains(actor)) {
          credentials = _credentials(binding: id, token: token);
        }
      },
    );
  }

  final _Network network;
  final String actor;
  final Set<String> roles;
  late final DiskCredentialExchange exchange;
  bool enabled = true;
  String? binding = _binding;
  Map<String, dynamic>? credentials;
  Future<void> Function(String, String)? saveCredentials;
  final received = <(String, String)>[];

  void update({Iterable<String>? editors}) =>
      exchange.update(enabled: enabled, editorActors: editors ?? roles);
}

Map<String, dynamic> _credentials({
  String binding = _binding,
  String token = _token,
}) => {'v': 1, 'bindingId': binding, 'token': token};

Map<String, dynamic> _hello(String actor) => {
  'v': 1,
  'roomId': _room,
  'actor': actor,
  'type': 'diskHello',
};

Map<String, dynamic> _access(
  String actor, {
  String binding = _binding,
  String token = _token,
}) => {
  ..._hello(actor),
  'type': 'diskAccess',
  'bindingId': binding,
  'token': token,
};

Iterable<Map<String, dynamic>> _secrets(_Channel channel) =>
    channel.sent.where((packet) => packet['type'] == 'diskAccess');

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump();
  }
}

void main() {
  late _Network network;
  late List<_Client> clients;

  setUp(() {
    network = _Network();
    clients = [];
  });

  _Client client(String actor, Set<String> roles, {bool secret = false}) {
    final result = _Client(network, actor, roles, hasCredentials: secret);
    clients.add(result);
    return result;
  }

  void exchangeTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        for (final client in clients) {
          client.exchange.dispose();
        }
        await _settle(tester);
      }
    });
  }

  tearDown(() async {
    for (final client in clients) {
      client.exchange.dispose();
    }
    await network.close();
  });

  testWidgets(
    'browser exchanges over real DTLS, not through SDP or the guest host',
    (tester) async {
      await tester.runAsync(() async {
        final rtc = _RtcNetwork();
        final roles = {'a', 'b'};
        final owner = _Client(rtc, 'a', roles, hasCredentials: true);
        final recipient = _Client(rtc, 'b', roles);
        final guest = _Client(rtc, 'guest-host', roles);
        final saved = Completer<void>();
        recipient.saveCredentials = (_, _) async => saved.complete();
        try {
          guest.update();
          recipient.update();
          await Future<void>.delayed(Duration.zero);
          owner.update();
          await saved.future.timeout(const Duration(seconds: 15));
          await Future<void>.delayed(Duration.zero);
          expect(recipient.credentials, _credentials());
          expect(guest.credentials, isNull);
          expect(rtc.peers.map((peer) => peer.id).toSet(), {
            _alias('a'),
            _alias('b'),
          });
          expect(rtc.failures, isEmpty);
          expect(rtc.descriptions, hasLength(2));
          for (final description in rtc.descriptions) {
            expect(description, contains('a=fingerprint:sha-256'));
            expect(description, isNot(contains(_token)));
          }
          expect(rtc.accesses, isNotEmpty);
          for (final channel in rtc.accesses) {
            expect(channel.sent.first['type'], 'diskHello');
            expect(_secrets(channel).single['token'], _token);
          }
        } finally {
          owner.exchange.dispose();
          recipient.exchange.dispose();
          guest.exchange.dispose();
          await rtc.close();
        }
      });
    },
    skip: !kIsWeb,
  );

  for (final actors in [
    <String>['a', 'b'],
    <String>['a', 'b', 'c'],
  ]) {
    exchangeTest('${actors.length} editors exchange directly without a host', (
      tester,
    ) async {
      final roles = actors.toSet();
      // Register in reverse order so every deterministic dial finds its target.
      for (final actor in actors.reversed) {
        client(actor, roles, secret: actor == 'a').update();
        await _settle(tester);
      }
      expect(network.peers, hasLength(actors.length));
      expect(network.configurations, everyElement(_configuration));
      for (final participant in clients) {
        expect(participant.credentials, _credentials());
      }
      final connections = [
        for (final peer in network.peers)
          for (final target in peer.targets) (peer.id, target),
      ];
      expect(connections, hasLength(actors.length * (actors.length - 1) ~/ 2));
      for (final (from, to) in connections) {
        expect(from.compareTo(to), lessThan(0));
      }
      for (final channel in network.accesses) {
        expect(channel.sent.first['type'], 'diskHello');
        expect(channel.sent.first.keys.toSet(), {
          'v',
          'roomId',
          'actor',
          'type',
        });
        for (final packet in _secrets(channel)) {
          expect(packet, _access(packet['actor'] as String));
          expect(packet.containsKey('history'), isFalse);
        }
      }
      for (var i = 0; i < 100; i++) {
        for (final participant in clients) {
          participant.update();
        }
      }
      await tester.pump(const Duration(seconds: 60));
      await _settle(tester);
      expect(network.peers, hasLength(actors.length));
      expect(network.channels, hasLength(connections.length * 2));
      for (final channel in network.accesses) {
        expect(_secrets(channel), hasLength(1));
      }
    });
  }

  exchangeTest('guest, implicit editor and disabled leader never open a peer', (
    tester,
  ) async {
    final roles = {'editor'};
    client('guest', roles, secret: true).update(editors: {'guest', 'editor'});
    client('implicit-editor', roles, secret: true).update();
    final disabled = client('editor', roles, secret: true)..enabled = false;
    disabled.update();
    await tester.pump(const Duration(minutes: 1));
    expect(network.peers, isEmpty);
    disabled.enabled = true;
    disabled.update();
    await _settle(tester);
    expect(network.peers.single.id, _alias('editor'));
  });

  exchangeTest(
    'exact alias, durable role and deterministic direction required',
    (tester) async {
      final receiver = client('b', {'a', 'b', 'c'}, secret: true)..update();
      await _settle(tester);
      for (final alias in [
        _alias('guest'),
        'a',
        'mytree-disk-another-room-a',
        '${_alias('a')}-suffix',
        _alias('b'),
        _alias('c'), // c must accept, not initiate, a connection from b.
      ]) {
        final channel = network.incoming('b', alias);
        channel.receive(_hello('a'));
        await _settle(tester);
        expect(channel.disposed, isTrue);
        expect(channel.sent, isEmpty);
      }
      // Even an isEditor identity is unknown if not supplied in editorActors.
      receiver.update(editors: {'b', 'c'});
      final unknown = network.incoming('b', _alias('a'));
      expect(unknown.disposed, isTrue);
      receiver.update();
      final accepted = network.incoming('b', _alias('a'));
      await _settle(tester);
      expect(accepted.sent, [_hello('b')]);
      accepted.receive(_hello('a'));
      await _settle(tester);
      expect(_secrets(accepted), [_access('b')]);
      final duplicate = network.incoming('b', _alias('a'));
      expect(duplicate.disposed, isTrue);
      expect(accepted.disposed, isFalse);
    },
  );

  exchangeTest('no secret without handshake; pending channels expire at 8s', (
    tester,
  ) async {
    client('b', {'a', 'b'}, secret: true).update();
    await _settle(tester);
    final waiting = network.incoming('b', _alias('a'));
    await _settle(tester);
    expect(waiting.sent, [_hello('b')]);
    await tester.pump(const Duration(seconds: 7));
    expect(waiting.disposed, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(waiting.disposed, isTrue);
    expect(_secrets(waiting), isEmpty);
    final unopened = network.incoming('b', _alias('a'), open: false);
    await tester.pump(const Duration(seconds: 8));
    expect(unopened.disposed, isTrue);
    unopened.openChannel();
    unopened.receive(_hello('a'));
    expect(unopened.sent, isEmpty);
  });

  final malformedHellos = <Object?>[
    null,
    'not a map',
    <String, dynamic>{},
    {..._hello('a'), 'v': 2},
    {..._hello('a'), 'v': '1'},
    {..._hello('a'), 'roomId': 'other'},
    {..._hello('a'), 'actor': 'c'},
    {..._hello('a'), 'history': <dynamic>[]},
    {..._hello('a'), 'type': 'unknown'},
    _access('a'),
  ];
  for (var index = 0; index < malformedHellos.length; index++) {
    exchangeTest('malformed/early handshake $index cannot disclose a token', (
      tester,
    ) async {
      final receiver = client('b', {'a', 'b'}, secret: true)..update();
      await _settle(tester);
      final channel = network.incoming('b', _alias('a'));
      await _settle(tester);
      channel.receive(malformedHellos[index]);
      channel.receive(_hello('a'));
      await _settle(tester);
      expect(channel.disposed, isTrue);
      expect(_secrets(channel), isEmpty);
      expect(receiver.received, isEmpty);
    });
  }

  exchangeTest('malformed access is rejected even after a valid handshake', (
    tester,
  ) async {
    final receiver = client('b', {'a', 'b'})..update();
    await _settle(tester);
    for (final packet in [
      {..._access('a'), 'v': 2},
      {..._access('a'), 'roomId': 'another-room'},
      _access('another-actor'),
      {..._access('a'), 'history': <dynamic>[]},
      {..._access('a'), 'bindingId': null},
      {..._access('a'), 'bindingId': 3},
      {..._access('a'), 'bindingId': ''},
      {..._access('a'), 'token': null},
      {..._access('a'), 'token': 42},
    ]) {
      final channel = network.incoming('b', _alias('a'));
      channel.receive(_hello('a'));
      await _settle(tester);
      channel.receive(packet);
      await _settle(tester);
      expect(channel.disposed, isTrue);
      expect(receiver.received, isEmpty);
    }
  });

  final invalidTokens = [
    '',
    ' a',
    'a ',
    'a b',
    'a\n',
    '\x00',
    '\x7f',
    'é',
    'x' * 4097,
  ];
  for (var index = 0; index < invalidTokens.length; index++) {
    exchangeTest('noncanonical token case $index', (tester) async {
      final token = invalidTokens[index];
      final receiver = client('b', {'a', 'b'})..update();
      await _settle(tester);
      final channel = network.incoming('b', _alias('a'));
      channel.receive(_hello('a'));
      await _settle(tester);
      channel.receive(_access('a', token: token));
      await _settle(tester);
      expect(receiver.received, isEmpty);
      expect(channel.disposed, isTrue);
    });
  }

  exchangeTest('canonical ASCII boundary tokens and current binding accepted', (
    tester,
  ) async {
    final receiver = client('b', {'a', 'b'})..update();
    await _settle(tester);
    final channel = network.incoming('b', _alias('a'));
    channel.receive(_hello('a'));
    await _settle(tester);
    for (final token in ['!', '~', 'x' * 4096]) {
      channel.receive(_access('a', token: token));
      await _settle(tester);
      expect(receiver.credentials, _credentials(token: token));
    }
    expect(receiver.received, hasLength(3));
    channel.receive(_access('a', token: 'x' * 4096));
    await _settle(tester);
    expect(receiver.received, hasLength(3));
    channel.receive(_access('a', binding: 'old-binding'));
    receiver.binding = null;
    channel.receive(_access('a'));
    await _settle(tester);
    expect(receiver.received, hasLength(3));
  });

  exchangeTest('stale local credentials withheld; rotations sent once live', (
    tester,
  ) async {
    final owner = client('b', {'a', 'b'}, secret: true)
      ..binding = 'new-binding'
      ..update();
    await _settle(tester);
    final channel = network.incoming('b', _alias('a'));
    channel.receive(_hello('a'));
    await _settle(tester);
    expect(_secrets(channel), isEmpty);
    owner.credentials = _credentials(binding: 'new-binding');
    owner.update();
    await _settle(tester);
    expect(_secrets(channel), hasLength(1));
    owner.credentials = _credentials(binding: 'new-binding', token: 'rotated');
    for (var i = 0; i < 20; i++) {
      owner.update();
    }
    await _settle(tester);
    expect(_secrets(channel), hasLength(2));
    owner.credentials = _credentials(binding: 'new-binding');
    owner.update();
    await _settle(tester);
    expect(_secrets(channel), hasLength(2));
    owner.binding = 'third-binding';
    owner.update();
    expect(_secrets(channel), hasLength(2));
    owner.credentials = _credentials(binding: 'third-binding', token: 'third');
    owner.update();
    await _settle(tester);
    expect(
      _secrets(channel).last,
      _access('b', binding: 'third-binding', token: 'third'),
    );
    expect(network.peers, hasLength(1));
    expect(channel.disposed, isFalse);
  });

  exchangeTest('malformed local credential never sent', (tester) async {
    final owner = client('b', {'a', 'b'}, secret: true)..update();
    await _settle(tester);
    final channel = network.incoming('b', _alias('a'));
    owner.credentials = {'bindingId': _binding, 'token': 'space token'};
    channel.receive(_hello('a'));
    await _settle(tester);
    expect(_secrets(channel), isEmpty);
    owner.credentials = {'bindingId': _binding, 'token': 123};
    owner.update();
    expect(_secrets(channel), isEmpty);
  });

  for (final action in ['disable', 'dispose', 'binding', 'role']) {
    exchangeTest('late hello completion cannot send after $action change', (
      tester,
    ) async {
      final roles = {'a', 'b'};
      final owner = client('b', roles, secret: true)..update();
      await _settle(tester);
      final channel = network.incoming('b', _alias('a'), open: false);
      final completion = Completer<void>();
      channel.helloCompletion = completion;
      channel.openChannel();
      channel.receive(_hello('a'));
      switch (action) {
        case 'disable':
          owner.enabled = false;
          owner.update();
        case 'dispose':
          owner.exchange.dispose();
        case 'binding':
          owner.binding = 'replacement-binding';
          owner.update();
        case 'role':
          roles.remove('a');
          owner.update();
      }
      completion.complete();
      channel.receive(_access('a'));
      await _settle(tester);
      expect(_secrets(channel), isEmpty);
      expect(owner.received, isEmpty);
    });
  }

  exchangeTest('revoked durable role is rechecked without an update', (
    tester,
  ) async {
    final roles = {'a', 'b'};
    final owner = client('b', roles, secret: true)..update();
    await _settle(tester);
    final channel = network.incoming('b', _alias('a'));
    roles.remove('a');
    channel.receive(_hello('a'));
    channel.receive(_access('a'));
    await _settle(tester);
    expect(_secrets(channel), isEmpty);
    expect(owner.received, isEmpty);
    await tester.pump(const Duration(seconds: 20));
    expect(channel.disposed, isTrue);
    roles.remove('b');
    owner.update();
    expect(network.peers.single.disposed, isTrue);
  });

  exchangeTest('pending save cannot publish after binding change or disposal', (
    tester,
  ) async {
    final receiver = client('b', {'a', 'b'})..update();
    final saved = Completer<void>();
    receiver.saveCredentials = (_, _) => saved.future;
    await _settle(tester);
    final channel = network.incoming('b', _alias('a'));
    channel.receive(_hello('a'));
    await _settle(tester);
    channel.receive(_access('a'));
    receiver.binding = 'replacement';
    receiver.exchange.dispose();
    saved.complete();
    await _settle(tester);
    expect(receiver.credentials, isNull);
    expect(_secrets(channel), isEmpty);
  });

  exchangeTest('save/send failures close quietly and retry without false ack', (
    tester,
  ) async {
    final receiver = client('b', {'a', 'b'})..update();
    receiver.saveCredentials = (_, _) => Future.error(StateError(_token));
    await _settle(tester);
    final channel = network.incoming('b', _alias('a'));
    channel.receive(_hello('a'));
    await _settle(tester);
    channel.receive(_access('a'));
    await _settle(tester);
    expect(receiver.credentials, isNull);
    expect(channel.disposed, isTrue);
    expect(_secrets(channel), isEmpty);
    receiver.credentials = _credentials();
    final broken = network.incoming('b', _alias('a'), open: false)
      ..failSend = true;
    broken.openChannel();
    await _settle(tester);
    expect(broken.disposed, isTrue);
    expect(broken.sent, isEmpty);
  });

  exchangeTest('failed credential save retries on a fresh channel at 20s', (
    tester,
  ) async {
    final roles = {'a', 'b'};
    final recipient = client('b', roles);
    var failSave = true;
    recipient.saveCredentials = (_, _) async {
      if (failSave) throw StateError('Local save failed');
    };
    recipient.update();
    await _settle(tester);
    client('a', roles, secret: true).update();
    await _settle(tester);
    expect(recipient.credentials, isNull);
    expect(recipient.received, hasLength(1));
    expect(network.channels.every((channel) => channel.disposed), isTrue);
    failSave = false;
    await tester.pump(const Duration(seconds: 20));
    await _settle(tester);
    expect(recipient.received, hasLength(2));
    expect(recipient.credentials, _credentials());
    expect(network.peers, hasLength(2));
  });

  exchangeTest('offline target retries at 20s, not on frequent updates', (
    tester,
  ) async {
    final roles = {'a', 'b'};
    final first = client('a', roles, secret: true)..update();
    await _settle(tester);
    expect(network.peers.single.targets, [_alias('b')]);
    final waiting = network.channels.single;
    for (var i = 0; i < 100; i++) {
      first.update();
    }
    await tester.pump(const Duration(seconds: 8));
    expect(waiting.disposed, isTrue);
    final second = client('b', roles)..update();
    await _settle(tester);
    for (var i = 0; i < 100; i++) {
      first.update();
    }
    await tester.pump(const Duration(seconds: 11));
    expect(network.peers.first.targets, hasLength(1));
    await tester.pump(const Duration(seconds: 1));
    await _settle(tester);
    expect(second.credentials, _credentials());
    expect(network.peers.first.targets, hasLength(2));
    expect(network.peers, hasLength(2));
  });

  exchangeTest('registration failure and disconnect retry only at 20s', (
    tester,
  ) async {
    network.autoRegister = false;
    final owner = client('a', {'a'})..update();
    final original = network.peers.single;
    for (var i = 0; i < 50; i++) {
      owner.update();
    }
    await tester.pump(const Duration(seconds: 19));
    expect(network.peers, hasLength(1));
    network.autoRegister = true;
    await tester.pump(const Duration(seconds: 1));
    await _settle(tester);
    expect(original.disposed, isTrue);
    expect(network.peers, hasLength(2));
    final active = network.peers.last;
    active.emit<void>('disconnected', null);
    owner.update();
    expect(active.disposed, isTrue);
    expect(network.peers, hasLength(2));
    await tester.pump(const Duration(seconds: 20));
    await _settle(tester);
    expect(network.peers, hasLength(3));
    expect(network.peers.last.id, _alias('a'));
  });

  exchangeTest('factory exceptions retry, stable idTaken does not storm', (
    tester,
  ) async {
    network.failFactory = true;
    final first = client('a', {'a'})..update();
    expect(network.peers, isEmpty);
    network.failFactory = false;
    await tester.pump(const Duration(seconds: 20));
    await _settle(tester);
    final leader = network.peers.single;
    final follower = client('a', {'a'})..update();
    await _settle(tester);
    expect(network.peers, hasLength(2));
    expect(network.peers.last.disposed, isTrue);
    for (var i = 0; i < 100; i++) {
      follower.update();
    }
    expect(network.peers, hasLength(2));
    expect(leader.disposed, isFalse);
    expect(network.peers.every((peer) => peer.id == _alias('a')), isTrue);
    follower.enabled = false;
    follower.update();
    first.exchange.dispose();
    await tester.pump(const Duration(minutes: 1));
    expect(network.peers, hasLength(2));
  });

  exchangeTest(
    'new editor added once; disable/re-enable isolates generations',
    (tester) async {
      final roles = {'a'};
      final owner = client('a', roles, secret: true)..update();
      await _settle(tester);
      final oldPeer = network.peers.single;
      roles.add('b');
      owner.update();
      owner.update();
      expect(oldPeer.targets, [_alias('b')]);
      final oldChannel = network.channels.single;
      owner.enabled = false;
      owner.update();
      oldPeer.emit<String?>('open', _alias('a'));
      oldChannel.openChannel();
      oldChannel.receive(_hello('b'));
      expect(oldChannel.sent, isEmpty);
      owner.enabled = true;
      owner.update();
      await _settle(tester);
      expect(network.peers, hasLength(2));
      expect(oldPeer.disposed, isTrue);
      expect(network.peers.last.id, oldPeer.id);
      owner.exchange.dispose();
      owner.update();
      await tester.pump(const Duration(minutes: 1));
      expect(network.peers, hasLength(2));
    },
  );
}
