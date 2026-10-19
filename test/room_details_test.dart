import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/local/room_tabs.dart';
import 'package:mytree_webrtc_demo/room_document.dart';
import 'package:mytree_webrtc_demo/room_history.dart';
import 'package:mytree_webrtc_demo/room_protocol.dart';
import 'package:mytree_webrtc_demo/room_session.dart';
import 'package:mytree_webrtc_demo/signaling/signaling.dart';
import 'package:mytree_webrtc_demo/storage/room_store.dart';

const _roomId = '0123456789abcdef0123456789abcdef';

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
  final peers = <_Peer>[];
  final channels = <_Channel>[];
  final registered = <String, _Peer>{};

  SignalingPeer create(String id, Map<String, dynamic> configuration) {
    final peer = _Peer(this, id);
    peers.add(peer);
    return peer;
  }

  Future<void> close() async {
    for (final peer in peers) {
      await peer.closeEvents();
    }
    for (final channel in channels) {
      await channel.closeEvents();
    }
  }
}

class _Peer with _Events implements SignalingPeer {
  _Peer(this.network, this.id);

  final _Network network;
  @override
  final String id;
  final attached = <_Channel>[];
  bool disposed = false;
  @override
  bool open = false;
  @override
  bool get disconnected => !open;
  @override
  String get service => 'details-test';
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
    final owner = network.registered[id];
    if (owner != null && !identical(owner, this) && !owner.disposed) {
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
    if (!open || disposed) throw StateError('Peer not registered');
    final outgoing = _Channel(target);
    network.channels.add(outgoing);
    attached.add(outgoing);
    final remote = network.registered[target];
    if (remote == null || !remote.open || remote.disposed) return outgoing;
    final incoming = _Channel(id);
    network.channels.add(incoming);
    remote.attached.add(incoming);
    outgoing.other = incoming;
    incoming.other = outgoing;
    scheduleMicrotask(() {
      if (remote.disposed) return;
      remote.emit<RoomChannel>('connection', incoming);
      scheduleMicrotask(() {
        if (incoming.disposed || outgoing.disposed) return;
        incoming.openChannel();
        outgoing.openChannel();
      });
    });
    return outgoing;
  }

  void accept(_Channel channel) {
    network.channels.add(channel);
    attached.add(channel);
    emit<RoomChannel>('connection', channel);
  }

  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    open = false;
    if (identical(network.registered[id], this)) network.registered.remove(id);
    for (final channel in attached) {
      channel.dispose();
    }
  }
}

class _Channel with _Events implements RoomChannel {
  _Channel(this.peer);

  @override
  final String peer;
  @override
  bool open = false;
  @override
  bool disposed = false;
  _Channel? other;
  final sent = <Map<String, dynamic>>[];
  @override
  String get service => 'details-test';
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

  void receive(Map<String, dynamic> value) => emit<Object?>('data', value);

  @override
  Future<void> send(Map<String, dynamic> data) async {
    if (!open || disposed) throw StateError('Channel not open');
    final detached = (jsonDecode(jsonEncode(data)) as Map)
        .cast<String, dynamic>();
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
    if (disposed) return;
    disposed = true;
    open = false;
    final remote = other;
    if (remote != null && !remote.disposed) {
      scheduleMicrotask(() {
        if (remote.disposed) return;
        remote.open = false;
        remote.emit<void>('close', null);
      });
    }
  }
}

class _Store extends MemoryRoomStore {
  final changes = StreamController<void>.broadcast(sync: true);
  final batches = <List<Map<String, dynamic>>>[];
  final authoredBatches = <List<Map<String, dynamic>>>[];
  Completer<void>? appendGate;
  bool failAppend = false;
  int membershipCalls = 0;

  @override
  Stream<void> watchHistory(String roomId) => changes.stream;

