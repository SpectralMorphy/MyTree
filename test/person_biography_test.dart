import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

// Exercise the file_selector platform boundary without opening a native picker.
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/room_identity.dart';
import 'package:mytree_webrtc_demo/room_session.dart';
import 'package:mytree_webrtc_demo/storage/room_store.dart';
import 'package:mytree_webrtc_demo/tree/tree_document.dart';
import 'package:mytree_webrtc_demo/ui/person_biography.dart';
import 'package:mytree_webrtc_demo/ui/tree_editor.dart';

const _pixel =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

class _PhotoPicker extends FileSelectorPlatform {
  _PhotoPicker(this.files);
  final List<XFile> files;

  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => files;
}

/// No disk or transport: preserve the production synchronous optimistic update
/// and separate durable projection, including failed and delayed writes.
class _BiographySession extends RoomSession {
  _BiographySession()
    : super(
        roomId: '0123456789abcdef0123456789abcdef',
        actorId: 'self',
        store: MemoryRoomStore(),
        existingMember: true,
      );

  final _document = TreeDocument();
  final _durable = TreeDocument();
  final _pending = <StampedTreeOperation>[];
  final operations = <TreeOperation>[];
  final textBases = <TreeTextSnapshot?>[];
  int _clock = 0;
  bool editingAllowed = true;
  bool failWrites = false;
  bool holdCreation = false;
  bool holdBirthDate = false;
  bool holdBinding = false;
  bool holdParentLink = false;
  bool failParentLink = false;
  String? _error;
  Completer<void>? _bindingWrite;
  Completer<void>? _creationWrite;
  Completer<void>? _birthDateWrite;
  Completer<void>? _parentLinkWrite;

  @override
  TreeDocument get tree => _document;
  @override
  TreeDocument get durableTree => _durable;
  @override
  bool get canEdit => editingAllowed;
  @override
  RoomRole get ownRole => editingAllowed ? RoomRole.editor : RoomRole.guest;
  @override
  bool get saving => _bindingWrite != null;
  @override
  String? get storageError => _error;
  @override
  String? get boundPersonId =>
      ownRole == RoomRole.editor ? _durable.bindings[actorId] : null;
  @override
  bool get canBindToPerson => canEdit && boundPersonId == null;

  StampedTreeOperation _stamp(
    TreeOperation operation, {
    String author = 'self',
  }) {
    final clock = ++_clock;
    return StampedTreeOperation(
      id: 'operation-$clock',
      author: author,
      clock: clock,
      createdAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: clock)),
      operation: operation,
    );
  }

  void seed(TreeOperation operation) {
    final event = _stamp(operation);
    _document.merge([event]);
    _durable.merge([event]);
  }

  void remote(TreeOperation operation) {
    final event = _stamp(operation, author: 'remote');
    _document.merge([event]);
    _durable.merge([event]);
    notifyListeners();
  }

  void setEditingAllowed(bool value) {
    editingAllowed = value;
    notifyListeners();
  }

  Future<void> _append(TreeOperation operation) {
    operations.add(operation);
    final event = _stamp(operation);
    _document.merge([event]);
    final delayBirthDate = holdBirthDate && operation.fieldKey == 'birthDate';
    final parentLink =
        operation.type == 'setValue' &&
        const ['fatherId', 'motherId'].contains(operation.fieldKey) &&
        operation.toJson()['value'] != null;
    final delayParentLink = holdParentLink && parentLink;
    final writeFailed = failWrites || (failParentLink && parentLink);
    if (writeFailed ||
        (holdBinding && operation.type == 'bindActor') ||
        (holdCreation &&
            const ['createPerson', 'createSibling'].contains(operation.type)) ||
        delayBirthDate ||
        delayParentLink) {
      _pending.add(event);
    } else {
      _durable.merge([event]);
    }
    if (writeFailed) _error = 'Диск недоступен';
    if (holdBinding && operation.type == 'bindActor') {
      _bindingWrite = Completer<void>();
    }
    if (holdCreation &&
        const ['createPerson', 'createSibling'].contains(operation.type)) {
      _creationWrite = Completer<void>();
    }
    if (delayBirthDate) _birthDateWrite = Completer<void>();
    if (delayParentLink) _parentLinkWrite = Completer<void>();
    notifyListeners();
    if (writeFailed) return Future.error(StateError(_error!));
    return _creationWrite?.future ??
        _birthDateWrite?.future ??
        _bindingWrite?.future ??
        _parentLinkWrite?.future ??
        Future.value();
  }

  @override
  Future<void> applyTreeOperation(TreeOperation operation) {
    if (!canEdit) return Future.error(StateError('Только редактор'));
    return _append(operation);
  }

  @override
  Future<void> editTreeText(
    String personId,
    TreeTextField field,
    String value, {
    String? itemId,
    TreeTextSnapshot? base,
  }) {
    textBases.add(base);
    final operation = tree.editText(
      personId,
      field,
      value,
      itemId: itemId,
      base: base,
    );
    return operation == null ? Future.value() : applyTreeOperation(operation);
  }

  @override
  Future<void> bindToPerson(String id) {
    if (!canBindToPerson || tree.bindings.containsKey(actorId)) {
      return Future.error(StateError('Привязка уже выполнена'));
    }
    return _append(tree.bindActor(actorId, id));
  }

  void completeBinding() {
    _durable.merge(_pending);
    _pending.clear();
    final completer = _bindingWrite;
    _bindingWrite = null;
    notifyListeners();
    completer?.complete();
  }

  void completeCreation() {
    _durable.merge(_pending);
    _pending.clear();
    final completer = _creationWrite;
    _creationWrite = null;
    notifyListeners();
    completer?.complete();
  }

  void completeBirthDate() {
    _durable.merge(_pending);
    _pending.clear();
    final completer = _birthDateWrite;
    _birthDateWrite = null;
    notifyListeners();
    completer?.complete();
  }

  void completeParentLink() {
    _durable.merge(_pending);
    _pending.clear();
    final completer = _parentLinkWrite;
    _parentLinkWrite = null;
    notifyListeners();
    completer?.complete();
  }

  @override
  Future<void> flush() {
    if (failWrites || failParentLink) {
      return Future.error(StateError(_error!));
    }
    _durable.merge(_pending);
    _pending.clear();
    _error = null;
    notifyListeners();
    return Future.value();
  }
}

