import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/tree/tree_document.dart';

const root = rootTreePersonId;
const png =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN0kAAAAASUVORK5CYII=';

class _Client {
  _Client(this.author, [Iterable<StampedTreeOperation> events = const []]) {
    receive(events);
  }

  final String author;
  final doc = TreeDocument();
  final events = <StampedTreeOperation>[];
  var clock = 0;
  var serial = 0;

  StampedTreeOperation commit(TreeOperation? operation) {
    if (operation == null) throw StateError('Expected a nonempty edit');
    final event = StampedTreeOperation(
      id: '$author-${serial++}',
      author: author,
      clock: ++clock,
      createdAt: DateTime.utc(2026, 1, 1),
      operation: operation,
    );
    events.add(event);
    doc.merge([event]);
    return event;
  }

  void receive(Iterable<StampedTreeOperation> incoming) {
    final values = incoming.toList();
    for (final value in values) {
      clock = max(clock, value.clock);
    }
    doc.merge(values);
  }

  void name(String value, {TreeTextSnapshot? base}) =>
      commit(doc.editText(root, TreeTextField.name, value, base: base));
}

// Historical wire records remain decodable; new commands cannot emit them.
TreeOperation _legacyFamilySurname(
  TreeDocument document,
  String personId, {
  required String? text,
  bool decline = false,
}) => TreeOperation.fromJson({
  'type': 'setSurname',
  'personId': personId,
  'scope': 'family',
  'familyKey': document.surnameFamilyKey(personId),
  'text': text,
  'decline': text != null && decline,
});

List<Object?> _projection(TreeDocument doc) => [
  for (final person in doc.people.values)
    {
      'id': person.id,
      'name': person.name,
      'biography': person.biography,
      'sex': person.sex.name,
      'birth': person.birthDate?.toIso8601String(),
      'death': person.deathDate?.toIso8601String(),
      'father': person.fatherId,
      'mother': person.motherId,
      'avatar': person.avatarPhotoId,
      'familySurname': person.familySurname,
      'individualSurname': person.individualSurname,
      'maidenSurname': person.maidenSurname,
      'effectiveSurname': person.effectiveSurname,
      'surnameInheritedFrom': person.surnameInheritedFrom,
      'surname': person.surname,
      'fullName': person.fullName,
      'patronymic': person.patronymic,
      'fullNameWithPatronymic': person.fullNameWithPatronymic,
      'lifeYears': person.lifeYears,
      'facts': [
        for (final fact in person.facts) [fact.id, fact.text, fact.color],
      ],
      'photos': [
        for (final photo in person.photos)
          [photo.id, photo.dataUrl, photo.caption],
      ],
    },
  doc.bindings,
  doc.patronymicOverrides,
  doc.siblingGroupIds,
  [
    for (final link in doc.directSiblingLinks)
      [link.id, link.personId, link.siblingId],
  ],
];

void _converges(
  Iterable<StampedTreeOperation> events, {
  TreeDocument? expected,
}) {
  final all = events.toList();
  final reference = expected ?? (TreeDocument()..merge(all));
  for (var seed = 0; seed < 12; seed++) {
    final replay = [...all, ...all]..shuffle(Random(seed));
    final doc = TreeDocument();
    for (final event in replay) {
      doc.merge([event]);
    }
    expect(
      _projection(doc),
      _projection(reference),
      reason: 'Replay seed $seed',
    );
    expect(doc.merge(all), isFalse);
  }
}

