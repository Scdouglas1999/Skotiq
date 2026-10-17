// The Moon's phase on the chart carries the units it was given.
//
// `AstronomyCalculations.moonIllumination` returns a PERCENT (0-100). A
// moonPosition tuple that documents its third slot as a 0-1 fraction and clamps
// it pins every real phase above 1% to exactly 1.0: the chart draws a solid
// white disc labelled "MOON 100%" while the app's own Dashboard card says
// "Waning Gibbous 74% illuminated".
//
// This drives the REAL widget: the moon tuple is built by
// `InteractiveSkyView`'s painter construction from `moonInfoProvider`, and the
// terminator geometry is read back off the painter's own canvas calls.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/astronomy/astronomy_calculations.dart';
import 'package:skotiq_planetarium/src/celestial_object.dart';
import 'package:skotiq_planetarium/src/providers/deep_star_providers.dart';
import 'package:skotiq_planetarium/src/providers/planetarium_providers.dart';
import 'package:skotiq_planetarium/src/rendering/sky_renderer.dart';
import 'package:skotiq_planetarium/src/widgets/interactive_sky_view.dart';

/// Canvas that only remembers the ovals drawn on it.
///
/// `_drawMoon` draws exactly one oval — the terminator, whose semi-minor axis
/// is |2k-1| of the disc radius — so its aspect ratio IS the phase the chart
/// rendered.
class _OvalSpyCanvas implements Canvas {
  final List<Rect> ovals = [];
  int _saveCount = 1;

  @override
  void drawOval(Rect rect, Paint paint) => ovals.add(rect);

  @override
  void save() => _saveCount++;

  @override
  void restore() => _saveCount--;

  @override
  int getSaveCount() => _saveCount;

  @override
  Rect getLocalClipBounds() => Rect.largest;

  @override
  Rect getDestinationClipBounds() => Rect.largest;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// The phase actually drawn, recovered from the terminator ellipse.
double _renderedIlluminatedFraction(_OvalSpyCanvas spy) {
  expect(spy.ovals, isNotEmpty, reason: 'the Moon was not drawn');
  final oval = spy.ovals.first;
  // width = 2 * r * |2k-1|, height = 2 * r.
  final semiAxisFraction = oval.width / oval.height;
  // Gibbous half of the month (the audited case): k = (1 + |2k-1|) / 2.
  return (1 + semiAxisFraction) / 2;
}

Future<_OvalSpyCanvas> _paintSkyWithMoon(
  WidgetTester tester, {
  required double illuminationPercent,
}) async {
  final container = ProviderContainer(
    overrides: [
      combinedStarsProvider.overrideWithValue(const AsyncValue.data(<Star>[])),
      fovFilteredDsosProvider.overrideWithValue(
        const AsyncValue.data(<DeepSkyObject>[]),
      ),
      // Exactly what the shipped provider emits: a PERCENT.
      moonInfoProvider.overrideWithValue(
        MoonTimes(
          illumination: illuminationPercent,
          phaseName: 'Waning Gibbous',
        ),
      ),
    ],
  );
  // The sky is drawn from the observer's site; without one the view renders
  // its no-site state instead.
  container
      .read(observerLocationProvider.notifier)
      .setLocation(latitude: 40.0, longitude: -74.0);

  // Aim the view at the Moon so it lands on the canvas.
  final (moonRaDeg, moonDecDeg, _) = container.read(moonPositionProvider);
  container
      .read(skyViewStateProvider.notifier)
      .setCenter(moonRaDeg / 15, moonDecDeg);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: InteractiveSkyView())),
    ),
  );
  await tester.pump();

  final painters = tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((w) => w.painter)
      .whereType<SkyCanvasPainter>()
      .where((p) => p.moonPosition != null)
      .toList();
  expect(painters, isNotEmpty, reason: 'no sky painter carried a Moon');

  final spy = _OvalSpyCanvas();
  for (final painter in painters) {
    painter.paint(spy, const Size(800, 600));
  }

  await tester.pumpWidget(const SizedBox.shrink());
  container.dispose();
  return spy;
}

void main() {
  testWidgets('a 74% Moon is drawn as a 74% Moon, not a full one', (
    tester,
  ) async {
    final spy = await _paintSkyWithMoon(tester, illuminationPercent: 74.0);
    expect(
      _renderedIlluminatedFraction(spy),
      closeTo(0.74, 0.005),
      reason:
          'the percent from moonInfoProvider must not be read as a '
          'fraction and clamped to full',
    );
  });

  testWidgets('a genuinely full Moon still renders full', (tester) async {
    final spy = await _paintSkyWithMoon(tester, illuminationPercent: 100.0);
    expect(_renderedIlluminatedFraction(spy), closeTo(1.0, 0.005));
  });

  testWidgets('a thin crescent is not rendered as a gibbous disc', (
    tester,
  ) async {
    // 8% lit: |2k-1| = 0.84, and it is drawn DARK-over-lit rather than lit-over.
    final spy = await _paintSkyWithMoon(tester, illuminationPercent: 8.0);
    final oval = spy.ovals.first;
    expect(oval.width / oval.height, closeTo(0.84, 0.01));
  });
}
