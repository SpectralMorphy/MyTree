import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/room_identity.dart';
import 'package:mytree_webrtc_demo/ui/room_dialogs.dart';
import 'package:qr_flutter/qr_flutter.dart';

const _room = '0123456789abcdef0123456789abcdef';
const _binding = 'invitation-binding';
const _token = 'synthetic-invitation-token';
final _editor = RoomDiskAccess.editor(bindingId: _binding, token: _token);
final _guest = RoomDiskAccess.guest(
  bindingId: _binding,
  publicUrl: 'https://disk.yandex.ru/d/synthetic-invitation',
);

class _Harness {
  final copied = <String>[];
  final messages = <String>[];
  bool failClipboard = false;

  Future<void> show(
    WidgetTester tester,
    PrepareRoomDiskAccess prepare, {
    bool editor = true,
    bool publish = true,
    bool native = false,
  }) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          if (failClipboard) throw PlatformException(code: 'unavailable');
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => InviteParticipantsDialog(
                  roomId: _room,
                  applicationUri: Uri.parse(
                    native ? 'file:///app/' : 'https://tree.example/MyTree/',
                  ),
                  canInviteEditors: editor,
                  canPublishDiskAccess: publish,
                  prepareDiskAccess: prepare,
                  onMessage: messages.add,
                ),
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
}

Future<void> _tap(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).last);
  await tester.tap(find.text(text).last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void _noPlainSecret(WidgetTester tester) {
  for (final widget in tester.widgetList<Text>(find.byType(Text))) {
    expect(
      widget.data ?? widget.textSpan?.toPlainText() ?? '',
      isNot(contains(_token)),
    );
  }
  for (final widget in tester.widgetList<SelectableText>(
    find.byType(SelectableText),
  )) {
    expect(widget.data ?? '', isNot(contains(_token)));
  }
  expect(find.byKey(const Key('room-link')), findsNothing);
}

Future<void> _expectQr(WidgetTester tester, String payload) async {
  final qr = find.byType(QrImageView);
  final image = tester.widget<QrImageView>(qr);
  final paint = tester.widget<CustomPaint>(
    find.descendant(
      of: qr,
      matching: find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is QrPainter,
      ),
    ),
  );
  final actual = paint.painter! as QrPainter;
  final expected = QrPainter(
    data: payload,
    version: image.version,
    errorCorrectionLevel: image.errorCorrectionLevel,
    gapless: image.gapless,
    eyeStyle: image.eyeStyle,
    dataModuleStyle: image.dataModuleStyle,
  );
  await tester.runAsync(() async {
    final actualBytes = await actual.toImageData(240);
    final expectedBytes = await expected.toImageData(240);
    expect(
      actualBytes!.buffer.asUint8List(),
      orderedEquals(expectedBytes!.buffer.asUint8List()),
    );
  });
}