void main() {
  group('domain and serialization', () {
    test('empty root is virtual, stable, immutable and needs no writes', () {
      final doc = TreeDocument();
      expect(doc.people.keys, [root]);
      final person = doc.person(root)!;
      expect(person.name, '');
      expect(person.displayName, 'Без имени');
      expect(person.sex, TreeSex.unknown);
      expect(person.facts, isEmpty);
      expect(doc.bindings, isEmpty);
      expect(doc.person('missing'), isNull);
      expect(doc.merge([]), isFalse);
      expect(() => doc.people.clear(), throwsUnsupportedError);
      expect(() => doc.bindings.clear(), throwsUnsupportedError);
      expect(() => person.facts.clear(), throwsUnsupportedError);
      expect(() => person.photos.clear(), throwsUnsupportedError);
    });

    test(
      'commands do not mutate document and operations round trip deeply immutable',
      () {
        final client = _Client('alice');
        final op = client.doc.editText(
          root,
          TreeTextField.name,
          'Ирина 🧑‍🌾',
        )!;
        expect(client.doc.person(root)!.name, '');
        final json = jsonDecode(jsonEncode(op.toJson()));
        final copy = TreeOperation.fromJson(json);
        expect(copy.toJson(), op.toJson());
        expect(copy.personId, root);
        expect(copy.fieldKey, 'name');
        expect(copy.description, 'Изменено имя');
        (json['inserts'] as List).clear();
        expect(copy.toJson()['inserts'], isNotEmpty);
        expect(() => copy.toJson().clear(), throwsUnsupportedError);
        expect(
          () => (copy.toJson()['inserts'] as List).clear(),
          throwsUnsupportedError,
        );
        expect(
          () => ((copy.toJson()['inserts'] as List).first as Map).clear(),
          throwsUnsupportedError,
        );
        final event = client.commit(copy);
        final restored = StampedTreeOperation.fromJson(
          jsonDecode(jsonEncode(event.toJson())),
        );
        expect(restored.toJson(), event.toJson());
        expect(client.doc.person(root)!.name, 'Ирина 🧑‍🌾');
        expect(TreeOperation.isValid(copy.toJson()), isTrue);
        expect(() => client.doc.createPerson(root), throwsArgumentError);
      },
    );

    test(
      'rejects malformed operations with FormatException, not cast errors',
      () {
        final valid = TreeDocument()
            .editText(root, TreeTextField.name, 'x')!
            .toJson();
        final malformed = <Object?>[
          null,
          [],
          'no',
          {1: 'no'},
          {},
          {'type': 'unknown', 'personId': root},
          {'type': 'deletePerson'},
          {'type': 'deletePerson', 'personId': ''},
          {'type': 'deletePerson', 'personId': root, 'extra': true},
          {...valid, 'extra': 1},
          {...valid, 'personId': ''},
          {...valid, 'field': 'caption'},
          {...valid, 'itemId': 'unwanted'},
          {...valid, 'inserts': null},
          {
            ...valid,
            'deletes': [1],
          },
          {...valid, 'deletes': [], 'inserts': []},
          {
            ...valid,
            'inserts': [
              {'id': 'x', 'text': 'ab', 'left': null, 'right': null},
            ],
          },
          {
            ...valid,
            'inserts': [
              {'id': 'x', 'text': 'x', 'left': 'x', 'right': null},
            ],
          },
          {
            ...valid,
            'inserts': [
              {'id': 'x', 'text': '\ud800', 'left': null, 'right': null},
            ],
          },
          {'type': 'bindActor', 'personId': root, 'actorId': ''},
          {'type': 'unbindActor', 'personId': root, 'actorId': 'alice'},
          {
            'type': 'unbindActor',
            'personId': root,
            'actorId': '',
            'bindingId': 'claim',
          },
          {
            'type': 'unbindActor',
            'personId': root,
            'actorId': 'alice',
            'bindingId': '',
          },
          {
            'type': 'unbindActor',
            'personId': root,
            'actorId': 'alice',
            'bindingId': 'x' * 129,
          },
          {'type': 'setValue', 'personId': root, 'field': 'sex', 'value': null},
          {
            'type': 'setValue',
            'personId': root,
            'field': 'name',
            'value': 'not LWW',
          },
          {
            'type': 'setValue',
            'personId': root,
            'field': 'birthDate',
            'value': '2023-02-29',
          },
          {
            'type': 'setValue',
            'personId': root,
            'field': 'birthDate',
            'value': 3,
          },
        ];
        for (final value in malformed) {
          expect(
            () => TreeOperation.fromJson(value),
            throwsFormatException,
            reason: '$value',
          );
          expect(TreeOperation.isValid(value), isFalse);
        }
        expect(
          () => TreeDocument().editText(
            root,
            TreeTextField.name,
            'x' * (maxTreeTextLength + 1),
          ),
          throwsFormatException,
        );
        expect(() => StampedTreeOperation.fromJson({}), throwsFormatException);
      },
    );

    test(
      'immutable stamp collisions reject the entire batch, equivalent JSON skips replay',
      () {
        final client = _Client('alice');
        final original = client.commit(
          client.doc.setValue(root, 'sex', 'female'),
        );
        final equivalent = StampedTreeOperation.fromJson(
          jsonDecode(jsonEncode(original.toJson())),
        );
        expect(client.doc.merge([equivalent]), isFalse);
        final different = StampedTreeOperation(
          id: original.id,
          author: original.author,
          clock: original.clock,
          createdAt: original.createdAt,
          operation: client.doc.setValue(root, 'sex', 'male'),
        );
        final newEvent = StampedTreeOperation(
          id: 'new',
          author: 'alice',
          clock: original.clock + 1,
          createdAt: original.createdAt,
          operation: client.doc.setValue(root, 'birthDate', '2000-01-01'),
        );
        final deletion = StampedTreeOperation(
          id: 'delete',
          author: 'alice',
          clock: original.clock + 2,
          createdAt: original.createdAt,
          operation: client.doc.deletePerson(root),
        );
        expect(
          () => client.doc.merge([newEvent, deletion, different]),
          throwsStateError,
        );
        expect(client.doc.person(root)!.sex, TreeSex.female);
        expect(client.doc.person(root)!.birthDate, isNull);
        expect(
          client.doc.merge([newEvent]),
          isTrue,
          reason: 'The rejected batch retained no hidden events',
        );
        expect(client.doc.person(root)!.birthDate, DateTime.utc(2000));
        expect(client.doc.merge([deletion]), isTrue);
        expect(client.doc.people, isEmpty);
      },
    );

    test(
      'independent atomic fields, strict dates, clearing and total LWW order',
      () {
        final a = _Client('alice');
        final b = _Client('bob');
        a.commit(a.doc.setValue(root, 'sex', TreeSex.female));
        a.commit(a.doc.setValue(root, 'birthDate', '2000-02-29'));
        b.commit(b.doc.setValue(root, 'deathDate', '2090-01-02'));
        final events = [...a.events, ...b.events];
        final doc = TreeDocument()..merge(events);
        expect(doc.person(root)!.sex, TreeSex.female);
        expect(doc.person(root)!.birthDate, DateTime.utc(2000, 2, 29));
        expect(doc.person(root)!.deathDate, DateTime.utc(2090, 1, 2));
        _converges(events);
        a.receive(b.events);
        a.commit(a.doc.setValue(root, 'birthDate', null));
        expect(a.doc.person(root)!.birthDate, isNull);
        for (final date in [
          '2000-2-29',
          '2023-02-29',
          '2024-04-31',
          '0000-01-01',
          '2024-01-01T00:00:00Z',
        ]) {
          expect(
            () => a.doc.setValue(root, 'birthDate', date),
            throwsFormatException,
          );
        }
        final left = StampedTreeOperation(
          id: 'a',
          author: 'same',
          clock: 50,
          createdAt: DateTime.utc(2099),
          operation: a.doc.setValue(root, 'sex', 'male'),
        );
        final right = StampedTreeOperation(
          id: 'b',
          author: 'same',
          clock: 50,
          createdAt: DateTime.utc(1900),
          operation: a.doc.setValue(root, 'sex', 'female'),
        );
        a.doc.merge([right, left]);
        expect(
          a.doc.person(root)!.sex,
          TreeSex.female,
          reason: 'ID, not wall time, breaks the tie',
        );
      },
    );
  });

  group('canonical surnames', () {
    test('literal forms, value equality, full names and life years', () {
      const surname = TreeSurname(text: 'Иванов', decline: true);
      expect(surname, const TreeSurname(text: 'Иванов', decline: true));
      expect(
        surname.hashCode,
        const TreeSurname(text: 'Иванов', decline: true).hashCode,
      );
      expect(surname, isNot(const TreeSurname(text: 'Иванов')));
      expect(surname.formForSex(TreeSex.male), 'Иванов');
      expect(surname.formForSex(TreeSex.unknown), 'Иванов');
      expect(surname.formForSex(TreeSex.female), 'Иванова');
      expect(surname.plural, 'Ивановы');
      expect(surname.text, 'Иванов');
      expect(const TreeSurname(text: 'Ли').formForSex(TreeSex.female), 'Ли');
      expect(const TreeSurname(text: 'Ли').plural, 'Ли');
      expect(const TreeSurname(text: 'А', decline: true).plural, 'Аы');
      final person = TreePerson(
        id: 'person',
        name: '  Анна Ивановна  ',
        sex: TreeSex.female,
        familySurname: surname,
        birthDate: DateTime.utc(1980),
      );
      expect(person.name, '  Анна Ивановна  ');
      expect(person.surname, 'Иванова');
      expect(person.fullName, 'Анна Ивановна Иванова');
      expect(person.lifeYears, '1980–н.в');
      expect(TreePerson(id: 'empty').fullName, 'Без имени');
      expect(TreePerson(id: 'empty').lifeYears, '?–?');
      expect(
        TreePerson(id: 'dead', deathDate: DateTime.utc(2020)).lifeYears,
        '?–2020',
      );
      expect(
        TreePerson(
          id: 'dead',
          birthDate: DateTime.utc(1900),
          deathDate: DateTime.utc(1980),
        ).lifeYears,
        '1900–1980',
      );
      expect(
        TreePerson(
          id: 'living',
          birthDate: DateTime.utc(1980),
          alive: false,
        ).lifeYears,
        '1980–?',
      );
      expect(TreePerson(id: 'living', alive: true).lifeYears, '?–н.в');
      expect(
        TreePerson(
          id: 'dated',
          birthDate: DateTime.utc(1980),
          deathDate: DateTime.utc(2000),
          alive: true,
        ).lifeYears,
        '1980–2000',
      );
    });

    test(
      'alive is an explicit nullable register distinct from a death date',
      () {
        final client = _Client('alice');
        expect(
          () => client.doc.setValue(root, 'alive', 'yes'),
          throwsFormatException,
        );
        expect(
          client.doc.setValue(root, 'alive', true).description,
          'Отмечен как живой',
        );
        expect(
          client.doc.setValue(root, 'alive', false).description,
          'Дата смерти неизвестна',
        );
        expect(
          client.doc.setValue(root, 'alive', null).description,
          'Сброшена отметка о жизни',
        );
        client.commit(client.doc.setValue(root, 'birthDate', '1980-01-01'));
        expect(client.doc.person(root)!.alive, isNull);
        expect(client.doc.person(root)!.lifeYears, '1980–н.в');
        client.commit(client.doc.setValue(root, 'alive', false));
        expect(client.doc.person(root)!.alive, isFalse);
        expect(client.doc.person(root)!.lifeYears, '1980–?');
        client.commit(client.doc.setValue(root, 'deathDate', '2001-02-03'));
        expect(client.doc.person(root)!.lifeYears, '1980–2001');
        client.commit(client.doc.setValue(root, 'alive', null));
        client.commit(client.doc.setValue(root, 'deathDate', null));
        expect(client.doc.person(root)!.alive, isNull);
        expect(client.doc.person(root)!.lifeYears, '1980–н.в');
        _converges(client.events);
      },
    );

    test('full names preserve given text and put unnamed fallback first', () {
      const name = ' \tАнна  Ивановна\t ';
      const surname = TreeSurname(text: 'Иванов', decline: true);
      for (final (sex, renderedSurname) in [
        (TreeSex.unknown, 'Иванов'),
        (TreeSex.male, 'Иванов'),
        (TreeSex.female, 'Иванова'),
      ]) {
        final person = TreePerson(
          id: sex.name,
          name: name,
          sex: sex,
          familySurname: surname,
        );
        expect(person.fullName, 'Анна  Ивановна $renderedSurname');
        expect(person.name, name);
        expect(person.displayName, name);
        expect(person.familySurname, surname);
      }
      expect(
        TreePerson(id: 'given-only', name: name).fullName,
        'Анна  Ивановна',
      );
      for (final blank in ['', ' \t\n ']) {
        final person = TreePerson(
          id: 'unnamed',
          name: blank,
          sex: TreeSex.female,
          familySurname: surname,
        );
        expect(person.fullName, 'Без имени Иванова');
        expect(person.name, blank);
        expect(person.displayName, 'Без имени');
        expect(TreePerson(id: 'empty', name: blank).fullName, 'Без имени');
      }
    });

    test(
      'name-first projection round trips without changing stored fields',
      () {
        const name = '  Анна  Ивановна  ';
        const surname = TreeSurname(text: 'Иванов', decline: true);
        final client = _Client('alice')..name(name);
        client.commit(client.doc.setValue(root, 'sex', TreeSex.female));
        client.commit(
          client.doc.setIndividualSurname(
            root,
            text: surname.text,
            decline: true,
          ),
        );
        final encoded = jsonEncode([
          for (final event in client.events) event.toJson(),
        ]);
        final restoredEvents = [
          for (final json in jsonDecode(encoded) as List)
            StampedTreeOperation.fromJson(json),
        ];
        expect(
          restoredEvents.map((event) => event.toJson()),
          client.events.map((event) => event.toJson()),
        );
        final restored = TreeDocument()..merge(restoredEvents);
        for (final document in [client.doc, restored]) {
          final person = document.person(root)!;
          expect(person.name, name);
          expect(document.textSnapshot(root, TreeTextField.name).text, name);
          expect(person.familySurname, isNull);
          expect(person.individualSurname, surname);
          expect(person.effectiveSurname, surname);
          expect(person.surname, 'Иванова');
          expect(person.fullName, 'Анна  Ивановна Иванова');
        }
        expect(_projection(restored), _projection(client.doc));
      },
    );

    test('strict atomic surname schema, normalized clears and rune limit', () {
      final client = _Client('alice');
      final family = _legacyFamilySurname(
        client.doc,
        root,
        text: 'Иванов',
        decline: true,
      );
      expect(family.toJson(), {
        'type': 'setSurname',
        'personId': root,
        'scope': 'family',
        'familyKey': 'person:4:root',
        'text': 'Иванов',
        'decline': true,
      });
      expect(client.doc.person(root)!.effectiveSurname, isNull);
      expect(family.fieldKey, 'surname:family:person:4:root');
      expect(family.description, 'Изменена семейная фамилия');
      final personal = client.doc.setIndividualSurname(
        root,
        text: '  Петров  ',
      );
      expect(personal.toJson()['text'], 'Петров');
      expect(personal.toJson()['familyKey'], isNull);
      // ignore: deprecated_member_use_from_same_package
      final alias = client.doc.setFamilySurname(root, text: 'Петров');
      expect(alias.toJson(), personal.toJson());
      final maiden = client.doc.setMaidenSurname(root, text: 'Сидоров');
      expect(personal.fieldKey, 'surname:individual');
      expect(maiden.fieldKey, 'surname:maiden');
      expect(personal.description, 'Изменена личная фамилия');
      expect(maiden.description, 'Изменена девичья фамилия');
      for (final op in [family, personal, maiden]) {
        expect(
          TreeOperation.fromJson(jsonDecode(jsonEncode(op.toJson()))).toJson(),
          op.toJson(),
        );
        expect(() => op.toJson().clear(), throwsUnsupportedError);
      }
      for (final text in [null, '', ' \t\n ']) {
        final clear = client.doc.setIndividualSurname(
          root,
          text: text,
          decline: true,
        );
        expect(clear.toJson()['text'], isNull);
        expect(clear.toJson()['decline'], isFalse);
      }
      final valid = personal.toJson();
      for (final invalid in <Map<String, Object?>>[
        {...valid, 'scope': 'unknown'},
        {...valid, 'familyKey': 'person:4:root'},
        {...family.toJson(), 'familyKey': null},
        {...family.toJson(), 'familyKey': 'person:5:other'},
        {...family.toJson(), 'familyKey': 'parents:01:a:1:b'},
        {...family.toJson(), 'familyKey': 'parents:2:a:1:b'},
        {...family.toJson(), 'familyKey': 'parents:1:a:1:b:extra'},
        {...family.toJson(), 'familyKey': 'parents:1:\ud800:1:b'},
        {...valid, 'text': ''},
        {...valid, 'text': ' '},
        {...valid, 'text': ' untrimmed'},
        {...valid, 'text': '\ud800'},
        {...valid, 'text': 'a\nb'},
        {...valid, 'text': 'a' * (maxTreeSurnameLength + 1)},
        {...valid, 'text': 1},
        {...valid, 'decline': 'true'},
        {...valid, 'decline': null},
        {...valid, 'text': null, 'decline': true},
        {...valid, 'extra': false},
        {...valid}..remove('familyKey'),
      ]) {
        expect(
          () => TreeOperation.fromJson(invalid),
          throwsFormatException,
          reason: '$invalid',
        );
        expect(TreeOperation.isValid(invalid), isFalse);
      }
      final astral = '🌳' * maxTreeSurnameLength;
      client.commit(client.doc.setIndividualSurname(root, text: astral));
      expect(client.doc.person(root)!.surname, astral);
      expect(
        () => client.doc.setIndividualSurname(root, text: '$astral🌳'),
        throwsFormatException,
      );
      expect(
        () => client.doc.setIndividualSurname('missing', text: 'x'),
        throwsArgumentError,
      );
    });

    test(
      'personal edits affect one person and paternal descendants, never siblings',
      () {
        final client = _Client('alice');
        for (final id in ['father', 'mother', 'sibling', 'child', 'new']) {
          client.commit(client.doc.createPerson(id));
        }
        for (final id in [root, 'sibling']) {
          client.commit(client.doc.setValue(id, 'fatherId', 'father'));
          client.commit(client.doc.setValue(id, 'motherId', 'mother'));
        }
        client.commit(client.doc.setValue('child', 'fatherId', root));
        client.commit(
          client.doc.setIndividualSurname('father', text: 'Отцовская'),
        );
        final before = client.events.length;
        final event = client.commit(
          client.doc.setIndividualSurname(root, text: 'Иванов', decline: true),
        );
        expect(client.events.length, before + 1);
        expect(event.operation.toJson()['scope'], 'individual');
        expect(event.operation.toJson()['familyKey'], isNull);
        expect(
          client.doc.surnameFamilyKey(root),
          treeSurnameFamilyKey(client.doc.person('sibling')!),
        );
        expect(client.doc.person(root)!.surname, 'Иванов');
        expect(client.doc.person('child')!.surname, 'Иванов');
        expect(client.doc.person('child')!.surnameInheritedFrom, root);
        expect(client.doc.person('sibling')!.surname, 'Отцовская');
        client.commit(client.doc.setValue('new', 'fatherId', 'father'));
        client.commit(client.doc.setValue('new', 'motherId', 'mother'));
        expect(client.doc.person('new')!.surname, 'Отцовская');
        client.commit(
          client.doc.setIndividualSurname('sibling', text: 'Петров'),
        );
        expect(client.doc.person('sibling')!.surname, 'Петров');
        expect(client.doc.person(root)!.surname, 'Иванов');
        expect(client.doc.person('child')!.surname, 'Иванов');
        client.commit(client.doc.setIndividualSurname(root, text: null));
        expect(client.doc.person(root)!.surname, 'Отцовская');
        expect(client.doc.person('child')!.surname, 'Отцовская');
        expect(client.doc.person('sibling')!.surname, 'Петров');
        expect(
          client.events.where(
            (event) =>
                event.operation.type == 'setSurname' &&
                event.operation.toJson()['scope'] == 'family',
          ),
          isEmpty,
        );
        _converges(client.events);
      },
    );

    test('untouched legacy family values stay readable without migration', () {
      final client = _Client('alice');
      for (final id in [
        'father',
        'mother',
        'sibling',
        'half',
        'reversed',
        'new',
      ]) {
        client.commit(client.doc.createPerson(id));
      }
      for (final id in [root, 'sibling']) {
        client.commit(client.doc.setValue(id, 'fatherId', 'father'));
        client.commit(client.doc.setValue(id, 'motherId', 'mother'));
      }
      client.commit(client.doc.setValue('half', 'fatherId', 'father'));
      client.commit(client.doc.setValue('reversed', 'fatherId', 'mother'));
      client.commit(client.doc.setValue('reversed', 'motherId', 'father'));
      final legacy = client.commit(
        _legacyFamilySurname(client.doc, root, text: 'Иванов', decline: true),
      );
      final original = jsonEncode(legacy.toJson());
      for (final id in [root, 'sibling']) {
        expect(
          client.doc.person(id)!.familySurname,
          const TreeSurname(text: 'Иванов', decline: true),
        );
      }
      for (final id in ['father', 'mother', 'half', 'reversed', 'new']) {
        expect(client.doc.person(id)!.familySurname, isNull);
      }
      client.commit(client.doc.setValue('new', 'fatherId', 'father'));
      client.commit(client.doc.setValue('new', 'motherId', 'mother'));
      expect(client.doc.person('new')!.surname, 'Иванов');
      client.commit(client.doc.setIndividualSurname(root, text: 'Личная'));
      expect(client.doc.person(root)!.familySurname, isNull);
      expect(client.doc.person('sibling')!.surname, 'Иванов');
      expect(client.doc.person('new')!.surname, 'Иванов');
      expect(jsonEncode(legacy.toJson()), original);
      _converges(client.events);
    });

    test(
      'family key preserves role, colons, astral IDs and maximum ID lengths',
      () {
        final client = _Client('alice');
        final father = '${'a' * 254}:a';
        final mother = '${'b' * 254}🌳';
        for (final id in [father, mother]) {
          client.commit(client.doc.createPerson(id));
        }
        client.commit(client.doc.setValue(root, 'fatherId', father));
        client.commit(client.doc.setValue(root, 'motherId', mother));
        final operation = _legacyFamilySurname(
          client.doc,
          root,
          text: 'Длинные ключи',
        );
        expect((operation.toJson()['familyKey']! as String).length, 529);
        client.commit(operation);
        expect(client.doc.person(root)!.surname, 'Длинные ключи');
        _converges(client.events);
      },
    );

    test(
      'personal, legacy fallback, inherited base and independent maiden',
      () {
        final client = _Client('alice');
        for (final id in ['grandfather', 'father', 'mother', 'child']) {
          client.commit(client.doc.createPerson(id, sex: TreeSex.female));
        }
        client.commit(client.doc.setValue('father', 'fatherId', 'grandfather'));
        client.commit(client.doc.setValue(root, 'fatherId', 'father'));
        client.commit(client.doc.setValue(root, 'motherId', 'mother'));
        client.commit(client.doc.setValue(root, 'sex', TreeSex.female));
        client.commit(client.doc.setValue('child', 'fatherId', root));
        client.commit(
          client.doc.setIndividualSurname('mother', text: 'Материнская'),
        );
        client.commit(
          client.doc.setIndividualSurname(
            'grandfather',
            text: 'Иванов',
            decline: true,
          ),
        );
        for (final id in ['father', root, 'child']) {
          final person = client.doc.person(id)!;
          // This test concerns birth inheritance. A female co-parent can now
          // have a different current surname through an implied marriage.
          expect(person.effectiveSurname?.formForSex(person.sex), 'Иванова');
          expect(person.effectiveSurname!.text, 'Иванов');
          expect(person.familySurname, isNull);
          expect(person.surnameInheritedFrom, person.fatherId);
        }
        client.commit(
          _legacyFamilySurname(client.doc, root, text: 'Петров', decline: true),
        );
        expect(client.doc.person(root)!.surnameInheritedFrom, isNull);
        expect(client.doc.person('child')!.surname, 'Петрова');
        client.commit(client.doc.setIndividualSurname(root, text: 'Ли'));
        client.commit(
          client.doc.setMaidenSurname(root, text: 'Сидоров', decline: true),
        );
        expect(client.doc.person(root)!.surname, 'Ли');
        expect(client.doc.person('child')!.surname, 'Ли');
        expect(
          client.doc.person(root)!.maidenSurname,
          const TreeSurname(text: 'Сидоров', decline: true),
        );
        client.commit(client.doc.setIndividualSurname(root, text: '  '));
        expect(client.doc.person(root)!.familySurname, isNull);
        expect(client.doc.person(root)!.surname, 'Иванова');
        expect(client.doc.person(root)!.surnameInheritedFrom, 'father');
        expect(client.doc.person(root)!.maidenSurname, isNotNull);
        client.commit(client.doc.setMaidenSurname(root, text: null));
        client.commit(client.doc.setValue(root, 'fatherId', null));
        expect(client.doc.person(root)!.surname, '');
        expect(client.doc.person(root)!.surnameInheritedFrom, isNull);
        expect(client.doc.person('child')!.effectiveSurname, isNull);
        _converges(client.events);
      },
    );

    test(
      'frozen targets survive moves and representative deletion without retargeting',
      () {
        final client = _Client('alice');
        for (final id in ['father', 'mother', 'other', 'sibling']) {
          client.commit(client.doc.createPerson(id));
        }
        for (final id in [root, 'sibling']) {
          client.commit(client.doc.setValue(id, 'fatherId', 'father'));
          client.commit(client.doc.setValue(id, 'motherId', 'mother'));
        }
        final delayed = _legacyFamilySurname(
          client.doc,
          root,
          text: 'Старая семья',
        );
        client.commit(client.doc.setIndividualSurname(root, text: 'Личная'));
        client.commit(client.doc.setValue(root, 'motherId', 'other'));
        client.commit(delayed);
        expect(client.doc.person(root)!.familySurname, isNull);
        expect(client.doc.person(root)!.surname, 'Личная');
        expect(client.doc.person('sibling')!.surname, 'Старая семья');
        client.commit(client.doc.setValue('sibling', 'motherId', 'other'));
        expect(client.doc.person('sibling')!.effectiveSurname, isNull);
        client.commit(client.doc.setValue('sibling', 'motherId', 'mother'));
        expect(client.doc.person('sibling')!.surname, 'Старая семья');
        client.commit(client.doc.setValue(root, 'motherId', 'mother'));
        expect(client.doc.person(root)!.familySurname, isNull);
        expect(client.doc.person(root)!.surname, 'Личная');
        final late = _legacyFamilySurname(
          client.doc,
          root,
          text: 'После удаления',
        );
        client.commit(client.doc.deletePerson(root));
        client.commit(late);
        expect(client.doc.person(root), isNull);
        expect(client.doc.person('sibling')!.surname, 'После удаления');
        expect(() => client.doc.createPerson(root), throwsArgumentError);
        // A family register is independent of whether its original editing
        // identity has arrived yet. Local session commands still require it.
        client.commit(
          TreeOperation.fromJson({
            ...late.toJson(),
            'personId': 'not-created-yet',
            'text': 'Независимый регистр',
          }),
        );
        expect(client.doc.person('not-created-yet'), isNull);
        expect(client.doc.person('sibling')!.surname, 'Независимый регистр');
        client.commit(client.doc.deletePerson('father'));
        expect(client.doc.person('sibling')!.familySurname, isNull);
        expect(client.doc.person('sibling')!.effectiveSurname, isNull);
        _converges(client.events);
      },
    );

    for (final clearFirst in [false, true]) {
      test(
        'personal null suppresses legacy fallback, clear first: $clearFirst',
        () {
          final client = _Client('alice');
          for (final id in ['father', 'mother', 'other', 'sibling', 'child']) {
            client.commit(client.doc.createPerson(id));
          }
          for (final id in [root, 'sibling']) {
            client.commit(client.doc.setValue(id, 'fatherId', 'father'));
            client.commit(client.doc.setValue(id, 'motherId', 'mother'));
          }
          client.commit(client.doc.setValue('child', 'fatherId', root));
          client.commit(
            client.doc.setIndividualSurname(
              'father',
              text: 'Иванов',
              decline: true,
            ),
          );
          client.commit(client.doc.setValue(root, 'sex', TreeSex.female));
          final legacy = _legacyFamilySurname(client.doc, root, text: 'Старая');
          final clear = client.doc.setIndividualSurname(root, text: null);
          client.commit(clearFirst ? clear : legacy);
          client.commit(clearFirst ? legacy : clear);
          expect(client.doc.person(root)!.familySurname, isNull);
          expect(client.doc.person(root)!.individualSurname, isNull);
          expect(
            client.doc.person(root)!.effectiveSurname,
            const TreeSurname(text: 'Иванов', decline: true),
          );
          expect(client.doc.person(root)!.surname, 'Иванова');
          expect(client.doc.person(root)!.surnameInheritedFrom, 'father');
          expect(client.doc.person('child')!.surname, 'Иванов');
          expect(client.doc.person('sibling')!.surname, 'Старая');
          client.commit(
            _legacyFamilySurname(client.doc, 'sibling', text: 'Ещё старое'),
          );
          expect(client.doc.person(root)!.surname, 'Иванова');
          expect(client.doc.person('sibling')!.surname, 'Ещё старое');
          client.commit(client.doc.setIndividualSurname('other', text: 'Ли'));
          client.commit(client.doc.setValue(root, 'fatherId', 'other'));
          expect(client.doc.person(root)!.surname, 'Ли');
          client.commit(client.doc.setValue(root, 'fatherId', 'father'));
          client.commit(client.doc.deletePerson('father'));
          expect(client.doc.person(root)!.effectiveSurname, isNull);
          expect(client.doc.person(root)!.surname, isEmpty);
          expect(client.doc.person('child')!.effectiveSurname, isNull);
          _converges(client.events);
        },
      );
    }

    test('a personal clear for an unknown identity applies after creation', () {
      final client = _Client('alice');
      final legacy = _legacyFamilySurname(client.doc, root, text: 'Старая');
      client.commit(
        TreeOperation.fromJson({
          ...legacy.toJson(),
          'personId': 'later',
          'familyKey': 'person:5:later',
        }),
      );
      client.commit(
        TreeOperation.fromJson({
          ...client.doc.setIndividualSurname(root, text: null).toJson(),
          'personId': 'later',
        }),
      );
      expect(client.doc.person('later'), isNull);
      client.commit(client.doc.createPerson('later'));
      expect(client.doc.person('later')!.familySurname, isNull);
      expect(client.doc.person('later')!.effectiveSurname, isNull);
      _converges(client.events);
    });

    test(
      'concurrent per-person configs are independent, atomic and reload stable',
      () {
        final initial = _Client('initial');
        for (final id in ['father', 'mother', 'sibling', 'child']) {
          initial.commit(initial.doc.createPerson(id));
        }
        for (final id in [root, 'sibling']) {
          initial.commit(initial.doc.setValue(id, 'fatherId', 'father'));
          initial.commit(initial.doc.setValue(id, 'motherId', 'mother'));
        }
        initial.commit(initial.doc.setValue('child', 'fatherId', root));
        initial.commit(
          initial.doc.setIndividualSurname('father', text: 'Отцовская'),
        );
        initial.commit(
          _legacyFamilySurname(initial.doc, root, text: 'Семейная'),
        );
        final a = _Client('alice', initial.events);
        final b = _Client('bob', initial.events);
        a.commit(
          a.doc.setIndividualSurname(root, text: 'Иванов', decline: true),
        );
        b.commit(b.doc.setIndividualSurname('sibling', text: 'Ли'));
        a.receive(b.events);
        b.receive(a.events);
        expect(a.doc.person(root)!.surname, 'Иванов');
        expect(a.doc.person('child')!.surname, 'Иванов');
        expect(a.doc.person('sibling')!.surname, 'Ли');
        a.commit(
          a.doc.setIndividualSurname(root, text: 'Петров', decline: true),
        );
        b.commit(b.doc.setIndividualSurname(root, text: 'Сидоров'));
        b.commit(b.doc.setMaidenSurname(root, text: 'Девичья'));
        a.receive(b.events);
        expect(
          a.doc.person(root)!.effectiveSurname,
          const TreeSurname(text: 'Сидоров'),
        );
        expect(a.doc.person('child')!.surname, 'Сидоров');
        expect(a.doc.person('sibling')!.surname, 'Ли');
        expect(a.doc.person(root)!.maidenSurname!.text, 'Девичья');
        a.commit(a.doc.setIndividualSurname('sibling', text: null));
        expect(a.doc.person('sibling')!.surname, 'Отцовская');
        expect(a.doc.person(root)!.surname, 'Сидоров');
        final all = [...initial.events, ...a.events, ...b.events];
        final encoded = jsonEncode(all.map((event) => event.toJson()).toList());
        final restoredEvents = [
          for (final json in jsonDecode(encoded) as List)
            StampedTreeOperation.fromJson(json),
        ];
        final restored = TreeDocument()..merge(restoredEvents);
        expect(_projection(restored), _projection(a.doc));
        expect(
          jsonEncode(restoredEvents.map((event) => event.toJson()).toList()),
          encoded,
        );
        _converges(all, expected: a.doc);
      },
    );

    test('inheritance uses accepted cycle-filtered father edges only', () {
      final initial = _Client('initial');
      for (final id in ['a', 'b', 'c']) {
        initial.commit(initial.doc.createPerson(id, sex: TreeSex.female));
      }
      initial.commit(
        initial.doc.setIndividualSurname('a', text: 'Иванов', decline: true),
      );
      final a = _Client('alice', initial.events);
      final b = _Client('bob', initial.events);
      final c = _Client('carol', initial.events);
      a.commit(a.doc.setValue('a', 'fatherId', 'b'));
      b.commit(b.doc.setValue('b', 'fatherId', 'c'));
      c.commit(c.doc.setValue('c', 'fatherId', 'a'));
      final events = [...initial.events, ...a.events, ...b.events, ...c.events];
      final doc = TreeDocument()..merge(events);
      expect(doc.person('a')!.fatherId, isNull);
      expect(doc.person('a')!.surnameInheritedFrom, isNull);
      expect(doc.person('c')!.surnameInheritedFrom, 'a');
      expect(doc.person('b')!.surnameInheritedFrom, 'c');
      for (final id in ['a', 'b', 'c']) {
        expect(doc.person(id)!.surname, 'Иванова');
        expect(doc.person(id)!.effectiveSurname!.text, 'Иванов');
      }
      _converges(events, expected: doc);
    });

    test(
      'block renderer compares canonical configs, not female rendered forms',
      () {
        const surname = TreeSurname(text: 'Иванов', decline: true);
        final male = TreePerson(
          id: 'm',
          familySurname: surname,
          sex: TreeSex.male,
        );
        final female = TreePerson(
          id: 'f',
          familySurname: surname,
          sex: TreeSex.female,
        );
        final missing = TreePerson(id: 'none');
        expect(surnameForBlock([]), '');
        expect(surnameForBlock([missing, missing]), '');
        expect(surnameForBlock([female]), 'Иванова');
        expect(surnameForBlock([male, female]), 'Ивановы');
        expect(surnameForBlock([male, missing]), 'разные фамилии');
        expect(
          surnameForBlock([
            male,
            TreePerson(
              id: 'other',
              individualSurname: const TreeSurname(text: 'Петров'),
            ),
          ]),
          'разные фамилии',
        );
        expect(
          surnameForBlock([
            male,
            TreePerson(
              id: 'other',
              familySurname: const TreeSurname(text: 'Иванов'),
            ),
          ]),
          'разные фамилии',
        );
        expect(
          surnameForBlock([
            TreePerson(
              id: 'a',
              familySurname: const TreeSurname(text: 'Ли'),
            ),
            TreePerson(
              id: 'b',
              familySurname: const TreeSurname(text: 'Ли'),
            ),
          ]),
          'Ли',
        );
      },
    );

    test(
      'deep accepted ancestry resolves iteratively without changing base',
      () {
        const count = 12000;
        final events = <StampedTreeOperation>[];
        for (var i = 0; i < count; i++) {
          final id = 'p${i.toString().padLeft(5, '0')}';
          events.add(
            StampedTreeOperation(
              id: 'create-$i',
              author: 'alice',
              clock: i,
              createdAt: DateTime.utc(2026),
              operation: TreeDocument().createPerson(id, sex: TreeSex.female),
            ),
          );
          events.add(
            StampedTreeOperation(
              id: 'parent-$i',
              author: 'alice',
              clock: 3 * count - i,
              createdAt: DateTime.utc(2026),
              operation: TreeOperation.fromJson({
                'type': 'setValue',
                'personId': id,
                'field': 'fatherId',
                'value': i + 1 == count
                    ? root
                    : 'p${(i + 1).toString().padLeft(5, '0')}',
              }),
            ),
          );
        }
        events.add(
          StampedTreeOperation(
            id: 'surname',
            author: 'alice',
            clock: 4 * count,
            createdAt: DateTime.utc(2026),
            operation: TreeDocument().setIndividualSurname(
              root,
              text: 'Иванов',
              decline: true,
            ),
          ),
        );
        final doc = TreeDocument()..merge(events.reversed);
        expect(doc.person('p00000')!.surname, 'Иванова');
        expect(doc.person('p00000')!.effectiveSurname!.text, 'Иванов');
        expect(doc.person('p00000')!.surnameInheritedFrom, 'p00001');
        expect(doc.person('p11999')!.surnameInheritedFrom, root);
      },
    );
  });

  group('derived patronymics', () {
    test(
      'name modes preserve stored names and legacy given-name-first fullName',
      () {
        final client = _Client('alice')..name('  Анна  Ивановна  ');
        client.commit(client.doc.createPerson('z-father', name: '  ИВАН  '));
        client.commit(client.doc.setValue(root, 'sex', TreeSex.female));
        client.commit(client.doc.setValue(root, 'fatherId', 'z-father'));
        client.commit(
          client.doc.setIndividualSurname(root, text: 'Сидоров', decline: true),
        );
        final count = client.events.length;
        final encoded = jsonEncode([
          for (final event in client.events) event.toJson(),
        ]);
        final snapshot = client.doc.textSnapshot(root, TreeTextField.name);
        final person = client.doc.person(root)!;
        expect(person.patronymic, 'Ивановна');
        expect(person.fullName, 'Анна  Ивановна Сидорова');
        expect(person.nameForMode(TreeNameMode.givenSurname), person.fullName);
        expect(
          person.nameForMode(TreeNameMode.surnameGivenPatronymic),
          'Сидорова Анна  Ивановна Ивановна',
          reason: 'Historical name text is not parsed or migrated',
        );
        expect(
          person.fullNameWithPatronymic,
          'Сидорова Анна  Ивановна Ивановна',
        );
        expect(person.name, '  Анна  Ивановна  ');
        expect(snapshot.text, person.name);
        expect(client.events.length, count);
        expect(
          jsonEncode([for (final event in client.events) event.toJson()]),
          encoded,
        );
        final restoredEvents = [
          for (final json in jsonDecode(encoded) as List)
            StampedTreeOperation.fromJson(json),
        ];
        expect(
          jsonEncode([for (final event in restoredEvents) event.toJson()]),
          encoded,
        );
        final restored = TreeDocument()..merge(restoredEvents);
        expect(_projection(restored), _projection(client.doc));
        expect(
          restored.textSnapshot(root, TreeTextField.name).atomIds,
          snapshot.atomIds,
        );
        expect(
          restored.editText(root, TreeTextField.name, person.name),
          isNull,
        );
        _converges(client.events);
      },
    );

    test(
      'name modes omit missing components and retain the unnamed fallback',
      () {
        for (final blank in ['', ' \t\n ']) {
          final unnamed = TreePerson(
            id: 'unnamed',
            name: blank,
            sex: TreeSex.female,
            individualSurname: const TreeSurname(text: 'Иванов', decline: true),
          );
          expect(unnamed.fullName, 'Без имени Иванова');
          expect(unnamed.fullNameWithPatronymic, 'Иванова Без имени');
          expect(unnamed.patronymic, '');
          expect(
            TreePerson(id: 'empty', name: blank).fullNameWithPatronymic,
            'Без имени',
          );
        }
        expect(
          TreePerson(id: 'given', name: '  Анна  ').fullNameWithPatronymic,
          'Анна',
        );
        final client = _Client('alice');
        client.commit(client.doc.createPerson('father', name: 'Иван'));
        client.commit(client.doc.setValue(root, 'fatherId', 'father'));
        client.commit(client.doc.setValue(root, 'sex', TreeSex.male));
        expect(
          client.doc.person(root)!.fullNameWithPatronymic,
          'Без имени Иванович',
        );
        expect(client.doc.person(root)!.fullName, 'Без имени');
        client.commit(client.doc.setIndividualSurname(root, text: 'Петров'));
        expect(
          client.doc.person(root)!.fullNameWithPatronymic,
          'Петров Без имени Иванович',
        );
      },
    );

    test(
      'sex, father rename, relink, unlink and deletion update derived forms',
      () {
        final client = _Client('alice')..name('Анна');
        client.commit(
          client.doc.createPerson('father', name: 'Иван', sex: TreeSex.female),
        );
        client.commit(client.doc.createPerson('other', name: ' ПЁТР '));
        client.commit(client.doc.createPerson('mother', name: 'Павел'));
        client.commit(client.doc.setValue(root, 'motherId', 'mother'));
        client.commit(client.doc.setValue(root, 'fatherId', 'father'));
        expect(
          client.doc.person(root)!.patronymic,
          '',
          reason: 'Unknown child sex',
        );
        client.commit(client.doc.setValue(root, 'sex', TreeSex.male));
        expect(client.doc.person(root)!.patronymic, 'Иванович');
        client.commit(client.doc.setValue(root, 'sex', TreeSex.female));
        expect(client.doc.person(root)!.patronymic, 'Ивановна');
        final previousPerson = client.doc.person(root)!;
        final count = client.events.length;
        client.commit(client.doc.editText('father', TreeTextField.name, 'Лев'));
        expect(
          client.events.length,
          count + 1,
          reason: 'No synthetic child edits',
        );
        expect(client.doc.person(root)!.patronymic, 'Львовна');
        expect(
          previousPerson.patronymic,
          'Ивановна',
          reason: 'Immutable old snapshot',
        );
        client.commit(client.doc.setValue(root, 'fatherId', null));
        expect(
          client.doc.person(root)!.patronymic,
          '',
          reason: 'Never use mother name',
        );
        client.commit(client.doc.setValue(root, 'fatherId', 'other'));
        expect(client.doc.person(root)!.patronymic, 'Петровна');
        client.commit(client.doc.deletePerson('other'));
        expect(client.doc.person(root)!.fatherId, isNull);
        expect(client.doc.person(root)!.patronymic, '');
        client.commit(client.doc.setValue(root, 'fatherId', 'father'));
        expect(client.doc.person(root)!.patronymic, 'Львовна');
        expect(client.doc.person(root)!.name, 'Анна');
        _converges(client.events);
      },
    );

    test(
      'unsupported father names stay empty, never use own name or ancestors',
      () {
        final client = _Client('alice')..name('Иван');
        client.commit(client.doc.createPerson('grandfather', name: 'Павел'));
        client.commit(client.doc.createPerson('father', name: 'Пётр'));
        client.commit(client.doc.setValue('father', 'fatherId', 'grandfather'));
        client.commit(client.doc.setValue(root, 'sex', TreeSex.male));
        client.commit(client.doc.setValue(root, 'fatherId', 'father'));
        expect(client.doc.person('father')!.patronymic, '');
        expect(client.doc.person(root)!.patronymic, 'Петрович');
        for (final name in [
          '',
          ' \t ',
          'John',
          'Иван Иванович',
          'Иван/Пётр',
          'О',
        ]) {
          client.commit(
            client.doc.editText('father', TreeTextField.name, name),
          );
          expect(
            client.doc.person(root)!.patronymic,
            '',
            reason: 'Father name: $name',
          );
        }
        client.commit(
          client.doc.editText('father', TreeTextField.name, 'John'),
        );
        client.commit(
          client.doc.setPatronymicOverride(
            'John',
            male: 'Джонович',
            female: 'Джоновна',
          ),
        );
        expect(client.doc.person(root)!.patronymic, 'Джонович');
        _converges(client.events);
      },
    );

    test(
      'concurrent cycles use accepted father edges, not raw rejected registers',
      () {
        final initial = _Client('initial');
        for (final (id, name, sex) in [
          ('a', 'Иван', TreeSex.male),
          ('b', 'Пётр', TreeSex.female),
          ('c', 'Павел', TreeSex.male),
        ]) {
          initial.commit(initial.doc.createPerson(id, name: name, sex: sex));
        }
        final a = _Client('alice', initial.events);
        final b = _Client('bob', initial.events);
        final c = _Client('carol', initial.events);
        a.commit(a.doc.setValue('a', 'fatherId', 'b'));
        b.commit(b.doc.setValue('b', 'fatherId', 'c'));
        c.commit(c.doc.setValue('c', 'fatherId', 'a'));
        final events = [
          ...initial.events,
          ...a.events,
          ...b.events,
          ...c.events,
        ];
        final doc = TreeDocument()..merge(events);
        expect(doc.person('a')!.fatherId, isNull);
        expect(doc.person('a')!.patronymic, '');
        expect(doc.person('b')!.fatherId, 'c');
        expect(doc.person('b')!.patronymic, 'Павловна');
        expect(doc.person('c')!.fatherId, 'a');
        expect(doc.person('c')!.patronymic, 'Иванович');
        _converges(events, expected: doc);
      },
    );

    test(
      'sibling propagation and quotient cycles derive only final accepted roles',
      () {
        final client = _Client('alice');
        client.commit(client.doc.createPerson('father', name: 'Иван'));
        client.commit(client.doc.setValue(root, 'sex', TreeSex.male));
        client.commit(
          client.doc.createSibling(
            root,
            'sister',
            name: 'Анна',
            sex: TreeSex.female,
          ),
        );
        client.commit(client.doc.setValue('sister', 'fatherId', 'father'));
        expect(client.doc.person(root)!.patronymic, 'Иванович');
        expect(client.doc.person('sister')!.patronymic, 'Ивановна');
        client.commit(
          TreeOperation.fromJson({
            'type': 'setValue',
            'personId': root,
            'field': 'fatherId',
            'value': 'sister',
          }),
        );
        for (final id in [root, 'sister']) {
          expect(client.doc.person(id)!.fatherId, isNull);
          expect(client.doc.person(id)!.patronymic, '');
        }
        client.commit(client.doc.setValue(root, 'fatherId', 'father'));
        client.commit(client.doc.unlinkSibling(root, 'sister'));
        client.commit(client.doc.setValue(root, 'fatherId', null));
        expect(client.doc.person(root)!.patronymic, '');
        expect(client.doc.person('sister')!.patronymic, 'Ивановна');
        client.commit(client.doc.deletePerson('father'));
        expect(client.doc.person('sister')!.patronymic, '');
        _converges(client.events);
      },
    );
  });

  group('room patronymic overrides', () {
    test(
      'canonical atomic payload, exports, immutable dictionary and reset',
      () {
        final client = _Client('alice');
        expect(basePatronymicDictionary['петр']!.male, 'Петрович');
        expect(normalizePatronymicName(' ПЁТР '), 'петр');
        expect(generatePatronymicForms('Иван')!.female, 'Ивановна');
        final operation = client.doc.setPatronymicOverride(
          ' ПЁТР ',
          male: '  Петрыч  ',
          female: ' Петрычна ',
        );
        expect(operation.toJson(), {
          'type': 'setPatronymicOverride',
          'name': 'петр',
          'male': 'Петрыч',
          'female': 'Петрычна',
        });
        expect(operation.isRoomScoped, isTrue);
        expect(operation.personId, '');
        expect(operation.itemId, isNull);
        expect(operation.fieldKey, 'patronymic:петр');
        expect(operation.description, 'Изменены отчества для имени «петр»');
        expect(
          client.doc.patronymicOverrides,
          isEmpty,
          reason: 'Command does not mutate',
        );
        final emptySnapshot = client.doc.patronymicOverrides;
        final copy = TreeOperation.fromJson(
          jsonDecode(jsonEncode(operation.toJson())),
        );
        expect(copy.toJson(), operation.toJson());
        expect(TreeOperation.isValid(copy.toJson()), isTrue);
        expect(() => copy.toJson().clear(), throwsUnsupportedError);
        client.commit(copy);
        const forms = TreePatronymicForms(male: 'Петрыч', female: 'Петрычна');
        final dictionary = client.doc.patronymicOverrides;
        expect(dictionary, {'петр': forms});
        expect(emptySnapshot, isEmpty);
        expect(() => dictionary.clear(), throwsUnsupportedError);
        expect(() => dictionary['иван'] = forms, throwsUnsupportedError);
        final reset = client.doc.setPatronymicOverride(
          'Пётр',
          male: null,
          female: null,
        );
        expect(reset.toJson(), {
          'type': 'setPatronymicOverride',
          'name': 'петр',
          'male': null,
          'female': null,
        });
        expect(reset.description, 'Сброшены отчества для имени «петр»');
        client.commit(reset);
        expect(client.doc.patronymicOverrides, isEmpty);
        expect(dictionary, {
          'петр': forms,
        }, reason: 'Published maps are snapshots');
        _converges(client.events);
      },
    );

    test(
      'one room override updates all children, empty forms intentionally suppress',
      () {
        final client = _Client('alice');
        client.commit(client.doc.createPerson('father', name: ' ПЁТР '));
        client.commit(
          client.doc.createPerson('son', name: 'Иван', sex: TreeSex.male),
        );
        client.commit(client.doc.setValue(root, 'sex', TreeSex.female));
        for (final id in [root, 'son']) {
          client.commit(client.doc.setValue(id, 'fatherId', 'father'));
        }
        final before = client.events.length;
        client.commit(
          client.doc.setPatronymicOverride(
            'петр',
            male: 'Петрыч',
            female: 'Петрычна',
          ),
        );
        expect(client.events.length, before + 1);
        expect(client.doc.person(root)!.patronymic, 'Петрычна');
        expect(client.doc.person('son')!.patronymic, 'Петрыч');
        client.commit(
          client.doc.setPatronymicOverride('Пётр', male: '', female: ''),
        );
        expect(client.doc.person(root)!.patronymic, '');
        expect(client.doc.person('son')!.patronymic, '');
        expect(
          client.doc.patronymicOverrides['петр'],
          const TreePatronymicForms(male: '', female: ''),
        );
        client.commit(
          client.doc.setPatronymicOverride(
            'петр',
            male: '',
            female: 'Петровна',
          ),
        );
        expect(client.doc.person(root)!.patronymic, 'Петровна');
        expect(client.doc.person('son')!.patronymic, '');
        client.commit(
          client.doc.setPatronymicOverride('ПЁТР', male: null, female: null),
        );
        expect(client.doc.person(root)!.patronymic, 'Петровна');
        expect(client.doc.person('son')!.patronymic, 'Петрович');
        client.commit(
          client.doc.editText('father', TreeTextField.name, 'Иван'),
        );
        client.commit(
          client.doc.setPatronymicOverride(
            'Иван',
            male: 'Особый',
            female: 'Особая',
          ),
        );
        client.commit(
          client.doc.setPatronymicOverride('Иван', male: null, female: null),
        );
        expect(
          client.doc.person('son')!.patronymic,
          'Иванович',
          reason: 'Algorithm restored too',
        );
        _converges(client.events);
      },
    );

    test(
      'strict schema rejects invalid names, forms, mixed nulls and fake targets',
      () {
        final doc = TreeDocument();
        final valid = doc
            .setPatronymicOverride('Иван', male: 'Иванович', female: 'Ивановна')
            .toJson();
        final invalidNames = <Object?>[
          null,
          1,
          '',
          ' ',
          'иван ',
          ' Иван',
          'ИВАН',
          'пётр',
          'а\nб',
          'а\u0000б',
          'а\u007fб',
          'а\u0085б',
          'а\u009fб',
          '\ud800',
          '\udc00',
          'а' * 201,
        ];
        final invalidForms = <Object?>[
          null,
          1,
          false,
          [],
          {},
          ' Иванович',
          'Иванович ',
          'а\tб',
          'а\nб',
          'а\u0000б',
          'а\u007fб',
          'а\u0085б',
          'а\u009fб',
          '\ud800',
          '\udc00',
          'а' * 201,
        ];
        final malformed = <Map<String, Object?>>[
          for (final name in invalidNames) {...valid, 'name': name},
          for (final value in invalidForms) ...[
            {...valid, 'male': value},
            {...valid, 'female': value},
          ],
          {...valid, 'personId': root},
          {...valid, 'personId': ''},
          {...valid, 'extra': true},
          for (final key in ['type', 'name', 'male', 'female'])
            {...valid}..remove(key),
        ];
        for (final json in malformed) {
          expect(
            () => TreeOperation.fromJson(json),
            throwsFormatException,
            reason: '$json',
          );
          expect(TreeOperation.isValid(json), isFalse, reason: '$json');
        }
        for (final (male, female) in [('x', null), (null, 'x')]) {
          expect(
            () => doc.setPatronymicOverride('Иван', male: male, female: female),
            throwsFormatException,
          );
        }
        for (final name in ['', ' \t ', 'а' * 201, 'а\nб', '\ud800']) {
          expect(
            () => doc.setPatronymicOverride(name, male: null, female: null),
            throwsFormatException,
          );
        }
        for (final value in ['а' * 201, 'а\nб', 'а\u0085б', '\ud800']) {
          expect(
            () => doc.setPatronymicOverride('Иван', male: value, female: value),
            throwsFormatException,
          );
        }
        final astral = '🌳' * maxTreePatronymicLength;
        final operation = doc.setPatronymicOverride(
          astral,
          male: astral,
          female: '',
        );
        expect(TreeOperation.isValid(operation.toJson()), isTrue);
        expect(
          () => doc.setPatronymicOverride('$astral🌳', male: '', female: ''),
          throwsFormatException,
        );
        expect(
          () =>
              doc.setPatronymicOverride('Иван', male: '$astral🌳', female: ''),
          throwsFormatException,
        );
        expect(
          () =>
              doc.setPatronymicOverride('Иван', male: '', female: '$astral🌳'),
          throwsFormatException,
        );
        expect(
          () => doc.setValue(root, 'patronymic', 'Записанное'),
          throwsFormatException,
        );
        expect(
          () => TreeOperation.fromJson({
            'type': 'createPerson',
            'personId': 'new',
            'name': 'Имя',
            'sex': 'male',
            'patronymic': 'Нет',
          }),
          throwsFormatException,
        );
      },
    );

    test(
      'dictionary survives deleting every identity and works without person guards',
      () {
        final client = _Client('alice');
        client.commit(
          client.doc.setPatronymicOverride(
            'Иван',
            male: 'Первый',
            female: 'Первая',
          ),
        );
        client.commit(client.doc.deletePerson(root));
        expect(client.doc.people, isEmpty);
        client.commit(
          client.doc.setPatronymicOverride(
            'ПЁТР',
            male: 'Петрыч',
            female: 'Петрычна',
          ),
        );
        client.commit(
          client.doc.setPatronymicOverride('Иван', male: null, female: null),
        );
        expect(client.doc.people, isEmpty);
        expect(client.doc.patronymicOverrides, {
          'петр': const TreePatronymicForms(male: 'Петрыч', female: 'Петрычна'),
        });
        for (final id in [root, '', 'missing']) {
          expect(
            () => client.doc.setValue(id, 'sex', TreeSex.male),
            throwsArgumentError,
          );
          expect(
            () => client.doc.setIndividualSurname(id, text: 'x'),
            throwsArgumentError,
          );
          expect(
            () => client.doc.editText(id, TreeTextField.name, 'x'),
            throwsArgumentError,
          );
          expect(() => client.doc.deletePerson(id), throwsArgumentError);
        }
        final emptyReplay = TreeDocument()..merge(client.events.reversed);
        expect(_projection(emptyReplay), _projection(client.doc));
        _converges(client.events);
        client.commit(client.doc.createPerson('father', name: 'Пётр'));
        client.commit(client.doc.createPerson('child', sex: TreeSex.female));
        client.commit(client.doc.setValue('child', 'fatherId', 'father'));
        expect(client.doc.person('child')!.patronymic, 'Петрычна');
        client.commit(client.doc.deletePerson('father'));
        client.commit(client.doc.deletePerson('child'));
        expect(client.doc.people, isEmpty);
        expect(client.doc.patronymicOverrides['петр']!.male, 'Петрыч');
        _converges(client.events);
      },
    );

    test(
      'reset delivered first suppresses delayed older values and replay is byte-stable',
      () {
        final builder = TreeDocument();
        StampedTreeOperation event(
          String id,
          int clock,
          TreeOperation operation,
        ) => StampedTreeOperation(
          id: id,
          author: 'alice',
          clock: clock,
          createdAt: DateTime.utc(2026),
          operation: operation,
        );
        final old = event(
          'old',
          1,
          builder.setPatronymicOverride(
            'Иван',
            male: 'Старый',
            female: 'Старая',
          ),
        );
        final reset = event(
          'reset',
          3,
          builder.setPatronymicOverride('Иван', male: null, female: null),
        );
        final delayed = event(
          'delayed',
          2,
          builder.setPatronymicOverride(
            'Иван',
            male: 'Поздно',
            female: 'Поздняя',
          ),
        );
        final doc = TreeDocument()..merge([reset]);
        doc.merge([old, delayed]);
        expect(doc.patronymicOverrides, isEmpty);
        _converges([old, delayed, reset], expected: doc);
        final newer = event(
          'newer',
          4,
          builder.setPatronymicOverride('Иван', male: 'Новый', female: 'Новая'),
        );
        doc.merge([newer]);
        expect(
          doc.patronymicOverrides['иван'],
          const TreePatronymicForms(male: 'Новый', female: 'Новая'),
        );
        final all = [old, delayed, reset, newer];
        final encoded = jsonEncode([for (final value in all) value.toJson()]);
        final restored = [
          for (final json in jsonDecode(encoded) as List)
            StampedTreeOperation.fromJson(json),
        ];
        expect(
          jsonEncode([for (final value in restored) value.toJson()]),
          encoded,
        );
        expect(_projection(TreeDocument()..merge(restored)), _projection(doc));
        _converges(all, expected: doc);
      },
    );

    test(
      'concurrent overrides are atomic per normalized name and use clock, author, id',
      () {
        final initial = _Client('initial');
        initial.commit(initial.doc.createPerson('father', name: 'Пётр'));
        initial.commit(initial.doc.setValue(root, 'sex', TreeSex.female));
        initial.commit(initial.doc.setValue(root, 'fatherId', 'father'));
        final a = _Client('alice', initial.events);
        final b = _Client('bob', initial.events);
        a.commit(
          a.doc.setPatronymicOverride(
            'ПЁТР',
            male: 'Мужская А',
            female: 'Женская А',
          ),
        );
        b.commit(
          b.doc.setPatronymicOverride(
            'петр',
            male: 'Мужская Б',
            female: 'Женская Б',
          ),
        );
        a.commit(
          a.doc.setPatronymicOverride('Иван', male: 'Другой', female: 'Другая'),
        );
        a.receive(b.events);
        expect(
          a.doc.patronymicOverrides['петр'],
          const TreePatronymicForms(male: 'Мужская Б', female: 'Женская Б'),
        );
        expect(a.doc.patronymicOverrides['иван']!.male, 'Другой');
        expect(a.doc.person(root)!.patronymic, 'Женская Б');
        final all = [...initial.events, ...a.events, ...b.events];
        _converges(all, expected: a.doc);
        final lowerClock = StampedTreeOperation(
          id: 'zz-lower-clock',
          author: 'zzzz',
          clock: 0,
          createdAt: DateTime.utc(2099),
          operation: a.doc.setPatronymicOverride(
            'петр',
            male: 'Не победит',
            female: 'Не победит',
          ),
        );
        final value = StampedTreeOperation(
          id: 'a-value',
          author: 'same',
          clock: 100,
          createdAt: DateTime.utc(2099),
          operation: a.doc.setPatronymicOverride(
            'петр',
            male: 'Поздний',
            female: 'Поздняя',
          ),
        );
        final reset = StampedTreeOperation(
          id: 'z-reset',
          author: 'same',
          clock: 100,
          createdAt: DateTime.utc(1900),
          operation: a.doc.setPatronymicOverride(
            'петр',
            male: null,
            female: null,
          ),
        );
        final events = [...all, lowerClock, value, reset];
        final doc = TreeDocument()..merge(events.reversed);
        expect(doc.patronymicOverrides.containsKey('петр'), isFalse);
        expect(doc.patronymicOverrides['иван']!.female, 'Другая');
        expect(doc.person(root)!.patronymic, 'Петровна');
        _converges(events, expected: doc);
      },
    );

    test(
      'ordinary operations retain their targets and encoded historical payloads',
      () {
        const historical = [
          '{"name":"  Иван Иванович  ","personId":"father","sex":"male","type":"createPerson"}',
          '{"field":"fatherId","personId":"root","type":"setValue","value":"father"}',
          '{"field":"sex","personId":"root","type":"setValue","value":"female"}',
          '{"decline":true,"familyKey":"person:4:root","personId":"root","scope":"family","text":"Иванов","type":"setSurname"}',
        ];
        final operations = [
          for (final encoded in historical)
            TreeOperation.fromJson(jsonDecode(encoded)),
        ];
        for (var index = 0; index < operations.length; index++) {
          expect(jsonEncode(operations[index].toJson()), historical[index]);
          expect(operations[index].isRoomScoped, isFalse);
          expect(operations[index].personId, index == 0 ? 'father' : root);
        }
        final events = [
          for (var index = 0; index < operations.length; index++)
            StampedTreeOperation(
              id: 'historical-$index',
              author: 'alice',
              clock: index,
              createdAt: DateTime.utc(2026),
              operation: operations[index],
            ),
        ];
        final doc = TreeDocument()..merge(events);
        expect(doc.person('father')!.name, '  Иван Иванович  ');
        expect(
          doc.person(root)!.patronymic,
          '',
          reason: 'No splitting of historical father names',
        );
        expect(doc.patronymicOverrides, isEmpty);
        for (var index = 0; index < operations.length; index++) {
          expect(jsonEncode(operations[index].toJson()), historical[index]);
        }
        expect(TreeOperation.isValid({'type': 'deletePerson'}), isFalse);
        expect(
          TreeOperation.isValid({'type': 'deletePerson', 'personId': ''}),
          isFalse,
        );
        _converges(events);
      },
    );
  });

  group('permanent person tombstones', () {
    test(
      'virtual root can be deleted, leaving an empty restorable projection',
      () {
        final client = _Client('alice');
        final operation = client.doc.deletePerson(root);
        expect(operation.toJson(), {'type': 'deletePerson', 'personId': root});
        expect(operation.fieldKey, 'person');
        expect(operation.description, 'Удалён человек');
        expect(operation.itemId, isNull);
        expect(TreeOperation.isValid(operation.toJson()), isTrue);
        expect(
          TreeOperation.fromJson(
            jsonDecode(jsonEncode(operation.toJson())),
          ).toJson(),
          operation.toJson(),
        );
        expect(() => operation.toJson().clear(), throwsUnsupportedError);
        expect(client.doc.people.keys, [
          root,
        ], reason: 'Commands do not mutate');
        client.commit(operation);
        expect(client.doc.person(root), isNull);
        expect(client.doc.people, isEmpty);
        expect(() => client.doc.deletePerson(root), throwsArgumentError);
        expect(() => client.doc.deletePerson('missing'), throwsArgumentError);
        expect(() => client.doc.createPerson(root), throwsArgumentError);
        expect(
          () => client.doc.textSnapshot(root, TreeTextField.name),
          throwsArgumentError,
        );
        expect(
          () => client.doc.setValue(root, 'sex', TreeSex.female),
          throwsArgumentError,
        );
        final restored = TreeDocument()
          ..merge(
            client.events.map(
              (event) => StampedTreeOperation.fromJson(
                jsonDecode(jsonEncode(event.toJson())),
              ),
            ),
          );
        expect(restored.people, isEmpty);
        expect(() => restored.createPerson(root), throwsArgumentError);
        client.commit(
          client.doc.createPerson('new-root', name: 'Новый человек'),
        );
        expect(client.doc.people.keys, ['new-root']);
        expect(client.doc.person(root), isNull);
        client.commit(client.doc.deletePerson('new-root'));
        expect(client.doc.people, isEmpty);
        _converges(client.events);
      },
    );

    test(
      'deleting ancestors or root removes only incident parent references',
      () {
        final client = _Client('alice');
        for (final id in ['parent', 'other', 'child', 'sibling']) {
          client.commit(client.doc.createPerson(id));
        }
        client.commit(client.doc.setValue(root, 'fatherId', 'parent'));
        client.commit(client.doc.setValue(root, 'motherId', 'other'));
        client.commit(client.doc.setValue('sibling', 'fatherId', 'parent'));
        client.commit(client.doc.setValue('child', 'fatherId', root));
        client.commit(client.doc.setValue('child', 'motherId', 'other'));
        client.commit(client.doc.deletePerson('parent'));
        expect(client.doc.person('parent'), isNull);
        expect(client.doc.person(root)!.fatherId, isNull);
        expect(client.doc.person('sibling')!.fatherId, isNull);
        expect(client.doc.person(root)!.motherId, 'other');
        expect(client.doc.person('child')!.fatherId, root);
        expect(client.doc.childrenOf('parent'), isEmpty);
        client.commit(client.doc.deletePerson(root));
        expect(client.doc.person('child')!.fatherId, isNull);
        expect(client.doc.person('child')!.motherId, 'other');
        expect(client.doc.childrenOf(root), isEmpty);
        expect(client.doc.people.keys, ['child', 'other', 'sibling']);
        for (final person in client.doc.people.values) {
          for (final parent in [
            person.fatherId,
            person.motherId,
          ].whereType<String>()) {
            expect(client.doc.person(parent), isNotNull);
            expect(client.doc.wouldCreateCycle(person.id, parent), isFalse);
          }
        }
        expect(
          () => client.doc.setValue('child', 'fatherId', root),
          throwsArgumentError,
        );
        _converges(client.events);
      },
    );

    test(
      'delete wins concurrent and later edits, item additions and recreation',
      () {
        final initial = _Client('initial');
        initial.commit(initial.doc.createPerson('target', name: 'Имя'));
        initial.commit(initial.doc.addFact('target', 'fact', text: 'Факт'));
        initial.commit(initial.doc.addPhoto('target', 'photo', dataUrl: png));
        initial.commit(initial.doc.bindActor('actor', 'target'));
        final a = _Client('alice', initial.events);
        final b = _Client('bob', initial.events);
        a.commit(a.doc.deletePerson('target'));
        b.commit(b.doc.editText('target', TreeTextField.name, 'Позднее имя'));
        b.commit(
          b.doc.editText('target', TreeTextField.biography, 'Биография'),
        );
        b.commit(b.doc.setValue('target', 'sex', TreeSex.female));
        b.commit(
          b.doc.editText(
            'target',
            TreeTextField.fact,
            'Правка',
            itemId: 'fact',
          ),
        );
        b.commit(b.doc.setFactColor('target', 'fact', '#ABCDEF'));
        b.commit(
          b.doc.editText(
            'target',
            TreeTextField.photoCaption,
            'Подпись',
            itemId: 'photo',
          ),
        );
        b.commit(b.doc.setValue('target', 'avatarPhotoId', 'photo'));
        b.commit(b.doc.addFact('target', 'new-fact', text: 'Новый факт'));
        b.commit(b.doc.addPhoto('target', 'new-photo', dataUrl: png));
        b.commit(b.doc.moveFact('target', 'new-fact', beforeId: 'fact'));
        b.commit(b.doc.movePhoto('target', 'new-photo', beforeId: 'photo'));
        b.commit(b.doc.removeFact('target', 'fact'));
        b.commit(b.doc.removePhoto('target', 'photo'));
        b.commit(b.doc.setValue(root, 'fatherId', 'target'));
        // An imported/stale create is still retained, never a resurrection.
        b.commit(
          TreeOperation.fromJson({
            'type': 'createPerson',
            'personId': 'target',
            'name': 'Попытка восстановления',
            'sex': 'male',
          }),
        );
        a.receive(b.events);
        b.receive(a.events);
        expect(a.doc.person('target'), isNull);
        expect(a.doc.person(root)!.fatherId, isNull);
        expect(a.doc.bindings, {'actor': 'target'});
        expect(() => a.doc.createPerson('target'), throwsArgumentError);
        expect(() => a.doc.addFact('target', 'another'), throwsArgumentError);
        expect(
          () => a.doc.addPhoto('target', 'another', dataUrl: png),
          throwsArgumentError,
        );
        expect(_projection(b.doc), _projection(a.doc));
        _converges([
          ...initial.events,
          ...a.events,
          ...b.events,
        ], expected: a.doc);
      },
    );

    test(
      'a deletion delivered before an unknown identity reserves its ID forever',
      () {
        final deletion = StampedTreeOperation(
          id: 'delete-before-create',
          author: 'alice',
          clock: 1,
          createdAt: DateTime.utc(2026),
          operation: TreeOperation.fromJson({
            'type': 'deletePerson',
            'personId': 'late',
          }),
        );
        final doc = TreeDocument()..merge([deletion]);
        expect(() => doc.createPerson('late'), throwsArgumentError);
        final creation = StampedTreeOperation(
          id: 'late-create',
          author: 'bob',
          clock: 100,
          createdAt: DateTime.utc(2026),
          operation: TreeDocument().createPerson('late', name: 'Не воскреснет'),
        );
        doc.merge([creation]);
        expect(doc.people.keys, [root]);
        expect(doc.person('late'), isNull);
        expect(() => doc.createPerson('late'), throwsArgumentError);
        _converges([deletion, creation], expected: doc);
      },
    );
  });

  group('anchored Unicode text CRDT', () {
    test(
      'concurrent inserts at distinct offsets, stable IDs, shuffled replay',
      () {
        final initial = _Client('initial')..name('abcd');
        final a = _Client('alice', initial.events);
        final b = _Client('bob', initial.events);
        final original = a.doc.textSnapshot(root, TreeTextField.name);
        a.name('aXbcd');
        b.name('abcYd');
        a.receive(b.events);
        expect(a.doc.person(root)!.name, 'aXbcYd');
        final next = a.doc.textSnapshot(root, TreeTextField.name);
        expect(original.atomIds.every(next.atomIds.contains), isTrue);
        expect(original.mapOffsetTo(next, 1), 2);
        expect(original.mapOffsetTo(next, 3), 5);
        _converges([
          ...initial.events,
          ...a.events,
          ...b.events,
        ], expected: a.doc);
      },
    );

    test(
      'same-gap concurrent runs stay intact and later local edits anchor correctly',
      () {
        final initial = _Client('initial')..name('ab');
        final a = _Client('alice', initial.events);
        final b = _Client('bob', initial.events);
        a.name('aXYb');
        a.name('aX🙂Yb');
        b.name('a12b');
        a.receive(b.events);
        b.receive(a.events);
        expect(a.doc.person(root)!.name, b.doc.person(root)!.name);
        expect(a.doc.person(root)!.name, contains('X🙂Y'));
        expect(a.doc.person(root)!.name, contains('12'));
        final before = a.doc.person(root)!.name;
        a.name('${before.substring(0, before.length - 1)}!b');
        expect(
          a.doc.person(root)!.name,
          '${before.substring(0, before.length - 1)}!b',
        );
        _converges([
          ...initial.events,
          ...a.events,
          ...b.events,
        ], expected: a.doc);
      },
    );

    test(
      'concurrent deletions do not delete unseen inserts; deleted anchors survive',
      () {
        final initial = _Client('initial')..name('abcd');
        final a = _Client('alice', initial.events);
        final b = _Client('bob', initial.events);
        a.name('ad');
        b.name('abXcd');
        a.receive(b.events);
        expect(a.doc.person(root)!.name, 'aXd');
        a.name('aYXd');
        expect(
          a.doc.person(root)!.name,
          'aYXd',
          reason: 'Right anchor is below tombstoned b',
        );
        _converges([...initial.events, ...a.events, ...b.events]);
      },
    );

    test(
      'stale editing snapshot preserves remote insertions and multi-hunk unchanged IDs',
      () {
        final initial = _Client('initial')..name('abcdef');
        final a = _Client('alice', initial.events);
        final b = _Client('bob', initial.events);
        final base = a.doc.textSnapshot(root, TreeTextField.name);
        b.name('abc🚀def');
        a.receive(b.events);
        a.name('aBcdeF', base: base);
        expect(a.doc.person(root)!.name, 'aBc🚀deF');
        final snapshot = a.doc.textSnapshot(root, TreeTextField.name);
        for (final index in [0, 2, 3, 4]) {
          expect(snapshot.atomIds, contains(base.atomIds[index]));
        }
        expect(a.doc.editText(root, TreeTextField.name, snapshot.text), isNull);
        _converges([...initial.events, ...a.events, ...b.events]);
      },
    );

    test(
      'Unicode scalars and UTF-16 cursor boundaries survive replacement/deletion',
      () {
        final a = _Client('alice')..name('A😀Б');
        final base = a.doc.textSnapshot(root, TreeTextField.name);
        expect(base.atomIds, hasLength(3));
        expect(base.boundaries, [0, 1, 3, 4]);
        a.name('A🙂😀Б!');
        final next = a.doc.textSnapshot(root, TreeTextField.name);
        expect(base.mapOffsetTo(next, 1), 3);
        expect(
          base.mapOffsetTo(next, 2),
          3,
          reason: 'No cursor inside a surrogate pair',
        );
        expect(base.mapOffsetTo(next, 3), 5);
        expect(base.mapOffsetTo(next, 4), 7);
        expect(base.mapOffsetTo(next, -10), 0);
        a.name('AБ!');
        final deleted = a.doc.textSnapshot(root, TreeTextField.name);
        expect(base.mapOffsetTo(deleted, 1), 1);
        expect(deleted.boundaries, [0, 1, 2, 3]);
        expect(() => base.atomIds.clear(), throwsUnsupportedError);
        expect(() => base.boundaries.clear(), throwsUnsupportedError);
        expect(
          () => base.mapOffsetTo(
            a.doc.textSnapshot(root, TreeTextField.biography),
            0,
          ),
          throwsArgumentError,
        );
      },
    );

    test(
      'name, biography, facts and photo captions are independent anchored text',
      () {
        final initial = _Client('initial');
        initial.commit(initial.doc.addFact(root, 'fact', text: 'ab'));
        initial.commit(
          initial.doc.addPhoto(root, 'photo', dataUrl: png, caption: 'xy'),
        );
        final a = _Client('alice', initial.events);
        final b = _Client('bob', initial.events);
        a.name('Имя');
        a.commit(a.doc.editText(root, TreeTextField.biography, 'Жизнь'));
        a.commit(
          a.doc.editText(root, TreeTextField.fact, 'a1b', itemId: 'fact'),
        );
        b.commit(
          b.doc.editText(root, TreeTextField.fact, 'ab2', itemId: 'fact'),
        );
        a.commit(
          a.doc.editText(
            root,
            TreeTextField.photoCaption,
            'xAy',
            itemId: 'photo',
          ),
        );
        b.commit(
          b.doc.editText(
            root,
            TreeTextField.photoCaption,
            'xyB',
            itemId: 'photo',
          ),
        );
        a.receive(b.events);
        final person = a.doc.person(root)!;
        expect(person.name, 'Имя');
        expect(person.biography, 'Жизнь');
        expect(person.facts.single.text, 'a1b2');
        expect(person.photos.single.caption, 'xAyB');
        expect(a.events.last.operation.fieldKey, 'photo:photo:caption');
        _converges([
          ...initial.events,
          ...a.events,
          ...b.events,
        ], expected: a.doc);
      },
    );

    test(
      'random sequential Unicode edits exactly reproduce requested strings',
      () {
        final client = _Client('typing');
        final random = Random(57);
        final chars = ['a', 'б', '🙂', '🌳', ' ', '\n', '́'];
        var runes = <String>[];
        for (var step = 0; step < 100; step++) {
          final next = [...runes];
          for (var edit = 0; edit < 1 + random.nextInt(4); edit++) {
            if (next.isNotEmpty && random.nextBool()) {
              next.removeAt(random.nextInt(next.length));
            } else {
              next.insert(
                random.nextInt(next.length + 1),
                chars[random.nextInt(chars.length)],
              );
            }
          }
          final text = next.join();
          if (text != runes.join()) client.name(text);
          expect(
            client.doc.person(root)!.name,
            text,
            reason: 'Typing step $step',
          );
          runes = next;
        }
        final replay = [...client.events]..shuffle(Random(3));
        expect(
          _projection(TreeDocument()..merge(replay)),
          _projection(client.doc),
        );
      },
    );

    test(
      'optimistic edits remain exact after random concurrent merges and deletes',
      () {
        final clients = [_Client('a'), _Client('b'), _Client('c')];
        final random = Random(801);
        final all = <StampedTreeOperation>[];
        const chars = ['a', 'б', '🙂', '🌳'];
        for (var step = 0; step < 100; step++) {
          final client = clients[random.nextInt(clients.length)];
          if (random.nextBool()) {
            client.receive(all.where((_) => random.nextBool()));
          }
          final next = client.doc.person(root)!.name.runes.toList();
          if (next.isNotEmpty && random.nextBool()) {
            next.removeAt(random.nextInt(next.length));
          } else {
            next.insert(
              random.nextInt(next.length + 1),
              chars[random.nextInt(chars.length)].runes.single,
            );
          }
          final value = String.fromCharCodes(next);
          all.add(
            client.commit(client.doc.editText(root, TreeTextField.name, value)),
          );
          expect(
            client.doc.person(root)!.name,
            value,
            reason: 'Optimistic step $step',
          );
        }
        for (final client in clients) {
          client.receive(all);
        }
        expect(_projection(clients[0].doc), _projection(clients[1].doc));
        expect(_projection(clients[1].doc), _projection(clients[2].doc));
        final shuffled = [...all]..shuffle(Random(1));
        expect(
          _projection(TreeDocument()..merge(shuffled)),
          _projection(clients[0].doc),
        );
      },
    );

    test(
      '100k limit, iterative long chains and large replacement fallback',
      () {
        final a = _Client('alice');
        a.name('a' * maxTreeTextLength);
        expect(a.doc.person(root)!.name.length, maxTreeTextLength);
        a.name('b' * maxTreeTextLength);
        expect(a.doc.person(root)!.name, 'b' * maxTreeTextLength);
        expect(
          a.doc.textSnapshot(root, TreeTextField.name).atomIds.length,
          maxTreeTextLength,
        );
      },
    );
  });

  group('stable-ID lists', () {
    test(
      'moves, concurrent append/remove/color/text converge without losing items',
      () {
        final initial = _Client('initial');
        for (final id in ['a', 'b', 'c']) {
          initial.commit(initial.doc.addFact(root, id, text: id));
        }
        final a = _Client('alice', initial.events);
        final b = _Client('bob', initial.events);
        a.commit(a.doc.moveFact(root, 'c', beforeId: 'a'));
        expect(a.doc.person(root)!.facts.map((fact) => fact.id), [
          'c',
          'a',
          'b',
        ]);
        b.commit(b.doc.moveFact(root, 'b', afterId: 'c'));
        expect(b.doc.person(root)!.facts.map((fact) => fact.id), [
          'a',
          'c',
          'b',
        ]);
        a.commit(a.doc.addFact(root, 'd', text: 'новый'));
        b.commit(b.doc.removeFact(root, 'a'));
        b.commit(b.doc.setFactColor(root, 'c', '#ABCDEF'));
        b.commit(b.doc.editText(root, TreeTextField.fact, 'cee', itemId: 'c'));
        a.receive(b.events);
        expect(a.doc.person(root)!.facts.map((fact) => fact.id).toSet(), {
          'b',
          'c',
          'd',
        });
        final c = a.doc
            .person(root)!
            .facts
            .firstWhere((fact) => fact.id == 'c');
        expect(c.text, 'cee');
        expect(c.color, '#ABCDEF');
        _converges([
          ...initial.events,
          ...a.events,
          ...b.events,
        ], expected: a.doc);
        expect(
          () => a.doc.addFact(root, 'a'),
          throwsArgumentError,
          reason: 'Tombstoned IDs cannot be reused',
        );
      },
    );

    test(
      'moves preserve text atom IDs and snapshots, removal is permanent',
      () {
        final client = _Client('alice');
        for (final id in ['a', 'b', 'c']) {
          client.commit(client.doc.addFact(root, id, text: '$id🙂'));
        }
        final snapshot = client.doc.textSnapshot(
          root,
          TreeTextField.fact,
          itemId: 'b',
        );
        client.commit(client.doc.moveFact(root, 'b', beforeId: 'a'));
        expect(client.doc.person(root)!.facts.map((fact) => fact.id), [
          'b',
          'a',
          'c',
        ]);
        client.commit(client.doc.moveFact(root, 'b', afterId: 'c'));
        expect(client.doc.person(root)!.facts.map((fact) => fact.id), [
          'a',
          'c',
          'b',
        ]);
        expect(
          client.doc
              .textSnapshot(root, TreeTextField.fact, itemId: 'b')
              .atomIds,
          snapshot.atomIds,
        );
        final late = client.doc.moveFact(root, 'b', beforeId: 'a');
        client.commit(client.doc.removeFact(root, 'b'));
        client.commit(late);
        expect(client.doc.person(root)!.facts.map((fact) => fact.id), [
          'a',
          'c',
        ]);
        expect(
          () => client.doc.moveFact(root, 'c', afterId: 'c'),
          throwsArgumentError,
        );
        expect(
          () => client.doc.setFactColor(root, 'a', 'red'),
          throwsFormatException,
        );
        _converges(client.events);
      },
    );

    test('random moves preserve the exact order of all other stable IDs', () {
      final client = _Client('moving');
      final ids = [for (var i = 0; i < 8; i++) 'item-$i'];
      for (final id in ids) {
        client.commit(client.doc.addFact(root, id));
      }
      final random = Random(8);
      for (var step = 0; step < 100; step++) {
        final oldIndex = random.nextInt(ids.length);
        final id = ids.removeAt(oldIndex);
        final index = random.nextInt(ids.length + 1);
        final before = index == ids.length ? null : ids[index];
        final after = index == 0 ? null : ids[index - 1];
        ids.insert(index, id);
        client.commit(
          client.doc.moveFact(root, id, afterId: after, beforeId: before),
        );
        expect(
          client.doc.person(root)!.facts.map((item) => item.id),
          ids,
          reason: 'Move step $step',
        );
      }
    });

    test(
      'photos move by stable ID, independent avatar clears when photo removed',
      () {
        final initial = _Client('initial');
        for (final id in ['a', 'b', 'c']) {
          initial.commit(
            initial.doc.addPhoto(root, id, dataUrl: png, caption: id),
          );
        }
        final a = _Client('alice', initial.events);
        final b = _Client('bob', initial.events);
        a.commit(a.doc.movePhoto(root, 'c', beforeId: 'a'));
        a.commit(a.doc.setValue(root, 'avatarPhotoId', 'c'));
        b.commit(b.doc.addPhoto(root, 'd', dataUrl: png));
        b.commit(b.doc.removePhoto(root, 'b'));
        a.receive(b.events);
        expect(a.doc.person(root)!.photos.map((photo) => photo.id).toSet(), {
          'a',
          'c',
          'd',
        });
        expect(a.doc.person(root)!.avatarPhotoId, 'c');
        a.commit(a.doc.removePhoto(root, 'c'));
        expect(a.doc.person(root)!.avatarPhotoId, isNull);
        expect(
          () => a.doc.setValue(root, 'avatarPhotoId', 'missing'),
          throwsArgumentError,
        );
        _converges([
          ...initial.events,
          ...a.events,
          ...b.events,
        ], expected: a.doc);
      },
    );
  });

  group('explicit sibling relationships', () {
    test(
      'atomic new sibling seeds name sex DOB and immutable group snapshots',
      () {
        final client = _Client('alice');
        expect(client.doc.siblingGroupIds, {root: 'person:4:root'});
        final operation = client.doc.createSibling(
          root,
          'brother',
          name: ' Брат ',
          sex: TreeSex.male,
          birthDate: DateTime.utc(1990, 2, 3),
        );
        expect(operation.toJson(), {
          'type': 'createSibling',
          'personId': 'brother',
          'siblingId': root,
          'name': ' Брат ',
          'sex': 'male',
          'birthDate': '1990-02-03',
        });
        expect(client.doc.people, hasLength(1));
        final event = client.commit(operation);
        final brother = client.doc.person('brother')!;
        expect(brother.name, ' Брат ');
        expect(brother.sex, TreeSex.male);
        expect(brother.birthDate, DateTime.utc(1990, 2, 3));
        expect(client.doc.directSiblingLinks.single.id, event.id);
        expect(
          client.doc.siblingGroupIds[root],
          client.doc.siblingGroupIds['brother'],
        );
        expect(treeSurnameFamilyKey(brother), 'person:7:brother');
        expect(
          client.doc.siblingsOf(root, includeHalf: false).map((p) => p.id),
          ['brother'],
        );
        expect(
          () => client.doc.siblingGroupIds.clear(),
          throwsUnsupportedError,
        );
        expect(
          () => client.doc.directSiblingLinks.clear(),
          throwsUnsupportedError,
        );
        expect(
          () => client.doc.createSibling(root, 'brother'),
          throwsArgumentError,
        );
        expect(
          () => client.doc.createSibling('unknown', 'new'),
          throwsArgumentError,
        );
        for (final invalid in <Map<String, Object?>>[
          {...operation.toJson(), 'siblingId': 'brother'},
          {...operation.toJson(), 'birthDate': '1990-02-30'},
          {...operation.toJson(), 'birthDate': '1990-2-3'},
          {...operation.toJson(), 'extra': true},
          {...operation.toJson()}..remove('birthDate'),
        ]) {
          expect(() => TreeOperation.fromJson(invalid), throwsFormatException);
        }
        client.commit(
          client.doc.editText('brother', TreeTextField.name, 'Брат новый'),
        );
        expect(client.doc.person('brother')!.name, 'Брат новый');
        expect(client.doc.merge([event]), isFalse);
        _converges(client.events);
      },
    );

    for (final known in [0, 1, 2]) {
      test(
        'new sibling copies $known accepted parents without unrelated grouping',
        () {
          final client = _Client('alice');
          for (final id in ['father', 'mother', 'unrelated']) {
            client.commit(client.doc.createPerson(id));
          }
          if (known > 0) {
            client.commit(client.doc.setValue(root, 'fatherId', 'father'));
          }
          if (known > 1) {
            client.commit(client.doc.setValue(root, 'motherId', 'mother'));
          }
          final original = client.events.length;
          client.commit(
            client.doc.createSibling(root, 'sister', sex: TreeSex.female),
          );
          expect(client.events.length, original + 1);
          expect(
            client.doc.person('sister')!.fatherId,
            known > 0 ? 'father' : null,
          );
          expect(
            client.doc.person('sister')!.motherId,
            known > 1 ? 'mother' : null,
          );
          expect(
            client.doc.siblingGroupIds['sister'],
            client.doc.siblingGroupIds[root],
          );
          expect(
            client.doc.siblingGroupIds['unrelated'],
            isNot(client.doc.siblingGroupIds[root]),
          );
          expect(client.doc.directSiblingLinks.length, known < 2 ? 1 : 0);
          if (known == 2) {
            expect(
              () => client.doc.unlinkSibling(root, 'sister'),
              throwsArgumentError,
            );
            client.commit(client.doc.setValue(root, 'fatherId', null));
            expect(client.doc.person('sister')!.fatherId, 'father');
          }
          _converges(client.events);
        },
      );
    }

    test(
      'parent set and clear propagate transitively, bridge unlink retains half siblings',
      () {
        final client = _Client('alice');
        for (final id in ['father', 'other']) {
          client.commit(client.doc.createPerson(id));
        }
        client.commit(client.doc.createSibling(root, 'b'));
        client.commit(client.doc.createSibling('b', 'c'));
        client.commit(client.doc.setValue('c', 'fatherId', 'father'));
        for (final id in [root, 'b', 'c']) {
          expect(client.doc.person(id)!.fatherId, 'father');
        }
        client.commit(client.doc.setValue('b', 'fatherId', null));
        for (final id in [root, 'b', 'c']) {
          expect(client.doc.person(id)!.fatherId, isNull);
        }
        client.commit(client.doc.setValue(root, 'fatherId', 'father'));
        final unlink = client.doc.unlinkSibling(root, 'b');
        client.commit(unlink);
        expect(client.doc.directSiblingLinks, hasLength(1));
        expect(client.doc.siblingsOf(root, includeHalf: false), isEmpty);
        expect(client.doc.siblingsOf(root).map((p) => p.id), ['b', 'c']);
        expect(
          client.doc.siblingsOf('b', includeHalf: false).map((p) => p.id),
          ['c'],
        );
        client.commit(client.doc.setValue(root, 'fatherId', 'other'));
        expect(client.doc.person('b')!.fatherId, 'father');
        expect(client.doc.person('c')!.fatherId, 'father');
        client.commit(client.doc.unlinkSibling('c', 'b'));
        client.commit(client.doc.setValue('b', 'fatherId', null));
        expect(client.doc.person('c')!.fatherId, 'father');
        expect(() => client.doc.unlinkSibling(root, 'b'), throwsArgumentError);
        _converges(client.events);
      },
    );

    test(
      'accepted second parent retires every edge permanently without journal writes',
      () {
        final client = _Client('alice');
        for (final id in ['father', 'mother']) {
          client.commit(client.doc.createPerson(id));
        }
        client.commit(client.doc.setValue(root, 'fatherId', 'father'));
        client.commit(
          client.doc.setIndividualSurname(
            'father',
            text: 'Иванов',
            decline: true,
          ),
        );
        client.commit(client.doc.createSibling(root, 'b', sex: TreeSex.female));
        client.commit(client.doc.createSibling('b', 'c'));
        final oldUnlink = client.doc.unlinkSibling(root, 'b');
        final before = client.events.length;
        client.commit(client.doc.setValue('c', 'motherId', 'mother'));
        expect(client.events.length, before + 1);
        expect(client.doc.directSiblingLinks, isEmpty);
        for (final id in [root, 'b', 'c']) {
          expect(client.doc.person(id)!.fatherId, 'father');
          expect(client.doc.person(id)!.motherId, 'mother');
        }
        expect(client.doc.person('b')!.surname, 'Иванова');
        expect(
          client.doc.siblingGroupIds.values.where(
            (id) => id.startsWith('siblings:'),
          ),
          isEmpty,
        );
        client.commit(oldUnlink);
        expect(
          client.doc.siblingsOf(root, includeHalf: false).map((p) => p.id),
          ['b', 'c'],
        );
        client.commit(client.doc.setValue('b', 'motherId', null));
        expect(client.doc.person(root)!.motherId, 'mother');
        client.commit(client.doc.deletePerson('father'));
        expect(client.doc.directSiblingLinks, isEmpty);
        expect(client.doc.person(root)!.fatherId, isNull);
        expect(client.doc.person('b')!.motherId, isNull);
        _converges(client.events);
      },
    );

    test(
      'component-wide local cycles reject and incoming cycles project coherently',
      () {
        final client = _Client('alice');
        client.commit(client.doc.createPerson('parent'));
        client.commit(client.doc.createSibling(root, 'b'));
        expect(
          () => client.doc.setValue(root, 'fatherId', 'b'),
          throwsArgumentError,
        );
        client.commit(client.doc.setValue('parent', 'fatherId', 'b'));
        expect(
          () => client.doc.setValue(root, 'motherId', 'parent'),
          throwsArgumentError,
        );
        final raw = TreeOperation.fromJson({
          'type': 'setValue',
          'personId': root,
          'field': 'fatherId',
          'value': 'b',
        });
        client.commit(raw);
        expect(client.doc.person(root)!.fatherId, isNull);
        expect(client.doc.person('b')!.fatherId, isNull);
        expect(client.doc.directSiblingLinks, hasLength(1));
        client.commit(
          TreeOperation.fromJson({...raw.toJson(), 'value': 'parent'}),
        );
        expect(client.doc.person(root)!.fatherId, 'parent');
        expect(client.doc.person('b')!.fatherId, 'parent');
        expect(client.doc.person('parent')!.fatherId, isNull);
        _converges(client.events);
      },
    );

    test('deleting a bridge cannot group survivors through a tombstone', () {
      final client = _Client('alice');
      client.commit(client.doc.createPerson('mother'));
      client.commit(client.doc.createSibling(root, 'b'));
      client.commit(client.doc.createSibling('b', 'c'));
      client.commit(client.doc.setValue(root, 'motherId', 'mother'));
      client.commit(client.doc.deletePerson('b'));
      expect(client.doc.directSiblingLinks, isEmpty);
      expect(
        client.doc.siblingGroupIds[root],
        isNot(client.doc.siblingGroupIds['c']),
      );
      expect(client.doc.siblingsOf(root, includeHalf: false), isEmpty);
      expect(client.doc.siblingsOf(root).map((p) => p.id), ['c']);
      expect(client.doc.person('c')!.motherId, 'mother');
      _converges(client.events);
    });

    test(
      'concurrent creation parent changes and exact unlink converge and reload unchanged',
      () {
        final initial = _Client('initial');
        for (final id in ['p', 'q']) {
          initial.commit(initial.doc.createPerson(id));
        }
        initial.commit(initial.doc.createSibling(root, 'b'));
        final a = _Client('alice', initial.events);
        final b = _Client('bob', initial.events);
        a.commit(a.doc.createSibling('b', 'c'));
        b.commit(b.doc.createSibling(root, 'd'));
        a.commit(a.doc.setValue(root, 'fatherId', 'p'));
        b.commit(b.doc.setValue('b', 'fatherId', 'q'));
        a.receive(b.events);
        b.receive(a.events);
        expect(a.doc.directSiblingLinks, hasLength(3));
        for (final id in [root, 'b', 'c', 'd']) {
          expect(a.doc.person(id)!.fatherId, 'q');
        }
        final stale = a.doc.unlinkSibling(root, 'b');
        a.commit(stale);
        a.commit(a.doc.createSibling(root, 'new'));
        a.commit(stale);
        expect(
          a.doc.directSiblingLinks.any((link) => link.personId == 'new'),
          isTrue,
        );
        final all = [...initial.events, ...a.events, ...b.events];
        final encoded = jsonEncode([for (final event in all) event.toJson()]);
        final reloaded = TreeDocument()
          ..merge([
            for (final json in jsonDecode(encoded) as List)
              StampedTreeOperation.fromJson(json),
          ]);
        expect(_projection(reloaded), _projection(a.doc));
        expect(encoded, jsonEncode([for (final event in all) event.toJson()]));
        _converges(all, expected: a.doc);
      },
    );

    test(
      'cycle-rejected second parent cannot retire a group and quotient cycles stay atomic',
      () {
        final client = _Client('alice');
        client.commit(client.doc.createPerson('father'));
        client.commit(client.doc.createPerson('other'));
        client.commit(client.doc.createSibling(root, 'b'));
        client.commit(client.doc.setValue(root, 'fatherId', 'father'));
        client.commit(
          TreeOperation.fromJson({
            'type': 'setValue',
            'personId': 'b',
            'field': 'motherId',
            'value': root,
          }),
        );
        expect(client.doc.directSiblingLinks, hasLength(1));
        for (final id in [root, 'b']) {
          expect(client.doc.person(id)!.fatherId, 'father');
          expect(client.doc.person(id)!.motherId, isNull);
        }
        client.commit(client.doc.createSibling('other', 'd'));
        client.commit(client.doc.setValue('other', 'motherId', root));
        client.commit(
          TreeOperation.fromJson({
            'type': 'setValue',
            'personId': root,
            'field': 'fatherId',
            'value': 'd',
          }),
        );
        expect(client.doc.person(root)!.fatherId, 'd');
        expect(client.doc.person('b')!.fatherId, 'd');
        expect(client.doc.person('other')!.motherId, isNull);
        expect(client.doc.person('d')!.motherId, isNull);
        expect(client.doc.directSiblingLinks, hasLength(2));
        _converges(client.events);
      },
    );

    test(
      'remove-before-claim and duplicate creations do not manufacture links',
      () {
        final client = _Client('alice');
        final operation = client.doc.createSibling(root, 'b');
        client.commit(
          TreeOperation.fromJson({
            'type': 'unlinkSibling',
            'personId': root,
            'siblingId': 'b',
            'linkId': 'alice-1',
          }),
        );
        final claim = client.commit(operation);
        expect(claim.id, 'alice-1');
        expect(client.doc.directSiblingLinks, isEmpty);
        client.commit(
          TreeOperation.fromJson({...operation.toJson(), 'name': 'Duplicate'}),
        );
        expect(client.doc.directSiblingLinks, isEmpty);
        expect(client.doc.person('b')!.name, isEmpty);
        client.commit(client.doc.createPerson('p'));
        client.commit(client.doc.createSibling(root, 'c'));
        client.commit(client.doc.setValue(root, 'fatherId', 'p'));
        client.commit(client.doc.setValue('c', 'fatherId', null));
        client.commit(client.doc.createSibling('c', 'd'));
        for (final id in [root, 'c', 'd']) {
          expect(client.doc.person(id)!.fatherId, isNull);
        }
        _converges(client.events);
      },
    );

    test(
      'unknown sources and unmatched unlink records remain valid history',
      () {
        final client = _Client('alice');
        final operation = TreeOperation.fromJson({
          ...client.doc.createSibling(root, 'b').toJson(),
          'siblingId': 'later',
        });
        final event = client.commit(operation);
        expect(client.doc.person('b'), isNotNull);
        expect(client.doc.directSiblingLinks, isEmpty);
        client.commit(client.doc.createPerson('later'));
        expect(client.doc.directSiblingLinks.single.id, event.id);
        client.commit(
          TreeOperation.fromJson({
            'type': 'unlinkSibling',
            'personId': 'b',
            'siblingId': root,
            'linkId': event.id,
          }),
        );
        expect(client.doc.directSiblingLinks, hasLength(1));
        _converges(client.events);
      },
    );
  });

  group('family relationships and actor claims', () {
    test(
      'birth ordering is strict, unknown-first and normalizes given names',
      () {
        final people = [
          TreePerson(id: 'unknown-z', name: 'Яна'),
          TreePerson(id: 'empty-b', name: '  '),
          TreePerson(id: 'dated-z', name: 'ЯНА', birthDate: DateTime.utc(1900)),
          TreePerson(id: 'unknown-b', name: ' АлЁна '),
          TreePerson(
            id: 'later',
            name: 'А',
            birthDate: DateTime.utc(1900, 1, 2),
          ),
          TreePerson(id: 'unknown-a', name: 'алена'),
          TreePerson(
            id: 'dated-b',
            name: ' АлЁна ',
            birthDate: DateTime.utc(1900),
          ),
          TreePerson(id: 'empty-a'),
          TreePerson(
            id: 'dated-a',
            name: 'АЛЕНА',
            birthDate: DateTime.utc(1900),
          ),
        ];
        const expected = [
          'empty-a',
          'empty-b',
          'unknown-a',
          'unknown-b',
          'unknown-z',
          'dated-a',
          'dated-b',
          'dated-z',
          'later',
        ];
        final original = [
          for (final person in people)
            (person.id, person.name, person.birthDate),
        ];
        for (var seed = 0; seed < 8; seed++) {
          final sorted = [...people]
            ..shuffle(Random(seed))
            ..sort(compareTreePeopleByBirth);
          expect(sorted.map((person) => person.id), expected);
        }
        for (var i = 0; i < people.length; i++) {
          expect(compareTreePeopleByBirth(people[i], people[i]), 0);
          for (var j = i + 1; j < people.length; j++) {
            expect(compareTreePeopleByBirth(people[i], people[j]), isNot(0));
            expect(
              compareTreePeopleByBirth(people[i], people[j]).sign,
              -compareTreePeopleByBirth(people[j], people[i]).sign,
            );
          }
        }
        expect([
          for (final person in people)
            (person.id, person.name, person.birthDate),
        ], original);
      },
    );

    test(
      'children and full/half siblings use birth/name/id order without writes',
      () {
        final client = _Client('alice');
        for (final id in ['father', 'mother', 'half-mother']) {
          client.commit(client.doc.createPerson(id));
        }
        client.commit(client.doc.setValue(root, 'fatherId', 'father'));
        client.commit(client.doc.setValue(root, 'motherId', 'mother'));
        final members = [
          ('missing-z', 'Яна', null),
          ('same-z', 'Яна', DateTime.utc(1900)),
          ('missing-b', ' АлЁна ', null),
          ('same-b', ' АлЁна ', DateTime.utc(1900)),
          ('later', 'А', DateTime.utc(1900, 1, 2)),
          ('missing-a', 'алена', null),
          ('same-a', 'АЛЕНА', DateTime.utc(1900)),
        ];
        for (final (id, name, birth) in members) {
          client.commit(client.doc.createPerson(id, name: name));
          client.commit(client.doc.setValue(id, 'fatherId', 'father'));
          client.commit(
            client.doc.setValue(
              id,
              'motherId',
              id == 'missing-b' ? 'half-mother' : 'mother',
            ),
          );
          if (birth != null) {
            client.commit(client.doc.setValue(id, 'birthDate', birth));
          }
        }
        client.commit(
          client.doc.setIndividualSurname('same-a', text: 'Яковлев'),
        );
        client.commit(
          client.doc.setIndividualSurname('same-b', text: 'Алексеев'),
        );
        final count = client.events.length;
        final original = jsonEncode([
          for (final event in client.events) event.toJson(),
        ]);
        final before = _projection(client.doc);
        const siblings = [
          'missing-a',
          'missing-b',
          'missing-z',
          'same-a',
          'same-b',
          'same-z',
          'later',
        ];
        expect(client.doc.childrenOf('father').map((person) => person.id), [
          root,
          ...siblings,
        ]);
        expect(
          client.doc.siblingsOf(root).map((person) => person.id),
          siblings,
        );
        expect(
          client.doc
              .siblingsOf(root, includeHalf: false)
              .map((person) => person.id),
          ['missing-a', 'missing-z', 'same-a', 'same-b', 'same-z', 'later'],
        );
        expect(
          () => client.doc.childrenOf('father').clear(),
          throwsUnsupportedError,
        );
        expect(
          () => client.doc.siblingsOf(root).clear(),
          throwsUnsupportedError,
        );
        expect(client.events.length, count);
        expect(_projection(client.doc), before);
        expect(
          jsonEncode([for (final event in client.events) event.toJson()]),
          original,
        );
        final restored = TreeDocument()
          ..merge([
            for (final json in jsonDecode(original) as List)
              StampedTreeOperation.fromJson(json),
          ]);
        expect(restored.childrenOf('father').map((person) => person.id), [
          root,
          ...siblings,
        ]);
        expect(restored.siblingsOf(root).map((person) => person.id), siblings);
        _converges(client.events);
      },
    );

    test(
      'direct/indirect local cycles rejected, shared ancestry unions allowed',
      () {
        final client = _Client('alice');
        for (final id in [
          'grandparent',
          'parent',
          'sibling',
          'uncle',
          'child',
        ]) {
          client.commit(client.doc.createPerson(id, name: id));
        }
        client.commit(client.doc.setValue('parent', 'fatherId', 'grandparent'));
        client.commit(client.doc.setValue('uncle', 'fatherId', 'grandparent'));
        client.commit(client.doc.setValue(root, 'fatherId', 'parent'));
        client.commit(client.doc.setValue('sibling', 'fatherId', 'parent'));
        client.commit(client.doc.setValue('child', 'fatherId', root));
        // A person and their uncle can share a child: not a directed ancestry cycle.
        client.commit(client.doc.setValue('child', 'motherId', 'uncle'));
        expect(client.doc.wouldCreateCycle('grandparent', 'child'), isTrue);
        expect(
          () => client.doc.setValue('grandparent', 'motherId', 'child'),
          throwsArgumentError,
        );
        expect(
          () => client.doc.setValue(root, 'fatherId', root),
          throwsArgumentError,
        );
        expect(client.doc.wouldCreateCycle('child', 'grandparent'), isFalse);
        expect(client.doc.childrenOf('parent').map((person) => person.id), [
          root,
          'sibling',
        ]);
        expect(client.doc.siblingsOf(root).map((person) => person.id), [
          'sibling',
        ]);
        expect(client.doc.siblingsOf(root, includeHalf: false), isEmpty);
        client.commit(client.doc.setValue(root, 'motherId', 'uncle'));
        client.commit(client.doc.setValue('sibling', 'motherId', 'uncle'));
        expect(
          client.doc
              .siblingsOf(root, includeHalf: false)
              .map((person) => person.id),
          ['sibling'],
        );
        expect(client.doc.siblingsOf('missing'), isEmpty);
        _converges(client.events);
      },
    );

    test('concurrent two- and three-person cycles always project acyclic', () {
      final initial = _Client('initial');
      for (final id in ['a', 'b', 'c']) {
        initial.commit(initial.doc.createPerson(id));
      }
      final a = _Client('alice', initial.events);
      final b = _Client('bob', initial.events);
      final c = _Client('carol', initial.events);
      a.commit(a.doc.setValue('a', 'fatherId', 'b'));
      b.commit(b.doc.setValue('b', 'motherId', 'c'));
      c.commit(c.doc.setValue('c', 'fatherId', 'a'));
      final all = [...initial.events, ...a.events, ...b.events, ...c.events];
      final doc = TreeDocument()..merge(all);
      expect(
        [
          doc.person('a')!.fatherId,
          doc.person('b')!.motherId,
          doc.person('c')!.fatherId,
        ].whereType<String>(),
        hasLength(2),
      );
      expect(
        doc.person('a')!.fatherId,
        isNull,
        reason: 'Highest stamp edges win conflict',
      );
      _converges(all);
      final two = [
        ...initial.events,
        a.events.single,
        StampedTreeOperation(
          id: 'two',
          author: 'bob',
          clock: 9,
          createdAt: DateTime.utc(2026),
          operation: b.doc.setValue('b', 'fatherId', 'a'),
        ),
      ];
      final twoDoc = TreeDocument()..merge(two);
      expect(twoDoc.person('a')!.fatherId, isNull);
      expect(twoDoc.person('b')!.fatherId, 'a');
      _converges(two);
    });

    test(
      'legacy claims without release preserve earliest total order, not arrival/time',
      () {
        final initial = _Client('initial');
        initial.commit(initial.doc.createPerson('other'));
        final a = _Client('alice', initial.events);
        final b = _Client('bob', initial.events);
        a.commit(a.doc.bindActor('actor', root));
        b.commit(b.doc.bindActor('actor', 'other'));
        a.receive(b.events);
        a.commit(a.doc.bindActor('actor', 'other'));
        a.commit(a.doc.bindActor('another', 'other'));
        expect(a.doc.bindings, {'actor': root, 'another': 'other'});
        a.commit(a.doc.deletePerson(root));
        a.commit(a.doc.bindActor('actor', 'other'));
        expect(a.doc.person(root), isNull);
        expect(a.doc.bindings, {'actor': root, 'another': 'other'});
        _converges([
          ...initial.events,
          ...a.events,
          ...b.events,
        ], expected: a.doc);
      },
    );
  });

  group('releasable actor claims', () {
    test(
      'immutable releases allow rebinding without changing other actors',
      () {
        final client = _Client('alice');
        client.commit(client.doc.createPerson('other'));
        final original = client.commit(client.doc.bindActor('alice', root));
        client.commit(client.doc.bindActor('bob', root));
        final release = client.doc.unbindActor('alice');
        expect(release.toJson(), {
          'type': 'unbindActor',
          'personId': root,
          'actorId': 'alice',
          'bindingId': original.id,
        });
        expect(release.fieldKey, 'binding:alice');
        expect(release.description, 'Участник отменил выбор себя в дереве');
        expect(client.doc.bindings, {'alice': root, 'bob': root});
        expect(() => release.toJson().clear(), throwsUnsupportedError);
        final copy = TreeOperation.fromJson(
          jsonDecode(jsonEncode(release.toJson())),
        );
        expect(copy.toJson(), release.toJson());
        client.commit(copy);
        expect(client.doc.bindings, {'bob': root});
        expect(() => client.doc.unbindActor('alice'), throwsArgumentError);
        client.commit(client.doc.bindActor('alice', 'other'));
        expect(client.doc.bindings, {'alice': 'other', 'bob': root});
        client.commit(client.doc.deletePerson('other'));
        client.commit(client.doc.unbindActor('alice'));
        client.commit(client.doc.bindActor('alice', root));
        expect(client.doc.bindings, {'alice': root, 'bob': root});
        expect(original.operation.toJson(), {
          'type': 'bindActor',
          'personId': root,
          'actorId': 'alice',
        });
        _converges(client.events, expected: client.doc);
      },
    );

    test(
      'concurrent bind and claim-specific releases converge in stamp order',
      () {
        final seed = _Client('seed');
        seed.commit(seed.doc.createPerson('other'));
        StampedTreeOperation event(
          String id,
          int clock,
          TreeOperation operation, {
          String author = 'alice',
        }) => StampedTreeOperation(
          id: id,
          author: author,
          clock: clock,
          createdAt: DateTime.utc(2026),
          operation: operation,
        );
        final original = event('claim', 2, seed.doc.bindActor('alice', root));
        final bob = event(
          'bob-claim',
          2,
          seed.doc.bindActor('bob', root),
          author: 'bob',
        );
        final document = TreeDocument()..merge([...seed.events, original, bob]);
        final release = document.unbindActor('alice');
        final events = [
          ...seed.events,
          original,
          bob,
          // An extra pre-release claim retains the historical first-claim rule.
          event('ignored-claim', 3, document.bindActor('alice', 'other')),
          event('a-release', 4, release),
          event('b-rebind', 4, document.bindActor('alice', root)),
          // A delayed second release of the old claim cannot undo the new one.
          event('stale-release', 5, release),
          event('foreign-release', 6, release, author: 'bob'),
        ];
        final expected = TreeDocument()..merge(events);
        expect(expected.bindings, {'alice': root, 'bob': root});
        expect(expected.unbindActor('alice').toJson()['bindingId'], 'b-rebind');
        _converges(events, expected: expected);
        final finalRelease = event(
          'current-release',
          7,
          expected.unbindActor('alice'),
        );
        final released = TreeDocument()..merge([...events, finalRelease]);
        expect(released.bindings, {'bob': root});
        _converges([...events, finalRelease], expected: released);
      },
    );

    test(
      'foreign author and mismatched person cannot release an active claim',
      () {
        final alice = _Client('alice');
        alice.commit(alice.doc.createPerson('other'));
        alice.commit(alice.doc.bindActor('alice', root));
        final release = alice.doc.unbindActor('alice');
        final bob = _Client('bob', alice.events);
        bob.commit(release);
        alice.receive(bob.events);
        alice.commit(
          TreeOperation.fromJson({...release.toJson(), 'personId': 'other'}),
        );
        expect(alice.doc.bindings, {'alice': root});
        _converges([...alice.events, ...bob.events], expected: alice.doc);
      },
    );
  });

  group('safe photo data URIs', () {
    test(
      'allows exact JPEG, PNG and WebP MIME with corresponding signatures',
      () {
        final jpeg =
            'data:image/jpeg;base64,${base64Encode([255, 216, 255, 217])}';
        final webp =
            'data:image/webp;base64,${base64Encode([82, 73, 70, 70, 4, 0, 0, 0, 87, 69, 66, 80])}';
        final doc = TreeDocument();
        for (final image in [png, jpeg, webp]) {
          expect(isValidTreePhotoDataUrl(image), isTrue);
          expect(doc.addPhoto(root, 'image', dataUrl: image).type, 'addPhoto');
        }
      },
    );

    test(
      'rejects SVG, MIME tricks, invalid base64, mismatches and oversized bytes',
      () {
        final invalid = <Object?>[
          null,
          3,
          '',
          'https://example.com/image.png',
          'data:image/svg+xml;base64,${base64Encode(utf8.encode('<svg/>'))}',
          png.replaceFirst('image/png', 'image/jpg'),
          png.replaceFirst('image/png', 'image/jpeg'),
          png.replaceFirst('image/png', 'IMAGE/PNG'),
          png.replaceFirst(';base64', ';charset=utf-8;base64'),
          'data:image/png;base64,',
          'data:image/png;base64,!!!!',
          'data:image/png;base64,SGVsbG8=',
          '$png\n',
        ];
        final tooLarge = List<int>.filled(maxTreePhotoBytes + 1, 0);
        tooLarge.setAll(0, [137, 80, 78, 71, 13, 10, 26, 10]);
        invalid.add('data:image/png;base64,${base64Encode(tooLarge)}');
        for (final value in invalid) {
          expect(
            isValidTreePhotoDataUrl(value),
            isFalse,
            reason: '$value'.substring(0, min('$value'.length, 100)),
          );
        }
        expect(
          () => TreeDocument().addPhoto(
            root,
            'bad',
            dataUrl: invalid.last as String,
          ),
          throwsFormatException,
        );
      },
    );
  });
}
