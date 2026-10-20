import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/room_document.dart';
import 'package:mytree_webrtc_demo/room_identity.dart';
import 'package:mytree_webrtc_demo/room_protocol.dart';
import 'package:mytree_webrtc_demo/room_session.dart';
import 'package:mytree_webrtc_demo/signaling/signaling.dart';
import 'package:mytree_webrtc_demo/storage/room_store.dart';
import 'package:mytree_webrtc_demo/tree/tree_document.dart';

const _roomId = '0123456789abcdef0123456789abcdef';
const _photo =
    'data:image/png;base64,'
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/'
    'x8AAusB9Wl6Dh0AAAAASUVORK5CYII=';

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
  bool paused = false;
  final peers = <_Peer>[];
  final channels = <_Channel>[];
  final registered = <String, _Peer>{};
  final _pending = <void Function()>[];

  SignalingPeer create(String id, Map<String, dynamic> configuration) {
    final peer = _Peer(this, id);
    peers.add(peer);
    return peer;
  }

  void deliver(void Function() callback) {
    if (paused) {
      _pending.add(callback);
    } else {
      scheduleMicrotask(callback);
    }
  }

  void resume() {
    paused = false;
    for (final callback in _pending) {
      scheduleMicrotask(callback);
    }
    _pending.clear();
  }

  Future<void> close() async {
    _pending.clear();
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
  String get service => 'tree-test';
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
    final outgoing = _Channel(network, target);
    network.channels.add(outgoing);
    attached.add(outgoing);
    final remote = network.registered[target];
    if (remote == null || !remote.open || remote.disposed) return outgoing;
    final incoming = _Channel(network, id);
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
  _Channel(this.network, this.peer);

  final _Network network;
  @override
  final String peer;
  @override
  bool open = false;
  @override
  bool disposed = false;
  _Channel? other;
  final sent = <Map<String, dynamic>>[];
  @override
  String get service => 'tree-test';
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
      network.deliver(() {
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
  bool failAppend = false;
  int membershipCalls = 0;

  @override
  Stream<void> watchHistory(String roomId) => changes.stream;

  @override
  Future<void> appendHistory(
    String roomId,
    List<Map<String, dynamic>> operations,
  ) {
    batches.add(
      (jsonDecode(jsonEncode(operations)) as List)
          .map((row) => (row as Map).cast<String, dynamic>())
          .toList(),
    );
    if (failAppend) return Future<void>.error(StateError('Disk full'));
    return super.appendHistory(roomId, operations).then((_) {
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

List<RoomMessage> _channelMessages(_Channel channel) {
  final decoder = RoomMessageDecoder(roomId: _roomId);
  return [
    for (final packet in channel.sent)
      if (decoder.decode(packet).message case final message?) message,
  ];
}

List<RoomMessage> _messages(_Network network) => [
  for (final channel in network.channels) ..._channelMessages(channel),
];

// A failed optimistic draft has no finalized proof yet. Its ID, tree payload
// and conflict-resolution stamps must stay fixed; finalized proofs are immutable
// too, but storage may assign a draft its sequence only on the successful retry.
Matcher _immutableEdit(RoomEdit expected) => predicate<Object?>((raw) {
  final actual = RoomEdit.fromJson(raw);
  return actual != null &&
      actual.sameCoreAs(expected) &&
      (expected.authorSequence == null || actual.sameContentAs(expected));
}, 'preserves the immutable edit core and any finalized author proof');

List<RoomEdit> _treeEdits(RoomSession room) =>
    room.changes.where((edit) => edit.kind == RoomEditKind.tree).toList();

// Older clients allowed guests to bind. Preserve that real journal payload
// without submitting a command which current guest permissions must reject.
Future<RoomEdit> _seedLegacyGuestBinding(_Store storage, String actor) async {
  final document = RoomDocument();
  final role = document.createEdit(
    actor,
    RoomRole.guest.name,
    kind: RoomEditKind.participantRole,
    targetActor: actor,
  );
  document.merge([role]);
  final binding = document.createEdit(
    actor,
    jsonEncode(TreeDocument().bindActor(actor, rootTreePersonId).toJson()),
    kind: RoomEditKind.tree,
  );
  await storage.appendHistory(_roomId, [role.toJson(), binding.toJson()]);
  return binding;
}

Map<String, Object?> _projection(TreeDocument tree) => {
  'bindings': tree.bindings,
  'siblingGroups': tree.siblingGroupIds,
  'directSiblingLinks': [
    for (final link in tree.directSiblingLinks)
      [link.id, link.personId, link.siblingId],
  ],
  'people': [
    for (final person in tree.people.values)
      {
        'id': person.id,
        'name': person.name,
        'biography': person.biography,
        'sex': person.sex.name,
        'birthDate': person.birthDate?.toIso8601String(),
        'deathDate': person.deathDate?.toIso8601String(),
        'fatherId': person.fatherId,
        'motherId': person.motherId,
        'avatarPhotoId': person.avatarPhotoId,
        'familySurname': person.familySurname,
        'individualSurname': person.individualSurname,
        'maidenSurname': person.maidenSurname,
        'effectiveSurname': person.effectiveSurname,
        'surnameInheritedFrom': person.surnameInheritedFrom,
        'fullName': person.fullName,
        'facts': [
          for (final fact in person.facts)
            {'id': fact.id, 'text': fact.text, 'color': fact.color},
        ],
        'photos': [
          for (final photo in person.photos)
            {
              'id': photo.id,
              'dataUrl': photo.dataUrl,
              'caption': photo.caption,
            },
        ],
      },
  ],
};

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
  late List<_Store> stores;

  setUp(() {
    network = _Network();
    sessions = [];
    stores = [];
  });

  _Store store() {
    final storage = _Store();
    stores.add(storage);
    return storage;
  }

  RoomSession session({
    required String actor,
    String? name,
    _Store? storage,
    RoomRole role = RoomRole.editor,
    bool member = true,
    bool follower = false,
    bool creator = false,
    bool requireFamilyTree = true,
  }) {
    final room = RoomSession(
      roomId: _roomId,
      actorId: actor,
      participantName: name ?? 'Profile $actor',
      invitationRole: role,
      store: storage ?? store(),
      existingMember: member,
      preferExistingHost: follower,
      newlyCreated: creator,
      requireFamilyTree: requireFamilyTree,
      peerFactory: network.create,
    );
    sessions.add(room);
    return room;
  }

  void treeTest(String name, Future<void> Function(WidgetTester) body) {
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
    for (final storage in stores) {
      await storage.changes.close();
    }
  });

  treeTest(
    'independent editors join, merge concurrent own-base character inserts and reload the full history',
    (tester) async {
      final aliceStore = store();
      final alice = session(actor: 'alice', storage: aliceStore, creator: true);
      await alice.start();
      await _settle(tester);
      await alice.applyTreeOperation(
        alice.tree.createPerson('father', name: 'Отец', sex: TreeSex.male),
      );
      await alice.applyTreeOperation(
        alice.tree.setValue(rootTreePersonId, 'fatherId', 'father'),
      );
      await alice.applyTreeOperation(
        alice.tree.setValue(
          rootTreePersonId,
          'birthDate',
          DateTime.utc(1980, 2, 3),
        ),
      );
      await alice.editTreeText(rootTreePersonId, TreeTextField.name, 'АБ');
      await alice.editTreeText(
        rootTreePersonId,
        TreeTextField.biography,
        'Семейная история',
      );
      await alice.applyTreeOperation(
        alice.tree.addFact(rootTreePersonId, 'kept', text: 'Старый факт'),
      );
      await alice.applyTreeOperation(
        alice.tree.addFact(rootTreePersonId, 'removed', text: 'Удалённый факт'),
      );
      await alice.applyTreeOperation(
        alice.tree.removeFact(rootTreePersonId, 'removed'),
      );
      await alice.applyTreeOperation(
        alice.tree.addPhoto(rootTreePersonId, 'avatar', dataUrl: _photo),
      );
      await alice.applyTreeOperation(
        alice.tree.setValue(rootTreePersonId, 'avatarPhotoId', 'avatar'),
      );
      final bobStore = store();
      final bob = session(
        actor: 'bob',
        storage: bobStore,
        member: false,
        follower: true,
      );
      expect(identical(aliceStore, bobStore), isFalse);
      await bob.start();
      await _settleRoom(tester);
      for (final room in [alice, bob]) {
        expect(room.joined, isTrue);
        expect(room.canEdit, isTrue);
        expect(room.initialSyncComplete, isTrue);
        expect(room.initialSyncError, isNull);
        expect(room.requireFamilyTree, isTrue);
      }
      expect(identical(alice.tree, bob.tree), isFalse);
      expect(_projection(bob.tree), _projection(alice.tree));
      final aliceBase = alice.tree.textSnapshot(
        rootTreePersonId,
        TreeTextField.name,
      );
      final bobBase = bob.tree.textSnapshot(
        rootTreePersonId,
        TreeTextField.name,
      );
      expect(identical(aliceBase, bobBase), isFalse);
      expect(aliceBase.text, 'АБ');
      expect(bobBase.atomIds, aliceBase.atomIds);
      final sharedIds = alice.changes.map((edit) => edit.id).toSet();
      network.paused = true;
      await Future.wait([
        alice.editTreeText(
          rootTreePersonId,
          TreeTextField.name,
          'АяБ',
          base: aliceBase,
        ),
        bob.editTreeText(
          rootTreePersonId,
          TreeTextField.name,
          'АюБ',
          base: bobBase,
        ),
      ]);
      await _settle(tester);
      expect(alice.tree.person(rootTreePersonId)!.name, 'АяБ');
      expect(bob.tree.person(rootTreePersonId)!.name, 'АюБ');
      final ownEdits = [
        ...alice.changes.where((edit) => !sharedIds.contains(edit.id)),
        ...bob.changes.where((edit) => !sharedIds.contains(edit.id)),
      ];
      expect(ownEdits, hasLength(2));
      for (final edit in ownEdits) {
        final payload = jsonDecode(edit.text) as Map;
        expect(payload['type'], 'editText');
        expect(payload['inserts'], hasLength(1));
        expect(payload['deletes'], isEmpty);
      }
      final expectedHistory = roomHistoryInventory([
        ...alice.changes,
        ...bob.changes,
      ]);
      network.resume();
      await _settleRoom(tester);
      final mergedName = alice.tree.person(rootTreePersonId)!.name;
      expect(mergedName, anyOf('АяюБ', 'АюяБ'));
      expect(bob.tree.person(rootTreePersonId)!.name, mergedName);
      await bob.editTreeText(
        rootTreePersonId,
        TreeTextField.fact,
        'Новый факт',
        itemId: 'kept',
      );
      await bob.applyTreeOperation(
        bob.tree.setFactColor(rootTreePersonId, 'kept', '#D1DED9'),
      );
      await alice.bindToPerson(rootTreePersonId);
      await _settleRoom(tester);
      final finalInventory = roomHistoryInventory(alice.changes);
      expect(finalInventory.keys, containsAll(expectedHistory.keys));
      expect(roomHistoryInventory(bob.changes), finalInventory);
      final expected = _projection(alice.tree);
      expect(_projection(bob.tree), expected);
      expect(
        alice.tree.person(rootTreePersonId)!.facts.single.text,
        'Новый факт',
      );
      expect(alice.tree.person(rootTreePersonId)!.fatherId, 'father');
      for (final room in [alice, bob]) {
        expect(
          room.text,
          isEmpty,
          reason: 'tree JSON must never become the legacy note',
        );
        expect(_projection(room.durableTree), expected);
        expect(room.initialSyncComplete, isTrue);
        await room.flush();
      }
      for (final storage in [aliceStore, bobStore]) {
        final saved = decodeRoomHistory(await storage.loadHistory(_roomId));
        expect(roomHistoryInventory(saved), finalInventory);
        final restored = TreeDocument()
          ..merge([
            for (final edit in saved.where(
              (edit) => edit.kind == RoomEditKind.tree,
            ))
              StampedTreeOperation(
                id: edit.id,
                author: edit.author,
                clock: edit.clock,
                createdAt: DateTime.fromMillisecondsSinceEpoch(
                  edit.createdAt,
                  isUtc: true,
                ),
                operation: TreeOperation.fromJson(jsonDecode(edit.text)),
              ),
          ]);
        expect(_projection(restored), expected);
      }
      final handshakes = _messages(network).where(
        (message) =>
            message.type == RoomMessageType.hello ||
            message.type == RoomMessageType.welcome,
      );
      expect(handshakes, isNotEmpty);
      expect(handshakes.every((message) => message.familyTree), isTrue);
      expect(handshakes.every((message) => message.familySurnames), isTrue);
      expect(handshakes.every((message) => message.personalSurnames), isTrue);
      expect(handshakes.every((message) => message.explicitSiblings), isTrue);
      expect(handshakes.every((message) => message.authorHistory), isTrue);
      expect(
        handshakes
            .where((message) => message.type == RoomMessageType.hello)
            .every((message) => message.history.isEmpty),
        isTrue,
      );
      for (final message in _messages(network)) {
        expect(
          message.history.map((edit) => edit.id),
          validateAuthorHistory(message.history).map((edit) => edit.id),
          reason:
              'Every payload, including a new tail, carries its full prefix',
        );
        expect(
          message.history.every((edit) => edit.authorSequence != null),
          isTrue,
        );
      }
      expect(
        _messages(
          network,
        ).any((message) => message.type == RoomMessageType.checkpoint),
        isTrue,
      );
      expect(
        _messages(network).any(
          (message) =>
              message.type == RoomMessageType.syncAck &&
              message.roomReady == true,
        ),
        isTrue,
      );
      alice.dispose();
      bob.dispose();
      await _settle(tester);
      network.autoRegister = false;
      for (final entry in [('alice', aliceStore), ('bob', bobStore)]) {
        final reopened = session(actor: entry.$1, storage: entry.$2);
        await reopened.start();
        expect(reopened.canEdit, isTrue);
        expect(reopened.networkAvailable, isFalse);
        expect(roomHistoryInventory(reopened.changes), finalInventory);
        expect(_projection(reopened.tree), expected);
        expect(_projection(reopened.durableTree), expected);
        expect(reopened.tree.person(rootTreePersonId)!.name, mergedName);
      }
    },
  );

  treeTest(
    'atomic sibling creation and unlink retry unchanged after failed saves',
    (tester) async {
      final storage = store();
      final alice = session(actor: 'alice', storage: storage, creator: true);
      await alice.start();
      await _settle(tester);
      await alice.applyTreeOperation(alice.tree.createPerson('father'));
      await alice.applyTreeOperation(
        alice.tree.setValue(rootTreePersonId, 'fatherId', 'father'),
      );
      final bob = session(actor: 'bob', member: false, follower: true);
      await bob.start();
      await _settleRoom(tester);
      final before = _treeEdits(alice).length;
      final op = alice.tree.createSibling(
        rootTreePersonId,
        'sister',
        name: 'Анна',
        sex: TreeSex.female,
        birthDate: DateTime.utc(1990, 2, 3),
      );
      storage.failAppend = true;
      await expectLater(alice.applyTreeOperation(op), throwsStateError);
      expect(_treeEdits(alice), hasLength(before + 1));
      final failed = _treeEdits(
        alice,
      ).singleWhere((edit) => jsonDecode(edit.text)['type'] == 'createSibling');
      expect(jsonDecode(failed.text), op.toJson());
      expect(alice.tree.person('sister')!.name, 'Анна');
      expect(alice.tree.person('sister')!.fatherId, 'father');
      expect(alice.tree.directSiblingLinks.single.id, failed.id);
      expect(alice.durableTree.person('sister'), isNull);
      await _settle(tester);
      expect(bob.tree.person('sister'), isNull);
      expect(
        _messages(
          network,
        ).expand((m) => m.history).any((edit) => edit.id == failed.id),
        isFalse,
      );
      await expectLater(alice.applyTreeOperation(op), throwsArgumentError);
      await expectLater(alice.flush(), throwsStateError);
      storage.failAppend = false;
      await alice.flush();
      await _settleRoom(tester);
      for (final room in [alice, bob]) {
        expect(room.tree.person('sister')!.birthDate, DateTime.utc(1990, 2, 3));
        expect(
          room.tree.siblingGroupIds['sister'],
          room.tree.siblingGroupIds[rootTreePersonId],
        );
        expect(
          _treeEdits(room).singleWhere((edit) => edit.id == failed.id).toJson(),
          _immutableEdit(failed),
        );
      }
      final unlink = alice.tree.unlinkSibling(rootTreePersonId, 'sister');
      storage.failAppend = true;
      await expectLater(alice.applyTreeOperation(unlink), throwsStateError);
      final failedUnlink = _treeEdits(
        alice,
      ).singleWhere((edit) => jsonDecode(edit.text)['type'] == 'unlinkSibling');
      expect(alice.tree.directSiblingLinks, isEmpty);
      expect(alice.tree.person('sister')!.fatherId, 'father');
      expect(alice.durableTree.directSiblingLinks, hasLength(1));
      await _settle(tester);
      expect(bob.tree.directSiblingLinks, hasLength(1));
      storage.failAppend = false;
      await alice.flush();
      await _settleRoom(tester);
      final expected = _projection(alice.tree);
      for (final room in [alice, bob]) {
        expect(room.tree.directSiblingLinks, isEmpty);
        expect(
          room.tree.siblingsOf(rootTreePersonId, includeHalf: false),
          isEmpty,
        );
        expect(room.tree.siblingsOf(rootTreePersonId).map((p) => p.id), [
          'sister',
        ]);
        expect(
          _treeEdits(
            room,
          ).singleWhere((edit) => edit.id == failedUnlink.id).toJson(),
          _immutableEdit(failedUnlink),
        );
        expect(_projection(room.durableTree), expected);
      }
      final inventory = roomHistoryInventory(alice.changes);
      alice.dispose();
      bob.dispose();
      await _settle(tester);
      network.autoRegister = false;
      final writes = storage.batches.length;
      final reopened = session(actor: 'alice', storage: storage);
      await reopened.start();
      expect(_projection(reopened.tree), expected);
      expect(roomHistoryInventory(reopened.changes), inventory);
      expect(storage.batches.length, writes);
    },
  );

  treeTest(
    'explicit peers converge concurrent new siblings and group parents then retire links',
    (tester) async {
      final alice = session(actor: 'alice', creator: true);
      await alice.start();
      await _settle(tester);
      await alice.applyTreeOperation(alice.tree.createPerson('father'));
      await alice.applyTreeOperation(alice.tree.createPerson('mother'));
      final bob = session(actor: 'bob', member: false, follower: true);
      await bob.start();
      await _settleRoom(tester);
      network.paused = true;
      await Future.wait([
        alice.applyTreeOperation(
          alice.tree.createSibling(
            rootTreePersonId,
            'a',
            name: 'Алёна',
            sex: TreeSex.female,
          ),
        ),
        bob.applyTreeOperation(
          bob.tree.createSibling(
            rootTreePersonId,
            'b',
            name: 'Борис',
            sex: TreeSex.male,
          ),
        ),
      ]);
      network.resume();
      await _settleRoom(tester);
      expect(_projection(alice.tree), _projection(bob.tree));
      expect(alice.tree.directSiblingLinks, hasLength(2));
      await bob.applyTreeOperation(
        bob.tree.setValue('b', 'fatherId', 'father'),
      );
      await _settleRoom(tester);
      for (final id in [rootTreePersonId, 'a', 'b']) {
        expect(alice.tree.person(id)!.fatherId, 'father');
      }
      await alice.applyTreeOperation(
        alice.tree.setValue('a', 'fatherId', null),
      );
      await _settleRoom(tester);
      for (final id in [rootTreePersonId, 'a', 'b']) {
        expect(bob.tree.person(id)!.fatherId, isNull);
      }
      await alice.applyTreeOperation(
        alice.tree.setValue(rootTreePersonId, 'fatherId', 'father'),
      );
      await bob.applyTreeOperation(
        bob.tree.setValue('b', 'motherId', 'mother'),
      );
      await _settleRoom(tester);
      expect(alice.tree.directSiblingLinks, isEmpty);
      expect(_projection(alice.tree), _projection(bob.tree));
      for (final room in [alice, bob]) {
        expect(
          room.tree.siblingsOf(rootTreePersonId, includeHalf: false),
          hasLength(2),
        );
        await expectLater(
          room.applyTreeOperation(
            TreeOperation.fromJson({
              'type': 'unlinkSibling',
              'personId': rootTreePersonId,
              'siblingId': 'a',
              'linkId': 'already-retired',
            }),
          ),
          throwsArgumentError,
        );
      }
      await alice.applyTreeOperation(alice.tree.deletePerson('mother'));
      await _settleRoom(tester);
      expect(bob.tree.directSiblingLinks, isEmpty);
    },
  );

  treeTest(
    'raw parent commands validate every direct sibling and creation is new-only',
    (tester) async {
      final room = session(actor: 'alice', creator: true);
      await room.start();
      await _settle(tester);
      await room.applyTreeOperation(
        room.tree.createSibling(rootTreePersonId, 'b'),
      );
      await room.applyTreeOperation(room.tree.createPerson('descendant'));
      await room.applyTreeOperation(
        room.tree.setValue('descendant', 'fatherId', 'b'),
      );
      final before = roomHistoryInventory(room.changes);
      for (final value in ['b', 'descendant']) {
        await expectLater(
          room.applyTreeOperation(
            TreeOperation.fromJson({
              'type': 'setValue',
              'personId': rootTreePersonId,
              'field': 'motherId',
              'value': value,
            }),
          ),
          throwsArgumentError,
        );
      }
      final template = room.tree
          .createSibling(rootTreePersonId, 'new')
          .toJson();
      for (final invalid in [
        {...template, 'personId': 'b'},
        {...template, 'siblingId': 'missing'},
      ]) {
        await expectLater(
          room.applyTreeOperation(TreeOperation.fromJson(invalid)),
          throwsArgumentError,
        );
      }
      expect(roomHistoryInventory(room.changes), before);
    },
  );

  treeTest(
    'surname capable peers converge independent personal configs and reload them',
    (tester) async {
      final storage = store();
      final alice = session(actor: 'alice', storage: storage, creator: true);
      await alice.start();
      await _settle(tester);
      for (final id in ['father', 'mother', 'other', 'sibling', 'child']) {
        await alice.applyTreeOperation(alice.tree.createPerson(id));
      }
      for (final id in [rootTreePersonId, 'sibling']) {
        await alice.applyTreeOperation(
          alice.tree.setValue(id, 'fatherId', 'father'),
        );
        await alice.applyTreeOperation(
          alice.tree.setValue(id, 'motherId', 'mother'),
        );
      }
      await alice.applyTreeOperation(
        alice.tree.setValue('child', 'fatherId', rootTreePersonId),
      );
      await alice.editTreeText(
        rootTreePersonId,
        TreeTextField.name,
        ' Анна Ивановна ',
      );
      await alice.applyTreeOperation(
        alice.tree.setValue(rootTreePersonId, 'sex', TreeSex.female),
      );
      await alice.applyTreeOperation(
        alice.tree.setIndividualSurname(
          'father',
          text: 'Иванов',
          decline: true,
        ),
      );
      final bob = session(actor: 'bob', member: false, follower: true);
      await bob.start();
      await _settleRoom(tester);
      expect(bob.tree.person(rootTreePersonId)!.surname, 'Иванова');
      expect(bob.initialSyncComplete, isTrue);
      final before = roomHistoryInventory(alice.changes);
      network.paused = true;
      await Future.wait([
        alice.applyTreeOperation(
          alice.tree.setIndividualSurname(
            rootTreePersonId,
            text: 'Петров',
            decline: true,
          ),
        ),
        bob.applyTreeOperation(
          bob.tree.setIndividualSurname('sibling', text: 'Ли'),
        ),
      ]);
      final concurrent = [
        ...alice.changes.where((edit) => !before.containsKey(edit.id)),
        ...bob.changes.where((edit) => !before.containsKey(edit.id)),
      ];
      expect(concurrent, hasLength(2));
      expect(
        concurrent.map((edit) => jsonDecode(edit.text)['personId']).toSet(),
        {rootTreePersonId, 'sibling'},
      );
      expect(
        concurrent.map((edit) => jsonDecode(edit.text)['scope']),
        everyElement('individual'),
      );
      expect(
        concurrent.map((edit) => jsonDecode(edit.text)['familyKey']),
        everyElement(isNull),
      );
      await bob.applyTreeOperation(
        bob.tree.setIndividualSurname(
          rootTreePersonId,
          text: 'Сидоров',
          decline: true,
        ),
      );
      await bob.applyTreeOperation(
        bob.tree.setMaidenSurname(
          rootTreePersonId,
          text: 'Кузнецов',
          decline: true,
        ),
      );
      network.resume();
      await _settleRoom(tester);
      expect(_projection(alice.tree), _projection(bob.tree));
      expect(alice.tree.person(rootTreePersonId)!.surname, 'Сидорова');
      expect(alice.tree.person('sibling')!.surname, 'Ли');
      expect(alice.tree.person('child')!.surname, 'Сидоров');
      expect(alice.tree.person(rootTreePersonId)!.familySurname, isNull);
      expect(alice.tree.person('sibling')!.familySurname, isNull);
      expect(
        alice.tree.person(rootTreePersonId)!.maidenSurname!.text,
        'Кузнецов',
      );
      await alice.bindToPerson(rootTreePersonId);
      await _settleRoom(tester);
      expect(
        alice.participants
            .singleWhere((person) => person.personId == rootTreePersonId)
            .name,
        'Profile alice',
      );
      expect(alice.boundPersonFullName, 'Анна Ивановна Сидорова');
      expect(
        alice.participants
            .singleWhere((person) => person.personId == rootTreePersonId)
            .boundPersonFullName,
        'Анна Ивановна Сидорова',
      );
      final delayed = alice.tree.setIndividualSurname(
        rootTreePersonId,
        text: 'Сидоров',
        decline: true,
      );
      final legacy = TreeOperation.fromJson({
        ...delayed.toJson(),
        'scope': 'family',
        'familyKey': alice.tree.surnameFamilyKey(rootTreePersonId),
      });
      await alice.applyTreeOperation(
        alice.tree.setValue(rootTreePersonId, 'motherId', 'other'),
      );
      await alice.applyTreeOperation(delayed);
      final immutableBefore = roomHistoryInventory(alice.changes);
      for (final operation in [
        legacy,
        TreeOperation.fromJson({
          ...legacy.toJson(),
          'familyKey': alice.tree.surnameFamilyKey(rootTreePersonId),
        }),
      ]) {
        await expectLater(
          alice.applyTreeOperation(operation),
          throwsArgumentError,
        );
      }
      expect(roomHistoryInventory(alice.changes), immutableBefore);
      expect(alice.tree.person(rootTreePersonId)!.familySurname, isNull);
      expect(alice.tree.person(rootTreePersonId)!.surname, 'Сидорова');
      await _settleRoom(tester);
      final expected = _projection(alice.tree);
      final inventory = roomHistoryInventory(alice.changes);
      expect(_projection(bob.durableTree), expected);
      alice.dispose();
      bob.dispose();
      await _settle(tester);
      network.autoRegister = false;
      final reopened = session(actor: 'alice', storage: storage);
      await reopened.start();
      expect(_projection(reopened.tree), expected);
      expect(roomHistoryInventory(reopened.changes), inventory);
    },
  );

  treeTest(
    'legacy surname history opens without migration, survives personal clears and peer reload',
    (tester) async {
      final storage = store();
      final domain = TreeDocument();
      final legacy = <RoomEdit>[];
      void seed(TreeOperation operation) {
        final clock = legacy.length + 1;
        final edit = RoomEdit(
          id: 'legacy-$clock',
          author: 'old-client',
          clock: clock,
          createdAt: clock,
          text: jsonEncode(operation.toJson()),
          kind: RoomEditKind.tree,
        );
        legacy.add(edit);
        domain.merge([
          StampedTreeOperation(
            id: edit.id,
            author: edit.author,
            clock: edit.clock,
            createdAt: DateTime.fromMillisecondsSinceEpoch(clock, isUtc: true),
            operation: operation,
          ),
        ]);
      }

      for (final id in ['father', 'mother', 'sibling', 'child']) {
        seed(domain.createPerson(id));
      }
      for (final id in [rootTreePersonId, 'sibling']) {
        seed(domain.setValue(id, 'fatherId', 'father'));
        seed(domain.setValue(id, 'motherId', 'mother'));
      }
      seed(domain.setValue('child', 'fatherId', rootTreePersonId));
      seed(
        domain.setIndividualSurname('father', text: 'Иванов', decline: true),
      );
      TreeOperation family(String? text) => TreeOperation.fromJson({
        ...domain.setIndividualSurname(rootTreePersonId, text: text).toJson(),
        'scope': 'family',
        'familyKey': domain.surnameFamilyKey(rootTreePersonId),
      });
      seed(family('Проигравшая'));
      seed(family('Старая'));
      seed(domain.setMaidenSurname(rootTreePersonId, text: 'Девичья'));
      legacy.add(
        RoomEdit(
          id: 'profile',
          author: 'alice',
          clock: legacy.length + 1,
          createdAt: 1,
          text: 'Profile alice',
          kind: RoomEditKind.participantName,
        ),
      );
      final original = [for (final edit in legacy) edit.toJson()];
      await storage.appendHistory(_roomId, original);
      final before = roomHistoryInventory(legacy);
      final writes = storage.batches.length;
      final alice = session(actor: 'alice', storage: storage);
      await alice.start();
      await _settle(tester);
      expect(storage.batches.length, writes);
      expect(storage.authoredBatches, isEmpty);
      expect(roomHistoryInventory(alice.changes), before);
      expect(alice.tree.person(rootTreePersonId)!.surname, 'Старая');
      expect(alice.tree.person('sibling')!.surname, 'Старая');
      expect(
        alice.tree.person(rootTreePersonId)!.maidenSurname!.text,
        'Девичья',
      );
      final bob = session(actor: 'bob', member: false, follower: true);
      await bob.start();
      await _settleRoom(tester);
      await alice.applyTreeOperation(
        alice.tree.setIndividualSurname(rootTreePersonId, text: null),
      );
      await _settleRoom(tester);
      for (final room in [alice, bob]) {
        expect(room.tree.person(rootTreePersonId)!.familySurname, isNull);
        expect(room.tree.person(rootTreePersonId)!.surname, 'Иванов');
        expect(room.tree.person('child')!.surname, 'Иванов');
        expect(room.tree.person('sibling')!.surname, 'Старая');
      }
      await bob.applyTreeOperation(
        bob.tree.setIndividualSurname('sibling', text: 'Ли'),
      );
      await _settleRoom(tester);
      final expected = _projection(alice.tree);
      final inventory = roomHistoryInventory(alice.changes);
      final saved = decodeRoomHistory(await storage.loadHistory(_roomId));
      expect([
        for (final edit in saved)
          if (before.containsKey(edit.id)) edit.toJson(),
      ], original);
      expect(_projection(bob.tree), expected);
      alice.dispose();
      bob.dispose();
      await _settle(tester);
      network.autoRegister = false;
      final writesBeforeReload = storage.batches.length;
      final reopened = session(actor: 'alice', storage: storage);
      await reopened.start();
      expect(_projection(reopened.tree), expected);
      expect(roomHistoryInventory(reopened.changes), inventory);
      expect(storage.batches.length, writesBeforeReload);
    },
  );

  treeTest(
    'failed personal surname save retries the same person operation after a parent change',
    (tester) async {
      final storage = store();
      final alice = session(actor: 'alice', storage: storage, creator: true);
      await alice.start();
      await _settle(tester);
      for (final id in ['father', 'mother', 'other', 'sibling']) {
        await alice.applyTreeOperation(alice.tree.createPerson(id));
      }
      for (final id in [rootTreePersonId, 'sibling']) {
        await alice.applyTreeOperation(
          alice.tree.setValue(id, 'fatherId', 'father'),
        );
        await alice.applyTreeOperation(
          alice.tree.setValue(id, 'motherId', 'mother'),
        );
      }
      final bob = session(actor: 'bob', member: false, follower: true);
      await bob.start();
      await _settleRoom(tester);
      storage.failAppend = true;
      final operation = alice.tree.setIndividualSurname(
        rootTreePersonId,
        text: 'Не потерять',
        decline: true,
      );
      final pending = alice.applyTreeOperation(operation);
      expect(
        jsonDecode(storage.authoredBatches.last.single['text'] as String),
        operation.toJson(),
      );
      await expectLater(pending, throwsStateError);
      final failed = _treeEdits(
        alice,
      ).singleWhere((edit) => jsonDecode(edit.text)['type'] == 'setSurname');
      final immutable = _immutableEdit(failed);
      expect(alice.storageError, contains('Disk full'));
      expect(alice.tree.person(rootTreePersonId)!.surname, 'Не потерять');
      expect(alice.tree.person('sibling')!.effectiveSurname, isNull);
      expect(
        alice.durableTree.person(rootTreePersonId)!.effectiveSurname,
        isNull,
      );
      await _settle(tester);
      expect(bob.tree.person(rootTreePersonId)!.effectiveSurname, isNull);
      expect(bob.tree.person('sibling')!.effectiveSurname, isNull);
      expect(
        _messages(network)
            .expand((message) => message.history)
            .any((edit) => edit.id == failed.id),
        isFalse,
      );
      await expectLater(alice.flush(), throwsStateError);
      // A remote parent change cannot retarget a pending personal operation.
      // The retry belongs to the edited person, never their old or new siblings.
      network.paused = true;
      await bob.applyTreeOperation(
        bob.tree.setValue(rootTreePersonId, 'motherId', 'other'),
      );
      storage.failAppend = false;
      network.resume();
      await _settleRoom(tester);
      await alice.flush();
      await _settleRoom(tester);
      for (final room in [alice, bob]) {
        expect(room.tree.person(rootTreePersonId)!.familySurname, isNull);
        expect(room.tree.person(rootTreePersonId)!.surname, 'Не потерять');
        expect(room.tree.person('sibling')!.effectiveSurname, isNull);
        expect(
          _treeEdits(room).singleWhere((edit) => edit.id == failed.id).toJson(),
          immutable,
        );
      }
      final attempts = storage.batches
          .expand((batch) => batch)
          .where((row) => row['id'] == failed.id)
          .toList();
      expect(attempts.length, greaterThanOrEqualTo(3));
      expect(attempts, everyElement(immutable));
      expect(
        decodeRoomHistory(
          await storage.loadHistory(_roomId),
        ).where((edit) => edit.id == failed.id),
        hasLength(1),
      );
    },
  );

  treeTest(
    'guests cannot edit or bind through either command API and create no history',
    (tester) async {
      final alice = session(actor: 'alice', creator: true);
      await alice.start();
      await _settle(tester);
      await alice.applyTreeOperation(
        alice.tree.createPerson('another', name: 'Другой'),
      );
      final bobStore = store();
      final bob = session(
        actor: 'bob',
        storage: bobStore,
        role: RoomRole.guest,
        member: false,
        follower: true,
      );
      await bob.start();
      await _settleRoom(tester);
      expect(bob.joined, isTrue);
      expect(bob.editable, isTrue);
      expect(bob.canEdit, isFalse);
      expect(bob.canBindToPerson, isFalse);
      expect(bob.canUnbindFromPerson, isFalse);
      await expectLater(bob.unbindFromPerson(), throwsStateError);
      final before = roomHistoryInventory(bob.changes);
      final batchesBefore = bobStore.batches.length;
      final packetsBefore = _messages(network).length;
      for (final operation in [
        bob.tree.createPerson('forbidden'),
        bob.tree.createSibling(rootTreePersonId, 'forbidden-sibling'),
        TreeOperation.fromJson({
          'type': 'unlinkSibling',
          'personId': rootTreePersonId,
          'siblingId': 'another',
          'linkId': 'forbidden-link',
        }),
        bob.tree.deletePerson(rootTreePersonId),
        bob.tree.setValue(rootTreePersonId, 'sex', TreeSex.female),
        TreeOperation.fromJson({
          ...bob.tree
              .setIndividualSurname(rootTreePersonId, text: 'Нельзя')
              .toJson(),
          'scope': 'family',
          'familyKey': bob.tree.surnameFamilyKey(rootTreePersonId),
        }),
        bob.tree.setIndividualSurname(rootTreePersonId, text: 'Нельзя'),
        bob.tree.setMaidenSurname(rootTreePersonId, text: 'Нельзя'),
        TreeOperation.fromJson({
          'type': 'bindActor',
          'personId': rootTreePersonId,
          'actorId': 'bob',
        }),
        bob.tree.bindActor('alice', rootTreePersonId),
        TreeOperation.fromJson({
          'type': 'unbindActor',
          'personId': rootTreePersonId,
          'actorId': 'bob',
          'bindingId': 'forbidden-release',
        }),
      ]) {
        await expectLater(bob.applyTreeOperation(operation), throwsStateError);
      }
      await expectLater(
        bob.editTreeText(rootTreePersonId, TreeTextField.name, 'Нельзя'),
        throwsStateError,
      );
      for (final id in [rootTreePersonId, 'another', 'missing']) {
        await expectLater(bob.bindToPerson(id), throwsStateError);
      }
      await _settle(tester);
      expect(bob.boundPersonId, isNull);
      expect(bob.tree.bindings, isEmpty);
      expect(bob.durableTree.bindings, isEmpty);
      expect(alice.durableTree.bindings, isEmpty);
      expect(roomHistoryInventory(bob.changes), before);
      expect(
        roomHistoryInventory(
          decodeRoomHistory(await bobStore.loadHistory(_roomId)),
        ),
        before,
      );
      expect(bobStore.batches, hasLength(batchesBefore));
      expect(_messages(network), hasLength(packetsBefore));
      expect(_treeEdits(bob).where((edit) => edit.author == 'bob'), isEmpty);
      final participant = bob.participants.singleWhere(
        (person) => person.isSelf,
      );
      expect(participant.name, 'Profile bob');
      expect(participant.personId, isNull);
      expect(participant.avatarDataUrl, isNull);
      expect(participant.role, RoomRole.guest);
    },
  );

  treeTest(
    'two actors bound to one person share online identity, person name and selected avatar',
    (tester) async {
      final alice = session(actor: 'alice', creator: true);
      await alice.start();
      await _settle(tester);
      await alice.editTreeText(
        rootTreePersonId,
        TreeTextField.name,
        'Анна Иванова',
      );
      await alice.applyTreeOperation(
        alice.tree.addPhoto(rootTreePersonId, 'avatar', dataUrl: _photo),
      );
      await alice.applyTreeOperation(
        alice.tree.setValue(rootTreePersonId, 'avatarPhotoId', 'avatar'),
      );
      final bob = session(actor: 'bob', member: false, follower: true);
      await bob.start();
      await _settleRoom(tester);
      final observer = session(
        actor: 'carol',
        role: RoomRole.guest,
        member: false,
        follower: true,
      );
      await observer.start();
      await _settleRoom(tester);
      for (final room in [alice, bob, observer]) {
        expect(room.otherOnlineCount, 2);
        expect(room.participants, hasLength(3));
      }
      await alice.bindToPerson(rootTreePersonId);
      await bob.bindToPerson(rootTreePersonId);
      await _settleRoom(tester);
      for (final room in [alice, bob, observer]) {
        expect(room.otherOnlineCount, 1);
        expect(room.participants, hasLength(2));
        final person = room.participants.singleWhere(
          (participant) => participant.personId == rootTreePersonId,
        );
        expect(
          person.name,
          'Profile ${room == observer ? 'alice' : room.actorId}',
        );
        expect(person.boundPersonFullName, 'Анна Иванова');
        expect(person.avatarDataUrl, _photo);
        expect(person.isOnline, isTrue);
        expect(person.role, RoomRole.editor);
        expect(person.isSelf, room != observer);
        if (room != observer) expect(person.actorId, room.actorId);
        expect(
          room.participants.where((participant) => participant.isSelf),
          hasLength(1),
        );
      }
      bob.dispose();
      await _settle(tester);
      expect(observer.otherOnlineCount, 1);
      expect(
        observer.participants
            .singleWhere(
              (participant) => participant.personId == rootTreePersonId,
            )
            .isOnline,
        isTrue,
      );
      alice.dispose();
      await _settle(tester);
      expect(observer.otherOnlineCount, 0);
      final offline = observer.participants.singleWhere(
        (participant) => participant.personId == rootTreePersonId,
      );
      expect(offline.isOnline, isFalse);
      expect(offline.name, 'Profile alice');
      expect(offline.boundPersonFullName, 'Анна Иванова');
      expect(offline.avatarDataUrl, _photo);
    },
  );

  treeTest(
    'legacy-bound guests keep separate plain profiles while editors still group and all raw bindings survive reload',
    (tester) async {
      final aliceStore = store();
      final alice = session(actor: 'alice', storage: aliceStore, creator: true);
      await alice.start();
      await _settle(tester);
      await alice.editTreeText(
        rootTreePersonId,
        TreeTextField.name,
        'Анна Иванова',
      );
      await alice.applyTreeOperation(
        alice.tree.addPhoto(rootTreePersonId, 'avatar', dataUrl: _photo),
      );
      await alice.applyTreeOperation(
        alice.tree.setValue(rootTreePersonId, 'avatarPhotoId', 'avatar'),
      );
      final bobStore = store();
      final bob = session(
        actor: 'bob',
        storage: bobStore,
        member: false,
        follower: true,
      );
      await bob.start();
      await _settleRoom(tester);
      final guestStores = <String, _Store>{};
      final legacyBindings = <RoomEdit>[];
      final guests = <RoomSession>[];
      for (final actor in ['carol', 'dave']) {
        final storage = store();
        guestStores[actor] = storage;
        legacyBindings.add(await _seedLegacyGuestBinding(storage, actor));
        final guest = session(
          actor: actor,
          storage: storage,
          role: RoomRole.guest,
          member: false,
          follower: true,
        );
        guests.add(guest);
        await guest.start();
        await _settleRoom(tester);
      }
      final rooms = [alice, bob, ...guests];
      for (final room in rooms) {
        expect(room.participants, hasLength(4));
        expect(room.otherOnlineCount, 3);
      }
      await alice.bindToPerson(rootTreePersonId);
      await bob.bindToPerson(rootTreePersonId);
      await _settleRoom(tester);
      final rawBindings = {
        for (final actor in ['alice', 'bob', 'carol', 'dave'])
          actor: rootTreePersonId,
      };
      final inventory = roomHistoryInventory(alice.changes);
      for (final room in rooms) {
        expect(room.participants, hasLength(3));
        expect(room.otherOnlineCount, 2);
        expect(
          room.participants.where((person) => person.isSelf),
          hasLength(1),
        );
        final editors = room.participants.singleWhere(
          (person) => person.personId == rootTreePersonId,
        );
        expect(editors.name, 'Profile ${room == bob ? 'bob' : 'alice'}');
        expect(editors.boundPersonFullName, 'Анна Иванова');
        expect(editors.avatarDataUrl, _photo);
        expect(editors.role, RoomRole.editor);
        expect(editors.isSelf, room == alice || room == bob);
        for (final actor in guestStores.keys) {
          final guest = room.participants.singleWhere(
            (person) => person.actorId == actor,
          );
          expect(guest.name, 'Profile $actor');
          expect(guest.role, RoomRole.guest);
          expect(guest.personId, isNull);
          expect(guest.avatarDataUrl, isNull);
          expect(guest.isOnline, isTrue);
          expect(guest.isSelf, room.actorId == actor);
        }
        expect(room.tree.bindings, rawBindings);
        expect(room.durableTree.bindings, rawBindings);
        expect(roomHistoryInventory(room.changes), inventory);
        for (final binding in legacyBindings) {
          expect(
            room.changes.singleWhere((edit) => edit.id == binding.id).toJson(),
            binding.toJson(),
          );
        }
      }
      for (final guest in guests) {
        expect(guest.ownRole, RoomRole.guest);
        expect(guest.boundPersonId, isNull);
        expect(guest.canBindToPerson, isFalse);
        expect(guest.canUnbindFromPerson, isFalse);
        expect(guest.boundPersonFullName, isNull);
        final before = roomHistoryInventory(guest.changes);
        await expectLater(guest.unbindFromPerson(), throwsStateError);
        await expectLater(
          guest.applyTreeOperation(guest.tree.unbindActor(guest.actorId)),
          throwsStateError,
        );
        await expectLater(
          guest.bindToPerson(rootTreePersonId),
          throwsStateError,
        );
        await expectLater(
          guest.applyTreeOperation(
            guest.tree.bindActor(guest.actorId, rootTreePersonId),
          ),
          throwsStateError,
        );
        expect(roomHistoryInventory(guest.changes), before);
      }
      for (final room in rooms) {
        await room.flush();
        room.dispose();
      }
      await _settle(tester);
      network.autoRegister = false;
      final storages = {'alice': aliceStore, 'bob': bobStore, ...guestStores};
      for (final entry in storages.entries) {
        final isGuest = guestStores.containsKey(entry.key);
        final reopened = session(
          actor: entry.key,
          storage: entry.value,
          role: RoomRole.guest,
        );
        await reopened.start();
        expect(reopened.ownRole, isGuest ? RoomRole.guest : RoomRole.editor);
        expect(reopened.canEdit, !isGuest);
        expect(reopened.boundPersonId, isGuest ? null : rootTreePersonId);
        expect(reopened.canBindToPerson, isFalse);
        expect(reopened.otherOnlineCount, 0);
        expect(reopened.participants, hasLength(3));
        expect(
          reopened.participants.singleWhere((person) => person.isSelf).personId,
          isGuest ? null : rootTreePersonId,
        );
        expect(reopened.tree.bindings, rawBindings);
        expect(reopened.durableTree.bindings, rawBindings);
        expect(roomHistoryInventory(reopened.changes), inventory);
        expect(
          roomHistoryInventory(
            decodeRoomHistory(await entry.value.loadHistory(_roomId)),
          ),
          inventory,
        );
      }
    },
  );

  for (final legacyBound in [false, true]) {
    treeTest(
      'guest promotion activates ${legacyBound ? 'a retained legacy binding' : 'one-time binding availability'} only after durable retry and survives reload',
      (tester) async {
        final aliceStore = store();
        final alice = session(
          actor: 'alice',
          storage: aliceStore,
          creator: true,
        );
        await alice.start();
        await _settle(tester);
        await alice.applyTreeOperation(alice.tree.createPerson('another'));
        await alice.bindToPerson(rootTreePersonId);
        final bobStore = store();
        final legacyBinding = legacyBound
            ? await _seedLegacyGuestBinding(bobStore, 'bob')
            : null;
        final bob = session(
          actor: 'bob',
          storage: bobStore,
          role: RoomRole.guest,
          member: false,
          follower: true,
        );
        await bob.start();
        await _settleRoom(tester);
        expect(bob.ownRole, RoomRole.guest);
        expect(bob.boundPersonId, isNull);
        expect(bob.canBindToPerson, isFalse);
        final bobBefore = roomHistoryInventory(bob.changes);
        final savedBefore = roomHistoryInventory(
          decodeRoomHistory(await aliceStore.loadHistory(_roomId)),
        );
        aliceStore.failAppend = true;
        await expectLater(alice.promoteParticipant('bob'), throwsStateError);
        final failedPromotion = alice.changes.singleWhere(
          (edit) =>
              edit.kind == RoomEditKind.participantRole &&
              edit.targetActor == 'bob' &&
              edit.text == RoomRole.editor.name,
        );
        final immutablePromotion = _immutableEdit(failedPromotion);
        expect(alice.storageError, contains('Disk full'));
        for (final room in [alice, bob]) {
          expect(room.participants, hasLength(2));
          expect(room.otherOnlineCount, 1);
          final guest = room.participants.singleWhere(
            (person) => person.actorId == 'bob',
          );
          expect(guest.role, RoomRole.guest);
          expect(guest.personId, isNull);
          expect(guest.name, 'Profile bob');
          expect(guest.avatarDataUrl, isNull);
          expect(
            room.durableTree.bindings['bob'],
            legacyBound ? rootTreePersonId : null,
          );
        }
        expect(bob.ownRole, RoomRole.guest);
        expect(bob.canEdit, isFalse);
        expect(bob.canBindToPerson, isFalse);
        expect(bob.boundPersonId, isNull);
        await expectLater(bob.bindToPerson(rootTreePersonId), throwsStateError);
        await expectLater(
          bob.applyTreeOperation(bob.tree.bindActor('bob', rootTreePersonId)),
          throwsStateError,
        );
        expect(roomHistoryInventory(bob.changes), bobBefore);
        expect(
          roomHistoryInventory(
            decodeRoomHistory(await aliceStore.loadHistory(_roomId)),
          ),
          savedBefore,
        );
        expect(
          _messages(network)
              .expand((message) => message.history)
              .any((edit) => edit.id == failedPromotion.id),
          isFalse,
        );
        await expectLater(alice.flush(), throwsStateError);
        aliceStore.failAppend = false;
        await alice.flush();
        await _settleRoom(tester);
        expect(alice.storageError, isNull);
        expect(bob.ownRole, RoomRole.editor);
        expect(bob.canEdit, isTrue);
        expect(bob.boundPersonId, legacyBound ? rootTreePersonId : null);
        expect(bob.canBindToPerson, !legacyBound);
        for (final room in [alice, bob]) {
          expect(room.participants, hasLength(legacyBound ? 1 : 2));
          expect(room.otherOnlineCount, legacyBound ? 0 : 1);
          expect(
            room.changes
                .singleWhere((edit) => edit.id == failedPromotion.id)
                .toJson(),
            immutablePromotion,
          );
          if (legacyBinding != null) {
            expect(
              room.changes
                  .singleWhere((edit) => edit.id == legacyBinding.id)
                  .toJson(),
              legacyBinding.toJson(),
            );
          }
        }
        if (!legacyBound) {
          await bob.bindToPerson(rootTreePersonId);
          await _settleRoom(tester);
        }
        final boundHistory = roomHistoryInventory(bob.changes);
        for (final id in [rootTreePersonId, 'another']) {
          await expectLater(bob.bindToPerson(id), throwsStateError);
        }
        await expectLater(
          bob.applyTreeOperation(bob.tree.bindActor('bob', 'another')),
          throwsStateError,
        );
        expect(roomHistoryInventory(bob.changes), boundHistory);
        expect(bob.boundPersonId, rootTreePersonId);
        expect(bob.canBindToPerson, isFalse);
        expect(bob.participants, hasLength(1));
        expect(bob.otherOnlineCount, 0);
        expect(bob.tree.bindings, {
          'alice': rootTreePersonId,
          'bob': rootTreePersonId,
        });
        expect(
          _treeEdits(bob).where((edit) => edit.author == 'bob'),
          hasLength(1),
        );
        final saved = decodeRoomHistory(await bobStore.loadHistory(_roomId));
        expect(
          saved.where((edit) => edit.id == failedPromotion.id),
          hasLength(1),
        );
        expect(roomHistoryInventory(saved), boundHistory);
        alice.dispose();
        bob.dispose();
        await _settle(tester);
        network.autoRegister = false;
        final reopened = session(
          actor: 'bob',
          storage: bobStore,
          role: RoomRole.guest,
        );
        await reopened.start();
        expect(reopened.ownRole, RoomRole.editor);
        expect(reopened.canEdit, isTrue);
        expect(reopened.boundPersonId, rootTreePersonId);
        expect(reopened.canBindToPerson, isFalse);
        expect(reopened.participants, hasLength(1));
        expect(reopened.tree.bindings, {
          'alice': rootTreePersonId,
          'bob': rootTreePersonId,
        });
        expect(roomHistoryInventory(reopened.changes), boundHistory);
      },
    );
  }

  treeTest(
    'aliases override bound given names while every bound tooltip keeps the full name',
    (tester) async {
      final alice = session(actor: 'alice', name: '', creator: true);
      await alice.start();
      await _settle(tester);
      expect(alice.participantName, '');
      expect(alice.participants.single.name, 'Аноним');
      expect(alice.boundPersonFullName, isNull);
      await alice.editTreeText(
        rootTreePersonId,
        TreeTextField.name,
        '  Анна  ',
      );
      await alice.applyTreeOperation(
        alice.tree.setIndividualSurname(rootTreePersonId, text: 'Иванова'),
      );
      await alice.bindToPerson(rootTreePersonId);
      expect(alice.participants.single.name, 'Анна');
      expect(alice.participants.single.boundPersonFullName, 'Анна Иванова');
      expect(alice.boundPersonFullName, 'Анна Иванова');
      final bob = session(
        actor: 'bob',
        name: 'Боб',
        member: false,
        follower: true,
      );
      await bob.start();
      await _settleRoom(tester);
      await bob.bindToPerson(rootTreePersonId);
      final observer = session(
        actor: 'carol',
        name: '',
        role: RoomRole.guest,
        member: false,
        follower: true,
      );
      await observer.start();
      await _settleRoom(tester);
      RoomParticipant bound(RoomSession room) => room.participants.singleWhere(
        (participant) => participant.personId == rootTreePersonId,
      );
      expect(bound(alice).name, 'Анна');
      expect(bound(bob).name, 'Боб');
      expect(bound(observer).actorId, 'bob');
      expect(bound(observer).name, 'Боб');
      await alice.setParticipantName('Алиса');
      await _settle(tester);
      expect(bound(alice).name, 'Алиса');
      expect(bound(bob).name, 'Боб');
      expect(bound(observer).actorId, 'alice');
      expect(bound(observer).name, 'Алиса');
      for (final room in [alice, bob, observer]) {
        expect(bound(room).boundPersonFullName, 'Анна Иванова');
      }
      await alice.setParticipantName('');
      await bob.setParticipantName('   ');
      await _settle(tester);
      for (final room in [alice, bob, observer]) {
        expect(bound(room).name, 'Анна');
        expect(bound(room).boundPersonFullName, 'Анна Иванова');
      }
      await alice.editTreeText(rootTreePersonId, TreeTextField.name, '');
      await _settle(tester);
      for (final room in [alice, bob, observer]) {
        expect(bound(room).name, 'Аноним');
        expect(bound(room).boundPersonFullName, 'Без имени Иванова');
      }
    },
  );

  treeTest(
    'own release synchronizes without changing grouped actors roles or immutable history and allows rebinding',
    (tester) async {
      final alice = session(actor: 'alice', creator: true);
      await alice.start();
      await _settle(tester);
      await alice.applyTreeOperation(alice.tree.createPerson('another'));
      await alice.bindToPerson(rootTreePersonId);
      final storage = store();
      final bob = session(
        actor: 'bob',
        storage: storage,
        member: false,
        follower: true,
      );
      await bob.start();
      await _settleRoom(tester);
      await bob.bindToPerson(rootTreePersonId);
      await _settleRoom(tester);
      final before = {for (final edit in bob.changes) edit.id: edit.toJson()};
      final oldClaim = _treeEdits(
        bob,
      ).singleWhere((edit) => edit.author == 'bob');
      expect(bob.canUnbindFromPerson, isTrue);
      expect(bob.otherOnlineCount, 0);
      network.paused = true;
      await bob.unbindFromPerson();
      expect(bob.boundPersonId, isNull);
      expect(bob.canUnbindFromPerson, isFalse);
      expect(bob.canBindToPerson, isTrue);
      expect(bob.participants, hasLength(2));
      expect(bob.otherOnlineCount, 1);
      expect(alice.participants, hasLength(1));
      network.resume();
      await _settleRoom(tester);
      for (final room in [alice, bob]) {
        expect(room.tree.bindings, {'alice': rootTreePersonId});
        expect(room.participants, hasLength(2));
        expect(room.otherOnlineCount, 1);
        expect(
          room.participants.every((p) => p.role == RoomRole.editor),
          isTrue,
        );
        for (final entry in before.entries) {
          expect(
            room.changes.singleWhere((edit) => edit.id == entry.key).toJson(),
            entry.value,
          );
        }
        final release = _treeEdits(
          room,
        ).singleWhere((edit) => jsonDecode(edit.text)['type'] == 'unbindActor');
        expect(release.author, 'bob');
        expect(jsonDecode(release.text)['bindingId'], oldClaim.id);
      }
      await bob.bindToPerson('another');
      expect(bob.boundPersonId, 'another');
      await bob.unbindFromPerson();
      await bob.bindToPerson(rootTreePersonId);
      await _settleRoom(tester);
      expect(alice.participants, hasLength(1));
      expect(alice.tree.bindings, {
        'alice': rootTreePersonId,
        'bob': rootTreePersonId,
      });
      final inventory = roomHistoryInventory(bob.changes);
      alice.dispose();
      bob.dispose();
      await _settle(tester);
      network.autoRegister = false;
      final reopened = session(actor: 'bob', storage: storage);
      await reopened.start();
      expect(reopened.boundPersonId, rootTreePersonId);
      expect(reopened.canUnbindFromPerson, isTrue);
      expect(reopened.canBindToPerson, isFalse);
      expect(reopened.participants, hasLength(1));
      expect(roomHistoryInventory(reopened.changes), inventory);
    },
  );

  treeTest(
    'failed release keeps durable grouping until the original immutable operation is retried',
    (tester) async {
      final alice = session(actor: 'alice', creator: true);
      await alice.start();
      await _settle(tester);
      await alice.bindToPerson(rootTreePersonId);
      final storage = store();
      final bob = session(
        actor: 'bob',
        storage: storage,
        member: false,
        follower: true,
      );
      await bob.start();
      await _settleRoom(tester);
      await bob.bindToPerson(rootTreePersonId);
      await _settleRoom(tester);
      storage.failAppend = true;
      await expectLater(bob.unbindFromPerson(), throwsStateError);
      final failed = _treeEdits(
        bob,
      ).singleWhere((edit) => jsonDecode(edit.text)['type'] == 'unbindActor');
      final immutable = _immutableEdit(failed);
      expect(bob.tree.bindings, {'alice': rootTreePersonId});
      expect(bob.boundPersonId, rootTreePersonId);
      expect(bob.canUnbindFromPerson, isTrue);
      expect(bob.canBindToPerson, isFalse);
      expect(bob.participants, hasLength(1));
      expect(bob.otherOnlineCount, 0);
      expect(bob.storageError, contains('Disk full'));
      await expectLater(bob.unbindFromPerson(), throwsStateError);
      expect(
        _treeEdits(
          bob,
        ).where((edit) => jsonDecode(edit.text)['type'] == 'unbindActor'),
        hasLength(1),
      );
      await _settle(tester);
      expect(alice.tree.bindings['bob'], rootTreePersonId);
      expect(
        _messages(network)
            .expand((message) => message.history)
            .any((edit) => edit.id == failed.id),
        isFalse,
      );
      storage.failAppend = false;
      await bob.unbindFromPerson();
      await _settleRoom(tester);
      for (final room in [alice, bob]) {
        expect(room.tree.bindings, {'alice': rootTreePersonId});
        expect(room.participants, hasLength(2));
        expect(room.otherOnlineCount, 1);
        expect(
          _treeEdits(room).singleWhere((edit) => edit.id == failed.id).toJson(),
          immutable,
        );
      }
      final attempts = storage.batches
          .expand((batch) => batch)
          .where((row) => row['id'] == failed.id)
          .toList();
      expect(attempts.length, greaterThanOrEqualTo(3));
      expect(attempts, everyElement(immutable));
      final saved = decodeRoomHistory(await storage.loadHistory(_roomId));
      expect(saved.where((edit) => edit.id == failed.id), hasLength(1));
    },
  );

  treeTest(
    'deleted person claims remain explicitly releasable and stale or foreign releases cannot bypass guards',
    (tester) async {
      final alice = session(actor: 'alice', creator: true);
      await alice.start();
      await _settle(tester);
      await alice.bindToPerson(rootTreePersonId);
      final oldRelease = alice.tree.unbindActor('alice');
      final foreign = TreeOperation.fromJson({
        ...oldRelease.toJson(),
        'actorId': 'bob',
      });
      await expectLater(alice.applyTreeOperation(foreign), throwsStateError);
      await alice.unbindFromPerson();
      await alice.bindToPerson(rootTreePersonId);
      final before = roomHistoryInventory(alice.changes);
      await expectLater(alice.applyTreeOperation(oldRelease), throwsStateError);
      expect(roomHistoryInventory(alice.changes), before);
      expect(alice.boundPersonId, rootTreePersonId);
      await alice.applyTreeOperation(alice.tree.deletePerson(rootTreePersonId));
      expect(alice.boundPersonId, rootTreePersonId);
      expect(alice.boundPersonFullName, isNull);
      expect(alice.canUnbindFromPerson, isTrue);
      await alice.unbindFromPerson();
      expect(alice.boundPersonId, isNull);
      expect(alice.canBindToPerson, isTrue);
      await alice.applyTreeOperation(alice.tree.createPerson('new-person'));
      await alice.bindToPerson('new-person');
      expect(alice.boundPersonId, 'new-person');
    },
  );

  treeTest(
    'failed editor binding remains available and does not deduplicate until flush retries the immutable write',
    (tester) async {
      final alice = session(actor: 'alice', creator: true);
      await alice.start();
      await _settle(tester);
      await alice.bindToPerson(rootTreePersonId);
      final bobStore = store();
      final bob = session(
        actor: 'bob',
        storage: bobStore,
        member: false,
        follower: true,
      );
      await bob.start();
      await _settleRoom(tester);
      final savedBefore = roomHistoryInventory(
        decodeRoomHistory(await bobStore.loadHistory(_roomId)),
      );
      bobStore.failAppend = true;
      await expectLater(bob.bindToPerson(rootTreePersonId), throwsStateError);
      final failed = _treeEdits(
        bob,
      ).singleWhere((edit) => edit.author == 'bob');
      final immutable = _immutableEdit(failed);
      expect(bob.storageError, contains('Disk full'));
      expect(bob.tree.bindings['bob'], rootTreePersonId);
      expect(bob.boundPersonId, isNull);
      expect(bob.canBindToPerson, isTrue);
      await _settle(tester);
      for (final room in [alice, bob]) {
        expect(room.otherOnlineCount, 1);
        expect(room.participants, hasLength(2));
      }
      expect(alice.tree.bindings.containsKey('bob'), isFalse);
      expect(
        roomHistoryInventory(
          decodeRoomHistory(await bobStore.loadHistory(_roomId)),
        ),
        savedBefore,
      );
      expect(
        _messages(network)
            .expand((message) => message.history)
            .any((edit) => edit.id == failed.id),
        isFalse,
      );
      await expectLater(bob.flush(), throwsStateError);
      expect(bob.canBindToPerson, isTrue);
      bobStore.failAppend = false;
      await bob.flush();
      await _settleRoom(tester);
      expect(bob.storageError, isNull);
      expect(bob.boundPersonId, rootTreePersonId);
      expect(bob.canBindToPerson, isFalse);
      for (final room in [alice, bob]) {
        expect(room.otherOnlineCount, 0);
        expect(room.participants, hasLength(1));
        expect(
          _treeEdits(room).singleWhere((edit) => edit.id == failed.id).toJson(),
          immutable,
        );
      }
      final attempts = bobStore.batches
          .expand((batch) => batch)
          .where((row) => row['id'] == failed.id)
          .toList();
      expect(attempts.length, greaterThanOrEqualTo(3));
      expect(attempts, everyElement(immutable));
      expect(
        decodeRoomHistory(
          await bobStore.loadHistory(_roomId),
        ).where((edit) => edit.id == failed.id),
        hasLength(1),
      );
    },
  );

  treeTest(
    'failed apply throws rather than reporting success and retries the original operation without broadcasting a draft',
    (tester) async {
      final aliceStore = store();
      final alice = session(actor: 'alice', storage: aliceStore, creator: true);
      await alice.start();
      await _settle(tester);
      final bob = session(actor: 'bob', member: false, follower: true);
      await bob.start();
      await _settleRoom(tester);
      final before = roomHistoryInventory(
        decodeRoomHistory(await aliceStore.loadHistory(_roomId)),
      );
      aliceStore.failAppend = true;
      await expectLater(
        alice.applyTreeOperation(
          alice.tree.createPerson('unsaved', name: 'Не потерять'),
        ),
        throwsStateError,
      );
      final failed = _treeEdits(alice).single;
      final immutable = _immutableEdit(failed);
      expect(alice.storageError, contains('Disk full'));
      expect(alice.tree.person('unsaved')!.name, 'Не потерять');
      expect(alice.durableTree.person('unsaved'), isNull);
      await _settle(tester);
      expect(bob.tree.person('unsaved'), isNull);
      expect(
        roomHistoryInventory(
          decodeRoomHistory(await aliceStore.loadHistory(_roomId)),
        ),
        before,
      );
      expect(
        _messages(network)
            .expand((message) => message.history)
            .any((edit) => edit.id == failed.id),
        isFalse,
      );
      await expectLater(alice.flush(), throwsStateError);
      aliceStore.failAppend = false;
      await alice.flush();
      await _settleRoom(tester);
      expect(alice.storageError, isNull);
      expect(alice.durableTree.person('unsaved')!.name, 'Не потерять');
      expect(bob.tree.person('unsaved')!.name, 'Не потерять');
      expect(_treeEdits(alice), hasLength(1));
      expect(_treeEdits(bob).single.toJson(), immutable);
      final attempts = aliceStore.batches
          .expand((batch) => batch)
          .where((row) => row['id'] == failed.id)
          .toList();
      expect(attempts.length, greaterThanOrEqualTo(3));
      expect(attempts, everyElement(immutable));
      expect(
        roomHistoryInventory(bob.changes),
        roomHistoryInventory(alice.changes),
      );
    },
  );

  treeTest(
    'root deletion wins later offline edits, keeps the full journal and bindings, and reloads an empty tree',
    (tester) async {
      final aliceStore = store();
      final alice = session(actor: 'alice', storage: aliceStore, creator: true);
      await alice.start();
      await _settle(tester);
      await alice.applyTreeOperation(
        alice.tree.createPerson('child', name: 'Ребёнок'),
      );
      await alice.applyTreeOperation(
        alice.tree.setValue('child', 'fatherId', rootTreePersonId),
      );
      await alice.applyTreeOperation(
        alice.tree.addFact(rootTreePersonId, 'fact', text: 'История'),
      );
      await alice.applyTreeOperation(
        alice.tree.addPhoto(rootTreePersonId, 'photo', dataUrl: _photo),
      );
      await alice.applyTreeOperation(
        alice.tree.setValue(rootTreePersonId, 'avatarPhotoId', 'photo'),
      );
      await alice.bindToPerson(rootTreePersonId);
      final bobStore = store();
      final bob = session(
        actor: 'bob',
        storage: bobStore,
        member: false,
        follower: true,
      );
      await bob.start();
      await _settleRoom(tester);
      await bob.bindToPerson(rootTreePersonId);
      await _settle(tester);
      final historical = roomHistoryInventory(alice.changes);
      network.paused = true;
      final deletion = alice.tree.deletePerson(rootTreePersonId);
      await alice.applyTreeOperation(deletion);
      await bob.editTreeText(
        rootTreePersonId,
        TreeTextField.name,
        'Позднее имя',
      );
      await bob.editTreeText(
        rootTreePersonId,
        TreeTextField.fact,
        'Поздний факт',
        itemId: 'fact',
      );
      await bob.editTreeText(
        rootTreePersonId,
        TreeTextField.photoCaption,
        'Поздняя подпись',
        itemId: 'photo',
      );
      await bob.applyTreeOperation(
        bob.tree.addPhoto(rootTreePersonId, 'late-photo', dataUrl: _photo),
      );
      await bob.applyTreeOperation(
        bob.tree.setValue('child', 'motherId', rootTreePersonId),
      );
      expect(alice.tree.person(rootTreePersonId), isNull);
      expect(bob.tree.person(rootTreePersonId)!.name, 'Позднее имя');
      network.resume();
      await _settleRoom(tester);
      for (final room in [alice, bob]) {
        expect(room.tree.person(rootTreePersonId), isNull);
        expect(room.tree.person('child')!.fatherId, isNull);
        expect(room.tree.person('child')!.motherId, isNull);
        expect(room.boundPersonId, rootTreePersonId);
        expect(room.canBindToPerson, isFalse);
        expect(room.tree.bindings, {
          'alice': rootTreePersonId,
          'bob': rootTreePersonId,
        });
        final participant = room.participants.single;
        expect(participant.personId, rootTreePersonId);
        expect(participant.name, 'Profile ${room.actorId}');
        expect(participant.avatarDataUrl, isNull);
        await expectLater(room.bindToPerson('child'), throwsStateError);
        await expectLater(
          room.applyTreeOperation(room.tree.bindActor(room.actorId, 'child')),
          throwsStateError,
        );
        await expectLater(
          room.applyTreeOperation(deletion),
          throwsArgumentError,
        );
        await expectLater(
          room.applyTreeOperation(
            TreeOperation.fromJson({
              'type': 'createPerson',
              'personId': rootTreePersonId,
              'name': '',
              'sex': 'unknown',
            }),
          ),
          throwsArgumentError,
        );
      }
      expect(_projection(alice.tree), _projection(bob.tree));
      await alice.applyTreeOperation(alice.tree.deletePerson('child'));
      await _settleRoom(tester);
      final inventory = roomHistoryInventory(alice.changes);
      expect(inventory.keys, containsAll(historical.keys));
      for (final storage in [aliceStore, bobStore]) {
        final saved = decodeRoomHistory(await storage.loadHistory(_roomId));
        expect(roomHistoryInventory(saved), inventory);
        final operations = saved
            .where((edit) => edit.kind == RoomEditKind.tree)
            .map((edit) => TreeOperation.fromJson(jsonDecode(edit.text)))
            .toList();
        expect(
          operations.where((operation) => operation.type == 'deletePerson'),
          hasLength(2),
        );
        expect(
          operations.where((operation) => operation.type == 'addPhoto'),
          hasLength(2),
        );
        expect(
          operations.where((operation) => operation.type == 'bindActor'),
          hasLength(2),
        );
        expect(
          operations
              .where((operation) => operation.type == 'addPhoto')
              .every((operation) => operation.toJson()['dataUrl'] == _photo),
          isTrue,
        );
      }
      for (final room in [alice, bob]) {
        expect(room.tree.people, isEmpty);
        expect(room.durableTree.people, isEmpty);
        expect(roomHistoryInventory(room.changes), inventory);
        await room.flush();
        room.dispose();
      }
      await _settle(tester);
      network.autoRegister = false;
      for (final entry in [('alice', aliceStore), ('bob', bobStore)]) {
        final reopened = session(actor: entry.$1, storage: entry.$2);
        await reopened.start();
        expect(reopened.tree.people, isEmpty);
        expect(reopened.durableTree.people, isEmpty);
        expect(reopened.boundPersonId, rootTreePersonId);
        expect(reopened.canBindToPerson, isFalse);
        expect(roomHistoryInventory(reopened.changes), inventory);
        expect(
          () => reopened.tree.createPerson(rootTreePersonId),
          throwsArgumentError,
        );
        expect(() => reopened.tree.createPerson('child'), throwsArgumentError);
      }
    },
  );

  treeTest(
    'failed deletion starts its append immediately, never broadcasts a draft and flush retries the same immutable ID',
    (tester) async {
      final storage = store();
      final alice = session(actor: 'alice', storage: storage, creator: true);
      await alice.start();
      await _settle(tester);
      await alice.applyTreeOperation(
        alice.tree.addPhoto(rootTreePersonId, 'photo', dataUrl: _photo),
      );
      final bob = session(actor: 'bob', member: false, follower: true);
      await bob.start();
      await _settleRoom(tester);
      final before = roomHistoryInventory(
        decodeRoomHistory(await storage.loadHistory(_roomId)),
      );
      final deletion = alice.tree.deletePerson(rootTreePersonId);
      storage.failAppend = true;
      final pending = alice.applyTreeOperation(deletion);
      final attempted = storage.authoredBatches.last.single;
      expect(jsonDecode(attempted['text'] as String), deletion.toJson());
      await expectLater(pending, throwsStateError);
      final failed = _treeEdits(
        alice,
      ).singleWhere((edit) => jsonDecode(edit.text)['type'] == 'deletePerson');
      final immutable = _immutableEdit(failed);
      expect(attempted, immutable);
      expect(alice.storageError, contains('Disk full'));
      expect(alice.tree.people, isEmpty);
      expect(alice.durableTree.person(rootTreePersonId), isNotNull);
      await _settle(tester);
      expect(bob.tree.person(rootTreePersonId), isNotNull);
      expect(
        roomHistoryInventory(
          decodeRoomHistory(await storage.loadHistory(_roomId)),
        ),
        before,
      );
      expect(
        _messages(network)
            .expand((message) => message.history)
            .any((edit) => edit.id == failed.id),
        isFalse,
      );
      await expectLater(
        alice.applyTreeOperation(deletion),
        throwsArgumentError,
      );
      await expectLater(alice.flush(), throwsStateError);
      storage.failAppend = false;
      await alice.flush();
      await _settleRoom(tester);
      expect(alice.storageError, isNull);
      for (final room in [alice, bob]) {
        expect(room.tree.people, isEmpty);
        expect(room.durableTree.people, isEmpty);
        expect(
          _treeEdits(
            room,
          ).where((edit) => jsonDecode(edit.text)['type'] == 'deletePerson'),
          hasLength(1),
        );
        expect(
          _treeEdits(room).singleWhere((edit) => edit.id == failed.id).toJson(),
          immutable,
        );
      }
      final attempts = storage.batches
          .expand((batch) => batch)
          .where((row) => row['id'] == failed.id)
          .toList();
      expect(attempts.length, greaterThanOrEqualTo(3));
      expect(attempts, everyElement(immutable));
      final saved = decodeRoomHistory(await storage.loadHistory(_roomId));
      expect(saved.where((edit) => edit.id == failed.id), hasLength(1));
      expect(roomHistoryInventory(saved).keys, containsAll(before.keys));
      expect(roomHistoryInventory(bob.changes), roomHistoryInventory(saved));
    },
  );

  treeTest(
    'production identity admission rejects a fully capable older welcome before history or membership',
    (tester) async {
      final storage = store();
      final room = session(
        actor: 'bob',
        name: '',
        storage: storage,
        member: false,
        follower: true,
      );
      await room.start();
      await _settle(tester);
      final outbound = network.channels.single;
      outbound.openChannel();
      await _settle(tester);
      final hello = _channelMessages(outbound).single;
      expect(hello.participantIdentity, isTrue);
      expect(hello.history, isEmpty);
      outbound.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.welcome,
          actor: 'older-tree',
          history: const [],
          online: 2,
          hosting: true,
          roomMetadata: true,
          roomRoles: true,
          familyTree: true,
          familySurnames: true,
          personalSurnames: true,
          explicitSiblings: true,
          authorHistory: true,
          durableSync: true,
        ).toJson(),
      );
      await _settle(tester);
      expect(outbound.disposed, isTrue);
      expect(room.joined, isFalse);
      expect(room.initialSyncError, contains('привязки'));
      expect(storage.membershipCalls, 0);
      expect(await storage.loadHistory(_roomId), isEmpty);
    },
  );

  for (final blankAlias in [false, true]) {
    treeTest(
      'saved ${blankAlias ? 'blank alias' : 'release'} requires identity support before a welcome preview',
      (tester) async {
        final host = session(
          actor: 'alice',
          creator: true,
          requireFamilyTree: false,
        );
        await host.start();
        await _settle(tester);
        if (blankAlias) {
          await host.setParticipantName('');
        } else {
          await host.bindToPerson(rootTreePersonId);
          await host.unbindFromPerson();
        }
        final before = roomHistoryInventory(host.changes);
        final inbound = _Channel(network, 'older-tree');
        network.registered[host.hostAlias]!.accept(inbound);
        inbound.openChannel();
        inbound.receive(
          RoomMessage(
            roomId: _roomId,
            type: RoomMessageType.hello,
            actor: 'older-tree',
            history: const [],
            roomMetadata: true,
            roomRoles: true,
            familyTree: true,
            familySurnames: true,
            personalSurnames: true,
            explicitSiblings: true,
            authorHistory: true,
            durableSync: true,
          ).toJson(),
        );
        await _settle(tester);
        expect(inbound.disposed, isTrue);
        expect(inbound.sent, isEmpty);
        expect(roomHistoryInventory(host.changes), before);
        expect(
          host.log.any(
            (line) => line.contains('привязки') && line.contains('Обновите'),
          ),
          isTrue,
        );
      },
    );

    for (final incoming in [false, true]) {
      treeTest(
        'legacy identity channel rejects ${incoming ? 'incoming' : 'outgoing'} ${blankAlias ? 'blank alias' : 'release'} without partial history',
        (tester) async {
          final host = session(
            actor: 'alice',
            creator: true,
            requireFamilyTree: false,
          );
          await host.start();
          await _settle(tester);
          await host.bindToPerson(rootTreePersonId);
          final inbound = _Channel(network, 'older-tree');
          network.registered[host.hostAlias]!.accept(inbound);
          inbound.openChannel();
          inbound.receive(
            RoomMessage(
              roomId: _roomId,
              type: RoomMessageType.hello,
              actor: 'older-tree',
              history: const [],
              roomMetadata: true,
              roomRoles: true,
              familyTree: true,
              familySurnames: true,
              personalSurnames: true,
              explicitSiblings: true,
              authorHistory: true,
            ).toJson(),
          );
          await _settle(tester);
          expect(inbound.disposed, isFalse);
          expect(
            _channelMessages(inbound)
                .singleWhere(
                  (message) => message.type == RoomMessageType.welcome,
                )
                .participantIdentity,
            isTrue,
          );
          final before = roomHistoryInventory(host.changes);
          if (incoming) {
            inbound.receive(
              RoomMessage(
                roomId: _roomId,
                type: RoomMessageType.edits,
                actor: 'older-tree',
                history: [
                  RoomEdit(
                    id: 'unnegotiated-identity',
                    author: 'older-tree',
                    clock: 100,
                    createdAt: 100,
                    text: blankAlias
                        ? ''
                        : jsonEncode(host.tree.unbindActor('alice').toJson()),
                    kind: blankAlias
                        ? RoomEditKind.participantName
                        : RoomEditKind.tree,
                  ),
                ],
              ).toJson(),
            );
          } else if (blankAlias) {
            await host.setParticipantName('');
          } else {
            await host.unbindFromPerson();
          }
          await _settle(tester);
          expect(inbound.disposed, isTrue);
          expect(
            _channelMessages(inbound)
                .expand((message) => message.history)
                .where(
                  (edit) =>
                      (edit.kind == RoomEditKind.participantName &&
                          edit.text.isEmpty) ||
                      (edit.kind == RoomEditKind.tree &&
                          jsonDecode(edit.text)['type'] == 'unbindActor'),
                ),
            isEmpty,
          );
          if (incoming) expect(roomHistoryInventory(host.changes), before);
          expect(host.log.any((line) => line.contains('Обновите')), isTrue);
        },
      );
    }
  }

  treeTest(
    'fresh profile requires author-history admission even in a legacy-compatible tree seam',
    (tester) async {
      final storage = store();
      final room = session(
        actor: 'bob',
        storage: storage,
        member: false,
        follower: true,
        requireFamilyTree: false,
      );
      await room.start();
      await _settle(tester);
      final outbound = network.channels.single;
      outbound.openChannel();
      await _settle(tester);
      outbound.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.welcome,
          actor: 'older-tree',
          history: const [
            RoomEdit(
              id: 'not-imported',
              author: 'older-tree',
              clock: 100,
              createdAt: 100,
              text: 'Do not import',
            ),
          ],
          online: 2,
          hosting: true,
          roomMetadata: true,
          roomRoles: true,
          familyTree: true,
          participantIdentity: true,
          familySurnames: true,
          personalSurnames: true,
          explicitSiblings: true,
          durableSync: true,
        ).toJson(),
      );
      await _settle(tester);
      expect(outbound.disposed, isTrue);
      expect(room.joined, isFalse);
      expect(room.initialSyncError, contains('историю автора'));
      expect(storage.membershipCalls, 0);
      expect(storage.batches, isEmpty);
      expect(storage.authoredBatches, isEmpty);
      expect(await storage.loadHistory(_roomId), isEmpty);
    },
  );

  treeTest(
    'production explicit-sibling gate rejects older capable welcome before any import',
    (tester) async {
      final storage = store();
      final room = session(
        actor: 'bob',
        storage: storage,
        member: false,
        follower: true,
      );
      await room.start();
      await _settle(tester);
      final outbound = network.channels.single;
      outbound.openChannel();
      await _settle(tester);
      final hello = _channelMessages(outbound).single;
      expect(hello.explicitSiblings, isTrue);
      expect(hello.history, isEmpty);
      outbound.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.welcome,
          actor: 'old-siblings',
          history: const [
            RoomEdit(
              id: 'not-imported',
              author: 'old-siblings',
              clock: 100,
              createdAt: 100,
              text: 'Private',
            ),
          ],
          online: 2,
          hosting: true,
          roomMetadata: true,
          roomRoles: true,
          familyTree: true,
          familySurnames: true,
          personalSurnames: true,
          authorHistory: true,
          participantIdentity: true,
          durableSync: true,
        ).toJson(),
      );
      await _settle(tester);
      expect(outbound.disposed, isTrue);
      expect(room.joined, isFalse);
      expect(room.initialSyncError, contains('прямые связи'));
      expect(storage.membershipCalls, 0);
      expect(storage.batches, isEmpty);
      expect(storage.authoredBatches, isEmpty);
      expect(await storage.loadHistory(_roomId), isEmpty);
    },
  );

  for (final kind in ['pending', 'retired', 'unlink']) {
    treeTest('known $kind sibling history rejects old hello before preview', (
      tester,
    ) async {
      final storage = store();
      final host = session(
        actor: 'alice',
        storage: storage,
        creator: true,
        requireFamilyTree: false,
      );
      await host.start();
      await _settle(tester);
      if (kind == 'retired') {
        for (final id in ['father', 'mother']) {
          await host.applyTreeOperation(host.tree.createPerson(id));
        }
      }
      storage.failAppend = kind == 'pending';
      final pending = host.applyTreeOperation(
        host.tree.createSibling(rootTreePersonId, 'b'),
      );
      if (kind == 'pending') {
        await expectLater(pending, throwsStateError);
      } else {
        await pending;
      }
      if (kind == 'retired') {
        await host.applyTreeOperation(
          host.tree.setValue(rootTreePersonId, 'fatherId', 'father'),
        );
        await host.applyTreeOperation(
          host.tree.setValue(rootTreePersonId, 'motherId', 'mother'),
        );
        expect(host.tree.directSiblingLinks, isEmpty);
      } else if (kind == 'unlink') {
        await host.applyTreeOperation(
          host.tree.unlinkSibling(rootTreePersonId, 'b'),
        );
      }
      final before = roomHistoryInventory(host.changes);
      final inbound = _Channel(network, 'old-siblings');
      network.registered[host.hostAlias]!.accept(inbound);
      inbound.openChannel();
      inbound.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.hello,
          actor: 'old-siblings',
          history: const [],
          roomMetadata: true,
          roomRoles: true,
          familyTree: true,
          familySurnames: true,
          personalSurnames: true,
          authorHistory: true,
          participantIdentity: true,
          durableSync: true,
        ).toJson(),
      );
      await _settle(tester);
      expect(inbound.disposed, isTrue);
      expect(inbound.sent, isEmpty);
      expect(roomHistoryInventory(host.changes), before);
      expect(
        host.log.any(
          (line) => line.contains('прямые связи') && line.contains('Обновите'),
        ),
        isTrue,
      );
    });
  }

  for (final incoming in [false, true]) {
    treeTest(
      'legacy channel blocks ${incoming ? 'incoming' : 'outgoing'} explicit siblings',
      (tester) async {
        final host = session(
          actor: 'alice',
          creator: true,
          requireFamilyTree: false,
        );
        await host.start();
        await _settle(tester);
        final inbound = _Channel(network, 'old-siblings');
        network.registered[host.hostAlias]!.accept(inbound);
        inbound.openChannel();
        inbound.receive(
          RoomMessage(
            roomId: _roomId,
            type: RoomMessageType.hello,
            actor: 'old-siblings',
            history: const [],
            roomMetadata: true,
            roomRoles: true,
            familyTree: true,
            familySurnames: true,
            personalSurnames: true,
            authorHistory: true,
            participantIdentity: true,
          ).toJson(),
        );
        await _settle(tester);
        expect(inbound.disposed, isFalse);
        expect(
          _channelMessages(inbound)
              .singleWhere((m) => m.type == RoomMessageType.welcome)
              .explicitSiblings,
          isTrue,
        );
        final before = roomHistoryInventory(host.changes);
        final operation = host.tree.createSibling(rootTreePersonId, 'new');
        if (incoming) {
          inbound.receive(
            RoomMessage(
              roomId: _roomId,
              type: RoomMessageType.edits,
              actor: 'old-siblings',
              history: [
                RoomEdit(
                  id: 'unsupported-sibling',
                  author: 'old-siblings',
                  clock: 100,
                  createdAt: 100,
                  text: jsonEncode(operation.toJson()),
                  kind: RoomEditKind.tree,
                ),
              ],
            ).toJson(),
          );
        } else {
          await host.applyTreeOperation(operation);
        }
        await _settle(tester);
        expect(inbound.disposed, isTrue);
        expect(
          _channelMessages(inbound)
              .expand((m) => m.history)
              .where(
                (edit) =>
                    edit.kind == RoomEditKind.tree &&
                    jsonDecode(edit.text)['type'] == 'createSibling',
              ),
          isEmpty,
        );
        if (incoming) {
          expect(roomHistoryInventory(host.changes), before);
          expect(host.tree.person('new'), isNull);
        } else {
          expect(host.durableTree.person('new'), isNotNull);
        }
        expect(
          host.log.any(
            (line) =>
                line.contains('прямые связи') && line.contains('Обновите'),
          ),
          isTrue,
        );
      },
    );
  }

  treeTest(
    'required surname admission rejects an older tree welcome before history or membership',
    (tester) async {
      final storage = store();
      final room = session(
        actor: 'bob',
        storage: storage,
        member: false,
        follower: true,
      );
      await room.start();
      await _settle(tester);
      final outbound = network.channels.single;
      outbound.openChannel();
      await _settle(tester);
      final hello = _channelMessages(outbound).single;
      expect(hello.familyTree, isTrue);
      expect(hello.familySurnames, isTrue);
      expect(hello.history, isEmpty);
      outbound.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.welcome,
          actor: 'older-tree',
          history: const [
            RoomEdit(
              id: 'not-imported',
              author: 'older-tree',
              clock: 100,
              createdAt: 100,
              text: 'Do not import',
            ),
          ],
          online: 2,
          hosting: true,
          roomMetadata: true,
          roomRoles: true,
          authorHistory: true,
          familyTree: true,
          participantIdentity: true,
          durableSync: true,
        ).toJson(),
      );
      await _settle(tester);
      expect(outbound.disposed, isTrue);
      expect(room.joined, isFalse);
      expect(room.initialSyncComplete, isFalse);
      expect(room.initialSyncError, contains('фамилии'));
      expect(room.initialSyncError, contains('Обновите'));
      expect(storage.membershipCalls, 0);
      expect(await storage.loadHistory(_roomId), isEmpty);
    },
  );

  treeTest(
    'production surname semantics reject a family-capable older welcome before any import',
    (tester) async {
      final storage = store();
      final room = session(
        actor: 'bob',
        storage: storage,
        member: false,
        follower: true,
      );
      await room.start();
      await _settle(tester);
      final outbound = network.channels.single;
      outbound.openChannel();
      await _settle(tester);
      final hello = _channelMessages(outbound).single;
      expect(hello.familySurnames, isTrue);
      expect(hello.personalSurnames, isTrue);
      expect(hello.history, isEmpty);
      outbound.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.welcome,
          actor: 'shared-surnames-client',
          history: const [
            RoomEdit(
              id: 'not-imported',
              author: 'shared-surnames-client',
              clock: 100,
              createdAt: 100,
              text: 'Do not import',
            ),
          ],
          online: 2,
          hosting: true,
          roomMetadata: true,
          roomRoles: true,
          familyTree: true,
          familySurnames: true,
          authorHistory: true,
          participantIdentity: true,
          durableSync: true,
        ).toJson(),
      );
      await _settle(tester);
      expect(outbound.disposed, isTrue);
      expect(room.joined, isFalse);
      expect(room.initialSyncComplete, isFalse);
      expect(room.initialSyncError, contains('отдельных людей'));
      expect(storage.membershipCalls, 0);
      expect(storage.batches, isEmpty);
      expect(storage.authoredBatches, isEmpty);
      expect(await storage.loadHistory(_roomId), isEmpty);
    },
  );

  for (final kind in ['legacy', 'clear', 'failed']) {
    treeTest(
      'known $kind surname requires personal semantics before welcome preview',
      (tester) async {
        final storage = store();
        if (kind == 'legacy') {
          await storage.appendHistory(_roomId, [
            RoomEdit(
              id: 'legacy-family',
              author: 'older',
              clock: 1,
              createdAt: 1,
              text: jsonEncode({
                'type': 'setSurname',
                'personId': rootTreePersonId,
                'scope': 'family',
                'familyKey': 'person:4:root',
                'text': 'Старая',
                'decline': false,
              }),
              kind: RoomEditKind.tree,
            ).toJson(),
          ]);
        }
        final host = session(
          actor: 'alice',
          storage: storage,
          creator: true,
          requireFamilyTree: false,
        );
        await host.start();
        await _settle(tester);
        if (kind != 'legacy') {
          storage.failAppend = kind == 'failed';
          final pending = host.applyTreeOperation(
            host.tree.setIndividualSurname(rootTreePersonId, text: null),
          );
          if (kind == 'failed') {
            await expectLater(pending, throwsStateError);
          } else {
            await pending;
          }
        }
        final before = roomHistoryInventory(host.changes);
        final inbound = _Channel(network, 'shared-surnames-client');
        network.registered[host.hostAlias]!.accept(inbound);
        inbound.openChannel();
        inbound.receive(
          RoomMessage(
            roomId: _roomId,
            type: RoomMessageType.hello,
            actor: 'shared-surnames-client',
            history: const [],
            roomMetadata: true,
            roomRoles: true,
            familyTree: true,
            familySurnames: true,
            authorHistory: true,
            participantIdentity: true,
            durableSync: true,
          ).toJson(),
        );
        await _settle(tester);
        expect(inbound.disposed, isTrue);
        expect(inbound.sent, isEmpty);
        expect(roomHistoryInventory(host.changes), before);
        expect(
          host.log.any(
            (line) =>
                line.contains('отдельных людей') && line.contains('Обновите'),
          ),
          isTrue,
        );
      },
    );
  }

  for (final incoming in [false, true]) {
    treeTest(
      'shared-only surname channel blocks ${incoming ? 'incoming' : 'outgoing'} personal semantics',
      (tester) async {
        final host = session(
          actor: 'alice',
          creator: true,
          requireFamilyTree: false,
        );
        await host.start();
        await _settle(tester);
        final inbound = _Channel(network, 'shared-surnames-client');
        network.registered[host.hostAlias]!.accept(inbound);
        inbound.openChannel();
        inbound.receive(
          RoomMessage(
            roomId: _roomId,
            type: RoomMessageType.hello,
            actor: 'shared-surnames-client',
            history: const [],
            roomMetadata: true,
            roomRoles: true,
            familyTree: true,
            familySurnames: true,
            authorHistory: true,
            participantIdentity: true,
          ).toJson(),
        );
        await _settle(tester);
        expect(inbound.disposed, isFalse);
        expect(
          _channelMessages(inbound)
              .singleWhere((message) => message.type == RoomMessageType.welcome)
              .personalSurnames,
          isTrue,
        );
        final before = roomHistoryInventory(host.changes);
        final operation = host.tree.setIndividualSurname(
          rootTreePersonId,
          text: null,
        );
        if (incoming) {
          inbound.receive(
            RoomMessage(
              roomId: _roomId,
              type: RoomMessageType.edits,
              actor: 'shared-surnames-client',
              history: [
                RoomEdit(
                  id: 'unnegotiated-personal',
                  author: 'shared-surnames-client',
                  clock: 100,
                  createdAt: 100,
                  text: jsonEncode(operation.toJson()),
                  kind: RoomEditKind.tree,
                ),
              ],
            ).toJson(),
          );
        } else {
          await host.applyTreeOperation(operation);
        }
        await _settle(tester);
        expect(inbound.disposed, isTrue);
        expect(
          _channelMessages(inbound)
              .expand((message) => message.history)
              .where(
                (edit) =>
                    edit.kind == RoomEditKind.tree &&
                    jsonDecode(edit.text)['type'] == 'setSurname',
              ),
          isEmpty,
        );
        if (incoming) expect(roomHistoryInventory(host.changes), before);
        expect(
          host.log.any(
            (line) =>
                line.contains('отдельных людей') && line.contains('Обновите'),
          ),
          isTrue,
        );
      },
    );
  }

  treeTest(
    'saved surname history rejects older tree hello before any preview is sent',
    (tester) async {
      final host = session(
        actor: 'alice',
        creator: true,
        requireFamilyTree: false,
      );
      await host.start();
      await _settle(tester);
      await host.applyTreeOperation(
        host.tree.setIndividualSurname(rootTreePersonId, text: 'Не раскрывать'),
      );
      final before = roomHistoryInventory(host.changes);
      final inbound = _Channel(network, 'older-tree');
      network.registered[host.hostAlias]!.accept(inbound);
      inbound.openChannel();
      inbound.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.hello,
          actor: 'older-tree',
          history: const [],
          roomMetadata: true,
          roomRoles: true,
          authorHistory: true,
          familyTree: true,
          participantIdentity: true,
          durableSync: true,
        ).toJson(),
      );
      await _settle(tester);
      expect(inbound.disposed, isTrue);
      expect(inbound.sent, isEmpty);
      expect(roomHistoryInventory(host.changes), before);
      expect(
        host.log.any(
          (line) => line.contains('фамилии') && line.contains('Обновите'),
        ),
        isTrue,
      );
    },
  );

  for (final incoming in [false, true]) {
    treeTest(
      'legacy tree capability without surname support blocks ${incoming ? 'incoming' : 'outgoing'} surname payloads',
      (tester) async {
        final host = session(
          actor: 'alice',
          creator: true,
          requireFamilyTree: false,
        );
        await host.start();
        await _settle(tester);
        final inbound = _Channel(network, 'older-tree');
        network.registered[host.hostAlias]!.accept(inbound);
        inbound.openChannel();
        inbound.receive(
          RoomMessage(
            roomId: _roomId,
            type: RoomMessageType.hello,
            actor: 'older-tree',
            history: const [],
            roomMetadata: true,
            roomRoles: true,
            authorHistory: true,
            familyTree: true,
            participantIdentity: true,
          ).toJson(),
        );
        await _settle(tester);
        expect(inbound.disposed, isFalse);
        expect(
          _channelMessages(inbound)
              .singleWhere((message) => message.type == RoomMessageType.welcome)
              .familySurnames,
          isTrue,
        );
        final before = roomHistoryInventory(host.changes);
        final operation = host.tree.setIndividualSurname(
          rootTreePersonId,
          text: 'Не передавать',
        );
        if (incoming) {
          inbound.receive(
            RoomMessage(
              roomId: _roomId,
              type: RoomMessageType.edits,
              actor: 'older-tree',
              history: [
                RoomEdit(
                  id: 'unnegotiated-surname',
                  author: 'older-tree',
                  clock: 100,
                  createdAt: 100,
                  text: jsonEncode(operation.toJson()),
                  kind: RoomEditKind.tree,
                ),
              ],
            ).toJson(),
          );
        } else {
          await host.applyTreeOperation(operation);
        }
        await _settle(tester);
        expect(inbound.disposed, isTrue);
        expect(
          _channelMessages(inbound)
              .expand((message) => message.history)
              .where(
                (edit) =>
                    edit.kind == RoomEditKind.tree &&
                    jsonDecode(edit.text)['type'] == 'setSurname',
              ),
          isEmpty,
        );
        if (incoming) {
          expect(roomHistoryInventory(host.changes), before);
          expect(host.tree.person(rootTreePersonId)!.effectiveSurname, isNull);
        } else {
          expect(
            host.durableTree.person(rootTreePersonId)!.surname,
            'Не передавать',
          );
        }
        expect(host.log.any((line) => line.contains('Обновите')), isTrue);
      },
    );
  }

  treeTest(
    'required-tree fresh admission rejects a roles-aware legacy welcome before importing history or membership',
    (tester) async {
      final storage = store();
      final room = session(
        actor: 'bob',
        storage: storage,
        member: false,
        follower: true,
      );
      await room.start();
      await _settle(tester);
      final outbound = network.channels.single;
      outbound.openChannel();
      await _settle(tester);
      final hello = _channelMessages(outbound).single;
      expect(hello.familyTree, isTrue);
      expect(hello.history, isEmpty);
      outbound.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.welcome,
          actor: 'legacy-host',
          history: const [
            RoomEdit(
              id: 'not-imported',
              author: 'legacy-host',
              clock: 100,
              createdAt: 100,
              text: 'Do not import',
            ),
          ],
          online: 2,
          hosting: true,
          roomMetadata: true,
          roomRoles: true,
          authorHistory: true,
          durableSync: true,
        ).toJson(),
      );
      await _settle(tester);
      expect(outbound.disposed, isTrue);
      expect(room.joined, isFalse);
      expect(room.initialSyncComplete, isFalse);
      expect(room.initialSyncError, contains('семейное дерево'));
      expect(storage.membershipCalls, 0);
      expect(await storage.hasMembership(_roomId), isFalse);
      expect(await storage.loadHistory(_roomId), isEmpty);
      expect(
        _channelMessages(outbound).expand((message) => message.history),
        isEmpty,
      );
    },
  );

  treeTest(
    'saved tree never leaks in hello and a tree host rejects a legacy hello before sending or importing history',
    (tester) async {
      final storage = store();
      final seed = RoomEdit(
        id: 'private-tree',
        author: 'alice',
        clock: 1,
        createdAt: 1,
        text: jsonEncode(
          TreeDocument()
              .createPerson('private-person', name: 'Секретное имя')
              .toJson(),
        ),
        kind: RoomEditKind.tree,
      );
      await storage.appendHistory(_roomId, [seed.toJson()]);
      final room = session(actor: 'alice', storage: storage, follower: true);
      await room.start();
      await _settle(tester);
      final outbound = network.channels.single;
      outbound.openChannel();
      await _settle(tester);
      final hello = _channelMessages(outbound).single;
      expect(hello.familyTree, isTrue);
      expect(hello.history, isEmpty);
      expect(jsonEncode(outbound.sent), isNot(contains('Секретное имя')));
      expect(jsonEncode(outbound.sent), isNot(contains('private-tree')));
      outbound.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.welcome,
          actor: 'legacy-host',
          history: const [],
          online: 2,
          hosting: true,
          roomMetadata: true,
          roomRoles: true,
          authorHistory: true,
        ).toJson(),
      );
      await _settle(tester);
      expect(outbound.disposed, isTrue);
      expect(room.initialSyncError, contains('семейное дерево'));
      room.dispose();
      await _settle(tester);
      final host = session(actor: 'alice', storage: storage);
      await host.start();
      await _settle(tester);
      final before = roomHistoryInventory(host.changes);
      final inbound = _Channel(network, 'legacy-client');
      network.registered[host.hostAlias]!.accept(inbound);
      inbound.openChannel();
      inbound.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.hello,
          actor: 'legacy-client',
          history: const [
            RoomEdit(
              id: 'reject-hello',
              author: 'legacy-client',
              clock: 100,
              createdAt: 100,
              text: 'Do not import',
            ),
          ],
          roomMetadata: true,
          roomRoles: true,
          authorHistory: true,
          durableSync: true,
        ).toJson(),
      );
      await _settle(tester);
      expect(inbound.disposed, isTrue);
      expect(inbound.sent, isEmpty);
      expect(roomHistoryInventory(host.changes), before);
      expect(
        roomHistoryInventory(
          decodeRoomHistory(await storage.loadHistory(_roomId)),
        ),
        before,
      );
    },
  );

  treeTest(
    'a legacy-compatible channel closes before newly durable tree history is sent',
    (tester) async {
      final host = session(
        actor: 'alice',
        creator: true,
        requireFamilyTree: false,
      );
      await host.start();
      await _settle(tester);
      final inbound = _Channel(network, 'legacy-client');
      network.registered[host.hostAlias]!.accept(inbound);
      inbound.openChannel();
      inbound.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.hello,
          actor: 'legacy-client',
          history: const [],
          roomMetadata: true,
          roomRoles: true,
          authorHistory: true,
        ).toJson(),
      );
      await _settle(tester);
      expect(inbound.disposed, isFalse);
      expect(
        _channelMessages(inbound)
            .singleWhere((message) => message.type == RoomMessageType.welcome)
            .familyTree,
        isTrue,
      );
      await host.applyTreeOperation(
        host.tree.createPerson(
          'new-person',
          name: 'Не отправлять старому клиенту',
        ),
      );
      await _settle(tester);
      expect(inbound.disposed, isTrue);
      expect(
        _channelMessages(inbound)
            .expand((message) => message.history)
            .where((edit) => edit.kind == RoomEditKind.tree),
        isEmpty,
      );
      expect(
        host.durableTree.person('new-person')!.name,
        'Не отправлять старому клиенту',
      );
    },
  );

  treeTest(
    'unnegotiated incoming tree history is rejected even in a legacy-compatible session',
    (tester) async {
      final storage = store();
      final host = session(
        actor: 'alice',
        storage: storage,
        creator: true,
        requireFamilyTree: false,
      );
      await host.start();
      await _settle(tester);
      final inbound = _Channel(network, 'legacy-client');
      network.registered[host.hostAlias]!.accept(inbound);
      inbound.openChannel();
      inbound.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.hello,
          actor: 'legacy-client',
          history: const [],
          roomMetadata: true,
          roomRoles: true,
          authorHistory: true,
        ).toJson(),
      );
      await _settle(tester);
      expect(inbound.disposed, isFalse);
      final before = roomHistoryInventory(host.changes);
      final operation = RoomEdit(
        id: 'unnegotiated-tree',
        author: 'legacy-client',
        clock: 100,
        createdAt: 100,
        text: jsonEncode(host.tree.createPerson('rejected-person').toJson()),
        kind: RoomEditKind.tree,
      );
      inbound.receive(
        RoomMessage(
          roomId: _roomId,
          type: RoomMessageType.edits,
          actor: 'legacy-client',
          history: [operation],
        ).toJson(),
      );
      await _settle(tester);
      expect(inbound.disposed, isTrue);
      expect(host.tree.person('rejected-person'), isNull);
      expect(roomHistoryInventory(host.changes), before);
      expect(
        roomHistoryInventory(
          decodeRoomHistory(await storage.loadHistory(_roomId)),
        ),
        before,
      );
    },
  );

  for (final parentField in ['fatherId', 'motherId']) {
    treeTest(
      'local raw $parentField operation cannot bypass the parent-cycle guard',
      (tester) async {
        final storage = store();
        final host = session(actor: 'alice', storage: storage, creator: true);
        await host.start();
        await _settle(tester);
        await host.applyTreeOperation(host.tree.createPerson('parent'));
        await host.applyTreeOperation(
          host.tree.setValue(rootTreePersonId, 'fatherId', 'parent'),
        );
        final before = roomHistoryInventory(host.changes);
        final projection = _projection(host.tree);
        final packetsBefore = _messages(network).length;
        final cycle = TreeOperation.fromJson({
          'type': 'setValue',
          'personId': 'parent',
          'field': parentField,
          'value': rootTreePersonId,
        });
        await expectLater(
          () => host.applyTreeOperation(cycle),
          throwsArgumentError,
        );
        await _settle(tester);
        expect(_projection(host.tree), projection);
        expect(roomHistoryInventory(host.changes), before);
        expect(
          roomHistoryInventory(
            decodeRoomHistory(await storage.loadHistory(_roomId)),
          ),
          before,
        );
        expect(_messages(network), hasLength(packetsBefore));
      },
    );
  }

  treeTest(
    'editor raw binding cannot choose another actor person on their behalf',
    (tester) async {
      final storage = store();
      final host = session(actor: 'alice', storage: storage, creator: true);
      await host.start();
      await _settle(tester);
      final before = roomHistoryInventory(host.changes);
      final operation = TreeOperation.fromJson({
        'type': 'bindActor',
        'personId': rootTreePersonId,
        'actorId': 'bob',
      });
      await expectLater(
        () => host.applyTreeOperation(operation),
        throwsStateError,
      );
      expect(host.tree.bindings, isEmpty);
      expect(host.durableTree.bindings, isEmpty);
      expect(roomHistoryInventory(host.changes), before);
      expect(
        roomHistoryInventory(
          decodeRoomHistory(await storage.loadHistory(_roomId)),
        ),
        before,
      );
    },
  );

  treeTest(
    'editor raw binding cannot bypass an already durable one-time own binding',
    (tester) async {
      final host = session(actor: 'alice', creator: true);
      await host.start();
      await _settle(tester);
      await host.applyTreeOperation(host.tree.createPerson('another'));
      await host.bindToPerson(rootTreePersonId);
      final before = roomHistoryInventory(host.changes);
      final operation = TreeOperation.fromJson({
        'type': 'bindActor',
        'personId': 'another',
        'actorId': 'alice',
      });
      await expectLater(
        () => host.applyTreeOperation(operation),
        throwsStateError,
      );
      expect(host.boundPersonId, rootTreePersonId);
      expect(roomHistoryInventory(host.changes), before);
      expect(
        _treeEdits(
          host,
        ).where((edit) => jsonDecode(edit.text)['type'] == 'bindActor'),
        hasLength(1),
      );
    },
  );

  for (final raw in <Map<String, Object?>>[
    {'type': 'deletePerson', 'personId': 'missing-person'},
    {'type': 'removeFact', 'personId': rootTreePersonId, 'itemId': 'missing'},
    {
      'type': 'setFactColor',
      'personId': rootTreePersonId,
      'itemId': 'missing',
      'color': '#D1DED9',
    },
    {
      'type': 'moveFact',
      'personId': rootTreePersonId,
      'itemId': 'missing',
      'afterId': null,
      'beforeId': null,
    },
    {'type': 'removePhoto', 'personId': rootTreePersonId, 'itemId': 'missing'},
    {
      'type': 'movePhoto',
      'personId': rootTreePersonId,
      'itemId': 'missing',
      'afterId': null,
      'beforeId': null,
    },
    {
      'type': 'addFact',
      'personId': 'missing-person',
      'itemId': 'fact',
      'text': '',
      'color': defaultTreeFactColor,
      'afterId': null,
      'beforeId': null,
    },
    {
      'type': 'addPhoto',
      'personId': 'missing-person',
      'itemId': 'photo',
      'dataUrl': _photo,
      'caption': '',
      'afterId': null,
      'beforeId': null,
    },
  ]) {
    treeTest(
      'local raw ${raw['type']} rejects unknown list or person IDs instead of silently saving a no-op',
      (tester) async {
        final storage = store();
        final host = session(actor: 'alice', storage: storage, creator: true);
        await host.start();
        await _settle(tester);
        final before = roomHistoryInventory(host.changes);
        final projection = _projection(host.tree);
        final operation = TreeOperation.fromJson(raw);
        await expectLater(
          () => host.applyTreeOperation(operation),
          throwsArgumentError,
        );
        expect(_projection(host.tree), projection);
        expect(roomHistoryInventory(host.changes), before);
        expect(
          roomHistoryInventory(
            decodeRoomHistory(await storage.loadHistory(_roomId)),
          ),
          before,
        );
      },
    );
  }
}
