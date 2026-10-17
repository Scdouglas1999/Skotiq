// The determinate progress bar's painted fill matches its value.
//
// Setting the FILL's width (`Container(width: maxWidth * value)`) cannot work:
// `Container(width:)` enforces its request against the incoming constraints, so
// a tight parent — `Expanded` inside a `Row`, which is how nearly every call
// site uses this widget — clamps the fraction back up to the full width and the
// bar paints 100% full beside a correct "0%" label. Under loose constraints the
// track shrink-wraps to the fill instead of spanning its slot.
//
// These tests measure the real painted fill.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _fillKey = ValueKey<String>('skotiq-progress-fill');

/// Tight-width parent: `Expanded` in a `Row` passes min == max == full width.
Widget _tight(Widget child, {double width = 400}) => MaterialApp(
  theme: SkotiqTheme.dark,
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: width,
        child: Row(children: [Expanded(child: child)]),
      ),
    ),
  ),
);

/// Loose-width parent: maxWidth bounded, minWidth 0.
Widget _loose(Widget child, {double width = 400}) => MaterialApp(
  theme: SkotiqTheme.dark,
  home: Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: child,
      ),
    ),
  ),
);

double _fillWidth(WidgetTester tester) =>
    tester.getSize(find.byKey(_fillKey)).width;

double _trackWidth(WidgetTester tester) =>
    tester.getSize(find.byType(SkotiqProgressBar)).width;

/// The paintable width inside the track's 1px border — what the fill is a
/// fraction of.
double _innerWidth(WidgetTester tester) =>
    tester.getSize(find.byType(FractionallySizedBox).first).width;

void main() {
  group('determinate fill honours value in a TIGHT parent', () {
    for (final value in <double>[0.0, 0.25, 0.5, 0.75, 1.0]) {
      testWidgets('value $value paints ${value * 100}% of the track', (
        tester,
      ) async {
        await tester.pumpWidget(
          _tight(
            SkotiqProgressBar(value: value, style: SkotiqProgressStyle.thick),
          ),
        );
        await tester.pumpAndSettle();

        expect(_trackWidth(tester), 400);
        expect(
          _fillWidth(tester),
          moreOrLessEquals(_innerWidth(tester) * value, epsilon: 0.5),
          reason:
              'A tight parent must not be able to stretch the fill: the fill '
              'width has to follow `value`, not the slot.',
        );
      });
    }
  });

  testWidgets('zero paints no fill at all', (tester) async {
    await tester.pumpWidget(_tight(const SkotiqProgressBar(value: 0)));
    await tester.pumpAndSettle();

    expect(_fillWidth(tester), 0.0);
  });

  testWidgets('track spans its slot under LOOSE constraints', (tester) async {
    await tester.pumpWidget(_loose(const SkotiqProgressBar(value: 0.5)));
    await tester.pumpAndSettle();

    expect(
      _trackWidth(tester),
      400,
      reason:
          'The track is the background, not the fill; it must not '
          'shrink-wrap to 50% because the value is 0.5.',
    );
    expect(
      _fillWidth(tester),
      moreOrLessEquals(_innerWidth(tester) * 0.5, epsilon: 0.5),
    );
  });

  testWidgets('out-of-range and non-finite values are clamped, not painted', (
    tester,
  ) async {
    await tester.pumpWidget(_tight(const SkotiqProgressBar(value: -3)));
    await tester.pumpAndSettle();
    expect(_fillWidth(tester), 0.0);

    await tester.pumpWidget(_tight(const SkotiqProgressBar(value: 7)));
    await tester.pumpAndSettle();
    expect(_fillWidth(tester), _innerWidth(tester));

    await tester.pumpWidget(_tight(const SkotiqProgressBar(value: double.nan)));
    await tester.pumpAndSettle();
    expect(_fillWidth(tester), 0.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('animates towards a new value instead of jumping', (
    tester,
  ) async {
    await tester.pumpWidget(
      _tight(
        const SkotiqProgressBar(
          value: 0,
          animationDuration: Duration(milliseconds: 400),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_fillWidth(tester), 0.0);

    await tester.pumpWidget(
      _tight(
        const SkotiqProgressBar(
          value: 1,
          animationDuration: Duration(milliseconds: 400),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final midway = _fillWidth(tester);
    expect(midway, greaterThan(0));
    expect(midway, lessThan(_innerWidth(tester)));

    await tester.pumpAndSettle();
    expect(_fillWidth(tester), _innerWidth(tester));
  });

  testWidgets('percentage label and painted fill agree', (tester) async {
    await tester.pumpWidget(
      _tight(
        const SkotiqProgressBar(
          value: 0,
          showPercentage: true,
          label: 'Integration',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('0%'), findsOneWidget);
    expect(
      _fillWidth(tester),
      0.0,
      reason:
          'The "0%" label beside a completely full bar was the original '
          'user-visible symptom.',
    );
  });

  testWidgets('segmented style still fills proportionally', (tester) async {
    await tester.pumpWidget(
      _tight(
        const SkotiqProgressBar(
          value: 0.5,
          style: SkotiqProgressStyle.segmented,
          segments: 4,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final fills = tester
        .widgetList<FractionallySizedBox>(find.byType(FractionallySizedBox))
        .map((w) => w.widthFactor)
        .toList();
    // 4 segments at 0.5 => two full segments and a 0.0 partial one.
    expect(fills, [1.0, 1.0, 0.0]);
  });
}
