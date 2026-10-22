import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/tree/tree_document.dart';

const _ivanov = TreeSurname(text: 'Иванов', decline: true);
const _petrov = TreeSurname(text: 'Петров', decline: true);
const _sidorov = TreeSurname(text: 'Сидоров', decline: true);

class _Client {
  _Client(this.author, [Iterable<StampedTreeOperation> initial = const []]) {
    receive(initial);
  }

  final String author;
  final doc = TreeDocument();
  final events = <StampedTreeOperation>[];
  var clock = 0;
  var serial = 0;

  StampedTreeOperation commit(TreeOperation operation) {
    final event = StampedTreeOperation(
      id: '$author-${serial++}',
      author: author,
      clock: ++clock,
      createdAt: DateTime.utc(2026),
      operation: operation,
    );
    events.add(event);
    doc.merge([event]);
    return event;
  }

  void receive(Iterable<StampedTreeOperation> incoming) {
    final all = incoming.toList();
    for (final event in all) {
      clock = max(clock, event.clock);
    }
    doc.merge(all);
  }

  void person(
    String id, {
    String name = '',
    TreeSex sex = TreeSex.unknown,
    TreeSurname? surname,
    String? birth,
  }) {
    commit(doc.createPerson(id, name: name, sex: sex));
    if (surname != null) {
      commit(
        doc.setIndividualSurname(
          id,
          text: surname.text,
          decline: surname.decline,
        ),
      );
    }
    if (birth != null) commit(doc.setValue(id, 'birthDate', birth));
  }

  void child(String id, String a, String b, {String? birth}) {
    person(id, birth: birth);
    commit(doc.setValue(id, 'fatherId', a));
    commit(doc.setValue(id, 'motherId', b));
  }
}

Map<String, Object?>? _surname(TreeSurname? value) =>
    value == null ? null : {'text': value.text, 'decline': value.decline};

Object _marriage(TreeMarriage value) => {
  'id': value.id,
  'person': value.personId,
  'partner': value.partnerId,
  'start': value.startDate?.toIso8601String(),
  'end': value.endDate?.toIso8601String(),
  'mode': value.endMode.name,
  'implied': value.isImplied,
  'order': value.orderingDate?.toIso8601String(),
  'choices': {
    for (final entry in value.surnameChoices.entries)
      entry.key: {
        'change': entry.value.changeSurname,
        'surname': _surname(entry.value.adoptedSurname),
        'explicit': entry.value.isExplicit,
      },
  },
};

Object? _change(TreeSurnameChange? value) => value == null
    ? null
    : {
        'id': value.id,
        'person': value.personId,
        'surname': _surname(value.surname),
        'date': value.date?.toIso8601String(),
        'reason': value.reason,
        'marriage': value.marriageId,
        'partner': value.partnerId,
        'implied': value.isImplied,
        'actual': value.changesSurname,
        'order': value.orderingDate?.toIso8601String(),
      };

Object _view(TreeDocument document) => {
  'people': {
    for (final p in document.people.values)
      p.id: {
        'name': p.name,
        'full': p.fullName,
        'fio': p.fullNameWithPatronymic,
        'birthSurname': _surname(p.effectiveSurname),
        'current': _surname(p.currentSurname),
        'birth': p.birthDate?.toIso8601String(),
        'alive': p.alive,
        'partners': document.partnersOf(p.id).map((p) => p.id).toList(),
        'marriages': document.marriagesOf(p.id).map(_marriage).toList(),
        'changes': document.surnameChangesOf(p.id).map(_change).toList(),
        'history': [
          for (final row in document.historyOf(p.id))
            {
              'id': row.id,
              'marriage': row.marriage == null
                  ? null
                  : _marriage(row.marriage!),
              'change': _change(row.surnameChange),
            },
        ],
      },
  },
  'graph': document.marriages.map(_marriage).toList(),
};

void _converges(
  Iterable<StampedTreeOperation> values, {
  TreeDocument? expected,
}) {
  final events = values.toList();
  final reference = expected ?? (TreeDocument()..merge(events));
  for (var seed = 0; seed < 8; seed++) {
    final shuffled = [...events, ...events]..shuffle(Random(seed));
    final doc = TreeDocument();
    for (final event in shuffled) {
      doc.merge([
        StampedTreeOperation.fromJson(jsonDecode(jsonEncode(event.toJson()))),
      ]);
    }
    expect(_view(doc), _view(reference), reason: 'shuffle $seed');
    expect(doc.merge(events), isFalse);
  }
}

