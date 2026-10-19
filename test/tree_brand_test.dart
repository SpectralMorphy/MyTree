import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/ui/tree_brand.dart';

void main() {
  testWidgets(
    'room loading uses the tree asset and a live synchronization status',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: RoomLoadingView(status: 'Получаем историю…')),
        ),
      );
      expect(find.byType(TreeMark), findsOneWidget);
      expect(find.text('Открываем комнату'), findsOneWidget);
      expect(find.text('Получаем историю…'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as AssetImage).assetName, 'assets/tree-mark.png');
      expect(image.semanticLabel, contains('семейное дерево'));
      final semantics = tester.widget<Semantics>(
        find
            .ancestor(
              of: find.byKey(const Key('initial-sync-status')),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(semantics.properties.liveRegion, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(390, 300),
  ]) {
    testWidgets('mobile loading stays bounded and scrolls at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var exited = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SafeArea(
              child: RoomLoadingView(
                status: 'Проверяем участников…',
                error: 'Не удалось проверить историю. ' * 12,
                onRetry: () {},
                onOpenLocal: () {},
                onExit: () => exited = true,
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final scrollable = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      expect(scrollable.physics, isA<ClampingScrollPhysics>());
      final image = tester.getRect(find.byType(TreeMark));
      expect(image.left, greaterThanOrEqualTo(0));
      expect(image.right, lessThanOrEqualTo(size.width));
      await tester.ensureVisible(find.text('Вернуться в меню'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Вернуться в меню'));
      expect(exited, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('tree pulse respects the reduced-motion preference', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: TreeMark(animate: true),
        ),
      ),
    );
    final scale = tester.widget<ScaleTransition>(find.byType(ScaleTransition));
    expect(scale.scale.value, 1);
    await tester.pump(const Duration(seconds: 3));
    expect(scale.scale.value, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed entry stops its progress and exposes explicit actions', (
    tester,
  ) async {
    var retries = 0;
    var localOpens = 0;
    var exits = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RoomLoadingView(
            status: 'Проверяем участников…',
            error: 'Не удалось проверить присутствие участников',
            onRetry: () => retries++,
            onOpenLocal: () => localOpens++,
            onExit: () => exits++,
          ),
        ),
      ),
    );
    expect(tester.widget<TreeMark>(find.byType(TreeMark)).animate, isFalse);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.tap(find.text('Повторить подключение'));
    await tester.tap(find.text('Открыть локальную копию'));
    await tester.tap(find.text('Вернуться в меню'));
    expect([retries, localOpens, exits], [1, 1, 1]);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
