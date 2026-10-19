import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/cloud/yandex_disk_client.dart';
import 'package:mytree_webrtc_demo/room_document.dart';
import 'package:mytree_webrtc_demo/room_identity.dart';
import 'package:mytree_webrtc_demo/room_protocol.dart';
import 'package:mytree_webrtc_demo/room_session.dart';
import 'package:mytree_webrtc_demo/signaling/signaling.dart';
import 'package:mytree_webrtc_demo/storage/room_store.dart';
import 'package:mytree_webrtc_demo/tree/tree_document.dart';

import 'room_disk_sync_test.dart' show MemoryDiskBackend, MemoryDiskClient;

const _roomId = '0123456789abcdef0123456789abcdef';
const _token = 'session-private-oauth-token';

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

  SignalingPeer create(
    String owner,
    String id,
    Map<String, dynamic> configuration,
  ) {
    final peer = _Peer(this, owner, id);
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
  _Peer(this.network, this.owner, this.id);

  final _Network network;
  final String owner;
  @override
  final String id;
  final attached = <_Channel>[];
  bool disposed = false;
  @override
  bool open = false;
  @override
  bool get disconnected => !open;
  @override
  String get service => 'disk-test';
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
    final current = network.registered[id];
    if (current != null && !identical(current, this) && !current.disposed) {
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
    final outgoing = _Channel(owner, target);
    network.channels.add(outgoing);
    attached.add(outgoing);
    final remote = network.registered[target];
    if (remote == null || !remote.open || remote.disposed) return outgoing;
    final incoming = _Channel(remote.owner, id);
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
  _Channel(this.owner, this.peer);

  final String owner;
  @override
  final String peer;
  @override
  bool open = false;
  @override
  bool disposed = false;
  _Channel? other;
  final sent = <Map<String, dynamic>>[];
  @override
  String get service => 'disk-test';
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
  Future<void> send(Map<String, dynamic> data) async {
    if (!open || disposed) throw StateError('Channel not open');
    final snapshot = (jsonDecode(jsonEncode(data)) as Map)
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
  bool failAppend = false;
  bool failCredentials = false;
  int failCredentialWrites = 0;
  int credentialSaveAttempts = 0;

  @override
  Future<void> appendHistory(
    String roomId,
    List<Map<String, dynamic>> operations,
  ) {
    if (failAppend) return Future.error(StateError('Local write failed'));
    return super.appendHistory(roomId, operations);
  }

  @override
  Future<void> saveDiskCredentials(
    String roomId,
    Map<String, dynamic>? value, {
    String? bindingId,
  }) {
    credentialSaveAttempts++;
    if (failCredentials || failCredentialWrites > 0) {
      if (failCredentialWrites > 0) failCredentialWrites--;
      return Future.error(StateError('Credential write failed'));
    }
    return super.saveDiskCredentials(roomId, value, bindingId: bindingId);
  }
}

class _RacingStore extends _Store {
  final stages =
      <
        ({
          Map<String, dynamic> credentials,
          String? bindingId,
          Completer<void> release,
        })
      >[];
  bool staging = true;

  @override
  Future<void> saveDiskCredentials(
    String roomId,
    Map<String, dynamic>? value, {
    String? bindingId,
  }) {
    if (!staging || value == null) {
      return super.saveDiskCredentials(roomId, value, bindingId: bindingId);
    }
    final request = (
      credentials: Map<String, dynamic>.of(value),
      bindingId: bindingId,
      release: Completer<void>(),
    );
    stages.add(request);
    if (stages.length == 2) {
      unawaited(() async {
        try {
          // Equal actor/clock claims resolve by ID. Persist the loser last so
          // the unscoped latest credentials deliberately disagree with metadata.
          final ordered = stages.toList()
            ..sort(
              (left, right) => (left.credentials['bindingId'] as String)
                  .compareTo(right.credentials['bindingId'] as String),
            );
          for (final stage in ordered) {
            await super.saveDiskCredentials(
              roomId,
              stage.credentials,
              bindingId: stage.bindingId,
            );
          }
          staging = false;
          // Neither command can append until both independent secrets exist.
          for (final stage in ordered.reversed) {
            stage.release.complete();
          }
        } catch (error, stack) {
          for (final stage in stages) {
            if (!stage.release.isCompleted) {
              stage.release.completeError(error, stack);
            }
          }
        }
      }());
    }
    return request.release.future;
  }
}

class _RecordingDiskClient extends MemoryDiskClient {
  _RecordingDiskClient(super.backend);

  final usedTokens = <String>[];

  @override
  Future<List<String>> listFiles(String token, String path) {
    usedTokens.add(token);
    return super.listFiles(token, path);
  }
}

class _TokenDiskClient extends MemoryDiskClient {
  _TokenDiskClient(super.backend, {required this.revokedTokens});

  final Set<String> revokedTokens;
  final requests = <({String operation, String token, String path})>[];

  void _request(String operation, String token, String path) {
    requests.add((operation: operation, token: token, path: path));
    if (revokedTokens.contains(token)) {
      throw const YandexDiskException(
        'Доступ к прежнему Диску отозван.',
        statusCode: 401,
      );
    }
  }

  @override
  Future<List<String>> listFiles(String token, String path) async {
    _request('list', token, path);
    return super.listFiles(token, path);
  }

  @override
  Future<Uint8List> readFile(String token, String path) async {
    _request('read', token, path);
    return super.readFile(token, path);
  }

  @override
  Future<void> writeFile(String token, String path, Uint8List bytes) async {
    _request('write', token, path);
    await super.writeFile(token, path, bytes);
  }
}

List<RoomEdit> _cloudBindingHistory(
  MemoryDiskBackend backend,
  String bindingId,
) => validateAuthorHistory([
  for (final file in backend.files.entries)
    if (file.key.startsWith('app:/mytree/$_roomId/$bindingId/batches/'))
      ...decodeRoomHistory(
        (jsonDecode(utf8.decode(file.value)) as Map)['history'],
      ),
]);

RoomEdit _role(String actor, RoomRole role, {int clock = 1}) => RoomEdit(
  id: '$actor-role',
  author: actor,
  clock: clock,
  createdAt: clock,
  text: role.name,
  kind: RoomEditKind.participantRole,
  targetActor: actor,
);

List<RoomMessage> _messages(_Channel channel) {
  final decoder = RoomMessageDecoder(roomId: _roomId);
  return [
    for (final packet in channel.sent)
      if (packet['type'] != 'diskHello' && packet['type'] != 'diskAccess')
        if (decoder.decode(packet).message case final message?) message,
  ];
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 24; i++) {
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
  late MemoryDiskBackend cloud;
  late List<RoomSession> sessions;

  setUp(() {
    network = _Network();
    cloud = MemoryDiskBackend();
    sessions = [];
  });

  RoomSession session({
    required String actor,
    _Store? store,
    RoomRole role = RoomRole.editor,
    bool member = true,
    bool creator = false,
    bool follower = false,
    MemoryDiskClient? diskClient,
  }) {
    final result = RoomSession(
      roomId: _roomId,
      actorId: actor,
      store: store ?? _Store(),
      existingMember: member,
      invitationRole: role,
      newlyCreated: creator,
      preferExistingHost: follower,
      peerFactory: (id, configuration) =>
          network.create(actor, id, configuration),
      diskClient: diskClient ?? MemoryDiskClient(cloud),
    );
    sessions.add(result);
    return result;
  }

  void diskTest(String name, Future<void> Function(WidgetTester) body) {
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
  });

  diskTest(
    'connect stores token separately; metadata, cloud and invitations never contain it',
    (tester) async {
      network.autoRegister = false;
      final store = _Store();
      final room = session(actor: 'owner', store: store, creator: true);
      await room.start();
      expect(room.canConnectDisk, isTrue);
      expect(room.diskBinding, isNull);
      await room.connectDisk(_token);
      expect(room.diskBinding, isNotNull);
      expect(room.diskBinding!.ownerActor, 'owner');
      expect(room.canConnectDisk, isFalse);
      expect(room.canDisconnectDisk, isTrue);
      final credentials = await store.loadDiskCredentials(_roomId);
      expect(credentials, {
        'v': 1,
        'bindingId': room.diskBinding!.id,
        'token': _token,
      });
      final connection = room.changes.singleWhere(
        (edit) => edit.kind == RoomEditKind.diskConnection,
      );
      expect(jsonDecode(connection.text), {'action': 'connect'});
      expect(connection.id, credentials!['bindingId']);
      expect(
        jsonEncode(await store.loadHistory(_roomId)),
        isNot(contains(_token)),
      );
      expect(
        jsonEncode(room.changes.map((edit) => edit.toJson()).toList()),
        isNot(contains(_token)),
      );
      final app = Uri.parse('https://example.test/mytree/');
      for (final role in RoomRole.values) {
        expect(
          createRoomLink(app, _roomId, role: role),
          isNot(contains(_token)),
        );
        expect(
          createRoomQrData(app, _roomId, role: role),
          isNot(contains(_token)),
        );
      }
      await room.syncDisk();
      expect(room.diskSyncError, isNull);
      expect(room.diskSyncStatus, contains('подтверждена'));
      expect(cloud.files, isNotEmpty);
      for (final bytes in cloud.files.values) {
        expect(utf8.decode(bytes), isNot(contains(_token)));
      }
    },
  );

  diskTest(
    'concurrent tab staging preserves the winning binding token across reload',
    (tester) async {
      network.autoRegister = false;
      const firstToken = 'first-tab-private-token';
      const secondToken = 'second-tab-private-token';
      final store = _RacingStore();
      await store.appendHistory(_roomId, [
        // Above wall time, below the exact-integer limit: both tabs allocate the
        // same next logical clock, so binding ID alone deterministically wins.
        _role('owner', RoomRole.editor, clock: 9007199254740000).toJson(),
      ]);
      final first = session(actor: 'owner', store: store);
      final second = session(actor: 'owner', store: store);
      await Future.wait([first.start(), second.start()]);
      await _settle(tester);
      expect(first.canConnectDisk, isTrue);
      expect(second.canConnectDisk, isTrue);
      Future<Object?> capture(Future<void> command) =>
          command.then<Object?>((_) => null, onError: (Object error) => error);
      final outcomes = await Future.wait([
        capture(first.connectDisk(firstToken)),
        capture(second.connectDisk(secondToken)),
      ]);
      await _settle(tester);
      expect(outcomes.where((error) => error == null), isNotEmpty);
      expect(store.stages, hasLength(2));
      final tokensByBinding = {
        for (final stage in store.stages)
          stage.credentials['bindingId'] as String:
              stage.credentials['token'] as String,
      };
      expect(
        tokensByBinding.values,
        unorderedEquals([firstToken, secondToken]),
      );
      final history = validateAuthorHistory(
        decodeRoomHistory(await store.loadHistory(_roomId)),
      );
      final connects =
          history
              .where((edit) => edit.kind == RoomEditKind.diskConnection)
              .toList()
            ..sort((left, right) => left.compareTo(right));
      expect(connects, hasLength(2));
      expect(connects.first.clock, connects.last.clock);
      final winner = connects.first;
      final loser = connects.last;
      expect(
        (await store.loadDiskCredentials(_roomId))!['bindingId'],
        loser.id,
        reason:
            'The last staged secret must not select the public metadata winner',
      );
      for (final edit in connects) {
        expect(await store.loadDiskCredentials(_roomId, bindingId: edit.id), {
          'v': 1,
          'bindingId': edit.id,
          'token': tokensByBinding[edit.id],
        });
      }
      final serializedHistory = jsonEncode(await store.loadHistory(_roomId));
      expect(serializedHistory, isNot(contains(firstToken)));
      expect(serializedHistory, isNot(contains(secondToken)));
      first.dispose();
      second.dispose();
      await _settle(tester);
      final client = _RecordingDiskClient(cloud);
      final reopened = session(
        actor: 'owner',
        store: store,
        diskClient: client,
      );
      await reopened.start();
      await _settle(tester);
      expect(reopened.diskBinding!.id, winner.id);
      await reopened.syncDisk();
      expect(client.usedTokens, isNotEmpty);
      expect(client.usedTokens, everyElement(tokensByBinding[winner.id]));
      expect(client.usedTokens, isNot(contains(tokensByBinding[loser.id])));
      expect(reopened.diskSyncError, isNull);
      expect(
        cloud.files.keys,
        everyElement(startsWith('app:/mytree/$_roomId/${winner.id}/batches/')),
      );
    },
  );

  diskTest(
    'credentials reload and offline edits reconstruct the cloud outbox',
    (tester) async {
      network.autoRegister = false;
      final store = _Store();
      final original = session(actor: 'owner', store: store, creator: true);
      await original.start();
      await original.connectDisk(_token);
      final bindingId = original.diskBinding!.id;
      cloud.writeFailure = StateError('Cloud offline');
      await original.edit('Durable before restart');
      await expectLater(original.syncDisk(), throwsStateError);
      expect(original.diskSyncStatus, contains('сохранены локально'));
      original.dispose();
      await _settle(tester);
      cloud.writeFailure = null;
      final reopened = session(actor: 'owner', store: store);
      await reopened.start();
      expect(reopened.diskBinding!.id, bindingId);
      expect(reopened.canDisconnectDisk, isTrue);
      expect(reopened.text, 'Durable before restart');
      await reopened.syncDisk();
      expect(reopened.diskSyncError, isNull);
      expect(reopened.diskSyncStatus, contains('подтверждена'));
      expect(
        roomHistoryInventory(cloud.uploadedHistory),
        roomHistoryInventory(reopened.changes),
      );
    },
  );

  diskTest(
    'owner and another editor claiming the same person may disconnect, others cannot',
    (tester) async {
      network.autoRegister = false;
      final ownerStore = _Store();
      await ownerStore.appendHistory(_roomId, [
        for (final actor in ['owner', 'same-person', 'other-editor'])
          _role(actor, RoomRole.editor).toJson(),
        _role('guest', RoomRole.guest).toJson(),
      ]);
      final owner = session(actor: 'owner', store: ownerStore);
      await owner.start();
      await owner.bindToPerson(rootTreePersonId);
      await owner.connectDisk(_token);
      final bindingId = owner.diskBinding!.id;
      expect(owner.canDisconnectDisk, isTrue);
      final seed = await ownerStore.loadHistory(_roomId);
      final sameStore = _Store();
      await sameStore.appendHistory(_roomId, seed);
      final samePerson = session(actor: 'same-person', store: sameStore);
      await samePerson.start();
      expect(samePerson.canDisconnectDisk, isFalse);
      await samePerson.bindToPerson(rootTreePersonId);
      expect(samePerson.boundPersonId, owner.boundPersonId);
      expect(samePerson.canDisconnectDisk, isTrue);
      final otherStore = _Store();
      await otherStore.appendHistory(_roomId, seed);
      final other = session(actor: 'other-editor', store: otherStore);
      await other.start();
      expect(other.canEdit, isTrue);
      expect(other.canDisconnectDisk, isFalse);
      await expectLater(other.disconnectDisk(), throwsStateError);
      final guestStore = _Store();
      await guestStore.appendHistory(_roomId, seed);
      final guest = session(
        actor: 'guest',
        store: guestStore,
        role: RoomRole.guest,
      );
      await guest.start();
      expect(guest.canConnectDisk, isFalse);
      expect(guest.canDisconnectDisk, isFalse);
      await expectLater(guest.connectDisk('other-token'), throwsStateError);
      await expectLater(guest.disconnectDisk(), throwsStateError);
      await expectLater(guest.syncDisk(), throwsStateError);
      await samePerson.disconnectDisk();
      expect(samePerson.diskBinding, isNull);
      final detach = samePerson.changes.lastWhere(
        (edit) => edit.kind == RoomEditKind.diskConnection,
      );
      expect(jsonDecode(detach.text), {
        'action': 'disconnect',
        'bindingId': bindingId,
      });
      expect(
        jsonEncode(await sameStore.loadHistory(_roomId)),
        isNot(contains(_token)),
      );
    },
  );

  diskTest('failed local credential write creates no public connection', (
    tester,
  ) async {
    network.autoRegister = false;
    final store = _Store()..failCredentials = true;
    final room = session(actor: 'owner', store: store, creator: true);
    await room.start();
    await expectLater(room.connectDisk(_token), throwsStateError);
    expect(room.diskBinding, isNull);
    expect(room.canConnectDisk, isTrue);
    expect(
      room.changes.where((edit) => edit.kind == RoomEditKind.diskConnection),
      isEmpty,
    );
    expect(await store.loadDiskCredentials(_roomId), isNull);
    expect(room.diskSyncError, isNot(contains(_token)));
    expect(cloud.files, isEmpty);
  });

  diskTest(
    'failed connection metadata remains private and retries one immutable binding',
    (tester) async {
      network.autoRegister = false;
      final store = _Store();
      final room = session(actor: 'owner', store: store, creator: true);
      await room.start();
      store.failAppend = true;
      await expectLater(room.connectDisk(_token), throwsStateError);
      expect(room.diskBinding, isNull);
      final staged = await store.loadDiskCredentials(_roomId);
      expect(staged!['token'], _token);
      expect(cloud.files, isEmpty);
      store.failAppend = false;
      await room.connectDisk(_token);
      expect(room.diskBinding!.id, staged['bindingId']);
      expect(
        room.changes.where((edit) => edit.kind == RoomEditKind.diskConnection),
        hasLength(1),
      );
      expect(room.diskSyncError, isNull);
    },
  );

  diskTest(
    'ready editors receive credentials, guests receive only public metadata',
    (tester) async {
      final hostStore = _Store();
      final host = session(actor: 'owner', store: hostStore, creator: true);
      await host.start();
      await _settle(tester);
      await host.connectDisk(_token);
      final editorStore = _Store();
      final editor = session(
        actor: 'editor',
        store: editorStore,
        member: false,
        follower: true,
      );
      await editor.start();
      await _settleRoom(tester);
      final guestStore = _Store();
      final guest = session(
        actor: 'guest',
        role: RoomRole.guest,
        store: guestStore,
        member: false,
        follower: true,
      );
      await guest.start();
      await _settleRoom(tester);
      expect(editor.initialSyncComplete, isTrue);
      expect(guest.initialSyncComplete, isTrue);
      expect(editor.diskBinding!.id, host.diskBinding!.id);
      expect(guest.diskBinding!.id, host.diskBinding!.id);
      expect(
        (await editorStore.loadDiskCredentials(_roomId))!['token'],
        _token,
      );
      expect(await guestStore.loadDiskCredentials(_roomId), isNull);
      expect(guest.diskSyncStatus, 'Подключён');
      final credentialMessages = [
        for (final channel in network.channels)
          for (final message in _messages(channel))
            if (message.type == RoomMessageType.diskCredentials)
              (channel, message),
      ];
      expect(credentialMessages, isNotEmpty);
      for (final (channel, message) in credentialMessages) {
        expect(channel.owner, isNot('guest'));
        expect(channel.other!.owner, isNot('guest'));
        expect(message.history, isEmpty);
        expect(message.diskBindingId, host.diskBinding!.id);
        expect(message.diskToken, _token);
        final earlier = _messages(channel).takeWhile(
          (candidate) => candidate.type != RoomMessageType.diskCredentials,
        );
        expect(
          earlier.any(
            (candidate) =>
                candidate.type == RoomMessageType.syncAck ||
                candidate.type == RoomMessageType.checkpoint,
          ),
          isTrue,
        );
      }
      for (final channel in network.channels) {
        for (final message in _messages(channel)) {
          if (message.type != RoomMessageType.diskCredentials) {
            expect(jsonEncode(message.toJson()), isNot(contains(_token)));
          }
        }
      }
      for (final store in [hostStore, editorStore, guestStore]) {
        expect(
          jsonEncode(await store.loadHistory(_roomId)),
          isNot(contains(_token)),
        );
      }
    },
  );

  diskTest(
    'credential save failure retries on a cloud round without reconnecting',
    (tester) async {
      final hostStore = _Store();
      final host = session(actor: 'owner', store: hostStore, creator: true);
      await host.start();
      await _settle(tester);
      final editorStore = _Store();
      final editor = session(
        actor: 'editor',
        store: editorStore,
        member: false,
        follower: true,
      );
      await editor.start();
      await _settleRoom(tester);
      expect(editor.initialSyncComplete, isTrue);
      editorStore.failCredentialWrites = 1;
      await host.connectDisk(_token);
      await host.syncDisk();
      await _settle(tester);
      expect(editorStore.credentialSaveAttempts, 1);
      expect(await editorStore.loadDiskCredentials(_roomId), isNull);
      expect(editor.diskSyncError, contains('сохранить доступ'));
      final channels = List<_Channel>.of(network.channels);
      final peers = List<_Peer>.of(network.peers);
      await host.syncDisk();
      await _settle(tester);
      expect(editorStore.credentialSaveAttempts, greaterThanOrEqualTo(2));
      expect(
        await editorStore.loadDiskCredentials(
          _roomId,
          bindingId: host.diskBinding!.id,
        ),
        {'v': 1, 'bindingId': host.diskBinding!.id, 'token': _token},
      );
      expect(editor.diskSyncError, isNull);
      expect(editor.initialSyncComplete, isTrue);
      expect(network.channels, channels);
      expect(network.peers, peers);
      expect(channels.every((channel) => !channel.disposed), isTrue);
      expect([
        for (final channel in channels)
          if (channel.other?.owner == 'editor')
            ..._messages(channel).where(
              (message) => message.type == RoomMessageType.diskCredentials,
            ),
      ], hasLength(greaterThanOrEqualTo(2)));
    },
  );

  for (final missingRole in ['sender', 'recipient']) {
    diskTest(
      'implicit legacy $missingRole editing rights cannot transfer credentials',
      (tester) async {
        final seed = [
          _role(
            missingRole == 'sender' ? 'editor' : 'owner',
            RoomRole.editor,
          ).toJson(),
        ];
        final hostStore = _Store();
        await hostStore.appendHistory(_roomId, seed);
        final host = session(actor: 'owner', store: hostStore);
        await host.start();
        await _settle(tester);
        expect(host.canEdit, isTrue);
        await host.connectDisk(_token);
        final editorStore = _Store();
        await editorStore.appendHistory(_roomId, seed);
        final editor = session(
          actor: 'editor',
          store: editorStore,
          follower: true,
        );
        await editor.start();
        await _settleRoom(tester);
        expect(editor.canEdit, isTrue);
        expect(editor.initialSyncComplete, isTrue);
        expect(editor.diskBinding!.id, host.diskBinding!.id);
        expect(await editorStore.loadDiskCredentials(_roomId), isNull);
        expect([
          for (final channel in network.channels)
            ..._messages(channel).where(
              (message) => message.type == RoomMessageType.diskCredentials,
            ),
        ], isEmpty);
      },
    );
  }

  diskTest('failed optimistic guest promotion cannot disclose credentials', (
    tester,
  ) async {
    final hostStore = _Store();
    final host = session(actor: 'owner', store: hostStore, creator: true);
    await host.start();
    await _settle(tester);
    final guestStore = _Store();
    final guest = session(
      actor: 'guest',
      role: RoomRole.guest,
      store: guestStore,
      member: false,
      follower: true,
    );
    await guest.start();
    await _settleRoom(tester);
    await host.connectDisk(_token);
    await _settle(tester);
    hostStore.failAppend = true;
    await expectLater(host.promoteParticipant('guest'), throwsStateError);
    await _settleRoom(tester);
    expect(guest.ownRole, RoomRole.guest);
    expect(guest.canEdit, isFalse);
    expect(await guestStore.loadDiskCredentials(_roomId), isNull);
    expect([
      for (final channel in network.channels)
        if (channel.other?.owner == 'guest')
          ..._messages(
            channel,
          ).where((message) => message.type == RoomMessageType.diskCredentials),
    ], isEmpty);
  });

  diskTest(
    'editors exchange credentials directly around a guest signaling host',
    (tester) async {
      final seed = [
        _role('guest-host', RoomRole.guest),
        _role('owner', RoomRole.editor),
        _role('observer', RoomRole.editor),
        RoomEdit(
          id: 'binding',
          author: 'owner',
          clock: 2,
          createdAt: 2,
          text: '{"action":"connect"}',
          kind: RoomEditKind.diskConnection,
        ),
      ].map((edit) => edit.toJson()).toList();
      final guestStore = _Store();
      await guestStore.appendHistory(_roomId, seed);
      final guestHost = session(
        actor: 'guest-host',
        role: RoomRole.guest,
        store: guestStore,
      );
      await guestHost.start();
      await _settle(tester);
      final ownerStore = _Store();
      await ownerStore.appendHistory(_roomId, seed);
      await ownerStore.saveDiskCredentials(_roomId, {
        'v': 1,
        'bindingId': 'binding',
        'token': _token,
      });
      final owner = session(actor: 'owner', store: ownerStore, follower: true);
      await owner.start();
      await _settleRoom(tester);
      final observerStore = _Store();
      await observerStore.appendHistory(_roomId, seed);
      final observer = session(
        actor: 'observer',
        store: observerStore,
        follower: true,
      );
      await observer.start();
      await _settleRoom(tester);
      expect(guestHost.canEdit, isFalse);
      expect(owner.canEdit, isTrue);
      expect(observer.canEdit, isTrue);
      expect(owner.initialSyncComplete, isTrue);
      expect(observer.initialSyncComplete, isTrue);
      expect(await guestStore.loadDiskCredentials(_roomId), isNull);
      expect(
        await observerStore.loadDiskCredentials(_roomId, bindingId: 'binding'),
        {'v': 1, 'bindingId': 'binding', 'token': _token},
      );
      expect(
        [
          for (final channel in network.channels)
            ..._messages(channel).where(
              (message) => message.type == RoomMessageType.diskCredentials,
            ),
        ],
        isEmpty,
        reason: 'The guest room hub never carries credential envelopes',
      );
      final directPackets = [
        for (final channel in network.channels)
          for (final packet in channel.sent)
            if (packet['type'] == 'diskAccess') (channel, packet),
      ];
      expect(directPackets, isNotEmpty);
      for (final (channel, packet) in directPackets) {
        expect(channel.peer, startsWith('mytree-disk-$_roomId-'));
        expect(channel.owner, isNot('guest-host'));
        expect(channel.other!.owner, isNot('guest-host'));
        expect(packet['bindingId'], 'binding');
        expect(packet['token'], _token);
      }
      for (final channel in network.channels) {
        if (channel.owner == 'guest-host' ||
            channel.other?.owner == 'guest-host') {
          expect(jsonEncode(channel.sent), isNot(contains(_token)));
        }
      }
      expect(
        network.peers.where(
          (peer) =>
              peer.owner == 'guest-host' && peer.id.startsWith('mytree-disk-'),
        ),
        isEmpty,
      );
      expect(observer.diskSyncStatus, isNot(contains('Ожидаем доступ')));
    },
  );

  diskTest(
    'revoked old Disk cannot block connecting and syncing a replacement',
    (tester) async {
      network.autoRegister = false;
      const oldToken = 'revoked-old-disk-token';
      const newToken = 'valid-replacement-disk-token';
      final revoked = <String>{};
      final client = _TokenDiskClient(cloud, revokedTokens: revoked);
      final store = _Store();
      final room = session(
        actor: 'owner',
        store: store,
        creator: true,
        diskClient: client,
      );
      await room.start();
      await room.connectDisk(oldToken);
      final oldBinding = room.diskBinding!.id;
      await room.edit('Before old Disk detach');
      await room.syncDisk();
      revoked.add(oldToken);
      await expectLater(room.syncDisk(), throwsStateError);
      expect(room.diskSyncError, contains('401'));
      await room.disconnectDisk();
      await expectLater(room.syncDisk(), throwsStateError);
      expect(room.diskUnlinkPending, isTrue);
      expect(room.diskSyncError, contains('401'));
      expect(
        room.canConnectDisk,
        isTrue,
        reason:
            'An unconfirmed old detach must not monopolize the active binding',
      );
      await room.connectDisk(newToken);
      final newBinding = room.diskBinding!.id;
      expect(newBinding, isNot(oldBinding));
      await room.edit('Only the replacement receives this later edit');
      await room.syncDisk();
      // A further polling round must retain the old replica's token and frozen
      // cutoff, rather than reconfiguring it with the active replacement token.
      await tester.pump(const Duration(seconds: 1));
      await _settle(tester);
      expect(room.diskBinding!.id, newBinding);
      expect(room.diskUnlinkPending, isTrue);
      expect(room.diskSyncError, contains('401'));
      expect(room.diskSyncStatus, contains('подтверждена'));
      expect(await store.loadDiskCredentials(_roomId, bindingId: oldBinding), {
        'v': 1,
        'bindingId': oldBinding,
        'token': oldToken,
      });
      expect(await store.loadDiskCredentials(_roomId, bindingId: newBinding), {
        'v': 1,
        'bindingId': newBinding,
        'token': newToken,
      });
      final oldRequests = client.requests
          .where(
            (request) =>
                request.path.startsWith('app:/mytree/$_roomId/$oldBinding/'),
          )
          .toList();
      final newRequests = client.requests
          .where(
            (request) =>
                request.path.startsWith('app:/mytree/$_roomId/$newBinding/'),
          )
          .toList();
      expect(oldRequests, isNotEmpty);
      expect(newRequests, isNotEmpty);
      expect(
        oldRequests.map((request) => request.token),
        everyElement(oldToken),
      );
      expect(
        newRequests.map((request) => request.token),
        everyElement(newToken),
      );
      expect(
        roomHistoryInventory(_cloudBindingHistory(cloud, newBinding)),
        roomHistoryInventory(room.changes),
      );
      expect(
        _cloudBindingHistory(cloud, oldBinding).any(
          (edit) =>
              edit.id == newBinding ||
              edit.text.contains('Only the replacement'),
        ),
        isFalse,
      );
      expect(
        jsonEncode(await store.loadHistory(_roomId)),
        isNot(contains(oldToken)),
      );
      expect(
        jsonEncode(await store.loadHistory(_roomId)),
        isNot(contains(newToken)),
      );
    },
  );

  diskTest(
    'restart resumes active B and archived A detach independently with frozen old cutoff',
    (tester) async {
      network.autoRegister = false;
      const oldToken = 'archived-old-disk-token';
      const newToken = 'active-new-disk-token';
      final revoked = <String>{};
      final originalClient = _TokenDiskClient(cloud, revokedTokens: revoked);
      final store = _Store();
      final original = session(
        actor: 'owner',
        store: store,
        creator: true,
        diskClient: originalClient,
      );
      await original.start();
      await original.connectDisk(oldToken);
      final oldBinding = original.diskBinding!.id;
      await original.edit('The old Disk may retain this prefix');
      await original.syncDisk();
      revoked.add(oldToken);
      await original.disconnectDisk();
      final cutoffInventory = roomHistoryInventory(original.changes);
      await expectLater(original.syncDisk(), throwsStateError);
      await original.connectDisk(newToken);
      final newBinding = original.diskBinding!.id;
      await original.edit('B edit authored after A detach');
      final bOnlyEdit = original.changes.singleWhere(
        (edit) => edit.text == 'B edit authored after A detach',
      );
      await original.syncDisk();
      expect(original.diskUnlinkPending, isTrue);
      original.dispose();
      await _settle(tester);
      final reopenedClient = _TokenDiskClient(cloud, revokedTokens: revoked);
      final reopened = session(
        actor: 'owner',
        store: store,
        diskClient: reopenedClient,
      );
      await reopened.start();
      await _settle(tester);
      expect(reopened.diskBinding!.id, newBinding);
      expect(reopened.diskUnlinkPending, isTrue);
      await reopened.syncDisk();
      await tester.pump(const Duration(seconds: 1));
      await _settle(tester);
      expect(reopened.diskBinding!.id, newBinding);
      expect(reopened.diskUnlinkPending, isTrue);
      expect(reopened.diskSyncError, contains('401'));
      expect(reopened.diskSyncStatus, contains('подтверждена'));
      expect(
        await store.loadDiskCredentials(_roomId, bindingId: oldBinding),
        isNotNull,
      );
      expect(await store.loadDiskCredentials(_roomId, bindingId: newBinding), {
        'v': 1,
        'bindingId': newBinding,
        'token': newToken,
      });
      // Retirement retries independently while B remains the active sync target.
      revoked.remove(oldToken);
      await tester.pump(const Duration(seconds: 31));
      await _settle(tester);
      expect(reopened.diskUnlinkPending, isFalse);
      expect(
        await store.loadDiskCredentials(_roomId, bindingId: oldBinding),
        isNull,
      );
      expect(await store.loadDiskCredentials(_roomId, bindingId: newBinding), {
        'v': 1,
        'bindingId': newBinding,
        'token': newToken,
      });
      expect(
        (await store.loadDiskCredentials(_roomId))!['bindingId'],
        newBinding,
      );
      expect(reopened.diskBinding!.id, newBinding);
      final oldHistory = _cloudBindingHistory(cloud, oldBinding);
      expect(roomHistoryInventory(oldHistory), cutoffInventory);
      expect(
        oldHistory.any(
          (edit) => edit.id == newBinding || edit.id == bOnlyEdit.id,
        ),
        isFalse,
      );
      expect(
        oldHistory.any(
          (edit) =>
              edit.kind == RoomEditKind.diskConnection &&
              (jsonDecode(edit.text) as Map)['action'] == 'disconnect',
        ),
        isTrue,
      );
      final oldRequests = reopenedClient.requests
          .where(
            (request) =>
                request.path.startsWith('app:/mytree/$_roomId/$oldBinding/'),
          )
          .toList();
      expect(
        oldRequests.where((request) => request.operation == 'write'),
        isNotEmpty,
      );
      expect(
        oldRequests.map((request) => request.token),
        everyElement(oldToken),
      );
      final newRequests = reopenedClient.requests
          .where(
            (request) =>
                request.path.startsWith('app:/mytree/$_roomId/$newBinding/'),
          )
          .toList();
      expect(newRequests, isNotEmpty);
      expect(
        newRequests.map((request) => request.token),
        everyElement(newToken),
      );
      await reopened.edit('B still works after scoped A credential cleanup');
      await reopened.syncDisk();
      expect(reopened.diskSyncError, isNull);
      expect(
        roomHistoryInventory(_cloudBindingHistory(cloud, newBinding)),
        roomHistoryInventory(reopened.changes),
      );
      expect(
        roomHistoryInventory(_cloudBindingHistory(cloud, oldBinding)),
        cutoffInventory,
        reason: 'Later active edits never widen the retired Disk snapshot',
      );
    },
  );

  diskTest(
    'offline disconnect retains credentials until the final cloud copy is confirmed',
    (tester) async {
      network.autoRegister = false;
      final store = _Store();
      final room = session(actor: 'owner', store: store, creator: true);
      await room.start();
      await room.connectDisk(_token);
      final binding = room.diskBinding!.id;
      await room.syncDisk();
      cloud.writeFailure = StateError('Offline');
      await room.disconnectDisk();
      expect(room.diskBinding, isNull);
      expect(room.diskSyncStatus, contains('Отвязка сохранена локально'));
      await expectLater(room.syncDisk(), throwsStateError);
      expect((await store.loadDiskCredentials(_roomId))!['bindingId'], binding);
      room.dispose();
      await _settle(tester);
      cloud.writeFailure = null;
      final reopened = session(actor: 'owner', store: store);
      await reopened.start();
      await _settle(tester);
      expect(reopened.diskBinding, isNull);
      expect(reopened.diskSyncStatus, contains('Отвязка сохранена локально'));
      await reopened.syncDisk();
      await _settle(tester);
      expect(await store.loadDiskCredentials(_roomId), isNull);
      expect(reopened.diskSyncStatus, 'Не подключён');
      expect(
        cloud.uploadedHistory.any(
          (edit) =>
              edit.kind == RoomEditKind.diskConnection &&
              (jsonDecode(edit.text) as Map)['action'] == 'disconnect',
        ),
        isTrue,
      );
    },
  );
}
