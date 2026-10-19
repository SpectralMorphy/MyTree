import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/cloud/room_disk_sync.dart';
import 'package:mytree_webrtc_demo/cloud/yandex_disk_client.dart';
import 'package:mytree_webrtc_demo/room_document.dart';
import 'package:mytree_webrtc_demo/room_protocol.dart';
import 'package:mytree_webrtc_demo/storage/room_store.dart';

const _roomId = '0123456789abcdef0123456789abcdef';
const _bindingId = 'disk-binding';
const _token = 'private-oauth-token';
const _directory = 'app:/mytree/$_roomId/$_bindingId/batches';

/// Shared fake cloud, also used by the session tests; each client is independent.
class MemoryDiskBackend {
  final directories = <String>{};
  final files = <String, Uint8List>{};
  final created = <String>[];
  final listed = <String>[];
  final read = <String>[];
  final written = <String>[];
  Future<void> Function(String path)? beforeList;
  Future<void> Function(String path)? beforeRead;
  Future<void> Function(String path, Uint8List bytes)? beforeWrite;
  Object? writeFailure;

  String addBatch(
    List<RoomEdit> history, {
    String roomId = _roomId,
    String bindingId = _bindingId,
    String directory = _directory,
  }) {
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'roomId': roomId,
          'bindingId': bindingId,
          'history': history.map((edit) => edit.toJson()).toList(),
        }),
      ),
    );
    final path = '$directory/${sha256.convert(bytes)}.json';
    files[path] = bytes;
    return path;
  }

  List<RoomEdit> get uploadedHistory => validateAuthorHistory([
    for (final bytes in files.values)
      ...decodeRoomHistory((jsonDecode(utf8.decode(bytes)) as Map)['history']),
  ]);
}

class MemoryDiskClient extends YandexDiskClient {
  MemoryDiskClient(this.backend);

  final MemoryDiskBackend backend;
  bool closed = false;

  @override
  Future<void> createDirectory(String token, String path) async {
    backend.created.add(path);
    backend.directories.add(path);
  }

  @override
  Future<List<String>> listFiles(String token, String path) async {
    backend.listed.add(path);
    // Freeze the directory view before the gate to model concurrent listings.
    final names = [
      for (final file in backend.files.keys)
        if (file.startsWith('$path/') &&
            !file.substring(path.length + 1).contains('/'))
          file.substring(path.length + 1),
    ];
    await backend.beforeList?.call(path);
    return names;
  }

