// The science-overlay legend named its ramps as `SkotiqChartColors`
// constants (`psfGradient`, `uniformityGradient`, `clipHighGradient`,
// `clipLowGradient`) and then painted the constants as swatches. Red night is a
// WAVELENGTH constraint, so the PSF strip's `seriesGreen` swatch and the
// clip-low strip's `seriesBlue` swatch sat green and blue on a red-night
// screen. This strip is inline on the Imaging HUD, not only inside a dialog the
// user chose to open.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_overlay_legend.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Fraction of the emitted channel energy carried by red.
double _redShare(Color c) {
  final total = c.r + c.g + c.b;
  return total == 0 ? 1.0 : c.r / total;
}

/// The four overlay keys that declare a ramp, and the ramp each declares.
const _rampsByKey = <String, List<Color>>{
  'psf': SkotiqChartColors.psfGradient,
  'uniformity': SkotiqChartColors.uniformityGradient,
  'clip_high': SkotiqChartColors.clipHighGradient,
  'clip_low': SkotiqChartColors.clipLowGradient,
};

/// Every solid swatch colour the four inline legend strips paint.
List<Color> _swatches(WidgetTester tester) => tester
    .widgetList<Container>(find.byType(Container))
    .map((c) => c.decoration)
    .whereType<BoxDecoration>()
    .map((d) => d.color)
    .whereType<Color>()
    .toList(growable: false);

Future<void> _pump(WidgetTester tester, ThemeData theme) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Builder(
        builder: (context) => Scaffold(
          body: Column(
            children: [
              for (final key in _rampsByKey.keys)
                ScienceOverlayLegend.inlineFor(context, key),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .physicalSize = const Size(1400, 900);
    TestWidgetsFlutterBinding
        .instance.platformDispatcher.views.first.devicePixelRatio = 1;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

  testWidgets('red night draws every legend swatch from the remap',
      (tester) async {
    await _pump(tester, SkotiqTheme.redNight);

    final painted = _swatches(tester);
    expect(painted, isNotEmpty, reason: 'no legend swatch rendered');

    for (final entry in _rampsByKey.entries) {
      for (final named in entry.value) {
        final resolved =
            SkotiqChartColors.forTheme(named, SkotiqColors.redNight);
        expect(painted, contains(resolved),
            reason: 'the ${entry.key} legend does not route $named '
                'through forTheme');
      }
    }

    // The named ramp hues themselves must be gone from the screen.
    for (final named in _rampsByKey.values.expand((ramp) => ramp).toSet()) {
      expect(painted, isNot(contains(named)),
          reason: 'a legend swatch still paints $named raw');
    }

    for (final c in painted) {
      expect(c.g, lessThanOrEqualTo(c.r),
          reason: '$c emits more green than red');
      expect(c.b, lessThanOrEqualTo(c.r),
          reason: '$c emits more blue than red');
      expect(_redShare(c), greaterThan(0.5),
          reason: '$c does not keep red dominant');
    }
  });

  testWidgets('dark keeps the named ramps exactly', (tester) async {
    await _pump(tester, SkotiqTheme.dark);

    final painted = _swatches(tester);
    for (final named in _rampsByKey.values.expand((ramp) => ramp).toSet()) {
      expect(painted, contains(named),
          reason: 'the remap must be the identity outside red night');
    }
  });
}
