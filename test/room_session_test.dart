import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/ice_configuration.dart';
import 'package:mytree_webrtc_demo/local/room_tabs.dart';
import 'package:mytree_webrtc_demo/room_document.dart';
import 'package:mytree_webrtc_demo/room_protocol.dart';
import 'package:mytree_webrtc_demo/room_session.dart';
import 'package:mytree_webrtc_demo/signaling/fallback_signaling.dart';
import 'package:mytree_webrtc_demo/signaling/peerjs_signaling.dart';
import 'package:mytree_webrtc_demo/signaling/signaling.dart';
import 'package:mytree_webrtc_demo/storage/room_store.dart';
import 'package:peer_rtc/peer_rtc.dart';

const _roomId = '0123456789abcdef0123456789abcdef';
const _alias = 'mytree-room-$_roomId';

mixin _Events {
  final _events = <String?, StreamController<dynamic>>{};
  bool _emitting = false;

  Stream<T> on<T>([String? type]) => _events
      .putIfAbsent(type, () => StreamController<dynamic>.broadcast(sync: true))
      .stream
      .cast<T>();

  void emit<T>(String type, T data) {
    final wasEmitting = _emitting;
    _emitting = true;
    try {
      _events[type]?.add(data);
    } finally {
      _emitting = wasEmitting;
    }
  }

  Future<void> closeEvents() async {
    for (final event in _events.values) {
      await event.close();
    }
  }
}

class _Network {
  bool autoRegister = false;
  final peers = <_FakePeer>[];
  final connections = <_FakeConnection>[];
  final registered = <String, _FakePeer>{};

  SignalingPeer create(String id, Map<String, dynamic> configuration) {
    final peer = _FakePeer(
      this,
      id,
      PeerOptions(autoReconnect: false, maxRetries: 1, config: configuration),
    );
    peers.add(peer);
    if (autoRegister) scheduleMicrotask(peer.register);
    return PeerJsSignalingPeer(peer);
  }

  Future<void> cleanup() async {
    for (final peer in peers) {
      await peer.closeEvents();
    }
    for (final connection in connections) {
      await connection.closeEvents();
    }
  }
}

class _FakePeer with _Events implements Peer {
  _FakePeer(this.network, this.id, this.options);
  final _Network network;
  @override
  final String id;
  @override
  final PeerOptions options;
  @override
  bool open = false;
  @override
  bool disconnected = false;
  @override
  bool destroyed = false;
  final outbound = <_FakeConnection>[];
  final attached = <_FakeConnection>[];
  Zone? socketZone;

  void register() {
    if (destroyed) return;
    final owner = network.registered[id];
    if (owner != null && !identical(owner, this) && !owner.destroyed) {
      emit<dynamic>('error', 'ID $id is taken');
      return;
    }
    network.registered[id] = this;
    open = true;
    disconnected = false;
    emit<String?>('open', id);
  }

  @override
  DataConnection connect(String target, {PeerConnectOption? options}) {
    if (!open || disconnected) throw StateError('Signaling is not ready');
    final outgoing = _FakeConnection(target);
    network.connections.add(outgoing);
    outbound.add(outgoing);
    attached.add(outgoing);
    final remote = network.registered[target];
    if (remote == null || !remote.open || remote.destroyed) return outgoing;
    final incoming = _FakeConnection(id);
    network.connections.add(incoming);
    remote.attached.add(incoming);
    incoming.other = outgoing;
    outgoing.other = incoming;
    scheduleMicrotask(() {
      if (remote.destroyed) return;
      remote.emit<DataConnection>('connection', incoming);
      scheduleMicrotask(() {
        if (incoming.disposed || outgoing.disposed) return;
        incoming.openChannel();
        outgoing.openChannel();
      });
    });
    return outgoing;
  }

  void loseSignaling() {
    if (identical(network.registered[id], this)) network.registered.remove(id);
    open = false;
    disconnected = true;
    emit<String?>('disconnected', id);
  }

  int reconnectCalls = 0;

  @override
  bool tryReconnect() {
    if (destroyed || !disconnected) return false;
    reconnectCalls++;
    emit<int>('reconnecting', 0);
    scheduleMicrotask(register);
    return true;
  }

  @override
  void cancelReconnect() {}

  @override
  void dispose() {
    if (_emitting) throw StateError('Disposed peer during synchronous event');
    if (destroyed) return;
    destroyed = true;
    open = false;
    disconnected = true;
    if (identical(network.registered[id], this)) network.registered.remove(id);
    for (final connection in attached) {
      connection.dispose();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StartupPeer with _Events implements SignalingPeer {
  _StartupPeer(this.id, {this.failure});

  @override
  final String id;
  final SignalingFailure? failure;
  bool started = false;
  bool disposed = false;
  @override
  String get service => 'test-signaling';
  @override
  bool get open => false;
  @override
  bool get disconnected => disposed;
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
    started = true;
    final error = failure;
    if (error != null) emit<SignalingFailure>('error', error);
  }

  @override
  RoomChannel connect(String peer) => throw StateError('Not registered');

  @override
  void dispose() {
    if (_emitting) throw StateError('Disposed peer during synchronous event');
    disposed = true;
  }
}

class _CoveragePeer extends _StartupPeer implements SignalingDiscovery {
  _CoveragePeer(super.id);
  bool registered = false;
  bool covered = false;
  @override
  bool get open => registered && !disposed;
  @override
  bool get discoveryComplete => covered && open;
  @override
  Stream<void> get onDiscoveryChanged => on<void>('discovery');

  void register() {
    registered = true;
    emit<String?>('open', id);
  }

  void cover(bool value) {
    covered = value;
    emit<void>('discovery', null);
  }
}

class _FakeConnection with _Events implements DataConnection {
  _FakeConnection(this.peer);
  @override
  final String peer;
  @override
  bool open = false;
  @override
  bool disposed = false;
  @override
  RTCPeerConnection? peerConnection;
  @override
  RTCDataChannel? dataChannel;
  _FakeConnection? other;
  final sent = <dynamic>[];
  bool closeCalled = false;
  bool dropData = false;
  Completer<void>? sendGate;

  void openChannel() {
    if (disposed) return;
    open = true;
    emit<void>('open', null);
  }

  void receive(dynamic data) => emit<dynamic>('data', data);

  @override
  Future<void> send(dynamic data) async {
    if (!open || disposed) throw StateError('Send before channel ready');
    final gate = sendGate;
    if (gate != null) await gate.future;
    if (!open || disposed) throw StateError('Channel closed while sending');
    // A real DataChannel transfers detached JSON, not mutable Dart objects.
    final detached = jsonDecode(jsonEncode(data));
    sent.add(detached);
    if (dropData) return;
    final remote = other;
    if (remote != null) {
      scheduleMicrotask(() {
        if (remote.open && !remote.disposed) remote.receive(detached);
      });
    }
  }

  @override
  void close() {
    closeCalled = true;
    throw StateError('Use dispose, not emitter close');
  }

  @override
  void dispose() {
    if (_emitting) {
      throw StateError('Disposed channel during synchronous event');
    }
    if (disposed) return;
    disposed = true;
    open = false;
    final remote = other;
    if (remote != null && !remote.disposed) {
      scheduleMicrotask(() {
        if (!remote.disposed) {
          remote.open = false;
          remote.emit<void>('close', null);
        }
      });
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RtcHealth implements RTCPeerConnection {
  @override
  RTCIceConnectionState? iceConnectionState =
      RTCIceConnectionState.RTCIceConnectionStateConnected;
  @override
  RTCPeerConnectionState? connectionState =
      RTCPeerConnectionState.RTCPeerConnectionStateConnected;

  @override
  Future<RTCIceConnectionState?> getIceConnectionState() async =>
      iceConnectionState;
  @override
  Future<RTCPeerConnectionState?> getConnectionState() async => connectionState;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Store extends MemoryRoomStore {
  int appendCalls = 0;
  int membershipCalls = 0;
  int loadCalls = 0;
  final changes = StreamController<void>.broadcast(sync: true);
  Completer<void>? appendGate;
  Completer<void>? authoredGate;
  Completer<void>? membershipGate;
  Completer<void>? loadGate;
  bool failAppend = false;
  bool failLoad = false;
  bool failFlush = false;
  bool notifyAppends = false;
  final batches = <List<Map<String, dynamic>>>[];
  final authoredBatches = <List<Map<String, dynamic>>>[];

  @override
  Future<List<Map<String, dynamic>>> loadHistory(String roomId) {
    loadCalls++;
    if (failLoad) return Future.error(StateError('Disk unreadable'));
    final gate = loadGate;
    return gate == null
        ? super.loadHistory(roomId)
        : gate.future.then((_) => super.loadHistory(roomId));
  }

  @override
  Future<void> appendHistory(
    String roomId,
    List<Map<String, dynamic>> operations,
  ) {
    appendCalls++;
    batches.add(operations);
    if (failAppend) return Future.error(StateError('Disk full'));
    final gate = appendGate;
    final append = gate == null
        ? super.appendHistory(roomId, operations)
        : gate.future.then((_) => super.appendHistory(roomId, operations));
    return append.then((_) {
      if (notifyAppends && !changes.isClosed) changes.add(null);
    });
  }

  @override
  Future<List<Map<String, dynamic>>> appendAuthoredHistory(
    String roomId,
    List<Map<String, dynamic>> drafts,
  ) {
    authoredBatches.add([
      for (final draft in drafts) Map<String, dynamic>.of(draft),
    ]);
    final gate = authoredGate;
    return gate == null
        ? super.appendAuthoredHistory(roomId, drafts)
        : gate.future.then((_) => super.appendAuthoredHistory(roomId, drafts));
  }

  @override
  Future<void> saveMembership(String roomId) {
    membershipCalls++;
    final gate = membershipGate;
    return gate == null
        ? super.saveMembership(roomId)
        : gate.future.then((_) => super.saveMembership(roomId));
  }

  @override
  Stream<void> watchHistory(String roomId) => changes.stream;

  Future<void> externalAppend(List<Map<String, dynamic>> operations) async {
    await super.appendHistory(_roomId, operations);
    changes.add(null);
  }

  @override
  Future<void> flush() => failFlush
      ? Future<void>.error(StateError('Flush failed'))
      : super.flush();
}

class _TabsHub {
  final clients = <_FakeRoomTabs>[];
  _FakeRoomTabs? leader;
  RoomTabState? state;
  int published = 0;

  void elect(_FakeRoomTabs? next) {
    leader = next;
    state = null;
    for (final client in clients) {
      if (client.started && !client.disposed) {
        scheduleMicrotask(() {
          if (!client.disposed) client.emit<void>('role', null);
        });
      }
    }
  }
}

class _FakeRoomTabs with _Events implements RoomTabs, RoomTabsResync {
  _FakeRoomTabs(this.hub);
  final _TabsHub hub;
  bool started = false;
  bool disposed = false;
  int starts = 0;
  int requests = 0;
  final resyncRequests = <String>[];
  void Function()? onRelease;

  @override
  Stream<String> get onResyncRequested => on<String>('resync');

  @override
  void requestResync(String requestId) {
    if (resyncRequests.contains(requestId)) return;
    resyncRequests.add(requestId);
    hub.leader?.emit<String>('resync', requestId);
  }

  @override
  bool get isLeader => started && !disposed && identical(hub.leader, this);
  @override
  Stream<void> get onRoleChanged => on<void>('role');
  @override
  Stream<RoomTabState> get onState => on<RoomTabState>('state');

  @override
  Future<void> start() async {
    starts++;
    if (disposed || started) return;
    started = true;
    hub.clients.add(this);
    hub.leader ??= this;
  }

  @override
  void publish(RoomTabState state) {
    if (!isLeader) return;
    hub.published++;
    hub.state = state;
    for (final client in hub.clients) {
      if (!identical(client, this) && client.started && !client.disposed) {
        client.emit<RoomTabState>('state', state);
      }
    }
  }

  @override
  void requestState() {
    requests++;
    final state = hub.state;
    if (!disposed && !isLeader && state != null) {
      emit<RoomTabState>('state', state);
    }
  }

  void receive(RoomTabState state) => emit<RoomTabState>('state', state);

  @override
  void dispose() {
    if (disposed) return;
    onRelease?.call();
    disposed = true;
    hub.clients.remove(this);
    if (identical(hub.leader, this)) {
      hub.elect(hub.clients.where((client) => !client.disposed).firstOrNull);
    }
  }
}

RoomTabState _tabState(
  List<Map<String, dynamic>> history, {
  String roomId = _roomId,
  String actor = 'local',
  bool ready = true,
  bool localCopy = false,
  int online = 1,
  String? error,
  List<String> completedResyncs = const [],
}) => RoomTabState(
  roomId: roomId,
  actorId: actor,
  onlineCount: online,
  initialSyncComplete: ready,
  localCopyOpened: localCopy,
  status: online > 1 ? 'Онлайн · участников: $online' : 'Комната готова',
  initialSyncStatus: ready
      ? 'История комнаты проверена'
      : 'Сохраняем и сверяем полную историю…',
  initialSyncError: error,
  inventory: roomHistoryInventory(decodeRoomHistory(history)),
  completedResyncs: completedResyncs,
);

Map<String, dynamic> _edit(
  String id,
  String text, {
  int clock = 1,
  String author = 'remote',
}) => RoomEdit(
  id: id,
  author: author,
  clock: clock,
  createdAt: clock,
  text: text,
).toJson();

List<RoomEdit> _authorChain(String author, List<String> texts) {
  final edits = <RoomEdit>[];
  for (final text in texts) {
    edits.add(
      sequenceAuthoredEdit(
        RoomEdit(
          id: '$author-${edits.length + 1}',
          author: author,
          clock: edits.length + 1,
          createdAt: edits.length + 1,
          text: text,
        ),
        edits,
      ),
    );
  }
  return edits;
}

List<RoomMessage> _sentMessages(_FakeConnection channel) {
  final decoder = RoomMessageDecoder(roomId: _roomId);
  return [
    for (final packet in channel.sent)
      if (decoder.decode(packet).message case final message?) message,
  ];
}

Map<String, dynamic> _message(
  String type,
  List<dynamic> history, {
  String roomId = _roomId,
  String actor = 'remote',
  int online = 2,
  bool hosting = true,
}) => {
  'v': 1,
  'roomId': roomId,
  'type': type,
  'actor': actor,
  'history': history,
  if (type == 'welcome' || type == 'presence') 'online': online,
  if (type == 'welcome' || type == 'presence') 'hosting': hosting,
};

Map<String, dynamic> _checkpoint(
  List<Map<String, dynamic>> history, {
  String actor = 'remote',
  String syncId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  bool inventory = true,
}) => {
  ..._message('checkpoint', const [], actor: actor),
  'syncId': syncId,
  'syncDigest': roomHistoryDigest(decodeRoomHistory(history)),
  if (inventory) 'inventory': roomHistoryInventory(decodeRoomHistory(history)),
};

Map<String, dynamic> _ackLocal(
  _FakeConnection channel, {
  String actor = 'remote',
  bool roomReady = true,
}) {
  final checkpoint = _sentMessages(
    channel,
  ).lastWhere((message) => message.type == RoomMessageType.checkpoint);
  return {
    ..._message('syncAck', const [], actor: actor),
    'syncId': checkpoint.syncId,
    'syncDigest': checkpoint.syncDigest,
    'roomReady': roomReady,
  };
}

void main() {
  late _Network network;
  late List<RoomSession> sessions;
  late Set<_Store> stores;
  late List<_FakeRoomTabs> tabs;

  setUp(() {
    network = _Network();
    sessions = [];
    stores = {};
    tabs = [];
  });

  _FakeRoomTabs roomTabs(_TabsHub hub) {
    final tab = _FakeRoomTabs(hub);
    tabs.add(tab);
    return tab;
  }

  RoomSession session({
    bool member = true,
    bool preferExistingHost = false,
    bool newlyCreated = false,
    bool requireFamilyTree = false,
    String actor = 'local',
    String? participantName,
    _Store? store,
    SignalingPeerFactory? factory,
    IceConfiguration? ice,
    RoomTabs? tabCoordinator,
    DateTime Function() now = DateTime.now,
  }) {
    final chosenStore = store ?? _Store();
    stores.add(chosenStore);
    final room = RoomSession(
      roomId: _roomId,
      actorId: actor,
      participantName: participantName,
      store: chosenStore,
      existingMember: member,
      preferExistingHost: preferExistingHost,
      newlyCreated: newlyCreated,
      requireFamilyTree: requireFamilyTree,
      peerFactory: factory ?? network.create,
      roomTabs: tabCoordinator,
      now: now,
      iceConfiguration: ice ?? const IceConfiguration(),
    );
    sessions.add(room);
    return room;
  }

  Future<void> settle(WidgetTester tester) async {
    // Flush promise chains without jumping across periodic heartbeat timers.
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }
  }

  Future<_FakeConnection> standaloneFollower(
    WidgetTester tester,
    RoomSession room,
  ) async {
    await room.start();
    var peer = network.peers.last;
    if (peer.id == _alias) {
      peer.emit<dynamic>('error', 'ID $_alias is taken');
      await settle(tester);
      peer = network.peers.last;
    }
    peer.register();
    await settle(tester);
    return peer.outbound.single;
  }

  void testRoomWidgets(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        // Flutter verifies fake timers before ordinary test tearDown runs.
        for (final room in sessions) {
          room.dispose();
        }
        await settle(tester);
      }
    });
  }

  tearDown(() async {
    for (final room in sessions) {
      room.dispose();
    }
    await Future<void>.value();
    await network.cleanup();
    for (final tab in tabs) {
      tab.dispose();
      await tab.closeEvents();
    }
    for (final store in stores) {
      await store.changes.close();
    }
  });

  Future<void> settleTabs(WidgetTester tester) async {
    // Leader publication, follower verification and storage watches are bounded
    // 35-ms coalescers, not unbounded chains of recursive microtask refreshes.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      await settle(tester);
    }
  }

  testRoomWidgets(
    'host counts distinct validated actors, retaining every channel',
    (tester) async {
      final room = session();
      await room.start();
      final peer = network.peers.single;
      peer.register();
      final channels = <_FakeConnection>[];
      for (final actor in ['local', 'alice', 'alice', 'bob']) {
        final channel = _FakeConnection('runtime-${channels.length}');
        channels.add(channel);
        network.connections.add(channel);
        peer.emit<DataConnection>('connection', channel);
        channel.openChannel();
        channel.receive(_message('hello', const [], actor: actor));
        await settle(tester);
      }
      expect(room.onlineCount, 3);
      expect(channels.every((channel) => !channel.disposed), isTrue);
      channels[1].emit<void>('close', null);
      await settle(tester);
      expect(
        room.onlineCount,
        3,
        reason: 'alice still has another live channel',
      );
      channels[2].emit<void>('close', null);
      await settle(tester);
      expect(room.onlineCount, 2);
      channels[3].emit<void>('close', null);
      await settle(tester);
      expect(
        room.onlineCount,
        1,
        reason: 'same-actor tab is not a participant',
      );
      expect(channels.first.disposed, isFalse);
      channels.first.receive(
        _message('edits', [
          _edit('local-channel', 'still live'),
        ], actor: 'local'),
      );
      await settle(tester);
      expect(room.text, 'still live');
    },
  );

  testRoomWidgets(
    'without tab support legacy same-actor sessions share unique count',
    (tester) async {
      network.autoRegister = true;
      final host = session();
      await host.start();
      await settle(tester);
      final duplicate = session(preferExistingHost: true);
      await duplicate.start();
      await settle(tester);
      expect(network.peers, hasLength(2));
      expect([host.onlineCount, duplicate.onlineCount], everyElement(1));
      final independent = session(
        actor: 'independent',
        preferExistingHost: true,
      );
      await independent.start();
      await settle(tester);
      expect([
        host.onlineCount,
        duplicate.onlineCount,
        independent.onlineCount,
      ], everyElement(2));
      await duplicate.edit('legacy duplicate edit');
      await settle(tester);
      expect([
        host.text,
        independent.text,
      ], everyElement('legacy duplicate edit'));
    },
  );

  testRoomWidgets(
    'offline new-room siblings reuse one peer and durable storage',
    (tester) async {
      final hub = _TabsHub();
      final store = _Store()..notifyAppends = true;
      final leaderTabs = roomTabs(hub);
      final leader = session(
        store: store,
        newlyCreated: true,
        tabCoordinator: leaderTabs,
      );
      await leader.start();
      expect(leaderTabs.starts, 1);
      expect(network.peers, hasLength(1));
      expect(leader.initialSyncComplete, isTrue);
      final followerTabs = roomTabs(hub);
      final follower = session(store: store, tabCoordinator: followerTabs);
      await follower.start();
      expect(network.peers, hasLength(1));
      expect(store.changes.hasListener, isTrue);
      await settleTabs(tester);
      expect(
        follower.initialSyncComplete,
        isTrue,
        reason: 'a never-shared random new room has an explicit solo proof',
      );
      expect(follower.status, startsWith('Локально ·'));
      expect([leader.onlineCount, follower.onlineCount], everyElement(1));
      await follower.edit('from follower');
      await settleTabs(tester);
      expect([leader.text, follower.text], everyElement('from follower'));
      await leader.edit('from leader');
      await settleTabs(tester);
      expect([leader.text, follower.text], everyElement('from leader'));
      expect([leader.historyLength, follower.historyLength], everyElement(2));
      expect(await store.loadHistory(_roomId), hasLength(2));
      final publications = hub.published;
      final reads = store.loadCalls;
      await tester.pump(const Duration(seconds: 1));
      await settleTabs(tester);
      expect(hub.published, publications, reason: 'no recursive publish loop');
      expect(store.loadCalls, reads, reason: 'no recursive refresh loop');
    },
  );

  testRoomWidgets(
    'follower durable edits relay through leader to independent actor',
    (tester) async {
      network.autoRegister = true;
      final hub = _TabsHub();
      final sharedStore = _Store()..notifyAppends = true;
      final leader = session(store: sharedStore, tabCoordinator: roomTabs(hub));
      await leader.start();
      await settle(tester);
      final remoteStore = _Store();
      final remote = session(
        actor: 'remote-device',
        store: remoteStore,
        preferExistingHost: true,
      );
      await remote.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settleTabs(tester);
      final follower = session(
        store: sharedStore,
        tabCoordinator: roomTabs(hub),
      );
      await follower.start();
      await settleTabs(tester);
      expect(network.peers, hasLength(2));
      expect(follower.initialSyncComplete, isTrue);
      expect([
        leader.onlineCount,
        follower.onlineCount,
        remote.onlineCount,
      ], everyElement(2));
      expect(follower.status, 'Онлайн · участников: 2');
      await follower.edit('shared append from local tab');
      await settleTabs(tester);
      await remote.edit('independent remote edit');
      await settleTabs(tester);
      expect([
        leader.text,
        follower.text,
        remote.text,
      ], everyElement('independent remote edit'));
      final left = await sharedStore.loadHistory(_roomId);
      final right = await remoteStore.loadHistory(_roomId);
      expect(
        {for (final edit in left) edit['id']: edit},
        {for (final edit in right) edit['id']: edit},
      );
      expect([
        leader.historyLength,
        follower.historyLength,
        remote.historyLength,
      ], everyElement(2));
      expect(sharedStore.membershipCalls, 0);
    },
  );

  testRoomWidgets(
    'concurrent same-actor tabs relay canonical full prefixes and matching inventories',
    (tester) async {
      network.autoRegister = true;
      final hub = _TabsHub();
      final sharedStore = _Store()..notifyAppends = true;
      final leader = session(store: sharedStore, tabCoordinator: roomTabs(hub));
      await leader.start();
      await settle(tester);
      final remoteStore = _Store();
      final remote = session(
        actor: 'remote-device',
        store: remoteStore,
        preferExistingHost: true,
      );
      await remote.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settleTabs(tester);
      final follower = session(
        store: sharedStore,
        tabCoordinator: roomTabs(hub),
      );
      await follower.start();
      await settleTabs(tester);
      await Future.wait([
        leader.edit('leader draft'),
        follower.edit('follower draft'),
      ]);
      await settleTabs(tester);
      final saved = validateAuthorHistory(
        decodeRoomHistory(await sharedStore.loadHistory(_roomId)),
      );
      expect(saved.map((edit) => edit.authorSequence), [1, 2]);
      expect(saved.last.authorPrevious, saved.first.id);
      final inventory = roomHistoryInventory(saved);
      for (final room in [leader, follower, remote]) {
        expect(room.historyLength, 2);
        expect(room.storageError, isNull);
        expect(roomHistoryInventory(room.changes), inventory);
      }
      expect(
        roomHistoryInventory(
          decodeRoomHistory(await remoteStore.loadHistory(_roomId)),
        ),
        inventory,
      );
      final batches = network.connections
          .expand(_sentMessages)
          .where((message) => message.type == RoomMessageType.edits);
      expect(batches, isNotEmpty);
      var sawTail = false;
      for (final batch in batches) {
        expect(
          batch.history.map((edit) => edit.id),
          validateAuthorHistory(batch.history).map((edit) => edit.id),
        );
        if (batch.history.any((edit) => edit.authorSequence == 2)) {
          sawTail = true;
          expect(
            batch.history.map((edit) => edit.id),
            saved.map((edit) => edit.id),
          );
        }
      }
      expect(sawTail, isTrue);
      expect(network.peers, hasLength(2));
    },
  );

  testRoomWidgets(
    'ready beacon requires full durable history, not only the winner',
    (tester) async {
      final hub = _TabsHub();
      final owner = roomTabs(hub);
      await owner.start();
      final old = _edit('losing-old', 'losing history');
      final latest = _edit('latest', 'visible winner', clock: 2);
      final store = _Store();
      await store.appendHistory(_roomId, [latest]);
      owner.publish(_tabState([old, latest], online: 2));
      final follower = session(store: store, tabCoordinator: roomTabs(hub));
      await follower.start();
      await settleTabs(tester);
      expect(follower.text, 'visible winner');
      expect(follower.initialSyncComplete, isFalse);
      expect(
        follower.onlineCount,
        1,
        reason: 'unverified beacons give no count proof',
      );
      expect(store.membershipCalls, 0);
      expect(store.appendCalls, 1, reason: 'a beacon cannot append history');
      await store.externalAppend([old]);
      await settleTabs(tester);
      expect(follower.initialSyncComplete, isTrue);
      expect(follower.onlineCount, 2);
      expect(follower.historyLength, 2);
      expect(network.peers, isEmpty);
    },
  );

  testRoomWidgets('leader pending cohort cannot be bypassed by a new sibling', (
    tester,
  ) async {
    network.autoRegister = true;
    final hub = _TabsHub();
    final store = _Store()..notifyAppends = true;
    final host = session(
      store: store,
      newlyCreated: true,
      tabCoordinator: roomTabs(hub),
    );
    await host.start();
    await settleTabs(tester);
    final earlier = session(store: store, tabCoordinator: roomTabs(hub));
    await earlier.start();
    await settleTabs(tester);
    expect(earlier.initialSyncComplete, isTrue);
    final channel = _FakeConnection('backfilling-remote');
    network.connections.add(channel);
    network.peers.single.emit<DataConnection>('connection', channel);
    channel.openChannel();
    final old = _edit('remote-old', 'missing old');
    final latest = _edit('remote-latest', 'latest', clock: 2);
    channel.receive({
      ..._message('hello', [latest]),
      'fastSync': true,
      'durableSync': true,
      'historyDigest': roomHistoryDigest(decodeRoomHistory([old, latest])),
    });
    await settle(tester);
    channel.receive(_checkpoint([old, latest]));
    channel.receive(_ackLocal(channel));
    await settleTabs(tester);
    expect(
      host.initialSyncComplete,
      isTrue,
      reason: 'existing display is latched',
    );
    expect(
      hub.state!.initialSyncComplete,
      isFalse,
      reason: 'a new entry cannot inherit the old host latch',
    );
    final later = session(store: store, tabCoordinator: roomTabs(hub));
    await later.start();
    await settleTabs(tester);
    expect(later.initialSyncComplete, isFalse);
    expect(
      earlier.initialSyncComplete,
      isTrue,
      reason: 'ordinary same-term updates do not clear earlier readiness',
    );
    channel.receive(_message('edits', [old]));
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    channel.receive(_ackLocal(channel));
    await settleTabs(tester);
    expect(later.initialSyncComplete, isTrue);
    expect([
      host.historyLength,
      earlier.historyLength,
      later.historyLength,
    ], everyElement(2));
  });

  testRoomWidgets(
    'follower local drafts and flush errors cannot be masked by owner',
    (tester) async {
      final hub = _TabsHub();
      final owner = roomTabs(hub);
      await owner.start();
      owner.publish(_tabState(const []));
      final store = _Store();
      final tab = roomTabs(hub);
      final follower = session(store: store, tabCoordinator: tab);
      await follower.start();
      await settleTabs(tester);
      store.failAppend = true;
      await follower.edit('unsaved local draft');
      final draft = store.batches.last.single;
      owner.publish(_tabState([draft], online: 3));
      await settleTabs(tester);
      expect(follower.storageError, contains('Disk full'));
      expect(follower.text, 'unsaved local draft');
      expect(
        follower.onlineCount,
        1,
        reason: 'optimistic text is not a checkpoint',
      );
      owner.publish(_tabState(const [], online: 2));
      await settleTabs(tester);
      expect(follower.storageError, contains('Disk full'));
      expect(
        follower.onlineCount,
        1,
        reason: 'own failed saving must not inherit a successful owner status',
      );
      store.failAppend = false;
      await follower.flush();
      owner.publish(_tabState([draft]));
      await settleTabs(tester);
      expect(follower.storageError, isNull);
      store.failFlush = true;
      await expectLater(follower.flush(), throwsStateError);
      owner.publish(_tabState([draft], online: 2));
      await settleTabs(tester);
      expect(follower.storageError, contains('Flush failed'));
      expect(network.peers, isEmpty);
    },
  );

  testRoomWidgets(
    'local-copy flag is truthful but never becomes sync readiness',
    (tester) async {
      final hub = _TabsHub();
      final store = _Store();
      final leader = session(store: store, tabCoordinator: roomTabs(hub));
      await leader.start();
      final follower = session(store: store, tabCoordinator: roomTabs(hub));
      await follower.start();
      await tester.pump(const Duration(seconds: 30));
      await settleTabs(tester);
      expect(follower.initialSyncComplete, isFalse);
      expect(follower.initialSyncError, isNotNull);
      leader.openLocalCopy();
      await settleTabs(tester);
      expect(follower.localCopyOpened, isTrue);
      expect(follower.initialSyncComplete, isFalse);
      expect(follower.status, contains('не подтверждена'));
      expect(follower.onlineCount, 1);
    },
  );

  testRoomWidgets(
    'follower retry requests leader, and term changes reset old proof',
    (tester) async {
      final hub = _TabsHub();
      final owner = roomTabs(hub);
      await owner.start();
      owner.publish(_tabState(const [], online: 2));
      final followerTabs = roomTabs(hub);
      final follower = session(tabCoordinator: followerTabs);
      await follower.start();
      await settleTabs(tester);
      expect(follower.initialSyncComplete, isTrue);
      owner.publish(_tabState(const [], ready: false));
      await settleTabs(tester);
      expect(
        follower.initialSyncComplete,
        isTrue,
        reason: 'ordinary updates retain latched readiness',
      );
      final requests = followerTabs.requests;
      await follower.retry();
      await settleTabs(tester);
      expect(followerTabs.requests, requests + 1);
      expect(follower.initialSyncComplete, isFalse);
      expect(network.peers, isEmpty);
      owner.publish(_tabState(const []));
      await settleTabs(tester);
      expect(follower.initialSyncComplete, isTrue);
      final next = roomTabs(hub);
      await next.start();
      hub.elect(next);
      await settle(tester);
      expect(follower.initialSyncComplete, isFalse);
      expect(follower.onlineCount, 1);
      next.publish(_tabState(const [], ready: false, error: 'owner checking'));
      await settleTabs(tester);
      expect(follower.initialSyncComplete, isFalse);
      expect(follower.initialSyncError, 'owner checking');
    },
  );

  testRoomWidgets('local takeover retires old network before releasing lock', (
    tester,
  ) async {
    network.autoRegister = true;
    final hub = _TabsHub();
    final store = _Store()..notifyAppends = true;
    final firstTabs = roomTabs(hub);
    final first = session(store: store, tabCoordinator: firstTabs);
    await first.start();
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    await settleTabs(tester);
    final nextTabs = roomTabs(hub);
    final next = session(store: store, tabCoordinator: nextTabs);
    await next.start();
    await settleTabs(tester);
    await next.edit('saved before local election');
    await settleTabs(tester);
    expect(next.initialSyncComplete, isTrue);
    final previousPeer = network.peers.single;
    bool? networkRetiredAtRelease;
    firstTabs.onRelease = () {
      networkRetiredAtRelease = previousPeer.destroyed;
    };
    first.dispose();
    await settle(tester);
    expect(networkRetiredAtRelease, isTrue);
    expect(nextTabs.isLeader, isTrue);
    expect(
      next.initialSyncComplete,
      isFalse,
      reason: 'takeover must run a new normal remote entry checkpoint',
    );
    expect(next.text, 'saved before local election');
    expect(next.joined, isTrue);
    expect(network.peers, hasLength(2));
    await tester.pump(const Duration(seconds: 1));
    await settleTabs(tester);
    expect(next.initialSyncComplete, isTrue);
    expect(store.membershipCalls, 0);
    final remote = session(member: false, actor: 'new-remote');
    await remote.start();
    await settle(tester);
    expect(remote.joined, isTrue);
    expect(remote.text, 'saved before local election');
    expect(next.onlineCount, 2);
  });

  testRoomWidgets(
    'stale reads, invalid identities and disposed tab states are ignored',
    (tester) async {
      final hub = _TabsHub();
      final owner = roomTabs(hub);
      await owner.start();
      final store = _Store();
      final tab = roomTabs(hub);
      final follower = session(store: store, tabCoordinator: tab);
      await follower.start();
      tab.receive(_tabState(const [], roomId: 'f' * 32));
      tab.receive(_tabState(const [], actor: 'not-this-store', online: 99));
      await settleTabs(tester);
      expect(follower.initialSyncComplete, isFalse);
      expect(follower.onlineCount, 1);
      final gate = Completer<void>();
      store.loadGate = gate;
      owner.publish(_tabState(const [], online: 3));
      await tester.pump(const Duration(milliseconds: 40));
      await settle(tester);
      final next = roomTabs(hub);
      await next.start();
      hub.elect(next);
      await settle(tester);
      gate.complete();
      await settleTabs(tester);
      expect(
        follower.initialSyncComplete,
        isFalse,
        reason: 'old owner proof cannot finish across an awaited read',
      );
      expect(follower.onlineCount, 1);
      var notifications = 0;
      follower.addListener(() => notifications++);
      follower.dispose();
      tab.receive(_tabState(const []));
      next.publish(_tabState(const [], online: 9));
      await settleTabs(tester);
      expect(notifications, 0);
      expect(follower.initialSyncComplete, isFalse);
      expect(network.peers, isEmpty);
    },
  );

  testRoomWidgets(
    'retired leader cannot publish or use late network callbacks',
    (tester) async {
      final hub = _TabsHub();
      final firstTabs = roomTabs(hub);
      final first = session(tabCoordinator: firstTabs);
      await first.start();
      final peer = network.peers.single;
      peer.register();
      await tester.pump(const Duration(seconds: 1));
      await settleTabs(tester);
      expect(first.initialSyncComplete, isTrue);
      final nextTabs = roomTabs(hub);
      final next = session(tabCoordinator: nextTabs);
      await next.start();
      await settleTabs(tester);
      hub.elect(nextTabs);
      // The lock getter guards publishing and RTC even before the role callback.
      peer.emit<String?>('open', peer.id);
      final stale = _FakeConnection('stale-incoming');
      network.connections.add(stale);
      peer.emit<DataConnection>('connection', stale);
      await settleTabs(tester);
      expect(peer.destroyed, isTrue);
      expect(stale.disposed, isTrue);
      expect(first.initialSyncComplete, isFalse);
      expect(next.initialSyncComplete, isFalse);
      expect(hub.state!.actorId, 'local');
      expect(hub.state!.initialSyncComplete, isFalse);
      expect(network.peers, hasLength(2));
    },
  );

  testRoomWidgets(
    'fresh tab neither claims local election nor admits from beacon',
    (tester) async {
      final hub = _TabsHub();
      final owner = roomTabs(hub);
      await owner.start();
      owner.publish(_tabState([_edit('saved-sibling', 'not an admission')]));
      final store = _Store();
      final freshTabs = roomTabs(hub);
      final fresh = session(
        member: false,
        store: store,
        tabCoordinator: freshTabs,
      );
      await fresh.start();
      freshTabs.receive(hub.state!);
      await store.externalAppend([_edit('saved-sibling', 'not an admission')]);
      await settleTabs(tester);
      expect(freshTabs.starts, 0);
      expect(fresh.joined, isFalse);
      expect(fresh.initialSyncComplete, isFalse);
      expect(fresh.historyLength, 0);
      expect(store.membershipCalls, 0);
      expect(store.changes.hasListener, isFalse);
      expect(network.peers.single.id, isNot(_alias));
    },
  );

  testRoomWidgets(
    'fresh admitted room keeps its network before sibling opens',
    (tester) async {
      network.autoRegister = true;
      final host = session(actor: 'host');
      await host.start();
      await settle(tester);
      final hub = _TabsHub();
      final store = _Store()..notifyAppends = true;
      final freshTabs = roomTabs(hub);
      final fresh = session(
        member: false,
        actor: 'joined-actor',
        store: store,
        tabCoordinator: freshTabs,
      );
      await fresh.start();
      await settle(tester);
      expect(fresh.joined, isTrue);
      expect(fresh.initialSyncComplete, isFalse);
      expect(
        freshTabs.starts,
        0,
        reason: 'durable admission is not full readiness',
      );
      final peer = network.peers.last;
      await tester.pump(const Duration(seconds: 1));
      await settleTabs(tester);
      expect(fresh.initialSyncComplete, isTrue);
      expect(freshTabs.starts, 1);
      expect(freshTabs.isLeader, isTrue);
      expect(
        peer.destroyed,
        isFalse,
        reason: 'lock winner preserves its verified public session',
      );
      final sibling = session(
        actor: 'joined-actor',
        store: store,
        tabCoordinator: roomTabs(hub),
      );
      await sibling.start();
      await settleTabs(tester);
      expect(network.peers, hasLength(2));
      expect([
        host.onlineCount,
        fresh.onlineCount,
        sibling.onlineCount,
      ], everyElement(2));
      expect(sibling.initialSyncComplete, isTrue);
      expect(store.membershipCalls, 1);
    },
  );

  testRoomWidgets(
    'coordinator stream errors revoke inherited proof, not membership',
    (tester) async {
      final hub = _TabsHub();
      final owner = roomTabs(hub);
      await owner.start();
      owner.publish(_tabState(const []));
      final tab = roomTabs(hub);
      final follower = session(tabCoordinator: tab);
      await follower.start();
      await settleTabs(tester);
      expect(follower.initialSyncComplete, isTrue);
      tab._events['state']!.addError(StateError('Tab coordination failed'));
      await settle(tester);
      expect(follower.initialSyncComplete, isFalse);
      expect(follower.initialSyncError, contains('Tab coordination failed'));
      expect(follower.joined, isTrue);
      expect(follower.editable, isTrue);
      expect(network.peers, isEmpty);
    },
  );

  testRoomWidgets(
    'entry waits for losing persistent edits, durable incorporation and peer ACK',
    (tester) async {
      final local = _edit('local-old', 'local old');
      final old = _edit('host-old', 'Ж😀' * 16000, clock: 2);
      final latest = _edit('host-latest', 'latest', clock: 3);
      final store = _Store();
      await store.appendHistory(_roomId, [local]);
      final room = session(store: store);
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      await settle(tester);
      channel.receive({
        ..._message('welcome', [latest]),
        'fastSync': true,
        'historyDigest': roomHistoryDigest(decodeRoomHistory([old, latest])),
        'durableSync': true,
      });
      await settle(tester);
      expect(room.text, 'latest');
      expect(room.joined, isTrue);
      expect(room.initialSyncComplete, isFalse);
      channel.receive({
        ..._message('inventory', const []),
        'inventory': roomHistoryInventory(decodeRoomHistory([old, latest])),
      });
      channel.receive(_checkpoint([old, latest]));
      await settle(tester);
      expect(room.initialSyncComplete, isFalse);
      expect(
        _sentMessages(channel).where((m) => m.type == RoomMessageType.syncAck),
        isEmpty,
      );

      store.appendGate = Completer<void>();
      for (final packet in encodeRoomMessage(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.edits,
          actor: 'remote',
          history: decodeRoomHistory([old]),
        ),
      )) {
        channel.receive(packet);
      }
      await settle(tester);
      expect(room.saving, isTrue);
      expect(room.historyLength, 2);
      expect(room.initialSyncComplete, isFalse);
      expect(
        _sentMessages(channel).where((m) => m.type == RoomMessageType.syncAck),
        isEmpty,
      );
      store.appendGate!.complete();
      await settle(tester);
      expect(room.historyLength, 3);
      expect((await store.loadHistory(_roomId)), hasLength(3));
      expect(
        _sentMessages(channel).where((m) => m.type == RoomMessageType.syncAck),
        hasLength(1),
      );
      expect(room.initialSyncComplete, isFalse, reason: 'send is not an ACK');
      channel.receive(_ackLocal(channel, roomReady: false));
      await settle(tester);
      expect(
        room.initialSyncComplete,
        isFalse,
        reason: 'host cohort is pending',
      );
      channel.receive(_ackLocal(channel));
      await settle(tester);
      expect(room.initialSyncComplete, isTrue);
      expect(room.initialSyncError, isNull);
    },
  );

