// The progress curve: what it draws, what it refuses to draw, and the table
// that stands in for it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/depthlock/depthlock_curve_chart.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'depthlock_test_doubles.dart';

List<DepthLockCurvePoint> _curve() => <DepthLockCurvePoint>[
      const DepthLockCurvePoint(
        frames: 32,
        score: 3.0,
        conservativeScore: 2.1,
        projected: false,
      ),
      const DepthLockCurvePoint(
        frames: 44,
        score: 3.6,
        conservativeScore: 2.8,
        projected: false,
      ),
      const DepthLockCurvePoint(
        frames: 60,
        score: 4.4,
        conservativeScore: 3.6,
        projected: false,
      ),
      const DepthLockCurvePoint(
        frames: 78,
        score: 5.2,
        conservativeScore: 4.4,
        projected: true,
      ),
      const DepthLockCurvePoint(
        frames: 96,
        score: 5.9,
        conservativeScore: 5.1,
        projected: true,
      ),
    ];

Future<void> _pumpChart(
  WidgetTester tester, {
  required FakeDepthLockBackend backend,
  required DepthLockGoal goal,
}) async {
  tester.view.physicalSize = const Size(900, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        depthLockBackendProvider.overrideWithValue(backend),
        depthLockEventStreamProvider.overrideWithValue(
          const Stream<SkotiqEvent>.empty(),
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SizedBox(
            width: 380,
            child: DepthLockCurveChart(goal: goal),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a goal below the minimum gets a sentence, not a fake curve', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend()..curve = _curve();
    await _pumpChart(
      tester,
      backend: backend,
      goal: depthLockGoalFixture(
        report: depthLockReportFixture(
          state: DepthLockState.insufficientEvidence,
          evidenceFrames: 12,
        ),
      ),
    );

    expect(
      find.text(
        'The curve starts once the goal has its first 32 exposures.',
      ),
      findsOneWidget,
    );
    expect(find.byType(CustomPaint), findsWidgets);
    // No curve was even asked for.
    expect(backend.curveCalls, 0);
  });

  testWidgets('the chart draws its series, its legend and its caption', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend()..curve = _curve();
    await _pumpChart(
      tester,
      backend: backend,
      goal: depthLockGoalFixture(
        report: depthLockReportFixture(forecast: depthLockForecastFixture()),
      ),
    );

    expect(backend.curveCalls, 1);
    // Two series and the threshold are all named — identity is never colour
    // alone.
    expect(find.text('Conservative S/N'), findsOneWidget);
    expect(find.text('Raw S/N'), findsOneWidget);
    expect(find.text('Goal'), findsOneWidget);
    expect(find.text('Floor limit'), findsNothing);
    expect(
      find.text('Solid: measured. Dashed: projected at the recent sky.'),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is DepthLockCurvePainter,
      ),
      findsOneWidget,
    );
  });

  testWidgets('an unreachable goal gains the floor-limit reference', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend()..curve = _curve();
    await _pumpChart(
      tester,
      backend: backend,
      goal: depthLockGoalFixture(
        report: depthLockReportFixture(
          forecast: depthLockForecastFixture(
            reachable: false,
            ceilingScore: 4.1,
          ),
        ),
      ),
    );

    expect(find.text('Floor limit'), findsOneWidget);
    final painter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<DepthLockCurvePainter>()
        .single;
    expect(painter.ceiling, 4.1);
    expect(painter.threshold, 5);
  });

  testWidgets('the table toggle shows the same points as rows', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend()..curve = _curve();
    await _pumpChart(
      tester,
      backend: backend,
      goal: depthLockGoalFixture(
        report: depthLockReportFixture(forecast: depthLockForecastFixture()),
      ),
    );

    await tester.tap(find.widgetWithText(SkotiqButton, 'Table'));
    await tester.pumpAndSettle();

    expect(find.text('Integration'), findsOneWidget);
    expect(find.text('Frames'), findsOneWidget);
    expect(find.text('Conservative'), findsOneWidget);
    // The first measured point: 32 frames at 300 s is 2.7 h.
    expect(find.text('32'), findsOneWidget);
    expect(find.text('2.1'), findsOneWidget);
    // And a projected row says that it is.
    expect(find.textContaining('(projected)'), findsWidgets);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Chart'));
    await tester.pumpAndSettle();
    expect(find.text('Integration'), findsNothing);
  });

  testWidgets('tapping the plot puts a crosshair on the nearest point', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend()..curve = _curve();
    await _pumpChart(
      tester,
      backend: backend,
      goal: depthLockGoalFixture(
        report: depthLockReportFixture(forecast: depthLockForecastFixture()),
      ),
    );

    DepthLockCurvePainter painter() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<DepthLockCurvePainter>()
        .single;

    expect(painter().hoverIndex, isNull);

    final Rect plot = tester.getRect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is DepthLockCurvePainter,
      ),
    );
    await tester.tapAt(Offset(plot.right - 8, plot.center.dy));
    await tester.pumpAndSettle();

    // The far right of the plot is the last point.
    expect(painter().hoverIndex, 4);
  });

  testWidgets('a curve the host cannot supply says so in its own words', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend()
      ..curveError = const SkotiqError(
        category: BackendErrorCategory.io,
        message: 'Evidence for goal-1 is no longer on disk',
      );
    await _pumpChart(
      tester,
      backend: backend,
      goal: depthLockGoalFixture(
        report: depthLockReportFixture(forecast: depthLockForecastFixture()),
      ),
    );

    expect(
      find.text('Evidence for goal-1 is no longer on disk'),
      findsOneWidget,
    );
  });
}
