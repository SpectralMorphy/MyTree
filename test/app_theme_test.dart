import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/main.dart';
import 'package:mytree_webrtc_demo/storage/room_store.dart';

double _contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  return first > second
      ? (first + 0.05) / (second + 0.05)
      : (second + 0.05) / (first + 0.05);
}

void main() {
  testWidgets('theme uses muted icon greens with readable foregrounds', (
    tester,
  ) async {
    await tester.pumpWidget(MyTreeDemoApp(store: MemoryRoomStore()));
    await tester.pumpAndSettle();
    final colors = tester
        .widget<MaterialApp>(find.byType(MaterialApp))
        .theme!
        .colorScheme;
    expect(colors.primary, const Color(0xFF28644B));
    expect(colors.primaryContainer, const Color(0xFFD9E9CD));
    expect(colors.surface, const Color(0xFFF3F7ED));
    expect(colors.onPrimaryContainer, const Color(0xFF315E47));
    expect(colors.onSurface, const Color(0xFF315E47));
    for (final pair in [
      (colors.onPrimary, colors.primary),
      (colors.onPrimaryContainer, colors.primaryContainer),
      (colors.onSurface, colors.surface),
    ]) {
      expect(_contrast(pair.$1, pair.$2), greaterThanOrEqualTo(4.5));
    }
    expect(colors.error, isNot(colors.primary));
    expect(tester.takeException(), isNull);
  });
}