  testRoomWidgets('equal roots use checkpoints and ACK, never inventory/bulk', (
    tester,
  ) async {
    network.autoRegister = true;
    final history = [_edit('old', 'old'), _edit('latest', 'latest', clock: 2)];
    final a = _Store();
    final b = _Store();
    await a.appendHistory(_roomId, history);
    await b.appendHistory(_roomId, history);
    final host = session(actor: 'host', store: a);
    await host.start();
    await settle(tester);
    final follower = session(
      actor: 'member',
      store: b,
      preferExistingHost: true,
    );
    await follower.start();
    await settle(tester);
    expect(
      [host.initialSyncComplete, follower.initialSyncComplete],
      [false, false],
    );
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(
      [host.initialSyncComplete, follower.initialSyncComplete],
      [true, true],
    );
    final messages = network.connections.expand(_sentMessages).toList();
    expect(messages.where((m) => m.type == RoomMessageType.inventory), isEmpty);
    expect(messages.where((m) => m.type == RoomMessageType.edits), isEmpty);
    expect(
      messages.where((m) => m.type == RoomMessageType.checkpoint),
      hasLength(2),
    );
    expect(
      messages
          .where((m) => m.type == RoomMessageType.checkpoint)
          .every((m) => m.inventory == null),
      isTrue,
    );
    expect(
      messages.where((m) => m.type == RoomMessageType.syncAck),
      isNotEmpty,
    );
    // Later typing and network loss must never resurrect the entry loader.
    await follower.edit('later');
    await settle(tester);
    network.peers.first.loseSignaling();
    await settle(tester);
    expect(
      [host.initialSyncComplete, follower.initialSyncComplete],
      [true, true],
    );
  });

  testRoomWidgets(
    'entry cutoff includes pending admission save, not later typing',
    (tester) async {
      final common = _edit('common', 'common');
      final store = _Store();
      await store.appendHistory(_roomId, [common]);
      final room = session(store: store);
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      await settle(tester);
      store.appendGate = Completer<void>();
      final pending = room.edit('pending at admission');
      channel.receive({
        ..._message('welcome', [common]),
        'fastSync': true,
        'historyDigest': roomHistoryDigest(decodeRoomHistory([common])),
        'durableSync': true,
        'authorHistory': true,
      });
      await settle(tester);
      expect(room.initialSyncComplete, isFalse);
      expect(
        _sentMessages(
          channel,
        ).where((m) => m.type == RoomMessageType.checkpoint),
        isEmpty,
      );
      store.appendGate!.complete();
      await pending;
      await settle(tester);
      final checkpoint = _sentMessages(
        channel,
      ).singleWhere((m) => m.type == RoomMessageType.checkpoint);
      expect(
        checkpoint.syncDigest,
        roomHistoryDigest(decodeRoomHistory(await store.loadHistory(_roomId))),
      );
      store.appendGate = Completer<void>();
      final later = room.edit('later still pending');
      channel.receive(_checkpoint([common]));
      channel.receive(_ackLocal(channel));
      await settle(tester);
      expect(room.saving, isTrue);
      expect(
        room.initialSyncComplete,
        isTrue,
        reason: 'typing after the fixed cutoff is normal editing, not entry',
      );
      store.appendGate!.complete();
      await later;
    },
  );

  testRoomWidgets('fresh admission and its completion are fully durable', (
    tester,
  ) async {
    final history = [
      _edit('first', 'first'),
      _edit('winner', 'winner', clock: 2),
    ];
    final store = _Store()
      ..appendGate = Completer<void>()
      ..membershipGate = Completer<void>();
    final room = session(member: false, store: store);
    final channel = await standaloneFollower(tester, room);
    channel.openChannel();
    await settle(tester);
    channel.receive({..._message('welcome', history), 'durableSync': true});
    await settle(tester);
    expect(room.joined, isFalse);
    expect(room.initialSyncComplete, isFalse);
    expect(store.membershipCalls, 0);
    store.appendGate!.complete();
    await settle(tester);
    expect(room.joined, isFalse);
    expect(store.membershipCalls, 1);
    store.membershipGate!.complete();
    await settle(tester);
    expect(room.joined, isTrue);
    expect(room.initialSyncComplete, isFalse);
    expect(await store.hasMembership(_roomId), isTrue);
    expect(await store.loadHistory(_roomId), hasLength(2));
    channel.receive(_checkpoint(history, inventory: false));
    channel.receive(_ackLocal(channel));
    await settle(tester);
    expect(room.initialSyncComplete, isTrue);
  });

  testRoomWidgets('host ready ACK waits for another live initial backfill', (
    tester,
  ) async {
    network.autoRegister = true;
    final hostStore = _Store();
    final host = session(actor: 'host', store: hostStore, newlyCreated: true);
    await host.start();
    await settle(tester);
    expect(host.initialSyncComplete, isTrue);
    final other = _FakeConnection('other-member');
    network.connections.add(other);
    network.peers.first.emit<DataConnection>('connection', other);
    other.openChannel();
    final old = _edit('other-old', 'old from other', clock: 1, author: 'other');
    final latest = _edit('other-latest', 'latest', clock: 2, author: 'other');
    other.receive({
      ..._message('hello', [latest], actor: 'other'),
      'fastSync': true,
      'historyDigest': roomHistoryDigest(decodeRoomHistory([old, latest])),
      'durableSync': true,
    });
    await settle(tester);
    other.receive(_checkpoint([old, latest], actor: 'other'));
    await settle(tester);
    final fresh = session(member: false, actor: 'fresh');
    await fresh.start();
    await settle(tester);
    expect(fresh.joined, isTrue);
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect(fresh.initialSyncComplete, isFalse);
    final toFresh = network.connections.singleWhere(
      (channel) => channel.peer != _alias && channel.peer != 'other-member',
    );
    expect(
      _sentMessages(toFresh)
          .where((m) => m.type == RoomMessageType.syncAck)
          .every((m) => m.roomReady == false),
      isTrue,
    );
    hostStore.appendGate = Completer<void>();
    other.receive(_message('edits', [old], actor: 'other'));
    await settle(tester);
    expect(fresh.initialSyncComplete, isFalse);
    hostStore.appendGate!.complete();
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(fresh.historyLength, 2);
    expect(fresh.initialSyncComplete, isTrue);
    expect(host.initialSyncComplete, isTrue);
  });

  testRoomWidgets(
    'solo requires validated alias coverage and a stable interval',
    (tester) async {
      late _CoveragePeer peer;
      final room = session(factory: (id, _) => peer = _CoveragePeer(id));
      await room.start();
      peer.cover(
        true,
      ); // Coverage alone before validated open is not registration.
      await tester.pump(const Duration(seconds: 1));
      expect(room.initialSyncComplete, isFalse);
      peer.cover(false);
      peer.register();
      await tester.pump(const Duration(seconds: 2));
      expect(room.onlineCount, 1);
      expect(room.initialSyncComplete, isFalse);
      peer.cover(true);
      await tester.pump(const Duration(milliseconds: 700));
      expect(room.initialSyncComplete, isFalse);
      await tester.pump(const Duration(milliseconds: 300));
      expect(room.initialSyncComplete, isTrue);
      room.dispose();
      await peer.closeEvents();
    },
  );

  testRoomWidgets(
    'durable live peer sync does not require solo discovery coverage',
    (tester) async {
      late _CoveragePeer peer;
      final room = session(factory: (id, _) => peer = _CoveragePeer(id));
      await room.start();
      peer.register();
      expect(peer.discoveryComplete, isFalse);
      final channel = _FakeConnection('real-member');
      network.connections.add(channel);
      peer.emit<RoomChannel>('connection', PeerJsRoomChannel(channel));
      channel.openChannel();
      channel.receive({..._message('hello', const []), 'durableSync': true});
      await settle(tester);
      channel.receive(_checkpoint(const [], inventory: false));
      channel.receive(_ackLocal(channel));
      await settle(tester);
      expect(room.initialSyncComplete, isFalse);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(peer.discoveryComplete, isFalse);
      expect(room.initialSyncComplete, isTrue);
      expect(
        _sentMessages(
          channel,
        ).where((m) => m.type == RoomMessageType.syncAck).last.roomReady,
        isTrue,
      );
      room.dispose();
      await peer.closeEvents();
    },
  );

