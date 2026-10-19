import 'dart:math' as math;
import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/room_session.dart';
import 'package:mytree_webrtc_demo/storage/room_store.dart';
import 'package:mytree_webrtc_demo/tree/tree_document.dart';
import 'package:mytree_webrtc_demo/tree/tree_layout.dart';
import 'package:mytree_webrtc_demo/ui/person_biography.dart';
import 'package:mytree_webrtc_demo/ui/tree_editor.dart';

const _png =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

class _Fixture {
  final document = TreeDocument();
  int _clock = 0;

  void apply(TreeOperation operation) {
    document.merge([
      StampedTreeOperation(
        id: 'fixture-${++_clock}',
        author: 'actor',
        clock: _clock,
        createdAt: DateTime.utc(2026),
        operation: operation,
      ),
    ]);
  }

  void add(String id, {TreeSex sex = TreeSex.unknown}) =>
      apply(document.createPerson(id, name: id, sex: sex));

  void parents(String id, {String? father, String? mother}) {
    if (father != null) apply(document.setValue(id, 'fatherId', father));
    if (mother != null) apply(document.setValue(id, 'motherId', mother));
  }

  void name(String id, String value) =>
      apply(document.editText(id, TreeTextField.name, value)!);
}

class _Session extends RoomSession {
  _Session(this.document, {this.boundId, this.editingAllowed = false})
    : super(
        roomId: '1234567890abcdef1234567890abcdef',
        actorId: 'actor',
        store: MemoryRoomStore(),
        existingMember: true,
      );

  final TreeDocument document;
  final bool editingAllowed;
  final operations = <TreeOperation>[];
  // Keep local writes later than the fixture's small deterministic history.
  int _clock = 100000;
  String? boundId;

  @override
  TreeDocument get tree => document;
  @override
  TreeDocument get durableTree => document;
  @override
  String? get boundPersonId => boundId;
  @override
  bool get canEdit => editingAllowed;
  @override
  bool get canBindToPerson => false;

  @override
  Future<void> applyTreeOperation(TreeOperation operation) async {
    if (!canEdit) throw StateError('Только редактор');
    operations.add(operation);
    document.merge([
      StampedTreeOperation(
        id: 'local-${++_clock}',
        author: actorId,
        clock: _clock,
        createdAt: DateTime.utc(2026),
        operation: operation,
      ),
    ]);
    notifyListeners();
  }

  void changed() => notifyListeners();
}

_Fixture _family({int siblings = 2, int children = 2}) {
  final fixture = _Fixture()
    ..name(rootTreePersonId, 'Я')
    ..add('Отец', sex: TreeSex.male)
    ..add('Мать', sex: TreeSex.female)
    ..add('Дед', sex: TreeSex.male)
    ..add('Бабушка', sex: TreeSex.female)
    ..parents('Отец', father: 'Дед', mother: 'Бабушка')
    ..parents(rootTreePersonId, father: 'Отец', mother: 'Мать')
    ..add('Партнёр', sex: TreeSex.female);
  for (var i = 0; i < siblings; i++) {
    final id = 'Сестра-$i';
    fixture
      ..add(id, sex: TreeSex.female)
      ..parents(id, father: 'Отец', mother: 'Мать');
  }
  for (var i = 0; i < children; i++) {
    final id = 'Ребёнок-$i';
    fixture
      ..add(id)
      ..parents(id, father: rootTreePersonId, mother: 'Партнёр');
  }
  return fixture;
}

_Fixture _coParentFamily() {
  final fixture = _family(siblings: 1, children: 2)
    ..add('Отец партнёра', sex: TreeSex.male)
    ..add('Мать партнёра', sex: TreeSex.female)
    ..parents('Партнёр', father: 'Отец партнёра', mother: 'Мать партнёра')
    ..add('Сестра партнёра', sex: TreeSex.female)
    ..parents(
      'Сестра партнёра',
      father: 'Отец партнёра',
      mother: 'Мать партнёра',
    )
    ..add('Дядя', sex: TreeSex.male)
    ..parents('Дядя', father: 'Дед', mother: 'Бабушка')
    ..add('Тётя', sex: TreeSex.female)
    ..add('Кузина-партнёр', sex: TreeSex.female)
    ..parents('Кузина-партнёр', father: 'Дядя', mother: 'Тётя')
    ..add('Сестра кузины', sex: TreeSex.female)
    ..parents('Сестра кузины', father: 'Дядя', mother: 'Тётя')
    ..add('Ребёнок кузины')
    ..parents(
      'Ребёнок кузины',
      father: rootTreePersonId,
      mother: 'Кузина-партнёр',
    );
  for (final id in [
    'Партнёр',
    'Сестра партнёра',
    'Кузина-партнёр',
    'Сестра кузины',
  ]) {
    fixture
      ..apply(fixture.document.addPhoto(id, 'portrait', dataUrl: _png))
      ..apply(fixture.document.setValue(id, 'avatarPhotoId', 'portrait'));
  }
  return fixture;
}

_Fixture _nikitaOlgaFamily() {
  final fixture = _Fixture()
    ..name(rootTreePersonId, 'Ольга')
    ..add('oleg', sex: TreeSex.male)
    ..name('oleg', 'Олег')
    ..add('natalia', sex: TreeSex.female)
    ..name('natalia', 'Наталья')
    ..parents(rootTreePersonId, father: 'oleg', mother: 'natalia')
    ..add('anastasia', sex: TreeSex.female)
    ..name('anastasia', 'Анастасия')
    ..parents('anastasia', mother: 'natalia')
    ..add('gennady', sex: TreeSex.male)
    ..name('gennady', 'Геннадий')
    ..add('lydia', sex: TreeSex.female)
    ..name('lydia', 'Лидия')
    ..parents('natalia', father: 'gennady', mother: 'lydia')
    ..add('veronika', sex: TreeSex.female)
    ..name('veronika', 'Вероника')
    ..parents('veronika', father: 'gennady', mother: 'lydia')
    ..add('roman', sex: TreeSex.male)
    ..name('roman', 'Роман')
    ..add('nikita', sex: TreeSex.male)
    ..name('nikita', 'Никита')
    ..parents('nikita', father: 'roman', mother: 'veronika');
  fixture.apply(fixture.document.setValue(rootTreePersonId, 'sex', 'female'));
  return fixture;
}

_Fixture _olgaAnastasiaFamily() => _nikitaOlgaFamily()
  ..add('nekto', sex: TreeSex.male)
  ..name('nekto', 'Некто')
  ..parents('anastasia', father: 'nekto');

_Fixture _partnerProximityFamily() => _olgaAnastasiaFamily()
  ..add('roman-father', sex: TreeSex.male)
  ..add('roman-mother', sex: TreeSex.female)
  ..parents('roman', father: 'roman-father', mother: 'roman-mother')
  ..add('roman-sister', sex: TreeSex.female)
  ..name('roman-sister', 'Яна')
  ..parents('roman-sister', father: 'roman-father', mother: 'roman-mother')
  ..add('outsider-parent')
  ..add('outsider')
  ..name('outsider', 'Жан')
  ..parents('outsider', father: 'outsider-parent');

_Fixture _ancestorCorridorFamily() => _olgaAnastasiaFamily()
  ..add('valentina', sex: TreeSex.female)
  ..name('valentina', 'Валентина')
  ..parents('roman', mother: 'valentina')
  ..add('oleg-father', sex: TreeSex.male)
  ..name('oleg-father', 'Без имени')
  ..add('oleg-mother', sex: TreeSex.female)
  ..name('oleg-mother', '?')
  ..parents('oleg', father: 'oleg-father', mother: 'oleg-mother')
  ..add('shrek', sex: TreeSex.male)
  ..name('shrek', 'Шрек')
  ..parents('shrek', father: 'oleg-father')
  ..add('paternal-context', sex: TreeSex.male)
  ..name('paternal-context', 'Алексей по отцу')
  ..add('roman-half-sibling', sex: TreeSex.female)
  ..name('roman-half-sibling', 'Сестра Романа')
  ..parents(
    'roman-half-sibling',
    father: 'paternal-context',
    mother: 'valentina',
  )
  ..add('maternal-great-father', sex: TreeSex.male)
  ..add('maternal-great-mother', sex: TreeSex.female)
  ..parents(
    'lydia',
    father: 'maternal-great-father',
    mother: 'maternal-great-mother',
  )
  ..add('paternal-great-father', sex: TreeSex.male)
  ..add('paternal-great-mother', sex: TreeSex.female)
  ..parents(
    'valentina',
    father: 'paternal-great-father',
    mother: 'paternal-great-mother',
  )
  ..add('maternal-context-great-father', sex: TreeSex.male)
  ..name('maternal-context-great-father', 'Борис по матери')
  ..parents('oleg-father', father: 'maternal-context-great-father')
  ..add('paternal-context-great-father', sex: TreeSex.male)
  ..name('paternal-context-great-father', 'Борис по отцу')
  ..parents('paternal-context', father: 'paternal-context-great-father');

_Fixture _parentRowDriftFamily() => _olgaAnastasiaFamily()
  ..add('prikol', sex: TreeSex.male)
  ..name('prikol', 'Прикол')
  ..parents('prikol', father: 'gennady', mother: 'lydia')
  ..add('valentina', sex: TreeSex.female)
  ..name('valentina', 'Валентина')
  ..parents('roman', mother: 'valentina')
  ..add('oleg-father', sex: TreeSex.male)
  ..name('oleg-father', 'Без имени')
  ..add('oleg-mother', sex: TreeSex.female)
  ..name('oleg-mother', '?')
  ..parents('oleg', father: 'oleg-father', mother: 'oleg-mother')
  ..add('shrek', sex: TreeSex.male)
  ..name('shrek', 'Шрек')
  ..parents('shrek', father: 'oleg-father')
  ..add('test', sex: TreeSex.male)
  ..name('test', 'тест')
  ..parents('lydia', father: 'test')
  ..add('test-parent')
  ..parents('test', father: 'test-parent');

// Each sibling needs an own co-parent: a partnerless sibling now correctly uses
// sibling-partner proximity too, so the old fixture no longer forces a reorder.
// Reversing actual parent roles makes the target change toward the opposite
// packed-row boundary without relying on sex, names, or removed layout rules.
_Fixture _selectionPermutationFamily({bool reverseCoParentRoles = false}) {
  final fixture = _parentRowDriftFamily()
    ..add('shrek-partner', sex: TreeSex.female)
    ..name('shrek-partner', 'Агата')
    ..add('shrek-child')
    ..parents('shrek-child', father: 'shrek', mother: 'shrek-partner');
  if (reverseCoParentRoles) {
    fixture
      ..parents(rootTreePersonId, father: 'natalia', mother: 'oleg')
      ..parents('shrek-child', father: 'shrek-partner', mother: 'shrek');
  }
  return fixture;
}

_Fixture _collateralParentFamily() {
  final fixture = _family(siblings: 1, children: 2)
    ..add('maternal-coparent')
    ..add('paternal-coparent')
    ..add('maternal-half')
    ..parents('maternal-half', father: 'maternal-coparent', mother: 'Мать')
    ..add('paternal-half')
    ..parents('paternal-half', father: 'Отец', mother: 'paternal-coparent')
    ..add('aunt')
    ..parents('aunt', father: 'Дед', mother: 'Бабушка');
  for (final (branch, relative, mother) in const [
    ('full', 'Сестра-0', true),
    ('maternal', 'maternal-half', false),
    ('paternal', 'paternal-half', true),
    ('cousin', 'aunt', true),
  ]) {
    final outsider = '$branch-outsider';
    fixture
      ..add(outsider)
      ..name(outsider, 'ААА чужой родитель')
      ..name(relative, 'ЯЯЯ кровный родственник $branch')
      ..apply(fixture.document.setValue(relative, 'birthDate', '1980-01-01'))
      ..add('$outsider-parent')
      ..parents(outsider, mother: '$outsider-parent');
    for (var i = 0; i < 2; i++) {
      fixture
        ..add('$branch-child-$i')
        ..parents(
          '$branch-child-$i',
          father: mother ? outsider : relative,
          mother: mother ? relative : outsider,
        );
    }
  }
  return fixture;
}

_Fixture _lineageFamily() {
  final fixture = _Fixture()..name(rootTreePersonId, 'Я');
  final generations = <List<String>>[
    ['f', 'm'],
    ['ff', 'fm', 'mf', 'mm'],
    ['fff', 'ffm', 'fmf', 'fmm', 'mff', 'mfm', 'mmf', 'mmm'],
  ];
  for (final generation in generations) {
    for (final id in generation) {
      fixture.add(id, sex: id.endsWith('f') ? TreeSex.male : TreeSex.female);
    }
  }
  fixture
    ..parents(rootTreePersonId, father: 'f', mother: 'm')
    ..add('sibling')
    ..parents('sibling', father: 'f', mother: 'm');
  for (final id in [...generations[0], ...generations[1]]) {
    fixture.parents(id, father: '${id}f', mother: '${id}m');
  }
  // Wide, unrelated context lets every ancestor generation be panned out of
  // view without making the actual both-lineage group too wide to center.
  for (var i = 0; i < 12; i++) {
    for (var depth = 0; depth <= 3; depth++) {
      final id = 'zz-filler-$i-$depth';
      fixture.add(id);
      if (depth > 0) {
        fixture.parents(id, father: 'zz-filler-$i-${depth - 1}');
      }
    }
  }
  return fixture;
}

Future<void> _mount(
  WidgetTester tester,
  _Session session, {
  Size size = const Size(1100, 850),
  double devicePixelRatio = 1,
  bool reduceMotion = true,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  TargetPlatform? platform,
  String? initialPersonId,
  ValueChanged<String>? onPickPerson,
  bool Function(TreePerson)? canPickPerson,
}) async {
  tester.view.physicalSize = size * devicePixelRatio;
  tester.view.devicePixelRatio = devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(session.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        platform: platform,
        brightness: brightness,
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduceMotion,
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: TreeEditor(
          session: session,
          initialPersonId: initialPersonId,
          onPickPerson: onPickPerson,
          canPickPerson: canPickPerson,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _person(String id) => find.byKey(ValueKey('tree-person-$id'));

ScrollController _levelController(WidgetTester tester, int index) => tester
    .widget<SingleChildScrollView>(
      find.byKey(ValueKey('tree-level-scroll-$index')),
    )
    .controller!;

ScrollController _mainController(WidgetTester tester) => tester
    .widget<SingleChildScrollView>(find.byKey(const Key('tree-main-scroll')))
    .controller!;

int _levelOf(_Fixture fixture, String id) => TreeLayout.build(
  fixture.document,
  selectedId: rootTreePersonId,
  mode: TreeTrunkMode.both,
).positions[id]!.level;

SemanticsData _nodeSemantics(WidgetTester tester, String name) => tester
    .getSemantics(find.bySemanticsLabel('Выбрать $name'))
    .getSemanticsData();

CustomPainter _linkPainter(WidgetTester tester) =>
    tester.widget<CustomPaint>(find.byKey(const Key('tree-links'))).painter!;

TreeLayout _layoutOf(
  _Fixture fixture, {
  String selectedId = rootTreePersonId,
  TreeTrunkMode mode = TreeTrunkMode.both,
}) => TreeLayout.build(
  fixture.document,
  selectedId: selectedId,
  mode: mode,
  nodeExtent: 108,
);

Finder _blockFor(_Fixture fixture, String id) => find.byKey(
  ValueKey('tree-block-${_layoutOf(fixture).positions[id]!.blockId}'),
);

Finder _surnameFor(_Fixture fixture, String id) => find.byKey(
  ValueKey('tree-block-surname-${_layoutOf(fixture).positions[id]!.blockId}'),
);

Finder _filterFor(String id) =>
    find.descendant(of: _person(id), matching: find.byType(ColorFiltered));

ColorFilter _filterOf(WidgetTester tester, String id) =>
    tester.widget<ColorFiltered>(_filterFor(id)).colorFilter;

Color _washOf(WidgetTester tester, _Fixture fixture, String id) =>
    (tester.widget<DecoratedBox>(_blockFor(fixture, id)).decoration
            as BoxDecoration)
        .color!;

Future<void> _selectPerson(WidgetTester tester, String id) async {
  // All cards are mounted, even outside the independently scrolled bands.
  tester
      .widget<InkWell>(
        find.descendant(of: _person(id), matching: find.byType(InkWell)),
      )
      .onTap!();
  await tester.pumpAndSettle();
}

void _expectFullColorPhotoNode(WidgetTester tester, String id, Color color) {
  expect(_filterFor(id), findsNothing, reason: '$id must not be desaturated.');
  expect(
    find.ancestor(of: _person(id), matching: find.byType(ColorFiltered)),
    findsNothing,
    reason: 'A block-level filter must not desaturate $id either.',
  );
  final photo = find.descendant(of: _person(id), matching: find.byType(Image));
  expect(photo, findsOneWidget);
  expect(tester.widget<Image>(photo).color, isNull);
  expect(
    tester
        .widget<Text>(find.descendant(of: _person(id), matching: find.text(id)))
        .style!
        .color,
    color,
  );
  final ring = tester.widget<DecoratedBox>(
    find.descendant(
      of: _person(id),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).border != null,
      ),
    ),
  );
  final border = (ring.decoration as BoxDecoration).border! as Border;
  expect(border.top.color, color);
}

double _cross(Offset offset, bool portrait) => portrait ? offset.dy : offset.dx;

void _expectAffineCards(
  WidgetTester tester,
  Map<String, Rect> before, {
  required Offset focal,
  required double scale,
}) {
  for (final entry in before.entries) {
    final after = tester.getRect(_person(entry.key));
    final expected = focal + (entry.value.topLeft - focal) * scale;
    expect(
      (after.topLeft - expected).distance,
      lessThan(.2),
      reason: '${entry.key} must follow the same focal transform as every row.',
    );
    expect(after.width, closeTo(entry.value.width * scale, .1));
    expect(after.height, closeTo(entry.value.height * scale, .1));
  }
}

void _expectTranslatedCards(
  WidgetTester tester,
  Map<String, Rect> before,
  Offset delta,
) {
  for (final entry in before.entries) {
    final after = tester.getRect(_person(entry.key));
    expect(
      (after.topLeft - entry.value.topLeft - delta).distance,
      lessThan(.2),
      reason:
          '${entry.key} must follow the entire canvas by $delta; '
          'actual movement was ${after.topLeft - entry.value.topLeft}.',
    );
    expect(after.width, closeTo(entry.value.width, .01));
    expect(after.height, closeTo(entry.value.height, .01));
  }
}

Map<int, double> _relativeLogicalCrossOffsets(
  WidgetTester tester,
  TreeLayout layout, {
  required bool portrait,
}) {
  final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
  final scale = tester.getRect(_person(layout.selectedId)).width / 108;
  final offsets = <int, double>{};
  for (final level in layout.levels) {
    final person = level.blocks.first.people.first.id;
    final screen = _cross(
      tester.getCenter(_person(person)) - canvas.topLeft,
      portrait,
    );
    // Remove the lane's padding/origin: the model point at the viewport start
    // is the meaningful logical scroll coordinate, not a raw padded offset.
    offsets[level.index] =
        layout.positions[person]!.crossCenter - screen / scale;
  }
  final reference = offsets.values.first;
  return {
    for (final entry in offsets.entries) entry.key: entry.value - reference,
  };
}

void _expectCanonicalRowGeometry(
  WidgetTester tester,
  TreeLayout layout, {
  required bool portrait,
}) {
  final scale = tester.getRect(_person(layout.selectedId)).width / 108;
  for (final level in layout.levels) {
    final people = level.blocks.expand((block) => block.people).toList();
    final first = people.first.id;
    for (final person in people.skip(1)) {
      expect(
        _cross(
          tester.getCenter(_person(person.id)) -
              tester.getCenter(_person(first)),
          portrait,
        ),
        closeTo(
          (layout.positions[person.id]!.crossCenter -
                  layout.positions[first]!.crossCenter) *
              scale,
          .2,
        ),
        reason: '${person.id} must use the cold, current-focus row geometry.',
      );
    }
  }
}

Set<int> _expectPreservedOrCanonicalRows(
  WidgetTester tester, {
  required TreeLayout beforeLayout,
  required TreeLayout afterLayout,
  required Map<String, Rect> before,
  required bool portrait,
  required String reason,
}) {
  _expectCanonicalRowGeometry(tester, afterLayout, portrait: portrait);
  final unchanged = <int>{};
  for (final level in afterLayout.levels) {
    final people = level.blocks.expand((block) => block.people).toList();
    final anchor = people.first.id;
    final oldAnchor = beforeLayout.positions[anchor]!;
    final newAnchor = afterLayout.positions[anchor]!;
    final sameRelativeGeometry = people.every((person) {
      final old = beforeLayout.positions[person.id]!;
      final current = afterLayout.positions[person.id]!;
      return old.level == current.level &&
          ((old.crossCenter - oldAnchor.crossCenter) -
                      (current.crossCenter - newAnchor.crossCenter))
                  .abs() <
              .001;
    });
    if (!sameRelativeGeometry) continue;
    unchanged.add(level.index);
    for (final person in people) {
      final actual = tester.getRect(_person(person.id));
      expect(
        (actual.topLeft - before[person.id]!.topLeft).distance,
        lessThan(.5),
        reason: '$reason moved ${person.id} without a canonical row reorder.',
      );
      expect(actual.size, before[person.id]!.size);
    }
  }
  return unchanged;
}

Future<void> _expectSteadySelectionPaints(
  WidgetTester tester, {
  required Future<void> Function() select,
  required Map<String, Finder> targets,
  required Map<String, Rect> pinned,
  required String reason,
}) async {
  final paints = <Map<String, Rect>>[];
  var recording = true;
  // The binding's renderer callback has painted by this persistent callback,
  // but selection's post-frame scroll restoration has not yet run. Reading
  // only after pump/settle can therefore miss an already-painted wrong offset.
  tester.binding.addPersistentFrameCallback((_) {
    if (!recording) return;
    paints.add({
      for (final entry in targets.entries)
        entry.key: tester.getRect(entry.value),
    });
  });
  try {
    await select();
    for (var frame = 0; frame < 18; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull, reason: '$reason frame=$frame');
    }
    await tester.pumpAndSettle();
  } finally {
    recording = false;
  }
  expect(paints, isNotEmpty);
  final settled = {
    for (final entry in targets.entries) entry.key: tester.getRect(entry.value),
  };
  for (var frame = 0; frame < paints.length; frame++) {
    for (final entry in paints[frame].entries) {
      final expected = pinned[entry.key] ?? settled[entry.key]!;
      expect(
        (entry.value.topLeft - expected.topLeft).distance,
        lessThan(.2),
        reason:
            '$reason first-paint/frame=$frame ${entry.key}: '
            'painted=${entry.value}, expected=$expected',
      );
      expect(entry.value.size, expected.size, reason: '$reason frame=$frame');
    }
  }
}

void _expectInside(Rect node, Rect viewport) {
  expect(node.left, greaterThanOrEqualTo(viewport.left - .1));
  expect(node.top, greaterThanOrEqualTo(viewport.top - .1));
  expect(node.right, lessThanOrEqualTo(viewport.right + .1));
  expect(node.bottom, lessThanOrEqualTo(viewport.bottom + .1));
}

void _expectPaintRgb(Color actual, Color expected) {
  // Paint quantizes interpolated colors to 8-bit components.
  expect(actual.r, closeTo(expected.r, 1 / 255));
  expect(actual.g, closeTo(expected.g, 1 / 255));
  expect(actual.b, closeTo(expected.b, 1 / 255));
}

Offset _pathStart(Path path) =>
    path.computeMetrics().single.getTangentForOffset(0)!.position;

Offset _pathEnd(Path path) {
  final metric = path.computeMetrics().single;
  return metric.getTangentForOffset(metric.length)!.position;
}

Set<(String, String)> _renderedConnections(
  WidgetTester tester,
  TreeLayout layout, {
  required bool portrait,
}) {
  final paintBox = tester.renderObject<RenderBox>(
    find.byKey(const Key('tree-links')),
  );
  final drawing = _ConnectionCanvas();
  _linkPainter(tester).paint(drawing, paintBox.size);
  Rect local(Finder finder) {
    final rect = tester.getRect(finder);
    // The painter uses logical coordinates inside the shared canvas transform.
    // Remove zoom and pan before comparing captured paths to real card edges.
    return Rect.fromPoints(
      paintBox.globalToLocal(rect.topLeft),
      paintBox.globalToLocal(rect.bottomRight),
    );
  }

  final parents = <String, Offset>{
    for (final id in layout.positions.keys)
      id: portrait
          ? Offset(
              local(_person(id)).center.dx + 30,
              local(_person(id)).top + 36,
            )
          : Offset(local(_person(id)).center.dx, local(_person(id)).top + 66),
  };
  final targets = <String, Offset>{
    for (final id in layout.positions.keys)
      'person:$id': portrait
          ? Offset(
              local(_person(id)).center.dx - 30,
              local(_person(id)).top + 36,
            )
          : Offset(local(_person(id)).center.dx, local(_person(id)).top + 6),
    for (final level in layout.levels)
      for (final block in level.blocks)
        'block:${block.id}': portrait
            ? local(find.byKey(ValueKey('tree-block-${block.id}'))).centerLeft
            : local(find.byKey(ValueKey('tree-block-${block.id}'))).topCenter,
  };
  final connections = <(String, String)>{};
  for (final path in drawing.paths) {
    final sources = parents.entries
        .where((entry) => (entry.value - _pathStart(path)).distance < .2)
        .map((entry) => entry.key)
        .toList();
    final destinations = targets.entries
        .where((entry) => (entry.value - _pathEnd(path)).distance < .2)
        .map((entry) => entry.key)
        .toList();
    expect(
      sources,
      hasLength(1),
      reason: 'Every painted link needs a real parent.',
    );
    expect(
      destinations,
      hasLength(1),
      reason: 'Every painted link needs an exact avatar or block destination.',
    );
    connections.add((sources.single, destinations.single));
  }
  expect(
    connections,
    hasLength(drawing.paths.length),
    reason: 'Rendering must not duplicate the same parent-to-target link.',
  );
  return connections;
}

Future<void> _wheel(
  WidgetTester tester, {
  required Offset position,
  required Offset delta,
}) async {
  final responses = <bool>[];
  await tester.sendEventToBinding(
    PointerScrollEvent(
      kind: PointerDeviceKind.mouse,
      position: position,
      scrollDelta: delta,
      onRespond: ({required bool allowPlatformDefault}) =>
          responses.add(allowPlatformDefault),
    ),
  );
  await tester.pumpAndSettle();
  expect(responses, [
    false,
  ], reason: 'The canvas consumes the wheel without platform scrolling.');
}

String _zoomLabel(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('tree-zoom-value'))).data!;

Future<void> _zoomWheel(
  WidgetTester tester,
  double dy, {
  required bool browserScale,
  Offset? focal,
}) async {
  focal ??= tester.getRect(find.byKey(const Key('tree-canvas'))).center;
  if (browserScale) {
    // Flutter's web engine uses scale = exp(-wheelDeltaY / 200).
    await tester.sendEventToBinding(
      PointerScaleEvent(
        kind: PointerDeviceKind.mouse,
        position: focal,
        scale: math.exp(-dy / 200),
      ),
    );
    await tester.pumpAndSettle();
  } else {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    try {
      await _wheel(tester, position: focal, delta: Offset(0, dy));
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }
  }
}

Future<void> _pinchBy(WidgetTester tester, double factor) async {
  final center = tester.getRect(find.byKey(const Key('tree-canvas'))).center;
  final first = await tester.startGesture(center - const Offset(25, 0));
  final second = await tester.startGesture(
    center + const Offset(25, 0),
    pointer: 2,
  );
  await tester.pump();
  await first.moveTo(center - Offset(25 * factor, 0));
  await tester.pump();
  await second.moveTo(center + Offset(25 * factor, 0));
  await tester.pumpAndSettle();
  await first.up();
  await second.up();
  await tester.pumpAndSettle();
}

void _expectToolbarFits(WidgetTester tester) {
  final toolbar = tester.getRect(find.byKey(const Key('tree-toolbar')));
  final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
  final search = tester.getRect(find.byKey(const Key('tree-search-field')));
  final mode = tester.getRect(find.byKey(const Key('tree-mode-picker')));
  final align = tester.getRect(find.byKey(const Key('tree-align-all')));
  final toggle = tester.getRect(find.byKey(const Key('tree-toolbar-toggle')));
  final zoom = [
    for (final key in ['tree-zoom-out', 'tree-zoom-reset', 'tree-zoom-in'])
      tester.getRect(find.byKey(Key(key))),
  ];
  final zoomGroup = zoom.reduce((a, b) => a.expandToInclude(b));
  expect(toolbar.height, closeTo(45, .1));
  expect(canvas.top, greaterThanOrEqualTo(toolbar.bottom));
  for (final control in [search, mode, align, toggle, ...zoom]) {
    _expectInside(control, toolbar);
    expect(control.width, greaterThan(0));
    expect(control.height, greaterThan(0));
  }
  expect(
    find.byTooltip(RegExp(r'^Выровнять всё(?:\nПробел)?$')),
    findsOneWidget,
  );
  expect(align.left, greaterThanOrEqualTo(mode.right - .1));
  expect(align.left - mode.right, lessThanOrEqualTo(8));
  expect(align.center.dy, closeTo(mode.center.dy, .1));
  expect(zoomGroup.width, lessThanOrEqualTo(108));
  expect(zoom[0].right, lessThanOrEqualTo(zoom[2].left + .1));
  expect(zoom[2].right, lessThanOrEqualTo(zoom[1].left + .1));
  expect(search.left, greaterThanOrEqualTo(zoomGroup.right));
  expect(search.right, closeTo(toolbar.right - 4, .1));
  for (final control in [search, mode, align, ...zoom]) {
    expect(control.center.dy, closeTo(toggle.center.dy, 1));
  }
  expect(
    find.descendant(
      of: find.byKey(const Key('tree-zoom-controls')),
      matching: find.byIcon(Icons.search),
    ),
    findsNothing,
  );
  expect(tester.takeException(), isNull);
}

Future<void> _zoomSteps(WidgetTester tester, int steps) async {
  final control = find.byKey(Key(steps > 0 ? 'tree-zoom-in' : 'tree-zoom-out'));
  for (var i = 0; i < steps.abs(); i++) {
    await tester.tap(control);
    await tester.pumpAndSettle();
  }
}

Future<void> _chooseMode(WidgetTester tester, TreeTrunkMode mode) async {
  await tester.tap(find.byKey(const Key('tree-mode-picker')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('tree-mode-${mode.name}')));
  await tester.pumpAndSettle();
}

class _ConnectionCanvas implements Canvas {
  final paths = <Path>[];
  final colors = <Color>[];

