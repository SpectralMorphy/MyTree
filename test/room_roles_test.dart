import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/local/room_tabs.dart';
import 'package:mytree_webrtc_demo/room_document.dart';
import 'package:mytree_webrtc_demo/room_identity.dart';
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
  String get service => 'roles-test';
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
  String get service => 'roles-test';
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
  bool failMembership = false;
  bool failFlush = false;
  int membershipCalls = 0;
  void Function(List<Map<String, dynamic>>)? beforeMembership;

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
  Future<void> saveMembership(String roomId) async {
    membershipCalls++;
    beforeMembership?.call(await loadHistory(roomId));
    if (failMembership) throw StateError('Membership failed');
    await super.saveMembership(roomId);
  }

  @override
  Future<void> flush() async {
    if (failFlush) throw StateError('Flush failed');
  }
}

class _Tabs with _Events implements RoomTabs {
  @override
  bool get isLeader => false;
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
  String actor,
  int clock,
  String value, {
  RoomEditKind kind = RoomEditKind.text,
  String? target,
}) => RoomEdit(
  id: id,
  author: actor,
  clock: clock,
  createdAt: clock,
  text: value,
  kind: kind,
  targetActor: target,
);

RoomEdit _role(
  String id,
  String target,
  RoomRole role, {
  String actor = 'alice',
  int clock = 1,
}) => _edit(
  id,
  actor,
  clock,
  role.name,
  kind: RoomEditKind.participantRole,
  target: target,
);

List<RoomMessage> _channelMessages(_Channel channel) {
  final decoder = RoomMessageDecoder(roomId: _roomId);
  return [
    for (final packet in channel.sent)
      if (decoder.decode(packet).message case final message?) message,
  ];
}