  testRoomWidgets(
    'outage and count one cannot prove solo; retry/local copy preserve history',
    (tester) async {
      final store = _Store();
      await store.appendHistory(_roomId, [_edit('saved', 'saved')]);
      final room = session(store: store);
      await room.start();
      await tester.pump(const Duration(seconds: 30));
      await settle(tester);
      expect(room.onlineCount, 1);
      expect(room.initialSyncComplete, isFalse);
      expect(room.initialSyncError, contains('30 секунд'));
      expect(room.joined, isTrue);
      expect(room.editable, isTrue);
      room.openLocalCopy();
      expect(room.localCopyOpened, isTrue);
      expect(room.initialSyncComplete, isFalse);
      expect(room.initialSyncStatus, contains('не подтверждена'));
      await room.retry();
      expect(room.localCopyOpened, isFalse);
      expect(room.initialSyncError, isNull);
      network.peers.last.register();
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(room.initialSyncComplete, isTrue);
      expect(room.text, 'saved');
      expect(store.membershipCalls, 0);
    },
  );

  testRoomWidgets(
    'three unadmitted provider hedges do not hold a real cohort for handshake timeout',
    (tester) async {
      network.autoRegister = true;
      final host = session(actor: 'host');
      await host.start();
      await settle(tester);
      final hedges = <_FakeConnection>[];
      for (var i = 0; i < 3; i++) {
        final hedge = _FakeConnection('losing-provider-$i');
        hedges.add(hedge);
        network.connections.add(hedge);
        network.peers.first.emit<DataConnection>('connection', hedge);
        if (i != 0) hedge.openChannel();
      }
      final returning = session(actor: 'phone', preferExistingHost: true);
      await returning.start();
      await settle(tester);
      expect(returning.connectedToRemoteHost, isTrue);
      expect(host.connectedToRemoteHost, isFalse);
      expect(returning.initialSyncComplete, isFalse);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(
        [host.initialSyncComplete, returning.initialSyncComplete],
        [true, true],
      );
      expect(hedges.every((channel) => !channel.disposed), isTrue);
      expect([host.onlineCount, returning.onlineCount], [2, 2]);
      // The transports still have ordinary admission bounds; excluding them
      // from this real cohort does not admit, count, or retain them forever.
      await tester.pump(const Duration(seconds: 11));
      await settle(tester);
      expect(hedges.every((channel) => channel.disposed), isTrue);
      expect(returning.connectedToRemoteHost, isTrue);
      expect(returning.initialSyncComplete, isTrue);
    },
  );

