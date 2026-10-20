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
const _invitationBinding = 'invitation-binding';
const _publicUrl = 'https://disk.yandex.ru/d/invitation-binding';
const _bindingPath = 'app:/mytree/$_roomId/$_invitationBinding';

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
  bool failMembership = false;
  bool failPublicAccess = false;
  bool failFlush = false;
  String? failAuthor;
  int membershipSaveAttempts = 0;
  final actions = <String>[];
  Future<void> Function(List<Map<String, dynamic>> operations)? beforeAppend;
  Future<void> Function()? beforeMembership;
  Future<void> Function()? beforeCredentials;
  Future<void> Function()? beforePublicAccess;
  Future<void> Function()? beforeFlush;

  @override
  Future<void> appendHistory(
    String roomId,
    List<Map<String, dynamic>> operations,
  ) async {
    actions.add('history');
    await beforeAppend?.call(operations);
    if (failAppend || operations.any((edit) => edit['author'] == failAuthor)) {
      throw StateError('Local write failed');
    }
    await super.appendHistory(roomId, operations);
  }

  @override
  Future<void> saveMembership(String roomId) async {
    actions.add('membership');
    membershipSaveAttempts++;
    await beforeMembership?.call();
    if (failMembership) throw StateError('Membership write failed');
    await super.saveMembership(roomId);
  }

  @override
  Future<void> saveDiskPublicAccess(
    String roomId,
    Map<String, dynamic>? value,
  ) async {
    actions.add('public');
    await beforePublicAccess?.call();
    if (failPublicAccess) throw StateError('Public access write failed');
    await super.saveDiskPublicAccess(roomId, value);
  }

  @override
  Future<void> flush() async {
    actions.add('flush');
    await beforeFlush?.call();
    if (failFlush) throw StateError('Flush failed');
    await super.flush();
  }

  @override
  Future<void> saveDiskCredentials(
    String roomId,
    Map<String, dynamic>? value, {
    String? bindingId,
  }) async {
    actions.add('credentials');
    credentialSaveAttempts++;
    await beforeCredentials?.call();
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
  Future<List<String>> listFiles(
    String token,
    String path, {
    bool Function()? isCurrent,
    DateTime? deadline,
  }) {
    usedTokens.add(token);
    return super.listFiles(
      token,
      path,
      isCurrent: isCurrent,
      deadline: deadline,
    );
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
  Future<List<String>> listFiles(
    String token,
    String path, {
    bool Function()? isCurrent,
    DateTime? deadline,
  }) async {
    _request('list', token, path);
    return super.listFiles(
      token,
      path,
      isCurrent: isCurrent,
      deadline: deadline,
    );
  }

  @override
  Future<Uint8List> readFile(
    String token,
    String path, {
    bool Function()? isCurrent,
    DateTime? deadline,
  }) async {
    _request('read', token, path);
    return super.readFile(
      token,
      path,
      isCurrent: isCurrent,
      deadline: deadline,
    );
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

List<RoomEdit> _diskEntryHistory({RoomRole ownerRole = RoomRole.editor}) {
  final history = <RoomEdit>[];
  void append(String id, RoomEditKind kind, String text) {
    history.add(
      sequenceAuthoredEdit(
        RoomEdit(
          id: id,
          author: 'owner',
          clock: history.length + 1,
          createdAt: history.length + 1,
          text: text,
          kind: kind,
          targetActor: kind == RoomEditKind.participantRole ? 'owner' : null,
        ),
        history,
      ),
    );
  }

  append('owner-role', RoomEditKind.participantRole, ownerRole.name);
  append('cloud-name', RoomEditKind.roomName, 'Cloud family');
  append('cloud-alias', RoomEditKind.participantName, 'Owner');
  append(
    'cloud-person',
    RoomEditKind.tree,
    jsonEncode(TreeDocument().createPerson('cloud-person').toJson()),
  );
  append(
    _invitationBinding,
    RoomEditKind.diskConnection,
    '{"action":"connect"}',
  );
  append('cloud-tail', RoomEditKind.text, 'The complete cloud journal');
  return history;
}

RoomDiskAccess _entryAccess(RoomRole role) => role == RoomRole.editor
    ? RoomDiskAccess.editor(bindingId: _invitationBinding, token: _token)
    : RoomDiskAccess.guest(
        bindingId: _invitationBinding,
        publicUrl: _publicUrl,
      );

class _PublishingDiskClient extends MemoryDiskClient {
  _PublishingDiskClient(super.backend);

  Future<void> Function()? beforePublish;
  final publicationAttempts = <String>[];

  @override
  Future<String> publishDirectory(String token, String path) async {
    publicationAttempts.add(path);
    await beforePublish?.call();
    return super.publishDirectory(token, path);
  }
}

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
    RoomDiskAccess? access,
    String? name,
  }) {
    final result = RoomSession(
      roomId: _roomId,
      actorId: actor,
      store: store ?? _Store(),
      existingMember: member,
      invitationRole: role,
      invitationDiskAccess: access,
      participantName: name,
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

  void seedCloud({List<RoomEdit>? history}) {
    cloud.publicRoots[_publicUrl] = _bindingPath;
    cloud.addBatch(
      history ?? _diskEntryHistory(),
      bindingId: _invitationBinding,
      directory: '$_bindingPath/batches',
    );
  }

  for (final role in RoomRole.values) {
    diskTest(
      'first-time ${role.name} enters from Disk without an online peer',
      (tester) async {
        network.autoRegister = false;
        seedCloud();
        final store = _Store();
        final room = session(
          actor: 'new-${role.name}',
          store: store,
          member: false,
          role: role,
          access: _entryAccess(role),
          name: 'New participant',
        );
        await room.start();
        await _settle(tester);
        expect(room.joined, isTrue);
        expect(room.initialSyncComplete, isTrue);
        expect(room.initialSyncStatus, contains('загружена с Диска'));
        expect(room.initialSyncStatus, contains('онлайн-сверка'));
        expect(room.initialSyncError, isNull);
        expect(room.hasValidatedOnlinePeer, isFalse);
        expect(room.connectedToRemoteHost, isFalse);
        expect(room.networkAvailable, isFalse);
        expect(room.onlineCount, 1);
        expect(room.ownRole, role);
        expect(room.canEdit, role == RoomRole.editor);
        expect(room.roomName, 'Cloud family');
        expect(room.text, 'The complete cloud journal');
        expect(room.tree.person('cloud-person'), isNotNull);
        expect(room.participantName, 'New participant');
        expect(room.diskBinding!.id, _invitationBinding);
        expect(await store.hasMembership(_roomId), isTrue);
        final durable = validateAuthorHistory(
          decodeRoomHistory(await store.loadHistory(_roomId)),
        );
        expect(
          roomHistoryInventory(durable),
          roomHistoryInventory(room.changes),
        );
        expect(
          _diskEntryHistory().every(
            (edit) => durable.any((saved) => saved.sameContentAs(edit)),
          ),
          isTrue,
        );
        expect(
          durable.any((edit) => edit.author == 'new-${role.name}'),
          isTrue,
        );
        expect(store.actions.last, 'membership');
        expect(cloud.created, isEmpty);
        expect(cloud.written, isEmpty);
        expect(cloud.published, isEmpty);
        expect(network.peers, isNotEmpty, reason: 'RTC starts after admission');
        expect(network.channels, isEmpty);
        if (role == RoomRole.editor) {
          expect(
            await store.loadDiskCredentials(_roomId),
            _entryAccess(role).toJson(),
          );
          expect(await store.loadDiskPublicAccess(_roomId), isNull);
          expect(cloud.publicUrls, isEmpty);
        } else {
          expect(await store.loadDiskCredentials(_roomId), isNull);
          expect(
            await store.loadDiskPublicAccess(_roomId),
            _entryAccess(role).toJson(),
          );
          expect(store.credentialSaveAttempts, 0);
          expect(cloud.listed, isEmpty);
          expect(cloud.read, isEmpty);
          expect(cloud.publicUrls, everyElement(_publicUrl));
          expect(room.diskSyncAcknowledged, isFalse);
        }
        expect(
          jsonEncode(durable.map((edit) => edit.toJson()).toList()),
          isNot(contains(_token)),
        );
        expect(room.log.join('\n'), isNot(contains(_token)));
      },
    );

    diskTest('stored ${role.name} access verifies cloud again after reload', (
      tester,
    ) async {
      network.autoRegister = false;
      seedCloud();
      final store = _Store();
      final first = session(
        actor: 'reader',
        store: store,
        member: false,
        role: role,
        access: _entryAccess(role),
      );
      await first.start();
      first.dispose();
      await _settle(tester);
      final history = _diskEntryHistory();
      final later = sequenceAuthoredEdit(
        const RoomEdit(
          id: 'cloud-later',
          author: 'owner',
          clock: 20,
          createdAt: 20,
          text: 'A later cloud-only change',
        ),
        history,
      );
      seedCloud(history: [...history, later]);
      final reopened = session(actor: 'reader', store: store, role: role);
      await reopened.start();
      expect(reopened.joined, isTrue);
      expect(reopened.initialSyncComplete, isTrue);
      expect(reopened.initialSyncStatus, contains('с Диска'));
      expect(reopened.text, 'A later cloud-only change');
      expect(reopened.hasValidatedOnlinePeer, isFalse);
      expect(cloud.written, isEmpty);
      expect(cloud.published, isEmpty);
      expect(
        decodeRoomHistory(
          await store.loadHistory(_roomId),
        ).any((edit) => edit.sameContentAs(later)),
        isTrue,
      );
    });
  }

  for (final stage in [
    'history',
    'profile',
    'credentials',
    'public',
    'flush',
    'membership',
  ]) {
    diskTest('Disk admission waits for durable $stage before reporting ready', (
      tester,
    ) async {
      network.autoRegister = false;
      seedCloud();
      final store = _Store();
      final release = Completer<void>();
      if (stage == 'history' || stage == 'profile') {
        store.beforeAppend = (edits) async {
          if (stage == 'history' ||
              edits.any((edit) => edit['author'] == 'newcomer')) {
            await release.future;
          }
        };
      } else if (stage == 'credentials') {
        store.beforeCredentials = () => release.future;
      } else if (stage == 'public') {
        store.beforePublicAccess = () => release.future;
      } else if (stage == 'flush') {
        store.beforeFlush = () => release.future;
      } else {
        store.beforeMembership = () => release.future;
      }
      final role = stage == 'public' ? RoomRole.guest : RoomRole.editor;
      final room = session(
        actor: 'newcomer',
        store: store,
        member: false,
        role: role,
        access: _entryAccess(role),
        name: 'Newcomer',
      );
      final starting = room.start();
      await _settle(tester);
      expect(room.joined, isFalse);
      expect(room.initialSyncComplete, isFalse);
      expect(room.editable, isFalse);
      expect(network.peers, isEmpty);
      expect(await store.hasMembership(_roomId), isFalse);
      expect(cloud.written, isEmpty);
      expect(cloud.created, isEmpty);
      release.complete();
      await starting;
      expect(room.joined, isTrue);
      expect(room.initialSyncComplete, isTrue);
      expect(await store.hasMembership(_roomId), isTrue);
      expect(store.actions.last, 'membership');
    });
  }

  for (final failure in [
    'history',
    'profile',
    'credentials',
    'public',
    'flush',
    'membership',
  ]) {
    diskTest('failed $failure never admits a Disk invitation and can retry', (
      tester,
    ) async {
      network.autoRegister = false;
      seedCloud();
      final store = _Store()
        ..failAppend = failure == 'history'
        ..failAuthor = failure == 'profile' ? 'newcomer' : null
        ..failCredentials = failure == 'credentials'
        ..failPublicAccess = failure == 'public'
        ..failFlush = failure == 'flush'
        ..failMembership = failure == 'membership';
      final role = failure == 'public' ? RoomRole.guest : RoomRole.editor;
      final room = session(
        actor: 'newcomer',
        store: store,
        member: false,
        role: role,
        access: _entryAccess(role),
        name: 'Newcomer',
      );
      await room.start();
      expect(room.joined, isFalse);
      expect(room.initialSyncComplete, isFalse);
      expect(await store.hasMembership(_roomId), isFalse);
      expect(room.initialSyncError, isNotNull);
      expect(room.diskSyncError ?? room.storageError, isNotNull);
      expect(cloud.written, isEmpty);
      expect(cloud.published, isEmpty);
      if (failure == 'history' || failure == 'profile' || failure == 'flush') {
        expect(room.storageError, isNotNull);
      }
      store
        ..failAppend = false
        ..failAuthor = null
        ..failCredentials = false
        ..failPublicAccess = false
        ..failFlush = false
        ..failMembership = false;
      await room.retry();
      await _settle(tester);
      expect(room.joined, isTrue);
      expect(room.initialSyncComplete, isTrue);
      expect(room.initialSyncStatus, contains('с Диска'));
      expect(await store.hasMembership(_roomId), isTrue);
      expect(room.initialSyncError, isNull);
    });
  }

  for (final invalid in [
    'detached',
    'implicit-owner',
    'guest-owner',
    'broken-proof',
    'wrong-envelope',
    'empty',
  ]) {
    diskTest('invalid $invalid cloud snapshot cannot grant membership', (
      tester,
    ) async {
      network.autoRegister = false;
      var history = _diskEntryHistory(
        ownerRole: invalid == 'guest-owner' ? RoomRole.guest : RoomRole.editor,
      );
      if (invalid == 'detached') {
        history = [
          ...history,
          sequenceAuthoredEdit(
            const RoomEdit(
              id: 'detach',
              author: 'owner',
              clock: 30,
              createdAt: 30,
              kind: RoomEditKind.diskConnection,
              text: '{"action":"disconnect","bindingId":"invitation-binding"}',
            ),
            history,
          ),
        ];
      } else if (invalid == 'implicit-owner') {
        history = [
          for (final edit in history)
            if (edit.kind != RoomEditKind.participantRole)
              RoomEdit(
                id: edit.id,
                author: edit.author,
                clock: edit.clock,
                createdAt: edit.createdAt,
                kind: edit.kind,
                text: edit.text,
              ),
        ];
      } else if (invalid == 'broken-proof') {
        history = [
          ...history.take(history.length - 1),
          history.last.withAuthorProof(
            authorSequence: history.last.authorSequence!,
            authorPrevious: 'missing-predecessor',
          ),
        ];
      }
      if (invalid == 'wrong-envelope') {
        cloud.addBatch(
          history,
          roomId: 'ffffffffffffffffffffffffffffffff',
          bindingId: _invitationBinding,
          directory: '$_bindingPath/batches',
        );
      } else if (invalid != 'empty') {
        seedCloud(history: history);
      }
      final store = _Store();
      final room = session(
        actor: 'newcomer',
        store: store,
        member: false,
        access: _entryAccess(RoomRole.editor),
      );
      await room.start();
      expect(room.joined, isFalse);
      expect(room.initialSyncComplete, isFalse);
      expect(room.initialSyncError, isNotNull);
      expect(await store.hasMembership(_roomId), isFalse);
      expect(await store.loadDiskCredentials(_roomId), isNull);
      expect(store.membershipSaveAttempts, 0);
      expect(await store.loadHistory(_roomId), isEmpty);
      expect(cloud.created, isEmpty);
      expect(cloud.written, isEmpty);
      expect(cloud.published, isEmpty);
    });
  }

  diskTest('a locally known detach invalidates an older invitation snapshot', (
    tester,
  ) async {
    network.autoRegister = false;
    final history = _diskEntryHistory();
    seedCloud(history: history);
    final detached = sequenceAuthoredEdit(
      const RoomEdit(
        id: 'locally-detached',
        author: 'owner',
        clock: 50,
        createdAt: 50,
        kind: RoomEditKind.diskConnection,
        text: '{"action":"disconnect","bindingId":"invitation-binding"}',
      ),
      history,
    );
    final store = _Store();
    await store.appendHistory(_roomId, [
      for (final edit in [...history, detached]) edit.toJson(),
    ]);
    final room = session(
      actor: 'newcomer',
      store: store,
      member: false,
      access: _entryAccess(RoomRole.editor),
    );
    await room.start();
    expect(room.joined, isFalse);
    expect(room.diskBinding, isNull);
    expect(room.initialSyncComplete, isFalse);
    expect(await store.hasMembership(_roomId), isFalse);
    expect(store.credentialSaveAttempts, 0);
    expect(cloud.written, isEmpty);
  });

  diskTest(
    'cancelling an in-flight cloud read cannot save a profile or membership',
    (tester) async {
      network.autoRegister = false;
      seedCloud();
      final release = Completer<void>();
      cloud.beforeRead = (_) => release.future;
      final store = _Store();
      final room = session(
        actor: 'cancelled',
        store: store,
        member: false,
        access: _entryAccess(RoomRole.editor),
        name: 'Cancelled',
      );
      final starting = room.start();
      await _settle(tester);
      expect(cloud.read, isNotEmpty);
      room.dispose();
      release.complete();
      await starting;
      expect(room.joined, isFalse);
      expect(room.initialSyncComplete, isFalse);
      expect(await store.loadHistory(_roomId), isEmpty);
      expect(await store.hasMembership(_roomId), isFalse);
      expect(store.credentialSaveAttempts, 0);
      expect(network.peers, isEmpty);
    },
  );

  diskTest(
    'retry supersedes a pending cloud attempt without duplicate membership',
    (tester) async {
      network.autoRegister = false;
      seedCloud();
      final release = Completer<void>();
      cloud.beforeList = (_) => release.future;
      final store = _Store();
      final room = session(
        actor: 'newcomer',
        store: store,
        member: false,
        access: _entryAccess(RoomRole.editor),
      );
      final starting = room.start();
      await _settle(tester);
      final retrying = room.retry();
      await _settle(tester);
      expect(store.membershipSaveAttempts, 0);
      cloud.beforeList = null;
      release.complete();
      await Future.wait([starting, retrying]);
      expect(room.joined, isTrue);
      expect(room.initialSyncComplete, isTrue);
      expect(store.membershipSaveAttempts, 1);
      expect(cloud.read, hasLength(1));
    },
  );

  diskTest('the original 30-second watchdog cannot admit a late cloud result', (
    tester,
  ) async {
    network.autoRegister = false;
    seedCloud();
    final release = Completer<void>();
    cloud.beforeRead = (_) => release.future;
    final store = _Store();
    final room = session(
      actor: 'late',
      store: store,
      member: false,
      access: _entryAccess(RoomRole.editor),
    );
    final starting = room.start();
    await _settle(tester);
    await tester.pump(const Duration(seconds: 31));
    expect(room.initialSyncComplete, isFalse);
    expect(room.initialSyncError, contains('30 секунд'));
    release.complete();
    await starting;
    expect(room.joined, isFalse);
    expect(await store.hasMembership(_roomId), isFalse);
    expect(store.membershipSaveAttempts, 0);
    expect(await store.loadHistory(_roomId), isEmpty);
  });

  diskTest('cloud errors are safe, leave RTC available, and retry cloud', (
    tester,
  ) async {
    network.autoRegister = false;
    seedCloud();
    cloud.beforeList = (_) =>
        Future.error(StateError('$_token $_publicUrl raw response'));
    final store = _Store();
    final room = session(
      actor: 'newcomer',
      store: store,
      member: false,
      access: _entryAccess(RoomRole.editor),
    );
    await room.start();
    expect(room.joined, isFalse);
    expect(room.initialSyncComplete, isFalse);
    expect(room.initialSyncError, contains('Диска'));
    expect(network.peers, isNotEmpty);
    expect(room.diskSyncError, isNotNull);
    expect(
      '${room.initialSyncError} ${room.diskSyncError} ${room.log}',
      isNot(contains(_token)),
    );
    expect(
      '${room.initialSyncError} ${room.diskSyncError} ${room.log}',
      isNot(contains(_publicUrl)),
    );
    cloud.beforeList = null;
    await room.retry();
    expect(room.joined, isTrue);
    expect(room.initialSyncComplete, isTrue);
    expect(room.initialSyncError, isNull);
    expect(room.diskSyncError, isNull);
    expect(cloud.listed.length, greaterThanOrEqualTo(2));
  });

  diskTest(
    'an unaccepted guest profile keeps its original role and retains no editor token',
    (tester) async {
      network.autoRegister = false;
      seedCloud();
      final store = _Store();
      await store.appendHistory(_roomId, [
        _role('returning', RoomRole.guest).toJson(),
      ]);
      final room = session(
        actor: 'returning',
        store: store,
        member: false,
        role: RoomRole.editor,
        access: _entryAccess(RoomRole.editor),
      );
      await room.start();
      expect(room.joined, isTrue);
      expect(room.initialSyncComplete, isTrue);
      expect(room.ownRole, RoomRole.guest);
      expect(room.canEdit, isFalse);
      expect(room.canPublishDiskInvitation, isFalse);
      expect(await store.loadDiskCredentials(_roomId), isNull);
      expect(store.credentialSaveAttempts, 0);
      expect(
        room.changes
            .where((edit) => edit.targetActor == 'returning')
            .map((edit) => edit.text),
        ['guest'],
      );
      await tester.pump(const Duration(seconds: 31));
      await _settle(tester);
      expect(cloud.written, isEmpty);
    },
  );

  diskTest(
    'accepted guest editor invitation saves promotion before retaining Disk token',
    (tester) async {
      network.autoRegister = false;
      seedCloud();
      final store = _Store();
      await store.saveMembership(_roomId);
      await store.appendHistory(_roomId, [
        _role('returning', RoomRole.guest).toJson(),
      ]);
      final release = Completer<void>();
      store.beforeAppend = (edits) async {
        if (edits.any(
          (e) => e['author'] == 'returning' && e['text'] == 'editor',
        )) {
          await release.future;
        }
      };
      final room = session(
        actor: 'returning',
        store: store,
        role: RoomRole.editor,
        access: _entryAccess(RoomRole.editor),
      );
      var credentialChecked = false;
      store.beforeCredentials = () async {
        final saved = RoomDocument()
          ..merge(decodeRoomHistory(await store.loadHistory(_roomId)));
        expect(saved.participantRoles['returning'], RoomRole.editor);
        credentialChecked = true;
      };
      var started = false;
      final starting = room.start().then((_) => started = true);
      await _settle(tester);
      expect(started, isFalse);
      expect(room.joined, isTrue);
      expect(room.canEdit, isFalse);
      expect(room.initialSyncComplete, isFalse);
      expect(store.credentialSaveAttempts, 0);
      expect(await store.loadDiskCredentials(_roomId), isNull);
      release.complete();
      await starting;
      expect(credentialChecked, isTrue);
      expect(room.canEdit, isTrue);
      expect(room.initialSyncComplete, isTrue);
      expect(
        (await store.loadDiskCredentials(_roomId))?['bindingId'],
        _invitationBinding,
      );
      expect(
        room.changes.where(
          (e) => e.targetActor == 'returning' && e.text == 'editor',
        ),
        hasLength(1),
      );
      await room.retry();
      expect(
        room.changes.where(
          (e) => e.targetActor == 'returning' && e.text == 'editor',
        ),
        hasLength(1),
      );
    },
  );

  diskTest(
    'failed invited guest promotion cannot retain token and retry reuses its role edit',
    (tester) async {
      network.autoRegister = false;
      seedCloud();
      final store = _Store();
      await store.saveMembership(_roomId);
      await store.appendHistory(_roomId, [
        _role('returning', RoomRole.guest).toJson(),
      ]);
      store.failAuthor = 'returning';
      final room = session(
        actor: 'returning',
        store: store,
        role: RoomRole.editor,
        access: _entryAccess(RoomRole.editor),
      );
      await room.start();
      expect(room.canEdit, isFalse);
      expect(room.initialSyncComplete, isFalse);
      expect(room.storageError, isNotNull);
      expect(store.credentialSaveAttempts, 0);
      expect(await store.loadDiskCredentials(_roomId), isNull);
      final pending = room.changes.singleWhere(
        (e) => e.targetActor == 'returning' && e.text == 'editor',
      );
      store.failAuthor = null;
      await room.retry();
      expect(room.canEdit, isTrue);
      expect(room.initialSyncComplete, isTrue);
      expect(
        (await store.loadDiskCredentials(_roomId))?['bindingId'],
        _invitationBinding,
      );
      expect(
        room.changes
            .where((e) => e.targetActor == 'returning' && e.text == 'editor')
            .single
            .id,
        pending.id,
      );
    },
  );

  diskTest(
    'public guest polling and resume read updates without uploads or private requests',
    (tester) async {
      network.autoRegister = false;
      seedCloud();
      final store = _Store();
      final room = session(
        actor: 'guest',
        store: store,
        member: false,
        role: RoomRole.guest,
        access: _entryAccess(RoomRole.guest),
      );
      await room.start();
      final history = _diskEntryHistory();
      final update = sequenceAuthoredEdit(
        const RoomEdit(
          id: 'guest-update',
          author: 'owner',
          clock: 40,
          createdAt: 40,
          text: 'Public update',
        ),
        history,
      );
      seedCloud(history: [...history, update]);
      await tester.pump(const Duration(seconds: 1));
      await _settle(tester);
      expect(room.text, 'Public update');
      expect(room.diskSyncStatus, contains('прочитана'));
      expect(room.diskSyncAcknowledged, isFalse);
      final reads = cloud.publicRead.length;
      room.resume();
      await tester.pump(const Duration(seconds: 1));
      await _settle(tester);
      expect(cloud.publicRead.length, greaterThan(reads));
      expect(cloud.listed, isEmpty);
      expect(cloud.read, isEmpty);
      expect(cloud.created, isEmpty);
      expect(cloud.written, isEmpty);
      expect(cloud.published, isEmpty);
      expect(await store.loadDiskCredentials(_roomId), isNull);
    },
  );

  diskTest(
    'public guest imports final edits and disconnect, then stops polling',
    (tester) async {
      network.autoRegister = false;
      seedCloud();
      final store = _Store();
      final guest = session(
        actor: 'guest',
        store: store,
        member: false,
        role: RoomRole.guest,
        access: _entryAccess(RoomRole.guest),
      );
      await guest.start();
      expect(guest.diskBinding!.id, _invitationBinding);
      final history = _diskEntryHistory();
      final lastEdit = sequenceAuthoredEdit(
        const RoomEdit(
          id: 'final-public-edit',
          author: 'owner',
          clock: 40,
          createdAt: 40,
          text: 'Last change before disconnect',
        ),
        history,
      );
      final disconnect = sequenceAuthoredEdit(
        const RoomEdit(
          id: 'final-public-disconnect',
          author: 'owner',
          clock: 41,
          createdAt: 41,
          kind: RoomEditKind.diskConnection,
          text: '{"action":"disconnect","bindingId":"invitation-binding"}',
        ),
        [...history, lastEdit],
      );
      seedCloud(history: [...history, lastEdit, disconnect]);
      await tester.pump(const Duration(seconds: 1));
      await _settle(tester);
      expect(guest.joined, isTrue);
      expect(guest.ownRole, RoomRole.guest);
      expect(guest.canEdit, isFalse);
      expect(guest.text, 'Last change before disconnect');
      expect(guest.diskBinding, isNull);
      expect(guest.diskInvitationsAvailable, isFalse);
      expect(guest.diskSyncStatus, 'Не подключён');
      expect(guest.diskSyncError, isNull);
      final durable = validateAuthorHistory(
        decodeRoomHistory(await store.loadHistory(_roomId)),
      );
      expect(durable.any((edit) => edit.sameContentAs(lastEdit)), isTrue);
      expect(durable.any((edit) => edit.sameContentAs(disconnect)), isTrue);
      final listings = cloud.publicListed.length;
      final reads = cloud.publicRead.length;
      guest.resume();
      await tester.pump(const Duration(seconds: 61));
      await _settle(tester);
      expect(cloud.publicListed, hasLength(listings));
      expect(cloud.publicRead, hasLength(reads));
      expect(await store.loadDiskCredentials(_roomId), isNull);
      expect(store.credentialSaveAttempts, 0);
      expect(cloud.listed, isEmpty);
      expect(cloud.read, isEmpty);
      expect(cloud.created, isEmpty);
      expect(cloud.written, isEmpty);
      expect(cloud.published, isEmpty);

      // A terminal snapshot is usable only by an already accepted reader, not
      // as proof of admission for a new guest opening the old public link.
      final newcomerStore = _Store();
      final newcomer = session(
        actor: 'newcomer',
        store: newcomerStore,
        member: false,
        role: RoomRole.guest,
        access: _entryAccess(RoomRole.guest),
      );
      await newcomer.start();
      expect(newcomer.joined, isFalse);
      expect(newcomer.initialSyncComplete, isFalse);
      expect(await newcomerStore.hasMembership(_roomId), isFalse);
      expect(await newcomerStore.loadHistory(_roomId), isEmpty);
      expect(await newcomerStore.loadDiskCredentials(_roomId), isNull);
      expect(cloud.written, isEmpty);
    },
  );

  for (final invitationOnReload in [false, true]) {
    diskTest(
      'accepted guest reload imports terminal public copy: invitation=$invitationOnReload',
      (tester) async {
        network.autoRegister = false;
        seedCloud();
        final store = _Store();
        final first = session(
          actor: 'guest',
          store: store,
          member: false,
          role: RoomRole.guest,
          access: _entryAccess(RoomRole.guest),
        );
        await first.start();
        expect(await store.hasMembership(_roomId), isTrue);
        final acceptedHistory = await store.loadHistory(_roomId);
        final membershipWrites = store.membershipSaveAttempts;
        first.dispose();
        await _settle(tester);

        final history = _diskEntryHistory();
        final lastEdit = sequenceAuthoredEdit(
          const RoomEdit(
            id: 'terminal-reload-edit',
            author: 'owner',
            clock: 40,
            createdAt: 40,
            text: 'Final cloud copy while the guest was closed',
          ),
          history,
        );
        final disconnect = sequenceAuthoredEdit(
          const RoomEdit(
            id: 'terminal-reload-disconnect',
            author: 'owner',
            clock: 41,
            createdAt: 41,
            kind: RoomEditKind.diskConnection,
            text: '{"action":"disconnect","bindingId":"invitation-binding"}',
          ),
          [...history, lastEdit],
        );
        seedCloud(history: [...history, lastEdit, disconnect]);
        final reopened = session(
          actor: 'guest',
          store: store,
          role: RoomRole.guest,
          access: invitationOnReload ? _entryAccess(RoomRole.guest) : null,
        );
        await reopened.start();
        await _settle(tester);
        expect(reopened.joined, isTrue);
        expect(reopened.initialSyncComplete, isTrue);
        expect(reopened.initialSyncStatus, contains('с Диска'));
        expect(reopened.initialSyncError, isNull);
        expect(reopened.localCopyOpened, isFalse);
        expect(reopened.hasValidatedOnlinePeer, isFalse);
        expect(reopened.ownRole, RoomRole.guest);
        expect(reopened.diskBinding, isNull);
        expect(reopened.text, 'Final cloud copy while the guest was closed');
        expect(reopened.diskSyncError, isNull);
        expect(store.membershipSaveAttempts, membershipWrites);
        final durable = validateAuthorHistory(
          decodeRoomHistory(await store.loadHistory(_roomId)),
        );
        expect(durable.any((edit) => edit.sameContentAs(lastEdit)), isTrue);
        expect(durable.any((edit) => edit.sameContentAs(disconnect)), isTrue);
        final listings = cloud.publicListed.length;
        reopened.resume();
        await tester.pump(const Duration(seconds: 61));
        await _settle(tester);
        expect(cloud.publicListed, hasLength(listings));
        expect(await store.loadDiskCredentials(_roomId), isNull);
        expect(store.credentialSaveAttempts, 0);
        expect(cloud.listed, isEmpty);
        expect(cloud.read, isEmpty);
        expect(cloud.created, isEmpty);
        expect(cloud.written, isEmpty);
        expect(cloud.published, isEmpty);

        // Staged local history/access without accepted membership does not
        // inherit the terminal-copy allowance, even for the same guest actor.
        final unacceptedStore = _Store();
        await unacceptedStore.appendHistory(_roomId, acceptedHistory);
        await unacceptedStore.saveDiskPublicAccess(
          _roomId,
          _entryAccess(RoomRole.guest).toJson(),
        );
        final unaccepted = session(
          actor: 'guest',
          store: unacceptedStore,
          member: false,
          role: RoomRole.guest,
          access: _entryAccess(RoomRole.guest),
        );
        await unaccepted.start();
        expect(unaccepted.joined, isFalse);
        expect(unaccepted.initialSyncComplete, isFalse);
        expect(unaccepted.initialSyncError, isNotNull);
        expect(await unacceptedStore.hasMembership(_roomId), isFalse);
        expect(unacceptedStore.membershipSaveAttempts, 0);
        expect(
          decodeRoomHistory(
            await unacceptedStore.loadHistory(_roomId),
          ).any((edit) => edit.id == disconnect.id || edit.id == lastEdit.id),
          isFalse,
        );
        expect(cloud.written, isEmpty);
      },
    );
  }

  diskTest(
    'plain invitations still require an online welcome and do not read Disk',
    (tester) async {
      network.autoRegister = false;
      final store = _Store();
      final room = session(
        actor: 'plain',
        store: store,
        member: false,
        role: RoomRole.guest,
      );
      await room.start();
      expect(room.joined, isFalse);
      expect(room.initialSyncComplete, isFalse);
      expect(await store.hasMembership(_roomId), isFalse);
      expect(cloud.listed, isEmpty);
      expect(cloud.publicListed, isEmpty);
      expect(cloud.created, isEmpty);
      await tester.pump(const Duration(seconds: 31));
      expect(room.joined, isFalse);
      expect(room.initialSyncError, isNotNull);
      expect(await store.loadHistory(_roomId), isEmpty);
    },
  );

  test(
    'constructor rejects mismatched invitation role and access without secrets',
    () {
      for (final role in RoomRole.values) {
        expect(
          () => session(
            actor: 'invalid',
            member: false,
            role: role,
            access: _entryAccess(
              role == RoomRole.editor ? RoomRole.guest : RoomRole.editor,
            ),
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'safe message',
              isNot(contains(_token)),
            ),
          ),
        );
      }
    },
  );

  Future<({RoomSession room, _Store store})> invitationOwner({
    MemoryDiskClient? client,
  }) async {
    seedCloud();
    final store = _Store();
    await store.appendHistory(_roomId, [
      for (final edit in _diskEntryHistory()) edit.toJson(),
    ]);
    await store.saveDiskCredentials(
      _roomId,
      _entryAccess(RoomRole.editor).toJson(),
    );
    final room = session(actor: 'owner', store: store, diskClient: client);
    await room.start();
    return (room: room, store: store);
  }

  diskTest(
    'preparing editor access never publishes; guest publication needs consent',
    (tester) async {
      network.autoRegister = false;
      final owner = await invitationOwner();
      expect(owner.room.diskInvitationsAvailable, isTrue);
      expect(owner.room.canPublishDiskInvitation, isTrue);
      expect(
        await owner.room.prepareDiskInvitation(RoomRole.editor),
        _entryAccess(RoomRole.editor),
      );
      expect(await owner.room.prepareDiskInvitation(RoomRole.guest), isNull);
      expect(cloud.published, isEmpty);
      expect(cloud.written, isEmpty);
      expect(cloud.created, isEmpty);
      expect(await owner.store.loadDiskPublicAccess(_roomId), isNull);
    },
  );

  diskTest(
    'consented publication uploads the current copy and publishes only its binding folder',
    (tester) async {
      network.autoRegister = false;
      final client = _PublishingDiskClient(cloud);
      final owner = await invitationOwner(client: client);
      await owner.room.edit('Current copy must exist before publication');
      client.beforePublish = () async {
        expect(owner.room.diskSyncAcknowledged, isTrue);
        expect(
          roomHistoryInventory(cloud.uploadedHistory),
          roomHistoryInventory(owner.room.changes),
        );
      };
      final access = await owner.room.prepareDiskInvitation(
        RoomRole.guest,
        allowPublication: true,
      );
      expect(access, _entryAccess(RoomRole.guest));
      expect(access!.token, isNull);
      expect(cloud.published, [_bindingPath]);
      expect(client.publicationAttempts, [_bindingPath]);
      expect(cloud.published, isNot(contains('app:/mytree')));
      expect(cloud.published, isNot(contains('app:/mytree/$_roomId')));
      expect(await owner.store.loadDiskPublicAccess(_roomId), access.toJson());
      expect(
        await owner.store.loadDiskCredentials(_roomId),
        _entryAccess(RoomRole.editor).toJson(),
      );
      final again = await owner.room.prepareDiskInvitation(RoomRole.guest);
      expect(again, access);
      expect(cloud.published, hasLength(1));
      expect(
        jsonEncode(await owner.store.loadHistory(_roomId)),
        isNot(contains(_publicUrl)),
      );
      expect(owner.room.log.join('\n'), isNot(contains(_token)));
    },
  );

  for (final publicAccess in ['none', 'stale', 'matching']) {
    diskTest(
      'guest Disk invitations require matching saved public access: $publicAccess',
      (tester) async {
        network.autoRegister = false;
        seedCloud();
        final store = _Store();
        await store.appendHistory(_roomId, [
          for (final edit in _diskEntryHistory()) edit.toJson(),
          _role('guest', RoomRole.guest).toJson(),
        ]);
        if (publicAccess != 'none') {
          await store.saveDiskPublicAccess(_roomId, {
            'v': 1,
            'bindingId': publicAccess == 'matching'
                ? _invitationBinding
                : 'old-binding',
            'publicUrl': _publicUrl,
          });
        }
        final guest = session(
          actor: 'guest',
          store: store,
          role: RoomRole.guest,
        );
        await guest.start();
        await _settle(tester);
        expect(guest.joined, isTrue);
        expect(guest.diskBinding!.id, _invitationBinding);
        expect(guest.ownRole, RoomRole.guest);
        expect(guest.diskInvitationsAvailable, publicAccess == 'matching');
        expect(guest.canPublishDiskInvitation, isFalse);
        expect(cloud.published, isEmpty);
        expect(cloud.written, isEmpty);
      },
    );
  }

  diskTest(
    'guests can reuse public access but cannot publish or request editor access',
    (tester) async {
      network.autoRegister = false;
      seedCloud();
      final store = _Store();
      final guest = session(
        actor: 'guest',
        store: store,
        member: false,
        role: RoomRole.guest,
        access: _entryAccess(RoomRole.guest),
      );
      await guest.start();
      expect(guest.diskInvitationsAvailable, isTrue);
      expect(guest.canPublishDiskInvitation, isFalse);
      expect(
        await guest.prepareDiskInvitation(RoomRole.guest),
        _entryAccess(RoomRole.guest),
      );
      await expectLater(
        guest.prepareDiskInvitation(RoomRole.editor),
        throwsStateError,
      );
      await store.saveDiskPublicAccess(_roomId, null);
      expect(await guest.prepareDiskInvitation(RoomRole.guest), isNull);
      await expectLater(
        guest.prepareDiskInvitation(RoomRole.guest, allowPublication: true),
        throwsStateError,
      );
      expect(cloud.published, isEmpty);
      expect(cloud.written, isEmpty);
      expect(store.credentialSaveAttempts, 0);
    },
  );

  diskTest(
    'ordinary rooms return no Disk invitation and implicit editors cannot disclose tokens',
    (tester) async {
      network.autoRegister = false;
      final plain = session(actor: 'plain', creator: true);
      await plain.start();
      expect(plain.diskInvitationsAvailable, isFalse);
      expect(plain.canPublishDiskInvitation, isFalse);
      expect(await plain.prepareDiskInvitation(RoomRole.editor), isNull);
      expect(
        await plain.prepareDiskInvitation(
          RoomRole.guest,
          allowPublication: true,
        ),
        isNull,
      );
      final store = _Store();
      final implicit = session(actor: 'implicit', store: store);
      await implicit.start();
      await implicit.connectDisk(_token);
      expect(implicit.canEdit, isTrue);
      expect(implicit.diskInvitationsAvailable, isTrue);
      expect(implicit.canPublishDiskInvitation, isFalse);
      await expectLater(
        implicit.prepareDiskInvitation(RoomRole.editor),
        throwsStateError,
      );
      await expectLater(
        implicit.prepareDiskInvitation(RoomRole.guest, allowPublication: true),
        throwsStateError,
      );
      expect(cloud.published, isEmpty);
    },
  );

  diskTest(
    'stale public access is not returned; missing current credentials cannot publish',
    (tester) async {
      network.autoRegister = false;
      final owner = await invitationOwner();
      await owner.store.saveDiskPublicAccess(_roomId, {
        'v': 1,
        'bindingId': 'old-binding',
        'publicUrl': 'https://disk.yandex.ru/d/old-binding',
      });
      expect(await owner.room.prepareDiskInvitation(RoomRole.guest), isNull);
      await owner.store.saveDiskCredentials(
        _roomId,
        null,
        bindingId: _invitationBinding,
      );
      await expectLater(
        owner.room.prepareDiskInvitation(RoomRole.editor),
        throwsStateError,
      );
      await expectLater(
        owner.room.prepareDiskInvitation(
          RoomRole.guest,
          allowPublication: true,
        ),
        throwsStateError,
      );
      expect(cloud.published, isEmpty);
    },
  );

  diskTest(
    'unsaved current history blocks publication without hiding storage errors',
    (tester) async {
      network.autoRegister = false;
      final owner = await invitationOwner();
      owner.store.failAppend = true;
      await owner.room.edit('Cannot save this change yet');
      await expectLater(
        owner.room.prepareDiskInvitation(
          RoomRole.guest,
          allowPublication: true,
        ),
        throwsStateError,
      );
      expect(owner.room.storageError, isNotNull);
      expect(cloud.published, isEmpty);
      expect(await owner.store.loadDiskPublicAccess(_roomId), isNull);
      owner.store.failAppend = false;
      final access = await owner.room.prepareDiskInvitation(
        RoomRole.guest,
        allowPublication: true,
      );
      expect(access, _entryAccess(RoomRole.guest));
      expect(
        cloud.uploadedHistory.any(
          (edit) => edit.text == 'Cannot save this change yet',
        ),
        isTrue,
      );
    },
  );

  diskTest(
    'credential changes while synchronization awaits prevent publication',
    (tester) async {
      network.autoRegister = false;
      final owner = await invitationOwner();
      final release = Completer<void>();
      cloud.beforeList = (_) => release.future;
      final preparing = owner.room.prepareDiskInvitation(
        RoomRole.guest,
        allowPublication: true,
      );
      final failed = expectLater(preparing, throwsStateError);
      await _settle(tester);
      await owner.store.saveDiskCredentials(_roomId, {
        'v': 1,
        'bindingId': _invitationBinding,
        'token': 'replacement-private-token',
      });
      release.complete();
      await failed;
      expect(cloud.published, isEmpty);
      expect(await owner.store.loadDiskPublicAccess(_roomId), isNull);
    },
  );

  for (final phase in ['synchronization', 'publication']) {
    diskTest(
      'a binding change during $phase cannot return or persist stale access',
      (tester) async {
        network.autoRegister = false;
        final client = _PublishingDiskClient(cloud);
        final owner = await invitationOwner(client: client);
        final release = Completer<void>();
        if (phase == 'synchronization') {
          cloud.beforeList = (_) => release.future;
        } else {
          client.beforePublish = () => release.future;
        }
        final preparing = owner.room.prepareDiskInvitation(
          RoomRole.guest,
          allowPublication: true,
        );
        final failed = expectLater(preparing, throwsStateError);
        await _settle(tester);
        final detach = sequenceAuthoredEdit(
          const RoomEdit(
            id: 'changed-while-publishing',
            author: 'owner',
            clock: 100,
            createdAt: 100,
            kind: RoomEditKind.diskConnection,
            text: '{"action":"disconnect","bindingId":"invitation-binding"}',
          ),
          decodeRoomHistory(await owner.store.loadHistory(_roomId)),
        );
        await owner.store.appendHistory(_roomId, [detach.toJson()]);
        // An authored append atomically catches up the full stored journal too.
        await owner.room.setParticipantName('Binding changed');
        await _settle(tester);
        expect(owner.room.diskBinding, isNull);
        release.complete();
        await failed;
        expect(await owner.store.loadDiskPublicAccess(_roomId), isNull);
        if (phase == 'synchronization') expect(cloud.published, isEmpty);
      },
    );
  }

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
