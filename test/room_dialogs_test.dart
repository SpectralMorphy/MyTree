import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/cloud/disk_binding.dart';
import 'package:mytree_webrtc_demo/room_document.dart';
import 'package:mytree_webrtc_demo/room_identity.dart';
import 'package:mytree_webrtc_demo/room_session.dart';
import 'package:mytree_webrtc_demo/storage/room_store.dart';
import 'package:mytree_webrtc_demo/ui/room_dialogs.dart';
import 'package:mytree_webrtc_demo/tree/tree_document.dart';

class _DialogSession extends RoomSession {
  _DialogSession({this.role = RoomRole.editor})
    : super(
        roomId: '1234567890abcdef1234567890abcdef',
        actorId: 'self',
        store: MemoryRoomStore(),
        existingMember: true,
      );

  List<RoomParticipant> roster = const [];
  List<RoomEdit> edits = const [];
  String title = 'Семейная комната';
  Object? renameError;
  Completer<void>? renameSave;
  Object? promotionError;
  Completer<void>? promotionSave;
  final promotions = <String>[];
  RoomRole role;
  bool ready = true;
  DiskBinding? binding;
  String diskStatus = 'Не подключён';
  String? diskError;
  bool diskBusy = false;
  bool diskAcknowledged = false;
  bool diskRetiring = false;
  bool networkConnected = false;
  Object? connectError;
  Object? disconnectError;
  Object? syncError;
  Completer<void>? connectSave;
  Completer<void>? disconnectSave;
  Completer<void>? syncSave;
  int connectCalls = 0;
  int disconnectCalls = 0;
  int syncCalls = 0;
  String? connectedToken;

  @override
  bool get canEdit => role == RoomRole.editor;
  @override
  RoomRole get ownRole => role;
  @override
  List<RoomParticipant> get participants => roster;
  @override
  List<RoomEdit> get changes => edits;
  @override
  String get roomName => title;
  @override
  bool get initialSyncComplete => ready;
  @override
  DiskBinding? get diskBinding => binding;
  @override
  bool get canConnectDisk => canEdit && binding == null;
  @override
  bool get canDisconnectDisk => canEdit && binding?.ownerActor == actorId;
  @override
  String get diskSyncStatus => diskStatus;
  @override
  String? get diskSyncError => diskError;
  @override
  bool get diskSyncBusy => diskBusy;
  @override
  bool get diskSyncAcknowledged => diskAcknowledged;
  @override
  bool get diskUnlinkPending => diskRetiring;
  @override
  bool get networkAvailable => networkConnected;

  @override
  Future<void> connectDisk(String token) async {
    connectCalls++;
    connectedToken = token;
    await connectSave?.future;
    if (connectError != null) throw connectError!;
    binding = _diskBinding();
    diskStatus = 'Подключён';
    notifyListeners();
  }

  @override
  Future<void> disconnectDisk() async {
    disconnectCalls++;
    await disconnectSave?.future;
    if (disconnectError != null) throw disconnectError!;
    binding = null;
    diskStatus = 'Не подключён';
    notifyListeners();
  }

  @override
  Future<void> syncDisk() async {
    syncCalls++;
    await syncSave?.future;
    if (syncError != null) {
      diskAcknowledged = false;
      throw syncError!;
    }
    diskStatus = 'Синхронизировано';
    diskError = null;
    diskAcknowledged = true;
    notifyListeners();
  }

  @override
  Future<void> renameRoom(String name) async {
    await renameSave?.future;
    if (renameError != null) throw renameError!;
    title = name;
    notifyListeners();
  }

  @override
  Future<void> promoteParticipant(String actorId) async {
    promotions.add(actorId);
    if (promotionError != null) throw promotionError!;
    await promotionSave?.future;
    updateRoster([
      for (final person in roster)
        if (person.actorId == actorId)
          RoomParticipant(
            actorId: person.actorId,
            name: person.name,
            isOnline: person.isOnline,
            isSelf: person.isSelf,
            role: RoomRole.editor,
            boundPersonFullName: person.boundPersonFullName,
          )
        else
          person,
    ]);
  }

  void updateRoster(List<RoomParticipant> people) {
    roster = people;
    notifyListeners();
  }
}

DiskBinding _diskBinding({String id = 'disk-binding', String owner = 'self'}) =>
    DiskBinding(id: id, ownerActor: owner);

RoomParticipant _person(
  String id,
  String name, {
  bool online = true,
  bool self = false,
  RoomRole role = RoomRole.editor,
  String? boundPersonFullName,
}) => RoomParticipant(
  actorId: id,
  name: name,
  isOnline: online,
  isSelf: self,
  role: role,
  boundPersonFullName: boundPersonFullName,
);

Future<void> _showDialog(
  WidgetTester tester,
  Widget dialog, {
  double textScale = 1,
  Brightness brightness = Brightness.light,
  ValueChanged<Object?>? onResult,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final result = await showDialog<Object?>(
                context: context,
                builder: (_) => dialog,
              );
              onResult?.call(result);
            },
            child: const Text('Открыть'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Открыть'));
  await tester.pumpAndSettle();
}

Future<void> _showDiskButton(
  WidgetTester tester,
  _DialogSession session, {
  Brightness brightness = Brightness.light,
  bool enabled = true,
  bool includeParticipants = false,
  VoidCallback? onConnect,
}) => tester.pumpWidget(
  MaterialApp(
    theme: ThemeData(brightness: brightness),
    home: Scaffold(
      appBar: AppBar(
        title: Text(
          session.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          RoomDiskStatusButton(
            session: session,
            enabled: enabled,
            onConnect: onConnect,
          ),
          if (includeParticipants)
            RoomParticipantsButton(
              otherOnlineCount: 2,
              networkAvailable: session.networkAvailable,
              onPressed: () {},
            ),
        ],
      ),
      body: const SizedBox.shrink(),
    ),
  ),
);

String _diskTooltipMessage(WidgetTester tester) => tester
    .widget<Tooltip>(
      find.descendant(
        of: find.byType(RoomDiskStatusButton),
        matching: find.byType(Tooltip),
      ),
    )
    .message!;

void _expectDiskSymbol(WidgetTester tester, IconData glyph, Color color) {
  final symbol = find.byKey(const Key('disk-sync-symbol'));
  final icon = tester.widget<Icon>(symbol);
  expect(icon.icon, glyph);
  expect(icon.color ?? IconTheme.of(tester.element(symbol)).color, color);
  final badge = find.byKey(const Key('disk-sync-badge'));
  expect(find.descendant(of: badge, matching: symbol), findsOneWidget);
  final decoration =
      tester.widget<DecoratedBox>(badge).decoration as BoxDecoration;
  expect(decoration.color, Theme.of(tester.element(badge)).colorScheme.surface);
}

List<String> _participantOrder(WidgetTester tester) => tester
    .widgetList<Semantics>(
      find.descendant(
        of: find.byKey(const Key('participants-list')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'participant-',
              ),
        ),
      ),
    )
    .map(
      (widget) => (widget.key! as ValueKey<String>).value.substring(
        'participant-'.length,
      ),
    )
    .toList();

