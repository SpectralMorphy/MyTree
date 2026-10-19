import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/room_document.dart';
import 'package:mytree_webrtc_demo/room_identity.dart';

RoomEdit edit(
  String id,
  int clock,
  String text, {
  String author = 'author',
  RoomEditKind kind = RoomEditKind.text,
  String? targetActor,
}) => RoomEdit(
  id: id,
  author: author,
  clock: clock,
  createdAt: clock,
  text: text,
  kind: kind,
  targetActor: targetActor,
);

RoomEdit sequenced(
  String id,
  int clock,
  int sequence, {
  String author = 'author',
  String? previous,
  List<String>? base,
}) => edit(id, clock, id, author: author).withAuthorProof(
  authorSequence: sequence,
  authorPrevious: previous,
  authorBase: base ?? (sequence == 1 ? [] : null),
);

void main() {
  test('history union is idempotent and independent of delivery order', () {
    final a = edit('a', 10, 'first');
    final b = edit('b', 20, 'second');
    final one = RoomDocument()..merge([a, b, a]);
    final two = RoomDocument()..merge([b, a, b]);

    expect(one.text, 'second');
    expect(two.text, one.text);
    expect(one.historyLength, 2);
    expect(two.toJson(), one.toJson());
  });

  test(
    'simultaneous edits select the same winner and retain both versions',
    () {
      final one = RoomDocument()
        ..merge([edit('b', 20, 'B'), edit('a', 20, 'A')]);
      final two = RoomDocument()
        ..merge([edit('a', 20, 'A'), edit('b', 20, 'B')]);
      expect(one.text, 'B');
      expect(two.text, 'B');
      expect(one.history.map((e) => e.text), ['A', 'B']);
    },
  );

  test(
    'an edit after loading remote history wins even with an older clock',
    () {
      final document = RoomDocument()..merge([edit('remote', 10000, 'remote')]);
      final next = document.createEdit(
        'local',
        'local',
        now: DateTime.fromMillisecondsSinceEpoch(1),
      );
      document.merge([next]);
      expect(next.clock, 10001);
      expect(document.text, 'local');
    },
  );

  test('edits serialize multiline and non-ASCII text without loss', () {
    final original = edit('a', 10, 'Семья 👋\nВторая строка');
    final decoded = RoomEdit.fromJson(original.toJson())!;
    expect(decoded.toJson(), original.toJson());
  });

  test('empty text is an edit, not missing history', () {
    final document = RoomDocument()
      ..merge([edit('a', 10, 'text'), edit('b', 20, '')]);
    expect(document.text, isEmpty);
    expect(document.historyLength, 2);
  });

  test('batch decoding validates immutable IDs before returning any edits', () {
    final first = edit('same', 1, 'first');
    expect(decodeRoomHistory([first.toJson(), first.toJson()]), hasLength(2));
    expect(
      () => decodeRoomHistory([
        first.toJson(),
        edit('same', 2, 'changed').toJson(),
      ]),
      throwsFormatException,
    );
    expect(
      () => decodeRoomHistory([
        first.toJson(),
        {'id': 'invalid'},
      ]),
      throwsFormatException,
    );
  });

  test('text JSON stays exactly compatible and missing kind means text', () {
    final original = edit('a', 10, 'Семья 👋\nВторая строка');
    final expected = {
      'id': 'a',
      'author': 'author',
      'clock': 10,
      'createdAt': 10,
      'text': original.text,
    };
    expect(original.kind, RoomEditKind.text);
    expect(original.toJson(), expected);
    expect(RoomEdit.fromJson(expected)!.sameContentAs(original), isTrue);
    final explicit = RoomEdit.fromJson({...expected, 'kind': 'text'})!;
    expect(explicit.sameContentAs(original), isTrue);
    expect(explicit.toJson(), expected);
  });

  test('metadata JSON round trips without changing the immutable payload', () {
    for (final kind in [RoomEditKind.participantName, RoomEditKind.roomName]) {
      final original = edit('name', 12, 'Семья 👋', kind: kind);
      expect(original.toJson()['kind'], kind.name);
      final decoded = RoomEdit.fromJson(original.toJson())!;
      expect(decoded.kind, kind);
      expect(decoded.author, 'author');
      expect(decoded.text, 'Семья 👋');
      expect(decoded.sameContentAs(original), isTrue);
      expect(
        decodeRoomHistory([original.toJson()]).single.toJson(),
        original.toJson(),
      );
    }
  });

  test(
    'name normalization trims but wire validation requires canonical names',
    () {
      expect(normalizeParticipantName('  Анна 👋  '), 'Анна 👋');
      expect(normalizeRoomName('  Наша семья  '), 'Наша семья');
      expect(isValidParticipantName('Анна 👋'), isTrue);
      expect(isValidRoomName('Наша семья'), isTrue);
      expect(normalizeParticipantName(''), '');
      expect(normalizeParticipantName('   '), '');
      expect(isValidParticipantName(''), isTrue);
      expect(isValidRoomName(''), isFalse);
      expect(normalizeRoomName('   '), isNull);
      for (final value in <Object?>[null, 1, '   ', ' Анна', 'Анна ']) {
        expect(isValidParticipantName(value), isFalse, reason: '$value');
        expect(isValidRoomName(value), isFalse, reason: '$value');
      }
      for (final code in [
        0,
        9,
        10,
        13,
        0x1f,
        0x7f,
        0x85,
        0x9f,
        0x2028,
        0x2029,
      ]) {
        final control = String.fromCharCode(code);
        for (final value in ['$control Анна', 'Ан$controlна', 'Анна$control']) {
          expect(normalizeParticipantName(value), isNull, reason: '$code');
          expect(normalizeRoomName(value), isNull, reason: '$code');
        }
      }
    },
  );

  test('name limits count Unicode code points, not UTF-16 code units', () {
    expect(maxParticipantNameLength, 64);
    expect(maxRoomNameLength, 120);
    expect(normalizeParticipantName('a' * 64), 'a' * 64);
    expect(normalizeParticipantName('a' * 65), isNull);
    expect(normalizeParticipantName('😀' * 64), '😀' * 64);
    expect(normalizeParticipantName('😀' * 65), isNull);
    expect(normalizeRoomName('a' * 120), 'a' * 120);
    expect(normalizeRoomName('a' * 121), isNull);
    expect(normalizeRoomName('😀' * 120), '😀' * 120);
    expect(normalizeRoomName('😀' * 121), isNull);
  });

  test(
    'unknown kinds and invalid or noncanonical metadata names are rejected',
    () {
      final raw = edit('a', 1, 'Анна').toJson();
      for (final kind in <Object?>[
        null,
        1,
        true,
        '',
        'unknown',
        'participant-name',
      ]) {
        expect(RoomEdit.fromJson({...raw, 'kind': kind}), isNull);
        expect(
          () => decodeRoomHistory([
            {...raw, 'kind': kind},
          ]),
          throwsFormatException,
        );
      }
      for (final kind in [
        RoomEditKind.participantName,
        RoomEditKind.roomName,
      ]) {
        final max = kind == RoomEditKind.participantName ? 64 : 120;
        for (final text in [
          if (kind == RoomEditKind.roomName) '',
          '  ',
          ' Анна',
          'Анна ',
          'Анна\nИван',
          'a' * (max + 1),
        ]) {
          final invalid = {...raw, 'kind': kind.name, 'text': text};
          expect(RoomEdit.fromJson(invalid), isNull);
          expect(() => decodeRoomHistory([invalid]), throwsFormatException);
        }
      }
      expect(RoomEdit.fromJson({...raw, 'text': '  \n'}), isNotNull);
    },
  );

  test(
    'empty alias is an immutable clearing edit, never an Anonymous value',
    () {
      final initial = edit(
        'named',
        10,
        'Анна',
        kind: RoomEditKind.participantName,
      );
      final cleared = edit(
        'cleared',
        20,
        '',
        kind: RoomEditKind.participantName,
      );
      final raw = cleared.toJson();
      expect(raw['text'], '');
      expect(RoomEdit.fromJson(raw)!.sameContentAs(cleared), isTrue);
      final canonical = sequenceAuthoredEdit(cleared, [initial]);
      expect(canonical.text, '');
      expect(canonical.authorBase, ['named']);
      expect(
        RoomEdit.fromJson(canonical.toJson())!.sameContentAs(canonical),
        isTrue,
      );
      for (final history in [
        [initial, canonical],
        [canonical, initial, canonical],
      ]) {
        final document = RoomDocument()..merge(history);
        expect(document.participantNames, {'author': ''});
        expect(document.historyLength, 2);
        expect(document.history.any((edit) => edit.text == 'Аноним'), isFalse);
        final restored = RoomDocument()
          ..merge(decodeRoomHistory(document.toJson()));
        expect(restored.participantNames, {'author': ''});
        expect(restored.toJson(), document.toJson());
      }
      final document = RoomDocument();
      final draft = document.createEdit(
        'author',
        '   ',
        kind: RoomEditKind.participantName,
      );
      expect(draft.text, '');
      document.merge([draft]);
      expect(document.participantNames, {'author': ''});
    },
  );

  test('metadata LWW is independent per author and does not replace text', () {
    final text = edit('text', 1, 'Заметка');
    final edits = [
      text,
      edit(
        'alice-a',
        10,
        'Аня',
        author: 'alice',
        kind: RoomEditKind.participantName,
      ),
      edit(
        'alice-b',
        10,
        'Анна',
        author: 'alice',
        kind: RoomEditKind.participantName,
      ),
      edit(
        'bob',
        30,
        'Борис',
        author: 'bob',
        kind: RoomEditKind.participantName,
      ),
      edit('title-a', 20, 'Старая', kind: RoomEditKind.roomName),
      edit(
        'title-b',
        20,
        'Наша семья',
        author: 'bob',
        kind: RoomEditKind.roomName,
      ),
    ];
    final one = RoomDocument()..merge(edits);
    final two = RoomDocument()..merge(edits.reversed);
    for (final document in [one, two]) {
      expect(document.text, 'Заметка');
      expect(document.latest, text);
      expect(document.roomName, 'Наша семья');
      expect(document.participantNames, {'alice': 'Анна', 'bob': 'Борис'});
      expect(document.historyLength, edits.length);
    }
    expect(one.toJson(), two.toJson());
    final restored = RoomDocument()..merge(decodeRoomHistory(one.toJson()));
    expect(restored.text, one.text);
    expect(restored.roomName, one.roomName);
    expect(restored.participantNames, one.participantNames);
    expect(restored.toJson(), one.toJson());
  });

  test(
    'metadata-only documents keep default text and name snapshots immutable',
    () {
      final document = RoomDocument();
      expect(document.roomName, 'Комната');
      expect(document.participantNames, isEmpty);
      document.merge([
        edit('name', 10, 'Анна', kind: RoomEditKind.participantName),
      ]);
      final names = document.participantNames;
      expect(document.text, isEmpty);
      expect(document.latest, isNull);
      expect(names, {'author': 'Анна'});
      expect(() => names['author'] = 'Changed', throwsUnsupportedError);
      document.merge([
        edit('rename', 20, 'Аня', kind: RoomEditKind.participantName),
      ]);
      expect(names, {'author': 'Анна'});
      expect(document.participantNames, {'author': 'Аня'});
    },
  );

  test('new metadata edits normalize names and share the document clock', () {
    final document = RoomDocument()
      ..merge([edit('remote', 10000, 'Семья', kind: RoomEditKind.roomName)]);
    final name = document.createEdit(
      'local',
      '  Анна  ',
      kind: RoomEditKind.participantName,
      now: DateTime.fromMillisecondsSinceEpoch(1),
    );
    expect(name.kind, RoomEditKind.participantName);
    expect(name.text, 'Анна');
    expect(name.author, 'local');
    expect(name.clock, 10001);
    document.merge([name]);
    final title = document.createEdit(
      'local',
      '  Наша семья  ',
      kind: RoomEditKind.roomName,
      now: DateTime.fromMillisecondsSinceEpoch(1),
    );
    expect(title.text, 'Наша семья');
    expect(title.clock, 10002);
    expect(title.id, isNot(name.id));
    expect(
      () => document.createEdit('local', '  ', kind: RoomEditKind.roomName),
      throwsFormatException,
    );
    expect(
      () => document.createEdit(
        'local',
        'a' * 65,
        kind: RoomEditKind.participantName,
      ),
      throwsFormatException,
    );
    final text = document.createEdit('local', '  \n');
    expect(text.kind, RoomEditKind.text);
    expect(text.text, '  \n');
  });

  test(
    'kind is part of immutable identity and retries do not rename again',
    () {
      final text = edit('same', 1, 'Анна');
      final name = edit('same', 1, 'Анна', kind: RoomEditKind.participantName);
      expect(text.sameContentAs(name), isFalse);
      expect(
        () => decodeRoomHistory([text.toJson(), name.toJson()]),
        throwsFormatException,
      );
      final document = RoomDocument();
      expect(document.merge([name]), [name]);
      expect(document.merge([name]), isEmpty);
      expect(document.historyLength, 1);
      expect(document.text, isEmpty);
    },
  );

  test('role JSON records issuing author and a distinct subject', () {
    for (final role in RoomRole.values) {
      final original = edit(
        'role',
        12,
        role.name,
        author: 'editor',
        kind: RoomEditKind.participantRole,
        targetActor: 'subject',
      );
      expect(original.toJson(), {
        'id': 'role',
        'author': 'editor',
        'clock': 12,
        'createdAt': 12,
        'text': role.name,
        'kind': 'participantRole',
        'targetActor': 'subject',
      });
      final decoded = RoomEdit.fromJson(original.toJson())!;
      expect(decoded.sameContentAs(original), isTrue);
      expect(decoded.targetActor, 'subject');
      expect(
        decodeRoomHistory([original.toJson()]).single.toJson(),
        original.toJson(),
      );
    }
  });

  test('roles require a valid target and exact supported role text', () {
    final raw = edit(
      'role',
      1,
      'guest',
      kind: RoomEditKind.participantRole,
      targetActor: 'subject',
    ).toJson();
    final missingTarget = Map<String, dynamic>.of(raw)..remove('targetActor');
    final invalid = [
      missingTarget,
      for (final target in <Object?>[null, '', 'x' * 129, 1, true, [], {}])
        {...raw, 'targetActor': target},
      for (final role in <Object?>[
        null,
        1,
        '',
        'owner',
        'Guest',
        ' guest',
        'guest ',
        'editor\n',
      ])
        {...raw, 'text': role},
    ];
    for (final value in invalid) {
      expect(RoomEdit.fromJson(value), isNull, reason: '$value');
      expect(() => decodeRoomHistory([value]), throwsFormatException);
    }
    expect(RoomEdit.fromJson({...raw, 'targetActor': 'x' * 128}), isNotNull);
    for (final kind in [
      RoomEditKind.text,
      RoomEditKind.participantName,
      RoomEditKind.roomName,
    ]) {
      for (final target in <Object?>[null, 'subject']) {
        final invalid = {...raw, 'kind': kind.name, 'targetActor': target};
        expect(RoomEdit.fromJson(invalid), isNull);
        expect(() => decodeRoomHistory([invalid]), throwsFormatException);
      }
    }
  });

  test('every role operation field is immutable across duplicate IDs', () {
    final role = edit(
      'same',
      1,
      'guest',
      author: 'editor',
      kind: RoomEditKind.participantRole,
      targetActor: 'subject',
    );
    final original = role.toJson();
    expect(decodeRoomHistory([original, original]), hasLength(2));
    for (final mutation in <Map<String, dynamic>>[
      {'author': 'other-editor'},
      {'clock': 2},
      {'createdAt': 2},
      {'text': 'editor'},
      {'targetActor': 'other-subject'},
    ]) {
      final changed = RoomEdit.fromJson({...original, ...mutation})!;
      expect(role.sameContentAs(changed), isFalse);
      expect(
        () => decodeRoomHistory([original, changed.toJson()]),
        throwsFormatException,
      );
    }
    final text = edit('same', 1, 'guest', author: 'editor');
    expect(role.sameContentAs(text), isFalse);
    expect(
      () => decodeRoomHistory([original, text.toJson()]),
      throwsFormatException,
    );
  });

  test('role projection is per target and independent of text and names', () {
    final text = edit('text', 1, 'Заметка', author: 'legacy');
    final edits = [
      text,
      edit(
        'name',
        2,
        'Анна',
        author: 'alice',
        kind: RoomEditKind.participantName,
      ),
      edit('room', 3, 'Семья', kind: RoomEditKind.roomName),
      edit(
        'alice-role',
        4,
        'guest',
        author: 'editor',
        kind: RoomEditKind.participantRole,
        targetActor: 'alice',
      ),
      edit(
        'bob-role',
        5,
        'editor',
        author: 'alice',
        kind: RoomEditKind.participantRole,
        targetActor: 'bob',
      ),
    ];
    final one = RoomDocument()..merge(edits);
    final two = RoomDocument()..merge(edits.reversed);
    final restored = RoomDocument()..merge(decodeRoomHistory(one.toJson()));
    for (final document in [one, two, restored]) {
      expect(document.text, 'Заметка');
      expect(document.latest!.toJson(), text.toJson());
      expect(document.roomName, 'Семья');
      expect(document.participantNames, {'alice': 'Анна'});
      expect(document.participantRoles, {
        'alice': RoomRole.guest,
        'bob': RoomRole.editor,
      });
      expect(document.roleFor('alice'), RoomRole.guest);
      expect(document.roleFor('bob'), RoomRole.editor);
      expect(document.roleFor('legacy'), RoomRole.editor);
      expect(document.roleFor('editor'), RoomRole.editor);
      expect(document.roleFor('unknown'), RoomRole.editor);
      expect(document.toJson(), one.toJson());
    }
    final roles = one.participantRoles;
    expect(() => roles['alice'] = RoomRole.editor, throwsUnsupportedError);
    one.merge([
      edit(
        'promote',
        6,
        'editor',
        kind: RoomEditKind.participantRole,
        targetActor: 'alice',
      ),
    ]);
    expect(roles['alice'], RoomRole.guest);
    expect(one.roleFor('alice'), RoomRole.editor);
  });

  test('promotion wins delayed guest records regardless of clock or order', () {
    final guest = edit(
      'guest',
      100,
      'guest',
      kind: RoomEditKind.participantRole,
      targetActor: 'subject',
    );
    final promotion = edit(
      'promote',
      1,
      'editor',
      author: 'promoter',
      kind: RoomEditKind.participantRole,
      targetActor: 'subject',
    );
    final laterGuest = edit(
      'late-guest',
      1000,
      'guest',
      kind: RoomEditKind.participantRole,
      targetActor: 'subject',
    );
    final one = RoomDocument()..merge([guest, promotion]);
    final two = RoomDocument()..merge([promotion, guest]);
    for (final document in [one, two]) {
      expect(document.roleFor('subject'), RoomRole.editor);
      expect(document.merge([laterGuest]), [laterGuest]);
      expect(document.roleFor('subject'), RoomRole.editor);
      expect(document.merge([promotion]), isEmpty);
      expect(document.historyLength, 3);
      expect(document.text, isEmpty);
      expect(document.latest, isNull);
      expect(document.participantNames, isEmpty);
      expect(document.roomName, 'Комната');
    }
    expect(one.toJson(), two.toJson());
  });

  test('created role edits validate targets and share the document clock', () {
    final document = RoomDocument()..merge([edit('remote', 1000, 'text')]);
    final role = document.createEdit(
      'editor',
      'guest',
      kind: RoomEditKind.participantRole,
      targetActor: 'subject',
      now: DateTime.fromMillisecondsSinceEpoch(1),
    );
    expect(role.author, 'editor');
    expect(role.targetActor, 'subject');
    expect(role.text, 'guest');
    expect(role.clock, 1001);
    document.merge([role]);
    final promotion = document.createEdit(
      'promoter',
      'editor',
      kind: RoomEditKind.participantRole,
      targetActor: 'subject',
      now: DateTime.fromMillisecondsSinceEpoch(1),
    );
    expect(promotion.clock, 1002);
    expect(promotion.id, isNot(role.id));
    for (final target in <String?>[null, '', 'x' * 129]) {
      expect(
        () => document.createEdit(
          'editor',
          'guest',
          kind: RoomEditKind.participantRole,
          targetActor: target,
        ),
        throwsFormatException,
      );
    }
    for (final value in ['', 'owner', ' guest', 'editor ']) {
      expect(
        () => document.createEdit(
          'editor',
          value,
          kind: RoomEditKind.participantRole,
          targetActor: 'subject',
        ),
        throwsFormatException,
      );
    }
    for (final kind in [
      RoomEditKind.text,
      RoomEditKind.participantName,
      RoomEditKind.roomName,
    ]) {
      expect(
        () => document.createEdit(
          'editor',
          'name',
          kind: kind,
          targetActor: 'subject',
        ),
        throwsFormatException,
      );
    }
  });

  group('author prefix proofs', () {
    test('legacy serialization stays byte-for-byte unchanged', () {
      final legacy = edit('a', 10, 'unchanged');
      expect(
        jsonEncode(legacy.toJson()),
        '{"id":"a","author":"author","clock":10,"createdAt":10,'
        '"text":"unchanged"}',
      );
      final decoded = decodeRoomHistory([legacy.toJson()]).single;
      expect(decoded.authorSequence, isNull);
      expect(decoded.authorPrevious, isNull);
      expect(decoded.authorBase, isNull);
      expect(jsonEncode(decoded.toJson()), jsonEncode(legacy.toJson()));
      expect(decoded.sameContentAs(legacy), isTrue);
    });

    test('proof keys round trip without changing any core field', () {
      final draft = edit('first', 10, 'value');
      final first = draft.withAuthorProof(
        authorSequence: 1,
        authorPrevious: null,
        authorBase: ['legacy-a', 'legacy-z'],
      );
      expect(first.toJson(), {
        ...draft.toJson(),
        'authorSequence': 1,
        'authorPrevious': null,
        'authorBase': ['legacy-a', 'legacy-z'],
      });
      expect(first.sameCoreAs(draft), isTrue);
      expect(first.sameContentAs(draft), isFalse);
      expect(RoomEdit.fromJson(first.toJson())!.sameContentAs(first), isTrue);
      final next = sequenced('next', 1, 2, previous: first.id);
      expect(next.toJson()['authorSequence'], 2);
      expect(next.toJson()['authorPrevious'], first.id);
      expect(next.toJson().containsKey('authorBase'), isFalse);
      expect(RoomEdit.fromJson(next.toJson())!.sameContentAs(next), isTrue);
      final otherBase = draft.withAuthorProof(
        authorSequence: 1,
        authorPrevious: null,
        authorBase: [],
      );
      expect(otherBase.sameCoreAs(first), isTrue);
      expect(otherBase.sameContentAs(first), isFalse);
      final otherPrevious = next.withAuthorProof(
        authorSequence: 2,
        authorPrevious: 'other',
      );
      final otherSequence = next.withAuthorProof(
        authorSequence: 3,
        authorPrevious: first.id,
      );
      expect(otherPrevious.sameContentAs(next), isFalse);
      expect(otherSequence.sameContentAs(next), isFalse);
    });

    test('baselines are immutable snapshots, including JSON decoding', () {
      final base = ['old'];
      final first = sequenced('first', 1, 1, base: base);
      base[0] = 'mutated';
      expect(first.authorBase, ['old']);
      expect(() => first.authorBase!.add('late'), throwsUnsupportedError);
      expect(
        () => (first.toJson()['authorBase'] as List).clear(),
        throwsUnsupportedError,
      );
      final rawBase = ['old'];
      final decoded = RoomEdit.fromJson({
        ...first.toJson(),
        'authorBase': rawBase,
      })!;
      rawBase.clear();
      expect(decoded.authorBase, ['old']);
      expect(() => decoded.authorBase![0] = 'late', throwsUnsupportedError);
    });

    test('chain presence, types, bounds and canonical baseline are exact', () {
      final raw = edit('a', 1, 'text').toJson();
      final first = <String, dynamic>{
        ...raw,
        'authorSequence': 1,
        'authorPrevious': null,
        'authorBase': <String>[],
      };
      final next = <String, dynamic>{
        ...raw,
        'authorSequence': 2,
        'authorPrevious': 'previous',
      };
      final missingPrevious = Map<String, dynamic>.of(first)
        ..remove('authorPrevious');
      final missingBase = Map<String, dynamic>.of(first)..remove('authorBase');
      final invalid = <Map<String, dynamic>>[
        {...raw, 'authorPrevious': null},
        {...raw, 'authorBase': []},
        {...raw, 'authorSequence': 1},
        missingPrevious,
        missingBase,
        for (final sequence in <Object?>[
          null,
          0,
          -1,
          9007199254740992,
          1.0,
          '1',
          true,
          [],
        ])
          {...first, 'authorSequence': sequence},
        for (final previous in <Object?>['previous', '', 1, true, [], {}])
          {...first, 'authorPrevious': previous},
        for (final base in <Object?>[
          null,
          'old',
          {},
          ['z', 'a'],
          ['a', 'a'],
          [''],
          ['x' * 129],
          [null],
          [1],
          [true],
          List.filled(maxAuthorBaseLength + 1, 'a'),
        ])
          {...first, 'authorBase': base},
        Map<String, dynamic>.of(next)..remove('authorPrevious'),
        for (final previous in <Object?>[null, '', 'x' * 129, 1, true, [], {}])
          {...next, 'authorPrevious': previous},
        {...next, 'authorBase': null},
        {...next, 'authorBase': []},
      ];
      for (var i = 0; i < invalid.length; i++) {
        expect(RoomEdit.fromJson(invalid[i]), isNull, reason: 'case $i');
        expect(
          () => decodeRoomHistory([invalid[i]]),
          throwsFormatException,
          reason: 'case $i',
        );
      }
      expect(
        RoomEdit.fromJson({...next, 'authorSequence': 9007199254740991}),
        isNotNull,
      );
      expect(
        RoomEdit.fromJson({...next, 'authorPrevious': 'x' * 128}),
        isNotNull,
      );
      expect(
        RoomEdit.fromJson({
          ...first,
          'authorBase': ['x' * 128],
        }),
        isNotNull,
      );
      expect(
        () => edit(
          'x',
          1,
          'x',
        ).withAuthorProof(authorSequence: 1, authorPrevious: null),
        throwsFormatException,
      );
      expect(
        () => edit('x', 1, 'x').withAuthorProof(
          authorSequence: 2,
          authorPrevious: 'previous',
          authorBase: [],
        ),
        throwsFormatException,
      );
    });

    test('baseline count limit is inclusive', () {
      final base = List.generate(
        maxAuthorBaseLength,
        (i) => i.toString().padLeft(6, '0'),
      );
      final first = sequenced('first', 1, 1, base: base);
      expect(first.authorBase, hasLength(maxAuthorBaseLength));
      expect(RoomEdit.fromJson(first.toJson()), isNotNull);
    });

    test('batch decoding intentionally accepts incomplete proof subsets', () {
      final second = sequenced('second', 1, 2, previous: 'missing');
      final root = sequenced('root', 1, 1, base: ['old']);
      for (final value in [second, root]) {
        expect(
          decodeRoomHistory([value.toJson()]).single.sameContentAs(value),
          isTrue,
        );
        expect(() => validateAuthorHistory([value]), throwsFormatException);
        expect(validateAuthorHistory([value], requireComplete: false), [value]);
      }
    });

    test('all-legacy histories stay readable and retain their old order', () {
      final legacy = [
        edit('z', 3, 'z'),
        edit('b', 1, 'b', author: 'other'),
        edit('a', 1, 'a'),
      ];
      expect(orderAuthorHistory(legacy).map((e) => e.id), ['a', 'b', 'z']);
      expect(orderAuthorHistory(legacy.reversed).map((e) => e.id), [
        'a',
        'b',
        'z',
      ]);
      expect((RoomDocument()..merge(legacy)).history.map((e) => e.id), [
        'a',
        'b',
        'z',
      ]);
    });

    test('identical duplicates dedupe before validating complete closure', () {
      final first = sequenced('first', 10, 1);
      final second = sequenced('second', 1, 2, previous: first.id);
      expect(orderAuthorHistory([second, first, first, second]), [
        first,
        second,
      ]);
      final changed = second.withAuthorProof(
        authorSequence: 3,
        authorPrevious: first.id,
      );
      expect(
        () => validateAuthorHistory([first, second, changed]),
        throwsFormatException,
      );
      expect(
        () => decodeRoomHistory([second.toJson(), changed.toJson()]),
        throwsFormatException,
      );
    });

    test('missing prefixes, holes and cross-author links are rejected', () {
      final first = sequenced('first', 10, 1);
      final invalid = <List<RoomEdit>>[
        [sequenced('second', 1, 2, previous: 'missing')],
        [first, sequenced('second', 1, 2, previous: 'missing')],
        [first, sequenced('third', 1, 3, previous: first.id)],
        [first, sequenced('second', 1, 2, previous: first.id, author: 'other')],
        [
          edit('legacy', 1, 'old'),
          sequenced('second', 2, 2, previous: 'legacy'),
        ],
        [first, sequenced('self', 1, 2, previous: 'self')],
      ];
      for (var i = 0; i < invalid.length; i++) {
        expect(
          () => validateAuthorHistory(invalid[i]),
          throwsFormatException,
          reason: 'case $i',
        );
      }
      expect(
        () => validateAuthorHistory(invalid[3], requireComplete: false),
        throwsFormatException,
      );
    });

    test('same-author sequence and predecessor forks are rejected', () {
      final first = sequenced('first', 10, 1);
      final second = sequenced('second', 1, 2, previous: first.id);
      final forked = <List<RoomEdit>>[
        [first, sequenced('other-first', 20, 1)],
        [first, second, sequenced('other-second', 2, 2, previous: first.id)],
        [first, second, sequenced('wrong-next', 3, 3, previous: first.id)],
        [
          sequenced('orphan-a', 1, 4, previous: 'missing'),
          sequenced('orphan-b', 2, 5, previous: 'missing'),
        ],
      ];
      for (final history in forked) {
        expect(() => validateAuthorHistory(history), throwsFormatException);
        expect(
          () => validateAuthorHistory(history, requireComplete: false),
          throwsFormatException,
        );
      }
    });

    test('first proof seals exactly every legacy edit of its own author', () {
      final oldA = edit('old-a', 100, 'old-a');
      final oldZ = edit('old-z', 200, 'Семья', kind: RoomEditKind.roomName);
      final other = edit('other-old', 1, 'other', author: 'other');
      final first = sequenced('first', 2, 1, base: ['old-a', 'old-z']);
      final history = [first, oldZ, other, oldA];
      expect(orderAuthorHistory(history), [other, oldA, oldZ, first]);
      for (final invalid in <List<RoomEdit>>[
        [first, oldA, other],
        [first, oldA, oldZ, edit('late', 0, 'backdated')],
        [sequenced('missing-base', 1, 1), oldA],
        [
          sequenced('foreign-base', 1, 1, base: ['other-old']),
          other,
        ],
        [
          sequenced('proof-base', 1, 1, base: ['first']),
          first,
        ],
      ]) {
        expect(() => validateAuthorHistory(invalid), throwsFormatException);
      }
      expect(
        () => validateAuthorHistory([
          first,
          oldA,
          oldZ,
          edit('late', 0, 'backdated'),
        ], requireComplete: false),
        throwsFormatException,
      );
      expect(
        orderAuthorHistory([
          ...history,
          edit('other-late', 0, 'allowed', author: 'other'),
        ]),
        hasLength(5),
      );
    });

    test('topological priority uses clock and ID only among ready edits', () {
      final a = sequenced('a-root', 50, 1, author: 'alice');
      final a2 = sequenced('a-next', 1, 2, author: 'alice', previous: a.id);
      final b = sequenced('b-root', 2, 1, author: 'bob');
      final b2 = sequenced('b-next', 20, 2, author: 'bob', previous: b.id);
      final independent = edit('legacy', 10, 'legacy', author: 'carol');
      final history = [a2, a, independent, b2, b];
      final expected = [b, independent, b2, a, a2];
      expect(orderAuthorHistory(history), expected);
      expect(orderAuthorHistory(history.reversed), expected);
      expect((RoomDocument()..merge(history)).history, expected);
      expect((RoomDocument()..merge(history.reversed)).history, expected);
    });

    test('author journal order does not change LWW text stamps', () {
      final old = edit('old', 100, 'clock winner');
      final first = sequenced('first', 10, 1, base: [old.id]);
      final second = sequenced('second', 1, 2, previous: first.id);
      final document = RoomDocument()..merge([second, first, old]);
      expect(document.history, [old, first, second]);
      expect(document.latest, old);
      expect(document.text, 'clock winner');
    });

    test('optimistic history tolerates drafts and missing dependencies', () {
      final second = sequenced('second', 1, 2, previous: 'first');
      final draft = edit('draft', 2, 'optimistic');
      final document = RoomDocument()..merge([second, draft]);
      expect(document.history, [second, draft]);
      final first = sequenced('first', 10, 1);
      document.merge([first]);
      expect(document.history, [draft, first, second]);
      expect(
        () => validateAuthorHistory(document.history),
        throwsFormatException,
      );
    });

    test('sequencing seals sorted baseline without changing draft core', () {
      final draft = edit('new', 0, 'new');
      final oldZ = edit('old-z', 30, 'z');
      final oldA = edit('old-a', 10, 'a');
      final unrelated = edit('unrelated', 1, 'other', author: 'other');
      final first = sequenceAuthoredEdit(draft, [oldZ, unrelated, oldA, oldA]);
      expect(first.sameCoreAs(draft), isTrue);
      expect(first.authorSequence, 1);
      expect(first.authorPrevious, isNull);
      expect(first.authorBase, ['old-a', 'old-z']);
      expect(orderAuthorHistory([first, oldZ, unrelated, oldA]), [
        unrelated,
        oldA,
        oldZ,
        first,
      ]);
      final empty = sequenceAuthoredEdit(draft, []);
      expect(empty.authorBase, isEmpty);
      expect(empty.toJson().containsKey('authorPrevious'), isTrue);
    });

    test(
      'sequencing follows author head despite backward and foreign clocks',
      () {
        final first = sequenced('first', 1000, 1);
        final second = sequenced('second', 1, 2, previous: first.id);
        final other = sequenced('other', 5000, 1, author: 'other');
        final draft = edit('third', 0, 'third');
        final result = sequenceAuthoredEdit(draft, [second, other, first]);
        expect(result.authorSequence, 3);
        expect(result.authorPrevious, second.id);
        expect(result.authorBase, isNull);
        expect(result.sameCoreAs(draft), isTrue);
        expect(orderAuthorHistory([result, second, other, first]), [
          first,
          second,
          result,
          other,
        ]);
      },
    );

    test('same-ID sequencing retry returns the stored canonical proof', () {
      final draft = edit('first', 1, 'value');
      final stored = sequenceAuthoredEdit(draft, []);
      expect(identical(sequenceAuthoredEdit(draft, [stored]), stored), isTrue);
      final differentProof = draft.withAuthorProof(
        authorSequence: 2,
        authorPrevious: 'different',
      );
      expect(
        identical(sequenceAuthoredEdit(differentProof, [stored]), stored),
        isTrue,
      );
      final legacy = edit('legacy', 1, 'legacy');
      expect(identical(sequenceAuthoredEdit(legacy, [legacy]), legacy), isTrue);
      expect(
        () => sequenceAuthoredEdit(edit('first', 1, 'changed'), [stored]),
        throwsFormatException,
      );
      expect(
        () => sequenceAuthoredEdit(draft, [
          stored,
          edit('late-legacy', 0, 'late'),
        ]),
        throwsFormatException,
      );
      expect(
        () => sequenceAuthoredEdit(sequenced('supplied', 1, 1), []),
        throwsFormatException,
      );
    });

    test('sameCoreAs still compares every existing payload field', () {
      final original = edit(
        'role',
        1,
        'guest',
        kind: RoomEditKind.participantRole,
        targetActor: 'subject',
      );
      for (final change in <Map<String, dynamic>>[
        {'id': 'other'},
        {'author': 'other'},
        {'clock': 2},
        {'createdAt': 2},
        {'text': 'editor'},
        {'targetActor': 'other'},
      ]) {
        final changed = RoomEdit.fromJson({...original.toJson(), ...change})!;
        expect(original.sameCoreAs(changed), isFalse);
      }
      expect(
        edit('same', 1, 'Анна').sameCoreAs(
          edit('same', 1, 'Анна', kind: RoomEditKind.participantName),
        ),
        isFalse,
      );
    });

    test(
      'only explicit finalization replaces a draft proof, never its clock',
      () {
        final document = RoomDocument();
        final draft = document.createEdit(
          'author',
          'optimistic',
          now: DateTime.fromMillisecondsSinceEpoch(1),
        );
        document.merge([draft]);
        final finalized = sequenceAuthoredEdit(draft, []);
        expect(document.merge([finalized]), isEmpty);
        expect(identical(document.history.single, draft), isTrue);
        expect(document.finalizeAuthored(finalized), finalized);
        expect(identical(document.history.single, finalized), isTrue);
        expect(identical(document.latest, finalized), isTrue);
        expect(document.text, 'optimistic');
        expect(document.historyLength, 1);
        expect(document.finalizeAuthored(finalized), finalized);
        final next = document.createEdit(
          'author',
          'next',
          now: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        );
        expect(next.clock, draft.clock + 1);
        expect(next.createdAt, 0);
        expect(() => document.finalizeAuthored(draft), throwsFormatException);
        expect(
          () => document.finalizeAuthored(
            finalized.withAuthorProof(
              authorSequence: 2,
              authorPrevious: 'other',
            ),
          ),
          throwsFormatException,
        );
        expect(
          () => document.finalizeAuthored(sequenced('unknown', 1, 1)),
          throwsFormatException,
        );
      },
    );

    test('finalization rejects every core mutation before replacing draft', () {
      final draft = edit('draft', 1, 'value');
      final document = RoomDocument()..merge([draft]);
      final finalized = sequenceAuthoredEdit(draft, []);
      for (final change in <Map<String, dynamic>>[
        {'author': 'other'},
        {'clock': 2},
        {'createdAt': 2},
        {'text': 'changed'},
        {'kind': 'participantName'},
      ]) {
        final changed = RoomEdit.fromJson({...finalized.toJson(), ...change})!;
        expect(() => document.finalizeAuthored(changed), throwsFormatException);
        expect(identical(document.history.single, draft), isTrue);
      }
    });

    test(
      'metadata and role finalization leave all projection values intact',
      () {
        for (final kind in [
          RoomEditKind.participantName,
          RoomEditKind.roomName,
          RoomEditKind.participantRole,
        ]) {
          final document = RoomDocument();
          final draft = document.createEdit(
            'author',
            kind == RoomEditKind.participantRole ? 'guest' : 'Семья',
            kind: kind,
            targetActor: kind == RoomEditKind.participantRole
                ? 'subject'
                : null,
            now: DateTime.fromMillisecondsSinceEpoch(10, isUtc: true),
          );
          document.merge([draft]);
          final names = document.participantNames;
          final roles = document.participantRoles;
          final roomName = document.roomName;
          document.finalizeAuthored(sequenceAuthoredEdit(draft, []));
          expect(document.participantNames, names);
          expect(document.participantRoles, roles);
          expect(document.roomName, roomName);
          expect(document.latest, isNull);
          expect(document.text, isEmpty);
          expect(document.history.single.sameCoreAs(draft), isTrue);
        }
      },
    );

    test(
      'createdAt stores the UTC instant independently of clock ordering',
      () {
        final document = RoomDocument()
          ..merge([edit('remote', 100000, 'remote')]);
        final instant = DateTime.parse('1970-01-01T03:00:00.001+03:00');
        final draft = document.createEdit('author', 'local', now: instant);
        expect(draft.createdAt, instant.toUtc().millisecondsSinceEpoch);
        expect(draft.createdAt, 1);
        expect(draft.clock, 100001);
        expect(draft.authorSequence, isNull);
      },
    );
  });

  test('invalid wire records are rejected', () {
    for (final value in [
      null,
      {},
      {'id': 'x'},
      {...edit('a', 1, 'text').toJson(), 'clock': -1},
      {...edit('a', 1, 'text').toJson(), 'text': 1},
    ]) {
      expect(RoomEdit.fromJson(value), isNull);
    }
  });
}
