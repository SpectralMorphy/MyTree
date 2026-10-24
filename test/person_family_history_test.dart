import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/room_document.dart';
import 'package:mytree_webrtc_demo/room_session.dart';
import 'package:mytree_webrtc_demo/storage/room_store.dart';
import 'package:mytree_webrtc_demo/tree/tree_document.dart';
import 'package:mytree_webrtc_demo/ui/person_family_history.dart';
import 'package:mytree_webrtc_demo/ui/biography_section.dart';

class _Session extends RoomSession {
  _Session()
    : super(
        roomId: '0123456789abcdef0123456789abcdef',
        actorId: 'self',
        store: MemoryRoomStore(),
        existingMember: true,
      );
  final document = TreeDocument();
  final operations = <TreeOperation>[];
  final records = <RoomEdit>[];
  int clock = 0;
  int retries = 0;
  bool editor = true;
  bool fail = false;
  int rejectSurnameBeforeAppend = 0;
  final rejected = <TreeOperation>[];
  Completer<void>? hold;
  String? saveError;

  @override
  TreeDocument get tree => document;
  @override
  List<RoomEdit> get changes => records;
  @override
  bool get canEdit => editor;
  @override
  String? get storageError => saveError;

  void seed(TreeOperation operation) {
    final stamp = ++clock;
    document.merge([
      StampedTreeOperation(
        id: 'event-$stamp',
        author: actorId,
        clock: stamp,
        createdAt: DateTime.utc(2026),
        operation: operation,
      ),
    ]);
  }

  @override
  Future<void> applyTreeOperation(TreeOperation operation) async {
    if (!editor) throw StateError('Только редактор');
    if (operation.type == 'setMarriageSurname' &&
        rejectSurnameBeforeAppend > 0) {
      rejectSurnameBeforeAppend--;
      rejected.add(operation);
      throw StateError('history size limit');
    }
    operations.add(operation);
    seed(operation);
    records.add(
      RoomEdit(
        id: 'event-$clock',
        author: actorId,
        clock: clock,
        createdAt: DateTime.utc(2026).millisecondsSinceEpoch,
        kind: RoomEditKind.tree,
        text: jsonEncode(operation.toJson()),
      ),
    );
    if (fail) saveError = 'disk full';
    notifyListeners();
    await hold?.future;
    if (fail) throw StateError('disk full');
  }

  @override
  Future<void> flush() async {
    retries++;
    if (fail) throw StateError('disk full');
    saveError = null;
    notifyListeners();
  }

  void refresh() => notifyListeners();
}

_Session _family({bool child = false, TreeSex sex = TreeSex.female}) {
  final session = _Session();
  final tree = session.tree;
  session.seed(tree.editText(rootTreePersonId, TreeTextField.name, 'Анна')!);
  session.seed(tree.setValue(rootTreePersonId, 'sex', sex.name));
  session.seed(
    tree.setIndividualSurname(rootTreePersonId, text: 'Сидоров', decline: true),
  );
  session.seed(tree.createPerson('partner', name: 'Иван', sex: TreeSex.male));
  session.seed(
    tree.setIndividualSurname('partner', text: 'Иванов', decline: true),
  );
  session.seed(tree.setValue(rootTreePersonId, 'alive', true));
  session.seed(tree.setValue('partner', 'alive', true));
  if (child) {
    session.seed(tree.createPerson('child', name: 'Дочь', sex: TreeSex.female));
    session.seed(tree.setValue('child', 'fatherId', 'partner'));
    session.seed(tree.setValue('child', 'motherId', rootTreePersonId));
    session.seed(tree.setValue('child', 'birthDate', '2000-02-03'));
  }
  return session;
}

