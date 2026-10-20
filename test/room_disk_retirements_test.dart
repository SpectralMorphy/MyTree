import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/cloud/room_disk_retirements.dart';
import 'package:mytree_webrtc_demo/cloud/yandex_disk_client.dart';
import 'package:mytree_webrtc_demo/room_document.dart';
import 'package:mytree_webrtc_demo/storage/room_store.dart';

const _room = 'dddddddddddddddddddddddddddddddd';

class _Disk extends YandexDiskClient {
  final written = <String, List<RoomEdit>>{};
  bool closed = false;

  @override
  Future<List<String>> listFiles(
    String token,
    String path, {
    bool Function()? isCurrent,
    DateTime? deadline,
  }) async => [];

  @override
  Future<void> writeFile(String token, String path, Uint8List bytes) async {
    written[path] = decodeRoomHistory(
      (jsonDecode(utf8.decode(bytes)) as Map)['history'],
    );
  }

  @override
  void close() => closed = true;
}

class _GatedStore extends MemoryRoomStore {
  final reading = Completer<void>();
  final release = Completer<void>();
  bool gate = true;

  @override
  Future<Map<String, dynamic>?> loadDiskCredentials(
    String roomId, {
    String? bindingId,
  }) async {
    if (bindingId == 'binding-a' && gate) {
      gate = false;
      reading.complete();
      await release.future;
    }
    return super.loadDiskCredentials(roomId, bindingId: bindingId);
  }
}

List<RoomEdit> _binding(String id, int clock) => [
  RoomEdit(
    id: id,
    author: 'editor',
    clock: clock,
    createdAt: clock,
    kind: RoomEditKind.diskConnection,
    text: '{"action":"connect"}',
  ),
  RoomEdit(
    id: 'detach-$id',
    author: 'editor',
    clock: clock + 1,
    createdAt: clock + 1,
    kind: RoomEditKind.diskConnection,
    text: jsonEncode({'action': 'disconnect', 'bindingId': id}),
  ),
];

void main() {
  testWidgets(
    'late proof allocation cannot expand old-clock drafts into replacement Disk history',
    (tester) async {
      final store = MemoryRoomStore();
      final disk = _Disk();
      final old = _binding('binding-a', 1);
      final first = old[0].withAuthorProof(
        authorSequence: 1,
        authorPrevious: null,
        authorBase: [],
      );
      final detach = old[1].withAuthorProof(
        authorSequence: 2,
        authorPrevious: first.id,
      );
      final replacement = _binding(
        'binding-b',
        3,
      ).first.withAuthorProof(authorSequence: 3, authorPrevious: detach.id);
      final stale = const RoomEdit(
        id: 'stale-draft',
        author: 'editor',
        clock: 1,
        createdAt: 1,
        text: 'Retried later',
      ).withAuthorProof(authorSequence: 4, authorPrevious: replacement.id);
      final history = [first, detach, replacement, stale];
      await store.saveDiskCredentials(_room, {
        'v': 1,
        'bindingId': first.id,
        'token': 'old-token',
      });
      final retirements = RoomDiskRetirements(
        roomId: _room,
        store: store,
        client: disk,
        readHistory: () => history,
        mergeHistory: (_) async {},
        onChanged: () {},
      );
      addTearDown(retirements.dispose);
      await retirements.update(enabled: true);
      await retirements.sync();
      await tester.pump();
      final sent = disk.written.values
          .expand((edits) => edits)
          .map((edit) => edit.id)
          .toSet();
      expect(sent, {first.id, detach.id});
      expect(sent, isNot(contains(replacement.id)));
      expect(sent, isNot(contains(stale.id)));
      expect(disk.closed, isFalse);
    },
  );

  testWidgets(
    'a detach arriving during archive load is scheduled without another edit or manual sync',
    (tester) async {
      final store = _GatedStore();
      final disk = _Disk();
      final history = _binding('binding-a', 1);
      for (final id in ['binding-a', 'binding-b']) {
        await store.saveDiskCredentials(_room, {
          'v': 1,
          'bindingId': id,
          'token': 'token-$id',
        });
      }
      final retirements = RoomDiskRetirements(
        roomId: _room,
        store: store,
        client: disk,
        readHistory: () => List.of(history),
        mergeHistory: (_) async {},
        onChanged: () {},
      );
      addTearDown(retirements.dispose);
      final first = retirements.update(enabled: true);
      await store.reading.future;
      history.addAll(_binding('binding-b', 3));
      final second = retirements.update(enabled: true);
      store.release.complete();
      await Future.wait([first, second]);
      // Do not call sync(): the coalesced update must schedule both automatically.
      await tester.pump(const Duration(milliseconds: 900));
      for (var i = 0; i < 30; i++) {
        await tester.pump();
      }
      expect(
        disk.written.keys.any((path) => path.contains('/binding-a/')),
        isTrue,
      );
      expect(
        disk.written.keys.any((path) => path.contains('/binding-b/')),
        isTrue,
      );
      final old = disk.written.entries
          .singleWhere((entry) => entry.key.contains('/binding-a/'))
          .value;
      expect(
        old.map((edit) => edit.id),
        containsAll(['binding-a', 'detach-binding-a']),
      );
      expect(old.any((edit) => edit.id.contains('binding-b')), isFalse);
      expect(
        disk.closed,
        isFalse,
        reason: 'Retirement must not close the shared active client.',
      );
    },
  );
}
