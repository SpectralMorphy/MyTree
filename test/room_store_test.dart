import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/room_document.dart';
import 'package:mytree_webrtc_demo/storage/create_room_store.dart';
import 'package:mytree_webrtc_demo/storage/file_room_store.dart';
import 'package:mytree_webrtc_demo/storage/room_store.dart';

Map<String, dynamic> _operation(String id, [String text = 'hello']) => {
  'id': id,
  'text': text,
  'clock': 1,
  'nested': {
    'tags': <String>['original'],
  },
};

RoomEdit _draft(String id, {String author = 'actor', int clock = 1}) =>
    RoomEdit(id: id, author: author, clock: clock, createdAt: 1, text: id);

List<RoomEdit> _prefix() {
  final first = sequenceAuthoredEdit(_draft('first', clock: 3), []);
  final second = sequenceAuthoredEdit(_draft('second', clock: 2), [first]);
  final third = sequenceAuthoredEdit(_draft('third', clock: 1), [
    first,
    second,
  ]);
  return [first, second, third];
}

class _FailingMemoryStore extends MemoryRoomStore {
  int calls = 0;
  int? failAt;
  bool failAfterWrite = false;
  Completer<void>? pause;
  final entered = Completer<void>();

  @override
  Future<void> appendHistory(
    String roomId,
    List<Map<String, dynamic>> operations,
  ) async {
    calls++;
    if (pause != null && !entered.isCompleted) {
      entered.complete();
      await pause!.future;
    }
    final fail = calls == failAt;
    if (fail && !failAfterWrite) throw StateError('Injected storage failure');
    await super.appendHistory(roomId, operations);
    if (fail) throw StateError('Write succeeded but acknowledgement failed');
  }
}