List<RoomEdit> _sentRoles(_Network network) => [
  for (final channel in network.channels)
    for (final message in _channelMessages(channel))
      ...message.history.where(
        (edit) => edit.kind == RoomEditKind.participantRole,
      ),
];

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 16; i++) {
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
    RoomRole? role,
    _Store? storage,
    bool member = true,
    bool follower = false,
    bool creator = false,
    _Tabs? localTabs,
  }) {
    if (localTabs != null) tabs.add(localTabs);
    final result = RoomSession(
      roomId: _roomId,
      actorId: actor,
      participantName: name,
      invitationRole: role,
      store: storage ?? store(),
      existingMember: member,
      preferExistingHost: follower,
      newlyCreated: creator,
      peerFactory: network.create,
      roomTabs: localTabs,
    );
    sessions.add(result);
    return result;
  }

  void rolesTest(String name, Future<void> Function(WidgetTester) body) {
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

  for (final inviteRole in RoomRole.values) {
    rolesTest(
      'fresh ${inviteRole.name} saves profile and role before membership',
      (tester) async {
        final host = session(
          actor: 'alice',
          name: 'Алиса',
          role: RoomRole.editor,
          creator: true,
        );
        await host.start();
        await _settle(tester);
        expect(host.ownRole, RoomRole.editor);
        final storage = store();
        RoomDocument? membershipSnapshot;
        storage.beforeMembership = (history) {
          membershipSnapshot = RoomDocument()
            ..merge(decodeRoomHistory(history));
        };
        final admitted = session(
          actor: 'bob',
          name: 'Борис',
          role: inviteRole,
          storage: storage,
          member: false,
          follower: true,
        );
        await admitted.start();
        expect(admitted.joined, isFalse);
        expect(admitted.canEdit, isFalse);
        expect(storage.membershipCalls, 0);
        await _settleRoom(tester);
        expect(membershipSnapshot, isNotNull);
        expect(membershipSnapshot!.participantNames['bob'], 'Борис');
        expect(membershipSnapshot!.participantRoles['bob'], inviteRole);
        expect(admitted.joined, isTrue);
        expect(admitted.editable, isTrue);
        expect(admitted.canEdit, inviteRole == RoomRole.editor);
        expect(admitted.ownRole, inviteRole);
        expect(admitted.initialSyncComplete, isTrue);
        expect(
          host.participants.singleWhere((p) => p.actorId == 'bob').role,
          inviteRole,
        );
        expect(await storage.hasMembership(_roomId), isTrue);
        final ownProfiles = decodeRoomHistory(
          await storage.loadHistory(_roomId),
        ).where((edit) => edit.author == 'bob').toList();
        expect(
          ownProfiles.map((edit) => edit.kind),
          containsAll([
            RoomEditKind.participantName,
            RoomEditKind.participantRole,
          ]),
        );
        final orderedProfiles = validateAuthorHistory(ownProfiles);
        expect(orderedProfiles.map((edit) => edit.authorSequence), [1, 2]);
        expect(orderedProfiles.last.authorPrevious, orderedProfiles.first.id);
        expect(
          storage.batches
              .expand((batch) => batch)
              .where((edit) => edit['author'] == 'bob')
              .map((edit) => edit['id']),
          unorderedEquals(ownProfiles.map((edit) => edit.id)),
          reason: 'Both authored profile writes must commit before membership',
        );
        expect(
          _sentRoles(network).any((edit) => edit.targetActor == 'bob'),
          isTrue,
        );
        final ownRoleCount = admitted.changes
            .where(
              (e) =>
                  e.kind == RoomEditKind.participantRole &&
                  e.targetActor == 'bob',
            )
            .length;
        await admitted.retry();
        await _settleRoom(tester);
        expect(
          admitted.changes.where(
            (e) =>
                e.kind == RoomEditKind.participantRole &&
                e.targetActor == 'bob',
          ),
          hasLength(ownRoleCount),
        );
      },
    );
  }

  for (final name in <String?>[null, '', '  ']) {
    rolesTest(
      'optional name ${name == null
          ? 'omitted'
          : name.isEmpty
          ? 'empty'
          : 'whitespace'} creates and admits with unchanged editor and guest permissions',
      (tester) async {
        final host = session(
          actor: 'alice',
          name: name,
          role: RoomRole.editor,
          creator: true,
        );
        await host.start();
        await _settle(tester);
        expect(host.canEdit, isTrue);
        expect(host.participantName, name == null ? null : '');
        expect(host.participants.single.name, 'Аноним');
        final storage = store();
        final guest = session(
          actor: 'bob',
          name: name,
          role: RoomRole.guest,
          storage: storage,
          member: false,
          follower: true,
        );
        await guest.start();
        await _settleRoom(tester);
        expect(guest.joined, isTrue);
        expect(guest.initialSyncComplete, isTrue);
        expect(guest.ownRole, RoomRole.guest);
        expect(guest.canEdit, isFalse);
        expect(guest.canBindToPerson, isFalse);
        expect(guest.canUnbindFromPerson, isFalse);
        expect(guest.participantName, name == null ? null : '');
        expect(guest.participants.map((p) => p.name), everyElement('Аноним'));
        final ownNames = guest.changes
            .where(
              (edit) =>
                  edit.author == 'bob' &&
                  edit.kind == RoomEditKind.participantName,
            )
            .toList();
        expect(ownNames, hasLength(name == null ? 0 : 1));
        if (ownNames.isNotEmpty) expect(ownNames.single.text, '');
        expect(await storage.hasMembership(_roomId), isTrue);
        guest.dispose();
        host.dispose();
        await _settle(tester);
        network.autoRegister = false;
        final reopened = session(actor: 'bob', storage: storage);
        await reopened.start();
        expect(reopened.ownRole, RoomRole.guest);
        expect(reopened.canEdit, isFalse);
        expect(reopened.participantName, name == null ? null : '');
        expect(
          reopened.participants.map((p) => p.name),
          everyElement('Аноним'),
        );
      },
    );
  }

  rolesTest('failed first entry never saves or publishes own profile or role', (
    tester,
  ) async {
    final storage = store();
    final room = session(
      actor: 'bob',
      name: 'Борис',
      role: RoomRole.guest,
      storage: storage,
      member: false,
      follower: true,
    );
    await room.start();
    await _settle(tester);
    await tester.pump(const Duration(seconds: 31));
    await _settle(tester);
    expect(room.joined, isFalse);
    expect(room.canEdit, isFalse);
    expect(room.ownRole, RoomRole.guest);
    expect(room.participantName, isNull);
    expect(room.participants, isEmpty);
    expect(storage.membershipCalls, 0);
    expect(await storage.loadHistory(_roomId), isEmpty);
    expect(_sentRoles(network), isEmpty);
  });

  rolesTest(
    'failed admission append retries immutable guest role before membership',
    (tester) async {
      final host = session(
        actor: 'alice',
        name: 'Алиса',
        role: RoomRole.editor,
        creator: true,
      );
      await host.start();
      await _settle(tester);
      final storage = store()..failAppend = true;
      final guest = session(
        actor: 'bob',
        name: 'Борис',
        role: RoomRole.guest,
        storage: storage,
        member: false,
        follower: true,
      );
      await guest.start();
      await _settle(tester);
      expect(guest.joined, isFalse);
      expect(guest.storageError, contains('Disk full'));
      expect(guest.participantName, isNull);
      expect(guest.participants, isEmpty);
      expect(storage.membershipCalls, 0);
      expect(host.participants.any((p) => p.actorId == 'bob'), isFalse);
      storage.failAppend = false;
      await guest.retry();
      await _settleRoom(tester);
      expect(guest.joined, isTrue);
      expect(guest.ownRole, RoomRole.guest);
      expect(guest.canEdit, isFalse);
      expect(guest.storageError, isNull);
      expect(
        guest.changes.where(
          (e) =>
              e.kind == RoomEditKind.participantRole && e.targetActor == 'bob',
        ),
        hasLength(1),
      );
    },
  );

  rolesTest(
    'membership failure hides durable profile and retry preserves original invite role',
    (tester) async {
      final host = session(
        actor: 'alice',
        name: 'Алиса',
        role: RoomRole.editor,
        creator: true,
      );
      await host.start();
      await _settle(tester);
      final storage = store()..failMembership = true;
      final fresh = session(
        actor: 'bob',
        name: 'Борис',
        role: RoomRole.guest,
        storage: storage,
        member: false,
        follower: true,
      );
      await fresh.start();
      await _settle(tester);
      expect(fresh.joined, isFalse);
      expect(fresh.participantName, isNull);
      expect(fresh.participants, isEmpty);
      expect(fresh.storageError, contains('Membership failed'));
      expect(await storage.hasMembership(_roomId), isFalse);
      final saved = RoomDocument()
        ..merge(decodeRoomHistory(await storage.loadHistory(_roomId)));
      expect(saved.participantRoles['bob'], RoomRole.guest);
      expect(host.participants.any((p) => p.actorId == 'bob'), isFalse);
      fresh.dispose();
      await _settle(tester);
      storage.failMembership = false;
      final retry = session(
        actor: 'bob',
        name: 'Борис',
        role: RoomRole.editor,
        storage: storage,
        member: false,
        follower: true,
      );
      await retry.start();
      await _settleRoom(tester);
      expect(retry.joined, isTrue);
      expect(retry.ownRole, RoomRole.guest);
      expect(retry.canEdit, isFalse);
      expect(
        retry.changes.where(
          (e) =>
              e.kind == RoomEditKind.participantRole && e.targetActor == 'bob',
        ),
        hasLength(1),
      );
    },
  );

  rolesTest(
    'guests cannot edit rename or promote but can save their own validated name',
    (tester) async {
      final host = session(
        actor: 'alice',
        name: 'Алиса',
        role: RoomRole.editor,
        creator: true,
      );
      await host.start();
      await _settle(tester);
      final storage = store();
      final guest = session(
        actor: 'bob',
        name: 'Борис',
        role: RoomRole.guest,
        storage: storage,
        member: false,
        follower: true,
      );
      await guest.start();
      await _settleRoom(tester);
      final before = guest.historyLength;
      await expectLater(guest.edit('Forbidden'), throwsStateError);
      await expectLater(guest.renameRoom('Forbidden'), throwsStateError);
      await expectLater(guest.promoteParticipant('bob'), throwsStateError);
      await expectLater(guest.promoteParticipant('alice'), throwsStateError);
      expect(guest.historyLength, before);
      await guest.setParticipantName('  Боб  ');
      await _settle(tester);
      expect(guest.participantName, 'Боб');
      expect(
        host.participants.singleWhere((p) => p.actorId == 'bob').name,
        'Боб',
      );
      expect(guest.canEdit, isFalse);
      await guest.setParticipantName('  ');
      await _settle(tester);
      expect(guest.participantName, '');
      expect(guest.participants.singleWhere((p) => p.isSelf).name, 'Аноним');
      expect(
        host.participants.singleWhere((p) => p.actorId == 'bob').name,
        'Аноним',
      );
      expect(guest.canEdit, isFalse);
      await guest.setParticipantName('Боб');
      await _settle(tester);
      for (final invalid in ['line\nbreak', List.filled(65, 'я').join()]) {
        await expectLater(
          guest.setParticipantName(invalid),
          throwsArgumentError,
        );
      }
      storage.failAppend = true;
      await expectLater(
        guest.setParticipantName('Не сохранено'),
        throwsStateError,
      );
      expect(guest.storageError, contains('Disk full'));
      expect(
        host.participants.singleWhere((p) => p.actorId == 'bob').name,
        'Боб',
      );
      storage.failAppend = false;
      await guest.flush();
      await _settle(tester);
      expect(
        host.participants.singleWhere((p) => p.actorId == 'bob').name,
        'Не сохранено',
      );
      await guest.retry();
      await _settleRoom(tester);
      expect(guest.participantName, 'Не сохранено');
    },
  );

  rolesTest(
    'editor promotion is durable before broadcast and grants target editing after sync',
    (tester) async {
      final hostStore = store();
      final host = session(
        actor: 'alice',
        name: 'Алиса',
        role: RoomRole.editor,
        creator: true,
        storage: hostStore,
      );
      await host.start();
      await _settle(tester);
      final targetStore = store();
      final target = session(
        actor: 'bob',
        name: 'Борис',
        role: RoomRole.guest,
        storage: targetStore,
        member: false,
        follower: true,
      );
      await target.start();
      await _settleRoom(tester);
      await expectLater(
        host.promoteParticipant('unknown'),
        throwsArgumentError,
      );
      await host.promoteParticipant('alice');
      final rolesBefore = _sentRoles(network).length;
      hostStore.appendGate = Completer<void>();
      var completed = false;
      final pending = host
          .promoteParticipant('bob')
          .then((_) => completed = true);
      expect(hostStore.authoredBatches.last.single['targetActor'], 'bob');
      expect(hostStore.authoredBatches.last.single['text'], 'editor');
      await _settle(tester);
      expect(completed, isFalse);
      expect(
        host.participants.singleWhere((p) => p.actorId == 'bob').role,
        RoomRole.guest,
      );
      expect(target.canEdit, isFalse);
      expect(_sentRoles(network), hasLength(rolesBefore));
      hostStore.appendGate!.complete();
      await pending;
      await _settle(tester);
      expect(target.ownRole, RoomRole.editor);
      expect(target.canEdit, isTrue);
      expect(
        host.participants.singleWhere((p) => p.actorId == 'bob').role,
        RoomRole.editor,
      );
      await target.edit('Теперь можно');
      await target.renameRoom('Новый заголовок');
      await _settle(tester);
      expect(host.text, 'Теперь можно');
      expect(host.roomName, 'Новый заголовок');
      final count = host.historyLength;
      await host.promoteParticipant('bob');
      expect(host.historyLength, count);
      target.dispose();
      host.dispose();
      await _settle(tester);
      network.autoRegister = false;
      final reopened = session(
        actor: 'bob',
        role: RoomRole.guest,
        storage: targetStore,
      );
      await reopened.start();
      expect(reopened.ownRole, RoomRole.editor);
      expect(reopened.canEdit, isTrue);
      expect(reopened.historyLength, target.historyLength);
    },
  );

  rolesTest(
    'failed promotion keeps durable permissions guest until an honest retry succeeds',
    (tester) async {
      final storage = store();
      await storage.appendHistory(_roomId, [
        _role('alice-role', 'alice', RoomRole.editor).toJson(),
        _role('bob-role', 'bob', RoomRole.guest).toJson(),
        _edit(
          'bob-name',
          'bob',
          2,
          'Борис',
          kind: RoomEditKind.participantName,
        ).toJson(),
      ]);
      final host = session(
        actor: 'alice',
        role: RoomRole.editor,
        storage: storage,
        creator: true,
      );
      await host.start();
      await _settle(tester);
      final localGuestTabs = _Tabs();
      final localGuest = session(
        actor: 'bob',
        role: RoomRole.guest,
        storage: storage,
        localTabs: localGuestTabs,
      );
      await localGuest.start();
      storage.failAppend = true;
      await expectLater(host.promoteParticipant('bob'), throwsStateError);
      expect(host.storageError, contains('Disk full'));
      expect(
        host.participants.singleWhere((p) => p.actorId == 'bob').role,
        RoomRole.guest,
      );
      expect(localGuest.canEdit, isFalse);
      await expectLater(localGuest.edit('Forbidden'), throwsStateError);
      await expectLater(localGuest.promoteParticipant('bob'), throwsStateError);
      storage.failAppend = false;
      await host.promoteParticipant('bob');
      await tester.pump(const Duration(milliseconds: 40));
      await _settle(tester);
      expect(host.storageError, isNull);
      expect(localGuest.canEdit, isTrue);
      expect(localGuest.ownRole, RoomRole.editor);
      expect(
        host.changes.where(
          (e) =>
              e.kind == RoomEditKind.participantRole &&
              e.targetActor == 'bob' &&
              e.text == 'editor',
        ),
        hasLength(1),
      );
    },
  );

  rolesTest(
    'offline target promotion returns through inventory and survives reload',
    (tester) async {
      final host = session(
        actor: 'alice',
        name: 'Алиса',
        role: RoomRole.editor,
        creator: true,
      );
      await host.start();
      await _settle(tester);
      final storage = store();
      final original = session(
        actor: 'bob',
        name: 'Борис',
        role: RoomRole.guest,
        storage: storage,
        member: false,
        follower: true,
      );
      await original.start();
      await _settleRoom(tester);
      original.dispose();
      await _settle(tester);
      expect(
        host.participants.singleWhere((p) => p.actorId == 'bob').isOnline,
        isFalse,
      );
      await host.promoteParticipant('bob');
      final reconnect = session(
        actor: 'bob',
        role: RoomRole.guest,
        storage: storage,
        follower: true,
      );
      await reconnect.start();
      expect(reconnect.canEdit, isFalse);
      await _settleRoom(tester);
      expect(reconnect.initialSyncComplete, isTrue);
      expect(reconnect.canEdit, isTrue);
      expect(
        roomHistoryInventory(reconnect.changes),
        roomHistoryInventory(host.changes),
      );
      reconnect.dispose();
      host.dispose();
      await _settle(tester);
      network.autoRegister = false;
      final reopened = session(
        actor: 'bob',
        role: RoomRole.guest,
        storage: storage,
      );
      await reopened.start();
      expect(reopened.ownRole, RoomRole.editor);
      expect(reopened.canEdit, isTrue);
    },
  );

  rolesTest(
    'legacy saved members remain editors and a saved guest accepts an editor invite',
    (tester) async {
      network.autoRegister = false;
      final legacyStore = store();
      await legacyStore.appendHistory(_roomId, [
        _edit('legacy-text', 'alice', 1, 'Старая заметка').toJson(),
      ]);
      final legacy = session(
        actor: 'alice',
        role: RoomRole.guest,
        storage: legacyStore,
      );
      await legacy.start();
      expect(legacy.ownRole, RoomRole.editor);
      expect(legacy.canEdit, isTrue);
      expect(legacy.participants.single.role, RoomRole.editor);
      expect(
        legacy.changes.any((e) => e.kind == RoomEditKind.participantRole),
        isFalse,
      );
      await legacy.edit('Старая комната работает');
      final storage = store();
      await storage.appendHistory(_roomId, [
        _role('guest-role', 'bob', RoomRole.guest).toJson(),
      ]);
      final guest = session(
        actor: 'bob',
        role: RoomRole.editor,
        storage: storage,
      );
      await guest.start();
      expect(guest.ownRole, RoomRole.editor);
      expect(guest.canEdit, isTrue);
      final promoted = guest.changes.singleWhere(
        (edit) =>
            edit.kind == RoomEditKind.participantRole && edit.text == 'editor',
      );
      expect(promoted.author, 'bob');
      expect(promoted.targetActor, 'bob');
      await guest.retry();
      expect(guest.changes, hasLength(2));
      expect(guest.ownRole, RoomRole.editor);
      guest.dispose();
      final restored = session(actor: 'bob', storage: storage);
      await restored.start();
      expect(restored.canEdit, isTrue);
      expect(
        restored.changes.map((edit) => edit.toJson()),
        guest.changes.map((edit) => edit.toJson()),
      );
      restored.dispose();
      final guestInvite = session(
        actor: 'bob',
        storage: storage,
        role: RoomRole.guest,
      );
      await guestInvite.start();
      expect(guestInvite.canEdit, isTrue);
      expect(
        guestInvite.changes.map((edit) => edit.toJson()),
        guest.changes.map((edit) => edit.toJson()),
      );
    },
  );

  for (final invitation in [null, RoomRole.guest]) {
    rolesTest('saved guest restore does not promote for $invitation', (
      tester,
    ) async {
      network.autoRegister = false;
      final storage = store();
      final initial = _role('guest-role', 'bob', RoomRole.guest);
      await storage.appendHistory(_roomId, [initial.toJson()]);
      final guest = session(actor: 'bob', storage: storage, role: invitation);
      await guest.start();
      await guest.retry();
      expect(guest.ownRole, RoomRole.guest);
      expect(guest.canEdit, isFalse);
      expect(guest.changes.map((edit) => edit.toJson()), [initial.toJson()]);
      expect(storage.authoredBatches, isEmpty);
    });
  }

  rolesTest(
    'editor invitation waits for durable guest promotion before granting commands or sync',
    (tester) async {
      final hostStore = store();
      final guestStore = store();
      final seed = [
        _role('alice-role', 'alice', RoomRole.editor),
        _role('bob-role', 'bob', RoomRole.guest),
        _role('eve-role', 'eve', RoomRole.guest),
      ];
      for (final storage in [hostStore, guestStore]) {
        await storage.appendHistory(
          _roomId,
          seed.map((e) => e.toJson()).toList(),
        );
      }
      final host = session(actor: 'alice', storage: hostStore, creator: true);
      await host.start();
      await _settle(tester);
      guestStore.appendGate = Completer<void>();
      final guest = session(
        actor: 'bob',
        storage: guestStore,
        role: RoomRole.editor,
        follower: true,
      );
      var started = false;
      final starting = guest.start().then((_) => started = true);
      await _settle(tester);
      expect(started, isFalse);
      expect(guest.ownRole, RoomRole.guest);
      expect(guest.canEdit, isFalse);
      expect(guestStore.authoredBatches, hasLength(1));
      final draft = guestStore.authoredBatches.single.single;
      expect(draft['targetActor'], 'bob');
      expect(draft['text'], 'editor');
      expect(_sentRoles(network).where((e) => e.id == draft['id']), isEmpty);
      expect(
        host.participants.singleWhere((p) => p.actorId == 'bob').role,
        RoomRole.guest,
      );
      await expectLater(guest.edit('Not saved yet'), throwsStateError);
      guestStore.appendGate!.complete();
      await starting;
      await _settleRoom(tester);
      expect(guest.initialSyncComplete, isTrue);
      expect(guest.canEdit, isTrue);
      expect(
        host.participants.singleWhere((p) => p.actorId == 'bob').role,
        RoomRole.editor,
      );
      expect(
        host.participants.singleWhere((p) => p.actorId == 'eve').role,
        RoomRole.guest,
      );
      expect(
        roomHistoryInventory(host.changes),
        roomHistoryInventory(guest.changes),
      );
      await guest.edit('Editor invitation accepted');
      await _settle(tester);
      expect(host.text, 'Editor invitation accepted');
    },
  );

  rolesTest(
    'failed editor invitation keeps guest rights and retries the same promotion',
    (tester) async {
      network.autoRegister = false;
      final storage = store();
      await storage.appendHistory(_roomId, [
        _role('bob-role', 'bob', RoomRole.guest).toJson(),
      ]);
      storage.failAppend = true;
      final guest = session(
        actor: 'bob',
        role: RoomRole.editor,
        storage: storage,
      );
      await guest.start();
      expect(guest.ownRole, RoomRole.guest);
      expect(guest.canEdit, isFalse);
      expect(guest.storageError, contains('Disk full'));
      expect(guest.initialSyncError, isNotNull);
      final pending = guest.changes.singleWhere((e) => e.text == 'editor');
      await expectLater(guest.edit('Forbidden'), throwsStateError);
      await guest.retry();
      expect(guest.canEdit, isFalse);
      expect(guest.changes.where((e) => e.text == 'editor').single, pending);
      storage.failAppend = false;
      await guest.retry();
      expect(guest.canEdit, isTrue);
      expect(guest.storageError, isNull);
      final saved = decodeRoomHistory(await storage.loadHistory(_roomId));
      expect(saved.singleWhere((e) => e.text == 'editor').id, pending.id);
      expect(saved, hasLength(2));
      await guest.retry();
      expect(
        guest.changes.map((edit) => edit.toJson()),
        saved.map((edit) => edit.toJson()),
      );
    },
  );

  rolesTest(
    'guest network host relays editor changes and promotes itself only after remote durable operation',
    (tester) async {
      final hostStore = store();
      final seed = [
        _role('guest-role', 'guest-host', RoomRole.guest),
        _role('editor-role', 'editor', RoomRole.editor),
        _edit(
          'guest-name',
          'guest-host',
          2,
          'Гость-хост',
          kind: RoomEditKind.participantName,
        ),
        _edit(
          'editor-name',
          'editor',
          3,
          'Редактор',
          kind: RoomEditKind.participantName,
        ),
      ];
      await hostStore.appendHistory(
        _roomId,
        seed.map((e) => e.toJson()).toList(),
      );
      final guestHost = session(
        actor: 'guest-host',
        role: RoomRole.guest,
        storage: hostStore,
      );
      await guestHost.start();
      await _settle(tester);
      expect(guestHost.canEdit, isFalse);
      expect(network.registered[guestHost.hostAlias], isNotNull);
      final editorStore = store();
      await editorStore.appendHistory(
        _roomId,
        seed.map((e) => e.toJson()).toList(),
      );
      final editor = session(
        actor: 'editor',
        role: RoomRole.editor,
        storage: editorStore,
        follower: true,
      );
      await editor.start();
      await _settleRoom(tester);
      final observer = session(
        actor: 'observer',
        name: 'Читатель',
        role: RoomRole.guest,
        member: false,
        follower: true,
      );
      await observer.start();
      await _settleRoom(tester);
      expect(observer.joined, isTrue);
      await editor.edit('Передано гостем-хостом');
      await editor.renameRoom('Комната гостя');
      await _settle(tester);
      expect(guestHost.text, editor.text);
      expect(observer.text, editor.text);
      expect(observer.roomName, 'Комната гостя');
      expect(guestHost.canEdit, isFalse);
      await editor.promoteParticipant('observer');
      await _settle(tester);
      expect(observer.canEdit, isTrue);
      expect(guestHost.canEdit, isFalse);
      await editor.promoteParticipant('guest-host');
      await _settle(tester);
      expect(guestHost.canEdit, isTrue);
      expect(
        observer.participants
            .singleWhere((p) => p.actorId == 'guest-host')
            .role,
        RoomRole.editor,
      );
      expect(
        roomHistoryInventory(observer.changes),
        roomHistoryInventory(guestHost.changes),
      );
      guestHost.dispose();
      await _settle(tester);
      await editor.retry();
      await _settleRoom(tester);
      await observer.retry();
      await _settleRoom(tester);
      await editor.edit('После смены хоста');
      await _settle(tester);
      expect(observer.text, editor.text);
    },
  );

  rolesTest(
    'saved guest takes over signaling alias without gaining editing rights',
    (tester) async {
      final creator = session(
        actor: 'alice',
        name: 'Алиса',
        role: RoomRole.editor,
        creator: true,
      );
      await creator.start();
      await _settle(tester);
      final guest = session(
        actor: 'bob',
        name: 'Борис',
        role: RoomRole.guest,
        member: false,
        follower: true,
      );
      await guest.start();
      await _settleRoom(tester);
      creator.dispose();
      await _settle(tester);
      await guest.retry();
      await _settleRoom(tester);
      expect(network.registered[guest.hostAlias], isNotNull);
      expect(guest.ownRole, RoomRole.guest);
      expect(guest.canEdit, isFalse);
      final editor = session(
        actor: 'carol',
        name: 'Вера',
        role: RoomRole.editor,
        member: false,
        follower: true,
      );
      await editor.start();
      await _settleRoom(tester);
      expect(editor.joined, isTrue);
      expect(editor.canEdit, isTrue);
      await editor.edit('Текст через гостя');
      await _settle(tester);
      expect(guest.text, editor.text);
      expect(guest.canEdit, isFalse);
      await expectLater(guest.edit('Нельзя'), throwsStateError);
    },
  );

  rolesTest(
    'role-enabled fresh admission rejects current metadata-only welcome before any import',
    (tester) async {
      final storage = store();
      final room = session(
        actor: 'bob',
        role: RoomRole.guest,
        storage: storage,
        member: false,
        follower: true,
      );
      await room.start();
      await _settle(tester);
      final channel = network.channels.single;
      channel.openChannel();
      await _settle(tester);
      final hello = _channelMessages(channel).single;
      expect(hello.roomRoles, isTrue);
      expect(hello.history, isEmpty);
      channel.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.welcome,
          actor: 'current-host',
          history: [_edit('not-imported', 'current-host', 100, 'Не сохранять')],
          online: 2,
          hosting: true,
          roomMetadata: true,
          authorHistory: true,
          durableSync: true,
        ).toJson(),
      );
      await _settle(tester);
      expect(channel.disposed, isTrue);
      expect(room.joined, isFalse);
      expect(room.initialSyncError, contains('ролей'));
      expect(storage.membershipCalls, 0);
      expect(await storage.loadHistory(_roomId), isEmpty);
    },
  );

  rolesTest(
    'role history never leaks in hello and role host rejects current unversioned peer',
    (tester) async {
      final storage = store();
      final seed = [
        _edit('text', 'alice', 1, 'Только текст'),
        _role('guest-role', 'alice', RoomRole.guest),
        _edit('name', 'alice', 2, 'Алиса', kind: RoomEditKind.participantName),
      ];
      await storage.appendHistory(
        _roomId,
        seed.map((e) => e.toJson()).toList(),
      );
      final room = session(
        actor: 'alice',
        role: RoomRole.guest,
        storage: storage,
        follower: true,
      );
      await room.start();
      await _settle(tester);
      final outbound = network.channels.single;
      outbound.openChannel();
      await _settle(tester);
      final hello = _channelMessages(outbound).single;
      expect(hello.roomRoles, isTrue);
      expect(hello.history, isEmpty);
      expect(jsonEncode(hello.toJson()), isNot(contains('guest-role')));
      expect(jsonEncode(hello.toJson()), isNot(contains('Алиса')));
      outbound.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.welcome,
          actor: 'old-host',
          history: [_edit('reject', 'old-host', 100, 'No')],
          online: 2,
          hosting: true,
          roomMetadata: true,
          authorHistory: true,
        ).toJson(),
      );
      await _settle(tester);
      expect(outbound.disposed, isTrue);
      expect(room.text, 'Только текст');
      expect(room.changes, hasLength(seed.length));
      room.dispose();
      await _settle(tester);
      final host = session(
        actor: 'alice',
        role: RoomRole.guest,
        storage: storage,
      );
      await host.start();
      await _settle(tester);
      final peer = network.registered[host.hostAlias]!;
      final inbound = _Channel('metadata-peer');
      peer.accept(inbound);
      inbound.openChannel();
      inbound.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.hello,
          actor: 'metadata-peer',
          history: [_edit('reject-hello', 'metadata-peer', 200, 'No')],
          roomMetadata: true,
          authorHistory: true,
        ).toJson(),
      );
      await _settle(tester);
      expect(inbound.disposed, isTrue);
      expect(inbound.sent, isEmpty);
      expect(host.changes, hasLength(seed.length));
    },
  );

  rolesTest(
    'incoming role records require roles capability even in legacy-compatible direct session',
    (tester) async {
      final storage = store();
      final host = session(actor: 'alice', storage: storage, creator: true);
      await host.start();
      await _settle(tester);
      final peer = network.registered[host.hostAlias]!;
      final inbound = _Channel('metadata-peer');
      peer.accept(inbound);
      inbound.openChannel();
      inbound.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.hello,
          actor: 'metadata-peer',
          history: [],
          roomMetadata: true,
          authorHistory: true,
        ).toJson(),
      );
      await _settle(tester);
      expect(inbound.disposed, isFalse);
      inbound.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.edits,
          actor: 'metadata-peer',
          history: [_role('not-negotiated', 'alice', RoomRole.guest)],
        ).toJson(),
      );
      await _settle(tester);
      expect(inbound.disposed, isTrue);
      expect(host.changes, isEmpty);
      expect(host.ownRole, RoomRole.editor);
      expect(await storage.loadHistory(_roomId), isEmpty);
    },
  );

  rolesTest(
    'legacy capability channel closes before a newly durable role is sent',
    (tester) async {
      final storage = store();
      final host = session(actor: 'alice', storage: storage, creator: true);
      await host.start();
      await _settle(tester);
      final peer = network.registered[host.hostAlias]!;
      final inbound = _Channel('metadata-peer');
      peer.accept(inbound);
      inbound.openChannel();
      inbound.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.hello,
          actor: 'metadata-peer',
          history: [],
          roomMetadata: true,
          authorHistory: true,
        ).toJson(),
      );
      await _settle(tester);
      expect(inbound.disposed, isFalse);
      await storage.appendHistory(_roomId, [
        _role('guest-record', 'offline-guest', RoomRole.guest).toJson(),
      ]);
      await tester.pump(const Duration(milliseconds: 40));
      await _settle(tester);
      expect(inbound.disposed, isTrue);
      expect(
        host.participants.singleWhere((p) => p.actorId == 'offline-guest').role,
        RoomRole.guest,
      );
      expect(
        _channelMessages(inbound).expand((message) => message.history),
        isEmpty,
      );
    },
  );

  rolesTest(
    'local tab role is loaded from durable journal not an unverified beacon',
    (tester) async {
      final storage = store();
      final initial = [_role('guest-role', 'bob', RoomRole.guest)];
      await storage.appendHistory(
        _roomId,
        initial.map((e) => e.toJson()).toList(),
      );
      final localTabs = _Tabs();
      final room = session(
        actor: 'bob',
        role: RoomRole.guest,
        storage: storage,
        localTabs: localTabs,
      );
      await room.start();
      final promotion = _role('promotion', 'bob', RoomRole.editor, clock: 10);
      final inventory = roomHistoryInventory([...initial, promotion]);
      final state = RoomTabState(
        roomId: _roomId,
        actorId: 'bob',
        onlineCount: 1,
        onlineActors: ['bob'],
        networkAvailable: true,
        initialSyncComplete: true,
        localCopyOpened: false,
        status: 'Онлайн',
        initialSyncStatus: 'Проверено',
        inventory: inventory,
      );
      localTabs.receive(state);
      await tester.pump(const Duration(milliseconds: 40));
      await _settle(tester);
      expect(room.canEdit, isFalse);
      expect(room.initialSyncComplete, isFalse);
      expect(room.changes, hasLength(1));
      await storage.appendHistory(_roomId, [promotion.toJson()]);
      localTabs.receive(state);
      await tester.pump(const Duration(milliseconds: 40));
      await _settle(tester);
      expect(room.canEdit, isTrue);
      expect(room.initialSyncComplete, isTrue);
      expect(room.changes, hasLength(2));
      expect(state.toJson().containsKey('participantRoles'), isFalse);
      expect(state.toJson().containsKey('role'), isFalse);
      expect(network.peers, isEmpty);
      await room.edit('Из соседней вкладки');
      expect(room.text, 'Из соседней вкладки');
    },
  );
}
