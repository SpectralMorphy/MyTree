import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/room_document.dart';
import 'package:mytree_webrtc_demo/room_session.dart';
import 'package:mytree_webrtc_demo/storage/room_store.dart';
import 'package:mytree_webrtc_demo/tree/tree_document.dart';
import 'package:mytree_webrtc_demo/ui/patronymic_dictionary_dialog.dart';

class _DictionarySession extends RoomSession {
  _DictionarySession()
    : super(
        roomId: '1234567890abcdef1234567890abcdef',
        actorId: 'self',
        store: MemoryRoomStore(),
        existingMember: true,
      );

  final document = TreeDocument();
  final operations = <TreeOperation>[];
  final edits = <RoomEdit>[];
  bool editor = true;
  bool failSave = false;
  String? saveError;
  Completer<void>? pendingSave;
  int retries = 0;

  @override
  bool get canEdit => editor;
  @override
  TreeDocument get tree => document;
  @override
  List<RoomEdit> get changes => edits;
  @override
  String? get storageError => saveError;

  @override
  Future<void> setPatronymicOverride(
    String name, {
    required String? male,
    required String? female,
  }) async {
    if (!editor) throw StateError('Только редактор');
    final operation = document.setPatronymicOverride(
      name,
      male: male,
      female: female,
    );
    operations.add(operation);
    edits.add(
      RoomEdit(
        id: 'edit-${operations.length}',
        author: actorId,
        clock: operations.length,
        createdAt: DateTime.utc(2026).millisecondsSinceEpoch,
        kind: RoomEditKind.tree,
        text: jsonEncode(operation.toJson()),
      ),
    );
    document.merge([
      StampedTreeOperation(
        id: 'edit-${operations.length}',
        author: 'self',
        clock: operations.length,
        createdAt: DateTime.utc(2026),
        operation: operation,
      ),
    ]);
    notifyListeners();
    await pendingSave?.future;
    if (failSave) {
      saveError = 'disk full';
      notifyListeners();
      throw StateError(saveError!);
    }
  }

  @override
  Future<void> flush() async {
    retries++;
    if (failSave) throw StateError(saveError!);
    saveError = null;
    notifyListeners();
  }

  void refresh() => notifyListeners();
}

Future<void> _open(WidgetTester tester, _DictionarySession session) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => PatronymicDictionaryDialog(session: session),
            ),
            child: const Text('Открыть'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Открыть'));
  await tester.pumpAndSettle();
}

Finder get _name => find.byKey(const Key('patronymic-father-name'));
Finder get _male => find.byKey(const Key('patronymic-male-form'));
Finder get _female => find.byKey(const Key('patronymic-female-form'));
Finder get _save => find.byKey(const Key('save-patronymic-entry'));

