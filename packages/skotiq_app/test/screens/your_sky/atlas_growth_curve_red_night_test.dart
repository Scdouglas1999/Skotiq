// The region "deepening over time" curve painted
// `SkotiqChartColors.seriesBlue` raw: #6B95B8, a solid blue line and area
// fill, on a card whose every other pixel was red. Red night is a WAVELENGTH
// constraint, so a blue line is not merely off-palette — it undoes the dark
// adaptation the mode exists to protect. Same defect the Analytics session
// charts had, in a second copy of the same growth-chart shape.
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/your_sky/widgets/atlas_growth_curve.dart';
import 'package:skotiq_core/skotiq_core.dart';
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

/// Four folds of a region, so the curve clears its two-point placeholder.
AtlasGrowthCurve _curve() {
  final points = List.generate(
    4,
    (i) => AtlasGrowthPoint(
      label: '2026-07-1$i',
      framesAdded: 20,
      secondsAdded: 2400,
      cumulativeFrames: 20 * (i + 1),
      cumulativeSeconds: 2400.0 * (i + 1),
      contributor: 'local',
    ),
  );
  return AtlasGrowthCurve(
    points: points,
    totalFrames: 80,
    totalSeconds: 9600,
  );
}

Widget _panel(ThemeData theme) => MaterialApp(
      theme: theme,
      home: Scaffold(
        body: SingleChildScrollView(
          child: AtlasGrowthCurvePanel(curve: _curve()),
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

  testWidgets('red night draws the atlas growth line from the remap',
      (tester) async {
    await tester.pumpWidget(_panel(SkotiqTheme.redNight));
    await tester.pump();

    final bar = _bar(tester);
    expect(
      bar.color,
      SkotiqChartColors.forTheme(
          SkotiqChartColors.seriesBlue, SkotiqColors.redNight),
      reason: 'the atlas growth line does not route through forTheme',
    );
    // The exact colour the finding measured on screen must be gone.
    expect(bar.color, isNot(SkotiqChartColors.seriesBlue));
    _expectRedNightSafe(bar.color!, 'atlas growth line');

    expect(bar.belowBarData.show, isTrue);
    _expectRedNightSafe(bar.belowBarData.color!, 'atlas growth area fill');
  });

  testWidgets('dark keeps the named series hue exactly', (tester) async {
    await tester.pumpWidget(_panel(SkotiqTheme.dark));
    await tester.pump();

    expect(_bar(tester).color, SkotiqChartColors.seriesBlue,
        reason: 'the remap must be the identity outside red night');
  });
}