void main() {
  group('marriage and surname history domain', () {
    test(
      'childless marriage is atomic, symmetric and not an ancestry edge',
      () {
        final c = _Client('a');
        c.person('wife', name: 'Анна', sex: TreeSex.female, surname: _petrov);
        c.person('husband', name: 'Иван', sex: TreeSex.male, surname: _ivanov);
        final operation = c.doc.addMarriage('wife', 'husband', id: 'episode');
        expect(c.doc.marriages, isEmpty);
        expect(c.doc.person('wife')!.surname, 'Петрова');
        c.commit(operation);
        final marriage = c.doc.marriages.single;
        expect(marriage.id, 'episode');
        expect(marriage.isImplied, isFalse);
        expect(marriage.otherPersonId('wife'), 'husband');
        expect(marriage.otherPersonId('elsewhere'), isNull);
        expect(marriage.startDate, isNull);
        expect(marriage.hasExplicitDates, isFalse);
        expect(marriage.endMode, TreeMarriageEndMode.unknown);
        expect(c.doc.partnersOf('wife').single.id, 'husband');
        expect(c.doc.partnersOf('husband').single.id, 'wife');
        expect(c.doc.person('wife')!.fatherId, isNull);
        expect(c.doc.childrenOf('wife'), isEmpty);
        expect(c.doc.person('wife')!.surname, 'Иванова');
        expect(c.doc.person('husband')!.surname, 'Иванов');
        expect(c.doc.historyOf('wife').single.surnameChange!.surname, _ivanov);
        expect(c.doc.historyOf('husband').single.surnameChange, isNull);
        expect(c.doc.marriagesOf('wife').single.id, marriage.id);
        expect(c.doc.marriagesOf('husband').single.id, marriage.id);
        expect(() => c.doc.addMarriage('wife', 'wife'), throwsFormatException);
        expect(() => c.doc.addMarriage('wife', 'missing'), throwsArgumentError);
        c.commit(c.doc.setValue('wife', 'fatherId', 'husband'));
        expect(
          c.doc.person('wife')!.fatherId,
          'husband',
          reason: 'Marriage does not participate in directed cycle checks',
        );
        _converges(c.events);
      },
    );

    test('new partner identity, DOB and birth surname use one operation', () {
      final c = _Client('a');
      c.person('wife', sex: TreeSex.female, surname: _petrov);
      final before = c.events.length;
      final op = c.doc.addMarriage(
        'wife',
        'new-partner',
        id: 'new-marriage',
        newPartner: TreeNewMarriagePartner(
          name: '  Иван  ',
          sex: TreeSex.male,
          birthDate: DateTime.utc(1980, 2, 29),
          birthSurname: _ivanov,
        ),
      );
      expect(c.doc.person('new-partner'), isNull);
      c.commit(op);
      expect(c.events.length, before + 1);
      final partner = c.doc.person('new-partner')!;
      expect(partner.name, 'Иван');
      expect(partner.birthDate, DateTime.utc(1980, 2, 29));
      expect(partner.effectiveSurname, _ivanov);
      expect(c.doc.person('wife')!.surname, 'Иванова');
      expect(() => c.doc.createPerson('new-partner'), throwsArgumentError);
      expect(
        () => c.doc.addMarriage(
          'wife',
          'new-partner',
          newPartner: const TreeNewMarriagePartner(),
        ),
        throwsArgumentError,
      );
      c.commit(c.doc.deletePerson('new-partner'));
      expect(c.doc.marriages, isEmpty);
      expect(c.doc.person('wife')!.surname, 'Иванова');
      expect(c.doc.historyOf('wife').single.marriage!.partnerId, 'new-partner');
      expect(
        () => c.doc.addMarriage(
          'wife',
          'new-partner',
          newPartner: const TreeNewMarriagePartner(),
        ),
        throwsArgumentError,
      );
      _converges(c.events);
    });

    test('common accepted live children imply one stable undated marriage', () {
      final c = _Client('a');
      c.person('father', name: 'Иван', sex: TreeSex.male, surname: _ivanov);
      c.person('mother', name: 'Анна', sex: TreeSex.female, surname: _petrov);
      c.child('young', 'father', 'mother', birth: '2005-06-07');
      final id = c.doc.marriages.single.id;
      c.child('old', 'father', 'mother', birth: '2000-01-02');
      c.person('unrelated', birth: '1900-01-01');
      c.commit(c.doc.setValue('unrelated', 'motherId', 'mother'));
      final marriage = c.doc.marriages.single;
      expect(marriage.id, id);
      expect(marriage.isImplied, isTrue);
      expect(marriage.orderingDate, DateTime.utc(2000, 1, 2));
      expect(marriage.startDate, isNull);
      expect(marriage.endDate, isNull);
      expect(marriage.hasExplicitDates, isFalse);
      expect(c.doc.person('mother')!.surname, 'Иванова');
      expect(c.doc.person('mother')!.effectiveSurname, _petrov);
      expect(c.doc.surnameChangesOf('mother').single.date, isNull);
      expect(
        c.doc.surnameChangesOf('mother').single.orderingDate,
        marriage.orderingDate,
      );
      expect(c.doc.historyOf('father'), hasLength(1));
      expect(c.doc.historyOf('mother'), hasLength(1));
      expect(
        c.events.where((e) => e.operation.type.contains('Marriage')),
        isEmpty,
      );
      c.commit(c.doc.deletePerson('old'));
      expect(c.doc.marriages.single.orderingDate, DateTime.utc(2005, 6, 7));
      c.commit(c.doc.setValue('young', 'motherId', null));
      expect(c.doc.marriages, isEmpty);
      expect(c.doc.person('mother')!.surname, 'Петрова');
      _converges(c.events);
    });

    test(
      'delete suppresses co-parent fallback across child additions and renames',
      () {
        final c = _Client('a');
        c.person('father', sex: TreeSex.male, surname: _ivanov);
        c.person('mother', sex: TreeSex.female, surname: _petrov);
        c.child('child', 'father', 'mother');
        final implied = c.doc.marriages.single;
        c.commit(c.doc.removeMarriage('mother', implied.id));
        expect(c.doc.marriages, isEmpty);
        expect(c.doc.historyOf('mother'), isEmpty);
        expect(c.doc.person('mother')!.surname, 'Петрова');
        expect(
          c.doc.partnersOf('mother').single.id,
          'father',
          reason: 'Co-parent navigation remains independent of noMarriage',
        );
        c.child('another-child', 'father', 'mother', birth: '2010-01-01');
        c.commit(c.doc.editText('father', TreeTextField.name, 'Переименован')!);
        c.commit(
          c.doc.setIndividualSurname('father', text: 'Сидоров', decline: true),
        );
        expect(c.doc.marriages, isEmpty);
        expect(c.doc.person('mother')!.surname, 'Петрова');
        expect(
          () => c.doc.addMarriage('father', 'mother', id: implied.id),
          throwsArgumentError,
        );
        c.commit(c.doc.addMarriage('father', 'mother', id: 'fresh'));
        expect(c.doc.marriages.single.id, 'fresh');
        expect(c.doc.person('mother')!.surname, 'Сидорова');
        c.commit(c.doc.removeMarriage('father', 'fresh'));
        expect(c.doc.marriages, isEmpty);
        _converges(c.events);
      },
    );

    test(
      'episode deletion wins later edits, duplicate add and late tombstone',
      () {
        final initial = _Client('initial');
        initial.person('a', surname: _ivanov);
        initial.person('b', sex: TreeSex.female, surname: _petrov);
        final add = initial.commit(
          initial.doc.addMarriage('a', 'b', id: 'old'),
        );
        final left = _Client('left', initial.events);
        final right = _Client('right', initial.events);
        final deletion = left.commit(left.doc.removeMarriage('a', 'old'));
        right.commit(
          right.doc.updateMarriage(
            'b',
            'old',
            startDate: DateTime.utc(2000),
            endDate: null,
          ),
        );
        right.commit(
          right.doc.setMarriageSurname(
            'b',
            'old',
            changeSurname: true,
            adoptedSurname: _sidorov,
          ),
        );
        right.commit(add.operation);
        left.receive(right.events);
        expect(left.doc.marriages, isEmpty);
        expect(left.doc.person('b')!.surname, 'Петрова');
        left.commit(left.doc.addMarriage('b', 'a', id: 'new'));
        expect(left.doc.marriages.single.id, 'new');
        final all = [...initial.events, ...left.events, ...right.events];
        _converges(all, expected: left.doc);
        final tombstoneFirst = TreeDocument()..merge([deletion]);
        tombstoneFirst.merge(all);
        expect(_view(tombstoneFirst), _view(left.doc));
      },
    );

    test(
      'multiple episodes keep identities and removal does not erase another',
      () {
        final c = _Client('a');
        c.person('a', surname: _ivanov);
        c.person('b', sex: TreeSex.female, surname: _petrov);
        c.commit(
          c.doc.addMarriage(
            'a',
            'b',
            id: 'first',
            startDate: DateTime.utc(2000),
            endDate: DateTime.utc(2005),
            endMode: TreeMarriageEndMode.date,
          ),
        );
        c.commit(
          c.doc.addMarriage(
            'b',
            'a',
            id: 'second',
            startDate: DateTime.utc(2010),
          ),
        );
        expect(c.doc.marriages, hasLength(2));
        expect(c.doc.partnersOf('a').map((p) => p.id), ['b']);
        c.commit(c.doc.removeMarriage('a', 'first'));
        expect(c.doc.marriages.single.id, 'second');
        expect(c.doc.historyOf('a').single.marriage!.id, 'second');
        expect(
          () => c.doc.addMarriage('a', 'b', id: 'first'),
          throwsArgumentError,
        );
        _converges(c.events);
      },
    );

    test(
      'implied edits materialize same ID and preserve independent choices',
      () {
        final initial = _Client('initial');
        initial.person('a', sex: TreeSex.male, surname: _ivanov);
        initial.person('b', sex: TreeSex.female, surname: _petrov);
        initial.child('child', 'a', 'b');
        final id = initial.doc.marriages.single.id;
        final left = _Client('left', initial.events);
        final right = _Client('right', initial.events);
        left.commit(left.doc.setMarriageSurname('b', id, changeSurname: false));
        right.commit(
          right.doc.updateMarriage(
            'a',
            id,
            startDate: DateTime.utc(2000),
            endDate: null,
          ),
        );
        left.receive(right.events);
        final marriage = left.doc.marriages.single;
        expect(marriage.id, id);
        expect(marriage.isImplied, isFalse);
        expect(marriage.startDate, DateTime.utc(2000));
        expect(marriage.surnameChoices['b']!.changeSurname, isFalse);
        expect(marriage.surnameChoices['b']!.isExplicit, isTrue);
        expect(left.doc.person('b')!.surname, 'Петрова');
        left.child('later-child', 'a', 'b');
        left.commit(
          left.doc.setIndividualSurname('a', text: 'Сидоров', decline: true),
        );
        left.commit(left.doc.setValue('child', 'motherId', null));
        expect(left.doc.person('b')!.surname, 'Петрова');
        expect(left.doc.marriages.single.id, id);
        _converges([
          ...initial.events,
          ...left.events,
          ...right.events,
        ], expected: left.doc);
      },
    );

    test(
      'two concurrent materializations do not duplicate and do not overwrite spouse intent',
      () {
        final initial = _Client('initial');
        initial.person('a', sex: TreeSex.female, surname: _ivanov);
        initial.person('b', sex: TreeSex.female, surname: _petrov);
        initial.child('child', 'a', 'b');
        final id = initial.doc.marriages.single.id;
        final left = _Client('left', initial.events);
        final right = _Client('right', initial.events);
        left.commit(
          left.doc.addMarriage('a', 'b', id: id, changeSurname: false),
        );
        right.commit(
          right.doc.addMarriage('b', 'a', id: id, changeSurname: false),
        );
        final events = [...initial.events, ...left.events, ...right.events];
        final doc = TreeDocument()..merge(events);
        expect(doc.marriages, hasLength(1));
        expect(
          doc.marriages.single.surnameChoices['a']!.changeSurname,
          isFalse,
        );
        expect(
          doc.marriages.single.surnameChoices['b']!.changeSurname,
          isFalse,
        );
        expect(doc.person('a')!.surname, 'Иванова');
        expect(doc.person('b')!.surname, 'Петрова');
        _converges(events, expected: doc);
      },
    );

    test(
      'shared dates and each partner surname choice are independent LWW registers',
      () {
        final initial = _Client('initial');
        initial.person('a', sex: TreeSex.male, surname: _ivanov);
        initial.person('b', sex: TreeSex.female, surname: _petrov);
        initial.commit(initial.doc.addMarriage('a', 'b', id: 'm'));
        final a = _Client('alice', initial.events);
        final b = _Client('bob', initial.events);
        a.commit(
          a.doc.updateMarriage(
            'a',
            'm',
            startDate: DateTime.utc(2001),
            endDate: null,
          ),
        );
        b.commit(b.doc.setMarriageSurname('b', 'm', changeSurname: false));
        a.commit(
          a.doc.setMarriageSurname(
            'a',
            'm',
            changeSurname: true,
            adoptedSurname: _sidorov,
          ),
        );
        a.receive(b.events);
        expect(a.doc.marriages.single.startDate, DateTime.utc(2001));
        expect(a.doc.person('a')!.surname, 'Сидоров');
        expect(a.doc.person('b')!.surname, 'Петрова');
        _converges([
          ...initial.events,
          ...a.events,
          ...b.events,
        ], expected: a.doc);
      },
    );

    test('birth inheritance and block titles never use current surnames', () {
      final c = _Client('a');
      c.person('father', name: 'Иван', sex: TreeSex.male, surname: _ivanov);
      c.person('wife', sex: TreeSex.female, surname: _petrov);
      c.child('child', 'father', 'wife');
      c.commit(c.doc.setValue('child', 'sex', TreeSex.female));
      c.commit(
        c.doc.addSurnameChange(
          'father',
          id: 'changed',
          surname: _sidorov,
          date: DateTime.utc(2020),
          reason: 'По желанию',
        ),
      );
      expect(c.doc.person('father')!.surname, 'Сидоров');
      expect(c.doc.person('father')!.effectiveSurname, _ivanov);
      expect(c.doc.person('child')!.surname, 'Иванова');
      expect(c.doc.person('child')!.surnameInheritedFrom, 'father');
      expect(c.doc.person('child')!.patronymic, 'Ивановна');
      expect(c.doc.person('father')!.fullName, 'Иван Сидоров');
      expect(
        c.doc
            .person('father')!
            .nameForMode(TreeNameMode.surnameGivenPatronymic),
        'Сидоров Иван',
      );
      expect(surnameForBlock([c.doc.person('father')!]), 'Иванов');
      expect(
        surnameForBlock([c.doc.person('father')!, c.doc.person('child')!]),
        'Ивановы',
      );
      _converges(c.events);
    });

    test(
      'explicit surname snapshots survive partner rename and birth edits',
      () {
        final c = _Client('a');
        c.person('a', sex: TreeSex.male, surname: _ivanov);
        c.person('b', sex: TreeSex.female, surname: _petrov);
        c.commit(
          c.doc.addMarriage('b', 'a', id: 'm', startDate: DateTime.utc(2000)),
        );
        c.commit(
          c.doc.setIndividualSurname('a', text: 'Сидоров', decline: true),
        );
        c.commit(c.doc.editText('a', TreeTextField.name, 'Новое имя')!);
        expect(c.doc.person('b')!.surname, 'Иванова');
        expect(
          c.doc.marriages.single.surnameChoices['b']!.adoptedSurname,
          _ivanov,
        );
        c.commit(
          c.doc.updateMarriage(
            'a',
            'm',
            startDate: DateTime.utc(2000),
            endDate: DateTime.utc(2005),
            endMode: TreeMarriageEndMode.date,
          ),
        );
        expect(
          c.doc.person('b')!.surname,
          'Иванова',
          reason: 'Divorce is not a surname rollback',
        );
        c.commit(c.doc.setValue('a', 'deathDate', '2010-01-01'));
        expect(c.doc.person('b')!.surname, 'Иванова');
        _converges(c.events);
      },
    );

    test(
      'implied defaults use latest concrete surname but never spouse-derived values',
      () {
        final c = _Client('a');
        c.person('a', sex: TreeSex.female, surname: _ivanov);
        c.person('b', sex: TreeSex.female, surname: _petrov);
        c.child('child', 'a', 'b');
        expect(c.doc.person('a')!.surname, 'Петрова');
        expect(c.doc.person('b')!.surname, 'Иванова');
        c.commit(
          c.doc.addSurnameChange('b', id: 'concrete', surname: _sidorov),
        );
        expect(
          c.doc.marriages.single.surnameChoices['a']!.adoptedSurname,
          _sidorov,
        );
        expect(c.doc.person('a')!.surname, 'Сидорова');
        expect(
          c.doc.marriages.single.surnameChoices['b']!.adoptedSurname,
          _ivanov,
        );
        _converges(c.events);
      },
    );

    test(
      'current surname is latest chronology, not event stamp or arrival order',
      () {
        final c = _Client('a');
        c.person('p', sex: TreeSex.female, surname: _ivanov);
        c.commit(
          c.doc.addSurnameChange(
            'p',
            id: 'late-date',
            surname: _sidorov,
            date: DateTime.utc(2020),
            reason: 'Последняя',
          ),
        );
        c.commit(
          c.doc.addSurnameChange(
            'p',
            id: 'earlier-date',
            surname: _petrov,
            date: DateTime.utc(2000),
            reason: 'Более ранняя',
          ),
        );
        c.commit(
          c.doc.addSurnameChange(
            'p',
            id: 'undated',
            surname: const TreeSurname(text: 'А'),
            reason: 'Без даты',
          ),
        );
        expect(c.doc.person('p')!.surname, 'Сидорова');
        expect(c.doc.historyOf('p').map((row) => row.id), [
          'undated',
          'earlier-date',
          'late-date',
        ]);
        c.commit(
          c.doc.updateSurnameChange(
            'p',
            'late-date',
            surname: _sidorov,
            date: DateTime.utc(1990),
            reason: 'Исправлена дата',
          ),
        );
        expect(c.doc.person('p')!.surname, 'Петрова');
        c.commit(c.doc.removeSurnameChange('p', 'earlier-date'));
        expect(c.doc.person('p')!.surname, 'Сидорова');
        c.commit(c.doc.removeSurnameChange('p', 'late-date'));
        c.commit(c.doc.removeSurnameChange('p', 'undated'));
        expect(c.doc.person('p')!.surname, 'Иванова');
        expect(
          () => c.doc.addSurnameChange('p', id: 'late-date', surname: _petrov),
          throwsArgumentError,
        );
        _converges(c.events);
      },
    );

    test('surname history removal is permanent and person scoped', () {
      final initial = _Client('initial');
      initial.person('p', surname: _ivanov);
      initial.person('other', surname: _ivanov);
      initial.commit(
        initial.doc.addSurnameChange('p', id: 'same-id', surname: _petrov),
      );
      initial.commit(
        initial.doc.addSurnameChange('other', id: 'same-id', surname: _sidorov),
      );
      final a = _Client('a', initial.events);
      final b = _Client('b', initial.events);
      a.commit(a.doc.removeSurnameChange('p', 'same-id'));
      b.commit(
        b.doc.updateSurnameChange(
          'p',
          'same-id',
          surname: _sidorov,
          date: DateTime.utc(2000),
          reason: 'Поздняя правка',
        ),
      );
      a.receive(b.events);
      expect(a.doc.person('p')!.surname, 'Иванов');
      expect(a.doc.person('other')!.surname, 'Сидоров');
      expect(a.doc.historyOf('p'), isEmpty);
      _converges([
        ...initial.events,
        ...a.events,
        ...b.events,
      ], expected: a.doc);
    });

    test(
      'same surnames produce no marriage change row and generic reason remains',
      () {
        final c = _Client('a');
        c.person('a', surname: _ivanov);
        c.person('b', sex: TreeSex.female, surname: _ivanov);
        c.commit(c.doc.addMarriage('b', 'a', id: 'same'));
        expect(
          c.doc.marriages.single.surnameChoices['b']!.changeSurname,
          isTrue,
        );
        expect(c.doc.historyOf('b').single.surnameChange, isNull);
        expect(c.doc.surnameChangesOf('b'), isEmpty);
        c.commit(
          c.doc.addSurnameChange(
            'b',
            id: 'reason',
            surname: _ivanov,
            reason: 'Фамилия осталась прежней',
          ),
        );
        final generic = c.doc.historyOf('b').last.surnameChange!;
        expect(generic.reason, 'Фамилия осталась прежней');
        expect(generic.changesSurname, isFalse);
        expect(c.doc.person('b')!.surname, 'Иванова');
        c.person('no-surname', sex: TreeSex.male);
        c.commit(c.doc.addMarriage('b', 'no-surname', id: 'empty-partner'));
        expect(
          c.doc.person('b')!.surname,
          'Иванова',
          reason: 'Null snapshot is not a surname clear',
        );
        expect(
          c.doc
              .historyOf('b')
              .where((r) => r.id == 'empty-partner')
              .single
              .surnameChange,
          isNull,
        );
        _converges(c.events);
      },
    );

    test(
      'undated no-change marriages precede undated surnames and sort by seniority',
      () {
        final c = _Client('a');
        c.person('p', surname: _ivanov);
        c.person('young', name: 'А', birth: '1990-01-01');
        c.person('old', name: 'Я', birth: '1900-01-01');
        c.person('unknown', name: 'Б');
        for (final id in ['young', 'old', 'unknown']) {
          c.commit(
            c.doc.addMarriage('p', id, id: 'm-$id', changeSurname: false),
          );
        }
        c.commit(
          c.doc.addSurnameChange('p', id: 'undated-z', surname: _sidorov),
        );
        c.commit(
          c.doc.addSurnameChange(
            'p',
            id: 'undated-a',
            surname: const TreeSurname(text: 'А'),
          ),
        );
        c.commit(
          c.doc.addSurnameChange(
            'p',
            id: 'dated',
            surname: _petrov,
            date: DateTime.utc(1980),
          ),
        );
        expect(c.doc.historyOf('p').map((r) => r.id), [
          'm-unknown',
          'm-old',
          'm-young',
          'undated-a',
          'undated-z',
          'dated',
        ]);
        _converges(c.events);
      },
    );

    test(
      'marriage sorting uses start or oldest common DOB, never end date',
      () {
        final c = _Client('a');
        for (final id in ['p', 'a', 'b', 'c']) {
          c.person(id);
        }
        c.child('child', 'p', 'a', birth: '2000-01-01');
        c.commit(
          c.doc.addMarriage(
            'p',
            'b',
            id: 'dated',
            startDate: DateTime.utc(1990),
          ),
        );
        c.commit(
          c.doc.addMarriage(
            'p',
            'c',
            id: 'end-only',
            endDate: DateTime.utc(2100),
            endMode: TreeMarriageEndMode.date,
          ),
        );
        expect(c.doc.historyOf('p').map((r) => r.id), [
          'end-only',
          'dated',
          c.doc.marriages.where((m) => m.isImplied).single.id,
        ]);
        final implied = c.doc.marriages.where((m) => m.isImplied).single;
        expect(implied.orderingDate, DateTime.utc(2000));
        expect(implied.startDate, isNull);
        _converges(c.events);
      },
    );

    test(
      'end modes preserve unknown, lifelong and strict dated period choices',
      () {
        final c = _Client('a');
        c.person('a');
        c.person('b');
        c.commit(c.doc.addMarriage('a', 'b', id: 'm'));
        expect(c.doc.marriages.single.endMode, TreeMarriageEndMode.unknown);
        c.commit(
          c.doc.updateMarriage(
            'a',
            'm',
            startDate: DateTime.utc(2000),
            endDate: null,
            endMode: TreeMarriageEndMode.lifelong,
          ),
        );
        final m = c.doc.marriages.single;
        expect(m.lifelongEndDate(null, null), isNull);
        expect(
          m.lifelongEndDate(DateTime.utc(2020), DateTime.utc(2010)),
          DateTime.utc(2010),
        );
        expect(m.lifelongEndDate(null, DateTime.utc(2010)), DateTime.utc(2010));
        expect(
          () => c.doc.updateMarriage(
            'a',
            'm',
            startDate: DateTime.utc(2020),
            endDate: DateTime.utc(2000),
            endMode: TreeMarriageEndMode.date,
          ),
          throwsFormatException,
        );
        expect(
          () => c.doc.updateMarriage(
            'a',
            'm',
            startDate: null,
            endDate: DateTime.utc(2000),
          ),
          throwsFormatException,
        );
        expect(
          () => c.doc.updateMarriage(
            'a',
            'm',
            startDate: null,
            endDate: null,
            endMode: TreeMarriageEndMode.date,
          ),
          throwsFormatException,
        );
        c.commit(
          c.doc.updateMarriage('b', 'm', startDate: null, endDate: null),
        );
        expect(c.doc.marriages.single.endMode, TreeMarriageEndMode.unknown);
        expect(c.doc.marriages.single.hasExplicitDates, isFalse);
        _converges(c.events);
      },
    );

    test(
      'deleted partner hides graph but explicit survivor history remains editable',
      () {
        final c = _Client('a');
        c.person('a', surname: _ivanov);
        c.person('b', sex: TreeSex.female, surname: _petrov);
        c.commit(c.doc.addMarriage('b', 'a', id: 'm'));
        c.commit(c.doc.deletePerson('a'));
        expect(c.doc.marriages, isEmpty);
        expect(c.doc.partnersOf('b'), isEmpty);
        expect(c.doc.historyOf('a'), isEmpty);
        expect(c.doc.historyOf('b').single.marriage!.otherPersonId('b'), 'a');
        expect(c.doc.person('b')!.surname, 'Иванова');
        c.commit(
          c.doc.updateMarriage(
            'b',
            'm',
            startDate: DateTime.utc(2000),
            endDate: null,
          ),
        );
        c.commit(
          c.doc.setMarriageSurname(
            'b',
            'm',
            changeSurname: true,
            adoptedSurname: _sidorov,
          ),
        );
        expect(c.doc.person('b')!.surname, 'Сидорова');
        c.commit(c.doc.removeMarriage('b', 'm'));
        expect(c.doc.historyOf('b'), isEmpty);
        expect(c.doc.person('b')!.surname, 'Петрова');
        expect(c.doc.person('a'), isNull);
        _converges(c.events);
      },
    );

    test(
      'unknown/root independent pair suppression survives late identities',
      () {
        final builder = _Client('builder');
        builder.person('a');
        builder.person('b', sex: TreeSex.female);
        builder.child('child', 'a', 'b');
        final removal = builder.doc.removeMarriage(
          'a',
          builder.doc.marriages.single.id,
        );
        final early = StampedTreeOperation(
          id: 'early-remove',
          author: 'early',
          clock: 0,
          createdAt: DateTime.utc(2026),
          operation: removal,
        );
        final doc = TreeDocument()..merge([early]);
        doc.merge(builder.events);
        expect(doc.marriages, isEmpty);
        expect(doc.partnersOf('a').single.id, 'b');
        final rootDelete = StampedTreeOperation(
          id: 'delete-root',
          author: 'early',
          clock: 0,
          createdAt: DateTime.utc(2026),
          operation: doc.deletePerson(rootTreePersonId),
        );
        doc.merge([rootDelete]);
        expect(doc.marriages, isEmpty);
        _converges([early, rootDelete, ...builder.events], expected: doc);
      },
    );

    test(
      'public projections are immutable old snapshots and missing lookups are empty',
      () {
        final c = _Client('a');
        c.person('a', surname: _ivanov);
        c.person('b', sex: TreeSex.female, surname: _petrov);
        c.commit(c.doc.addMarriage('a', 'b', id: 'm'));
        final marriages = c.doc.marriages;
        final history = c.doc.historyOf('b');
        final person = c.doc.person('b')!;
        expect(() => marriages.clear(), throwsUnsupportedError);
        expect(
          () => marriages.single.surnameChoices.clear(),
          throwsUnsupportedError,
        );
        expect(() => history.clear(), throwsUnsupportedError);
        expect(() => c.doc.partnersOf('a').clear(), throwsUnsupportedError);
        expect(
          () => c.doc.surnameChangesOf('b').clear(),
          throwsUnsupportedError,
        );
        expect(() => c.doc.marriagesOf('a').clear(), throwsUnsupportedError);
        c.commit(c.doc.removeMarriage('a', 'm'));
        expect(marriages.single.id, 'm');
        expect(history.single.surnameChange!.surname, _ivanov);
        expect(person.surname, 'Иванова');
        expect(c.doc.person('b')!.surname, 'Петрова');
        for (final id in ['missing', '']) {
          expect(c.doc.historyOf(id), isEmpty);
          expect(c.doc.marriagesOf(id), isEmpty);
          expect(c.doc.surnameChangesOf(id), isEmpty);
          expect(c.doc.partnersOf(id), isEmpty);
        }
      },
    );

    test(
      'concrete surname chronology uses common-child hint without inventing dates',
      () {
        final c = _Client('a');
        c.person('p', sex: TreeSex.female, surname: _ivanov);
        c.person('first', surname: _petrov);
        c.person('second', sex: TreeSex.female, surname: _sidorov);
        c.child('old-child', 'first', 'p', birth: '2000-01-01');
        c.commit(
          c.doc.addMarriage('p', 'first', id: 'persisted', changeSurname: true),
        );
        c.commit(
          c.doc.addSurnameChange(
            'p',
            id: 'earlier',
            surname: _sidorov,
            date: DateTime.utc(1990),
          ),
        );
        c.child('later-child', 'p', 'second', birth: '2010-01-01');
        final later = c.doc.marriages.where((m) => m.isImplied).single;
        expect(later.surnameChoices['second']!.adoptedSurname, _petrov);
        expect(c.doc.person('second')!.surname, 'Петрова');
        expect(
          c.doc.marriages.where((m) => m.id == 'persisted').single.startDate,
          isNull,
        );
        expect(
          c.doc
              .surnameChangesOf('p')
              .where((s) => s.marriageId == 'persisted')
              .single
              .date,
          isNull,
        );
        _converges(c.events);
      },
    );

    test('late surname tombstone wins an unseen add and all later updates', () {
      final builder = _Client('builder');
      builder.person('p', surname: _ivanov);
      final add = builder.doc.addSurnameChange('p', id: 's', surname: _petrov);
      final remove = TreeOperation.fromJson({
        'type': 'removeSurnameChange',
        'personId': 'p',
        'itemId': 's',
      });
      final early = StampedTreeOperation(
        id: 'remove',
        author: 'a',
        clock: 0,
        createdAt: DateTime.utc(2026),
        operation: remove,
      );
      final late = StampedTreeOperation(
        id: 'add',
        author: 'a',
        clock: 100,
        createdAt: DateTime.utc(2026),
        operation: add,
      );
      final doc = TreeDocument()..merge([early]);
      doc.merge([...builder.events, late]);
      expect(doc.person('p')!.surname, 'Иванов');
      expect(doc.historyOf('p'), isEmpty);
      expect(
        () => doc.addSurnameChange('p', id: 's', surname: _sidorov),
        throwsArgumentError,
      );
      _converges([early, ...builder.events, late], expected: doc);
    });

    test(
      'period and surname edits use clock author id and keep immutable endpoints',
      () {
        final c = _Client('seed');
        c.person('a', surname: _ivanov);
        c.person('b', sex: TreeSex.female, surname: _petrov);
        c.person('wrong');
        c.commit(c.doc.addMarriage('a', 'b', id: 'm'));
        StampedTreeOperation stamp(
          String id,
          String author,
          TreeOperation op,
        ) => StampedTreeOperation(
          id: id,
          author: author,
          clock: 100,
          createdAt: DateTime.utc(id == 'z' ? 1900 : 2099),
          operation: op,
        );
        final lower = stamp(
          'a',
          'same',
          c.doc.updateMarriage(
            'a',
            'm',
            startDate: DateTime.utc(2000),
            endDate: DateTime.utc(2005),
            endMode: TreeMarriageEndMode.date,
          ),
        );
        final higher = stamp(
          'z',
          'same',
          c.doc.updateMarriage(
            'b',
            'm',
            startDate: DateTime.utc(2010),
            endDate: null,
            endMode: TreeMarriageEndMode.lifelong,
          ),
        );
        final wrong = stamp(
          'zz',
          'zz',
          TreeOperation.fromJson({
            'type': 'removeMarriage',
            'personId': 'a',
            'partnerId': 'wrong',
            'itemId': 'm',
          }),
        );
        c.doc.merge([wrong, higher, lower]);
        expect(c.doc.marriages.single.startDate, DateTime.utc(2010));
        expect(c.doc.marriages.single.endDate, isNull);
        expect(c.doc.marriages.single.endMode, TreeMarriageEndMode.lifelong);
        expect(c.doc.marriages.single.otherPersonId('a'), 'b');
        final keep = stamp(
          'keep',
          'zz',
          c.doc.setMarriageSurname('b', 'm', changeSurname: false),
        );
        final adopt = stamp(
          'adopt',
          'aa',
          c.doc.setMarriageSurname(
            'b',
            'm',
            changeSurname: true,
            adoptedSurname: _sidorov,
          ),
        );
        c.doc.merge([keep, adopt]);
        expect(c.doc.person('b')!.surname, 'Петрова');
        _converges([
          ...c.events,
          lower,
          higher,
          wrong,
          keep,
          adopt,
        ], expected: c.doc);
      },
    );

    test(
      'atomic new-partner seed participates in earliest identity and LWW birth surname',
      () {
        final seed = _Client('seed');
        seed.person('a');
        final atomic = seed.doc.addMarriage(
          'a',
          'b',
          id: 'm',
          newPartner: const TreeNewMarriagePartner(
            name: 'Atomic',
            birthSurname: _ivanov,
          ),
        );
        final creation = StampedTreeOperation(
          id: 'atomic',
          author: 'a',
          clock: 10,
          createdAt: DateTime.utc(2026),
          operation: atomic,
        );
        final earlierSurname = StampedTreeOperation(
          id: 'surname',
          author: 'a',
          clock: 1,
          createdAt: DateTime.utc(2026),
          operation: TreeOperation.fromJson({
            'type': 'setSurname',
            'personId': 'b',
            'scope': 'individual',
            'familyKey': null,
            'text': 'Петров',
            'decline': true,
          }),
        );
        final doc = TreeDocument()
          ..merge([...seed.events, earlierSurname, creation]);
        expect(doc.person('b')!.effectiveSurname, _ivanov);
        final oldCreation = StampedTreeOperation(
          id: 'older-identity',
          author: 'a',
          clock: 0,
          createdAt: DateTime.utc(2026),
          operation: TreeDocument().createPerson('b', name: 'Earlier'),
        );
        doc.merge([oldCreation]);
        expect(doc.person('b')!.name, 'Earlier');
        expect(
          doc.person('b')!.effectiveSurname,
          _petrov,
          reason: 'Losing atomic creation must not seed birth fields',
        );
        _converges([
          ...seed.events,
          oldCreation,
          earlierSurname,
          creation,
        ], expected: doc);
      },
    );

    test(
      'accepted parent projection rejects false common pairs and ignores deleted children',
      () {
        final c = _Client('a');
        for (final id in ['a', 'b', 'child']) {
          c.person(id);
        }
        c.commit(c.doc.setValue('child', 'fatherId', 'a'));
        c.commit(
          TreeOperation.fromJson({
            'type': 'setValue',
            'personId': 'child',
            'field': 'motherId',
            'value': 'b',
          }),
        );
        c.commit(
          TreeOperation.fromJson({
            'type': 'setValue',
            'personId': 'b',
            'field': 'fatherId',
            'value': 'child',
          }),
        );
        expect(c.doc.person('child')!.motherId, isNull);
        expect(c.doc.marriages, isEmpty);
        c.commit(c.doc.setValue('b', 'fatherId', null));
        expect(c.doc.marriages.single.otherPersonId('a'), 'b');
        c.commit(c.doc.deletePerson('child'));
        expect(c.doc.marriages, isEmpty);
        _converges(c.events);
      },
    );

    test(
      'long colon and astral IDs keep deterministic implied identity and suppression',
      () {
        final c = _Client('a');
        final a = '${'a' * 254}:a';
        final b = '${'b' * 254}🌳';
        c.person(a, surname: _ivanov);
        c.person(b, sex: TreeSex.female, surname: _petrov);
        c.child('child', a, b);
        final id = c.doc.marriages.single.id;
        expect(id.length, greaterThan(256));
        expect(id.length, lessThanOrEqualTo(550));
        c.commit(c.doc.updateMarriage(b, id, startDate: null, endDate: null));
        expect(c.doc.marriages.single.id, id);
        c.commit(c.doc.removeMarriage(a, id));
        c.child('another', b, a);
        expect(c.doc.marriages, isEmpty);
        _converges(c.events);
      },
    );

    test(
      'multiline surname reasons round trip while names and surnames stay single-line',
      () {
        final c = _Client('a');
        c.person('p', surname: _ivanov);
        const reason = 'Первая строка\nВторая строка\r\nТретья строка';
        final op = c.doc.addSurnameChange(
          'p',
          id: 'multiline',
          surname: _petrov,
          reason: '  $reason  ',
        );
        final restored = TreeOperation.fromJson(
          jsonDecode(jsonEncode(op.toJson())),
        );
        expect(restored.toJson()['reason'], reason);
        c.commit(restored);
        expect(c.doc.historyOf('p').single.surnameChange!.reason, reason);
        expect(
          () => c.doc.addSurnameChange('p', surname: _petrov, reason: 'a\tb'),
          throwsFormatException,
        );
        expect(
          () => c.doc.addSurnameChange(
            'p',
            surname: const TreeSurname(text: 'a\nb'),
          ),
          throwsFormatException,
        );
        expect(
          () => c.doc.addMarriage(
            'p',
            'new',
            newPartner: const TreeNewMarriagePartner(name: 'a\nb'),
          ),
          throwsFormatException,
        );
        _converges(c.events);
      },
    );

    test(
      'strict schemas reject malformed dates, controls, Unicode, IDs and shapes',
      () {
        final c = _Client('a');
        c.person('a');
        c.person('b');
        final marriage = c.doc.addMarriage('a', 'b', id: 'm').toJson();
        final change = c.doc
            .addSurnameChange('a', id: 's', surname: _ivanov)
            .toJson();
        final bad = <Map<String, Object?>>[
          {...marriage, 'extra': true},
          {...marriage}..remove('newPartner'),
          {...marriage, 'partnerId': 'a'},
          {...marriage, 'partnerId': 'a\u0085'},
          {...marriage, 'itemId': 'implied:wrong'},
          {...marriage, 'itemId': 'x' * 257},
          {...marriage, 'endMode': 'dated'},
          {...marriage, 'endMode': 'date'},
          {...marriage, 'startDate': '2023-02-29'},
          {...marriage, 'startDate': '2000-1-01'},
          {...marriage, 'startDate': '0000-01-01'},
          {...marriage, 'startDate': 1},
          {
            ...marriage,
            'startDate': '2020-01-01',
            'endDate': '2000-01-01',
            'endMode': 'date',
          },
          {...marriage, 'surnameChoices': null},
          {
            ...marriage,
            'surnameChoices': {
              'a': {'changeSurname': false, 'surname': null},
            },
          },
          {
            ...marriage,
            'surnameChoices': {
              'a': {'changeSurname': false, 'surname': _surname(_ivanov)},
              'b': {'changeSurname': false, 'surname': null},
            },
          },
          {
            ...marriage,
            'newPartner': {'name': 'a', 'sex': 'male', 'birthDate': null},
          },
          {
            ...marriage,
            'newPartner': {
              'name': 'a\n',
              'sex': 'male',
              'birthDate': null,
              'birthSurname': null,
            },
          },
          {
            ...marriage,
            'newPartner': {
              'name': '\ud800',
              'sex': 'male',
              'birthDate': null,
              'birthSurname': null,
            },
          },
          {
            ...marriage,
            'newPartner': {
              'name': 'a' * 201,
              'sex': 'male',
              'birthDate': null,
              'birthSurname': null,
            },
          },
          {...change, 'surname': null},
          {
            ...change,
            'surname': {'text': '', 'decline': false},
          },
          {
            ...change,
            'surname': {'text': ' x', 'decline': false},
          },
          {
            ...change,
            'surname': {'text': 'x', 'decline': 1},
          },
          {
            ...change,
            'surname': {'text': '\ud800', 'decline': false},
          },
          {
            ...change,
            'surname': {'text': 'x\u009f', 'decline': false},
          },
          {
            ...change,
            'surname': {'text': 'x' * 201, 'decline': false},
          },
          {
            ...change,
            'surname': {'text': 'x', 'decline': false, 'extra': 1},
          },
          {...change, 'date': '2000-01-01T00:00:00Z'},
          {...change, 'reason': '\udc00'},
          {...change, 'reason': 'reason\ttext'},
          {...change, 'reason': ' reason'},
          {...change, 'reason': 'x' * 1001},
          {...change, 'reason': 1},
        ];
        for (final json in bad) {
          expect(
            () => TreeOperation.fromJson(json),
            throwsFormatException,
            reason: '$json',
          );
          expect(TreeOperation.isValid(json), isFalse);
        }
        final astralSurname = TreeSurname(text: '🌳' * 200);
        final valid = c.doc.addSurnameChange(
          'a',
          surname: astralSurname,
          reason: '🌳' * 1000,
        );
        expect(TreeOperation.isValid(valid.toJson()), isTrue);
        expect(
          () => (valid.toJson()['surname'] as Map).clear(),
          throwsUnsupportedError,
        );
        expect(
          TreeOperation.fromJson(
            jsonDecode(jsonEncode(valid.toJson())),
          ).toJson(),
          valid.toJson(),
        );
        expect(valid.isRoomScoped, isFalse);
        expect(valid.fieldKey, startsWith('surnameChange:'));
        expect(valid.description, 'Добавлена смена фамилии');
      },
    );

    test(
      'all new operations round trip without modifying historical names or events',
      () {
        final c = _Client('a');
        c.person('a', name: 'Иван Иванович Иванов', surname: _ivanov);
        c.person(
          'b',
          name: 'Анна Петровна',
          sex: TreeSex.female,
          surname: _petrov,
        );
        final initial = jsonEncode(c.events.map((e) => e.toJson()).toList());
        c.commit(c.doc.addMarriage('b', 'a', id: 'm'));
        c.commit(
          c.doc.updateMarriage(
            'b',
            'm',
            startDate: DateTime.utc(2000),
            endDate: null,
          ),
        );
        c.commit(
          c.doc.setMarriageSurname(
            'a',
            'm',
            changeSurname: true,
            adoptedSurname: _sidorov,
          ),
        );
        c.commit(
          c.doc.addSurnameChange(
            'b',
            id: 's',
            surname: _sidorov,
            reason: 'Причина',
          ),
        );
        c.commit(
          c.doc.updateSurnameChange(
            'b',
            's',
            surname: _petrov,
            date: DateTime.utc(2010),
          ),
        );
        c.commit(c.doc.removeSurnameChange('b', 's'));
        c.commit(c.doc.removeMarriage('b', 'm'));
        final encoded = jsonEncode(c.events.map((e) => e.toJson()).toList());
        final restored = [
          for (final json in jsonDecode(encoded) as List)
            StampedTreeOperation.fromJson(json),
        ];
        expect(jsonEncode(restored.map((e) => e.toJson()).toList()), encoded);
        expect(
          jsonEncode(
            c.events
                .take(jsonDecode(initial).length as int)
                .map((e) => e.toJson())
                .toList(),
          ),
          initial,
        );
        expect(c.doc.person('a')!.name, 'Иван Иванович Иванов');
        expect(c.doc.person('b')!.name, 'Анна Петровна');
        expect(_view(TreeDocument()..merge(restored)), _view(c.doc));
        _converges(c.events);
      },
    );
  });
}
