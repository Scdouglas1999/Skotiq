// Every series colour on the Analytics charts must come from
// `SkotiqChartColors.forTheme`.
//
// Measured in the running app with red night active: the Image-quality line
// drew rgb(107,149,184) = #6B95B8, Guiding drew rgb(74,154,114), Focus drift
// rgb(138,130,176) and Sensor temperature rgb(203,136,71) — four fixed series
// hues on a page whose every other pixel was red. The remap already existed and
// the dashboard guiding chart already used it; these charts named the series
// constant and painted it raw. Red night is a WAVELENGTH constraint, so a blue
// line is not merely off-palette: it undoes the dark adaptation the mode exists
// to protect.
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_app/screens/analytics/widgets/period_analysis_panel.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_timeline_scrubber.dart';
import 'package:skotiq_app/screens/analytics/widgets/session_chart.dart';
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

class _TutorialsDisabledNotifier extends TutorialNotifier {
  _TutorialsDisabledNotifier() : super(_NoopTutorialProgressDao()) {
    // ignore: invalid_use_of_protected_member
    state = const TutorialProgress(tutorialsEnabled: false);
  }
}

class _NoopTutorialProgressDao implements TutorialProgressDao {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Frames carrying all four measurements, so all four session charts populate.
List<DbCapturedImage> _frames() => List.generate(
      12,
      (i) => DbCapturedImage(
        id: i + 1,
        filePath: '/tmp/$i.fits',
        fileName: '$i.fits',
        fileFormat: 'fits',
        frameType: 'light',
        exposureDuration: 120,
        binX: 1,
        binY: 1,
        capturedAt: DateTime.utc(2026, 7, 14, 22, i * 5),
        createdAt: DateTime.utc(2026, 7, 14, 22, i * 5),
        isAccepted: true,
        isPlateSolved: false,
        hfr: 2.4 + i * 0.03,
        guidingRmsTotal: 0.55 + i * 0.01,
        focuserPosition: 18400 + i,
        sensorTemp: -9.8 + i * 0.02,
      ),
    );

Widget _sessionTab(ThemeData theme, List<DbCapturedImage> frames) {
  return ProviderScope(
    overrides: [
      standaloneImagesProvider.overrideWith((ref) => Stream.value(frames)),
      allDbImagesProvider.overrideWith(
        (ref) => Stream.value(const <DbCapturedImage>[]),
      ),
      allSessionsProvider.overrideWith(
        (ref) => Stream.value(const <ImagingSession>[]),
      ),
      tutorialProvider.overrideWith((ref) => _TutorialsDisabledNotifier()),
    ],
    child: MaterialApp(
      theme: theme,
      home: const Scaffold(
        body: AnalyticsScreen(initialTab: AnalyticsTab.session),
      ),
    ),
  );
}

/// Card title -> the colour that card's line is told to draw itself in.
Map<String, Color> _lineColorsByTitle(WidgetTester tester) {
  final out = <String, Color>{};
  final charts = find.byType(SessionChart);
  for (var i = 0; i < charts.evaluate().length; i++) {
    final card = charts.at(i);
    final title = tester.widget<SessionChart>(card).title;
    final chart = tester.widget<LineChart>(
      find.descendant(of: card, matching: find.byType(LineChart)),
    );
    out[title] = chart.data.lineBarsData.single.color!;
  }
  return out;
}

/// The series hue each session card names, before the theme is applied.
const _namedHues = <String, Color>{
  'Image quality': SkotiqChartColors.seriesBlue,
  'Guiding performance': SkotiqChartColors.seriesGreen,
  'Focus drift': SkotiqChartColors.seriesViolet,
  'Sensor temperature': SkotiqChartColors.seriesOrange,
};

class _PresetAnalysis extends PeriodAnalysisNotifier {
  _PresetAnalysis(this._state);
  final PeriodAnalysisState _state;