  testRoomWidgets(
    'bounded incoming hello assembly remains in real cohort until durable admission',
    (tester) async {
      network.autoRegister = true;
      final host = session(actor: 'host');
      await host.start();
      await settle(tester);
      final incoming = _FakeConnection('large-hello-runtime');
      network.connections.add(incoming);
      network.peers.first.emit<DataConnection>('connection', incoming);
      incoming.openChannel();
      final edit = _edit(
        'large-hello-edit',
        'Ж😀' * 6000,
        author: 'large-peer',
      );
      final chunks = encodeRoomMessage(
        decodeRoomMessage({
          ..._message('hello', [edit], actor: 'large-peer'),
          'durableSync': true,
        }, roomId: _roomId),
      ).toList();
      incoming.receive(chunks.first);
      final returning = session(actor: 'phone', preferExistingHost: true);
      await returning.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 13));
      await settle(tester);
      expect(incoming.disposed, isFalse);
      expect(
        returning.initialSyncComplete,
        isFalse,
        reason: 'a real assembly is not a blank signaling hedge',
      );
      incoming.receive(chunks[1]);
      await tester.pump(const Duration(seconds: 11));
      for (final chunk in chunks.skip(2)) {
        incoming.receive(chunk);
      }
      await settle(tester);
      incoming.receive(_checkpoint([edit], actor: 'large-peer'));
      incoming.receive(_ackLocal(incoming, actor: 'large-peer'));
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(returning.initialSyncComplete, isTrue);
      expect(returning.text, edit['text']);
      expect(host.initialSyncComplete, isTrue);
      expect(host.onlineCount, 3);
      expect(incoming.disposed, isFalse);
    },
  );

  testRoomWidgets(
    'unadmitted transports alone cannot prove solo before their deadline',
    (tester) async {
      final host = session();
      await host.start();
      final peer = network.peers.single;
      peer.register();
      final hedge = _FakeConnection('pending-only');
      network.connections.add(hedge);
      peer.emit<DataConnection>('connection', hedge);
      hedge.openChannel();
      await tester.pump(const Duration(seconds: 11));
      await settle(tester);
      expect(host.initialSyncComplete, isFalse);
      expect(hedge.disposed, isFalse);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(hedge.disposed, isTrue);
      expect(host.initialSyncComplete, isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(host.initialSyncComplete, isTrue);
    },
  );

  testRoomWidgets(
    'stale admitted same-actor round retires without dropping healthy returning channel',
    (tester) async {
      network.autoRegister = true;
      final host = session(actor: 'host');
      await host.start();
      await settle(tester);
      final stale = _FakeConnection('old-phone-runtime');
      network.connections.add(stale);
      network.peers.first.emit<DataConnection>('connection', stale);
      stale.openChannel();
      stale.receive({
        ..._message('hello', const [], actor: 'phone'),
        'durableSync': true,
      });
      await settle(tester);
      await tester.pump(const Duration(seconds: 2));
      final returning = session(actor: 'phone', preferExistingHost: true);
      await returning.start();
      await settle(tester);
      final healthy = network.peers.last.outbound.single;
      for (var i = 0; i < 3; i++) {
        stale.receive(_message('presence', const [], actor: 'phone'));
        await tester.pump(const Duration(seconds: 3));
        await settle(tester);
      }
      expect(
        stale.disposed,
        isFalse,
        reason: 'actor equality is not a retirement reason',
      );
      expect(returning.initialSyncComplete, isFalse);
      expect(healthy.disposed, isFalse);
      stale.receive(_message('presence', const [], actor: 'phone'));
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(stale.disposed, isTrue);
      expect(
        healthy.disposed,
        isFalse,
        reason: 'its imported/ACKed round is fulfilled',
      );
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(
        [host.initialSyncComplete, returning.initialSyncComplete],
        [true, true],
      );
      expect([host.onlineCount, returning.onlineCount], [2, 2]);
      await returning.edit('healthy phone still shares');
      await settle(tester);
      expect(host.text, 'healthy phone still shares');
    },
  );

  testRoomWidgets(
    'missing initial ACK expires despite keepalive and preserves evidence against solo',
    (tester) async {
      final host = session();
      await host.start();
      final peer = network.peers.single;
      peer.register();
      final channel = _FakeConnection('no-ack');
      network.connections.add(channel);
      peer.emit<DataConnection>('connection', channel);
      channel.openChannel();
      channel.receive({..._message('hello', const []), 'durableSync': true});
      await settle(tester);
      channel.receive(_checkpoint(const []));
      await settle(tester);
      for (var i = 0; i < 4; i++) {
        channel.receive(_message('presence', const []));
        await tester.pump(const Duration(seconds: 3));
        await settle(tester);
      }
      expect(channel.disposed, isTrue);
      expect(host.log, contains(contains('Не подтверждена контрольная точка')));
      await tester.pump(const Duration(seconds: 5));
      expect(host.onlineCount, 1);
      expect(host.initialSyncComplete, isFalse);
      expect(host.initialSyncError, isNull);
      await tester.pump(const Duration(seconds: 13));
      expect(host.initialSyncError, contains('30 секунд'));
      expect(host.joined, isTrue);
    },
  );

  testRoomWidgets(
    'saved follower missing ACK retries through existing alias election after checkpoint bound',
    (tester) async {
      final store = _Store();
      final room = session(store: store, preferExistingHost: true);
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      channel.receive({
        ..._message('welcome', const []),
        'durableSync': true,
        'authorHistory': true,
      });
      await settle(tester);
      channel.receive(_checkpoint(const []));
      await settle(tester);
      await room.edit('durable while waiting');
      for (var i = 0; i < 4; i++) {
        channel.receive(_message('presence', const []));
        await tester.pump(const Duration(seconds: 3));
        await settle(tester);
      }
      expect(channel.disposed, isTrue);
      expect(room.connectedToRemoteHost, isFalse);
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      expect(network.peers, hasLength(2));
      expect(network.peers.last.id, _alias);
      expect(room.joined, isTrue);
      expect(room.text, 'durable while waiting');
      expect(room.initialSyncComplete, isFalse);
      expect(store.membershipCalls, 0);
    },
  );

  testRoomWidgets(
    'transient saved outbound close retries and still requires a current durable ACK',
    (tester) async {
      final store = _Store();
      final local = _edit('local-only', 'local history');
      final remote = _edit('remote-only', 'remote history', clock: 2);
      await store.appendHistory(_roomId, [local]);
      final room = session(store: store, preferExistingHost: true);
      final first = await standaloneFollower(tester, room);
      final firstPeer = network.peers.single;
      first.openChannel();
      first.receive({
        ..._message('welcome', [remote]),
        'durableSync': true,
      });
      await settle(tester);
      first.receive(_checkpoint([remote]));
      await settle(tester);
      final staleAck = _ackLocal(first);
      first.emit<void>('close', null);
      await settle(tester);
      expect(room.initialSyncError, isNull);
      expect(room.initialSyncComplete, isFalse);
      expect(room.localCopyOpened, isFalse);
      expect(room.joined, isTrue);
      await tester.pump(const Duration(milliseconds: 1100));
      await settle(tester);
      expect(network.peers, hasLength(2));
      expect(firstPeer.destroyed, isTrue);
      expect(first.disposed, isTrue);
      expect(network.peers.last.id, _alias);
      // The retry must retain evidence of the interrupted participant. A
      // successful empty election cannot turn that loss into proof of solo.
      network.peers.last.register();
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(room.initialSyncComplete, isFalse);
      final next = _FakeConnection('returning-runtime');
      network.connections.add(next);
      network.peers.last.emit<DataConnection>('connection', next);
      next.openChannel();
      next.receive({
        ..._message('hello', [remote]),
        'durableSync': true,
      });
      await settle(tester);
      next.receive(_checkpoint([local, remote]));
      next.receive(staleAck);
      first.receive(staleAck);
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(room.initialSyncComplete, isFalse);
      next.receive(_ackLocal(next));
      await settle(tester);
      expect(room.initialSyncComplete, isTrue);
      expect(room.initialSyncError, isNull);
      expect(room.historyLength, 2);
      expect(await store.loadHistory(_roomId), [local, remote]);
      expect(store.membershipCalls, 0);
    },
  );

  testRoomWidgets(
    'saved outbound close after hello but before welcome cannot become solo on automatic retry',
    (tester) async {
      final store = _Store();
      final local = _edit('saved-only', 'saved local history');
      await store.appendHistory(_roomId, [local]);
      final room = session(store: store, preferExistingHost: true);
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      await settle(tester);
      expect(_sentMessages(channel).single.type, RoomMessageType.hello);
      channel.emit<void>('close', null);
      await settle(tester);
      expect(room.initialSyncError, isNull);
      await tester.pump(const Duration(milliseconds: 1100));
      await settle(tester);
      final replacement = network.peers.last;
      expect(replacement.id, _alias);
      replacement.register();
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(room.initialSyncComplete, isFalse);
      await tester.pump(const Duration(milliseconds: 27899));
      expect(room.initialSyncError, isNull);
      await tester.pump(const Duration(milliseconds: 1));
      expect(room.initialSyncError, contains('30 секунд'));
      expect(room.initialSyncComplete, isFalse);
      expect(room.localCopyOpened, isFalse);
      expect(room.joined, isTrue);
      expect(store.membershipCalls, 0);
      expect(await store.loadHistory(_roomId), [local]);
      // Only an explicit new verification may discard the failed-attempt
      // evidence and use a newly validated absence check.
      await room.retry();
      network.peers.last.register();
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(room.initialSyncComplete, isTrue);
      expect(room.initialSyncError, isNull);
    },
  );

  testRoomWidgets(
    'failed pre-admission welcome save remains explicit and cannot become solo',
    (tester) async {
      final store = _Store()..failAppend = true;
      final room = session(store: store, preferExistingHost: true);
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      channel.receive({
        ..._message('welcome', [_edit('remote-only', 'must save')]),
        'durableSync': true,
      });
      await settle(tester);
      final storageError = room.initialSyncError;
      expect(storageError, isNotNull);
      expect(room.storageError, isNotNull);
      expect(channel.disposed, isTrue);
      await tester.pump(const Duration(milliseconds: 1100));
      await settle(tester);
      network.peers.last.register();
      await tester.pump(const Duration(seconds: 31));
      await settle(tester);
      expect(room.initialSyncComplete, isFalse);
      expect(room.initialSyncError, storageError);
      expect(room.localCopyOpened, isFalse);
      expect(store.membershipCalls, 0);
      expect(await store.loadHistory(_roomId), isEmpty);
    },
  );

  testRoomWidgets(
    'transient last incoming close reelects without extending deadline and recovers after error',
    (tester) async {
      final store = _Store();
      final local = _edit('local-only', 'local history');
      final remote = _edit('remote-only', 'remote history', clock: 2);
      await store.appendHistory(_roomId, [local]);
      final room = session(store: store);
      await room.start();
      final firstPeer = network.peers.single;
      firstPeer.register();
      final first = _FakeConnection('interrupted-runtime');
      network.connections.add(first);
      firstPeer.emit<DataConnection>('connection', first);
      first.openChannel();
      first.receive({..._message('hello', const []), 'durableSync': true});
      await settle(tester);
      first.receive(_checkpoint([remote]));
      await settle(tester);
      final staleAck = _ackLocal(first);
      await tester.pump(const Duration(seconds: 4));
      first.emit<void>('close', null);
      await settle(tester);
      expect(room.initialSyncError, isNull);
      expect(
        network.peers,
        hasLength(1),
        reason: 'ordinary backoff, not a spin',
      );
      await tester.pump(const Duration(milliseconds: 1100));
      await settle(tester);
      expect(network.peers, hasLength(2));
      expect(firstPeer.destroyed, isTrue);
      expect(first.disposed, isTrue);
      final current = network.peers.last;
      current.register();
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(
        room.initialSyncComplete,
        isFalse,
        reason: 'lost peer is not solo',
      );
      await tester.pump(const Duration(milliseconds: 23899));
      expect(room.initialSyncError, isNull);
      await tester.pump(const Duration(milliseconds: 1));
      final timeout = room.initialSyncError;
      expect(timeout, contains('30 секунд'));
      expect(room.localCopyOpened, isFalse);
      expect(room.joined, isTrue);
      expect(await store.loadHistory(_roomId), [local]);
      final next = _FakeConnection('recovered-runtime');
      network.connections.add(next);
      current.emit<DataConnection>('connection', next);
      next.openChannel();
      store.appendGate = Completer<void>();
      next.receive({
        ..._message('hello', [remote]),
        'durableSync': true,
      });
      await settle(tester);
      expect(room.initialSyncError, timeout);
      expect(room.initialSyncComplete, isFalse);
      expect(
        next.sent,
        isEmpty,
        reason: 'no welcome or ACK before durable save',
      );
      store.appendGate!.complete();
      await settle(tester);
      next.receive(_checkpoint([local, remote]));
      next.receive(staleAck);
      first.receive(_checkpoint([local, remote]));
      first.receive(staleAck);
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(room.initialSyncComplete, isFalse);
      expect(room.initialSyncError, timeout);
      next.receive(_ackLocal(next));
      await settle(tester);
      expect(room.initialSyncComplete, isTrue);
      expect(room.initialSyncError, isNull);
      expect(room.localCopyOpened, isFalse);
      expect(await store.loadHistory(_roomId), [local, remote]);
      expect(store.membershipCalls, 0);
    },
  );

  testRoomWidgets(
    'fresh pre-welcome close retries as a visitor and cannot bypass admission or deadline',
    (tester) async {
      final store = _Store();
      final room = session(member: false, store: store);
      final first = await standaloneFollower(tester, room);
      first.openChannel();
      await settle(tester);
      await tester.pump(const Duration(seconds: 4));
      first.emit<void>('close', null);
      await settle(tester);
      expect(room.initialSyncError, isNull);
      await tester.pump(const Duration(milliseconds: 1100));
      await settle(tester);
      expect(network.peers, hasLength(2));
      expect(network.peers.last.id, isNot(_alias));
      first.receive({..._message('welcome', const []), 'durableSync': true});
      room.openLocalCopy();
      await tester.pump(const Duration(milliseconds: 24900));
      await settle(tester);
      expect(room.error, contains('30 секунд'));
      expect(room.initialSyncComplete, isFalse);
      expect(room.localCopyOpened, isFalse);
      expect(room.joined, isFalse);
      expect(store.membershipCalls, 0);
      expect(await store.loadHistory(_roomId), isEmpty);
      final peers = network.peers.length;
      await tester.pump(const Duration(seconds: 40));
      await settle(tester);
      expect(network.peers.length, peers, reason: 'expired visitor must stop');
    },
  );

  testRoomWidgets(
    'dispose cancels the automatic initial incoming recovery generation',
    (tester) async {
      final room = session();
      await room.start();
      final peer = network.peers.single;
      peer.register();
      final channel = _FakeConnection('interrupted-runtime');
      network.connections.add(channel);
      peer.emit<DataConnection>('connection', channel);
      channel.openChannel();
      channel.receive({..._message('hello', const []), 'durableSync': true});
      await settle(tester);
      channel.emit<void>('close', null);
      room.dispose();
      await settle(tester);
      await tester.pump(const Duration(seconds: 40));
      await settle(tester);
      expect(network.peers, hasLength(1));
      expect(peer.destroyed, isTrue);
      expect(channel.disposed, isTrue);
      expect(room.initialSyncComplete, isFalse);
    },
  );

  testRoomWidgets(
    'admitted checkpoint assembly can finish within its existing fixed 25 seconds',
    (tester) async {
      final old = _edit('slow-large-old', 'Ж😀' * 6000);
      final room = session(preferExistingHost: true);
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      channel.receive({..._message('welcome', const []), 'durableSync': true});
      await settle(tester);
      channel.receive(_checkpoint([old]));
      channel.receive(_ackLocal(channel));
      await settle(tester);
      final chunks = encodeRoomMessage(
        decodeRoomMessage(_message('edits', [old]), roomId: _roomId),
      ).toList();
      channel.receive(chunks.first);
      room.resume();
      await tester.pump(const Duration(seconds: 13));
      await settle(tester);
      expect(
        channel.disposed,
        isFalse,
        reason: 'resume must preserve the real assembly deadline',
      );
      channel.receive(chunks[1]);
      await tester.pump(const Duration(seconds: 11));
      await settle(tester);
      expect(channel.disposed, isFalse);
      for (final chunk in chunks.skip(2)) {
        channel.receive(chunk);
      }
      await settle(tester);
      expect(room.initialSyncComplete, isTrue);
      expect(room.text, old['text']);
      // A fulfilled round cancels both short and large-transfer bounds.
      channel.receive(_message('presence', const []));
      await tester.pump(const Duration(seconds: 6));
      await settle(tester);
      expect(channel.disposed, isFalse);
    },
  );

  testRoomWidgets(
    'admitted checkpoint assembly cap is not postponed by fragments or presence',
    (tester) async {
      final old = _edit('unfinished-large-old', 'Ж😀' * 6000);
      final room = session(preferExistingHost: true);
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      channel.receive({..._message('welcome', const []), 'durableSync': true});
      await settle(tester);
      channel.receive(_checkpoint([old]));
      channel.receive(_ackLocal(channel));
      await settle(tester);
      final chunks = encodeRoomMessage(
        decodeRoomMessage(_message('edits', [old]), roomId: _roomId),
      ).toList();
      channel.receive(chunks.first);
      await tester.pump(const Duration(seconds: 15));
      channel.receive(chunks[1]);
      channel.receive(_message('presence', const []));
      await tester.pump(const Duration(seconds: 10));
      await settle(tester);
      expect(channel.disposed, isTrue);
      expect(room.initialSyncComplete, isFalse);
      expect(room.historyLength, 0);
    },
  );

  testRoomWidgets(
    'superseding final host checkpoint gets a fresh bounded ACK round and ignores stale proof',
    (tester) async {
      final host = session(actor: 'host');
      await host.start();
      final peer = network.peers.single;
      peer.register();
      final alice = _FakeConnection('alice-runtime');
      final bob = _FakeConnection('bob-runtime');
      for (final channel in [alice, bob]) {
        network.connections.add(channel);
        peer.emit<DataConnection>('connection', channel);
        channel.openChannel();
        channel.receive({
          ..._message(
            'hello',
            const [],
            actor: channel == alice ? 'alice' : 'bob',
          ),
          'durableSync': true,
        });
        await settle(tester);
      }
      final staleAliceAck = _ackLocal(alice, actor: 'alice');
      alice.receive(_checkpoint(const [], actor: 'alice'));
      alice.receive(staleAliceAck);
      await settle(tester);
      // Alice's own round is fulfilled. Bob's admitted contribution still
      // prevents the final host cutoff, rather than dropping healthy Alice.
      await tester.pump(const Duration(seconds: 10));
      final imported = _edit('bob-import', 'from bob', author: 'bob');
      bob.receive(_message('edits', [imported], actor: 'bob'));
      bob.receive(_checkpoint([imported], actor: 'bob'));
      bob.receive(_ackLocal(bob, actor: 'bob'));
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      final finalAliceAck = _ackLocal(alice, actor: 'alice');
      expect(finalAliceAck['syncId'], isNot(staleAliceAck['syncId']));
      bob.receive(_ackLocal(bob, actor: 'bob'));
      alice.receive(staleAliceAck);
      await settle(tester);
      expect(
        host.initialSyncComplete,
        isFalse,
        reason: 'the old snapshot ACK cannot fulfill the final cutoff',
      );
      await tester.pump(const Duration(seconds: 8));
      await settle(tester);
      expect(
        alice.disposed,
        isFalse,
        reason: 'the final round did not inherit the admission deadline',
      );
      alice.receive(finalAliceAck);
      await settle(tester);
      expect(host.initialSyncComplete, isTrue);
      for (var i = 0; i < 3; i++) {
        alice.receive(_message('presence', const [], actor: 'alice'));
        bob.receive(_message('presence', const [], actor: 'bob'));
        await tester.pump(const Duration(seconds: 5));
        await settle(tester);
      }
      expect([alice.disposed, bob.disposed], [false, false]);
      var notifications = 0;
      host.addListener(() => notifications++);
      host.dispose();
      final peers = network.peers.length;
      alice.receive(_checkpoint([imported], actor: 'alice', syncId: 'b' * 32));
      alice.receive(finalAliceAck);
      await tester.pump(const Duration(seconds: 40));
      await settle(tester);
      expect(notifications, 0);
      expect(network.peers.length, peers);
      expect([alice.disposed, bob.disposed], [true, true]);
    },
  );

  testRoomWidgets(
    'known pending initial participant timeout cannot be inferred solo',
    (tester) async {
      final room = session();
      await room.start();
      final peer = network.peers.single;
      peer.register();
      final incoming = _FakeConnection('initial-member');
      network.connections.add(incoming);
      peer.emit<DataConnection>('connection', incoming);
      incoming.openChannel();
      final old = _edit('missing-old', 'missing historical edit');
      incoming.receive({..._message('hello', const []), 'durableSync': true});
      await settle(tester);
      incoming.receive(_checkpoint([old]));
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(room.initialSyncComplete, isFalse);
      await tester.pump(const Duration(seconds: 21));
      await settle(tester);
      expect(incoming.disposed, isTrue);
      expect(room.initialSyncComplete, isFalse);
      await tester.pump(const Duration(seconds: 8));
      expect(room.initialSyncError, isNotNull);
    },
  );

  testRoomWidgets('unadmitted canceled discovery hedge does not poison solo', (
    tester,
  ) async {
    final room = session();
    await room.start();
    final peer = network.peers.single;
    peer.register();
    final hedge = _FakeConnection('unadmitted-hedge');
    network.connections.add(hedge);
    peer.emit<DataConnection>('connection', hedge);
    hedge.openChannel();
    await tester.pump(const Duration(milliseconds: 600));
    expect(room.initialSyncComplete, isFalse);
    hedge.emit<void>('close', null);
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(room.initialSyncComplete, isTrue);
  });

  testRoomWidgets(
    'latched host allows newcomer after another incomplete peer drops',
    (tester) async {
      network.autoRegister = true;
      final host = session(actor: 'host', newlyCreated: true);
      await host.start();
      await settle(tester);
      final abandoned = _FakeConnection('abandoned');
      network.connections.add(abandoned);
      network.peers.first.emit<DataConnection>('connection', abandoned);
      abandoned.openChannel();
      abandoned.receive({..._message('hello', const []), 'durableSync': true});
      await settle(tester);
      abandoned.receive(_checkpoint([_edit('never-received', 'missing')]));
      await settle(tester);
      abandoned.emit<void>('close', null);
      await settle(tester);
      expect(host.initialSyncComplete, isTrue);
      final fresh = session(member: false, actor: 'later-newcomer');
      await fresh.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(fresh.joined, isTrue);
      expect(fresh.initialSyncComplete, isTrue);
    },
  );

  for (final returning in [false, true]) {
    testRoomWidgets(
      '${returning ? 'returning' : 'new'} member does not wait for an established silent channel',
      (tester) async {
        network.autoRegister = true;
        final host = session(actor: 'host', newlyCreated: true);
        await host.start();
        await settle(tester);
        await host.edit('history before suspension');
        final oldStore = _Store();
        final sleeping = session(
          actor: 'sleeping',
          store: oldStore,
          preferExistingHost: true,
        );
        await sleeping.start();
        await settle(tester);
        await tester.pump(const Duration(seconds: 1));
        await settle(tester);
        expect(sleeping.initialSyncComplete, isTrue);
        final oldOutgoing = network.peers.last.outbound.single;
        final oldIncoming = oldOutgoing.other!;
        sleeping.setForeground(false);
        oldOutgoing.dropData = true;
        oldIncoming.dropData = true;
        await host.edit('new durable history while the old channel is silent');
        for (var tick = 0; tick < 5; tick++) {
          await tester.pump(const Duration(seconds: 5));
          await settle(tester);
        }
        expect(oldIncoming.disposed, isFalse);
        expect(host.onlineCount, 1);
        // A heartbeat restores presence, not the overdue durable proof. It must
        // not make this old recheck a prerequisite for a new member again.
        oldIncoming.receive(_message('presence', const [], actor: 'sleeping'));
        await settle(tester);
        final joiningStore = returning ? oldStore : _Store();
        final joining = session(
          actor: returning ? 'sleeping' : 'new-member',
          member: returning,
          store: joiningStore,
          preferExistingHost: true,
        );
        await joining.start();
        await settle(tester);
        await tester.pump(const Duration(seconds: 1));
        await settle(tester);
        expect(
          joining.initialSyncComplete,
          isTrue,
          reason:
              'an unavailable previously imported peer is not a new initial contribution',
        );
        expect(joining.initialSyncError, isNull);
        expect(joining.text, host.text);
        expect(
          roomHistoryInventory(joining.changes),
          roomHistoryInventory(host.changes),
        );
        expect(
          oldIncoming.disposed,
          isFalse,
          reason: 'entry must not require destroying the recoverable old RTC',
        );
      },
    );
  }

  for (final announcement in ['inventory', 'checkpoint', 'recheck']) {
    testRoomWidgets(
      'entry retains missing $announcement contribution across silent recheck',
      (tester) async {
        network.autoRegister = true;
        final storage = _Store();
        final host = session(actor: 'host', store: storage, newlyCreated: true);
        await host.start();
        await settle(tester);
        final old = _FakeConnection('old-runtime');
        network.connections.add(old);
        network.peers.first.emit<DataConnection>('connection', old);
        old.openChannel();
        old.receive({
          ..._message('hello', const [], actor: 'old'),
          'durableSync': true,
          'recheckSync': true,
          'fastSync': true,
          'historyDigest': roomHistoryDigest(const []),
        });
        await settle(tester);
        old.receive(_checkpoint(const [], actor: 'old'));
        old.receive(_ackLocal(old, actor: 'old'));
        await tester.pump(const Duration(seconds: 1));
        await settle(tester);
        expect(host.onlineCount, 2);
        final missing = _edit(
          'announced-but-not-imported',
          'required old contribution',
          author: 'old',
        );
        final expected = roomHistoryInventory(decodeRoomHistory([missing]));
        if (announcement == 'checkpoint') {
          old.receive(_checkpoint([missing], actor: 'old', syncId: 'b' * 32));
        } else {
          old.receive({
            ..._message('inventory', const [], actor: 'old'),
            'inventory': expected,
            if (announcement == 'recheck') 'recheckId': 'c' * 32,
          });
        }
        await settle(tester);
        for (var tick = 0; tick < 5; tick++) {
          old.receive(_message('presence', const [], actor: 'old'));
          await tester.pump(const Duration(seconds: 5));
          await settle(tester);
        }
        expect(old.disposed, isFalse);
        final joining = session(
          member: false,
          actor: 'joining',
          preferExistingHost: true,
        );
        await joining.start();
        await settle(tester);
        await tester.pump(const Duration(seconds: 1));
        await settle(tester);
        expect(
          joining.initialSyncComplete,
          isFalse,
          reason:
              'a declared missing immutable record remains part of admission',
        );
        final request = _sentMessages(old).lastWhere(
          (message) =>
              message.type == RoomMessageType.inventory &&
              message.recheckId != null,
        );
        // An empty subsequent cutoff cannot erase the earlier declared record.
        old.receive(_checkpoint(const [], actor: 'old', syncId: 'd' * 32));
        old.receive(_ackLocal(old, actor: 'old'));
        old.receive({
          ..._checkpoint(const [], actor: 'old', syncId: 'e' * 32),
          'recheckId': request.recheckId,
        });
        await tester.pump(const Duration(seconds: 1));
        await settle(tester);
        expect(joining.initialSyncComplete, isFalse);
        final gate = storage.appendGate = Completer<void>();
        old.receive(_message('edits', [missing], actor: 'old'));
        await settle(tester);
        expect(joining.initialSyncComplete, isFalse);
        expect(await storage.loadHistory(_roomId), isEmpty);
        gate.complete();
        await settle(tester);
        await tester.pump(const Duration(seconds: 1));
        await settle(tester);
        old.receive(_ackLocal(old, actor: 'old'));
        await settle(tester);
        expect(joining.initialSyncComplete, isTrue);
        expect(joining.text, 'required old contribution');
        expect(roomHistoryInventory(joining.changes), expected);
        expect(old.disposed, isFalse);
      },
    );
  }

  testRoomWidgets(
    'entry still waits for a silent established peer assembling real history',
    (tester) async {
      network.autoRegister = true;
      final host = session(actor: 'host', newlyCreated: true);
      await host.start();
      await settle(tester);
      final old = _FakeConnection('assembling-runtime');
      network.connections.add(old);
      network.peers.first.emit<DataConnection>('connection', old);
      old.openChannel();
      old.receive({
        ..._message('hello', const [], actor: 'old'),
        'durableSync': true,
        'recheckSync': true,
      });
      await settle(tester);
      old.receive(_checkpoint(const [], actor: 'old'));
      old.receive(_ackLocal(old, actor: 'old'));
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      final incoming = _edit('assembling-edit', 'Ж😀' * 6000, author: 'old');
      final chunks = encodeRoomMessage(
        decodeRoomMessage(
          _message('edits', [incoming], actor: 'old'),
          roomId: _roomId,
        ),
      ).toList();
      old.receive(chunks.first);
      for (var tick = 0; tick < 4; tick++) {
        await tester.pump(const Duration(seconds: 5));
        await settle(tester);
      }
      final joining = session(
        member: false,
        actor: 'joining',
        preferExistingHost: true,
      );
      await joining.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(
        joining.initialSyncComplete,
        isFalse,
        reason:
            'native silence does not discard a real pending history transfer',
      );
      expect(old.disposed, isFalse);
      for (final packet in chunks.skip(1)) {
        old.receive(packet);
      }
      await settle(tester);
      old.receive(_checkpoint([incoming], actor: 'old', syncId: 'b' * 32));
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      old.receive(_ackLocal(old, actor: 'old'));
      await settle(tester);
      expect(joining.initialSyncComplete, isTrue);
      expect(joining.text, incoming['text']);
      expect(
        roomHistoryInventory(joining.changes),
        roomHistoryInventory(host.changes),
      );
      expect(old.disposed, isFalse);
    },
  );

  testRoomWidgets(
    'failed initial round blocks absence only, not a clean live cohort',
    (tester) async {
      network.autoRegister = true;
      final host = session(actor: 'host');
      await host.start();
      await settle(tester);
      final abandoned = _FakeConnection('abandoned');
      network.connections.add(abandoned);
      network.peers.first.emit<DataConnection>('connection', abandoned);
      abandoned.openChannel();
      abandoned.receive({..._message('hello', const []), 'durableSync': true});
      await settle(tester);
      abandoned.receive(_checkpoint([_edit('never-received', 'missing')]));
      await settle(tester);
      abandoned.emit<void>('close', null);
      await settle(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(host.initialSyncComplete, isFalse);
      expect(host.initialSyncError, isNull);
      final fresh = session(member: false, actor: 'new-cohort');
      await fresh.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(fresh.initialSyncComplete, isTrue);
      expect(host.initialSyncComplete, isTrue);
    },
  );

  testRoomWidgets(
    'new unshared room is known solo after load, never a fresh join',
    (tester) async {
      final created = session(newlyCreated: true);
      expect(created.initialSyncComplete, isFalse);
      await created.start();
      expect(created.initialSyncComplete, isTrue);
      final fresh = session(member: false, newlyCreated: true);
      await fresh.start();
      expect(fresh.initialSyncComplete, isFalse);
      fresh.openLocalCopy();
      expect(fresh.localCopyOpened, isFalse);
      final corrupt = session(
        newlyCreated: true,
        store: _Store()..failLoad = true,
      );
      await corrupt.start();
      expect(corrupt.initialSyncComplete, isFalse);
      corrupt.openLocalCopy();
      expect(corrupt.localCopyOpened, isFalse);
    },
  );

  testRoomWidgets('stale generation and disposed ACK cannot complete entry', (
    tester,
  ) async {
    final common = _edit('common', 'common');
    final room = session();
    final channel = await standaloneFollower(tester, room);
    channel.openChannel();
    await settle(tester);
    channel.receive({
      ..._message('welcome', [common]),
      'durableSync': true,
    });
    await settle(tester);
    final staleAck = _ackLocal(channel);
    channel.receive(_checkpoint([common]));
    channel.receive({...staleAck, 'syncId': 'b' * 32});
    await settle(tester);
    expect(
      room.initialSyncComplete,
      isFalse,
      reason: 'ACK from a different snapshot does not count',
    );
    await room.retry();
    channel.receive(_checkpoint([common]));
    channel.receive(staleAck);
    await settle(tester);
    expect(room.initialSyncComplete, isFalse);
    room.dispose();
    channel.receive(staleAck);
    await tester.pump(const Duration(seconds: 40));
    expect(room.initialSyncComplete, isFalse);
  });

  testRoomWidgets('unnegotiated control messages cannot imply readiness', (
    tester,
  ) async {
    final room = session();
    final channel = await standaloneFollower(tester, room);
    channel.openChannel();
    await settle(tester);
    channel.receive(_message('welcome', const []));
    await settle(tester);
    channel.receive(_checkpoint(const []));
    await settle(tester);
    expect(channel.disposed, isTrue);
    expect(room.joined, isTrue);
    expect(room.initialSyncComplete, isFalse);
    expect(room.log.last, contains('не согласовано'));
  });

  testRoomWidgets(
    'pending initial local save blocks solo but later retry is explicit',
    (tester) async {
      final store = _Store();
      final room = session(store: store);
      await room.start();
      store.appendGate = Completer<void>();
      final pending = room.edit('before validated registration');
      network.peers.last.register();
      await tester.pump(const Duration(seconds: 2));
      expect(room.initialSyncComplete, isFalse);
      store.appendGate!.complete();
      await pending;
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(room.initialSyncComplete, isTrue);
      await room.retry();
      expect(
        room.initialSyncComplete,
        isFalse,
        reason: 'explicit retry is allowed to request a fresh entry check',
      );
      network.peers.last.register();
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(room.initialSyncComplete, isTrue);
    },
  );

  testRoomWidgets(
    'legacy welcome imports durably but explicitly cannot prove readiness',
    (tester) async {
      final store = _Store();
      final room = session(member: false, store: store);
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      await settle(tester);
      channel.receive(_message('welcome', [_edit('legacy', 'legacy history')]));
      await settle(tester);
      expect(room.joined, isTrue);
      expect(room.initialSyncComplete, isFalse);
      expect(room.initialSyncError, contains('старый клиент'));
      expect(await store.loadHistory(_roomId), hasLength(1));
      expect(
        _sentMessages(channel).where(
          (m) =>
              m.type == RoomMessageType.checkpoint ||
              m.type == RoomMessageType.syncAck,
        ),
        isEmpty,
      );
      room.openLocalCopy();
      expect(room.localCopyOpened, isTrue);
    },
  );

  testRoomWidgets(
    'saved membership opens offline, loads history and appends eagerly',
    (tester) async {
      final store = _Store();
      await store.appendHistory(_roomId, [_edit('old', 'saved')]);
      store.appendCalls = 0;
      final room = session(store: store);
      expect(room.joined, isTrue);
      await room.start();
      expect(room.text, 'saved');
      expect(room.historyLength, 1);
      expect(room.onlineCount, 1);
      expect(network.peers.single.id, _alias);
      expect(network.peers.single.outbound, isEmpty);

      store.appendGate = Completer<void>();
      final pending = room.edit('new offline');
      expect(
        store.authoredBatches.length,
        1,
        reason: 'Atomic authored append must begin before first await',
      );
      expect(room.text, 'new offline');
      expect(room.historyLength, 2);
      expect(room.savingCount, 1);
      room.dispose(); // Immediate page/tab disposal does not cancel the append.
      store.appendGate!.complete();
      await pending;
      final restored = session(store: store);
      await restored.start();
      expect(restored.text, 'new offline');
      expect(restored.historyLength, 2);
    },
  );

  testRoomWidgets(
    'saved fast-rejoin hint connects directly to an existing host',
    (tester) async {
      network.autoRegister = true;
      final host = session(actor: 'host');
      await host.start();
      await settle(tester);
      final returning = session(preferExistingHost: true, actor: 'returning');
      await returning.start();
      await settle(tester);
      expect(network.peers, hasLength(2));
      expect(network.peers.first.id, _alias);
      expect(network.peers.last.id, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(network.peers.last.outbound.single.peer, _alias);
      expect(returning.joined, isTrue);
      expect(returning.editable, isTrue);
      expect([host.onlineCount, returning.onlineCount], everyElement(2));
    },
  );

  testRoomWidgets(
    'saved fast-rejoin without an online host falls back to alias and stays editable',
    (tester) async {
      final store = _Store();
      final room = session(preferExistingHost: true, store: store);
      await room.start();
      final follower = network.peers.single;
      expect(follower.id, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(room.editable, isTrue);
      await room.edit('saved while the old host is absent');
      follower.register();
      await settle(tester);
      expect(follower.outbound, hasLength(1));
      await tester.pump(const Duration(seconds: 12));
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      expect(follower.destroyed, isTrue);
      expect(network.peers, hasLength(2));
      final elected = network.peers.last;
      expect(elected.id, _alias);
      elected.register();
      await settle(tester);
      expect(room.status, 'Комната готова');
      expect(room.editable, isTrue);
      expect(room.text, 'saved while the old host is absent');
      expect(room.onlineCount, 1);
      expect(store.membershipCalls, 0);
    },
  );

  testRoomWidgets('manual retry consumes a saved fast-rejoin hint only once', (
    tester,
  ) async {
    final room = session(preferExistingHost: true);
    await room.start();
    expect(network.peers.single.id, matches(RegExp(r'^[0-9a-f]{32}$')));
    await room.retry();
    await settle(tester);
    expect(network.peers, hasLength(2));
    expect(network.peers.first.destroyed, isTrue);
    expect(network.peers.last.id, _alias);
    expect(room.joined, isTrue);
    expect(room.editable, isTrue);
  });

  testRoomWidgets(
    'a fast-rejoin hint never permits fresh members to claim alias',
    (tester) async {
      final store = _Store();
      final room = session(
        member: false,
        preferExistingHost: true,
        store: store,
      );
      await room.start();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(seconds: 1));
        await settle(tester);
      }
      expect(network.peers.length, greaterThan(1));
      expect(
        network.peers.map((peer) => peer.id),
        everyElement(matches(RegExp(r'^[0-9a-f]{32}$'))),
      );
      expect(room.joined, isFalse);
      expect(room.editable, isFalse);
      expect(store.membershipCalls, 0);
      expect(await store.hasMembership(_roomId), isFalse);
    },
  );

  testRoomWidgets(
    'rapid typing notifies only the newest optimistic local text',
    (tester) async {
      final store = _Store()..appendGate = Completer<void>();
      final room = session(store: store);
      await room.start();
      final observed = <String>[];
      room.addListener(() => observed.add(room.text));
      final first = room.edit('a');
      final second = room.edit('ab');
      final third = room.edit('abc');
      expect(store.authoredBatches, hasLength(3));
      expect(room.text, 'abc');
      expect(room.savingCount, 3);
      observed.clear();
      store.appendGate!.complete();
      await Future.wait([first, second, third]);
      expect(observed, everyElement('abc'));
      expect(room.saving, isFalse);
      expect((await store.loadHistory(_roomId)).length, 3);
    },
  );

  testRoomWidgets(
    'fresh join waits for signaling and an open valid welcome, then saves',
    (tester) async {
      final store = _Store();
      final room = session(member: false, store: store);
      await room.start();
      final peer = network.peers.single;
      expect(peer.id, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(peer.options.autoReconnect, isFalse);
      expect(peer.outbound, isEmpty);
      expect(room.joined, isFalse);
      peer.register();
      await settle(tester);
      final channel = peer.outbound.single;
      expect(channel.peer, _alias);
      channel.receive(_message('welcome', [_edit('r1', 'before-open')]));
      await settle(tester);
      expect(room.joined, isFalse);
      expect(store.membershipCalls, 0);
      expect(channel.sent, isEmpty);
      channel.openChannel();
      await settle(tester);
      expect(channel.sent.single['type'], 'hello');
      expect(room.joined, isFalse);

      store.appendGate = Completer<void>();
      channel.receive(_message('welcome', [_edit('r1', 'accepted')]));
      await settle(tester);
      expect(room.joined, isFalse);
      expect(store.appendCalls, 1);
      expect(store.membershipCalls, 0);
      store.appendGate!.complete();
      await settle(tester);
      expect(room.joined, isTrue);
      expect(room.text, 'accepted');
      expect(room.onlineCount, 2);
      expect(await store.hasMembership(_roomId), isTrue);
      expect(store.membershipCalls, 1);
    },
  );

  testRoomWidgets(
    'fresh fallback join survives 7.2-second secondary registration and completes durable sync',
    (tester) async {
      final history = [
        for (final edit in _authorChain('host', [
          'older value',
          'latest value',
        ]))
          edit.toJson(),
      ];
      final hostStore = _Store();
      await hostStore.appendHistory(_roomId, history);
      network.autoRegister = true;
      final host = session(actor: 'host', store: hostStore);
      await host.start();
      await settle(tester);
      network.autoRegister = false;

      final appendGate = Completer<void>();
      final membershipGate = Completer<void>();
      final store = _Store()
        ..appendGate = appendGate
        ..membershipGate = membershipGate;
      final primaries = <_StartupPeer>[];
      final registrationTimers = <Timer>[];
      addTearDown(() async {
        for (final peer in primaries) {
          await peer.closeEvents();
        }
      });
      var attempts = 0;
      final room = session(
        member: false,
        actor: 'fresh',
        store: store,
        factory: (id, configuration) {
          attempts++;
          return FallbackSignalingPeer(
            id: id,
            configuration: configuration,
            providers: [
              (id, _) {
                final peer = _StartupPeer(
                  id,
                  failure: const SignalingFailure(
                    SignalingFailureKind.unavailable,
                    'Primary signaling is blocked',
                  ),
                );
                primaries.add(peer);
                return peer;
              },
              (id, configuration) {
                final peer = network.create(id, configuration);
                final transport = network.peers.last;
                // Model a valid MQTT registration: connect 4.9 s + concurrent
                // SUBACKs 1.7 s + probe 0.5 s + ephemeral claim 0.1 s = 7.2 s.
                // MQTT stage behavior itself is covered in its protocol suite.
                registrationTimers.add(
                  Timer(const Duration(milliseconds: 7200), transport.register),
                );
                return peer;
              },
            ],
          );
        },
      );
      try {
        await room.start();
        await settle(tester);
        final secondary = network.peers.last;
        expect(secondary.id, matches(RegExp(r'^[0-9a-f]{32}$')));
        // Pump in small steps: registration must be observed before the
        // unchanged 8-second RoomSession registration deadline, not after it.
        for (var i = 0; i < 71; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await settle(tester);
        }
        expect(
          secondary.destroyed,
          isFalse,
          reason: 'the secondary must not be disposed at the old 7-second cap',
        );
        expect(secondary.open, isFalse);
        expect(secondary.outbound, isEmpty);
        expect(attempts, 1);
        expect(room.joined, isFalse);
        expect(room.initialSyncComplete, isFalse);
        expect(store.membershipCalls, 0);
        expect(await store.hasMembership(_roomId), isFalse);

        await tester.pump(const Duration(milliseconds: 100));
        await settle(tester);
        expect(secondary.destroyed, isFalse);
        expect(secondary.open, isTrue);
        final channel = secondary.outbound.single;
        expect(channel.peer, _alias);
        expect(channel.open, isTrue);
        expect(
          _sentMessages(channel.other!)
              .singleWhere((message) => message.type == RoomMessageType.welcome)
              .durableSync,
          isTrue,
        );
        expect(store.appendCalls, greaterThan(0));
        expect(
          room.joined,
          isFalse,
          reason: 'welcome history is not saved yet',
        );
        expect(store.membershipCalls, 0);

        appendGate.complete();
        await settle(tester);
        expect(store.membershipCalls, 1);
        expect(room.joined, isFalse, reason: 'membership must also be durable');
        expect(room.initialSyncComplete, isFalse);
        membershipGate.complete();
        await settle(tester);
        expect(room.joined, isTrue);
        expect(await store.hasMembership(_roomId), isTrue);
        expect(
          room.initialSyncComplete,
          isFalse,
          reason: 'admission still needs the real host ready checkpoint ACK',
        );

        // The host uses its existing one-second cohort quiet interval.
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await settle(tester);
        }
        final digest = roomHistoryDigest(decodeRoomHistory(history));
        expect(await store.loadHistory(_roomId), unorderedEquals(history));
        expect([
          host.initialSyncComplete,
          room.initialSyncComplete,
        ], everyElement(true));
        expect([host.onlineCount, room.onlineCount], everyElement(2));
        expect(room.text, 'latest value');
        expect(room.initialSyncError, isNull);
        expect(room.error, isNull);
        expect(room.localCopyOpened, isFalse);
        expect(
          attempts,
          1,
          reason: '7.2-second readiness precedes session timeout',
        );
        expect(secondary.destroyed, isFalse);
        expect(channel.disposed, isFalse);
        final sent = _sentMessages(channel);
        final received = _sentMessages(channel.other!);
        for (final messages in [sent, received]) {
          expect(
            messages
                .lastWhere((m) => m.type == RoomMessageType.checkpoint)
                .syncDigest,
            digest,
          );
        }
        for (final (outbound, inbound) in [
          (sent, received),
          (received, sent),
        ]) {
          final checkpoint = outbound.lastWhere(
            (m) => m.type == RoomMessageType.checkpoint,
          );
          expect(
            inbound.any(
              (m) =>
                  m.type == RoomMessageType.syncAck &&
                  m.syncId == checkpoint.syncId &&
                  m.syncDigest == digest &&
                  m.roomReady == true,
            ),
            isTrue,
            reason:
                'both real sessions must acknowledge the full saved history',
          );
        }
        expect(tester.takeException(), isNull);
      } finally {
        for (final timer in registrationTimers) {
          timer.cancel();
        }
        if (!appendGate.isCompleted) appendGate.complete();
        if (!membershipGate.isCompleted) membershipGate.complete();
      }
    },
  );

  testRoomWidgets(
    'saved rejoin sends a payload-free capability offer before history inventory',
    (tester) async {
      final store = _Store();
      final saved = List.generate(
        200,
        (index) => _edit('saved-$index', 'old state $index', clock: index),
      );
      await store.appendHistory(_roomId, saved);
      final room = session(store: store);
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      await settle(tester);
      final hello = channel.sent.single as Map;
      expect(hello['type'], 'hello');
      expect(hello['fastSync'], isTrue);
      expect(hello['historyDigest'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(hello['authorHistory'], isTrue);
      expect(hello['history'], isEmpty);
      expect(utf8.encode(jsonEncode(hello)).length, lessThan(1000));
      expect(store.appendCalls, 1);
    },
  );

  for (final name in ['', 'Private alias']) {
    testRoomWidgets(
      'non-tree entry with ${name.isEmpty ? 'empty' : 'explicit'} alias rejects an older identity welcome before profile or membership',
      (tester) async {
        final store = _Store();
        final room = session(
          member: false,
          store: store,
          participantName: name,
        );
        final channel = await standaloneFollower(tester, room);
        channel.openChannel();
        await settle(tester);
        final hello = _sentMessages(channel).single;
        expect(hello.participantIdentity, isTrue);
        expect(hello.history, isEmpty);
        channel.receive({
          ..._message('welcome', const []),
          'roomMetadata': true,
          'roomRoles': true,
          'familyTree': true,
          'familySurnames': true,
          'personalSurnames': true,
          'marriageHistory': true,
          'patronymics': true,
          'explicitSiblings': true,
          'authorHistory': true,
          'durableSync': true,
        });
        await settle(tester);
        expect(channel.disposed, isTrue);
        expect(room.joined, isFalse);
        expect(room.initialSyncError, contains('привязки'));
        expect(room.participantName, isNull);
        expect(room.participants, isEmpty);
        expect(store.appendCalls, 0);
        expect(store.membershipCalls, 0);
        expect(await store.loadHistory(_roomId), isEmpty);
      },
    );
  }

  for (final incoming in [false, true]) {
    testRoomWidgets(
      'production patronymic gate rejects old ${incoming ? 'hello' : 'welcome'} with empty local history before admission',
      (tester) async {
        final store = _Store();
        final room = session(
          member: incoming,
          store: store,
          requireFamilyTree: true,
        );
        final _FakeConnection channel;
        if (incoming) {
          await room.start();
          final peer = network.peers.single;
          peer.register();
          await settle(tester);
          channel = _FakeConnection('old-runtime');
          network.connections.add(channel);
          peer.attached.add(channel);
          peer.emit<DataConnection>('connection', channel);
        } else {
          channel = await standaloneFollower(tester, room);
        }
        channel.openChannel();
        await settle(tester);
        expect(room.changes, isEmpty);
        if (!incoming) {
          final hello = _sentMessages(channel).single;
          expect(hello.patronymics, isTrue);
          expect(hello.history, isEmpty);
        }
        final packetsBefore = channel.sent.length;
        channel.receive({
          ..._message(incoming ? 'hello' : 'welcome', [
            _edit('must-not-save', 'Private old history'),
          ]),
          'roomMetadata': true,
          'roomRoles': true,
          'familyTree': true,
          'familySurnames': true,
          'personalSurnames': true,
          'marriageHistory': true,
          'explicitSiblings': true,
          'authorHistory': true,
          'participantIdentity': true,
          'durableSync': true,
        });
        await settle(tester);
        expect(channel.disposed, isTrue);
        expect(channel.sent, hasLength(packetsBefore));
        expect(room.joined, incoming);
        expect(room.changes, isEmpty);
        expect(room.initialSyncError, contains('отчества'));
        expect(room.initialSyncError, contains('Обновите страницу на обоих'));
        expect(store.appendCalls, 0);
        expect(store.membershipCalls, 0);
        expect(await store.loadHistory(_roomId), isEmpty);
        if (incoming) {
          await tester.pump(const Duration(seconds: 31));
          await settle(tester);
          expect(room.initialSyncComplete, isFalse);
          expect(room.initialSyncError, contains('отчества'));
        }
      },
    );
  }

  for (final incoming in [false, true]) {
    testRoomWidgets(
      'production marriageHistory gate rejects old ${incoming ? 'hello' : 'welcome'} with empty local history before admission',
      (tester) async {
        final store = _Store();
        final room = session(
          member: incoming,
          store: store,
          requireFamilyTree: true,
        );
        final _FakeConnection channel;
        if (incoming) {
          await room.start();
          final peer = network.peers.single;
          peer.register();
          await settle(tester);
          channel = _FakeConnection('old-marriages');
          network.connections.add(channel);
          peer.attached.add(channel);
          peer.emit<DataConnection>('connection', channel);
        } else {
          channel = await standaloneFollower(tester, room);
        }
        channel.openChannel();
        await settle(tester);
        expect(room.changes, isEmpty);
        if (!incoming) {
          final hello = _sentMessages(channel).single;
          expect(hello.marriageHistory, isTrue);
          expect(hello.history, isEmpty);
        }
        final packetsBefore = channel.sent.length;
        channel.receive({
          ..._message(incoming ? 'hello' : 'welcome', [
            _edit('must-not-save', 'Private old history'),
          ]),
          'roomMetadata': true,
          'roomRoles': true,
          'familyTree': true,
          'familySurnames': true,
          'personalSurnames': true,
          'explicitSiblings': true,
          'patronymics': true,
          'lifeStatus': true,
          'authorHistory': true,
          'participantIdentity': true,
          'durableSync': true,
        });
        await settle(tester);
        expect(channel.disposed, isTrue);
        expect(channel.sent, hasLength(packetsBefore));
        expect(room.joined, incoming);
        expect(room.changes, isEmpty);
        expect(room.initialSyncError, contains('историю браков и фамилий'));
        expect(room.initialSyncError, contains('Обновите страницу на обоих'));
        expect(store.appendCalls, 0);
        expect(store.membershipCalls, 0);
        expect(await store.loadHistory(_roomId), isEmpty);
        if (incoming) {
          await tester.pump(const Duration(seconds: 31));
          await settle(tester);
          expect(room.initialSyncComplete, isFalse);
          expect(room.initialSyncError, contains('историю браков и фамилий'));
        }
      },
    );
  }

  testRoomWidgets(
    'required author history rejects an old welcome even with empty local history',
    (tester) async {
      final store = _Store();
      final room = session(
        member: false,
        store: store,
        requireFamilyTree: true,
      );
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      await settle(tester);
      final hello = _sentMessages(channel).single;
      expect(hello.authorHistory, isTrue);
      expect(hello.history, isEmpty);
      channel.receive({
        ..._message('welcome', [_edit('must-not-save', 'private')]),
        'roomMetadata': true,
        'roomRoles': true,
        'familyTree': true,
        'familySurnames': true,
        'personalSurnames': true,
        'marriageHistory': true,
        'patronymics': true,
        'explicitSiblings': true,
        'participantIdentity': true,
        'durableSync': true,
      });
      await settle(tester);
      expect(channel.disposed, isTrue);
      expect(room.joined, isFalse);
      expect(room.initialSyncError, contains('историю автора'));
      expect(store.appendCalls, 0);
      expect(store.membershipCalls, 0);
      expect(await store.loadHistory(_roomId), isEmpty);
    },
  );

  testRoomWidgets(
    'required author history rejects an old hello even in an empty room',
    (tester) async {
      final store = _Store();
      final host = session(store: store, requireFamilyTree: true);
      await host.start();
      final peer = network.peers.single;
      peer.register();
      await settle(tester);
      final channel = _FakeConnection('old-runtime');
      network.connections.add(channel);
      peer.attached.add(channel);
      peer.emit<DataConnection>('connection', channel);
      channel.openChannel();
      channel.receive({
        ..._message('hello', [_edit('must-not-save', 'old client')]),
        'roomMetadata': true,
        'roomRoles': true,
        'familyTree': true,
        'familySurnames': true,
        'personalSurnames': true,
        'marriageHistory': true,
        'patronymics': true,
        'explicitSiblings': true,
        'participantIdentity': true,
        'durableSync': true,
      });
      await settle(tester);
      expect(channel.disposed, isTrue);
      expect(channel.sent, isEmpty);
      expect(host.onlineCount, 1);
      expect(host.initialSyncError, contains('историю автора'));
      final capabilityError = host.initialSyncError;
      expect(store.appendCalls, 0);
      expect(await store.loadHistory(_roomId), isEmpty);
      await tester.pump(const Duration(seconds: 31));
      await settle(tester);
      expect(
        host.initialSyncComplete,
        isFalse,
        reason: 'rejected hello is not solo',
      );
      expect(host.initialSyncError, capabilityError);
      expect(host.initialSyncError, contains('Обновите страницу на обоих'));
      expect(
        network.peers,
        hasLength(1),
        reason: 'incompatibility is not an outage',
      );
    },
  );

  testRoomWidgets(
    'malformed initial protocol stays an explicit error across automatic election',
    (tester) async {
      final store = _Store();
      final room = session(store: store, preferExistingHost: true);
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      channel.receive({'invalid': true});
      await settle(tester);
      final protocolError = room.initialSyncError;
      expect(protocolError, contains('Некорректное сообщение комнаты'));
      expect(channel.disposed, isTrue);
      await tester.pump(const Duration(milliseconds: 1100));
      await settle(tester);
      network.peers.last.register();
      await tester.pump(const Duration(seconds: 31));
      await settle(tester);
      expect(room.initialSyncComplete, isFalse);
      expect(room.initialSyncError, protocolError);
      expect(room.localCopyOpened, isFalse);
      expect(store.appendCalls, 0);
      expect(store.membershipCalls, 0);
    },
  );

  testRoomWidgets(
    'stored author proofs reject old hello before admission or any preview',
    (tester) async {
      final store = _Store();
      final edits = _authorChain('local', ['private first', 'private tail']);
      await store.appendHistory(_roomId, [
        for (final edit in edits) edit.toJson(),
      ]);
      final host = session(store: store);
      await host.start();
      final peer = network.peers.single;
      peer.register();
      await settle(tester);
      final channel = _FakeConnection('old-runtime');
      network.connections.add(channel);
      peer.attached.add(channel);
      peer.emit<DataConnection>('connection', channel);
      channel.openChannel();
      channel.receive({
        ..._message('hello', [_edit('must-not-save', 'old client')]),
        'fastSync': true,
        'historyDigest': roomHistoryDigest([]),
      });
      await settle(tester);
      expect(channel.disposed, isTrue);
      expect(channel.sent, isEmpty);
      expect(host.onlineCount, 1);
      expect(store.appendCalls, 1);
      expect((await store.loadHistory(_roomId)).length, 2);
    },
  );

  for (final incoming in [false, true]) {
    testRoomWidgets(
      'unnegotiated ${incoming ? 'incoming' : 'outgoing'} author proof closes a legacy seam without payload loss',
      (tester) async {
        final store = _Store();
        final host = session(store: store);
        await host.start();
        final peer = network.peers.single;
        peer.register();
        await settle(tester);
        final channel = _FakeConnection('old-runtime');
        network.connections.add(channel);
        peer.attached.add(channel);
        peer.emit<DataConnection>('connection', channel);
        channel.openChannel();
        channel.receive(_message('hello', const []));
        await settle(tester);
        expect(channel.disposed, isFalse);
        expect(host.onlineCount, 2);
        if (incoming) {
          channel.receive(
            _message('edits', [
              _authorChain('remote', ['new']).single.toJson(),
            ]),
          );
        } else {
          await host.edit('new');
        }
        await settle(tester);
        expect(channel.disposed, isTrue);
        expect(
          _sentMessages(channel).expand((message) => message.history),
          isEmpty,
        );
        expect((await store.loadHistory(_roomId)).length, incoming ? 0 : 1);
        if (!incoming) {
          expect(host.changes.single.authorSequence, 1);
          expect(host.text, 'new');
        }
      },
    );
  }

  testRoomWidgets(
    'a missing author predecessor is rejected before persistence or checkpoint ACK',
    (tester) async {
      final store = _Store();
      final room = session(store: store);
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      await settle(tester);
      final edits = _authorChain('remote', ['first', 'tail']);
      final rows = [for (final edit in edits) edit.toJson()];
      channel.receive({
        ..._message('welcome', const []),
        'authorHistory': true,
        'durableSync': true,
        'fastSync': true,
        'historyDigest': roomHistoryDigest(edits),
      });
      await settle(tester);
      expect(room.historyLength, 0);
      expect(room.text, isEmpty);
      channel.receive(_checkpoint(rows));
      await settle(tester);
      expect(
        _sentMessages(
          channel,
        ).where((message) => message.type == RoomMessageType.syncAck),
        isEmpty,
      );
      channel.receive(_message('edits', [edits.last.toJson()]));
      await settle(tester);
      expect(channel.disposed, isTrue);
      expect(store.appendCalls, 0);
      expect(await store.loadHistory(_roomId), isEmpty);
      expect(room.historyLength, 0);
      expect(
        _sentMessages(
          channel,
        ).where((message) => message.type == RoomMessageType.syncAck),
        isEmpty,
      );
    },
  );

  testRoomWidgets(
    'solo entry waits for canonical draft proof without freezing a legacy fingerprint',
    (tester) async {
      final store = _Store();
      final room = session(store: store);
      await room.start();
      store.appendGate = Completer<void>();
      final saving = room.edit('started before registration');
      await settle(tester);
      network.peers.single.register();
      await settle(tester);
      expect(room.initialSyncComplete, isFalse);
      store.appendGate!.complete();
      await saving;
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(room.changes.single.authorSequence, 1);
      expect(room.initialSyncComplete, isTrue);
      expect(room.initialSyncError, isNull);
    },
  );

  testRoomWidgets(
    'entry checkpoint freezes IDs then resolves saved proof without absorbing later typing',
    (tester) async {
      final store = _Store();
      final room = session(store: store);
      final channel = await standaloneFollower(tester, room);
      store.appendGate = Completer<void>();
      final firstSave = room.edit('frozen contribution');
      await settle(tester);
      channel.openChannel();
      await settle(tester);
      channel.receive({
        ..._message('welcome', const []),
        'authorHistory': true,
        'durableSync': true,
        'fastSync': true,
        'historyDigest': roomHistoryDigest([]),
      });
      await settle(tester);
      expect(room.onlineCount, 2);
      expect(
        _sentMessages(
          channel,
        ).where((message) => message.type == RoomMessageType.checkpoint),
        isEmpty,
      );
      final laterSave = room.edit('later typing');
      await settle(tester);
      store.appendGate!.complete();
      await Future.wait([firstSave, laterSave]);
      await settle(tester);
      final saved = decodeRoomHistory(await store.loadHistory(_roomId));
      final first = saved.singleWhere(
        (edit) => edit.text == 'frozen contribution',
      );
      final later = saved.singleWhere((edit) => edit.text == 'later typing');
      expect(first.authorSequence, 1);
      expect(later.authorSequence, 2);
      final messages = _sentMessages(channel);
      final inventory = messages.singleWhere(
        (message) => message.type == RoomMessageType.inventory,
      );
      expect(inventory.inventory, roomHistoryInventory([first]));
      expect(inventory.inventory!.containsKey(later.id), isFalse);
      final checkpoint = messages.firstWhere(
        (message) => message.type == RoomMessageType.checkpoint,
      );
      expect(checkpoint.syncDigest, roomHistoryDigest([first]));
      for (final batch in messages.where(
        (message) => message.type == RoomMessageType.edits,
      )) {
        expect(validateAuthorHistory(batch.history), isNotEmpty);
      }
    },
  );

  testRoomWidgets(
    'entry cutoff includes a same-actor predecessor discovered during proof allocation',
    (tester) async {
      final store = _Store();
      final room = session(store: store);
      final channel = await standaloneFollower(tester, room);
      store.authoredGate = Completer<void>();
      final saving = room.edit('frozen draft');
      channel.openChannel();
      await settle(tester);
      channel.receive({
        ..._message('welcome', const []),
        'authorHistory': true,
        'durableSync': true,
        'fastSync': true,
        'historyDigest': roomHistoryDigest([]),
      });
      await settle(tester);
      expect(room.historyLength, 1);
      expect(
        _sentMessages(
          channel,
        ).where((message) => message.type == RoomMessageType.checkpoint),
        isEmpty,
      );
      final predecessor = _authorChain('local', ['another tab']).single;
      await store.externalAppend([predecessor.toJson()]);
      expect(
        room.historyLength,
        1,
        reason: 'the store watch has not refreshed',
      );
      store.authoredGate!.complete();
      await saving;
      await settle(tester);
      final saved = validateAuthorHistory(
        decodeRoomHistory(await store.loadHistory(_roomId)),
      );
      expect(saved, hasLength(2));
      expect(saved.last.text, 'frozen draft');
      expect(saved.last.authorSequence, 2);
      expect(saved.last.authorPrevious, predecessor.id);
      final messages = _sentMessages(channel);
      final inventory = messages.singleWhere(
        (message) => message.type == RoomMessageType.inventory,
      );
      expect(inventory.inventory, roomHistoryInventory(saved));
      final checkpoint = messages.singleWhere(
        (message) => message.type == RoomMessageType.checkpoint,
      );
      expect(checkpoint.syncDigest, roomHistoryDigest(saved));
    },
  );

  testRoomWidgets(
    'inventory diffs resend the full author prefix despite remote predecessor claims',
    (tester) async {
      final store = _Store();
      final edits = _authorChain('author', ['first', 'tail']);
      await store.appendHistory(_roomId, [
        for (final edit in edits) edit.toJson(),
      ]);
      final host = session(store: store);
      await host.start();
      final peer = network.peers.single;
      peer.register();
      await settle(tester);
      final channel = _FakeConnection('returning-runtime');
      network.connections.add(channel);
      peer.attached.add(channel);
      peer.emit<DataConnection>('connection', channel);
      channel.openChannel();
      channel.receive({
        ..._message('hello', const []),
        'authorHistory': true,
        'durableSync': true,
        'fastSync': true,
        'historyDigest': roomHistoryDigest([edits.first]),
      });
      await settle(tester);
      final welcome = _sentMessages(
        channel,
      ).singleWhere((message) => message.type == RoomMessageType.welcome);
      expect(welcome.authorHistory, isTrue);
      expect(welcome.history, isEmpty);
      channel.receive({
        ..._message('inventory', const []),
        'inventory': roomHistoryInventory([edits.first]),
      });
      await settle(tester);
      final sent = _sentMessages(
        channel,
      ).where((message) => message.type == RoomMessageType.edits);
      expect(sent, hasLength(1));
      expect(sent.single.history.map((edit) => edit.id), [
        'author-1',
        'author-2',
      ]);
      expect(validateAuthorHistory(sent.single.history), hasLength(2));
    },
  );

  testRoomWidgets('fresh join never negotiates a partial-history welcome', (
    tester,
  ) async {
    final store = _Store();
    final room = session(member: false, store: store);
    final channel = await standaloneFollower(tester, room);
    channel.openChannel();
    await settle(tester);
    expect(channel.sent.single.containsKey('fastSync'), isFalse);
    channel.receive({
      ..._message('welcome', [_edit('latest', 'partial')]),
      'fastSync': true,
      'historyDigest': 'a' * 64,
    });
    await settle(tester);
    expect(room.joined, isFalse);
    expect(channel.disposed, isTrue);
    expect(store.appendCalls, 0);
    expect(store.membershipCalls, 0);
  });

  testRoomWidgets(
    'legacy fast welcome can display its unproven winner before background history',
    (tester) async {
      final store = _Store();
      final common = _edit('common', 'shared', clock: 1);
      final losingLocal = _edit('local-only', 'offline local', clock: 2);
      final winningRemote = _edit('remote-latest', 'new text', clock: 4);
      final remoteOld = _edit('remote-old', 'older remote', clock: 3);
      await store.appendHistory(_roomId, [common, losingLocal]);
      final room = session(store: store);
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      await settle(tester);
      channel.receive({
        ..._message('welcome', [winningRemote]),
        'fastSync': true,
        'historyDigest': roomHistoryDigest(
          decodeRoomHistory([common, remoteOld, winningRemote]),
        ),
      });
      await settle(tester);
      expect(room.text, 'new text');
      expect(room.onlineCount, 2);
      expect(room.historyLength, 3);
      expect(
        (await store.loadHistory(_roomId)).map((edit) => edit['id']),
        contains('remote-latest'),
      );
      expect(_sentMessages(channel).map((message) => message.type.name), [
        'hello',
        'inventory',
      ]);
      channel.receive({
        ..._message('inventory', const []),
        'inventory': roomHistoryInventory(
          decodeRoomHistory([common, remoteOld, winningRemote]),
        ),
      });
      await settle(tester);
      final sentEdits = _sentMessages(channel)
          .where((message) => message.type == RoomMessageType.edits)
          .expand((message) => message.history);
      expect(sentEdits.map((edit) => edit.id), ['local-only']);
      channel.receive(_message('edits', [remoteOld]));
      await settle(tester);
      expect(room.historyLength, 4);
      expect(room.text, 'new text');
      expect((await store.loadHistory(_roomId)).length, 4);
    },
  );

  testRoomWidgets(
    'equal durable histories skip inventories and redundant full-history uploads',
    (tester) async {
      network.autoRegister = true;
      final history = [
        _edit('first', 'first'),
        _edit('last', 'last', clock: 2),
      ];
      final hostStore = _Store();
      final memberStore = _Store();
      await hostStore.appendHistory(_roomId, history);
      await memberStore.appendHistory(_roomId, history);
      final host = session(actor: 'host', store: hostStore);
      await host.start();
      await settle(tester);
      final returning = session(
        actor: 'returning',
        store: memberStore,
        preferExistingHost: true,
      );
      await returning.start();
      await settle(tester);
      expect([host.onlineCount, returning.onlineCount], everyElement(2));
      expect([host.historyLength, returning.historyLength], everyElement(2));
      final messages = network.connections.expand(_sentMessages).toList();
      expect(
        messages.where((message) => message.type.name == 'inventory'),
        isEmpty,
      );
      expect(
        messages.where((message) => message.type == RoomMessageType.edits),
        isEmpty,
      );
      expect(
        messages
            .where((message) => message.type == RoomMessageType.hello)
            .single
            .history,
        isEmpty,
      );
      expect(
        messages
            .where((message) => message.type == RoomMessageType.welcome)
            .single
            .history,
        isEmpty,
      );
    },
  );

  testRoomWidgets(
    'background inventory converges divergent full histories and sends only missing edits',
    (tester) async {
      network.autoRegister = true;
      final shared = List.generate(
        180,
        (index) => _edit('shared-$index', 'history $index', clock: index),
      );
      final hostStore = _Store();
      final memberStore = _Store();
      await hostStore.appendHistory(_roomId, [
        ...shared,
        _edit('host-old', 'host old', clock: 181),
        _edit('host-latest', 'latest', clock: 184),
      ]);
      await memberStore.appendHistory(_roomId, [
        ...shared,
        _edit('member-old', 'member old', clock: 182),
        _edit('member-latest', 'member latest', clock: 183),
      ]);
      final host = session(actor: 'host', store: hostStore);
      await host.start();
      await settle(tester);
      final returning = session(
        actor: 'returning',
        store: memberStore,
        preferExistingHost: true,
      );
      await returning.start();
      await settle(tester);
      await settle(tester);
      expect([host.text, returning.text], everyElement('latest'));
      expect([host.historyLength, returning.historyLength], everyElement(184));
      final left = await hostStore.loadHistory(_roomId);
      final right = await memberStore.loadHistory(_roomId);
      expect(
        {for (final edit in left) edit['id']: edit},
        {for (final edit in right) edit['id']: edit},
      );
      final messages = network.connections.expand(_sentMessages).toList();
      expect(
        messages.where((message) => message.type.name == 'inventory'),
        hasLength(2),
      );
      final sentEdits = messages
          .where((message) => message.type == RoomMessageType.edits)
          .expand((message) => message.history);
      expect(
        sentEdits.map((edit) => edit.id),
        isNot(contains(startsWith('shared-'))),
      );
      expect(
        sentEdits.map((edit) => edit.id),
        containsAll(['member-old', 'host-old']),
      );
      expect(
        network.connections.any(
          (channel) => channel.sent.any((packet) => packet['type'] == 'chunk'),
        ),
        isTrue,
      );
      expect(returning.initialSyncComplete, isFalse);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect([
        host.initialSyncComplete,
        returning.initialSyncComplete,
      ], everyElement(isTrue));
    },
  );

  testRoomWidgets(
    'background inventory rejects changed contents of a shared immutable ID',
    (tester) async {
      final store = _Store();
      final old = _edit('old-shared', 'original', clock: 1);
      final latest = _edit('latest', 'unchanged latest', clock: 2);
      await store.appendHistory(_roomId, [old, latest]);
      final room = session(store: store);
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      await settle(tester);
      channel.receive({
        ..._message('welcome', [latest]),
        'fastSync': true,
        'historyDigest': 'a' * 64,
      });
      await settle(tester);
      final before = await store.loadHistory(_roomId);
      channel.receive({
        ..._message('inventory', const []),
        'inventory': roomHistoryInventory(
          decodeRoomHistory([
            _edit('old-shared', 'tampered', clock: 1),
            latest,
          ]),
        ),
      });
      await settle(tester);
      expect(channel.disposed, isTrue);
      expect(await store.loadHistory(_roomId), before);
      expect(room.text, 'unchanged latest');
      expect(
        _sentMessages(
          channel,
        ).where((message) => message.type == RoomMessageType.edits),
        isEmpty,
      );
    },
  );

  testRoomWidgets(
    'fast sync never sends failed drafts and rejects inventory conflicts with them',
    (tester) async {
      final store = _Store();
      final durable = _edit('durable', 'saved', clock: 1);
      await store.appendHistory(_roomId, [durable]);
      final room = session(store: store);
      final channel = await standaloneFollower(tester, room);
      store.failAppend = true;
      await room.edit('unsaved draft');
      final unsaved = store.batches.last.single;
      channel.openChannel();
      await settle(tester);
      final hello = _sentMessages(channel).single;
      expect(hello.history, isEmpty);
      expect(
        hello.historyDigest,
        roomHistoryDigest(decodeRoomHistory([durable])),
      );
      channel.receive({
        ..._message('welcome', [durable]),
        'authorHistory': true,
        'fastSync': true,
        'historyDigest': 'a' * 64,
      });
      await settle(tester);
      final inventory = _sentMessages(
        channel,
      ).singleWhere((message) => message.type.name == 'inventory');
      expect(inventory.inventory!.keys, ['durable']);
      expect(room.text, 'unsaved draft');
      channel.receive({
        ..._message('inventory', const []),
        'inventory': roomHistoryInventory(
          decodeRoomHistory([
            durable,
            {...unsaved, 'text': 'changed draft'},
          ]),
        ),
      });
      await settle(tester);
      expect(channel.disposed, isTrue);
      expect(room.storageError, isNotNull);
      expect((await store.loadHistory(_roomId)).length, 1);
      expect(
        _sentMessages(
          channel,
        ).where((message) => message.type == RoomMessageType.edits),
        isEmpty,
      );
    },
  );

  testRoomWidgets(
    'new durable edits between hello and equal-root welcome trigger reciprocal inventory',
    (tester) async {
      final store = _Store();
      final common = _edit('common', 'before', clock: 1);
      await store.appendHistory(_roomId, [common]);
      final room = session(store: store);
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      await settle(tester);
      final initialDigest = _sentMessages(channel).single.historyDigest;
      await room.edit('during handshake');
      await settle(tester);
      expect(_sentMessages(channel), hasLength(1));
      channel.receive({
        ..._message('welcome', [common]),
        'authorHistory': true,
        'fastSync': true,
        'historyDigest': initialDigest,
      });
      await settle(tester);
      expect(
        _sentMessages(
          channel,
        ).where((message) => message.type.name == 'inventory'),
        hasLength(1),
      );
      channel.receive({
        ..._message('inventory', const []),
        'inventory': roomHistoryInventory(decodeRoomHistory([common])),
      });
      await settle(tester);
      final sentEdits = _sentMessages(channel)
          .where((message) => message.type == RoomMessageType.edits)
          .expand((message) => message.history);
      expect(sentEdits.map((edit) => edit.text), ['during handshake']);
    },
  );

  testRoomWidgets(
    'pending append stays out of fast metadata and broadcasts after welcome',
    (tester) async {
      final store = _Store();
      final common = _edit('common', 'before', clock: 1);
      await store.appendHistory(_roomId, [common]);
      final room = session(store: store);
      final channel = await standaloneFollower(tester, room);
      store.appendGate = Completer<void>();
      final saving = room.edit('pending edit');
      channel.openChannel();
      await settle(tester);
      final hello = _sentMessages(channel).single;
      expect(hello.history, isEmpty);
      expect(
        hello.historyDigest,
        roomHistoryDigest(decodeRoomHistory([common])),
      );
      channel.receive({
        ..._message('welcome', [common]),
        'authorHistory': true,
        'fastSync': true,
        'historyDigest': hello.historyDigest,
      });
      await settle(tester);
      expect(
        _sentMessages(
          channel,
        ).where((message) => message.type == RoomMessageType.edits),
        isEmpty,
      );
      store.appendGate!.complete();
      await saving;
      await settle(tester);
      final edits = _sentMessages(channel)
          .where((message) => message.type == RoomMessageType.edits)
          .expand((message) => message.history);
      expect(edits.map((edit) => edit.text), ['pending edit']);
      expect(validateAuthorHistory(edits), hasLength(1));
      expect((await store.loadHistory(_roomId)).length, 2);
    },
  );

  testRoomWidgets(
    'host answers a later inventory even when hello roots were equal',
    (tester) async {
      final store = _Store();
      final common = _edit('common', 'before', clock: 1);
      await store.appendHistory(_roomId, [common]);
      final host = session(actor: 'host', store: store);
      await host.start();
      final peer = network.peers.single;
      peer.register();
      await settle(tester);
      final channel = _FakeConnection('returning-runtime');
      network.connections.add(channel);
      peer.attached.add(channel);
      peer.emit<DataConnection>('connection', channel);
      channel.openChannel();
      channel.receive({
        ..._message('hello', [common]),
        'fastSync': true,
        'historyDigest': roomHistoryDigest(decodeRoomHistory([common])),
      });
      await settle(tester);
      expect(
        _sentMessages(
          channel,
        ).where((message) => message.type.name == 'inventory'),
        isEmpty,
      );
      channel.receive({
        ..._message('inventory', const []),
        'inventory': roomHistoryInventory(
          decodeRoomHistory([
            common,
            _edit('new', 'during handshake', clock: 2),
          ]),
        ),
      });
      await settle(tester);
      final inventories = _sentMessages(
        channel,
      ).where((message) => message.type.name == 'inventory');
      expect(inventories, hasLength(1));
      expect(inventories.single.inventory!.keys, ['common']);
      channel.receive(
        _message('edits', [_edit('new', 'during handshake', clock: 2)]),
      );
      await settle(tester);
      expect(host.historyLength, 2);
      expect(host.text, 'during handshake');
    },
  );

  testRoomWidgets(
    'legacy welcome still uploads every durable local edit after a fast offer',
    (tester) async {
      final store = _Store();
      await store.appendHistory(_roomId, [
        _edit('older', 'older', clock: 1),
        _edit('latest', 'latest', clock: 2),
      ]);
      final room = session(store: store);
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      await settle(tester);
      channel.receive(_message('welcome', const []));
      await settle(tester);
      final edits = _sentMessages(channel)
          .where((message) => message.type == RoomMessageType.edits)
          .expand((message) => message.history);
      expect(edits.map((edit) => edit.id), ['older', 'latest']);
      expect(
        _sentMessages(
          channel,
        ).where((message) => message.type.name == 'inventory'),
        isEmpty,
      );
    },
  );

  testRoomWidgets(
    'first join fails within 30 seconds without membership and can retry',
    (tester) async {
      final store = _Store();
      final room = session(member: false, store: store);
      await room.start();
      for (var i = 0; i < 31; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(room.joined, isFalse);
      expect(room.error, contains('30 секунд'));
      expect(store.membershipCalls, 0);
      expect(await store.hasMembership(_roomId), isFalse);
      expect(network.peers.every((peer) => peer.id != _alias), isTrue);
      final count = network.peers.length;
      await tester.pump(const Duration(minutes: 1));
      expect(network.peers.length, count);
      await room.retry();
      expect(room.error, isNull);
      expect(network.peers.length, count + 1);
      expect(network.peers.last.id, isNot(_alias));
    },
  );

  testRoomWidgets('wrong room and malformed history are rejected atomically', (
    tester,
  ) async {
    for (final welcome in [
      _message('welcome', [_edit('ok', 'wrong room')], roomId: 'f' * 32),
      _message('welcome', [
        _edit('ok', 'unchecked'),
        {'id': 'broken'},
      ]),
      _message('welcome', [_edit('same', 'a'), _edit('same', 'b')]),
      {
        'v': 1,
        'roomId': _roomId,
        'type': 'welcome',
        'actor': 'remote',
        'history': [],
        'online': 2,
      },
    ]) {
      final store = _Store();
      final room = session(member: false, store: store);
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      channel.receive(welcome);
      await settle(tester);
      expect(room.joined, isFalse);
      expect(room.historyLength, 0);
      expect(store.appendCalls, 0);
      expect(store.membershipCalls, 0);
      expect(channel.disposed, isTrue);
      expect(channel.closeCalled, isFalse);
      room.dispose();
      await settle(tester);
    }
  });

  testRoomWidgets(
    'exact package ID collision becomes random follower only once',
    (tester) async {
      final room = session();
      await room.start();
      final aliasPeer = network.peers.single;
      aliasPeer.emit<dynamic>('error', 'ID $_alias is taken');
      expect(
        aliasPeer.destroyed,
        isFalse,
        reason: 'Disposal is deferred outside sync emitter',
      );
      aliasPeer.emit<String?>('disconnected', aliasPeer.id);
      await settle(tester);
      expect(aliasPeer.destroyed, isTrue);
      expect(network.peers, hasLength(2));
      final follower = network.peers.last;
      expect(follower.id, matches(RegExp(r'^[0-9a-f]{32}$')));
      follower.register();
      follower.register();
      follower.emit<void>('reconnected', null);
      await settle(tester);
      expect(follower.outbound, hasLength(1));
      expect(follower.outbound.single.peer, _alias);
      expect(room.joined, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testRoomWidgets(
    'start subscribes before typed alias collision and passes RTC configuration',
    (tester) async {
      final peers = <_StartupPeer>[];
      final configurations = <Map<String, dynamic>>[];
      addTearDown(() async {
        for (final peer in peers) {
          await peer.closeEvents();
        }
      });
      final room = session(
        factory: (id, configuration) {
          configurations.add(configuration);
          final peer = _StartupPeer(
            id,
            failure: id == _alias
                ? const SignalingFailure(
                    SignalingFailureKind.idTaken,
                    'Alias claimed on an independent signaling service',
                  )
                : null,
          );
          peers.add(peer);
          return peer;
        },
      );
      await room.start();
      await settle(tester);
      expect(peers, hasLength(2));
      expect(peers.first.id, _alias);
      expect(peers.first.disposed, isTrue);
      expect(peers.last.id, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(peers.every((peer) => peer.started), isTrue);
      expect(
        configurations,
        everyElement(const IceConfiguration().toRtcConfiguration()),
      );
      expect(room.signalingService, 'test-signaling');
      expect(room.joined, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testRoomWidgets(
    'typed unavailable error never becomes an alias collision by message text',
    (tester) async {
      final peers = <_StartupPeer>[];
      addTearDown(() async {
        for (final peer in peers) {
          await peer.closeEvents();
        }
      });
      final room = session(
        factory: (id, configuration) {
          final peer = _StartupPeer(
            id,
            failure: const SignalingFailure(
              SignalingFailureKind.unavailable,
              'ID $_alias is taken',
            ),
          );
          peers.add(peer);
          return peer;
        },
      );
      await room.start();
      await settle(tester);
      expect(peers, hasLength(1));
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      expect(peers.length, greaterThanOrEqualTo(2));
      expect(peers.map((peer) => peer.id), everyElement(_alias));
      expect(room.joined, isTrue);
      expect(room.error, isNull);
    },
  );

  testRoomWidgets(
    'host relays three participants, retains channels and unions history',
    (tester) async {
      network.autoRegister = true;
      final hostStore = _Store();
      final host = session(actor: 'host', store: hostStore);
      await host.start();
      await settle(tester);
      final second = session(member: false, actor: 'second');
      await second.start();
      final third = session(member: false, actor: 'third');
      await third.start();
      await settle(tester);
      expect(second.joined, isTrue);
      expect(third.joined, isTrue);
      expect(host.onlineCount, 3);
      expect(second.onlineCount, 3);
      expect(third.onlineCount, 3);
      expect(
        network.connections.every((connection) => !connection.disposed),
        isTrue,
      );

      await second.edit('from second');
      await settle(tester);
      expect(host.text, 'from second');
      expect(third.text, 'from second');
      await third.edit('from third');
      await settle(tester);
      expect([host.text, second.text, third.text], everyElement('from third'));
      expect([
        host.historyLength,
        second.historyLength,
        third.historyLength,
      ], everyElement(2));
      expect(hostStore.appendCalls, 2);
      final hostPeer = network.registered[_alias]!;
      expect(hostPeer.attached, hasLength(2));
      final firstChannel = hostPeer.attached.first;
      firstChannel.receive(
        _message('edits', [
          _edit('foreign', 'additional', clock: 2),
        ], actor: 'second'),
      );
      await settle(tester);
      expect([
        host.historyLength,
        second.historyLength,
        third.historyLength,
      ], everyElement(3));
      expect(
        host.text,
        'from third',
        reason: 'LWW is deterministic, history still retains losing edit',
      );
    },
  );

  testRoomWidgets('saved follower automatically takes alias after host exits', (
    tester,
  ) async {
    network.autoRegister = true;
    final creator = session(actor: 'creator');
    await creator.start();
    await settle(tester);
    final memberStore = _Store();
    final member = session(member: false, actor: 'member', store: memberStore);
    await member.start();
    await settle(tester);
    await member.edit('durable before takeover');
    await settle(tester);
    creator.dispose();
    await settle(tester);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await settle(tester);
    expect(network.registered[_alias], isNotNull);
    expect(member.joined, isTrue);
    expect(member.error, isNull);
    expect(member.text, 'durable before takeover');
    final newcomer = session(member: false, actor: 'newcomer');
    await newcomer.start();
    await settle(tester);
    expect(newcomer.joined, isTrue);
    expect(newcomer.text, 'durable before takeover');
    expect(member.onlineCount, 2);
    expect(memberStore.membershipCalls, 1);
  });

  testRoomWidgets(
    'two saved members collide during takeover and union offline edits',
    (tester) async {
      network.autoRegister = true;
      final creator = session(actor: 'creator');
      await creator.start();
      await settle(tester);
      await creator.edit('before exit');
      final first = session(member: false, actor: 'first');
      await first.start();
      final second = session(member: false, actor: 'second');
      await second.start();
      await settle(tester);
      expect([first.joined, second.joined], everyElement(isTrue));
      network.autoRegister = false;
      creator.dispose();
      await settle(tester);
      await first.edit('offline first');
      await second.edit('offline second');
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      final candidates = network.peers
          .where((peer) => peer.id == _alias && !peer.destroyed)
          .toList();
      expect(candidates, hasLength(2));
      candidates.first.register();
      candidates.last.register();
      await settle(tester);
      final loserFollower = network.peers.last;
      expect(loserFollower.id, isNot(_alias));
      loserFollower.register();
      await settle(tester);
      expect([first.onlineCount, second.onlineCount], everyElement(2));
      expect([first.historyLength, second.historyLength], everyElement(3));
      expect(first.text, second.text);
      expect(first.error, isNull);
      expect(second.error, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testRoomWidgets(
    'host signaling recovers its registration without replacing admitted RTC',
    (tester) async {
      network.autoRegister = true;
      final host = session(actor: 'host');
      await host.start();
      await settle(tester);
      final saved = session(member: false, actor: 'saved');
      await saved.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(
        [host.initialSyncComplete, saved.initialSyncComplete],
        [true, true],
      );
      final oldHostPeer = network.registered[_alias]!;
      final peers = network.peers.toList();
      final channels = network.connections.toList();
      oldHostPeer.loseSignaling();
      await host.edit('during outage');
      await settle(tester);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(seconds: 1));
        await settle(tester);
      }
      expect(network.registered[_alias], same(oldHostPeer));
      expect(oldHostPeer.reconnectCalls, 1);
      expect(network.peers, orderedEquals(peers));
      expect(network.connections, orderedEquals(channels));
      expect(channels.every((channel) => !channel.disposed), isTrue);
      expect([host.joined, saved.joined], everyElement(isTrue));
      expect([host.text, saved.text], everyElement('during outage'));
      expect([host.onlineCount, saved.onlineCount], everyElement(2));
      await saved.edit('after signaling recovery');
      await settle(tester);
      expect(host.text, 'after signaling recovery');
      expect(tester.takeException(), isNull);
    },
  );

  testRoomWidgets(
    'repeated full histories deduplicate writes and immutable IDs cannot change',
    (tester) async {
      final store = _Store();
      final room = session(store: store);
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      channel.receive(_message('welcome', [_edit('one', 'original')]));
      await settle(tester);
      expect(store.appendCalls, 1);
      channel.receive(_message('welcome', [_edit('one', 'original')]));
      channel.receive(
        _message('edits', [
          _edit('one', 'original'),
          _edit('two', 'latest', clock: 2),
        ]),
      );
      channel.receive(_message('edits', [_edit('two', 'latest', clock: 2)]));
      await settle(tester);
      expect(store.appendCalls, 2);
      expect(room.historyLength, 2);
      expect(room.text, 'latest');
      channel.receive(_message('edits', [_edit('one', 'mutated', clock: 100)]));
      await settle(tester);
      expect(channel.disposed, isTrue);
      expect(room.text, 'latest');
      expect(store.appendCalls, 2);
    },
  );

  testRoomWidgets(
    'failed writes preserve local typing and retry without broadcasting unsaved text',
    (tester) async {
      network.autoRegister = true;
      final host = session(actor: 'host');
      await host.start();
      await settle(tester);
      final store = _Store();
      final follower = session(actor: 'saved', store: store);
      await follower.start();
      await settle(tester);
      store.failAppend = true;
      await follower.edit('not saved yet');
      await settle(tester);
      expect(follower.text, 'not saved yet');
      expect(follower.storageError, contains('Disk full'));
      expect(host.text, isEmpty);
      store.failAppend = false;
      await follower.flush();
      await settle(tester);
      expect(follower.storageError, isNull);
      expect(host.text, 'not saved yet');
      expect((await store.loadHistory(_roomId)).length, 1);
    },
  );

  testRoomWidgets('flush throws rather than losing an unsaved draft on exit', (
    tester,
  ) async {
    final store = _Store()..failAppend = true;
    final room = session(store: store);
    await room.start();
    await room.edit('keep this draft');
    await expectLater(room.flush(), throwsStateError);
    expect(room.text, 'keep this draft');
    expect(room.editable, isTrue);
    expect(room.storageError, contains('Disk full'));
    expect(await store.loadHistory(_roomId), isEmpty);
    store.failAppend = false;
    await room.flush();
    expect(room.storageError, isNull);
    expect(
      (await store.loadHistory(_roomId)).single['text'],
      'keep this draft',
    );
    store.failFlush = true;
    await expectLater(room.flush(), throwsStateError);
    expect(room.storageError, contains('Flush failed'));
    expect(room.editable, isTrue);
  });

  testRoomWidgets(
    'corrupt local history never becomes an empty writable room',
    (tester) async {
      final store = _Store()..failLoad = true;
      final room = session(store: store);
      await room.start();
      expect(room.joined, isTrue);
      expect(room.storageError, contains('Disk unreadable'));
      expect(room.editable, isFalse);
      expect(network.peers, isEmpty);
      await room.edit('must not replace unreadable history');
      expect(store.appendCalls, 0);
      store.failLoad = false;
      await store.appendHistory(_roomId, [_edit('saved', 'recovered')]);
      await room.retry();
      expect(room.text, 'recovered');
      expect(network.peers, hasLength(1));
    },
  );

  testRoomWidgets(
    'bounded chunked welcome transfers large Unicode history exactly',
    (tester) async {
      network.autoRegister = true;
      final hostStore = _Store();
      final largeText = List.filled(16000, 'Ж😀').join();
      await hostStore.appendHistory(_roomId, [_edit('large', largeText)]);
      final host = session(actor: 'host', store: hostStore);
      await host.start();
      await settle(tester);
      final fresh = session(member: false, actor: 'fresh');
      await fresh.start();
      await settle(tester);
      expect(fresh.joined, isTrue);
      expect(fresh.text, largeText);
      expect(fresh.historyLength, 1);
      final hostChannel = network.registered[_alias]!.attached.single;
      final chunks = hostChannel.sent
          .where((dynamic data) => data['type'] == 'chunk')
          .toList();
      expect(chunks.length, greaterThan(1));
      for (final chunk in chunks) {
        expect(utf8.encode(jsonEncode(chunk)).length, lessThan(12000));
      }
      expect(tester.takeException(), isNull);
    },
  );

  testRoomWidgets('oversize or malformed chunk cannot persist membership', (
    tester,
  ) async {
    final store = _Store();
    final room = session(member: false, store: store);
    final channel = await standaloneFollower(tester, room);
    channel.openChannel();
    channel.receive({
      'v': 1,
      'roomId': _roomId,
      'type': 'chunk',
      'actor': 'remote',
      'transfer': 'a' * 32,
      'index': 0,
      'count': 999999,
      'bytes': RoomSession.maxTransferBytes + 1,
      'data': 'AAAA',
    });
    await settle(tester);
    expect(channel.disposed, isTrue);
    expect(room.joined, isFalse);
    expect(store.appendCalls, 0);
    expect(store.membershipCalls, 0);
  });

  testRoomWidgets(
    'initial foreground event does not restart a pending registration',
    (tester) async {
      final room = session();
      await room.start();
      final peer = network.peers.single;
      room.setForeground(true);
      await tester.pump(const Duration(milliseconds: 250));
      await settle(tester);
      expect(network.peers, hasLength(1));
      expect(peer.destroyed, isFalse);
      peer.register();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(room.initialSyncComplete, isTrue);
    },
  );

  testRoomWidgets(
    'explicit resume preserves a fresh registration but replaces a suspended one',
    (tester) async {
      var clock = DateTime.utc(2026, 10, 15);
      final room = session(now: () => clock);
      await room.start();
      final peer = network.peers.single;
      room.resume();
      await tester.pump(const Duration(milliseconds: 250));
      await settle(tester);
      expect(network.peers, hasLength(1));
      expect(peer.destroyed, isFalse);
      clock = clock.add(const Duration(minutes: 10));
      room.resume();
      await tester.pump(const Duration(milliseconds: 250));
      await settle(tester);
      expect(network.peers, hasLength(2));
      expect(peer.destroyed, isTrue);
      expect(room.initialSyncComplete, isFalse);
    },
  );

  testRoomWidgets(
    'resume preserves a connecting follower before its handshake deadline',
    (tester) async {
      final room = session(preferExistingHost: true);
      final channel = await standaloneFollower(tester, room);
      expect(channel.open, isFalse);
      room.resume();
      await tester.pump(const Duration(milliseconds: 250));
      await settle(tester);
      expect(channel.disposed, isFalse);
      expect(network.peers, hasLength(1));
      channel.openChannel();
      channel.receive({..._message('welcome', const []), 'durableSync': true});
      await settle(tester);
      channel.receive(_checkpoint(const []));
      channel.receive(_ackLocal(channel));
      await settle(tester);
      expect(room.initialSyncComplete, isTrue);
      expect(room.initialSyncError, isNull);
    },
  );

  testRoomWidgets(
    'resume does not shorten the deadline for an initial durable checkpoint',
    (tester) async {
      final room = session(preferExistingHost: true);
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      channel.receive({..._message('welcome', const []), 'durableSync': true});
      await settle(tester);
      room.resume();
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      await tester.pump(const Duration(seconds: 6));
      await settle(tester);
      expect(channel.disposed, isFalse);
      expect(room.initialSyncError, isNull);
      expect(room.initialSyncComplete, isFalse);
      channel.receive(_checkpoint(const []));
      channel.receive(_ackLocal(channel));
      await settle(tester);
      expect(room.initialSyncComplete, isTrue);
      expect(room.initialSyncError, isNull);
    },
  );

  for (final duringProbe in [false, true]) {
    testRoomWidgets(
      'resume preserves a hello being saved ${duringProbe ? 'during' : 'before'} its probe',
      (tester) async {
        network.autoRegister = true;
        final store = _Store();
        final room = session(newlyCreated: true, store: store);
        await room.start();
        await settle(tester);
        final peer = network.peers.single;
        _FakeConnection? silent;
        if (duringProbe) {
          silent = _FakeConnection('silent-runtime');
          network.connections.add(silent);
          peer.emit<DataConnection>('connection', silent);
          silent.openChannel();
          silent.receive(_message('hello', const [], actor: 'silent'));
          await settle(tester);
          expect(room.onlineCount, 2);
          room.resume();
          await tester.pump(const Duration(milliseconds: 200));
          await settle(tester);
        }
        final gate = store.appendGate = Completer<void>();
        final arriving = _FakeConnection('arriving-runtime');
        network.connections.add(arriving);
        peer.emit<DataConnection>('connection', arriving);
        arriving.openChannel();
        arriving.receive(
          _message('hello', [_edit('arriving-edit', 'survived resume')]),
        );
        await settle(tester);
        expect(store.appendCalls, 1);
        if (!duringProbe) {
          room.resume();
          await tester.pump(const Duration(milliseconds: 200));
          await settle(tester);
        }
        await tester.pump(const Duration(seconds: 6));
        await settle(tester);
        final disposedDuringSave = arriving.disposed;
        gate.complete();
        await settle(tester);
        expect(disposedDuringSave, isFalse);
        expect(peer.destroyed, isFalse);
        expect(network.peers, hasLength(1));
        if (silent != null) expect(silent.disposed, isTrue);
        expect(room.text, 'survived resume');
        expect(room.historyLength, 1);
        expect(
          _sentMessages(arriving).any((m) => m.type == RoomMessageType.welcome),
          isTrue,
        );
      },
    );
  }

  testRoomWidgets(
    'heartbeat wall-clock gap wakes discovery even without visibility events',
    (tester) async {
      network.autoRegister = true;
      var clock = DateTime.utc(2026, 10, 15);
      final room = session(newlyCreated: true, now: () => clock);
      await room.start();
      await settle(tester);
      await room.edit('durable before suspension');
      final oldPeer = network.peers.single;
      clock = clock.add(const Duration(hours: 1));
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
      expect(network.peers, hasLength(1));
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      expect(network.peers, hasLength(2));
      expect(oldPeer.destroyed, isTrue);
      expect(room.initialSyncComplete, isFalse);
      expect(room.verifyingAfterResume, isTrue);
      expect(room.text, 'durable before suspension');
      expect(room.historyLength, 1);
    },
  );

  testRoomWidgets(
    'stalled channels survive the focus grace then reconnect and union offline journals',
    (tester) async {
      network.autoRegister = true;
      var clock = DateTime.utc(2026, 10, 15);
      final hostStore = _Store();
      final memberStore = _Store();
      final host = session(actor: 'host', store: hostStore, now: () => clock);
      await host.start();
      await settle(tester);
      await host.edit('shared before sleep');
      final member = session(
        actor: 'member',
        store: memberStore,
        preferExistingHost: true,
        now: () => clock,
      );
      await member.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(
        [host.initialSyncComplete, member.initialSyncComplete],
        [true, true],
      );
      final oldPeers = network.peers.toList();
      final incoming = oldPeers.first.attached.single;
      final outgoing = oldPeers.last.outbound.single;
      expect(incoming.other, same(outgoing));
      incoming.dropData = true;
      outgoing.dropData = true;
      host.setForeground(false);
      member.setForeground(false);
      await host.edit('host losing offline edit');
      await host.edit('host latest offline edit');
      await member.edit('member losing offline edit');
      await member.edit('member latest offline edit');
      await settle(tester);
      final hostOffline = await hostStore.loadHistory(_roomId);
      final memberOffline = await memberStore.loadHistory(_roomId);
      expect([hostOffline.length, memberOffline.length], [3, 3]);
      final union = {
        for (final edit in [...hostOffline, ...memberOffline]) edit['id']: edit,
      };
      expect(union, hasLength(5));
      // Wall time jumps, but neither liveness nor heartbeat timers execute asleep.
      clock = clock.add(const Duration(hours: 1));
      expect(network.peers, hasLength(2));
      expect([incoming.open, outgoing.open], [true, true]);
      host.setForeground(true);
      member.setForeground(true);
      expect(
        [host.initialSyncComplete, member.initialSyncComplete],
        [false, false],
      );
      expect([host.localCopyOpened, member.localCopyOpened], [false, false]);
      host.resume();
      member.resume();
      await settle(tester);
      expect([incoming.disposed, outgoing.disposed], [false, false]);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      await tester.pump(const Duration(seconds: 89));
      await settle(tester);
      expect([incoming.disposed, outgoing.disposed], [false, false]);
      expect(
        [host.initialSyncComplete, member.initialSyncComplete],
        [false, false],
      );
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      for (var retry = 0; retry < 4; retry++) {
        await tester.pump(const Duration(seconds: 1));
        await settle(tester);
      }
      expect([incoming.disposed, outgoing.disposed], [true, true]);
      expect(oldPeers.any((peer) => peer.destroyed), isTrue);
      expect([host.onlineCount, member.onlineCount], [2, 2]);
      expect(host.text, member.text);
      expect([host.historyLength, member.historyLength], [5, 5]);
      for (final store in [hostStore, memberStore]) {
        expect({
          for (final edit in await store.loadHistory(_roomId)) edit['id']: edit,
        }, union);
        expect(store.membershipCalls, 0);
      }
      expect(
        [host.initialSyncComplete, member.initialSyncComplete],
        [true, true],
      );
    },
  );

  testRoomWidgets(
    'execution pause rechecks missed history on the same admitted RTC channel',
    (tester) async {
      network.autoRegister = true;
      var clock = DateTime.utc(2026, 10, 22);
      final host = session(actor: 'host');
      await host.start();
      await settle(tester);
      final storage = _Store();
      final member = session(
        actor: 'member',
        store: storage,
        preferExistingHost: true,
        now: () => clock,
      );
      await member.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(member.initialSyncComplete, isTrue);
      final peers = network.peers.toList();
      final outgoing = peers.last.outbound.single;
      final incoming = outgoing.other!;
      final staleAck = _ackLocal(outgoing, actor: 'host');
      member.setForeground(false);
      incoming.dropData = true;
      await host.edit('missed while the event loop slept');
      await settle(tester);
      expect(member.text, isEmpty);
      incoming.dropData = false;
      final gate = storage.appendGate = Completer<void>();
      clock = clock.add(const Duration(seconds: 25));
      member.setForeground(true);
      expect(member.initialSyncComplete, isFalse);
      expect(member.verifyingAfterResume, isTrue);
      outgoing.receive(staleAck);
      outgoing.receive(_checkpoint(const [], actor: 'host'));
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      expect(outgoing.disposed, isFalse);
      expect(incoming.disposed, isFalse);
      expect(network.peers, orderedEquals(peers));
      expect(member.initialSyncComplete, isFalse);
      expect(await storage.loadHistory(_roomId), isEmpty);
      gate.complete();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(member.initialSyncComplete, isTrue);
      expect(member.text, 'missed while the event loop slept');
      expect(
        roomHistoryInventory(member.changes),
        roomHistoryInventory(host.changes),
      );
      expect(network.peers, orderedEquals(peers));
      expect(peers.every((peer) => !peer.destroyed), isTrue);
      expect(storage.membershipCalls, 0);
      expect(
        _sentMessages(outgoing).where((message) => message.recheckId != null),
        isNotEmpty,
      );
    },
  );

  testRoomWidgets(
    'fresh nonce is required even after the current local checkpoint is ACKed',
    (tester) async {
      var clock = DateTime.utc(2026, 10, 22);
      final member = session(preferExistingHost: true, now: () => clock);
      final channel = await standaloneFollower(tester, member);
      channel.openChannel();
      channel.receive({
        ..._message('welcome', const []),
        'durableSync': true,
        'recheckSync': true,
        'fastSync': true,
        'historyDigest': roomHistoryDigest(const []),
      });
      await settle(tester);
      channel.receive(_checkpoint(const []));
      channel.receive(_ackLocal(channel));
      await settle(tester);
      expect(member.initialSyncComplete, isTrue);
      final peer = network.peers.single;
      final staleAck = _ackLocal(channel);
      member.setForeground(false);
      clock = clock.add(const Duration(seconds: 25));
      member.setForeground(true);
      await settle(tester);
      final firstRequest = _sentMessages(channel).lastWhere(
        (message) =>
            message.type == RoomMessageType.inventory &&
            message.recheckId != null,
      );
      final firstRoundAck = _ackLocal(channel);
      member.setForeground(false);
      clock = clock.add(const Duration(seconds: 25));
      member.setForeground(true);
      await settle(tester);
      final request = _sentMessages(channel).lastWhere(
        (message) =>
            message.type == RoomMessageType.inventory &&
            message.recheckId != null,
      );
      expect(request.recheckId, isNot(firstRequest.recheckId));
      channel.receive(staleAck);
      channel.receive(firstRoundAck);
      channel.receive({
        ..._checkpoint(const [], syncId: 'e' * 32),
        'recheckId': firstRequest.recheckId,
      });
      channel.receive(_checkpoint(const []));
      channel.receive(_ackLocal(channel));
      await settle(tester);
      expect(
        member.initialSyncComplete,
        isFalse,
        reason:
            'a current ACK proves only our contribution, not a fresh remote read',
      );
      channel.receive({
        ..._checkpoint(const [], syncId: 'b' * 32),
        'recheckId': 'c' * 32,
      });
      await settle(tester);
      expect(member.initialSyncComplete, isFalse);
      channel.receive({
        ..._checkpoint(const [], syncId: 'd' * 32),
        'recheckId': request.recheckId,
      });
      await settle(tester);
      expect(member.initialSyncComplete, isTrue);
      expect(channel.disposed, isFalse);
      expect(network.peers, [peer]);
      expect(peer.destroyed, isFalse);
    },
  );

  testRoomWidgets(
    'queued inventory cannot close RTC while a new checkpoint is preparing',
    (tester) async {
      var clock = DateTime.utc(2026, 10, 23);
      final storage = _Store();
      final member = session(
        store: storage,
        preferExistingHost: true,
        now: () => clock,
      );
      final channel = await standaloneFollower(tester, member);
      channel.openChannel();
      channel.receive({
        ..._message('welcome', const []),
        'durableSync': true,
        'recheckSync': true,
        'fastSync': true,
        'historyDigest': roomHistoryDigest(const []),
      });
      await settle(tester);
      channel.receive(_checkpoint(const []));
      channel.receive(_ackLocal(channel));
      await settle(tester);
      expect(member.initialSyncComplete, isTrue);
      final gate = storage.appendGate = Completer<void>();
      final imported = _edit('queued-before-resume', 'held incoming append');
      channel.receive(_message('edits', [imported]));
      await settle(tester);
      channel.receive({
        ..._message('inventory', const []),
        'inventory': <String, String>{},
      });
      member.setForeground(false);
      clock = clock.add(const Duration(seconds: 25));
      member.setForeground(true);
      expect(member.initialSyncComplete, isFalse);
      gate.complete();
      await settle(tester);
      expect(
        channel.disposed,
        isFalse,
        reason:
            'an older inventory can precede the queued checkpoint preparation',
      );
      expect(network.peers, hasLength(1));
      expect(member.initialSyncError, isNull);
      final request = _sentMessages(channel).lastWhere(
        (message) =>
            message.type == RoomMessageType.inventory &&
            message.recheckId != null,
      );
      channel.receive(_checkpoint([imported]));
      channel.receive(_ackLocal(channel));
      channel.receive({
        ..._checkpoint([imported], syncId: 'f' * 32),
        'recheckId': request.recheckId,
      });
      await settle(tester);
      expect(member.initialSyncComplete, isTrue);
      expect(member.text, 'held incoming append');
      expect(channel.disposed, isFalse);
    },
  );

  testRoomWidgets(
    'minute-long remote silence keeps native RTC and recovers exact history',
    (tester) async {
      network.autoRegister = true;
      final host = session(actor: 'host');
      await host.start();
      await settle(tester);
      final member = session(actor: 'member', member: false);
      await member.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(member.initialSyncComplete, isTrue);
      final peers = network.peers.toList();
      final outgoing = peers.last.outbound.single;
      final incoming = outgoing.other!;
      outgoing.dropData = true;
      incoming.dropData = true;
      member.setForeground(false);
      await host.edit('latest while remote timers are silent');
      for (var tick = 0; tick < 13; tick++) {
        await tester.pump(const Duration(seconds: 5));
        await settle(tester);
      }
      expect([outgoing.disposed, incoming.disposed], [false, false]);
      expect(network.peers, orderedEquals(peers));
      expect([host.onlineCount, member.onlineCount], [1, 1]);
      outgoing.dropData = false;
      incoming.dropData = false;
      member.setForeground(true);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(
        [host.initialSyncComplete, member.initialSyncComplete],
        [true, true],
      );
      expect(member.text, 'latest while remote timers are silent');
      expect(
        roomHistoryInventory(host.changes),
        roomHistoryInventory(member.changes),
      );
      expect(network.peers, orderedEquals(peers));
      expect([outgoing.disposed, incoming.disposed], [false, false]);
    },
  );

  testRoomWidgets(
    'soft send timeout retains ordered chunks until the native send completes',
    (tester) async {
      network.autoRegister = true;
      final host = session(actor: 'host');
      await host.start();
      await settle(tester);
      final member = session(actor: 'member', preferExistingHost: true);
      await member.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      final peers = network.peers.toList();
      final outgoing = peers.last.outbound.single;
      final incoming = outgoing.other!;
      final before = incoming.sent.length;
      final gate = incoming.sendGate = Completer<void>();
      final text = 'ж' * 16000;
      await host.edit(text);
      await tester.pump(const Duration(seconds: 6));
      await settle(tester);
      expect(
        incoming.sent.length,
        before,
        reason: 'a soft timeout cannot release the pending native send',
      );
      expect([incoming.disposed, outgoing.disposed], [false, false]);
      expect(network.peers, orderedEquals(peers));
      incoming.sendGate = null;
      gate.complete();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(member.text, text);
      expect(host.storageError, isNull);
      expect(member.storageError, isNull);
      expect(
        roomHistoryInventory(host.changes),
        roomHistoryInventory(member.changes),
      );
      expect(network.peers, orderedEquals(peers));
      expect([incoming.disposed, outgoing.disposed], [false, false]);
      expect(
        _sentMessages(
          incoming,
        ).where((message) => message.type == RoomMessageType.edits),
        isNotEmpty,
      );
    },
  );

  testRoomWidgets(
    'heartbeats cannot keep a permanently blocked native send alive forever',
    (tester) async {
      network.autoRegister = true;
      final host = session(actor: 'host');
      await host.start();
      await settle(tester);
      final member = session(actor: 'member', preferExistingHost: true);
      await member.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      final outgoing = network.peers.last.outbound.single;
      final incoming = outgoing.other!;
      final gate = incoming.sendGate = Completer<void>();
      await host.edit('saved before the native send stalled');
      for (var tick = 0; tick < 18; tick++) {
        await tester.pump(const Duration(seconds: 5));
        await settle(tester);
      }
      expect(incoming.disposed, isFalse);
      expect(incoming.sent.any((packet) => packet['type'] == 'edits'), isFalse);
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
      expect(
        incoming.disposed,
        isTrue,
        reason: 'receive-only heartbeat progress cannot unblock a native send',
      );
      gate.complete();
      await settle(tester);
      for (var retry = 0; retry < 4; retry++) {
        await tester.pump(const Duration(seconds: 1));
        await settle(tester);
      }
      expect(member.text, 'saved before the native send stalled');
      expect(
        roomHistoryInventory(host.changes),
        roomHistoryInventory(member.changes),
      );
    },
  );

  testRoomWidgets(
    'simultaneous durable rechecks converge without replacing either RTC peer',
    (tester) async {
      network.autoRegister = true;
      var clock = DateTime.utc(2026, 10, 22);
      final host = session(actor: 'host', now: () => clock);
      await host.start();
      await settle(tester);
      await host.edit('common history');
      final member = session(
        actor: 'member',
        preferExistingHost: true,
        now: () => clock,
      );
      await member.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      final peers = network.peers.toList();
      final outgoing = peers.last.outbound.single;
      final incoming = outgoing.other!;
      outgoing.dropData = true;
      incoming.dropData = true;
      host.setForeground(false);
      member.setForeground(false);
      await host.edit('host offline contribution');
      await member.edit('member offline contribution');
      await settle(tester);
      outgoing.dropData = false;
      incoming.dropData = false;
      clock = clock.add(const Duration(seconds: 25));
      host.setForeground(true);
      member.setForeground(true);
      expect(
        [host.initialSyncComplete, member.initialSyncComplete],
        [false, false],
      );
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(
        [host.initialSyncComplete, member.initialSyncComplete],
        [true, true],
      );
      expect(
        roomHistoryInventory(host.changes),
        roomHistoryInventory(member.changes),
      );
      expect(host.historyLength, 3);
      expect(network.peers, orderedEquals(peers));
      expect([outgoing.disposed, incoming.disposed], [false, false]);
      expect(peers.every((peer) => !peer.destroyed), isTrue);
    },
  );

  testRoomWidgets(
    'wake after a closed channel hides stale copy until history and fresh ACK are durable',
    (tester) async {
      network.autoRegister = true;
      var clock = DateTime.utc(2026, 10, 20);
      final host = session(actor: 'host');
      await host.start();
      await settle(tester);
      final storage = _Store();
      final member = session(
        actor: 'member',
        store: storage,
        preferExistingHost: true,
        now: () => clock,
      );
      await member.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(member.initialSyncComplete, isTrue);
      final old = network.peers.last.outbound.single;
      final staleAck = _ackLocal(old, actor: 'host');
      old.dropData = true;
      old.other!.dropData = true;
      member.setForeground(false);
      await host.edit('changed while phone slept');
      await settle(tester);
      expect(member.text, isEmpty);
      final gate = storage.appendGate = Completer<void>();
      clock = clock.add(const Duration(seconds: 25));
      old.dispose();
      member.setForeground(true);
      expect(member.initialSyncComplete, isFalse);
      expect(member.verifyingAfterResume, isTrue);
      expect(member.initialSyncStatus, 'Сверяем изменения после возвращения…');
      old.receive(staleAck);
      old.receive(_checkpoint(const [], actor: 'host'));
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      expect(old.disposed, isTrue);
      expect(member.initialSyncComplete, isFalse);
      expect(member.verifyingAfterResume, isTrue);
      expect(await storage.loadHistory(_roomId), isEmpty);
      // Duplicate foreground and presence events cannot restart the budget or
      // turn the previous connection's durable proof into a new one.
      member.setForeground(true);
      member.resume();
      gate.complete();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(member.initialSyncComplete, isTrue);
      expect(member.verifyingAfterResume, isFalse);
      expect(member.text, 'changed while phone slept');
      expect(
        roomHistoryInventory(member.changes),
        roomHistoryInventory(host.changes),
      );
      expect(storage.membershipCalls, 0);
    },
  );

  testRoomWidgets(
    'fresh verification completed while hidden is not repeated on foreground',
    (tester) async {
      network.autoRegister = true;
      var clock = DateTime.utc(2026, 10, 22);
      final host = session(actor: 'host');
      await host.start();
      await settle(tester);
      final member = session(
        actor: 'member',
        preferExistingHost: true,
        now: () => clock,
      );
      await member.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      member.setForeground(false);
      clock = clock.add(const Duration(seconds: 25));
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
      // The in-place exchange can finish in the same turn; no reconnect delay
      // is necessary once its new nonce and durable checkpoint are confirmed.
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(member.initialSyncComplete, isTrue);
      final peers = network.peers.toList();
      member.setForeground(true);
      expect(member.initialSyncComplete, isTrue);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      expect(network.peers, orderedEquals(peers));
    },
  );

  testRoomWidgets(
    'last peer closing during the focus probe cannot keep stale readiness',
    (tester) async {
      network.autoRegister = true;
      var clock = DateTime.utc(2026, 10, 22);
      final host = session(actor: 'host');
      await host.start();
      await settle(tester);
      final storage = _Store();
      final member = session(
        actor: 'member',
        store: storage,
        preferExistingHost: true,
        now: () => clock,
      );
      await member.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      final old = network.peers.last.outbound.single;
      old.dropData = true;
      old.other!.dropData = true;
      member.setForeground(false);
      await host.edit('missed before deferred close');
      await settle(tester);
      clock = clock.add(const Duration(seconds: 4));
      member.setForeground(true);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      expect(member.initialSyncComplete, isTrue);
      final gate = storage.appendGate = Completer<void>();
      old.open = false;
      old.emit<void>('close', null);
      await settle(tester);
      expect(member.initialSyncComplete, isFalse);
      expect(member.verifyingAfterResume, isTrue);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      expect(member.initialSyncComplete, isFalse);
      gate.complete();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(member.initialSyncComplete, isTrue);
      expect(member.text, 'missed before deferred close');
    },
  );

  testRoomWidgets(
    'short focus return escalates a silent last peer to durable verification',
    (tester) async {
      network.autoRegister = true;
      var clock = DateTime.utc(2026, 10, 22);
      final host = session(actor: 'host');
      await host.start();
      await settle(tester);
      final storage = _Store();
      final member = session(
        actor: 'member',
        store: storage,
        preferExistingHost: true,
        now: () => clock,
      );
      await member.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      final old = network.peers.last.outbound.single;
      old.dropData = true;
      old.other!.dropData = true;
      member.setForeground(false);
      await host.edit('missed during a short pause');
      await settle(tester);
      clock = clock.add(const Duration(seconds: 4));
      member.setForeground(true);
      expect(member.initialSyncComplete, isTrue);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 5999));
      await settle(tester);
      expect(member.initialSyncComplete, isTrue);
      final saved = storage.appendGate = Completer<void>();
      await tester.pump(const Duration(milliseconds: 1));
      await settle(tester);
      expect(member.initialSyncComplete, isFalse);
      expect(member.verifyingAfterResume, isTrue);
      expect(old.disposed, isFalse);
      old.dropData = false;
      old.other!.dropData = false;
      member.resume();
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      expect(member.initialSyncComplete, isFalse);
      saved.complete();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(member.initialSyncComplete, isTrue);
      expect(member.text, 'missed during a short pause');
      expect(
        roomHistoryInventory(member.changes),
        roomHistoryInventory(host.changes),
      );
    },
  );

  testRoomWidgets(
    'resumed solo cannot substitute discovery for synchronization',
    (tester) async {
      network.autoRegister = true;
      var clock = DateTime.utc(2026, 10, 20);
      final room = session(newlyCreated: true, now: () => clock);
      await room.start();
      await settle(tester);
      expect(room.initialSyncComplete, isTrue);
      room.setForeground(false);
      clock = clock.add(const Duration(seconds: 25));
      room.setForeground(true);
      expect(room.verifyingAfterResume, isTrue);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      expect(room.networkAvailable, isTrue);
      expect(room.initialSyncComplete, isFalse);
      await tester.pump(const Duration(seconds: 28));
      await settle(tester);
      expect(room.initialSyncError, contains('30 секунд'));
      room.openLocalCopy();
      expect(room.localCopyOpened, isTrue);
      expect(room.initialSyncComplete, isFalse);
      expect(room.verifyingAfterResume, isFalse);
    },
  );

  testRoomWidgets(
    'healthy resume probes once, waits for the ordinary heartbeat and preserves peers and edits',
    (tester) async {
      network.autoRegister = true;
      final host = session(actor: 'host');
      await host.start();
      await settle(tester);
      final member = session(actor: 'member', preferExistingHost: true);
      await member.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      final peers = network.peers.toList();
      final outgoing = peers.last.outbound.single;
      final incoming = outgoing.other!;
      final before = outgoing.sent.length;
      member.resume();
      member.resume();
      await tester.pump(const Duration(milliseconds: 199));
      await settle(tester);
      expect(
        outgoing.sent.length,
        before,
        reason: 'resume is debounced for 200 ms',
      );
      await tester.pump(const Duration(milliseconds: 1));
      await settle(tester);
      expect(outgoing.sent.skip(before).map((packet) => packet['type']), [
        'presence',
      ]);
      member.resume();
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      expect(
        outgoing.sent.length,
        before + 1,
        reason: 'events coalesce during the six-second probe too',
      );
      // Only this side resumes. Presence is not an ACK; the host's normal 5s
      // heartbeat must get a chance to arrive before deciding the channel is dead.
      await tester.pump(const Duration(seconds: 4));
      await settle(tester);
      expect(incoming.sent.last['type'], 'presence');
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      expect(network.peers, orderedEquals(peers));
      expect(peers.every((peer) => !peer.destroyed), isTrue);
      expect([incoming.disposed, outgoing.disposed], [false, false]);
      await member.edit('member edit after healthy probe');
      await settle(tester);
      expect(host.text, 'member edit after healthy probe');
      await host.edit('host edit after healthy probe');
      await settle(tester);
      expect(member.text, 'host edit after healthy probe');
      expect(
        [host.initialSyncComplete, member.initialSyncComplete],
        [true, true],
      );
    },
  );

  testRoomWidgets(
    'host resume isolates a silent channel without replacing healthy incoming peers',
    (tester) async {
      network.autoRegister = true;
      final host = session(actor: 'host');
      await host.start();
      await settle(tester);
      final healthy = session(actor: 'healthy', preferExistingHost: true);
      await healthy.start();
      await settle(tester);
      final healthyOutgoing = network.peers.last.outbound.single;
      final healthyIncoming = healthyOutgoing.other!;
      final silent = session(actor: 'silent', preferExistingHost: true);
      await silent.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      final silentOutgoing = network.peers.last.outbound.single;
      final silentIncoming = silentOutgoing.other!;
      silentOutgoing.dropData = true;
      silentIncoming.dropData = true;
      final peers = network.peers.toList();
      host.resume();
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      expect(healthyIncoming.sent.last['type'], 'presence');
      expect(silentIncoming.sent.last['type'], 'presence');
      await tester.pump(const Duration(seconds: 6));
      await settle(tester);
      expect(silentIncoming.disposed, isFalse);
      expect(host.onlineCount, 2);
      expect(
        [healthyIncoming.disposed, healthyOutgoing.disposed],
        [false, false],
      );
      expect(peers.first.destroyed, isFalse);
      expect(
        network.peers,
        orderedEquals(peers),
        reason: 'one answering channel prevents a whole-peer refresh',
      );
      silent.dispose();
      await healthy.edit('healthy member retained');
      await settle(tester);
      expect(host.text, 'healthy member retained');
      await host.edit('host retained too');
      await settle(tester);
      expect(healthy.text, 'host retained too');
      expect([host.onlineCount, healthy.onlineCount], [2, 2]);
      expect(
        [host.initialSyncComplete, healthy.initialSyncComplete],
        [true, true],
      );
    },
  );

  testRoomWidgets(
    'healthy Alt+Tab keeps readiness and channels across long hides',
    (tester) async {
      network.autoRegister = true;
      var clock = DateTime.utc(2026, 10, 22);
      final host = session(actor: 'host');
      await host.start();
      await settle(tester);
      final member = session(
        actor: 'member',
        preferExistingHost: true,
        now: () => clock,
      );
      await member.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      final peers = network.peers.toList();
      final readiness = <bool>[];
      member.addListener(() => readiness.add(member.initialSyncComplete));
      for (var hide = 0; hide < 3; hide++) {
        member.setForeground(false);
        for (var tick = 0; tick < 6; tick++) {
          clock = clock.add(const Duration(seconds: 5));
          await tester.pump(const Duration(seconds: 5));
          await settle(tester);
        }
        member.setForeground(true);
        await tester.pump(const Duration(milliseconds: 200));
        await settle(tester);
        expect(member.initialSyncComplete, isTrue);
        expect(member.verifyingAfterResume, isFalse);
        expect(network.peers, orderedEquals(peers));
        await host.edit('still connected $hide');
        await settle(tester);
        expect(member.text, 'still connected $hide');
      }
      expect(readiness, isNotEmpty);
      expect(readiness, everyElement(isTrue));
      expect(peers.every((peer) => !peer.destroyed), isTrue);
    },
  );

  testRoomWidgets(
    'healthy hide shorter than three seconds does not probe or create peers',
    (tester) async {
      network.autoRegister = true;
      var clock = DateTime.utc(2026, 10, 15);
      final room = session(now: () => clock);
      await room.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      final peer = network.peers.single;
      expect(room.networkAvailable, isTrue);
      room.setForeground(false);
      clock = clock.add(const Duration(milliseconds: 2999));
      room.setForeground(true);
      await tester.pump(const Duration(milliseconds: 250));
      await settle(tester);
      expect(network.peers.single, same(peer));
      expect(peer.destroyed, isFalse);
      // Three seconds hidden alone is not suspension or a lost connection.
      room.setForeground(false);
      clock = clock.add(const Duration(seconds: 3));
      room.setForeground(true);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      expect(network.peers, hasLength(2));
      expect(peer.destroyed, isTrue);
      expect(room.initialSyncComplete, isTrue);
      expect(room.verifyingAfterResume, isFalse);
    },
  );

  testRoomWidgets(
    'resume fast-kicks long backoff, cancels its timer and resets retry attempt',
    (tester) async {
      final room = session();
      await room.start();
      // Registration alone does not reset retries. Reach the capped exponential
      // delay deterministically, allowing for the existing 0..699 ms jitter.
      for (var attempt = 0; attempt < 5; attempt++) {
        network.peers.last.emit<dynamic>('error', 'signaling outage $attempt');
        await settle(tester);
        await tester.pump(const Duration(seconds: 8));
        await settle(tester);
      }
      expect(network.peers, hasLength(6));
      final backedOff = network.peers.last;
      backedOff.emit<dynamic>('error', 'pending long backoff');
      await settle(tester);
      final before = network.peers.length;
      room.setForeground(false);
      room.setForeground(
        true,
      ); // Unhealthy connectivity overrides a short hide.
      room.resume();
      await tester.pump(const Duration(milliseconds: 199));
      await settle(tester);
      expect(network.peers.length, before);
      await tester.pump(const Duration(milliseconds: 1));
      await settle(tester);
      expect(network.peers.length, before + 1);
      expect(backedOff.destroyed, isTrue);
      final kicked = network.peers.last;
      expect(kicked.id, _alias);
      kicked.register();
      await settle(tester);
      await tester.pump(const Duration(seconds: 9));
      await settle(tester);
      expect(
        network.peers.length,
        before + 1,
        reason: 'old long backoff was cancelled',
      );
      kicked.emit<dynamic>('error', 'next outage');
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 1100));
      await settle(tester);
      expect(
        network.peers.length,
        before + 2,
        reason: 'retry starts again at 400..1099 ms, not eight seconds',
      );
    },
  );

  testRoomWidgets(
    'confirmed copy waits after suspension but an explicit local copy stays open',
    (tester) async {
      final readyStore = _Store();
      final localStore = _Store();
      final history = [
        _edit('loser', 'old'),
        _edit('winner', 'latest', clock: 2),
      ];
      await readyStore.appendHistory(_roomId, history);
      await localStore.appendHistory(_roomId, history);
      var clock = DateTime.utc(2026, 10, 15);
      final ready = session(
        store: readyStore,
        newlyCreated: true,
        now: () => clock,
      );
      final local = session(store: localStore, now: () => clock);
      await ready.start();
      await local.start();
      local.openLocalCopy();
      expect(ready.initialSyncComplete, isTrue);
      expect(local.localCopyOpened, isTrue);
      final appends = [readyStore.appendCalls, localStore.appendCalls];
      final observed = <(bool, bool, bool)>[];
      void observe() => observed.add((
        ready.initialSyncComplete,
        local.initialSyncComplete,
        local.localCopyOpened,
      ));
      ready.addListener(observe);
      local.addListener(observe);
      // Only a registration stranded across suspension should be replaced.
      clock = clock.add(const Duration(minutes: 10));
      ready.resume();
      local.resume();
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      expect(network.peers, hasLength(4));
      expect(observed, isNotEmpty);
      expect(observed, everyElement((false, false, true)));
      expect([ready.joined, local.joined], [true, true]);
      expect([ready.text, local.text], ['latest', 'latest']);
      expect([ready.historyLength, local.historyLength], [2, 2]);
      expect(local.initialSyncStatus, contains('не подтверждена'));
      expect(
        [readyStore.appendCalls, localStore.appendCalls],
        appends,
        reason: 'resume does not rewrite the durable journal',
      );
      expect(await readyStore.loadHistory(_roomId), history);
      expect(await localStore.loadHistory(_roomId), history);
      expect([readyStore.membershipCalls, localStore.membershipCalls], [0, 0]);
    },
  );

  testRoomWidgets(
    'healthy local follower Alt+Tab keeps readiness without asking owner to resync',
    (tester) async {
      final hub = _TabsHub();
      final owner = roomTabs(hub);
      await owner.start();
      owner.publish(_tabState(const [], online: 2));
      final tab = roomTabs(hub);
      var clock = DateTime.utc(2026, 10, 22);
      final follower = session(tabCoordinator: tab, now: () => clock);
      await follower.start();
      await settleTabs(tester);
      final ready = <bool>[];
      follower.addListener(() => ready.add(follower.initialSyncComplete));
      follower.setForeground(false);
      for (var tick = 0; tick < 8; tick++) {
        clock = clock.add(const Duration(seconds: 5));
        await tester.pump(const Duration(seconds: 5));
        await settleTabs(tester);
      }
      follower.setForeground(true);
      await tester.pump(const Duration(milliseconds: 200));
      await settleTabs(tester);
      expect(follower.initialSyncComplete, isTrue);
      expect(ready, everyElement(isTrue));
      expect(tab.resyncRequests, isEmpty);
      expect(network.peers, isEmpty);
    },
  );

  testRoomWidgets(
    'local follower resume rejects cached ready state until correlated fresh proof',
    (tester) async {
      final hub = _TabsHub();
      final owner = roomTabs(hub);
      await owner.start();
      owner.publish(_tabState(const [], online: 2));
      final tab = roomTabs(hub);
      var clock = DateTime.utc(2026, 10, 15);
      final follower = session(tabCoordinator: tab, now: () => clock);
      await follower.start();
      await settleTabs(tester);
      expect(follower.initialSyncComplete, isTrue);
      final requests = tab.requests;
      follower.setForeground(false);
      clock = clock.add(const Duration(minutes: 10));
      follower.setForeground(true);
      follower.resume();
      follower.resume();
      await tester.pump(const Duration(milliseconds: 200));
      await settleTabs(tester);
      expect(tab.requests, requests);
      expect(tab.resyncRequests, hasLength(1));
      expect(follower.initialSyncComplete, isFalse);
      owner.publish(_tabState(const [], online: 2));
      await settleTabs(tester);
      expect(follower.initialSyncComplete, isFalse);
      owner.publish(
        _tabState(
          const [],
          online: 2,
          completedResyncs: ['bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'],
        ),
      );
      await settleTabs(tester);
      expect(follower.initialSyncComplete, isFalse);
      owner.publish(
        _tabState(
          const [],
          online: 2,
          completedResyncs: [tab.resyncRequests.single],
        ),
      );
      await settleTabs(tester);
      expect(follower.initialSyncComplete, isTrue);
      expect(follower.onlineCount, 2);
      expect(network.peers, isEmpty);
      expect(network.connections, isEmpty);
    },
  );

  testRoomWidgets(
    'resumed local follower asks its owner for a new durable peer round',
    (tester) async {
      network.autoRegister = true;
      var clock = DateTime.utc(2026, 10, 20);
      final remote = session(actor: 'remote', newlyCreated: true);
      await remote.start();
      await settle(tester);
      final hub = _TabsHub();
      final shared = _Store();
      final ownerTab = roomTabs(hub);
      final owner = session(
        actor: 'local',
        store: shared,
        preferExistingHost: true,
        tabCoordinator: ownerTab,
      );
      await owner.start();
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settleTabs(tester);
      final followerTab = roomTabs(hub);
      final follower = session(
        actor: 'local',
        store: shared,
        tabCoordinator: followerTab,
        now: () => clock,
      );
      await follower.start();
      await settleTabs(tester);
      expect(
        [owner.initialSyncComplete, follower.initialSyncComplete],
        [true, true],
      );
      final peersBefore = network.peers.length;
      follower.setForeground(false);
      clock = clock.add(const Duration(seconds: 25));
      follower.setForeground(true);
      expect(follower.initialSyncComplete, isFalse);
      await tester.pump(const Duration(milliseconds: 200));
      await settleTabs(tester);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await settleTabs(tester);
      expect(
        [owner.initialSyncComplete, follower.initialSyncComplete],
        [true, true],
      );
      expect(
        hub.state!.completedResyncs,
        contains(followerTab.resyncRequests.single),
      );
      expect(
        network.peers.length,
        peersBefore,
        reason:
            'The owner rechecks its existing RTC; the local follower opens no sockets',
      );
      expect(
        roomHistoryInventory(follower.changes),
        roomHistoryInventory(remote.changes),
      );
    },
  );

  testRoomWidgets(
    'resume cannot restart a failed fresh join or grant membership',
    (tester) async {
      final store = _Store();
      var clock = DateTime.utc(2026, 10, 15);
      final fresh = session(member: false, store: store, now: () => clock);
      await fresh.start();
      for (var i = 0; i < 31; i++) {
        await tester.pump(const Duration(seconds: 1));
        await settle(tester);
      }
      expect(fresh.error, contains('30 секунд'));
      final error = fresh.error;
      final peers = network.peers.length;
      fresh.setForeground(false);
      clock = clock.add(const Duration(hours: 1));
      fresh.setForeground(true);
      fresh.resume();
      await tester.pump(const Duration(seconds: 40));
      await settle(tester);
      expect(network.peers.length, peers);
      expect(fresh.error, error);
      expect(fresh.joined, isFalse);
      expect(fresh.initialSyncComplete, isFalse);
      expect(store.membershipCalls, 0);
    },
  );

  testRoomWidgets(
    'dispose cancels pending resume debounce and ignores later visibility events',
    (tester) async {
      final room = session();
      await room.start();
      await settle(tester);
      room.resume();
      await tester.pump(const Duration(milliseconds: 199));
      var notifications = 0;
      room.addListener(() => notifications++);
      room.dispose();
      room.resume();
      room.setForeground(false);
      room.setForeground(true);
      final peers = network.peers.length;
      await settle(tester);
      expect(network.peers.single.destroyed, isTrue);
      // testWidgets also checks that disposal leaves no pending fake timers.
      expect(network.peers.length, peers);
      expect(notifications, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testRoomWidgets('dispose cancels an active six-second resume probe', (
    tester,
  ) async {
    network.autoRegister = true;
    final host = session(actor: 'host');
    await host.start();
    await settle(tester);
    final member = session(actor: 'member', preferExistingHost: true);
    await member.start();
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    member.resume();
    await tester.pump(const Duration(milliseconds: 200));
    await settle(tester);
    final channel = network.peers.last.outbound.single;
    expect(channel.sent.last['type'], 'presence');
    host.dispose();
    member.dispose();
    await settle(tester);
    expect(channel.disposed, isTrue);
    // Do not advance past the probe deadline: a forgotten timer must fail the
    // framework's pending-timer assertion, even if its callback has a guard.
    expect(tester.takeException(), isNull);
  });

  testRoomWidgets(
    'empty host losing complete discovery enters normal reconnect without resetting readiness',
    (tester) async {
      final peers = <_CoveragePeer>[];
      addTearDown(() async {
        for (final peer in peers) {
          await peer.closeEvents();
        }
      });
      final room = session(
        factory: (id, _) {
          final peer = _CoveragePeer(id);
          peers.add(peer);
          return peer;
        },
      );
      await room.start();
      final peer = peers.single;
      peer.register();
      peer.cover(true);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(room.initialSyncComplete, isTrue);
      peer.cover(false);
      await settle(tester);
      expect(peer.open, isTrue, reason: 'one backend is still registered');
      expect(
        peers,
        hasLength(1),
        reason: 'ordinary reconnect retains its backoff',
      );
      await tester.pump(const Duration(milliseconds: 1100));
      await settle(tester);
      expect(peers, hasLength(2));
      expect(peer.disposed, isTrue);
      expect(peers.last.id, _alias);
      expect(room.initialSyncComplete, isTrue);
    },
  );

  testRoomWidgets(
    'incomplete discovery reconnects only after the last incoming peer is lost',
    (tester) async {
      final peers = <_CoveragePeer>[];
      addTearDown(() async {
        for (final peer in peers) {
          await peer.closeEvents();
        }
      });
      final room = session(
        newlyCreated: true,
        factory: (id, _) {
          final peer = _CoveragePeer(id);
          peers.add(peer);
          return peer;
        },
      );
      await room.start();
      final peer = peers.single;
      peer.register();
      final channels = <_FakeConnection>[];
      for (final actor in ['alice', 'bob']) {
        final channel = _FakeConnection('$actor-runtime');
        channels.add(channel);
        network.connections.add(channel);
        peer.emit<RoomChannel>('connection', PeerJsRoomChannel(channel));
        channel.openChannel();
        channel.receive(_message('hello', const [], actor: actor));
        await settle(tester);
      }
      peer.cover(true);
      peer.cover(false);
      await tester.pump(const Duration(milliseconds: 1100));
      await settle(tester);
      expect(
        peers,
        hasLength(1),
        reason: 'live peers make partial discovery sufficient',
      );
      channels.first.emit<void>('close', null);
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 1100));
      await settle(tester);
      expect(
        peers,
        hasLength(1),
        reason: 'the remaining incoming peer is still usable',
      );
      expect(channels.last.disposed, isFalse);
      channels.last.emit<void>('close', null);
      await settle(tester);
      expect(peers, hasLength(1));
      await tester.pump(const Duration(milliseconds: 1100));
      await settle(tester);
      expect(peers, hasLength(2));
      expect(peer.disposed, isTrue);
      expect(peers.last.id, _alias);
      expect(room.initialSyncComplete, isTrue);
    },
  );

  testRoomWidgets(
    'ICE disconnection allows five seconds to recover and resets on recovery',
    (tester) async {
      final room = session();
      final channel = await standaloneFollower(tester, room);
      final health = _RtcHealth();
      channel.peerConnection = health;
      channel.openChannel();
      channel.receive(_message('welcome', const []));
      await settle(tester);
      expect(room.onlineCount, 2);

      health.iceConnectionState =
          RTCIceConnectionState.RTCIceConnectionStateDisconnected;
      channel.emit('iceStateChanged', health.iceConnectionState);
      await tester.pump(const Duration(seconds: 4));
      expect(channel.disposed, isFalse);
      expect(room.onlineCount, 2);
      health.iceConnectionState =
          RTCIceConnectionState.RTCIceConnectionStateConnected;
      channel.emit('iceStateChanged', health.iceConnectionState);
      await tester.pump(const Duration(seconds: 2));
      expect(channel.disposed, isFalse);

      health.iceConnectionState =
          RTCIceConnectionState.RTCIceConnectionStateDisconnected;
      channel.emit('iceStateChanged', health.iceConnectionState);
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
      expect(channel.disposed, isTrue);
      expect(room.onlineCount, 1);
      expect(room.joined, isTrue);
      expect(room.log, contains(contains('WebRTC/ICE потерял связь')));
    },
  );

  testRoomWidgets('failed or closed ICE is terminal without a recovery grace', (
    tester,
  ) async {
    for (final terminal in [
      RTCIceConnectionState.RTCIceConnectionStateFailed,
      RTCIceConnectionState.RTCIceConnectionStateClosed,
    ]) {
      final room = session();
      final channel = await standaloneFollower(tester, room);
      final health = _RtcHealth();
      channel.peerConnection = health;
      channel.openChannel();
      channel.receive(_message('welcome', const []));
      await settle(tester);
      health.iceConnectionState = terminal;
      channel.emit('iceStateChanged', terminal);
      await settle(tester);
      expect(channel.disposed, isTrue);
      expect(room.onlineCount, 1);
      expect(room.joined, isTrue);
      room.dispose();
      await settle(tester);
    }
  });

  testRoomWidgets('connectivity polling detects RTC failures without events', (
    tester,
  ) async {
    final room = session();
    final channel = await standaloneFollower(tester, room);
    final health = _RtcHealth();
    channel.peerConnection = health;
    channel.openChannel();
    channel.receive(_message('welcome', const []));
    await settle(tester);
    health.connectionState =
        RTCPeerConnectionState.RTCPeerConnectionStateFailed;
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(channel.disposed, isTrue);
    expect(room.onlineCount, 1);
    expect(room.joined, isTrue);
  });

  testRoomWidgets(
    'zone-caught socket failures ignore stale getters and late events',
    (tester) async {
      late Zone socketZone;
      final room = session(
        factory: (id, configuration) {
          socketZone = Zone.current;
          return network.create(id, configuration);
        },
      );
      await room.start();
      final oldPeer = network.peers.single;
      oldPeer.register();
      socketZone.run(() {
        unawaited(Future<void>.error(StateError('WebSocket handshake failed')));
      });
      await settle(tester);
      expect(oldPeer.open, isTrue); // Stale package getter must not win.
      expect(room.log.last, contains('WebSocket handshake failed'));
      oldPeer.register();
      final unwanted = _FakeConnection('unwanted');
      network.connections.add(unwanted);
      oldPeer.emit<DataConnection>('connection', unwanted);
      await settle(tester);
      expect(unwanted.disposed, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      expect(oldPeer.destroyed, isTrue);
      expect(network.peers, hasLength(2));
      oldPeer.emit<dynamic>('error', 'stale');
      oldPeer.emit<String?>('open', oldPeer.id);
      await settle(tester);
      expect(room.log.last, isNot('stale'));
    },
  );

  testRoomWidgets(
    'disposal cancels timers, pending retries and async welcome callbacks',
    (tester) async {
      final store = _Store()..appendGate = Completer<void>();
      final room = session(member: false, store: store);
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      channel.receive(_message('welcome', [_edit('pending', 'pending save')]));
      await settle(tester);
      expect(store.appendCalls, 1);
      var notifications = 0;
      room.addListener(() => notifications++);
      room.dispose();
      final count = network.peers.length;
      store.appendGate!.complete();
      channel.emit<void>('open', null);
      channel.receive(_message('welcome', [_edit('late', 'late')]));
      await tester.pump(const Duration(minutes: 2));
      await settle(tester);
      expect(network.peers.length, count);
      expect(notifications, 0);
      expect(store.membershipCalls, 0);
      expect(channel.disposed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testRoomWidgets(
    'accepted offline room refreshes externally persisted history without appending',
    (tester) async {
      final store = _Store();
      final room = session(store: store);
      await room.start();
      expect(store.changes.hasListener, isTrue);
      await store.externalAppend([_edit('other-tab', 'saved by closed tab')]);
      store.changes.add(null); // Bursts are coalesced into one bounded refresh.
      expect(room.text, isEmpty);
      await tester.pump(const Duration(milliseconds: 40));
      await settle(tester);
      expect(room.text, 'saved by closed tab');
      expect(room.historyLength, 1);
      expect(store.appendCalls, 0);
      expect(store.loadCalls, 2);
      network.autoRegister = true;
      await room.retry();
      await settle(tester);
      final fresh = session(member: false, actor: 'fresh');
      await fresh.start();
      await settle(tester);
      expect(fresh.joined, isTrue);
      expect(fresh.text, 'saved by closed tab');
    },
  );

  testRoomWidgets(
    'external durable edits refresh host and broadcast to online followers',
    (tester) async {
      network.autoRegister = true;
      final store = _Store();
      final host = session(actor: 'host', store: store);
      await host.start();
      await settle(tester);
      final freshStore = _Store();
      final fresh = session(member: false, actor: 'fresh', store: freshStore);
      await fresh.start();
      expect(
        freshStore.changes.hasListener,
        isFalse,
        reason: 'No storage event may imply acceptance',
      );
      await settle(tester);
      expect(freshStore.changes.hasListener, isTrue);
      await store.externalAppend([_edit('external', 'from another tab')]);
      await tester.pump(const Duration(milliseconds: 40));
      await settle(tester);
      expect([host.text, fresh.text], everyElement('from another tab'));
      expect(
        store.appendCalls,
        0,
        reason: 'Already durable external edits must not be appended again',
      );
      expect(freshStore.appendCalls, 1);
      expect([host.historyLength, fresh.historyLength], everyElement(1));
    },
  );

  testRoomWidgets(
    'history refresh preserves failed drafts and cancels watcher on disposal',
    (tester) async {
      final store = _Store();
      final room = session(store: store);
      await room.start();
      store.failAppend = true;
      await room.edit('failed local draft');
      await store.externalAppend([_edit('external', 'durable external')]);
      await tester.pump(const Duration(milliseconds: 40));
      await settle(tester);
      expect(room.text, 'failed local draft');
      expect(room.historyLength, 2);
      expect(room.storageError, contains('Disk full'));
      store.changes.add(null);
      room.dispose(); // Cancel a pending coalesced refresh, not just the stream.
      expect(store.changes.hasListener, isFalse);
      final reads = store.loadCalls;
      store.changes.add(null);
      await tester.pump(const Duration(milliseconds: 60));
      await settle(tester);
      expect(store.loadCalls, reads);
      expect(tester.takeException(), isNull);
    },
  );

  testRoomWidgets(
    'first valid chunk replaces the ordinary handshake deadline',
    (tester) async {
      final room = session();
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      final welcome = decodeRoomMessage(
        _message('welcome', [_edit('large', 'Ж😀' * 6000)]),
        roomId: _roomId,
      );
      final chunks = encodeRoomMessage(welcome).toList();
      channel.receive(chunks.first);
      await tester.pump(const Duration(seconds: 13));
      await settle(tester);
      expect(
        channel.disposed,
        isFalse,
        reason: 'The 12-second handshake expired',
      );
      for (final chunk in chunks.skip(1)) {
        channel.receive(chunk);
      }
      await settle(tester);
      expect(room.text, 'Ж😀' * 6000);
      expect(room.onlineCount, 2);
      expect(channel.disposed, isFalse);
    },
  );

  testRoomWidgets(
    'assembly deadline is fixed despite later accepted fragments',
    (tester) async {
      final room = session();
      final channel = await standaloneFollower(tester, room);
      channel.openChannel();
      final chunks = encodeRoomMessage(
        decodeRoomMessage(
          _message('welcome', [_edit('large', 'a' * 25000)]),
          roomId: _roomId,
        ),
      ).toList();
      channel.receive(chunks.first);
      await tester.pump(const Duration(seconds: 15));
      channel.receive(
        chunks[1],
      ); // Renews liveness, but not the transfer deadline.
      await tester.pump(const Duration(seconds: 10));
      await settle(tester);
      expect(channel.disposed, isTrue);
      expect(room.log, contains(contains('Передача истории не завершена')));
      expect(room.historyLength, 0);
    },
  );

  testRoomWidgets('identical chunk duplicates do not renew channel liveness', (
    tester,
  ) async {
    final room = session();
    final channel = await standaloneFollower(tester, room);
    channel.openChannel();
    final first = encodeRoomMessage(
      decodeRoomMessage(
        _message('welcome', [_edit('large', 'a' * 25000)]),
        roomId: _roomId,
      ),
    ).first;
    channel.receive(first);
    await tester.pump(const Duration(seconds: 15));
    channel.receive(first);
    await tester.pump(const Duration(seconds: 5));
    await settle(tester);
    expect(channel.disposed, isTrue);
    expect(room.log, contains(contains('Участник перестал отвечать')));
    expect(room.historyLength, 0);
  });

  testRoomWidgets('chunk transfer cannot extend a fresh join past 30 seconds', (
    tester,
  ) async {
    final store = _Store();
    final room = session(member: false, store: store);
    final channel = await standaloneFollower(tester, room);
    channel.openChannel();
    final chunks = encodeRoomMessage(
      decodeRoomMessage(
        _message('welcome', [_edit('large', 'a' * 25000)]),
        roomId: _roomId,
      ),
    ).toList();
    await tester.pump(const Duration(seconds: 6));
    channel.receive(chunks.first); // Assembly deadline is now at 31 seconds.
    await tester.pump(const Duration(seconds: 15));
    channel.receive(chunks[1]); // Liveness is now later than the join deadline.
    await tester.pump(const Duration(seconds: 9));
    await settle(tester);
    expect(room.joined, isFalse);
    expect(room.error, contains('30 секунд'));
    expect(channel.disposed, isTrue);
    expect(store.membershipCalls, 0);
    expect(store.appendCalls, 0);
  });

  testRoomWidgets('invalid TURN config does not silently use STUN', (
    tester,
  ) async {
    final room = session(
      ice: const IceConfiguration(turnUrls: 'turn:relay.example'),
    );
    await room.start();
    expect(network.peers, isEmpty);
    expect(room.error, contains('TURN_USERNAME'));
    expect(room.joined, isTrue);
    await room.edit('offline despite config failure');
    expect(room.text, 'offline despite config failure');
  });
}
