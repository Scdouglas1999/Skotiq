// Both periodogram Y axes must label every tick distinctly.
//
// Observed defect: with a peak LS power of 0.07 the Power axis printed
// "0.1 / 0.1 / 0.0 / 0.0 / 0.0" top to bottom — three identical ticks — because
// the ticks were maxPower * 1.1 * i / 4 formatted with toStringAsFixed(1). The
// Box Least Squares "SR (signal residual)" axis printed "0.0" five times. An
// insignificant detection, which is the normal case, therefore had an
// unreadable Y axis.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/period_analysis_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// 80 points at 90 s cadence over 118.5 minutes with low-amplitude noise —
/// the seeded curve from the audit, whose LS peak power lands around 0.07.
List<LightCurvePoint> _noiseCurve() {
  final start = DateTime.utc(2026, 8, 1, 9);
  var seed = 12345;
  double next() {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
    return seed / 0x7FFFFFFF - 0.5;
  }

  return List.generate(80, (i) {
    return LightCurvePoint(
      timestamp: start.add(Duration(seconds: 90 * i)),
      flux: 1000.0,
      differentialMagnitude: next() * 0.06,
      snr: 120,
      uncertainty: 0.008,
    );
  });
}

class _PresetAnalysis extends PeriodAnalysisNotifier {
  _PresetAnalysis(this._state);
  final PeriodAnalysisState _state;

  @override
  PeriodAnalysisState build() => _state;
}

/// Every axis-label list the two spectrum painters are about to draw.
///
/// The labels go straight onto a canvas, so there is no Text widget to find;
/// the painters expose exactly the strings paint() renders.
List<List<String>> _axisLabelSets(WidgetTester tester) {
  final out = <List<String>>[];
  for (final paint
      in tester.widgetList<CustomPaint>(find.byType(CustomPaint))) {
    final dynamic painter = paint.painter;
    if (painter == null) continue;
    try {
      out.add((painter.powerAxisLabels as List).cast<String>());
    } on NoSuchMethodError {
      // Not the Lomb-Scargle painter.
    }
    try {
      out.add((painter.srAxisLabels as List).cast<String>());
    } on NoSuchMethodError {
      // Not the BLS painter.
    }
  }
  return out;
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .physicalSize = const Size(1200, 3000);
    TestWidgetsFlutterBinding
        .instance.platformDispatcher.views.first.devicePixelRatio = 1;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

  testWidgets('every tick on both spectrum axes carries a distinct value',
      (tester) async {
    final curve = _noiseCurve();
    // A real analysis run, not a hand-made result: the point of the finding is
    // what the shipped algorithm's output looks like on an ordinary night.
    const service = PeriodAnalysisService();
    final result = service.analyze(
      points: curve,
      minPeriodDays: 0.01,
      maxPeriodDays: 0.0823,
    );
    expect(result.lombScargle.peakPower, lessThan(0.5),
        reason: 'the interesting case is an insignificant detection');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          periodAnalysisProvider.overrideWith(
            () => _PresetAnalysis(PeriodAnalysisState(result: result)),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: SingleChildScrollView(
                child: PeriodAnalysisPanel(
                  colors: SkotiqColors.of(context),
                  lightCurve: curve,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // The BLS card must never print a bare SDE: its threshold has to be beside
    // it, because on this implementation pure noise can outscore a strong
    // injected signal and a user comparing two runs would rank them backwards.
    expect(
      find.textContaining('significance threshold'),
      findsOneWidget,
      reason: 'SDE without its bar is not a verdict',
    );

    final sets = _axisLabelSets(tester);
    expect(sets, hasLength(2), reason: 'LS power axis and BLS SR axis');
    for (final labels in sets) {
      expect(labels.length, greaterThanOrEqualTo(3));
      expect(
        labels.toSet(),
        hasLength(labels.length),
        reason: 'duplicate tick labels make the axis unreadable: $labels',
      );
    }
  });
}
