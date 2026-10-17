// The project-growth curve painted `SkotiqChartColors.seriesBlue` raw:
// #6B95B8, a solid blue line with blue dots and a blue area fill, on a card
// whose every other pixel was red. Red night is a WAVELENGTH constraint, so
// that is not merely off-palette — it undoes the dark adaptation the mode
// exists to protect. Same defect the Analytics session charts had; the remap
// (`SkotiqChartColors.forTheme`) already existed, the panel just named the
// constant and drew it.
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart'
    show BestNight, GrowthPoint;
import 'package:skotiq_app/screens/session_review/widgets/growth_curve_panel.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Fraction of the emitted channel energy carried by red.
double _redShare(Color c) {
  final total = c.r + c.g + c.b;
  return total == 0 ? 1.0 : c.r / total;
}

void _expectRedNightSafe(Color c, String what) {
  expect(c.g, lessThanOrEqualTo(c.r),
      reason: '$what emits more green than red');
  expect(c.b, lessThanOrEqualTo(c.r), reason: '$what emits more blue than red');
  expect(_redShare(c), greaterThan(0.5),
      reason: '$what does not keep red dominant');
}

/// Four nights of accrued integration, so the curve draws a real line.
List<GrowthPoint> _points() => List.generate(
      4,
      (i) => GrowthPoint(
        date: DateTime.utc(2026, 7, 10 + i),
        cumulativeHours: 1.5 * (i + 1),
        framesToDate: 30 * (i + 1),
      ),
    );

Widget _panel(ThemeData theme) => MaterialApp(
      theme: theme,
      home: Scaffold(
        body: SingleChildScrollView(
          child: GrowthCurvePanel(
            points: _points(),
            best: BestNight(
              date: DateTime.utc(2026, 7, 12),
              meanWeight: 1.4,
              frameCount: 30,
              integrationHours: 1.5,
            ),
          ),
        ),
      ),
    );

LineChartBarData _bar(WidgetTester tester) =>
    tester.widget<LineChart>(find.byType(LineChart)).data.lineBarsData.single;

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .physicalSize = const Size(1200, 1600);
    TestWidgetsFlutterBinding
        .instance.platformDispatcher.views.first.devicePixelRatio = 1;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

  testWidgets('red night draws the growth line from the remap', (tester) async {
    await tester.pumpWidget(_panel(SkotiqTheme.redNight));
    await tester.pump();

    final bar = _bar(tester);
    expect(
      bar.color,
      SkotiqChartColors.forTheme(
          SkotiqChartColors.seriesBlue, SkotiqColors.redNight),
      reason: 'the growth line does not route its series through forTheme',
    );
    // The exact colour the finding measured on screen must be gone.
    expect(bar.color, isNot(SkotiqChartColors.seriesBlue));
    _expectRedNightSafe(bar.color!, 'growth line');
  });

  testWidgets('red night remaps the fill and the per-night dots too',
      (tester) async {
    await tester.pumpWidget(_panel(SkotiqTheme.redNight));
    await tester.pump();

    final bar = _bar(tester);
    expect(bar.belowBarData.show, isTrue);
    _expectRedNightSafe(bar.belowBarData.color!, 'growth area fill');

    // The dot painter is built per spot from the same resolved hue; a fix that
    // remapped only `color` would leave blue dots on the red card. Index 2 is
    // the badged best night, which is drawn from `colors.success` instead.
    final dots = bar.dotData.getDotPainter;
    final resolved = SkotiqChartColors.forTheme(
        SkotiqChartColors.seriesBlue, SkotiqColors.redNight);
    for (final i in [0, 1, 3]) {
      final painter = dots(FlSpot(i.toDouble(), 1.5 * (i + 1)), 0, bar, i)
          as FlDotCirclePainter;
      expect(painter.color, resolved, reason: 'growth dot $i is painted raw');
      _expectRedNightSafe(painter.color, 'growth dot $i');
    }
  });

  testWidgets('dark keeps the named series hue exactly', (tester) async {
    await tester.pumpWidget(_panel(SkotiqTheme.dark));
    await tester.pump();

    expect(_bar(tester).color, SkotiqChartColors.seriesBlue,
        reason: 'the remap must be the identity outside red night');
  });
}
