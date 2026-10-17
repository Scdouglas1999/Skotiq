// One card must not print two rise times for the same event.
//
// Live finding: the Night Outlook hero card for M92 carried the warning
// "Rises late at 11:54" while the chart footer of the SAME card read
// "Rise: 12:01". The warning came from the planner scorer, which anchors its
// rise/transit/set solve on `nightDateOf` of the night it is scoring; the
// footer came from a second solve inside AltitudeChart anchored on the raw
// wall clock. `calculateObjectVisibility` searches local noon to local noon,
// so once the clock crosses midnight — exactly when someone is imaging — the
// chart described the FOLLOWING night and the two disagreed by a sidereal day.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/altitude_chart.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show AppSettingsNotifier, AppSettingsState, appSettingsProvider;
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _latitude = 40.0;
const _longitude = -75.0;
const _raHours = 17.285;
const _decDegrees = 43.136;

class _SiteSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(latitude: _latitude, longitude: _longitude);
}

class _Fixture implements CelestialObject {
  @override
  String get id => 'm92';
  @override
  String get name => 'M92';
  @override
  CelestialCoordinate get coordinates =>
      const CelestialCoordinate(ra: _raHours, dec: _decDegrees);
  @override
  double? get magnitude => null;
}

/// The text of the chip whose label is [label], e.g. 'Rise: ' -> '12:01'.
String? chipValue(WidgetTester tester, String label) {
  final texts = tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .toList();
  final index = texts.indexOf(label);
  if (index < 0 || index + 1 >= texts.length) return null;
  return texts[index + 1];
}

String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}';

void main() {
  testWidgets(
    'the footer rise time is the one the planner scored for the same night',
    (tester) async {
      // 03:00 — past local midnight, mid-session, which is when the chart's
      // wall-clock anchor and the planner's night anchor fall on opposite
      // sides of local noon.
      final now = DateTime(2026, 8, 2, 3, 0);

      // What the planner's warnings and the Night Outlook chips are computed
      // from: the real scorer, over the night that contains `now`.
      final twilight = AstronomyCalculations.calculateTwilightTimes(
        date: AstronomyCalculations.nightDateOf(now),
        latitudeDeg: _latitude,
        longitudeDeg: _longitude,
      );
      final scored = TargetScoringService(
        latitude: _latitude,
        longitude: _longitude,
        observationTime: now,
      ).scoreTargetForNight(
        target: _Fixture(),
        nightStart: twilight.astronomicalDusk!,
        nightEnd: twilight.astronomicalDawn!,
      );
      final expectedRise = scored.visibility.riseTime;
      expect(expectedRise, isNotNull);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsProvider.overrideWith(_SiteSettingsNotifier.new),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: Scaffold(
              body: SingleChildScrollView(
                child: AltitudeChart(
                  raHours: _raHours,
                  decDegrees: _decDegrees,
                  targetName: 'M92',
                  nowOverride: () => now,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        chipValue(tester, 'Rise: '),
        _hhmm(expectedRise!),
        reason: 'the card must not state a rise time the planner disagrees '
            'with for the same event',
      );
    },
  );
}
