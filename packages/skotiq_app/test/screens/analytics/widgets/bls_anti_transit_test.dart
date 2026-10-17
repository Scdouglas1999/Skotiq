// "Box Least Squares (Transit Search)" reported negative transit depths.
//
// The BLS statistic SR = s^2 / (r(1-r)) is sign-blind, so the box it picks can
// be BRIGHTER than the out-of-box baseline — an anti-transit. Labelled "Depth:
// -53.6 mmag" under a "Transit Search" heading, a brightening (the usual
// outcome on pure noise) read as the session's transit result.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/period_analysis_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// 80 points at 90 s cadence with a box of [boxMag] magnitudes injected over
/// phase [0.3, 0.45] of a 20-minute period. Positive = fainter = a transit;
/// negative = brighter = an anti-transit.
List<LightCurvePoint> _curve({required double boxMag}) {
  final start = DateTime.utc(2026, 8, 1, 9);
  var seed = 20260801;
  double noise() {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
    return (seed / 0x7FFFFFFF - 0.5) * 0.01;
  }

  const periodSeconds = 1200.0;
  return List.generate(80, (i) {
    final t = 90.0 * i;
    final phase = (t % periodSeconds) / periodSeconds;
    final inBox = phase >= 0.30 && phase <= 0.45;
    return LightCurvePoint(
      timestamp: start.add(Duration(seconds: t.round())),
      flux: 1000.0,
      differentialMagnitude: (inBox ? boxMag : 0.0) + noise(),
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

Future<PeriodAnalysisResult> _pumpAnalysis(
  WidgetTester tester,
  List<LightCurvePoint> curve,
) async {
  const service = PeriodAnalysisService();
  final result = service.analyze(
    points: curve,
    minPeriodDays: 0.005,
    maxPeriodDays: 0.05,
  );

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
  return result;
}

List<String> _renderedText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data)
    .whereType<String>()
    .toList();

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

  testWidgets('a brightening is named an anti-transit, never a transit depth',
      (tester) async {
    final result = await _pumpAnalysis(tester, _curve(boxMag: -0.15));
    expect(result.bls.transitDepth, lessThan(0),
        reason: 'the injected box is brighter than baseline');

    final texts = _renderedText(tester);
    expect(
      texts.where((t) => t.contains('Brightening (anti-transit)')),
      isNotEmpty,
      reason: 'the sign has to be named, not printed as a minus sign',
    );
    expect(
      texts.where((t) => t.contains('not a transit candidate')),
      isNotEmpty,
    );
    // No "Depth: -53.6 mmag" anywhere.
    final negativeMmag = RegExp(r'-\s*\d+(\.\d+)?\s*mmag');
    expect(
      texts.where(negativeMmag.hasMatch),
      isEmpty,
      reason: 'a negative depth must not be printed as a signed depth: $texts',
    );
    expect(
      texts.where((t) => t.startsWith('Depth')),
      isEmpty,
      reason: 'nothing may call an anti-transit a depth',
    );
  });

  testWidgets('a real transit still reads as a depth', (tester) async {
    final result = await _pumpAnalysis(tester, _curve(boxMag: 0.15));
    expect(result.bls.transitDepth, greaterThan(0));

    final texts = _renderedText(tester);
    expect(texts.where((t) => t.contains('anti-transit')), isEmpty);
    expect(texts.where((t) => t == 'Depth'), isNotEmpty);
  });
}