void main() {
  testWidgets(
    'editor sharing is explicit and cancel does not read or copy access',
    (tester) async {
      final harness = _Harness();
      var calls = 0;
      await harness.show(tester, (role, {required allowPublication}) async {
        calls++;
        return _editor;
      });
      await _tap(tester, 'Редактор');
      await _tap(tester, 'Скопировать URL');
      expect(find.text('Передать доступ редактору?'), findsOneWidget);
      expect(calls, 0);
      _noPlainSecret(tester);
      await _tap(tester, 'Отмена');
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(harness.copied, isEmpty);
      await _tap(tester, 'Скопировать URL');
      await _tap(tester, 'Передать');
      await tester.pumpAndSettle();
      expect(calls, 1);
      final invitation = parseRoomInvitation(harness.copied.single)!;
      expect(
        invitation,
        RoomInvitation(_room, role: RoomRole.editor, diskAccess: _editor),
      );
      expect(Uri.parse(harness.copied.single).query, isEmpty);
      _noPlainSecret(tester);
      await _tap(tester, 'Скопировать код');
      await tester.pumpAndSettle();
      expect(parseRoomInvitation(harness.copied.last), invitation);
      expect(find.text('Передать доступ редактору?'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'guest publication requires consent and code contains only public access',
    (tester) async {
      final harness = _Harness();
      final calls = <bool>[];
      await harness.show(tester, (role, {required allowPublication}) async {
        expect(role, RoomRole.guest);
        calls.add(allowPublication);
        return allowPublication ? _guest : null;
      });
      await _tap(tester, 'Скопировать код');
      expect(calls, [false]);
      expect(find.text('Разрешить гостям доступ к Диску?'), findsOneWidget);
      expect(find.textContaining('включая удалённые записи'), findsOneWidget);
      expect(harness.copied, isEmpty);
      await _tap(tester, 'Отмена');
      await tester.pumpAndSettle();
      expect(calls, [false]);
      await _tap(tester, 'Скопировать код');
      await _tap(tester, 'Разрешить');
      await tester.pumpAndSettle();
      expect(calls, [false, false, true]);
      expect(
        parseRoomInvitation(harness.copied.single),
        RoomInvitation(_room, diskAccess: _guest),
      );
      expect(harness.copied.single, isNot(contains('token')));
      _noPlainSecret(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'existing guest public access needs no publication or editor confirmation',
    (tester) async {
      final harness = _Harness();
      final calls = <bool>[];
      await harness.show(
        tester,
        (role, {required allowPublication}) async {
          calls.add(allowPublication);
          return _guest;
        },
        editor: false,
        publish: false,
      );
      await _tap(tester, 'Редактор');
      expect(
        tester
            .widget<SegmentedButton<RoomRole>>(
              find.byKey(const Key('invitation-role')),
            )
            .selected,
        {RoomRole.guest},
      );
      await _tap(tester, 'Скопировать URL');
      await tester.pumpAndSettle();
      expect(calls, [false]);
      expect(find.text('Разрешить гостям доступ к Диску?'), findsNothing);
      expect(
        parseRoomInvitation(harness.copied.single),
        RoomInvitation(_room, diskAccess: _guest),
      );
      expect(harness.copied.single, isNot(contains(_token)));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final native in [false, true]) {
    testWidgets('guest QR contains exact public invitation, native=$native', (
      tester,
    ) async {
      final harness = _Harness();
      await harness.show(
        tester,
        (role, {required allowPublication}) async => _guest,
        native: native,
      );
      await _tap(tester, 'Показать QR');
      await tester.pumpAndSettle();
      await _expectQr(
        tester,
        createRoomQrData(
          Uri.parse(native ? 'file:///app/' : 'https://tree.example/MyTree/'),
          _room,
          role: RoomRole.guest,
          diskAccess: _guest,
        ),
      );
      expect(find.text('QR · Гость'), findsOneWidget);
      await _tap(tester, 'Закрыть');
      expect(find.byType(InviteParticipantsDialog), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('editor QR shares the selected token only after confirmation', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.show(
      tester,
      (role, {required allowPublication}) async => _editor,
    );
    await _tap(tester, 'Редактор');
    await _tap(tester, 'Показать QR');
    expect(find.byType(QrImageView), findsNothing);
    await _tap(tester, 'Передать');
    await tester.pumpAndSettle();
    await _expectQr(
      tester,
      createRoomQrData(
        Uri.parse('https://tree.example/MyTree/'),
        _room,
        role: RoomRole.editor,
        diskAccess: _editor,
      ),
    );
    _noPlainSecret(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'pending access disables duplicates, role changes, and dismissal',
    (tester) async {
      final harness = _Harness();
      final pending = Completer<RoomDiskAccess?>();
      var calls = 0;
      await harness.show(tester, (role, {required allowPublication}) {
        calls++;
        return pending.future;
      });
      final action = tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Скопировать URL'),
          )
          .onPressed!;
      action();
      action();
      await tester.pump();
      expect(calls, 1);
      expect(
        tester
            .widget<SegmentedButton<RoomRole>>(
              find.byKey(const Key('invitation-role')),
            )
            .onSelectionChanged,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Закрыть'))
            .onPressed,
        isNull,
      );
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      pending.complete(_guest);
      await tester.pumpAndSettle();
      expect(harness.copied.length, 1);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final failure in ['role', 'exception', 'missing']) {
    testWidgets(
      'safe $failure failure never emits a misleading or private guest invitation',
      (tester) async {
        final harness = _Harness();
        await harness.show(tester, (role, {required allowPublication}) async {
          if (failure == 'exception') throw StateError(_token);
          return failure == 'role' ? _editor : null;
        }, publish: false);
        await _tap(tester, 'Скопировать URL');
        await tester.pumpAndSettle();
        expect(harness.copied, isEmpty);
        expect(
          find.text(
            'Не удалось подготовить приглашение через Диск. Проверьте доступ и повторите.',
          ),
          findsOneWidget,
        );
        _noPlainSecret(tester);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'long QR reports a safe fallback without losing URL/code copying',
    (tester) async {
      final harness = _Harness();
      final longAccess = RoomDiskAccess.editor(
        bindingId: _binding,
        token: 'x' * 4096,
      );
      await harness.show(
        tester,
        (role, {required allowPublication}) async => longAccess,
      );
      await _tap(tester, 'Редактор');
      await _tap(tester, 'Показать QR');
      await _tap(tester, 'Передать');
      await tester.pumpAndSettle();
      expect(
        find.text('Приглашение слишком длинное для QR. Скопируйте URL.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _tap(tester, 'Закрыть');
      await _tap(tester, 'Скопировать URL');
      await tester.pumpAndSettle();
      expect(
        parseRoomInvitation(harness.copied.single)!.diskAccess,
        longAccess,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('clipboard failure offers QR without exposing access in text', (
    tester,
  ) async {
    final harness = _Harness()..failClipboard = true;
    await harness.show(
      tester,
      (role, {required allowPublication}) async => _guest,
    );
    await _tap(tester, 'Скопировать URL');
    await tester.pumpAndSettle();
    expect(harness.messages, [
      'Не удалось скопировать. Повторите или используйте QR.',
    ]);
    _noPlainSecret(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
