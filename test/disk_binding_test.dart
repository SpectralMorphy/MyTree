import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/cloud/disk_binding.dart';
import 'package:mytree_webrtc_demo/room_document.dart';

RoomEdit _connection(
  String id,
  int clock, {
  String owner = 'owner',
  String? disconnect,
}) => RoomEdit(
  id: id,
  author: owner,
  clock: clock,
  createdAt: 1000 - clock,
  kind: RoomEditKind.diskConnection,
  text: jsonEncode({
    'action': disconnect == null ? 'connect' : 'disconnect',
    if (disconnect != null) 'bindingId': disconnect,
  }),
);

Iterable<List<T>> _permutations<T>(List<T> values) sync* {
  if (values.isEmpty) {
    yield [];
    return;
  }
  for (var index = 0; index < values.length; index++) {
    final remaining = List<T>.of(values)..removeAt(index);
    for (final tail in _permutations(remaining)) {
      yield [values[index], ...tail];
    }
  }
}

void main() {
  test('wire and author proofs preserve public Disk metadata only', () {
    final connect = _connection('binding', 1);
    final disconnect = _connection('detach', 2, disconnect: connect.id);
    for (final edit in [connect, disconnect]) {
      expect(edit.toJson()['kind'], 'diskConnection');
      final decoded = decodeRoomHistory([edit.toJson()]).single;
      expect(decoded.sameContentAs(edit), isTrue);
      final canonical = sequenceAuthoredEdit(edit, []);
      expect(canonical.sameCoreAs(edit), isTrue);
      expect(validateAuthorHistory([canonical]), [canonical]);
      expect(
        RoomEdit.fromJson(canonical.toJson())!.sameContentAs(canonical),
        isTrue,
      );
      expect(jsonEncode(edit.toJson()), isNot(contains('token')));
    }
    expect(jsonDecode(connect.text), {'action': 'connect'});
    expect(jsonDecode(disconnect.text), {
      'action': 'disconnect',
      'bindingId': connect.id,
    });
  });

  test('payload shape is exact; malformed and secret fields are rejected', () {
    final raw = _connection('binding', 1).toJson();
    final invalid = <String>[
      '',
      '{',
      'null',
      '[]',
      '"connect"',
      '{}',
      '{"action":null}',
      '{"action":1}',
      '{"action":"Connect"}',
      '{"action":" connect"}',
      '{"action":"disconnect"}',
      '{"action":"connect","bindingId":"other"}',
      '{"action":"connect","ownerActor":"other"}',
      '{"action":"connect","token":"must-stay-local"}',
      '{"action":"connect","action":"connect"}',
      '{"action":"disconnect","action":"connect"}',
      '{"action":"disconnect","bindingId":"hidden-secret","bindingId":"id"}',
      for (final bindingId in <Object?>[null, '', 'x' * 129, 1, true, [], {}])
        jsonEncode({'action': 'disconnect', 'bindingId': bindingId}),
      '{"action":"disconnect","bindingId":"id","extra":null}',
    ];
    final document = RoomDocument();
    for (var index = 0; index < invalid.length; index++) {
      final text = invalid[index];
      expect(isValidDiskConnection(text), isFalse, reason: 'case $index');
      expect(RoomEdit.fromJson({...raw, 'text': text}), isNull);
      expect(
        () => decodeRoomHistory([
          {...raw, 'text': text},
        ]),
        throwsFormatException,
      );
      expect(
        () => validateAuthorHistory([
          RoomEdit(
            id: 'invalid',
            author: 'owner',
            clock: 1,
            createdAt: 1,
            text: text,
            kind: RoomEditKind.diskConnection,
          ),
        ]),
        throwsFormatException,
      );
      expect(
        () => document.createEdit(
          'owner',
          text,
          kind: RoomEditKind.diskConnection,
        ),
        throwsFormatException,
      );
    }
    for (final target in <String?>[null, 'target']) {
      expect(RoomEdit.fromJson({...raw, 'targetActor': target}), isNull);
    }
    expect(
      isValidDiskConnection(
        jsonEncode({'action': 'disconnect', 'bindingId': 'x' * 128}),
      ),
      isTrue,
    );
    const preserved = ' { "bindingId" : "id", "action" : "disconnect" } ';
    expect(isValidDiskConnection(preserved), isTrue);
    expect(RoomEdit.fromJson({...raw, 'text': preserved})!.text, preserved);
    expect(
      isValidDiskConnection(r'{"action":"connect","action":"connect"}'),
      isFalse,
    );
    expect(
      isValidDiskConnection(
        jsonEncode({'action': 'disconnect', 'bindingId': 'quoted ": string'}),
      ),
      isTrue,
    );
  });

  test('connects use clock then ID, not input order or wall time', () {
    final a = _connection('a', 5, owner: 'alice');
    final b = _connection('b', 5, owner: 'bob');
    final later = _connection('0', 6, owner: 'carol');
    for (final edits in _permutations([a, b, later])) {
      final active = DiskBinding.project(edits)!;
      expect(active.id, a.id);
      expect(active.ownerActor, 'alice');
    }
    expect(DiskBinding.project([]), isNull);
  });

  test(
    'exact disconnect and reconnect replay identically for every delivery',
    () {
      final first = _connection('first', 1);
      final ignored = _connection('ignored-connect', 2, owner: 'other');
      final stale = _connection('stale-detach', 3, disconnect: ignored.id);
      final detach = _connection('detach', 4, disconnect: first.id);
      final reconnect = _connection('reconnect', 5, owner: 'next-owner');
      final oldDetach = _connection('old-detach', 6, disconnect: first.id);
      expect(DiskBinding.project([first, ignored, stale])!.id, first.id);
      expect(DiskBinding.project([first, ignored, stale, detach]), isNull);
      final history = [first, ignored, detach, reconnect, oldDetach];
      for (final edits in _permutations(history)) {
        final active = DiskBinding.project(edits)!;
        expect(active.id, reconnect.id);
        expect(active.ownerActor, 'next-owner');
      }
      final document = RoomDocument()..merge(history.reversed);
      expect(document.historyLength, history.length);
      expect(document.toJson(), history.map((edit) => edit.toJson()).toList());
      final restored = decodeRoomHistory(document.toJson());
      expect(DiskBinding.project(restored)!.id, reconnect.id);
      expect(DiskBinding.project([...restored, ...restored])!.id, reconnect.id);
    },
  );

  test('late arrival of an earlier connect replays previously seen detach', () {
    final connect = _connection('binding', 10);
    final detach = _connection('detach', 20, disconnect: connect.id);
    final document = RoomDocument()..merge([detach]);
    expect(DiskBinding.project(document.history), isNull);
    document.merge([connect]);
    expect(DiskBinding.project(document.history), isNull);
    // A logically earlier disconnect is not a tombstone for a future connect.
    final premature = _connection('premature', 1, disconnect: connect.id);
    expect(DiskBinding.project([connect, premature])!.id, connect.id);
  });

  test('metadata does not alter other projections and shares their clock', () {
    final document = RoomDocument();
    final text = document.createEdit('owner', 'note');
    document.merge([text]);
    final connect = document.createEdit(
      'owner',
      '{"action":"connect"}',
      kind: RoomEditKind.diskConnection,
      id: 'staged-binding',
      now: DateTime.fromMillisecondsSinceEpoch(1),
    );
    expect(connect.id, 'staged-binding');
    expect(connect.clock, text.clock + 1);
    document.merge([connect]);
    document.finalizeAuthored(sequenceAuthoredEdit(connect, [text]));
    expect(document.text, 'note');
    expect(document.latest, text);
    expect(document.roomName, 'Комната');
    expect(document.participantNames, isEmpty);
    expect(document.participantRoles, isEmpty);
    expect(DiskBinding.project(document.history)!.id, connect.id);
    final next = document.createEdit(
      'owner',
      'next',
      now: DateTime.fromMillisecondsSinceEpoch(1),
    );
    expect(next.clock, connect.clock + 1);
    for (final id in ['', 'x' * 129]) {
      expect(
        () => document.createEdit(
          'owner',
          '{"action":"connect"}',
          kind: RoomEditKind.diskConnection,
          id: id,
        ),
        throwsFormatException,
      );
    }
    expect(document.createEdit('owner', 'text', id: 'x' * 128).id, 'x' * 128);
  });
}
