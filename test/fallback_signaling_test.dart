import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/signaling/fallback_signaling.dart';
import 'package:mytree_webrtc_demo/signaling/signaling.dart';

const _id = 'mytree-room-test';
const _delay = Duration(milliseconds: 100);
const _unavailable = SignalingFailure(
  SignalingFailureKind.unavailable,
  'PeerJS websocket blocked',
);

// These doubles exercise only the shared contracts, without PeerJS, MQTT or RTC.
mixin _Events {
  final _events = <String, StreamController<dynamic>>{};
  bool _emitting = false;

  Stream<T> events<T>(String name) => _events
      .putIfAbsent(name, () => StreamController<dynamic>.broadcast(sync: true))
      .stream
      .cast<T>();

  void emit(String name, Object? value) {
    final previous = _emitting;
    _emitting = true;
    try {
      _events[name]?.add(value);
    } finally {
      _emitting = previous;
    }
  }

  Future<void> closeEvents() async {
    for (final controller in _events.values) {
      await controller.close();
    }
  }
}

class _FakePeer with _Events implements SignalingPeer {
  _FakePeer(this.id, this.service);

  @override
  final String id;
  @override
  final String service;
  @override
  bool open = false;
  @override
  bool disconnected = false;
  bool disposed = false;
  int starts = 0;
  int disposals = 0;
  Object? startError;
  Object? connectError;
  void Function(_FakePeer)? onStart;
  _FakeChannel Function(String)? onConnect;
  final outbound = <_FakeChannel>[];
  final attached = <_FakeChannel>[];

  @override
  Stream<String?> get onOpen => events<String?>('open');
  @override
  Stream<RoomChannel> get onConnection => events<RoomChannel>('connection');
  @override
  Stream<SignalingFailure> get onError => events<SignalingFailure>('error');
  @override
  Stream<void> get onDisconnected => events<void>('disconnected');
  @override
  Stream<void> get onClose => events<void>('close');

  @override
  void start() {
    starts++;
    if (startError != null) throw startError!;
    onStart?.call(this);
  }

  void register() {
    open = true;
    disconnected = false;
    emit('open', id);
  }

  void fail(SignalingFailure error) => emit('error', error);

  void loseSignaling() {
    open = false;
    disconnected = true;
    emit('disconnected', null);
  }

  @override
  RoomChannel connect(String peer) {
    if (connectError != null) throw connectError!;
    final channel = onConnect?.call(peer) ?? _FakeChannel(peer, service);
    outbound.add(channel);
    attached.add(channel);
    return channel;
  }

  @override
  void dispose() {
    if (_emitting) throw StateError('Peer disposed inside synchronous event');
    if (disposed) return;
    disposed = true;
    disposals++;
    open = false;
    disconnected = true;
    for (final channel in attached) {
      channel.dispose();
    }
  }
}

class _DiscoveringPeer extends _FakePeer implements SignalingDiscovery {
  _DiscoveringPeer(super.id, super.service);

  @override
  bool discoveryComplete = false;
  @override
  Stream<void> get onDiscoveryChanged => events<void>('discovery');

  @override
  void register() {
    discoveryComplete = true;
    super.register();
    emit('discovery', null);
  }

  void registrationPending() {
    discoveryComplete = false;
    emit('discovery', null);
  }
}

class _FakeChannel with _Events implements RoomChannel {
  _FakeChannel(this.peer, this.service);

  @override
  final String peer;
  @override
  final String service;
  @override
  bool open = false;
  @override
  bool disposed = false;
  @override
  ChannelConnectivity connectivity = ChannelConnectivity.connecting;
  int disposals = 0;
  _FakeChannel? other;
  final sent = <Map<String, dynamic>>[];

  @override
  Stream<void> get onOpen => events<void>('open');
  @override
  Stream<Object?> get onData => events<Object?>('data');
  @override
  Stream<Object> get onError => events<Object>('error');
  @override
  Stream<void> get onClose => events<void>('close');
  @override
  Stream<ChannelConnectivity> get onConnectivity =>
      events<ChannelConnectivity>('connectivity');

  // Intentionally allow stale events even after disposal, like a queued callback.
  void openChannel() {
    open = true;
    connectivity = ChannelConnectivity.connected;
    emit('open', null);
  }

  void receive(Object? data) => emit('data', data);
  void fail(Object error) => emit('error', error);

  void changeConnectivity(ChannelConnectivity state) {
    connectivity = state;
    emit('connectivity', state);
  }

  @override
  Future<void> send(Map<String, dynamic> data) async {
    if (!open || disposed) throw StateError('Channel is not open');
    final detached = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
    sent.add(detached);
    final remote = other;
    if (remote != null) {
      scheduleMicrotask(() {
        if (remote.open && !remote.disposed) remote.receive(detached);
      });
    }
  }

  @override
  void dispose() {
    if (_emitting) {
      throw StateError('Channel disposed inside synchronous event');
    }
    if (disposed) return;
    disposed = true;
    disposals++;
    open = false;
    connectivity = ChannelConnectivity.closed;
  }
}

// A namespace per signaling service, shared by an existing host and a newcomer.
class _Bus {
  _Bus(this.service);
  final String service;
  final registered = <String, _FakePeer>{};
  final channels = <_FakeChannel>[];

  _FakePeer create(String id, Map<String, dynamic> configuration) {
    final peer = _FakePeer(id, service);
    peer.onStart = (_) => scheduleMicrotask(() {
      final previous = registered[id];
      if (previous != null && !previous.disposed) {
        peer.fail(SignalingFailure(SignalingFailureKind.idTaken, '$id taken'));
      } else if (!peer.disposed) {
        registered[id] = peer;
        peer.register();
      }
    });
    peer.onConnect = (target) {
      final outgoing = _FakeChannel(target, service);
      channels.add(outgoing);
      final remote = registered[target];
      if (remote == null || remote.disposed) return outgoing;
      final incoming = _FakeChannel(id, service);
      channels.add(incoming);
      remote.attached.add(incoming);
      outgoing.other = incoming;
      incoming.other = outgoing;
      scheduleMicrotask(() {
        if (remote.disposed || outgoing.disposed) return;
        remote.emit('connection', incoming);
        scheduleMicrotask(() {
          if (outgoing.disposed || incoming.disposed) return;
          incoming.openChannel();
          outgoing.openChannel();
        });
      });
      return outgoing;
    };
    return peer;
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump();
  }
}