  @override
  void drawPath(Path path, Paint paint) {
    paths.add(path);
    colors.add(paint.color);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  testWidgets('empty room is exactly one selectable, unnamed root', (
    tester,
  ) async {
    final session = _Session(TreeDocument());
    await _mount(tester, session, size: const Size(390, 844));

    expect(find.byKey(const Key('tree-canvas')), findsOneWidget);
    expect(find.byKey(const Key('tree-toolbar')), findsOneWidget);
    expect(_person(rootTreePersonId), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith('tree-person-'),
      ),
      findsOneWidget,
    );
    final data = _nodeSemantics(tester, 'Без имени');
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.flagsCollection.isSelected == Tristate.isTrue, isTrue);
    final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
    expect(
      tester.getCenter(_person(rootTreePersonId)).dx,
      closeTo(canvas.center.dx, 1),
    );
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      '${brightness.name} selection fill is translucent while names and outlines remain opaque',
      (tester) async {
        final fixture = _family(siblings: 1, children: 0);
        final session = _Session(fixture.document);
        await _mount(tester, session, brightness: brightness);
        final people = fixture.document.people;
        for (final selected in [rootTreePersonId, 'Отец', 'Мать']) {
          await _selectPerson(tester, selected);
          final theme = Theme.of(tester.element(_person(selected)));
          for (final id in [rootTreePersonId, 'Отец', 'Мать']) {
            final material = tester.widget<Material>(
              find.descendant(of: _person(id), matching: find.byType(Material)),
            );
            final shape = material.shape! as RoundedRectangleBorder;
            expect(
              material.color,
              id == selected
                  ? theme.colorScheme.surfaceContainerLowest.withValues(
                      alpha: .5,
                    )
                  : Colors.transparent,
            );
            expect(shape.side.width, 1.5);
            expect(shape.side.color.a, id == selected ? 1 : 0);
            final name = tester.widget<DecoratedBox>(
              find.byKey(ValueKey('tree-name-background-$id')),
            );
            expect((name.decoration as BoxDecoration).color!.a, 1);
          }
        }
        expect(identical(fixture.document.people, people), isTrue);
        expect(session.operations, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final portrait in [false, true]) {
    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} explicit siblings update grouping, parent curves, and split semantics without navigation writes',
      (tester) async {
        final fixture = _Fixture()..name(rootTreePersonId, 'Борис');
        fixture.apply(
          fixture.document.setIndividualSurname(
            rootTreePersonId,
            text: 'Личный',
          ),
        );
        final session = _Session(fixture.document, editingAllowed: true);
        await _mount(
          tester,
          session,
          size: portrait ? const Size(1500, 2100) : const Size(2100, 1500),
        );

        Future<void> check(List<List<String>> groups, String stage) async {
          final writes = session.operations.length;
          final people = fixture.document.people;
          for (final mode in TreeTrunkMode.values) {
            await _chooseMode(tester, mode);
            for (final selected in [
              rootTreePersonId,
              if (people.containsKey('brother')) 'brother',
              if (people.containsKey('sister')) 'sister',
            ]) {
              await _selectPerson(tester, selected);
              final layout = _layoutOf(
                fixture,
                selectedId: selected,
                mode: mode,
              );
              for (final ids in groups) {
                final block = layout.levels
                    .expand((level) => level.blocks)
                    .singleWhere(
                      (block) =>
                          block.people.any((person) => person.id == ids.first),
                    );
                final canonical = [for (final id in ids) people[id]!]
                  ..sort(compareTreePeopleByBirth);
                expect(
                  block.people.map((person) => person.id),
                  canonical.map((person) => person.id),
                  reason: '$stage, ${mode.name}, $selected',
                );
                expect(
                  ids.map((id) => layout.positions[id]!.level).toSet(),
                  hasLength(1),
                  reason: '$stage: explicit siblings share one generation.',
                );
              }
              final rendered = _renderedConnections(
                tester,
                layout,
                portrait: portrait,
              );
              expect(
                rendered.map((connection) => connection.$1).toSet(),
                people.values
                    .expand((person) => [person.fatherId, person.motherId])
                    .whereType<String>()
                    .toSet(),
                reason: '$stage: sibling claims never become parent curves.',
              );
              _expectCanonicalRowGeometry(tester, layout, portrait: portrait);
              expect(tester.takeException(), isNull);
            }
          }
          expect(session.operations, hasLength(writes));
          expect(identical(fixture.document.people, people), isTrue);
        }

        Future<void> apply(TreeOperation operation) async {
          final count = session.operations.length;
          await session.applyTreeOperation(operation);
          await tester.pumpAndSettle();
          expect(session.operations, hasLength(count + 1));
        }

        await apply(
          fixture.document.createSibling(
            rootTreePersonId,
            'brother',
            name: 'Алексей',
            sex: TreeSex.male,
          ),
        );
        await apply(
          fixture.document.createSibling(
            'brother',
            'sister',
            name: 'Вера',
            sex: TreeSex.female,
          ),
        );
        expect(fixture.document.directSiblingLinks, hasLength(2));
        expect(fixture.document.person('brother')!.surname, isEmpty);
        final linkedBlock = _layoutOf(fixture).levels
            .expand((level) => level.blocks)
            .singleWhere(
              (block) => block.people.any((person) => person.id == 'brother'),
            );
        expect(surnameForBlock(linkedBlock.people), 'разные фамилии');
        await check([
          [rootTreePersonId, 'brother', 'sister'],
        ], 'parentless links');

        await apply(
          fixture.document.createPerson(
            'father',
            name: 'Отец',
            sex: TreeSex.male,
          ),
        );
        await apply(fixture.document.setValue('sister', 'fatherId', 'father'));
        for (final id in [rootTreePersonId, 'brother', 'sister']) {
          expect(fixture.document.person(id)!.fatherId, 'father');
        }
        await check([
          [rootTreePersonId, 'brother', 'sister'],
        ], 'shared father');
        await apply(fixture.document.setValue('brother', 'fatherId', null));
        for (final id in [rootTreePersonId, 'brother', 'sister']) {
          expect(fixture.document.person(id)!.fatherId, isNull);
        }
        await check([
          [rootTreePersonId, 'brother', 'sister'],
        ], 'shared parent clear');
        await apply(
          fixture.document.setValue(rootTreePersonId, 'fatherId', 'father'),
        );
        await apply(fixture.document.unlinkSibling('brother', 'sister'));
        expect(fixture.document.directSiblingLinks, hasLength(1));
        expect(fixture.document.person('sister')!.fatherId, 'father');
        expect(
          fixture.document.siblingsOf('sister', includeHalf: false),
          isEmpty,
        );
        await check([
          [rootTreePersonId, 'brother'],
          ['sister'],
        ], 'split retains half sibling');

        await apply(
          fixture.document.createPerson(
            'mother',
            name: 'Мать',
            sex: TreeSex.female,
          ),
        );
        await apply(fixture.document.setValue('brother', 'motherId', 'mother'));
        expect(fixture.document.directSiblingLinks, isEmpty);
        expect(fixture.document.person(rootTreePersonId)!.motherId, 'mother');
        expect(fixture.document.person('sister')!.motherId, isNull);
        await check([
          [rootTreePersonId, 'brother'],
          ['sister'],
        ], 'computed siblings after completion');
        await apply(
          fixture.document.setValue(rootTreePersonId, 'motherId', null),
        );
        expect(fixture.document.directSiblingLinks, isEmpty);
        expect(fixture.document.person('brother')!.motherId, 'mother');
        await check([
          [rootTreePersonId],
          ['brother'],
          ['sister'],
        ], 'retired links do not return');
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} a parentless explicit sibling supplies the related nephew curve instead of an unrelated co-parent',
      (tester) async {
        final fixture = _Fixture()..name(rootTreePersonId, 'Борис');
        fixture.apply(
          fixture.document.createSibling(
            rootTreePersonId,
            'sister',
            name: 'Яна',
            sex: TreeSex.female,
          ),
        );
        fixture
          ..add('unrelated', sex: TreeSex.male)
          ..name('unrelated', 'Алексей')
          ..add('nephew')
          ..parents('nephew', father: 'unrelated', mother: 'sister');
        final session = _Session(fixture.document);
        final people = fixture.document.people;
        await _mount(
          tester,
          session,
          size: portrait ? const Size(1200, 1800) : const Size(1800, 1200),
        );
        for (final mode in TreeTrunkMode.values) {
          await _chooseMode(tester, mode);
          final layout = _layoutOf(fixture, mode: mode);
          expect(layout.positions['sister']!.emphasis, TreeEmphasis.normal);
          expect(layout.positions['nephew']!.emphasis, TreeEmphasis.cousin);
          expect(_renderedConnections(tester, layout, portrait: portrait), {
            ('sister', 'block:${layout.positions['nephew']!.blockId}'),
          });
          expect(session.operations, isEmpty);
          expect(identical(fixture.document.people, people), isTrue);
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  for (final (platform, size, picking) in [
    (TargetPlatform.windows, const Size(1100, 850), false),
    (TargetPlatform.linux, const Size(1100, 850), false),
    (TargetPlatform.macOS, const Size(1100, 850), false),
    (TargetPlatform.windows, const Size(430, 900), true),
    (TargetPlatform.android, const Size(430, 900), false),
    (TargetPlatform.iOS, const Size(430, 900), true),
    (TargetPlatform.android, const Size(1100, 850), false),
  ]) {
    testWidgets(
      'toolbar hotkey tooltips on ${platform.name} at ${size.width} in the ${picking ? 'picker' : 'editor'}',
      (tester) async {
        final fixture = _lineageFamily();
        final session = _Session(fixture.document);
        final picked = <String>[];
        await _mount(
          tester,
          session,
          size: size,
          platform: platform,
          onPickPerson: picking ? picked.add : null,
        );
        final desktop = [
          TargetPlatform.windows,
          TargetPlatform.linux,
          TargetPlatform.macOS,
        ].contains(platform);
        final hints = {
          'tree-align-all': ('Выровнять всё', 'Пробел'),
          'tree-zoom-out': ('Уменьшить масштаб', 'Ctrl + колесо вниз'),
          'tree-zoom-in': ('Увеличить масштаб', 'Ctrl + колесо вверх'),
        };
        for (final entry in hints.entries) {
          final (label, shortcut) = entry.value;
          final message = desktop ? '$label\n$shortcut' : label;
          expect(
            tester.widget<IconButton>(find.byKey(Key(entry.key))).tooltip,
            message,
          );
          expect(find.byTooltip(message), findsOneWidget);
        }
        expect(find.byTooltip('Свернуть панель дерева'), findsOneWidget);
        expect(find.byTooltip('Сбросить масштаб'), findsOneWidget);
        for (final (key, label) in const [
          (LogicalKeyboardKey.digit1, 'По отцу'),
          (LogicalKeyboardKey.digit2, 'По матери'),
          (LogicalKeyboardKey.digit3, 'Обе линии'),
        ]) {
          await tester.sendKeyEvent(key);
          await tester.pumpAndSettle();
          expect(
            find.byTooltip(
              desktop
                  ? 'Линия дерева: $label\n1 — по отцу\n2 — по матери\n3 — обе линии'
                  : 'Линия дерева: $label',
            ),
            findsOneWidget,
          );
          _expectToolbarFits(tester);
        }
        if (platform == TargetPlatform.windows && !picking) {
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(
            tester.getCenter(find.byKey(const Key('tree-align-all'))),
          );
          await tester.pump(const Duration(seconds: 1));
          await tester.pump(const Duration(milliseconds: 200));
          expect(find.text('Выровнять всё\nПробел'), findsOneWidget);
          await mouse.removePointer();
          await tester.pumpAndSettle();
        }
        expect(session.operations, isEmpty);
        expect(picked, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final picking in [false, true]) {
    testWidgets(
      'keyboard shortcuts select 1 father 2 mother 3 both in the ${picking ? 'picker' : 'editor'} with visible and hidden toolbar',
      (tester) async {
        final fixture = _lineageFamily();
        final session = _Session(fixture.document, editingAllowed: true);
        final people = fixture.document.people;
        final picked = <String>[];
        await _mount(
          tester,
          session,
          onPickPerson: picking ? picked.add : null,
        );
        final focus = tester
            .widget<Focus>(find.byKey(const Key('tree-keyboard-focus')))
            .focusNode!;
        expect(focus.hasPrimaryFocus, isTrue);
        for (final hidden in [false, true]) {
          if (hidden) {
            await tester.tap(find.byKey(const Key('tree-toolbar-toggle')));
            await tester.pumpAndSettle();
            focus.requestFocus();
            await tester.pump();
          }
          for (final (key, mode, label) in const [
            (LogicalKeyboardKey.digit1, TreeTrunkMode.father, 'По отцу'),
            (LogicalKeyboardKey.digit2, TreeTrunkMode.mother, 'По матери'),
            (LogicalKeyboardKey.digit3, TreeTrunkMode.both, 'Обе линии'),
          ]) {
            await tester.sendKeyEvent(key);
            await tester.pumpAndSettle();
            if (!hidden) {
              expect(find.byTooltip('Линия дерева: $label'), findsOneWidget);
            }
            final layout = _layoutOf(fixture, mode: mode);
            _expectCanonicalRowGeometry(tester, layout, portrait: false);
            expect(
              _nodeSemantics(tester, 'Я').flagsCollection.isSelected,
              Tristate.isTrue,
            );
            expect(session.operations, isEmpty);
            expect(identical(fixture.document.people, people), isTrue);
          }
        }
        expect(picked, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'keyboard Space aligns independently panned rows with hidden toolbar and ignores held-key repeats',
    (tester) async {
      final fixture = _lineageFamily();
      final session = _Session(fixture.document);
      await _mount(tester, session);
      final align = tester
          .widget<IconButton>(find.byKey(const Key('tree-align-all')))
          .onPressed!;
      await tester.tap(find.byKey(const Key('tree-toolbar-toggle')));
      await tester.pumpAndSettle();
      final focus = tester
          .widget<Focus>(find.byKey(const Key('tree-keyboard-focus')))
          .focusNode!;
      focus.requestFocus();
      await tester.pump();
      align();
      await tester.pumpAndSettle();
      final aligned = {
        for (final id in fixture.document.people.keys)
          id: tester.getRect(_person(id)),
      };
      final controllers = [
        for (final level in _layoutOf(fixture).levels)
          _levelController(tester, level.index),
      ];
      for (final controller in controllers) {
        controller.jumpTo(
          (controller.offset + 60).clamp(
            0,
            controller.position.maxScrollExtent,
          ),
        );
      }
      await tester.pump();
      expect(controllers.any((controller) => controller.offset > 0), isTrue);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      for (final entry in aligned.entries) {
        expect(
          (tester.getRect(_person(entry.key)).topLeft - entry.value.topLeft)
              .distance,
          lessThan(.2),
        );
      }
      final row = controllers.firstWhere(
        (controller) =>
            controller.position.maxScrollExtent - controller.offset > 40,
      );
      row.jumpTo(row.offset + 30);
      await tester.pump();
      final panned = row.offset;
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(
        row.offset,
        panned,
        reason: 'Holding Space must not repeatedly realign a user pan.',
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      expect(session.operations, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'keyboard shortcuts ignore modifiers, repeated digit presses and inactive application',
    (tester) async {
      final fixture = _lineageFamily();
      final session = _Session(fixture.document);
      await _mount(tester, session);
      final focus = tester
          .widget<Focus>(find.byKey(const Key('tree-keyboard-focus')))
          .focusNode!;
      final initialPainter = _linkPainter(tester);
      for (final modifier in [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.altLeft,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.shiftLeft,
      ]) {
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.sendKeyUpEvent(modifier);
        await tester.pumpAndSettle();
        expect(_linkPainter(tester), same(initialPainter));
        expect(find.byTooltip('Линия дерева: Обе линии'), findsOneWidget);
      }
      await tester.sendKeyDownEvent(LogicalKeyboardKey.digit1);
      await tester.pumpAndSettle();
      await _chooseMode(tester, TreeTrunkMode.mother);
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.digit1);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Линия дерева: По матери'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(find.byTooltip('Линия дерева: По матери'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(session.operations, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final portrait in [false, true]) {
    testWidgets(
      'keyboard shortcuts preserve ${portrait ? 'mobile' : 'desktop'} search typing and IME composition until canvas focus',
      (tester) async {
        final fixture = _family(siblings: 8, children: 3);
        final session = _Session(fixture.document, editingAllowed: true);
        await _mount(
          tester,
          session,
          size: portrait ? const Size(430, 900) : const Size(1100, 850),
        );
        final search = find.byKey(const Key('tree-search-field'));
        await tester.enterText(search, '1');
        await tester.pumpAndSettle();
        final controller = tester.widget<TextField>(search).controller!;
        final painter = _linkPainter(tester);
        final row = _levelController(
          tester,
          _levelOf(fixture, rootTreePersonId),
        );
        row.jumpTo((row.offset + 30).clamp(0, row.position.maxScrollExtent));
        await tester.pump();
        final offset = row.offset;
        for (final key in [
          LogicalKeyboardKey.digit1,
          LogicalKeyboardKey.space,
          LogicalKeyboardKey.digit2,
          LogicalKeyboardKey.digit3,
        ]) {
          await tester.sendKeyEvent(key);
        }
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '1 2 3',
            selection: TextSelection.collapsed(offset: 5),
            composing: TextRange(start: 2, end: 5),
          ),
        );
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(controller.text, '1 2 3');
        expect(controller.value.composing, const TextRange(start: 2, end: 5));
        expect(_linkPainter(tester), same(painter));
        expect(row.offset, offset);
        expect(tester.testTextInput.isVisible, isTrue);
        expect(session.operations, isEmpty);
        final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
        await tester.tapAt(canvas.topLeft + const Offset(8, 8));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Линия дерева: По матери'), findsOneWidget);
        expect(tester.widget<TextField>(search).focusNode!.hasFocus, isFalse);
        expect(session.operations, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'keyboard shortcuts do not intercept biography name or surname fields and modal routes',
    (tester) async {
      final fixture = _family();
      final session = _Session(fixture.document, editingAllowed: true);
      await _mount(tester, session);
      await tester.tap(find.byKey(const Key('open-biography')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('biography-edit-toggle')));
      await tester.pumpAndSettle();
      for (final key in ['person-name-field', 'person-surname-field']) {
        final field = find.byKey(Key(key));
        await tester.ensureVisible(field);
        await tester.enterText(field, '1 2 3');
        await tester.pumpAndSettle();
        final operations = session.operations.length;
        final painter = _linkPainter(tester);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '1 2 3',
            selection: TextSelection.collapsed(offset: 5),
            composing: TextRange(start: 0, end: 5),
          ),
        );
        await tester.pump();
        for (final key in [
          LogicalKeyboardKey.digit1,
          LogicalKeyboardKey.digit2,
          LogicalKeyboardKey.digit3,
          LogicalKeyboardKey.space,
        ]) {
          await tester.sendKeyEvent(key);
        }
        await tester.pumpAndSettle();
        expect(_linkPainter(tester), same(painter));
        expect(
          tester.widget<TextField>(field).controller!.value.composing,
          const TextRange(start: 0, end: 5),
        );
        expect(session.operations, hasLength(operations));
      }
      await tester.tap(find.byKey(const Key('biography-close')));
      await tester.pumpAndSettle();
      final focus = tester
          .widget<Focus>(find.byKey(const Key('tree-keyboard-focus')))
          .focusNode!;
      final context = tester.element(find.byType(TreeEditor));
      showDialog<void>(
        context: context,
        builder: (context) => const AlertDialog(
          title: Text('Открытая форма'),
          content: TextField(autofocus: true),
        ),
      );
      await tester.pumpAndSettle();
      final painter = _linkPainter(tester);
      for (final key in [
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.digit2,
      ]) {
        await tester.sendKeyEvent(key);
      }
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(
        _linkPainter(tester),
        same(painter),
        reason:
            'A covered editor is inactive even if its old focus is restored.',
      );
      expect(find.byTooltip('Линия дерева: Обе линии'), findsOneWidget);
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'keyboard Space leaves focused button activation native and outside focus is inert',
    (tester) async {
      final fixture = _family();
      final session = _Session(fixture.document);
      await _mount(tester, session);
      final toggle = find.byKey(const Key('tree-toolbar-toggle'));
      final buttonFocus = Focus.of(
        tester.element(
          find.descendant(of: toggle, matching: find.byType(Icon)).first,
        ),
      );
      buttonFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('tree-toolbar')),
        findsNothing,
        reason: 'Space activates the focused toggle instead of Align All.',
      );
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final context = tester.element(find.byType(TreeEditor));
      final overlay = OverlayEntry(
        builder: (context) =>
            Focus(focusNode: focus, child: const SizedBox.shrink()),
      );
      Overlay.of(context).insert(overlay);
      await tester.pump();
      focus.requestFocus();
      await tester.pump();
      final painter = _linkPainter(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(_linkPainter(tester), same(painter));
      overlay.remove();
      overlay.dispose();
      expect(session.operations, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final portrait in [true, false]) {
    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} Oleg Shrek first paint keeps the clicked card and reordered row steady',
      (tester) async {
        for (final fullSiblings in [false, true]) {
          for (final zoom in [100, 150]) {
            await tester.pumpWidget(const SizedBox.shrink());
            final fixture = _selectionPermutationFamily();
            if (fullSiblings) fixture.parents('shrek', mother: 'oleg-mother');
            final session = _Session(fixture.document, editingAllowed: true);
            final peopleBefore = fixture.document.people;
            await _mount(
              tester,
              session,
              initialPersonId: 'oleg',
              reduceMotion: false,
              size: portrait ? const Size(1700, 2400) : const Size(2400, 1700),
            );
            if (zoom == 150) await _zoomSteps(tester, 5);
            var previous = _layoutOf(fixture, selectedId: 'oleg');
            var reordered = false;
            for (final selected in ['shrek', 'oleg', 'shrek', 'oleg']) {
              final layout = _layoutOf(fixture, selectedId: selected);
              final level = layout.levels.singleWhere(
                (level) => level.index == layout.positions[selected]!.level,
              );
              final oldLevel = previous.levels.singleWhere(
                (old) => old.index == level.index,
              );
              reordered |=
                  oldLevel.blocks.map((block) => block.id).join('|') !=
                  level.blocks.map((block) => block.id).join('|');
              final target = tester.getRect(_person(selected));
              _expectInside(
                target,
                tester.getRect(find.byKey(const Key('tree-canvas'))),
              );
              await _expectSteadySelectionPaints(
                tester,
                select: () => tester.tap(_person(selected)),
                targets: {
                  for (final block in level.blocks) ...{
                    'block-${block.id}': find.byKey(
                      ValueKey('tree-block-${block.id}'),
                    ),
                    for (final person in block.people)
                      person.id: _person(person.id),
                  },
                },
                pinned: {selected: target},
                reason: '$zoom%, full=$fullSiblings, selected=$selected',
              );
              _expectCanonicalRowGeometry(tester, layout, portrait: portrait);
              previous = layout;
            }
            expect(
              reordered,
              isTrue,
              reason:
                  'First-paint protection must exercise actual whole-block permutation.',
            );
            expect(session.operations, isEmpty);
            expect(identical(fixture.document.people, peopleBefore), isTrue);
          }
        }
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} visible Oleg Shrek selections pin the clicked card while its canonical row reorders',
      (tester) async {
        for (final fullSiblings in [false, true]) {
          for (final dated in [false, true]) {
            await tester.pumpWidget(const SizedBox.shrink());
            final fixture = _selectionPermutationFamily();
            if (fullSiblings) fixture.parents('shrek', mother: 'oleg-mother');
            if (dated) {
              fixture.apply(
                fixture.document.setValue('oleg', 'birthDate', '1980-01-01'),
              );
              fixture.apply(
                fixture.document.setValue('shrek', 'birthDate', '1970-01-01'),
              );
            }
            final session = _Session(fixture.document, editingAllowed: true);
            final people = fixture.document.people;
            await _mount(
              tester,
              session,
              initialPersonId: 'oleg',
              // The extra real co-parent widens this intentionally visible-card
              // fixture; leave room for both dated orders even at 150%. Keep
              // viewport dimensions on that zoom's exact logical-pixel grid.
              size: portrait ? const Size(2700, 3900) : const Size(3900, 2700),
            );
            var previous = _layoutOf(fixture, selectedId: 'oleg');
            var reordered = false;
            for (final zoom in [100, 150]) {
              if (zoom == 150) await _zoomSteps(tester, 5);
              for (final selected in ['shrek', 'oleg', 'shrek', 'oleg']) {
                final canvas = tester.getRect(
                  find.byKey(const Key('tree-canvas')),
                );
                final target = tester.getRect(_person(selected));
                _expectInside(target, canvas);
                final before = {
                  for (final id in people.keys) id: tester.getRect(_person(id)),
                };
                await tester.tap(_person(selected));
                await tester.pumpAndSettle();
                final current = _layoutOf(fixture, selectedId: selected);
                final row = current.positions[selected]!.level;
                final oldRow = previous.levels
                    .singleWhere((level) => level.index == row)
                    .blocks
                    .expand((block) => block.people)
                    .map((person) => person.id)
                    .toList();
                final newRow = current.levels
                    .singleWhere((level) => level.index == row)
                    .blocks
                    .expand((block) => block.people)
                    .map((person) => person.id)
                    .toList();
                reordered |= oldRow.join('|') != newRow.join('|');
                final reason =
                    '$zoom%, full=$fullSiblings, dated=$dated, $selected';
                expect(
                  (tester.getRect(_person(selected)).topLeft - target.topLeft)
                      .distance,
                  lessThan(.2),
                  reason:
                      '$reason: selecting a fully visible card must not move that card, even when its model slot changes.',
                );
                _expectCanonicalRowGeometry(
                  tester,
                  current,
                  portrait: portrait,
                );
                _expectPreservedOrCanonicalRows(
                  tester,
                  beforeLayout: previous,
                  afterLayout: current,
                  before: before,
                  portrait: portrait,
                  reason: reason,
                );
                expect(
                  {
                    for (final entry in current.positions.entries)
                      entry.key: entry.value.level,
                  },
                  {
                    for (final entry in previous.positions.entries)
                      entry.key: entry.value.level,
                  },
                );
                expect(
                  _nodeSemantics(
                    tester,
                    people[selected]!.displayName,
                  ).flagsCollection.isSelected,
                  Tristate.isTrue,
                );
                previous = current;
              }
              final controller = _levelController(
                tester,
                previous.positions['oleg']!.level,
              );
              controller.jumpTo(
                (controller.offset + 25).clamp(
                  controller.position.minScrollExtent,
                  controller.position.maxScrollExtent,
                ),
              );
              await tester.pump();
            }
            expect(
              reordered,
              isTrue,
              reason:
                  'The regression must exercise a genuine whole-block or sibling permutation.',
            );
            expect(session.operations, isEmpty);
            expect(identical(fixture.document.people, people), isTrue);
            expect(tester.takeException(), isNull);
          }
        }
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} visible selected-card anchors survive scroll bounds and coalesced selections',
      (tester) async {
        for (final zoom in [100, 150]) {
          for (final atLeading in [true, false]) {
            await tester.pumpWidget(const SizedBox.shrink());
            final fixture = _selectionPermutationFamily(
              reverseCoParentRoles: !atLeading,
            );
            final session = _Session(fixture.document, editingAllowed: true);
            final initialId = atLeading ? 'shrek' : 'oleg';
            final targetId = atLeading ? 'oleg' : 'shrek';
            await _mount(
              tester,
              session,
              initialPersonId: initialId,
              reduceMotion: false,
              size: portrait ? const Size(2800, 4000) : const Size(4000, 2800),
            );
            if (zoom == 150) await _zoomSteps(tester, 5);
            final initial = _layoutOf(fixture, selectedId: initialId);
            final row = _levelController(
              tester,
              initial.positions['oleg']!.level,
            );
            row.jumpTo(
              atLeading
                  ? row.position.minScrollExtent
                  : row.position.maxScrollExtent,
            );
            await tester.pump();
            final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
            final target = tester.getRect(_person(targetId));
            _expectInside(target, canvas);
            final maxBefore = row.position.maxScrollExtent;
            final selectedLayout = _layoutOf(fixture, selectedId: targetId);
            final selectedLevel = selectedLayout.levels.singleWhere(
              (level) =>
                  level.index == selectedLayout.positions[targetId]!.level,
            );
            await _expectSteadySelectionPaints(
              tester,
              select: () => tester.tap(_person(targetId)),
              targets: {
                for (final block in selectedLevel.blocks) ...{
                  'block-${block.id}': find.byKey(
                    ValueKey('tree-block-${block.id}'),
                  ),
                  for (final person in block.people)
                    person.id: _person(person.id),
                },
              },
              pinned: {targetId: target},
              reason: '$zoom%, leading=$atLeading, selected=$targetId',
            );
            expect(
              (tester.getRect(_person(targetId)).topLeft - target.topLeft)
                  .distance,
              lessThan(.2),
              reason:
                  '$zoom%, leading=$atLeading: bounds cannot move a fully visible target.',
            );
            expect(
              row.position.maxScrollExtent,
              greaterThan(maxBefore + 100),
              reason:
                  'The test must require presentation padding, not pass only through clamped in-range offsets.',
            );
            await _selectPerson(tester, 'shrek');
            // Give the rapid second selection comfortable visibility in its
            // intermediate canonical row; the bound case above is independent.
            final currentLayout = _layoutOf(fixture, selectedId: 'shrek');
            final bounds = currentLayout.levels
                .singleWhere(
                  (level) =>
                      level.index == currentLayout.positions['oleg']!.level,
                )
                .blocks
                .expand((block) => block.people)
                .map((person) => tester.getRect(_person(person.id)))
                .reduce((a, b) => a.expandToInclude(b));
            row.jumpTo(
              (row.offset +
                      _cross(bounds.center - canvas.center, portrait) /
                          (zoom / 100))
                  .clamp(
                    row.position.minScrollExtent,
                    row.position.maxScrollExtent,
                  ),
            );
            await tester.pump();
            final olegTarget = tester.getRect(_person('oleg'));
            _expectInside(olegTarget, canvas);
            final beforeLayout = _layoutOf(fixture, selectedId: 'shrek');
            final intermediate = _layoutOf(fixture, selectedId: 'oleg');
            final finalLayout = _layoutOf(fixture, selectedId: 'roman');
            final beforeRoman = tester.getRect(_person('roman'));
            final expectedRoman = beforeRoman.shift(
              portrait
                  ? Offset(
                      0,
                      -((intermediate.positions['oleg']!.crossCenter -
                                  beforeLayout.positions['oleg']!.crossCenter) -
                              (intermediate.positions['roman']!.crossCenter -
                                  beforeLayout
                                      .positions['roman']!
                                      .crossCenter)) *
                          zoom /
                          100,
                    )
                  : Offset(
                      -((intermediate.positions['oleg']!.crossCenter -
                                  beforeLayout.positions['oleg']!.crossCenter) -
                              (intermediate.positions['roman']!.crossCenter -
                                  beforeLayout
                                      .positions['roman']!
                                      .crossCenter)) *
                          zoom /
                          100,
                      0,
                    ),
            );
            _expectInside(expectedRoman, canvas);
            final finalLevel = finalLayout.levels.singleWhere(
              (level) => level.index == finalLayout.positions['roman']!.level,
            );
            await _expectSteadySelectionPaints(
              tester,
              select: () async {
                for (final id in ['oleg', 'roman']) {
                  tester
                      .widget<InkWell>(
                        find.descendant(
                          of: _person(id),
                          matching: find.byType(InkWell),
                        ),
                      )
                      .onTap!();
                }
              },
              targets: {
                for (final block in finalLevel.blocks) ...{
                  'block-${block.id}': find.byKey(
                    ValueKey('tree-block-${block.id}'),
                  ),
                  for (final person in block.people)
                    person.id: _person(person.id),
                },
              },
              pinned: {'roman': expectedRoman},
              reason: '$zoom%, leading=$atLeading, rapid Oleg Roman',
            );
            expect(
              (tester.getRect(_person('roman')).topLeft - expectedRoman.topLeft)
                  .distance,
              lessThan(.2),
              reason:
                  'A second callback before layout must compose the first selected-card anchor.',
            );
            _expectCanonicalRowGeometry(
              tester,
              finalLayout,
              portrait: portrait,
            );
            expect(session.operations, isEmpty);
            expect(tester.takeException(), isNull);
          }
        }
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} a clipped Roman centers after Nekto partner reordering makes him visible',
      (tester) async {
        for (final zoom in [100, 150]) {
          for (final mode in [
            TreeTrunkMode.both,
            TreeTrunkMode.father,
            TreeTrunkMode.mother,
          ]) {
            await tester.pumpWidget(const SizedBox.shrink());
            final fixture = _parentRowDriftFamily();
            for (var i = 0; i < 12; i++) {
              fixture.add('unrelated-root-$i');
            }
            final people = fixture.document.people;
            final session = _Session(fixture.document);
            await _mount(
              tester,
              session,
              initialPersonId: 'nekto',
              size: portrait ? const Size(850, 1100) : const Size(1100, 850),
              reduceMotion: false,
            );
            await _chooseMode(tester, mode);
            if (zoom == 150) await _zoomSteps(tester, 5);
            await tester.tap(find.byKey(const Key('tree-align-all')));
            await tester.pumpAndSettle();
            final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
            final target = _person('roman');
            final beforeLayout = _layoutOf(
              fixture,
              selectedId: 'nekto',
              mode: mode,
            );
            final afterLayout = _layoutOf(
              fixture,
              selectedId: 'roman',
              mode: mode,
            );
            final row = _levelController(
              tester,
              beforeLayout.positions['roman']!.level,
            );
            final targetRect = tester.getRect(target);
            final extent = portrait ? targetRect.height : targetRect.width;
            final desiredCenter =
                _cross(canvas.bottomRight, portrait) - extent / 2 + 20;
            final requested =
                row.offset +
                (_cross(tester.getCenter(target), portrait) - desiredCenter) /
                    (zoom / 100);
            expect(
              requested,
              inInclusiveRange(
                row.position.minScrollExtent,
                row.position.maxScrollExtent,
              ),
            );
            row.jumpTo(requested);
            await tester.pump();
            final clipped = tester.getRect(target);
            expect(
              _cross(clipped.bottomRight - canvas.bottomRight, portrait),
              closeTo(20, .2),
              reason:
                  'The card must actually be clipped before the pointer selection.',
            );
            final rowShift =
                beforeLayout.levels
                    .singleWhere(
                      (level) =>
                          level.index == beforeLayout.positions['roman']!.level,
                    )
                    .blocks
                    .first
                    .start -
                afterLayout.levels
                    .singleWhere(
                      (level) =>
                          level.index == afterLayout.positions['roman']!.level,
                    )
                    .blocks
                    .first
                    .start;
            final movedCenter =
                _cross(clipped.center, portrait) +
                (afterLayout.positions['roman']!.crossCenter -
                        beforeLayout.positions['roman']!.crossCenter +
                        rowShift) *
                    zoom /
                    100;
            expect(
              movedCenter + extent / 2,
              lessThan(_cross(canvas.bottomRight, portrait)),
              reason:
                  'Reordering alone must reveal the card, exposing the lost centering request.',
            );
            final unrelated = _person('test-parent');
            final unrelatedRow = _levelController(
              tester,
              beforeLayout.positions['test-parent']!.level,
            );
            final unrelatedOffset = unrelatedRow.offset;
            final unrelatedDelta =
                unrelatedRow.position.maxScrollExtent - unrelatedOffset >= 35
                ? 35.0
                : -35.0;
            unrelatedRow.jumpTo(unrelatedOffset + unrelatedDelta);
            await tester.pump();
            expect(
              (unrelatedRow.offset - unrelatedOffset).abs(),
              greaterThan(10),
            );
            final unrelatedCross = _cross(
              tester.getCenter(unrelated),
              portrait,
            );
            final visiblePart = clipped.intersect(canvas);
            expect(visiblePart.isEmpty, isFalse);
            await tester.tapAt(visiblePart.center);
            await tester.pumpAndSettle();
            expect(
              _nodeSemantics(tester, 'Роман').flagsCollection.isSelected,
              Tristate.isTrue,
            );
            expect(
              _cross(tester.getCenter(target), portrait),
              closeTo(_cross(canvas.center, portrait), .2),
              reason:
                  '$zoom%, ${mode.name}: a pre-click clipped card must center, not just become visible.',
            );
            _expectInside(tester.getRect(target), canvas);
            expect(
              _cross(tester.getCenter(unrelated), portrait),
              closeTo(unrelatedCross, .2),
              reason:
                  'Centering the selected card must not behave like Align All.',
            );
            _expectCanonicalRowGeometry(
              tester,
              afterLayout,
              portrait: portrait,
            );
            expect(identical(fixture.document.people, people), isTrue);
            expect(session.operations, isEmpty);
            expect(tester.takeException(), isNull);
          }
        }
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} coalesced selections keep only the latest clipped or visible intent',
      (tester) async {
        for (final clippedLast in [false, true]) {
          await tester.pumpWidget(const SizedBox.shrink());
          final fixture = _family(siblings: 12, children: 2);
          final session = _Session(fixture.document);
          await _mount(
            tester,
            session,
            size: portrait ? const Size(900, 1400) : const Size(1400, 900),
            reduceMotion: false,
          );
          final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
          final clipped = _person('Сестра-0');
          final visible = _person('Сестра-1');
          final row = _levelController(tester, _levelOf(fixture, 'Сестра-0'));
          row.jumpTo(
            row.offset +
                _cross(
                  tester.getRect(clipped).topLeft - canvas.topLeft,
                  portrait,
                ) +
                20,
          );
          await tester.pump();
          expect(
            _cross(tester.getRect(clipped).topLeft - canvas.topLeft, portrait),
            closeTo(-20, .2),
          );
          final visibleRect = tester.getRect(visible);
          _expectInside(visibleRect, canvas);
          void selectBoth() {
            for (final id
                in clippedLast
                    ? ['Сестра-1', 'Сестра-0']
                    : ['Сестра-0', 'Сестра-1']) {
              tester
                  .widget<InkWell>(
                    find.descendant(
                      of: _person(id),
                      matching: find.byType(InkWell),
                    ),
                  )
                  .onTap!();
            }
          }

          if (clippedLast) {
            selectBoth();
            await tester.pumpAndSettle();
            expect(
              _cross(tester.getCenter(clipped), portrait),
              closeTo(_cross(canvas.center, portrait), .2),
            );
          } else {
            await _expectSteadySelectionPaints(
              tester,
              select: () async => selectBoth(),
              targets: {'visible': visible},
              pinned: {'visible': visibleRect},
              reason:
                  'A superseded clipped target must not center the latest visible selection.',
            );
          }
          expect(session.operations, isEmpty);
          expect(tester.takeException(), isNull);
        }
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} partially clipped selections still auto-align on either viewport axis',
      (tester) async {
        for (final clipCross in [true, false]) {
          await tester.pumpWidget(const SizedBox.shrink());
          final fixture = _family(siblings: 12, children: 4);
          var parent = 'Ребёнок-0';
          for (var depth = 0; depth < 4; depth++) {
            final child = 'lower-$depth';
            fixture
              ..add(child)
              ..parents(child, father: parent);
            parent = child;
          }
          final session = _Session(fixture.document);
          await _mount(
            tester,
            session,
            size: portrait ? const Size(430, 900) : const Size(1100, 450),
          );
          final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
          final target = _person('Сестра-0');
          final row = _levelController(tester, _levelOf(fixture, 'Сестра-0'));
          final main = _mainController(tester);
          if (clipCross) {
            row.jumpTo(
              (row.offset +
                      _cross(
                        tester.getCenter(target) - canvas.topLeft,
                        portrait,
                      ) -
                      20)
                  .clamp(
                    row.position.minScrollExtent,
                    row.position.maxScrollExtent,
                  ),
            );
          } else {
            final delta = portrait
                ? tester.getCenter(target).dx - canvas.left - 20
                : tester.getCenter(target).dy - canvas.top - 20;
            main.jumpTo(
              (main.offset + delta).clamp(
                main.position.minScrollExtent,
                main.position.maxScrollExtent,
              ),
            );
          }
          await tester.pump();
          final clipped = tester.getRect(target);
          expect(
            clipCross
                ? _cross(clipped.topLeft - canvas.topLeft, portrait)
                : portrait
                ? clipped.left - canvas.left
                : clipped.top - canvas.top,
            lessThan(0),
          );
          await _selectPerson(tester, 'Сестра-0');
          _expectInside(tester.getRect(target), canvas);
          expect(
            (tester.getRect(target).topLeft - clipped.topLeft).distance,
            greaterThan(1),
          );
          expect(session.operations, isEmpty);
          expect(tester.takeException(), isNull);
        }
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} screenshot27 direct and Anastasia-mediated Olga selections share the same cold parent-row viewport',
      (tester) async {
        for (final zoom in [100, 150]) {
          Map<String, Rect>? expectedFinal;
          Map<String, Rect>? expectedCold;
          Map<int, double>? expectedFinalScroll;
          Map<int, double>? expectedColdScroll;
          for (final viaAnastasia in [false, true]) {
            await tester.pumpWidget(const SizedBox.shrink());
            final fixture = _parentRowDriftFamily();
            for (final (id, date) in const [
              ('prikol', '1960-01-01'),
              ('natalia', '1970-01-01'),
              ('veronika', '1980-01-01'),
            ]) {
              fixture.apply(fixture.document.setValue(id, 'birthDate', date));
            }
            final session = _Session(fixture.document, editingAllowed: true);
            final people = fixture.document.people;
            await _mount(
              tester,
              session,
              initialPersonId: 'nikita',
              size: portrait ? const Size(1700, 2400) : const Size(2400, 1700),
            );
            if (zoom == 150) await _zoomSteps(tester, 5);
            final initial = _layoutOf(fixture, selectedId: 'nikita');
            final parentLevel = initial.positions['natalia']!.level;
            final parentIds = initial.levels
                .singleWhere((level) => level.index == parentLevel)
                .blocks
                .expand((block) => block.people)
                .map((person) => person.id)
                .toList();
            final comparedIds = [
              ...parentIds,
              'anastasia',
              rootTreePersonId,
              'nikita',
            ];
            Map<String, Rect> cards() => {
              for (final id in comparedIds) id: tester.getRect(_person(id)),
            };
            Map<int, double> rowOffsets() => {
              for (final level in initial.levels)
                level.index: _levelController(tester, level.index).offset,
            };
            final cold = cards();
            final coldScroll = rowOffsets();
            if (expectedCold == null) {
              expectedCold = cold;
              expectedColdScroll = coldScroll;
            } else {
              expect(
                cold,
                expectedCold,
                reason:
                    'Both routes start from the same cold Nikita view, without Align All.',
              );
              expect(coldScroll, expectedColdScroll);
            }
            final siblingBlock = find.byKey(
              ValueKey('tree-block-${initial.positions['natalia']!.blockId}'),
            );
            final blockStart = _cross(
              tester.getRect(siblingBlock).topLeft,
              portrait,
            );
            final parentScroll = _levelController(tester, parentLevel).offset;
            final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
            for (final selected in [
              ...(viaAnastasia ? ['anastasia'] : <String>[]),
              rootTreePersonId,
            ]) {
              await _selectPerson(tester, selected);
              final layout = _layoutOf(fixture, selectedId: selected);
              final reason =
                  '$zoom%, viaAnastasia=$viaAnastasia, selected=$selected';
              expect(
                _cross(tester.getRect(siblingBlock).topLeft, portrait),
                closeTo(blockStart, .2),
                reason: reason,
              );
              expect(
                _levelController(tester, parentLevel).offset,
                closeTo(parentScroll, .2),
                reason: reason,
              );
              final person = people[selected]!;
              final mother = tester.getRect(_person(person.motherId!));
              final father = tester.getRect(_person(person.fatherId!));
              expect(
                portrait
                    ? father.top - mother.bottom
                    : father.left - mother.right,
                closeTo(2 * layout.gap * zoom / 100, .2),
                reason: reason,
              );
              for (final id in parentIds) {
                _expectInside(tester.getRect(_person(id)), canvas);
              }
              _expectCanonicalRowGeometry(tester, layout, portrait: portrait);
            }
            final result = cards();
            final scrolls = rowOffsets();
            if (expectedFinal == null) {
              expectedFinal = result;
              expectedFinalScroll = scrolls;
            } else {
              for (final id in comparedIds) {
                expect(
                  (result[id]!.topLeft - expectedFinal[id]!.topLeft).distance,
                  lessThan(.2),
                  reason:
                      '$zoom%, $id: direct and via-Anastasia paths must have the same actual final Olga viewport.',
                );
              }
              for (final level in scrolls.keys) {
                expect(
                  scrolls[level],
                  closeTo(expectedFinalScroll![level]!, .2),
                );
              }
            }
            expect(session.operations, isEmpty);
            expect(identical(fixture.document.people, people), isTrue);
            expect(tester.takeException(), isNull);
          }
        }
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} screenshot25 parent row keeps its viewport across Nikita Olga roundtrips at 100 and 150 percent',
      (tester) async {
        for (final zoom in [100, 150]) {
          await tester.pumpWidget(const SizedBox.shrink());
          final fixture = _parentRowDriftFamily();
          for (final (id, date) in const [
            ('prikol', '1960-01-01'),
            ('natalia', '1970-01-01'),
            ('veronika', '1980-01-01'),
          ]) {
            fixture.apply(fixture.document.setValue(id, 'birthDate', date));
          }
          final session = _Session(fixture.document, editingAllowed: true);
          final people = fixture.document.people;
          final initial = _layoutOf(fixture, selectedId: 'nikita');
          final ranks = {
            for (final entry in initial.positions.entries)
              entry.key: entry.value.level,
          };
          final actualEdges = {
            for (final link in initial.links) (link.parentId, link.childId),
          };
          await _mount(
            tester,
            session,
            initialPersonId: 'nikita',
            size: portrait ? const Size(1700, 2400) : const Size(2400, 1700),
          );
          if (zoom == 150) await _zoomSteps(tester, 5);
          final scale = zoom / 100;
          final levelIndex = initial.positions['natalia']!.level;
          final row = _levelController(tester, levelIndex);
          final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
          final ids = initial.levels
              .singleWhere((level) => level.index == levelIndex)
              .blocks
              .expand((block) => block.people)
              .map((person) => person.id)
              .toList();
          Rect rowBounds() => ids
              .map((id) => tester.getRect(_person(id)))
              .reduce((a, b) => a.expandToInclude(b));
          final centerDelta =
              _cross(rowBounds().center - canvas.center, portrait) / scale;
          row.jumpTo(
            (row.offset + centerDelta).clamp(
              row.position.minScrollExtent,
              row.position.maxScrollExtent,
            ),
          );
          await tester.pump();
          expect(row.offset - row.position.minScrollExtent, greaterThan(80));
          expect(row.position.maxScrollExtent - row.offset, greaterThan(80));
          final siblingBlock = find.byKey(
            ValueKey('tree-block-${initial.positions['natalia']!.blockId}'),
          );
          final main = _mainController(tester);
          final mainBefore = main.offset;
          final unaffectedLevel = initial.positions['test']!.level;
          final unaffectedRow = _levelController(tester, unaffectedLevel);
          unaffectedRow.jumpTo(
            (unaffectedRow.offset + 25).clamp(
              unaffectedRow.position.minScrollExtent,
              unaffectedRow.position.maxScrollExtent,
            ),
          );
          await tester.pump();
          final unaffectedOffset = unaffectedRow.offset;
          for (final panned in [false, true]) {
            if (panned) {
              row.jumpTo(row.offset + 40);
              await tester.pump();
            }
            final blockBefore = tester.getRect(siblingBlock);
            final prikolBefore = tester.getRect(_person('prikol'));
            final scrollBefore = row.offset;
            for (final selected in [
              rootTreePersonId,
              'nikita',
              rootTreePersonId,
              'nikita',
            ]) {
              for (final id in ids) {
                _expectInside(tester.getRect(_person(id)), canvas);
              }
              await _selectPerson(tester, selected);
              final layout = _layoutOf(fixture, selectedId: selected);
              final reason = '$zoom%, independentPan=$panned, $selected';
              expect(
                _cross(
                  tester.getRect(siblingBlock).topLeft - blockBefore.topLeft,
                  portrait,
                ),
                closeTo(0, .2),
                reason:
                    '$reason: required internal sibling/father permutations cannot translate the whole unchanged parent row.',
              );
              expect(
                (tester.getRect(_person('prikol')).topLeft -
                        prikolBefore.topLeft)
                    .distance,
                lessThan(.2),
                reason: reason,
              );
              expect(row.offset, closeTo(scrollBefore, .2), reason: reason);
              expect(main.offset, closeTo(mainBefore, .2), reason: reason);
              expect(
                unaffectedRow.offset,
                closeTo(unaffectedOffset, .2),
                reason: reason,
              );
              _expectCanonicalRowGeometry(tester, layout, portrait: portrait);
              expect({
                for (final entry in layout.positions.entries)
                  entry.key: entry.value.level,
              }, ranks);
              expect({
                for (final link in layout.links) (link.parentId, link.childId),
              }, actualEdges);
              final selectedPerson = people[selected]!;
              final mother = tester.getRect(_person(selectedPerson.motherId!));
              final father = tester.getRect(_person(selectedPerson.fatherId!));
              expect(
                portrait
                    ? father.top - mother.bottom
                    : father.left - mother.right,
                closeTo(2 * layout.gap * scale, .2),
                reason: '$reason: actual parent seam must still reorder.',
              );
              expect(
                _nodeSemantics(
                  tester,
                  selectedPerson.displayName,
                ).flagsCollection.isSelected,
                Tristate.isTrue,
              );
              for (final id in ids) {
                _expectInside(tester.getRect(_person(id)), canvas);
              }
            }
            // Coalesced callbacks must compose pending compensation too.
            for (final selected in [rootTreePersonId, 'nikita']) {
              tester
                  .widget<InkWell>(
                    find.descendant(
                      of: _person(selected),
                      matching: find.byType(InkWell),
                    ),
                  )
                  .onTap!();
            }
            await tester.pumpAndSettle();
            expect(
              _cross(
                tester.getRect(siblingBlock).topLeft - blockBefore.topLeft,
                portrait,
              ),
              closeTo(0, .2),
            );
            expect(row.offset, closeTo(scrollBefore, .2));
          }
          expect(session.operations, isEmpty);
          expect(identical(fixture.document.people, people), isTrue);
          expect(tester.takeException(), isNull);
        }
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} one-sided ancestor rows compensate their actual content translation outside virtual zero',
      (tester) async {
        final fixture = _parentRowDriftFamily();
        final session = _Session(fixture.document);
        final people = fixture.document.people;
        await _mount(
          tester,
          session,
          initialPersonId: 'nikita',
          size: portrait ? const Size(1700, 2400) : const Size(2400, 1700),
        );
        final initial = _layoutOf(fixture, selectedId: 'nikita');
        final levelIndex = initial.positions['test']!.level;
        final original = initial.levels.singleWhere(
          (level) => level.index == levelIndex,
        );
        expect(original.blocks, hasLength(1));
        expect(
          original.blocks.single.start + original.blocks.single.extent,
          lessThan(0),
        );
        final before = tester.getRect(_person('test'));
        final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
        _expectInside(before, canvas);
        final row = _levelController(tester, levelIndex);
        final originalStart = original.blocks.single.start;
        for (final selected in ['lydia', 'nikita', 'lydia', 'nikita']) {
          await _selectPerson(tester, selected);
          final layout = _layoutOf(fixture, selectedId: selected);
          final next = layout.levels.singleWhere(
            (level) => level.index == levelIndex,
          );
          final delta = next.blocks.single.start - originalStart;
          expect(
            row.offset,
            greaterThanOrEqualTo(row.position.minScrollExtent),
          );
          expect(row.offset, lessThanOrEqualTo(row.position.maxScrollExtent));
          // Selecting visible Lydia can extend shared presentation padding to
          // keep her own row pinned. Native offsets may include that padding;
          // the actual Test card below must still retain its screen position.
          expect(
            _cross(
              tester.getRect(_person('test')).topLeft - before.topLeft,
              portrait,
            ),
            closeTo(0, .2),
          );
          if (selected == 'lydia') {
            expect(next.blocks.single.start, greaterThan(0));
            expect(
              delta,
              isNot(
                closeTo(
                  ((next.minCross + next.maxCross) -
                          (original.minCross + original.maxCross)) /
                      2,
                  .2,
                ),
              ),
              reason:
                  'Virtual zero makes the min/max midpoint an incorrect content translation.',
            );
          }
          _expectCanonicalRowGeometry(tester, layout, portrait: portrait);
        }
        expect(session.operations, isEmpty);
        expect(identical(fixture.document.people, people), isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} shared-parent child cohorts remain whole across the screenshot24 selection route in every mode at 100 and 150 percent',
      (tester) async {
        final fixture = _ancestorCorridorFamily();
        for (final (id, date) in const [
          ('natalia', '1970-01-01'),
          ('veronika', '1980-01-01'),
        ]) {
          fixture.apply(fixture.document.setValue(id, 'birthDate', date));
        }
        final session = _Session(fixture.document, editingAllowed: true);
        final people = fixture.document.people;
        final initial = _layoutOf(fixture);
        final ranks = {
          for (final entry in initial.positions.entries)
            entry.key: entry.value.level,
        };
        final actualEdges = {
          for (final link in initial.links) (link.parentId, link.childId),
        };
        final renderedBySelection =
            <(String, TreeTrunkMode), Set<(String, String)>>{};
        await _mount(
          tester,
          session,
          initialPersonId: 'natalia',
          size: portrait ? const Size(1700, 2400) : const Size(2400, 1700),
        );
        for (final zoom in [100, 150]) {
          if (zoom == 150) await _zoomSteps(tester, 5);
          for (final mode in TreeTrunkMode.values) {
            await _chooseMode(tester, mode);
            for (final selected in [
              'natalia',
              'nikita',
              'roman',
              'veronika',
              rootTreePersonId,
              'anastasia',
              'nikita',
            ]) {
              await _selectPerson(tester, selected);
              final layout = _layoutOf(
                fixture,
                selectedId: selected,
                mode: mode,
              );
              final reason = '$zoom%, ${mode.name}, $selected';
              final olga = layout.positions[rootTreePersonId]!;
              final anastasia = layout.positions['anastasia']!;
              expect(olga.blockId, isNot(anastasia.blockId));
              expect(anastasia.level, olga.level, reason: reason);
              final blocks = layout.levels
                  .singleWhere((level) => level.index == olga.level)
                  .blocks;
              final olgaSlot = blocks.indexWhere(
                (block) => block.id == olga.blockId,
              );
              final anastasiaSlot = blocks.indexWhere(
                (block) => block.id == anastasia.blockId,
              );
              expect(
                (olgaSlot - anastasiaSlot).abs(),
                1,
                reason:
                    '$reason: Natalia’s separate full-sibling child blocks must share adjacent whole slots, never surround Nikita.',
              );
              for (final level in layout.levels) {
                for (final block in level.blocks) {
                  final original = initial.levels
                      .expand((level) => level.blocks)
                      .singleWhere((original) => original.id == block.id);
                  expect(
                    block.people.map((person) => person.id),
                    unorderedEquals(original.people.map((person) => person.id)),
                    reason: '$reason: no full-sibling block splits.',
                  );
                  if (mode != TreeTrunkMode.both) {
                    final canonical = block.people.toList()
                      ..sort(compareTreePeopleByBirth);
                    expect(
                      block.people.map((person) => person.id),
                      canonical.map((person) => person.id),
                      reason:
                          '$reason: single modes keep strict sibling chronology.',
                    );
                  }
                }
              }
              expect(
                {
                  for (final entry in layout.positions.entries)
                    entry.key: entry.value.level,
                },
                ranks,
                reason: reason,
              );
              expect(
                {
                  for (final link in layout.links)
                    (link.parentId, link.childId),
                },
                actualEdges,
                reason:
                    '$reason: grouping cannot remove or invent parent links.',
              );
              expect(
                _nodeSemantics(
                  tester,
                  people[selected]!.displayName,
                ).flagsCollection.isSelected,
                Tristate.isTrue,
              );
              expect(
                tester.getRect(_person(selected)).width,
                closeTo(108 * zoom / 100, .1),
              );
              _expectCanonicalRowGeometry(tester, layout, portrait: portrait);
              final rendered = _renderedConnections(
                tester,
                layout,
                portrait: portrait,
              );
              final key = (selected, mode);
              if (renderedBySelection.containsKey(key)) {
                expect(
                  rendered,
                  renderedBySelection[key],
                  reason:
                      '$reason: repeated selection and zoom keep actual painted edge identities.',
                );
              } else {
                renderedBySelection[key] = rendered;
              }
              if (mode == TreeTrunkMode.both &&
                  [
                    'nikita',
                    rootTreePersonId,
                    'anastasia',
                  ].contains(selected)) {
                final person = people[selected]!;
                final mother = tester.getRect(_person(person.motherId!));
                final father = tester.getRect(_person(person.fatherId!));
                expect(
                  portrait
                      ? father.top - mother.bottom
                      : father.left - mother.right,
                  closeTo(2 * layout.gap * zoom / 100, .2),
                  reason:
                      '$reason: the compatible actual parent seam remains intact.',
                );
              }
              expect(session.operations, isEmpty);
              expect(identical(fixture.document.people, people), isTrue);
              expect(tester.takeException(), isNull);
            }
          }
        }
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} Natalia and Roman context links follow the actual blood-related parent in every mode',
      (tester) async {
        final fixture = _ancestorCorridorFamily()
          ..add('roman-nephew-outsider')
          ..add('roman-nephew')
          ..parents(
            'roman-nephew',
            father: 'roman-nephew-outsider',
            mother: 'roman-half-sibling',
          );
        for (final id in ['veronika', 'roman-half-sibling']) {
          fixture.apply(
            fixture.document.setValue(id, 'birthDate', '1970-01-01'),
          );
        }
        final ranks = {
          for (final entry in _layoutOf(fixture).positions.entries)
            entry.key: entry.value.level,
        };
        final peopleBefore = fixture.document.people;
        final session = _Session(fixture.document, editingAllowed: true);
        await _mount(
          tester,
          session,
          size: portrait ? const Size(700, 1200) : const Size(1200, 750),
          initialPersonId: 'natalia',
        );
        final sessions = [session];
        final coldConnections =
            <(String, TreeTrunkMode), Set<(String, String)>>{};
        for (var round = 0; round < 2; round++) {
          for (final mode in TreeTrunkMode.values) {
            await _chooseMode(tester, mode);
            for (final selected in ['natalia', 'roman', 'natalia']) {
              await _selectPerson(tester, selected);
              final layout = _layoutOf(
                fixture,
                selectedId: selected,
                mode: mode,
              );
              expect({
                for (final entry in layout.positions.entries)
                  entry.key: entry.value.level,
              }, ranks);
              final rendered = _renderedConnections(
                tester,
                layout,
                portrait: portrait,
              );
              Set<String> sources(String id) => rendered
                  .where(
                    (edge) =>
                        edge.$2 == 'block:${layout.positions[id]!.blockId}',
                  )
                  .map((edge) => edge.$1)
                  .toSet();
              if (selected == 'natalia') {
                expect(sources('nikita'), {'veronika'});
                expect(sources(rootTreePersonId), {'natalia', 'oleg'});
                expect(sources('anastasia'), {'natalia', 'nekto'});
                if (mode == TreeTrunkMode.both) {
                  final childLevel = layout.positions[rootTreePersonId]!.level;
                  expect(layout.positions['anastasia']!.level, childLevel);
                  final row = layout.levels
                      .singleWhere((level) => level.index == childLevel)
                      .blocks
                      .expand((block) => block.people)
                      .map((person) => person.id)
                      .toList();
                  final indices = [
                    row.indexOf(rootTreePersonId),
                    row.indexOf('anastasia'),
                  ]..sort();
                  expect(
                    row.sublist(indices.first, indices.last + 1),
                    unorderedEquals([rootTreePersonId, 'anastasia']),
                    reason:
                        'A nephew must not intrude between Natalia’s direct children.',
                  );
                }
              } else {
                expect(sources('nikita'), {'roman', 'veronika'});
                expect(sources('roman-nephew'), {'roman-half-sibling'});
              }
              final key = (selected, mode);
              if (coldConnections.containsKey(key)) {
                expect(rendered, coldConnections[key]);
              } else {
                coldConnections[key] = rendered;
              }
              _expectCanonicalRowGeometry(tester, layout, portrait: portrait);
            }
          }
          if (round == 0) {
            await tester.pumpWidget(const SizedBox.shrink());
            final coldSession = _Session(
              fixture.document,
              editingAllowed: true,
            );
            sessions.add(coldSession);
            await _mount(
              tester,
              coldSession,
              size: portrait ? const Size(700, 1200) : const Size(1200, 750),
              initialPersonId: 'natalia',
            );
          }
        }
        for (final session in sessions) {
          expect(session.operations, isEmpty);
        }
        expect(identical(fixture.document.people, peopleBefore), isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    for (final sexVariant in ['swapped', 'unknown']) {
      testWidgets(
        '${portrait ? 'portrait' : 'landscape'} full and maternal/paternal half-nephews and cousins use blood parents with $sexVariant sex and adversarial names/dates',
        (tester) async {
          final fixture = _collateralParentFamily();
          for (final person in fixture.document.people.values.toList()) {
            fixture.apply(
              fixture.document.setValue(
                person.id,
                'sex',
                sexVariant == 'unknown'
                    ? 'unknown'
                    : person.sex == TreeSex.male
                    ? 'female'
                    : 'male',
              ),
            );
          }
          final session = _Session(fixture.document, editingAllowed: true);
          final peopleBefore = fixture.document.people;
          final ranks = {
            for (final entry in _layoutOf(fixture).positions.entries)
              entry.key: entry.value.level,
          };
          await _mount(
            tester,
            session,
            size: portrait ? const Size(700, 1200) : const Size(1200, 750),
          );
          for (final mode in TreeTrunkMode.values) {
            await _chooseMode(tester, mode);
            final layout = _layoutOf(fixture, mode: mode);
            expect({
              for (final entry in layout.positions.entries)
                entry.key: entry.value.level,
            }, ranks);
            final rendered = _renderedConnections(
              tester,
              layout,
              portrait: portrait,
            );
            for (final (branch, parent) in const [
              ('full', 'Сестра-0'),
              ('maternal', 'maternal-half'),
              ('paternal', 'paternal-half'),
              ('cousin', 'aunt'),
            ]) {
              final target =
                  'block:${layout.positions['$branch-child-0']!.blockId}';
              expect(
                rendered.where((edge) => edge.$2 == target).toSet(),
                {(parent, target)},
                reason:
                    'The actual $branch parent wins even when its unrelated co-parent is undated and sorts first.',
              );
            }
            _expectCanonicalRowGeometry(tester, layout, portrait: portrait);
          }
          expect(session.operations, isEmpty);
          expect(identical(fixture.document.people, peopleBefore), isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      '${portrait ? 'mobile' : 'desktop'} deleting the selected person falls back to the surviving root',
      (tester) async {
        final fixture = _Fixture()
          ..name(rootTreePersonId, 'Я')
          ..add('selected');
        final session = _Session(fixture.document, editingAllowed: true);
        await _mount(
          tester,
          session,
          size: portrait ? const Size(430, 900) : const Size(1100, 850),
          initialPersonId: 'selected',
        );
        await tester.tap(find.byKey(const Key('open-biography')));
        await tester.pumpAndSettle();
        await session.applyTreeOperation(session.tree.deletePerson('selected'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (portrait) {
          // A remote deletion can leave the biography route open, but it remains
          // safe to close and return to the editor's new selection.
          expect(find.text('Человек не найден в дереве'), findsOneWidget);
          await tester.tap(find.byKey(const Key('biography-close')));
          await tester.pumpAndSettle();
        }
        expect(_person('selected'), findsNothing);
        expect(_person(rootTreePersonId), findsOneWidget);
        expect(
          _nodeSemantics(tester, 'Я').flagsCollection.isSelected,
          Tristate.isTrue,
        );
        expect(find.byKey(const Key('tree-empty')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'mobile' : 'desktop'} deleting the last root shows an empty tree and editor can create a person and open biography',
      (tester) async {
        final session = _Session(TreeDocument(), editingAllowed: true);
        await _mount(
          tester,
          session,
          size: portrait ? const Size(430, 900) : const Size(1100, 850),
        );
        await tester.tap(find.byKey(const Key('open-biography')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('biography-edit-toggle')));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const Key('delete-person')),
          250,
          scrollable: find
              .descendant(
                of: find.byKey(const PageStorageKey('biography-root')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('delete-person')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('delete-person')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('confirm-delete-person')));
        await tester.pumpAndSettle();
        expect(find.byType(PersonBiography), findsNothing);
        expect(session.tree.people, isEmpty);
        expect(_person(rootTreePersonId), findsNothing);
        expect(find.byKey(const Key('tree-empty')), findsOneWidget);
        expect(find.text('В дереве пока никого нет'), findsOneWidget);
        expect(find.byKey(const Key('open-biography')), findsNothing);
        await tester.tap(find.byKey(const Key('tree-add-person')));
        await tester.pumpAndSettle();
        expect(session.tree.people, hasLength(1));
        final createdId = session.tree.people.keys.single;
        expect(createdId, isNot(rootTreePersonId));
        expect(session.operations.map((operation) => operation.type), [
          'deletePerson',
          'createPerson',
        ]);
        final biography = tester.widget<PersonBiography>(
          find.byType(PersonBiography),
        );
        expect(biography.personId, createdId);
        expect(biography.fullScreen, portrait);
        await tester.tap(find.byKey(const Key('biography-close')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('tree-empty')), findsNothing);
        expect(_person(createdId), findsOneWidget);
        expect(
          _nodeSemantics(tester, 'Без имени').flagsCollection.isSelected,
          Tristate.isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'deleting the root selects the first remaining ID, not insertion order',
    (tester) async {
      final fixture = _Fixture()
        ..add('z-last')
        ..add('a-first');
      final session = _Session(
        fixture.document,
        boundId: rootTreePersonId,
        editingAllowed: true,
      );
      await _mount(tester, session, initialPersonId: rootTreePersonId);
      await session.applyTreeOperation(
        session.tree.deletePerson(rootTreePersonId),
      );
      await tester.pumpAndSettle();
      expect(_person(rootTreePersonId), findsNothing);
      expect(
        _nodeSemantics(tester, 'a-first').flagsCollection.isSelected,
        Tristate.isTrue,
      );
      expect(
        _nodeSemantics(tester, 'z-last').flagsCollection.isSelected,
        Tristate.isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final mode in ['editor', 'guest', 'picker']) {
    testWidgets(
      'empty $mode tree offers creation only to a non-picker editor',
      (tester) async {
        final fixture = _Fixture();
        fixture.apply(fixture.document.deletePerson(rootTreePersonId));
        final session = _Session(
          fixture.document,
          editingAllowed: mode != 'guest',
        );
        final picked = <String>[];
        await _mount(
          tester,
          session,
          onPickPerson: mode == 'picker' ? picked.add : null,
        );
        expect(find.byKey(const Key('tree-empty')), findsOneWidget);
        expect(find.text('В дереве пока никого нет'), findsOneWidget);
        expect(
          find.byKey(const Key('tree-add-person')),
          mode == 'editor' ? findsOneWidget : findsNothing,
        );
        expect(find.byKey(const Key('open-biography')), findsNothing);
        expect(find.byType(PersonBiography), findsNothing);
        expect(_person(rootTreePersonId), findsNothing);
        expect(session.operations, isEmpty);
        expect(picked, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'bound person is the initial main node; unknown binding uses root',
    (tester) async {
      final fixture = _family();
      final session = _Session(fixture.document, boundId: 'Мать');
      await _mount(tester, session);
      expect(
        _nodeSemantics(tester, 'Мать').flagsCollection.isSelected ==
            Tristate.isTrue,
        isTrue,
      );
      expect(
        _nodeSemantics(tester, 'Я').flagsCollection.isSelected ==
            Tristate.isTrue,
        isFalse,
      );

      session.boundId = 'missing';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TreeEditor(key: const Key('replacement'), session: session),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        _nodeSemantics(tester, 'Я').flagsCollection.isSelected ==
            Tristate.isTrue,
        isTrue,
      );
    },
  );

  testWidgets(
    'picker browses any node and commits only an explicitly confirmed valid selection',
    (tester) async {
      final fixture = _family(siblings: 14, children: 14);
      final session = _Session(
        fixture.document,
        boundId: 'Мать',
        editingAllowed: true,
      );
      final picked = <String>[];
      final peopleBefore = fixture.document.people;
      await _mount(
        tester,
        session,
        initialPersonId: 'Сестра-0',
        onPickPerson: picked.add,
        canPickPerson: (person) => person.sex == TreeSex.male,
      );
      expect(
        _nodeSemantics(tester, 'Сестра-0').flagsCollection.isSelected,
        Tristate.isTrue,
      );
      expect(find.byKey(const Key('open-biography')), findsNothing);
      expect(find.byType(PersonBiography), findsNothing);
      final confirm = find.byKey(const Key('confirm-tree-person'));
      expect(find.byTooltip('Подтвердить выбор'), findsOneWidget);
      expect(tester.widget<IconButton>(confirm).onPressed, isNull);
      expect(
        [
          ...tester.widgetList<Opacity>(
            find.descendant(
              of: _person(rootTreePersonId),
              matching: find.byType(Opacity),
            ),
          ),
          ...tester.widgetList<Opacity>(
            find.ancestor(
              of: _person(rootTreePersonId),
              matching: find.byType(Opacity),
            ),
          ),
        ].any((widget) => widget.opacity < 1),
        isTrue,
        reason: 'Unpickable people remain navigable but visibly dimmed.',
      );
      final focusLevel = _levelOf(fixture, rootTreePersonId);
      final hovered = _levelController(tester, focusLevel);
      final childScroll = _levelController(
        tester,
        _levelOf(fixture, 'Ребёнок-0'),
      );
      final main = _mainController(tester);
      main.jumpTo(main.position.maxScrollExtent / 2);
      final mainBefore = main.offset;
      final childBefore = childScroll.offset;
      hovered.jumpTo(hovered.position.maxScrollExtent / 2);
      await tester.pump();
      final before = hovered.offset;
      final hitArea = tester
          .getRect(find.byKey(ValueKey('tree-level-scroll-$focusLevel')))
          .intersect(tester.getRect(find.byKey(const Key('tree-canvas'))));
      await _wheel(
        tester,
        position: hitArea.center,
        delta: const Offset(0, 32),
      );
      expect(hovered.offset, before);
      expect(
        main.offset,
        closeTo((mainBefore + 32).clamp(0, main.position.maxScrollExtent), .1),
      );
      expect(childScroll.offset, childBefore);
      // Recenter through a real node's callback before tapping visible cards.
      tester
          .widget<InkWell>(
            find.descendant(
              of: _person(rootTreePersonId),
              matching: find.byType(InkWell),
            ),
          )
          .onTap!();
      await tester.pumpAndSettle();
      expect(picked, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.widget<IconButton>(confirm).onPressed, isNull);
      expect(
        _nodeSemantics(tester, 'Я').flagsCollection.isSelected,
        Tristate.isTrue,
      );
      await tester.tap(
        _person('Отец'),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.byType(PersonBiography), findsNothing);
      expect(find.byKey(const Key('tree-biography-panel')), findsNothing);
      expect(picked, isEmpty);
      await tester.tap(_person('Отец'));
      await tester.pumpAndSettle();
      expect(picked, isEmpty);
      expect(
        _nodeSemantics(tester, 'Отец').flagsCollection.isSelected,
        Tristate.isTrue,
      );
      expect(tester.widget<IconButton>(confirm).onPressed, isNotNull);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(picked, ['Отец']);
      expect(identical(fixture.document.people, peopleBefore), isTrue);
      expect(session.operations, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('picker confirmation tracks remote eligibility changes', (
    tester,
  ) async {
    final fixture = _family();
    final session = _Session(fixture.document);
    final picked = <String>[];
    var eligible = true;
    await _mount(
      tester,
      session,
      initialPersonId: 'Отец',
      onPickPerson: picked.add,
      canPickPerson: (person) => eligible && person.sex == TreeSex.male,
    );
    final confirm = find.byKey(const Key('confirm-tree-person'));
    expect(tester.widget<IconButton>(confirm).onPressed, isNotNull);
    fixture.apply(fixture.document.setValue('Отец', 'sex', 'female'));
    session.changed();
    await tester.pumpAndSettle();
    expect(
      _nodeSemantics(tester, 'Отец').flagsCollection.isSelected,
      Tristate.isTrue,
    );
    expect(tester.widget<IconButton>(confirm).onPressed, isNull);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(picked, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
    fixture.apply(fixture.document.setValue('Отец', 'sex', 'male'));
    session.changed();
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(confirm).onPressed, isNotNull);
    final unchangedPeople = fixture.document.people;
    eligible = false;
    session.changed();
    await tester.pumpAndSettle();
    expect(identical(fixture.document.people, unchangedPeople), isTrue);
    expect(tester.widget<IconButton>(confirm).onPressed, isNull);
    eligible = true;
    session.changed();
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(confirm).onPressed, isNotNull);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(picked, ['Отец']);
    expect(session.operations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final portrait in [true, false]) {
    testWidgets(
      '${portrait ? 'mobile' : 'desktop'} toolbar search uses birth surname and ignores legacy surname without editing or opening biography',
      (tester) async {
        final fixture = _Fixture()
          ..name(rootTreePersonId, 'Начало')
          ..add('unknown', sex: TreeSex.female)
          ..name('unknown', 'Анна Без даты')
          ..add('younger', sex: TreeSex.female)
          ..name('younger', 'Анна Младшая')
          ..add('oldest', sex: TreeSex.female)
          ..name('oldest', 'Анна Старшая');
        for (final id in ['unknown', 'younger', 'oldest']) {
          fixture.apply(
            fixture.document.setIndividualSurname(
              id,
              text: 'Иванов',
              decline: true,
            ),
          );
        }
        fixture
          ..apply(
            fixture.document.setValue(
              'younger',
              'birthDate',
              DateTime.utc(1950),
            ),
          )
          ..apply(
            fixture.document.setValue(
              'oldest',
              'birthDate',
              DateTime.utc(1890),
            ),
          )
          ..apply(
            fixture.document.setValue(
              'oldest',
              'deathDate',
              DateTime.utc(1960),
            ),
          )
          ..apply(
            fixture.document.setMaidenSurname(
              'oldest',
              text: 'Старов',
              decline: true,
            ),
          );
        final session = _Session(fixture.document, editingAllowed: true);
        final peopleBefore = fixture.document.people;
        await _mount(
          tester,
          session,
          size: portrait ? const Size(390, 844) : const Size(1100, 850),
        );
        final search = find.byKey(const Key('tree-search-field'));
        _expectInside(
          tester.getRect(search),
          tester.getRect(find.byKey(const Key('tree-toolbar'))),
        );
        await tester.enterText(search, 'иванова анна');
        await tester.pumpAndSettle();
        Finder option(String id) =>
            find.byKey(ValueKey('tree-search-option-$id'));
        expect(
          tester.getTopLeft(option('oldest')).dy,
          lessThan(tester.getTopLeft(option('younger')).dy),
        );
        expect(
          tester.getTopLeft(option('unknown')).dy,
          lessThan(tester.getTopLeft(option('oldest')).dy),
        );
        expect(
          find.descendant(
            of: option('oldest'),
            matching: find.text('Анна Старшая Иванова'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: option('oldest'),
            matching: find.text('1890–1960'),
          ),
          findsOneWidget,
        );
        expect(find.textContaining('до замужества'), findsNothing);
        expect(find.textContaining('Старова'), findsNothing);
        expect(
          find.descendant(of: option('unknown'), matching: find.text('?–?')),
          findsOneWidget,
        );
        await tester.enterText(search, 'старова');
        await tester.pumpAndSettle();
        expect(option('oldest'), findsNothing);
        expect(option('younger'), findsNothing);
        expect(option('unknown'), findsNothing);
        expect(find.text('Ничего не найдено'), findsOneWidget);
        await tester.enterText(search, 'иванова старшая 1890');
        await tester.pumpAndSettle();
        expect(option('oldest'), findsOneWidget);
        expect(option('younger'), findsNothing);
        expect(option('unknown'), findsNothing);
        await tester.tap(option('oldest'));
        await tester.pumpAndSettle();
        expect(
          _nodeSemantics(tester, 'Анна Старшая').flagsCollection.isSelected,
          Tristate.isTrue,
        );
        expect(find.byType(PersonBiography), findsNothing);
        expect(find.byKey(const Key('tree-biography-panel')), findsNothing);
        expect(find.byKey(const Key('confirm-tree-person')), findsNothing);
        expect(option('oldest'), findsNothing);
        expect(session.operations, isEmpty);
        expect(identical(fixture.document.people, peopleBefore), isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'picker search browses invalid and valid results before confirmation',
    (tester) async {
      final fixture = _family();
      final session = _Session(fixture.document, editingAllowed: true);
      final peopleBefore = fixture.document.people;
      final picked = <String>[];
      await _mount(
        tester,
        session,
        onPickPerson: picked.add,
        canPickPerson: (person) => person.sex == TreeSex.male,
      );
      final search = find.byKey(const Key('tree-search-field'));
      final confirm = find.byKey(const Key('confirm-tree-person'));
      for (final id in ['Мать', 'Отец']) {
        await tester.enterText(search, id);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('tree-search-option-$id')));
        await tester.pumpAndSettle();
        expect(
          _nodeSemantics(tester, id).flagsCollection.isSelected,
          Tristate.isTrue,
        );
        expect(
          tester.widget<IconButton>(confirm).onPressed,
          id == 'Мать' ? isNull : isNotNull,
        );
        expect(picked, isEmpty);
        expect(find.byType(PersonBiography), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        expect(session.operations, isEmpty);
      }
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(picked, ['Отец']);
      expect(identical(fixture.document.people, peopleBefore), isTrue);
      expect(session.operations, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final portrait in [true, false]) {
    testWidgets(
      '${portrait ? 'mobile' : 'desktop'} biography picker preserves main selection and has independent session-only zoom',
      (tester) async {
        final fixture = _Fixture()
          ..name(rootTreePersonId, 'Я')
          ..add('Мать', sex: TreeSex.female)
          ..add('Отец', sex: TreeSex.male);
        final session = _Session(fixture.document, editingAllowed: true);
        await _mount(
          tester,
          session,
          size: portrait ? const Size(430, 900) : const Size(1100, 850),
        );
        await _zoomSteps(tester, 2);
        expect(_zoomLabel(tester), '120%');
        await tester.tap(find.byKey(const Key('open-biography')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('biography-edit-toggle')));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const Key('add-relative')),
          200,
          scrollable: find
              .descendant(
                of: find.byKey(const PageStorageKey('biography-root')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('add-relative')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('relative-kind')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Мать').last);
        await tester.pumpAndSettle();
        final pick = find.byKey(const Key('relative-pick-from-tree'));
        expect(tester.widget<OutlinedButton>(pick).child, isA<Text>());
        expect(
          find.descendant(of: pick, matching: find.text('Выбрать')),
          findsOneWidget,
        );
        await tester.tap(pick);
        await tester.pumpAndSettle();
        final route = find.byKey(const Key('tree-person-picker-route'));
        expect(route, findsOneWidget);
        expect(
          tester.getSize(route),
          portrait ? const Size(430, 900) : const Size(1100, 850),
        );
        expect(find.text('Выбрать из дерева'), findsOneWidget);
        expect(
          find.text('Найдите человека и подтвердите выбор галочкой'),
          findsOneWidget,
        );
        expect(find.byTooltip('Отмена выбора'), findsOneWidget);
        expect(find.byKey(const Key('open-biography')), findsNothing);
        expect(find.byType(PersonBiography), findsNothing);
        expect(_zoomLabel(tester), '100%');
        _expectToolbarFits(tester);
        await _zoomWheel(tester, 100000, browserScale: false);
        expect(_zoomLabel(tester), '26%');
        await _zoomSteps(tester, 1);
        expect(_zoomLabel(tester), '30%');
        await tester.tap(find.byKey(const Key('tree-zoom-reset')));
        await tester.pumpAndSettle();
        await _zoomSteps(tester, 3);
        expect(_zoomLabel(tester), '130%');
        _expectToolbarFits(tester);
        final search = find.byKey(const Key('tree-search-field'));
        await tester.enterText(search, 'Мать');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('tree-search-option-Мать')));
        await tester.pumpAndSettle();
        expect(route, findsOneWidget);
        expect(_zoomLabel(tester), '130%');
        expect(
          _nodeSemantics(tester, 'Мать').flagsCollection.isSelected,
          Tristate.isTrue,
        );
        expect(tester.widget<TextField>(search).controller!.text, isEmpty);
        _expectToolbarFits(tester);
        if (portrait) {
          await tester.enterText(search, 'Отец');
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('tree-search-back')), findsOneWidget);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(route, findsOneWidget);
          expect(find.byKey(const Key('tree-search-back')), findsNothing);
          expect(_zoomLabel(tester), '130%');
        }
        expect(session.operations, isEmpty);
        await tester.tap(find.byTooltip('Отмена выбора'));
        await tester.pumpAndSettle();
        expect(route, findsNothing);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.byKey(const Key('relative-selected-person')), findsNothing);
        expect(session.operations, isEmpty);
        await tester.tap(pick);
        await tester.pumpAndSettle();
        expect(_zoomLabel(tester), '100%');
        expect(tester.widget<TextField>(search).controller!.text, isEmpty);
        expect(tester.widget<TextField>(search).focusNode!.hasFocus, isFalse);
        await tester.tap(_person(rootTreePersonId));
        await tester.pumpAndSettle();
        expect(route, findsOneWidget);
        expect(find.byType(SnackBar), findsNothing);
        final confirm = find.byKey(const Key('confirm-tree-person'));
        expect(tester.widget<IconButton>(confirm).onPressed, isNull);
        expect(session.operations, isEmpty);
        await tester.tap(_person('Мать'));
        await tester.pumpAndSettle();
        expect(route, findsOneWidget);
        expect(tester.widget<IconButton>(confirm).onPressed, isNotNull);
        expect(session.operations, isEmpty);
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(route, findsNothing);
        final selected = find.byKey(const Key('relative-selected-person'));
        expect(tester.widget<Text>(selected).data, 'Мать\n?–?');
        await tester.tap(pick);
        await tester.pumpAndSettle();
        expect(
          _nodeSemantics(tester, 'Мать').flagsCollection.isSelected,
          Tristate.isTrue,
        );
        await tester.tap(_person(rootTreePersonId));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Отмена выбора'));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(selected).data, 'Мать\n?–?');
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          tester.widget<PersonBiography>(find.byType(PersonBiography)).personId,
          rootTreePersonId,
        );
        expect(session.operations, isEmpty);
        expect(session.tree.person(rootTreePersonId)!.motherId, isNull);
        await tester.tap(find.byKey(const Key('confirm-add-relative')));
        await tester.pumpAndSettle();
        expect(session.tree.person(rootTreePersonId)!.motherId, 'Мать');
        expect(session.operations, hasLength(1));
        expect(
          tester.widget<PersonBiography>(find.byType(PersonBiography)).personId,
          rootTreePersonId,
        );
        await tester.tap(find.byKey(const Key('biography-close')));
        await tester.pumpAndSettle();
        expect(
          _nodeSemantics(tester, 'Я').flagsCollection.isSelected,
          Tristate.isTrue,
        );
        expect(
          _nodeSemantics(tester, 'Мать').flagsCollection.isSelected,
          Tristate.isFalse,
        );
        expect(_zoomLabel(tester), '120%');
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(900, 1440),
    const Size(1440, 900),
  ]) {
    testWidgets(
      '${size.width.toInt()}x${size.height.toInt()} nominal four-mm avatar floor is identical at DPR 1 and 3 for every zoom path',
      (tester) async {
        const minAvatarMm = 4.0;
        const logicalPixelsPerInch = 96.0;
        const millimetersPerInch = 25.4;
        final avatarSizes = <double>[];
        for (final dpr in [1.0, 3.0]) {
          final session = _Session(_family().document, editingAllowed: true);
          final peopleBefore = session.tree.people;
          await _mount(tester, session, size: size, devicePixelRatio: dpr);
          final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
          expect(tester.view.physicalSize / dpr, size);
          expect(canvas.width, closeTo(size.width, .01));
          final avatar = find.descendant(
            of: _person(rootTreePersonId),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is SizedBox &&
                  widget.width == 60 &&
                  widget.height == 60,
            ),
          );
          expect(avatar, findsOneWidget);
          final originalAvatar = tester.getRect(avatar).size;
          expect(originalAvatar, const Size.square(60));
          final floor =
              (minAvatarMm *
                      logicalPixelsPerInch /
                      millimetersPerInch /
                      originalAvatar.width *
                      100)
                  .ceil() /
              100;
          expect(floor, .26);

          void expectFloor() {
            final actualAvatar = tester.getRect(avatar).size;
            expect(_zoomLabel(tester), '${(floor * 100).round()}%');
            expect(
              actualAvatar.width,
              closeTo(originalAvatar.width * floor, .001),
            );
            expect(
              actualAvatar.height,
              closeTo(originalAvatar.height * floor, .001),
            );
            final nominalMm =
                actualAvatar.width / logicalPixelsPerInch * millimetersPerInch;
            expect(nominalMm, greaterThanOrEqualTo(minAvatarMm));
            expect(
              originalAvatar.width *
                  (floor - .01) /
                  logicalPixelsPerInch *
                  millimetersPerInch,
              lessThan(minAvatarMm),
              reason:
                  'The floor must be the smallest sufficient whole percent.',
            );
            expect(
              tester
                  .widget<IconButton>(find.byKey(const Key('tree-zoom-out')))
                  .onPressed,
              isNull,
            );
          }

          await _zoomSteps(tester, -7);
          expect(_zoomLabel(tester), '30%');
          await _zoomSteps(tester, -1);
          expectFloor();
          avatarSizes.add(tester.getRect(avatar).width);
          await _zoomSteps(tester, -1);
          expectFloor();
          await _zoomSteps(tester, 1);
          expect(_zoomLabel(tester), '30%');
          expect(
            tester
                .widget<IconButton>(find.byKey(const Key('tree-zoom-out')))
                .onPressed,
            isNotNull,
          );

          for (final browserScale in [false, true]) {
            await _zoomWheel(tester, 100000, browserScale: browserScale);
            expectFloor();
            await _zoomWheel(tester, -100, browserScale: browserScale);
            expect(_zoomLabel(tester), '30%');
          }

          await tester.tap(find.byKey(const Key('tree-zoom-reset')));
          await tester.pumpAndSettle();
          expect(_zoomLabel(tester), '100%');
          // This rounds below the floor before the final central clamp.
          await _pinchBy(tester, .25994);
          expectFloor();
          await _pinchBy(tester, .01);
          expectFloor();
          await _zoomSteps(tester, 1);
          expect(_zoomLabel(tester), '30%');
          expect(identical(session.tree.people, peopleBefore), isTrue);
          expect(session.operations, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
        expect(avatarSizes[1], closeTo(avatarSizes[0], .001));
      },
    );
  }

  for (final browserScale in [false, true]) {
    final signal = browserScale ? 'web scale' : 'native Ctrl-wheel';
    testWidgets(
      '$signal zoom uses accumulated absolute five-point grid steps',
      (tester) async {
        final session = _Session(_family().document, editingAllowed: true);
        final peopleBefore = session.tree.people;
        await _mount(tester, session);
        Future<void> wheel(double dy, String expected) async {
          await _zoomWheel(tester, dy, browserScale: browserScale);
          expect(_zoomLabel(tester), expected, reason: '$signal dy=$dy');
        }

        await wheel(-120, '105%');
        await wheel(-79, '105%');
        await wheel(-1, '110%');
        await wheel(-300, '125%');
        await wheel(100, '120%');
        await wheel(400, '100%');
        await wheel(100, '95%');
        await wheel(-100, '100%');
        expect(session.operations, isEmpty);
        expect(identical(session.tree.people, peopleBefore), isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$signal clears partial deltas on reversal and at bounds without overscroll debt',
      (tester) async {
        final session = _Session(_family().document, editingAllowed: true);
        await _mount(tester, session);
        Future<void> wheel(double dy, String expected) async {
          await _zoomWheel(tester, dy, browserScale: browserScale);
          expect(_zoomLabel(tester), expected, reason: '$signal dy=$dy');
        }

        await wheel(-99, '100%');
        await wheel(1, '100%');
        await wheel(99, '95%');
        await wheel(99, '95%');
        await wheel(-1, '95%');
        await wheel(-99, '100%');

        // Reaching a bound clears a leftover partial step as well as any huge
        // overshoot. The first reverse notch must take effect immediately.
        await wheel(2075, '26%');
        await wheel(-99, '26%');
        await wheel(-1, '30%');
        await wheel(100000, '26%');
        await wheel(99, '26%');
        for (var percent = 30; percent <= 200; percent += 5) {
          await wheel(-100, '$percent%');
        }
        await wheel(-100000, '200%');
        await wheel(-99, '200%');
        for (var percent = 195; percent >= 30; percent -= 5) {
          await wheel(100, '$percent%');
        }
        await wheel(175, '26%');
        await wheel(100000, '26%');
        await wheel(-100, '30%');
        expect(session.operations, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$signal snaps off-grid touch zoom in the requested direction',
      (tester) async {
        final session = _Session(_family().document, editingAllowed: true);
        await _mount(tester, session, size: const Size(430, 900));
        final width = tester.getRect(_person(rootTreePersonId)).width;
        await _pinchBy(tester, 1.073);
        expect(_zoomLabel(tester), '107%');
        expect(
          tester.getRect(_person(rootTreePersonId)).width,
          closeTo(width * 1.073, .1),
          reason: 'Raw touch pinch remains continuous, not five-point stepped.',
        );
        await _zoomWheel(tester, -100, browserScale: browserScale);
        expect(_zoomLabel(tester), '110%');
        await tester.tap(find.byKey(const Key('tree-zoom-reset')));
        await tester.pumpAndSettle();
        await _pinchBy(tester, 1.073);
        await _zoomWheel(tester, 100, browserScale: browserScale);
        expect(_zoomLabel(tester), '105%');
        expect(session.operations, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('toolbar buttons snap arbitrary touch zoom to ten-point grid', (
    tester,
  ) async {
    final session = _Session(_family().document, editingAllowed: true);
    await _mount(tester, session, size: const Size(430, 900));
    await _pinchBy(tester, 1.073);
    await _zoomSteps(tester, 1);
    expect(_zoomLabel(tester), '110%');
    await tester.tap(find.byKey(const Key('tree-zoom-reset')));
    await tester.pumpAndSettle();
    await _pinchBy(tester, 1.073);
    await _zoomSteps(tester, -1);
    expect(_zoomLabel(tester), '100%');
    await _zoomWheel(tester, -100, browserScale: false);
    expect(_zoomLabel(tester), '105%');
    await _zoomSteps(tester, 1);
    expect(_zoomLabel(tester), '110%');
    await _zoomSteps(tester, -1);
    expect(_zoomLabel(tester), '100%');
    expect(session.operations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final portrait in [true, false]) {
    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} all rows retain exact affine zoom and relative logical scroll at singleton and one-axis bounds',
      (tester) async {
        final fixture = _family(siblings: 14, children: 14)
          ..add('Прадед', sex: TreeSex.male)
          ..parents('Дед', father: 'Прадед');
        final session = _Session(fixture.document, editingAllowed: true);
        final peopleBefore = fixture.document.people;
        await _mount(
          tester,
          session,
          size: portrait ? const Size(430, 900) : const Size(1100, 700),
        );
        final layout = _layoutOf(fixture);
        final rows = {
          for (final level in layout.levels)
            level.index: _levelController(tester, level.index),
        };
        final singletonLevel = layout.positions['Прадед']!.level;
        expect(
          layout.levels
              .singleWhere((level) => level.index == singletonLevel)
              .blocks
              .expand((block) => block.people),
          hasLength(1),
        );
        final singleton = rows[singletonLevel]!;
        singleton.jumpTo(singleton.position.minScrollExtent);
        final main = _mainController(tester);
        main.jumpTo(main.position.maxScrollExtent);
        var index = 0;
        for (final row in rows.values) {
          row.jumpTo(switch (index++ % 3) {
            0 => 0,
            1 => row.position.maxScrollExtent,
            _ => row.position.maxScrollExtent / 2,
          });
        }
        await tester.pump();
        final initial = {
          for (final id in fixture.document.people.keys)
            id: tester.getRect(_person(id)),
        };
        final relativeBefore = _relativeLogicalCrossOffsets(
          tester,
          layout,
          portrait: portrait,
        );
        final focal = tester
            .getRect(find.byKey(const Key('tree-canvas')))
            .center;

        Future<void> checkZoom(
          Future<void> Function() action, {
          Offset? at,
        }) async {
          final before = {
            for (final id in fixture.document.people.keys)
              id: tester.getRect(_person(id)),
          };
          final scrollBefore = {
            for (final entry in rows.entries) entry.key: entry.value.offset,
          };
          await action();
          final scale =
              tester.getRect(_person(rootTreePersonId)).width /
              before[rootTreePersonId]!.width;
          _expectAffineCards(tester, before, focal: at ?? focal, scale: scale);
          final relativeAfter = _relativeLogicalCrossOffsets(
            tester,
            layout,
            portrait: portrait,
          );
          final referenceDelta =
              rows.values.first.offset - scrollBefore.values.first;
          for (final entry in rows.entries) {
            expect(
              relativeAfter[entry.key],
              closeTo(relativeBefore[entry.key]!, .2),
              reason: 'Zoom must not realign independently panned generations.',
            );
            expect(
              entry.value.offset - scrollBefore[entry.key]!,
              closeTo(referenceDelta, .2),
              reason: 'Every row must receive the same padding correction.',
            );
          }
          for (final controller in [main, ...rows.values]) {
            expect(
              controller.offset,
              greaterThanOrEqualTo(controller.position.minScrollExtent - .01),
            );
            expect(
              controller.offset,
              lessThanOrEqualTo(controller.position.maxScrollExtent + .01),
            );
          }
          expect(tester.takeException(), isNull);
        }

        final offCenterFocal = focal + const Offset(-80, -120);
        for (final delta in [
          -100.0,
          -5000.0,
          -5000.0,
          5000.0,
          5000.0,
          -1500.0,
        ]) {
          await checkZoom(
            () => _zoomWheel(
              tester,
              delta,
              browserScale: true,
              focal: offCenterFocal,
            ),
            at: offCenterFocal,
          );
        }
        expect(_zoomLabel(tester), '100%');
        _expectAffineCards(tester, initial, focal: offCenterFocal, scale: 1);
        await checkZoom(() => _zoomSteps(tester, 1));
        await checkZoom(() => _zoomSteps(tester, -1));
        _expectAffineCards(tester, initial, focal: focal, scale: 1);
        await checkZoom(() => _pinchBy(tester, 1.073));
        expect(_zoomLabel(tester), '107%');
        await checkZoom(() => _pinchBy(tester, .1));
        expect(_zoomLabel(tester), '26%');
        await checkZoom(() => _pinchBy(tester, .5));
        expect(_zoomLabel(tester), '26%');
        await checkZoom(() => _zoomWheel(tester, -5000, browserScale: true));
        expect(_zoomLabel(tester), '200%');
        await checkZoom(() => _zoomWheel(tester, -5000, browserScale: true));
        await checkZoom(() => _zoomWheel(tester, 5000, browserScale: false));
        expect(_zoomLabel(tester), '26%');
        await checkZoom(() => _zoomWheel(tester, 5000, browserScale: false));
        await checkZoom(() async {
          await tester.tap(find.byKey(const Key('tree-zoom-reset')));
          await tester.pumpAndSettle();
        });
        expect(_zoomLabel(tester), '100%');
        _expectAffineCards(tester, initial, focal: focal, scale: 1);
        expect(identical(fixture.document.people, peopleBefore), isTrue);
        expect(session.operations, isEmpty);
      },
    );
  }

  testWidgets(
    'phone pinch anchors its midpoint, suppresses taps, and restores one-finger drag',
    (tester) async {
      final fixture = _family(siblings: 14, children: 14);
      final session = _Session(fixture.document, editingAllowed: true);
      final picked = <String>[];
      await _mount(
        tester,
        session,
        size: const Size(430, 900),
        onPickPerson: picked.add,
      );
      final main = _mainController(tester);
      final row = _levelController(tester, _levelOf(fixture, rootTreePersonId));
      final rowBefore = row.offset;
      final firstStart =
          tester.getCenter(_person(rootTreePersonId)) - const Offset(24, 0);
      final first = await tester.startGesture(firstStart, pointer: 1);
      // The named root is now last among undated siblings. Drag away from the
      // trailing bound, not into it, before starting the pinch.
      await first.moveBy(const Offset(0, 24));
      await tester.pump();
      await first.moveBy(const Offset(0, 24));
      await tester.pump();
      expect(row.offset, lessThan(rowBefore));
      final before = tester.getRect(_person(rootTreePersonId));
      final cardsBefore = {
        for (final id in fixture.document.people.keys)
          id: tester.getRect(_person(id)),
      };
      final focal = firstStart + const Offset(24, 48);
      final second = await tester.startGesture(
        focal + const Offset(24, 0),
        pointer: 2,
      );
      await tester.pump();
      await first.moveTo(focal - const Offset(36, 0));
      await tester.pump();
      await second.moveTo(focal + const Offset(36, 0));
      await tester.pumpAndSettle();
      expect(_zoomLabel(tester), '150%');
      final after = tester.getRect(_person(rootTreePersonId));
      expect(after.width, closeTo(before.width * 1.5, .1));
      _expectAffineCards(tester, cardsBefore, focal: focal, scale: 1.5);
      expect(
        (after.topLeft - (focal + (before.topLeft - focal) * 1.5)).distance,
        lessThan(.2),
      );
      final offsets = [main.offset, row.offset];
      await first.up();
      await tester.pump();
      await second.moveBy(const Offset(0, -80));
      await tester.pump();
      expect([main.offset, row.offset], offsets);
      expect(_zoomLabel(tester), '150%');
      await second.up();
      await tester.pumpAndSettle();
      expect(picked, isEmpty);

      // A two-finger contact with no movement must not become a node tap either.
      final center = tester.getCenter(_person(rootTreePersonId));
      final stationaryFirst = await tester.startGesture(
        center - const Offset(12, 0),
        pointer: 3,
      );
      final stationarySecond = await tester.startGesture(
        center + const Offset(12, 0),
        pointer: 4,
      );
      await tester.pump();
      await stationaryFirst.cancel();
      await stationarySecond.up();
      await tester.pumpAndSettle();
      expect(picked, isEmpty);

      expect(row.offset - row.position.minScrollExtent, greaterThan(60));
      final oneFinger = await tester.startGesture(center, pointer: 5);
      await oneFinger.moveBy(const Offset(0, 30));
      await tester.pump();
      final rowAfterSlop = row.offset;
      await oneFinger.moveBy(const Offset(0, 45));
      await tester.pump();
      expect(row.offset - rowAfterSlop, closeTo(-30, .1));
      expect(main.offset, offsets.first);
      await oneFinger.up();
      await tester.pumpAndSettle();
      expect(_zoomLabel(tester), '150%');
      expect(picked, isEmpty);
      expect(session.operations, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final portrait in [true, false]) {
    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} zoom scales cards, text, and link endpoints but not controls',
      (tester) async {
        final fixture = _family(siblings: 14, children: 14);
        final session = _Session(fixture.document, editingAllowed: true);
        await _mount(
          tester,
          session,
          size: portrait ? const Size(430, 900) : const Size(1100, 700),
        );
        final peopleBefore = fixture.document.people;
        final levels = {
          for (final level in _layoutOf(fixture).levels)
            level.index: _levelController(tester, level.index),
        };
        levels[_levelOf(fixture, rootTreePersonId)]!.jumpTo(200);
        levels[_levelOf(fixture, 'Ребёнок-0')]!.jumpTo(100);
        await tester.pump();
        final offsetsBefore = {
          for (final entry in levels.entries) entry.key: entry.value.offset,
        };
        final node = _person(rootTreePersonId);
        final name = find.descendant(
          of: find.byKey(const ValueKey('tree-name-background-root')),
          matching: find.text('Я'),
        );
        final avatar = find.descendant(
          of: node,
          matching: find.byType(ClipRRect),
        );
        final nodeBefore = tester.getRect(node);
        final nameBefore = tester.getRect(name).size;
        final avatarBefore = tester.getRect(avatar).size;
        final toolbarBefore = tester.getRect(
          find.byKey(const Key('tree-toolbar')),
        );
        final biographyBefore = tester
            .getRect(find.byKey(const Key('open-biography')))
            .size;
        final canvasBefore = tester.getRect(
          find.byKey(const Key('tree-canvas')),
        );
        final main = _mainController(tester);
        final logicalContentExtent =
            main.position.viewportDimension + main.position.maxScrollExtent;
        final physicalMainViewport = portrait
            ? canvasBefore.width
            : canvasBefore.height;

        void expectScaled(double scale) {
          expect(
            main.position.viewportDimension,
            closeTo(physicalMainViewport / scale, .1),
          );
          expect(
            main.position.maxScrollExtent,
            closeTo(
              (logicalContentExtent - physicalMainViewport / scale).clamp(
                0,
                double.infinity,
              ),
              .1,
            ),
            reason:
                'Zoom must refresh scroll bounds, not only painted positions.',
          );
          expect(tester.getRect(node).width, closeTo(108 * scale, .1));
          expect(tester.getRect(node).height, closeTo(108 * scale, .1));
          expect(
            tester.getRect(name).width,
            closeTo(nameBefore.width * scale, .1),
          );
          expect(
            tester.getRect(name).height,
            closeTo(nameBefore.height * scale, .1),
          );
          expect(
            tester.getRect(avatar).width,
            closeTo(avatarBefore.width * scale, .1),
          );
          expect(
            tester.getRect(avatar).height,
            closeTo(avatarBefore.height * scale, .1),
          );
          expect(
            tester.getRect(find.byKey(const Key('tree-toolbar'))),
            toolbarBefore,
          );
          expect(
            tester.getRect(find.byKey(const Key('tree-canvas'))),
            canvasBefore,
          );
          expect(
            tester.getRect(find.byKey(const Key('open-biography'))).size,
            biographyBefore,
          );
          final links = tester.renderObject<RenderBox>(
            find.byKey(const Key('tree-links')),
          );
          final drawing = _ConnectionCanvas();
          _linkPainter(tester).paint(drawing, links.size);
          final root = tester.getRect(node);
          final target = portrait
              ? Offset(root.center.dx - 30 * scale, root.top + 36 * scale)
              : Offset(root.center.dx, root.top + 6 * scale);
          final incoming = drawing.paths
              .where(
                (path) =>
                    (links.localToGlobal(_pathEnd(path)) - target).distance <
                    .2,
              )
              .toList();
          expect(incoming, hasLength(2));
          for (final id in ['Отец', 'Мать']) {
            final parent = tester.getRect(_person(id));
            final anchor = portrait
                ? Offset(parent.center.dx + 30 * scale, parent.top + 36 * scale)
                : Offset(parent.center.dx, parent.top + 66 * scale);
            expect(
              incoming.any(
                (path) =>
                    (links.localToGlobal(_pathStart(path)) - anchor).distance <
                    .2,
              ),
              isTrue,
              reason: 'The scaled link must still meet $id’s avatar.',
            );
          }
        }

        await _zoomSteps(tester, 10);
        expect(_zoomLabel(tester), '200%');
        expectScaled(2);
        await tester.tap(find.byKey(const Key('tree-zoom-reset')));
        await tester.pumpAndSettle();
        expect(
          (tester.getRect(node).topLeft - nodeBefore.topLeft).distance,
          lessThan(.2),
        );
        for (final entry in offsetsBefore.entries) {
          expect(levels[entry.key]!.offset, closeTo(entry.value, .1));
        }
        await _zoomSteps(tester, -5);
        expect(_zoomLabel(tester), '50%');
        expectScaled(.5);
        expect(
          _nodeSemantics(tester, 'Я').flagsCollection.isSelected,
          Tristate.isTrue,
        );
        expect(session.operations, isEmpty);
        expect(fixture.document.people, peopleBefore);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} Ctrl-wheel anchors the pointer and consumes zoom without ordinary scrolling',
      (tester) async {
        final fixture = _family(siblings: 14, children: 14);
        final session = _Session(fixture.document, editingAllowed: true);
        await _mount(
          tester,
          session,
          size: portrait ? const Size(430, 900) : const Size(1100, 700),
        );
        final main = _mainController(tester);
        final levels = {
          for (final level in _layoutOf(fixture).levels)
            level.index: _levelController(tester, level.index),
        };
        final index = _levelOf(fixture, rootTreePersonId);
        main.jumpTo(main.position.maxScrollExtent / 2);
        expect(
          levels[index]!.offset - levels[index]!.position.minScrollExtent,
          greaterThan(48),
        );
        levels[index]!.jumpTo(levels[index]!.offset - 48);
        await tester.pump();
        final before = tester.getRect(_person(rootTreePersonId));
        final cardsBefore = {
          for (final id in fixture.document.people.keys)
            id: tester.getRect(_person(id)),
        };
        final focal = before.center + const Offset(16, -12);
        final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
        expect(canvas.contains(focal), isTrue);
        final otherBefore = {
          for (final entry in levels.entries)
            if (entry.key != index) entry.key: entry.value.offset,
        };
        final relativeBefore = _relativeLogicalCrossOffsets(
          tester,
          _layoutOf(fixture),
          portrait: portrait,
        );
        final rowBefore = levels[index]!.offset;
        Rect? firstPaint;
        var captureNextPaint = true;
        tester.binding.addPersistentFrameCallback((_) {
          if (captureNextPaint) {
            firstPaint = tester.getRect(_person(rootTreePersonId));
            captureNextPaint = false;
          }
        });
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        try {
          await _wheel(tester, position: focal, delta: const Offset(0, -120));
        } finally {
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        }
        final after = tester.getRect(_person(rootTreePersonId));
        final scale = after.width / before.width;
        expect(_zoomLabel(tester), '105%');
        expect(scale, closeTo(1.05, .0001));
        _expectAffineCards(tester, cardsBefore, focal: focal, scale: scale);
        expect(
          firstPaint,
          after,
          reason: 'Focal correction precedes first paint.',
        );
        expect(
          (after.topLeft - (focal + (before.topLeft - focal) * scale)).distance,
          lessThan(.2),
        );
        for (final entry in otherBefore.entries) {
          expect(
            levels[entry.key]!.offset - entry.value,
            closeTo(levels[index]!.offset - rowBefore, .1),
          );
        }
        expect(
          _nodeSemantics(tester, 'Я').flagsCollection.isSelected,
          Tristate.isTrue,
        );
        expect(session.operations, isEmpty);
        final relativeAfter = _relativeLogicalCrossOffsets(
          tester,
          _layoutOf(fixture),
          portrait: portrait,
        );
        for (final entry in relativeBefore.entries) {
          expect(relativeAfter[entry.key], closeTo(entry.value, .1));
        }
        // Raw padded offsets may stay unchanged when the common padding absorbs
        // a focal correction; exact affine cards and logical row offsets above
        // rule out ordinary scrolling without assuming offsets must move.
        // Flutter web translates browser Ctrl-wheel into scale=exp(-dy/200),
        // sometimes without a separately delivered Ctrl key event. Reversing
        // one notch returns to 100%, not a multiplicative intermediate value.
        firstPaint = null;
        captureNextPaint = true;
        await tester.sendEventToBinding(
          PointerScaleEvent(
            kind: PointerDeviceKind.mouse,
            position: focal,
            scale: math.exp(-120 / 200),
          ),
        );
        await tester.pumpAndSettle();
        final browserAfter = tester.getRect(_person(rootTreePersonId));
        expect(_zoomLabel(tester), '100%');
        expect(browserAfter.width, closeTo(after.width / 1.05, .1));
        _expectAffineCards(tester, cardsBefore, focal: focal, scale: 1);
        expect(firstPaint, browserAfter);
        expect(
          (browserAfter.topLeft - (focal + (after.topLeft - focal) / 1.05))
              .distance,
          lessThan(.2),
        );
        for (final entry in otherBefore.entries) {
          expect(
            levels[entry.key]!.offset - entry.value,
            closeTo(levels[index]!.offset - rowBefore, .1),
          );
        }
        expect(session.operations, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} wheel and primary pans remain independent around a rigid middle pan at 200%',
      (tester) async {
        final fixture = _family(siblings: 14, children: 14);
        await _mount(
          tester,
          _Session(fixture.document),
          size: portrait ? const Size(430, 900) : const Size(1100, 700),
        );
        await _zoomSteps(tester, 10);
        final main = _mainController(tester);
        final levels = {
          for (final level in _layoutOf(fixture).levels)
            level.index: _levelController(tester, level.index),
        };
        final index = _levelOf(fixture, rootTreePersonId);
        final hovered = levels[index]!;
        main.jumpTo(main.position.maxScrollExtent / 2);
        hovered.jumpTo(hovered.position.maxScrollExtent / 2);
        await tester.pump();
        Offset hitPosition() {
          final band = tester.getRect(
            find.byKey(ValueKey('tree-level-scroll-$index')),
          );
          final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
          final area = band.intersect(canvas);
          expect(area.width, greaterThan(0));
          expect(area.height, greaterThan(0));
          return area.center;
        }

        final mainBefore = main.offset;
        final rowBefore = hovered.offset;
        final otherBeforeWheel = {
          for (final entry in levels.entries)
            if (entry.key != index) entry.key: entry.value.offset,
        };
        await _wheel(
          tester,
          position: hitPosition(),
          delta: const Offset(24, 32),
        );
        expect(main.offset, closeTo(mainBefore + (portrait ? 12 : 16), .1));
        expect(hovered.offset, closeTo(rowBefore + (portrait ? 16 : 12), .1));
        for (final entry in otherBeforeWheel.entries) {
          expect(levels[entry.key]!.offset, entry.value);
        }
        final beforeMiddle = {
          for (final id in fixture.document.people.keys)
            id: tester.getRect(_person(id)),
        };
        final middle = await tester.startGesture(
          hitPosition(),
          kind: PointerDeviceKind.mouse,
          buttons: kMiddleMouseButton,
        );
        await middle.moveBy(const Offset(-24, -32));
        await tester.pump();
        _expectTranslatedCards(tester, beforeMiddle, const Offset(-24, -32));
        await middle.up();
        await tester.pumpAndSettle();
        final mainAfterMiddle = main.offset;
        final rowAfterMiddle = hovered.offset;
        final othersAfterMiddle = {
          for (final entry in levels.entries)
            if (entry.key != index) entry.key: entry.value.offset,
        };
        await _wheel(
          tester,
          position: hitPosition(),
          delta: const Offset(24, 32),
        );
        expect(
          main.offset,
          closeTo(mainAfterMiddle + (portrait ? 12 : 16), .1),
        );
        expect(
          hovered.offset,
          closeTo(rowAfterMiddle + (portrait ? 16 : 12), .1),
        );
        for (final entry in othersAfterMiddle.entries) {
          expect(levels[entry.key]!.offset, entry.value);
        }
        final beforePrimaryMain = main.offset;
        final beforePrimaryRow = hovered.offset;
        final otherBeforePrimary = {
          for (final entry in levels.entries)
            if (entry.key != index) entry.key: entry.value.offset,
        };
        final primary = await tester.startGesture(
          hitPosition(),
          kind: PointerDeviceKind.mouse,
        );
        await primary.moveBy(const Offset(-24, 0));
        await tester.pump();
        final afterSlop = portrait ? main.offset : hovered.offset;
        await primary.moveBy(const Offset(-48, 0));
        await tester.pump();
        expect(
          (portrait ? main.offset : hovered.offset) - afterSlop,
          closeTo(24, .1),
        );
        expect(
          portrait ? hovered.offset : main.offset,
          portrait ? beforePrimaryRow : beforePrimaryMain,
        );
        await primary.up();
        await tester.pumpAndSettle();
        for (final entry in otherBeforePrimary.entries) {
          expect(levels[entry.key]!.offset, entry.value);
        }
        expect(_zoomLabel(tester), '200%');
        expect(
          _nodeSemantics(tester, 'Я').flagsCollection.isSelected,
          Tristate.isTrue,
        );
        expect(find.byType(PersonBiography), findsNothing);

        // Blank leading padding has no generation listener, but must consume
        // wheel input with the same physical distances and zoom behavior.
        main.jumpTo(0);
        await tester.pump();
        final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
        final paddingPoint = portrait
            ? Offset(canvas.left + 8, canvas.center.dy)
            : Offset(canvas.center.dx, canvas.top + 8);
        final paddingDelta = portrait
            ? const Offset(32, 0)
            : const Offset(0, 32);
        final rowsBeforePadding = {
          for (final entry in levels.entries) entry.key: entry.value.offset,
        };
        await _wheel(tester, position: paddingPoint, delta: -paddingDelta);
        expect(main.offset, 0);
        await _wheel(tester, position: paddingPoint, delta: paddingDelta);
        expect(main.offset, closeTo(16, .1));
        for (final entry in rowsBeforePadding.entries) {
          expect(levels[entry.key]!.offset, entry.value);
        }
        main.jumpTo(0);
        await tester.pump();
        final nodeWidth = tester.getRect(_person(rootTreePersonId)).width;
        final beforePaddingZoom = {
          for (final id in fixture.document.people.keys)
            id: tester.getRect(_person(id)),
        };
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        try {
          await _wheel(
            tester,
            position: paddingPoint,
            delta: const Offset(0, 100),
          );
        } finally {
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        }
        expect(_zoomLabel(tester), '195%');
        _expectAffineCards(
          tester,
          beforePaddingZoom,
          focal: paddingPoint,
          scale: 195 / 200,
        );
        expect(
          tester.getRect(_person(rootTreePersonId)).width,
          closeTo(nodeWidth * 195 / 200, .1),
        );
        expect(main.offset, closeTo(0, .1));
        for (final entry in rowsBeforePadding.entries) {
          expect(levels[entry.key]!.offset, closeTo(entry.value, .1));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final portrait in [true, false]) {
    testWidgets(
      '${portrait ? 'portrait columns' : 'landscape rows'} scroll independently',
      (tester) async {
        final fixture = _family(siblings: 14, children: 14);
        final session = _Session(fixture.document);
        await _mount(
          tester,
          session,
          size: portrait ? const Size(430, 900) : const Size(1100, 700),
        );
        final main = tester.widget<SingleChildScrollView>(
          find.byKey(const Key('tree-main-scroll')),
        );
        expect(
          main.scrollDirection,
          portrait ? Axis.horizontal : Axis.vertical,
        );
        final focusLevel = _levelOf(fixture, rootTreePersonId);
        final childLevel = _levelOf(fixture, 'Ребёнок-0');
        final focusScroll = _levelController(tester, focusLevel);
        final childScroll = _levelController(tester, childLevel);
        expect(focusScroll.position.maxScrollExtent, greaterThan(0));
        expect(childScroll.position.maxScrollExtent, greaterThan(0));
        expect(identical(focusScroll, childScroll), isFalse);
        final childBefore = childScroll.offset;
        final mainBefore = main.controller!.offset;
        final painter = _linkPainter(tester);
        focusScroll.jumpTo(focusScroll.offset == 0 ? 100 : 0);
        await tester.pump();
        expect(childScroll.offset, childBefore);
        expect(main.controller!.offset, mainBefore);
        expect(identical(_linkPainter(tester), painter), isTrue);

        final userOffset = focusScroll.offset;
        session.changed();
        await tester.pumpAndSettle();
        expect(focusScroll.offset, userOffset);
        expect(childScroll.offset, childBefore);
        expect(identical(_linkPainter(tester), painter), isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} wheel follows physical axes without moving other generations or bubbling at edges',
      (tester) async {
        final fixture = _family(siblings: 14, children: 14);
        await _mount(
          tester,
          _Session(fixture.document),
          size: portrait ? const Size(430, 900) : const Size(1100, 700),
        );
        final main = _mainController(tester);
        expect(main.position.maxScrollExtent, greaterThan(0));
        main.jumpTo(main.position.maxScrollExtent / 2);
        final levels = {
          for (final level in _layoutOf(fixture).levels)
            level.index: _levelController(tester, level.index),
        };
        final index = _levelOf(fixture, rootTreePersonId);
        final hovered = levels[index]!;
        hovered.jumpTo(hovered.position.maxScrollExtent / 2);
        await tester.pump();
        final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
        Offset hitPosition() {
          final area = tester
              .getRect(find.byKey(ValueKey('tree-level-scroll-$index')))
              .intersect(canvas);
          expect(area.width, greaterThan(0));
          expect(area.height, greaterThan(0));
          return area.center;
        }

        final otherOffsets = {
          for (final entry in levels.entries)
            if (entry.key != index) entry.key: entry.value.offset,
        };
        final vertical = portrait ? hovered : main;
        final sideways = portrait ? main : hovered;
        for (final delta in [
          const Offset(0, 32),
          const Offset(0, -24),
          const Offset(28, 0),
          const Offset(-20, 0),
          const Offset(12, 16),
        ]) {
          final verticalBefore = vertical.offset;
          final sidewaysBefore = sideways.offset;
          await _wheel(tester, position: hitPosition(), delta: delta);
          expect(
            vertical.offset,
            closeTo(
              (verticalBefore + delta.dy).clamp(
                0,
                vertical.position.maxScrollExtent,
              ),
              .1,
            ),
          );
          expect(
            sideways.offset,
            closeTo(
              (sidewaysBefore + delta.dx).clamp(
                0,
                sideways.position.maxScrollExtent,
              ),
              .1,
            ),
          );
          for (final entry in otherOffsets.entries) {
            expect(levels[entry.key]!.offset, entry.value);
          }
        }
        for (final controller in [vertical, sideways]) {
          final other = identical(controller, vertical) ? sideways : vertical;
          for (final atEnd in [false, true]) {
            controller.jumpTo(atEnd ? controller.position.maxScrollExtent : 0);
            await tester.pump();
            final boundary = controller.offset;
            final otherBefore = other.offset;
            final delta = atEnd ? 96.0 : -96.0;
            await _wheel(
              tester,
              position: hitPosition(),
              delta: identical(controller, vertical)
                  ? Offset(0, delta)
                  : Offset(delta, 0),
            );
            expect(controller.offset, boundary);
            expect(
              other.offset,
              otherBefore,
              reason: 'An edge must not bubble.',
            );
            for (final entry in otherOffsets.entries) {
              expect(levels[entry.key]!.offset, entry.value);
            }
          }
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} primary mouse drag scrolls horizontally without moving other generations',
      (tester) async {
        final fixture = _family(siblings: 14, children: 14);
        await _mount(
          tester,
          _Session(fixture.document),
          size: portrait ? const Size(430, 900) : const Size(1100, 700),
        );
        final main = _mainController(tester);
        main.jumpTo(main.position.maxScrollExtent / 2);
        final levels = {
          for (final level in _layoutOf(fixture).levels)
            level.index: _levelController(tester, level.index),
        };
        final index = _levelOf(fixture, rootTreePersonId);
        final hovered = levels[index]!;
        hovered.jumpTo(hovered.position.maxScrollExtent / 2);
        await tester.pump();
        final before = {
          for (final entry in levels.entries) entry.key: entry.value.offset,
        };
        final mainBefore = main.offset;
        final hitArea = tester
            .getRect(find.byKey(ValueKey('tree-level-scroll-$index')))
            .intersect(tester.getRect(find.byKey(const Key('tree-canvas'))));
        final gesture = await tester.startGesture(
          hitArea.center,
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveBy(const Offset(-24, 0));
        await tester.pump();
        await gesture.moveBy(const Offset(-48, 0));
        await tester.pump();
        if (portrait) {
          expect(main.offset, greaterThan(mainBefore));
          expect(hovered.offset, before[index]);
        } else {
          expect(hovered.offset, greaterThan(before[index]!));
          expect(main.offset, mainBefore);
        }
        for (final entry in before.entries) {
          if (entry.key != index) {
            expect(levels[entry.key]!.offset, entry.value);
          }
        }
        await gesture.up();
        await tester.pumpAndSettle();
        expect(find.byType(PersonBiography), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    if (portrait) {
      testWidgets(
        'portrait middle pan and cross-wheel roundtrip preserve every row during a primary drag at 150%',
        (tester) async {
          final fixture = _family(siblings: 14, children: 14)
            ..add('Прадед', sex: TreeSex.male)
            ..parents('Дед', father: 'Прадед');
          final session = _Session(fixture.document, editingAllowed: true);
          await _mount(tester, session, size: const Size(1000, 1300));
          await _zoomSteps(tester, 5);
          final main = _mainController(tester);
          final levels = {
            for (final level in _layoutOf(fixture).levels)
              level.index: _levelController(tester, level.index),
          };
          final focus = levels[_levelOf(fixture, rootTreePersonId)]!;
          final parent = levels[_levelOf(fixture, 'Мать')]!;
          final parentNotifications = <(double, SchedulerPhase)>[];
          void recordParentOffset() => parentNotifications.add((
            parent.offset,
            tester.binding.schedulerPhase,
          ));
          parent.addListener(recordParentOffset);
          addTearDown(() => parent.removeListener(recordParentOffset));
          final beforeMiddle = {
            for (final id in fixture.document.people.keys)
              id: tester.getRect(_person(id)),
          };
          final middle = await tester.startGesture(
            tester.getCenter(_person(rootTreePersonId)),
            kind: PointerDeviceKind.mouse,
            buttons: kMiddleMouseButton,
          );
          await middle.moveBy(const Offset(-64, -52));
          await tester.pump();
          await middle.up();
          await tester.pumpAndSettle();
          _expectTranslatedCards(tester, beforeMiddle, const Offset(-64, -52));
          expect(
            parentNotifications,
            contains((parent.offset, SchedulerPhase.postFrameCallbacks)),
            reason:
                'Changed-dimension correction must publish the final offset '
                'after layout so later outer drags retain row semantics.',
          );
          expect(
            parentNotifications.any(
              (entry) => entry.$2 == SchedulerPhase.persistentCallbacks,
            ),
            isFalse,
            reason: 'Scroll listeners must not be notified during layout.',
          );
          final beforeWheel = {
            for (final id in fixture.document.people.keys)
              id: tester.getRect(_person(id)),
          };
          await _wheel(
            tester,
            position: tester.getCenter(_person(rootTreePersonId)),
            delta: const Offset(0, -24),
          );
          final applied =
              tester.getCenter(_person(rootTreePersonId)).dy -
              beforeWheel[rootTreePersonId]!.center.dy;
          expect(applied, closeTo(24, .1));
          await _wheel(
            tester,
            position: tester.getCenter(_person(rootTreePersonId)),
            delta: Offset(0, applied),
          );
          _expectTranslatedCards(tester, beforeWheel, Offset.zero);
          final beforePrimary = {
            for (final id in fixture.document.people.keys)
              id: tester.getRect(_person(id)),
          };
          final mainBefore = main.offset;
          final rowOffsets = {
            for (final entry in levels.entries) entry.key: entry.value.offset,
          };
          final focusBefore = focus.offset;
          final primary = await tester.startGesture(
            tester.getCenter(_person(rootTreePersonId)),
            kind: PointerDeviceKind.mouse,
          );
          for (var step = 1; step <= 12; step++) {
            await primary.moveBy(
              const Offset(-70 / 12, 0),
              timeStamp: Duration(milliseconds: step * 16),
            );
            await tester.pump(const Duration(milliseconds: 16));
            _expectTranslatedCards(
              tester,
              beforePrimary,
              Offset(-(main.offset - mainBefore) * 1.5, 0),
            );
            for (final entry in rowOffsets.entries) {
              expect(levels[entry.key]!.offset, closeTo(entry.value, .1));
            }
          }
          expect(main.offset, greaterThan(mainBefore));
          expect(focus.offset, focusBefore);
          await primary.up(timeStamp: const Duration(milliseconds: 208));
          await tester.pumpAndSettle();
          _expectTranslatedCards(
            tester,
            beforePrimary,
            Offset(-(main.offset - mainBefore) * 1.5, 0),
          );
          expect(_zoomLabel(tester), '150%');
          expect(find.byType(PersonBiography), findsNothing);
          expect(session.operations, isEmpty);
          // Disposing after queuing another changed-dimension correction must
          // not leave post-frame offset notifications targeting dead positions.
          final closing = await tester.startGesture(
            tester.getCenter(_person(rootTreePersonId)),
            kind: PointerDeviceKind.mouse,
            buttons: kMiddleMouseButton,
          );
          await closing.moveBy(const Offset(0, -100));
          await closing.up();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final zoomPercent in [100, 200]) {
      for (final cancel in [false, true]) {
        testWidgets(
          '${portrait ? 'portrait' : 'landscape'} middle drag rigidly translates every generation at $zoomPercent% beyond bounds and ends on ${cancel ? 'cancel' : 'up'}',
          (tester) async {
            final fixture = _family(siblings: 14, children: 14)
              ..add('Прадед', sex: TreeSex.male)
              ..parents('Дед', father: 'Прадед');
            final session = _Session(fixture.document, editingAllowed: true);
            final peopleBefore = fixture.document.people;
            await _mount(
              tester,
              session,
              size: portrait ? const Size(430, 900) : const Size(1100, 700),
            );
            if (zoomPercent == 200) await _zoomSteps(tester, 10);
            final layout = _layoutOf(fixture);
            final main = _mainController(tester);
            final levels = {
              for (final level in layout.levels)
                level.index: _levelController(tester, level.index),
            };
            final singleton = layout.positions['Прадед']!.level;
            expect(
              layout.levels
                  .singleWhere((level) => level.index == singleton)
                  .blocks
                  .expand((block) => block.people),
              hasLength(1),
            );
            // Independent row positions, including opposite bounds and a short
            // grandparent row, must survive a common canvas translation.
            var index = 0;
            for (final row in levels.values) {
              row.jumpTo(switch (index++ % 3) {
                0 => row.position.minScrollExtent,
                1 => row.position.maxScrollExtent,
                _ => row.position.maxScrollExtent / 2,
              });
            }
            levels[singleton]!.jumpTo(
              levels[singleton]!.position.minScrollExtent,
            );
            final shortRow = levels[layout.positions['Дед']!.level]!;
            shortRow.jumpTo(shortRow.position.maxScrollExtent);
            main.jumpTo(main.position.maxScrollExtent / 2);
            await tester.pump();
            // Start on an unselected card to expose accidental selection/taps.
            await Scrollable.ensureVisible(
              tester.element(_person('Сестра-0')),
              alignment: .5,
            );
            await tester.pumpAndSettle();
            final start = tester.getCenter(_person('Сестра-0'));
            expect(
              tester
                  .getRect(find.byKey(const Key('tree-canvas')))
                  .contains(start),
              isTrue,
            );
            final before = {
              for (final id in fixture.document.people.keys)
                id: tester.getRect(_person(id)),
            };
            final relativeBefore = _relativeLogicalCrossOffsets(
              tester,
              layout,
              portrait: portrait,
            );
            void expectTranslation(Offset delta) {
              _expectTranslatedCards(tester, before, delta);
              final relativeAfter = _relativeLogicalCrossOffsets(
                tester,
                layout,
                portrait: portrait,
              );
              for (final entry in relativeBefore.entries) {
                expect(relativeAfter[entry.key], closeTo(entry.value, .2));
              }
              for (final controller in [main, ...levels.values]) {
                expect(
                  controller.offset,
                  greaterThanOrEqualTo(
                    controller.position.minScrollExtent - .01,
                  ),
                );
                expect(
                  controller.offset,
                  lessThanOrEqualTo(controller.position.maxScrollExtent + .01),
                );
              }
            }

            final gesture = await tester.startGesture(
              start,
              kind: PointerDeviceKind.mouse,
              buttons: kMiddleMouseButton,
            );
            // Pointer packets before the next frame must accumulate, not each
            // restart from the last painted scroll geometry.
            await gesture.moveBy(const Offset(-11, -13));
            await gesture.moveBy(const Offset(-7, -5));
            await gesture.moveBy(const Offset(-6, -14));
            await tester.pump();
            var delta = const Offset(-24, -32);
            expectTranslation(delta);
            for (final movement in [
              const Offset(10000, 10000),
              const Offset(-20000, -20000),
            ]) {
              await gesture.moveBy(movement);
              await tester.pump();
              delta += movement;
              expectTranslation(delta);
            }
            if (cancel) {
              await gesture.cancel();
            } else {
              await gesture.up();
            }
            await tester.pumpAndSettle();
            expectTranslation(delta);
            await gesture.moveTo(start);
            await gesture.moveBy(const Offset(20, 16));
            await tester.pumpAndSettle();
            expectTranslation(delta);
            expect(find.byType(PersonBiography), findsNothing);
            final selected = tester.widget<Semantics>(
              find
                  .descendant(
                    of: _person(rootTreePersonId),
                    matching: find.byType(Semantics),
                  )
                  .first,
            );
            expect(
              selected.properties.selected,
              isTrue,
              reason:
                  'A middle drag must not select the card where it started.',
            );
            expect(_zoomLabel(tester), '$zoomPercent%');
            expect(session.operations, isEmpty);
            expect(identical(fixture.document.people, peopleBefore), isTrue);
            expect(tester.takeException(), isNull);
          },
        );
      }

      testWidgets(
        '${portrait ? 'portrait' : 'landscape'} middle drag starts in blank leading canvas padding at $zoomPercent%',
        (tester) async {
          final fixture = _family(siblings: 14, children: 14)
            ..add('Прадед', sex: TreeSex.male)
            ..parents('Дед', father: 'Прадед');
          final session = _Session(fixture.document, editingAllowed: true);
          final peopleBefore = fixture.document.people;
          await _mount(
            tester,
            session,
            size: portrait ? const Size(430, 900) : const Size(1100, 700),
          );
          if (zoomPercent == 200) await _zoomSteps(tester, 10);
          final layout = _layoutOf(fixture);
          final main = _mainController(tester);
          main.jumpTo(main.position.minScrollExtent);
          await tester.pump();
          final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
          final start = portrait
              ? Offset(canvas.left + 8, canvas.center.dy)
              : Offset(canvas.center.dx, canvas.top + 8);
          for (final level in layout.levels) {
            expect(
              tester
                  .getRect(
                    find.byKey(ValueKey('tree-level-scroll-${level.index}')),
                  )
                  .contains(start),
              isFalse,
              reason: 'The gesture must not start in a generation listener.',
            );
          }
          final before = {
            for (final id in fixture.document.people.keys)
              id: tester.getRect(_person(id)),
          };
          final gesture = await tester.startGesture(
            start,
            kind: PointerDeviceKind.mouse,
            buttons: kMiddleMouseButton,
          );
          await gesture.moveBy(const Offset(45, 37));
          await tester.pump();
          _expectTranslatedCards(tester, before, const Offset(45, 37));
          await gesture.moveBy(const Offset(-90, -74));
          await tester.pump();
          _expectTranslatedCards(tester, before, const Offset(-45, -37));
          await gesture.up();
          await tester.pumpAndSettle();
          _expectTranslatedCards(tester, before, const Offset(-45, -37));
          expect(find.byType(PersonBiography), findsNothing);
          expect(
            tester
                .widget<Semantics>(
                  find
                      .descendant(
                        of: _person(rootTreePersonId),
                        matching: find.byType(Semantics),
                      )
                      .first,
                )
                .properties
                .selected,
            isTrue,
          );
          expect(_zoomLabel(tester), '$zoomPercent%');
          expect(session.operations, isEmpty);
          expect(identical(fixture.document.people, peopleBefore), isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} middle pan stops when its button is released while another remains held',
      (tester) async {
        final fixture = _family(siblings: 1);
        final session = _Session(fixture.document, editingAllowed: true);
        await _mount(
          tester,
          session,
          size: portrait ? const Size(430, 900) : const Size(1100, 700),
        );
        final before = {
          for (final id in fixture.document.people.keys)
            id: tester.getRect(_person(id)),
        };
        final start = tester.getCenter(_person(rootTreePersonId));
        final pointer = TestPointer(41, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(
          pointer.down(start, buttons: kMiddleMouseButton),
        );
        await tester.sendEventToBinding(
          pointer.move(
            start + const Offset(-24, -32),
            buttons: kMiddleMouseButton | kSecondaryMouseButton,
          ),
        );
        await tester.pump();
        _expectTranslatedCards(tester, before, const Offset(-24, -32));
        await tester.sendEventToBinding(
          pointer.move(
            start + const Offset(-48, -64),
            buttons: kSecondaryMouseButton,
          ),
        );
        await tester.pump();
        _expectTranslatedCards(tester, before, const Offset(-24, -32));
        await tester.sendEventToBinding(
          pointer.move(start + const Offset(-72, -96)),
        );
        await tester.pump();
        _expectTranslatedCards(tester, before, const Offset(-24, -32));
        await tester.sendEventToBinding(pointer.up());
        await tester.pumpAndSettle();
        _expectTranslatedCards(tester, before, const Offset(-24, -32));
        expect(find.byType(PersonBiography), findsNothing);
        expect(session.operations, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} secondary tap selects the clicked person and opens their biography',
      (tester) async {
        final fixture = _family(siblings: 1);
        await _mount(
          tester,
          _Session(fixture.document),
          size: portrait ? const Size(430, 900) : const Size(1100, 850),
        );
        _expectInside(
          tester.getRect(_person('Сестра-0')),
          tester.getRect(find.byKey(const Key('tree-canvas'))),
        );
        await tester.tap(
          _person('Сестра-0'),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        final biography = tester.widget<PersonBiography>(
          find.byType(PersonBiography),
        );
        expect(biography.personId, 'Сестра-0');
        expect(biography.fullScreen, portrait);
        expect(
          find.byKey(
            Key(portrait ? 'tree-biography-route' : 'tree-biography-panel'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('biography-close')));
        await tester.pumpAndSettle();
        expect(find.byType(PersonBiography), findsNothing);
        expect(
          _nodeSemantics(tester, 'Сестра-0').flagsCollection.isSelected,
          Tristate.isTrue,
        );
        expect(
          _nodeSemantics(tester, 'Я').flagsCollection.isSelected,
          Tristate.isFalse,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final portrait in [true, false]) {
    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} aligned Olga and Anastasia only swap fathers without moving the parent viewport at 100 and 150 percent',
      (tester) async {
        final fixture = _olgaAnastasiaFamily();
        final session = _Session(fixture.document, editingAllowed: true);
        final peopleBefore = fixture.document.people;
        await _mount(
          tester,
          session,
          initialPersonId: rootTreePersonId,
          size: portrait ? const Size(1500, 2200) : const Size(2200, 1500),
        );
        for (final zoom in [100, 150]) {
          if (zoom == 150) await _zoomSteps(tester, 5);
          await tester.tap(find.byKey(const Key('tree-align-all')));
          await tester.pumpAndSettle();
          for (final panned in [false, true]) {
            if (panned) {
              final pan = await tester.startGesture(
                tester.getCenter(_person(rootTreePersonId)),
                kind: PointerDeviceKind.mouse,
                buttons: kMiddleMouseButton,
              );
              await pan.moveBy(
                portrait ? const Offset(12, -36) : const Offset(-36, 12),
              );
              await pan.up();
              await tester.pumpAndSettle();
              final parent = _levelController(
                tester,
                _levelOf(fixture, 'natalia'),
              );
              parent.jumpTo(parent.offset + 20);
              await tester.pump();
            }
            final offsets = {
              for (final level in _layoutOf(fixture).levels)
                level.index: _levelController(tester, level.index).offset,
            };
            final mainOffset = _mainController(tester).offset;
            for (var cycle = 0; cycle < 3; cycle++) {
              for (final selected in ['anastasia', rootTreePersonId]) {
                final before = {
                  for (final id in fixture.document.people.keys)
                    id: tester.getRect(_person(id)),
                };
                final siblingBlockBefore = tester.getRect(
                  _blockFor(fixture, 'natalia'),
                );
                final canvas = tester.getRect(
                  find.byKey(const Key('tree-canvas')),
                );
                for (final rect in before.values) {
                  _expectInside(rect, canvas);
                }
                await tester.tap(_person(selected));
                await tester.pumpAndSettle();
                final reason =
                    '$zoom%, panned $panned, cycle $cycle, selected $selected';
                final layout = _layoutOf(fixture, selectedId: selected);
                final row = layout.levels.singleWhere(
                  (level) => level.index == layout.positions['natalia']!.level,
                );
                expect(
                  row.blocks.expand((block) => block.people).map((p) => p.id),
                  selected == rootTreePersonId
                      ? ['veronika', 'natalia', 'oleg', 'roman', 'nekto']
                      : ['veronika', 'natalia', 'nekto', 'roman', 'oleg'],
                  reason: reason,
                );
                _expectCanonicalRowGeometry(tester, layout, portrait: portrait);
                expect(
                  tester.getRect(_blockFor(fixture, 'natalia')),
                  siblingBlockBefore,
                  reason: '$reason moved the shared maternal sibling block.',
                );
                for (final entry in before.entries) {
                  final expected = entry.key == 'oleg'
                      ? before['nekto']!
                      : entry.key == 'nekto'
                      ? before['oleg']!
                      : entry.value;
                  final actual = tester.getRect(_person(entry.key));
                  expect(
                    (actual.topLeft - expected.topLeft).distance,
                    lessThan(.2),
                    reason: '$reason moved ${entry.key} beyond its cold slot.',
                  );
                  expect(actual.size, expected.size);
                  _expectInside(actual, canvas);
                }
                final mother = tester.getRect(_person('natalia'));
                final father = tester.getRect(
                  _person(selected == rootTreePersonId ? 'oleg' : 'nekto'),
                );
                expect(
                  portrait
                      ? father.top - mother.bottom
                      : father.left - mother.right,
                  closeTo(2 * layout.gap * zoom / 100, .2),
                  reason: '$reason must join literal parent cards.',
                );
                for (final entry in offsets.entries) {
                  expect(
                    _levelController(tester, entry.key).offset,
                    closeTo(entry.value, .001),
                    reason: '$reason scrolled generation ${entry.key}.',
                  );
                }
                expect(_mainController(tester).offset, mainOffset);
                expect(_zoomLabel(tester), '$zoom%');
              }
            }
            final beforeRapidSelection = {
              for (final id in fixture.document.people.keys)
                id: tester.getRect(_person(id)),
            };
            for (final selected in ['anastasia', rootTreePersonId]) {
              tester
                  .widget<InkWell>(
                    find.descendant(
                      of: _person(selected),
                      matching: find.byType(InkWell),
                    ),
                  )
                  .onTap!();
            }
            await tester.pumpAndSettle();
            _expectTranslatedCards(tester, beforeRapidSelection, Offset.zero);
            for (final entry in offsets.entries) {
              expect(
                _levelController(tester, entry.key).offset,
                closeTo(entry.value, .001),
              );
            }
            expect(_mainController(tester).offset, mainOffset);
          }
        }
        expect(session.operations, isEmpty);
        expect(identical(fixture.document.people, peopleBefore), isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} adding Shrek and collateral children never lifts Oleg parents out of their generation',
      (tester) async {
        final fixture = _olgaAnastasiaFamily()
          ..add('oldest')
          ..add('older')
          ..add('test-ancestor')
          ..parents('older', father: 'oldest')
          ..parents('test-ancestor', father: 'older')
          ..parents('lydia', father: 'test-ancestor')
          ..add('oleg-father', sex: TreeSex.male)
          ..add('oleg-mother', sex: TreeSex.female)
          ..parents('oleg', father: 'oleg-father', mother: 'oleg-mother');
        final session = _Session(fixture.document, editingAllowed: true);
        await _mount(
          tester,
          session,
          initialPersonId: 'oleg-father',
          size: portrait ? const Size(1500, 2200) : const Size(2200, 1500),
        );
        final baseline = _layoutOf(fixture);
        final originalRanks = {
          for (final entry in baseline.positions.entries)
            entry.key: entry.value.level,
        };
        final originalLinks = baseline.links
            .map((link) => (link.parentId, link.childId))
            .toSet();
        var selected = 'oleg-father';
        var mode = TreeTrunkMode.both;
        final linkedChildren = <String>[];
        double main(String id) {
          final center = tester.getCenter(_person(id));
          return portrait ? center.dx : center.dy;
        }

        void check(String reason) {
          final layout = _layoutOf(fixture, selectedId: selected, mode: mode);
          for (final entry in originalRanks.entries) {
            expect(
              layout.positions[entry.key]!.level,
              entry.value,
              reason: '$reason must not rerank existing ${entry.key}.',
            );
          }
          final olegRank = originalRanks['oleg']!;
          for (final id in ['oleg-father', 'oleg-mother']) {
            expect(layout.positions[id]!.level, olegRank - 1, reason: reason);
            expect(main(id), closeTo(main('gennady'), .2), reason: reason);
          }
          for (final id in linkedChildren) {
            expect(layout.positions[id]!.level, olegRank, reason: reason);
            expect(main(id), closeTo(main('oleg'), .2), reason: reason);
            expect(session.tree.person(id)!.birthDate, isNull);
          }
          expect(
            main('oleg'),
            greaterThan(main('oleg-father')),
            reason: reason,
          );
          expect(
            layout.links.map((link) => (link.parentId, link.childId)).toSet(),
            containsAll(originalLinks),
            reason: reason,
          );
          _expectCanonicalRowGeometry(tester, layout, portrait: portrait);
          expect(tester.takeException(), isNull, reason: reason);
        }

        Future<void> apply(TreeOperation operation, String reason) async {
          await session.applyTreeOperation(operation);
          await tester.pumpAndSettle();
          check(reason);
        }

        check('before adding Shrek');
        await apply(
          session.tree.createPerson('shrek', name: 'Шрек', sex: TreeSex.male),
          'created disconnected Shrek',
        );
        linkedChildren.add('shrek');
        await apply(
          session.tree.setValue('shrek', 'fatherId', 'oleg-father'),
          'linked Shrek to the selected father',
        );
        await apply(
          session.tree.setValue('shrek', 'motherId', 'oleg-mother'),
          'linked Shrek to both parents',
        );
        await apply(
          session.tree.createPerson('maternal-child', name: 'Ребёнок матери'),
          'created another disconnected child',
        );
        linkedChildren.add('maternal-child');
        await apply(
          session.tree.setValue('maternal-child', 'motherId', 'oleg-mother'),
          'linked another shallow child to the mother',
        );
        await apply(
          session.tree.createPerson('shrek-child', name: 'Ребёнок Шрека'),
          'created a disconnected next-generation child',
        );
        await apply(
          session.tree.setValue('shrek-child', 'fatherId', 'shrek'),
          'extended the collateral branch',
        );
        final savedPeople = session.tree.people;
        final writes = session.operations.length;
        for (final nextMode in TreeTrunkMode.values) {
          mode = nextMode;
          await _chooseMode(tester, mode);
          for (final id in [
            'oleg-father',
            'shrek',
            'oleg',
            rootTreePersonId,
            'oleg-mother',
            'maternal-child',
          ]) {
            selected = id;
            await _selectPerson(tester, selected);
            check('${mode.name}, selected $selected');
          }
        }
        expect(session.operations, hasLength(7));
        expect(session.operations, hasLength(writes));
        expect(identical(session.tree.people, savedPeople), isTrue);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} sibling order is strict by missing date then birth date then name across focus and modes',
      (tester) async {
        final fixture = _family(siblings: 0, children: 1)
          ..name(rootTreePersonId, 'Виктор');
        for (final entry in {
          'z-anna': 'Анна',
          'a-boris': 'Борис',
          'known-oldest': 'Алексей',
          'z-nina': 'Нина',
          'a-yana': 'Яна',
        }.entries) {
          fixture
            ..add(entry.key)
            ..name(entry.key, entry.value)
            ..parents(entry.key, father: 'Отец', mother: 'Мать');
        }
        for (final entry in {
          'known-oldest': '1900-01-01',
          'z-nina': '2000-01-01',
          'a-yana': '2000-01-01',
        }.entries) {
          fixture.apply(
            fixture.document.setValue(entry.key, 'birthDate', entry.value),
          );
        }
        final session = _Session(fixture.document);
        final people = fixture.document.people;
        await _mount(
          tester,
          session,
          size: portrait ? const Size(1500, 2200) : const Size(2200, 1500),
        );
        final expected = [
          'z-anna',
          'a-boris',
          rootTreePersonId,
          'known-oldest',
          'z-nina',
          'a-yana',
        ];
        for (final mode in [
          TreeTrunkMode.both,
          TreeTrunkMode.mother,
          TreeTrunkMode.father,
          TreeTrunkMode.both,
        ]) {
          await _chooseMode(tester, mode);
          for (final selected in [...expected, 'Партнёр', rootTreePersonId]) {
            await _selectPerson(tester, selected);
            final layout = _layoutOf(fixture, selectedId: selected, mode: mode);
            final block = layout.levels
                .expand((level) => level.blocks)
                .singleWhere(
                  (block) => block.people.any(
                    (person) => person.id == rootTreePersonId,
                  ),
                );
            expect(
              block.people.map((person) => person.id),
              expected,
              reason: '${mode.name}, $selected: selection is not a sort key.',
            );
            for (var i = 1; i < expected.length; i++) {
              expect(
                _cross(tester.getCenter(_person(expected[i])), portrait) -
                    _cross(
                      tester.getCenter(_person(expected[i - 1])),
                      portrait,
                    ),
                closeTo(layout.nodeExtent + layout.gap, .2),
              );
            }
            _expectCanonicalRowGeometry(tester, layout, portrait: portrait);
            expect(tester.takeException(), isNull);
          }
        }
        expect(session.operations, isEmpty);
        expect(identical(fixture.document.people, people), isTrue);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} partner proximity preserves sibling chronology except actual two-line ancestor parent seams',
      (tester) async {
        final fixture = _coParentFamily();
        final session = _Session(fixture.document);
        final people = fixture.document.people;
        await _mount(
          tester,
          session,
          size: portrait ? const Size(1500, 2200) : const Size(2200, 1500),
        );
        for (final mode in TreeTrunkMode.values) {
          await _chooseMode(tester, mode);
          for (final selected in [
            rootTreePersonId,
            'Партнёр',
            'Ребёнок-0',
            rootTreePersonId,
          ]) {
            await _selectPerson(tester, selected);
            final layout = _layoutOf(fixture, selectedId: selected, mode: mode);
            final block = layout.levels
                .expand((level) => level.blocks)
                .singleWhere(
                  (block) =>
                      block.people.any((person) => person.id == 'Партнёр'),
                );
            final actualParentSeam =
                mode == TreeTrunkMode.both && selected == 'Ребёнок-0';
            final expected = actualParentSeam
                ? ['Сестра партнёра', 'Партнёр']
                : ['Партнёр', 'Сестра партнёра'];
            expect(
              block.people.map((person) => person.id),
              expected,
              reason:
                  '${mode.name}, $selected: only real ancestor seams may reorder siblings.',
            );
            expect(
              _cross(tester.getCenter(_person(expected.last)), portrait) -
                  _cross(tester.getCenter(_person(expected.first)), portrait),
              closeTo(layout.nodeExtent + layout.gap, .2),
            );
            if (actualParentSeam) {
              final mother = tester.getRect(_person('Партнёр'));
              final father = tester.getRect(_person(rootTreePersonId));
              expect(
                portrait
                    ? father.top - mother.bottom
                    : father.left - mother.right,
                closeTo(2 * layout.gap, .2),
              );
            }
            _expectCanonicalRowGeometry(tester, layout, portrait: portrait);
            expect(tester.takeException(), isNull);
          }
        }
        expect(session.operations, isEmpty);
        expect(identical(fixture.document.people, people), isTrue);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} both-line ancestor blocks exclude collateral intruders on every parental level',
      (tester) async {
        final fixture = _ancestorCorridorFamily();
        final session = _Session(fixture.document);
        final people = fixture.document.people;
        final ranks = {
          for (final entry in _layoutOf(fixture).positions.entries)
            entry.key: entry.value.level,
        };
        Set<String> ancestorsOf(String selected) {
          final result = <String>{};
          final pending = [selected];
          while (pending.isNotEmpty) {
            final person = people[pending.removeLast()]!;
            for (final parent in [person.motherId, person.fatherId]) {
              if (parent != null && result.add(parent)) pending.add(parent);
            }
          }
          return result;
        }

        await _mount(
          tester,
          session,
          initialPersonId: 'nikita',
          size: portrait ? const Size(1700, 2400) : const Size(2400, 1700),
        );
        for (final zoom in [100, 150]) {
          if (zoom == 150) await _zoomSteps(tester, 5);
          final renderedBySelection = <String, Set<(String, String)>>{};
          for (final mode in [
            TreeTrunkMode.both,
            TreeTrunkMode.mother,
            TreeTrunkMode.father,
            TreeTrunkMode.both,
          ]) {
            await _chooseMode(tester, mode);
            for (final selected in [
              'nikita',
              rootTreePersonId,
              'anastasia',
              'nikita',
            ]) {
              await _selectPerson(tester, selected);
              final layout = _layoutOf(
                fixture,
                selectedId: selected,
                mode: mode,
              );
              final ancestors = ancestorsOf(selected);
              final reason = '$zoom%, ${mode.name}, $selected';
              for (final level in layout.levels) {
                final ancestorSlots = [
                  for (var i = 0; i < level.blocks.length; i++)
                    if (level.blocks[i].people.any(
                      (person) => ancestors.contains(person.id),
                    ))
                      i,
                ];
                if (mode == TreeTrunkMode.both && ancestorSlots.length > 1) {
                  expect(
                    ancestorSlots.last - ancestorSlots.first + 1,
                    ancestorSlots.length,
                    reason: '$reason: no collateral block may split ancestors.',
                  );
                }
                if (mode != TreeTrunkMode.both) {
                  for (final block in level.blocks) {
                    final canonical = block.people.toList()
                      ..sort(compareTreePeopleByBirth);
                    expect(
                      block.people.map((person) => person.id),
                      canonical.map((person) => person.id),
                      reason:
                          '$reason: single-mode sibling order is untouched.',
                    );
                  }
                }
              }
              if (mode == TreeTrunkMode.both) {
                for (final child in [selected, ...ancestors]) {
                  final person = people[child]!;
                  if (person.motherId == null || person.fatherId == null) {
                    continue;
                  }
                  final mother = layout.positions[person.motherId]!;
                  final father = layout.positions[person.fatherId]!;
                  if (mother.level != father.level) continue;
                  final maternalCard = tester.getRect(
                    _person(person.motherId!),
                  );
                  final paternalCard = tester.getRect(
                    _person(person.fatherId!),
                  );
                  expect(
                    portrait
                        ? paternalCard.top - maternalCard.bottom
                        : paternalCard.left - maternalCard.right,
                    closeTo(2 * layout.gap * zoom / 100, .2),
                    reason: '$reason: actual parent seams remain adjacent.',
                  );
                }
              }
              expect(
                {
                  for (final entry in layout.positions.entries)
                    entry.key: entry.value.level,
                },
                ranks,
                reason: '$reason: corridor placement cannot alter generations.',
              );
              final rendered = _renderedConnections(
                tester,
                layout,
                portrait: portrait,
              );
              expect(
                rendered,
                renderedBySelection.putIfAbsent(selected, () => rendered),
                reason: '$reason: modes do not change relationship targets.',
              );
              _expectCanonicalRowGeometry(tester, layout, portrait: portrait);
              expect(session.operations, isEmpty);
              expect(identical(fixture.document.people, people), isTrue);
              expect(tester.takeException(), isNull);
            }
          }
        }
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} common descendant branch sides survive every mode and ancestor selection at 100 and 150 percent',
      (tester) async {
        final fixture = _olgaAnastasiaFamily()
          ..add('valentina', sex: TreeSex.female)
          ..name('valentina', 'Валентина')
          ..parents('roman', mother: 'valentina');
        // The paternal grandmother is older, but must not cross the maternal
        // grandfather's route to their nearest common descendant, Nikita.
        fixture.apply(
          fixture.document.setValue('valentina', 'birthDate', '1920-01-01'),
        );
        final session = _Session(fixture.document, editingAllowed: true);
        final peopleBefore = fixture.document.people;
        final realLinks = _layoutOf(
          fixture,
        ).links.map((link) => (link.parentId, link.childId)).toSet();
        await _mount(
          tester,
          session,
          initialPersonId: 'valentina',
          size: portrait ? const Size(1500, 2200) : const Size(2200, 1500),
        );
        final renderedBySelection = <String, Set<(String, String)>>{};
        for (final zoom in [100, 150]) {
          if (zoom == 150) await _zoomSteps(tester, 5);
          for (final mode in [
            TreeTrunkMode.both,
            TreeTrunkMode.father,
            TreeTrunkMode.mother,
            TreeTrunkMode.both,
          ]) {
            await _chooseMode(tester, mode);
            for (final selected in [
              'valentina',
              'gennady',
              'roman',
              'nikita',
              rootTreePersonId,
              'valentina',
            ]) {
              await _selectPerson(tester, selected);
              final layout = _layoutOf(
                fixture,
                selectedId: selected,
                mode: mode,
              );
              final reason = '$zoom%, ${mode.name}, selected $selected';
              _expectCanonicalRowGeometry(tester, layout, portrait: portrait);
              for (final (maternal, paternal) in [
                ('lydia', 'gennady'),
                ('lydia', 'valentina'),
                ('gennady', 'valentina'),
                ('natalia', 'oleg'),
                ('natalia', 'nekto'),
                ('veronika', 'roman'),
              ]) {
                expect(
                  layout.positions[maternal]!.level,
                  layout.positions[paternal]!.level,
                  reason: reason,
                );
                expect(
                  _cross(tester.getCenter(_person(maternal)), portrait),
                  lessThan(
                    _cross(tester.getCenter(_person(paternal)), portrait),
                  ),
                  reason:
                      '$reason: $maternal must precede $paternal by their shared descendant branches, not sex or birth.',
                );
              }
              final sisters = layout.levels
                  .singleWhere(
                    (level) =>
                        level.index == layout.positions['natalia']!.level,
                  )
                  .blocks
                  .singleWhere(
                    (block) => block.id == layout.positions['natalia']!.blockId,
                  );
              expect(sisters.people.map((person) => person.id).toSet(), {
                'natalia',
                'veronika',
              });
              expect(
                (_cross(tester.getCenter(_person('natalia')), portrait) -
                        _cross(tester.getCenter(_person('veronika')), portrait))
                    .abs(),
                closeTo((layout.nodeExtent + layout.gap) * zoom / 100, .2),
                reason: '$reason must keep the full-sibling block contiguous.',
              );
              final person = fixture.document.person(selected)!;
              if (mode == TreeTrunkMode.both &&
                  person.motherId != null &&
                  person.fatherId != null) {
                final mother = tester.getRect(_person(person.motherId!));
                final father = tester.getRect(_person(person.fatherId!));
                expect(
                  portrait
                      ? father.top - mother.bottom
                      : father.left - mother.right,
                  closeTo(2 * layout.gap * zoom / 100, .2),
                  reason:
                      '$reason must retain literal selected-parent neighbors.',
                );
              }
              expect(
                layout.links
                    .map((link) => (link.parentId, link.childId))
                    .toSet(),
                realLinks,
                reason: '$reason must not invent or change genealogical edges.',
              );
              final rendered = _renderedConnections(
                tester,
                layout,
                portrait: portrait,
              );
              expect(
                rendered,
                renderedBySelection.putIfAbsent(selected, () => rendered),
                reason: '$reason must retain mode-independent displayed links.',
              );
              expect(tester.takeException(), isNull, reason: reason);
            }
          }
        }
        expect(session.operations, isEmpty);
        expect(identical(fixture.document.people, peopleBefore), isTrue);
      },
    );

    for (final brightness in Brightness.values) {
      testWidgets(
        '${portrait ? 'portrait' : 'landscape'} ${brightness.name} all-mode selected partners precede sibling partners without changing their visual treatment',
        (tester) async {
          final fixture = _partnerProximityFamily();
          final session = _Session(fixture.document);
          final people = fixture.document.people;
          final original = _layoutOf(fixture, selectedId: 'natalia');
          final ranks = {
            for (final entry in original.positions.entries)
              entry.key: entry.value.level,
          };
          final links = original.links
              .map((link) => (link.parentId, link.childId))
              .toSet();
          await _mount(
            tester,
            session,
            initialPersonId: 'natalia',
            brightness: brightness,
            size: portrait ? const Size(1700, 2500) : const Size(2500, 1700),
          );
          final distantFilter = _filterOf(tester, 'roman');
          for (final zoom in [100, 150]) {
            if (zoom == 150) await _zoomSteps(tester, 5);
            for (final mode in TreeTrunkMode.values) {
              await _chooseMode(tester, mode);
              for (final selected in ['natalia', 'veronika', 'natalia']) {
                await _selectPerson(tester, selected);
                final layout = _layoutOf(
                  fixture,
                  selectedId: selected,
                  mode: mode,
                );
                final reason = '$zoom%, ${mode.name}, $selected';
                final blocks = layout.levels
                    .singleWhere(
                      (level) =>
                          level.index == layout.positions[selected]!.level,
                    )
                    .blocks;
                int slot(String id) => blocks.indexWhere(
                  (block) => block.id == layout.positions[id]!.blockId,
                );
                final ownPartners = selected == 'natalia'
                    ? ['oleg', 'nekto']
                    : ['roman'];
                final siblingPartners = selected == 'natalia'
                    ? ['roman']
                    : ['oleg', 'nekto'];
                final ownSlots = [
                  slot(selected),
                  for (final id in ownPartners) slot(id),
                ]..sort();
                expect(
                  ownSlots.last - ownSlots.first + 1,
                  ownSlots.length,
                  reason:
                      '$reason: sibling partners cannot split own partners.',
                );
                final familySlots = [
                  ...ownSlots,
                  for (final id in siblingPartners) slot(id),
                ]..sort();
                expect(
                  familySlots.last - familySlots.first + 1,
                  familySlots.length,
                  reason:
                      '$reason: unrelated context must stay outside the family cluster.',
                );
                expect(
                  blocks[slot('natalia')].people.map((person) => person.id),
                  ['veronika', 'natalia'],
                  reason: '$reason: proximity cannot reorder sisters.',
                );
                expect(
                  blocks[slot('roman')].people.map((person) => person.id),
                  ['roman', 'roman-sister'],
                  reason:
                      '$reason: a sibling partner moves with their whole block.',
                );
                for (var i = familySlots.first; i < familySlots.last; i++) {
                  final before = tester.getRect(
                    _person(blocks[i].people.last.id),
                  );
                  final after = tester.getRect(
                    _person(blocks[i + 1].people.first.id),
                  );
                  expect(
                    portrait
                        ? after.top - before.bottom
                        : after.left - before.right,
                    closeTo(2 * layout.gap * zoom / 100, .2),
                    reason: '$reason: normal block spacing is retained.',
                  );
                }
                for (final id in ownPartners) {
                  expect(_filterFor(id), findsNothing, reason: reason);
                }
                for (final id in [...siblingPartners, 'roman-sister']) {
                  expect(_filterOf(tester, id), distantFilter, reason: reason);
                  expect(layout.positions[id]!.emphasis, TreeEmphasis.distant);
                }
                for (final id in ['roman', 'oleg', 'nekto']) {
                  expect(
                    _washOf(tester, fixture, id),
                    const Color(0xFF686C65).withValues(alpha: .24),
                    reason:
                        '$reason: proximity must not highlight a partner block.',
                  );
                }
                expect(
                  {
                    for (final entry in layout.positions.entries)
                      entry.key: entry.value.level,
                  },
                  ranks,
                  reason: reason,
                );
                expect(
                  layout.links
                      .map((link) => (link.parentId, link.childId))
                      .toSet(),
                  links,
                  reason: reason,
                );
                _expectCanonicalRowGeometry(tester, layout, portrait: portrait);
                expect(tester.takeException(), isNull, reason: reason);
              }
            }
          }
          expect(session.operations, isEmpty);
          expect(identical(fixture.document.people, people), isTrue);
        },
      );
    }

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} selected Roman and Veronika keep whole partner blocks and real links at 100 and 150 percent',
      (tester) async {
        final fixture = _olgaAnastasiaFamily();
        final session = _Session(fixture.document, editingAllowed: true);
        final peopleBefore = fixture.document.people;
        await _mount(
          tester,
          session,
          initialPersonId: 'roman',
          size: portrait ? const Size(1500, 2200) : const Size(2200, 1500),
        );
        const realLinks = <(String, String)>{
          ('oleg', rootTreePersonId),
          ('natalia', rootTreePersonId),
          ('nekto', 'anastasia'),
          ('natalia', 'anastasia'),
          ('gennady', 'natalia'),
          ('lydia', 'natalia'),
          ('gennady', 'veronika'),
          ('lydia', 'veronika'),
          ('roman', 'nikita'),
          ('veronika', 'nikita'),
        };
        var previousSelected = 'roman';
        for (final zoom in [100, 150]) {
          if (zoom == 150) await _zoomSteps(tester, 5);
          await tester.tap(find.byKey(const Key('tree-align-all')));
          await tester.pumpAndSettle();
          final renderedBySelection = <String, Set<(String, String)>>{};
          for (final mode in [
            TreeTrunkMode.both,
            TreeTrunkMode.father,
            TreeTrunkMode.mother,
            TreeTrunkMode.both,
          ]) {
            await _chooseMode(tester, mode);
            var previousLayout = _layoutOf(
              fixture,
              selectedId: previousSelected,
              mode: mode,
            );
            for (final selected in ['roman', 'veronika', 'roman']) {
              final before = {
                for (final id in fixture.document.people.keys)
                  id: tester.getRect(_person(id)),
              };
              final offsets = {
                for (final level in previousLayout.levels)
                  level.index: _levelController(tester, level.index).offset,
              };
              final mainOffset = _mainController(tester).offset;
              await _selectPerson(tester, selected);
              final layout = _layoutOf(
                fixture,
                selectedId: selected,
                mode: mode,
              );
              final reason = '$zoom%, ${mode.name}, selected $selected';
              final unchangedRows = _expectPreservedOrCanonicalRows(
                tester,
                beforeLayout: previousLayout,
                afterLayout: layout,
                before: before,
                portrait: portrait,
                reason: reason,
              );
              if (mode == TreeTrunkMode.both) {
                final level = layout.positions['roman']!.level;
                final row = layout.levels
                    .singleWhere((generation) => generation.index == level)
                    .blocks
                    .expand((block) => block.people)
                    .map((person) => person.id)
                    .toList();
                expect(
                  row.sublist(
                    row.indexOf('veronika'),
                    row.indexOf('roman') + 1,
                  ),
                  ['veronika', 'natalia', 'roman'],
                  reason:
                      '$reason preserves strict given-name sibling order; partner focus cannot move Natalia.',
                );
                final generation = layout.levels.singleWhere(
                  (generation) => generation.index == level,
                );
                expect(
                  generation.blocks.indexWhere(
                        (block) =>
                            block.id == layout.positions['roman']!.blockId,
                      ) -
                      generation.blocks.indexWhere(
                        (block) =>
                            block.id == layout.positions['veronika']!.blockId,
                      ),
                  1,
                  reason: '$reason must join whole partner blocks.',
                );
                final roman = tester.getRect(_person('roman'));
                final sisterBoundary = tester.getRect(_person('natalia'));
                expect(
                  portrait
                      ? roman.top - sisterBoundary.bottom
                      : roman.left - sisterBoundary.right,
                  closeTo(2 * layout.gap * zoom / 100, .2),
                  reason:
                      '$reason must retain exactly the normal gap at the sibling-block boundary.',
                );
                for (final id in ['oleg', 'nekto']) {
                  final index = row.indexOf(id);
                  expect(
                    index <
                            math.min(
                              row.indexOf('roman'),
                              row.indexOf('veronika'),
                            ) ||
                        index >
                            math.max(
                              row.indexOf('roman'),
                              row.indexOf('veronika'),
                            ),
                    isTrue,
                    reason:
                        '$reason must keep unrelated $id outside the partner gap.',
                  );
                }
                expect(
                  unchangedRows,
                  contains(level),
                  reason: '$reason needs no new sorting of the partner row.',
                );
                if (selected == 'veronika') {
                  final mother = tester.getRect(_person('lydia'));
                  final father = tester.getRect(_person('gennady'));
                  expect(
                    portrait
                        ? father.top - mother.bottom
                        : father.left - mother.right,
                    closeTo(2 * layout.gap * zoom / 100, .2),
                    reason:
                        '$reason must preserve the higher-priority selected-parent seam.',
                  );
                }
                for (final index in unchangedRows) {
                  expect(
                    _levelController(tester, index).offset,
                    closeTo(offsets[index]!, .001),
                    reason: '$reason scrolled unchanged generation $index.',
                  );
                }
              }
              expect(
                _mainController(tester).offset,
                mainOffset,
                reason: reason,
              );
              expect(
                layout.links
                    .map((link) => (link.parentId, link.childId))
                    .toSet(),
                realLinks,
                reason:
                    '$reason must not invent partners or parent-child edges.',
              );
              String block(String id) =>
                  'block:${layout.positions[id]!.blockId}';
              final expectedRendered = <(String, String)>{
                ('roman', block('nikita')),
                ('veronika', block('nikita')),
                if (selected == 'veronika') ...{
                  ('gennady', 'person:veronika'),
                  ('lydia', 'person:veronika'),
                  ('natalia', block(rootTreePersonId)),
                  ('natalia', block('anastasia')),
                },
              };
              final rendered = _renderedConnections(
                tester,
                layout,
                portrait: portrait,
              );
              expect(rendered, expectedRendered, reason: reason);
              expect(
                rendered,
                renderedBySelection.putIfAbsent(selected, () => rendered),
                reason: '$reason must keep mode-independent rendered links.',
              );
              expect(_zoomLabel(tester), '$zoom%');
              previousLayout = layout;
              previousSelected = selected;
            }
          }
        }
        expect(session.operations, isEmpty);
        expect(identical(fixture.document.people, peopleBefore), isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} selected Natalia keeps both partner blocks compact without requiring impossible pairwise card adjacency at 100 and 150 percent',
      (tester) async {
        final fixture = _olgaAnastasiaFamily();
        final session = _Session(fixture.document, editingAllowed: true);
        final peopleBefore = fixture.document.people;
        await _mount(
          tester,
          session,
          initialPersonId: 'natalia',
          size: portrait ? const Size(1500, 2200) : const Size(2200, 1500),
        );
        for (final zoom in [100, 150]) {
          if (zoom == 150) await _zoomSteps(tester, 5);
          await tester.tap(find.byKey(const Key('tree-align-all')));
          await tester.pumpAndSettle();
          // Returning from another partner focus must reproduce the same cold
          // layout. Multiple co-parents need a compact block group, not an
          // impossible assertion that every pair shares a literal card seam.
          for (var cycle = 0; cycle < 2; cycle++) {
            if (cycle > 0) {
              await _selectPerson(tester, 'roman');
              await _selectPerson(tester, 'natalia');
            }
            final layout = _layoutOf(fixture, selectedId: 'natalia');
            _expectCanonicalRowGeometry(tester, layout, portrait: portrait);
            final blocks = layout.levels
                .singleWhere(
                  (level) => level.index == layout.positions['natalia']!.level,
                )
                .blocks;
            final partnerBlocks = {
              for (final id in ['natalia', 'oleg', 'nekto'])
                layout.positions[id]!.blockId,
            };
            final indices = [
              for (var i = 0; i < blocks.length; i++)
                if (partnerBlocks.contains(blocks[i].id)) i,
            ];
            expect(indices, hasLength(3));
            expect(
              indices.last - indices.first,
              2,
              reason:
                  '$zoom%, cycle $cycle must exclude unrelated Roman from the partner cluster.',
            );
            for (var i = indices.first; i < indices.last; i++) {
              final first = tester.getRect(_person(blocks[i].people.last.id));
              final last = tester.getRect(
                _person(blocks[i + 1].people.first.id),
              );
              expect(
                portrait ? last.top - first.bottom : last.left - first.right,
                closeTo(2 * layout.gap * zoom / 100, .2),
              );
            }
            final before = {
              for (final id in fixture.document.people.keys)
                id: tester.getRect(_person(id)),
            };
            final offsets = {
              for (final level in layout.levels)
                level.index: _levelController(tester, level.index).offset,
            };
            final mainOffset = _mainController(tester).offset;
            await _selectPerson(tester, 'natalia');
            _expectTranslatedCards(tester, before, Offset.zero);
            for (final entry in offsets.entries) {
              expect(_levelController(tester, entry.key).offset, entry.value);
            }
            expect(_mainController(tester).offset, mainOffset);
            expect(_zoomLabel(tester), '$zoom%');
          }
        }
        expect(session.operations, isEmpty);
        expect(identical(fixture.document.people, peopleBefore), isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} both-line parent cards override birth order at full-sibling block boundaries',
      (tester) async {
        final fixture = _family(siblings: 1, children: 0)
          ..add('Дядя', sex: TreeSex.male)
          ..parents('Дядя', father: 'Дед', mother: 'Бабушка')
          ..add('Мамин отец', sex: TreeSex.male)
          ..add('Мамина мать', sex: TreeSex.female)
          ..parents('Мать', father: 'Мамин отец', mother: 'Мамина мать')
          ..add('Тётя матери', sex: TreeSex.female)
          ..parents('Тётя матери', father: 'Мамин отец', mother: 'Мамина мать');
        for (final entry in {
          'Дядя': '1960-01-01',
          'Отец': '1970-01-01',
          'Мать': '1960-01-01',
          'Тётя матери': '1970-01-01',
        }.entries) {
          fixture.apply(
            fixture.document.setValue(entry.key, 'birthDate', entry.value),
          );
        }
        final session = _Session(fixture.document, editingAllowed: true);
        final peopleBefore = fixture.document.people;
        await _mount(
          tester,
          session,
          size: portrait ? const Size(1200, 1800) : const Size(1800, 1300),
        );
        for (final mode in [
          TreeTrunkMode.both,
          TreeTrunkMode.father,
          TreeTrunkMode.mother,
          TreeTrunkMode.both,
        ]) {
          await _chooseMode(tester, mode);
          final layout = _layoutOf(fixture, mode: mode);
          final blocks = layout.levels.expand((level) => level.blocks);
          List<String> members(String id) => blocks
              .singleWhere((block) => block.id == layout.positions[id]!.blockId)
              .people
              .map((person) => person.id)
              .toList();
          expect(
            members('Мать'),
            mode == TreeTrunkMode.both
                ? ['Тётя матери', 'Мать']
                : ['Мать', 'Тётя матери'],
          );
          expect(
            members('Отец'),
            mode == TreeTrunkMode.both ? ['Отец', 'Дядя'] : ['Дядя', 'Отец'],
          );
          _expectCanonicalRowGeometry(tester, layout, portrait: portrait);
          if (mode == TreeTrunkMode.both) {
            final mother = tester.getRect(_person('Мать'));
            final father = tester.getRect(_person('Отец'));
            expect(
              portrait
                  ? father.top - mother.bottom
                  : father.left - mother.right,
              closeTo(2 * layout.gap, .2),
            );
          }
        }
        expect(session.operations, isEmpty);
        expect(identical(fixture.document.people, peopleBefore), isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} Nikita to Olga to Nikita repeats canonical order with required parent boundaries',
      (tester) async {
        final fixture = _nikitaOlgaFamily();
        final session = _Session(fixture.document, editingAllowed: true);
        final peopleBefore = fixture.document.people;
        await _mount(
          tester,
          session,
          initialPersonId: 'nikita',
          size: portrait ? const Size(1200, 1800) : const Size(1800, 1300),
        );
        expect(fixture.document.person(rootTreePersonId)!.displayName, 'Ольга');
        expect(fixture.document.person('anastasia')!.fatherId, isNull);
        for (final mode in TreeTrunkMode.values) {
          await _chooseMode(tester, mode);
          final snapshots = <String, Map<int, List<String>>>{};
          for (var repeat = 0; repeat < 4; repeat++) {
            for (final selected in ['nikita', rootTreePersonId, 'nikita']) {
              await _selectPerson(tester, selected);
              final layout = _layoutOf(
                fixture,
                selectedId: selected,
                mode: mode,
              );
              _expectCanonicalRowGeometry(tester, layout, portrait: portrait);
              final order = <int, List<String>>{};
              for (final level in layout.levels) {
                final ids =
                    level.blocks
                        .expand((block) => block.people)
                        .map((p) => p.id)
                        .toList()
                      ..sort(
                        (a, b) => _cross(tester.getCenter(_person(a)), portrait)
                            .compareTo(
                              _cross(tester.getCenter(_person(b)), portrait),
                            ),
                      );
                order[level.index] = ids;
              }
              final previous = snapshots[selected];
              if (previous == null) {
                snapshots[selected] = order;
              } else {
                expect(
                  order,
                  previous,
                  reason: '${mode.name}, $selected, repeat $repeat',
                );
              }
              final siblings = order[layout.positions['natalia']!.level]!;
              expect(
                (siblings.indexOf('veronika') - siblings.indexOf('natalia'))
                    .abs(),
                1,
              );
              if (mode == TreeTrunkMode.both) {
                final focus = fixture.document.person(selected)!;
                final blocks = layout.levels.expand((level) => level.blocks);
                final motherBlock = blocks.singleWhere(
                  (block) =>
                      block.id == layout.positions[focus.motherId]!.blockId,
                );
                final fatherBlock = blocks.singleWhere(
                  (block) =>
                      block.id == layout.positions[focus.fatherId]!.blockId,
                );
                // Use actual card edges: the painted block wash has an extra
                // 6px outset on each side and is not the model packing boundary.
                expect(motherBlock.people.last.id, focus.motherId);
                expect(fatherBlock.people.first.id, focus.fatherId);
                final mother = tester.getRect(_person(focus.motherId!));
                final father = tester.getRect(_person(focus.fatherId!));
                expect(
                  portrait
                      ? father.top - mother.bottom
                      : father.left - mother.right,
                  closeTo(2 * layout.gap, .2),
                  reason:
                      '$selected must have literal adjacent mother/father cards, with siblings outside the boundary.',
                );
                expect(
                  _cross(tester.getCenter(_person(focus.motherId!)), portrait),
                  lessThan(
                    _cross(
                      tester.getCenter(_person(focus.fatherId!)),
                      portrait,
                    ),
                  ),
                );
              }
              for (final pair in [
                ['natalia', 'oleg'],
                ['veronika', 'roman'],
                ['lydia', 'gennady'],
              ]) {
                expect(
                  _cross(tester.getCenter(_person(pair.first)), portrait),
                  lessThan(
                    _cross(tester.getCenter(_person(pair.last)), portrait),
                  ),
                  reason:
                      '${mode.name}, $selected must retain maternal-before-paternal sides.',
                );
                // Single-line modes retain sister chronology rather than
                // reversing a couple to expose its boundary. In both mode a
                // focus-parent seam still outranks the other cousin's couple.
                if ((mode != TreeTrunkMode.both && pair.first != 'lydia') ||
                    (mode == TreeTrunkMode.both &&
                        ((selected == rootTreePersonId &&
                                pair.first == 'veronika') ||
                            (selected == 'nikita' &&
                                pair.first == 'natalia')))) {
                  continue;
                }
                final row = order[layout.positions[pair.first]!.level]!;
                expect(
                  (row.indexOf(pair.first) - row.indexOf(pair.last)).abs(),
                  1,
                  reason:
                      '${mode.name}, $selected must keep ${pair.join(' + ')} adjacent; actual row $row.',
                );
                expect(
                  _cross(
                    tester.getCenter(_person(pair.first)) -
                        tester.getCenter(_person(pair.last)),
                    portrait,
                  ).abs(),
                  lessThanOrEqualTo(layout.nodeExtent + 2 * layout.gap + .2),
                );
              }
            }
          }
        }
        expect(session.operations, isEmpty);
        expect(identical(fixture.document.people, peopleBefore), isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} undated half-sibling taps preserve unchanged rows while applying required parent order at 100 and 150 percent',
      (tester) async {
        final fixture = _Fixture()
          ..name(rootTreePersonId, 'Тест')
          ..add('lydia', sex: TreeSex.female)
          ..name('lydia', 'Лидия')
          ..add('gennady', sex: TreeSex.male)
          ..name('gennady', 'Геннадий')
          ..parents('lydia', father: rootTreePersonId)
          ..add('natalia', sex: TreeSex.female)
          ..name('natalia', 'Наталья')
          ..parents('natalia', father: 'gennady', mother: 'lydia')
          ..add('veronika', sex: TreeSex.female)
          ..name('veronika', 'Вероника')
          ..parents('veronika', father: 'gennady', mother: 'lydia')
          ..add('oleg', sex: TreeSex.male)
          ..name('oleg', 'Олег')
          ..add('olga', sex: TreeSex.female)
          ..name('olga', 'Ольга')
          ..parents('olga', father: 'oleg', mother: 'natalia')
          ..add('anastasia', sex: TreeSex.female)
          ..name('anastasia', 'Анастасия')
          ..parents('anastasia', mother: 'natalia');
        expect(
          fixture.document.people.values.every((p) => p.birthDate == null),
          isTrue,
        );
        await _mount(
          tester,
          _Session(fixture.document),
          initialPersonId: 'olga',
          size: portrait ? const Size(1200, 1800) : const Size(1800, 1300),
        );
        expect(
          _layoutOf(fixture).positions['natalia']!.blockId,
          _layoutOf(fixture).positions['veronika']!.blockId,
        );
        expect(
          _layoutOf(fixture).positions['olga']!.blockId,
          isNot(_layoutOf(fixture).positions['anastasia']!.blockId),
        );
        for (final zoom in [100, 150]) {
          if (zoom == 150) await _zoomSteps(tester, 5);
          expect(_zoomLabel(tester), '$zoom%');
          final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
          // The focus row never needs to reorder. The parent row can require
          // a canonical repair: Olga has a known father on the paternal side,
          // whereas Anastasia does not. Unchanged rows still must not move.
          var previousLayout = _layoutOf(fixture, selectedId: 'olga');
          final nodesBefore = {
            for (final id in ['olga', 'anastasia'])
              id: tester.getRect(_person(id)),
          };
          final blocksBefore = {
            for (final id in ['olga', 'anastasia'])
              id: tester.getRect(_blockFor(fixture, id)),
          };
          final blockOrder = _cross(
            blocksBefore['olga']!.center - blocksBefore['anastasia']!.center,
            portrait,
          );
          expect(blockOrder.abs(), greaterThan(108));
          final mainBefore = _mainController(tester).offset;
          for (var cycle = 0; cycle < 4; cycle++) {
            for (final selected in ['anastasia', 'olga']) {
              for (final id in fixture.document.people.keys) {
                _expectInside(tester.getRect(_person(id)), canvas);
              }
              final before = {
                for (final id in fixture.document.people.keys)
                  id: tester.getRect(_person(id)),
              };
              await tester.tap(_person(selected));
              await tester.pumpAndSettle();
              expect(
                _nodeSemantics(
                  tester,
                  fixture.document.person(selected)!.displayName,
                ).flagsCollection.isSelected,
                Tristate.isTrue,
              );
              final reason = '$zoom%, cycle $cycle, selected $selected';
              final currentLayout = _layoutOf(fixture, selectedId: selected);
              final unchangedRows = _expectPreservedOrCanonicalRows(
                tester,
                beforeLayout: previousLayout,
                afterLayout: currentLayout,
                before: before,
                portrait: portrait,
                reason: reason,
              );
              expect(
                unchangedRows,
                contains(currentLayout.positions['olga']!.level),
              );
              previousLayout = currentLayout;
              expect(
                _mainController(tester).offset,
                mainBefore,
                reason: reason,
              );
              for (final entry in nodesBefore.entries) {
                final actual = tester.getRect(_person(entry.key));
                expect(
                  (actual.topLeft - entry.value.topLeft).distance,
                  lessThan(.5),
                  reason: '$reason moved ${entry.key}',
                );
                expect(actual.size, entry.value.size);
              }
              for (final entry in blocksBefore.entries) {
                final actual = tester.getRect(_blockFor(fixture, entry.key));
                expect(
                  (actual.topLeft - entry.value.topLeft).distance,
                  lessThan(.5),
                  reason: '$reason moved block ${entry.key}',
                );
                expect(actual.size, entry.value.size);
              }
              expect(
                _cross(
                  tester.getCenter(_blockFor(fixture, 'olga')) -
                      tester.getCenter(_blockFor(fixture, 'anastasia')),
                  portrait,
                ),
                closeTo(blockOrder, .5),
                reason: reason,
              );
            }
          }
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} undated sibling and parent selections preserve every row without a required canonical reorder',
      (tester) async {
        final fixture = _Fixture()
          ..name(rootTreePersonId, 'Я')
          ..add('Отец', sex: TreeSex.male)
          ..add('Мать', sex: TreeSex.female)
          ..parents(rootTreePersonId, father: 'Отец', mother: 'Мать')
          ..add('Партнёр', sex: TreeSex.female)
          ..add('Тесть', sex: TreeSex.male)
          ..add('Тёща', sex: TreeSex.female)
          ..parents('Партнёр', father: 'Тесть', mother: 'Тёща');
        for (var i = 0; i < 2; i++) {
          fixture
            ..add('Сестра-$i', sex: TreeSex.female)
            ..parents('Сестра-$i', father: 'Отец', mother: 'Мать');
        }
        for (var i = 0; i < 3; i++) {
          fixture
            ..add('Ребёнок-$i')
            ..parents(
              'Ребёнок-$i',
              father: rootTreePersonId,
              mother: 'Партнёр',
            );
        }
        expect(
          fixture.document.people.values.every(
            (person) => person.birthDate == null,
          ),
          isTrue,
        );
        await _mount(
          tester,
          _Session(fixture.document),
          size: portrait ? const Size(430, 1000) : const Size(1280, 900),
        );
        await tester.tap(find.byKey(const Key('open-biography')));
        await tester.pumpAndSettle();
        if (portrait) {
          await tester.tap(find.byKey(const Key('biography-close')));
          await tester.pumpAndSettle();
        }
        for (final mode in TreeTrunkMode.values) {
          await _chooseMode(tester, mode);
          final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
          final before = {
            for (final id in fixture.document.people.keys)
              id: tester.getRect(_person(id)),
          };
          final coParentOrder =
              _cross(before['Партнёр']!.center, portrait) -
              _cross(before[rootTreePersonId]!.center, portrait);
          expect(coParentOrder.abs(), greaterThan(108));
          final mainBefore = _mainController(tester).offset;
          var previousSelection = rootTreePersonId;
          for (var cycle = 0; cycle < 3; cycle++) {
            for (final id in [
              'Сестра-1',
              'Отец',
              'Мать',
              'Сестра-0',
              rootTreePersonId,
            ]) {
              final selectedBefore = tester.getRect(_person(id));
              _expectInside(selectedBefore, canvas);
              final transitionBefore = {
                for (final personId in fixture.document.people.keys)
                  personId: tester.getRect(_person(personId)),
              };
              final beforeLayout = _layoutOf(
                fixture,
                selectedId: previousSelection,
                mode: mode,
              );
              await tester.tap(_person(id));
              await tester.pumpAndSettle();
              expect(
                _nodeSemantics(
                  tester,
                  fixture.document.person(id)!.displayName,
                ).flagsCollection.isSelected,
                Tristate.isTrue,
              );
              expect(
                _mainController(tester).offset,
                mainBefore,
                reason:
                    '${mode.name}, cycle $cycle, selected $id is already visible',
              );
              final unchanged = _expectPreservedOrCanonicalRows(
                tester,
                beforeLayout: beforeLayout,
                afterLayout: _layoutOf(fixture, selectedId: id, mode: mode),
                before: transitionBefore,
                portrait: portrait,
                reason: '${mode.name}, cycle $cycle, selected $id',
              );
              if (unchanged.contains(_levelOf(fixture, rootTreePersonId))) {
                final currentOrder =
                    _cross(tester.getCenter(_person('Партнёр')), portrait) -
                    _cross(
                      tester.getCenter(_person(rootTreePersonId)),
                      portrait,
                    );
                final beforeOrder = _cross(
                  transitionBefore['Партнёр']!.center -
                      transitionBefore[rootTreePersonId]!.center,
                  portrait,
                );
                expect(currentOrder, closeTo(beforeOrder, .5));
              }
              previousSelection = id;
            }
          }
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} biography selection still reveals a cross-axis and main-axis offscreen person',
      (tester) async {
        final fixture = _family(siblings: 14);
        await _mount(
          tester,
          _Session(fixture.document),
          size: portrait ? const Size(430, 900) : const Size(1100, 700),
        );
        Future<void> selectFromBiography(String id) async {
          if (find.byType(PersonBiography).evaluate().isEmpty) {
            await tester.tap(find.byKey(const Key('open-biography')));
            await tester.pumpAndSettle();
          }
          tester
              .widget<PersonBiography>(find.byType(PersonBiography))
              .onSelect(id);
          await tester.pumpAndSettle();
        }

        var canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
        expect(canvas.overlaps(tester.getRect(_person('Сестра-0'))), isFalse);
        await selectFromBiography('Сестра-0');
        canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
        _expectInside(tester.getRect(_person('Сестра-0')), canvas);
        expect(
          _nodeSemantics(tester, 'Сестра-0').flagsCollection.isSelected,
          Tristate.isTrue,
        );
        final main = _mainController(tester);
        main.jumpTo(main.position.maxScrollExtent);
        await tester.pump();
        final clippedAncestor = tester.getRect(_person('Дед'));
        expect(
          portrait ? clippedAncestor.left : clippedAncestor.top,
          lessThan(portrait ? canvas.left : canvas.top),
        );
        await selectFromBiography('Дед');
        canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
        _expectInside(tester.getRect(_person('Дед')), canvas);
        expect(
          _nodeSemantics(tester, 'Дед').flagsCollection.isSelected,
          Tristate.isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final portrait in [true, false]) {
    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} text updates do not cancel an in-flight selection alignment',
      (tester) async {
        final fixture = _family(siblings: 14);
        final session = _Session(fixture.document);
        await _mount(
          tester,
          session,
          size: portrait ? const Size(430, 900) : const Size(1100, 700),
          reduceMotion: false,
        );
        final controller = _levelController(
          tester,
          _levelOf(fixture, 'Сестра-0'),
        );
        final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
        final target =
            (controller.offset +
                    _cross(
                      tester.getCenter(_person('Сестра-0')) - canvas.center,
                      portrait,
                    ))
                .clamp(0, controller.position.maxScrollExtent);
        expect((target - controller.offset).abs(), greaterThan(500));
        // Biography/semantic selection can request a card outside the viewport.
        tester
            .widget<InkWell>(
              find.descendant(
                of: _person('Сестра-0'),
                matching: find.byType(InkWell),
              ),
            )
            .onTap!();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        final during = controller.offset;
        expect(controller.position.isScrollingNotifier.value, isTrue);
        expect((target - during).abs(), greaterThan(10));
        // Keep the canonical slot unchanged: this tests a text refresh, not
        // a name edit that deliberately reorders the sibling block.
        fixture.name('Сестра-0', 'Сестра-0 обновлена');
        session.changed();
        await tester.pump();
        expect(controller.offset, closeTo(during, .1));
        expect(controller.position.isScrollingNotifier.value, isTrue);
        await tester.pumpAndSettle();
        expect(controller.offset, closeTo(target, .5));
        expect(
          _cross(tester.getCenter(_person('Сестра-0')), portrait),
          closeTo(_cross(canvas.center, portrait), .5),
        );
        expect(find.text('Сестра-0 обновлена'), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} zoom cancels a pending align-all without forcing the next visible selection',
      (tester) async {
        final fixture = _family(siblings: 1, children: 0);
        final session = _Session(fixture.document, editingAllowed: true);
        await _mount(
          tester,
          session,
          size: portrait ? const Size(430, 900) : const Size(1100, 700),
        );
        final controller = _levelController(
          tester,
          _levelOf(fixture, rootTreePersonId),
        );
        expect(
          controller.offset - controller.position.minScrollExtent,
          greaterThan(40),
        );
        controller.jumpTo(controller.offset - 40);
        await tester.pump();
        final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
        final before = {
          for (final id in fixture.document.people.keys)
            id: tester.getRect(_person(id)),
        };
        // Invoke both controls before a frame can execute the requested align.
        tester
            .widget<IconButton>(find.byKey(const Key('tree-align-all')))
            .onPressed!();
        tester
            .widget<IconButton>(find.byKey(const Key('tree-zoom-in')))
            .onPressed!();
        await tester.pumpAndSettle();
        expect(_zoomLabel(tester), '110%');
        _expectAffineCards(tester, before, focal: canvas.center, scale: 1.1);
        final siblingBefore = tester.getRect(_person('Сестра-0'));
        _expectInside(siblingBefore, canvas);
        expect(
          (_cross(siblingBefore.center - canvas.center, portrait)).abs(),
          greaterThan(30),
        );
        await _selectPerson(tester, 'Сестра-0');
        expect(tester.getRect(_person('Сестра-0')), siblingBefore);
        expect(session.operations, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} align-all recenters visible relevant groups on every generation and fallback rows without history',
      (tester) async {
        final fixture = _family(siblings: 2, children: 2)
          ..add('Внук')
          ..parents('Внук', father: 'Ребёнок-0');
        for (var i = 0; i <= 5; i++) {
          fixture.add('other-$i');
          if (i > 0) fixture.parents('other-$i', father: 'other-${i - 1}');
        }
        fixture
          ..add('other-last-sibling')
          ..parents('other-last-sibling', father: 'other-4');
        final session = _Session(fixture.document, editingAllowed: true);
        final peopleBefore = fixture.document.people;
        await _mount(
          tester,
          session,
          size: portrait ? const Size(700, 1800) : const Size(1800, 750),
        );
        final layout = _layoutOf(fixture);
        final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
        final groups = <List<String>>[
          ['Дед', 'Бабушка'],
          ['Отец', 'Мать'],
          [rootTreePersonId],
          ['Ребёнок-0', 'Ребёнок-1'],
          ['Внук'],
          ['other-5', 'other-last-sibling'],
        ];
        for (final level in layout.levels) {
          final controller = _levelController(tester, level.index);
          final available =
              controller.position.maxScrollExtent - controller.offset;
          controller.jumpTo(controller.offset + (available >= 40 ? 40 : -40));
        }
        await tester.pump();
        for (final group in groups) {
          for (final id in group) {
            final rect = tester.getRect(_person(id));
            final crossStart = portrait ? rect.top : rect.left;
            final crossEnd = portrait ? rect.bottom : rect.right;
            expect(
              crossStart,
              greaterThanOrEqualTo(portrait ? canvas.top : canvas.left),
            );
            expect(
              crossEnd,
              lessThanOrEqualTo(portrait ? canvas.bottom : canvas.right),
            );
          }
        }
        expect(
          (_cross(tester.getCenter(_person(rootTreePersonId)), portrait) -
                  _cross(canvas.center, portrait))
              .abs(),
          greaterThan(30),
          reason: 'The selected person is visible but deliberately off-center.',
        );
        await tester.tap(find.byKey(const Key('tree-align-all')));
        await tester.pumpAndSettle();
        for (final group in groups) {
          final centers = group.map(
            (id) => _cross(tester.getCenter(_person(id)), portrait),
          );
          expect(
            (centers.reduce(math.min) + centers.reduce(math.max)) / 2,
            closeTo(_cross(canvas.center, portrait), .2),
            reason:
                'Manual alignment must center ${group.join(', ')} even when visible.',
          );
        }
        final selected = tester.getRect(_person(rootTreePersonId));
        final parents = tester.getRect(_person('Отец'));
        expect(
          portrait
              ? (selected.right + parents.left) / 2
              : (selected.bottom + parents.top) / 2,
          closeTo(portrait ? canvas.center.dx : canvas.center.dy, .2),
          reason:
              'Main-axis focus plus immediate-parent centering is unchanged.',
        );
        final aligned = {
          for (final id in fixture.document.people.keys)
            id: tester.getRect(_person(id)),
        };
        for (var repeat = 0; repeat < 3; repeat++) {
          await tester.tap(find.byKey(const Key('tree-align-all')));
          await tester.pumpAndSettle();
          for (final entry in aligned.entries) {
            expect(tester.getRect(_person(entry.key)), entry.value);
          }
        }
        _expectCanonicalRowGeometry(tester, layout, portrait: portrait);
        expect(
          _nodeSemantics(tester, 'Я').flagsCollection.isSelected,
          Tristate.isTrue,
        );
        expect(session.operations, isEmpty);
        expect(identical(fixture.document.people, peopleBefore), isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    for (final mode in TreeTrunkMode.values) {
      testWidgets(
        '${portrait ? 'portrait' : 'landscape'} ${mode.name} auto and forced alignment follow the preferred lineage on every ancestor level without changing the document',
        (tester) async {
          final fixture = _lineageFamily();
          final session = _Session(
            fixture.document,
            boundId: rootTreePersonId,
            editingAllowed: true,
          );
          final peopleBefore = fixture.document.people;
          await _mount(
            tester,
            session,
            size: portrait ? const Size(800, 1800) : const Size(1800, 850),
          );
          final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
          final bothGroups = <List<String>>[
            ['f', 'm'],
            ['ff', 'fm', 'mf', 'mm'],
            ['fff', 'ffm', 'fmf', 'fmm', 'mff', 'mfm', 'mmf', 'mmm'],
          ];
          final groups = switch (mode) {
            TreeTrunkMode.father => <List<String>>[
              ['f'],
              ['ff'],
              ['fff'],
            ],
            TreeTrunkMode.mother => <List<String>>[
              ['m'],
              ['mm'],
              ['mmm'],
            ],
            TreeTrunkMode.both => bothGroups,
          };
          void expectCentered(List<List<String>> targets, String reason) {
            for (final group in targets) {
              final centers = group.map(
                (id) => _cross(tester.getCenter(_person(id)), portrait),
              );
              expect(
                (centers.reduce(math.min) + centers.reduce(math.max)) / 2,
                closeTo(_cross(canvas.center, portrait), .2),
                reason: '$reason: ${group.join(', ')}',
              );
            }
          }

          expectCentered(
            bothGroups,
            'Initial both mode includes both lineages',
          );
          // Request a real mode change even when the mode under test is both.
          if (mode == TreeTrunkMode.both) {
            await _chooseMode(tester, TreeTrunkMode.mother);
          }
          final beforeLayout = _layoutOf(
            fixture,
            mode: mode == TreeTrunkMode.both
                ? TreeTrunkMode.mother
                : TreeTrunkMode.both,
          );
          for (final group in groups) {
            final level = beforeLayout.positions[group.first]!.level;
            final controller = _levelController(tester, level);
            controller.jumpTo(controller.position.maxScrollExtent);
          }
          await tester.pump();
          for (final group in groups) {
            for (final id in group) {
              final rect = tester.getRect(_person(id));
              expect(
                portrait ? rect.bottom : rect.right,
                lessThan(portrait ? canvas.top : canvas.left),
                reason: '$id must be offscreen before automatic alignment.',
              );
            }
          }
          await _chooseMode(tester, mode);
          expectCentered(groups, 'Automatic alignment follows ${mode.name}');
          final layout = _layoutOf(fixture, mode: mode);
          _expectCanonicalRowGeometry(tester, layout, portrait: portrait);
          if (mode != TreeTrunkMode.both) {
            final alternatives = mode == TreeTrunkMode.mother
                ? ['mf', 'mmf']
                : ['fm', 'ffm'];
            for (var i = 0; i < alternatives.length; i++) {
              final preferred = groups[i + 1].single;
              final midpoint =
                  (_cross(tester.getCenter(_person(preferred)), portrait) +
                      _cross(
                        tester.getCenter(_person(alternatives[i])),
                        portrait,
                      )) /
                  2;
              expect(
                (midpoint - _cross(canvas.center, portrait)).abs(),
                greaterThan(50),
                reason:
                    'Single-lineage centering must not average both parents.',
              );
            }
          }

          // Deliberately offset every relevant row, but keep all target cards
          // fully visible. A normal sibling selection must preserve those views.
          final ancestorLevels = {
            for (final group in groups) layout.positions[group.first]!.level,
          };
          ancestorLevels.add(layout.positions[rootTreePersonId]!.level);
          for (final level in ancestorLevels) {
            final controller = _levelController(tester, level);
            final available =
                controller.position.maxScrollExtent - controller.offset;
            controller.jumpTo(controller.offset + (available >= 40 ? 40 : -40));
          }
          await tester.pump();
          for (final group in groups) {
            for (final id in group) {
              final rect = tester.getRect(_person(id));
              expect(
                portrait ? rect.top : rect.left,
                greaterThanOrEqualTo(portrait ? canvas.top : canvas.left),
              );
              expect(
                portrait ? rect.bottom : rect.right,
                lessThanOrEqualTo(portrait ? canvas.bottom : canvas.right),
              );
            }
          }
          _expectInside(tester.getRect(_person('sibling')), canvas);
          final visible = {
            for (final id in fixture.document.people.keys)
              id: tester.getRect(_person(id)),
          };
          await _selectPerson(tester, 'sibling');
          for (final entry in visible.entries) {
            expect(
              tester.getRect(_person(entry.key)),
              entry.value,
              reason: 'Automatic selection must preserve visible ${entry.key}.',
            );
          }
          await tester.tap(find.byKey(const Key('tree-align-all')));
          await tester.pumpAndSettle();
          expectCentered(groups, 'Forced alignment follows ${mode.name}');
          expectCentered([
            ['sibling'],
          ], 'Forced alignment centers the newly selected sibling');
          final siblingLayout = _layoutOf(
            fixture,
            selectedId: 'sibling',
            mode: mode,
          );
          _expectCanonicalRowGeometry(
            tester,
            siblingLayout,
            portrait: portrait,
          );
          final aligned = {
            for (final id in fixture.document.people.keys)
              id: tester.getRect(_person(id)),
          };
          await tester.tap(find.byKey(const Key('tree-align-all')));
          await tester.pumpAndSettle();
          for (final entry in aligned.entries) {
            expect(tester.getRect(_person(entry.key)), entry.value);
          }
          expect(session.boundPersonId, rootTreePersonId);
          expect(session.operations, isEmpty);
          expect(identical(fixture.document.people, peopleBefore), isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} a visible selection retains its whole screen position until explicit alignment reveals its clipped parent',
      (tester) async {
        final fixture = _Fixture()
          ..name(rootTreePersonId, 'Я')
          ..add('Отец', sex: TreeSex.male)
          ..add('Мать', sex: TreeSex.female)
          ..parents(rootTreePersonId, father: 'Отец', mother: 'Мать')
          ..add('Сестра')
          ..parents('Сестра', father: 'Отец', mother: 'Мать')
          ..add('Ребёнок')
          ..parents('Ребёнок', father: rootTreePersonId)
          ..add('Внук')
          ..parents('Внук', father: 'Ребёнок');
        await _mount(
          tester,
          _Session(fixture.document),
          size: portrait ? const Size(430, 900) : const Size(1100, 450),
        );
        final main = _mainController(tester);
        main.jumpTo(120);
        await tester.pump();
        final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
        _expectInside(tester.getRect(_person('Сестра')), canvas);
        final parentBefore = tester.getRect(_person('Отец'));
        expect(
          portrait ? parentBefore.left : parentBefore.top,
          lessThan(portrait ? canvas.left : canvas.top),
        );
        final selectedBefore = tester.getRect(_person('Сестра'));
        await tester.tap(_person('Сестра'));
        await tester.pumpAndSettle();
        expect(main.offset, 120);
        expect(tester.getRect(_person('Сестра')), selectedBefore);
        expect(tester.getRect(_person('Отец')), parentBefore);
        await tester.tap(find.byKey(const Key('tree-align-all')));
        await tester.pumpAndSettle();
        expect(main.offset, lessThan(120));
        _expectInside(tester.getRect(_person('Отец')), canvas);
        _expectInside(tester.getRect(_person('Мать')), canvas);
        _expectInside(tester.getRect(_person('Сестра')), canvas);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} offscreen parents center in the viewport while the visible selected sibling retains its edge position',
      (tester) async {
        final fixture = _Fixture()
          ..name(rootTreePersonId, 'Я')
          ..add('Отец', sex: TreeSex.male)
          ..add('Мать', sex: TreeSex.female)
          ..parents(rootTreePersonId, father: 'Отец', mother: 'Мать');
        for (var i = 0; i < 12; i++) {
          fixture
            ..add('Сестра-$i')
            ..parents('Сестра-$i', father: 'Отец', mother: 'Мать')
            ..add('Родительский сосед-$i');
        }
        await _mount(
          tester,
          _Session(fixture.document),
          size: portrait ? const Size(430, 900) : const Size(1100, 700),
        );
        final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
        final selectedScroll = _levelController(
          tester,
          _levelOf(fixture, 'Сестра-0'),
        );
        final edgeCenter = (portrait ? canvas.top : canvas.left) + 62;
        selectedScroll.jumpTo(
          selectedScroll.offset +
              _cross(tester.getCenter(_person('Сестра-0')), portrait) -
              edgeCenter,
        );
        final parentScroll = _levelController(
          tester,
          _levelOf(fixture, 'Отец'),
        );
        parentScroll.jumpTo(parentScroll.position.maxScrollExtent);
        await tester.pump();
        final selectedBefore = tester.getRect(_person('Сестра-0'));
        _expectInside(selectedBefore, canvas);
        expect(
          _cross(selectedBefore.center, portrait),
          closeTo(edgeCenter, .1),
        );
        expect(canvas.overlaps(tester.getRect(_person('Отец'))), isFalse);
        expect(canvas.overlaps(tester.getRect(_person('Мать'))), isFalse);
        await tester.tap(_person('Сестра-0'));
        await tester.pumpAndSettle();
        expect(tester.getRect(_person('Сестра-0')), selectedBefore);
        _expectInside(tester.getRect(_person('Отец')), canvas);
        _expectInside(tester.getRect(_person('Мать')), canvas);
        expect(
          _cross(
            (tester.getCenter(_person('Отец')) +
                    tester.getCenter(_person('Мать'))) /
                2,
            portrait,
          ),
          closeTo(_cross(canvas.center, portrait), .2),
          reason:
              'Offscreen ancestors follow the viewport, not the shifted focus.',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} oversized parent spans reveal a real parent rather than an empty midpoint',
      (tester) async {
        final fixture = _Fixture()
          ..name(rootTreePersonId, 'Я')
          ..add('AAA-отец', sex: TreeSex.male)
          ..add('AAA-мать', sex: TreeSex.female)
          ..add('Дед отца', sex: TreeSex.male)
          ..add('Бабушка отца', sex: TreeSex.female)
          ..add('Дед матери', sex: TreeSex.male)
          ..add('Бабушка матери', sex: TreeSex.female)
          ..parents('AAA-отец', father: 'Дед отца', mother: 'Бабушка отца')
          ..parents('AAA-мать', father: 'Дед матери', mother: 'Бабушка матери')
          ..parents(rootTreePersonId, father: 'AAA-отец', mother: 'AAA-мать')
          ..add('Сестра')
          ..parents('Сестра', father: 'AAA-отец', mother: 'AAA-мать');
        for (var i = 0; i < 14; i++) {
          fixture
            ..add('P-дядя-$i')
            ..parents('P-дядя-$i', father: 'Дед отца', mother: 'Бабушка отца')
            ..add('M-тётя-$i')
            ..parents(
              'M-тётя-$i',
              father: 'Дед матери',
              mother: 'Бабушка матери',
            );
        }
        await _mount(
          tester,
          _Session(fixture.document),
          size: portrait ? const Size(240, 256) : const Size(230, 220),
        );
        final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
        bool crossVisible(String id) {
          final rect = tester.getRect(_person(id));
          return portrait
              ? rect.top >= canvas.top && rect.bottom <= canvas.bottom
              : rect.left >= canvas.left && rect.right <= canvas.right;
        }

        bool aParentVisible() =>
            crossVisible('AAA-отец') || crossVisible('AAA-мать');
        // Literal adjacent parents can still exceed a narrow viewport. Reveal
        // a real card rather than centering their empty inter-block gap.
        expect(
          (_cross(
                tester.getCenter(_person('AAA-отец')) -
                    tester.getCenter(_person('AAA-мать')),
                portrait,
              )).abs() +
              108,
          greaterThan(portrait ? canvas.height : canvas.width),
        );
        expect(
          aParentVisible(),
          isTrue,
          reason: 'Initial alignment must show a real parent.',
        );
        final controller = _levelController(
          tester,
          _levelOf(fixture, 'AAA-отец'),
        );
        final alignedOffset = controller.offset;
        await _selectPerson(tester, 'Сестра');
        expect(
          controller.offset,
          alignedOffset,
          reason: 'One visible parent is sufficient for an oversized span.',
        );
        final midpoint =
            (_cross(tester.getCenter(_person('AAA-отец')), portrait) +
                _cross(tester.getCenter(_person('AAA-мать')), portrait)) /
            2;
        controller.jumpTo(
          (controller.offset + midpoint - _cross(canvas.center, portrait))
              .clamp(0, controller.position.maxScrollExtent),
        );
        await tester.pump();
        expect(aParentVisible(), isFalse);
        await _selectPerson(tester, rootTreePersonId);
        expect(
          aParentVisible(),
          isTrue,
          reason: 'Navigation must reveal an actual card, not the gap.',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} an oversized descendant block reveals a real child in a narrow cross viewport',
      (tester) async {
        final fixture = _Fixture()
          ..name(rootTreePersonId, 'Я')
          ..add('Партнёр', sex: TreeSex.female);
        for (var i = 0; i < 2; i++) {
          fixture
            ..add('Ребёнок-$i')
            ..parents(
              'Ребёнок-$i',
              father: rootTreePersonId,
              mother: 'Партнёр',
            );
        }
        await _mount(
          tester,
          _Session(fixture.document),
          size: portrait ? const Size(240, 256) : const Size(230, 220),
        );
        final toolbar = tester.getRect(find.byKey(const Key('tree-toolbar')));
        for (final key in [
          'tree-toolbar-toggle',
          'tree-mode-picker',
          'tree-align-all',
          'tree-search-field',
          'tree-zoom-out',
          'tree-zoom-reset',
          'tree-zoom-in',
        ]) {
          _expectInside(tester.getRect(find.byKey(Key(key))), toolbar);
        }
        final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
        final crossExtent = portrait ? canvas.height : canvas.width;
        final firstChild = tester.getRect(_person('Ребёнок-0'));
        final lastChild = tester.getRect(_person('Ребёнок-1'));
        final childExtent = portrait ? firstChild.height : firstChild.width;
        final childSpan =
            _cross(lastChild.center - firstChild.center, portrait).abs() +
            childExtent;
        expect(crossExtent, greaterThan(childExtent));
        expect(crossExtent, lessThan(childSpan));
        expect(
          ['Ребёнок-0', 'Ребёнок-1'].any((id) {
            final child = tester.getRect(_person(id));
            return portrait
                ? child.top >= canvas.top && child.bottom <= canvas.bottom
                : child.left >= canvas.left && child.right <= canvas.right;
          }),
          isTrue,
          reason: 'Centering between the children would clip both of them.',
        );
        final controller = _levelController(
          tester,
          _levelOf(fixture, 'Ребёнок-0'),
        );
        final midpoint =
            (tester.getCenter(_person('Ребёнок-0')) +
                tester.getCenter(_person('Ребёнок-1'))) /
            2;
        controller.jumpTo(
          controller.offset + _cross(midpoint - canvas.center, portrait) + 1,
        );
        await tester.pump();
        final nearest = ['Ребёнок-0', 'Ребёнок-1']
          ..sort((a, b) {
            final aDistance = _cross(
              tester.getCenter(_person(a)) - canvas.center,
              portrait,
            ).abs();
            final bDistance = _cross(
              tester.getCenter(_person(b)) - canvas.center,
              portrait,
            ).abs();
            final comparison = aDistance.compareTo(bDistance);
            return comparison == 0 ? a.compareTo(b) : comparison;
          });
        for (final id in nearest) {
          final rect = tester.getRect(_person(id));
          expect(
            portrait
                ? rect.top >= canvas.top && rect.bottom <= canvas.bottom
                : rect.left >= canvas.left && rect.right <= canvas.right,
            isFalse,
          );
        }
        await tester.tap(find.byKey(const Key('tree-align-all')));
        await tester.pumpAndSettle();
        expect(
          _cross(tester.getCenter(_person(nearest.first)), portrait),
          closeTo(_cross(canvas.center, portrait), .2),
          reason:
              'Forced oversized alignment chooses the nearest real card, not the gap.',
        );
        final aligned = controller.offset;
        await tester.tap(find.byKey(const Key('tree-align-all')));
        await tester.pumpAndSettle();
        expect(controller.offset, aligned);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'mode reveals clipped focus; a visible sibling is selected without recentering',
    (tester) async {
      final fixture = _family(siblings: 10, children: 10);
      await _mount(tester, _Session(fixture.document));
      final focusLevel = _levelOf(fixture, rootTreePersonId);
      final controller = _levelController(tester, focusLevel);
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      final firstPainter = _linkPainter(tester);

      await _chooseMode(tester, TreeTrunkMode.father);
      await tester.pumpAndSettle();
      final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
      expect(
        tester.getCenter(_person(rootTreePersonId)).dx,
        closeTo(canvas.center.dx, 1),
      );
      expect(identical(firstPainter, _linkPainter(tester)), isFalse);
      expect(
        tester
            .widget<PopupMenuButton<TreeTrunkMode>>(
              find.byKey(const Key('tree-mode-picker')),
            )
            .initialValue,
        TreeTrunkMode.father,
      );

      controller.jumpTo(
        (controller.offset +
                tester.getCenter(_person('Сестра-0')).dx -
                (canvas.center.dx + 132))
            .clamp(0, controller.position.maxScrollExtent),
      );
      await tester.pump();
      final before = tester.getRect(_person('Сестра-0'));
      _expectInside(before, canvas);
      expect((before.center.dx - canvas.center.dx).abs(), greaterThan(100));
      await tester.tap(_person('Сестра-0'));
      await tester.pumpAndSettle();
      expect(
        _nodeSemantics(tester, 'Сестра-0').flagsCollection.isSelected ==
            Tristate.isTrue,
        isTrue,
      );
      expect(
        _nodeSemantics(tester, 'Я').flagsCollection.isSelected ==
            Tristate.isTrue,
        isFalse,
      );
      expect(tester.getRect(_person('Сестра-0')), before);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(844, 390),
    const Size(1100, 700),
    const Size(390, 844),
    const Size(320, 500),
    const Size(240, 500),
  ]) {
    for (final textScale in [1.0, 2.0]) {
      for (final picker in [false, true]) {
        testWidgets(
          '${picker ? 'picker' : 'editor'} toolbar real bounds fit ${size.width}x${size.height} at ${textScale * 100}% text scale',
          (tester) async {
            final fixture = _family()
              ..name(
                rootTreePersonId,
                'Очень длинное имя выбранного человека для компактной панели',
              );
            final session = _Session(fixture.document, editingAllowed: true);
            final picked = <String>[];
            await _mount(
              tester,
              session,
              size: size,
              textScale: textScale,
              onPickPerson: picker ? picked.add : null,
            );
            expect(
              MediaQuery.orientationOf(
                tester.element(find.byKey(const Key('tree-toolbar'))),
              ),
              size.width > size.height
                  ? Orientation.landscape
                  : Orientation.portrait,
            );
            _expectToolbarFits(tester);
            expect(
              find.descendant(
                of: find.byKey(const Key('tree-toolbar')),
                matching: find.textContaining(
                  'Очень длинное имя выбранного человека',
                ),
              ),
              findsNothing,
              reason:
                  'The selected name belongs on its card, not in the toolbar.',
            );
            expect(find.byTooltip('Свернуть панель дерева'), findsOneWidget);
            expect(find.byTooltip('Линия дерева: Обе линии'), findsOneWidget);
            await tester.tap(find.byKey(const Key('tree-align-all')));
            await tester.pumpAndSettle();
            _expectToolbarFits(tester);
            expect(picked, isEmpty);
            expect(session.operations, isEmpty);
          },
        );
      }
    }
  }

  for (final portrait in [true, false]) {
    for (final picker in [false, true]) {
      testWidgets(
        '${portrait ? 'portrait' : 'landscape'} ${picker ? 'picker' : 'editor'} toolbar fully collapses, reclaims height, and preserves local state',
        (tester) async {
          final fixture = _family();
          final session = _Session(fixture.document, editingAllowed: true);
          final peopleBefore = fixture.document.people;
          final picked = <String>[];
          await _mount(
            tester,
            session,
            size: portrait ? const Size(390, 844) : const Size(844, 390),
            onPickPerson: picker ? picked.add : null,
          );
          _expectToolbarFits(tester);
          await _chooseMode(tester, TreeTrunkMode.mother);
          await _selectPerson(tester, 'Сестра-0');
          await _zoomSteps(tester, 2);
          expect(_zoomLabel(tester), '120%');
          final toolbar = tester.getRect(find.byKey(const Key('tree-toolbar')));
          final before = tester.getRect(find.byKey(const Key('tree-canvas')));
          final toggle = find.byKey(const Key('tree-toolbar-toggle'));
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          for (final key in [
            'tree-toolbar',
            'tree-search-field',
            'tree-mode-picker',
            'tree-align-all',
            'tree-zoom-in',
            'tree-zoom-out',
            'tree-zoom-reset',
            'tree-zoom-value',
          ]) {
            expect(find.byKey(Key(key)), findsNothing, reason: key);
          }
          expect(find.text('Семейное дерево'), findsNothing);
          expect(toggle, findsOneWidget);
          expect(tester.widget<IconButton>(toggle).onPressed, isNotNull);
          expect(find.byTooltip('Развернуть панель дерева'), findsOneWidget);
          final collapsed = tester.getRect(
            find.byKey(const Key('tree-canvas')),
          );
          expect(collapsed.height, closeTo(before.height + toolbar.height, .1));
          expect(collapsed.top, closeTo(before.top - toolbar.height, .1));
          expect(collapsed.bottom, closeTo(before.bottom, .1));
          _expectInside(tester.getRect(toggle), collapsed);
          expect(
            _nodeSemantics(tester, 'Сестра-0').flagsCollection.isSelected,
            Tristate.isTrue,
          );
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(_zoomLabel(tester), '120%');
          expect(
            tester
                .widget<PopupMenuButton<TreeTrunkMode>>(
                  find.byKey(const Key('tree-mode-picker')),
                )
                .initialValue,
            TreeTrunkMode.mother,
          );
          expect(
            _nodeSemantics(tester, 'Сестра-0').flagsCollection.isSelected,
            Tristate.isTrue,
          );
          expect(tester.getRect(find.byKey(const Key('tree-canvas'))), before);
          expect(find.byTooltip('Свернуть панель дерева'), findsOneWidget);
          _expectToolbarFits(tester);
          expect(picked, isEmpty);
          expect(session.operations, isEmpty);
          expect(identical(fixture.document.people, peopleBefore), isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(240, 500),
  ]) {
    for (final picker in [false, true]) {
      testWidgets(
        '${picker ? 'picker' : 'editor'} mobile search fills one toolbar row at $size and restores it on every exit',
        (tester) async {
          final fixture = _family();
          final peopleBefore = fixture.document.people;
          final session = _Session(fixture.document, editingAllowed: true);
          final picked = <String>[];
          await _mount(
            tester,
            session,
            size: size,
            onPickPerson: picker ? picked.add : null,
          );
          await _zoomSteps(tester, 2);
          final field = find.byKey(const Key('tree-search-field'));
          final toolbar = find.byKey(const Key('tree-toolbar'));
          final canvas = find.byKey(const Key('tree-canvas'));
          final initialField = tester.getRect(field);
          final initialCanvas = tester.getRect(canvas);
          final controller = tester.widget<TextField>(field).controller!;
          final focus = tester.widget<TextField>(field).focusNode!;
          expect(initialField.width, 64);

          void expectExpanded() {
            final bounds = tester.getRect(toolbar);
            final input = tester.getRect(field);
            expect(bounds.height, 45);
            expect(input.left, closeTo(bounds.left + 4, .1));
            expect(input.right, closeTo(bounds.right - 4, .1));
            expect(tester.getRect(canvas), initialCanvas);
            expect(
              tester.widget<TextField>(field).controller,
              same(controller),
            );
            expect(tester.widget<TextField>(field).focusNode, same(focus));
            expect(focus.hasFocus, isTrue);
            expect(find.byKey(const Key('tree-search-back')), findsOneWidget);
            for (final key in [
              'tree-toolbar-toggle',
              'tree-mode-picker',
              'tree-align-all',
              'tree-zoom-controls',
            ]) {
              expect(find.byKey(Key(key)), findsNothing, reason: key);
            }
            expect(tester.takeException(), isNull);
          }

          void expectCollapsed() {
            expect(tester.getRect(field), initialField);
            expect(tester.getRect(canvas), initialCanvas);
            expect(focus.hasFocus, isFalse);
            expect(find.byKey(const Key('tree-search-back')), findsNothing);
            expect(find.byKey(const Key('tree-toolbar')), findsOneWidget);
            expect(
              find.byKey(const Key('tree-search-option-Мать')),
              findsNothing,
            );
            expect(_zoomLabel(tester), '120%');
            _expectToolbarFits(tester);
          }

          await tester.tap(field);
          await tester.pumpAndSettle();
          expectExpanded();
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expectCollapsed();

          await tester.enterText(field, 'Мать');
          await tester.pumpAndSettle();
          expectExpanded();
          final option = find.byKey(const Key('tree-search-option-Мать'));
          expect(option, findsOneWidget);
          final menu = tester.getRect(option);
          _expectInside(menu, Offset.zero & size);
          expect(menu.top, greaterThan(tester.getRect(toolbar).bottom));
          await tester.tap(find.byTooltip('Очистить поиск'));
          await tester.pumpAndSettle();
          expectExpanded();
          expect(option, findsNothing);
          expect(controller.text, isEmpty);
          await tester.enterText(field, 'Мать');
          await tester.pumpAndSettle();
          expect(option, findsOneWidget);
          await tester.tap(find.byKey(const Key('tree-search-back')));
          await tester.pumpAndSettle();
          expectCollapsed();
          expect(controller.text, 'Мать');

          await tester.tap(field);
          await tester.pumpAndSettle();
          expectExpanded();
          expect(option, findsOneWidget);
          await tester.tapAt(Offset(8, initialCanvas.bottom - 8));
          await tester.pumpAndSettle();
          expectCollapsed();
          expect(controller.text, 'Мать');

          await tester.tap(field);
          await tester.pumpAndSettle();
          expectExpanded();
          focus.unfocus();
          await tester.pumpAndSettle();
          expectCollapsed();

          await tester.tap(field);
          await tester.pumpAndSettle();
          expectExpanded();
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expectCollapsed();

          await tester.tap(field);
          await tester.pumpAndSettle();
          expectExpanded();
          await tester.tap(option);
          await tester.pumpAndSettle();
          expectCollapsed();
          expect(controller.text, isEmpty);
          expect(
            _nodeSemantics(tester, 'Мать').flagsCollection.isSelected,
            Tristate.isTrue,
          );
          expect(find.byType(PersonBiography), findsNothing);
          expect(picked, isEmpty);
          expect(session.operations, isEmpty);
          expect(fixture.document.people, same(peopleBefore));
        },
      );
    }
  }

  testWidgets(
    'focused search survives rotation and a desktop breakpoint without replacing input',
    (tester) async {
      final fixture = _family();
      final session = _Session(fixture.document);
      await _mount(tester, session, size: const Size(390, 844));
      final field = find.byKey(const Key('tree-search-field'));
      await tester.enterText(field, 'Мать');
      await tester.pumpAndSettle();
      final controller = tester.widget<TextField>(field).controller!;
      final focus = tester.widget<TextField>(field).focusNode!;
      final levelControllers = {
        for (final level in _layoutOf(fixture).levels)
          level.index: _levelController(tester, level.index),
      };
      controller.selection = const TextSelection.collapsed(offset: 2);
      final option = find.byKey(const Key('tree-search-option-Мать'));
      for (final size in [
        const Size(844, 390),
        const Size(1100, 700),
        const Size(390, 844),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field).controller, same(controller));
        expect(tester.widget<TextField>(field).focusNode, same(focus));
        for (final entry in levelControllers.entries) {
          expect(_levelController(tester, entry.key), same(entry.value));
          expect(entry.value.positions, hasLength(1));
        }
        expect(focus.hasFocus, isTrue);
        expect(controller.text, 'Мать');
        expect(controller.selection.baseOffset, 2);
        expect(
          tester.getSize(field).width,
          size.width < 900 ? size.width - 8 : 240,
        );
        expect(option, findsOneWidget);
        _expectInside(tester.getRect(option), Offset.zero & size);
        expect(
          find.byKey(const Key('tree-search-back')),
          size.width < 900 ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byKey(const Key('tree-search-back')));
      await tester.pumpAndSettle();
      _expectToolbarFits(tester);
      expect(session.operations, isEmpty);
    },
  );

  for (final size in [
    const Size(1100, 450),
    const Size(1100, 700),
    const Size(1440, 900),
  ]) {
    testWidgets(
      'desktop search keeps its right-aligned fixed width on focus at $size',
      (tester) async {
        final session = _Session(_family().document, editingAllowed: true);
        await _mount(tester, session, size: size);
        final field = find.byKey(const Key('tree-search-field'));
        final before = tester.getRect(field);
        final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
        expect(before.width, 240);
        await tester.enterText(field, 'Мать');
        await tester.pumpAndSettle();
        expect(tester.getRect(field), before);
        expect(tester.getRect(find.byKey(const Key('tree-canvas'))), canvas);
        expect(find.byKey(const Key('tree-search-back')), findsNothing);
        _expectToolbarFits(tester);
        final option = find.byKey(const Key('tree-search-option-Мать'));
        expect(option, findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(option, findsNothing);
        expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
        expect(tester.getRect(field), before);
        _expectToolbarFits(tester);
        expect(session.operations, isEmpty);
      },
    );
  }

  for (final picker in [false, true]) {
    testWidgets(
      '${picker ? 'confirmation' : 'biography'} floating action is 56px with a 28px icon',
      (tester) async {
        final fixture = _family();
        final session = _Session(fixture.document);
        final picked = <String>[];
        var allowed = false;
        await _mount(
          tester,
          session,
          size: const Size(390, 844),
          onPickPerson: picker ? picked.add : null,
          canPickPerson: picker ? (_) => allowed : null,
        );
        final action = find.byKey(
          Key(picker ? 'confirm-tree-person' : 'open-biography'),
        );
        final icon = find.descendant(
          of: action,
          matching: find.byIcon(picker ? Icons.check : Icons.badge_outlined),
        );
        expect(tester.getSize(action), const Size.square(56));
        expect(tester.getSize(icon), const Size.square(28));
        expect(
          find.byTooltip(picker ? 'Подтвердить выбор' : 'Биография'),
          findsOneWidget,
        );
        if (picker) {
          expect(tester.widget<IconButton>(action).onPressed, isNull);
          allowed = true;
          session.changed();
          await tester.pumpAndSettle();
          expect(tester.widget<IconButton>(action).onPressed, isNotNull);
          expect(tester.getSize(action), const Size.square(56));
          await tester.tap(action);
          await tester.pumpAndSettle();
          expect(picked, [rootTreePersonId]);
        } else {
          await tester.tap(action);
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('tree-biography-route')), findsOneWidget);
        }
        expect(session.operations, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('landscape toolbar stays one row beside an open biography', (
    tester,
  ) async {
    final session = _Session(_family().document);
    await _mount(tester, session, size: const Size(1100, 700));
    await tester.tap(find.byKey(const Key('open-biography')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tree-biography-panel')), findsOneWidget);
    _expectToolbarFits(tester);
    final toolbarHeight = tester
        .getSize(find.byKey(const Key('tree-toolbar')))
        .height;
    final canvasHeight = tester
        .getSize(find.byKey(const Key('tree-canvas')))
        .height;
    await tester.tap(find.byKey(const Key('tree-toolbar-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tree-toolbar')), findsNothing);
    expect(find.byKey(const Key('tree-biography-panel')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('tree-canvas'))).height,
      closeTo(canvasHeight + toolbarHeight, .1),
    );
    await tester.tap(find.byKey(const Key('tree-toolbar-toggle')));
    await tester.pumpAndSettle();
    _expectToolbarFits(tester);
    expect(session.operations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop biography is a 360px panel alongside the canvas', (
    tester,
  ) async {
    final fixture = _family();
    await _mount(tester, _Session(fixture.document));
    final before = tester.getSize(find.byKey(const Key('tree-canvas'))).width;
    await tester.tap(find.byKey(const Key('open-biography')));
    await tester.pumpAndSettle();
    final biography = tester.widget<PersonBiography>(
      find.byType(PersonBiography),
    );
    final panel = tester.getRect(find.byKey(const Key('tree-biography-panel')));
    final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
    expect(panel.width, 360);
    expect(canvas.width, before - 360);
    expect(canvas.right, panel.left);
    expect(biography.fullScreen, isFalse);
    expect(biography.personId, rootTreePersonId);

    biography.onSelect('Мать');
    await tester.pumpAndSettle();
    expect(
      tester.widget<PersonBiography>(find.byType(PersonBiography)).personId,
      'Мать',
    );
    await tester.tap(find.byKey(const Key('biography-close')));
    await tester.pumpAndSettle();
    expect(find.byType(PersonBiography), findsNothing);
    expect(tester.getSize(find.byKey(const Key('tree-canvas'))).width, before);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mobile biography is a route and relative selection returns to tree',
    (tester) async {
      final fixture = _family();
      await _mount(
        tester,
        _Session(fixture.document),
        size: const Size(390, 844),
      );
      final mainBefore = _mainController(tester).offset;
      final fatherBefore = tester.getRect(_person('Отец'));
      _expectInside(
        fatherBefore,
        tester.getRect(find.byKey(const Key('tree-canvas'))),
      );
      await tester.tap(find.byKey(const Key('open-biography')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tree-biography-route')), findsOneWidget);
      final biography = tester.widget<PersonBiography>(
        find.byType(PersonBiography),
      );
      expect(biography.fullScreen, isTrue);
      biography.onSelect('Отец');
      await tester.pumpAndSettle();
      expect(find.byType(PersonBiography), findsNothing);
      expect(
        _nodeSemantics(tester, 'Отец').flagsCollection.isSelected ==
            Tristate.isTrue,
        isTrue,
      );
      expect(_mainController(tester).offset, mainBefore);
      expect(tester.getRect(_person('Отец')), fatherBefore);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('long node hover shows no tooltip; toolbar hover still does', (
    tester,
  ) async {
    const name = 'Очень длинное имя родственника, не помещающееся на карточке';
    final fixture = _family()..name('Мать', name);
    await _mount(tester, _Session(fixture.document));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    expect(find.textContaining(name), findsOneWidget);
    expect(find.text('Увеличить масштаб'), findsNothing);
    await mouse.moveTo(tester.getCenter(_person('Мать')));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.textContaining(name), findsOneWidget);
    expect(find.byTooltip(name), findsNothing);
    expect(
      find.descendant(of: _person('Мать'), matching: find.byType(Tooltip)),
      findsNothing,
    );
    expect(_nodeSemantics(tester, name).flagsCollection.isButton, isTrue);
    await mouse.moveTo(tester.getCenter(find.byKey(const Key('tree-zoom-in'))));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Увеличить масштаб'), findsOneWidget);
    expect(find.text('Увеличить масштаб'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final portrait in [true, false]) {
    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} aunts and siblings of higher ancestors use cousin filters and olive washes in every mode',
      (tester) async {
        final fixture = _family(siblings: 1, children: 1)
          ..add('Дядя', sex: TreeSex.male)
          ..parents('Дядя', father: 'Дед', mother: 'Бабушка')
          ..add('Кузен')
          ..parents('Кузен', father: 'Дядя')
          ..add('Дед матери', sex: TreeSex.male)
          ..add('Бабушка матери', sex: TreeSex.female)
          ..parents('Мать', father: 'Дед матери', mother: 'Бабушка матери')
          ..add('Тётя матери', sex: TreeSex.female)
          ..parents(
            'Тётя матери',
            father: 'Дед матери',
            mother: 'Бабушка матери',
          )
          ..add('Полудядя матери', sex: TreeSex.male)
          ..parents('Полудядя матери', mother: 'Бабушка матери')
          ..add('Прадед', sex: TreeSex.male)
          ..add('Прабабушка', sex: TreeSex.female)
          ..parents('Дед', father: 'Прадед', mother: 'Прабабушка')
          ..add('Брат деда', sex: TreeSex.male)
          ..parents('Брат деда', father: 'Прадед', mother: 'Прабабушка')
          ..add('Полусестра деда', sex: TreeSex.female)
          ..parents('Полусестра деда', mother: 'Прабабушка')
          ..add('Прапрадед', sex: TreeSex.male)
          ..add('Прапрабабушка', sex: TreeSex.female)
          ..parents('Прадед', father: 'Прапрадед', mother: 'Прапрабабушка')
          ..add('Брат прадеда', sex: TreeSex.male)
          ..parents(
            'Брат прадеда',
            father: 'Прапрадед',
            mother: 'Прапрабабушка',
          )
          ..add('Полубрат прадеда', sex: TreeSex.male)
          ..parents('Полубрат прадеда', father: 'Прапрадед')
          ..add('Дальний');
        for (final id in ['Дядя', 'Полусестра деда', 'Полубрат прадеда']) {
          fixture.apply(
            fixture.document.addPhoto(id, 'portrait', dataUrl: _png),
          );
        }
        final session = _Session(fixture.document, editingAllowed: true);
        final peopleBefore = fixture.document.people;
        await _mount(
          tester,
          session,
          size: portrait ? const Size(900, 1500) : const Size(1500, 1000),
        );
        for (final mode in TreeTrunkMode.values) {
          await _chooseMode(tester, mode);
          final cousinFilter = _filterOf(tester, 'Кузен');
          expect(cousinFilter, isNot(_filterOf(tester, 'Дальний')));
          for (final id in [
            'Дядя',
            'Тётя матери',
            'Полудядя матери',
            'Брат деда',
            'Полусестра деда',
            'Брат прадеда',
            'Полубрат прадеда',
          ]) {
            expect(
              _filterOf(tester, id),
              cousinFilter,
              reason: '${mode.name}: $id',
            );
            final sharesNormalBlock = [
              'Дядя',
              'Тётя матери',
              'Брат деда',
              'Брат прадеда',
            ].contains(id);
            expect(
              _washOf(tester, fixture, id),
              const Color(
                0xFF85884A,
              ).withValues(alpha: sharesNormalBlock ? .24 : .14),
              reason: sharesNormalBlock
                  ? '${mode.name}: normal relatives take precedence in $id’s shared block.'
                  : '${mode.name}: $id’s cousin-only block has a lighter olive wash.',
            );
            expect(
              find.descendant(of: _filterFor(id), matching: find.text(id)),
              findsOneWidget,
              reason: 'The cousin filter includes $id’s text.',
            );
          }
          for (final id in ['Дядя', 'Полусестра деда', 'Полубрат прадеда']) {
            expect(
              find.descendant(of: _filterFor(id), matching: find.byType(Image)),
              findsOneWidget,
              reason: 'The cousin filter includes $id’s photograph.',
            );
          }
          for (final id in [
            rootTreePersonId,
            'Отец',
            'Мать',
            'Дед',
            'Прадед',
            'Прапрадед',
            'Сестра-0',
            'Ребёнок-0',
          ]) {
            expect(_filterFor(id), findsNothing, reason: '${mode.name}: $id');
          }
          final positions = _layoutOf(fixture).positions;
          expect(positions['Дядя']!.blockId, positions['Отец']!.blockId);
          expect(
            _washOf(tester, fixture, 'Дядя'),
            _washOf(tester, fixture, 'Отец'),
          );
          expect(
            _washOf(tester, fixture, rootTreePersonId),
            const Color(0xFF85884A).withValues(alpha: .24),
          );
          expect(
            _washOf(tester, fixture, 'Кузен'),
            const Color(0xFF85884A).withValues(alpha: .14),
          );
          expect(
            _washOf(tester, fixture, 'Кузен'),
            isNot(_washOf(tester, fixture, rootTreePersonId)),
            reason:
                'Cousin-only blocks must visibly differ from normal blocks.',
          );
          expect(
            _washOf(tester, fixture, 'Дальний'),
            const Color(0xFF686C65).withValues(alpha: .24),
          );
        }
        expect(session.operations, isEmpty);
        expect(identical(fixture.document.people, peopleBefore), isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} the exact rendered connection set is independent of trunk mode across ancestor, collateral and descendant blocks',
      (tester) async {
        final fixture = _family(siblings: 1, children: 2)
          ..add('Мамин отец', sex: TreeSex.male)
          ..add('Мамина мать', sex: TreeSex.female)
          ..parents('Мать', father: 'Мамин отец', mother: 'Мамина мать')
          ..add('Мамина сестра', sex: TreeSex.female)
          ..parents(
            'Мамина сестра',
            father: 'Мамин отец',
            mother: 'Мамина мать',
          )
          ..add('Муж тёти', sex: TreeSex.male)
          ..add('Дядя', sex: TreeSex.male)
          ..parents('Дядя', father: 'Дед', mother: 'Бабушка')
          ..add('Жена дяди', sex: TreeSex.female)
          ..add('Отчим', sex: TreeSex.male)
          ..add('Мачеха', sex: TreeSex.female)
          ..add('Материнская полусестра', sex: TreeSex.female)
          ..parents('Материнская полусестра', father: 'Отчим', mother: 'Мать')
          ..add('Полубрат', sex: TreeSex.male)
          ..parents('Полубрат', father: 'Отец', mother: 'Мачеха')
          ..add('Сноха', sex: TreeSex.female)
          ..add('Зять', sex: TreeSex.male)
          ..add('Невестка', sex: TreeSex.female)
          ..add('Отец партнёра', sex: TreeSex.male)
          ..add('Мать партнёра', sex: TreeSex.female)
          ..parents('Партнёр', father: 'Отец партнёра', mother: 'Мать партнёра')
          ..add('Дальний родитель')
          ..add('Дальний ребёнок')
          ..parents('Дальний ребёнок', father: 'Дальний родитель')
          ..add('Племянник от деда')
          ..parents('Племянник от деда', father: 'Дед', mother: 'Сестра-0');
        for (var i = 0; i < 2; i++) {
          fixture
            ..add('Кузен-$i')
            ..parents('Кузен-$i', father: 'Дядя', mother: 'Жена дяди')
            ..add('Мамин кузен-$i')
            ..parents(
              'Мамин кузен-$i',
              father: 'Муж тёти',
              mother: 'Мамина сестра',
            )
            ..add('Внук-$i')
            ..parents('Внук-$i', father: 'Ребёнок-0', mother: 'Сноха')
            ..add('Племянник-$i')
            ..parents('Племянник-$i', father: 'Зять', mother: 'Сестра-0')
            ..add('Полуплемянник-$i')
            ..parents(
              'Полуплемянник-$i',
              father: 'Полубрат',
              mother: 'Невестка',
            );
        }
        // Exercise both dated and undated deterministic collateral choices.
        for (final entry in {
          'Мамина сестра': '1960-01-01',
          'Муж тёти': '1965-01-01',
          'Полубрат': '1980-01-01',
          'Невестка': '1985-01-01',
        }.entries) {
          fixture.apply(
            fixture.document.setValue(entry.key, 'birthDate', entry.value),
          );
        }
        final session = _Session(fixture.document, editingAllowed: true);
        final peopleBefore = fixture.document.people;
        await _mount(
          tester,
          session,
          size: portrait ? const Size(900, 1500) : const Size(1500, 1000),
        );
        final layout = _layoutOf(fixture);
        String block(String id) => 'block:${layout.positions[id]!.blockId}';
        final expected = <(String, String)>{
          ('Дед', 'person:Отец'),
          ('Бабушка', 'person:Отец'),
          ('Мамин отец', 'person:Мать'),
          ('Мамина мать', 'person:Мать'),
          ('Отец', 'person:$rootTreePersonId'),
          ('Мать', 'person:$rootTreePersonId'),
          ('Отчим', block('Материнская полусестра')),
          ('Мать', block('Материнская полусестра')),
          ('Отец', block('Полубрат')),
          ('Мачеха', block('Полубрат')),
          (rootTreePersonId, block('Ребёнок-0')),
          ('Партнёр', block('Ребёнок-0')),
          ('Дядя', block('Кузен-0')),
          ('Мамина сестра', block('Мамин кузен-0')),
          ('Ребёнок-0', block('Внук-0')),
          ('Сестра-0', block('Племянник-0')),
          ('Полубрат', block('Полуплемянник-0')),
          ('Дед', block('Племянник от деда')),
        };
        for (final mode in [
          TreeTrunkMode.both,
          TreeTrunkMode.father,
          TreeTrunkMode.mother,
          TreeTrunkMode.both,
        ]) {
          await _chooseMode(tester, mode);
          final current = _layoutOf(fixture, mode: mode);
          expect(
            _renderedConnections(tester, current, portrait: portrait),
            expected,
            reason:
                '${mode.name} changes ordering/centering, never edge identities.',
          );
          _expectCanonicalRowGeometry(tester, current, portrait: portrait);
          expect(session.operations, isEmpty);
          expect(identical(fixture.document.people, peopleBefore), isTrue);
        }
        expect(tester.takeException(), isNull);
      },
    );

    for (final dated in [false, true]) {
      testWidgets(
        '${portrait ? 'portrait' : 'landscape'} a ${dated ? 'dated' : 'undated'} shared ancestor sibling block keeps the same avatar target and both parents in every trunk mode',
        (tester) async {
          final fixture = _Fixture()
            ..name(rootTreePersonId, 'Я')
            ..add('a-father', sex: TreeSex.male)
            ..add('z-mother', sex: TreeSex.female)
            ..add('00-aunt', sex: TreeSex.female)
            ..add('grandfather', sex: TreeSex.male)
            ..add('grandmother', sex: TreeSex.female)
            ..parents(rootTreePersonId, father: 'a-father', mother: 'z-mother');
          for (final id in ['a-father', 'z-mother', '00-aunt']) {
            fixture.parents(id, father: 'grandfather', mother: 'grandmother');
          }
          if (dated) {
            for (final entry in {
              '00-aunt': '1950-01-01',
              'z-mother': '1960-01-01',
              'a-father': '1970-01-01',
            }.entries) {
              fixture.apply(
                fixture.document.setValue(entry.key, 'birthDate', entry.value),
              );
            }
          }
          final session = _Session(fixture.document, editingAllowed: true);
          final peopleBefore = fixture.document.people;
          await _mount(
            tester,
            session,
            size: portrait ? const Size(700, 1200) : const Size(1200, 750),
          );
          final expected = <(String, String)>{
            ('grandfather', 'person:${dated ? 'z-mother' : 'a-father'}'),
            ('grandmother', 'person:${dated ? 'z-mother' : 'a-father'}'),
            ('a-father', 'person:$rootTreePersonId'),
            ('z-mother', 'person:$rootTreePersonId'),
          };
          for (final mode in TreeTrunkMode.values) {
            await _chooseMode(tester, mode);
            final layout = _layoutOf(fixture, mode: mode);
            final block = layout.levels
                .expand((level) => level.blocks)
                .singleWhere(
                  (block) =>
                      block.people.any((person) => person.id == 'z-mother'),
                );
            expect(block.people.first.id, '00-aunt');
            expect(
              block.people.map((person) => person.id),
              dated || mode == TreeTrunkMode.both
                  ? ['00-aunt', 'z-mother', 'a-father']
                  : ['00-aunt', 'a-father', 'z-mother'],
              reason:
                  '${mode.name}: single modes retain birth/ID order; only both mode may expose the actual parent seam.',
            );
            expect(
              _renderedConnections(tester, layout, portrait: portrait),
              expected,
              reason:
                  '${mode.name}: choose a stable real ancestor, not the preferred trunk or first non-ancestor aunt.',
            );
            _expectCanonicalRowGeometry(tester, layout, portrait: portrait);
          }
          expect(session.operations, isEmpty);
          expect(identical(fixture.document.people, peopleBefore), isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} full and maternal/paternal half-sibling blocks retain both real parents in every mode',
      (tester) async {
        final fixture = _family(siblings: 2, children: 0)
          ..add('Отчим', sex: TreeSex.male)
          ..add('Мачеха', sex: TreeSex.female);
        for (var i = 0; i < 3; i++) {
          fixture
            ..add('Материнский полубрат-$i', sex: TreeSex.male)
            ..parents(
              'Материнский полубрат-$i',
              father: 'Отчим',
              mother: 'Мать',
            )
            ..add('Отцовская полусестра-$i', sex: TreeSex.female)
            ..parents(
              'Отцовская полусестра-$i',
              father: 'Отец',
              mother: 'Мачеха',
            );
        }
        final session = _Session(fixture.document, editingAllowed: true);
        final peopleBefore = fixture.document.people;
        await _mount(
          tester,
          session,
          size: portrait ? const Size(900, 1500) : const Size(1500, 1000),
        );
        final siblingFamilies = <String, List<String>>{
          rootTreePersonId: ['Отец', 'Мать'],
          'Материнский полубрат-0': ['Отчим', 'Мать'],
          'Отцовская полусестра-0': ['Отец', 'Мачеха'],
        };
        for (final mode in TreeTrunkMode.values) {
          await _chooseMode(tester, mode);
          for (final selected in [
            rootTreePersonId,
            'Сестра-1',
            'Материнский полубрат-0',
            'Отцовская полусестра-0',
          ]) {
            await _selectPerson(tester, selected);
            final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
            final drawing = _ConnectionCanvas();
            _linkPainter(tester).paint(drawing, canvas.size);
            Rect local(Finder finder) =>
                tester.getRect(finder).shift(-canvas.topLeft);
            final selectedBlock = _layoutOf(
              fixture,
            ).positions[selected]!.blockId;
            final selectedParents = selected.startsWith('Материнский')
                ? siblingFamilies['Материнский полубрат-0']!
                : selected.startsWith('Отцовская')
                ? siblingFamilies['Отцовская полусестра-0']!
                : siblingFamilies[rootTreePersonId]!;
            for (final entry in siblingFamilies.entries) {
              // Opposite half-siblings need not be siblings of each other.
              if (!entry.value.any(selectedParents.contains)) continue;
              final isFocusBlock =
                  _layoutOf(fixture).positions[entry.key]!.blockId ==
                  selectedBlock;
              final block = local(_blockFor(fixture, entry.key));
              final node = local(_person(isFocusBlock ? selected : entry.key));
              final target = isFocusBlock
                  ? portrait
                        ? Offset(node.center.dx - 30, node.top + 36)
                        : Offset(node.center.dx, node.top + 6)
                  : portrait
                  ? block.centerLeft
                  : block.topCenter;
              if (!isFocusBlock) {
                expect(
                  (_cross(target, portrait) - _cross(node.center, portrait))
                      .abs(),
                  greaterThan(100),
                  reason: 'Context attaches to the entire full-sibling block.',
                );
              }
              final incoming = drawing.paths
                  .where((path) => (_pathEnd(path) - target).distance < .1)
                  .toList();
              expect(
                incoming,
                hasLength(2),
                reason:
                    '${mode.name}, selected $selected: ${entry.key} needs both parents.',
              );
              for (final parentId in entry.value) {
                final parent = local(_person(parentId));
                final anchor = portrait
                    ? Offset(parent.center.dx + 30, parent.top + 36)
                    : Offset(parent.center.dx, parent.top + 66);
                expect(
                  incoming.any(
                    (path) => (_pathStart(path) - anchor).distance < .1,
                  ),
                  isTrue,
                  reason:
                      '${mode.name}, selected $selected: missing $parentId → ${entry.key}.',
                );
              }
              for (final path in incoming) {
                final color = drawing.colors[drawing.paths.indexOf(path)];
                expect(color.a, closeTo(.60, 1 / 255));
              }
            }
          }
        }
        expect(session.operations, isEmpty);
        expect(identical(fixture.document.people, peopleBefore), isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} only selected co-parents regain full node/photo/text colors, including live unlink and deletion changes',
      (tester) async {
        final fixture = _coParentFamily();
        final session = _Session(fixture.document, editingAllowed: true);
        await _mount(
          tester,
          session,
          size: portrait ? const Size(1200, 1800) : const Size(1800, 1200),
        );
        final peopleBefore = fixture.document.people;
        const normalFemale = Color(0xFF28644B);
        final distantFilter = _filterOf(tester, 'Сестра партнёра');
        final cousinFilter = _filterOf(tester, 'Сестра кузины');
        expect(distantFilter, isNot(cousinFilter));
        void expectSiblingContext() {
          for (final entry in {
            'Партнёр': 'Сестра партнёра',
            'Кузина-партнёр': 'Сестра кузины',
          }.entries) {
            final cousin = entry.key == 'Кузина-партнёр';
            final model = _layoutOf(fixture);
            expect(
              model.positions[entry.key]!.blockId,
              model.positions[entry.value]!.blockId,
              reason: 'The co-parent shares a real full-sibling block.',
            );
            expect(
              model.positions[entry.key]!.emphasis,
              cousin ? TreeEmphasis.cousin : TreeEmphasis.distant,
              reason: 'A node-only exception must not promote model emphasis.',
            );
            final filter = cousin ? cousinFilter : distantFilter;
            expect(_filterOf(tester, entry.value), filter);
            expect(
              find.descendant(
                of: _filterFor(entry.value),
                matching: find.byType(Image),
              ),
              findsOneWidget,
            );
            expect(
              find.descendant(
                of: _filterFor(entry.value),
                matching: find.text(entry.value),
              ),
              findsOneWidget,
            );
            expect(
              _washOf(tester, fixture, entry.key),
              (cousin ? const Color(0xFF85884A) : const Color(0xFF686C65))
                  .withValues(alpha: cousin ? .14 : .24),
              reason:
                  'Promoting only a co-parent node must not change its block wash.',
            );
          }
        }

        for (final mode in TreeTrunkMode.values) {
          await _chooseMode(tester, mode);
          await _selectPerson(tester, rootTreePersonId);
          final layoutBefore = _layoutOf(fixture, mode: mode);
          final positionsBefore = {
            for (final id in fixture.document.people.keys)
              id: tester.getRect(_person(id)),
          };
          for (final id in ['Партнёр', 'Кузина-партнёр']) {
            _expectFullColorPhotoNode(tester, id, normalFemale);
          }
          expectSiblingContext();
          await _selectPerson(tester, 'Сестра-0');
          expect(_filterOf(tester, 'Партнёр'), distantFilter);
          expect(_filterOf(tester, 'Кузина-партнёр'), cousinFilter);
          expectSiblingContext();
          // Losing the selected node's co-parents may require a canonical
          // BOTH row reorder. Coloring itself must not disturb unchanged rows,
          // and single-trunk modes still never need a co-parent reorder.
          final unchangedRows = _expectPreservedOrCanonicalRows(
            tester,
            beforeLayout: layoutBefore,
            afterLayout: _layoutOf(fixture, selectedId: 'Сестра-0', mode: mode),
            before: positionsBefore,
            portrait: portrait,
            reason: '${mode.name}: changing co-parent node colors',
          );
          if (mode != TreeTrunkMode.both) {
            expect(unchangedRows, hasLength(layoutBefore.levels.length));
          }
          await _selectPerson(tester, rootTreePersonId);
          for (final id in ['Партнёр', 'Кузина-партнёр']) {
            _expectFullColorPhotoNode(tester, id, normalFemale);
          }
          expectSiblingContext();
        }
        expect(identical(fixture.document.people, peopleBefore), isTrue);
        expect(session.operations, isEmpty);

        Future<void> remoteChange(TreeOperation operation) async {
          fixture.apply(operation);
          final people = fixture.document.people;
          session.changed();
          await tester.pumpAndSettle();
          expect(identical(fixture.document.people, people), isTrue);
          expect(
            session.operations,
            isEmpty,
            reason: 'Viewing remote edits must not write history.',
          );
        }

        await remoteChange(
          fixture.document.setValue('Ребёнок-0', 'motherId', null),
        );
        _expectFullColorPhotoNode(tester, 'Партнёр', normalFemale);
        // The remaining shared child still makes this person a co-parent.
        await remoteChange(fixture.document.deletePerson('Ребёнок-1'));
        expect(_filterOf(tester, 'Партнёр'), distantFilter);
        _expectFullColorPhotoNode(tester, 'Кузина-партнёр', normalFemale);
        expectSiblingContext();

        await remoteChange(
          fixture.document.setValue('Ребёнок кузины', 'fatherId', null),
        );
        expect(_filterOf(tester, 'Кузина-партнёр'), cousinFilter);
        expectSiblingContext();
        await remoteChange(
          fixture.document.setValue('Ребёнок-0', 'motherId', 'Партнёр'),
        );
        _expectFullColorPhotoNode(tester, 'Партнёр', normalFemale);
        await remoteChange(fixture.document.deletePerson('Партнёр'));
        expect(_person('Партнёр'), findsNothing);
        expect(_filterOf(tester, 'Сестра партнёра'), distantFilter);
        expect(_filterOf(tester, 'Кузина-партнёр'), cousinFilter);
        expect(
          _washOf(tester, fixture, 'Сестра партнёра'),
          const Color(0xFF686C65).withValues(alpha: .24),
        );

        await remoteChange(
          fixture.document.setValue(
            'Ребёнок кузины',
            'fatherId',
            rootTreePersonId,
          ),
        );
        _expectFullColorPhotoNode(tester, 'Кузина-партнёр', normalFemale);
        await remoteChange(fixture.document.deletePerson('Ребёнок кузины'));
        expect(_filterOf(tester, 'Кузина-партнёр'), cousinFilter);
        expect(_filterOf(tester, 'Сестра кузины'), cousinFilter);
        expect(
          _washOf(tester, fixture, 'Кузина-партнёр'),
          const Color(0xFF85884A).withValues(alpha: .14),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'distant cards and their photos/text are monochrome; cousins faded',
    (tester) async {
      final fixture = _family()
        ..add('Дядя', sex: TreeSex.male)
        ..parents('Дядя', father: 'Дед', mother: 'Бабушка')
        ..add('Кузен')
        ..parents('Кузен', father: 'Дядя')
        ..add('Дальний');
      fixture.apply(
        fixture.document.addPhoto('Дальний', 'portrait', dataUrl: _png),
      );
      fixture.apply(
        fixture.document.setValue('Дальний', 'avatarPhotoId', 'portrait'),
      );
      await _mount(tester, _Session(fixture.document));

      expect(
        find.descendant(
          of: _person('Дальний'),
          matching: find.byType(ColorFiltered),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _person('Дальний'), matching: find.byType(Image)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _person('Дальний'), matching: find.text('Дальний')),
        findsOneWidget,
      );
      final distant = tester.widget<ColorFiltered>(
        find.descendant(
          of: _person('Дальний'),
          matching: find.byType(ColorFiltered),
        ),
      );
      final cousin = tester.widget<ColorFiltered>(
        find.descendant(
          of: _person('Кузен'),
          matching: find.byType(ColorFiltered),
        ),
      );
      expect(distant.colorFilter, isNot(cousin.colorFilter));
      expect(
        find.descendant(
          of: _person(rootTreePersonId),
          matching: find.byType(ColorFiltered),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final portrait in [true, false]) {
    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} full and half nephews match cousins without losing muted parent links',
      (tester) async {
        final fixture = _family(siblings: 1, children: 1)
          ..add('Дядя', sex: TreeSex.male)
          ..parents('Дядя', father: 'Дед', mother: 'Бабушка')
          ..add('Тётя', sex: TreeSex.female)
          ..add('Кузен')
          ..parents('Кузен', father: 'Дядя', mother: 'Тётя')
          ..add('Мачеха', sex: TreeSex.female)
          ..add('Полубрат', sex: TreeSex.male)
          ..parents('Полубрат', father: 'Отец', mother: 'Мачеха')
          ..add('Невестка', sex: TreeSex.female)
          ..add('Племянница')
          ..parents('Племянница', father: 'Полубрат', mother: 'Невестка')
          ..add('Зять', sex: TreeSex.male)
          ..add('Племянник')
          ..parents('Племянник', father: 'Зять', mother: 'Сестра-0')
          ..add('Дальний')
          // Also a sibling's child, but direct descent must stay normal.
          ..parents('Ребёнок-0', mother: 'Сестра-0');
        await _mount(
          tester,
          _Session(fixture.document),
          size: portrait ? const Size(900, 1500) : const Size(1500, 1000),
        );
        ColorFilter filterOf(String id) => _filterOf(tester, id);
        Color washOf(String id) => _washOf(tester, fixture, id);
        for (final mode in TreeTrunkMode.values) {
          await _chooseMode(tester, mode);
          final cousinFilter = filterOf('Кузен');
          expect(cousinFilter, isNot(filterOf('Дальний')));
          for (final id in ['Кузен', 'Племянник', 'Племянница']) {
            expect(filterOf(id), cousinFilter, reason: '${mode.name}: $id');
            expect(
              washOf(id),
              const Color(0xFF85884A).withValues(alpha: .14),
              reason:
                  '$id keeps the lighter cousin olive wash, not normal olive or distant grey.',
            );
          }
          expect(
            washOf('Дальний'),
            const Color(0xFF686C65).withValues(alpha: .24),
          );
          expect(
            find.descendant(
              of: _person('Ребёнок-0'),
              matching: find.byType(ColorFiltered),
            ),
            findsNothing,
            reason: 'Direct descendants win over nephew emphasis.',
          );
          final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
          final drawing = _ConnectionCanvas();
          _linkPainter(tester).paint(drawing, canvas.size);
          Rect local(Finder finder) =>
              tester.getRect(finder).shift(-canvas.topLeft);
          for (final entry in {
            'Кузен': ['Дядя', 'Тётя'],
            'Племянник': ['Зять', 'Сестра-0'],
            'Племянница': ['Полубрат', 'Невестка'],
            'Ребёнок-0': [rootTreePersonId, 'Сестра-0'],
          }.entries) {
            final block = local(_blockFor(fixture, entry.key));
            final target = portrait ? block.centerLeft : block.topCenter;
            final indices = [
              for (var i = 0; i < drawing.paths.length; i++)
                if ((_pathEnd(drawing.paths[i]) - target).distance < .1) i,
            ];
            final direct = entry.key == 'Ребёнок-0';
            expect(
              indices,
              hasLength(direct ? 2 : 1),
              reason:
                  '${mode.name}: ${entry.key} retains the existing parent policy.',
            );
            for (final index in indices) {
              final parents = entry.value.where((id) {
                final rect = local(_person(id));
                final anchor = portrait
                    ? Offset(rect.center.dx + 30, rect.top + 36)
                    : Offset(rect.center.dx, rect.top + 66);
                return (_pathStart(drawing.paths[index]) - anchor).distance <
                    .1;
              }).toList();
              expect(parents, hasLength(1), reason: entry.key);
              final palette = switch (fixture.document
                  .person(parents.single)!
                  .sex) {
                TreeSex.male => const Color(0xFFAE742C),
                TreeSex.female => const Color(0xFF338B64),
                TreeSex.unknown => const Color(0xFF8A9087),
              };
              final expected =
                  (direct
                          ? palette
                          : Color.lerp(const Color(0xFF686C65), palette, .35)!)
                      .withValues(alpha: direct ? .60 : .40);
              _expectPaintRgb(drawing.colors[index], expected);
              expect(
                drawing.colors[index].a,
                closeTo(direct ? .60 : .40, 1 / 255),
              );
            }
          }
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('real parent links survive all modes and reproject on scroll', (
    tester,
  ) async {
    final fixture = _family(siblings: 10, children: 10)
      ..add('Другой родитель')
      ..add('Дальний ребёнок')
      ..parents(
        'Дальний ребёнок',
        father: 'Другой родитель',
        mother: 'Партнёр',
      );
    await _mount(tester, _Session(fixture.document));
    for (final mode in TreeTrunkMode.values) {
      await _chooseMode(tester, mode);
      final canvas = _ConnectionCanvas();
      _linkPainter(tester).paint(canvas, const Size(1100, 650));
      // Two grandparents -> father's block; two parents -> focus siblings;
      // both focus and co-parent -> direct child block. No distant-block link.
      expect(canvas.paths, hasLength(6), reason: mode.name);
      final sexColors = [
        const Color(0xFFAE742C),
        const Color(0xFF338B64),
        const Color(0xFF8A9087),
      ];
      expect(
        canvas.colors.map((color) => color.toARGB32()).toSet(),
        {
          for (final color in sexColors)
            color.withValues(alpha: .60).toARGB32(),
        },
        reason: '${mode.name}: normal links keep the brighter gender palette.',
      );
      for (final color in canvas.colors) {
        expect(color.a, closeTo(.60, 1 / 255));
      }
    }
    final painter = _linkPainter(tester);
    final before = _ConnectionCanvas();
    painter.paint(before, const Size(1100, 650));
    final focus = _levelController(tester, _levelOf(fixture, rootTreePersonId));
    focus.jumpTo(focus.offset + 80);
    await tester.pump();
    final after = _ConnectionCanvas();
    painter.paint(after, const Size(1100, 650));
    expect(identical(_linkPainter(tester), painter), isTrue);
    expect(
      after.paths.map((path) => path.getBounds()).toList(),
      isNot(before.paths.map((path) => path.getBounds()).toList()),
    );
    expect(tester.takeException(), isNull);
  });

  for (final portrait in [true, false]) {
    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} rounded-square avatars and opaque names mask links behind the cards',
      (tester) async {
        final fixture = _family(siblings: 1);
        fixture.apply(
          fixture.document.addPhoto(
            rootTreePersonId,
            'portrait',
            dataUrl: _png,
          ),
        );
        await _mount(
          tester,
          _Session(fixture.document),
          size: portrait ? const Size(430, 900) : const Size(1100, 850),
        );
        final theme = Theme.of(tester.element(_person(rootTreePersonId)));
        for (final id in [rootTreePersonId, 'Отец']) {
          expect(tester.getSize(_person(id)), const Size.square(108));
          final avatarClip = find.descendant(
            of: _person(id),
            matching: find.byType(ClipRRect),
          );
          final clip = tester.widget<ClipRRect>(avatarClip);
          expect(clip.borderRadius, BorderRadius.circular(10));
          expect(clip.clipBehavior, Clip.antiAlias);
          final ring = find.descendant(
            of: _person(id),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is DecoratedBox &&
                  widget.decoration is BoxDecoration &&
                  (widget.decoration as BoxDecoration).border != null,
            ),
          );
          expect(ring, findsOneWidget);
          expect(tester.getSize(ring), const Size.square(60));
          expect(tester.getRect(avatarClip), tester.getRect(ring).deflate(3));
          final decoration =
              tester.widget<DecoratedBox>(ring).decoration as BoxDecoration;
          expect(decoration.shape, BoxShape.rectangle);
          expect(decoration.borderRadius, BorderRadius.circular(14));
          final border = decoration.border! as Border;
          for (final side in [
            border.top,
            border.right,
            border.bottom,
            border.left,
          ]) {
            expect(side.width, 3);
          }
          final material = tester.widget<Material>(
            find.descendant(of: _person(id), matching: find.byType(Material)),
          );
          final shape = material.shape! as RoundedRectangleBorder;
          expect(
            material.color,
            id == rootTreePersonId
                ? theme.colorScheme.surfaceContainerLowest.withValues(alpha: .5)
                : Colors.transparent,
          );
          expect(shape.side.width, 1.5);
          if (id == rootTreePersonId) {
            expect(shape.side.color, border.top.color);
            expect(shape.side.color, isNot(theme.colorScheme.primary));
          } else {
            expect(shape.side.color, Colors.transparent);
          }
          expect(material.clipBehavior, Clip.antiAlias);
          final name =
              tester
                      .widget<DecoratedBox>(
                        find.byKey(ValueKey('tree-name-background-$id')),
                      )
                      .decoration
                  as BoxDecoration;
          expect(name.color!.a, 1, reason: 'Names must hide crossing links.');
          expect(
            name.color,
            id == rootTreePersonId
                ? theme.colorScheme.surfaceContainerLowest
                : theme.colorScheme.surface,
          );
        }
        final photo = find.descendant(
          of: _person(rootTreePersonId),
          matching: find.byType(Image),
        );
        expect(tester.widget<Image>(photo).fit, BoxFit.cover);
        expect(
          find.ancestor(of: photo, matching: find.byType(ClipRRect)),
          findsOneWidget,
        );
        final wash =
            tester
                    .widget<DecoratedBox>(_blockFor(fixture, rootTreePersonId))
                    .decoration
                as BoxDecoration;
        expect(wash.color!.a, closeTo(.24, .002));
        final links = find.byKey(const Key('tree-links'));
        final layers = tester
            .widget<Stack>(
              find.ancestor(of: links, matching: find.byType(Stack)).first,
            )
            .children;
        final linkLayer = layers.indexWhere(
          (layer) => find
              .descendant(of: find.byWidget(layer), matching: links)
              .evaluate()
              .isNotEmpty,
        );
        final scrollLayer = layers.indexWhere(
          (layer) => find
              .descendant(
                of: find.byWidget(layer),
                matching: find.byKey(const Key('tree-main-scroll')),
              )
              .evaluate()
              .isNotEmpty,
        );
        expect(linkLayer, greaterThanOrEqualTo(0));
        expect(scrollLayer, greaterThan(linkLayer));
        expect(
          tester
              .widget<IgnorePointer>(
                find
                    .ancestor(of: links, matching: find.byType(IgnorePointer))
                    .first,
              )
              .ignoring,
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} links meet the selected avatar, not sibling-block midpoint',
      (tester) async {
        final fixture = _family(siblings: 6);
        await _mount(
          tester,
          _Session(fixture.document),
          size: portrait ? const Size(430, 900) : const Size(1100, 850),
        );
        final canvasRect = tester.getRect(find.byKey(const Key('tree-canvas')));
        final root = tester
            .getRect(_person(rootTreePersonId))
            .shift(-canvasRect.topLeft);
        final sibling = tester
            .getRect(_person('Сестра-0'))
            .shift(-canvasRect.topLeft);
        final target = portrait
            ? Offset(root.center.dx - 30, root.top + 36)
            : Offset(root.center.dx, root.top + 6);
        final groupMidpoint = portrait
            ? (root.center.dy + sibling.center.dy) / 2
            : (root.center.dx + sibling.center.dx) / 2;
        expect(
          ((portrait ? target.dy : target.dx) - groupMidpoint).abs(),
          greaterThan(100),
        );
        final drawing = _ConnectionCanvas();
        _linkPainter(tester).paint(drawing, canvasRect.size);
        final incoming = drawing.paths
            .where((path) => (_pathEnd(path) - target).distance < .1)
            .toList();
        expect(incoming, hasLength(2));
        for (final parentId in ['Отец', 'Мать']) {
          final parent = tester
              .getRect(_person(parentId))
              .shift(-canvasRect.topLeft);
          final anchor = portrait
              ? Offset(parent.center.dx + 30, parent.top + 36)
              : Offset(parent.center.dx, parent.top + 66);
          expect(
            incoming.any((path) => (_pathStart(path) - anchor).distance < .1),
            isTrue,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} ancestor and direct-child links retain both parents; deeper/context links keep one at block centers',
      (tester) async {
        final fixture = _family(siblings: 1, children: 4)
          ..add('AAA-дядя', sex: TreeSex.male)
          ..parents('AAA-дядя', father: 'Дед', mother: 'Бабушка')
          ..add('Тётя', sex: TreeSex.female);
        fixture.add('Сноха', sex: TreeSex.female);
        for (var i = 0; i < 4; i++) {
          fixture
            ..add('Кузен-$i')
            ..parents('Кузен-$i', father: 'AAA-дядя', mother: 'Тётя')
            ..add('Внук-$i')
            ..parents('Внук-$i', father: 'Ребёнок-0', mother: 'Сноха');
        }
        await _mount(
          tester,
          _Session(fixture.document),
          size: portrait ? const Size(430, 900) : const Size(1100, 850),
        );
        final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
        final drawing = _ConnectionCanvas();
        _linkPainter(tester).paint(drawing, canvas.size);
        Rect local(Finder finder) =>
            tester.getRect(finder).shift(-canvas.topLeft);
        final father = local(_person('Отец'));
        final fatherAnchor = portrait
            ? Offset(father.center.dx - 30, father.top + 36)
            : Offset(father.center.dx, father.top + 6);
        expect(
          drawing.paths.where(
            (path) => (_pathEnd(path) - fatherAnchor).distance < .1,
          ),
          hasLength(2),
        );
        final fatherBlock = _layoutOf(fixture).levels
            .expand((level) => level.blocks)
            .singleWhere(
              (block) => block.people.any((person) => person.id == 'Отец'),
            );
        expect(
          fatherBlock.people.map((person) => person.id),
          ['Отец', 'AAA-дядя'],
          reason: 'The selected father leads his block at the parent boundary.',
        );
        for (final entry in {
          'Ребёнок-0': [rootTreePersonId, 'Партнёр'],
          'Кузен-0': ['AAA-дядя'],
          'Внук-0': ['Ребёнок-0'],
        }.entries) {
          final block = local(_blockFor(fixture, entry.key));
          final target = portrait ? block.centerLeft : block.topCenter;
          final firstSibling = local(_person(entry.key));
          expect(
            (_cross(target, portrait) - _cross(firstSibling.center, portrait))
                .abs(),
            greaterThan(100),
            reason: 'A multi-child block must not attach to its first sibling.',
          );
          final incoming = drawing.paths
              .where((path) => (_pathEnd(path) - target).distance < .1)
              .toList();
          expect(incoming, hasLength(entry.value.length), reason: entry.key);
          if (entry.key == 'Кузен-0') {
            final cousinColor =
                drawing.colors[drawing.paths.indexOf(incoming.single)];
            final expected = Color.lerp(
              const Color(0xFF686C65),
              const Color(0xFFAE742C),
              .35,
            )!.withValues(alpha: .40);
            _expectPaintRgb(cousinColor, expected);
            expect(cousinColor.a, closeTo(.40, 1 / 255));
          }
          for (final parentId in entry.value) {
            final parent = local(_person(parentId));
            final from = portrait
                ? Offset(parent.center.dx + 30, parent.top + 36)
                : Offset(parent.center.dx, parent.top + 66);
            expect(
              incoming.any((path) => (_pathStart(path) - from).distance < .1),
              isTrue,
              reason: '${entry.key} must retain the link from $parentId.',
            );
          }
        }
        final childScroll = _levelController(
          tester,
          _levelOf(fixture, 'Ребёнок-0'),
        );
        final before = _ConnectionCanvas();
        _linkPainter(tester).paint(before, canvas.size);
        final childBlockBefore = local(_blockFor(fixture, 'Ребёнок-0'));
        final oldTarget = portrait
            ? childBlockBefore.centerLeft
            : childBlockBefore.topCenter;
        final childPathIndex = before.paths.indexWhere(
          (path) => (_pathEnd(path) - oldTarget).distance < .1,
        );
        expect(childPathIndex, greaterThanOrEqualTo(0));
        childScroll.jumpTo(childScroll.offset + 60);
        await tester.pump();
        final after = _ConnectionCanvas();
        _linkPainter(tester).paint(after, canvas.size);
        final movedBlock = local(_blockFor(fixture, 'Ребёнок-0'));
        final movedTarget = portrait
            ? movedBlock.centerLeft
            : movedBlock.topCenter;
        expect(
          (_pathEnd(after.paths[childPathIndex]) - movedTarget).distance,
          lessThan(.1),
        );
        expect(
          _cross(_pathEnd(after.paths[childPathIndex]) - oldTarget, portrait),
          closeTo(-60, .1),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'selection reveals clipped parent and centers invisible child union',
    (tester) async {
      final fixture = _family(siblings: 10, children: 4);
      for (var i = 0; i < 12; i++) {
        fixture
          ..add('Родительский сосед-$i')
          ..parents('Родительский сосед-$i', father: 'Дед')
          ..add('Промежуточный сосед-$i')
          ..parents('Промежуточный сосед-$i', father: 'Родительский сосед-$i')
          ..add('Дочерний сосед-$i')
          ..parents('Дочерний сосед-$i', father: 'Промежуточный сосед-$i');
      }
      await _mount(
        tester,
        _Session(fixture.document),
        size: const Size(700, 400),
        initialPersonId: 'Сестра-9',
      );
      await _chooseMode(tester, TreeTrunkMode.father);
      final parentLevel = _levelOf(fixture, 'Отец');
      final childLevel = _levelOf(fixture, 'Ребёнок-0');
      final parentScroll = _levelController(tester, parentLevel);
      final childScroll = _levelController(tester, childLevel);
      parentScroll.jumpTo(parentScroll.position.maxScrollExtent);
      childScroll.jumpTo(childScroll.position.minScrollExtent);
      await tester.pump();
      final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
      final focusBefore = tester.getRect(_person(rootTreePersonId));
      _expectInside(focusBefore, canvas);
      final parentBefore = tester.getRect(_person('Отец'));
      expect(
        parentBefore.right <= canvas.left || parentBefore.left >= canvas.right,
        isTrue,
        reason:
            'The preferred parent must really be offscreen before selection.',
      );
      for (var i = 0; i < 4; i++) {
        final childBefore = tester.getRect(_person('Ребёнок-$i'));
        expect(
          childBefore.right <= canvas.left || childBefore.left >= canvas.right,
          isTrue,
          reason: 'Visible descendants must not be recentered automatically.',
        );
      }
      await _selectPerson(tester, rootTreePersonId);
      expect(tester.getRect(_person(rootTreePersonId)).left, focusBefore.left);
      final parent = tester.getRect(_person('Отец'));
      expect(parent.left, greaterThanOrEqualTo(canvas.left));
      expect(parent.right, lessThanOrEqualTo(canvas.right));
      final firstChild = tester.getRect(_person('Ребёнок-0'));
      final lastChild = tester.getRect(_person('Ребёнок-3'));
      expect(
        (firstChild.left + lastChild.right) / 2,
        closeTo(canvas.center.dx, 1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'zoom controls are bounded, accessible, and fit a narrow short viewport',
    (tester) async {
      final fixture = _Fixture()
        ..name(rootTreePersonId, 'Очень длинное имя выбранного человека');
      final session = _Session(fixture.document, editingAllowed: true);
      await _mount(tester, session, size: const Size(390, 240));
      final peopleBefore = fixture.document.people;
      final zoomIn = find.byKey(const Key('tree-zoom-in'));
      final zoomOut = find.byKey(const Key('tree-zoom-out'));
      final reset = find.byKey(const Key('tree-zoom-reset'));
      bool enabled(Finder control) =>
          tester
              .getSemantics(control)
              .getSemanticsData()
              .flagsCollection
              .isEnabled ==
          Tristate.isTrue;
      void expectControlsFit() {
        final toolbar = tester.getRect(find.byKey(const Key('tree-toolbar')));
        expect(toolbar.height, lessThan(100));
        for (final control in [
          find.byKey(const Key('tree-align-all')),
          zoomIn,
          zoomOut,
          reset,
        ]) {
          _expectInside(tester.getRect(control), toolbar);
          expect(tester.getRect(control).width, greaterThanOrEqualTo(32));
        }
        expect(
          tester.getRect(find.byKey(const Key('tree-canvas'))).height,
          greaterThan(100),
        );
        expect(tester.takeException(), isNull);
      }

      expect(_zoomLabel(tester), '100%');
      expect(find.byTooltip('Увеличить масштаб'), findsOneWidget);
      expect(find.byTooltip('Уменьшить масштаб'), findsOneWidget);
      expect(find.byTooltip('Сбросить масштаб'), findsOneWidget);
      expect(enabled(reset), isFalse);
      expectControlsFit();
      await _zoomSteps(tester, 1);
      expect(_zoomLabel(tester), '110%');
      expect(enabled(reset), isTrue);
      await _zoomSteps(tester, 12);
      expect(_zoomLabel(tester), '200%');
      expect(enabled(zoomIn), isFalse);
      expect(enabled(zoomOut), isTrue);
      expectControlsFit();
      await _zoomSteps(tester, -18);
      expect(_zoomLabel(tester), '26%');
      expect(enabled(zoomOut), isFalse);
      expect(enabled(zoomIn), isTrue);
      await tester.tap(reset);
      await tester.pumpAndSettle();
      expect(_zoomLabel(tester), '100%');
      expect(enabled(reset), isFalse);
      await tester.tap(find.byKey(const Key('tree-toolbar-toggle')));
      await tester.pumpAndSettle();
      for (final control in [zoomIn, zoomOut, reset]) {
        expect(control, findsNothing);
      }
      expect(find.byKey(const Key('tree-search-field')), findsNothing);
      expect(find.byKey(const Key('tree-toolbar')), findsNothing);
      expect(
        tester.getRect(find.byKey(const Key('tree-canvas'))).height,
        closeTo(240, .1),
      );
      await tester.tap(find.byKey(const Key('tree-toolbar-toggle')));
      await tester.pumpAndSettle();
      expectControlsFit();
      expect(_zoomLabel(tester), '100%');
      await _zoomSteps(tester, 1);
      expect(_zoomLabel(tester), '110%');
      expect(session.operations, isEmpty);
      expect(fixture.document.people, peopleBefore);
    },
  );

  testWidgets(
    'sex legend and unknown-sex badge are absent, with unnamed avatar fallback retained',
    (tester) async {
      final fixture = _family()
        ..name(rootTreePersonId, 'Неизвестный')
        ..name('Ребёнок-0', '');
      fixture.apply(
        fixture.document.addPhoto('Ребёнок-1', 'photo', dataUrl: _png),
      );
      await _mount(tester, _Session(fixture.document));
      final toolbar = find.byKey(const Key('tree-toolbar'));
      for (final label in ['Мужчина', 'Женщина', 'Пол не указан']) {
        expect(
          find.descendant(of: toolbar, matching: find.text(label)),
          findsNothing,
        );
      }
      for (final id in [rootTreePersonId, 'Ребёнок-1']) {
        expect(
          find.descendant(of: _person(id), matching: find.byType(Icon)),
          findsNothing,
        );
      }
      final unnamedFallback = find.descendant(
        of: _person('Ребёнок-0'),
        matching: find.byIcon(Icons.person_outline),
      );
      expect(unnamedFallback, findsOneWidget);
      expect(tester.widget<Icon>(unnamedFallback).size, 28);
      expect(
        find.descendant(of: _person('Отец'), matching: find.byIcon(Icons.male)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _person('Мать'),
          matching: find.byIcon(Icons.female),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact mode icon opens described, accessible choices', (
    tester,
  ) async {
    await _mount(tester, _Session(TreeDocument()), size: const Size(390, 844));
    expect(
      tester.getSize(find.byKey(const Key('tree-toolbar'))).height,
      lessThan(100),
    );
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byKey(const Key('tree-mode-both')), findsNothing);
    expect(find.byTooltip('Линия дерева: Обе линии'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tree-mode-picker')));
    await tester.pumpAndSettle();
    for (final mode in TreeTrunkMode.values) {
      expect(find.byKey(ValueKey('tree-mode-${mode.name}')), findsOneWidget);
    }
    expect(
      find.text('Ствол дерева — предки по отцовской линии'),
      findsOneWidget,
    );
    expect(
      find.text('Ствол дерева — предки по материнской линии'),
      findsOneWidget,
    );
    expect(find.text('Ствол дерева — обе родительские линии'), findsOneWidget);
    final selected = tester.getSemantics(
      find.byKey(const Key('tree-mode-both')),
    );
    expect(
      selected.getSemanticsData().flagsCollection.isSelected,
      Tristate.isTrue,
    );
    await tester.tap(find.byKey(const Key('tree-mode-mother')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Линия дерева: По матери'), findsOneWidget);
    expect(find.byKey(const Key('tree-mode-mother')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('node names and initials use the requested gender colors', (
    tester,
  ) async {
    final fixture = _family()..name(rootTreePersonId, 'Неизвестный');
    await _mount(tester, _Session(fixture.document));
    for (final entry in {
      'Отец': const Color(0xFF875826),
      'Мать': const Color(0xFF28644B),
      rootTreePersonId: const Color(0xFF686C65),
    }.entries) {
      final person = fixture.document.person(entry.key)!;
      final label = tester.widget<Text>(
        find.descendant(
          of: _person(entry.key),
          matching: find.text(person.displayName),
        ),
      );
      final initial = tester.widget<Text>(
        find.descendant(
          of: _person(entry.key),
          matching: find.text(person.name.characters.first),
        ),
      );
      expect(label.style!.color, entry.value);
      expect(initial.style!.color, entry.value);
      tester
          .widget<InkWell>(
            find.descendant(
              of: _person(entry.key),
              matching: find.byType(InkWell),
            ),
          )
          .onTap!();
      await tester.pumpAndSettle();
      final material = tester.widget<Material>(
        find.descendant(
          of: _person(entry.key),
          matching: find.byType(Material),
        ),
      );
      final selectedBorder = (material.shape! as RoundedRectangleBorder).side;
      expect(selectedBorder.width, 1.5);
      expect(selectedBorder.color, entry.value);
      final ring = tester.widget<DecoratedBox>(
        find.descendant(
          of: _person(entry.key),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox &&
                widget.decoration is BoxDecoration &&
                (widget.decoration as BoxDecoration).border != null,
          ),
        ),
      );
      final ringBorder = (ring.decoration as BoxDecoration).border! as Border;
      expect(ringBorder.top.width, 3);
      expect(ringBorder.top.color, entry.value);
    }
    expect(tester.takeException(), isNull);
  });

  for (final portrait in [true, false]) {
    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} block surnames inherit, pluralize, and show mixed personal overrides without changing card geometry',
      (tester) async {
        final fixture = _family();
        final session = _Session(fixture.document);
        await _mount(
          tester,
          session,
          size: portrait ? const Size(430, 900) : const Size(1100, 850),
        );
        final ids = [rootTreePersonId, 'Отец', 'Мать', 'Ребёнок-0'];
        final blocksBefore = {
          for (final id in fixture.document.people.keys)
            id: tester.getRect(_blockFor(fixture, id)),
        };
        final nodesBefore = {
          for (final id in fixture.document.people.keys)
            id: tester.getRect(_person(id)),
        };
        void expectUnchangedGeometry() {
          for (final entry in blocksBefore.entries) {
            expect(
              tester.getRect(_blockFor(fixture, entry.key)),
              entry.value,
              reason:
                  'A surname footer must not extend or move its background.',
            );
          }
          for (final entry in nodesBefore.entries) {
            expect(
              tester.getRect(_person(entry.key)),
              entry.value,
              reason: 'Surnames must not change cards, spacing or layout.',
            );
          }
        }

        for (final id in ids) {
          expect(_surnameFor(fixture, id), findsNothing);
        }
        fixture
          ..apply(
            fixture.document.setIndividualSurname(
              'Отец',
              text: 'Иванов',
              decline: true,
            ),
          )
          ..apply(
            fixture.document.setIndividualSurname(
              'Мать',
              text: 'Сидоров',
              decline: true,
            ),
          );
        session.changed();
        await tester.pumpAndSettle();
        for (final entry in {
          rootTreePersonId: 'Ивановы',
          'Отец': 'Иванов',
          'Мать': 'Сидорова',
          'Ребёнок-0': 'Ивановы',
        }.entries) {
          final footer = _surnameFor(fixture, entry.key);
          final label = tester.widget<Text>(footer);
          expect(label.data, entry.value);
          expect(
            label.style!.color,
            Theme.of(
              tester.element(footer),
            ).colorScheme.onSurface.withValues(alpha: .50),
          );
          final background = tester.getRect(_blockFor(fixture, entry.key));
          final footerRect = tester.getRect(footer);
          expect(
            footerRect.top,
            greaterThanOrEqualTo(background.bottom + 2 - .1),
            reason: 'The surname belongs below, never inside, the background.',
          );
          expect(footerRect.center.dy, closeTo(background.bottom + 12, .1));
          expect(footerRect.center.dx, closeTo(background.center.dx, .1));
        }
        expectUnchangedGeometry();
        fixture.apply(
          fixture.document.setIndividualSurname(
            'Сестра-0',
            text: 'Петров',
            decline: true,
          ),
        );
        session.changed();
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(_surnameFor(fixture, rootTreePersonId)).data,
          'разные фамилии',
        );
        expect(
          tester.widget<Text>(_surnameFor(fixture, 'Ребёнок-0')).data,
          'Ивановы',
        );
        expectUnchangedGeometry();
        fixture.apply(
          fixture.document.setIndividualSurname('Сестра-0', text: 'Иванов'),
        );
        session.changed();
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(_surnameFor(fixture, rootTreePersonId)).data,
          'разные фамилии',
          reason:
              'Equal text with a different declension config is still mixed.',
        );
        expectUnchangedGeometry();
        fixture.apply(
          fixture.document.setIndividualSurname('Сестра-0', text: null),
        );
        session.changed();
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(_surnameFor(fixture, rootTreePersonId)).data,
          'Ивановы',
        );
        fixture.apply(
          fixture.document.setIndividualSurname('Отец', text: null),
        );
        session.changed();
        await tester.pumpAndSettle();
        for (final id in [rootTreePersonId, 'Отец', 'Ребёнок-0']) {
          expect(_surnameFor(fixture, id), findsNothing);
        }
        expectUnchangedGeometry();
        expect(session.operations, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${portrait ? 'portrait' : 'landscape'} hover highlights the whole generation viewport with only the main scrollbar',
      (tester) async {
        final fixture = _family(siblings: 1, children: 1);
        final session = _Session(fixture.document);
        await _mount(
          tester,
          session,
          size: portrait ? const Size(430, 900) : const Size(1100, 850),
          platform: TargetPlatform.windows,
        );
        final canvas = tester.getRect(find.byKey(const Key('tree-canvas')));
        final level = _levelOf(fixture, rootTreePersonId);
        final highlight = find.byKey(ValueKey('tree-level-highlight-$level'));
        final band = tester.getRect(highlight);
        expect(
          portrait ? band.height : band.width,
          portrait ? canvas.height : canvas.width,
        );
        expect(tester.widget<ColoredBox>(highlight).color, Colors.transparent);
        expect(find.byType(Scrollbar), findsOneWidget);
        expect(
          tester.widget<Scrollbar>(find.byType(Scrollbar)).controller,
          same(_mainController(tester)),
        );
        for (final bandLevel in _layoutOf(fixture).levels) {
          final scroll = find.byKey(
            ValueKey('tree-level-scroll-${bandLevel.index}'),
          );
          expect(
            find.ancestor(of: scroll, matching: find.byType(Scrollbar)),
            findsOneWidget,
          );
        }
        final emptyPoint = portrait
            ? Offset(band.center.dx, canvas.bottom - 32)
            : Offset(canvas.right - 32, band.center.dy);
        expect(
          tester.getRect(_person(rootTreePersonId)).contains(emptyPoint),
          isFalse,
        );
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(emptyPoint);
        await tester.pumpAndSettle();
        expect(
          tester.widget<ColoredBox>(highlight).color,
          Theme.of(
            tester.element(highlight),
          ).colorScheme.onSurface.withValues(alpha: .035),
        );
        expect(tester.getRect(highlight), band);
        for (final other in _layoutOf(
          fixture,
        ).levels.where((item) => item.index != level)) {
          expect(
            tester
                .widget<ColoredBox>(
                  find.byKey(ValueKey('tree-level-highlight-${other.index}')),
                )
                .color,
            Colors.transparent,
          );
        }
        await mouse.moveTo(
          tester.getCenter(find.byKey(const Key('tree-toolbar'))),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<ColoredBox>(highlight).color, Colors.transparent);
        await mouse.removePointer();
        expect(session.operations, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('adding either parent realigns both-parent gap above the focus', (
    tester,
  ) async {
    final fixture = _Fixture()..name(rootTreePersonId, 'Я');
    final session = _Session(fixture.document);
    await _mount(tester, session);
    fixture
      ..add('Отец', sex: TreeSex.male)
      ..parents(rootTreePersonId, father: 'Отец');
    session.changed();
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(_person('Отец')).dx,
      closeTo(tester.getCenter(_person(rootTreePersonId)).dx, 1),
    );
    fixture
      ..add('Мать', sex: TreeSex.female)
      ..parents(rootTreePersonId, mother: 'Мать');
    session.changed();
    await tester.pumpAndSettle();
    final parentGap =
        (tester.getCenter(_person('Отец')).dx +
            tester.getCenter(_person('Мать')).dx) /
        2;
    expect(
      parentGap,
      closeTo(tester.getCenter(_person(rootTreePersonId)).dx, 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'document changes update names without snapping independent scrolls',
    (tester) async {
      final fixture = _family(siblings: 14, children: 14);
      // A known date fixes the root after all undated siblings independently
      // of its edited name; the unchanged-order scroll contract remains strict.
      fixture.apply(
        fixture.document.setValue(rootTreePersonId, 'birthDate', '2000-01-01'),
      );
      final session = _Session(fixture.document);
      await _mount(tester, session);
      final level = _levelController(
        tester,
        _levelOf(fixture, rootTreePersonId),
      );
      level.jumpTo(100);
      await tester.pump();
      fixture.name(rootTreePersonId, 'Новое имя');
      session.changed();
      await tester.pumpAndSettle();
      expect(level.offset, 100);
      expect(
        find.descendant(
          of: _person(rootTreePersonId),
          matching: find.text('Новое имя'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