void main() {
  group('Disk status action', () {
    for (final brightness in Brightness.values) {
      testWidgets(
        '${brightness.name} cloud and status badge use theme colors',
        (tester) async {
          final session = _DialogSession()
            ..binding = _diskBinding()
            ..diskAcknowledged = true
            ..diskStatus = 'Синхронизировано';
          addTearDown(session.dispose);
          await _showDiskButton(tester, session, brightness: brightness);
          final button = find.byKey(const Key('disk-sync-button'));
          final cloud = find.byKey(const Key('disk-sync-cloud'));
          final symbol = find.byKey(const Key('disk-sync-symbol'));
          final colors = Theme.of(tester.element(button)).colorScheme;
          expect(tester.widget<IconButton>(button).onPressed, isNotNull);
          final icon = tester.widget<Icon>(cloud);
          expect(icon.icon, Icons.cloud_outlined);
          expect(
            icon.size ?? IconTheme.of(tester.element(cloud)).size,
            isIn([26.0, 28.0]),
          );
          final stack = find
              .ancestor(of: symbol, matching: find.byType(Stack))
              .first;
          expect(find.descendant(of: stack, matching: cloud), findsOneWidget);
          _expectDiskSymbol(tester, Icons.check, colors.primary);
          session.diskAcknowledged = false;
          session.diskStatus = 'Ожидает синхронизации';
          session.updateRoster(session.roster);
          await tester.pump();
          _expectDiskSymbol(tester, Icons.sync, colors.onSurfaceVariant);
          session.diskAcknowledged = true;
          session.diskError = 'Диск недоступен. Повторите позже.';
          session.updateRoster(session.roster);
          await tester.pump();
          _expectDiskSymbol(tester, Icons.close, colors.error);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    testWidgets(
      'guest is hidden but an unbound editor keeps a neutral cloud on live updates',
      (tester) async {
        final session = _DialogSession(role: RoomRole.guest)
          ..binding = _diskBinding()
          ..diskRetiring = true
          ..diskError = 'Не удалось завершить отвязку.';
        addTearDown(session.dispose);
        await _showDiskButton(tester, session);
        final button = find.byKey(const Key('disk-sync-button'));
        expect(button, findsNothing);
        session.role = RoomRole.editor;
        session.binding = null;
        session.diskRetiring = false;
        session.diskError = null;
        session.diskStatus = 'Не подключён';
        session.updateRoster(session.roster);
        await tester.pump();
        expect(button, findsOneWidget);
        expect(find.byKey(const Key('disk-sync-cloud')), findsOneWidget);
        expect(find.byKey(const Key('disk-sync-symbol')), findsNothing);
        expect(_diskTooltipMessage(tester), 'Яндекс Диск: Не подключён');
        session.binding = _diskBinding();
        session.updateRoster(session.roster);
        await tester.pump();
        expect(button, findsOneWidget);
        session.role = RoomRole.guest;
        session.updateRoster(session.roster);
        await tester.pump();
        expect(button, findsNothing);
        expect(session.syncCalls, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('unbound cloud opens setup instead of an impossible sync', (
      tester,
    ) async {
      final session = _DialogSession()..diskStatus = 'Не подключён';
      addTearDown(session.dispose);
      var opens = 0;
      await _showDiskButton(tester, session, onConnect: () => opens++);
      final button = find.byKey(const Key('disk-sync-button'));
      expect(button, findsOneWidget);
      expect(find.byKey(const Key('disk-sync-symbol')), findsNothing);
      await tester.tap(button);
      await tester.pump();
      expect(opens, 1);
      expect(session.syncCalls, 0);
      expect(_diskTooltipMessage(tester), 'Яндекс Диск: Не подключён');
      await _showDiskButton(
        tester,
        session,
        enabled: false,
        onConnect: () => opens++,
      );
      expect(tester.widget<IconButton>(button).onPressed, isNull);
      await tester.tap(button);
      await tester.pump();
      expect(opens, 1);
      expect(session.syncCalls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'pending retirement stays visible and outranks active acknowledgement',
      (tester) async {
        final session = _DialogSession()
          ..diskRetiring = true
          ..diskStatus = 'Отвязка сохранена локально · отправляем на Диск';
        addTearDown(session.dispose);
        await _showDiskButton(tester, session);
        final button = find.byKey(const Key('disk-sync-button'));
        final colors = Theme.of(tester.element(button)).colorScheme;
        _expectDiskSymbol(tester, Icons.sync, colors.onSurfaceVariant);
        expect(tester.widget<IconButton>(button).onPressed, isNotNull);
        expect(
          _diskTooltipMessage(tester),
          startsWith('Яндекс Диск: ${session.diskStatus}'),
        );
        session.binding = _diskBinding(id: 'replacement');
        session.diskAcknowledged = true;
        session.diskStatus = 'Синхронизировано';
        session.updateRoster(session.roster);
        await tester.pump();
        _expectDiskSymbol(tester, Icons.sync, colors.onSurfaceVariant);
        final message = _diskTooltipMessage(tester);
        expect(message, startsWith('Яндекс Диск: ${session.diskStatus}'));
        expect(message.toLowerCase(), contains('отвяз'));
        session.diskRetiring = false;
        session.updateRoster(session.roster);
        await tester.pump();
        _expectDiskSymbol(tester, Icons.check, colors.primary);
        expect(
          _diskTooltipMessage(tester).toLowerCase(),
          isNot(contains('отвяз')),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'unbound error has full semantics and a real desktop hover tooltip',
      (tester) async {
        const status =
            'Синхронизация изменений комнаты отложена до повторной проверки Диска';
        final error =
            'Не удалось подтвердить сохранение последних изменений. '
            '${'Подробности безопасной ошибки для пользователя. ' * 12}'
            'Конец полного сообщения.';
        final session = _DialogSession()
          ..diskStatus = status
          ..diskError = error;
        addTearDown(session.dispose);
        final semantics = tester.ensureSemantics();
        await _showDiskButton(tester, session, onConnect: () {});
        final button = find.byKey(const Key('disk-sync-button'));
        final colors = Theme.of(tester.element(button)).colorScheme;
        _expectDiskSymbol(tester, Icons.close, colors.error);
        final message = _diskTooltipMessage(tester);
        expect(message, startsWith('Яндекс Диск: $status'));
        expect(message, contains(error));
        expect(
          tester.getSemantics(find.bySemanticsLabel(message)),
          matchesSemantics(
            label: message,
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            hasTapAction: true,
          ),
        );
        expect(find.text(message), findsNothing);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: const Offset(1, 1));
        await mouse.moveTo(tester.getCenter(button));
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(find.text(message), findsOneWidget);
        final tooltipText = tester.widget<Text>(find.text(message));
        expect(tooltipText.maxLines, isNull);
        expect(tooltipText.overflow, isNot(TextOverflow.ellipsis));
        expect(tester.takeException(), isNull);
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'background busy overrides errors and check and rejects stale taps',
      (tester) async {
        final session = _DialogSession()
          ..binding = _diskBinding()
          ..diskAcknowledged = true
          ..diskError = 'Не удалось проверить Диск.';
        addTearDown(session.dispose);
        final semantics = tester.ensureSemantics();
        await _showDiskButton(tester, session);
        final button = find.byKey(const Key('disk-sync-button'));
        final colors = Theme.of(tester.element(button)).colorScheme;
        final sync = tester.widget<IconButton>(button).onPressed!;
        session.diskBusy = true;
        session.updateRoster(session.roster);
        await tester.pump();
        _expectDiskSymbol(tester, Icons.sync, colors.onSurfaceVariant);
        expect(tester.widget<IconButton>(button).onPressed, isNull);
        expect(
          tester
              .getSemantics(find.bySemanticsLabel(_diskTooltipMessage(tester)))
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isFalse,
        );
        sync();
        await tester.tap(button);
        await tester.pump();
        expect(session.syncCalls, 0);
        session.diskBusy = false;
        session.updateRoster(session.roster);
        await tester.pump();
        _expectDiskSymbol(tester, Icons.close, colors.error);
        expect(tester.widget<IconButton>(button).onPressed, isNotNull);
        session.diskError = null;
        session.updateRoster(session.roster);
        await tester.pump();
        _expectDiskSymbol(tester, Icons.check, colors.primary);
        expect(tester.takeException(), isNull);
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'sync is duplicate-safe without RTC or settings and listens live',
      (tester) async {
        final save = Completer<void>();
        final session = _DialogSession()
          ..binding = _diskBinding(owner: 'other-editor')
          ..networkConnected = false
          ..diskAcknowledged = true
          ..diskError = 'Не удалось проверить Диск.'
          ..syncSave = save;
        addTearDown(session.dispose);
        await _showDiskButton(tester, session);
        final button = find.byKey(const Key('disk-sync-button'));
        final colors = Theme.of(tester.element(button)).colorScheme;
        expect(session.networkAvailable, isFalse);
        final sync = tester.widget<IconButton>(button).onPressed!;
        await tester.tap(button);
        sync();
        await tester.pump();
        expect(session.syncCalls, 1);
        expect(session.diskBusy, isFalse);
        _expectDiskSymbol(tester, Icons.sync, colors.onSurfaceVariant);
        expect(tester.widget<IconButton>(button).onPressed, isNull);
        await tester.tap(button);
        await tester.pump();
        expect(session.syncCalls, 1);
        expect(find.byType(RoomSettingsDialog), findsNothing);
        expect(find.byType(AlertDialog), findsNothing);
        expect(session.connectCalls, 0);
        expect(session.disconnectCalls, 0);
        save.complete();
        await tester.pumpAndSettle();
        _expectDiskSymbol(tester, Icons.check, colors.primary);
        expect(_diskTooltipMessage(tester), 'Яндекс Диск: Синхронизировано');
        expect(tester.widget<IconButton>(button).onPressed, isNotNull);
        session.diskAcknowledged = false;
        session.diskStatus = 'Ожидает синхронизации';
        session.updateRoster(session.roster);
        await tester.pump();
        _expectDiskSymbol(tester, Icons.sync, colors.onSurfaceVariant);
        expect(
          _diskTooltipMessage(tester),
          'Яндекс Диск: Ожидает синхронизации',
        );
        session.diskAcknowledged = true;
        session.diskStatus = 'Синхронизировано';
        session.updateRoster(session.roster);
        await tester.pump();
        _expectDiskSymbol(tester, Icons.check, colors.primary);
        expect(session.syncCalls, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'raw sync failure is safe and retry restores the acknowledged check',
      (tester) async {
        const rawFailure = 'private-raw-exception-must-not-be-displayed';
        const safeError =
            'Не удалось синхронизировать с Диском. Повторите позже.';
        final session = _DialogSession()
          ..binding = _diskBinding()
          ..diskAcknowledged = true
          ..diskStatus = 'Синхронизировано'
          ..syncError = StateError(rawFailure);
        addTearDown(session.dispose);
        final semantics = tester.ensureSemantics();
        await _showDiskButton(tester, session);
        final button = find.byKey(const Key('disk-sync-button'));
        final colors = Theme.of(tester.element(button)).colorScheme;
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(session.syncCalls, 1);
        _expectDiskSymbol(tester, Icons.close, colors.error);
        final message = _diskTooltipMessage(tester);
        expect(message, startsWith('Яндекс Диск: ${session.diskStatus}'));
        expect(message, contains(safeError));
        expect(message, isNot(contains(rawFailure)));
        expect(find.bySemanticsLabel(message), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp(rawFailure)), findsNothing);
        expect(find.textContaining(rawFailure), findsNothing);
        final save = Completer<void>();
        session.syncError = null;
        session.syncSave = save;
        await tester.tap(button);
        await tester.pump();
        _expectDiskSymbol(tester, Icons.sync, colors.onSurfaceVariant);
        expect(_diskTooltipMessage(tester), isNot(contains(safeError)));
        expect(tester.widget<IconButton>(button).onPressed, isNull);
        save.complete();
        await tester.pumpAndSettle();
        expect(session.syncCalls, 2);
        _expectDiskSymbol(tester, Icons.check, colors.primary);
        expect(_diskTooltipMessage(tester), 'Яндекс Диск: Синхронизировано');
        expect(tester.takeException(), isNull);
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'local failure remains visible after unbinding until external success',
      (tester) async {
        final session = _DialogSession()
          ..binding = _diskBinding()
          ..syncError = StateError('private failure');
        addTearDown(session.dispose);
        await _showDiskButton(tester, session);
        final button = find.byKey(const Key('disk-sync-button'));
        final colors = Theme.of(tester.element(button)).colorScheme;
        await tester.tap(button);
        await tester.pumpAndSettle();
        session.binding = null;
        session.diskStatus = 'Не подключён';
        session.updateRoster(session.roster);
        await tester.pump();
        expect(session.diskError, isNull);
        _expectDiskSymbol(tester, Icons.close, colors.error);
        expect(
          _diskTooltipMessage(tester),
          contains('Не удалось синхронизировать с Диском. Повторите позже.'),
        );
        session.role = RoomRole.guest;
        session.updateRoster(session.roster);
        await tester.pump();
        expect(button, findsNothing);
        session.role = RoomRole.editor;
        session.binding = _diskBinding(id: 'replacement');
        session.diskAcknowledged = true;
        session.diskStatus = 'Синхронизировано';
        session.updateRoster(session.roster);
        await tester.pump();
        _expectDiskSymbol(tester, Icons.check, colors.primary);
        expect(_diskTooltipMessage(tester), 'Яндекс Диск: Синхронизировано');
        expect(session.syncCalls, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'enabled false disables semantics and blocks taps and stale callbacks',
      (tester) async {
        final session = _DialogSession()
          ..binding = _diskBinding()
          ..diskAcknowledged = true
          ..diskStatus = 'Синхронизировано';
        addTearDown(session.dispose);
        final semantics = tester.ensureSemantics();
        await _showDiskButton(tester, session);
        final button = find.byKey(const Key('disk-sync-button'));
        final sync = tester.widget<IconButton>(button).onPressed!;
        await _showDiskButton(tester, session, enabled: false);
        expect(tester.widget<IconButton>(button).onPressed, isNull);
        expect(
          tester.getSemantics(
            find.bySemanticsLabel(_diskTooltipMessage(tester)),
          ),
          matchesSemantics(
            label: _diskTooltipMessage(tester),
            isButton: true,
            hasEnabledState: true,
            isEnabled: false,
            hasTapAction: false,
          ),
        );
        sync();
        await tester.tap(button);
        await tester.pump();
        expect(session.syncCalls, 0);
        await _showDiskButton(tester, session);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(session.syncCalls, 1);
        expect(tester.takeException(), isNull);
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'pending sync failure after disposal does not update the widget',
      (tester) async {
        final save = Completer<void>();
        final session = _DialogSession()
          ..binding = _diskBinding()
          ..syncSave = save
          ..syncError = StateError('private failure');
        addTearDown(session.dispose);
        await _showDiskButton(tester, session);
        await tester.tap(find.byKey(const Key('disk-sync-button')));
        await tester.pump();
        expect(session.syncCalls, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        save.complete();
        await tester.pumpAndSettle();
        expect(find.byType(RoomDiskStatusButton), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    for (final width in [320.0, 390.0]) {
      testWidgets(
        'phone header keeps Disk left of participants at width $width',
        (tester) async {
          tester.view.physicalSize = Size(width, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final session = _DialogSession()
            ..binding = _diskBinding()
            ..networkConnected = true
            ..diskAcknowledged = true;
          addTearDown(session.dispose);
          await _showDiskButton(tester, session, includeParticipants: true);
          final disk = find.byKey(const Key('disk-sync-button'));
          final participants = find.byKey(const Key('participants-button'));
          expect(disk.hitTestable(), findsOneWidget);
          expect(participants.hitTestable(), findsOneWidget);
          final appBar = find.byType(AppBar);
          expect(find.descendant(of: appBar, matching: disk), findsOneWidget);
          expect(
            find.descendant(of: appBar, matching: participants),
            findsOneWidget,
          );
          final diskRect = tester.getRect(disk);
          final participantsRect = tester.getRect(participants);
          expect(diskRect.right, lessThanOrEqualTo(participantsRect.left));
          expect(diskRect.center.dy, closeTo(participantsRect.center.dy, 0.01));
          expect(diskRect.left, greaterThanOrEqualTo(0));
          expect(participantsRect.right, lessThanOrEqualTo(width));
          expect(tester.takeException(), isNull);
          await tester.tap(disk);
          await tester.pumpAndSettle();
          expect(session.syncCalls, 1);
          expect(find.byType(RoomSettingsDialog), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  });

  for (final connected in [true, false]) {
    for (final otherOnline in [0, 2]) {
      testWidgets(
        'participant action: network=$connected others=$otherOnline',
        (tester) async {
          final semantics = tester.ensureSemantics();
          var taps = 0;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                appBar: AppBar(
                  actions: [
                    RoomParticipantsButton(
                      otherOnlineCount: otherOnline,
                      networkAvailable: connected,
                      onPressed: () => taps++,
                    ),
                  ],
                ),
              ),
            ),
          );
          expect(
            tester
                .widget<Icon>(find.byKey(const Key('participants-icon')))
                .icon,
            connected ? Icons.person_outline : Icons.cloud_off_outlined,
          );
          final count = find.byKey(const Key('participants-count'));
          if (connected) {
            expect(tester.widget<Text>(count).data, '$otherOnline');
            expect(
              tester.getCenter(count).dx,
              lessThan(
                tester.getCenter(find.byKey(const Key('participants-icon'))).dx,
              ),
            );
          } else {
            expect(count, findsNothing);
          }
          final dot = find.byKey(const Key('participants-online-dot'));
          expect(dot, otherOnline > 0 ? findsOneWidget : findsNothing);
          if (otherOnline > 0) {
            final decoration =
                tester.widget<Container>(dot).decoration! as BoxDecoration;
            final icon = find.byKey(const Key('participants-icon'));
            final iconColor =
                tester.widget<Icon>(icon).color ??
                IconTheme.of(tester.element(icon)).color!;
            expect(decoration.shape, BoxShape.circle);
            expect(decoration.color, isNot(iconColor));
            expect(
              decoration.color!.computeLuminance(),
              greaterThan(iconColor.computeLuminance()),
              reason: 'Online presence needs a brighter marker than the icon.',
            );
          }
          expect(
            find.bySemanticsLabel(
              'Участники: $otherOnline других онлайн'
              '${connected ? '' : '. Нет подключения к сети'}',
            ),
            findsOneWidget,
          );
          expect(
            tester.getSemantics(
              find.bySemanticsLabel(
                'Участники: $otherOnline других онлайн'
                '${connected ? '' : '. Нет подключения к сети'}',
              ),
            ),
            matchesSemantics(
              label:
                  'Участники: $otherOnline других онлайн'
                  '${connected ? '' : '. Нет подключения к сети'}',
              isButton: true,
              hasEnabledState: true,
              isEnabled: true,
              hasTapAction: true,
            ),
          );
          await tester.tap(find.byKey(const Key('participants-button')));
          expect(taps, 1);
          expect(tester.takeException(), isNull);
          semantics.dispose();
        },
      );
    }
  }

  testWidgets('roster is exact, online first with avatars, and updates live', (
    tester,
  ) async {
    final session = _DialogSession();
    addTearDown(session.dispose);
    const longName =
        'Очень длинное имя участника, которое не помещается в подпись';
    session.roster = [
      _person('offline', 'Ольга', online: false),
      _person('self', 'Анна', self: true),
      _person('online', longName),
    ];
    final semantics = tester.ensureSemantics();
    await _showDialog(tester, RoomParticipantsDialog(session: session));
    expect(find.byType(CircleAvatar), findsNWidgets(3));
    expect(find.text('Анна'), findsOneWidget);
    expect(find.text('Ольга'), findsOneWidget);
    expect(find.text(longName), findsOneWidget);
    expect(find.text('Вы'), findsNothing);
    expect(find.text('Изменить имя'), findsNothing);
    expect(find.byTooltip('Изменить имя'), findsNothing);
    final self = find.byKey(const Key('participant-self'));
    final selfData = tester.getSemantics(self).getSemanticsData();
    expect(selfData.hasAction(SemanticsAction.tap), isFalse);
    expect(selfData.flagsCollection.isButton, isFalse);
    expect(selfData.hint, isEmpty);
    final glow = find.byKey(const Key('self-participant-glow'));
    expect(glow, findsOneWidget);
    expect(find.descendant(of: self, matching: glow), findsOneWidget);
    final decoration =
        tester.widget<Container>(glow).decoration! as BoxDecoration;
    expect(decoration.shape, BoxShape.circle);
    expect(decoration.border, isNotNull);
    expect(decoration.boxShadow, isNotEmpty);
    expect(
      decoration.boxShadow!.any((shadow) => shadow.blurRadius > 0),
      isTrue,
    );
    await tester.tap(self);
    await tester.pumpAndSettle();
    expect(find.byType(ParticipantNameDialog), findsNothing);
    expect(find.text('Сделать редактором?'), findsNothing);
    expect(
      find.bySemanticsLabel('$longName, онлайн, редактор'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Анна, вы, онлайн, редактор'), findsOneWidget);
    final name = tester.widget<Text>(find.text(longName));
    expect(name.maxLines, 1);
    expect(name.overflow, TextOverflow.ellipsis);
    expect(name.textAlign, TextAlign.center);
    expect(find.byKey(const Key('participants-list')), findsOneWidget);
    expect(_participantOrder(tester), ['self', 'online', 'offline']);
    expect(
      find.byKey(const Key('participant-online-dot-self')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('participant-online-dot-online')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('participant-online-dot-offline')),
      findsNothing,
    );
    session.updateRoster([
      _person('offline', 'Ольга'),
      _person('self', 'Анна', self: true),
      _person('online', longName, online: false),
      _person('new', 'Иван', online: false),
    ]);
    await tester.pump();
    expect(find.byType(RoomParticipantsDialog), findsOneWidget);
    expect(find.byType(CircleAvatar), findsNWidgets(4));
    expect(_participantOrder(tester), ['self', 'offline', 'new', 'online']);
    expect(
      find.byKey(const Key('participant-online-dot-self')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('participant-online-dot-offline')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('participant-online-dot-online')),
      findsNothing,
    );
    expect(find.byKey(const Key('participant-online-dot-new')), findsNothing);
    expect(find.text('Иван'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final textScale in [1.0, 2.5]) {
    testWidgets(
      'roster tooltips retain full bound identity and truncated aliases at scale $textScale',
      (tester) async {
        final session = _DialogSession();
        addTearDown(session.dispose);
        const longAlias = 'Очень длинное имя участника за пределами подписи';
        const boundAlias = 'Длинный псевдоним вместо имени человека';
        const fullName = 'Анна Васильевна Иванова';
        session.roster = [
          _person('short', 'Я'),
          _person('long', longAlias),
          _person('bound', 'А', boundPersonFullName: fullName),
          _person('bound-long', boundAlias, boundPersonFullName: fullName),
          _person('same', longAlias, boundPersonFullName: longAlias),
        ];
        await _showDialog(
          tester,
          RoomParticipantsDialog(session: session),
          textScale: textScale,
        );
        for (final person in session.roster) {
          final tile = find.byKey(Key('participant-tile-${person.actorId}'));
          final label = find.descendant(
            of: tile,
            matching: find.text(person.name),
          );
          final text = tester.widget<Text>(label);
          expect(tester.getSize(tile).width, 96);
          expect(tester.getSize(label).width, lessThanOrEqualTo(80));
          expect(text.maxLines, 1);
          expect(text.overflow, TextOverflow.ellipsis);
          final tooltip = find.ancestor(
            of: find.byKey(Key('participant-${person.actorId}')),
            matching: find.byType(Tooltip),
          );
          if (person.actorId == 'short') {
            expect(tooltip, findsNothing);
          } else {
            expect(tooltip, findsOneWidget);
            expect(
              tester.widget<Tooltip>(tooltip).message,
              switch (person.actorId) {
                'bound' => fullName,
                'bound-long' => '$boundAlias\n$fullName',
                _ => longAlias,
              },
            );
          }
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('tooltip detects overflow caused only by increased text scale', (
    tester,
  ) async {
    final session = _DialogSession();
    addTearDown(session.dispose);
    session.roster = [_person('scaled', 'Мария')];
    for (final scale in [1.0, 3.0]) {
      await _showDialog(
        tester,
        RoomParticipantsDialog(session: session),
        textScale: scale,
      );
      expect(
        find.byTooltip('Мария'),
        scale == 1 ? findsNothing : findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  for (final count in [1, 5]) {
    testWidgets('participant grid centers every row for $count people', (
      tester,
    ) async {
      final session = _DialogSession();
      addTearDown(session.dispose);
      session.roster = [
        for (var i = 0; i < count; i++)
          _person('actor-$i', 'Участник $i', self: i == 0),
      ];
      await _showDialog(tester, RoomParticipantsDialog(session: session));
      final list = find.byKey(const Key('participants-list'));
      expect(tester.widget<Wrap>(list).alignment, WrapAlignment.center);
      final listRect = tester.getRect(list);
      final rows = <double, List<Rect>>{};
      for (var i = 0; i < count; i++) {
        final participant = find.byKey(Key('participant-actor-$i'));
        final rect = tester.getRect(participant);
        rows.putIfAbsent(rect.top, () => []).add(rect);
        expect(
          tester
              .getCenter(
                find.descendant(
                  of: participant,
                  matching: find.byType(CircleAvatar),
                ),
              )
              .dx,
          closeTo(rect.center.dx, 0.01),
        );
        expect(
          tester.widget<Text>(find.text('Участник $i')).textAlign,
          TextAlign.center,
        );
      }
      if (count > 1) {
        expect(rows.length, greaterThan(1));
        expect(rows.values.last.length, lessThan(rows.values.first.length));
      }
      for (final row in rows.values) {
        row.sort((a, b) => a.left.compareTo(b.left));
        expect(
          (row.first.left + row.last.right) / 2,
          closeTo(listRect.center.dx, 0.01),
          reason: 'Full and partial rows must share the list center.',
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'one list sorts editors first and marks only guests with an eye',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final session = _DialogSession();
      addTearDown(session.dispose);
      session.roster = [
        _person(
          'guest-offline',
          'Гость офлайн',
          online: false,
          role: RoomRole.guest,
        ),
        _person('editor-offline', 'Алексей', online: false),
        _person('guest-online-b', 'Иван', role: RoomRole.guest),
        _person('editor-online-b', 'Борис'),
        _person('self', 'Анна', self: true),
        _person('guest-online-a', 'Иван', role: RoomRole.guest),
        _person('editor-online-a', 'борис'),
      ];
      final originalOrder = session.roster
          .map((person) => person.actorId)
          .toList();
      await _showDialog(tester, RoomParticipantsDialog(session: session));
      final list = find.byKey(const Key('participants-list'));
      expect(list, findsOneWidget);
      expect(
        find.descendant(of: list, matching: find.byType(Wrap)),
        findsNothing,
      );
      expect(find.byType(Wrap), findsOneWidget);
      for (final heading in ['Редакторы', 'Гости', 'Онлайн', 'Офлайн']) {
        expect(find.text(heading), findsNothing);
      }
      expect(_participantOrder(tester), [
        'self',
        'editor-online-a',
        'editor-online-b',
        'editor-offline',
        'guest-online-a',
        'guest-online-b',
        'guest-offline',
      ]);
      expect(session.roster.map((person) => person.actorId), originalOrder);
      expect(find.text('Сделать редактором'), findsNothing);
      for (final person in session.roster) {
        final participant = find.byKey(Key('participant-${person.actorId}'));
        final tile = find.byKey(Key('participant-tile-${person.actorId}'));
        final colors = Theme.of(tester.element(tile)).colorScheme;
        expect(
          (tester.widget<Ink>(tile).decoration! as BoxDecoration).color,
          person.isOnline ? colors.primaryContainer : isNull,
        );
        final dot = find.byKey(Key('participant-online-dot-${person.actorId}'));
        expect(dot, person.isOnline ? findsOneWidget : findsNothing);
        if (person.isOnline) {
          expect(
            find.descendant(of: participant, matching: dot),
            findsOneWidget,
          );
          final decoration =
              tester.widget<Container>(dot).decoration! as BoxDecoration;
          expect(decoration.shape, BoxShape.circle);
          expect(decoration.color, const Color(0xFF32D74B));
          expect(
            decoration.border,
            Border.all(color: colors.surface, width: 2),
          );
          final stack = find
              .ancestor(of: dot, matching: find.byType(Stack))
              .first;
          expect(
            tester.getBottomRight(dot).dx,
            closeTo(tester.getBottomRight(stack).dx, 0.01),
          );
          expect(
            tester.getBottomRight(dot).dy,
            closeTo(tester.getBottomRight(stack).dy, 0.01),
          );
        }
        final badge = find.byKey(Key('guest-badge-${person.actorId}'));
        if (person.role == RoomRole.editor) {
          expect(badge, findsNothing);
          final data = tester.getSemantics(participant).getSemanticsData();
          expect(data.label, contains(', редактор'));
          expect(data.hint, isEmpty);
          expect(data.hasAction(SemanticsAction.tap), isFalse);
        } else {
          expect(
            find.descendant(of: participant, matching: badge),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: badge,
              matching: find.byIcon(Icons.visibility_outlined),
            ),
            findsOneWidget,
          );
          final stack = find
              .ancestor(of: badge, matching: find.byType(Stack))
              .first;
          expect(
            tester.getTopRight(badge).dx,
            closeTo(tester.getTopRight(stack).dx, 0.01),
          );
          expect(
            tester.getTopRight(badge).dy,
            closeTo(tester.getTopRight(stack).dy, 0.01),
          );
          if (person.isOnline) {
            expect(
              tester.getRect(badge).overlaps(tester.getRect(dot)),
              isFalse,
            );
          }
          final data = tester.getSemantics(participant).getSemanticsData();
          expect(data.label, contains(', гость'));
          expect(data.hint, 'Сделать редактором');
          expect(data.hasAction(SemanticsAction.tap), isTrue);
        }
      }
      expect(find.byIcon(Icons.visibility_outlined), findsNWidgets(3));
      expect(tester.takeException(), isNull);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      '${brightness.name} guest eyes have a brown badge with a contrasting white glyph',
      (tester) async {
        final session = _DialogSession();
        addTearDown(session.dispose);
        session.roster = [
          _person('editor', 'Редактор'),
          _person('self', 'Гость', self: true, role: RoomRole.guest),
          _person('online', 'Онлайн', role: RoomRole.guest),
          _person('offline', 'Офлайн', online: false, role: RoomRole.guest),
        ];
        await _showDialog(
          tester,
          RoomParticipantsDialog(session: session),
          brightness: brightness,
        );
        expect(find.byKey(const Key('guest-badge-editor')), findsNothing);
        for (final actor in ['self', 'online', 'offline']) {
          final badge = find.byKey(Key('guest-badge-$actor'));
          final fill =
              (tester.widget<Container>(badge).decoration! as BoxDecoration)
                  .color!;
          final eye = tester.widget<Icon>(
            find.descendant(
              of: badge,
              matching: find.byIcon(Icons.visibility_outlined),
            ),
          );
          expect(fill, const Color(0xFF875826));
          expect(fill.a, 1);
          expect(eye.color, Colors.white);
          final contrast =
              (eye.color!.computeLuminance() + .05) /
              (fill.computeLuminance() + .05);
          expect(contrast, greaterThanOrEqualTo(4.5));
          expect(tester.getSize(badge), const Size(20, 20));
        }
        expect(session.promotions, isEmpty);
        expect(session.changes, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final online in [true, false]) {
    testWidgets(
      'editor promotes ${online ? 'online' : 'offline'} guest only after save',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final session = _DialogSession()..promotionSave = Completer<void>();
        addTearDown(session.dispose);
        session.roster = [
          _person('self', 'Анна', self: true),
          _person('guest', 'Иван', online: online, role: RoomRole.guest),
        ];
        await _showDialog(tester, RoomParticipantsDialog(session: session));
        final list = find.byKey(const Key('participants-list'));
        final target = find.byKey(const Key('participant-guest'));
        final badge = find.byKey(const Key('guest-badge-guest'));
        expect(find.text('Сделать редактором'), findsNothing);
        expect(badge, findsOneWidget);
        expect(
          tester.getSemantics(target).getSemanticsData().hint,
          'Сделать редактором',
        );
        await tester.ensureVisible(target);
        await tester.tap(target);
        await tester.pumpAndSettle();
        expect(find.text('Сделать редактором?'), findsOneWidget);
        expect(session.promotions, isEmpty);
        await tester.tap(
          find.widgetWithText(FilledButton, 'Сделать редактором'),
        );
        await tester.pump();
        expect(session.promotions, ['guest']);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(find.descendant(of: list, matching: target), findsOneWidget);
        expect(badge, findsOneWidget);
        expect(session.roster.last.role, RoomRole.guest);
        expect(
          tester
              .getSemantics(target)
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isFalse,
        );
        session.promotionSave!.complete();
        await tester.pumpAndSettle();
        expect(find.byType(RoomParticipantsDialog), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(badge, findsNothing);
        expect(find.descendant(of: list, matching: target), findsOneWidget);
        expect(
          find.bySemanticsLabel(
            'Иван, ${online ? 'онлайн' : 'офлайн'}, редактор',
          ),
          findsOneWidget,
        );
        expect(
          tester
              .getSemantics(target)
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isFalse,
        );
        expect(session.roster.last.role, RoomRole.editor);
        expect(find.text('Сделать редактором'), findsNothing);
        expect(tester.takeException(), isNull);
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'promotion cancellation and save failure keep guest, retry works',
    (tester) async {
      final session = _DialogSession()
        ..promotionError = StateError('disk unavailable');
      addTearDown(session.dispose);
      session.roster = [
        _person('self', 'Анна', self: true),
        _person('guest', 'Иван', role: RoomRole.guest),
      ];
      await _showDialog(tester, RoomParticipantsDialog(session: session));
      final target = find.byKey(const Key('participant-guest'));
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(session.promotions, isEmpty);
      await tester.tap(target);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Сделать редактором'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'Не удалось сохранить: Bad state: disk unavailable',
        ),
        findsOneWidget,
      );
      expect(session.roster.last.role, RoomRole.guest);
      expect(find.byKey(const Key('guest-badge-guest')), findsOneWidget);
      expect(
        find.descendant(of: target, matching: find.text('Иван')),
        findsOneWidget,
      );
      await tester.pump();
      expect(find.textContaining('disk unavailable'), findsOneWidget);
      session.promotionError = null;
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Сделать редактором'));
      await tester.pumpAndSettle();
      expect(session.promotions, ['guest', 'guest']);
      expect(session.roster.last.role, RoomRole.editor);
      expect(find.textContaining('Не удалось сохранить'), findsNothing);
      expect(find.byKey(const Key('guest-badge-guest')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('guest panel has no self-name or promotion actions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final session = _DialogSession(role: RoomRole.guest);
    addTearDown(session.dispose);
    session.roster = [
      _person('editor', 'Анна'),
      _person('self', 'Мария', self: true, role: RoomRole.guest),
      _person('guest', 'Иван', role: RoomRole.guest),
    ];
    await _showDialog(tester, RoomParticipantsDialog(session: session));
    expect(find.text('Сделать редактором'), findsNothing);
    expect(find.text('Вы'), findsNothing);
    expect(find.text('Изменить имя'), findsNothing);
    expect(find.text('Изменить моё имя'), findsNothing);
    expect(find.bySemanticsLabel('Мария, вы, онлайн, гость'), findsOneWidget);
    expect(find.byIcon(Icons.visibility_outlined), findsNWidgets(2));
    expect(find.byKey(const Key('guest-badge-editor')), findsNothing);
    for (final actor in ['self', 'guest']) {
      final badge = find.byKey(Key('guest-badge-$actor'));
      final dot = find.byKey(Key('participant-online-dot-$actor'));
      expect(dot, findsOneWidget);
      expect(tester.getRect(badge).overlaps(tester.getRect(dot)), isFalse);
      expect(
        find.descendant(
          of: find.byKey(Key('participant-$actor')),
          matching: badge,
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: badge,
          matching: find.byIcon(Icons.visibility_outlined),
        ),
        findsOneWidget,
      );
    }
    final glow = find.byKey(const Key('self-participant-glow'));
    expect(glow, findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('participant-self')),
        matching: glow,
      ),
      findsOneWidget,
    );
    for (final actor in ['editor', 'self', 'guest']) {
      final target = find.byKey(Key('participant-$actor'));
      final data = tester.getSemantics(target).getSemanticsData();
      expect(data.hasAction(SemanticsAction.tap), isFalse);
      expect(data.flagsCollection.isButton, isFalse);
      expect(data.hint, isEmpty);
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pump();
      expect(find.text('Сделать редактором?'), findsNothing);
      expect(find.byType(ParticipantNameDialog), findsNothing);
    }
    expect(session.promotions, isEmpty);
    expect(tester.takeException(), isNull);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final input in ['', '   ']) {
    testWidgets('blank name prompt returns canonical empty alias ($input)', (
      tester,
    ) async {
      final results = <Object?>[];
      await _showDialog(
        tester,
        const ParticipantNameDialog(),
        onResult: results.add,
      );
      expect(find.textContaining('Имя необязательно'), findsNothing);
      final field = tester.widget<TextField>(
        find.byKey(const Key('participant-name')),
      );
      expect(field.decoration!.labelText, 'Ваше имя');
      expect(field.decoration!.hintText, 'Аноним');
      await tester.enterText(find.byKey(const Key('participant-name')), input);
      await tester.tap(find.text('Продолжить'));
      await tester.pumpAndSettle();
      expect(results, ['']);
      expect(find.byType(ParticipantNameDialog), findsNothing);
      await _showDialog(
        tester,
        const ParticipantNameDialog(),
        onResult: results.add,
      );
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(results, ['', null]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('own-name save can clear an existing alias to canonical blank', (
    tester,
  ) async {
    final names = <String>[];
    await _showDialog(
      tester,
      ParticipantNameDialog(
        initialName: 'Мария',
        onSave: (name) async => names.add(name),
      ),
    );
    final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
    expect((dialog.title! as Text).data, 'Изменить моё имя');
    final content = dialog.content! as Column;
    expect(content.children, [isA<TextField>()]);
    final field = tester.widget<TextField>(
      find.byKey(const Key('participant-name')),
    );
    expect(field.decoration!.labelText, 'Ваше имя');
    expect(field.decoration!.hintText, 'Аноним');
    expect(field.decoration!.helperText, isNull);
    expect(find.textContaining('Имя необязательно'), findsNothing);
    expect(find.textContaining('Это я:'), findsNothing);
    expect(find.byType(Tooltip), findsNothing);
    expect(find.byKey(const Key('participant-unbind')), findsNothing);
    expect(find.text('Отмена'), findsOneWidget);
    expect(find.text('Сохранить'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('participant-name')), '   ');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(names, ['']);
    expect(find.byType(ParticipantNameDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (description, input) in [
    ('newline', 'Имя\nФамилия'),
    ('control', 'Имя\u0001'),
    ('too long', 'я' * 65),
  ]) {
    testWidgets('optional name still rejects $description on submit', (
      tester,
    ) async {
      final names = <String>[];
      await _showDialog(
        tester,
        ParticipantNameDialog(onSave: (name) async => names.add(name)),
      );
      final field = find.byKey(const Key('participant-name'));
      // Bypass input formatters to exercise validation at the submit boundary.
      tester.widget<TextField>(field).controller!.text = input;
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(names, isEmpty);
      expect(find.textContaining('До 64 символов'), findsOneWidget);
      expect(find.byType(ParticipantNameDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'own-name unbind awaits durability, blocks dismissal and preserves draft',
    (tester) async {
      const boundFullName = 'Анна Васильевна Иванова';
      final saving = Completer<void>();
      final bound = ValueNotifier<bool>(true);
      addTearDown(bound.dispose);
      final names = <String>[];
      var unbinds = 0;
      await _showDialog(
        tester,
        ValueListenableBuilder<bool>(
          valueListenable: bound,
          builder: (_, isBound, _) => ParticipantNameDialog(
            initialName: 'Сохранённое имя',
            boundPersonName: isBound ? boundFullName : null,
            onSave: (name) async => names.add(name),
            onUnbind: isBound
                ? () async {
                    unbinds++;
                    await saving.future;
                    bound.value = false;
                  }
                : null,
          ),
        ),
      );
      final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
      expect((dialog.title! as Text).data, 'Изменить моё имя');
      final content = dialog.content! as Column;
      expect(content.children, [
        isA<TextField>(),
        isA<SizedBox>(),
        isA<Tooltip>(),
      ]);
      final field = find.byKey(const Key('participant-name'));
      final input = tester.widget<TextField>(field);
      expect(input.decoration!.labelText, 'Ваше имя');
      expect(input.decoration!.hintText, 'Аноним');
      expect(input.decoration!.helperText, isNull);
      expect(find.textContaining('Это я:'), findsNothing);
      expect(find.textContaining('Имя необязательно'), findsNothing);
      expect(find.textContaining('только это устройство'), findsNothing);
      expect(find.textContaining('других'), findsNothing);
      expect(find.text(boundFullName), findsNothing);
      final tooltip = find.byTooltip(boundFullName);
      final unbindButton = find.byKey(const Key('participant-unbind'));
      expect(tooltip, findsOneWidget);
      expect(tester.widget<Tooltip>(tooltip).excludeFromSemantics, isTrue);
      expect(
        find.descendant(of: tooltip, matching: unbindButton),
        findsOneWidget,
      );
      expect(find.text('Отменить «Это я»'), findsOneWidget);
      expect(
        tester.getTopLeft(field).dy,
        lessThan(tester.getTopLeft(unbindButton).dy),
      );
      await tester.enterText(field, 'Несохранённый псевдоним');
      final save = tester
          .widget<FilledButton>(find.byType(FilledButton))
          .onPressed!;
      final unbind = tester
          .widget<TextButton>(find.byKey(const Key('participant-unbind')))
          .onPressed!;
      unbind();
      unbind();
      save();
      await tester.pump();
      expect(unbinds, 1);
      expect(names, isEmpty);
      expect(bound.value, isTrue);
      expect(tester.widget<TextField>(field).enabled, isFalse);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('participant-unbind')))
            .onPressed,
        isNull,
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Отмена'))
            .onPressed,
        isNull,
      );
      await tester.tapAt(const Offset(8, 8));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(ParticipantNameDialog), findsOneWidget);
      saving.complete();
      await tester.pumpAndSettle();
      expect(bound.value, isFalse);
      expect(find.byType(ParticipantNameDialog), findsOneWidget);
      expect(find.byKey(const Key('participant-unbind')), findsNothing);
      expect(find.byTooltip(boundFullName), findsNothing);
      expect(find.textContaining('Это я:'), findsNothing);
      expect(
        tester.widget<TextField>(field).controller!.text,
        'Несохранённый псевдоним',
      );
      expect(tester.widget<TextField>(field).enabled, isTrue);
      expect(names, isEmpty);
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(names, ['Несохранённый псевдоним']);
      expect(find.byType(ParticipantNameDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed unbind keeps error and input through rebuild, then retries',
    (tester) async {
      final rebuild = ValueNotifier<int>(0);
      addTearDown(rebuild.dispose);
      var fail = true;
      var unbinds = 0;
      final names = <String>[];
      await _showDialog(
        tester,
        ValueListenableBuilder<int>(
          valueListenable: rebuild,
          builder: (_, _, _) => ParticipantNameDialog(
            initialName: 'Сохранённое имя',
            boundPersonName: 'Анна Иванова',
            onSave: (name) async => names.add(name),
            onUnbind: () async {
              unbinds++;
              if (fail) throw StateError('profile unavailable');
            },
          ),
        ),
      );
      final field = find.byKey(const Key('participant-name'));
      final unbind = find.byKey(const Key('participant-unbind'));
      await tester.enterText(field, 'Черновик');
      await tester.tap(unbind);
      await tester.pumpAndSettle();
      expect(find.textContaining('Не удалось отменить связь:'), findsOneWidget);
      expect(find.textContaining('profile unavailable'), findsOneWidget);
      expect(find.byType(ParticipantNameDialog), findsOneWidget);
      expect(tester.widget<TextField>(field).controller!.text, 'Черновик');
      expect(tester.widget<TextField>(field).enabled, isTrue);
      rebuild.value++;
      await tester.pump(const Duration(seconds: 2));
      expect(find.textContaining('profile unavailable'), findsOneWidget);
      expect(tester.widget<TextField>(field).controller!.text, 'Черновик');
      fail = false;
      await tester.tap(unbind);
      await tester.pumpAndSettle();
      expect(unbinds, 2);
      expect(names, isEmpty);
      expect(find.textContaining('Не удалось отменить связь:'), findsNothing);
      expect(find.byType(ParticipantNameDialog), findsOneWidget);
      expect(tester.widget<TextField>(field).controller!.text, 'Черновик');
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(names, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'own-name dialog awaits save and blocks duplicate save or dismissal',
    (tester) async {
      final saving = Completer<void>();
      final names = <String>[];
      await _showDialog(
        tester,
        ParticipantNameDialog(
          initialName: 'Мария',
          onSave: (name) {
            names.add(name);
            return saving.future;
          },
        ),
      );
      expect(find.text('Изменить моё имя'), findsOneWidget);
      expect(find.text('Как вас зовут?'), findsNothing);
      expect(find.text('Продолжить'), findsNothing);
      final field = find.byKey(const Key('participant-name'));
      expect(tester.widget<TextField>(field).controller!.text, 'Мария');
      tester.widget<TextField>(field).controller!.text = 'Имя\nФамилия';
      await tester.tap(find.text('Сохранить'));
      await tester.pump();
      expect(find.textContaining('До 64 символов'), findsOneWidget);
      expect(names, isEmpty);
      await tester.enterText(field, '  Новое имя  ');
      final save = tester
          .widget<FilledButton>(find.byType(FilledButton))
          .onPressed!;
      save();
      save();
      await tester.pump();
      expect(names, ['Новое имя']);
      expect(find.byType(ParticipantNameDialog), findsOneWidget);
      expect(tester.widget<TextField>(field).enabled, isFalse);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Отмена'))
            .onPressed,
        isNull,
      );
      await tester.tapAt(const Offset(8, 8));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(ParticipantNameDialog), findsOneWidget);
      saving.complete();
      await tester.pumpAndSettle();
      expect(find.byType(ParticipantNameDialog), findsNothing);
      expect(names, ['Новое имя']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed own-name dialog save retains input and allows retry or cancel',
    (tester) async {
      var fail = true;
      final names = <String>[];
      final dialog = ParticipantNameDialog(
        initialName: 'Мария',
        onSave: (name) async {
          names.add(name);
          if (fail) throw StateError('profile unavailable');
        },
      );
      await _showDialog(tester, dialog);
      final field = find.byKey(const Key('participant-name'));
      await tester.enterText(field, 'Анна');
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(find.textContaining('profile unavailable'), findsOneWidget);
      expect(find.byType(ParticipantNameDialog), findsOneWidget);
      expect(tester.widget<TextField>(field).controller!.text, 'Анна');
      await tester.pump(const Duration(seconds: 2));
      expect(find.textContaining('profile unavailable'), findsOneWidget);
      expect(tester.widget<TextField>(field).enabled, isNot(false));
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Сохранить'),
            )
            .onPressed,
        isNotNull,
      );
      fail = false;
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(names, ['Анна', 'Анна']);
      expect(find.byType(ParticipantNameDialog), findsNothing);
      await _showDialog(tester, dialog);
      expect(tester.widget<TextField>(field).controller!.text, 'Мария');
      await tester.enterText(field, 'Не сохранять');
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(find.byType(ParticipantNameDialog), findsNothing);
      expect(names, ['Анна', 'Анна']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(390, 300),
  ]) {
    testWidgets('participant panel is bounded and scrolls at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = _DialogSession();
      addTearDown(session.dispose);
      session.roster = [
        for (var i = 0; i < 28; i++)
          _person(
            'actor-$i',
            'Участник с длинным именем $i',
            online: i % 3 == 0,
            self: i == 0,
            role: i < 14 ? RoomRole.editor : RoomRole.guest,
          ),
      ];
      await _showDialog(tester, RoomParticipantsDialog(session: session));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('participants-list')), findsOneWidget);
      expect(_participantOrder(tester), hasLength(28));
      final footer = find.text('Пригласить участников');
      expect(footer.hitTestable(), findsOneWidget);
      final panel = tester.getRect(find.byType(Material).last);
      expect(panel.left, greaterThanOrEqualTo(0));
      expect(panel.right, lessThanOrEqualTo(size.width));
      expect(panel.bottom, lessThanOrEqualTo(size.height));
      await tester.scrollUntilVisible(
        find.byKey(const Key('participant-actor-27')),
        160,
        scrollable: find.descendant(
          of: find.byKey(const Key('participants-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('participant-actor-27')).hitTestable(),
        findsOneWidget,
      );
      expect(footer.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('new dialogs remain usable in a short mobile viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = _DialogSession();
    addTearDown(session.dispose);
    session.edits = [
      for (var i = 0; i < 20; i++)
        RoomEdit(
          id: 'edit-$i',
          author: 'self',
          clock: i,
          createdAt: i,
          text: 'Длинная запись журнала $i',
        ),
    ];
    for (final dialog in [
      const ParticipantNameDialog(),
      ParticipantNameDialog(initialName: 'Мария', onSave: (_) async {}),
      RoomSettingsDialog(session: session),
      RoomChangesDialog(session: session),
    ]) {
      await _showDialog(tester, dialog);
      expect(tester.takeException(), isNull);
      final close = dialog is RoomChangesDialog
          ? find.text('Закрыть')
          : find.text('Отмена');
      expect(close.hitTestable(), findsOneWidget);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets(
    'participants invite footer respects readiness and updates live',
    (tester) async {
      final session = _DialogSession()..ready = false;
      session.roster = [_person('self', 'Анна', self: true)];
      addTearDown(session.dispose);
      await _showDialog(tester, RoomParticipantsDialog(session: session));
      final invite = find.widgetWithText(
        OutlinedButton,
        'Пригласить участников',
      );
      expect(tester.widget<OutlinedButton>(invite).onPressed, isNull);
      session.ready = true;
      session.updateRoster(session.roster);
      await tester.pump();
      expect(tester.widget<OutlinedButton>(invite).onPressed, isNotNull);
      await tester.tap(invite);
      await tester.pumpAndSettle();
      expect(find.byType(RoomParticipantsDialog), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('room settings validates, retains real save errors and retries', (
    tester,
  ) async {
    final session = _DialogSession();
    addTearDown(session.dispose);
    await _showDialog(tester, RoomSettingsDialog(session: session));
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byKey(const Key('room-name')), '  ');
    await tester.tap(find.text('Сохранить'));
    await tester.pump();
    expect(find.textContaining('Укажите название'), findsOneWidget);
    expect(session.title, 'Семейная комната');
    session.renameError = StateError('disk unavailable');
    await tester.enterText(find.byKey(const Key('room-name')), '  Новый дом  ');
    await tester.tap(find.text('Сохранить'));
    await tester.pump();
    expect(
      find.textContaining('Не удалось сохранить название'),
      findsOneWidget,
    );
    expect(find.byType(RoomSettingsDialog), findsOneWidget);
    session.renameError = null;
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(session.title, 'Новый дом');
    expect(find.byType(RoomSettingsDialog), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('guest settings are read-only and react to a durable promotion', (
    tester,
  ) async {
    final session = _DialogSession(role: RoomRole.guest);
    addTearDown(session.dispose);
    await _showDialog(tester, RoomSettingsDialog(session: session));
    final field = find.byKey(const Key('room-name'));
    expect(tester.widget<TextField>(field).controller!.text, session.title);
    expect(tester.widget<TextField>(field).readOnly, isTrue);
    expect(tester.widget<TextField>(field).onSubmitted, isNull);
    expect(find.text('Доступ только для просмотра'), findsOneWidget);
    expect(find.text('Сохранить'), findsNothing);
    expect(find.text('Закрыть').hitTestable(), findsOneWidget);
    session.role = RoomRole.editor;
    session.updateRoster(session.roster);
    await tester.pump();
    expect(tester.widget<TextField>(field).readOnly, isFalse);
    expect(find.text('Доступ только для просмотра'), findsNothing);
    await tester.enterText(field, 'Новый дом');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(session.title, 'Новый дом');
    expect(find.byType(RoomSettingsDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'Disk connect expands a private token field and requires consent',
    (tester) async {
      final session = _DialogSession();
      addTearDown(session.dispose);
      await _showDialog(tester, RoomSettingsDialog(session: session));
      expect(find.text('Яндекс Диск'), findsOneWidget);
      expect(find.text('Не подключён'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      await tester.tap(find.byKey(const Key('disk-connect-expand')));
      await tester.pumpAndSettle();
      final tokenField = find.byKey(const Key('disk-token'));
      final field = tester.widget<TextField>(tokenField);
      expect(field.decoration!.labelText, 'OAuth-токен');
      expect(field.obscureText, isTrue);
      expect(field.enableSuggestions, isFalse);
      expect(field.autocorrect, isFalse);
      await tester.tap(find.byKey(const Key('disk-connect')));
      await tester.pumpAndSettle();
      expect(find.text('Укажите OAuth-токен.'), findsOneWidget);
      expect(session.connectCalls, 0);
      await tester.enterText(tokenField, '  test-ui-token  ');
      await tester.tap(find.byKey(const Key('disk-connect')));
      await tester.pumpAndSettle();
      expect(find.text('Подключить Яндекс Диск?'), findsOneWidget);
      expect(
        find.text(
          'Доступ к папке приложения будет общим для редакторов комнаты, '
          'но не для гостей.',
        ),
        findsOneWidget,
      );
      expect(session.connectCalls, 0);
      await tester.tap(find.widgetWithText(TextButton, 'Отмена').last);
      await tester.pumpAndSettle();
      expect(session.connectCalls, 0);
      expect(tester.widget<TextField>(tokenField).controller!.text, isNotEmpty);
      await tester.tap(find.byKey(const Key('disk-connect')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Подключить').last);
      await tester.pumpAndSettle();
      expect(session.connectCalls, 1);
      expect(session.connectedToken, 'test-ui-token');
      expect(find.byType(RoomSettingsDialog), findsOneWidget);
      expect(find.text('Подключён'), findsOneWidget);
      expect(tokenField, findsNothing);
      expect(find.byKey(const Key('disk-sync')), findsOneWidget);
      expect(find.byKey(const Key('disk-disconnect')), findsOneWidget);
      session.binding = null;
      session.updateRoster(session.roster);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('disk-connect-expand')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(tokenField).controller!.text, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Disk connect errors stay separate from rename errors and retry',
    (tester) async {
      final session = _DialogSession()
        ..connectError = StateError('test-ui-token must not be displayed');
      addTearDown(session.dispose);
      await _showDialog(tester, RoomSettingsDialog(session: session));
      await tester.enterText(find.byKey(const Key('room-name')), '');
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('disk-connect-expand')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('disk-token')),
        'test-ui-token',
      );
      await tester.tap(find.byKey(const Key('disk-connect')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Подключить').last);
      await tester.pumpAndSettle();
      expect(find.text('Не удалось подключить Яндекс Диск.'), findsOneWidget);
      expect(find.textContaining('Укажите название'), findsOneWidget);
      expect(find.textContaining('must not be displayed'), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('room-name')))
            .decoration!
            .errorText,
        startsWith('Укажите название'),
      );
      session.connectError = null;
      await tester.tap(find.byKey(const Key('disk-connect')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Подключить').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('disk-error')), findsNothing);
      expect(find.textContaining('Укажите название'), findsOneWidget);
      expect(session.connectCalls, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Disk pending connect disables edits, commands and dismissal', (
    tester,
  ) async {
    final save = Completer<void>();
    final session = _DialogSession()..connectSave = save;
    addTearDown(session.dispose);
    await _showDialog(tester, RoomSettingsDialog(session: session));
    await tester.tap(find.byKey(const Key('disk-connect-expand')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('disk-token')),
      'test-ui-token',
    );
    await tester.tap(find.byKey(const Key('disk-connect')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Подключить').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(session.connectCalls, 1);
    expect(find.byKey(const Key('disk-progress')), findsOneWidget);
    for (final key in ['room-name', 'disk-token']) {
      expect(tester.widget<TextField>(find.byKey(Key(key))).enabled, isFalse);
    }
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('disk-connect')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Сохранить'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Отмена'))
          .onPressed,
      isNull,
    );
    await tester.tapAt(const Offset(4, 4));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(RoomSettingsDialog), findsOneWidget);
    save.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('disk-progress')), findsNothing);
    expect(find.text('Подключён'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Disk status and actions follow live roles and ownership', (
    tester,
  ) async {
    final session = _DialogSession(role: RoomRole.guest);
    addTearDown(session.dispose);
    await _showDialog(tester, RoomSettingsDialog(session: session));
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byKey(const Key('disk-connect-expand')), findsNothing);
    expect(find.byKey(const Key('disk-token')), findsNothing);
    session.binding = _diskBinding(owner: 'other-editor');
    session.diskStatus = 'Ожидает синхронизации';
    session.diskError = 'Диск недоступен. Повторите позже.';
    session.updateRoster(session.roster);
    await tester.pumpAndSettle();
    expect(find.text('Ожидает синхронизации'), findsOneWidget);
    expect(find.text('Диск недоступен. Повторите позже.'), findsOneWidget);
    expect(find.byKey(const Key('disk-sync')), findsNothing);
    expect(find.byKey(const Key('disk-disconnect')), findsNothing);
    session.role = RoomRole.editor;
    session.updateRoster(session.roster);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('disk-connect-expand')), findsNothing);
    expect(find.byKey(const Key('disk-sync')), findsOneWidget);
    expect(find.byKey(const Key('disk-disconnect')), findsNothing);
    session.diskError = null;
    await tester.tap(find.byKey(const Key('disk-sync')));
    await tester.pumpAndSettle();
    expect(session.syncCalls, 1);
    expect(find.text('Синхронизировано'), findsOneWidget);
    expect(find.byKey(const Key('disk-error')), findsNothing);
    session.binding = _diskBinding();
    session.updateRoster(session.roster);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('disk-disconnect')), findsOneWidget);
    session.role = RoomRole.guest;
    session.updateRoster(session.roster);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('disk-sync')), findsNothing);
    expect(find.byKey(const Key('disk-disconnect')), findsNothing);
    expect(find.text('Закрыть'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'Disk unlink requires owner confirmation, retains errors and retries',
    (tester) async {
      final session = _DialogSession()
        ..binding = _diskBinding()
        ..disconnectError = StateError('test-ui-token must not be displayed');
      addTearDown(session.dispose);
      await _showDialog(tester, RoomSettingsDialog(session: session));
      await tester.tap(find.byKey(const Key('disk-disconnect')));
      await tester.pumpAndSettle();
      expect(find.text('Отвязать Яндекс Диск?'), findsOneWidget);
      expect(find.text('Файлы на Диске сохранятся.'), findsOneWidget);
      expect(session.disconnectCalls, 0);
      await tester.tap(find.widgetWithText(TextButton, 'Отмена').last);
      await tester.pumpAndSettle();
      expect(session.disconnectCalls, 0);
      await tester.tap(find.byKey(const Key('disk-disconnect')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отвязать'));
      await tester.pumpAndSettle();
      expect(session.disconnectCalls, 1);
      expect(find.text('Не удалось отвязать Яндекс Диск.'), findsOneWidget);
      expect(find.textContaining('must not be displayed'), findsNothing);
      expect(session.binding, isNotNull);
      session.disconnectError = null;
      await tester.tap(find.byKey(const Key('disk-disconnect')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отвязать'));
      await tester.pumpAndSettle();
      expect(session.binding, isNull);
      expect(find.text('Не подключён'), findsOneWidget);
      expect(find.byKey(const Key('disk-error')), findsNothing);
      expect(find.byKey(const Key('disk-connect-expand')), findsOneWidget);
      expect(find.byType(RoomSettingsDialog), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Disk commands recheck live permissions and binding after consent',
    (tester) async {
      final session = _DialogSession();
      addTearDown(session.dispose);
      await _showDialog(tester, RoomSettingsDialog(session: session));
      await tester.tap(find.byKey(const Key('disk-connect-expand')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('disk-token')),
        'test-ui-token',
      );
      await tester.tap(find.byKey(const Key('disk-connect')));
      await tester.pumpAndSettle();
      session.role = RoomRole.guest;
      session.updateRoster(session.roster);
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Подключить').last);
      await tester.pumpAndSettle();
      expect(session.connectCalls, 0);
      expect(find.byKey(const Key('disk-token')), findsNothing);
      session.role = RoomRole.editor;
      session.binding = _diskBinding();
      session.updateRoster(session.roster);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('disk-disconnect')));
      await tester.pumpAndSettle();
      session.binding = _diskBinding(id: 'replacement');
      session.updateRoster(session.roster);
      await tester.pump();
      await tester.tap(find.text('Отвязать'));
      await tester.pumpAndSettle();
      expect(session.disconnectCalls, 0);
      expect(session.binding!.id, 'replacement');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Disk sync failure is safe, retry remains pending until completed',
    (tester) async {
      final session = _DialogSession()
        ..binding = _diskBinding(owner: 'other-editor')
        ..syncError = StateError('test-ui-token must not be displayed');
      addTearDown(session.dispose);
      await _showDialog(tester, RoomSettingsDialog(session: session));
      await tester.tap(find.byKey(const Key('disk-sync')));
      await tester.pumpAndSettle();
      expect(
        find.text('Не удалось синхронизировать с Диском.'),
        findsOneWidget,
      );
      expect(find.textContaining('must not be displayed'), findsNothing);
      final save = Completer<void>();
      session.syncError = null;
      session.syncSave = save;
      await tester.tap(find.byKey(const Key('disk-sync')));
      await tester.pump();
      expect(
        tester.widget<TextButton>(find.byKey(const Key('disk-sync'))).onPressed,
        isNull,
      );
      expect(find.text('Не удалось синхронизировать с Диском.'), findsNothing);
      expect(find.text('Синхронизировано'), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(RoomSettingsDialog), findsOneWidget);
      save.complete();
      await tester.pumpAndSettle();
      expect(session.syncCalls, 2);
      expect(find.text('Синхронизировано'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'background Disk work allows closing and renaming; local saves guard commands',
    (tester) async {
      final session = _DialogSession()..binding = _diskBinding();
      addTearDown(session.dispose);
      await _showDialog(tester, RoomSettingsDialog(session: session));
      session.diskBusy = true;
      session.updateRoster(session.roster);
      await tester.pump();
      expect(
        tester.widget<TextButton>(find.byKey(const Key('disk-sync'))).onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('disk-disconnect')))
            .onPressed,
        isNotNull,
      );
      expect(
        tester.widget<TextField>(find.byKey(const Key('room-name'))).enabled,
        isTrue,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(RoomSettingsDialog), findsNothing);
      session.diskBusy = false;
      session.updateRoster(session.roster);
      await _showDialog(tester, RoomSettingsDialog(session: session));
      final save = Completer<void>();
      session.renameSave = save;
      await tester.tap(find.text('Сохранить'));
      await tester.pump();
      for (final key in ['disk-sync', 'disk-disconnect']) {
        expect(
          tester.widget<TextButton>(find.byKey(Key(key))).onPressed,
          isNull,
        );
      }
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(RoomSettingsDialog), findsOneWidget);
      save.complete();
      await tester.pumpAndSettle();
      expect(find.byType(RoomSettingsDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'history is separate, newest first, includes metadata and updates live',
    (tester) async {
      final session = _DialogSession();
      addTearDown(session.dispose);
      session.roster = [_person('self', 'Анна', self: true)];
      await _showDialog(tester, RoomChangesDialog(session: session));
      expect(find.text('Изменений пока нет'), findsOneWidget);
      session.edits = [
        const RoomEdit(
          id: 'name',
          author: 'self',
          clock: 1,
          createdAt: 1,
          text: 'Анна',
          kind: RoomEditKind.participantName,
        ),
        const RoomEdit(
          id: 'text',
          author: 'self',
          clock: 2,
          createdAt: 2,
          text: 'Первая запись',
        ),
        const RoomEdit(
          id: 'title',
          author: 'self',
          clock: 3,
          createdAt: 3,
          text: 'Наш дом',
          kind: RoomEditKind.roomName,
        ),
      ];
      session.updateRoster(session.roster);
      await tester.pump();
      expect(find.text('Название комнаты'), findsOneWidget);
      expect(find.text('Изменён текст'), findsOneWidget);
      expect(find.text('Имя участника'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Наш дом')).dy,
        lessThan(tester.getTopLeft(find.text('Первая запись')).dy),
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Пригласить участников'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Disk journal uses readable labels without binding payloads', (
    tester,
  ) async {
    final session = _DialogSession();
    addTearDown(session.dispose);
    final connectPayload = jsonEncode({'v': 1, 'action': 'connect'});
    final disconnectPayload = jsonEncode({
      'v': 1,
      'action': 'disconnect',
      'bindingId': 'binding-identity-not-for-display',
    });
    session.edits = [
      RoomEdit(
        id: 'disk-connect',
        author: 'self',
        clock: 1,
        createdAt: 1,
        kind: RoomEditKind.diskConnection,
        text: connectPayload,
      ),
      RoomEdit(
        id: 'disk-disconnect',
        author: 'self',
        clock: 2,
        createdAt: 2,
        kind: RoomEditKind.diskConnection,
        text: disconnectPayload,
      ),
    ];
    await _showDialog(tester, RoomChangesDialog(session: session));
    expect(find.text('Яндекс Диск'), findsNWidgets(2));
    expect(find.text('Яндекс Диск подключён'), findsOneWidget);
    expect(find.text('Яндекс Диск отвязан'), findsOneWidget);
    expect(find.text(connectPayload), findsNothing);
    expect(find.text(disconnectPayload), findsNothing);
    expect(
      find.textContaining('binding-identity-not-for-display'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('journal displays a UTC instant in local time and locale', (
    tester,
  ) async {
    final instant = DateTime.utc(2025, 10, 26, 0, 35);
    final session = _DialogSession();
    addTearDown(session.dispose);
    session.roster = [_person('self', 'Анна', self: true)];
    session.edits = [
      RoomEdit(
        id: 'utc-instant',
        author: 'self',
        clock: 1,
        createdAt: instant.millisecondsSinceEpoch,
        text: 'UTC journal entry',
      ),
    ];
    await _showDialog(tester, RoomChangesDialog(session: session));
    final context = tester.element(find.byType(RoomChangesDialog));
    final localizations = MaterialLocalizations.of(context);
    final local = instant.toLocal();
    final expected =
        'Анна · ${localizations.formatShortDate(local)} '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
    expect(find.text(expected), findsOneWidget);
    expect(session.edits.single.createdAt, instant.millisecondsSinceEpoch);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'tree journal squashes only consecutive same-person same-field same-author edits',
    (tester) async {
      final session = _DialogSession();
      addTearDown(session.dispose);
      RoomEdit treeEdit(int index, String person, String author) => RoomEdit(
        id: 'tree-$index',
        author: author,
        clock: index,
        createdAt: index,
        kind: RoomEditKind.tree,
        text: jsonEncode({
          ...TreeDocument().editText('root', TreeTextField.name, 'a')!.toJson(),
          'personId': person,
        }),
      );
      session.edits = [
        treeEdit(1, 'root', 'self'),
        treeEdit(2, 'root', 'self'),
        treeEdit(3, 'other', 'self'),
        treeEdit(4, 'other', 'another'),
      ];
      await _showDialog(tester, RoomChangesDialog(session: session));
      expect(find.text('Изменено имя'), findsNWidgets(3));
      expect(session.edits, hasLength(4));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'role journal identifies the promoted participant, not the author',
    (tester) async {
      final session = _DialogSession();
      addTearDown(session.dispose);
      session.roster = [
        _person('self', 'Анна', self: true),
        _person('guest', 'Иван'),
      ];
      session.edits = const [
        RoomEdit(
          id: 'promotion',
          author: 'self',
          clock: 3,
          createdAt: 3,
          text: 'editor',
          kind: RoomEditKind.participantRole,
          targetActor: 'guest',
        ),
      ];
      await _showDialog(tester, RoomChangesDialog(session: session));
      expect(find.text('Роль участника'), findsOneWidget);
      expect(find.text('Иван: Редактор'), findsOneWidget);
      expect(find.textContaining('Анна ·'), findsOneWidget);
      expect(find.text('Анна: Редактор'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