Future<void> _add(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('add-patronymic-entry')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('base dictionary is read-only until explicitly saved', (
    tester,
  ) async {
    final session = _DictionarySession();
    addTearDown(session.dispose);
    await _open(tester, session);
    expect(find.text('Словарь отчеств'), findsOneWidget);
    expect(find.text('Анатольевич / Анатольевна'), findsOneWidget);
    await _add(tester);
    await tester.enterText(_name, ' Иван ');
    expect(tester.widget<TextField>(_male).controller!.text, 'Иванович');
    expect(tester.widget<TextField>(_female).controller!.text, 'Ивановна');
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(session.operations, isEmpty);
    expect(session.tree.patronymicOverrides, isEmpty);
  });

  testWidgets('adds atomic room entry, edits it, resets to the base', (
    tester,
  ) async {
    final session = _DictionarySession();
    addTearDown(session.dispose);
    await _open(tester, session);
    await _add(tester);
    await tester.enterText(_name, '  Анатолий  ');
    await tester.enterText(_male, 'Анатолиевич');
    await tester.enterText(_female, 'Анатолиевна');
    await tester.tap(_save);
    await tester.pumpAndSettle();
    expect(session.operations, hasLength(1));
    expect(
      session.tree.patronymicOverrides['анатолий'],
      const TreePatronymicForms(male: 'Анатолиевич', female: 'Анатолиевна'),
    );
    await tester.tap(find.byKey(const ValueKey('patronymic-entry-анатолий')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_name).enabled, isFalse);
    expect(tester.widget<TextField>(_male).controller!.text, 'Анатолиевич');
    await tester.tap(find.byKey(const Key('reset-patronymic-entry')));
    await tester.pumpAndSettle();
    expect(session.operations, hasLength(2));
    expect(session.tree.patronymicOverrides, isEmpty);
    expect(find.text('Анатольевич / Анатольевна'), findsOneWidget);
  });

  testWidgets('guest can read but cannot add or edit; role changes are live', (
    tester,
  ) async {
    final session = _DictionarySession()..editor = false;
    addTearDown(session.dispose);
    await _open(tester, session);
    expect(find.byKey(const Key('add-patronymic-entry')), findsNothing);
    await tester.tap(find.text('Анатолий'));
    await tester.pumpAndSettle();
    expect(_name, findsNothing);
    session.editor = true;
    session.refresh();
    await tester.pumpAndSettle();
    await _add(tester);
    await tester.enterText(_name, 'Иван');
    session.editor = false;
    session.refresh();
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(_save).onPressed, isNull);
    expect(session.operations, isEmpty);
  });

  testWidgets(
    'failed optimistic save retains draft and flushes the same edit',
    (tester) async {
      final session = _DictionarySession()..failSave = true;
      addTearDown(session.dispose);
      await _open(tester, session);
      await _add(tester);
      await tester.enterText(_name, 'Иван');
      await tester.enterText(_female, 'Особая форма');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(find.textContaining('Не удалось сохранить:'), findsOneWidget);
      expect(
        tester.widget<TextField>(_female).controller!.text,
        'Особая форма',
      );
      expect(tester.widget<TextField>(_female).enabled, isFalse);
      expect(session.operations, hasLength(1));
      expect(find.text('Повторить сохранение'), findsOneWidget);
      session.failSave = false;
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(session.operations, hasLength(1));
      expect(session.retries, 1);
      expect(_name, findsNothing);
    },
  );

  testWidgets('pending save blocks dismissal and duplicate commands', (
    tester,
  ) async {
    final pending = Completer<void>();
    final session = _DictionarySession()..pendingSave = pending;
    addTearDown(session.dispose);
    await _open(tester, session);
    await _add(tester);
    await tester.enterText(_name, 'Иван');
    await tester.tap(_save);
    await tester.pump();
    expect(tester.widget<FilledButton>(_save).onPressed, isNull);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Отмена'))
          .onPressed,
      isNull,
    );
    expect(session.operations, hasLength(1));
    pending.complete();
    await tester.pumpAndSettle();
    expect(_name, findsNothing);
  });

  testWidgets(
    'remote winner does not turn failed save retry into a new command',
    (tester) async {
      final pending = Completer<void>();
      final session = _DictionarySession()
        ..pendingSave = pending
        ..failSave = true;
      addTearDown(session.dispose);
      await _open(tester, session);
      await _add(tester);
      await tester.enterText(_name, 'Иван');
      await tester.tap(_save);
      await tester.pump();
      session.document.merge([
        StampedTreeOperation(
          id: 'remote-winner',
          author: 'other',
          clock: 100,
          createdAt: DateTime.utc(2026),
          operation: session.document.setPatronymicOverride(
            'Иван',
            male: 'Другая форма',
            female: 'Другая форма',
          ),
        ),
      ]);
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.text('Повторить сохранение'), findsOneWidget);
      session.failSave = false;
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(session.operations, hasLength(1));
      expect(session.retries, 1);
      expect(
        session.document.patronymicOverrides['иван']!.male,
        'Другая форма',
      );
    },
  );

  testWidgets(
    'reopening an equal optimistic entry still flushes its failed save',
    (tester) async {
      final session = _DictionarySession()..failSave = true;
      addTearDown(session.dispose);
      await _open(tester, session);
      await _add(tester);
      await tester.enterText(_name, 'Анатолий');
      await tester.enterText(_male, 'Особая форма');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('patronymic-entry-анатолий')));
      await tester.pumpAndSettle();
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(find.textContaining('Не удалось сохранить:'), findsOneWidget);
      expect(session.operations, hasLength(1));
      expect(session.retries, 1);
      session.failSave = false;
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(_name, findsNothing);
      expect(session.operations, hasLength(1));
      expect(session.retries, 2);
    },
  );

  testWidgets('reset retry ignores the discarded invalid form draft', (
    tester,
  ) async {
    final session = _DictionarySession();
    addTearDown(session.dispose);
    await session.setPatronymicOverride(
      'Анатолий',
      male: 'Форма',
      female: 'Форма',
    );
    await _open(tester, session);
    await tester.tap(find.byKey(const ValueKey('patronymic-entry-анатолий')));
    await tester.pumpAndSettle();
    await tester.enterText(_male, 'Неверная\tформа');
    session.failSave = true;
    await tester.tap(find.byKey(const Key('reset-patronymic-entry')));
    await tester.pumpAndSettle();
    expect(find.text('Повторить сохранение'), findsOneWidget);
    session.failSave = false;
    await tester.tap(_save);
    await tester.pumpAndSettle();
    expect(session.operations, hasLength(2));
    expect(session.retries, 1);
    expect(_name, findsNothing);
    expect(session.tree.patronymicOverrides, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'case-changing display does not retarget an existing dictionary key',
    (tester) async {
      final session = _DictionarySession();
      addTearDown(session.dispose);
      await session.setPatronymicOverride(
        'ışık',
        male: 'Форма',
        female: 'Форма',
      );
      await _open(tester, session);
      await tester.tap(find.byKey(const ValueKey('patronymic-entry-ışık')));
      await tester.pumpAndSettle();
      await tester.enterText(_male, 'Другая форма');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(session.tree.patronymicOverrides.keys, ['ışık']);
      expect(session.tree.patronymicOverrides['ışık']!.male, 'Другая форма');
      await tester.tap(find.byKey(const ValueKey('patronymic-entry-ışık')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reset-patronymic-entry')));
      await tester.pumpAndSettle();
      expect(session.tree.patronymicOverrides, isEmpty);
    },
  );

  testWidgets('equivalent father spelling preserves typed custom forms', (
    tester,
  ) async {
    final session = _DictionarySession();
    addTearDown(session.dispose);
    await _open(tester, session);
    await _add(tester);
    await tester.enterText(_name, 'John');
    await tester.enterText(_male, 'Джонович');
    await tester.enterText(_female, 'Джоновна');
    await tester.enterText(_name, ' JOHN ');
    expect(tester.widget<TextField>(_male).controller!.text, 'Джонович');
    expect(tester.widget<TextField>(_female).controller!.text, 'Джоновна');
    await tester.tap(_save);
    await tester.pumpAndSettle();
    expect(
      session.tree.patronymicOverrides['john'],
      const TreePatronymicForms(male: 'Джонович', female: 'Джоновна'),
    );
  });

  testWidgets('dictionary and entry form fit a phone viewport', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = _DictionarySession();
    addTearDown(session.dispose);
    await _open(tester, session);
    await _add(tester);
    await tester.enterText(_name, 'Иван');
    await tester.tap(_save);
    await tester.pumpAndSettle();
    expect(session.operations, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