String _key(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');

File _historyFile(Directory directory, String room) =>
    File('${directory.path}/history-${_key(room)}.jsonl');

const _credentialRoom = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _otherCredentialRoom = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
Map<String, dynamic> _credentials({
  String bindingId = 'binding',
  String token = 'local-only-token',
}) => {'v': 1, 'bindingId': bindingId, 'token': token};
File _credentialsFile(Directory directory, [String room = _credentialRoom]) =>
    File('${directory.path}/disk-credentials-${_key(room)}.json');
File _credentialsArchiveFile(Directory directory, String bindingId) => File(
  '${directory.path}/disk-credentials-${_key(_credentialRoom)}.binding.${sha256.convert(utf8.encode(bindingId))}.json',
);

const _publicUrl = 'https://disk.yandex.ru/d/public-access-marker';
Map<String, dynamic> _publicAccess({
  String bindingId = 'binding',
  String publicUrl = _publicUrl,
}) => {'v': 1, 'bindingId': bindingId, 'publicUrl': publicUrl};
File _publicAccessFile(Directory directory, [String room = _credentialRoom]) =>
    File('${directory.path}/disk-public-access-${_key(room)}.json');

class _HistoryOnlyStore extends RoomStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void _contractTests(String name, RoomStore Function() create) {
  group(name, () {
    late RoomStore store;
    setUp(() => store = create());

    test('generates a stable random client ID', () async {
      final ids = await Future.wait(
        List.generate(10, (_) => store.loadClientId()),
      );
      expect(ids.toSet(), hasLength(1));
      expect(ids.first, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('missing rooms are normal, membership tracks the last room', () async {
      expect(await store.loadLastRoom(), isNull);
      expect(await store.hasMembership('first'), isFalse);
      expect(await store.loadHistory('first'), isEmpty);
      await store.saveMembership('first');
      expect(await store.hasMembership('first'), isTrue);
      expect(await store.loadLastRoom(), 'first');
      await store.saveMembership('second');
      expect(await store.hasMembership('first'), isTrue);
      expect(await store.hasMembership('second'), isTrue);
      expect(await store.loadLastRoom(), 'second');
      await store.flush();
      // Reading/exiting a room never clears membership or the restore target.
      await store.loadHistory('second');
      expect(await store.loadLastRoom(), 'second');
    });

    test(
      'deduplicates batches and retries, independent of map key order',
      () async {
        final record = _operation('edit-1');
        await store.appendHistory('room', [record, record]);
        await store.appendHistory('room', [
          {
            'nested': {
              'tags': ['original'],
            },
            'clock': 1,
            'text': 'hello',
            'id': 'edit-1',
          },
          _operation('edit-2'),
        ]);
        expect(await store.loadHistory('room'), [record, _operation('edit-2')]);
      },
    );

    test(
      'rejects conflicting IDs before persisting any of that batch',
      () async {
        await store.appendHistory('room', [_operation('edit-1')]);
        await expectLater(
          store.appendHistory('room', [
            _operation('edit-2'),
            _operation('edit-1', 'changed'),
          ]),
          throwsFormatException,
        );
        expect(await store.loadHistory('room'), [_operation('edit-1')]);
        await expectLater(
          store.appendHistory('room', [
            _operation('edit-3'),
            _operation('edit-3', 'conflict inside batch'),
          ]),
          throwsFormatException,
        );
        expect(await store.loadHistory('room'), [_operation('edit-1')]);
      },
    );

    test(
      'snapshots input immediately and returns detached nested JSON',
      () async {
        final input = _operation('snapshot');
        final saving = store.appendHistory('room', [input]);
        input['id'] = 'mutated';
        ((input['nested'] as Map)['tags'] as List).add('mutated');
        await saving;
        final loaded = await store.loadHistory('room');
        expect(loaded, [_operation('snapshot')]);
        loaded.first['id'] = 'also-mutated';
        ((loaded.first['nested'] as Map)['tags'] as List).clear();
        expect(await store.loadHistory('room'), [_operation('snapshot')]);
      },
    );

    test('room and operation IDs cannot collide or escape paths', () async {
      const first = 'room/../雪?&=a';
      const second = 'room/../雪?&=ab';
      await store.saveMembership(first);
      await store.appendHistory(first, [_operation('../edit/雪?&=')]);
      await store.appendHistory(second, [_operation('../edit/雪?&=')]);
      expect(await store.loadHistory(first), [_operation('../edit/雪?&=')]);
      expect(await store.loadHistory(second), [_operation('../edit/雪?&=')]);
      expect(await store.hasMembership(second), isFalse);
      expect(await store.loadLastRoom(), first);
    });

    test(
      'rejects malformed IDs and non-JSON values without losing history',
      () async {
        await store.appendHistory('room', [_operation('valid')]);
        for (final record in <Map<String, dynamic>>[
          {'text': 'missing ID'},
          {'id': ''},
          {'id': 123},
          {'id': 'bad-number', 'value': double.nan},
          {'id': 'bad-object', 'value': Object()},
          {
            'id': 'bad-keys',
            'value': <Object, Object>{123: 'not a string'},
          },
        ]) {
          await expectLater(
            store.appendHistory('room', [record]),
            throwsFormatException,
          );
        }
        expect(await store.loadHistory('room'), [_operation('valid')]);
        await expectLater(store.saveMembership('  '), throwsArgumentError);
        await expectLater(store.hasMembership(''), throwsArgumentError);
        await expectLater(store.loadHistory(''), throwsArgumentError);
        await expectLater(store.appendHistory('', []), throwsArgumentError);
        await store.appendHistory('room', []);
        await store.flush();
      },
    );

    test(
      'authoring serializes same-author drafts and returns full history',
      () async {
        final legacy = _draft('legacy', clock: 20).toJson();
        await store.appendHistory('room', [legacy]);
        final firstDraft = _draft('new-first', clock: 10).toJson();
        final first = store.appendAuthoredHistory('room', [firstDraft]);
        firstDraft['text'] = 'mutated after invocation';
        final second = store.appendAuthoredHistory('room', [
          _draft('new-first', clock: 10).toJson(),
          _draft('new-second', clock: 1).toJson(),
        ]);
        expect((await first).map((raw) => raw['id']), ['legacy', 'new-first']);
        final result = await second;
        final edits = validateAuthorHistory(decodeRoomHistory(result));
        expect(edits.map((edit) => edit.id), [
          'legacy',
          'new-first',
          'new-second',
        ]);
        expect(edits[1].authorSequence, 1);
        expect(edits[1].authorBase, ['legacy']);
        expect(edits[2].authorSequence, 2);
        expect(edits[2].authorPrevious, 'new-first');
        expect(edits[1].text, 'new-first');
        expect(
          edits[2].clock,
          1,
          reason: 'Proof allocation does not change stamps',
        );
        expect(await store.loadHistory('room'), result);
        result.last['text'] = 'mutated returned snapshot';
        expect((await store.loadHistory('room')).last['text'], 'new-second');
      },
    );

    test('authored retries preserve the exact stored JSON and ID', () async {
      final draft = _draft('retry');
      final canonical = sequenceAuthoredEdit(draft, []).toJson()
        ..['kind'] = 'text';
      await store.appendHistory('room', [canonical]);
      expect(await store.appendAuthoredHistory('room', [draft.toJson()]), [
        canonical,
      ]);
      expect(await store.loadHistory('room'), [canonical]);
      await expectLater(
        store.appendAuthoredHistory('room', [
          _draft('must-not-persist').toJson(),
          {...draft.toJson(), 'text': 'changed core'},
        ]),
        throwsFormatException,
      );
      expect(await store.loadHistory('room'), [canonical]);
    });

    test(
      'authored batches require strict unproven edits from one author',
      () async {
        for (final drafts in [
          [_operation('not-a-room-edit')],
          [_draft('a').toJson(), _draft('b', author: 'other').toJson()],
          [_prefix().first.toJson()],
          [
            _draft('duplicate').toJson(),
            {..._draft('duplicate').toJson(), 'text': 'changed'},
          ],
        ]) {
          await expectLater(
            store.appendAuthoredHistory('room', drafts),
            throwsFormatException,
          );
          expect(await store.loadHistory('room'), isEmpty);
        }
        expect(await store.appendAuthoredHistory('room', []), isEmpty);
        await expectLater(
          store.appendAuthoredHistory('', []),
          throwsArgumentError,
        );
      },
    );

    test(
      'remote batches validate full author closure before any write',
      () async {
        final prefix = _prefix();
        await store.appendHistory('room', [prefix.first.toJson()]);
        for (final invalid in [
          [prefix.last.toJson()],
          [
            _draft('unrelated', author: 'other').toJson(),
            sequenceAuthoredEdit(_draft('fork'), []).toJson(),
          ],
          [
            prefix[1].toJson(),
            {...prefix.last.toJson(), 'authorPrevious': 'first'},
          ],
        ]) {
          await expectLater(
            store.appendHistory('room', invalid),
            throwsFormatException,
          );
          expect(await store.loadHistory('room'), [prefix.first.toJson()]);
        }
        await store.appendHistory('room', [
          prefix.last.toJson(),
          prefix[1].toJson(),
        ]);
        expect(
          await store.loadHistory('room'),
          prefix.map((edit) => edit.toJson()),
        );
      },
    );

    test(
      'complete remote batches persist predecessors before low-clock successors',
      () async {
        final prefix = _prefix();
        await store.appendHistory(
          'room',
          prefix.reversed.map((edit) => edit.toJson()).toList(),
        );
        expect(
          await store.loadHistory('room'),
          prefix.map((edit) => edit.toJson()),
        );
      },
    );

    test(
      'Disk credentials are separate detached room-local snapshots',
      () async {
        expect(await store.loadDiskCredentials(_credentialRoom), isNull);
        final input = _credentials();
        final saving = store.saveDiskCredentials(_credentialRoom, input);
        input['bindingId'] = 'mutated';
        input['token'] = 'mutated-token';
        await saving;
        expect(
          await store.loadDiskCredentials(_credentialRoom),
          _credentials(),
        );
        final loaded = (await store.loadDiskCredentials(_credentialRoom))!;
        loaded['token'] = 'mutated-return-value';
        expect(
          await store.loadDiskCredentials(_credentialRoom),
          _credentials(),
        );
        expect(await store.loadDiskCredentials(_otherCredentialRoom), isNull);
        expect(await store.loadHistory(_credentialRoom), isEmpty);
        expect(await store.hasMembership(_credentialRoom), isFalse);
        expect(await store.loadLastRoom(), isNull);
        // Staging credentials must not require a connect already in history.
        final connect = RoomDocument().createEdit(
          'actor',
          '{"action":"connect"}',
          kind: RoomEditKind.diskConnection,
          id: 'binding',
        );
        await store.appendAuthoredHistory(_credentialRoom, [connect.toJson()]);
        final history = await store.loadHistory(_credentialRoom);
        expect(history.single['id'], 'binding');
        expect(jsonEncode(history), isNot(contains('local-only-token')));
        expect(jsonEncode(history), isNot(contains('token')));
        expect(
          await store.loadDiskCredentials(_credentialRoom),
          _credentials(),
        );
      },
    );

    test(
      'staged binding credentials survive competing latest values',
      () async {
        final first = _credentials(bindingId: 'first', token: 'first-secret');
        final second = _credentials(
          bindingId: 'second',
          token: 'second-secret',
        );
        await Future.wait([
          store.saveDiskCredentials(_credentialRoom, first),
          store.saveDiskCredentials(
            _credentialRoom,
            second,
            bindingId: 'second',
          ),
        ]);
        expect(await store.loadDiskCredentials(_credentialRoom), second);
        expect(
          await store.loadDiskCredentials(_credentialRoom, bindingId: 'first'),
          first,
        );
        expect(
          await store.loadDiskCredentials(_credentialRoom, bindingId: 'second'),
          second,
        );
        expect(
          await store.loadDiskCredentials(
            _credentialRoom,
            bindingId: 'missing',
          ),
          isNull,
        );
        final loaded = (await store.loadDiskCredentials(
          _credentialRoom,
          bindingId: 'first',
        ))!;
        loaded['token'] = 'mutated';
        expect(
          await store.loadDiskCredentials(_credentialRoom, bindingId: 'first'),
          first,
        );
        await store.saveDiskCredentials(
          _credentialRoom,
          null,
          bindingId: 'first',
        );
        expect(
          await store.loadDiskCredentials(_credentialRoom, bindingId: 'first'),
          isNull,
        );
        expect(await store.loadDiskCredentials(_credentialRoom), second);
        await store.saveDiskCredentials(
          _credentialRoom,
          null,
          bindingId: 'missing',
        );
        expect(await store.loadDiskCredentials(_credentialRoom), second);
        await store.saveDiskCredentials(_credentialRoom, first);
        await store.saveDiskCredentials(
          _credentialRoom,
          null,
          bindingId: 'first',
        );
        expect(await store.loadDiskCredentials(_credentialRoom), isNull);
        expect(
          await store.loadDiskCredentials(_credentialRoom, bindingId: 'second'),
          second,
        );
        await store.saveDiskCredentials(_credentialRoom, null);
        expect(
          await store.loadDiskCredentials(_credentialRoom, bindingId: 'second'),
          isNull,
        );
        expect(await store.loadHistory(_credentialRoom), isEmpty);
      },
    );

    test(
      'credential binding selectors are validated before changing data',
      () async {
        final value = _credentials();
        await store.saveDiskCredentials(_credentialRoom, value);
        for (final bindingId in ['', 'x' * 129]) {
          await expectLater(
            store.loadDiskCredentials(_credentialRoom, bindingId: bindingId),
            throwsArgumentError,
          );
          await expectLater(
            store.saveDiskCredentials(
              _credentialRoom,
              value,
              bindingId: bindingId,
            ),
            throwsArgumentError,
          );
          await expectLater(
            store.saveDiskCredentials(
              _credentialRoom,
              null,
              bindingId: bindingId,
            ),
            throwsArgumentError,
          );
        }
        await expectLater(
          store.saveDiskCredentials(
            _credentialRoom,
            value,
            bindingId: 'different',
          ),
          throwsFormatException,
        );
        expect(await store.loadDiskCredentials(_credentialRoom), value);
        expect(
          await store.loadDiskCredentials(
            _credentialRoom,
            bindingId: 'binding',
          ),
          value,
        );
        expect(
          await store.loadDiskCredentials(
            _credentialRoom,
            bindingId: 'different',
          ),
          isNull,
        );
      },
    );

    test(
      'replacing or deleting credentials never deletes room history',
      () async {
        final tree = RoomEdit(
          id: 'tree',
          author: 'actor',
          clock: 1,
          createdAt: 1,
          text:
              '{"type":"createPerson","personId":"person",'
              '"name":"Anna","sex":"unknown"}',
          kind: RoomEditKind.tree,
        );
        final history = [tree.toJson()];
        await store.saveMembership(_credentialRoom);
        await store.appendHistory(_credentialRoom, history);
        await store.saveDiskCredentials(_credentialRoom, _credentials());
        await store.saveDiskCredentials(_otherCredentialRoom, _credentials());
        final replacement = _credentials(
          bindingId: 'next',
          token: 'next-token',
        );
        final writing = store.saveDiskCredentials(_credentialRoom, replacement);
        final reading = store.loadDiskCredentials(_credentialRoom);
        await writing;
        expect(await reading, replacement);
        await store.saveDiskCredentials(_credentialRoom, null);
        await store.saveDiskCredentials(_credentialRoom, null);
        expect(await store.loadDiskCredentials(_credentialRoom), isNull);
        expect(
          await store.loadDiskCredentials(_otherCredentialRoom),
          _credentials(),
        );
        expect(await store.loadHistory(_credentialRoom), history);
        expect(await store.hasMembership(_credentialRoom), isTrue);
        expect(await store.loadLastRoom(), _credentialRoom);
      },
    );

    test(
      'credential schema and room IDs are strict without leaking tokens',
      () async {
        final valid = _credentials();
        await store.saveDiskCredentials(_credentialRoom, valid);
        final invalid = <Map<String, dynamic>>[
          {},
          {...valid}..remove('v'),
          {...valid}..remove('bindingId'),
          {...valid}..remove('token'),
          {...valid, 'extra': 'secret-diagnostic-marker'},
          for (final v in <Object?>[null, 0, 2, 1.0, '1', true])
            {...valid, 'v': v},
          for (final id in <Object?>[null, '', 'x' * 129, 1, true, [], {}])
            {...valid, 'bindingId': id},
          for (final token in <Object?>[
            null,
            '',
            ' ',
            ' secret-diagnostic-marker',
            'secret-diagnostic-marker ',
            'secret-diagnostic-marker\n',
            'secret-diagnostic-marker\u007f',
            'secret-diagnostic-marker\u0085',
            'секрет',
            'x' * 4097,
            1,
            true,
            [],
            {},
            Object(),
          ])
            {...valid, 'token': token},
        ];
        for (var index = 0; index < invalid.length; index++) {
          await expectLater(
            store.saveDiskCredentials(_credentialRoom, invalid[index]),
            throwsA(
              isA<FormatException>().having(
                (error) => error.toString(),
                'redacted diagnostic',
                isNot(contains('secret-diagnostic-marker')),
              ),
            ),
            reason: 'case $index',
          );
        }
        for (final room in ['', ' ', 'room', '../room', 'A' * 32, 'a' * 33]) {
          await expectLater(
            store.loadDiskCredentials(room),
            throwsArgumentError,
          );
          await expectLater(
            store.saveDiskCredentials(room, valid),
            throwsArgumentError,
          );
          await expectLater(
            store.saveDiskCredentials(room, null),
            throwsArgumentError,
          );
        }
        expect(await store.loadDiskCredentials(_credentialRoom), valid);
        await store.saveDiskCredentials(
          _credentialRoom,
          _credentials(bindingId: 'x' * 128),
        );
        expect(
          (await store.loadDiskCredentials(_credentialRoom))!['bindingId'],
          'x' * 128,
        );
        final maximumToken = _credentials(token: '!' * 4096);
        await store.saveDiskCredentials(_credentialRoom, maximumToken);
        expect(await store.loadDiskCredentials(_credentialRoom), maximumToken);
      },
    );

    test(
      'binding archives support maximum Unicode IDs without path aliases',
      () async {
        final first = _credentials(bindingId: '雪' * 128, token: 'first-secret');
        final second = _credentials(
          bindingId: '../別/?=&',
          token: 'second-secret',
        );
        await store.saveDiskCredentials(_credentialRoom, first);
        await store.saveDiskCredentials(_credentialRoom, second);
        expect(
          await store.loadDiskCredentials(
            _credentialRoom,
            bindingId: first['bindingId'] as String,
          ),
          first,
        );
        expect(
          await store.loadDiskCredentials(
            _credentialRoom,
            bindingId: second['bindingId'] as String,
          ),
          second,
        );
        await store.saveDiskCredentials(
          _credentialRoom,
          null,
          bindingId: first['bindingId'] as String,
        );
        expect(await store.loadDiskCredentials(_credentialRoom), second);
        expect(
          await store.loadDiskCredentials(
            _credentialRoom,
            bindingId: first['bindingId'] as String,
          ),
          isNull,
        );
      },
    );

    test(
      'Disk public access is a detached room-local read-only snapshot',
      () async {
        expect(await store.loadDiskPublicAccess(_credentialRoom), isNull);
        final input = _publicAccess();
        final saving = store.saveDiskPublicAccess(_credentialRoom, input);
        input['bindingId'] = 'mutated';
        input['publicUrl'] = 'https://yadi.sk/d/mutated';
        input['token'] = 'must-not-persist';
        await saving;
        expect(
          await store.loadDiskPublicAccess(_credentialRoom),
          _publicAccess(),
        );
        final loaded = (await store.loadDiskPublicAccess(_credentialRoom))!;
        loaded['publicUrl'] = 'https://yadi.sk/d/mutated-return';
        loaded['token'] = 'must-not-persist';
        expect(
          await store.loadDiskPublicAccess(_credentialRoom),
          _publicAccess(),
        );
        expect(await store.loadDiskPublicAccess(_otherCredentialRoom), isNull);
        expect(await store.loadDiskCredentials(_credentialRoom), isNull);
        expect(
          await store.loadDiskCredentials(
            _credentialRoom,
            bindingId: 'binding',
          ),
          isNull,
        );
        expect(await store.loadHistory(_credentialRoom), isEmpty);
        expect(await store.hasMembership(_credentialRoom), isFalse);
        expect(await store.loadLastRoom(), isNull);
        await store.appendHistory(_credentialRoom, [_operation('tree')]);
        final history = await store.loadHistory(_credentialRoom);
        expect(history, [_operation('tree')]);
        expect(jsonEncode(history), isNot(contains(_publicUrl)));
        expect(jsonEncode(history), isNot(contains('publicUrl')));
        expect(jsonEncode(history), isNot(contains('token')));
      },
    );

    test(
      'replacing or removing public access preserves history and credentials',
      () async {
        final history = [_operation('tree')];
        await store.saveMembership(_credentialRoom);
        await store.appendHistory(_credentialRoom, history);
        await store.saveDiskCredentials(_credentialRoom, _credentials());
        final staged = _credentials(bindingId: 'staged', token: 'staged-token');
        await store.saveDiskCredentials(_credentialRoom, staged);
        await store.saveDiskPublicAccess(_credentialRoom, _publicAccess());
        await store.saveDiskPublicAccess(_otherCredentialRoom, _publicAccess());
        final replacement = _publicAccess(
          bindingId: 'next',
          publicUrl: 'https://yadi.sk/d/replacement',
        );
        final writing = store.saveDiskPublicAccess(
          _credentialRoom,
          replacement,
        );
        final reading = store.loadDiskPublicAccess(_credentialRoom);
        await writing;
        expect(await reading, replacement);
        await store.saveDiskPublicAccess(_credentialRoom, null);
        await store.saveDiskPublicAccess(_credentialRoom, null);
        expect(await store.loadDiskPublicAccess(_credentialRoom), isNull);
        expect(
          await store.loadDiskPublicAccess(_otherCredentialRoom),
          _publicAccess(),
        );
        expect(await store.loadDiskCredentials(_credentialRoom), staged);
        expect(
          await store.loadDiskCredentials(
            _credentialRoom,
            bindingId: 'binding',
          ),
          _credentials(),
        );
        expect(await store.loadHistory(_credentialRoom), history);
        expect(await store.hasMembership(_credentialRoom), isTrue);
        expect(await store.loadLastRoom(), _credentialRoom);
        await store.saveDiskPublicAccess(_credentialRoom, replacement);
        await store.saveDiskCredentials(_credentialRoom, null);
        expect(await store.loadDiskPublicAccess(_credentialRoom), replacement);
      },
    );

    test(
      'public-access schema and room IDs are strict without echoing URLs',
      () async {
        final valid = _publicAccess();
        await store.saveDiskPublicAccess(_credentialRoom, valid);
        final invalid = <Map<String, dynamic>>[
          {},
          {...valid}..remove('v'),
          {...valid}..remove('bindingId'),
          {...valid}..remove('publicUrl'),
          {...valid, 'extra': _publicUrl},
          {...valid, 'token': 'must-not-persist'},
          _credentials(),
          for (final v in <Object?>[null, 0, 2, 1.0, '1', true])
            {...valid, 'v': v},
          for (final id in <Object?>[null, '', 'x' * 129, 1, true, [], {}])
            {...valid, 'bindingId': id},
          for (final url in <Object?>[
            null,
            '',
            ' $_publicUrl',
            '$_publicUrl ',
            '$_publicUrl\n',
            'http://disk.yandex.ru/d/public-access-marker',
            'https://example.com/d/public-access-marker',
            'https://disk.yandex.ru.example.com/d/public-access-marker',
            'https://user@disk.yandex.ru/d/public-access-marker',
            'https://disk.yandex.ru:444/d/public-access-marker',
            '$_publicUrl#fragment',
            'https://disk.yandex.ru/d/',
            'https://disk.yandex.ru/d/${'x' * (32 * 1024)}',
            1,
            true,
            [],
            {},
            Object(),
          ])
            {...valid, 'publicUrl': url},
        ];
        for (var index = 0; index < invalid.length; index++) {
          await expectLater(
            store.saveDiskPublicAccess(_credentialRoom, invalid[index]),
            throwsA(
              isA<FormatException>().having(
                (error) => error.toString(),
                'redacted diagnostic',
                isNot(contains('public-access-marker')),
              ),
            ),
            reason: 'case $index',
          );
        }
        for (final room in [
          '',
          ' ',
          'room',
          '../room',
          'A' * 32,
          'a' * 33,
          _publicUrl,
        ]) {
          final redactedArgumentError = throwsA(
            isA<ArgumentError>().having(
              (error) => error.toString(),
              'redacted diagnostic',
              isNot(contains('public-access-marker')),
            ),
          );
          await expectLater(
            store.loadDiskPublicAccess(room),
            redactedArgumentError,
          );
          await expectLater(
            store.saveDiskPublicAccess(room, valid),
            redactedArgumentError,
          );
          await expectLater(
            store.saveDiskPublicAccess(room, null),
            redactedArgumentError,
          );
        }
        expect(await store.loadDiskPublicAccess(_credentialRoom), valid);
        final unicode = _publicAccess(bindingId: '雪' * 128);
        await store.saveDiskPublicAccess(_credentialRoom, unicode);
        expect(await store.loadDiskPublicAccess(_credentialRoom), unicode);
        expect(await store.loadDiskCredentials(_credentialRoom), isNull);
      },
    );

    test('native/memory history watching is an empty stream', () async {
      await store.appendHistory('room', [_operation('first')]);
      expect(await store.watchHistory('room').toList(), isEmpty);
    });

    test('reads observe all writes already queued', () async {
      final first = store.appendHistory('room', [_operation('first')]);
      final second = store.appendHistory('room', [_operation('second')]);
      final reading = store.loadHistory('room');
      await Future.wait([first, second]);
      expect(await reading, [_operation('first'), _operation('second')]);
    });
  });
}

void main() {
  _contractTests('MemoryRoomStore', MemoryRoomStore.new);

  test('base RoomStore refuses silently ephemeral Disk credentials', () async {
    final store = _HistoryOnlyStore();
    await expectLater(
      store.loadDiskCredentials(_credentialRoom),
      throwsUnsupportedError,
    );
    await expectLater(
      store.saveDiskCredentials(_credentialRoom, _credentials()),
      throwsUnsupportedError,
    );
    await expectLater(
      store.saveDiskCredentials(_credentialRoom, null),
      throwsUnsupportedError,
    );
  });

  test('base RoomStore refuses ephemeral Disk public access', () async {
    final store = _HistoryOnlyStore();
    await expectLater(
      store.loadDiskPublicAccess(_credentialRoom),
      throwsUnsupportedError,
    );
    await expectLater(
      store.saveDiskPublicAccess(_credentialRoom, _publicAccess()),
      throwsUnsupportedError,
    );
    await expectLater(
      store.saveDiskPublicAccess(_credentialRoom, null),
      throwsUnsupportedError,
    );
  });

  test(
    'default authored retries reuse a durable prefix after injected failure',
    () async {
      final store = _FailingMemoryStore()..failAt = 2;
      final drafts = [
        for (final id in ['a', 'b', 'c']) _draft(id).toJson(),
      ];
      await expectLater(
        store.appendAuthoredHistory('room', drafts),
        throwsStateError,
      );
      final prefix = await store.loadHistory('room');
      expect(prefix, hasLength(1));
      expect(prefix.single['authorSequence'], 1);
      store.failAt = null;
      final result = await store.appendAuthoredHistory('room', drafts);
      expect(result.first, prefix.single);
      expect(result.map((raw) => raw['authorSequence']), [1, 2, 3]);
      expect(store.calls, 4, reason: 'Retry writes only the two absent IDs');
      validateAuthorHistory(decodeRoomHistory(result));
    },
  );

  test(
    'default authored retry also handles an unacknowledged durable write',
    () async {
      final store = _FailingMemoryStore()
        ..failAt = 1
        ..failAfterWrite = true;
      final draft = _draft('durable-without-ack').toJson();
      await expectLater(
        store.appendAuthoredHistory('room', [draft]),
        throwsStateError,
      );
      final persisted = await store.loadHistory('room');
      store.failAt = null;
      expect(await store.appendAuthoredHistory('room', [draft]), persisted);
      expect(
        store.calls,
        1,
        reason: 'Already persisted canonical ID is not rewritten',
      );
    },
  );

  test(
    'default authored transaction shares the memory read/remote writer lock',
    () async {
      final release = Completer<void>();
      final store = _FailingMemoryStore()..pause = release;
      final authored = store.appendAuthoredHistory('room', [
        _draft('local').toJson(),
      ]);
      await store.entered.future;
      var readCompleted = false;
      final reading = store.loadHistory('room').then((value) {
        readCompleted = true;
        return value;
      });
      final remote = sequenceAuthoredEdit(
        _draft('remote', author: 'other'),
        [],
      );
      final writing = store.appendHistory('room', [remote.toJson()]);
      await Future<void>.delayed(Duration.zero);
      expect(readCompleted, isFalse);
      release.complete();
      expect((await authored).map((raw) => raw['id']), ['local']);
      expect((await reading).map((raw) => raw['id']), ['local']);
      await writing;
      expect(await store.loadHistory('room'), hasLength(2));
    },
  );

  test(
    'author-proof allocation cannot commit an oversized canonical history',
    () async {
      final store = MemoryRoomStore();
      final legacy = {
        ..._draft('large-legacy').toJson(),
        'text': List.filled(8 * 1024 * 1024, 'x').join(),
      };
      // Generic legacy persistence keeps its original contract and no size limit.
      await store.appendHistory('room', [legacy]);
      await expectLater(
        store.appendAuthoredHistory('room', [
          _draft('small-new-edit').toJson(),
        ]),
        throwsFormatException,
      );
      expect(await store.loadHistory('room'), [legacy]);
    },
  );

  group('FileRoomStore', () {
    late Directory directory;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('mytree-room-store-');
    });
    tearDown(() async {
      await directory.delete(recursive: true);
    });

    _contractTests('contract', () => FileRoomStore.withDirectory(directory));

    test(
      'factory selects native persistence without invoking a plugin yet',
      () {
        expect(createRoomStore(), isA<FileRoomStore>());
      },
    );

    test(
      'persists client, memberships, last room, and history across reopening',
      () async {
        final first = FileRoomStore.withDirectory(directory);
        final client = await first.loadClientId();
        await first.saveMembership('first');
        await first.saveMembership('last');
        await first.appendHistory('last', [_operation('durable')]);
        await first.flush();
        final reopened = FileRoomStore.withDirectory(directory);
        expect(await reopened.loadClientId(), client);
        expect(await reopened.hasMembership('first'), isTrue);
        expect(await reopened.hasMembership('last'), isTrue);
        expect(await reopened.loadLastRoom(), 'last');
        expect(await reopened.loadHistory('last'), [_operation('durable')]);
      },
    );

    test(
      'credentials survive reopen, replace atomically, delete independently',
      () async {
        final store = FileRoomStore.withDirectory(directory);
        await store.saveMembership(_credentialRoom);
        await store.appendHistory(_credentialRoom, [_operation('tree')]);
        final history = await _historyFile(
          directory,
          _credentialRoom,
        ).readAsString();
        final saving = store.saveDiskCredentials(
          _credentialRoom,
          _credentials(),
        );
        await store.flush();
        await saving;
        final file = _credentialsFile(directory);
        final original = await file.readAsString();
        expect(jsonDecode(original), _credentials());
        expect(
          await FileRoomStore.withDirectory(
            directory,
          ).loadDiskCredentials(_credentialRoom),
          _credentials(),
        );
        final staleTemporary = File('${file.path}.tmp');
        await staleTemporary.writeAsString(
          'interrupted secret-diagnostic-marker',
        );
        expect(
          await store.loadDiskCredentials(_credentialRoom),
          _credentials(),
        );
        final replacement = _credentials(
          bindingId: 'next',
          token: 'next-token',
        );
        await store.saveDiskCredentials(_credentialRoom, replacement);
        expect(await staleTemporary.exists(), isFalse);
        expect(
          await FileRoomStore.withDirectory(
            directory,
          ).loadDiskCredentials(_credentialRoom),
          replacement,
        );
        final reopened = FileRoomStore.withDirectory(directory);
        await reopened.saveDiskCredentials(_credentialRoom, null);
        expect(await file.exists(), isFalse);
        expect(
          await FileRoomStore.withDirectory(
            directory,
          ).loadDiskCredentials(_credentialRoom),
          isNull,
        );
        expect(
          await _historyFile(directory, _credentialRoom).readAsString(),
          history,
        );
        expect(await reopened.hasMembership(_credentialRoom), isTrue);
        expect(await reopened.loadLastRoom(), _credentialRoom);
      },
    );

    test(
      'public access survives reopen and atomic replacement without an archive',
      () async {
        final store = FileRoomStore.withDirectory(directory);
        await store.saveMembership(_credentialRoom);
        await store.appendHistory(_credentialRoom, [_operation('tree')]);
        await store.saveDiskCredentials(_credentialRoom, _credentials());
        final historyFile = _historyFile(directory, _credentialRoom);
        final historyBytes = await historyFile.readAsBytes();
        final credentialBytes = await _credentialsFile(directory).readAsBytes();
        final archiveBytes = await _credentialsArchiveFile(
          directory,
          'binding',
        ).readAsBytes();
        final saving = store.saveDiskPublicAccess(
          _credentialRoom,
          _publicAccess(),
        );
        await store.flush();
        await saving;
        final file = _publicAccessFile(directory);
        expect(jsonDecode(await file.readAsString()), _publicAccess());
        final reopened = FileRoomStore.withDirectory(directory);
        expect(
          await reopened.loadDiskPublicAccess(_credentialRoom),
          _publicAccess(),
        );
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString('interrupted $_publicUrl');
        expect(
          await reopened.loadDiskPublicAccess(_credentialRoom),
          _publicAccess(),
        );
        final replacement = _publicAccess(
          bindingId: 'next',
          publicUrl: 'https://yadi.sk/d/replacement',
        );
        await reopened.saveDiskPublicAccess(_credentialRoom, replacement);
        expect(await temporary.exists(), isFalse);
        expect(
          await FileRoomStore.withDirectory(
            directory,
          ).loadDiskPublicAccess(_credentialRoom),
          replacement,
        );
        final publicFiles = await directory
            .list()
            .where(
              (entity) => entity.uri.pathSegments.last.startsWith(
                'disk-public-access-',
              ),
            )
            .toList();
        expect(publicFiles.map((entity) => entity.uri.pathSegments.last), [
          file.uri.pathSegments.last,
        ]);
        await temporary.writeAsString('interrupted $_publicUrl');
        await reopened.saveDiskPublicAccess(_credentialRoom, null);
        expect(await temporary.exists(), isFalse);
        expect(await file.exists(), isFalse);
        expect(
          await FileRoomStore.withDirectory(
            directory,
          ).loadDiskPublicAccess(_credentialRoom),
          isNull,
        );
        expect(await historyFile.readAsBytes(), historyBytes);
        expect(
          await _credentialsFile(directory).readAsBytes(),
          credentialBytes,
        );
        expect(
          await _credentialsArchiveFile(directory, 'binding').readAsBytes(),
          archiveBytes,
        );
        expect(await reopened.hasMembership(_credentialRoom), isTrue);
        expect(await reopened.loadLastRoom(), _credentialRoom);
      },
    );

    test(
      'malformed public-access files throw without echoing URLs or changing data',
      () async {
        final store = FileRoomStore.withDirectory(directory);
        await store.appendHistory(_credentialRoom, [_operation('intact')]);
        await store.saveDiskCredentials(_credentialRoom, _credentials());
        final file = _publicAccessFile(directory);
        final redactedError = throwsA(
          isA<FormatException>().having(
            (error) => error.toString(),
            'redacted diagnostic',
            isNot(contains('public-access-marker')),
          ),
        );
        for (final encoded in [
          '$_publicUrl not JSON',
          'null',
          '[]',
          '"$_publicUrl"',
          '{}',
          '{"v":1,"bindingId":"binding","publicUrl":null}',
          '{"v":1,"bindingId":"binding","publicUrl":"$_publicUrl","token":"hidden"}',
          '{"v":1,"bindingId":"binding","publicUrl":"$_publicUrl","publicUrl":"$_publicUrl"}',
          '{"v":2,"v":1,"bindingId":"binding","publicUrl":"$_publicUrl"}',
        ]) {
          await file.writeAsString(encoded);
          await expectLater(
            store.loadDiskPublicAccess(_credentialRoom),
            redactedError,
          );
          await expectLater(
            store.saveDiskPublicAccess(_credentialRoom, _publicAccess()),
            redactedError,
          );
          expect(await file.readAsString(), encoded);
        }
        await file.writeAsBytes([0xff, ...utf8.encode(_publicUrl)]);
        await expectLater(
          store.loadDiskPublicAccess(_credentialRoom),
          redactedError,
        );
        await store.saveDiskPublicAccess(_credentialRoom, null);
        expect(await store.loadDiskPublicAccess(_credentialRoom), isNull);
        expect(
          await store.loadDiskCredentials(_credentialRoom),
          _credentials(),
        );
        expect(await store.loadHistory(_credentialRoom), [
          _operation('intact'),
        ]);
      },
    );

    test(
      'failed atomic public-access writes preserve the pointer and recover',
      () async {
        final store = FileRoomStore.withDirectory(directory);
        await store.saveDiskPublicAccess(_credentialRoom, _publicAccess());
        final file = _publicAccessFile(directory);
        final original = await file.readAsString();
        final blocked = Directory('${file.path}.tmp');
        await blocked.create();
        final replacement = _publicAccess(
          bindingId: 'next',
          publicUrl: 'https://yadi.sk/d/replacement',
        );
        await expectLater(
          store.saveDiskPublicAccess(_credentialRoom, replacement),
          throwsA(isA<FileSystemException>()),
        );
        expect(await file.readAsString(), original);
        expect(
          await store.loadDiskPublicAccess(_credentialRoom),
          _publicAccess(),
        );
        await blocked.delete();
        await store.saveDiskPublicAccess(_credentialRoom, replacement);
        expect(await store.loadDiskPublicAccess(_credentialRoom), replacement);
        await file.delete();
        final invalidFile = Directory(file.path);
        await invalidFile.create();
        await expectLater(
          store.loadDiskPublicAccess(_credentialRoom),
          throwsA(isA<FileSystemException>()),
        );
        await expectLater(
          store.saveDiskPublicAccess(_credentialRoom, null),
          throwsA(isA<FileSystemException>()),
        );
        await invalidFile.delete();
        await store.saveDiskPublicAccess(_credentialRoom, replacement);
        expect(await store.loadDiskPublicAccess(_credentialRoom), replacement);
      },
    );

    test(
      'native archives retain both bindings and support legacy latest-only values',
      () async {
        final first = _credentials(bindingId: 'first', token: 'first-secret');
        final second = _credentials(
          bindingId: 'second',
          token: 'second-secret',
        );
        final file = _credentialsFile(directory);
        await file.writeAsString(jsonEncode(first));
        final store = FileRoomStore.withDirectory(directory);
        expect(
          await store.loadDiskCredentials(_credentialRoom, bindingId: 'first'),
          first,
        );
        expect(
          await store.loadDiskCredentials(_credentialRoom, bindingId: 'second'),
          isNull,
        );
        await store.saveDiskCredentials(_credentialRoom, second);
        final reopened = FileRoomStore.withDirectory(directory);
        expect(await reopened.loadDiskCredentials(_credentialRoom), second);
        expect(
          await reopened.loadDiskCredentials(
            _credentialRoom,
            bindingId: 'first',
          ),
          first,
        );
        expect(
          await reopened.loadDiskCredentials(
            _credentialRoom,
            bindingId: 'second',
          ),
          second,
        );
        expect(
          jsonDecode(
            await _credentialsArchiveFile(directory, 'first').readAsString(),
          ),
          first,
        );
        final wrongArchive = _credentialsArchiveFile(directory, 'first');
        await wrongArchive.writeAsString(
          jsonEncode(_credentials(bindingId: 'wrong')),
        );
        await expectLater(
          reopened.loadDiskCredentials(_credentialRoom, bindingId: 'first'),
          throwsFormatException,
        );
        // Scoped explicit removal can discard a malformed archive, not a newer pointer.
        await reopened.saveDiskCredentials(
          _credentialRoom,
          null,
          bindingId: 'first',
        );
        expect(await wrongArchive.exists(), isFalse);
        expect(await reopened.loadDiskCredentials(_credentialRoom), second);
        await reopened.saveDiskCredentials(_credentialRoom, null);
        expect(
          await _credentialsArchiveFile(directory, 'second').exists(),
          isFalse,
        );
      },
    );

    test(
      'failed latest-pointer writes retain the staged binding archive',
      () async {
        final store = FileRoomStore.withDirectory(directory);
        final first = _credentials(bindingId: 'first', token: 'first-secret');
        final changed = _credentials(
          bindingId: 'first',
          token: 'changed-secret',
        );
        final second = _credentials(
          bindingId: 'second',
          token: 'second-secret',
        );
        await store.saveDiskCredentials(_credentialRoom, first);
        final blocked = Directory('${_credentialsFile(directory).path}.tmp');
        await blocked.create();
        await expectLater(
          store.saveDiskCredentials(_credentialRoom, changed),
          throwsA(isA<FileSystemException>()),
        );
        expect(await store.loadDiskCredentials(_credentialRoom), first);
        expect(
          await store.loadDiskCredentials(_credentialRoom, bindingId: 'first'),
          changed,
        );
        await blocked.delete();
        await store.saveDiskCredentials(_credentialRoom, second);
        expect(await store.loadDiskCredentials(_credentialRoom), second);
        expect(
          await store.loadDiskCredentials(_credentialRoom, bindingId: 'first'),
          changed,
        );
        expect(
          await FileRoomStore.withDirectory(
            directory,
          ).loadDiskCredentials(_credentialRoom, bindingId: 'first'),
          changed,
        );
      },
    );

    test(
      'malformed credential files throw redacted errors without changing history',
      () async {
        final store = FileRoomStore.withDirectory(directory);
        await store.appendHistory(_credentialRoom, [_operation('intact')]);
        final file = _credentialsFile(directory);
        for (final encoded in [
          'secret-diagnostic-marker not JSON',
          'null',
          '[]',
          '"secret-diagnostic-marker"',
          '{}',
          '{"v":1,"bindingId":"binding","token":null}',
          '{"v":1,"bindingId":"binding","token":"secret-diagnostic-marker","extra":1}',
          '{"v":1,"bindingId":"binding","token":"secret-diagnostic-marker","token":"duplicate"}',
        ]) {
          await file.writeAsString(encoded);
          await expectLater(
            store.loadDiskCredentials(_credentialRoom),
            throwsA(
              isA<FormatException>().having(
                (error) => error.toString(),
                'redacted diagnostic',
                isNot(contains('secret-diagnostic-marker')),
              ),
            ),
          );
          await expectLater(
            store.saveDiskCredentials(_credentialRoom, _credentials()),
            throwsFormatException,
          );
          expect(await file.readAsString(), encoded);
          expect(await store.loadHistory(_credentialRoom), [
            _operation('intact'),
          ]);
        }
        await file.writeAsBytes([
          0xff,
          ...utf8.encode('secret-diagnostic-marker'),
        ]);
        await expectLater(
          store.loadDiskCredentials(_credentialRoom),
          throwsFormatException,
        );
        // Explicit null can remove broken secrets without touching the room.
        await store.saveDiskCredentials(_credentialRoom, null);
        expect(await store.loadDiskCredentials(_credentialRoom), isNull);
        expect(await store.loadHistory(_credentialRoom), [
          _operation('intact'),
        ]);
      },
    );

    test(
      'a failed atomic credential write keeps the previous durable value',
      () async {
        final store = FileRoomStore.withDirectory(directory);
        await store.saveDiskCredentials(_credentialRoom, _credentials());
        final file = _credentialsFile(directory);
        final original = await file.readAsString();
        final blocked = Directory('${file.path}.tmp');
        await blocked.create();
        await expectLater(
          store.saveDiskCredentials(
            _credentialRoom,
            _credentials(token: 'replacement'),
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(await file.readAsString(), original);
        expect(
          await store.loadDiskCredentials(_credentialRoom),
          _credentials(),
        );
        await blocked.delete();
        await store.saveDiskCredentials(
          _credentialRoom,
          _credentials(token: 'replacement'),
        );
        expect(
          (await store.loadDiskCredentials(_credentialRoom))!['token'],
          'replacement',
        );
      },
    );

    test(
      'appends JSONL rather than rewriting old records; retries add no bytes',
      () async {
        final store = FileRoomStore.withDirectory(directory);
        await store.appendHistory('room', [_operation('first')]);
        final file = _historyFile(directory, 'room');
        final original = await file.readAsString();
        await store.appendHistory('room', [_operation('second')]);
        final appended = await file.readAsString();
        expect(appended.startsWith(original), isTrue);
        expect(const LineSplitter().convert(appended), hasLength(2));
        final reopened = FileRoomStore.withDirectory(directory);
        await reopened.appendHistory('room', [
          _operation('first'),
          _operation('second'),
        ]);
        expect(await file.readAsString(), appended);
      },
    );

    test(
      'authored retry recovers a partial native prefix without changing proof bytes',
      () async {
        final prefix = _prefix();
        final file = _historyFile(directory, 'room');
        final firstLine = '${jsonEncode(prefix.first.toJson())}\n';
        await file.writeAsString('$firstLine{"id":"second","author":');
        final store = FileRoomStore.withDirectory(directory);
        final drafts = [
          _draft('first', clock: 3).toJson(),
          _draft('second', clock: 2).toJson(),
          _draft('third', clock: 1).toJson(),
        ];
        await expectLater(
          store.appendAuthoredHistory('room', drafts),
          throwsFormatException,
        );
        expect(await file.readAsString(), firstLine);
        final persisted = await store.appendAuthoredHistory('room', drafts);
        expect(persisted, prefix.map((edit) => edit.toJson()));
        final contents = await file.readAsString();
        expect(contents.startsWith(firstLine), isTrue);
        expect(const LineSplitter().convert(contents), hasLength(3));
        expect(await store.appendAuthoredHistory('room', drafts), persisted);
        expect(await file.readAsString(), contents);
        expect(
          await FileRoomStore.withDirectory(directory).loadHistory('room'),
          persisted,
        );
      },
    );

    test('native remote writes are physically predecessor-first', () async {
      final prefix = _prefix();
      final store = FileRoomStore.withDirectory(directory);
      await store.appendHistory(
        'room',
        prefix.reversed.map((edit) => edit.toJson()).toList(),
      );
      final lines = const LineSplitter().convert(
        await _historyFile(directory, 'room').readAsString(),
      );
      expect(lines.map((line) => (jsonDecode(line) as Map)['id']), [
        'first',
        'second',
        'third',
      ]);
    });

    test(
      'native reads report incomplete author closure without modifying it',
      () async {
        final file = _historyFile(directory, 'room');
        final contents = '${jsonEncode(_prefix().last.toJson())}\n';
        await file.writeAsString(contents);
        final store = FileRoomStore.withDirectory(directory);
        await expectLater(store.loadHistory('room'), throwsFormatException);
        await expectLater(
          store.appendAuthoredHistory('room', [_draft('new').toJson()]),
          throwsFormatException,
        );
        expect(await file.readAsString(), contents);
      },
    );

    test('flush waits for previously queued writes', () async {
      final store = FileRoomStore.withDirectory(directory);
      final writes = [
        store.saveMembership('room'),
        store.appendHistory('room', [_operation('pending')]),
      ];
      await store.flush();
      final reopened = FileRoomStore.withDirectory(directory);
      expect(await reopened.loadLastRoom(), 'room');
      expect(await reopened.loadHistory('room'), [_operation('pending')]);
      await Future.wait(writes);
    });

    test('repairs a complete final JSON record missing its newline', () async {
      final file = _historyFile(directory, 'room');
      await file.writeAsString(jsonEncode(_operation('first')));
      final store = FileRoomStore.withDirectory(directory);
      expect(await store.loadHistory('room'), [_operation('first')]);
      expect((await file.readAsString()).endsWith('\n'), isTrue);
      await store.appendHistory('room', [_operation('second')]);
      expect(await FileRoomStore.withDirectory(directory).loadHistory('room'), [
        _operation('first'),
        _operation('second'),
      ]);
    });

    test(
      'reports/truncates interrupted EOF then retries without gluing records',
      () async {
        final file = _historyFile(directory, 'room');
        final intact = '${jsonEncode(_operation('first'))}\n';
        await file.writeAsString('$intact{"id":"interrupted","text":');
        final store = FileRoomStore.withDirectory(directory);
        await expectLater(
          store.appendHistory('room', [_operation('second')]),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('Truncated an incomplete history tail'),
            ),
          ),
        );
        expect(await file.readAsString(), intact);
        await store.appendHistory('room', [_operation('second')]);
        expect(
          await FileRoomStore.withDirectory(directory).loadHistory('room'),
          [_operation('first'), _operation('second')],
        );
        expect(
          const LineSplitter().convert(await file.readAsString()),
          hasLength(2),
        );
      },
    );

    test('repairs and reports an interrupted multibyte UTF-8 tail', () async {
      final file = _historyFile(directory, 'room');
      final intact = utf8.encode('${jsonEncode(_operation('first'))}\n');
      await file.writeAsBytes([...intact, 0xe2, 0x82]);
      final store = FileRoomStore.withDirectory(directory);
      await expectLater(store.loadHistory('room'), throwsFormatException);
      expect(await file.readAsBytes(), intact);
      expect(await store.loadHistory('room'), [_operation('first')]);
    });

    test(
      'interior corruption is reported and never silently removed',
      () async {
        final file = _historyFile(directory, 'room');
        final contents =
            '${jsonEncode(_operation('first'))}\nnot json\n'
            '${jsonEncode(_operation('second'))}\n';
        await file.writeAsString(contents);
        final store = FileRoomStore.withDirectory(directory);
        await expectLater(store.loadHistory('room'), throwsFormatException);
        await expectLater(
          store.appendHistory('room', [_operation('third')]),
          throwsFormatException,
        );
        expect(await file.readAsString(), contents);
      },
    );

    test(
      'a valid JSON tail with a malformed operation is not truncated',
      () async {
        final file = _historyFile(directory, 'room');
        const contents = '{"text":"missing id"}';
        await file.writeAsString(contents);
        final store = FileRoomStore.withDirectory(directory);
        await expectLater(store.loadHistory('room'), throwsFormatException);
        expect(await file.readAsString(), contents);
      },
    );

    test(
      'deduplicates persisted duplicate lines but reports conflicting ones',
      () async {
        final file = _historyFile(directory, 'room');
        final first = jsonEncode(_operation('first'));
        await file.writeAsString('$first\n$first\n');
        expect(
          await FileRoomStore.withDirectory(directory).loadHistory('room'),
          [_operation('first')],
        );
        await file.writeAsString(
          '$first\n${jsonEncode(_operation('first', 'bad'))}\n',
        );
        await expectLater(
          FileRoomStore.withDirectory(directory).loadHistory('room'),
          throwsFormatException,
        );
      },
    );

    test('a real filesystem failure does not poison the write queue', () async {
      final blocked = Directory(_historyFile(directory, 'room').path);
      await blocked.create();
      final store = FileRoomStore.withDirectory(directory);
      await expectLater(
        store.appendHistory('room', [_operation('retry')]),
        throwsA(isA<FileSystemException>()),
      );
      await store.saveMembership('room');
      expect(await store.loadLastRoom(), 'room');
      await blocked.delete();
      await store.appendHistory('room', [_operation('retry')]);
      await store.flush();
      expect(await store.loadHistory('room'), [_operation('retry')]);
    });

    test('membership failure cannot change last room first', () async {
      final store = FileRoomStore.withDirectory(directory);
      await store.saveMembership('previous');
      await Directory(
        '${directory.path}/member-${_key('blocked')}.json',
      ).create();
      await expectLater(
        store.saveMembership('blocked'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await store.loadLastRoom(), 'previous');
      await expectLater(
        store.hasMembership('blocked'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test(
      'last-room failure still leaves its membership durably saved',
      () async {
        await Directory('${directory.path}/last-room.json').create();
        final store = FileRoomStore.withDirectory(directory);
        await expectLater(
          store.saveMembership('member'),
          throwsA(isA<FileSystemException>()),
        );
        expect(await store.hasMembership('member'), isTrue);
      },
    );

    test(
      'metadata corruption and missing referenced membership are reported',
      () async {
        final store = FileRoomStore.withDirectory(directory);
        final clientFile = File('${directory.path}/client-id.json');
        await clientFile.writeAsString('broken JSON');
        await expectLater(store.loadClientId(), throwsFormatException);
        expect(await clientFile.readAsString(), 'broken JSON');
        await clientFile.writeAsString('null');
        await expectLater(store.loadClientId(), throwsFormatException);
        await File(
          '${directory.path}/last-room.json',
        ).writeAsString(jsonEncode('missing-membership'));
        await expectLater(store.loadLastRoom(), throwsFormatException);
        await File(
          '${directory.path}/member-${_key('room')}.json',
        ).writeAsString(jsonEncode('different-room'));
        await expectLater(store.hasMembership('room'), throwsFormatException);
        await expectLater(store.saveMembership('room'), throwsFormatException);
      },
    );
  });
}