  @override
  Future<void> appendHistory(
    String roomId,
    List<Map<String, dynamic>> operations,
  ) {
    batches.add(operations);
    if (failAppend) return Future<void>.error(StateError('Disk full'));
    final gate = appendGate;
    final saved = gate == null
        ? super.appendHistory(roomId, operations)
        : gate.future.then((_) => super.appendHistory(roomId, operations));
    return saved.then((_) {
      if (!changes.isClosed) changes.add(null);
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
    return super.appendAuthoredHistory(roomId, drafts);
  }

  @override
  Future<void> saveMembership(String roomId) {
    membershipCalls++;
    return super.saveMembership(roomId);
  }
}

class _Tabs with _Events implements RoomTabs {
  _Tabs({this.isLeader = false});

  @override
  final bool isLeader;
  final published = <RoomTabState>[];
  bool disposed = false;
  @override
  Stream<void> get onRoleChanged => on<void>('role');
  @override
  Stream<RoomTabState> get onState => on<RoomTabState>('state');
  @override
  Future<void> start() async {}
  @override
  void requestState() {}
  @override
  void publish(RoomTabState state) => published.add(state);
  void receive(RoomTabState state) => emit<RoomTabState>('state', state);
  @override
  void dispose() => disposed = true;
}

RoomEdit _edit(
  String id,
  String author,
  int clock,
  String text, {
  RoomEditKind kind = RoomEditKind.text,
}) => RoomEdit(
  id: id,
  author: author,
  clock: clock,
  createdAt: clock,
  text: text,
  kind: kind,
);

List<RoomMessage> _messages(_Network network) => [
  for (final channel in network.channels) ..._channelMessages(channel),
];

List<RoomMessage> _channelMessages(_Channel channel) {
  final decoder = RoomMessageDecoder(roomId: _roomId);
  return [
    for (final packet in channel.sent)
      if (decoder.decode(packet).message case final message?) message,
  ];
}

Set<String> _online(RoomSession room) => {
  for (final participant in room.participants)
    if (participant.isOnline) participant.actorId,
};

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump();
  }
}

Future<void> _settleRoom(WidgetTester tester) async {
  await _settle(tester);
  await tester.pump(const Duration(seconds: 1));
  await _settle(tester);
}