  @override
  PeriodAnalysisState build() => _state;
}

/// A light curve with a real period, so the panel draws every spectrum.
List<LightCurvePoint> _lightCurve() {
  final start = DateTime.utc(2026, 8, 1, 9);
  return List.generate(80, (i) {
    final phase = (i * 90) / 3600.0;
    return LightCurvePoint(
      timestamp: start.add(Duration(seconds: 90 * i)),
      flux: 1000.0,
      differentialMagnitude: 0.05 * (phase % 1.0),
      snr: 120,
      uncertainty: 0.008,
    );
  });
}

/// Every plot/peak colour the period painters are about to draw with.
List<Color> _painterSeriesColors(WidgetTester tester) {
  final out = <Color>[];
  for (final paint
      in tester.widgetList<CustomPaint>(find.byType(CustomPaint))) {
    final dynamic painter = paint.painter;
    if (painter == null) continue;
    try {
      out.add(painter.plotColor as Color);
    } on NoSuchMethodError {
      continue; // not a period-analysis painter
    }
    try {
      out.add(painter.peakColor as Color);
    } on NoSuchMethodError {
      // phase-fold painter has no peak marker
    }
  }
  return out;
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .physicalSize = const Size(1600, 3000);
    TestWidgetsFlutterBinding
        .instance.platformDispatcher.views.first.devicePixelRatio = 1;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

  testWidgets('red night draws every session series from the remap',
      (tester) async {
    await tester.pumpWidget(_sessionTab(SkotiqTheme.redNight, _frames()));
    await tester.pump();

    final drawn = _lineColorsByTitle(tester);
    expect(drawn.keys.toSet(), _namedHues.keys.toSet());

    drawn.forEach((title, color) {
      expect(
        color,
        SkotiqChartColors.forTheme(
            _namedHues[title]!, SkotiqColors.redNight),
        reason: '$title does not route its series through forTheme',
      );
      _expectRedNightSafe(color, '$title series');
    });

    // The exact colour the finding measured on screen must be gone.
    expect(drawn['Image quality'], isNot(SkotiqChartColors.seriesBlue));
  });

  testWidgets('the fill under each session line is remapped too',
      (tester) async {
    await tester.pumpWidget(_sessionTab(SkotiqTheme.redNight, _frames()));
    await tester.pump();

    final charts = find.byType(SessionChart);
    for (var i = 0; i < charts.evaluate().length; i++) {
      final card = charts.at(i);
      final title = tester.widget<SessionChart>(card).title;
      final chart = tester.widget<LineChart>(
        find.descendant(of: card, matching: find.byType(LineChart)),
      );
      final below = chart.data.lineBarsData.single.belowBarData;
      if (!below.show) continue;
      _expectRedNightSafe(below.color!, '$title area fill');
    }
  });

  testWidgets('dark keeps the named series hues exactly', (tester) async {
    await tester.pumpWidget(_sessionTab(SkotiqTheme.dark, _frames()));
    await tester.pump();

    final drawn = _lineColorsByTitle(tester);
    expect(drawn.keys.toSet(), _namedHues.keys.toSet());
    drawn.forEach((title, color) {
      expect(color, _namedHues[title],
          reason: 'the remap must be the identity outside red night');
    });
  });

  testWidgets('red night remaps the period-analysis spectra as well',
      (tester) async {
    final curve = _lightCurve();
    const service = PeriodAnalysisService();
    final result = service.analyze(
      points: curve,
      minPeriodDays: 0.01,
      maxPeriodDays: 0.0823,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          periodAnalysisProvider.overrideWith(
            () => _PresetAnalysis(PeriodAnalysisState(result: result)),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.redNight,
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

    final colors = _painterSeriesColors(tester);
    // Lomb-Scargle (plot + peak), phase fold (plot), BLS (plot + peak).
    expect(colors.length, greaterThanOrEqualTo(5),
        reason: 'the period panel draws fewer spectra than expected');
    for (final color in colors) {
      _expectRedNightSafe(color, 'period spectrum series');
    }
    expect(colors, isNot(contains(SkotiqChartColors.seriesBlue)));
    expect(colors, isNot(contains(SkotiqChartColors.seriesGreen)));
  });

  testWidgets('red night remaps the timeline scrubber frame bars',
      (tester) async {
    final metrics = List.generate(
      6,
      (i) => ScienceFrameQualityMetricsRow(
        id: i + 1,
        timestamp: DateTime.utc(2026, 8, 1, 22, i * 5),
        median: 100,
        mean: 101,
        stdDev: 5,
        mad: 4,
        background: 90,
        noise: 3,
        snr: 30.0 + i,
        dynamicRangeP1P99: 500,
        lowClipPercent: 0,
        highClipPercent: 0,
        uniformityCv: 0.02,
        gradientX: 0,
        gradientY: 0,
        processingTier: 'full',
        processingMs: 12,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.redNight,
        home: Builder(
          builder: (context) => Scaffold(
            body: ScienceTimelineScrubber(
              colors: SkotiqColors.of(context),
              frameMetrics: metrics,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final unselected = SkotiqChartColors.forTheme(
      SkotiqChartColors.unselectedFrame(),
      SkotiqColors.redNight,
    );
    final bars = tester
        .widgetList<Container>(find.byType(Container))
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .map((d) => d.color)
        .whereType<Color>()
        .where((c) => c.a > 0)
        .toList(growable: false);
    expect(bars, contains(unselected),
        reason: 'the unselected frame bar is not drawn from the remap');
    expect(bars, isNot(contains(SkotiqChartColors.unselectedFrame())));
    for (final bar in bars) {
      _expectRedNightSafe(bar, 'scrubber frame bar');
    }
  });
}
