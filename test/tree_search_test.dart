import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/tree/tree_document.dart';
import 'package:mytree_webrtc_demo/ui/tree_search.dart';

TreePerson _person(
  String id, {
  String name = 'Анна',
  TreeSex sex = TreeSex.unknown,
  DateTime? birth,
  DateTime? death,
  TreeSurname? surname,
  TreeSurname? maiden,
}) => TreePerson(
  id: id,
  name: name,
  sex: sex,
  birthDate: birth,
  deathDate: death,
  effectiveSurname: surname,
  maidenSurname: maiden,
);

Map<String, TreePerson> _map(Iterable<TreePerson> people) => {
  for (final person in people) person.id: person,
};

Finder get _field => find.byKey(const Key('tree-search-field'));
Finder _option(String id) => find.byKey(ValueKey('tree-search-option-$id'));

Future<void> _mount(
  WidgetTester tester,
  ValueNotifier<Map<String, TreePerson>> people,
  List<String> selected, {
  Size size = const Size(390, 844),
  double keyboard = 0,
  double top = 8,
  bool compact = false,
  bool showBackButton = false,
  ValueChanged<bool>? onFocusChanged,
  void Function(PointerSignalEvent)? onPointerSignal,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  addTearDown(people.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(
        body: Padding(
          padding: EdgeInsets.only(left: 8, right: 8, top: top),
          child: Align(
            alignment: Alignment.topLeft,
            child: Listener(
              onPointerSignal: onPointerSignal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ValueListenableBuilder<Map<String, TreePerson>>(
                      valueListenable: people,
                      builder: (context, value, child) => TreePersonSearch(
                        people: value,
                        onSelected: selected.add,
                        compact: compact,
                        showBackButton: showBackButton,
                        onFocusChanged: onFocusChanged,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Масштаб',
                    onPressed: () {},
                    icon: const Icon(Icons.zoom_in),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _query(WidgetTester tester, String text) async {
  await tester.tap(_field);
  await tester.enterText(_field, text);
  await tester.pumpAndSettle();
}

void main() {
  group('searchTreePeople', () {
    test(
      'matches every token across birth surname, full name and years only',
      () {
        final anna = _person(
          'anna',
          name: 'Анна Петровна',
          sex: TreeSex.female,
          surname: const TreeSurname(text: 'Ёлкин', decline: true),
          maiden: const TreeSurname(text: 'Семёнов', decline: true),
          birth: DateTime.utc(1930, 5, 3),
          death: DateTime.utc(2010),
        );
        final people = _map([
          anna,
          _person('other', name: 'Анна Ивановна', birth: DateTime.utc(1930)),
        ]);
        expect(anna.fullName, 'Анна Петровна Ёлкина');
        expect(
          searchTreePeople(people, '  ЕЛКИНА\tанна\nПЕТРОВНА 1930 2010 '),
          [anna],
        );
        expect(searchTreePeople(people, 'анна петровна 2001'), isEmpty);
        expect(searchTreePeople(people, 'семенова'), isEmpty);
        expect(searchTreePeople(people, 'семенов'), isEmpty);
        expect(searchTreePeople(people, 'семенова елкина'), isEmpty);
      },
    );

    test('normalizes Cyrillic ё, Unicode whitespace and letter case', () {
      final person = _person(
        'unicode',
        name: 'Алёна Éloïse',
        surname: const TreeSurname(text: 'Бёрг'),
      );
      expect(searchTreePeople(_map([person]), 'БЕРГ АЛЕНА ÉLOÏSE'), [person]);
    });

    test('uses surname sex forms without adding a second female suffix', () {
      final people = _map([
        _person(
          'female',
          sex: TreeSex.female,
          surname: const TreeSurname(text: 'Иванов', decline: true),
          maiden: const TreeSurname(text: 'Петров', decline: true),
        ),
        _person(
          'male',
          sex: TreeSex.male,
          surname: const TreeSurname(text: 'Иванов', decline: true),
          maiden: const TreeSurname(text: 'Петров', decline: true),
        ),
        _person(
          'fixed',
          sex: TreeSex.female,
          surname: const TreeSurname(text: 'Седых'),
          maiden: const TreeSurname(text: 'Историческая'),
        ),
        _person(
          'already-female',
          sex: TreeSex.female,
          surname: const TreeSurname(text: 'Толстая'),
        ),
      ]);
      expect(searchTreePeople(people, 'иванова').map((person) => person.id), [
        'female',
      ]);
      expect(searchTreePeople(people, 'ивановаа'), isEmpty);
      expect(searchTreePeople(people, 'иванов').length, 2);
      expect(searchTreePeople(people, 'седых').single.id, 'fixed');
      expect(searchTreePeople(people, 'толстая').single.id, 'already-female');
      expect(searchTreePeople(people, 'толстаяа'), isEmpty);
      expect(searchTreePeople(people, 'петров'), isEmpty);
      expect(searchTreePeople(people, 'историческая'), isEmpty);
    });

    test(
      'unknown birth dates first, then dates, trimmed given name and id',
      () {
        final people = _map([
          _person('unknown-z', name: 'Анна Яковлевна'),
          _person('later', birth: DateTime.utc(2000, 1, 2)),
          _person(
            'unknown-a',
            name: 'Анна Алексеевна',
            death: DateTime.utc(850),
          ),
          _person('same-b', birth: DateTime.utc(2000, 1, 1)),
          _person('1000', birth: DateTime.utc(1000), death: DateTime.utc(1100)),
          _person('same-a', birth: DateTime.utc(2000, 1, 1)),
          _person('900', birth: DateTime.utc(900), death: DateTime.utc(1000)),
          _person(
            'name-tie',
            name: 'Анна Борисовна',
            birth: DateTime.utc(2000),
          ),
        ]);
        final originalIds = people.keys.toList();
        expect(searchTreePeople(people, 'анна').map((person) => person.id), [
          'unknown-a',
          'unknown-z',
          '900',
          '1000',
          'same-a',
          'same-b',
          'name-tie',
          'later',
        ]);
        expect(people.keys, originalIds);
      },
    );

    test('equal birth dates sort given names before rendered surnames', () {
      final people = _map([
        _person(
          'surname-first',
          name: 'Яна',
          sex: TreeSex.female,
          surname: const TreeSurname(text: 'Алексеев', decline: true),
          birth: DateTime.utc(1980),
        ),
        _person(
          'given-first',
          name: 'Анна',
          sex: TreeSex.female,
          surname: const TreeSurname(text: 'Яковлев', decline: true),
          birth: DateTime.utc(1980),
        ),
      ]);
      expect(searchTreePeople(people, '1980').map((person) => person.id), [
        'given-first',
        'surname-first',
      ]);
    });

    test(
      'missing/equal date ties use normalized given name, never surname',
      () {
        final values = [
          _person(
            'unknown-z',
            name: 'Яна',
            surname: const TreeSurname(text: 'Семья'),
          ),
          _person(
            'unknown-empty-b',
            name: '  ',
            surname: const TreeSurname(text: 'Семья'),
          ),
          _person(
            'unknown-b',
            name: ' АлЁна ',
            surname: const TreeSurname(text: 'Семья А'),
          ),
          _person(
            'dated-b',
            name: ' АлЁна ',
            birth: DateTime.utc(1900),
            surname: const TreeSurname(text: 'Семья А'),
          ),
          _person(
            'dated-a',
            name: 'АЛЕНА',
            birth: DateTime.utc(1900),
            surname: const TreeSurname(text: 'Семья Я'),
          ),
          _person(
            'unknown-a',
            name: 'алена',
            surname: const TreeSurname(text: 'Семья Я'),
          ),
          _person(
            'unknown-empty-a',
            name: '',
            surname: const TreeSurname(text: 'Семья'),
          ),
        ];
        final original = [
          for (final person in values)
            (person.id, person.name, person.birthDate, person.effectiveSurname),
        ];
        for (final source in [values, values.reversed]) {
          final people = _map(source);
          final insertionOrder = people.keys.toList();
          expect(searchTreePeople(people, 'семья').map((person) => person.id), [
            'unknown-empty-a',
            'unknown-empty-b',
            'unknown-a',
            'unknown-b',
            'unknown-z',
            'dated-a',
            'dated-b',
          ]);
          expect(people.keys, insertionOrder);
        }
        expect([
          for (final person in values)
            (person.id, person.name, person.birthDate, person.effectiveSurname),
        ], original);
      },
    );

    test('empty queries and empty maps produce no options', () {
      final people = _map([_person('one')]);
      expect(searchTreePeople(people, ''), isEmpty);
      expect(searchTreePeople(people, '\t \n'), isEmpty);
      expect(searchTreePeople({}, 'анна'), isEmpty);
    });
  });

  testWidgets('compact field hides empty suggestions and supports clearing', (
    tester,
  ) async {
    final people = ValueNotifier(_map([_person('anna')]));
    await _mount(tester, people, []);
    expect(tester.getSize(_field).height, lessThanOrEqualTo(48));
    expect(find.byIcon(Icons.search), findsOneWidget);
    expect(find.text('Поиск по дереву'), findsOneWidget);
    await tester.tap(_field);
    await tester.pumpAndSettle();
    expect(_option('anna'), findsNothing);
    await _query(tester, 'анна');
    expect(_option('anna'), findsOneWidget);
    await tester.tap(find.byTooltip('Очистить поиск'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(_field);
    expect(field.controller!.text, isEmpty);
    expect(field.focusNode!.hasFocus, isTrue);
    expect(_option('anna'), findsNothing);
    expect(find.byTooltip('Очистить поиск'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'expanded search reports focus and closes on Back or Escape even empty',
    (tester) async {
      final people = ValueNotifier(_map([_person('anna')]));
      final focused = <bool>[];
      final selected = <String>[];
      await _mount(
        tester,
        people,
        selected,
        showBackButton: true,
        onFocusChanged: focused.add,
      );
      final field = tester.widget<TextField>(_field);
      await tester.tap(_field);
      await tester.pumpAndSettle();
      expect(focused, [true]);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(focused, [true, false]);
      expect(field.focusNode!.hasFocus, isFalse);

      await _query(tester, 'анна');
      expect(_option('anna'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tree-search-back')));
      await tester.pumpAndSettle();
      expect(focused, [true, false, true, false]);
      expect(field.controller!.text, 'анна');
      expect(_option('anna'), findsNothing);

      await tester.tap(_field);
      await tester.pumpAndSettle();
      expect(_option('anna'), findsOneWidget);
      await tester.tap(_option('anna'));
      await tester.pumpAndSettle();
      expect(selected, ['anna']);
      expect(focused, [true, false, true, false, true, false]);
      expect(field.controller!.text, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'expanded search does not consume Escape during IME composition',
    (tester) async {
      final people = ValueNotifier(_map([_person('anna')]));
      await _mount(tester, people, [], showBackButton: true);
      await _query(tester, 'анна');
      final field = tester.widget<TextField>(_field);
      field.controller!.value = const TextEditingValue(
        text: 'анна',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 0, end: 4),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(field.focusNode!.hasFocus, isTrue);
      expect(_option('anna'), findsOneWidget);
      expect(
        field.controller!.value.composing,
        const TextRange(start: 0, end: 4),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shows birth surname, full name and years without legacy surname details',
    (tester) async {
      final selected = <String>[];
      final people = ValueNotifier(
        _map([
          _person(
            'anna',
            name: 'Анна Петровна',
            sex: TreeSex.female,
            surname: const TreeSurname(text: 'Иванов', decline: true),
            maiden: const TreeSurname(text: 'Петров', decline: true),
            birth: DateTime.utc(1930),
            death: DateTime.utc(2010),
          ),
        ]),
      );
      await _mount(tester, people, selected);
      await _query(tester, 'петрова');
      expect(_option('anna'), findsNothing);
      expect(find.text('Ничего не найдено'), findsOneWidget);
      await _query(tester, 'иванова');
      expect(find.text('Анна Петровна Иванова'), findsOneWidget);
      expect(find.text('Иванова Анна Петровна'), findsNothing);
      expect(find.text('1930–2010'), findsOneWidget);
      expect(find.textContaining('до замужества'), findsNothing);
      final semantics = tester.widget<Semantics>(_option('anna')).properties;
      expect(semantics.button, isTrue);
      expect(semantics.label, 'Анна Петровна Иванова, 1930–2010');
      await tester.tap(_option('anna'));
      await tester.pumpAndSettle();
      expect(selected, ['anna']);
      final field = tester.widget<TextField>(_field);
      expect(field.controller!.text, isEmpty);
      expect(field.focusNode!.hasFocus, isFalse);
      expect(_option('anna'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unknown dates are older in visible results and keyboard selection',
    (tester) async {
      final selected = <String>[];
      final people = ValueNotifier(
        _map([
          _person('dated', name: 'Алёна', birth: DateTime.utc(1800)),
          _person('missing-b', name: ' АлЁна '),
          _person('missing-a', name: 'алена'),
        ]),
      );
      await _mount(tester, people, selected);
      await _query(tester, 'алена');
      expect(
        tester.getTopLeft(_option('missing-a')).dy,
        lessThan(tester.getTopLeft(_option('missing-b')).dy),
      );
      expect(
        tester.getTopLeft(_option('missing-b')).dy,
        lessThan(tester.getTopLeft(_option('dated')).dy),
      );
      expect(
        tester.widget<Semantics>(_option('missing-a')).properties.selected,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selected, ['missing-a']);
      expect(people.value['missing-b']!.name, ' АлЁна ');
      expect(people.value['missing-a']!.birthDate, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('arrows, Enter, Escape and the software search action work', (
    tester,
  ) async {
    final selected = <String>[];
    final people = ValueNotifier(
      _map([
        _person('younger', birth: DateTime.utc(2000)),
        _person('older', birth: DateTime.utc(1900)),
      ]),
    );
    await _mount(tester, people, selected);
    await _query(tester, 'анна');
    expect(
      tester.getTopLeft(_option('older')).dy,
      lessThan(tester.getTopLeft(_option('younger')).dy),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      tester.widget<Semantics>(_option('younger')).properties.selected,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, ['older']);

    await _query(tester, 'анна');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_option('older'), findsNothing);
    expect(tester.widget<TextField>(_field).controller!.text, 'анна');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, ['older']);
    await tester.tap(_field);
    await tester.pumpAndSettle();
    expect(_option('older'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(selected, ['older', 'older']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('live additions, edits and deletions preserve query and caret', (
    tester,
  ) async {
    final selected = <String>[];
    final people = ValueNotifier(_map([_person('old', name: 'Анна Старая')]));
    await _mount(tester, people, selected);
    await _query(tester, 'анна');
    final field = tester.widget<TextField>(_field);
    final controller = field.controller!;
    controller.selection = const TextSelection.collapsed(offset: 2);
    await tester.pumpAndSettle();
    final staleTap = tester.widget<Semantics>(_option('old')).properties.onTap!;

    people.value = _map([
      _person('old', name: 'Анна Новая', birth: DateTime.utc(1900)),
      _person('new', name: 'Анна Добавленная', birth: DateTime.utc(1800)),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Анна Старая'), findsNothing);
    expect(find.text('Анна Новая'), findsOneWidget);
    expect(find.text('1900–н.в.'), findsOneWidget);
    expect(_option('new'), findsOneWidget);
    expect(
      tester.getTopLeft(_option('new')).dy,
      lessThan(tester.getTopLeft(_option('old')).dy),
    );
    expect(tester.widget<TextField>(_field).controller, same(controller));
    expect(controller.text, 'анна');
    expect(controller.selection.baseOffset, 2);
    expect(field.focusNode!.hasFocus, isTrue);

    people.value = _map([_person('new', name: 'Анна Добавленная')]);
    await tester.pumpAndSettle();
    expect(_option('old'), findsNothing);
    staleTap();
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(controller.text, 'анна');
    expect(controller.selection.baseOffset, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, ['new']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote matching changes replace the no-results message live', (
    tester,
  ) async {
    final people = ValueNotifier(_map([_person('anna')]));
    await _mount(tester, people, []);
    await _query(tester, 'ольга');
    expect(find.text('Ничего не найдено'), findsOneWidget);
    people.value = _map([_person('olga', name: 'Ольга')]);
    await tester.pumpAndSettle();
    expect(find.text('Ничего не найдено'), findsNothing);
    expect(_option('olga'), findsOneWidget);
    people.value = {};
    await tester.pumpAndSettle();
    expect(find.text('Ничего не найдено'), findsOneWidget);
    expect(tester.widget<TextField>(_field).controller!.text, 'ольга');
    expect(tester.takeException(), isNull);
  });

  for (final (size, keyboard) in [
    (const Size(390, 844), 0.0),
    (const Size(390, 300), 160.0),
  ]) {
    testWidgets('suggestions fit $size with keyboard inset $keyboard', (
      tester,
    ) async {
      final selected = <String>[];
      final people = ValueNotifier(
        _map([
          for (var index = 0; index < 24; index++)
            _person(
              '$index',
              name: 'Анна Очень Длинное Имя И Отчество $index',
              birth: DateTime.utc(1800 + index),
              sex: TreeSex.female,
              surname: const TreeSurname(text: 'Преображенский'),
            ),
        ]),
      );
      await _mount(tester, people, selected, size: size, keyboard: keyboard);
      await _query(tester, 'анна');
      final menu = tester.getRect(find.byType(SingleChildScrollView));
      expect(menu.top, greaterThanOrEqualTo(0));
      expect(menu.bottom, lessThanOrEqualTo(size.height - keyboard));
      expect(menu.height, lessThanOrEqualTo(260));
      expect(menu.left, greaterThanOrEqualTo(0));
      expect(menu.right, lessThanOrEqualTo(size.width));
      for (var index = 0; index < 12; index++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      final highlighted = tester.getRect(_option('12'));
      expect(highlighted.overlaps(menu), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selected, ['12']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('opens upward when the viewport has more room above', (
    tester,
  ) async {
    final people = ValueNotifier(_map([_person('anna')]));
    await _mount(tester, people, [], size: const Size(390, 300), top: 210);
    await _query(tester, 'анна');
    final menu = tester.getRect(find.byType(SingleChildScrollView));
    expect(menu.bottom, lessThan(tester.getTopLeft(_field).dy));
    expect(menu.top, greaterThanOrEqualTo(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'keyboard and viewport changes relayout without replacing input',
    (tester) async {
      final people = ValueNotifier(
        _map([for (var i = 0; i < 15; i++) _person('$i')]),
      );
      await _mount(tester, people, []);
      await _query(tester, 'анна');
      final controller = tester.widget<TextField>(_field).controller!;
      controller.selection = const TextSelection.collapsed(offset: 1);
      tester.view.physicalSize = const Size(390, 300);
      tester.view.viewInsets = const FakeViewPadding(bottom: 150);
      await tester.pumpAndSettle();
      final menu = tester.getRect(find.byType(SingleChildScrollView));
      expect(menu.bottom, lessThanOrEqualTo(150));
      expect(controller.selection.baseOffset, 1);
      expect(controller.text, 'анна');
      expect(tester.widget<TextField>(_field).focusNode!.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('control-wheel over the search cannot zoom an ancestor canvas', (
    tester,
  ) async {
    var zoomEvents = 0;
    final people = ValueNotifier(_map([_person('anna')]));
    await _mount(
      tester,
      people,
      [],
      onPointerSignal: (event) {
        GestureBinding.instance.pointerSignalResolver.register(event, (_) {
          zoomEvents++;
        });
      },
    );
    await _query(tester, 'анна');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(_field),
        scrollDelta: const Offset(0, 40),
      ),
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(zoomEvents, 0);
    expect(tester.widget<TextField>(_field).controller!.text, 'анна');
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping outside and disposing close the overlay cleanly', (
    tester,
  ) async {
    final people = ValueNotifier(_map([_person('anna')]));
    await _mount(tester, people, []);
    await _query(tester, 'анна');
    await tester.tapAt(const Offset(20, 700));
    await tester.pumpAndSettle();
    expect(_option('anna'), findsNothing);
    await _query(tester, 'анна');
    expect(_option('anna'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(_option('anna'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