void main() {
  late List<FallbackSignalingPeer> wrappers;
  late List<_FakePeer> peers;
  late List<_Bus> buses;

  setUp(() {
    wrappers = [];
    peers = [];
    buses = [];
  });

  FallbackSignalingPeer productionPolicy(String id) {
    // Inspect factory settings only; never start real signaling providers.
    final result =
        createSignalingPeer(id, const {'iceServers': []})
            as FallbackSignalingPeer;
    wrappers.add(result);
    return result;
  }

  FallbackSignalingPeer wrapper({
    String id = _id,
    Duration preferenceDelay = _delay,
    Duration? channelRaceDelay,
    List<SignalingPeerFactory>? providers,
  }) {
    final result = FallbackSignalingPeer(
      id: id,
      configuration: const {'iceServers': []},
      preferenceDelay: preferenceDelay,
      channelRaceDelay: channelRaceDelay,
      providers:
          providers ??
          [
            (id, config) {
              final peer = _FakePeer(id, 'PeerJS');
              peers.add(peer);
              return peer;
            },
            (id, config) {
              final peer = _FakePeer(id, 'MQTT');
              peers.add(peer);
              return peer;
            },
          ],
    );
    wrappers.add(result);
    return result;
  }

  void testSignaling(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        // Flutter checks pending fake timers before normal tearDown callbacks.
        for (final peer in wrappers) {
          peer.dispose();
        }
        await _settle(tester);
        final channels = <_FakeChannel>{
          for (final peer in peers) ...peer.attached,
          for (final bus in buses) ...bus.channels,
        };
        for (final channel in channels) {
          channel.dispose();
          await channel.closeEvents();
        }
        for (final peer in peers) {
          peer.dispose();
          await peer.closeEvents();
        }
      }
    });
  }

  test('empty provider list is rejected', () {
    expect(() => wrapper(providers: []), throwsArgumentError);
  });

  testSignaling(
    'first provider opens but only both registrations complete discovery',
    (tester) async {
      final peer = wrapper();
      final opens = <String?>[];
      final coverage = <bool>[];
      peer.onOpen.listen(opens.add);
      peer.onDiscoveryChanged.listen(
        (_) => coverage.add(peer.discoveryComplete),
      );
      expect(peer.discoveryComplete, isFalse);
      peer.start();
      await _settle(tester);
      expect(coverage, [false]);
      expect(
        peers.first,
        isNot(isA<SignalingDiscovery>()),
        reason: 'Existing custom providers need no new interface members',
      );

      peers[0].register();
      await _settle(tester);
      expect(opens, [_id]);
      expect(peer.open, isTrue);
      expect(peer.discoveryComplete, isFalse);
      expect(coverage, [false, false]);

      peers[1].register();
      await _settle(tester);
      expect(peer.discoveryComplete, isTrue);
      expect(coverage, [false, false, true]);
      expect(opens, [_id], reason: 'Secondary readiness is not another onOpen');

      peers[0].register();
      peers[1].register();
      await _settle(tester);
      expect(coverage, [
        false,
        false,
        true,
      ], reason: 'Duplicate opens are not changes');
    },
  );

  testSignaling(
    'secondary pending capability invalidates otherwise open discovery',
    (tester) async {
      final primary = _DiscoveringPeer(_id, 'arbitrary primary');
      final secondary = _DiscoveringPeer(_id, 'arbitrary secondary');
      peers.addAll([primary, secondary]);
      final peer = wrapper(providers: [(_, _) => primary, (_, _) => secondary])
        ..start();
      primary.register();
      secondary.register();
      await _settle(tester);
      expect(peer.discoveryComplete, isTrue);
      final coverage = <bool>[];
      peer.onDiscoveryChanged.listen(
        (_) => coverage.add(peer.discoveryComplete),
      );

      secondary.registrationPending();
      await _settle(tester);
      expect(peer.open, isTrue);
      expect(
        secondary.open,
        isTrue,
        reason: 'Transport getters may remain stale',
      );
      expect(peer.discoveryComplete, isFalse);
      expect(coverage, [false]);

      secondary.register();
      await _settle(tester);
      expect(peer.discoveryComplete, isTrue);
      expect(coverage.last, isTrue);
    },
  );

  for (final failedBackend in [0, 1]) {
    for (final collision in [false, true]) {
      testSignaling(
        'late ${collision ? 'collision' : 'offline'} on provider $failedBackend clears discovery without closing RTC',
        (tester) async {
          final peer = wrapper()..start();
          peers[0].register();
          peers[1].register();
          final channel = peer.connect('host');
          await _settle(tester);
          final active = peers[0].outbound.single;
          active.openChannel();
          expect(peer.discoveryComplete, isTrue);
          final coverage = <bool>[];
          peer.onDiscoveryChanged.listen(
            (_) => coverage.add(peer.discoveryComplete),
          );
          if (collision) {
            peers[failedBackend].fail(
              const SignalingFailure(
                SignalingFailureKind.idTaken,
                'Alias contention after registration',
              ),
            );
          } else {
            peers[failedBackend].loseSignaling();
          }
          await _settle(tester);
          expect(peer.discoveryComplete, isFalse);
          expect(coverage, [false]);
          expect(peer.open, !collision);
          expect(channel.open, isTrue);
          expect(active.disposed, isFalse);
          await channel.send({'edit': 'still connected'});
          expect(active.sent, [
            {'edit': 'still connected'},
          ]);
          peers[failedBackend].register();
          await _settle(tester);
          expect(
            peer.discoveryComplete,
            isFalse,
            reason: 'Failed backends cannot revive',
          );
        },
      );
    }
  }

  for (final slowBackend in [0, 1]) {
    testSignaling(
      'timed out provider $slowBackend recovers a fresh registration without replacing healthy RTC',
      (tester) async {
        final peer = wrapper();
        final opens = <String?>[];
        final errors = <SignalingFailure>[];
        final coverage = <bool>[];
        peer.onOpen.listen(opens.add);
        peer.onError.listen(errors.add);
        peer.onDiscoveryChanged.listen(
          (_) => coverage.add(peer.discoveryComplete),
        );
        peer.start();
        final expired = peers[slowBackend];
        final healthy = peers[1 - slowBackend]..register();
        await tester.pump(_delay);
        final channel = peer.connect('host');
        var channelOpens = 0;
        channel.onOpen.listen((_) => channelOpens++);
        await _settle(tester);
        final active = healthy.outbound.single..openChannel();
        await tester.pump(
          Duration(milliseconds: slowBackend == 0 ? 2900 : 13900),
        );
        expect(peer.open, isTrue);
        expect(peer.discoveryComplete, isFalse);
        expect(expired.disposed, isTrue);
        expect(
          expired._events.values.every((controller) => !controller.hasListener),
          isTrue,
          reason: 'Release subscriptions before creating a replacement',
        );
        final changesBeforeRetry = coverage.length;
        await tester.pump(const Duration(milliseconds: 499));
        expect(peers, hasLength(2), reason: 'Recovery has a real backoff');
        await tester.pump(const Duration(milliseconds: 251));
        final replacement = peers.last;
        expect(peers, hasLength(3));
        expect(replacement.id, _id);
        expect(replacement.service, expired.service);
        expect(replacement.starts, 1);
        expect(coverage.length, changesBeforeRetry + 1);
        expect(coverage.last, isFalse, reason: 'Retry registration is pending');

        expired.register(); // Old registration cannot validate the new epoch.
        expired.fail(
          const SignalingFailure(
            SignalingFailureKind.idTaken,
            'Stale conflict',
          ),
        );
        expired.loseSignaling();
        await _settle(tester);
        expect(peer.discoveryComplete, isFalse);
        expect(errors, isEmpty);
        replacement.register();
        await _settle(tester);
        expect(peer.discoveryComplete, isTrue);
        expect(coverage.last, isTrue);
        expect(opens, [_id]);
        expect(healthy.starts, 1);
        expect(healthy.disposed, isFalse);
        expect(active.disposed, isFalse);
        expect(channel.open, isTrue);
        expect(channelOpens, 1);
        await channel.send({'edit': 'during registration recovery'});
        expect(active.sent, [
          {'edit': 'during registration recovery'},
        ]);
        await tester.pump(const Duration(seconds: 30));
        expect(peers, hasLength(3), reason: 'Readiness cancels retry deadline');
        expect(peer.discoveryComplete, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final slowBackend in [0, 1]) {
    testSignaling(
      'pending channel can use recovered provider $slowBackend without restarting the healthy attempt',
      (tester) async {
        final peer = wrapper()..start();
        final expired = peers[slowBackend];
        final healthy = peers[1 - slowBackend]..register();
        await tester.pump(_delay);
        final channel = peer.connect('host');
        var opens = 0;
        final errors = <Object>[];
        channel.onOpen.listen((_) => opens++);
        channel.onError.listen(errors.add);
        await _settle(tester);
        final pendingHealthy = healthy.outbound.single;
        await tester.pump(
          Duration(milliseconds: slowBackend == 0 ? 2900 : 13900),
        );
        expect(expired.disposed, isTrue);
        expect(channel.open, isFalse);
        expect(pendingHealthy.disposed, isFalse);
        await tester.pump(const Duration(milliseconds: 750));
        expect(peers, hasLength(3));
        final recovered = peers.last..register();
        await _settle(tester);
        expect(
          recovered.outbound,
          hasLength(1),
          reason:
              'A failure of an expired registration must not bar its replacement.',
        );
        recovered.register();
        await _settle(tester);
        expect(recovered.outbound, hasLength(1));
        expect(healthy.outbound, [pendingHealthy]);
        final winner = recovered.outbound.single..openChannel();
        await _settle(tester);
        expect(channel.open, isTrue);
        expect(opens, 1);
        expect(errors, isEmpty);
        expect(pendingHealthy.disposed, isTrue);
        expect(healthy.disposed, isFalse);
        await channel.send({'sync': 'recovered registration'});
        expect(winner.sent, [
          {'sync': 'recovered registration'},
        ]);
        expired.register();
        pendingHealthy.openChannel();
        await _settle(tester);
        expect(
          opens,
          1,
          reason: 'Stale registrations and losing RTC cannot win again.',
        );
        expect(winner.disposed, isFalse);
        expect(errors, isEmpty);
      },
    );
  }

  for (final slowBackend in [0, 1]) {
    testSignaling(
      'recovered provider $slowBackend does not revive an exhausted logical channel',
      (tester) async {
        final peer = wrapper()..start();
        final expired = peers[slowBackend];
        final healthy = peers[1 - slowBackend]..register();
        await tester.pump(_delay);
        final channel = peer.connect('host');
        var opens = 0;
        final errors = <Object>[];
        channel.onOpen.listen((_) => opens++);
        channel.onError.listen(errors.add);
        await _settle(tester);
        healthy.outbound.single.fail(StateError('RTC negotiation failed'));
        await _settle(tester);
        await tester.pump(
          Duration(milliseconds: slowBackend == 0 ? 2900 : 13900),
        );
        expect(expired.disposed, isTrue);
        expect(errors, hasLength(1));
        await tester.pump(const Duration(milliseconds: 750));
        expect(peers, hasLength(3));
        final recovered = peers.last..register();
        await _settle(tester);
        expect(recovered.outbound, isEmpty);
        expect(channel.open, isFalse);
        expect(opens, 0);
        expect(errors, hasLength(1));

        final next = peer.connect('host');
        next.onError.listen((_) {});
        await _settle(tester);
        await tester.pump(const Duration(milliseconds: 250));
        expect(recovered.outbound, hasLength(1));
        recovered.outbound.single.openChannel();
        await _settle(tester);
        expect(next.open, isTrue);
        expect(channel.open, isFalse);
        expect(opens, 0);
        expect(errors, hasLength(1));
      },
    );
  }

  testSignaling('retry still requires optional provider discovery coverage', (
    tester,
  ) async {
    final primary = _DiscoveringPeer(_id, 'primary');
    peers.add(primary);
    final peer = wrapper(
      providers: [
        (_, _) => primary,
        (id, _) {
          final secondary = _DiscoveringPeer(id, 'secondary');
          peers.add(secondary);
          return secondary;
        },
      ],
    )..start();
    primary.register();
    await tester.pump(const Duration(seconds: 14));
    await tester.pump(const Duration(milliseconds: 750));
    final replacement = peers.last as _DiscoveringPeer;
    replacement.open = true;
    replacement.emit('open', _id);
    await _settle(tester);
    expect(peer.open, isTrue);
    expect(peer.discoveryComplete, isFalse);
    final coverage = <bool>[];
    peer.onDiscoveryChanged.listen((_) => coverage.add(peer.discoveryComplete));
    replacement.register();
    await _settle(tester);
    expect(peer.discoveryComplete, isTrue);
    expect(coverage, [true]);
  });

  testSignaling('cold provider recovery is bounded to two jittered retries', (
    tester,
  ) async {
    final peer = wrapper()..start();
    peers[0].register();
    final errors = <SignalingFailure>[];
    peer.onError.listen(errors.add);
    await tester.pump(const Duration(seconds: 14));
    await tester.pump(const Duration(milliseconds: 750));
    expect(peers, hasLength(3));
    peers.last.fail(_unavailable);
    await _settle(tester);
    expect(peers.last.disposed, isTrue);
    await tester.pump(const Duration(milliseconds: 999));
    expect(peers, hasLength(3), reason: 'Second retry backs off longer');
    await tester.pump(const Duration(milliseconds: 251));
    expect(peers, hasLength(4));
    await tester.pump(const Duration(seconds: 14));
    await tester.pump(const Duration(minutes: 1));
    expect(peers, hasLength(4));
    expect(peers.map((p) => p.id).toSet(), {_id});
    expect(peers.skip(1).every((p) => p.disposed), isTrue);
    expect(peers[0].disposed, isFalse);
    expect(peer.open, isTrue);
    expect(peer.discoveryComplete, isFalse);
    expect(errors, isEmpty, reason: 'Failure does not imply room absence');
  });

  testSignaling('collision during retry blocks the entire logical peer', (
    tester,
  ) async {
    final peer = wrapper();
    final opens = <String?>[];
    final errors = <SignalingFailure>[];
    peer.onOpen.listen(opens.add);
    peer.onError.listen(errors.add);
    peer.start();
    peers[0].register();
    final channel = peer.connect('host');
    await _settle(tester);
    final active = peers[0].outbound.single..openChannel();
    await tester.pump(const Duration(seconds: 14));
    await tester.pump(const Duration(milliseconds: 750));
    const conflict = SignalingFailure(
      SignalingFailureKind.idTaken,
      'Identity taken during fresh registration',
    );
    peers.last.fail(conflict);
    peers.last.register();
    peers[0].register();
    await tester.pump(const Duration(minutes: 1));
    expect(errors, [same(conflict)]);
    expect(peer.open, isFalse);
    expect(peer.discoveryComplete, isFalse);
    expect(() => peer.connect('another'), throwsStateError);
    expect(peers, hasLength(3));
    expect(opens, [_id]);
    expect(channel.open, isTrue);
    expect(active.disposed, isFalse);
    await channel.send({'edit': 'existing RTC survives collision'});
    expect(active.sent, [
      {'edit': 'existing RTC survives collision'},
    ]);
  });

  for (final disposeDuringRetry in [false, true]) {
    testSignaling(
      'dispose cancels ${disposeDuringRetry ? 'active retry registration' : 'pending retry backoff'}',
      (tester) async {
        final peer = wrapper()..start();
        peers[0].register();
        await tester.pump(const Duration(seconds: 14));
        if (disposeDuringRetry) {
          await tester.pump(const Duration(milliseconds: 750));
        }
        final count = peers.length;
        peer.dispose();
        peers.last.register();
        peers.last.fail(_unavailable);
        await tester.pump(const Duration(minutes: 1));
        expect(peers, hasLength(count));
        expect(peers.every((p) => p.disposed && p.disposals == 1), isTrue);
        expect(peer.discoveryComplete, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final retryAlreadyStarted in [false, true]) {
    testSignaling(
      'loss of the only healthy provider cancels ${retryAlreadyStarted ? 'active' : 'pending'} internal recovery',
      (tester) async {
        final peer = wrapper()..start();
        peers[0].register();
        final disconnects = <void>[];
        peer.onDisconnected.listen(disconnects.add);
        await tester.pump(const Duration(seconds: 14));
        if (retryAlreadyStarted) {
          await tester.pump(const Duration(milliseconds: 750));
        }
        final count = peers.length;
        peers[0].loseSignaling();
        peers.last.register();
        await tester.pump(const Duration(minutes: 1));
        expect(disconnects, hasLength(1));
        expect(
          peers,
          hasLength(count),
          reason: 'Session retries a new wrapper',
        );
        expect(peers.last.disposed, isTrue);
        expect(peer.open, isFalse);
      },
    );
  }

  testSignaling('typed factory collision during retry is a hard conflict', (
    tester,
  ) async {
    const conflict = SignalingFailure(
      SignalingFailureKind.idTaken,
      'Retry factory detected an occupied identity',
    );
    var secondaryAttempts = 0;
    final peer = wrapper(
      providers: [
        (id, _) {
          final primary = _FakePeer(id, 'primary');
          peers.add(primary);
          return primary;
        },
        (id, _) {
          if (secondaryAttempts++ > 0) throw conflict;
          final secondary = _FakePeer(id, 'secondary');
          peers.add(secondary);
          return secondary;
        },
      ],
    );
    final errors = <SignalingFailure>[];
    peer.onError.listen(errors.add);
    peer.start();
    peers[0].register();
    await tester.pump(const Duration(seconds: 14));
    await tester.pump(const Duration(milliseconds: 750));
    await tester.pump(const Duration(minutes: 1));
    expect(errors, [same(conflict)]);
    expect(secondaryAttempts, 2);
    expect(peer.open, isFalse);
    expect(peer.discoveryComplete, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final failInFactory in [true, false]) {
    testSignaling(
      'retry ${failInFactory ? 'factory' : 'start'} exceptions remain inside their epoch',
      (tester) async {
        final attempts = <_FakePeer>[];
        void Function()? oldZoneFailure;
        final peer = wrapper(
          providers: [
            (id, _) {
              final primary = _FakePeer(id, 'primary');
              peers.add(primary);
              return primary;
            },
            (id, _) {
              if (attempts.length == 1 && failInFactory) {
                final failed = _FakePeer(id, 'never returned');
                attempts.add(failed);
                peers.add(failed);
                throw StateError('Retry factory failed');
              }
              final secondary = _FakePeer(id, 'secondary');
              if (attempts.isEmpty) {
                secondary.onStart = (_) {
                  // Simulates a provider's queued asynchronous failure after
                  // its registration deadline and replacement have passed.
                  oldZoneFailure = Zone.current.bindCallbackGuarded(() {
                    throw StateError('Old asynchronous registration failure');
                  });
                };
              } else if (attempts.length == 1) {
                secondary.startError = StateError('Retry start failed');
              }
              attempts.add(secondary);
              peers.add(secondary);
              return secondary;
            },
          ],
        )..start();
        peers[0].register();
        await tester.pump(const Duration(seconds: 14));
        await tester.pump(const Duration(milliseconds: 750));
        expect(attempts, hasLength(2));
        await tester.pump(const Duration(milliseconds: 1250));
        expect(attempts, hasLength(3));
        attempts.last.register();
        await _settle(tester);
        expect(peer.discoveryComplete, isTrue);
        oldZoneFailure!();
        attempts.first.register();
        attempts.first.fail(_unavailable);
        await _settle(tester);
        expect(peer.discoveryComplete, isTrue);
        expect(peers[0].disposed, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testSignaling(
    'discovery stream closes on dispose and ignores late callbacks',
    (tester) async {
      final primary = _DiscoveringPeer(_id, 'PeerJS');
      final secondary = _DiscoveringPeer(_id, 'MQTT');
      peers.addAll([primary, secondary]);
      final peer = wrapper(providers: [(_, _) => primary, (_, _) => secondary])
        ..start();
      primary.register();
      secondary.register();
      await _settle(tester);
      final coverage = <bool>[];
      var done = false;
      peer.onDiscoveryChanged.listen(
        (_) => coverage.add(peer.discoveryComplete),
        onDone: () => done = true,
      );
      peer.dispose();
      expect(peer.discoveryComplete, isFalse);
      primary.register();
      secondary.registrationPending();
      secondary.register();
      secondary.fail(_unavailable);
      await _settle(tester);
      expect(coverage, [false]);
      expect(done, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testSignaling(
    'production factory accelerates followers but not room aliases',
    (_) async {
      const runtimeId = '0123456789abcdef0123456789abcdef';
      for (final entry in {
        runtimeId: const Duration(milliseconds: 250),
        'mytree-room-$runtimeId': const Duration(seconds: 3),
        'unknown-identity': const Duration(seconds: 3),
      }.entries) {
        final policy = productionPolicy(entry.key);
        expect(policy.preferenceDelay, entry.value);
        expect(policy.channelRaceDelay, const Duration(milliseconds: 250));
        expect(policy.open, isFalse);
      }
      expect(
        peers,
        isEmpty,
        reason: 'Factory inspection must not start providers',
      );
      final generic = wrapper(preferenceDelay: const Duration(seconds: 3));
      expect(generic.channelRaceDelay, const Duration(seconds: 3));
    },
  );

  testSignaling('runtime follower announces ready fallback at exactly 250 ms', (
    tester,
  ) async {
    const runtimeId = '0123456789abcdef0123456789abcdef';
    final policy = productionPolicy(runtimeId);
    final peer = wrapper(
      id: runtimeId,
      preferenceDelay: policy.preferenceDelay,
      channelRaceDelay: policy.channelRaceDelay,
    );
    final opens = <String?>[];
    peer.onOpen.listen(opens.add);
    peer.start();
    peers[1].register(); // Primary construction/registration is still pending.
    await tester.pump(const Duration(milliseconds: 249));
    expect(opens, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(opens, [runtimeId]);
    expect(peer.open, isTrue);
    expect(peer.service, 'MQTT');
    peers[0].register();
    await _settle(tester);
    expect(opens, [
      runtimeId,
    ], reason: 'Late primary is not a second registration');
  });

  testSignaling(
    'room alias keeps its conservative three-second registration wait',
    (tester) async {
      const alias = 'mytree-room-0123456789abcdef0123456789abcdef';
      final policy = productionPolicy(alias);
      final peer = wrapper(
        id: alias,
        preferenceDelay: policy.preferenceDelay,
        channelRaceDelay: policy.channelRaceDelay,
      );
      final opens = <String?>[];
      peer.onOpen.listen(opens.add);
      peer.start();
      peers[1].register();
      await tester.pump(const Duration(milliseconds: 2999));
      expect(
        opens,
        isEmpty,
        reason: 'An alias cannot use the short follower wait',
      );
      await tester.pump(const Duration(milliseconds: 1));
      expect(opens, [alias]);
      expect(peer.service, 'MQTT');
    },
  );

  testSignaling(
    '250 ms channel hedge is independent of three-second registration',
    (tester) async {
      final peer = wrapper(
        preferenceDelay: const Duration(seconds: 3),
        channelRaceDelay: const Duration(milliseconds: 250),
      )..start();
      peers[0].register();
      peers[1].register();
      final channel = peer.connect('host');
      await _settle(tester);
      expect(peers[0].outbound, hasLength(1));
      await tester.pump(const Duration(milliseconds: 249));
      expect(peers[1].outbound, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(peers[1].outbound, hasLength(1));
      peers[1].outbound.single.openChannel();
      await _settle(tester);
      expect(channel.open, isTrue);
      expect(channel.service, 'MQTT');
    },
  );

  testSignaling(
    'standby arriving after the hedge starts immediately when ready',
    (tester) async {
      final peer = wrapper(
        preferenceDelay: const Duration(seconds: 3),
        channelRaceDelay: const Duration(milliseconds: 250),
      )..start();
      peers[0].register();
      final channel = peer.connect('host');
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        peers[1].outbound,
        isEmpty,
        reason: 'Standby has not registered yet',
      );
      peers[1].register();
      expect(
        peers[1].outbound,
        hasLength(1),
        reason: 'Do not start a second delay',
      );
      peers[1].outbound.single.openChannel();
      await _settle(tester);
      expect(channel.open, isTrue);
      expect(channel.service, 'MQTT');
    },
  );

  testSignaling(
    'late ID contention invalidates an early-announced runtime peer',
    (tester) async {
      const runtimeId = '0123456789abcdef0123456789abcdef';
      final policy = productionPolicy(runtimeId);
      final peer = wrapper(
        id: runtimeId,
        preferenceDelay: policy.preferenceDelay,
        channelRaceDelay: policy.channelRaceDelay,
      );
      final opens = <String?>[];
      final errors = <SignalingFailure>[];
      peer.onOpen.listen(opens.add);
      peer.onError.listen(errors.add);
      peer.start();
      peers[1].register();
      await tester.pump(const Duration(milliseconds: 250));
      expect(opens, [runtimeId]);
      expect(peer.open, isTrue);
      const conflict = SignalingFailure(
        SignalingFailureKind.idTaken,
        'Runtime identity is already owned',
      );
      peers[0].fail(conflict);
      expect(errors, [same(conflict)]);
      expect(peer.open, isFalse);
      expect(() => peer.connect('host'), throwsStateError);
      peers[0].register();
      peers[1].register();
      await tester.pump(const Duration(seconds: 1));
      expect(opens, [runtimeId]);
      expect(peer.open, isFalse);
      expect(peers.every((p) => p.outbound.isEmpty), isTrue);
    },
  );

  testSignaling('both services start concurrently and primary is preferred', (
    tester,
  ) async {
    final peer = wrapper();
    final opens = <String?>[];
    peer.onOpen.listen(opens.add);
    peer.start();
    peer.start();
    expect(peers.map((p) => p.starts), [1, 1]);
    expect(peers.map((p) => p.id), [_id, _id]);
    expect(peer.open, isFalse);
    expect(() => peer.connect('host'), throwsStateError);

    peers[1].register();
    await tester.pump(const Duration(milliseconds: 50));
    expect(opens, isEmpty, reason: 'Give primary its preference window');
    peers[0].register();
    expect(opens, [_id]);
    final channel = peer.connect('host');
    await _settle(tester);
    expect(peers[0].outbound.single.peer, 'host');
    expect(peers[1].outbound, isEmpty);
    final channelOpens = <void>[];
    channel.onOpen.listen(channelOpens.add);
    peers[0].outbound.single.openChannel();
    await tester.pump(const Duration(seconds: 1));
    expect(channel.service, 'PeerJS');
    expect(channelOpens, hasLength(1));
    expect(peers[1].outbound, isEmpty);
    peers[0].register();
    peers[1].register();
    expect(opens, [
      _id,
    ], reason: 'One logical registration, not one per service');
  });

  testSignaling('primary unavailable automatically selects ready MQTT', (
    tester,
  ) async {
    final peer = wrapper();
    final opens = <String?>[];
    final errors = <SignalingFailure>[];
    peer.onOpen.listen(opens.add);
    peer.onError.listen(errors.add);
    peer.start();
    peers[1].register();
    peers[0].fail(_unavailable);
    await _settle(tester);
    expect(opens, [_id]);
    expect(errors, isEmpty);
    expect(peer.service, 'MQTT');
    final channel = peer.connect('host');
    await _settle(tester);
    expect(peers[0].outbound, isEmpty);
    peers[1].outbound.single.openChannel();
    expect(channel.open, isTrue);
    expect(channel.service, 'MQTT');
  });

  testSignaling(
    'silent primary yields to MQTT after a bounded preference wait',
    (tester) async {
      final peer = wrapper();
      final opens = <String?>[];
      peer.onOpen.listen(opens.add);
      peer.start();
      peers[1].register();
      await tester.pump(const Duration(milliseconds: 99));
      expect(opens, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(opens, [_id]);
      final channel = peer.connect('host');
      await _settle(tester);
      peers[1].outbound.single.openChannel();
      expect(channel.service, 'MQTT');
    },
  );

  testSignaling('constructor/start failures do not block the standby service', (
    tester,
  ) async {
    for (final failInFactory in [true, false]) {
      final peer = wrapper(
        providers: [
          (id, config) {
            if (failInFactory) throw StateError('PeerJS construction failed');
            final primary = _FakePeer(id, 'PeerJS')
              ..startError = StateError('PeerJS start failed');
            peers.add(primary);
            return primary;
          },
          (id, config) {
            final standby = _FakePeer(id, 'MQTT');
            peers.add(standby);
            return standby;
          },
        ],
      );
      final opens = <String?>[];
      final errors = <SignalingFailure>[];
      peer.onOpen.listen(opens.add);
      peer.onError.listen(errors.add);
      peer.start();
      peers.last.register();
      await _settle(tester);
      expect(opens, [_id]);
      expect(errors, isEmpty);
      expect(peer.service, 'MQTT');
    }
  });

  testSignaling(
    'standby registration lets a PeerJS-blocked newcomer find the same host',
    (tester) async {
      final primaryBus = _Bus('PeerJS');
      final mqttBus = _Bus('MQTT');
      buses.addAll([primaryBus, mqttBus]);
      SignalingPeerFactory tracked(_Bus bus) => (id, config) {
        final peer = bus.create(id, config);
        peers.add(peer);
        return peer;
      };
      final host = wrapper(providers: [tracked(primaryBus), tracked(mqttBus)]);
      final incoming = <RoomChannel>[];
      host.onConnection.listen(incoming.add);
      host.start();
      await _settle(tester);
      expect(host.open, isTrue);
      expect(primaryBus.registered[_id], isNotNull);
      expect(mqttBus.registered[_id], isNotNull);
      final originalHost = mqttBus.registered[_id];

      final newcomer = wrapper(
        id: 'newcomer',
        providers: [
          (id, config) {
            final blocked = _FakePeer(id, 'PeerJS')
              ..onStart = (p) => p.fail(_unavailable);
            peers.add(blocked);
            return blocked;
          },
          tracked(mqttBus),
        ],
      );
      newcomer.start();
      await _settle(tester);
      final outgoing = newcomer.connect(_id);
      var opens = 0;
      outgoing.onOpen.listen((_) => opens++);
      await _settle(tester);
      expect(outgoing.open, isTrue);
      expect(outgoing.service, 'MQTT');
      expect(opens, 1);
      expect(incoming, hasLength(1));
      expect(incoming.single.peer, 'newcomer');
      expect(mqttBus.registered[_id], same(originalHost));
      final received = <Object?>[];
      incoming.single.onData.listen(received.add);
      await outgoing.send({'type': 'hello', 'history': []});
      await _settle(tester);
      expect(received, [
        {'type': 'hello', 'history': []},
      ]);
      expect(primaryBus.channels, isEmpty);
    },
  );

  for (final conflictBackend in [0, 1]) {
    testSignaling(
      'typed ID contention on backend $conflictBackend never bypasses election',
      (tester) async {
        final peer = wrapper();
        final opens = <String?>[];
        final errors = <SignalingFailure>[];
        peer.onOpen.listen(opens.add);
        peer.onError.listen(errors.add);
        peer.start();
        // MQTT already owns the alias locally, but the other namespace reports
        // another room owner. Do not announce it as a second independent host.
        peers[1].register();
        final conflict = SignalingFailure(
          SignalingFailureKind.idTaken,
          'Exact alias is already owned',
        );
        peers[conflictBackend].fail(conflict);
        peers[0].register();
        peers[1].register();
        await tester.pump(const Duration(seconds: 1));
        expect(errors, [same(conflict)]);
        expect(opens, isEmpty);
        expect(peer.open, isFalse);
        expect(() => peer.connect('host'), throwsStateError);
        expect(peers.every((p) => p.outbound.isEmpty), isTrue);
      },
    );
  }

  testSignaling(
    'registration must emit open, not rely on stale ready getters',
    (tester) async {
      final primary = _FakePeer(_id, 'PeerJS')..open = true;
      final standby = _FakePeer(_id, 'MQTT');
      peers.addAll([primary, standby]);
      final peer = wrapper(
        providers: [(id, config) => primary, (id, config) => standby],
      );
      final opens = <String?>[];
      peer.onOpen.listen(opens.add);
      peer.start();
      await tester.pump(const Duration(seconds: 1));
      expect(opens, isEmpty);
      expect(peer.open, isFalse);
      expect(() => peer.connect('host'), throwsStateError);
      primary.register();
      expect(opens, [_id]);
    },
  );

  testSignaling('silent services fail within the registration deadline', (
    tester,
  ) async {
    final peer = wrapper();
    final errors = <SignalingFailure>[];
    final opens = <String?>[];
    peer.onError.listen(errors.add);
    peer.onOpen.listen(opens.add);
    peer.start();
    await tester.pump(const Duration(seconds: 3));
    expect(errors, isEmpty, reason: 'The standby still has time to register');
    expect(peers[0].disposed, isTrue);
    await tester.pump(const Duration(milliseconds: 10999));
    expect(errors, isEmpty);
    expect(peers[1].disposed, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(errors, hasLength(1));
    expect(errors.single.kind, SignalingFailureKind.unavailable);
    expect(errors.single.message, contains('timed out'));
    peers[0].register();
    peers[1].register();
    await _settle(tester);
    expect(opens, isEmpty, reason: 'Expired backends cannot revive the peer');
    expect(peer.open, isFalse);
  });

  for (final readyAfter in [
    const Duration(milliseconds: 7200),
    const Duration(milliseconds: 13500),
  ]) {
    testSignaling(
      'MQTT registration may finish after ${readyAfter.inMilliseconds} ms within its complete startup budget',
      (tester) async {
        final peer = wrapper();
        final opens = <String?>[];
        final errors = <SignalingFailure>[];
        peer.onOpen.listen(opens.add);
        peer.onError.listen(errors.add);
        peer.start();
        await tester.pump(readyAfter);
        expect(peers.first.disposed, isTrue);
        expect(
          peers[1].disposed,
          isFalse,
          reason:
              'Connect, SUBACK and identity claim have separate bounded stages.',
        );
        expect(errors, isEmpty);
        peers[1].register();
        await _settle(tester);
        expect(opens, [_id]);
        final channel = peer.connect('host');
        channel.onError.listen((_) {});
        await _settle(tester);
        peers[1].outbound.single.openChannel();
        await _settle(tester);
        expect(channel.open, isTrue);
        await tester.pump(const Duration(seconds: 15));
        expect(errors, isEmpty);
        expect(peer.open, isTrue);
        expect(channel.open, isTrue);
        expect(peers[1].disposed, isFalse);
        expect(
          peers.where((provider) => provider.service == 'MQTT'),
          hasLength(1),
        );
        expect(peers[1].outbound, hasLength(1));
      },
    );
  }

  testSignaling('late standby registration survives the primary deadline', (
    tester,
  ) async {
    final peer = wrapper();
    final opens = <String?>[];
    final errors = <SignalingFailure>[];
    peer.onOpen.listen(opens.add);
    peer.onError.listen(errors.add);
    peer.start();
    await tester.pump(const Duration(seconds: 3));
    peers[1].register();
    await _settle(tester);
    expect(opens, [_id]);
    expect(errors, isEmpty);
    expect(peer.service, 'MQTT');
    await tester.pump(const Duration(seconds: 10));
    expect(
      peer.open,
      isTrue,
      reason: 'Successful registration cancels its timer',
    );
    expect(errors, isEmpty);
  });

  for (final wrongId in <String?>[null, '', 'another-room']) {
    testSignaling('registration rejects mismatched ID ${jsonEncode(wrongId)}', (
      tester,
    ) async {
      final peer = wrapper();
      final opens = <String?>[];
      final errors = <SignalingFailure>[];
      peer.onOpen.listen(opens.add);
      peer.onError.listen(errors.add);
      peer.start();
      peers[0].open = true;
      peers[0].emit('open', wrongId);
      await _settle(tester);
      expect(peer.open, isFalse);
      expect(opens, isEmpty);
      expect(() => peer.connect('host'), throwsStateError);
      peers[1].register();
      await _settle(tester);
      expect(opens, [_id]);
      expect(peer.service, 'MQTT');
      expect(errors, isEmpty);
    });
  }

  testSignaling(
    'primary remote-unavailable races MQTT without losing registration',
    (tester) async {
      final peer = wrapper()..start();
      peers[0].register();
      peers[1].register();
      final peerErrors = <SignalingFailure>[];
      peer.onError.listen(peerErrors.add);
      final channel = peer.connect('host');
      final channelErrors = <Object>[];
      channel.onError.listen(channelErrors.add);
      await _settle(tester);
      final primaryAttempt = peers[0].outbound.single;
      peers[0].fail(
        const SignalingFailure(
          SignalingFailureKind.remoteUnavailable,
          'Could not connect to peer host',
        ),
      );
      await _settle(tester);
      expect(primaryAttempt.disposed, isTrue);
      expect(peers[1].outbound, hasLength(1));
      peers[1].outbound.single.openChannel();
      expect(channel.service, 'MQTT');
      expect(peer.open, isTrue);
      expect(peerErrors, isEmpty);
      expect(channelErrors, isEmpty);
    },
  );

  testSignaling(
    'no primary DataChannel opens an alternate after race timeout',
    (tester) async {
      final peer = wrapper()..start();
      peers[0].register();
      peers[1].register();
      final channel = peer.connect('host');
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 99));
      expect(peers[1].outbound, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(peers[1].outbound, hasLength(1));
      peers[1].outbound.single.openChannel();
      await _settle(tester);
      expect(channel.open, isTrue);
      expect(channel.service, 'MQTT');
      expect(peers[0].outbound.single.disposed, isTrue);
    },
  );

  for (final winnerIndex in [0, 1]) {
    testSignaling(
      'race winner $winnerIndex delivers once and disposes late loser',
      (tester) async {
        final peer = wrapper()..start();
        peers[0].register();
        peers[1].register();
        final channel = peer.connect('host');
        var opens = 0;
        final received = <Object?>[];
        channel.onOpen.listen((_) => opens++);
        channel.onData.listen(received.add);
        await _settle(tester);
        await tester.pump(_delay);
        final winner = peers[winnerIndex].outbound.single;
        final loser = peers[1 - winnerIndex].outbound.single;
        winner.openChannel();
        // Fire the losing event before deferred disposal and again afterwards.
        loser.openChannel();
        loser.receive({'source': 'loser'});
        winner.openChannel();
        winner.receive({'source': 'winner'});
        await _settle(tester);
        loser.openChannel();
        loser.receive({'source': 'late loser'});
        await channel.send({'edit': 'one'});
        await _settle(tester);
        expect(opens, 1);
        expect(received, [
          {'source': 'winner'},
        ]);
        expect(winner.sent, [
          {'edit': 'one'},
        ]);
        expect(loser.sent, isEmpty);
        expect(loser.disposed, isTrue);
        expect(loser.disposals, 1);
        expect(winner.disposed, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testSignaling(
    'late open from a failed attempt cannot win the alternate race',
    (tester) async {
      final peer = wrapper()..start();
      peers[0].register();
      peers[1].register();
      final channel = peer.connect('host');
      var opens = 0;
      channel.onOpen.listen((_) => opens++);
      await _settle(tester);
      final failed = peers[0].outbound.single;
      failed.fail(StateError('Negotiation failed'));
      failed.openChannel(); // Already queued before deferred disposal runs.
      peers[1].outbound.single.openChannel();
      await _settle(tester);
      expect(channel.service, 'MQTT');
      expect(opens, 1);
      expect(channel.open, isTrue);
      expect(failed.disposed, isTrue);
    },
  );

  testSignaling(
    'established channel survives primary signaling loss with MQTT ready',
    (tester) async {
      final peer = wrapper()..start();
      peers[0].register();
      peers[1].register();
      final disconnects = <void>[];
      final peerErrors = <SignalingFailure>[];
      peer.onDisconnected.listen(disconnects.add);
      peer.onError.listen(peerErrors.add);
      final channel = peer.connect('host');
      var closes = 0;
      channel.onClose.listen((_) => closes++);
      await _settle(tester);
      final active = peers[0].outbound.single;
      active.openChannel();
      peers[0].loseSignaling();
      await tester.pump(const Duration(seconds: 30));
      expect(
        peers,
        hasLength(2),
        reason: 'Registered providers owning RTC are deliberately not replaced',
      );
      expect(peers[0].disposed, isFalse);
      expect(peer.open, isTrue);
      expect(peer.service, 'MQTT');
      expect(channel.service, 'PeerJS');
      expect(channel.open, isTrue);
      expect(active.disposed, isFalse);
      expect(closes, 0);
      expect(disconnects, isEmpty);
      expect(peerErrors, isEmpty);
      await channel.send({'edit': 'during signaling outage'});
      expect(active.sent, [
        {'edit': 'during signaling outage'},
      ]);
      expect(
        peers[1].outbound,
        isEmpty,
        reason: 'Never migrate established data',
      );
    },
  );

  testSignaling(
    'both registration services failing emits the actual typed error',
    (tester) async {
      final peer = wrapper();
      final errors = <SignalingFailure>[];
      final opens = <String?>[];
      peer.onError.listen(errors.add);
      peer.onOpen.listen(opens.add);
      peer.start();
      peers[0].fail(_unavailable);
      expect(errors, isEmpty);
      const mqttFailure = SignalingFailure(
        SignalingFailureKind.unavailable,
        'MQTT websocket refused',
      );
      peers[1].fail(mqttFailure);
      await _settle(tester);
      expect(errors, [same(mqttFailure)]);
      expect(errors.single.message, contains('MQTT websocket refused'));
      expect(opens, isEmpty);
      expect(peer.open, isFalse);
      expect(() => peer.connect('host'), throwsStateError);
    },
  );

  testSignaling(
    'both channel attempts failing emits a real negotiation error',
    (tester) async {
      final peer = wrapper()..start();
      peers[0].register();
      peers[1].register();
      final channel = peer.connect('host');
      final errors = <Object>[];
      channel.onError.listen(errors.add);
      await _settle(tester);
      peers[0].outbound.single.fail(StateError('Primary negotiation failed'));
      await _settle(tester);
      final lastError = StateError('MQTT negotiation failed');
      peers[1].outbound.single.fail(lastError);
      await _settle(tester);
      expect(errors, [same(lastError)]);
      expect(channel.open, isFalse);
      expect(peers.every((p) => p.outbound.single.disposed), isTrue);
      await expectLater(
        channel.send({'edit': 'must not send'}),
        throwsStateError,
      );
    },
  );

  testSignaling('synchronous primary connect failure immediately tries MQTT', (
    tester,
  ) async {
    final peer = wrapper()..start();
    peers[0].register();
    peers[1].register();
    peers[0].connectError = StateError('Cannot create primary DataChannel');
    final channel = peer.connect('host');
    final errors = <Object>[];
    channel.onError.listen(errors.add);
    await _settle(tester);
    expect(peers[1].outbound, hasLength(1));
    peers[1].outbound.single.openChannel();
    expect(channel.open, isTrue);
    expect(channel.service, 'MQTT');
    expect(errors, isEmpty);
  });

  testSignaling(
    'dispose cancels preference registration and ignores late peer events',
    (tester) async {
      final peer = wrapper();
      final opens = <String?>[];
      final errors = <SignalingFailure>[];
      final incoming = <RoomChannel>[];
      peer.onOpen.listen(opens.add);
      peer.onError.listen(errors.add);
      peer.onConnection.listen(incoming.add);
      peer.start();
      peers[1].register();
      peer.dispose();
      peer.dispose();
      peers[0].register();
      peers[1].register();
      peers[0].fail(_unavailable);
      final lateIncoming = _FakeChannel('late-newcomer', 'PeerJS');
      peers[0].attached.add(lateIncoming);
      peers[0].emit('connection', lateIncoming);
      await tester.pump(const Duration(minutes: 1));
      peer.start();
      expect(lateIncoming.disposed, isTrue);
      expect(opens, isEmpty);
      expect(errors, isEmpty);
      expect(incoming, isEmpty);
      expect(peer.open, isFalse);
      expect(peers.map((p) => p.starts), [1, 1]);
      expect(peers.map((p) => p.disposals), [1, 1]);
      expect(tester.takeException(), isNull);
    },
  );

  testSignaling(
    'dispose cancels channel race and ignores late channel callbacks',
    (tester) async {
      final peer = wrapper()..start();
      peers[0].register();
      peers[1].register();
      final channel = peer.connect('host');
      var opens = 0;
      final received = <Object?>[];
      final errors = <Object>[];
      channel.onOpen.listen((_) => opens++);
      channel.onData.listen(received.add);
      channel.onError.listen(errors.add);
      await _settle(tester);
      final attempt = peers[0].outbound.single;
      channel.dispose();
      channel.dispose();
      attempt.openChannel();
      attempt.receive({'edit': 'late'});
      attempt.fail(StateError('late'));
      await tester.pump(const Duration(minutes: 1));
      expect(peers[1].outbound, isEmpty);
      expect(channel.disposed, isTrue);
      expect(channel.open, isFalse);
      expect(attempt.disposed, isTrue);
      expect(opens, 0);
      expect(received, isEmpty);
      expect(errors, isEmpty);
      await expectLater(channel.send({'edit': 'late'}), throwsStateError);
      expect(tester.takeException(), isNull);
    },
  );

  testSignaling('peer disposal ignores callbacks from an established winner', (
    tester,
  ) async {
    final peer = wrapper()..start();
    peers[0].register();
    peers[1].register();
    final channel = peer.connect('host');
    final received = <Object?>[];
    final errors = <Object>[];
    final health = <ChannelConnectivity>[];
    channel.onData.listen(received.add);
    channel.onError.listen(errors.add);
    channel.onConnectivity.listen(health.add);
    await _settle(tester);
    final active = peers[0].outbound.single;
    active.openChannel();
    expect(channel.open, isTrue);
    peer.dispose();
    active.receive({'edit': 'late after owner disposal'});
    active.fail(StateError('late after owner disposal'));
    active.changeConnectivity(ChannelConnectivity.failed);
    await _settle(tester);
    try {
      expect(received, isEmpty);
      expect(errors, isEmpty);
      expect(health, isEmpty);
      expect(channel.disposed, isTrue);
      expect(channel.open, isFalse);
      expect(active.disposed, isTrue);
      await expectLater(channel.send({'edit': 'late'}), throwsStateError);
    } finally {
      channel.dispose();
    }
  });

  testSignaling('peer disposal during a pending race disposes all attempts', (
    tester,
  ) async {
    final peer = wrapper()..start();
    peers[0].register();
    peers[1].register();
    final channel = peer.connect('host');
    var opens = 0;
    channel.onOpen.listen((_) => opens++);
    await _settle(tester);
    await tester.pump(_delay);
    peer.dispose();
    for (final backend in peers) {
      backend.outbound.single.openChannel();
    }
    await tester.pump(const Duration(minutes: 1));
    expect(channel.disposed, isTrue);
    expect(opens, 0);
    expect(peers.every((p) => p.outbound.single.disposed), isTrue);
    expect(peers.map((p) => p.disposals), [1, 1]);
    expect(tester.takeException(), isNull);
  });
}
