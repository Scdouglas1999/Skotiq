// The "Alt:" / "Airmass:" chips are present tense, so they must keep up with
// the clock.
//
// AltitudeChart computed _currentAltitude/_currentAirmass only in
// _calculateData, which ran from initState and from didUpdateWidget when
// ra/dec changed. There was no timer and no clock provider anywhere in the
// widget, so on the planner's Night Outlook hero card the chip read
// "Alt: 14.7°  Airmass: 3.88" at 10:00 and still read exactly 14.7 / 3.88 at
// 10:17 — a stale altitude stated as the current one. The candidate-list card
// for the same object appeared to disagree only because scrolling recycled it
// through initState again.

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/altitude_chart.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show
        AppSettingsNotifier,
        AppSettingsState,
        SchedulerConfig,
        appSettingsProvider,
        schedulerPersistedConfigProvider;
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

const _latitude = 40.0;
const _longitude = -75.0;

class _SiteSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(latitude: _latitude, longitude: _longitude);
}

/// The text of the chip whose label is [label], e.g. 'Alt: ' -> '21.1°'.
String? chipValue(WidgetTester tester, String label) {
  final texts = tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .toList();
  final index = texts.indexOf(label);
  if (index < 0 || index + 1 >= texts.length) return null;
  return texts[index + 1];
}

void main() {
  testWidgets('the Alt/Airmass readout tracks the clock, it does not freeze', (
    tester,
  ) async {
    // Mid-night so the target is up and the chips render numbers. RA 16h27m /
    // Dec -3.2 (M14) is well east of the meridian at this instant, so its
    // altitude is climbing fast enough to be unmistakable over 20 minutes.
    var now = DateTime(2026, 7, 30, 1, 30);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          appSettingsProvider.overrideWith(_SiteSettingsNotifier.new)
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: SingleChildScrollView(
              child: AltitudeChart(
                raHours: 16.45,
                decDegrees: -3.25,
                targetName: 'M14',
                nowOverride: () => now,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final altAtMount = chipValue(tester, 'Alt: ');
    final airmassAtMount = chipValue(tester, 'Airmass: ');
    expect(altAtMount, isNotNull);
    expect(airmassAtMount, isNotNull);

    // Twenty minutes pass with the card on screen and nothing else touched:
    // no rebuild from a parent, no scroll, no ra/dec change.
    now = now.add(const Duration(minutes: 20));
    await tester.pump(const Duration(minutes: 20));

    expect(
      chipValue(tester, 'Alt: '),
      isNot(altAtMount),
      reason: 'the chip is labelled in the present tense; 20 minutes of sky '
          'rotation must show up in it',
    );
    expect(chipValue(tester, 'Airmass: '), isNot(airmassAtMount));
  });

  testWidgets('the ticker is cancelled when the card leaves the tree', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          appSettingsProvider.overrideWith(_SiteSettingsNotifier.new)
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: SingleChildScrollView(
              child: AltitudeChart(
                raHours: 16.45,
                decDegrees: -3.25,
                nowOverride: () => DateTime(2026, 7, 30, 1, 30),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Tearing the tree down leaves no pending timer — flutter_test fails the
    // test itself if one survives, which is the assertion here.
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.pump(const Duration(minutes: 5));
  });

  testWidgets('the threshold line marks the SITE minimum, not a fixed 30 deg', (
    tester,
  ) async {
    // The dashed warning line is what the operator reads as "below this I
    // cannot image". It was hard-coded to 30 while the scheduler gated on its
    // own configured value, so the two contradicted each other on one screen.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          appSettingsProvider.overrideWith(_SiteSettingsNotifier.new),
          schedulerPersistedConfigProvider.overrideWith(
            (ref) => SchedulerConfig.defaults.copyWith(minAltitudeDegrees: 45),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: SingleChildScrollView(
              child: AltitudeChart(
                raHours: 16.45,
                decDegrees: -3.25,
                nowOverride: () => DateTime(2026, 7, 30, 1, 30),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final chart = tester.widget<LineChart>(find.byType(LineChart));
    final thresholds = chart.data.extraLinesData.horizontalLines
        .where((line) => line.dashArray != null)
        .toList();
    expect(thresholds, hasLength(1));
    expect(thresholds.single.y, 45);
  });
}
