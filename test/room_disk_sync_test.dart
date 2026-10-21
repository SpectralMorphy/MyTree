import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/cloud/room_disk_sync.dart';
import 'package:mytree_webrtc_demo/cloud/yandex_disk_client.dart';
import 'package:mytree_webrtc_demo/room_document.dart';
import 'package:mytree_webrtc_demo/room_identity.dart';
import 'package:mytree_webrtc_demo/room_protocol.dart';
import 'package:mytree_webrtc_demo/storage/room_store.dart';

const _roomId = '0123456789abcdef0123456789abcdef';
const _bindingId = 'disk-binding';
const _token = 'private-oauth-token';
const _directory = 'app:/mytree/$_roomId/$_bindingId/batches';
const _publicUrl = 'https://disk.yandex.ru/d/published-binding';
const _bindingRoot = 'app:/mytree/$_roomId/$_bindingId';

/// Shared fake cloud, also used by the session tests; each client is independent.
class MemoryDiskBackend {
  final directories = <String>{};
  final files = <String, Uint8List>{};
  final created = <String>[];
  final listed = <String>[];
  final read = <String>[];
  final written = <String>[];
  final published = <String>[];
  final publicListed = <String>[];
  final publicRead = <String>[];
  final publicUrls = <String>[];
  final publicRoots = <String, String>{_publicUrl: _bindingRoot};
  final requestGuards = <bool Function()?>[];
  final requestDeadlines = <DateTime?>[];
  List<String>? listing;
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
    return addRawBatch(bytes, directory: directory);
  }

  String addRawBatch(Uint8List bytes, {String directory = _directory}) {
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
  Future<String> publishDirectory(String token, String path) async {
    backend.published.add(path);
    final publicUrl = 'https://disk.yandex.ru/d/${path.split('/').last}';
    backend.publicRoots[publicUrl] = path;
    return publicUrl;
  }

  @override
  Future<List<String>> listFiles(
    String token,
    String path, {
    bool Function()? isCurrent,
    DateTime? deadline,
  }) async {
    backend.listed.add(path);
    _recordReadContext(isCurrent, deadline);
    return _listFiles(path, isCurrent: isCurrent, deadline: deadline);
  }

  @override
  Future<List<String>> listPublicFiles(
    String publicUrl, {
    String path = '/batches',
    bool Function()? isCurrent,
    DateTime? deadline,
  }) async {
    backend.publicListed.add(path);
    backend.publicUrls.add(publicUrl);
    _recordReadContext(isCurrent, deadline);
    return _listFiles(
      '${_publicRoot(publicUrl)}$path',
      isCurrent: isCurrent,
      deadline: deadline,
    );
  }

  Future<List<String>> _listFiles(
    String path, {
    bool Function()? isCurrent,
    DateTime? deadline,
  }) async {
    _checkReadContext(isCurrent, deadline);
    // Freeze the directory view before the gate to model concurrent listings.
    final names =
        backend.listing ??
        [
          for (final file in backend.files.keys)
            if (file.startsWith('$path/') &&
                !file.substring(path.length + 1).contains('/'))
              file.substring(path.length + 1),
        ];
    await backend.beforeList?.call(path);
    _checkReadContext(isCurrent, deadline);
    return names;
  }

  @override
  Future<Uint8List> readFile(
    String token,
    String path, {
    bool Function()? isCurrent,
    DateTime? deadline,
  }) async {
    backend.read.add(path);
    _recordReadContext(isCurrent, deadline);
    return _readFile(path, isCurrent: isCurrent, deadline: deadline);
  }

  @override
  Future<Uint8List> readPublicFile(
    String publicUrl,
    String path, {
    bool Function()? isCurrent,
    DateTime? deadline,
  }) async {
    backend.publicRead.add(path);
    backend.publicUrls.add(publicUrl);
    _recordReadContext(isCurrent, deadline);
    return _readFile(
      '${_publicRoot(publicUrl)}$path',
      isCurrent: isCurrent,
      deadline: deadline,
    );
  }

  String _publicRoot(String publicUrl) {
    final root = backend.publicRoots[publicUrl];
    if (root == null) {
      throw const YandexDiskException('Missing public folder', statusCode: 404);
    }
    return root;
  }

  void _recordReadContext(bool Function()? isCurrent, DateTime? deadline) {
    backend.requestGuards.add(isCurrent);
    backend.requestDeadlines.add(deadline);
  }

  void _checkReadContext(bool Function()? isCurrent, DateTime? deadline) {
    if (!(isCurrent?.call() ?? true) ||
        (deadline != null && !DateTime.now().isBefore(deadline))) {
      throw const YandexDiskException('Read cancelled');
    }
  }

  Future<Uint8List> _readFile(
    String path, {
    bool Function()? isCurrent,
    DateTime? deadline,
  }) async {
    _checkReadContext(isCurrent, deadline);
    await backend.beforeRead?.call(path);
    _checkReadContext(isCurrent, deadline);
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

List<RoomEdit> _diskAdmissionHistory({int extraEdits = 0}) {
  final history = <RoomEdit>[];
  void append(RoomEdit edit) {
    history.add(sequenceAuthoredEdit(edit, history));
  }

  append(
    const RoomEdit(
      id: 'owner-role',
      author: 'owner',
      clock: 1,
      createdAt: 1,
      text: 'editor',
      kind: RoomEditKind.participantRole,
      targetActor: 'owner',
    ),
  );
  append(
    const RoomEdit(
      id: _bindingId,
      author: 'owner',
      clock: 2,
      createdAt: 2,
      text: '{"action":"connect"}',
      kind: RoomEditKind.diskConnection,
    ),
  );
  append(
    const RoomEdit(
      id: 'cloud-text',
      author: 'owner',
      clock: 3,
      createdAt: 3,
      text: 'Cloud history',
    ),
  );
  for (var index = 0; index < extraEdits; index++) {
    append(
      RoomEdit(
        id: 'cloud-extra-$index',
        author: 'owner',
        clock: 4 + index,
        createdAt: 4 + index,
        text: 'Cloud edit $index',
      ),
    );
  }
  return history;
}

List<RoomEdit> _finalDiskHistory(List<RoomEdit> history) {
  final last = sequenceAuthoredEdit(
    const RoomEdit(
      id: 'final-cloud-text',
      author: 'owner',
      clock: 4,
      createdAt: 4,
      text: 'Last edit before disconnect',
    ),
    history,
  );
  final detach = sequenceAuthoredEdit(
    RoomEdit(
      id: 'final-detach',
      author: 'owner',
      clock: 5,
      createdAt: 5,
      text: jsonEncode({'action': 'disconnect', 'bindingId': _bindingId}),
      kind: RoomEditKind.diskConnection,
    ),
    [...history, last],
  );
  return [...history, last, detach];
}

void _expectNoDiskWrites(MemoryDiskBackend backend) {
  expect(backend.created, isEmpty);
  expect(backend.published, isEmpty);
  expect(backend.written, isEmpty);
}

void main() {
  for (final public in [false, true]) {
    group('readDiskRoomHistory ${public ? 'public' : 'private'}', () {
      late MemoryDiskBackend backend;
      late MemoryDiskClient client;
      late RoomDiskAccess access;
      late List<RoomEdit> history;

      List<String> getReads() => public ? backend.publicRead : backend.read;
      List<String> getListings() =>
          public ? backend.publicListed : backend.listed;

      Future<List<RoomEdit>> read({
        List<RoomEdit> localHistory = const [],
        bool Function()? isCurrent,
        Duration timeout = const Duration(seconds: 30),
        bool allowFinalDisconnect = false,
      }) => readDiskRoomHistory(
        client: client,
        roomId: _roomId,
        access: access,
        localHistory: localHistory,
        isCurrent: isCurrent,
        timeout: timeout,
        allowFinalDisconnect: allowFinalDisconnect,
      );

      setUp(() {
        backend = MemoryDiskBackend();
        client = MemoryDiskClient(backend);
        access = public
            ? RoomDiskAccess.guest(bindingId: _bindingId, publicUrl: _publicUrl)
            : RoomDiskAccess.editor(bindingId: _bindingId, token: _token);
        history = _diskAdmissionHistory();
        addTearDown(() {
          _expectNoDiskWrites(backend);
          client.close();
        });
      });

      test(
        'returns a canonical combined snapshot with read-only access',
        () async {
          final firstPath = backend.addBatch(history.reversed.toList());
          backend.addBatch([history.last]);
          backend.files['$_directory/readme.txt'] = Uint8List(0);
          final local = sequenceAuthoredEdit(
            const RoomEdit(
              id: 'local-only',
              author: 'local',
              clock: 4,
              createdAt: 4,
              text: 'Keep the durable local edit',
            ),
            history,
          );
          final localHistory = [history.first, local];
          final result = await read(localHistory: localHistory);
          expect(result.map((edit) => edit.id), [
            ...history.map((edit) => edit.id),
            local.id,
          ]);
          expect(localHistory, [history.first, local]);
          expect(() => result.add(local), throwsUnsupportedError);
          expect(getListings(), [public ? '/batches' : _directory]);
          expect(getReads(), hasLength(2));
          expect(
            getReads(),
            contains(
              public ? '/batches/${firstPath.split('/').last}' : firstPath,
            ),
          );
          expect(public ? backend.listed : backend.publicListed, isEmpty);
          expect(public ? backend.read : backend.publicRead, isEmpty);
          if (public) {
            expect(backend.publicUrls, everyElement(_publicUrl));
          }
          expect(client.closed, isFalse, reason: 'The caller owns the client');
        },
      );

      test(
        'propagates one guard and absolute deadline to every request',
        () async {
          backend.addBatch(history.take(2).toList());
          backend.addBatch([history.last]);
          backend.beforeList = (_) async {
            expect(backend.requestGuards.single!(), isTrue);
          };
          backend.beforeRead = (_) async {
            expect(backend.requestGuards.last!(), isTrue);
          };
          final started = DateTime.now();
          const timeout = Duration(seconds: 5);
          await read(timeout: timeout);
          final finished = DateTime.now();
          expect(backend.requestGuards, hasLength(3));
          final guard = backend.requestGuards.first!;
          final deadline = backend.requestDeadlines.first!;
          expect(backend.requestGuards, everyElement(same(guard)));
          expect(backend.requestDeadlines, everyElement(same(deadline)));
          expect(deadline.isBefore(started.add(timeout)), isFalse);
          expect(deadline.isAfter(finished.add(timeout)), isFalse);
          expect(
            guard(),
            isFalse,
            reason: 'The completed read context is closed',
          );
        },
      );

      testWidgets(
        'downloads at most four batches and preserves the out-of-order union',
        (tester) async {
          history = _diskAdmissionHistory(extraEdits: 6);
          for (final edit in history.reversed) {
            backend.addBatch([edit]);
          }
          final paths = backend.files.keys.toList()..sort();
          final gates = {for (final path in paths) path: Completer<void>()};
          var active = 0;
          var peak = 0;
          var finished = false;
          backend.beforeRead = (path) async {
            active++;
            if (active > peak) peak = active;
            try {
              await gates[path]!.future;
            } finally {
              active--;
            }
          };
          final pending = read().then((result) {
            finished = true;
            return result;
          });
          await tester.pump();
          expect(getReads(), hasLength(4));
          expect(active, 4);
          // Keep the first sorted batch blocked while the other slots progress.
          for (var index = 3; index < paths.length; index++) {
            gates[paths[index]]!.complete();
            await tester.pump();
            expect(
              getReads(),
              hasLength(index + 2 < paths.length ? index + 2 : paths.length),
            );
            expect(active, lessThanOrEqualTo(4));
            expect(finished, isFalse);
          }
          for (final path in paths.take(3).toList().reversed) {
            gates[path]!.complete();
            await tester.pump();
          }
          final result = await pending;
          expect(peak, 4);
          expect(active, 0);
          expect(result.map((edit) => edit.id), history.map((edit) => edit.id));
          expect(roomHistoryDigest(result), roomHistoryDigest(history));
          expect(
            getReads(),
            paths.map(
              (path) => public ? '/batches/${path.split('/').last}' : path,
            ),
          );
          final guard = backend.requestGuards.first!;
          final deadline = backend.requestDeadlines.first!;
          expect(backend.requestGuards, hasLength(1 + paths.length));
          expect(backend.requestGuards, everyElement(same(guard)));
          expect(backend.requestDeadlines, everyElement(same(deadline)));
          expect(guard(), isFalse);
        },
      );

      test('every snapshot freshly reads the immutable batches', () async {
        final path = backend.addBatch(history);
        await read();
        await read();
        expect(getReads(), hasLength(2));
        backend.files[path] = Uint8List.fromList([...backend.files[path]!, 32]);
        await expectLater(read(), throwsStateError);
        expect(getReads(), hasLength(3));
      });

      for (final invalidName in ['not-a-digest.json', '../${'f' * 64}.json']) {
        test(
          'validates even the last candidate before any download: $invalidName',
          () async {
            history = _diskAdmissionHistory(extraEdits: 5);
            for (final edit in history) {
              backend.addBatch([edit]);
            }
            backend.listing = [
              ...backend.files.keys.map((path) => path.split('/').last),
              invalidName,
            ];
            await expectLater(read(), throwsStateError);
            expect(getReads(), isEmpty);
          },
        );
      }

      for (final failure in [
        'transport',
        'hash',
        'json',
        'utf8',
        'version',
        'room',
        'binding',
        'record',
        'per-file-budget',
      ]) {
        testWidgets(
          '$failure stops queued downloads and observes late failures',
          (tester) async {
            final corruptExisting = failure == 'transport' || failure == 'hash';
            history = _diskAdmissionHistory(
              extraEdits: corruptExisting ? 1 : 0,
            );
            for (final edit in history) {
              backend.addBatch([edit]);
            }
            late final String badPath;
            if (corruptExisting) {
              badPath = (backend.files.keys.toList()..sort()).first;
            } else {
              final payload = {
                'v': failure == 'version' ? 2 : 1,
                'roomId': failure == 'room' ? 'f' * 32 : _roomId,
                'bindingId': failure == 'binding'
                    ? 'other-binding'
                    : _bindingId,
                'history': [
                  {
                    ...history.last.toJson(),
                    if (failure == 'record') 'clock': -1,
                  },
                ],
              };
              final bytes = failure == 'per-file-budget'
                  ? Uint8List(maxRoomTransferBytes + 1)
                  : Uint8List.fromList(
                      failure == 'utf8'
                          ? [0xff]
                          : utf8.encode(
                              failure == 'json'
                                  ? '{bad JSON'
                                  : jsonEncode(payload),
                            ),
                    );
              badPath = backend.addRawBatch(bytes);
            }
            // This correctly named queued candidate must never be requested.
            final queuedName = '${'f' * 64}.json';
            backend.listing = [
              ...backend.files.keys.map((path) => path.split('/').last),
              queuedName,
            ];
            expect(backend.files, hasLength(4));
            expect(badPath.split('/').last.compareTo(queuedName), lessThan(0));
            if (failure == 'hash') {
              backend.files[badPath] = Uint8List.fromList([
                ...backend.files[badPath]!,
                32,
              ]);
            }
            final releaseBad = Completer<void>();
            final releaseOthers = Completer<void>();
            backend.beforeRead = (path) async {
              if (path == badPath) {
                await releaseBad.future;
                if (failure == 'transport') {
                  throw StateError('Transport $_token');
                }
              } else {
                await releaseOthers.future;
                throw StateError('Late transport failure $_token');
              }
            };
            final failed = expectLater(read(), throwsStateError);
            await tester.pump();
            expect(getReads(), hasLength(4));
            releaseBad.complete();
            await tester.pump();
            await failed;
            for (final guard in backend.requestGuards) {
              expect(guard!(), isFalse);
            }
            expect(getReads(), hasLength(4));
            releaseOthers.complete();
            await tester.pump();
            expect(getReads(), hasLength(4));
          },
        );
      }

      testWidgets('cumulative raw budget stops queued downloads', (
        tester,
      ) async {
        final original = backend.addBatch(history);
        final payload = backend.files.remove(original)!;
        final size = maxRoomTransferBytes ~/ 2 + 1;
        final padded = Uint8List(size)..fillRange(0, size, 32);
        padded.setRange(0, payload.length, payload);
        final firstLarge = backend.addRawBatch(padded);
        final second = Uint8List.fromList(padded);
        second[second.length - 1] = 10;
        final secondLarge = backend.addRawBatch(second);
        backend.addBatch([history.first]);
        backend.addBatch([history.last]);
        final queuedNames = ['${'f' * 63}e.json', '${'f' * 64}.json'];
        expect(
          backend.files.keys.every(
            (path) => path.split('/').last.compareTo(queuedNames.first) < 0,
          ),
          isTrue,
        );
        backend.listing = [
          ...backend.files.keys.map((path) => path.split('/').last),
          ...queuedNames,
        ];
        final gates = {
          for (final name in backend.listing!)
            '$_directory/$name': Completer<void>(),
        };
        backend.beforeRead = (path) => gates[path]!.future;
        final failed = expectLater(read(), throwsStateError);
        await tester.pump();
        expect(getReads(), hasLength(4));
        gates[firstLarge]!.complete();
        await tester.pump();
        expect(getReads(), hasLength(5));
        gates[secondLarge]!.complete();
        await tester.pump();
        await failed;
        expect(
          getReads(),
          hasLength(5),
          reason: 'No sixth read after budget failure',
        );
        for (final guard in backend.requestGuards) {
          expect(guard!(), isFalse);
        }
        for (final gate in gates.values) {
          if (!gate.isCompleted) gate.complete();
        }
        await tester.pump();
        expect(getReads(), hasLength(5));
      });

      test(
        'terminal disconnect is not fresh admission or private access',
        () async {
          final terminal = _finalDiskHistory(history);
          backend.addBatch(terminal);
          await expectLater(read(localHistory: history), throwsStateError);
          await expectLater(read(allowFinalDisconnect: true), throwsStateError);
          if (public) {
            final result = await read(
              localHistory: history,
              allowFinalDisconnect: true,
            );
            expect(roomHistoryDigest(result), roomHistoryDigest(terminal));
          } else {
            await expectLater(
              read(localHistory: history, allowFinalDisconnect: true),
              throwsStateError,
            );
          }
        },
      );

      test(
        'terminal mode still rejects a projected replacement binding',
        () async {
          final terminal = _finalDiskHistory(history);
          final replacement = sequenceAuthoredEdit(
            const RoomEdit(
              id: 'replacement',
              author: 'owner',
              clock: 6,
              createdAt: 6,
              text: '{"action":"connect"}',
              kind: RoomEditKind.diskConnection,
            ),
            terminal,
          );
          backend.addBatch([...terminal, replacement]);
          await expectLater(
            read(localHistory: history, allowFinalDisconnect: true),
            throwsStateError,
          );
        },
      );

      test('uses all listed batches beyond a single 1000-item page', () async {
        // Pagination belongs to the client. Consume its entire returned list,
        // including the only binding proof placed after the first page.
        backend.addBatch([history.last]);
        final firstName = backend.files.keys.single.split('/').last;
        final bindingPath = backend.addBatch(history.take(2).toList());
        backend.listing = [
          ...List.filled(1000, firstName),
          bindingPath.split('/').last,
        ];
        expect(roomHistoryDigest(await read()), roomHistoryDigest(history));
        expect(getReads(), hasLength(2));
      });

      for (final localPredecessor in [false, true]) {
        test(
          'prefixes can be supplied by ${localPredecessor ? 'local history' : 'other batches'}',
          () async {
            backend.addBatch(history.skip(1).toList());
            if (!localPredecessor) backend.addBatch([history.first]);
            final result = await read(
              localHistory: localPredecessor ? [history.first] : const [],
            );
            expect(roomHistoryDigest(result), roomHistoryDigest(history));
          },
        );
      }

      test('valid binding schema is independent of admission roles', () async {
        final binding = sequenceAuthoredEdit(
          const RoomEdit(
            id: _bindingId,
            author: 'owner-without-role',
            clock: 1,
            createdAt: 1,
            text: '{"action":"connect"}',
            kind: RoomEditKind.diskConnection,
          ),
          const [],
        );
        backend.addBatch([binding]);
        expect((await read()).single.sameContentAs(binding), isTrue);
      });

      for (final corruption in [
        'empty',
        'empty-batch',
        'missing-binding',
        'hash',
        'room',
        'binding',
        'version',
        'envelope',
        'json',
        'utf8',
        'record',
        'binding-schema',
        'name',
        'path-name',
        'conflict',
        'local-conflict',
        'gap',
        'detached',
        'local-detach',
        'rebound',
        'mixed-room',
      ]) {
        test('rejects $corruption instead of admitting a snapshot', () async {
          var local = <RoomEdit>[];
          var batch = List<RoomEdit>.of(history);
          if (corruption == 'empty-batch') batch = [];
          if (corruption == 'missing-binding') batch = [history.first];
          if (corruption == 'gap') batch = history.skip(1).toList();
          if (corruption != 'empty') {
            backend.addBatch(
              batch,
              roomId: corruption == 'room' ? 'f' * 32 : _roomId,
              bindingId: corruption == 'binding' ? 'other-binding' : _bindingId,
            );
          }
          switch (corruption) {
            case 'empty' || 'empty-batch':
              local = history;
            case 'hash':
              final path = backend.files.keys.single;
              backend.files[path] = Uint8List.fromList([
                ...backend.files[path]!,
                32,
              ]);
            case 'version' || 'record' || 'binding-schema':
              final envelope =
                  jsonDecode(utf8.decode(backend.files.values.single))
                      as Map<String, dynamic>;
              if (corruption == 'version') {
                envelope['v'] = 2;
              } else if (corruption == 'record') {
                (envelope['history'] as List)[0]['clock'] = -1;
              } else {
                (envelope['history'] as List)[1]['text'] =
                    '{"action":"connect","token":"$_token"}';
              }
              backend.files.clear();
              backend.addRawBatch(
                Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
              );
            case 'envelope' || 'json' || 'utf8':
              backend.files.clear();
              backend.addRawBatch(
                Uint8List.fromList(
                  corruption == 'utf8'
                      ? [0xff]
                      : utf8.encode(corruption == 'json' ? '{bad JSON' : '[]'),
                ),
              );
            case 'name':
              final path = backend.files.keys.single;
              backend.files['$_directory/not-a-digest.json'] = backend.files
                  .remove(path)!;
            case 'path-name':
              backend.listing = ['../${'a' * 64}.json'];
            case 'conflict' || 'local-conflict':
              final conflicting = RoomEdit.fromJson({
                ...history.last.toJson(),
                'text': 'Rewritten immutable ID',
              })!;
              if (corruption == 'local-conflict') {
                local = [...history.take(2), conflicting];
              } else {
                backend.addBatch([conflicting]);
              }
            case 'detached' || 'local-detach' || 'rebound':
              final detach = sequenceAuthoredEdit(
                RoomEdit(
                  id: 'detach',
                  author: 'owner',
                  clock: 4,
                  createdAt: 4,
                  text: jsonEncode({
                    'action': 'disconnect',
                    'bindingId': _bindingId,
                  }),
                  kind: RoomEditKind.diskConnection,
                ),
                history,
              );
              if (corruption == 'local-detach') {
                local = [...history, detach];
              } else {
                backend.addBatch([detach]);
              }
              if (corruption == 'rebound') {
                backend.addBatch([
                  sequenceAuthoredEdit(
                    const RoomEdit(
                      id: 'replacement-binding',
                      author: 'owner',
                      clock: 5,
                      createdAt: 5,
                      text: '{"action":"connect"}',
                      kind: RoomEditKind.diskConnection,
                    ),
                    [...history, detach],
                  ),
                ]);
              }
            case 'mixed-room':
              backend.addBatch(history, roomId: 'f' * 32);
          }
          await expectLater(read(localHistory: local), throwsStateError);
          if (corruption == 'name' || corruption == 'path-name') {
            expect(getReads(), isEmpty);
          }
        });
      }

      test('bounds candidate JSON count before downloading any file', () async {
        backend.addBatch(history);
        final name = backend.files.keys.single.split('/').last;
        backend.listing = List.filled(2049, name);
        await expectLater(read(), throwsStateError);
        expect(getReads(), isEmpty);
      });

      test(
        'accepts the 2048 candidate boundary and deduplicates reads',
        () async {
          backend.addBatch(history);
          backend.listing = List.filled(
            2048,
            backend.files.keys.single.split('/').last,
          );
          expect(roomHistoryDigest(await read()), roomHistoryDigest(history));
          expect(getReads(), hasLength(1));
        },
      );

      for (final totalLimit in [false, true]) {
        test('bounds ${totalLimit ? 'total raw' : 'per-file'} bytes', () async {
          final path = backend.addBatch(history);
          final payload = backend.files.remove(path)!;
          final size = totalLimit
              ? maxRoomTransferBytes ~/ 2 + 1
              : maxRoomTransferBytes + 1;
          final padded = Uint8List(size)..fillRange(0, size, 32);
          padded.setRange(0, payload.length, payload);
          backend.addRawBatch(padded);
          if (totalLimit) {
            final duplicate = Uint8List.fromList(padded);
            duplicate[duplicate.length - 1] = 10;
            backend.addRawBatch(duplicate);
          }
          // The logical history is tiny and identical across batches. Limits
          // apply to downloaded bytes, including whitespace and repeated edits.
          await expectLater(read(), throwsStateError);
          expect(getReads(), hasLength(totalLimit ? 2 : 1));
        });
      }

      test('accepts exactly 8 MiB of raw bytes', () async {
        final path = backend.addBatch(history);
        final payload = backend.files.remove(path)!;
        final padded = Uint8List(maxRoomTransferBytes)
          ..fillRange(0, maxRoomTransferBytes, 32);
        padded.setRange(0, payload.length, payload);
        backend.addRawBatch(padded);
        expect(roomHistoryDigest(await read()), roomHistoryDigest(history));
      });

      test(
        'bounds the canonical union even when each input fits separately',
        () async {
          RoomEdit largeEdit(String id, String author) => sequenceAuthoredEdit(
            RoomEdit(
              id: id,
              author: author,
              clock: 4,
              createdAt: 4,
              text: 'x' * (maxRoomTransferBytes ~/ 2),
            ),
            const [],
          );
          final local = largeEdit('large-local', 'local');
          final remote = largeEdit('large-remote', 'remote');
          backend.addBatch([...history, remote]);
          expect(
            backend.files.values.single.length,
            lessThan(maxRoomTransferBytes),
          );
          await expectLater(read(localHistory: [local]), throwsStateError);
        },
      );

      for (final extraByte in [false, true]) {
        test(
          'canonical union ${extraByte ? 'rejects one byte over' : 'accepts exactly'} 8 MiB',
          () async {
            final empty = sequenceAuthoredEdit(
              const RoomEdit(
                id: 'large-local',
                author: 'local',
                clock: 4,
                createdAt: 4,
                text: '',
              ),
              const [],
            );
            final overhead = utf8
                .encode(
                  jsonEncode(
                    [...history, empty].map((edit) => edit.toJson()).toList(),
                  ),
                )
                .length;
            final large = RoomEdit.fromJson({
              ...empty.toJson(),
              'text':
                  'x' * (maxRoomTransferBytes - overhead + (extraByte ? 1 : 0)),
            })!;
            backend.addBatch(history);
            final local = [...history, large];
            if (extraByte) {
              await expectLater(read(localHistory: local), throwsStateError);
            } else {
              final result = await read(localHistory: local);
              expect(result, hasLength(local.length));
              expect(result.last.sameContentAs(large), isTrue);
            }
          },
        );
      }

      test(
        'canonical byte bound counts UTF-8 bytes rather than characters',
        () async {
          final large = sequenceAuthoredEdit(
            RoomEdit(
              id: 'large-unicode',
              author: 'local',
              clock: 4,
              createdAt: 4,
              text: 'я' * (maxRoomTransferBytes ~/ 2),
            ),
            const [],
          );
          backend.addBatch(history);
          await expectLater(read(localHistory: [large]), throwsStateError);
        },
      );

      test(
        'sanitizes client failures, including URLs and credentials',
        () async {
          backend.addBatch(history);
          backend.beforeRead = (_) async {
            throw StateError('Transport $_token $_publicUrl');
          };
          await expectLater(
            read(),
            throwsA(
              isA<StateError>().having(
                (error) => error.toString(),
                'safe message',
                allOf(
                  isNot(contains(_token)),
                  isNot(contains(_publicUrl)),
                  isNot(contains('Transport')),
                ),
              ),
            ),
          );
        },
      );

      test(
        'freezes the provided local prefix before awaiting the cloud',
        () async {
          backend.addBatch(history.skip(1).toList());
          final local = [history.first];
          final entered = Completer<void>();
          final release = Completer<void>();
          backend.beforeList = (_) async {
            entered.complete();
            await release.future;
          };
          final pending = read(localHistory: local);
          await entered.future;
          local.clear();
          release.complete();
          expect(roomHistoryDigest(await pending), roomHistoryDigest(history));
          expect(local, isEmpty);
        },
      );

      test('cancelled generation starts no requests', () async {
        backend.addBatch(history);
        await expectLater(read(isCurrent: () => false), throwsStateError);
        expect(getListings(), isEmpty);
        expect(getReads(), isEmpty);
      });

      for (final stage in ['list', 'read']) {
        test('cancellation during $stage cannot continue or succeed', () async {
          history = _diskAdmissionHistory(extraEdits: 4);
          for (final edit in history) {
            backend.addBatch([edit]);
          }
          final entered = Completer<void>();
          final release = Completer<void>();
          Future<void> gate(String _) async {
            if (!entered.isCompleted) entered.complete();
            await release.future;
          }

          if (stage == 'list') {
            backend.beforeList = gate;
          } else {
            backend.beforeRead = gate;
          }
          var generation = 0;
          final pending = read(isCurrent: () => generation == 0);
          final failed = expectLater(pending, throwsStateError);
          await entered.future;
          generation++;
          expect(backend.requestGuards.last!(), isFalse);
          release.complete();
          await failed;
          expect(getListings(), hasLength(1));
          expect(getReads(), hasLength(stage == 'list' ? 0 : 4));
        });

        testWidgets('overall deadline stops late $stage continuation', (
          tester,
        ) async {
          history = _diskAdmissionHistory(extraEdits: 4);
          for (final edit in history) {
            backend.addBatch([edit]);
          }
          final release = Completer<void>();
          if (stage == 'list') {
            backend.beforeList = (_) => release.future;
          } else {
            backend.beforeRead = (_) => release.future;
          }
          var finished = false;
          final pending = read(timeout: const Duration(seconds: 1));
          final failed = expectLater(pending, throwsStateError).then((_) {
            finished = true;
          });
          await tester.pump();
          expect(getListings(), hasLength(1));
          expect(getReads(), hasLength(stage == 'list' ? 0 : 4));
          await tester.pump(const Duration(seconds: 1));
          expect(finished, isTrue, reason: 'The overall wait is bounded');
          await failed;
          expect(backend.requestGuards.last!(), isFalse);
          release.complete();
          await tester.pump();
          expect(getReads(), hasLength(stage == 'list' ? 0 : 4));
        });
      }

      test('expired deadline starts no requests', () async {
        backend.addBatch(history);
        await expectLater(read(timeout: Duration.zero), throwsStateError);
        expect(getListings(), isEmpty);
        expect(getReads(), isEmpty);
      });
    });
  }

  group('RoomDiskReadSync', () {
    late MemoryDiskBackend backend;
    late MemoryDiskClient client;
    late RoomDiskReadSync sync;
    late RoomDiskAccess access;
    late List<RoomEdit> cloud;
    late List<RoomEdit> local;
    late int merges;
    late int changes;

    setUp(() {
      backend = MemoryDiskBackend();
      client = MemoryDiskClient(backend);
      access = RoomDiskAccess.guest(
        bindingId: _bindingId,
        publicUrl: _publicUrl,
      );
      cloud = _diskAdmissionHistory();
      backend.addBatch(cloud);
      local = [];
      merges = 0;
      changes = 0;
      sync = RoomDiskReadSync(
        roomId: _roomId,
        client: client,
        readHistory: () => local,
        mergeHistory: (edits) async {
          merges++;
          local = validateAuthorHistory([...local, ...edits]);
        },
        onChanged: () => changes++,
        pollInterval: const Duration(seconds: 10),
      );
      addTearDown(() {
        sync.dispose();
        expect(client.closed, isFalse, reason: 'Shared client stays open');
        _expectNoDiskWrites(backend);
        expect(backend.listed, isEmpty);
        expect(backend.read, isEmpty);
        client.close();
      });
    });

    test(
      'merges reads without claiming local guest metadata was uploaded',
      () async {
        final profile = sequenceAuthoredEdit(
          const RoomEdit(
            id: 'guest-profile',
            author: 'guest',
            clock: 4,
            createdAt: 4,
            text: 'Guest',
            kind: RoomEditKind.participantName,
          ),
          const [],
        );
        local = [profile];
        final entered = Completer<void>();
        final release = Completer<void>();
        backend.beforeList = (_) async {
          entered.complete();
          await release.future;
        };
        expect(sync.status, 'Нет гостевого доступа к Диску');
        sync.update(access: access, enabled: true);
        expect(sync.status, 'Ожидаем историю с Диска');
        final pending = sync.sync();
        expect(identical(sync.sync(), pending), isTrue);
        await entered.future;
        expect(sync.busy, isTrue);
        expect(sync.status, 'Чтение истории с Диска…');
        final concurrent = sequenceAuthoredEdit(
          const RoomEdit(
            id: 'guest-concurrent',
            author: 'guest',
            clock: 5,
            createdAt: 5,
            text: 'Guest renamed while reading',
            kind: RoomEditKind.participantName,
          ),
          local,
        );
        local = [...local, concurrent];
        release.complete();
        await pending;
        expect(sync.busy, isFalse);
        expect(sync.error, isNull);
        expect(sync.status, 'История прочитана с Диска');
        expect(sync.status, isNot(contains('подтверждена')));
        expect(merges, 1);
        expect(changes, 2);
        expect(local.map((edit) => edit.id), [
          ...cloud.map((edit) => edit.id),
          profile.id,
          concurrent.id,
        ]);
        expect(
          roomHistoryDigest(backend.uploadedHistory),
          roomHistoryDigest(cloud),
        );
      },
    );

    testWidgets('debounces and periodically refreshes the public snapshot', (
      tester,
    ) async {
      sync.update(access: access, enabled: true);
      await tester.pump(const Duration(milliseconds: 799));
      expect(backend.publicListed, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(merges, 1);
      expect(sync.status, 'История прочитана с Диска');
      final later = sequenceAuthoredEdit(
        const RoomEdit(
          id: 'cloud-later',
          author: 'owner',
          clock: 4,
          createdAt: 4,
          text: 'Later public change',
        ),
        cloud,
      );
      backend.addBatch([later]);
      await tester.pump(const Duration(seconds: 9));
      expect(merges, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(merges, 2);
      expect(local.map((edit) => edit.id), contains(later.id));
      sync.update(access: access, enabled: false);
      await tester.pump(const Duration(minutes: 1));
      expect(merges, 2);
      expect(sync.status, 'Чтение Диска приостановлено');
    });

    testWidgets(
      'imports the final edit and disconnect, then stops even on resume',
      (tester) async {
        local = List<RoomEdit>.of(cloud);
        final terminal = _finalDiskHistory(cloud);
        backend.addBatch(terminal.skip(cloud.length).toList());
        sync.update(access: access, enabled: true);
        await sync.sync();
        expect(merges, 1);
        expect(roomHistoryDigest(local), roomHistoryDigest(terminal));
        expect(sync.error, isNull);
        expect(sync.status, 'Подключение Диска отключено');
        final reads = backend.publicRead.length;
        final listings = backend.publicListed.length;
        await tester.pump(const Duration(seconds: 61));
        sync.update(access: access, enabled: true);
        sync.schedule();
        await tester.pump(const Duration(seconds: 61));
        await expectLater(sync.sync(), throwsStateError);
        expect(backend.publicRead, hasLength(reads));
        expect(backend.publicListed, hasLength(listings));
        expect(merges, 1);
        await expectLater(
          readDiskRoomHistory(client: client, roomId: _roomId, access: access),
          throwsStateError,
        );
      },
    );

    for (final corruption in ['gap', 'hash', 'replacement', 'never-active']) {
      test('terminal polling rejects $corruption without merging', () async {
        local = List<RoomEdit>.of(cloud);
        final terminal = _finalDiskHistory(cloud);
        final path = backend.addBatch(
          corruption == 'gap'
              ? [terminal.last]
              : terminal.skip(cloud.length).toList(),
        );
        switch (corruption) {
          case 'hash':
            backend.files[path] = Uint8List.fromList([
              ...backend.files[path]!,
              32,
            ]);
          case 'replacement':
            backend.addBatch([
              sequenceAuthoredEdit(
                const RoomEdit(
                  id: 'replacement-binding',
                  author: 'owner',
                  clock: 6,
                  createdAt: 6,
                  text: '{"action":"connect"}',
                  kind: RoomEditKind.diskConnection,
                ),
                terminal,
              ),
            ]);
          case 'never-active':
            // The expected binding's connect lost to an earlier claim. Its
            // disconnect is a no-op, not a terminal proof, even though a later
            // disconnect of the other binding makes the final projection null.
            backend.addBatch([
              const RoomEdit(
                id: 'earlier-binding',
                author: 'other',
                clock: 0,
                createdAt: 0,
                text: '{"action":"connect"}',
                kind: RoomEditKind.diskConnection,
              ),
              const RoomEdit(
                id: 'other-detach',
                author: 'other',
                clock: 6,
                createdAt: 6,
                text: '{"action":"disconnect","bindingId":"earlier-binding"}',
                kind: RoomEditKind.diskConnection,
              ),
            ]);
        }
        sync.update(access: access, enabled: true);
        await expectLater(sync.sync(), throwsStateError);
        expect(merges, 0);
        expect(roomHistoryDigest(local), roomHistoryDigest(cloud));
        expect(sync.error, isNotNull);
      });
    }

    testWidgets('never reads with editor, missing or disabled access', (
      tester,
    ) async {
      for (final next in [
        RoomDiskAccess.editor(bindingId: _bindingId, token: _token),
        null,
      ]) {
        sync.update(access: next, enabled: true);
        sync.schedule();
        await expectLater(sync.sync(), throwsStateError);
        await tester.pump(const Duration(minutes: 1));
      }
      sync.update(access: access, enabled: false);
      sync.schedule();
      await expectLater(sync.sync(), throwsStateError);
      await tester.pump(const Duration(minutes: 1));
      expect(backend.publicListed, isEmpty);
      expect(merges, 0);
    });

    test(
      'failed read is sanitized and can be retried without writes',
      () async {
        backend.beforeRead = (_) async {
          throw StateError('Transport $_token $_publicUrl');
        };
        sync.update(access: access, enabled: true);
        await expectLater(sync.sync(), throwsStateError);
        expect(merges, 0);
        expect(local, isEmpty);
        expect(sync.error, isNotNull);
        expect(sync.error, isNot(contains(_token)));
        expect(sync.error, isNot(contains(_publicUrl)));
        expect(sync.status, contains('недоступен'));
        backend.beforeRead = null;
        await sync.sync();
        expect(sync.error, isNull);
        expect(merges, 1);
        expect(sync.status, 'История прочитана с Диска');
      },
    );

    testWidgets(
      'partial parallel reads never merge or claim a valid snapshot',
      (tester) async {
        cloud = _diskAdmissionHistory(extraEdits: 5);
        backend.files.clear();
        for (final edit in cloud) {
          backend.addBatch([edit]);
        }
        final paths = backend.files.keys.toList()..sort();
        final gates = {for (final path in paths) path: Completer<void>()};
        backend.beforeRead = (path) async {
          await gates[path]!.future;
          if (path == paths[3]) throw StateError('Failed batch $_token');
        };
        sync.update(access: access, enabled: true);
        var finished = false;
        final failed = expectLater(sync.sync(), throwsStateError).then((_) {
          finished = true;
        });
        await tester.pump();
        expect(backend.publicRead, hasLength(4));
        for (final path in paths.take(3)) {
          gates[path]!.complete();
        }
        await tester.pump();
        expect(backend.publicRead, hasLength(7));
        expect(finished, isFalse);
        expect(sync.busy, isTrue);
        expect(merges, 0);
        expect(local, isEmpty);
        expect(sync.status, isNot('История прочитана с Диска'));
        gates[paths[3]]!.complete();
        await tester.pump();
        await failed;
        expect(sync.busy, isFalse);
        expect(merges, 0);
        expect(local, isEmpty);
        expect(sync.error, isNotNull);
        expect(sync.error, isNot(contains(_token)));
        expect(sync.status, isNot('История прочитана с Диска'));
        for (final gate in gates.values) {
          if (!gate.isCompleted) gate.complete();
        }
        await tester.pump();
        expect(backend.publicRead, hasLength(7));
        expect(merges, 0);
        backend.beforeRead = null;
        await sync.sync();
        expect(backend.publicRead, hasLength(7 + paths.length));
        expect(merges, 1);
        expect(roomHistoryDigest(local), roomHistoryDigest(cloud));
        expect(sync.status, 'История прочитана с Диска');
        sync.update(access: access, enabled: false);
      },
    );

    testWidgets('a timed-out poll cannot merge a late public response', (
      tester,
    ) async {
      final release = Completer<void>();
      backend.beforeRead = (_) => release.future;
      sync.update(access: access, enabled: true);
      final failed = expectLater(sync.sync(), throwsStateError);
      await tester.pump();
      expect(backend.publicRead, hasLength(1));
      await tester.pump(const Duration(seconds: 30));
      await failed;
      expect(sync.busy, isFalse);
      expect(sync.error, isNotNull);
      expect(merges, 0);
      release.complete();
      await tester.pump();
      expect(merges, 0);
      expect(backend.publicRead, hasLength(1));
      sync.update(access: access, enabled: false);
    });

    testWidgets(
      'replacing access invalidates the old poll and reads the new binding',
      (tester) async {
        const nextBinding = 'next-binding';
        const nextUrl = 'https://disk.yandex.ru/d/next-binding';
        const nextRoot = 'app:/mytree/$_roomId/$nextBinding';
        final replacement = sequenceAuthoredEdit(
          const RoomEdit(
            id: nextBinding,
            author: 'new-owner',
            clock: 1,
            createdAt: 1,
            text: '{"action":"connect"}',
            kind: RoomEditKind.diskConnection,
          ),
          const [],
        );
        backend.publicRoots[nextUrl] = nextRoot;
        backend.addBatch(
          [replacement],
          bindingId: nextBinding,
          directory: '$nextRoot/batches',
        );
        final release = Completer<void>();
        backend.beforeRead = (path) async {
          if (path.startsWith('$_directory/')) await release.future;
        };
        sync.update(access: access, enabled: true);
        final oldFailed = expectLater(sync.sync(), throwsStateError);
        await tester.pump();
        final nextAccess = RoomDiskAccess.guest(
          bindingId: nextBinding,
          publicUrl: nextUrl,
        );
        sync.update(access: nextAccess, enabled: true);
        release.complete();
        await tester.pump();
        await oldFailed;
        expect(merges, 0, reason: 'The cancelled binding must not merge');
        expect(backend.publicRead, hasLength(1));
        // pump() only drains microtasks; advance the fake timer queue explicitly
        // to run the zero-delay retry scheduled after the old poll completes.
        await tester.pump(Duration.zero);
        expect(merges, 1);
        expect(local.single.sameContentAs(replacement), isTrue);
        expect(sync.error, isNull);
        expect(sync.status, 'История прочитана с Диска');
        sync.update(access: nextAccess, enabled: false);
      },
    );

    test('failed durable merge does not claim a successful read', () async {
      sync.dispose();
      sync = RoomDiskReadSync(
        roomId: _roomId,
        client: client,
        readHistory: () => local,
        mergeHistory: (_) async {
          throw StateError('Local journal failed $_token');
        },
        onChanged: () {},
      );
      sync.update(access: access, enabled: true);
      await expectLater(sync.sync(), throwsStateError);
      expect(local, isEmpty);
      expect(sync.error, isNotNull);
      expect(sync.error, isNot(contains(_token)));
      expect(sync.status, isNot('История прочитана с Диска'));
    });

    for (final stop in ['disable', 'detach', 'dispose']) {
      test('$stop invalidates an in-flight public snapshot', () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        backend.beforeRead = (_) async {
          entered.complete();
          await release.future;
        };
        sync.update(access: access, enabled: true);
        final pending = sync.sync();
        final failed = expectLater(pending, throwsStateError);
        await entered.future;
        if (stop == 'dispose') {
          sync.dispose();
        } else {
          sync.update(access: stop == 'detach' ? null : access, enabled: false);
        }
        release.complete();
        await failed;
        expect(merges, 0);
        expect(local, isEmpty);
        expect(sync.error, isNull);
        expect(client.closed, isFalse);
      });
    }
  });

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