Future<void> _mount(
  WidgetTester tester,
  _Session session, {
  bool editing = false,
  Brightness brightness = Brightness.light,
  Size size = const Size(480, 1000),
  ValueNotifier<TreeNameMode>? nameMode,
  ValueChanged<String>? onSelect,
  Future<String?> Function(String, bool Function(TreePerson))? onPick,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(session.dispose);
  final mode = nameMode ?? ValueNotifier(TreeNameMode.givenSurname);
  if (nameMode == null) addTearDown(mode.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: PersonFamilyHistory(
            session: session,
            personId: rootTreePersonId,
            editing: editing,
            nameMode: mode,
            onSelect: onSelect ?? (_) {},
            onPickFromTree: onPick,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Finder get _save => find.byKey(const Key('save-family-history'));
Future<void> _existing(WidgetTester tester) async {
  await _tap(tester, find.widgetWithText(ChoiceChip, 'Из дерева'));
  await _tap(tester, find.byKey(const Key('marriage-pick-from-tree')));
}

Future<void> _date(WidgetTester tester) async {
  await _tap(tester, find.byKey(const Key('history-start-date')));
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

Future<void> _endMode(WidgetTester tester, String text) async {
  await _tap(tester, find.widgetWithText(ChoiceChip, text));
  if (text == 'Дата') {
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  }
}

String _entryIdentity(TreeFamilyHistoryEntry entry) =>
    '${entry.marriage != null ? 'marriage' : 'surnameChange'}-${entry.id}';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('section header is larger than surname rows in $brightness', (
      tester,
    ) async {
      final session = _family(child: true);
      session.seed(
        session.tree.setValue(rootTreePersonId, 'birthDate', '1980-05-06'),
      );
      await _mount(
        tester,
        session,
        brightness: brightness,
        size: const Size(320, 844),
      );
      final header = find.byType(BiographySectionHeader);
      final title = tester.widget<Text>(find.text('Фамилии и браки'));
      final surname = tester.widget<Text>(find.text('Сидорова'));
      expect(title.style!.fontSize, greaterThan(surname.style!.fontSize!));
      expect(surname.style!.fontSize, 16);
      final decoration = tester.widget<DecoratedBox>(
        find.descendant(of: header, matching: find.byType(DecoratedBox)),
      );
      final color = (decoration.decoration as BoxDecoration).color!;
      expect(
        color,
        Theme.of(
          tester.element(header),
        ).colorScheme.primaryContainer.withValues(alpha: .35),
      );
      expect(find.text('06.05.1980'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(session.operations, isEmpty);
    });
  }

  for (final editing in [false, true]) {
    testWidgets('unchanged birth surname is not repeated; editing=$editing', (
      tester,
    ) async {
      final session = _family();
      await _mount(tester, session, editing: editing);
      expect(
        find.byKey(const Key('family-history-birth-surname')),
        findsNothing,
      );
      expect(find.text('Сидорова'), findsNothing);
      expect(find.text('при рождении'), findsNothing);
      expect(session.operations, isEmpty);
    });
  }

  testWidgets(
    'inherited birth surname precedes changes and disappears after the last removal',
    (tester) async {
      final session = _family();
      final tree = session.tree;
      session.seed(tree.setIndividualSurname(rootTreePersonId, text: null));
      session.seed(
        tree.createPerson('father', name: 'Пётр', sex: TreeSex.male),
      );
      session.seed(
        tree.setIndividualSurname('father', text: 'Петров', decline: true),
      );
      session.seed(tree.setValue(rootTreePersonId, 'fatherId', 'father'));
      session.seed(
        tree.addSurnameChange(
          rootTreePersonId,
          id: 'change',
          surname: const TreeSurname(text: 'Седых'),
          reason: 'По желанию',
        ),
      );
      await _mount(tester, session, editing: true);
      final birth = find.byKey(const Key('family-history-birth-surname'));
      expect(
        find.descendant(of: birth, matching: find.text('Петрова')),
        findsOneWidget,
      );
      expect(find.text('при рождении'), findsOneWidget);
      expect(
        find.descendant(of: birth, matching: find.text('?')),
        findsOneWidget,
      );
      session.seed(tree.setValue(rootTreePersonId, 'birthDate', '1980-05-06'));
      session.refresh();
      await tester.pumpAndSettle();
      final birthDate = find.descendant(
        of: birth,
        matching: find.text('06.05.1980'),
      );
      expect(birthDate, findsOneWidget);
      expect(
        find.descendant(of: birth, matching: find.text('?')),
        findsNothing,
      );
      expect(
        tester.getRect(birthDate).right,
        lessThan(tester.getRect(find.text('Петрова')).left),
      );
      expect(
        tester.getRect(birth).bottom,
        lessThanOrEqualTo(tester.getRect(find.text('Седых')).top),
      );
      expect(
        find.descendant(of: birth, matching: find.byType(IconButton)),
        findsNothing,
      );
      expect(session.operations, isEmpty);
      await _tap(
        tester,
        find.byKey(
          const ValueKey('delete-family-history-surnameChange-change'),
        ),
      );
      await _tap(
        tester,
        find.byKey(const Key('confirm-delete-family-history')),
      );
      expect(find.text('при рождении'), findsNothing);
      expect(birth, findsNothing);
      expect(session.operations.single.type, 'removeSurnameChange');
    },
  );

  testWidgets(
    'inferred marriage has no displayed child-derived date; names browse in both modes',
    (tester) async {
      final session = _family(child: true);
      final mode = ValueNotifier(TreeNameMode.givenSurname);
      addTearDown(mode.dispose);
      final selected = <String>[];
      await _mount(tester, session, nameMode: mode, onSelect: selected.add);
      expect(find.text('Брак с '), findsOneWidget);
      expect(find.text('Иван Иванов'), findsOneWidget);
      expect(find.text('Сидорова'), findsOneWidget);
      expect(find.text('при рождении'), findsOneWidget);
      expect(find.textContaining('03.02.2000'), findsNothing);
      await tester.tap(find.text('Иван Иванов'));
      expect(selected, ['partner']);
      mode.value = TreeNameMode.surnameGivenPatronymic;
      await tester.pumpAndSettle();
      expect(find.text('Иванов Иван'), findsOneWidget);
      expect(session.operations, isEmpty);
    },
  );

  testWidgets(
    'no surname change means no first surname/date row; real marriage boundaries only',
    (tester) async {
      final session = _family();
      session.seed(
        session.tree.addMarriage(
          rootTreePersonId,
          'partner',
          id: 'marriage',
          changeSurname: false,
          startDate: DateTime.utc(1990, 4, 5),
        ),
      );
      await _mount(tester, session);
      expect(
        find.byKey(const ValueKey('family-history-surname-marriage-marriage')),
        findsNothing,
      );
      expect(find.text('(05.04.1990 — ?)'), findsOneWidget);
      expect(find.text('Иванова'), findsNothing);
      expect(find.text('Сидорова'), findsNothing);
      expect(find.text('при рождении'), findsNothing);
      expect(session.operations, isEmpty);
    },
  );

  testWidgets(
    'lifelong is current only for two explicitly alive people; known death bounds end',
    (tester) async {
      final session = _family();
      session.seed(
        session.tree.addMarriage(
          rootTreePersonId,
          'partner',
          id: 'marriage',
          changeSurname: false,
          startDate: DateTime.utc(1990),
          endMode: TreeMarriageEndMode.lifelong,
        ),
      );
      await _mount(tester, session);
      expect(find.text('(01.01.1990 — н.в)'), findsOneWidget);
      session.seed(session.tree.setValue('partner', 'alive', false));
      session.refresh();
      await tester.pumpAndSettle();
      expect(find.text('(01.01.1990 — ?)'), findsOneWidget);
      session.seed(session.tree.setValue('partner', 'deathDate', '2020-06-07'));
      session.refresh();
      await tester.pumpAndSettle();
      expect(find.text('(01.01.1990 — 07.06.2020)'), findsOneWidget);
      session.seed(
        session.tree.setValue(rootTreePersonId, 'deathDate', '2018-03-04'),
      );
      session.refresh();
      await tester.pumpAndSettle();
      expect(find.text('(01.01.1990 — 04.03.2018)'), findsOneWidget);
      expect(session.operations, isEmpty);
    },
  );

  testWidgets(
    'marriage caption keeps premarital surname and puts period below on the right',
    (tester) async {
      final session = _family();
      final tree = session.tree;
      session.seed(
        tree.addMarriage(
          rootTreePersonId,
          'partner',
          id: 'period',
          changeSurname: false,
          startDate: DateTime.utc(1990),
        ),
      );
      session.seed(
        tree.addSurnameChange(
          'partner',
          id: 'later',
          surname: const TreeSurname(text: 'Петров', decline: true),
          date: DateTime.utc(2000),
        ),
      );
      await _mount(tester, session);
      expect(find.text('Иван Иванов'), findsOneWidget);
      expect(find.text('Иван Петров'), findsNothing);
      final range = find.byKey(const ValueKey('marriage-range-period'));
      expect(tester.widget<Text>(range).textAlign, TextAlign.right);
      expect(
        tester.getRect(range).top,
        greaterThanOrEqualTo(
          tester
              .getRect(find.byKey(const ValueKey('marriage-partner-period')))
              .bottom,
        ),
      );
      expect(tester.widget<Text>(range).data, '(01.01.1990 — ?)');
      expect(session.operations, isEmpty);
    },
  );

  testWidgets(
    'marriage date pill opens calendar immediately and cancellation keeps the mode',
    (tester) async {
      final session = _family();
      await _mount(tester, session, editing: true);
      await _tap(tester, find.byKey(const Key('add-marriage')));
      await _tap(tester, find.byKey(const Key('history-end-date')));
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const Key('history-end-unknown')))
            .selected,
        isTrue,
      );
      expect(
        find
            .byType(OutlinedButton)
            .evaluate()
            .any(
              (element) =>
                  (element.widget.key == const Key('history-end-date')),
            ),
        isFalse,
      );
      await _tap(tester, find.text('Отмена'));
      expect(session.operations, isEmpty);
    },
  );

  testWidgets(
    'lifelong without any real date does not manufacture parentheses',
    (tester) async {
      final session = _family();
      session.seed(
        session.tree.addMarriage(
          rootTreePersonId,
          'partner',
          id: 'marriage',
          changeSurname: false,
          endMode: TreeMarriageEndMode.lifelong,
        ),
      );
      await _mount(tester, session);
      expect(find.textContaining('н.в'), findsNothing);
      expect(find.textContaining('('), findsNothing);
    },
  );

  testWidgets(
    'female defaults adopt; picker is view-only, excludes only self, allows ancestor/any sex',
    (tester) async {
      final session = _family();
      session.seed(
        session.tree.setValue(rootTreePersonId, 'fatherId', 'partner'),
      );
      var picks = 0;
      await _mount(
        tester,
        session,
        editing: true,
        onPick: (initial, canPick) async {
          picks++;
          expect(canPick(session.tree.person(rootTreePersonId)!), isFalse);
          expect(canPick(session.tree.person('partner')!), isTrue);
          return 'partner';
        },
      );
      await _tap(tester, find.byKey(const Key('add-marriage')));
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('marriage-change-surname')),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const Key('history-end-unknown')))
            .selected,
        isTrue,
      );
      expect(
        find.byType(DropdownButtonFormField<TreeMarriageEndMode>),
        findsNothing,
      );
      await _existing(tester);
      expect(picks, 1);
      expect(session.operations, isEmpty);
      await _tap(tester, _save);
      expect(session.operations, hasLength(1));
      expect(session.tree.marriagesOf(rootTreePersonId), hasLength(1));
    },
  );

  testWidgets(
    'unchecked female marriage keeps surname and has no surname first row',
    (tester) async {
      final session = _family();
      await _mount(
        tester,
        session,
        editing: true,
        onPick: (_, _) async => 'partner',
      );
      await _tap(tester, find.byKey(const Key('add-marriage')));
      await _tap(tester, find.byKey(const Key('marriage-change-surname')));
      await _existing(tester);
      await _tap(tester, _save);
      expect(
        session.tree.historyOf(rootTreePersonId).single.surnameChange,
        isNull,
      );
      expect(
        session.tree.person(rootTreePersonId)!.currentSurname,
        session.tree.person(rootTreePersonId)!.effectiveSurname,
      );
    },
  );

  for (final sex in [TreeSex.male, TreeSex.unknown]) {
    testWidgets('${sex.name} marriage defaults do not adopt surname', (
      tester,
    ) async {
      final session = _family(sex: sex);
      await _mount(tester, session, editing: true);
      await _tap(tester, find.byKey(const Key('add-marriage')));
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('marriage-change-surname')),
            )
            .value,
        isFalse,
      );
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(session.operations, isEmpty);
    });
  }

  for (final (sex, expected) in [
    (TreeSex.female, TreeSex.male),
    (TreeSex.male, TreeSex.female),
    (TreeSex.unknown, TreeSex.unknown),
  ]) {
    testWidgets('new spouse defaults to opposite sex of $sex', (tester) async {
      final session = _family(sex: sex);
      await _mount(tester, session, editing: true);
      await _tap(tester, find.byKey(const Key('add-marriage')));
      final field = find.byType(DropdownButtonFormField<TreeSex>);
      expect(
        tester.widget<DropdownButtonFormField<TreeSex>>(field).initialValue,
        expected,
      );
      await tester.enterText(
        find.byKey(const Key('marriage-new-name')),
        'Супруг',
      );
      await _tap(tester, _save);
      final marriage = session.tree.marriagesOf(rootTreePersonId).single;
      final partner = session.tree.person(
        marriage.otherPersonId(rootTreePersonId)!,
      )!;
      expect(partner.sex, expected);
      expect(session.operations.single.type, 'addMarriage');
    });
  }

  testWidgets('new spouse sex draft survives source switching', (tester) async {
    final session = _family();
    await _mount(tester, session, editing: true);
    await _tap(tester, find.byKey(const Key('add-marriage')));
    final field = find.byType(DropdownButtonFormField<TreeSex>);
    await _tap(tester, field);
    await tester.tap(find.text('Пол не указан').last);
    await tester.pumpAndSettle();
    await _tap(tester, find.widgetWithText(ChoiceChip, 'Из дерева'));
    await _tap(tester, find.widgetWithText(ChoiceChip, 'Новый человек'));
    expect(
      tester.widget<DropdownButtonFormField<TreeSex>>(field).initialValue,
      TreeSex.unknown,
    );
    await _tap(tester, find.text('Отмена'));
    expect(session.operations, isEmpty);
  });

  testWidgets(
    'marriage surname appears when a new spouse gets their initially missing surname',
    (tester) async {
      final session = _family();
      await _mount(tester, session, editing: true);
      await _tap(tester, find.byKey(const Key('add-marriage')));
      await tester.enterText(
        find.byKey(const Key('marriage-new-name')),
        'Пётр',
      );
      await _tap(tester, _save);
      final marriage = session.tree.marriagesOf(rootTreePersonId).single;
      final partnerId = marriage.otherPersonId(rootTreePersonId)!;
      expect(marriage.surnameChoices[rootTreePersonId]!.changeSurname, isTrue);
      expect(marriage.surnameChoices[rootTreePersonId]!.adoptedSurname, isNull);
      final original = session.records.single.text;
      await session.applyTreeOperation(
        session.tree.setIndividualSurname(
          partnerId,
          text: 'Петров',
          decline: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Петрова'), findsOneWidget);
      expect(find.text('Сидорова'), findsOneWidget);
      expect(find.text('при рождении'), findsOneWidget);
      final entry = session.tree.historyOf(rootTreePersonId).single;
      expect(entry.surnameChange!.changesSurname, isTrue);
      expect(session.records.first.text, original);
      await _tap(
        tester,
        find.byKey(ValueKey('edit-family-history-${_entryIdentity(entry)}')),
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('marriage-change-surname')),
            )
            .value,
        isTrue,
      );
      await _tap(tester, find.text('Отмена'));
      expect(session.operations.map((operation) => operation.type), [
        'addMarriage',
        'setSurname',
      ]);
    },
  );

  testWidgets(
    'new partner name sex DOB and canonical surname snapshot save atomically',
    (tester) async {
      final session = _family();
      await _mount(tester, session, editing: true);
      await _tap(tester, find.byKey(const Key('add-marriage')));
      await tester.enterText(
        find.byKey(const Key('marriage-new-name')),
        'Пётр',
      );
      await tester.enterText(
        find.byKey(const Key('marriage-new-surname')),
        'Петров',
      );
      await _tap(tester, find.byType(DropdownButtonFormField<TreeSex>));
      await tester.tap(find.text('Мужской').last);
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const Key('marriage-new-birth-date')));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(session.operations, isEmpty);
      await _tap(tester, _save);
      expect(session.operations, hasLength(1));
      final marriage = session.tree.marriagesOf(rootTreePersonId).single;
      final partner = session.tree.person(
        marriage.otherPersonId(rootTreePersonId)!,
      )!;
      expect(partner.name, 'Пётр');
      expect(partner.sex, TreeSex.male);
      expect(partner.birthDate, DateTime.utc(1970));
      expect(partner.effectiveSurname!.text, 'Петров');
      expect(
        marriage.surnameChoices[rootTreePersonId]!.adoptedSurname!.text,
        'Петров',
      );
      expect(find.text('Петрова'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == 'Отчество',
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'existing partner label follows live name mode and cancel writes nothing',
    (tester) async {
      final session = _family();
      final mode = ValueNotifier(TreeNameMode.givenSurname);
      addTearDown(mode.dispose);
      var attempt = 0;
      await _mount(
        tester,
        session,
        editing: true,
        nameMode: mode,
        onPick: (_, _) async => ++attempt == 1 ? null : 'partner',
      );
      await _tap(tester, find.byKey(const Key('add-marriage')));
      await _existing(tester);
      expect(find.byKey(const Key('marriage-selected-person')), findsNothing);
      await _tap(tester, find.byKey(const Key('marriage-pick-from-tree')));
      expect(find.text('Иван Иванов'), findsOneWidget);
      mode.value = TreeNameMode.surnameGivenPatronymic;
      await tester.pumpAndSettle();
      expect(find.text('Иванов Иван'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(session.operations, isEmpty);
    },
  );

  testWidgets(
    'inferred row can materialize dates and independent surname choice with two drafts before await',
    (tester) async {
      final session = _family(child: true);
      final entry = session.tree.historyOf(rootTreePersonId).single;
      await _mount(tester, session, editing: true);
      await _tap(
        tester,
        find.byKey(ValueKey('edit-family-history-${_entryIdentity(entry)}')),
      );
      await _date(tester);
      await _endMode(tester, 'Пожизненно');
      session.hold = Completer<void>();
      await tester.tap(_save);
      await tester.pump();
      expect(session.operations, hasLength(2));
      final marriage = session.tree.marriagesOf(rootTreePersonId).single;
      expect(marriage.startDate, DateTime.utc(1970));
      expect(marriage.endMode, TreeMarriageEndMode.lifelong);
      expect(tester.widget<FilledButton>(_save).onPressed, isNull);
      session.hold!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('family-history-dialog')), findsNothing);
    },
  );

  testWidgets(
    'custom surname reason and date row edit; unrelated raw birth name remains',
    (tester) async {
      final session = _family();
      await _mount(tester, session, editing: true);
      await _tap(tester, find.byKey(const Key('add-surname-change')));
      await tester.enterText(
        find.byKey(const Key('history-surname')),
        'Лесной',
      );
      await tester.enterText(
        find.byKey(const Key('history-reason')),
        'По желанию',
      );
      await _date(tester);
      await _tap(tester, _save);
      expect(find.text('Леснойа'), findsOneWidget);
      expect(find.text('Сидорова'), findsOneWidget);
      expect(find.text('при рождении'), findsOneWidget);
      expect(find.text('01.01.1970'), findsOneWidget);
      expect(find.text('По желанию'), findsOneWidget);
      expect(
        session.tree.person(rootTreePersonId)!.effectiveSurname!.text,
        'Сидоров',
      );
      final entry = session.tree.historyOf(rootTreePersonId).single;
      await _tap(
        tester,
        find.byKey(ValueKey('edit-family-history-${_entryIdentity(entry)}')),
      );
      await tester.enterText(
        find.byKey(const Key('history-reason')),
        'Новая причина',
      );
      await _tap(tester, _save);
      expect(find.text('Новая причина'), findsOneWidget);
    },
  );

  testWidgets('custom reason saves two lines and keeps them when reopened', (
    tester,
  ) async {
    final session = _family();
    await _mount(tester, session, editing: true);
    await _tap(tester, find.byKey(const Key('add-surname-change')));
    await tester.enterText(find.byKey(const Key('history-surname')), 'Седых');
    await tester.enterText(
      find.byKey(const Key('history-reason')),
      'Первая строка\nВторая строка',
    );
    await _tap(tester, _save);
    expect(session.operations, hasLength(1));
    expect(find.text('Первая строка\nВторая строка'), findsOneWidget);
    final entry = session.tree.historyOf(rootTreePersonId).single;
    await _tap(
      tester,
      find.byKey(ValueKey('edit-family-history-${_entryIdentity(entry)}')),
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('history-reason')))
          .controller!
          .text,
      'Первая строка\nВторая строка',
    );
    await _tap(tester, find.text('Отмена'));
    expect(session.operations, hasLength(1));
  });

  for (final marriage in [true, false]) {
    testWidgets(
      '${marriage ? 'marriage' : 'surname'} deletion asks confirmation; cancel is a no-op',
      (tester) async {
        final session = _family();
        session.seed(
          marriage
              ? session.tree.addMarriage(
                  rootTreePersonId,
                  'partner',
                  id: 'record',
                  changeSurname: false,
                )
              : session.tree.addSurnameChange(
                  rootTreePersonId,
                  id: 'record',
                  surname: const TreeSurname(text: 'Седых'),
                  reason: 'Причина',
                ),
        );
        await _mount(tester, session, editing: true);
        final entry = session.tree.historyOf(rootTreePersonId).single;
        final remove = find.byKey(
          ValueKey('delete-family-history-${_entryIdentity(entry)}'),
        );
        await _tap(tester, remove);
        expect(
          find.text(marriage ? 'Удалить брак?' : 'Удалить смену фамилии?'),
          findsOneWidget,
        );
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
        expect(session.operations, isEmpty);
        await _tap(tester, remove);
        await tester.tap(
          find.byKey(const Key('confirm-delete-family-history')),
        );
        await tester.pumpAndSettle();
        expect(session.operations, hasLength(1));
        expect(session.tree.historyOf(rootTreePersonId), isEmpty);
      },
    );
  }

  testWidgets(
    'failed save locks draft; retry flushes original core even after a competing remote record',
    (tester) async {
      final session = _family();
      await _mount(
        tester,
        session,
        editing: true,
        onPick: (_, _) async => 'partner',
      );
      await _tap(tester, find.byKey(const Key('add-marriage')));
      await _existing(tester);
      session.fail = true;
      await _tap(tester, _save);
      expect(find.textContaining('disk full'), findsWidgets);
      expect(find.text('Повторить сохранение'), findsOneWidget);
      expect(session.operations, hasLength(1));
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('marriage-change-surname')),
            )
            .onChanged,
        isNull,
      );
      final payload = session.records.single.text;
      final marriage = session.tree.marriagesOf(rootTreePersonId).single;
      session.seed(
        session.tree.updateMarriage(
          rootTreePersonId,
          marriage.id,
          startDate: DateTime.utc(1999),
          endDate: null,
        ),
      );
      session.fail = false;
      await _tap(tester, _save);
      expect(session.retries, 1);
      expect(session.operations, hasLength(1));
      expect(session.records.single.text, payload);
      expect(find.byKey(const Key('family-history-dialog')), findsNothing);
    },
  );

  testWidgets(
    'marriage and surname records may share an ID without row or action key collisions',
    (tester) async {
      final session = _family();
      session.seed(
        session.tree.addMarriage(
          rootTreePersonId,
          'partner',
          id: 'record',
          changeSurname: true,
        ),
      );
      session.seed(
        session.tree.addSurnameChange(
          rootTreePersonId,
          id: 'record',
          surname: const TreeSurname(text: 'Седых'),
          date: DateTime.utc(2001),
          reason: 'Своя причина',
        ),
      );
      await _mount(tester, session, editing: true);
      expect(tester.takeException(), isNull);
      for (final kind in ['marriage', 'surnameChange']) {
        for (final prefix in [
          'family-history-entry',
          'family-history-surname',
          'edit-family-history',
          'delete-family-history',
        ]) {
          expect(find.byKey(ValueKey('$prefix-$kind-record')), findsOneWidget);
        }
      }
      await _tap(
        tester,
        find.byKey(const ValueKey('edit-family-history-surnameChange-record')),
      );
      expect(find.text('Изменить смену фамилии'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('history-reason')))
            .controller!
            .text,
        'Своя причина',
      );
      await _tap(tester, find.text('Отмена'));
      await _tap(
        tester,
        find.byKey(
          const ValueKey('delete-family-history-surnameChange-record'),
        ),
      );
      await _tap(
        tester,
        find.byKey(const Key('confirm-delete-family-history')),
      );
      expect(session.tree.historyOf(rootTreePersonId), hasLength(1));
      expect(
        session.tree.historyOf(rootTreePersonId).single.marriage!.id,
        'record',
      );
      expect(
        find.byKey(const ValueKey('family-history-entry-marriage-record')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'generic no-change row shows only its exact reason without surname or change date',
    (tester) async {
      final session = _family();
      session.seed(
        session.tree.addSurnameChange(
          rootTreePersonId,
          id: 'unchanged',
          surname: const TreeSurname(text: 'Сидоров', decline: true),
          date: DateTime.utc(2001),
          reason: 'Уточнение записи',
        ),
      );
      await _mount(tester, session, editing: true);
      final entry = session.tree.historyOf(rootTreePersonId).single;
      expect(entry.surnameChange!.changesSurname, isFalse);
      expect(
        find.byKey(ValueKey('family-history-surname-${_entryIdentity(entry)}')),
        findsNothing,
      );
      expect(find.text('Уточнение записи'), findsOneWidget);
      expect(find.text('при рождении'), findsNothing);
      expect(find.text('Сидорова'), findsNothing);
      expect(find.textContaining('01.01.2001'), findsNothing);
      await _tap(
        tester,
        find.byKey(ValueKey('edit-family-history-${_entryIdentity(entry)}')),
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('history-reason')))
            .controller!
            .text,
        'Уточнение записи',
      );
      await _tap(tester, find.text('Отмена'));
      expect(session.operations, isEmpty);
    },
  );

  for (final width in [480.0, 320.0]) {
    testWidgets(
      'surnames share one left edge with unknown dates; width=$width',
      (tester) async {
        final session = _family();
        final tree = session.tree;
        session.seed(
          tree.addSurnameChange(
            rootTreePersonId,
            id: 'undated',
            surname: const TreeSurname(text: 'Седых'),
            reason: 'По желанию',
          ),
        );
        session.seed(
          tree.addSurnameChange(
            rootTreePersonId,
            id: 'dated',
            surname: const TreeSurname(text: 'Орлова'),
            date: DateTime.utc(2001, 11, 28),
            reason: 'Позже',
          ),
        );
        await _mount(tester, session, size: Size(width, 1000));
        final birth = find.byKey(const Key('family-history-birth-surname'));
        final undated = find.byKey(
          const ValueKey('family-history-surname-surnameChange-undated'),
        );
        final dated = find.byKey(
          const ValueKey('family-history-surname-surnameChange-dated'),
        );
        expect(
          find.descendant(of: birth, matching: find.text('?')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: undated, matching: find.text('?')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: dated, matching: find.text('28.11.2001')),
          findsOneWidget,
        );
        final left = tester.getTopLeft(find.text('Сидорова')).dx;
        expect(tester.getTopLeft(find.text('Седых')).dx, left);
        expect(tester.getTopLeft(find.text('Орлова')).dx, left);
        expect(tester.getRect(find.text('28.11.2001')).right, lessThan(left));
        expect(tester.takeException(), isNull);
        expect(session.operations, isEmpty);
      },
    );
  }

  testWidgets(
    'only-end date and domain row order are rendered without UI resorting',
    (tester) async {
      final session = _family();
      session.seed(
        session.tree.addMarriage(
          rootTreePersonId,
          'partner',
          id: 'earlier',
          changeSurname: false,
          endMode: TreeMarriageEndMode.date,
          endDate: DateTime.utc(1980),
        ),
      );
      session.seed(
        session.tree.addSurnameChange(
          rootTreePersonId,
          id: 'later',
          surname: const TreeSurname(text: 'Седых'),
          date: DateTime.utc(2001),
          reason: 'Позже',
        ),
      );
      await _mount(tester, session);
      expect(find.text('(? — 01.01.1980)'), findsOneWidget);
      final entries = session.tree.historyOf(rootTreePersonId);
      expect(
        tester
            .getTopLeft(
              find.byKey(
                ValueKey('family-history-entry-${_entryIdentity(entries[0])}'),
              ),
            )
            .dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(
                  ValueKey(
                    'family-history-entry-${_entryIdentity(entries[1])}',
                  ),
                ),
              )
              .dy,
        ),
      );
    },
  );

  testWidgets(
    'deleted spouse keeps explicit row editable without a replacement chooser',
    (tester) async {
      final session = _family();
      session.seed(
        session.tree.addMarriage(
          rootTreePersonId,
          'partner',
          id: 'marriage',
          startDate: DateTime.utc(1990),
          changeSurname: true,
        ),
      );
      session.seed(session.tree.deletePerson('partner'));
      await _mount(tester, session, editing: true);
      expect(find.text('Удалённый человек'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('marriage-partner-marriage')),
        findsNothing,
      );
      await _tap(
        tester,
        find.byKey(const ValueKey('edit-family-history-marriage-marriage')),
      );
      expect(find.byKey(const Key('marriage-pick-from-tree')), findsNothing);
      await _endMode(tester, 'Пожизненно');
      await _tap(tester, _save);
      expect(session.operations.single.type, 'setMarriageDates');
      expect(
        session.tree.marriagesOf(rootTreePersonId).single.endMode,
        TreeMarriageEndMode.lifelong,
      );
    },
  );

  testWidgets(
    'failed two-draft implied edit retries both original cores without another operation',
    (tester) async {
      final session = _family(child: true);
      final entry = session.tree.historyOf(rootTreePersonId).single;
      await _mount(tester, session, editing: true);
      await _tap(
        tester,
        find.byKey(ValueKey('edit-family-history-${_entryIdentity(entry)}')),
      );
      await _date(tester);
      await _tap(tester, find.byKey(const Key('marriage-change-surname')));
      session.fail = true;
      await _tap(tester, _save);
      expect(session.operations, hasLength(2));
      final texts = session.records.map((edit) => edit.text).toList();
      expect(find.text('Повторить сохранение'), findsOneWidget);
      session.fail = false;
      await _tap(tester, _save);
      expect(session.retries, 1);
      expect(session.records.map((edit) => edit.text), texts);
      expect(session.operations, hasLength(2));
    },
  );

  testWidgets(
    'partial append retries only missing frozen choice and cannot close while it is still rejected',
    (tester) async {
      final session = _family(child: true);
      final entry = session.tree.historyOf(rootTreePersonId).single;
      await _mount(tester, session, editing: true);
      await _tap(
        tester,
        find.byKey(ValueKey('edit-family-history-${_entryIdentity(entry)}')),
      );
      await _date(tester);
      session.rejectSurnameBeforeAppend = 2;
      await _tap(tester, _save);
      expect(session.operations.map((operation) => operation.type), [
        'setMarriageDates',
      ]);
      expect(find.textContaining('history size limit'), findsOneWidget);
      expect(find.byKey(const Key('family-history-dialog')), findsOneWidget);
      final frozen = session.rejected.single.toJson();
      // A later projection change must not resnapshot the unappended choice.
      session.seed(
        session.tree.setIndividualSurname(
          'partner',
          text: 'Другой',
          decline: true,
        ),
      );
      session.refresh();
      await _tap(tester, _save);
      expect(session.operations, hasLength(1));
      expect(session.rejected, hasLength(2));
      expect(find.byKey(const Key('family-history-dialog')), findsOneWidget);
      expect(find.textContaining('history size limit'), findsOneWidget);
      await _tap(tester, _save);
      expect(session.operations.map((operation) => operation.type), [
        'setMarriageDates',
        'setMarriageSurname',
      ]);
      expect(session.operations.last.toJson(), frozen);
      expect(
        session.retries,
        3,
      ); // two prior-core flushes and the final all-core flush
      expect(find.byKey(const Key('family-history-dialog')), findsNothing);
    },
  );

  testWidgets(
    'failed optimistic deletion retains error and flush retry after its row disappears',
    (tester) async {
      final session = _family();
      session.seed(
        session.tree.addMarriage(
          rootTreePersonId,
          'partner',
          id: 'marriage',
          changeSurname: false,
        ),
      );
      await _mount(tester, session, editing: true);
      await _tap(
        tester,
        find.byKey(const ValueKey('delete-family-history-marriage-marriage')),
      );
      session.fail = true;
      await _tap(
        tester,
        find.byKey(const Key('confirm-delete-family-history')),
      );
      expect(session.tree.historyOf(rootTreePersonId), isEmpty);
      expect(find.textContaining('disk full'), findsOneWidget);
      expect(session.operations, hasLength(1));
      session.fail = false;
      await _tap(tester, find.text('Повторить сохранение'));
      expect(session.retries, 1);
      expect(session.operations, hasLength(1));
      expect(find.byKey(const Key('family-history-error')), findsNothing);
    },
  );

  testWidgets(
    'pending picker disables duplicate actions and revalidates role at return',
    (tester) async {
      final session = _family();
      final result = Completer<String?>();
      var calls = 0;
      await _mount(
        tester,
        session,
        editing: true,
        onPick: (_, _) {
          calls++;
          return result.future;
        },
      );
      await _tap(tester, find.byKey(const Key('add-marriage')));
      await _tap(tester, find.widgetWithText(ChoiceChip, 'Из дерева'));
      final choose = find.byKey(const Key('marriage-pick-from-tree'));
      await tester.tap(choose);
      await tester.pump();
      expect(tester.widget<OutlinedButton>(choose).onPressed, isNull);
      expect(tester.widget<FilledButton>(_save).onPressed, isNull);
      expect(session.operations, isEmpty);
      session.editor = false;
      session.refresh();
      result.complete('partner');
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.textContaining('больше не доступен'), findsOneWidget);
      expect(session.operations, isEmpty);
    },
  );

  testWidgets('guest sees history and partner navigation but no commands', (
    tester,
  ) async {
    final session = _family(child: true)..editor = false;
    await _mount(tester, session, editing: true);
    expect(find.text('Брак с '), findsOneWidget);
    expect(find.byKey(const Key('add-marriage')), findsNothing);
    expect(find.byTooltip('Изменить запись'), findsNothing);
    expect(find.byTooltip('Удалить запись'), findsNothing);
    expect(session.operations, isEmpty);
  });

  for (final size in [const Size(320, 568), const Size(390, 844)]) {
    testWidgets(
      'both history dialogs fit phone $size including expanded date end',
      (tester) async {
        final session = _family();
        await _mount(tester, session, editing: true, size: size);
        await _tap(tester, find.byKey(const Key('add-marriage')));
        await tester.enterText(
          find.byKey(const Key('marriage-new-name')),
          'Очень длинное имя нового человека',
        );
        await _endMode(tester, 'Дата');
        expect(find.widgetWithText(ChoiceChip, '01.01.1970'), findsOneWidget);
        final chips = [
          for (final mode in ['date', 'ongoing', 'unknown'])
            tester.getRect(find.byKey(Key('history-end-$mode'))),
        ];
        expect(chips.map((rect) => rect.center.dy).toSet(), hasLength(1));
        expect(
          find.byType(DropdownButtonFormField<TreeMarriageEndMode>),
          findsNothing,
        );
        await _tap(tester, find.byKey(const Key('marriage-change-surname')));
        expect(tester.takeException(), isNull);
        await _tap(tester, find.text('Отмена'));
        await _tap(tester, find.byKey(const Key('add-surname-change')));
        await tester.enterText(
          find.byKey(const Key('history-surname')),
          'Очень длинная фамилия',
        );
        await _tap(tester, find.byKey(const Key('history-reason')));
        expect(tester.takeException(), isNull);
        await _tap(tester, find.text('Отмена'));
        expect(session.operations, isEmpty);
      },
    );
  }
}