void main() {
  late _Network network;
  late List<RoomSession> sessions;
  late Set<_Store> stores;
  late List<_Tabs> tabs;

  setUp(() {
    network = _Network();
    sessions = [];
    stores = {};
    tabs = [];
  });

  _Store store() {
    final result = _Store();
    stores.add(result);
    return result;
  }

  RoomSession session({
    required String actor,
    String? name,
    _Store? storage,
    bool member = true,
    bool follower = false,
    bool newlyCreated = false,
    _Tabs? localTabs,
  }) {
    if (localTabs != null) tabs.add(localTabs);
    final result = RoomSession(
      roomId: _roomId,
      actorId: actor,
      participantName: name,
      store: storage ?? store(),
      existingMember: member,
      preferExistingHost: follower,
      newlyCreated: newlyCreated,
      peerFactory: network.create,
      roomTabs: localTabs,
    );
    sessions.add(result);
    return result;
  }

  void detailsTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        for (final room in sessions) {
          room.dispose();
        }
        await _settle(tester);
      }
    });
  }

  tearDown(() async {
    for (final room in sessions) {
      room.dispose();
    }
    await network.close();
    for (final tab in tabs) {
      tab.dispose();
      await tab.closeEvents();
    }
    for (final storage in stores) {
      await storage.changes.close();
    }
  });

  detailsTest(
    'metadata starts appending synchronously and failed saves stay nondurable',
    (tester) async {
      final storage = store()..appendGate = Completer<void>();
      final history = RoomHistory(
        roomId: _roomId,
        actorId: 'alice',
        store: storage,
        existingMember: false,
      );
      addTearDown(history.dispose);
      final savedName = history.setParticipantName('  Алиса  ');
      expect(storage.authoredBatches, hasLength(1));
      expect(storage.authoredBatches.single.single['kind'], 'participantName');
      expect(history.participantNames, {'alice': 'Алиса'});
      expect(history.durableHistory, isEmpty);
      expect(history.saving, isTrue);
      storage.appendGate!.complete();
      final name = await savedName;
      expect(name!.kind, RoomEditKind.participantName);
      expect(name.authorSequence, 1);
      expect(history.durableHistory, [name]);

      storage.appendGate = null;
      storage.failAppend = true;
      final savedTitle = history.renameRoom('Семейный круг');
      expect(storage.authoredBatches, hasLength(2));
      expect(history.roomName, 'Семейный круг');
      expect(await savedTitle, isNull);
      expect(history.durableHistory, [name]);
      expect(history.error, contains('Disk full'));
      expect(history.text, isEmpty);
      storage.failAppend = false;
      await history.flush();
      expect(history.durableHistory.map((edit) => edit.kind), [
        RoomEditKind.participantName,
        RoomEditKind.roomName,
      ]);
      expect(history.durableHistory.last.authorSequence, 2);
      expect(history.durableHistory.last.authorPrevious, name.id);
      expect(history.error, isNull);
    },
  );

  detailsTest(
    'room rename is optimistic locally but only durable metadata leaves the session',
    (tester) async {
      final hostStore = store();
      final host = session(
        actor: 'alice',
        name: 'Алиса',
        storage: hostStore,
        newlyCreated: true,
      );
      await host.start();
      await _settle(tester);
      final guest = session(
        actor: 'bob',
        name: 'Борис',
        member: false,
        follower: true,
      );
      await guest.start();
      await _settleRoom(tester);
      expect(guest.joined, isTrue);
      await host.edit('Заметка остаётся текстом');
      await _settle(tester);
      expect(guest.text, host.text);

      hostStore.appendGate = Completer<void>();
      final renamed = host.renameRoom('  Семейный круг  ');
      expect(hostStore.authoredBatches.last.single['kind'], 'roomName');
      expect(host.roomName, 'Семейный круг');
      expect(host.saving, isTrue);
      await _settle(tester);
      expect(guest.roomName, 'Комната');
      expect(
        _messages(network)
            .expand((message) => message.history)
            .where((edit) => edit.kind == RoomEditKind.roomName),
        isEmpty,
      );
      hostStore.appendGate!.complete();
      await renamed;
      await _settle(tester);
      expect(guest.roomName, 'Семейный круг');
      expect([host.text, guest.text], everyElement('Заметка остаётся текстом'));
      expect(
        _messages(network)
            .expand((message) => message.history)
            .where((edit) => edit.kind == RoomEditKind.roomName),
        isNotEmpty,
      );
    },
  );

  detailsTest(
    'failed first join creates neither membership nor a durable participant profile',
    (tester) async {
      final storage = store();
      final guest = session(
        actor: 'bob',
        name: 'Борис',
        storage: storage,
        member: false,
        follower: true,
      );
      await guest.start();
      await _settle(tester);
      await tester.pump(const Duration(seconds: 31));
      await _settle(tester);
      expect(guest.joined, isFalse);
      expect(guest.participantName, isNull);
      expect(guest.participants, isEmpty);
      expect(storage.membershipCalls, 0);
      expect(await storage.hasMembership(_roomId), isFalse);
      expect(await storage.loadHistory(_roomId), isEmpty);
      expect(storage.batches, isEmpty);
    },
  );

  detailsTest(
    'non-editing admission saves the name and keeps the roster after an offline reopen',
    (tester) async {
      final host = session(actor: 'alice', name: 'Алиса', newlyCreated: true);
      await host.start();
      await _settle(tester);
      final storage = store();
      final guest = session(
        actor: 'bob',
        name: 'Борис',
        storage: storage,
        member: false,
        follower: true,
      );
      await guest.start();
      await _settleRoom(tester);
      expect(guest.joined, isTrue);
      expect(storage.membershipCalls, 1);
      expect(await storage.hasMembership(_roomId), isTrue);
      expect(guest.participantName, 'Борис');
      expect(
        host.participants.map((participant) => participant.name),
        unorderedEquals(['Алиса', 'Борис']),
      );
      expect(
        guest.changes.where((edit) => edit.kind == RoomEditKind.text),
        isEmpty,
      );
      expect(guest.text, isEmpty);
      host.dispose();
      guest.dispose();
      await _settle(tester);
      network.autoRegister = false;
      final reopened = session(actor: 'bob', storage: storage);
      await reopened.start();
      expect(reopened.participantName, 'Борис');
      expect(
        reopened.participants.map((participant) => participant.name),
        unorderedEquals(['Алиса', 'Борис']),
      );
      expect(
        reopened.participants
            .where((participant) => participant.isSelf)
            .single
            .actorId,
        'bob',
      );
      expect(
        reopened.participants.every((participant) => !participant.isOnline),
        isTrue,
      );
      expect(reopened.otherOnlineCount, 0);
      expect(reopened.networkAvailable, isFalse);
    },
  );

  detailsTest(
    'explicit empty entry clears only own alias and omitted entry preserves the clear after reload',
    (tester) async {
      network.autoRegister = false;
      final storage = store();
      final original = [
        _edit(
          'alice-alias',
          'alice',
          1,
          'Алиса',
          kind: RoomEditKind.participantName,
        ),
        _edit(
          'bob-alias',
          'bob',
          2,
          'Борис',
          kind: RoomEditKind.participantName,
        ),
      ];
      await storage.appendHistory(
        _roomId,
        original.map((edit) => edit.toJson()).toList(),
      );
      final room = session(actor: 'alice', name: '  ', storage: storage);
      await room.start();
      expect(room.participantName, '');
      expect(room.participants.singleWhere((p) => p.isSelf).name, 'Аноним');
      expect(
        room.participants.singleWhere((p) => p.actorId == 'bob').name,
        'Борис',
      );
      final clears = room.changes
          .where(
            (edit) =>
                edit.author == 'alice' &&
                edit.kind == RoomEditKind.participantName &&
                edit.text.isEmpty,
          )
          .toList();
      expect(clears, hasLength(1));
      expect(clears.single.authorSequence, 1);
      for (final old in original) {
        expect(
          room.changes.singleWhere((edit) => edit.id == old.id).toJson(),
          old.toJson(),
        );
      }
      final inventory = roomHistoryInventory(room.changes);
      room.dispose();
      await _settle(tester);
      final reopened = session(actor: 'alice', storage: storage);
      await reopened.start();
      expect(reopened.participantName, '');
      expect(reopened.participants.singleWhere((p) => p.isSelf).name, 'Аноним');
      expect(roomHistoryInventory(reopened.changes), inventory);
      expect(
        roomHistoryInventory(
          decodeRoomHistory(await storage.loadHistory(_roomId)),
        ),
        inventory,
      );
    },
  );

  detailsTest(
    'mixed-kind divergent histories complete the checkpoint union without changing text projection',
    (tester) async {
      final hostStore = store();
      final guestStore = store();
      final hostEdits = [
        _edit('host-text', 'alice', 10, 'Старый текст'),
        _edit(
          'alice-name',
          'alice',
          1,
          'Алиса',
          kind: RoomEditKind.participantName,
        ),
        _edit('old-title', 'alice', 20, 'Родня', kind: RoomEditKind.roomName),
      ];
      final guestEdits = [
        _edit('guest-text', 'bob', 15, 'Новый текст'),
        _edit(
          'bob-name',
          'bob',
          2,
          'Борис',
          kind: RoomEditKind.participantName,
        ),
        _edit(
          'new-title',
          'bob',
          30,
          'Семейный круг',
          kind: RoomEditKind.roomName,
        ),
      ];
      await hostStore.appendHistory(
        _roomId,
        hostEdits.map((edit) => edit.toJson()).toList(),
      );
      await guestStore.appendHistory(
        _roomId,
        guestEdits.map((edit) => edit.toJson()).toList(),
      );
      final host = session(actor: 'alice', name: 'Алиса', storage: hostStore);
      await host.start();
      await _settle(tester);
      final guest = session(
        actor: 'bob',
        name: 'Борис',
        storage: guestStore,
        follower: true,
      );
      await guest.start();
      await _settleRoom(tester);
      final union = roomHistoryInventory([...hostEdits, ...guestEdits]);
      for (final room in [host, guest]) {
        expect(room.initialSyncComplete, isTrue);
        expect(room.text, 'Новый текст');
        expect(room.roomName, 'Семейный круг');
        expect(roomHistoryInventory(room.changes), union);
        expect(room.changes, hasLength(6));
      }
      for (final storage in [hostStore, guestStore]) {
        expect(
          roomHistoryInventory(
            decodeRoomHistory(await storage.loadHistory(_roomId)),
          ),
          union,
        );
      }
      final messages = _messages(network);
      expect(
        messages.where(
          (message) =>
              message.type == RoomMessageType.checkpoint &&
              message.inventory?.length == 6,
        ),
        isNotEmpty,
      );
      expect(
        messages.where(
          (message) =>
              message.type == RoomMessageType.syncAck &&
              message.roomReady == true,
        ),
        isNotEmpty,
      );
      expect(
        messages
            .where(
              (message) =>
                  message.type == RoomMessageType.hello ||
                  message.type == RoomMessageType.welcome,
            )
            .every((message) => message.roomMetadata),
        isTrue,
      );
    },
  );

  detailsTest(
    'legacy welcome is rejected before import and the first hello never leaks metadata',
    (tester) async {
      final storage = store();
      final known = [
        _edit('known-text', 'alice', 1, 'Сохранённый текст'),
        _edit(
          'known-name',
          'alice',
          100,
          'Алиса',
          kind: RoomEditKind.participantName,
        ),
        _edit(
          'known-title',
          'alice',
          200,
          'Наша семья',
          kind: RoomEditKind.roomName,
        ),
      ];
      await storage.appendHistory(
        _roomId,
        known.map((edit) => edit.toJson()).toList(),
      );
      final room = session(
        actor: 'alice',
        name: 'Алиса',
        storage: storage,
        follower: true,
      );
      await room.start();
      await _settle(tester);
      final channel = network.channels.single;
      channel.openChannel();
      await _settle(tester);
      final hello = _channelMessages(
        channel,
      ).singleWhere((message) => message.type == RoomMessageType.hello);
      expect(hello.roomMetadata, isTrue);
      expect(
        hello.history.every((edit) => edit.kind == RoomEditKind.text),
        isTrue,
      );
      expect(hello.history, isEmpty);
      expect(jsonEncode(hello.toJson()), isNot(contains('Наша семья')));
      expect(jsonEncode(hello.toJson()), isNot(contains('Алиса')));
      channel.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.welcome,
          actor: 'legacy',
          history: [_edit('legacy-text', 'legacy', 1000, 'Не импортировать')],
          online: 2,
          hosting: true,
        ).toJson(),
      );
      await _settle(tester);
      expect(channel.disposed, isTrue);
      expect(room.text, 'Сохранённый текст');
      expect(roomHistoryInventory(room.changes), roomHistoryInventory(known));
      expect(
        roomHistoryInventory(
          decodeRoomHistory(await storage.loadHistory(_roomId)),
        ),
        roomHistoryInventory(known),
      );
      expect(
        _channelMessages(channel)
            .expand((message) => message.history)
            .every((edit) => edit.kind == RoomEditKind.text),
        isTrue,
      );
    },
  );

  detailsTest(
    'fresh named entry and named host both reject legacy admission before persisting text',
    (tester) async {
      final guestStore = store();
      final guest = session(
        actor: 'bob',
        name: 'Борис',
        storage: guestStore,
        member: false,
        follower: true,
      );
      await guest.start();
      await _settle(tester);
      final outbound = network.channels.single;
      outbound.openChannel();
      await _settle(tester);
      outbound.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.welcome,
          actor: 'legacy-host',
          history: [
            _edit('legacy-welcome', 'legacy-host', 1000, 'Не сохранять'),
          ],
          online: 2,
          hosting: true,
        ).toJson(),
      );
      await _settle(tester);
      expect(guest.joined, isFalse);
      expect(guestStore.membershipCalls, 0);
      expect(await guestStore.loadHistory(_roomId), isEmpty);
      expect(
        _channelMessages(outbound).expand((message) => message.history),
        isEmpty,
      );

      final hostStore = store();
      final host = session(
        actor: 'alice',
        name: 'Алиса',
        storage: hostStore,
        newlyCreated: true,
      );
      await host.start();
      await _settle(tester);
      final peer = network.peers.singleWhere(
        (peer) => peer.id == host.hostAlias && !peer.disposed,
      );
      final incoming = _Channel('legacy-client');
      peer.accept(incoming);
      incoming.openChannel();
      incoming.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.hello,
          actor: 'legacy-client',
          history: [
            _edit('legacy-hello', 'legacy-client', 1000, 'Не сохранять'),
          ],
        ).toJson(),
      );
      await _settle(tester);
      expect(incoming.disposed, isTrue);
      expect(host.text, isEmpty);
      expect(
        host.changes.every((edit) => edit.kind == RoomEditKind.participantName),
        isTrue,
      );
      expect(incoming.sent, isEmpty);
    },
  );

  detailsTest(
    'star rosters track exact online actors and deduplicate same-actor channels',
    (tester) async {
      final host = session(actor: 'alice', name: 'Алиса', newlyCreated: true);
      await host.start();
      await _settle(tester);
      final bob = session(
        actor: 'bob',
        name: 'Борис',
        member: false,
        follower: true,
      );
      await bob.start();
      await _settleRoom(tester);
      final carol = session(
        actor: 'carol',
        name: 'Вера',
        member: false,
        follower: true,
      );
      await carol.start();
      await _settleRoom(tester);
      final duplicate = session(
        actor: 'bob',
        name: 'Борис',
        member: false,
        follower: true,
      );
      await duplicate.start();
      await _settleRoom(tester);
      for (final room in [host, bob, carol, duplicate]) {
        expect(_online(room), {'alice', 'bob', 'carol'});
        expect(room.otherOnlineCount, 2);
        expect(room.participants, hasLength(3));
        expect(
          room.participants.where((participant) => participant.isSelf),
          hasLength(1),
        );
      }
      expect(() => host.participants.clear(), throwsUnsupportedError);
      final presences = _messages(
        network,
      ).where((message) => message.type == RoomMessageType.presence);
      expect(
        presences.any(
          (message) =>
              message.onlineActors?.toSet().containsAll({
                'alice',
                'bob',
                'carol',
              }) ==
              true,
        ),
        isTrue,
      );
      for (final message in presences) {
        expect(message.onlineActors, hasLength(message.online!));
        expect(message.onlineActors!.toSet(), hasLength(message.online!));
      }
      duplicate.dispose();
      await _settle(tester);
      expect(_online(host), {'alice', 'bob', 'carol'});
      expect(_online(carol), {'alice', 'bob', 'carol'});
      bob.dispose();
      await _settle(tester);
      for (final room in [host, carol]) {
        expect(_online(room), {'alice', 'carol'});
        expect(room.otherOnlineCount, 1);
        expect(
          room.participants
              .singleWhere((participant) => participant.actorId == 'bob')
              .isOnline,
          isFalse,
        );
        expect(
          room.participants
              .singleWhere((participant) => participant.actorId == 'bob')
              .name,
          'Борис',
        );
      }
      carol.dispose();
      await _settle(tester);
      expect(_online(host), {'alice'});
      expect(host.otherOnlineCount, 0);
      expect(host.participants, hasLength(3));
    },
  );

  detailsTest(
    'local tab verifies metadata inventory before trusting roster and clears online state offline',
    (tester) async {
      final storage = store();
      final edits = [
        _edit('text', 'alice', 1, 'Заметка'),
        _edit(
          'alice-name',
          'alice',
          2,
          'Алиса',
          kind: RoomEditKind.participantName,
        ),
        _edit(
          'bob-name',
          'bob',
          3,
          'Борис',
          kind: RoomEditKind.participantName,
        ),
        _edit('title', 'alice', 100, 'Родня', kind: RoomEditKind.roomName),
      ];
      final missing = _edit(
        'carol-name',
        'carol',
        101,
        'Вера',
        kind: RoomEditKind.participantName,
      );
      await storage.appendHistory(
        _roomId,
        edits.map((edit) => edit.toJson()).toList(),
      );
      final localTabs = _Tabs();
      final room = session(
        actor: 'alice',
        storage: storage,
        localTabs: localTabs,
      );
      await room.start();
      expect(network.peers, isEmpty);
      final inventory = roomHistoryInventory([...edits, missing]);
      final onlineState = RoomTabState(
        roomId: _roomId,
        actorId: 'alice',
        onlineCount: 2,
        onlineActors: ['alice', 'bob'],
        networkAvailable: true,
        initialSyncComplete: true,
        localCopyOpened: false,
        status: 'Онлайн · участников: 2',
        initialSyncStatus: 'История комнаты проверена',
        inventory: inventory,
      );
      localTabs.receive(onlineState);
      await tester.pump(const Duration(milliseconds: 40));
      await _settle(tester);
      expect(room.initialSyncComplete, isFalse);
      expect(room.networkAvailable, isFalse);
      expect(room.otherOnlineCount, 0);
      await storage.appendHistory(_roomId, [missing.toJson()]);
      localTabs.receive(onlineState);
      await tester.pump(const Duration(milliseconds: 40));
      await _settle(tester);
      expect(room.initialSyncComplete, isTrue);
      expect(room.networkAvailable, isTrue);
      expect(_online(room), {'alice', 'bob'});
      expect(room.otherOnlineCount, 1);
      expect(room.roomName, 'Родня');
      expect(room.text, 'Заметка');
      expect(room.participants, hasLength(3));
      expect(
        room.participants
            .singleWhere((participant) => participant.actorId == 'carol')
            .isOnline,
        isFalse,
      );
      localTabs.receive(
        RoomTabState(
          roomId: _roomId,
          actorId: 'alice',
          onlineCount: 1,
          onlineActors: const [],
          networkAvailable: false,
          initialSyncComplete: true,
          localCopyOpened: false,
          status: 'Локально · сеть недоступна',
          initialSyncStatus: 'История комнаты проверена',
          inventory: inventory,
        ),
      );
      await tester.pump(const Duration(milliseconds: 40));
      await _settle(tester);
      expect(room.networkAvailable, isFalse);
      expect(_online(room), isEmpty);
      expect(room.otherOnlineCount, 0);
      expect(room.participants, hasLength(3));
      expect(room.initialSyncComplete, isTrue);
    },
  );

  detailsTest(
    'local tab revokes stale online claims despite an unsaved edit and unverified leader inventory',
    (tester) async {
      final storage = store();
      final edits = [
        _edit('text', 'alice', 1, 'Сохранённая заметка'),
        _edit(
          'alice-name',
          'alice',
          2,
          'Алиса',
          kind: RoomEditKind.participantName,
        ),
        _edit(
          'bob-name',
          'bob',
          3,
          'Борис',
          kind: RoomEditKind.participantName,
        ),
        _edit(
          'carol-name',
          'carol',
          4,
          'Вера',
          kind: RoomEditKind.participantName,
        ),
      ];
      await storage.appendHistory(
        _roomId,
        edits.map((edit) => edit.toJson()).toList(),
      );
      final localTabs = _Tabs();
      final room = session(
        actor: 'alice',
        storage: storage,
        localTabs: localTabs,
      );
      await room.start();
      final missing = _edit(
        'missing-title',
        'carol',
        100,
        'Родня',
        kind: RoomEditKind.roomName,
      );
      final verifiedInventory = roomHistoryInventory(edits);
      final pendingInventory = roomHistoryInventory([...edits, missing]);
      RoomTabState state(
        List<String> actors, {
        bool network = true,
        bool pending = true,
      }) => RoomTabState(
        roomId: _roomId,
        actorId: 'alice',
        onlineCount: network ? actors.length : 1,
        onlineActors: actors,
        networkAvailable: network,
        initialSyncComplete: true,
        localCopyOpened: false,
        status: network ? 'Онлайн' : 'Локально · сеть недоступна',
        initialSyncStatus: 'История комнаты проверена',
        inventory: pending ? pendingInventory : verifiedInventory,
      );
      localTabs.receive(state(['alice', 'bob'], pending: false));
      await tester.pump(const Duration(milliseconds: 40));
      await _settle(tester);
      expect(_online(room), {'alice', 'bob'});
      expect(room.networkAvailable, isTrue);
      expect(room.initialSyncComplete, isTrue);

      storage.failAppend = true;
      await room.edit('Несохранённая заметка');
      expect(room.storageError, contains('Disk full'));
      expect(room.text, 'Несохранённая заметка');
      expect(await storage.loadHistory(_roomId), hasLength(edits.length));
      var notifications = 0;
      room.addListener(() => notifications++);
      final beforeRemoval = notifications;
      localTabs.receive(state(['alice', 'carol']));
      expect(
        notifications,
        greaterThan(beforeRemoval),
        reason: 'revocation must repaint before storage verification',
      );
      expect(_online(room), {
        'alice',
      }, reason: 'Bob is revoked but Carol has no durable inventory proof');
      expect(room.onlineCount, 1);
      await tester.pump(const Duration(milliseconds: 40));
      await _settle(tester);
      expect(_online(room), {'alice'});
      expect(room.storageError, contains('Disk full'));
      expect(
        room.roomName,
        'Комната',
        reason: 'a beacon never imports missing metadata',
      );

      final beforeOffline = notifications;
      localTabs.receive(state(const [], network: false));
      expect(notifications, greaterThan(beforeOffline));
      expect(
        room.networkAvailable,
        isFalse,
        reason: 'offline revocation cannot wait on an unrelated failed append',
      );
      expect(_online(room), isEmpty);
      expect(room.otherOnlineCount, 0);
      expect(room.onlineCount, 1);
      await tester.pump(const Duration(milliseconds: 40));
      await _settle(tester);
      expect(room.networkAvailable, isFalse);
      expect(room.storageError, contains('Disk full'));
      expect(room.participants, hasLength(3));
      expect(
        room.participants
            .singleWhere((participant) => participant.actorId == 'bob')
            .isOnline,
        isFalse,
      );
      expect(
        room.participants
            .singleWhere((participant) => participant.actorId == 'carol')
            .isOnline,
        isFalse,
      );

      localTabs.receive(state(['alice', 'carol']));
      await tester.pump(const Duration(milliseconds: 40));
      await _settle(tester);
      expect(_online(room).contains('carol'), isFalse);
      expect(room.storageError, contains('Disk full'));
      storage.failAppend = false;
      await room.flush();
      localTabs.receive(state(['alice', 'carol']));
      await tester.pump(const Duration(milliseconds: 40));
      await _settle(tester);
      expect(room.storageError, isNull);
      expect(
        _online(room).contains('carol'),
        isFalse,
        reason:
            'saving the local draft is not proof of the missing leader operation',
      );
      await storage.appendHistory(_roomId, [missing.toJson()]);
      localTabs.receive(state(['alice', 'carol']));
      await tester.pump(const Duration(milliseconds: 40));
      await _settle(tester);
      expect(room.networkAvailable, isTrue);
      expect(_online(room), {'alice', 'carol'});
      expect(room.otherOnlineCount, 1);
      expect(room.onlineCount, 2);
      expect(room.roomName, 'Родня');
      expect(room.text, 'Несохранённая заметка');
    },
  );

  detailsTest(
    'local leader publishes typed inventory and roster, never metadata values as a tab history',
    (tester) async {
      final localTabs = _Tabs(isLeader: true);
      final host = session(
        actor: 'alice',
        name: 'Алиса',
        newlyCreated: true,
        localTabs: localTabs,
      );
      await host.start();
      await _settle(tester);
      final guest = session(
        actor: 'bob',
        name: 'Борис',
        member: false,
        follower: true,
      );
      await guest.start();
      await _settleRoom(tester);
      await host.renameRoom('Родня');
      await tester.pump(const Duration(milliseconds: 40));
      await _settle(tester);
      final state = localTabs.published.last;
      expect(state.networkAvailable, isTrue);
      expect(state.onlineActors, unorderedEquals(['alice', 'bob']));
      expect(state.inventory, roomHistoryInventory(host.changes));
      expect(
        host.changes.where((edit) => edit.kind == RoomEditKind.roomName),
        hasLength(1),
      );
      expect(state.toJson().containsKey('history'), isFalse);
      expect(state.toJson().containsKey('text'), isFalse);
      expect(state.toJson().containsKey('roomName'), isFalse);
      expect(state.toJson().containsKey('participantNames'), isFalse);
      expect(jsonEncode(state.toJson()), isNot(contains('Родня')));
      expect(jsonEncode(state.toJson()), isNot(contains('Алиса')));
    },
  );
}