  @override
  Future<Uint8List> readFile(String token, String path) async {
    backend.read.add(path);
    await backend.beforeRead?.call(path);
    final bytes = backend.files[path];
    if (bytes == null) {
      throw const YandexDiskException('Missing file', statusCode: 404);
    }
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> writeFile(String token, String path, Uint8List bytes) async {
    backend.written.add(path);
    final snapshot = Uint8List.fromList(bytes);
    await backend.beforeWrite?.call(path, snapshot);
    final failure = backend.writeFailure;
    if (failure != null) throw failure;
    final previous = backend.files[path];
    if (previous != null && base64Encode(previous) != base64Encode(snapshot)) {
      throw const YandexDiskException(
        'Immutable file changed',
        statusCode: 409,
      );
    }
    backend.files[path] = snapshot;
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

class _Replica {
  _Replica(this.store);

  final MemoryRoomStore store;
  List<RoomEdit> history = const [];
  int merges = 0;
  bool failMerge = false;

  Future<void> reload() async {
    history = List.unmodifiable(
      validateAuthorHistory(
        decodeRoomHistory(await store.loadHistory(_roomId)),
      ),
    );
  }

  Future<RoomEdit> append(String id, String actor, String text) async {
    final edit = sequenceAuthoredEdit(
      RoomEdit(
        id: id,
        author: actor,
        clock: history.length + 1,
        createdAt: history.length + 1,
        text: text,
      ),
      history,
    );
    await store.appendHistory(_roomId, [edit.toJson()]);
    await reload();
    return edit;
  }

  RoomDiskSync sync(MemoryDiskBackend backend) {
    final result = RoomDiskSync(
      roomId: _roomId,
      client: MemoryDiskClient(backend),
      readHistory: () => history,
      mergeHistory: (edits) async {
        merges++;
        if (failMerge) throw StateError('Local journal unavailable');
        await store.appendHistory(
          _roomId,
          edits.map((edit) => edit.toJson()).toList(),
        );
        await reload();
      },
      onChanged: () {},
      pollInterval: const Duration(days: 1),
    );
    result.update(bindingId: _bindingId, token: _token, enabled: true);
    addTearDown(result.dispose);
    return result;
  }
}

void main() {
  test('prepare uses only application room/binding directories', () async {
    final backend = MemoryDiskBackend();
    final replica = _Replica(MemoryRoomStore());
    final sync = replica.sync(backend);
    await sync.prepare(_bindingId, _token);
    expect(backend.created, [
      'app:/mytree',
      'app:/mytree/$_roomId',
      'app:/mytree/$_roomId/$_bindingId',
      _directory,
    ]);
    expect(jsonEncode(backend.created), isNot(contains(_token)));
    expect(sync.acknowledged, isFalse);
  });

  test(
    'concurrent offline editor branches converge by immutable batch union',
    () async {
      final backend = MemoryDiskBackend();
      final alice = _Replica(MemoryRoomStore());
      final bob = _Replica(MemoryRoomStore());
      await alice.append('alice-1', 'alice', 'Alice offline');
      await bob.append('bob-1', 'bob', 'Bob offline');
      final aliceSync = alice.sync(backend);
      final bobSync = bob.sync(backend);
      final listed = Completer<void>();
      var listings = 0;
      backend.beforeList = (_) async {
        if (++listings == 2) listed.complete();
        await listed.future;
      };
      await Future.wait([aliceSync.sync(), bobSync.sync()]);
      expect(backend.files, hasLength(2));
      expect(alice.history.map((edit) => edit.id), ['alice-1']);
      expect(bob.history.map((edit) => edit.id), ['bob-1']);
      backend.beforeList = null;
      await Future.wait([aliceSync.sync(), bobSync.sync()]);
      expect(
        roomHistoryInventory(alice.history),
        roomHistoryInventory(bob.history),
      );
      expect(
        alice.history.map((edit) => edit.id),
        unorderedEquals(['alice-1', 'bob-1']),
      );
      expect(
        backend.uploadedHistory.map((edit) => edit.id),
        unorderedEquals(['alice-1', 'bob-1']),
      );
      expect(aliceSync.acknowledged, isTrue);
      expect(bobSync.acknowledged, isTrue);
      expect(
        backend.files,
        hasLength(2),
        reason: 'Never replace a shared snapshot',
      );
      for (final entry in backend.files.entries) {
        expect(entry.key, '$_directory/${sha256.convert(entry.value)}.json');
        expect(utf8.decode(entry.value), isNot(contains(_token)));
      }
    },
  );

  test(
    'predecessors may be supplied by separate batches or local durable union',
    () async {
      for (final firstIsLocal in [false, true]) {
        final source = _Replica(MemoryRoomStore());
        final first = await source.append('first', 'author', 'first');
        final tail = await source.append('tail', 'author', 'tail');
        final backend = MemoryDiskBackend()..addBatch([tail]);
        final replica = _Replica(MemoryRoomStore());
        if (firstIsLocal) {
          await replica.store.appendHistory(_roomId, [first.toJson()]);
          await replica.reload();
        } else {
          backend.addBatch([first]);
        }
        final sync = replica.sync(backend);
        await sync.sync();
        expect(replica.history.map((edit) => edit.id), ['first', 'tail']);
        expect(sync.acknowledged, isTrue);
        expect(backend.uploadedHistory.map((edit) => edit.id), [
          'first',
          'tail',
        ]);
      }
    },
  );

  test(
    'missing author predecessor rejects the complete union before merge or upload',
    () async {
      final source = _Replica(MemoryRoomStore());
      await source.append('first', 'author', 'first');
      final tail = await source.append('tail', 'author', 'tail');
      final backend = MemoryDiskBackend()..addBatch([tail]);
      final replica = _Replica(MemoryRoomStore());
      await replica.append('local', 'other', 'keep me');
      final sync = replica.sync(backend);
      final before = roomHistoryInventory(replica.history);
      await expectLater(sync.sync(), throwsStateError);
      expect(replica.merges, 0);
      expect(roomHistoryInventory(replica.history), before);
      expect(backend.written, isEmpty);
      expect(sync.acknowledged, isFalse);
      expect(sync.error, isNotNull);
    },
  );

  for (final corruption in [
    'hash',
    'room',
    'binding',
    'json',
    'name',
    'conflict',
  ]) {
    test(
      '$corruption corruption never merges or acknowledges cloud history',
      () async {
        final replica = _Replica(MemoryRoomStore());
        final original = await replica.append(
          'local',
          'author',
          'durable local',
        );
        final backend = MemoryDiskBackend();
        final path = backend.addBatch(
          [original],
          roomId: corruption == 'room' ? 'f' * 32 : _roomId,
          bindingId: corruption == 'binding' ? 'other-binding' : _bindingId,
        );
        switch (corruption) {
          case 'hash':
            backend.files[path] = Uint8List.fromList([
              ...backend.files[path]!,
              32,
            ]);
          case 'json':
            backend.files.clear();
            final bytes = Uint8List.fromList(
              utf8.encode('{malformed cloud JSON'),
            );
            backend.files['$_directory/${sha256.convert(bytes)}.json'] = bytes;
          case 'name':
            backend.files['$_directory/not-a-digest.json'] = backend.files
                .remove(path)!;
          case 'conflict':
            backend.addBatch([
              RoomEdit.fromJson({...original.toJson(), 'text': 'rewritten'})!,
            ]);
        }
        final sync = replica.sync(backend);
        await expectLater(sync.sync(), throwsStateError);
        expect(replica.merges, 0);
        expect(replica.history.single.sameContentAs(original), isTrue);
        expect(backend.written, isEmpty);
        expect(sync.acknowledged, isFalse);
        expect(sync.error, isNotNull);
        expect(sync.error, isNot(contains(_token)));
      },
    );
  }

  test(
    'failed cloud upload preserves local journal and remains unacknowledged',
    () async {
      final backend = MemoryDiskBackend()
        ..writeFailure = StateError('Transport $_token');
      final replica = _Replica(MemoryRoomStore());
      final edit = await replica.append('offline', 'editor', 'saved locally');
      final sync = replica.sync(backend);
      await expectLater(sync.sync(), throwsStateError);
      expect(sync.acknowledged, isFalse);
      expect(sync.error, isNot(contains(_token)));
      expect(sync.status, contains('сохранены локально'));
      expect(backend.files, isEmpty);
      await replica.reload();
      expect(replica.history.single.sameContentAs(edit), isTrue);
      backend.writeFailure = null;
      await sync.sync();
      expect(sync.acknowledged, isTrue);
      expect(sync.error, isNull);
      expect(backend.uploadedHistory.single.sameContentAs(edit), isTrue);
    },
  );

  test(
    'failed local merge cannot upload or acknowledge uncommitted remote history',
    () async {
      final remote = _Replica(MemoryRoomStore());
      final edit = await remote.append('remote', 'remote', 'remote edit');
      final backend = MemoryDiskBackend()..addBatch([edit]);
      final replica = _Replica(MemoryRoomStore())..failMerge = true;
      final sync = replica.sync(backend);
      await expectLater(sync.sync(), throwsStateError);
      expect(replica.history, isEmpty);
      expect(backend.written, isEmpty);
      expect(sync.acknowledged, isFalse);
      replica.failMerge = false;
      await sync.sync();
      expect(replica.history.single.sameContentAs(edit), isTrue);
      expect(sync.acknowledged, isTrue);
    },
  );

  test(
    'restart reconstructs pending uploads from the durable journal',
    () async {
      final backend = MemoryDiskBackend()..writeFailure = StateError('Offline');
      final store = MemoryRoomStore();
      final original = _Replica(store);
      final edit = await original.append(
        'pending',
        'editor',
        'survives restart',
      );
      final originalSync = original.sync(backend);
      await expectLater(originalSync.sync(), throwsStateError);
      originalSync.dispose();
      backend.writeFailure = null;
      final reopened = _Replica(store);
      await reopened.reload();
      final reopenedSync = reopened.sync(backend);
      expect(reopenedSync.acknowledged, isFalse);
      await reopenedSync.sync();
      expect(reopenedSync.acknowledged, isTrue);
      expect(backend.uploadedHistory.single.sameContentAs(edit), isTrue);
      final writes = backend.written.length;
      await reopenedSync.sync();
      expect(
        backend.written,
        hasLength(writes),
        reason: 'Already confirmed records need no upload',
      );
    },
  );

  for (final stop in ['disable', 'detach', 'dispose']) {
    test('$stop invalidates an in-flight cloud generation', () async {
      final backend = MemoryDiskBackend();
      final replica = _Replica(MemoryRoomStore());
      await replica.append('local', 'editor', 'local');
      final sync = replica.sync(backend);
      final entered = Completer<void>();
      final release = Completer<void>();
      backend.beforeList = (_) async {
        entered.complete();
        await release.future;
      };
      final pending = sync.sync();
      await entered.future;
      if (stop == 'dispose') {
        sync.dispose();
      } else {
        sync.update(
          bindingId: stop == 'detach' ? null : _bindingId,
          token: stop == 'detach' ? null : _token,
          enabled: false,
        );
      }
      release.complete();
      await pending;
      expect(replica.merges, 0);
      expect(backend.written, isEmpty);
      expect(sync.acknowledged, isFalse);
    });
  }

  test(
    'an upload ACK covers its frozen set, never concurrent local edits',
    () async {
      final backend = MemoryDiskBackend();
      final replica = _Replica(MemoryRoomStore());
      final first = await replica.append('first', 'editor', 'first');
      final sync = replica.sync(backend);
      final entered = Completer<void>();
      final release = Completer<void>();
      backend.beforeWrite = (_, _) async {
        entered.complete();
        await release.future;
      };
      final pending = sync.sync();
      expect(
        identical(sync.sync(), pending),
        isTrue,
        reason: 'One in-flight run per replica',
      );
      await entered.future;
      final concurrent = await replica.append(
        'concurrent',
        'editor',
        'while uploading',
      );
      expect(sync.busy, isTrue);
      release.complete();
      await pending;
      expect(backend.uploadedHistory.single.sameContentAs(first), isTrue);
      expect(sync.acknowledged, isFalse);
      expect(sync.status, contains('изменения для отправки'));
      backend.beforeWrite = null;
      await sync.sync();
      expect(sync.acknowledged, isTrue);
      expect(backend.uploadedHistory.map((edit) => edit.id), [
        first.id,
        concurrent.id,
      ]);
    },
  );
}