void main() {
  late _BiographySession session;
  String? pickedExistingId;
  List<String> lastPickableIds = [];

  setUp(() {
    session = _BiographySession();
    pickedExistingId = null;
    lastPickableIds = [];
  });

  tearDown(() => session.dispose());

  Future<void> mount(
    WidgetTester tester, {
    String id = rootTreePersonId,
    ValueChanged<String>? onSelect,
    VoidCallback? onClose,
    PickTreePerson? onPickFromTree,
    bool fullScreen = false,
    Size size = const Size(480, 1100),
    ThemeData? theme,
    ValueNotifier<TreeNameMode>? nameMode,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: PersonBiography(
            session: session,
            nameMode: nameMode,
            personId: id,
            onSelect: onSelect ?? (_) {},
            onClose: onClose ?? () {},
            onPickFromTree:
                onPickFromTree ??
                (_, canPick) async {
                  lastPickableIds = session.tree.people.values
                      .where(canPick)
                      .map((person) => person.id)
                      .toList();
                  return pickedExistingId;
                },
            fullScreen: fullScreen,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> edit(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('biography-edit-toggle')));
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    if (target.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        target,
        300,
        scrollable: find
            .descendant(
              of: find.byType(ListView).last,
              matching: find.byType(Scrollable),
            )
            .first,
      );
    } else {
      await tester.ensureVisible(target);
    }
    await tester.pumpAndSettle();
  }

  Future<void> visibleTap(WidgetTester tester, Finder target) async {
    await reveal(tester, target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> relativeFrames(
    WidgetTester tester, {
    int count = 24,
    String? expectedError,
  }) async {
    for (var frame = 0; frame < count; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.takeException(),
        isNull,
        reason: 'Relative form frame $frame',
      );
      expect(find.byType(ErrorWidget, skipOffstage: false), findsNothing);
      final error = find.byKey(
        const Key('relative-error'),
        skipOffstage: false,
      );
      if (expectedError == null) {
        expect(
          error,
          findsNothing,
          reason: 'No transient form error at frame $frame',
        );
      } else {
        expect(error, findsOneWidget, reason: 'Frame $frame');
        expect(tester.widget<Text>(error).data, contains(expectedError));
      }
    }
  }

  Future<void> chooseRelativeKind(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const Key('relative-kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> openRelative(WidgetTester tester) async {
    await edit(tester);
    await visibleTap(tester, find.byKey(const Key('add-relative')));
  }

  Future<void> chooseFromTree(WidgetTester tester) async {
    final pick = find.byKey(const Key('relative-pick-from-tree'));
    if (pick.evaluate().isEmpty) {
      await tester.tap(find.widgetWithText(ChoiceChip, 'Из дерева'));
      await tester.pumpAndSettle();
    }
  }

  Future<void> chooseExisting(WidgetTester tester, String name) async {
    pickedExistingId = session.tree.people.values
        .singleWhere((person) => person.name == name)
        .id;
    await chooseFromTree(tester);
    await tester.tap(find.byKey(const Key('relative-pick-from-tree')));
    await tester.pumpAndSettle();
    pickedExistingId = null;
  }

  Finder newRelativeSex() => find.descendant(
    of: find.byType(AlertDialog),
    matching: find.byType(DropdownButtonFormField<TreeSex>),
  );

  DropdownButton<T> dropdown<T>(WidgetTester tester, Finder field) =>
      tester.widget<DropdownButton<T>>(
        find.descendant(of: field, matching: find.byType(DropdownButton<T>)),
      );

  DropdownButton<dynamic> relativeKindDropdown(WidgetTester tester) =>
      tester.widget<DropdownButton<dynamic>>(
        find.descendant(
          of: find.byKey(const Key('relative-kind')),
          matching: find.byWidgetPredicate(
            (widget) => widget is DropdownButton<dynamic>,
          ),
        ),
      );

  DropdownMenuItem<dynamic> relativeKindOption(
    WidgetTester tester,
    String label,
  ) => relativeKindDropdown(
    tester,
  ).items!.singleWhere((item) => (item.child as Text).data == label);

  void seedRelatives() {
    for (final (id, name) in const [
      ('father', 'Олег'),
      ('mother', 'Елена'),
      ('sibling', 'Ирина'),
      ('half', 'Михаил'),
      ('other-parent', 'Другой родитель'),
      ('other-sibling', 'Другой брат'),
      ('child', 'Дочь'),
    ]) {
      session.seed(session.tree.createPerson(id, name: name));
    }
    for (final id in [rootTreePersonId, 'sibling', 'other-sibling']) {
      session.seed(session.tree.setValue(id, 'fatherId', 'father'));
      session.seed(session.tree.setValue(id, 'motherId', 'mother'));
    }
    session.seed(session.tree.setValue('half', 'fatherId', 'father'));
    session.seed(session.tree.setValue('half', 'motherId', 'other-parent'));
    session.seed(session.tree.setValue('child', 'fatherId', rootTreePersonId));
    session.seed(session.tree.setValue('child', 'motherId', 'other-parent'));
  }

  // Historical wire data remains readable, but new UI commands never use it.
  TreeOperation legacyFamilySurname(
    String id,
    String text, {
    bool decline = false,
  }) => TreeOperation.fromJson({
    'type': 'setSurname',
    'personId': id,
    'scope': 'family',
    'familyKey': treeSurnameFamilyKey(session.tree.person(id)!),
    'text': text,
    'decline': decline,
  });

  Finder unlink(String group, String personId) => find.descendant(
    of: find.byKey(ValueKey('relative-$group-$personId')),
    matching: find.byTooltip('удалить связь'),
  );

  Finder siblingUnlink(String personId) => find.descendant(
    of: find.byKey(ValueKey('relative-Братья и сёстры-$personId')),
    matching: find.byTooltip('Убрать прямую братскую связь'),
  );

  void expectSurnameControls(WidgetTester tester) {
    final field = find.byKey(const Key('person-surname-field'));
    final decline = find.byKey(const Key('surname-decline'));
    expect(field, findsOneWidget);
    expect(
      tester.widget<TextField>(field).decoration!.labelText,
      'Фамилия при рождении',
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Фамилия при рождении',
      ),
      findsOneWidget,
    );
    expect(tester.widget<CheckboxListTile>(decline).title, isA<Text>());
    expect(
      find.descendant(of: decline, matching: find.text('склонять фамилию')),
      findsOneWidget,
    );
    expect(find.byType(CheckboxListTile), findsOneWidget);
    expect(find.byKey(const Key('surname-individual-toggle')), findsNothing);
    expect(find.text('отдельная'), findsNothing);
    expect(find.textContaining('для блока'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    for (final key in [
      'person-family-surname',
      'person-individual-surname',
      'person-maiden-surname',
      'family-surname-decline',
      'individual-surname-decline',
      'maiden-surname-decline',
    ]) {
      expect(find.byKey(Key(key)), findsNothing);
    }
    expect(find.textContaining('до замужества'), findsNothing);
    expect(find.textContaining('смены фамилии'), findsNothing);
  }

  for (final (sex, icon, color) in const [
    (TreeSex.female, Icons.female, Color(0xFF28644B)),
    (TreeSex.male, Icons.male, Color(0xFF875826)),
    (TreeSex.unknown, Icons.person_outline, Color(0xFF686C65)),
  ]) {
    testWidgets('${sex.name} symbols and avatar use the tree palette', (
      tester,
    ) async {
      session.seed(session.tree.setValue(rootTreePersonId, 'sex', sex.name));
      await mount(tester);
      final avatar = find.byKey(const Key('person-avatar'));
      final decoration =
          tester
                  .widget<Container>(
                    find.descendant(
                      of: avatar,
                      matching: find.byType(Container),
                    ),
                  )
                  .decoration!
              as BoxDecoration;
      expect((decoration.border! as Border).top.color, color);
      expect(
        tester
            .widget<ColoredBox>(
              find.descendant(of: avatar, matching: find.byType(ColoredBox)),
            )
            .color,
        color.withValues(alpha: .12),
      );
      // Check both the actual Venus/Mars avatar and the read-view sex symbol.
      expect(find.byIcon(icon), findsNWidgets(2));
      for (final symbol in tester.widgetList<Icon>(find.byIcon(icon))) {
        expect(symbol.color, color);
      }
      await edit(tester);
      final picker = dropdown<TreeSex>(
        tester,
        find.byType(DropdownButtonFormField<TreeSex>),
      );
      final option = picker.items!.singleWhere((item) => item.value == sex);
      final symbol = (option.child as Row).children.whereType<Icon>().single;
      expect(symbol.icon, icon);
      expect(symbol.color, color);
      expect(session.operations, isEmpty);
    });
  }

  testWidgets('empty biography is a read view and close does not save', (
    tester,
  ) async {
    var closed = 0;
    await mount(tester, onClose: () => closed++);
    expect(find.text('Без имени'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const Key('person-relatives')), findsOneWidget);
    await tester.ensureVisible(find.text('Биография пока не добавлена'));
    expect(find.text('Биография пока не добавлена'), findsOneWidget);
    expect(session.operations, isEmpty);
    await tester.tap(find.byKey(const Key('biography-close')));
    expect(closed, 1);
    expect(session.operations, isEmpty);
  });

  testWidgets(
    'name mode updates identity relatives binding and inherited surname hints live without edits',
    (tester) async {
      session.seed(
        session.tree.editText(rootTreePersonId, TreeTextField.name, 'Анна')!,
      );
      session.seed(session.tree.setValue(rootTreePersonId, 'sex', 'female'));
      session.seed(
        session.tree.createPerson(
          'grandfather',
          name: 'Пётр',
          sex: TreeSex.male,
        ),
      );
      session.seed(
        session.tree.createPerson('father', name: 'Иван', sex: TreeSex.male),
      );
      session.seed(session.tree.setValue('father', 'fatherId', 'grandfather'));
      session.seed(
        session.tree.setIndividualSurname(
          'father',
          text: 'Иванов',
          decline: true,
        ),
      );
      session.seed(
        session.tree.setValue(rootTreePersonId, 'fatherId', 'father'),
      );
      session.seed(
        session.tree.createPerson('sister', name: 'Ольга', sex: TreeSex.female),
      );
      session.seed(session.tree.setValue('sister', 'fatherId', 'father'));
      final nameMode = ValueNotifier(TreeNameMode.givenSurname);
      addTearDown(nameMode.dispose);
      final peopleBefore = session.tree.people;
      await mount(tester, nameMode: nameMode);
      expect(find.text('Анна Иванова'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Иван Иванов'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Ольга Иванова'), findsOneWidget);
      await visibleTap(tester, find.byKey(const Key('this-is-me')));
      expect(
        find.text('Связать ваш профиль с «Анна Иванова»?'),
        findsOneWidget,
      );
      nameMode.value = TreeNameMode.surnameGivenPatronymic;
      await tester.pumpAndSettle();
      expect(
        find.text('Связать ваш профиль с «Иванова Анна Ивановна»?'),
        findsOneWidget,
      );
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(find.text('Иванова Анна Ивановна'), findsOneWidget);
      expect(
        find.widgetWithText(ActionChip, 'Иванов Иван Петрович'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(ActionChip, 'Иванова Ольга Ивановна'),
        findsOneWidget,
      );
      await edit(tester);
      final name = find.byKey(const Key('person-name-field'));
      final surname = find.byKey(const Key('person-surname-field'));
      final nameController = tester.widget<TextField>(name).controller!;
      final surnameController = tester.widget<TextField>(surname).controller!;
      expect(nameController.text, 'Анна');
      expect(surnameController.text, isEmpty);
      expect(
        tester.widget<TextField>(surname).decoration!.helperText,
        'Наследуется от отца: Иванов Иван Петрович',
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == 'Отчество',
        ),
        findsNothing,
      );
      expect(
        find.widgetWithText(InputChip, 'Иванов Иван Петрович'),
        findsOneWidget,
      );
      nameMode.value = TreeNameMode.givenSurname;
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(name).controller, same(nameController));
      expect(
        tester.widget<TextField>(surname).controller,
        same(surnameController),
      );
      expect(nameController.text, 'Анна');
      expect(surnameController.text, isEmpty);
      expect(
        tester.widget<TextField>(surname).decoration!.helperText,
        'Наследуется от отца: Иван Иванов',
      );
      expect(session.operations, isEmpty);
      expect(session.tree.people, same(peopleBefore));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      nameMode.value = TreeNameMode.surnameGivenPatronymic;
      nameMode.addListener(() {});
      expect(tester.takeException(), isNull);
    },
  );

  for (final hasFather in [false, true]) {
    testWidgets(
      'FIO has no patronymic gaps with ${hasFather ? 'unknown sex' : 'no father'}',
      (tester) async {
        session.seed(
          session.tree.editText(rootTreePersonId, TreeTextField.name, 'Саша')!,
        );
        session.seed(
          session.tree.setIndividualSurname(rootTreePersonId, text: 'Седых'),
        );
        if (hasFather) {
          session.seed(
            session.tree.createPerson(
              'father',
              name: 'Иван',
              sex: TreeSex.male,
            ),
          );
          session.seed(
            session.tree.setValue(rootTreePersonId, 'fatherId', 'father'),
          );
        } else {
          session.seed(session.tree.setValue(rootTreePersonId, 'sex', 'male'));
        }
        final nameMode = ValueNotifier(TreeNameMode.surnameGivenPatronymic);
        addTearDown(nameMode.dispose);
        await mount(tester, nameMode: nameMode);
        expect(find.text('Седых Саша'), findsOneWidget);
        expect(session.operations, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'family history is directly after relatives and before facts in read and edit modes',
    (tester) async {
      seedRelatives();
      await mount(tester);
      for (final editing in [false, true]) {
        if (editing) await edit(tester);
        final history = find.byKey(const Key('person-family-history'));
        await reveal(tester, history);
        final relatives = find.byKey(const Key('person-relatives'));
        expect(
          tester.getBottomLeft(relatives).dy,
          lessThan(tester.getTopLeft(history).dy),
        );
        await reveal(tester, find.text('Факты и воспоминания'));
        expect(
          tester.getBottomLeft(history).dy,
          lessThan(tester.getTopLeft(find.text('Факты и воспоминания')).dy),
        );
        expect(find.text('Фамилии и браки'), findsOneWidget);
        expect(
          find.byKey(const Key('add-marriage')),
          editing ? findsOneWidget : findsNothing,
        );
      }
      expect(session.operations, isEmpty);
    },
  );

  testWidgets('a missing person is handled without editing or binding', (
    tester,
  ) async {
    await mount(tester, id: 'missing', fullScreen: true);
    expect(find.text('Человек не найден в дереве'), findsOneWidget);
    expect(find.byKey(const Key('biography-edit-toggle')), findsNothing);
    expect(find.byKey(const Key('this-is-me')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final legacyBound in [false, true]) {
    testWidgets(
      'guest can view the album but cannot edit or bind (legacy binding=$legacyBound)',
      (tester) async {
        if (legacyBound) {
          session.seed(session.tree.bindActor('self', rootTreePersonId));
        }
        session.setEditingAllowed(false);
        await mount(tester);
        expect(session.ownRole, RoomRole.guest);
        expect(session.canBindToPerson, isFalse);
        expect(session.boundPersonId, isNull);
        expect(find.byKey(const Key('biography-edit-toggle')), findsNothing);
        expect(find.byType(TextField), findsNothing);
        expect(find.byKey(const Key('this-is-me')), findsNothing);
        expect(find.text('Ваш профиль'), findsNothing);
        await expectLater(
          session.bindToPerson(rootTreePersonId),
          throwsStateError,
        );
        await expectLater(
          session.applyTreeOperation(
            session.tree.bindActor('self', rootTreePersonId),
          ),
          throwsStateError,
        );
        await tester.tap(find.byKey(const Key('person-avatar')));
        await tester.pumpAndSettle();
        expect(find.text('В альбоме пока нет фотографий'), findsOneWidget);
        expect(find.byKey(const Key('album-upload')), findsNothing);
        expect(session.operations, isEmpty);
        expect(
          session.tree.bindings['self'],
          legacyBound ? rootTreePersonId : null,
        );
        expect(session.durableTree.bindings, session.tree.bindings);
      },
    );

    testWidgets(
      'editor promotion ${legacyBound ? 'activates the retained legacy profile' : 'reveals the binding button'}',
      (tester) async {
        if (legacyBound) {
          session.seed(session.tree.bindActor('self', rootTreePersonId));
        }
        session.setEditingAllowed(false);
        await mount(tester);
        expect(find.byKey(const Key('this-is-me')), findsNothing);
        expect(find.text('Ваш профиль'), findsNothing);
        session.setEditingAllowed(true);
        await tester.pumpAndSettle();
        expect(session.ownRole, RoomRole.editor);
        expect(session.boundPersonId, legacyBound ? rootTreePersonId : null);
        expect(session.canBindToPerson, !legacyBound);
        expect(
          find.byKey(const Key('this-is-me')),
          legacyBound ? findsNothing : findsOneWidget,
        );
        expect(
          find.text('Ваш профиль'),
          legacyBound ? findsOneWidget : findsNothing,
        );
        expect(session.operations, isEmpty);
        expect(
          session.tree.bindings['self'],
          legacyBound ? rootTreePersonId : null,
        );
        expect(session.durableTree.bindings, session.tree.bindings);
      },
    );
  }

  testWidgets('role revocation removes active editing controls', (
    tester,
  ) async {
    await mount(tester);
    await edit(tester);
    expect(find.byKey(const Key('person-name-field')), findsOneWidget);
    expect(find.byKey(const Key('person-relatives')), findsOneWidget);
    session.setEditingAllowed(false);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const Key('add-relative')), findsNothing);
    expect(find.byKey(const Key('biography-edit-toggle')), findsNothing);
    expect(find.byKey(const Key('person-relatives')), findsOneWidget);
  });

  testWidgets('parents, full and half siblings, and children select a person', (
    tester,
  ) async {
    for (final entry in {
      'father': 'Олег',
      'mother': 'Елена',
      'sibling': 'Ирина',
      'half': 'Михаил',
      'child': 'Дочь',
    }.entries) {
      session.seed(session.tree.createPerson(entry.key, name: entry.value));
    }
    for (final id in [rootTreePersonId, 'sibling']) {
      session.seed(session.tree.setValue(id, 'fatherId', 'father'));
      session.seed(session.tree.setValue(id, 'motherId', 'mother'));
    }
    session.seed(session.tree.setValue('half', 'fatherId', 'father'));
    session.seed(session.tree.setValue('child', 'fatherId', rootTreePersonId));
    final selected = <String>[];
    await mount(tester, onSelect: selected.add);
    for (final entry in {
      'father': 'Олег',
      'mother': 'Елена',
      'sibling': 'Ирина',
      'half': 'Михаил',
      'child': 'Дочь',
    }.entries) {
      await visibleTap(tester, find.widgetWithText(ActionChip, entry.value));
      expect(selected.last, entry.key);
    }
    expect(find.text('Неполнородные братья и сёстры'), findsOneWidget);
    await edit(tester);
    expect(find.byKey(const Key('person-relatives')), findsOneWidget);
    expect(find.byKey(const Key('add-relative')), findsOneWidget);
  });

  testWidgets(
    'editing keeps Add under the relatives heading and replaces the old footer',
    (tester) async {
      seedRelatives();
      final selected = <String>[];
      await mount(tester, onSelect: selected.add);
      expect(find.byTooltip('удалить связь'), findsNothing);
      expect(find.byKey(const Key('delete-person')), findsNothing);
      await edit(tester);
      final relatives = find.byKey(const Key('person-relatives'));
      await tester.ensureVisible(relatives);
      await tester.pumpAndSettle();
      expect(relatives, findsOneWidget);
      final add = find.byKey(const Key('add-relative'));
      expect(find.descendant(of: relatives, matching: add), findsOneWidget);
      expect(
        tester.getBottomLeft(find.text('Родные')).dy,
        lessThan(tester.getTopLeft(add).dy),
      );
      expect(
        tester.getBottomLeft(add).dy,
        lessThan(tester.getTopLeft(find.text('Отец')).dy),
      );
      expect(find.byType(InputChip), findsNWidgets(3));
      expect(find.byTooltip('удалить связь'), findsNWidgets(3));
      await visibleTap(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('relative-Отец-father')),
          matching: find.text('Олег'),
        ),
      );
      expect(selected, ['father']);
      expect(session.operations, isEmpty);
      await tester.drag(find.byType(ListView).first, const Offset(0, -1500));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('delete-person')), findsOneWidget);
      expect(find.textContaining('Изменения сохраняются'), findsNothing);
      expect(find.textContaining('Обмен с участниками'), findsNothing);
    },
  );

  for (final (size, fullScreen) in const [
    (Size(480, 1100), false),
    (Size(390, 844), true),
    (Size(320, 568), true),
  ]) {
    testWidgets(
      'Add is below Родные and before relative groups at $size (fullScreen=$fullScreen)',
      (tester) async {
        seedRelatives();
        await mount(tester, size: size, fullScreen: fullScreen);
        final add = find.byKey(const Key('add-relative'));
        expect(add, findsNothing);
        await edit(tester);
        await reveal(tester, add);
        final relatives = find.byKey(const Key('person-relatives'));
        expect(find.descendant(of: relatives, matching: add), findsOneWidget);
        expect(
          tester.getBottomLeft(find.text('Родные')).dy,
          lessThan(tester.getTopLeft(add).dy),
        );
        for (final label in [
          'Отец',
          'Мать',
          'Братья и сёстры',
          'Неполнородные братья и сёстры',
          'Дети',
        ]) {
          expect(
            tester.getBottomLeft(add).dy,
            lessThan(tester.getTopLeft(find.text(label)).dy),
          );
        }
        expect(session.operations, isEmpty);
        await tester.tap(add);
        await relativeFrames(tester);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(session.operations, isEmpty);
        await tester.tap(find.text('Отмена'));
        await relativeFrames(tester);
        await edit(tester);
        expect(add, findsNothing);
        expect(session.operations, isEmpty);
      },
    );
  }

  testWidgets('parent X removes only its field and never the parent node', (
    tester,
  ) async {
    seedRelatives();
    await mount(tester);
    await edit(tester);
    await visibleTap(tester, unlink('Отец', 'father'));
    expect(find.byType(AlertDialog), findsNothing);
    final person = session.durableTree.person(rootTreePersonId)!;
    expect(person.fatherId, isNull);
    expect(person.motherId, 'mother');
    expect(session.durableTree.person('father'), isNotNull);
    expect(session.durableTree.person('sibling')!.fatherId, 'father');
    expect(session.durableTree.person('half')!.fatherId, 'father');
    expect(session.durableTree.people, hasLength(8));
    expect(session.operations.single.toJson(), {
      'type': 'setValue',
      'personId': rootTreePersonId,
      'field': 'fatherId',
      'value': null,
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('child X leaves the child and its other parent untouched', (
    tester,
  ) async {
    seedRelatives();
    await mount(tester);
    await edit(tester);
    await visibleTap(tester, unlink('Дети', 'child'));
    final child = session.durableTree.person('child')!;
    expect(child.fatherId, isNull);
    expect(child.motherId, 'other-parent');
    expect(session.durableTree.person(rootTreePersonId)!.fatherId, 'father');
    expect(session.durableTree.person('half')!.motherId, 'other-parent');
    expect(session.durableTree.people, hasLength(8));
    expect(session.operations.single.personId, 'child');
    expect(session.operations.single.fieldKey, 'fatherId');
    expect(tester.takeException(), isNull);
  });

  for (final (group, id, name, motherId) in const [
    ('Братья и сёстры', 'sibling', 'Ирина', 'mother'),
    ('Неполнородные братья и сёстры', 'half', 'Михаил', 'other-parent'),
  ]) {
    testWidgets('$group stay clickable without any unlink control', (
      tester,
    ) async {
      seedRelatives();
      final selected = <String>[];
      await mount(tester, onSelect: selected.add);
      await edit(tester);
      final relative = find.byKey(ValueKey('relative-$group-$id'));
      await reveal(tester, relative);
      expect(tester.widget(relative), isA<ActionChip>());
      expect(
        find.descendant(of: relative, matching: find.text(name)),
        findsOneWidget,
      );
      expect(unlink(group, id), findsNothing);
      expect(
        find.descendant(of: relative, matching: find.byIcon(Icons.close)),
        findsNothing,
      );
      await visibleTap(tester, relative);
      expect(selected, [id]);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(const Key('confirm-unlink-sibling')), findsNothing);
      expect(session.durableTree.person(id)!.fatherId, 'father');
      expect(session.durableTree.person(id)!.motherId, motherId);
      expect(session.durableTree.person(rootTreePersonId)!.fatherId, 'father');
      expect(session.durableTree.person(rootTreePersonId)!.motherId, 'mother');
      expect(session.operations, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('failed parent unlink retries without a second removal command', (
    tester,
  ) async {
    seedRelatives();
    await mount(tester);
    await edit(tester);
    session.failWrites = true;
    await visibleTap(tester, unlink('Отец', 'father'));
    expect(session.tree.person(rootTreePersonId)!.fatherId, isNull);
    expect(session.durableTree.person(rootTreePersonId)!.fatherId, 'father');
    expect(find.byKey(const Key('biography-save-error')), findsOneWidget);
    expect(session.operations, hasLength(1));
    session.failWrites = false;
    await tester.tap(find.text('Повторить сохранение'));
    await tester.pumpAndSettle();
    expect(session.durableTree.person(rootTreePersonId)!.fatherId, isNull);
    expect(session.durableTree.person(rootTreePersonId)!.motherId, 'mother');
    expect(session.durableTree.person('sibling')!.fatherId, 'father');
    expect(session.durableTree.people, hasLength(8));
    expect(session.operations, hasLength(1));
    expect(find.byKey(const Key('biography-save-error')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'deleting a person requires confirmation and preserves relatives',
    (tester) async {
      seedRelatives();
      var closed = 0;
      await mount(tester, onClose: () => closed++);
      await edit(tester);
      await visibleTap(tester, find.byKey(const Key('delete-person')));
      expect(find.text('Удалить человека?'), findsOneWidget);
      expect(find.textContaining('нельзя отменить'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(session.operations, isEmpty);
      expect(closed, 0);
      await visibleTap(tester, find.byKey(const Key('delete-person')));
      await tester.tap(find.byKey(const Key('confirm-delete-person')));
      await tester.pumpAndSettle();
      expect(session.operations.single.type, 'deletePerson');
      expect(session.durableTree.person(rootTreePersonId), isNull);
      expect(session.durableTree.person('child')!.fatherId, isNull);
      expect(session.durableTree.person('child')!.motherId, 'other-parent');
      expect(session.durableTree.person('sibling')!.fatherId, 'father');
      expect(session.durableTree.people, hasLength(7));
      expect(closed, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed deletion keeps error and retries the hidden person once',
    (tester) async {
      seedRelatives();
      var closed = 0;
      await mount(tester, onClose: () => closed++);
      await edit(tester);
      session.failWrites = true;
      await visibleTap(tester, find.byKey(const Key('delete-person')));
      await tester.tap(find.byKey(const Key('confirm-delete-person')));
      await tester.pumpAndSettle();
      expect(session.tree.person(rootTreePersonId), isNull);
      expect(session.durableTree.person(rootTreePersonId), isNotNull);
      expect(find.text('Человек не найден в дереве'), findsOneWidget);
      expect(find.byKey(const Key('biography-save-error')), findsOneWidget);
      expect(find.textContaining('Диск недоступен'), findsOneWidget);
      expect(closed, 0);
      expect(session.operations.single.type, 'deletePerson');
      await tester.tap(find.text('Повторить сохранение'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('biography-save-error')), findsOneWidget);
      expect(session.operations, hasLength(1));
      expect(closed, 0);
      session.failWrites = false;
      await tester.tap(find.text('Повторить сохранение'));
      await tester.pumpAndSettle();
      expect(session.durableTree.person(rootTreePersonId), isNull);
      expect(session.durableTree.person('child')!.fatherId, isNull);
      expect(session.operations, hasLength(1));
      expect(session.durableTree.people, hasLength(7));
      expect(find.byKey(const Key('biography-save-error')), findsNothing);
      expect(closed, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('delete confirmation rechecks edit permission', (tester) async {
    await mount(tester);
    await edit(tester);
    await visibleTap(tester, find.byKey(const Key('delete-person')));
    session.setEditingAllowed(false);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete-person')));
    await tester.pumpAndSettle();
    expect(session.tree.person(rootTreePersonId), isNotNull);
    expect(session.operations, isEmpty);
    expect(find.byKey(const Key('biography-save-error')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(390, 844), const Size(1100, 900)]) {
    testWidgets('sibling choice precedes child and mutes from-tree at $size', (
      tester,
    ) async {
      await mount(tester, size: size, fullScreen: size.width < 900);
      await openRelative(tester);
      final labels = relativeKindDropdown(
        tester,
      ).items!.map((item) => (item.child as Text).data).toList();
      expect(labels, ['Отца', 'Мать', 'Брат/сестра', 'Ребёнка']);
      expect(labels.where((label) => label == 'Брат/сестра'), hasLength(1));
      final chips = tester
          .widgetList<ChoiceChip>(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(ChoiceChip),
            ),
          )
          .toList();
      expect(chips.map((chip) => (chip.label as Text).data).toList(), [
        'Новый человек',
        'Из дерева',
      ]);
      expect(chips.first.selected, isTrue);
      expect(find.byKey(const Key('relative-new-name')), findsOneWidget);
      await chooseRelativeKind(tester, 'Брат/сестра');
      await relativeFrames(tester);
      final siblingChips = tester
          .widgetList<ChoiceChip>(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(ChoiceChip),
            ),
          )
          .toList();
      expect(siblingChips.map((chip) => (chip.label as Text).data).toList(), [
        'Новый человек',
        'Из дерева',
      ]);
      expect(siblingChips.first.selected, isTrue);
      expect(siblingChips.first.onSelected, isNotNull);
      expect(siblingChips.last.selected, isFalse);
      expect(siblingChips.last.onSelected, isNull);
      expect(find.byKey(const Key('relative-pick-from-tree')), findsNothing);
      expect(
        dropdown<TreeSex>(tester, newRelativeSex()).value,
        TreeSex.unknown,
      );
      expect(dropdown<TreeSex>(tester, newRelativeSex()).onChanged, isNotNull);
      expect(session.operations, isEmpty);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(session.operations, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final (sex, size) in const [
    (TreeSex.male, Size(320, 568)),
    (TreeSex.female, Size(390, 844)),
    (TreeSex.unknown, Size(1100, 900)),
  ]) {
    for (final parentMask in [0, 1, 2, 3]) {
      final delayed = parentMask.isEven;
      testWidgets(
        'atomic sibling creation sex=${sex.name} copies live parents mask=$parentMask, muted from-tree frames delayed=$delayed',
        (tester) async {
          session.seed(session.tree.createPerson('father', name: 'Отец'));
          session.seed(session.tree.createPerson('mother', name: 'Мать'));
          session.seed(
            session.tree.createPerson('existing', name: 'Тёзка', sex: sex),
          );
          if ((parentMask & 1) != 0) {
            session.seed(
              session.tree.setValue(rootTreePersonId, 'fatherId', 'father'),
            );
          }
          if ((parentMask & 2) != 0) {
            session.seed(
              session.tree.setValue(rootTreePersonId, 'motherId', 'mother'),
            );
          }
          await mount(tester, size: size, fullScreen: true);
          await openRelative(tester);
          await chooseRelativeKind(tester, 'Брат/сестра');
          await relativeFrames(tester);
          expect(find.text('Из дерева'), findsOneWidget);
          expect(find.text('Новый человек'), findsOneWidget);
          expect(
            tester
                .widget<ChoiceChip>(
                  find.widgetWithText(ChoiceChip, 'Из дерева'),
                )
                .onSelected,
            isNull,
          );
          expect(
            tester
                .widget<ChoiceChip>(
                  find.widgetWithText(ChoiceChip, 'Новый человек'),
                )
                .selected,
            isTrue,
          );
          expect(
            find.byKey(const Key('relative-pick-from-tree')),
            findsNothing,
          );
          expect(
            find.byKey(const Key('relative-selected-person')),
            findsNothing,
          );
          expect(
            dropdown<TreeSex>(tester, newRelativeSex()).value,
            TreeSex.unknown,
          );
          expect(
            dropdown<TreeSex>(tester, newRelativeSex()).onChanged,
            isNotNull,
          );
          if (sex != TreeSex.unknown) {
            await tester.ensureVisible(newRelativeSex());
            await tester.tap(newRelativeSex());
            await tester.pumpAndSettle();
            await tester.tap(
              find.text(sex == TreeSex.male ? 'Мужской' : 'Женский').last,
            );
            await relativeFrames(tester);
          }
          expect(dropdown<TreeSex>(tester, newRelativeSex()).value, sex);
          final name = find.byKey(const Key('relative-new-name'));
          await tester.enterText(name, 'Тёзка');
          if (parentMask == 3) {
            await tester.ensureVisible(
              find.text('Дата рождения (необязательно)'),
            );
            await tester.tap(find.text('Дата рождения (необязательно)'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('OK'));
            await relativeFrames(tester);
          }
          expect(
            session.operations,
            isEmpty,
            reason: 'Opening and drafting never write.',
          );
          session.holdCreation = delayed;
          await tester.tap(find.byKey(const Key('confirm-add-relative')));
          await relativeFrames(tester);
          final operation = session.operations.single;
          expect(operation.type, 'createSibling');
          expect(operation.personId, isNot('existing'));
          expect(operation.toJson()['siblingId'], rootTreePersonId);
          expect(operation.toJson()['sex'], sex.name);
          expect(
            operation.toJson()['birthDate'],
            parentMask == 3 ? '1970-01-01' : isNull,
          );
          final sibling = session.tree.person(operation.personId)!;
          expect(sibling.name, 'Тёзка');
          expect(sibling.sex, sex);
          expect(sibling.fatherId, (parentMask & 1) != 0 ? 'father' : isNull);
          expect(sibling.motherId, (parentMask & 2) != 0 ? 'mother' : isNull);
          expect(
            sibling.birthDate,
            parentMask == 3 ? DateTime.utc(1970) : isNull,
          );
          expect(
            session.tree.directSiblingLinks,
            hasLength(parentMask == 3 ? 0 : 1),
          );
          if (delayed) {
            expect(find.text('Сохраняем…'), findsOneWidget);
            expect(session.durableTree.person(sibling.id), isNull);
            expect(tester.widget<TextField>(name).enabled, isFalse);
            expect(relativeKindDropdown(tester).onChanged, isNull);
            session.completeCreation();
            await relativeFrames(tester);
          }
          expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
          expect(session.operations, hasLength(1));
          expect(
            session.durableTree.person(sibling.id)!.fatherId,
            sibling.fatherId,
          );
          expect(
            session.durableTree.person(sibling.id)!.motherId,
            sibling.motherId,
          );
          expect(session.durableTree.person('existing')!.fatherId, isNull);
          expect(session.durableTree.people, hasLength(5));
          expect(
            session.durableTree
                .siblingsOf(rootTreePersonId, includeHalf: false)
                .map((p) => p.id),
            [sibling.id],
          );
          expect(session.storageError, isNull);
        },
      );
    }
  }

  testWidgets(
    'explicit sibling chips expose only the current direct edge, not transitive peers',
    (tester) async {
      session.seed(
        session.tree.createSibling(rootTreePersonId, 'direct', name: 'Прямой'),
      );
      session.seed(
        session.tree.createSibling('direct', 'transitive', name: 'Через брата'),
      );
      final selected = <String>[];
      await mount(tester, onSelect: selected.add);
      final direct = find.byKey(
        const ValueKey('relative-Братья и сёстры-direct'),
      );
      final transitive = find.byKey(
        const ValueKey('relative-Братья и сёстры-transitive'),
      );
      await reveal(tester, direct);
      expect(tester.widget(direct), isA<ActionChip>());
      expect(siblingUnlink('direct'), findsNothing);
      await edit(tester);
      await reveal(tester, direct);
      expect(tester.widget(direct), isA<InputChip>());
      expect(siblingUnlink('direct'), findsOneWidget);
      expect(tester.widget(transitive), isA<ActionChip>());
      expect(siblingUnlink('transitive'), findsNothing);
      await visibleTap(tester, transitive);
      expect(selected, ['transitive']);
      expect(session.operations, isEmpty);
      expect(session.tree.directSiblingLinks, hasLength(2));
    },
  );

  testWidgets(
    'direct sibling X preserves parent records and leaves derived half siblings',
    (tester) async {
      session.seed(session.tree.createPerson('father', name: 'Отец'));
      session.seed(
        session.tree.setValue(rootTreePersonId, 'fatherId', 'father'),
      );
      session.seed(
        session.tree.createSibling(rootTreePersonId, 'brother', name: 'Брат'),
      );
      session.seed(
        session.tree.createSibling('brother', 'sister', name: 'Сестра'),
      );
      await mount(tester);
      await edit(tester);
      await visibleTap(tester, siblingUnlink('brother'));
      expect(find.byType(AlertDialog), findsNothing);
      expect(session.operations.single.type, 'unlinkSibling');
      expect(session.tree.directSiblingLinks, hasLength(1));
      for (final id in [rootTreePersonId, 'brother', 'sister']) {
        expect(session.durableTree.person(id)!.fatherId, 'father');
        expect(session.durableTree.person(id)!.motherId, isNull);
      }
      expect(session.durableTree.people, hasLength(4));
      expect(
        session.tree.siblingsOf(rootTreePersonId, includeHalf: false),
        isEmpty,
      );
      for (final id in ['brother', 'sister']) {
        final half = find.byKey(
          ValueKey('relative-Неполнородные братья и сёстры-$id'),
        );
        await reveal(tester, half);
        expect(tester.widget(half), isA<ActionChip>());
        expect(
          find.descendant(of: half, matching: find.byIcon(Icons.close)),
          findsNothing,
        );
      }
    },
  );

  testWidgets(
    'biography parent set and clear propagate through an explicit group; second parent retires direct edges',
    (tester) async {
      session.seed(
        session.tree.createSibling(rootTreePersonId, 'brother', name: 'Брат'),
      );
      session.seed(
        session.tree.createSibling('brother', 'sister', name: 'Сестра'),
      );
      session.seed(
        session.tree.createPerson('father', name: 'Папа', sex: TreeSex.male),
      );
      session.seed(
        session.tree.createPerson('mother', name: 'Мама', sex: TreeSex.female),
      );
      await mount(tester);
      await openRelative(tester);
      await chooseExisting(tester, 'Папа');
      await tester.tap(find.byKey(const Key('confirm-add-relative')));
      await relativeFrames(tester);
      expect(session.operations.single.fieldKey, 'fatherId');
      for (final id in [rootTreePersonId, 'brother', 'sister']) {
        expect(session.durableTree.person(id)!.fatherId, 'father');
      }
      await visibleTap(tester, unlink('Отец', 'father'));
      for (final id in [rootTreePersonId, 'brother', 'sister']) {
        expect(session.durableTree.person(id)!.fatherId, isNull);
      }
      expect(session.tree.directSiblingLinks, hasLength(2));
      await visibleTap(tester, find.byKey(const Key('add-relative')));
      await chooseExisting(tester, 'Папа');
      await tester.tap(find.byKey(const Key('confirm-add-relative')));
      await relativeFrames(tester);
      await visibleTap(tester, find.byKey(const Key('add-relative')));
      await chooseExisting(tester, 'Мама');
      await tester.tap(find.byKey(const Key('confirm-add-relative')));
      await relativeFrames(tester);
      expect(session.operations, hasLength(4));
      expect(
        session.operations.every((operation) => operation.type == 'setValue'),
        isTrue,
      );
      expect(session.tree.directSiblingLinks, isEmpty);
      for (final id in [rootTreePersonId, 'brother', 'sister']) {
        final person = session.durableTree.person(id)!;
        expect(person.fatherId, 'father');
        expect(person.motherId, 'mother');
      }
      expect(
        session.tree.siblingsOf(rootTreePersonId, includeHalf: false),
        hasLength(2),
      );
      await reveal(
        tester,
        find.byKey(const ValueKey('relative-Братья и сёстры-brother')),
      );
      expect(siblingUnlink('brother'), findsNothing);
      await visibleTap(tester, unlink('Отец', 'father'));
      expect(session.durableTree.person(rootTreePersonId)!.fatherId, isNull);
      expect(session.durableTree.person('brother')!.fatherId, 'father');
      expect(session.durableTree.person('sister')!.fatherId, 'father');
      expect(session.durableTree.person('father'), isNotNull);
      expect(session.tree.directSiblingLinks, isEmpty);
      expect(session.operations, hasLength(5));
    },
  );

  for (final completeParents in [false, true]) {
    testWidgets(
      'failed atomic sibling save retries one event, complete parents=$completeParents',
      (tester) async {
        if (completeParents) {
          seedRelatives();
        }
        await mount(tester);
        await openRelative(tester);
        await chooseRelativeKind(tester, 'Брат/сестра');
        await tester.enterText(
          find.byKey(const Key('relative-new-name')),
          'Новая сестра',
        );
        session.failWrites = true;
        final add = find.byKey(const Key('confirm-add-relative'));
        await tester.tap(add);
        await relativeFrames(tester, expectedError: 'Диск недоступен');
        final operation = session.operations.single;
        final pending = session._pending.single.id;
        final clock = session._clock;
        expect(operation.type, 'createSibling');
        expect(session.tree.person(operation.personId), isNotNull);
        expect(session.durableTree.person(operation.personId), isNull);
        expect(
          session.tree.directSiblingLinks,
          hasLength(completeParents ? 0 : 1),
        );
        expect(relativeKindDropdown(tester).onChanged, isNull);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('relative-new-name')))
              .enabled,
          isFalse,
        );
        expect(
          find.descendant(of: add, matching: find.text('Повторить сохранение')),
          findsOneWidget,
        );
        await tester.tap(add);
        await relativeFrames(tester, expectedError: 'Диск недоступен');
        expect(session._pending.single.id, pending);
        expect(session._clock, clock);
        session.failWrites = false;
        await tester.tap(add);
        await relativeFrames(tester);
        expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
        expect(session.operations, hasLength(1));
        expect(session._clock, clock);
        expect(
          session.durableTree.person(operation.personId)!.name,
          'Новая сестра',
        );
        expect(
          session.tree.people.values.where(
            (person) => person.name == 'Новая сестра',
          ),
          hasLength(1),
        );
        expect(session.storageError, isNull);
      },
    );
  }

  testWidgets(
    'failed atomic sibling retry cannot restore a remotely unlinked relationship',
    (tester) async {
      await mount(tester);
      await openRelative(tester);
      await chooseRelativeKind(tester, 'Брат/сестра');
      await tester.enterText(
        find.byKey(const Key('relative-new-name')),
        'Новый брат',
      );
      session.failWrites = true;
      final add = find.byKey(const Key('confirm-add-relative'));
      await tester.tap(add);
      await relativeFrames(tester, expectedError: 'Диск недоступен');
      final siblingId = session.operations.single.personId;
      final retry = tester.widget<FilledButton>(add).onPressed!;
      session.remote(session.tree.unlinkSibling(rootTreePersonId, siblingId));
      session.failWrites = false;
      final clock = session._clock;
      retry();
      await relativeFrames(tester, expectedError: 'Связь изменилась');
      expect(session.operations, hasLength(1));
      expect(session._clock, clock);
      await session.flush();
      expect(session.durableTree.person(siblingId), isNotNull);
      expect(session.tree.directSiblingLinks, isEmpty);
      expect(session.tree.siblingsOf(rootTreePersonId), isEmpty);
    },
  );

  testWidgets(
    'failed direct sibling unlink retries the same event without clearing parents',
    (tester) async {
      session.seed(session.tree.createPerson('father', name: 'Отец'));
      session.seed(
        session.tree.setValue(rootTreePersonId, 'fatherId', 'father'),
      );
      session.seed(
        session.tree.createSibling(rootTreePersonId, 'brother', name: 'Брат'),
      );
      await mount(tester);
      await edit(tester);
      session.failWrites = true;
      await visibleTap(tester, siblingUnlink('brother'));
      expect(session.operations.single.type, 'unlinkSibling');
      final eventId = session._pending.single.id;
      expect(session.tree.directSiblingLinks, isEmpty);
      expect(session.durableTree.directSiblingLinks, hasLength(1));
      await tester.tap(find.text('Повторить сохранение'));
      await tester.pumpAndSettle();
      expect(session._pending.single.id, eventId);
      expect(session.operations, hasLength(1));
      session.failWrites = false;
      await tester.tap(find.text('Повторить сохранение'));
      await tester.pumpAndSettle();
      expect(session.durableTree.directSiblingLinks, isEmpty);
      expect(session.durableTree.person(rootTreePersonId)!.fatherId, 'father');
      expect(session.durableTree.person('brother')!.fatherId, 'father');
      expect(session.operations, hasLength(1));
    },
  );

  testWidgets(
    'sibling creation rejects captured existing-picker callbacks and pending picks',
    (tester) async {
      session.seed(session.tree.createPerson('existing', name: 'Существующий'));
      final picked = Completer<String?>();
      var pickerCalls = 0;
      await mount(
        tester,
        onPickFromTree: (_, __) {
          pickerCalls++;
          return picked.future;
        },
      );
      await openRelative(tester);
      await chooseFromTree(tester);
      final stalePick = tester
          .widget<OutlinedButton>(
            find.byKey(const Key('relative-pick-from-tree')),
          )
          .onPressed!;
      final staleExisting = tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Из дерева'))
          .onSelected!;
      stalePick();
      await tester.pump();
      expect(pickerCalls, 1);
      await chooseRelativeKind(tester, 'Брат/сестра');
      picked.complete('existing');
      await relativeFrames(tester);
      stalePick();
      staleExisting(true);
      await relativeFrames(tester);
      expect(pickerCalls, 1);
      expect(find.byKey(const Key('relative-selected-person')), findsNothing);
      expect(find.byKey(const Key('relative-pick-from-tree')), findsNothing);
      expect(find.byKey(const Key('relative-new-name')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('relative-new-name')),
        'Новый',
      );
      await tester.tap(find.byKey(const Key('confirm-add-relative')));
      await relativeFrames(tester);
      expect(session.operations.single.type, 'createSibling');
      expect(session.operations.single.personId, isNot('existing'));
      expect(session.tree.person('existing')!.fatherId, isNull);
      expect(
        session.tree.siblingsOf(rootTreePersonId).map((person) => person.id),
        [session.operations.single.personId],
      );
    },
  );

  testWidgets(
    'captured direct sibling X cannot remove a retired claim or parent',
    (tester) async {
      session.seed(session.tree.createPerson('father', name: 'Отец'));
      session.seed(session.tree.createPerson('mother', name: 'Мать'));
      session.seed(
        session.tree.setValue(rootTreePersonId, 'fatherId', 'father'),
      );
      session.seed(
        session.tree.createSibling(rootTreePersonId, 'brother', name: 'Брат'),
      );
      await mount(tester);
      await edit(tester);
      final chip = find.byKey(
        const ValueKey('relative-Братья и сёстры-brother'),
      );
      await reveal(tester, chip);
      final staleRemove = tester.widget<InputChip>(chip).onDeleted!;
      session.remote(
        session.tree.setValue(rootTreePersonId, 'motherId', 'mother'),
      );
      expect(session.tree.directSiblingLinks, isEmpty);
      staleRemove();
      await tester.pumpAndSettle();
      expect(session.operations, isEmpty);
      for (final id in [rootTreePersonId, 'brother']) {
        expect(session.durableTree.person(id)!.fatherId, 'father');
        expect(session.durableTree.person(id)!.motherId, 'mother');
      }
      expect(tester.widget(chip), isA<ActionChip>());
      expect(siblingUnlink('brother'), findsNothing);
    },
  );

  testWidgets(
    'captured sibling submit after source deletion creates no orphan',
    (tester) async {
      session.seed(session.tree.createPerson('survivor', name: 'Другой'));
      await mount(tester);
      await openRelative(tester);
      await chooseRelativeKind(tester, 'Брат/сестра');
      await tester.enterText(
        find.byKey(const Key('relative-new-name')),
        'Новый',
      );
      final submit = tester
          .widget<FilledButton>(find.byKey(const Key('confirm-add-relative')))
          .onPressed!;
      session.remote(session.tree.deletePerson(rootTreePersonId));
      submit();
      await relativeFrames(
        tester,
        expectedError: 'Не удалось добавить родственника',
      );
      expect(session.operations, isEmpty);
      expect(session.durableTree.people.keys, ['survivor']);
      expect(session.tree.directSiblingLinks, isEmpty);
    },
  );

  testWidgets(
    'guest cannot create or unlink explicit siblings through captured controls',
    (tester) async {
      session.seed(
        session.tree.createSibling(rootTreePersonId, 'brother', name: 'Брат'),
      );
      await mount(tester);
      await openRelative(tester);
      await chooseRelativeKind(tester, 'Брат/сестра');
      await tester.enterText(
        find.byKey(const Key('relative-new-name')),
        'Новая',
      );
      final add = tester
          .widget<FilledButton>(find.byKey(const Key('confirm-add-relative')))
          .onPressed!;
      session.setEditingAllowed(false);
      add();
      await relativeFrames(tester, expectedError: 'В режиме гостя');
      expect(session.operations, isEmpty);
      expect(session.tree.people, hasLength(2));
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('add-relative')), findsNothing);
      expect(siblingUnlink('brother'), findsNothing);
      session.setEditingAllowed(true);
      await tester.pumpAndSettle();
      await edit(tester);
      final chip = find.byKey(
        const ValueKey('relative-Братья и сёстры-brother'),
      );
      await reveal(tester, chip);
      final remove = tester.widget<InputChip>(chip).onDeleted!;
      session.setEditingAllowed(false);
      remove();
      await tester.pumpAndSettle();
      expect(session.operations, isEmpty);
      expect(session.durableTree.directSiblingLinks, hasLength(1));
      expect(find.byKey(const Key('add-relative')), findsNothing);
    },
  );

  for (final (kind, focusSex, relativeSex, field) in const [
    ('Отца', TreeSex.male, TreeSex.male, 'fatherId'),
    ('Мать', TreeSex.female, TreeSex.female, 'motherId'),
    ('Ребёнка', TreeSex.male, TreeSex.female, 'fatherId'),
    ('Ребёнка', TreeSex.female, TreeSex.male, 'motherId'),
  ]) {
    for (final createNew in [false, true]) {
      for (final delayedSave in [false, true]) {
        testWidgets(
          'successful $kind $field (new=$createNew, delayed=$delayedSave) never flashes a form error',
          (tester) async {
            session.seed(
              session.tree.setValue(rootTreePersonId, 'sex', focusSex.name),
            );
            if (!createNew) {
              session.seed(
                session.tree.createPerson(
                  'candidate',
                  name: 'Родственник',
                  sex: relativeSex,
                ),
              );
            }
            await mount(tester, size: const Size(390, 844), fullScreen: true);
            await openRelative(tester);
            if (kind != 'Отца') await chooseRelativeKind(tester, kind);
            if (createNew) {
              await tester.tap(find.text('Новый человек'));
              await relativeFrames(tester);
              await tester.enterText(
                find.byKey(const Key('relative-new-name')),
                'Родственник',
              );
            } else {
              await chooseExisting(tester, 'Родственник');
            }
            expect(session.operations, isEmpty);
            session.holdCreation = createNew && delayedSave;
            session.holdParentLink = delayedSave;
            await tester.tap(find.byKey(const Key('confirm-add-relative')));
            await relativeFrames(tester);
            if (createNew && delayedSave) {
              expect(session.operations.single.type, 'createPerson');
              expect(find.byType(AlertDialog), findsOneWidget);
              session.completeCreation();
              await relativeFrames(tester);
            }
            final relativeId = createNew
                ? session.operations.first.personId
                : 'candidate';
            final childId = kind == 'Ребёнка' ? relativeId : rootTreePersonId;
            final parentId = kind == 'Ребёнка' ? rootTreePersonId : relativeId;
            final optimisticChild = session.tree.person(childId)!;
            expect(
              field == 'motherId'
                  ? optimisticChild.motherId
                  : optimisticChild.fatherId,
              parentId,
            );
            if (delayedSave) {
              expect(find.byType(AlertDialog), findsOneWidget);
              expect(find.text('Сохраняем…'), findsOneWidget);
              final durableChild = session.durableTree.person(childId)!;
              expect(
                field == 'motherId'
                    ? durableChild.motherId
                    : durableChild.fatherId,
                isNull,
              );
              session.completeParentLink();
              await relativeFrames(tester);
            }
            expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
            expect(session.operations, hasLength(createNew ? 2 : 1));
            expect(session.operations.last.toJson(), {
              'type': 'setValue',
              'personId': childId,
              'field': field,
              'value': parentId,
            });
            final durableChild = session.durableTree.person(childId)!;
            expect(
              field == 'motherId'
                  ? durableChild.motherId
                  : durableChild.fatherId,
              parentId,
            );
            expect(session.storageError, isNull);
          },
        );
      }
    }
  }

  for (final kind in ['Отца', 'Ребёнка']) {
    for (final createNew in [false, true]) {
      testWidgets(
        'failed $kind link (new=$createNew) keeps its save error and retries the same event',
        (tester) async {
          session.seed(
            session.tree.setValue(rootTreePersonId, 'sex', 'female'),
          );
          if (!createNew) {
            session.seed(
              session.tree.createPerson('candidate', name: 'Родственник'),
            );
          }
          await mount(tester);
          await openRelative(tester);
          if (kind != 'Отца') await chooseRelativeKind(tester, kind);
          if (createNew) {
            await tester.tap(find.text('Новый человек'));
            await relativeFrames(tester);
            await tester.enterText(
              find.byKey(const Key('relative-new-name')),
              'Родственник',
            );
          } else {
            await chooseExisting(tester, 'Родственник');
          }
          session.failParentLink = true;
          final add = find.byKey(const Key('confirm-add-relative'));
          await tester.tap(add);
          await relativeFrames(tester, expectedError: 'Диск недоступен');
          expect(
            tester.widget<Text>(find.byKey(const Key('relative-error'))).data,
            isNot(contains('уже указан')),
          );
          final relativeId = createNew
              ? session.operations.first.personId
              : 'candidate';
          final childId = kind == 'Ребёнка' ? relativeId : rootTreePersonId;
          final parentId = kind == 'Ребёнка' ? rootTreePersonId : relativeId;
          final field = kind == 'Ребёнка' ? 'motherId' : 'fatherId';
          final optimisticChild = session.tree.person(childId)!;
          expect(
            field == 'motherId'
                ? optimisticChild.motherId
                : optimisticChild.fatherId,
            parentId,
          );
          final pendingId = session._pending.single.id;
          final clock = session._clock;
          expect(tester.widget<FilledButton>(add).onPressed, isNotNull);
          await tester.tap(add);
          await relativeFrames(tester, expectedError: 'Диск недоступен');
          expect(session._pending.single.id, pendingId);
          expect(session._clock, clock);
          expect(session.operations, hasLength(createNew ? 2 : 1));
          session.failParentLink = false;
          await tester.tap(add);
          await relativeFrames(tester);
          expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
          final durableChild = session.durableTree.person(childId)!;
          expect(
            field == 'motherId' ? durableChild.motherId : durableChild.fatherId,
            parentId,
          );
          expect(session._clock, clock);
          expect(session._pending, isEmpty);
          expect(session.operations, hasLength(createNew ? 2 : 1));
          expect(session.storageError, isNull);
        },
      );
    }
  }

  testWidgets(
    'failed new-person creation retries its original person before linking',
    (tester) async {
      await mount(tester);
      await openRelative(tester);
      await tester.tap(find.text('Новый человек'));
      await relativeFrames(tester);
      await tester.enterText(
        find.byKey(const Key('relative-new-name')),
        'Родитель',
      );
      session.failWrites = true;
      final add = find.byKey(const Key('confirm-add-relative'));
      await tester.tap(add);
      await relativeFrames(tester, expectedError: 'Диск недоступен');
      final createdId = session.operations.single.personId;
      final pendingId = session._pending.single.id;
      await tester.tap(add);
      await relativeFrames(tester, expectedError: 'Диск недоступен');
      expect(session.operations, hasLength(1));
      expect(session._pending.single.id, pendingId);
      session.failWrites = false;
      await tester.tap(add);
      await relativeFrames(tester);
      expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
      expect(session.operations.map((operation) => operation.type), [
        'createPerson',
        'setValue',
      ]);
      expect(session.durableTree.person(rootTreePersonId)!.fatherId, createdId);
      expect(session.durableTree.people, hasLength(2));
      expect(session._pending, isEmpty);
    },
  );

  testWidgets(
    'retrying a failed parent link cannot overwrite its remote replacement',
    (tester) async {
      session.seed(session.tree.createPerson('candidate', name: 'Родитель'));
      session.seed(
        session.tree.createPerson('remote-parent', name: 'Другой родитель'),
      );
      await mount(tester);
      await openRelative(tester);
      await chooseExisting(tester, 'Родитель');
      session.failParentLink = true;
      final add = find.byKey(const Key('confirm-add-relative'));
      await tester.tap(add);
      await relativeFrames(tester, expectedError: 'Диск недоступен');
      final retry = tester.widget<FilledButton>(add).onPressed!;
      session.remote(
        session.tree.setValue(rootTreePersonId, 'fatherId', 'remote-parent'),
      );
      final clock = session._clock;
      session.failParentLink = false;
      retry();
      await relativeFrames(tester, expectedError: 'Связь изменилась');
      expect(session.operations, hasLength(1));
      expect(session._clock, clock);
      expect(session.tree.person(rootTreePersonId)!.fatherId, 'remote-parent');
      expect(
        session.durableTree.person(rootTreePersonId)!.fatherId,
        'remote-parent',
      );
      expect(tester.widget<FilledButton>(add).onPressed, isNull);
      await session.flush();
      expect(
        session.durableTree.person(rootTreePersonId)!.fatherId,
        'remote-parent',
      );
      expect(session.operations, hasLength(1));
    },
  );

  for (final kind in ['Отца', 'Ребёнка']) {
    testWidgets(
      'genuine remote occupancy stays visible during delayed new $kind save',
      (tester) async {
        session.seed(
          session.tree.createPerson('remote-parent', name: 'Родитель'),
        );
        await mount(tester);
        await openRelative(tester);
        if (kind != 'Отца') await chooseRelativeKind(tester, kind);
        await tester.tap(find.text('Новый человек'));
        await relativeFrames(tester);
        await tester.enterText(
          find.byKey(const Key('relative-new-name')),
          'Новый человек',
        );
        session.holdCreation = true;
        await tester.tap(find.byKey(const Key('confirm-add-relative')));
        await relativeFrames(tester);
        final createdId = session.operations.single.personId;
        final childId = kind == 'Ребёнка' ? createdId : rootTreePersonId;
        session.remote(
          session.tree.setValue(childId, 'fatherId', 'remote-parent'),
        );
        await relativeFrames(tester, expectedError: 'Отец уже указан');
        session.completeCreation();
        await relativeFrames(tester, expectedError: 'Отец уже указан');
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(session.operations.single.type, 'createPerson');
        expect(session.durableTree.person(childId)!.fatherId, 'remote-parent');
        expect(session.durableTree.person(createdId), isNotNull);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('confirm-add-relative')),
              )
              .onPressed,
          isNull,
        );
      },
    );
  }

  for (final brightness in Brightness.values) {
    for (final (hasFather, hasMother) in const [
      (true, false),
      (false, true),
      (true, true),
    ]) {
      testWidgets(
        '${brightness.name} unavailable parent choices are visibly muted ($hasFather/$hasMother)',
        (tester) async {
          session.seed(session.tree.createPerson('father', name: 'Отец'));
          session.seed(session.tree.createPerson('mother', name: 'Мать'));
          if (hasFather) {
            session.seed(
              session.tree.setValue(rootTreePersonId, 'fatherId', 'father'),
            );
          }
          if (hasMother) {
            session.seed(
              session.tree.setValue(rootTreePersonId, 'motherId', 'mother'),
            );
          }
          await mount(tester, theme: ThemeData(brightness: brightness));
          await openRelative(tester);
          final field = find.byKey(const Key('relative-kind'));
          final theme = Theme.of(tester.element(field));
          for (final (label, occupied) in [
            ('Отца', hasFather),
            ('Мать', hasMother),
          ]) {
            final option = relativeKindOption(tester, label);
            expect(option.enabled, !occupied);
            expect(
              (option.child as Text).style?.color,
              occupied ? theme.disabledColor : isNull,
            );
          }
          expect(
            (relativeKindOption(tester, 'Брат/сестра').child as Text).style,
            isNull,
          );
          expect(
            (relativeKindOption(tester, 'Ребёнка').child as Text).style,
            isNull,
          );
          final selected = relativeKindDropdown(tester).value;
          await tester.tap(field);
          await tester.pumpAndSettle();
          final disabledLabel = hasFather ? 'Отца' : 'Мать';
          final disabledText = find.text(disabledLabel).last;
          expect(
            tester.widget<Text>(disabledText).style!.color,
            theme.disabledColor,
          );
          await tester.tap(disabledText);
          await tester.pumpAndSettle();
          expect(relativeKindDropdown(tester).value, selected);
          expect(session.operations, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final (hasFather, hasMother) in const [
    (true, false),
    (false, true),
    (true, true),
  ]) {
    testWidgets(
      'occupied parent options father=$hasFather mother=$hasMother stay disabled; child stays available',
      (tester) async {
        session.seed(session.tree.createPerson('father', name: 'Отец'));
        session.seed(session.tree.createPerson('mother', name: 'Мать'));
        session.seed(session.tree.createPerson('candidate', name: 'Алекс'));
        if (hasFather) {
          session.seed(
            session.tree.setValue(rootTreePersonId, 'fatherId', 'father'),
          );
        }
        if (hasMother) {
          session.seed(
            session.tree.setValue(rootTreePersonId, 'motherId', 'mother'),
          );
        }
        await mount(tester);
        await openRelative(tester);
        expect(relativeKindOption(tester, 'Отца').enabled, !hasFather);
        expect(relativeKindOption(tester, 'Мать').enabled, !hasMother);
        expect(relativeKindOption(tester, 'Ребёнка').enabled, isTrue);
        final initial = !hasFather
            ? 'Отца'
            : !hasMother
            ? 'Мать'
            : 'Ребёнка';
        expect(
          relativeKindDropdown(tester).value,
          relativeKindOption(tester, initial).value,
        );
        expect(session.operations, isEmpty);
        await chooseRelativeKind(tester, 'Ребёнка');
        await chooseExisting(tester, 'Алекс');
        await tester.tap(find.byKey(const Key('confirm-add-relative')));
        await tester.pumpAndSettle();
        final focus = session.durableTree.person(rootTreePersonId)!;
        expect(focus.fatherId, hasFather ? 'father' : isNull);
        expect(focus.motherId, hasMother ? 'mother' : isNull);
        expect(
          session.durableTree.person('candidate')!.fatherId,
          rootTreePersonId,
        );
        expect(session.operations, hasLength(1));
        expect(session.operations.single.personId, 'candidate');
        expect(session.tree.people, hasLength(4));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final (label, field) in const [
    ('Отца', 'fatherId'),
    ('Мать', 'motherId'),
  ]) {
    for (final createNew in [false, true]) {
      testWidgets(
        'stale $field Add and picker cannot replace a remote parent (new=$createNew)',
        (tester) async {
          session.seed(
            session.tree.createPerson('remote-parent', name: 'Родитель'),
          );
          session.seed(session.tree.createPerson('candidate', name: 'Алекс'));
          var pickerCalls = 0;
          await mount(
            tester,
            onPickFromTree: (_, _) async {
              pickerCalls++;
              return 'candidate';
            },
          );
          await openRelative(tester);
          if (label != 'Отца') await chooseRelativeKind(tester, label);
          await chooseFromTree(tester);
          final pick = find.byKey(const Key('relative-pick-from-tree'));
          final openPicker = tester.widget<OutlinedButton>(pick).onPressed!;
          if (createNew) {
            await tester.tap(find.text('Новый человек'));
            await tester.pumpAndSettle();
            await tester.enterText(
              find.byKey(const Key('relative-new-name')),
              'Не создавать',
            );
          } else {
            await tester.tap(pick);
            await tester.pumpAndSettle();
            expect(pickerCalls, 1);
          }
          final add = tester
              .widget<FilledButton>(
                find.byKey(const Key('confirm-add-relative')),
              )
              .onPressed!;
          session.remote(
            session.tree.setValue(rootTreePersonId, field, 'remote-parent'),
          );
          final clock = session._clock;
          // Both callbacks came from the enabled UI before the remote update.
          openPicker();
          add();
          await tester.pumpAndSettle();
          expect(pickerCalls, createNew ? 0 : 1);
          expect(session.operations, isEmpty);
          expect(
            session._clock,
            clock,
            reason: 'No replacement or orphan history.',
          );
          expect(session.tree.people, hasLength(3));
          expect(
            session.tree.person(rootTreePersonId)!.fatherId,
            field == 'fatherId' ? 'remote-parent' : isNull,
          );
          expect(
            session.tree.person(rootTreePersonId)!.motherId,
            field == 'motherId' ? 'remote-parent' : isNull,
          );
          expect(relativeKindOption(tester, label).enabled, isFalse);
          expect(find.byKey(const Key('relative-error')), findsOneWidget);
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const Key('confirm-add-relative')),
                )
                .onPressed,
            isNull,
          );
          if (!createNew) {
            expect(tester.widget<OutlinedButton>(pick).onPressed, isNull);
          }
          session.remote(session.tree.setValue(rootTreePersonId, field, null));
          await tester.pumpAndSettle();
          expect(relativeKindOption(tester, label).enabled, isTrue);
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const Key('confirm-add-relative')),
                )
                .onPressed,
            isNotNull,
          );
          expect(session.operations, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final (label, field) in const [
    ('Отца', 'fatherId'),
    ('Мать', 'motherId'),
  ]) {
    testWidgets('picker rejects $field occupied while it was open', (
      tester,
    ) async {
      session.seed(session.tree.createPerson('candidate', name: 'Алекс'));
      session.seed(
        session.tree.createPerson('remote-parent', name: 'Родитель'),
      );
      final result = Completer<String?>();
      late bool Function(TreePerson) filter;
      await mount(
        tester,
        onPickFromTree: (_, canPick) {
          filter = canPick;
          return result.future;
        },
      );
      await openRelative(tester);
      if (label != 'Отца') await chooseRelativeKind(tester, label);
      await chooseFromTree(tester);
      await tester.tap(find.byKey(const Key('relative-pick-from-tree')));
      await tester.pumpAndSettle();
      final stale = session.tree.person('candidate')!;
      expect(filter(stale), isTrue);
      session.remote(
        session.tree.setValue(rootTreePersonId, field, 'remote-parent'),
      );
      expect(filter(stale), isFalse);
      result.complete('candidate');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('relative-selected-person')), findsNothing);
      expect(find.byKey(const Key('relative-error')), findsOneWidget);
      expect(session.operations, isEmpty);
      expect(session.tree.people, hasLength(3));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'new $field cannot overwrite a parent arriving during creation',
      (tester) async {
        session.seed(
          session.tree.createPerson('remote-parent', name: 'Родитель'),
        );
        session.holdCreation = true;
        await mount(tester);
        await openRelative(tester);
        if (label != 'Отца') await chooseRelativeKind(tester, label);
        await tester.tap(find.text('Новый человек'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('relative-new-name')),
          'Новый родитель',
        );
        await tester.tap(find.text('Дата рождения (необязательно)'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('confirm-add-relative')));
        await tester.pump();
        final createdId = session.operations.single.personId;
        expect(session.operations.single.type, 'createPerson');
        session.remote(
          session.tree.setValue(rootTreePersonId, field, 'remote-parent'),
        );
        final clock = session._clock;
        session.completeCreation();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          find.textContaining('Новый человек остался в дереве'),
          findsOneWidget,
        );
        expect(session.durableTree.person(createdId), isNotNull);
        expect(session.durableTree.people, hasLength(3));
        final focus = session.durableTree.person(rootTreePersonId)!;
        expect(focus.fatherId, field == 'fatherId' ? 'remote-parent' : isNull);
        expect(focus.motherId, field == 'motherId' ? 'remote-parent' : isNull);
        expect(session.operations, hasLength(1));
        expect(session._clock, clock);
        await tester.tap(find.byKey(const Key('confirm-add-relative')));
        await tester.pumpAndSettle();
        expect(
          session.operations,
          hasLength(1),
          reason: 'No duplicate or rollback.',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'parent occupancy is rechecked after awaiting the new birth date',
    (tester) async {
      session.seed(
        session.tree.createPerson('remote-parent', name: 'Родитель'),
      );
      session.holdBirthDate = true;
      await mount(tester);
      await openRelative(tester);
      await tester.tap(find.text('Новый человек'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('relative-new-name')),
        'Новый родитель',
      );
      await tester.tap(find.text('Дата рождения (необязательно)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-add-relative')));
      await tester.pump();
      expect(session.operations.map((operation) => operation.type), [
        'createPerson',
        'setValue',
      ]);
      expect(session.operations.last.fieldKey, 'birthDate');
      final createdId = session.operations.first.personId;
      session.remote(
        session.tree.setValue(rootTreePersonId, 'fatherId', 'remote-parent'),
      );
      final clock = session._clock;
      session.completeBirthDate();
      await tester.pumpAndSettle();
      expect(
        session.durableTree.person(rootTreePersonId)!.fatherId,
        'remote-parent',
      );
      expect(
        session.durableTree.person(createdId)!.birthDate,
        DateTime.utc(1970),
      );
      expect(session.operations, hasLength(2));
      expect(session._clock, clock);
      expect(
        find.textContaining('Новый человек остался в дереве'),
        findsOneWidget,
      );
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final losePermission in [false, true]) {
    testWidgets(
      'child picker and Add use live occupied slots (role revoked=$losePermission)',
      (tester) async {
        session.seed(session.tree.setValue(rootTreePersonId, 'sex', 'female'));
        session.seed(session.tree.createPerson('child', name: 'Ребёнок'));
        session.seed(
          session.tree.createPerson('other-parent', name: 'Другой родитель'),
        );
        session.seed(
          session.tree.setValue('child', 'fatherId', 'other-parent'),
        );
        var result = Completer<String?>();
        late bool Function(TreePerson) filter;
        await mount(
          tester,
          onPickFromTree: (_, canPick) {
            filter = canPick;
            return result.future;
          },
        );
        await openRelative(tester);
        await chooseRelativeKind(tester, 'Ребёнка');
        await chooseFromTree(tester);
        final pick = find.byKey(const Key('relative-pick-from-tree'));
        await tester.tap(pick);
        await tester.pumpAndSettle();
        final stale = session.tree.person('child')!;
        expect(
          filter(stale),
          isTrue,
          reason: 'Only the father slot is occupied.',
        );
        session.remote(session.tree.setValue(rootTreePersonId, 'sex', 'male'));
        expect(
          filter(stale),
          isFalse,
          reason: 'Now the occupied father slot is targeted.',
        );
        result.complete('child');
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('relative-selected-person')), findsNothing);
        expect(session.operations, isEmpty);
        session.remote(
          session.tree.setValue(rootTreePersonId, 'sex', 'female'),
        );
        await tester.pumpAndSettle();
        result = Completer<String?>();
        await tester.tap(pick);
        await tester.pumpAndSettle();
        result.complete('child');
        await tester.pumpAndSettle();
        final add = tester
            .widget<FilledButton>(find.byKey(const Key('confirm-add-relative')))
            .onPressed!;
        if (losePermission) {
          session.setEditingAllowed(false);
        } else {
          session.remote(
            session.tree.setValue(rootTreePersonId, 'sex', 'male'),
          );
        }
        final clock = session._clock;
        add();
        await tester.pumpAndSettle();
        expect(session.durableTree.person('child')!.fatherId, 'other-parent');
        expect(session.durableTree.person('child')!.motherId, isNull);
        expect(session.operations, isEmpty);
        expect(session._clock, clock);
        expect(find.byKey(const Key('relative-error')), findsOneWidget);
        expect(relativeKindOption(tester, 'Ребёнка').enabled, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'new child uses live parent role and preserves a slot filled during creation',
    (tester) async {
      session.seed(session.tree.setValue(rootTreePersonId, 'sex', 'female'));
      session.seed(
        session.tree.createPerson('other-parent', name: 'Другой родитель'),
      );
      session.holdCreation = true;
      await mount(tester);
      await openRelative(tester);
      await chooseRelativeKind(tester, 'Ребёнка');
      await tester.tap(find.text('Новый человек'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('relative-new-name')),
        'Новый ребёнок',
      );
      await tester.tap(find.byKey(const Key('confirm-add-relative')));
      await tester.pump();
      final childId = session.operations.single.personId;
      session.remote(
        session.tree.setValue(childId, 'fatherId', 'other-parent'),
      );
      session.remote(session.tree.setValue(rootTreePersonId, 'sex', 'male'));
      final clock = session._clock;
      session.completeCreation();
      await tester.pumpAndSettle();
      final child = session.durableTree.person(childId)!;
      expect(child.fatherId, 'other-parent');
      expect(child.motherId, isNull);
      expect(session.operations.single.type, 'createPerson');
      expect(session._clock, clock);
      expect(session.durableTree.people, hasLength(3));
      expect(
        find.textContaining('Новый человек остался в дереве'),
        findsOneWidget,
      );
      expect(find.text('Роль выбранного человека'), findsNothing);
      expect(find.byType(DropdownButtonFormField<bool>), findsNothing);
      expect(relativeKindOption(tester, 'Ребёнка').enabled, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new parent creation rechecks permission before optional edits or linking',
    (tester) async {
      session.holdCreation = true;
      await mount(tester);
      await openRelative(tester);
      await tester.tap(find.text('Новый человек'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('relative-new-name')),
        'Новый родитель',
      );
      await tester.tap(find.byKey(const Key('confirm-add-relative')));
      await tester.pump();
      session.setEditingAllowed(false);
      session.completeCreation();
      await tester.pumpAndSettle();
      expect(session.operations.single.type, 'createPerson');
      expect(session.durableTree.person(rootTreePersonId)!.fatherId, isNull);
      expect(find.byKey(const Key('relative-error')), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('choose an existing mother instead of always adding a father', (
    tester,
  ) async {
    session.seed(
      session.tree.createPerson('mother', name: 'Мария', sex: TreeSex.female),
    );
    session.seed(
      session.tree.setIndividualSurname(
        'mother',
        text: 'Петров',
        decline: true,
      ),
    );
    session.seed(session.tree.setValue('mother', 'birthDate', '1950-01-01'));
    session.seed(session.tree.setValue('mother', 'deathDate', '2010-01-01'));
    await mount(tester);
    await edit(tester);
    await visibleTap(tester, find.byKey(const Key('add-relative')));
    await tester.tap(find.byKey(const Key('relative-kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Мать').last);
    await tester.pumpAndSettle();
    await chooseFromTree(tester);
    final pick = find.byKey(const Key('relative-pick-from-tree'));
    expect(tester.widget<OutlinedButton>(pick).onPressed, isNotNull);
    expect(find.widgetWithText(OutlinedButton, 'Выбрать'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(find.byIcon(Icons.account_tree_outlined), findsNothing);
    await chooseExisting(tester, 'Мария');
    expect(find.byKey(const Key('relative-selected-person')), findsOneWidget);
    expect(find.text('Мария Петрова\n1950–2010'), findsOneWidget);
    expect(session.operations, isEmpty);
    await tester.tap(find.byKey(const Key('confirm-add-relative')));
    await tester.pumpAndSettle();
    expect(session.tree.person(rootTreePersonId)!.motherId, 'mother');
    expect(session.tree.person(rootTreePersonId)!.fatherId, isNull);
    expect(session.durableTree.person(rootTreePersonId)!.motherId, 'mother');
  });

  testWidgets(
    'tree picker cancellation and selection retain the relative draft',
    (tester) async {
      for (final (id, name) in const [('first', 'Мария'), ('second', 'Анна')]) {
        session.seed(
          session.tree.createPerson(id, name: name, sex: TreeSex.female),
        );
      }
      final initialIds = <String>[];
      var result = Completer<String?>();
      await mount(
        tester,
        onPickFromTree: (initialId, canPick) {
          initialIds.add(initialId);
          expect(canPick(session.tree.person('second')!), isTrue);
          return result.future;
        },
      );
      await openRelative(tester);
      await chooseRelativeKind(tester, 'Мать');
      await tester.tap(find.text('Новый человек'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('relative-new-name')),
        'Черновик',
      );
      final pick = find.byKey(const Key('relative-pick-from-tree'));
      expect(pick, findsNothing);
      await tester.tap(find.text('Из дерева'));
      await tester.pumpAndSettle();
      await tester.tap(pick);
      await tester.pumpAndSettle();
      expect(initialIds, [rootTreePersonId]);
      result.complete('first');
      await tester.pumpAndSettle();
      expect(find.textContaining('Мария'), findsOneWidget);
      expect(session.operations, isEmpty);
      result = Completer<String?>();
      await tester.tap(pick);
      await tester.pumpAndSettle();
      expect(initialIds, [rootTreePersonId, 'first']);
      expect(tester.widget<OutlinedButton>(pick).onPressed, isNull);
      await tester.tap(find.byKey(const Key('confirm-add-relative')));
      await tester.pumpAndSettle();
      expect(session.operations, isEmpty);
      result.complete(null);
      await tester.pumpAndSettle();
      expect(find.textContaining('Мария'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(find.byKey(const Key('relative-error')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('relative-kind')),
          matching: find.text('Мать'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Новый человек'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('relative-new-name')))
            .controller!
            .text,
        'Черновик',
      );
      await tester.tap(find.text('Из дерева'));
      await tester.pumpAndSettle();
      result = Completer<String?>();
      await tester.tap(pick);
      await tester.pumpAndSettle();
      result.complete('second');
      await tester.pumpAndSettle();
      expect(find.textContaining('Анна'), findsOneWidget);
      expect(find.textContaining('Мария'), findsNothing);
      expect(session.operations, isEmpty);
      expect(session.durableTree.person(rootTreePersonId)!.motherId, isNull);
      await tester.tap(find.byKey(const Key('confirm-add-relative')));
      await tester.pumpAndSettle();
      expect(session.operations, hasLength(1));
      expect(session.durableTree.person(rootTreePersonId)!.motherId, 'second');
      expect(session.tree.people, hasLength(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('tree picker filters each role, cycles, self and missing IDs', (
    tester,
  ) async {
    for (final (id, sex) in const [
      ('man', TreeSex.male),
      ('woman', TreeSex.female),
      ('unknown', TreeSex.unknown),
      ('ancestor', TreeSex.unknown),
      ('descendant', TreeSex.unknown),
    ]) {
      session.seed(session.tree.createPerson(id, name: id, sex: sex));
    }
    session.seed(
      session.tree.setValue('descendant', 'motherId', rootTreePersonId),
    );
    bool Function(TreePerson)? filter;
    var result = Completer<String?>();
    await mount(
      tester,
      onPickFromTree: (initialId, canPick) {
        expect(initialId, rootTreePersonId);
        filter = canPick;
        return result.future;
      },
    );
    await openRelative(tester);
    await chooseFromTree(tester);
    final pick = find.byKey(const Key('relative-pick-from-tree'));
    for (final (role, allowed) in const [
      ('Отца', ['man', 'unknown', 'ancestor']),
      ('Мать', ['woman', 'unknown', 'ancestor']),
      ('Ребёнка', ['man', 'woman', 'unknown', 'descendant']),
    ]) {
      if (role != 'Отца') await chooseRelativeKind(tester, role);
      if (role == 'Ребёнка') {
        session.remote(
          session.tree.setValue(rootTreePersonId, 'fatherId', 'ancestor'),
        );
        await tester.pumpAndSettle();
      }
      result = Completer<String?>();
      await tester.tap(pick);
      await tester.pumpAndSettle();
      expect(
        session.tree.people.values.where(filter!).map((person) => person.id),
        unorderedEquals(allowed),
      );
      expect(filter!(TreePerson(id: 'missing')), isFalse);
      result.complete(role == 'Ребёнка' ? 'missing' : null);
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const Key('relative-error')), findsOneWidget);
    expect(session.operations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'tree picker rechecks a remotely changed parent sex after await',
    (tester) async {
      session.seed(
        session.tree.createPerson(
          'candidate',
          name: 'Родитель',
          sex: TreeSex.male,
        ),
      );
      final result = Completer<String?>();
      late bool Function(TreePerson) filter;
      final stalePerson = session.tree.person('candidate')!;
      await mount(
        tester,
        onPickFromTree: (_, canPick) {
          filter = canPick;
          return result.future;
        },
      );
      await openRelative(tester);
      await chooseFromTree(tester);
      await tester.tap(find.byKey(const Key('relative-pick-from-tree')));
      await tester.pumpAndSettle();
      expect(filter(stalePerson), isTrue);
      session.remote(session.tree.setValue('candidate', 'sex', 'female'));
      await tester.pumpAndSettle();
      expect(
        filter(stalePerson),
        isFalse,
        reason: 'Re-read the live person, not the captured card.',
      );
      result.complete('candidate');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('relative-error')), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(session.tree.person(rootTreePersonId)!.fatherId, isNull);
      expect(session.operations, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('tree picker rechecks cycles after await and again on Add', (
    tester,
  ) async {
    session.seed(session.tree.createPerson('candidate', name: 'Родитель'));
    var result = Completer<String?>();
    await mount(tester, onPickFromTree: (_, _) => result.future);
    await openRelative(tester);
    await chooseFromTree(tester);
    final pick = find.byKey(const Key('relative-pick-from-tree'));
    await tester.tap(pick);
    await tester.pumpAndSettle();
    session.remote(
      session.tree.setValue('candidate', 'fatherId', rootTreePersonId),
    );
    result.complete('candidate');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('relative-error')), findsOneWidget);
    expect(session.operations, isEmpty);
    session.remote(session.tree.setValue('candidate', 'fatherId', null));
    await tester.pumpAndSettle();
    result = Completer<String?>();
    await tester.tap(pick);
    await tester.pumpAndSettle();
    result.complete('candidate');
    await tester.pumpAndSettle();
    expect(find.textContaining('Родитель'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(session.operations, isEmpty);
    session.remote(
      session.tree.setValue('candidate', 'fatherId', rootTreePersonId),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-add-relative')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('relative-error')), findsOneWidget);
    expect(session.tree.person(rootTreePersonId)!.fatherId, isNull);
    expect(session.operations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tree picker rejects a result after editing permission is lost', (
    tester,
  ) async {
    session.seed(session.tree.createPerson('candidate', name: 'Родитель'));
    final result = Completer<String?>();
    late bool Function(TreePerson) filter;
    await mount(
      tester,
      onPickFromTree: (_, canPick) {
        filter = canPick;
        return result.future;
      },
    );
    await openRelative(tester);
    await chooseFromTree(tester);
    final pick = find.byKey(const Key('relative-pick-from-tree'));
    await tester.tap(pick);
    await tester.pumpAndSettle();
    session.setEditingAllowed(false);
    expect(filter(session.tree.person('candidate')!), isFalse);
    result.complete('candidate');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('relative-error')), findsOneWidget);
    expect(tester.widget<OutlinedButton>(pick).onPressed, isNull);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('confirm-add-relative')))
          .onPressed,
      isNull,
    );
    expect(session.tree.person(rootTreePersonId)!.fatherId, isNull);
    expect(session.operations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final (label, sex, field) in const [
    ('Мать', TreeSex.female, 'motherId'),
    ('Отца', TreeSex.male, 'fatherId'),
  ]) {
    testWidgets('new $field has a role-consistent locked sex', (tester) async {
      await mount(tester);
      await edit(tester);
      await visibleTap(tester, find.byKey(const Key('add-relative')));
      await tester.tap(find.text('Новый человек'));
      await tester.pumpAndSettle();
      // Father is the initial role. Switching roles must also reset the field.
      expect(dropdown<TreeSex>(tester, newRelativeSex()).value, TreeSex.male);
      expect(dropdown<TreeSex>(tester, newRelativeSex()).onChanged, isNull);
      await chooseRelativeKind(tester, 'Мать');
      if (sex == TreeSex.male) await chooseRelativeKind(tester, label);
      final picker = dropdown<TreeSex>(tester, newRelativeSex());
      expect(picker.value, sex);
      expect(picker.onChanged, isNull);
      await tester.enterText(
        find.byKey(const Key('relative-new-name')),
        'Новый родитель',
      );
      await tester.tap(find.byKey(const Key('confirm-add-relative')));
      await tester.pumpAndSettle();
      final parent = session.durableTree.people.values.singleWhere(
        (person) => person.name == 'Новый родитель',
      );
      expect(parent.sex, sex);
      final child = session.durableTree.person(rootTreePersonId)!;
      expect(child.motherId, sex == TreeSex.female ? parent.id : isNull);
      expect(child.fatherId, sex == TreeSex.male ? parent.id : isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'existing parents exclude opposite known sex and leave unknown sex unchanged',
    (tester) async {
      for (final (id, name, sex) in const [
        ('man', 'Олег', TreeSex.male),
        ('woman', 'Мария', TreeSex.female),
        ('unknown', 'Алекс', TreeSex.unknown),
      ]) {
        session.seed(session.tree.createPerson(id, name: name, sex: sex));
      }
      await mount(tester);
      await edit(tester);
      await visibleTap(tester, find.byKey(const Key('add-relative')));
      final pick = find.byKey(const Key('relative-pick-from-tree'));
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      await chooseExisting(tester, 'Олег');
      expect(lastPickableIds, unorderedEquals(['man', 'unknown']));
      await chooseRelativeKind(tester, 'Мать');
      expect(find.byKey(const Key('relative-selected-person')), findsNothing);
      await tester.tap(pick);
      await tester.pumpAndSettle();
      expect(lastPickableIds, unorderedEquals(['woman', 'unknown']));
      await chooseRelativeKind(tester, 'Ребёнка');
      await tester.tap(pick);
      await tester.pumpAndSettle();
      expect(lastPickableIds, unorderedEquals(['man', 'woman', 'unknown']));
      await chooseRelativeKind(tester, 'Мать');
      await chooseExisting(tester, 'Алекс');
      await tester.tap(find.byKey(const Key('confirm-add-relative')));
      await tester.pumpAndSettle();
      expect(session.durableTree.person(rootTreePersonId)!.motherId, 'unknown');
      expect(session.durableTree.person('unknown')!.sex, TreeSex.unknown);
      expect(session.operations, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a remotely changed parent sex is rechecked on submit', (
    tester,
  ) async {
    session.seed(
      session.tree.createPerson('parent', name: 'Родитель', sex: TreeSex.male),
    );
    await mount(tester);
    await edit(tester);
    await visibleTap(tester, find.byKey(const Key('add-relative')));
    await chooseExisting(tester, 'Родитель');
    session.remote(session.tree.setValue('parent', 'sex', 'female'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Родитель'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    await tester.tap(find.byKey(const Key('confirm-add-relative')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('relative-error')), findsOneWidget);
    expect(session.tree.person(rootTreePersonId)!.fatherId, isNull);
    expect(session.operations, isEmpty);
  });

  for (final (sex, asMother) in const [
    (TreeSex.male, false),
    (TreeSex.female, true),
    (TreeSex.unknown, false),
  ]) {
    for (final newPerson in [false, true]) {
      testWidgets(
        '${sex.name} adds a child without a parent-role field, new=$newPerson',
        (tester) async {
          session.seed(
            session.tree.setValue(rootTreePersonId, 'sex', sex.name),
          );
          if (!newPerson) {
            session.seed(session.tree.createPerson('child', name: 'Ребёнок'));
          }
          await mount(tester);
          await openRelative(tester);
          await chooseRelativeKind(tester, 'Ребёнка');
          expect(find.text('Роль выбранного человека'), findsNothing);
          expect(find.text('Отец ребёнка'), findsNothing);
          expect(find.text('Мать ребёнка'), findsNothing);
          expect(find.byType(DropdownButtonFormField<bool>), findsNothing);
          if (newPerson) {
            await tester.tap(find.text('Новый человек'));
            await tester.pumpAndSettle();
            await tester.enterText(
              find.byKey(const Key('relative-new-name')),
              'Ребёнок',
            );
          } else {
            await chooseExisting(tester, 'Ребёнок');
          }
          await tester.tap(find.byKey(const Key('confirm-add-relative')));
          await tester.pumpAndSettle();
          final child = session.durableTree.people.values.singleWhere(
            (person) => person.name == 'Ребёнок',
          );
          expect(child.fatherId, asMother ? isNull : rootTreePersonId);
          expect(child.motherId, asMother ? rootTreePersonId : isNull);
          expect(session.durableTree.person(rootTreePersonId)!.sex, sex);
          expect(find.byType(AlertDialog), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('child submission uses live sex without a parent-role field', (
    tester,
  ) async {
    session.seed(session.tree.createPerson('child', name: 'Ребёнок'));
    await mount(tester);
    await openRelative(tester);
    await chooseRelativeKind(tester, 'Ребёнка');
    for (final sex in ['male', 'female', 'unknown', 'female']) {
      session.remote(session.tree.setValue(rootTreePersonId, 'sex', sex));
      await tester.pumpAndSettle();
      expect(find.text('Роль выбранного человека'), findsNothing);
      expect(find.byType(DropdownButtonFormField<bool>), findsNothing);
    }
    await chooseExisting(tester, 'Ребёнок');
    session.remote(session.tree.setValue(rootTreePersonId, 'sex', 'male'));
    // Submit before rendering the remote update: the operation must use the
    // live person's sex rather than the female snapshot from the last build.
    await tester.tap(find.byKey(const Key('confirm-add-relative')));
    await tester.pumpAndSettle();
    expect(session.durableTree.person('child')!.fatherId, rootTreePersonId);
    expect(session.durableTree.person('child')!.motherId, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'child parent role is revalidated after awaiting new person save',
    (tester) async {
      session.seed(session.tree.setValue(rootTreePersonId, 'sex', 'female'));
      session.holdCreation = true;
      await mount(tester);
      await openRelative(tester);
      await chooseRelativeKind(tester, 'Ребёнка');
      await tester.tap(find.text('Новый человек'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('relative-new-name')),
        'Нина',
      );
      await tester.tap(find.byKey(const Key('confirm-add-relative')));
      await tester.pump();
      expect(session.operations.single.type, 'createPerson');
      final child = session.tree.people.values.singleWhere(
        (person) => person.name == 'Нина',
      );
      expect(child.fatherId, isNull);
      expect(child.motherId, isNull);
      session.remote(session.tree.setValue(rootTreePersonId, 'sex', 'male'));
      session.completeCreation();
      await tester.pumpAndSettle();
      expect(session.durableTree.person(child.id)!.fatherId, rootTreePersonId);
      expect(session.durableTree.person(child.id)!.motherId, isNull);
      expect(session.operations.map((operation) => operation.type), [
        'createPerson',
        'setValue',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  for (final (size, parentSex, childSex, delayedSave) in const [
    (Size(390, 844), TreeSex.female, TreeSex.female, false),
    (Size(390, 844), TreeSex.male, TreeSex.male, true),
    (Size(320, 568), TreeSex.female, TreeSex.male, true),
    (Size(320, 568), TreeSex.male, TreeSex.female, false),
  ]) {
    testWidgets(
      'phone child creation: ${size.width}x${size.height}, ${parentSex.name}/${childSex.name}, delayed=$delayedSave, no birth date',
      (tester) async {
        seedRelatives();
        session.seed(
          session.tree.setValue(rootTreePersonId, 'sex', parentSex.name),
        );
        session.holdCreation = delayedSave;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);

        // Do not replace FlutterError.onError or inspect only the final settled
        // screen: a transient ErrorWidget during a route/focus/layout frame is
        // a failure even if the child eventually appears.
        Future<void> frames(String phase, {int count = 24}) async {
          for (var frame = 0; frame < count; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            final error = tester.takeException();
            if (error is FlutterError) {
              fail(
                '$phase, frame $frame\n'
                '${error.diagnostics.map((part) => part.toStringDeep()).join('\n')}',
              );
            }
            expect(error, isNull, reason: '$phase, frame $frame');
            expect(
              find.byType(ErrorWidget, skipOffstage: false),
              findsNothing,
              reason: '$phase, frame $frame',
            );
          }
        }

        Future<void> tap(Finder target, String phase) async {
          for (
            var attempt = 0;
            target.evaluate().isEmpty && attempt < 10;
            attempt++
          ) {
            await tester.drag(
              find.byType(ListView).last,
              const Offset(0, -240),
            );
            await frames('$phase scroll');
          }
          expect(target, findsOneWidget, reason: phase);
          await tester.ensureVisible(target);
          await frames('$phase visibility', count: 1);
          await tester.tap(target);
          await frames(phase);
        }

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.android),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(size.width == 320 ? 1.2 : 1),
              ),
              child: child!,
            ),
            home: Scaffold(body: TreeEditor(session: session)),
          ),
        );
        await frames('initial tree');
        await tap(
          find.byKey(const Key('open-biography')),
          'open biography route',
        );
        await tap(
          find.byKey(const Key('biography-edit-toggle')),
          'enable editing',
        );
        await tap(find.byKey(const Key('add-relative')), 'open Add Relative');
        await tap(find.byKey(const Key('relative-kind')), 'open kind dropdown');
        await tap(find.text('Ребёнка').last, 'choose child');
        await tap(find.text('Новый человек'), 'new child form');
        final nameField = find.byKey(const Key('relative-new-name'));
        await tap(nameField, 'focus child name');
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await frames('software keyboard opens');
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'Нина',
            selection: TextSelection.collapsed(offset: 4),
            composing: TextRange(start: 0, end: 4),
          ),
        );
        await frames('IME child name composition');
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'Нина',
            selection: TextSelection.collapsed(offset: 4),
          ),
        );
        await frames('IME child name commit');
        await tap(newRelativeSex(), 'open child sex dropdown with keyboard');
        await tap(
          find.text(childSex == TreeSex.female ? 'Женский' : 'Мужской').last,
          'choose child sex',
        );
        expect(dropdown<TreeSex>(tester, newRelativeSex()).value, childSex);
        expect(find.text('Дата рождения (необязательно)'), findsOneWidget);
        tester.view.resetViewInsets();
        await frames('software keyboard closes');
        await tap(
          find.byKey(const Key('confirm-add-relative')),
          'submit without birth date',
        );
        if (delayedSave) {
          expect(session.operations.single.type, 'createPerson');
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(find.text('Сохраняем…'), findsOneWidget);
          final optimistic = session.tree.person(
            session.operations.single.personId,
          )!;
          expect(optimistic.birthDate, isNull);
          expect(optimistic.sex, childSex);
          expect(optimistic.fatherId, isNull);
          expect(optimistic.motherId, isNull);
          session.completeCreation();
          await frames('finish child creation and link');
        }
        expect(find.byType(AlertDialog), findsNothing);
        final child = session.durableTree.people.values.singleWhere(
          (person) => person.name == 'Нина',
        );
        expect(child.sex, childSex);
        expect(child.birthDate, isNull);
        expect(
          child.fatherId,
          parentSex == TreeSex.male ? rootTreePersonId : isNull,
        );
        expect(
          child.motherId,
          parentSex == TreeSex.female ? rootTreePersonId : isNull,
        );
        expect(session.operations.map((operation) => operation.type), [
          'createPerson',
          'setValue',
        ]);
        expect(
          session.operations.last.fieldKey,
          parentSex == TreeSex.male ? 'fatherId' : 'motherId',
        );
        await tap(
          find.byKey(const Key('biography-close')),
          'return to live tree',
        );
        await frames('new child in tree', count: 60);
        expect(find.byKey(ValueKey('tree-person-${child.id}')), findsOneWidget);
        expect(session.storageError, isNull);
      },
    );
  }

  testWidgets('new child is linked in the selected parent direction', (
    tester,
  ) async {
    session.seed(session.tree.setValue(rootTreePersonId, 'sex', 'female'));
    await mount(tester);
    await edit(tester);
    await visibleTap(tester, find.byKey(const Key('add-relative')));
    await tester.tap(find.byKey(const Key('relative-kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ребёнка').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Новый человек'));
    await tester.pumpAndSettle();
    final picker = dropdown<TreeSex>(tester, newRelativeSex());
    expect(picker.value, TreeSex.unknown);
    expect(picker.onChanged, isNotNull);
    expect(picker.items!.map((item) => item.value), TreeSex.values);
    await tester.tap(newRelativeSex());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Женский').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('relative-new-name')), 'Нина');
    await tester.tap(find.byKey(const Key('confirm-add-relative')));
    await tester.pumpAndSettle();
    final child = session.tree.people.values.singleWhere(
      (person) => person.name == 'Нина',
    );
    expect(child.motherId, rootTreePersonId);
    expect(child.fatherId, isNull);
    expect(child.sex, TreeSex.female);
    expect(session.durableTree.person(child.id)!.sex, TreeSex.female);
    expect(session.tree.person(rootTreePersonId)!.motherId, isNull);
  });

  testWidgets('death date modal distinguishes living, unknown and a date', (
    tester,
  ) async {
    Future<void> open() async {
      await tester.tap(find.byKey(const Key('person-death-date')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('person-death-dialog')), findsOneWidget);
    }

    Future<void> choose(String mode) async {
      await open();
      await tester.tap(find.byKey(Key('person-death-choice-$mode')));
      await tester.pumpAndSettle();
    }

    session.seed(
      session.tree.setValue(rootTreePersonId, 'birthDate', '1980-05-06'),
    );
    await mount(tester);
    expect(find.text('06.05.1980 — н.в'), findsOneWidget);
    expect(session.tree.person(rootTreePersonId)!.lifeYears, '1980–н.в');
    await edit(tester);
    expect(find.byKey(const Key('person-death-choice-ongoing')), findsNothing);
    expect(find.byTooltip('Убрать дату смерти'), findsNothing);
    await open();
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const Key('person-death-choice-ongoing')),
          )
          .selected,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('person-death-choice-unknown')));
    await tester.pumpAndSettle();
    expect(session.tree.person(rootTreePersonId)!.alive, isFalse);
    expect(session.tree.person(rootTreePersonId)!.lifeYears, '1980–?');
    expect(session.operations.single.fieldKey, 'alive');
    await choose('ongoing');
    expect(session.tree.person(rootTreePersonId)!.alive, isTrue);
    expect(session.tree.person(rootTreePersonId)!.lifeYears, '1980–н.в');
    await choose('date');
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    final dated = session.tree.person(rootTreePersonId)!;
    expect(dated.deathDate, DateTime.utc(1970));
    expect(dated.alive, isNull);
    expect(dated.lifeYears, '1980–1970');
    await open();
    expect(find.widgetWithText(ChoiceChip, '01.01.1970'), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('person-death-choice-date')))
          .selected,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('person-death-choice-unknown')));
    await tester.pumpAndSettle();
    final cleared = session.tree.person(rootTreePersonId)!;
    expect(cleared.deathDate, isNull);
    expect(cleared.alive, isFalse);
    expect(cleared.lifeYears, '1980–?');
    await tester.tap(find.byKey(const Key('biography-edit-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('06.05.1980 — не известно'), findsOneWidget);
    expect(session.operations.map((operation) => operation.fieldKey), [
      'alive',
      'alive',
      'deathDate',
      'alive',
      'deathDate',
      'alive',
    ]);
  });

  testWidgets('cancelling death mode and its calendar writes nothing', (
    tester,
  ) async {
    await mount(tester);
    await edit(tester);
    await tester.tap(find.byKey(const Key('person-death-date')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('person-death-choice-date')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('person-death-dialog')), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const Key('person-death-choice-unknown')),
          )
          .selected,
      isTrue,
    );
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(session.operations, isEmpty);
    expect(session.tree.person(rootTreePersonId)!.deathDate, isNull);
  });

  testWidgets('descendants cannot be selected as parents', (tester) async {
    session.seed(session.tree.createPerson('child', name: 'Потомок'));
    session.seed(session.tree.setValue('child', 'fatherId', rootTreePersonId));
    var opened = 0;
    await mount(
      tester,
      onPickFromTree: (_, canPick) async {
        opened++;
        expect(canPick(session.tree.person('child')!), isFalse);
        expect(canPick(session.tree.person(rootTreePersonId)!), isFalse);
        return 'child';
      },
    );
    await edit(tester);
    await visibleTap(tester, find.byKey(const Key('add-relative')));
    await chooseFromTree(tester);
    final pick = find.byKey(const Key('relative-pick-from-tree'));
    expect(tester.widget<OutlinedButton>(pick).onPressed, isNotNull);
    expect(find.textContaining('Нет подходящих людей'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    await tester.tap(pick);
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.byKey(const Key('relative-selected-person')), findsNothing);
    await tester.tap(find.byKey(const Key('confirm-add-relative')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('relative-error')), findsOneWidget);
    expect(session.operations, isEmpty);
  });

  testWidgets(
    'editor binding asks one brief question and waits for durable save',
    (tester) async {
      session.holdBinding = true;
      session.seed(
        session.tree.editText(rootTreePersonId, TreeTextField.name, 'Алексей')!,
      );
      session.seed(
        session.tree.setIndividualSurname(rootTreePersonId, text: 'Семейный'),
      );
      await mount(tester);
      await tester.tap(find.byKey(const Key('this-is-me')));
      await tester.pumpAndSettle();
      final confirmation = tester.widget<AlertDialog>(find.byType(AlertDialog));
      expect(confirmation.title, isA<Text>());
      expect(
        (confirmation.content! as Text).data,
        'Связать ваш профиль с «Алексей Семейный»?',
      );
      expect(confirmation.actions, hasLength(2));
      expect(find.textContaining('необратимо'), findsNothing);
      expect(find.textContaining('Отменить связь можно'), findsNothing);
      expect(find.textContaining('Привязка не даёт права'), findsNothing);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(session.tree.bindings, isEmpty);
      await tester.tap(find.byKey(const Key('this-is-me')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-person-binding')));
      await tester.pump();
      expect(session.tree.bindings['self'], rootTreePersonId);
      expect(session.boundPersonId, isNull);
      expect(find.byKey(const Key('this-is-me')), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('this-is-me')))
            .onPressed,
        isNull,
      );
      session.completeBinding();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('this-is-me')), findsNothing);
      expect(find.text('Ваш профиль'), findsOneWidget);
      expect(session.boundPersonId, rootTreePersonId);
      expect(session.operations.single.type, 'bindActor');
    },
  );

  testWidgets(
    'binding confirmation cannot bind after losing editor permission',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const Key('this-is-me')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('confirm-person-binding')), findsOneWidget);
      session.setEditingAllowed(false);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-person-binding')));
      await tester.pumpAndSettle();
      expect(session.ownRole, RoomRole.guest);
      expect(session.tree.bindings, isEmpty);
      expect(session.durableTree.bindings, isEmpty);
      expect(session.operations, isEmpty);
      expect(find.byKey(const Key('this-is-me')), findsNothing);
      expect(find.text('Ваш профиль'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('album selection, caption and order persist without closing', (
    tester,
  ) async {
    session.seed(
      session.tree.addPhoto(
        rootTreePersonId,
        'first',
        dataUrl: _pixel,
        caption: 'Семья',
      ),
    );
    session.seed(
      session.tree.addPhoto(
        rootTreePersonId,
        'second',
        dataUrl: _pixel,
        caption: 'Друзья',
      ),
    );
    session.seed(
      session.tree.setValue(rootTreePersonId, 'avatarPhotoId', 'first'),
    );
    await mount(tester);
    await edit(tester);
    await tester.tap(find.byKey(const Key('person-avatar')));
    await tester.pumpAndSettle();
    expect(find.text('Аватар'), findsOneWidget);
    await visibleTap(
      tester,
      find.byKey(const ValueKey('choose-avatar-second')),
    );
    expect(
      session.durableTree.person(rootTreePersonId)!.avatarPhotoId,
      'second',
    );
    final selectedBorder =
        tester
                .widget<Container>(
                  find.byKey(const ValueKey('album-photo-second')),
                )
                .decoration!
            as BoxDecoration;
    expect((selectedBorder.border! as Border).top.width, 3);
    await tester.enterText(
      find.byKey(const ValueKey('photo-caption-field-second')),
      'Наши друзья',
    );
    await tester.pumpAndSettle();
    expect(
      session.durableTree.person(rootTreePersonId)!.photos.last.caption,
      'Наши друзья',
    );
    final second = find.byKey(const ValueKey('album-photo-second'));
    await visibleTap(
      tester,
      find.descendant(of: second, matching: find.byTooltip('Фото выше')),
    );
    expect(
      session.durableTree.person(rootTreePersonId)!.photos.first.id,
      'second',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'field controllers preserve selection through remote text and later local typing',
    (tester) async {
      session.seed(
        session.tree.editText(rootTreePersonId, TreeTextField.name, 'Анна')!,
      );
      await mount(tester);
      await edit(tester);
      final field = find.byKey(const Key('person-name-field'));
      await tester.enterText(field, 'Анна!');
      await tester.pumpAndSettle();
      final controller = tester.widget<TextField>(field).controller!;
      controller.selection = const TextSelection(
        baseOffset: 1,
        extentOffset: 3,
      );
      session.remote(
        session.tree.editText(rootTreePersonId, TreeTextField.name, 'С Анна!')!,
      );
      await tester.pumpAndSettle();
      expect(
        identical(tester.widget<TextField>(field).controller, controller),
        isTrue,
      );
      expect(controller.text, 'С Анна!');
      expect(
        controller.selection,
        const TextSelection(baseOffset: 3, extentOffset: 5),
      );
      await tester.enterText(field, 'С Анна!+');
      await tester.pumpAndSettle();
      await tester.enterText(field, 'С Анна!++');
      await tester.pumpAndSettle();
      expect(session.durableTree.person(rootTreePersonId)!.name, 'С Анна!++');
      expect(session.textBases.map((base) => base!.text), [
        'Анна',
        'С Анна!',
        'С Анна!+',
      ]);
    },
  );

  testWidgets(
    'remote text maps an active IME composing range and its next commit',
    (tester) async {
      session.seed(
        session.tree.editText(rootTreePersonId, TreeTextField.name, 'Анна')!,
      );
      await mount(tester);
      await edit(tester);
      final field = find.byKey(const Key('person-name-field'));
      await tester.tap(field);
      await tester.pumpAndSettle();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'Анна',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 1, end: 3),
        ),
      );
      await tester.pump();
      final controller = tester.widget<TextField>(field).controller!;
      expect(controller.value.composing, const TextRange(start: 1, end: 3));
      session.remote(
        session.tree.editText(rootTreePersonId, TreeTextField.name, 'С Анна')!,
      );
      await tester.pumpAndSettle();
      expect(controller.text, 'С Анна');
      expect(controller.selection, const TextSelection.collapsed(offset: 5));
      expect(controller.value.composing, const TextRange(start: 3, end: 5));
      // Simulate the IME committing its transformed composition after a frame.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'С Аня',
          selection: TextSelection.collapsed(offset: 5),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.text, 'С Аня');
      expect(controller.value.composing, TextRange.empty);
      expect(session.durableTree.person(rootTreePersonId)!.name, 'С Аня');
      expect(session.textBases.last!.text, 'С Анна');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'photo upload resizes a portrait through the portable codec and canvas path',
    (tester) async {
      final file = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(
          recorder,
        ).drawColor(const Color(0xFF53765B), ui.BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(64, 1400);
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          return XFile.fromData(
            bytes!.buffer.asUint8List(),
            name: 'portrait.png',
            mimeType: 'image/png',
          );
        } finally {
          image.dispose();
          picture.dispose();
        }
      });
      final previous = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = _PhotoPicker([file!]);
      addTearDown(() => FileSelectorPlatform.instance = previous);
      await mount(tester);
      await edit(tester);
      await tester.tap(find.byKey(const Key('person-avatar')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('album-upload')));
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (session.tree.person(rootTreePersonId)!.photos.isEmpty &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('biography-save-error')), findsNothing);
      final photo = session.durableTree.person(rootTreePersonId)!.photos.single;
      expect(photo.dataUrl, startsWith('data:image/png;base64,'));
      final bytes = base64Decode(photo.dataUrl.split(',').last);
      expect(bytes.length, lessThanOrEqualTo(700 * 1024));
      await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(bytes);
        final image = (await codec.getNextFrame()).image;
        try {
          expect(image.width, 47);
          expect(image.height, 1024);
        } finally {
          image.dispose();
          codec.dispose();
        }
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('remote deletion clears a collapsed mapped composition', (
    tester,
  ) async {
    session.seed(
      session.tree.editText(rootTreePersonId, TreeTextField.name, 'Анна')!,
    );
    await mount(tester);
    await edit(tester);
    final field = find.byKey(const Key('person-name-field'));
    final controller = tester.widget<TextField>(field).controller!;
    controller.value = const TextEditingValue(
      text: 'Анна',
      selection: TextSelection.collapsed(offset: 3),
      composing: TextRange(start: 1, end: 3),
    );
    session.remote(
      session.tree.editText(rootTreePersonId, TreeTextField.name, 'Аа')!,
    );
    await tester.pumpAndSettle();
    expect(controller.text, 'Аа');
    expect(controller.value.composing, TextRange.empty);
    expect(tester.takeException(), isNull);
  });

  for (final editing in [false, true]) {
    testWidgets('facts precede biography text (editing=$editing)', (
      tester,
    ) async {
      session.seed(
        session.tree.addFact(rootTreePersonId, 'first', text: 'Первый факт'),
      );
      await mount(tester, size: const Size(480, 2200));
      if (editing) await edit(tester);
      final fact = find.byKey(const ValueKey('fact-first'));
      final biography = find.byKey(const ValueKey('biography-text-root'));
      expect(fact, findsOneWidget);
      expect(biography, findsOneWidget);
      expect(
        tester.getBottomLeft(fact).dy,
        lessThan(tester.getTopLeft(find.text('О человеке')).dy),
      );
      expect(
        tester.getBottomLeft(find.text('Факты и воспоминания')).dy,
        lessThan(tester.getTopLeft(fact).dy),
      );
      expect(
        tester.getTopLeft(fact).dy,
        lessThan(tester.getTopLeft(biography).dy),
      );
      expect(session.operations, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets('fact palette is richer and readable in ${brightness.name}', (
      tester,
    ) async {
      for (var i = 0; i < treeFactColors.length; i++) {
        session.seed(
          session.tree.addFact(
            rootTreePersonId,
            'color-$i',
            text: 'Цветной факт $i',
            color: treeFactColors[i],
          ),
        );
      }
      var colors = ColorScheme.fromSeed(
        seedColor: const Color(0xFF28644B),
        brightness: brightness,
      );
      if (brightness == Brightness.light) {
        colors = colors.copyWith(
          surface: const Color(0xFFF3F7ED),
          onSurface: const Color(0xFF315E47),
        );
      }
      await mount(
        tester,
        size: const Size(480, 2400),
        theme: ThemeData(colorScheme: colors),
      );
      final fills = <Color>{};
      for (var i = 0; i < treeFactColors.length; i++) {
        final fact = find.byKey(ValueKey('fact-color-$i'));
        final decoration =
            tester.widget<Container>(fact).decoration! as BoxDecoration;
        final fill = decoration.color!;
        final accent = (decoration.border! as Border).left.color;
        final saved = Color(
          int.parse(treeFactColors[i].replaceFirst('#', 'FF'), radix: 16),
        );
        fills.add(fill);
        expect(fill.a, 1);
        expect(accent.a, 1);
        expect(
          HSLColor.fromColor(fill).saturation,
          greaterThan(HSLColor.fromColor(saved).saturation),
        );
        final vivid = HSLColor.fromColor(saved).withSaturation(
          (HSLColor.fromColor(saved).saturation * 1.5).clamp(0, 1),
        );
        expect(
          fill,
          vivid
              .withLightness(brightness == Brightness.dark ? .22 : .84)
              .toColor(),
        );
        expect(
          accent,
          vivid
              .withLightness(brightness == Brightness.dark ? .70 : .38)
              .toColor(),
        );
        final text = tester.widget<SelectableText>(
          find.descendant(of: fact, matching: find.byType(SelectableText)),
        );
        expect(text.style!.color, colors.onSurface);
        final textLuminance = text.style!.color!.computeLuminance();
        final fillLuminance = fill.computeLuminance();
        final contrast = textLuminance > fillLuminance
            ? (textLuminance + .05) / (fillLuminance + .05)
            : (fillLuminance + .05) / (textLuminance + .05);
        expect(contrast, greaterThanOrEqualTo(4.5));
      }
      expect(fills, hasLength(treeFactColors.length));
      expect(session.operations, isEmpty);
      await edit(tester);
      await visibleTap(
        tester,
        find.byKey(const ValueKey('fact-color-color-0')),
      );
      final markers = tester.widgetList<Icon>(find.byIcon(Icons.circle));
      expect(markers, hasLength(treeFactColors.length));
      for (final marker in markers) {
        expect(marker.color!.a, 1);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('biography and facts are immediate collaborative edits', (
    tester,
  ) async {
    session.seed(
      session.tree.addFact(
        rootTreePersonId,
        'fact-one',
        text: 'Работал в саду',
      ),
    );
    await mount(tester);
    await edit(tester);
    final biography = find.byKey(const Key('person-biography-field'));
    await reveal(tester, biography);
    await tester.enterText(biography, 'Любит семью');
    await tester.pumpAndSettle();
    final fact = find.byKey(const ValueKey('fact-field-fact-one'));
    await tester.ensureVisible(fact);
    await tester.enterText(fact, 'Вырастил большой сад');
    await tester.pumpAndSettle();
    expect(
      session.durableTree.person(rootTreePersonId)!.biography,
      'Любит семью',
    );
    expect(
      session.durableTree.person(rootTreePersonId)!.facts.single.text,
      'Вырастил большой сад',
    );
  });

  testWidgets(
    'removing mounted facts and photo captions has no stale snapshot listener',
    (tester) async {
      session.seed(
        session.tree.addFact(rootTreePersonId, 'fact-one', text: 'Память'),
      );
      session.seed(
        session.tree.addPhoto(
          rootTreePersonId,
          'photo-one',
          dataUrl: _pixel,
          caption: 'Семья',
        ),
      );
      await mount(tester);
      await edit(tester);
      final fact = find.byKey(const ValueKey('fact-fact-one'));
      await visibleTap(
        tester,
        find.descendant(of: fact, matching: find.byTooltip('Удалить факт')),
      );
      expect(session.tree.person(rootTreePersonId)!.facts, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(ListView).first, const Offset(0, 1500));
      await tester.pumpAndSettle();
      await visibleTap(tester, find.byKey(const Key('person-avatar')));
      await visibleTap(tester, find.byTooltip('Удалить фотографию'));
      expect(session.tree.person(rootTreePersonId)!.photos, isEmpty);
      expect(find.text('В альбоме пока нет фотографий'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'switching the selected person keeps field snapshots independent',
    (tester) async {
      session.seed(session.tree.createPerson('other', name: 'Другой человек'));
      session.seed(
        session.tree.editText(rootTreePersonId, TreeTextField.name, 'Первый')!,
      );
      await mount(tester);
      await edit(tester);
      await tester.enterText(
        find.byKey(const Key('person-name-field')),
        'Первый!',
      );
      await tester.pumpAndSettle();
      await mount(tester, id: 'other');
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Другой человек'), findsOneWidget);
      await edit(tester);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('person-name-field')))
            .controller!
            .text,
        'Другой человек',
      );
      await tester.enterText(
        find.byKey(const Key('person-name-field')),
        'Второй',
      );
      await tester.pumpAndSettle();
      expect(session.durableTree.person(rootTreePersonId)!.name, 'Первый!');
      expect(session.durableTree.person('other')!.name, 'Второй');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('facts reorder and change color through narrow operations', (
    tester,
  ) async {
    session.seed(
      session.tree.addFact(rootTreePersonId, 'first', text: 'Первый'),
    );
    session.seed(
      session.tree.addFact(rootTreePersonId, 'second', text: 'Второй'),
    );
    await mount(tester);
    await edit(tester);
    await reveal(tester, find.byKey(const ValueKey('fact-color-first')));
    await tester.pumpAndSettle();
    tester
        .widget<ReorderableListView>(find.byType(ReorderableListView))
        .onReorderItem!(0, 1);
    await tester.pumpAndSettle();
    expect(
      session.durableTree
          .person(rootTreePersonId)!
          .facts
          .map((fact) => fact.id),
      ['second', 'first'],
    );
    await visibleTap(tester, find.byKey(const ValueKey('fact-color-first')));
    await tester.tap(find.text('Цвет 2'));
    await tester.pumpAndSettle();
    expect(
      session.durableTree.person(rootTreePersonId)!.facts.last.color,
      treeFactColors[1],
    );
    expect(session.operations.map((op) => op.type), [
      'moveFact',
      'setFactColor',
    ]);
  });

  testWidgets(
    'surname inherits without copying and edits only the current person',
    (tester) async {
      seedRelatives();
      session.seed(
        session.tree.editText(rootTreePersonId, TreeTextField.name, 'Анна')!,
      );
      session.seed(session.tree.setValue(rootTreePersonId, 'sex', 'female'));
      session.seed(
        session.tree.setIndividualSurname(
          'father',
          text: 'Иванов',
          decline: true,
        ),
      );
      await mount(tester);
      expect(find.text('Анна Иванова'), findsOneWidget);
      await edit(tester);
      expectSurnameControls(tester);
      final field = find.byKey(const Key('person-surname-field'));
      final decline = find.byKey(const Key('surname-decline'));
      final controller = tester.widget<TextField>(field).controller!;
      var input = tester.widget<TextField>(field);
      expect(controller.text, isEmpty);
      expect(input.decoration!.hintText, 'Иванов');
      expect(input.decoration!.helperText, 'Наследуется от отца: Олег Иванов');
      expect(tester.widget<CheckboxListTile>(decline).value, isTrue);
      expect(session.operations, isEmpty);
      session.remote(
        session.tree.setIndividualSurname(
          'father',
          text: 'Петров',
          decline: false,
        ),
      );
      await tester.pumpAndSettle();
      input = tester.widget<TextField>(field);
      expect(input.controller, same(controller));
      expect(controller.text, isEmpty);
      expect(input.decoration!.hintText, 'Петров');
      expect(tester.widget<CheckboxListTile>(decline).value, isFalse);
      expect(session.operations, isEmpty);
      await visibleTap(tester, decline);
      expect(
        session.operations,
        isEmpty,
        reason: 'No inherited value is copied.',
      );
      await tester.enterText(field, 'Сидоров');
      await tester.pumpAndSettle();
      expect(controller.text, 'Сидоров');
      expect(
        session.durableTree.person(rootTreePersonId)!.individualSurname,
        const TreeSurname(text: 'Сидоров', decline: true),
      );
      expect(session.tree.person(rootTreePersonId)!.surname, 'Сидорова');
      for (final id in ['sibling', 'other-sibling', 'half']) {
        expect(session.durableTree.person(id)!.individualSurname, isNull);
        expect(session.durableTree.person(id)!.surname, 'Петров');
      }
      expect(session.tree.person('father')!.surname, 'Петров');
      session.remote(
        session.tree.setIndividualSurname(
          'sibling',
          text: 'Орлов',
          decline: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.text, 'Сидоров');
      expect(tester.widget<CheckboxListTile>(decline).value, isTrue);
      await tester.enterText(field, '');
      await tester.pumpAndSettle();
      input = tester.widget<TextField>(field);
      expect(input.controller, same(controller));
      expect(controller.text, isEmpty);
      expect(input.decoration!.hintText, 'Петров');
      expect(input.decoration!.helperText, 'Наследуется от отца: Олег Петров');
      expect(tester.widget<CheckboxListTile>(decline).value, isFalse);
      expect(
        session.durableTree.person(rootTreePersonId)!.individualSurname,
        isNull,
      );
      expect(
        session.durableTree.person(rootTreePersonId)!.surnameInheritedFrom,
        'father',
      );
      expect(session.tree.person(rootTreePersonId)!.surname, 'Петров');
      expect(session.tree.person(rootTreePersonId)!.name, 'Анна');
      expect(session.tree.person('sibling')!.surname, 'Орлов');
      expect(session.operations.map((operation) => operation.type), [
        'setSurname',
        'setSurname',
      ]);
      expect(
        session.operations.map((operation) => operation.personId),
        everyElement(rootTreePersonId),
      );
      expect(
        session.operations.map((operation) => operation.toJson()['scope']),
        ['individual', 'individual'],
      );
      expect(session.textBases, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'legacy surname opens without migration and editing creates only a personal value',
    (tester) async {
      seedRelatives();
      session.seed(
        session.tree.editText(rootTreePersonId, TreeTextField.name, 'Анна')!,
      );
      session.seed(session.tree.setValue(rootTreePersonId, 'sex', 'female'));
      session.seed(
        legacyFamilySurname(rootTreePersonId, 'Иванов', decline: true),
      );
      session.seed(
        session.tree.setMaidenSurname(
          rootTreePersonId,
          text: 'Орлов',
          decline: true,
        ),
      );
      await mount(tester);
      expect(find.text('Анна Иванова'), findsOneWidget);
      await edit(tester);
      expectSurnameControls(tester);
      final field = find.byKey(const Key('person-surname-field'));
      final decline = find.byKey(const Key('surname-decline'));
      final element = tester.element(field);
      final controller = tester.widget<TextField>(field).controller!;
      expect(
        controller.text,
        'Иванов',
        reason: 'Edit the canonical base, not Иванова.',
      );
      expect(tester.widget<CheckboxListTile>(decline).value, isTrue);
      expect(
        session.operations,
        isEmpty,
        reason: 'Opening must never migrate history.',
      );
      await tester.enterText(field, 'Петров');
      await tester.pumpAndSettle();
      expect(tester.element(field), same(element));
      expect(tester.widget<TextField>(field).controller, same(controller));
      expect(
        session.durableTree.person(rootTreePersonId)!.fullName,
        'Анна Петрова',
      );
      await visibleTap(tester, decline);
      expect(
        session.durableTree.person(rootTreePersonId)!.individualSurname,
        const TreeSurname(text: 'Петров'),
      );
      expect(
        session.durableTree.person(rootTreePersonId)!.familySurname,
        isNull,
      );
      expect(
        session.durableTree.person(rootTreePersonId)!.fullName,
        'Анна Петров',
      );
      for (final id in ['sibling', 'other-sibling']) {
        expect(
          session.durableTree.person(id)!.familySurname,
          const TreeSurname(text: 'Иванов', decline: true),
        );
        expect(session.durableTree.person(id)!.individualSurname, isNull);
      }
      expect(
        session.durableTree.person(rootTreePersonId)!.maidenSurname,
        const TreeSurname(text: 'Орлов', decline: true),
      );
      await edit(tester);
      await reveal(tester, find.text('Анна Петров'));
      expect(find.text('Анна Петров'), findsOneWidget);
      expect(find.textContaining('до замужества'), findsNothing);
      expect(find.textContaining('Орлов'), findsNothing);
      expect(
        session.operations.map((operation) => operation.type),
        everyElement('setSurname'),
      );
      expect(
        session.operations.map((operation) => operation.personId),
        everyElement(rootTreePersonId),
      );
      expect(
        session.operations.map((operation) => operation.toJson()['scope']),
        everyElement('individual'),
      );
      expect(session.operations, hasLength(2));
      expect(session.textBases, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final savedDecline in [null, false, true]) {
    testWidgets(
      'personal surname decline defaults true and honors saved $savedDecline',
      (tester) async {
        session.seed(session.tree.setValue(rootTreePersonId, 'sex', 'female'));
        if (savedDecline != null) {
          session.seed(
            session.tree.setIndividualSurname(
              rootTreePersonId,
              text: 'Иванов',
              decline: savedDecline,
            ),
          );
        }
        await mount(tester);
        await edit(tester);
        expectSurnameControls(tester);
        final field = find.byKey(const Key('person-surname-field'));
        final decline = find.byKey(const Key('surname-decline'));
        expect(
          tester.widget<CheckboxListTile>(decline).value,
          savedDecline ?? true,
        );
        expect(session.operations, isEmpty);
        await tester.enterText(field, 'Петров');
        await tester.pumpAndSettle();
        expect(
          session.durableTree.person(rootTreePersonId)!.individualSurname,
          TreeSurname(text: 'Петров', decline: savedDecline ?? true),
        );
        await edit(tester);
        await edit(tester);
        expect(
          tester.widget<CheckboxListTile>(decline).value,
          savedDecline ?? true,
        );
        expect(session.operations.single.toJson()['scope'], 'individual');
        expect(session.operations.single.personId, rootTreePersonId);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'inheritance hint uses the father canonical base even for a female father',
    (tester) async {
      seedRelatives();
      session.seed(session.tree.setValue('father', 'sex', 'female'));
      session.seed(
        session.tree.setIndividualSurname(
          'father',
          text: 'Иванов',
          decline: true,
        ),
      );
      await mount(tester);
      await edit(tester);
      final field = find.byKey(const Key('person-surname-field'));
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(tester.widget<TextField>(field).decoration!.hintText, 'Иванов');
      expect(
        tester.widget<TextField>(field).decoration!.helperText,
        'Наследуется от отца: Олег Иванова',
      );
      expect(session.operations, isEmpty);
    },
  );

  for (final fromLegacy in [false, true]) {
    for (final clearButton in [false, true]) {
      testWidgets(
        'clear surname (legacy=$fromLegacy, button=$clearButton) is authoritative through refresh and reopen',
        (tester) async {
          seedRelatives();
          session.seed(
            legacyFamilySurname(rootTreePersonId, 'Иванов', decline: true),
          );
          session.seed(
            session.tree.setIndividualSurname('father', text: 'Петров'),
          );
          if (!fromLegacy) {
            session.seed(
              session.tree.setIndividualSurname(
                rootTreePersonId,
                text: 'Сидоров',
                decline: true,
              ),
            );
          }
          await mount(tester);
          await edit(tester);
          final field = find.byKey(const Key('person-surname-field'));
          final decline = find.byKey(const Key('surname-decline'));
          final controller = tester.widget<TextField>(field).controller!;
          expect(controller.text, fromLegacy ? 'Иванов' : 'Сидоров');
          expect(session.operations, isEmpty);
          if (clearButton) {
            await visibleTap(tester, find.byTooltip('Убрать фамилию'));
          } else {
            await tester.enterText(field, '');
            await tester.pumpAndSettle();
          }
          expect(controller.text, isEmpty);
          expect(
            session.durableTree.person(rootTreePersonId)!.individualSurname,
            isNull,
          );
          expect(
            session.durableTree.person(rootTreePersonId)!.familySurname,
            isNull,
          );
          expect(
            session.durableTree.person(rootTreePersonId)!.surname,
            'Петров',
          );
          expect(tester.widget<CheckboxListTile>(decline).value, isFalse);
          expect(
            tester.widget<TextField>(field).decoration!.hintText,
            'Петров',
          );
          session.remote(
            legacyFamilySurname('sibling', 'Орлов', decline: true),
          );
          session.remote(
            session.tree.setValue(rootTreePersonId, 'sex', 'female'),
          );
          await tester.pumpAndSettle();
          expect(tester.widget<TextField>(field).controller, same(controller));
          expect(controller.text, isEmpty);
          expect(
            session.durableTree.person(rootTreePersonId)!.surname,
            'Петров',
          );
          await edit(tester);
          await edit(tester);
          expect(tester.widget<TextField>(field).controller!.text, isEmpty);
          expect(
            tester.widget<TextField>(field).decoration!.hintText,
            'Петров',
          );
          expect(tester.widget<CheckboxListTile>(decline).value, isFalse);
          expect(
            session.operations,
            hasLength(1),
            reason: 'Reopening never migrates or resurrects a legacy value.',
          );
          await tester.enterText(field, 'Сидоров');
          await tester.pumpAndSettle();
          expect(
            session.durableTree.person(rootTreePersonId)!.individualSurname,
            const TreeSurname(text: 'Сидоров'),
          );
          for (final id in ['sibling', 'other-sibling']) {
            expect(
              session.durableTree.person(id)!.familySurname,
              const TreeSurname(text: 'Орлов', decline: true),
            );
            expect(session.durableTree.person(id)!.individualSurname, isNull);
          }
          expect(
            session.operations.map((operation) => operation.toJson()['scope']),
            ['individual', 'individual'],
          );
          expect(
            session.operations.map((operation) => operation.personId),
            everyElement(rootTreePersonId),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final legacy in [false, true]) {
    testWidgets(
      'remote surname refresh preserves controller, caret and composition (legacy=$legacy)',
      (tester) async {
        seedRelatives();
        final before = legacy ? 'Иванов' : 'Петров';
        session.seed(
          legacy
              ? legacyFamilySurname(rootTreePersonId, before)
              : session.tree.setIndividualSurname(
                  rootTreePersonId,
                  text: before,
                ),
        );
        await mount(tester);
        await edit(tester);
        final field = find.byKey(const Key('person-surname-field'));
        final decline = find.byKey(const Key('surname-decline'));
        final controller = tester.widget<TextField>(field).controller!;
        expect(controller.text, before);
        expect(tester.widget<CheckboxListTile>(decline).value, isFalse);
        controller.value = TextEditingValue(
          text: before,
          selection: const TextSelection(baseOffset: 1, extentOffset: 3),
          composing: const TextRange(start: 1, end: 3),
        );
        session.remote(
          legacy
              ? legacyFamilySurname('sibling', 'С $before', decline: true)
              : session.tree.setIndividualSurname(
                  rootTreePersonId,
                  text: 'С $before',
                  decline: true,
                ),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field).controller, same(controller));
        expect(controller.text, 'С $before');
        expect(tester.widget<CheckboxListTile>(decline).value, isTrue);
        expect(
          controller.selection,
          const TextSelection(baseOffset: 3, extentOffset: 5),
        );
        expect(controller.value.composing, const TextRange(start: 3, end: 5));
        session.remote(
          session.tree.setValue(rootTreePersonId, 'sex', 'female'),
        );
        session.remote(
          session.tree.setMaidenSurname(rootTreePersonId, text: 'Историческая'),
        );
        session.remote(
          session.tree.setIndividualSurname('sibling', text: 'Орлов'),
        );
        await tester.pumpAndSettle();
        expect(controller.text, 'С $before');
        expect(
          controller.selection,
          const TextSelection(baseOffset: 3, extentOffset: 5),
        );
        expect(controller.value.composing, const TextRange(start: 3, end: 5));
        expect(
          session.operations,
          isEmpty,
          reason: 'Remote refresh must never write.',
        );
        expect(find.textContaining('Историческая'), findsNothing);
        await tester.enterText(field, 'С $before!');
        await tester.pumpAndSettle();
        expect(session.operations, hasLength(1));
        expect(session.operations.single.toJson()['scope'], 'individual');
        expect(session.operations.single.personId, rootTreePersonId);
        expect(
          session.durableTree.person(rootTreePersonId)!.individualSurname,
          TreeSurname(text: 'С $before!', decline: true),
        );
        session.remote(
          session.tree.setIndividualSurname(rootTreePersonId, text: null),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field).controller, same(controller));
        expect(controller.text, isEmpty);
        expect(tester.widget<CheckboxListTile>(decline).value, isTrue);
        session.remote(legacyFamilySurname('other-sibling', 'Старое значение'));
        await tester.pumpAndSettle();
        expect(
          controller.text,
          isEmpty,
          reason: 'A remote clear is authoritative too.',
        );
        expect(session.operations, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'remote surname maps active IME composition and its next personal commit',
    (tester) async {
      session.seed(
        session.tree.setIndividualSurname(
          rootTreePersonId,
          text: 'Иванов',
          decline: true,
        ),
      );
      await mount(tester);
      await edit(tester);
      final field = find.byKey(const Key('person-surname-field'));
      await tester.tap(field);
      await tester.pumpAndSettle();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'Иванов',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 1, end: 3),
        ),
      );
      await tester.pump();
      final controller = tester.widget<TextField>(field).controller!;
      session.remote(
        session.tree.setIndividualSurname(
          rootTreePersonId,
          text: 'С Иванов',
          decline: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.selection, const TextSelection.collapsed(offset: 5));
      expect(controller.value.composing, const TextRange(start: 3, end: 5));
      expect(session.operations, isEmpty);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'С Ионов',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.text, 'С Ионов');
      expect(controller.value.composing, TextRange.empty);
      expect(
        session.durableTree.person(rootTreePersonId)!.individualSurname,
        const TreeSurname(text: 'С Ионов', decline: true),
      );
      expect(session.operations.single.toJson()['scope'], 'individual');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('remote surname replacement clears a collapsed composing range', (
    tester,
  ) async {
    session.seed(
      session.tree.setIndividualSurname(rootTreePersonId, text: 'Иванов'),
    );
    await mount(tester);
    await edit(tester);
    final field = find.byKey(const Key('person-surname-field'));
    final controller = tester.widget<TextField>(field).controller!;
    controller.value = const TextEditingValue(
      text: 'Иванов',
      selection: TextSelection.collapsed(offset: 3),
      composing: TextRange(start: 1, end: 3),
    );
    session.remote(
      session.tree.setIndividualSurname(rootTreePersonId, text: 'Инов'),
    );
    await tester.pumpAndSettle();
    expect(controller.text, 'Инов');
    expect(controller.value.composing, TextRange.empty);
    expect(session.operations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('surname write error retries the same personal event ID', (
    tester,
  ) async {
    seedRelatives();
    await mount(tester);
    await edit(tester);
    expect(session.operations, isEmpty);
    session.failWrites = true;
    final field = find.byKey(const Key('person-surname-field'));
    await tester.enterText(field, 'Петров');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, 'Петров');
    expect(session.tree.person(rootTreePersonId)!.surname, 'Петров');
    expect(session.tree.person('sibling')!.surname, isEmpty);
    expect(
      session.durableTree.person(rootTreePersonId)!.effectiveSurname,
      isNull,
    );
    expect(find.byKey(const Key('biography-save-error')), findsOneWidget);
    expect(find.textContaining('Диск недоступен'), findsOneWidget);
    final pendingId = session._pending.single.id;
    final clock = session._clock;
    await tester.pump(const Duration(seconds: 10));
    expect(find.byKey(const Key('biography-save-error')), findsOneWidget);
    await tester.tap(find.text('Повторить сохранение'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('biography-save-error')), findsOneWidget);
    expect(session._pending.single.id, pendingId);
    expect(session._clock, clock);
    expect(session.operations, hasLength(1));
    session.failWrites = false;
    await tester.tap(find.text('Повторить сохранение'));
    await tester.pumpAndSettle();
    expect(session.durableTree.person(rootTreePersonId)!.surname, 'Петров');
    expect(session.durableTree.person('sibling')!.surname, isEmpty);
    expect(
      session.durableTree.person(rootTreePersonId)!.individualSurname,
      const TreeSurname(text: 'Петров', decline: true),
    );
    expect(session.operations.single.personId, rootTreePersonId);
    expect(session.operations.single.toJson()['scope'], 'individual');
    expect(session._pending, isEmpty);
    expect(session._clock, clock, reason: 'Retry flushes; it never restamps.');
    expect(session.operations, hasLength(1));
    expect(find.byKey(const Key('biography-save-error')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('guests see rendered surnames but no surname editing controls', (
    tester,
  ) async {
    session.seed(
      session.tree.editText(rootTreePersonId, TreeTextField.name, 'Анна')!,
    );
    session.seed(session.tree.setValue(rootTreePersonId, 'sex', 'female'));
    session.seed(
      session.tree.setIndividualSurname(
        rootTreePersonId,
        text: 'Иванов',
        decline: true,
      ),
    );
    session.seed(
      session.tree.setMaidenSurname(
        rootTreePersonId,
        text: 'Петров',
        decline: true,
      ),
    );
    session.setEditingAllowed(false);
    await mount(tester);
    expect(find.text('Анна Иванова'), findsOneWidget);
    expect(find.textContaining('до замужества'), findsNothing);
    expect(find.textContaining('Петров'), findsNothing);
    expect(find.byKey(const Key('biography-edit-toggle')), findsNothing);
    expect(find.byKey(const Key('person-surname-field')), findsNothing);
    expect(find.byKey(const Key('surname-individual-toggle')), findsNothing);
    expect(find.byKey(const Key('surname-decline')), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(
      session.durableTree.person(rootTreePersonId)!.maidenSurname,
      const TreeSurname(text: 'Петров', decline: true),
    );
    expect(session.operations, isEmpty);
  });

  for (final height in [500.0, 844.0]) {
    testWidgets(
      'single personal surname field and decline checkbox work at 390 by $height',
      (tester) async {
        seedRelatives();
        session.seed(session.tree.setValue(rootTreePersonId, 'sex', 'female'));
        await mount(tester, size: Size(390, height), fullScreen: true);
        await edit(tester);
        final field = find.byKey(const Key('person-surname-field'));
        final decline = find.byKey(const Key('surname-decline'));
        await reveal(tester, field);
        expectSurnameControls(tester);
        final controller = tester.widget<TextField>(field).controller!;
        expect(tester.widget<CheckboxListTile>(decline).value, isTrue);
        expect(session.operations, isEmpty);
        await tester.enterText(field, 'Иванов');
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field).controller, same(controller));
        expect(
          session.durableTree.person(rootTreePersonId)!.surname,
          'Иванова',
        );
        await visibleTap(tester, decline);
        expect(
          session.durableTree.person(rootTreePersonId)!.individualSurname,
          const TreeSurname(text: 'Иванов'),
        );
        expect(session.durableTree.person(rootTreePersonId)!.surname, 'Иванов');
        await visibleTap(tester, find.byTooltip('Убрать фамилию'));
        expect(tester.widget<TextField>(field).controller, same(controller));
        expect(controller.text, isEmpty);
        expect(tester.widget<CheckboxListTile>(decline).value, isTrue);
        await edit(tester);
        await edit(tester);
        await reveal(tester, field);
        expect(tester.widget<TextField>(field).controller!.text, isEmpty);
        expect(tester.widget<CheckboxListTile>(decline).value, isTrue);
        for (final id in ['sibling', 'other-sibling', 'half']) {
          expect(session.durableTree.person(id)!.individualSurname, isNull);
          expect(session.durableTree.person(id)!.familySurname, isNull);
          expect(session.durableTree.person(id)!.surname, isEmpty);
        }
        expect(session.operations, hasLength(3));
        expect(
          session.operations.map((operation) => operation.personId),
          everyElement(rootTreePersonId),
        );
        expect(
          session.operations.map((operation) => operation.toJson()['scope']),
          everyElement('individual'),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('save errors remain visible and retry flushes the pending edit', (
    tester,
  ) async {
    await mount(tester);
    await edit(tester);
    session.failWrites = true;
    await tester.enterText(
      find.byKey(const Key('person-name-field')),
      'Несохранённое имя',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('biography-save-error')), findsOneWidget);
    expect(find.textContaining('Диск недоступен'), findsOneWidget);
    expect(session.tree.person(rootTreePersonId)!.name, 'Несохранённое имя');
    expect(session.durableTree.person(rootTreePersonId)!.name, isEmpty);
    await tester.pump(const Duration(seconds: 10));
    expect(find.byKey(const Key('biography-save-error')), findsOneWidget);
    session.failWrites = false;
    await tester.tap(find.text('Повторить сохранение'));
    await tester.pumpAndSettle();
    expect(
      session.durableTree.person(rootTreePersonId)!.name,
      'Несохранённое имя',
    );
    expect(find.byKey(const Key('biography-save-error')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
