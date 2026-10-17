import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The tooltip must stay fully inside the viewport no matter which edge its
/// trigger sits against.
///
/// Clamping the ANCHOR point and then shifting the tooltip by a fraction of its
/// own width renders a right-edge trigger's tooltip almost entirely off-screen
/// — a one-character sliver on the Imaging panel's "Stack & Share" button.
/// Because this is the shared design-system tooltip, the same applies to any
/// trigger near any edge.
void main() {
  const viewport = Size(400, 300);

  Future<Rect> tooltipRect(
    WidgetTester tester, {
    required Alignment where,
    required SkotiqTooltipPosition side,
    String message = 'Stack & Share this session',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Align(
            alignment: where,
            child: SkotiqTooltip(
              message: message,
              position: side,
              // A painted box, so it participates in hit testing and the
              // long-press trigger actually fires.
              child: const ColoredBox(
                key: Key('trigger'),
                color: Color(0xFF224466),
                child: SizedBox(width: 60, height: 24),
              ),
            ),
          ),
        ),
      ),
    );

    // Long-press is the touch trigger and shows with no wait duration, which
    // makes it the reliable way to open the tooltip in a widget test.
    await tester.longPress(find.byKey(const Key('trigger')));
    await tester.pumpAndSettle();

    final textFinder = find.text(message);
    expect(textFinder, findsOneWidget, reason: 'tooltip should be showing');
    return tester.getRect(textFinder);
  }

  for (final (name, where, side)
      in <(String, Alignment, SkotiqTooltipPosition)>[
        (
          'right edge, right-positioned',
          Alignment.centerRight,
          SkotiqTooltipPosition.right,
        ),
        (
          'left edge, left-positioned',
          Alignment.centerLeft,
          SkotiqTooltipPosition.left,
        ),
        (
          'top edge, top-positioned',
          Alignment.topCenter,
          SkotiqTooltipPosition.top,
        ),
        (
          'bottom edge, bottom-positioned',
          Alignment.bottomCenter,
          SkotiqTooltipPosition.bottom,
        ),
        (
          'top-right corner, right-positioned',
          Alignment.topRight,
          SkotiqTooltipPosition.right,
        ),
        (
          'bottom-left corner, bottom-positioned',
          Alignment.bottomLeft,
          SkotiqTooltipPosition.bottom,
        ),
      ]) {
    testWidgets('stays on screen: $name', (tester) async {
      await tester.binding.setSurfaceSize(viewport);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final rect = await tooltipRect(tester, where: where, side: side);

      expect(
        rect.left,
        greaterThanOrEqualTo(0.0),
        reason: '$name: tooltip runs off the left edge',
      );
      expect(
        rect.top,
        greaterThanOrEqualTo(0.0),
        reason: '$name: tooltip runs off the top edge',
      );
      expect(
        rect.right,
        lessThanOrEqualTo(viewport.width),
        reason: '$name: tooltip runs off the right edge',
      );
      expect(
        rect.bottom,
        lessThanOrEqualTo(viewport.height),
        reason: '$name: tooltip runs off the bottom edge',
      );
      // And it must be genuinely readable, not a clipped sliver.
      expect(
        rect.width,
        greaterThan(20.0),
        reason: '$name: tooltip collapsed to an unreadable width',
      );
    });
  }

  testWidgets(
    'a message wider than the viewport wraps instead of overflowing',
    (tester) async {
      await tester.binding.setSurfaceSize(viewport);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      const long =
          'This tooltip message is deliberately far too long to fit across a '
          'narrow viewport in a single line without wrapping somewhere';
      final rect = await tooltipRect(
        tester,
        where: Alignment.centerRight,
        side: SkotiqTooltipPosition.right,
        message: long,
      );

      expect(rect.left, greaterThanOrEqualTo(0.0));
      expect(rect.right, lessThanOrEqualTo(viewport.width));
    },
  );
}
