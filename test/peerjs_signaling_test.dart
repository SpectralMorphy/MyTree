import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mytree_webrtc_demo/signaling/peerjs_signaling.dart';
import 'package:mytree_webrtc_demo/signaling/signaling.dart';
import 'package:peer_rtc/peer_rtc.dart';

mixin _Events {
  final _events = <String?, StreamController<dynamic>>{};
  bool _emitting = false;

  Stream<T> on<T>([String? name]) => _events
      .putIfAbsent(name, () => StreamController<dynamic>.broadcast(sync: true))
      .stream
      .cast<T>();

  void emit<T>(String name, T data) {
    final previous = _emitting;
    _emitting = true;
    try {
      _events[name]?.add(data);
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

// Only the handful of PeerJS members used by the boundary need a double.
class _Peer with _Events implements Peer {
  _Peer(this.id);

  @override
  String? id;
  @override
  final options = PeerOptions(autoReconnect: true);
  @override
  bool open = false;
  @override
  bool disconnected = false;
  @override
  bool destroyed = false;
  int reconnectCancellations = 0;
  int disposals = 0;
  final connections = <_Connection>[];
  PeerConnectOption? lastConnectOptions;

  @override
  DataConnection connect(String peer, {PeerConnectOption? options}) {
    lastConnectOptions = options;
    final connection = _Connection(peer);
    connections.add(connection);
    return connection;
  }

  @override
  void cancelReconnect() => reconnectCancellations++;

  @override
  void dispose() {
    destroyed = true;
    disposals++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecoveringPeer extends _Peer {
  _RecoveringPeer(super.id) {
    options
      ..autoReconnect = false
      ..maxRetries = 1;
  }

  int recoveries = 0;
  bool recoveryAccepted = true;
  void Function()? onRecovery;

  @override
  bool tryReconnect() {
    recoveries++;
    onRecovery?.call();
    return recoveryAccepted;
  }

  @override
  void cancelReconnect() {
    if (_emitting) throw StateError('Reentrant PeerJS cancellation');
    super.cancelReconnect();
  }
}

class _Connection with _Events implements DataConnection {
  _Connection(this.peer);

  @override
  final String peer;
  @override
  bool open = false;
  @override
  bool disposed = false;
  @override
  RTCPeerConnection? peerConnection;
  int disposals = 0;
  int emitterCloses = 0;
  final sent = <dynamic>[];
  Object? sendError;

  @override
  Future<void> send(dynamic data) async {
    if (sendError != null) throw sendError!;
    sent.add(data);
  }

  @override
  void dispose() {
    disposed = true;
    open = false;
    disposals++;
  }

  @override
  void close() {
    emitterCloses++;
    throw StateError('Emitter close is not DataConnection disposal');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RtcConnection implements RTCPeerConnection {
  @override
  RTCPeerConnectionState? connectionState;
  @override
  RTCIceConnectionState? iceConnectionState;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Peer raw;
  late PeerJsSignalingPeer peer;
  late List<_Connection> incoming;

  setUp(() {
    raw = _Peer('exact-id');
    peer = PeerJsSignalingPeer(raw);
    peer.start();
    incoming = [];
  });

  tearDown(() async {
    peer.dispose();
    await raw.closeEvents();
    for (final connection in {...raw.connections, ...incoming}) {
      await connection.closeEvents();
    }
  });

  test(
    'discovery follows validated registration, reconnect, close and disposal',
    () async {
      final coverage = <bool>[];
      var done = false;
      peer.onDiscoveryChanged.listen(
        (_) => coverage.add(peer.discoveryComplete),
        onDone: () => done = true,
      );
      expect(peer.discoveryComplete, isFalse);
      raw.open = true;
      expect(
        peer.discoveryComplete,
        isFalse,
        reason: 'No confirmed registration yet',
      );
      raw.emit('open', 'exact-id');
      await Future<void>.value();
      expect(peer.discoveryComplete, isTrue);
      expect(coverage, [true]);

      raw.emit('error', 'Could not connect to peer remote-host');
      await Future<void>.value();
      expect(peer.discoveryComplete, isTrue);
      expect(coverage, [
        true,
      ], reason: 'Remote discovery failure is not registration loss');
      raw.emit('reconnecting', 1);
      await Future<void>.value();
      expect(peer.discoveryComplete, isFalse);
      raw.emit('reconnected', null);
      await Future<void>.value();
      expect(peer.discoveryComplete, isTrue);
      raw.emit('close', null);
      await Future<void>.value();
      expect(
        raw.open,
        isTrue,
        reason: 'A stale package getter cannot hide closure',
      );
      expect(peer.discoveryComplete, isFalse);
      expect(coverage, [true, false, true, false]);

      peer.dispose();
      raw.emit('open', 'exact-id');
      raw.emit('reconnected', null);
      raw.emit('error', 'ID exact-id is taken');
      await Future<void>.delayed(Duration.zero);
      expect(peer.discoveryComplete, isFalse);
      expect(coverage.last, isFalse);
      expect(done, isTrue);
    },
  );

  for (final wrongId in <String?>[null, '', 'another-id']) {
    test('discovery rejects registration for mismatched ID $wrongId', () async {
      final failures = <SignalingFailure>[];
      peer.onError.listen(failures.add);
      raw.open = true;
      raw.emit('open', wrongId);
      await Future<void>.value();
      expect(peer.discoveryComplete, isFalse);
      expect(failures.single.kind, SignalingFailureKind.unavailable);
    });
  }

  test(
    'late collision clears discovery and preserves an established channel',
    () async {
      final channel = peer.connect('remote');
      final connection = raw.connections.single..open = true;
      raw.open = true;
      raw.emit('open', 'exact-id');
      await Future<void>.value();
      expect(peer.discoveryComplete, isTrue);
      final coverage = <bool>[];
      peer.onDiscoveryChanged.listen(
        (_) => coverage.add(peer.discoveryComplete),
      );
      raw.emit('error', 'ID exact-id is taken');
      await Future<void>.value();
      expect(peer.discoveryComplete, isFalse);
      expect(coverage, [false]);
      expect(channel.open, isTrue);
      expect(connection.disposed, isFalse);
      await channel.send({'still': 'connected'});
    },
  );

  test('already-open replay cannot override a newer disconnect', () async {
    final existing = _Peer('existing')..open = true;
    final adapter = PeerJsSignalingPeer(existing);
    final opens = <String?>[];
    adapter.onOpen.listen(opens.add);
    adapter.start();
    existing.emit('disconnected', 'existing');
    await Future<void>.value();
    expect(adapter.discoveryComplete, isFalse);
    expect(opens, isEmpty);
    adapter.dispose();
    await existing.closeEvents();
  });

  test('existing peer retains its options and shared registration events', () {
    final options = raw.options;
    final opened = <String?>[];
    var disconnected = 0;
    var closed = 0;
    peer.onOpen.listen(opened.add);
    peer.onDisconnected.listen((_) => disconnected++);
    peer.onClose.listen((_) => closed++);
    peer.start();
    expect(raw.options, same(options));
    expect(raw.options.autoReconnect, isTrue);
    expect(peer.id, 'exact-id');
    expect(peer.service, 'PeerJS');
    expect(peer.open, isFalse);
    raw.open = true;
    raw.emit('open', 'exact-id');
    expect(peer.open, isTrue);
    expect(peer.disconnected, isFalse);
    raw.disconnected = true;
    raw.emit('disconnected', 'exact-id');
    raw.emit('close', null);
    expect(peer.open, isFalse);
    expect(peer.disconnected, isTrue);
    expect(opened, ['exact-id']);
    expect(disconnected, 1);
    expect(closed, 1);
  });

  test(
    'already-open existing peer replays registration once on start',
    () async {
      final existing = _Peer('existing')..open = true;
      final adapter = PeerJsSignalingPeer(existing);
      final opens = <String?>[];
      adapter.onOpen.listen(opens.add);
      adapter.start();
      adapter.start();
      expect(
        opens,
        isEmpty,
        reason: 'Listeners get time to attach before replay',
      );
      await Future<void>.value();
      expect(opens, ['existing']);
      expect(adapter.open, isTrue);
      adapter.dispose();
      await existing.closeEvents();
    },
  );

  test(
    'reconnecting invalidates stale getters until reconnected confirms ID',
    () {
      final opens = <String?>[];
      var disconnects = 0;
      peer.onOpen.listen(opens.add);
      peer.onDisconnected.listen((_) => disconnects++);
      raw.open = true;
      raw.emit('open', 'exact-id');
      expect(peer.open, isTrue);
      raw.emit('reconnecting', 1);
      expect(raw.open, isTrue, reason: 'Package getters may be stale');
      expect(peer.open, isFalse);
      expect(peer.disconnected, isTrue);
      raw.emit('reconnected', null);
      expect(peer.open, isTrue);
      expect(opens, ['exact-id', 'exact-id']);
      expect(disconnects, 1);
    },
  );

  test(
    'remote failure preserves registration but service failure invalidates it',
    () {
      raw.open = true;
      raw.emit('open', 'exact-id');
      raw.emit('error', 'Could not connect to peer remote-host');
      expect(peer.open, isTrue);
      raw.emit('error', 'WebSocket handshake failed');
      expect(raw.open, isTrue);
      expect(raw.disconnected, isFalse);
      expect(peer.open, isFalse);
      expect(peer.disconnected, isTrue);
    },
  );

  test(
    'disposal is idempotent and ignores late registration and error events',
    () {
      final opens = <String?>[];
      final errors = <SignalingFailure>[];
      var disconnects = 0;
      peer.onOpen.listen(opens.add);
      peer.onError.listen(errors.add);
      peer.onDisconnected.listen((_) => disconnects++);
      peer.dispose();
      peer.dispose();
      peer.start();
      raw.open = true;
      raw.emit('open', 'exact-id');
      raw.emit('reconnected', null);
      raw.emit('reconnecting', 1);
      raw.emit('error', 'WebSocket handshake failed');
      expect(opens, isEmpty);
      expect(errors, isEmpty);
      expect(disconnects, 0);
      expect(peer.open, isFalse);
      expect(raw.disposals, 1);
      expect(raw.reconnectCancellations, 1);
    },
  );

  test(
    'recovery preserves logical ID and the exact live RTC channel',
    () async {
      final native = _RecoveringPeer('stable-id');
      final adapter = PeerJsSignalingPeer(native)..start();
      final opens = <String?>[];
      var disconnects = 0;
      adapter.onOpen.listen(opens.add);
      adapter.onDisconnected.listen((_) => disconnects++);
      native.onRecovery = () => native.emit('reconnecting', 0);
      adapter.reconnect();
      expect(native.recoveries, 0, reason: 'No confirmed original ID yet');
      native.open = true;
      native.emit('open', 'stable-id');
      final channel = adapter.connect('remote');
      final connection = native.connections.single..open = true;
      native
        ..open = false
        ..disconnected = true
        ..id = null;
      native.emit('disconnected', 'stable-id');
      expect(adapter.id, 'stable-id');
      expect(adapter.discoveryComplete, isFalse);
      adapter.reconnect();
      adapter.reconnect();
      native.emit('reconnecting', 1);
      expect(native.recoveries, 1);
      expect(disconnects, 1, reason: 'Recovery progress is not another outage');
      expect(native.disposals, 0);
      expect(channel.disposed, isFalse);
      await channel.send({'during': 'registration recovery'});
      native
        ..id = 'stable-id'
        ..open = true
        ..disconnected = false;
      native.emit('open', 'stable-id');
      expect(adapter.open, isTrue);
      expect(adapter.discoveryComplete, isTrue);
      adapter.reconnect();
      expect(native.recoveries, 1);
      expect(opens, ['stable-id', 'stable-id']);
      expect(native.connections.single, same(connection));
      expect(connection.disposals, 0);
      adapter.dispose();
      await native.closeEvents();
      await connection.closeEvents();
    },
  );

  test(
    'failed recovery can be retried, but conflict and disposal are terminal',
    () async {
      final native = _RecoveringPeer('stable-id');
      final adapter = PeerJsSignalingPeer(native)..start();
      native.open = true;
      native.emit('open', 'stable-id');
      native
        ..open = false
        ..disconnected = true;
      native.emit('disconnected', 'stable-id');
      adapter.reconnect();
      native.emit('reconnectFailed', null);
      adapter.reconnect();
      expect(native.recoveries, 2);
      native.emit('error', 'ID stable-id is taken');
      native.open = true;
      native.emit('open', 'stable-id');
      native.emit('reconnected', null);
      adapter.reconnect();
      expect(adapter.open, isFalse);
      expect(adapter.discoveryComplete, isFalse);
      expect(native.recoveries, 2);
      adapter.dispose();
      adapter.reconnect();
      expect(native.recoveries, 2);
      await native.closeEvents();
    },
  );

  test(
    'recovery conflict cancels outside the synchronous package error callback',
    () async {
      final native = _RecoveringPeer('stable-id');
      final adapter = PeerJsSignalingPeer(native)..start();
      native.open = true;
      native.emit('open', 'stable-id');
      native
        ..open = false
        ..disconnected = true;
      native.emit('disconnected', 'stable-id');
      adapter.reconnect();
      final failures = <SignalingFailure>[];
      adapter.onError.listen(failures.add);
      native.emit('error', 'ID stable-id is taken');
      adapter.reconnect();
      expect(failures.single.kind, SignalingFailureKind.idTaken);
      expect(adapter.open, isFalse);
      expect(native.reconnectCancellations, 0);
      await Future<void>.value();
      expect(native.reconnectCancellations, 1);
      expect(native.recoveries, 1);
      adapter.dispose();
      await native.closeEvents();
    },
  );

  test(
    'recovery never changes external automatic or multi-attempt options',
    () async {
      final native = _RecoveringPeer('stable-id');
      final adapter = PeerJsSignalingPeer(native)..start();
      native.open = true;
      native.emit('open', 'stable-id');
      native
        ..open = false
        ..disconnected = true;
      native.emit('disconnected', 'stable-id');
      native.options.maxRetries = 5;
      adapter.reconnect();
      expect(native.options.maxRetries, 5);
      native.options
        ..maxRetries = 1
        ..autoReconnect = true;
      adapter.reconnect();
      expect(native.options.autoReconnect, isTrue);
      expect(native.recoveries, 0);
      native.options.autoReconnect = false;
      native.recoveryAccepted = false;
      adapter.reconnect();
      adapter.reconnect();
      expect(
        native.recoveries,
        2,
        reason: 'Rejected attempt is not kept pending',
      );
      adapter.dispose();
      await native.closeEvents();
    },
  );

  test('null PeerJS ID is exposed as an empty common identity', () async {
    final unidentified = _Peer(null);
    final adapter = PeerJsSignalingPeer(unidentified);
    expect(adapter.id, '');
    adapter.dispose();
    await unidentified.closeEvents();
  });

  test('only the exact current ID collision is typed idTaken', () {
    final failures = <SignalingFailure>[];
    peer.onError.listen(failures.add);
    raw.emit('error', 'ID exact-id is taken');
    expect(failures.single.kind, SignalingFailureKind.idTaken);
    expect(failures.single.message, 'ID exact-id is taken');

    for (final lookalike in [
      'ID different-id is taken',
      'ID exact-id is taken ',
      ' ID exact-id is taken',
      'ID exact-id is taken: websocket unavailable',
      'ID exact-id is taken\n',
      'id exact-id is taken',
      'unavailable-id',
      StateError('ID exact-id is taken'),
    ]) {
      raw.emit('error', lookalike);
      expect(failures.last.kind, SignalingFailureKind.unavailable);
      expect(failures.last.message, '$lookalike');
    }
  });

  test('missing remote is typed separately from local service failure', () {
    final failures = <SignalingFailure>[];
    peer.onError.listen(failures.add);
    raw.emit('error', 'Could not connect to peer remote-host');
    raw.emit('error', 'WebSocket handshake failed');
    expect(failures.map((f) => f.kind), [
      SignalingFailureKind.remoteUnavailable,
      SignalingFailureKind.unavailable,
    ]);
    expect(failures.first.message, 'Could not connect to peer remote-host');
  });

  test(
    'connect options stay inside PeerJS and a channel is wrapped only once',
    () {
      final wrapped = peer.connect('remote');
      final connection = raw.connections.single;
      final received = <RoomChannel>[];
      peer.onConnection.listen(received.add);
      raw.emit('connection', connection);
      raw.emit('connection', connection);
      expect(raw.lastConnectOptions?.reliable, isTrue);
      expect(wrapped.peer, 'remote');
      expect(wrapped.service, 'PeerJS');
      expect(received, [same(wrapped), same(wrapped)]);
      expect(wrapped.open, isFalse);
      connection.open = true;
      expect(wrapped.open, isTrue);
    },
  );

  test(
    'incoming channels expose common data, error, open and close streams',
    () {
      final connection = _Connection('remote');
      incoming.add(connection);
      final accepted = <RoomChannel>[];
      peer.onConnection.listen(accepted.add);
      raw.emit('connection', connection);
      final channel = accepted.single;
      var opens = 0;
      var closes = 0;
      final data = <Object?>[];
      final errors = <Object>[];
      channel.onOpen.listen((_) => opens++);
      channel.onClose.listen((_) => closes++);
      channel.onData.listen(data.add);
      channel.onError.listen(errors.add);
      final failure = Exception('RTC send failed');
      connection.emit('open', null);
      connection.emit('data', {'hello': 'world'});
      connection.emit('data', null);
      connection.emit('error', failure);
      connection.emit('close', null);
      expect(opens, 1);
      expect(closes, 1);
      expect(data, [
        {'hello': 'world'},
        null,
      ]);
      expect(errors, [same(failure)]);
    },
  );

  test('send delegates data and preserves asynchronous send failure', () async {
    final channel = peer.connect('remote');
    final connection = raw.connections.single;
    final message = <String, dynamic>{'type': 'hello', 'history': []};
    await channel.send(message);
    expect(connection.sent, [same(message)]);
    final failure = StateError('DataChannel send failed');
    connection.sendError = failure;
    await expectLater(channel.send(message), throwsA(same(failure)));
  });

  const iceStates = {
    RTCIceConnectionState.RTCIceConnectionStateNew:
        ChannelConnectivity.connecting,
    RTCIceConnectionState.RTCIceConnectionStateChecking:
        ChannelConnectivity.connecting,
    RTCIceConnectionState.RTCIceConnectionStateConnected:
        ChannelConnectivity.connected,
    RTCIceConnectionState.RTCIceConnectionStateCompleted:
        ChannelConnectivity.connected,
    RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        ChannelConnectivity.disconnected,
    RTCIceConnectionState.RTCIceConnectionStateFailed:
        ChannelConnectivity.failed,
    RTCIceConnectionState.RTCIceConnectionStateClosed:
        ChannelConnectivity.closed,
  };

  for (final entry in iceStates.entries) {
    test('RTC ${entry.key.name} normalizes in getter and events', () {
      final channel = peer.connect('remote');
      final connection = raw.connections.single;
      connection.peerConnection = _RtcConnection()
        ..iceConnectionState = entry.key;
      final changes = <ChannelConnectivity>[];
      channel.onConnectivity.listen(changes.add);
      connection.emit('iceStateChanged', entry.key);
      expect(channel.connectivity, entry.value);
      expect(changes, [entry.value]);
    });
  }

  test('unknown RTC notifications are ignored, not cast to common states', () {
    final channel = peer.connect('remote');
    final changes = <ChannelConnectivity>[];
    channel.onConnectivity.listen(changes.add);
    for (final value in [
      null,
      'connected',
      RTCIceConnectionState.RTCIceConnectionStateCount,
    ]) {
      raw.connections.single.emit('iceStateChanged', value);
    }
    expect(changes, isEmpty);
    expect(channel.connectivity, ChannelConnectivity.connecting);
    raw.connections.single.open = true;
    expect(channel.connectivity, ChannelConnectivity.connected);
  });

  test(
    'failed or closed RTC peer connection overrides stale open ICE state',
    () {
      final channel = peer.connect('remote');
      final connection = raw.connections.single..open = true;
      final rtc = _RtcConnection()
        ..iceConnectionState =
            RTCIceConnectionState.RTCIceConnectionStateConnected
        ..connectionState = RTCPeerConnectionState.RTCPeerConnectionStateFailed;
      connection.peerConnection = rtc;
      expect(channel.connectivity, ChannelConnectivity.failed);
      rtc.connectionState = RTCPeerConnectionState.RTCPeerConnectionStateClosed;
      expect(channel.connectivity, ChannelConnectivity.closed);
      rtc.connectionState = null;
      connection.disposed = true;
      expect(channel.connectivity, ChannelConnectivity.closed);
    },
  );

  test('disposal uses DataConnection.dispose rather than emitter close', () {
    final outbound = peer.connect('remote');
    final accepted = _Connection('incoming');
    incoming.add(accepted);
    peer.onConnection.listen((_) {});
    raw.emit('connection', accepted);
    outbound.dispose();
    expect(raw.connections.single.disposals, 1);
    peer.dispose();
    expect(raw.reconnectCancellations, 1);
    expect(raw.disposals, 1);
    expect(accepted.disposals, 1);
    expect(raw.connections.single.disposals, 1);
    expect(accepted.emitterCloses, 0);
    expect(raw.connections.single.emitterCloses, 0);
  });
}
