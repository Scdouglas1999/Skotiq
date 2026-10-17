// The framing altitude chart states three clock faces about the SITE — the
// Rise / Transit / Set chips, the time axis and the touch tooltip — so all
// three must follow Settings → Location → Timezone. Formatting host-local time
// leaves this card on the controlling laptop's zone while the status bar and
// the dashboard move.
//
// The chart's astronomy is deliberately NOT rebased: `nowOverride` /
// `DateTime.now()` still supply the true instant, because shifting the input
// would move the rise/transit/set solve itself. Only the rendering follows the
// operator's chosen zone — which is why this test pins the same solve under two
// different timezones and asserts the SOLVE is identical while the FACES move.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/altitude_chart.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show AppSettingsNotifier, AppSettingsState, appSettingsProvider;
import 'package:skotiq_ui/skotiq_ui.dart';

const _latitude = 40.0;
const _longitude = -75.0;
const _raHours = 17.285;
const _decDegrees = 43.136;

class _SiteSettingsNotifier extends AppSettingsNotifier {
  _SiteSettingsNotifier(this.timezone);

  final String timezone;

  @override
  Future<AppSettingsState> build() async => AppSettingsState(
        latitude: _latitude,
        longitude: _longitude,
        timezone: timezone,
        useSystemTime: false,
      );
}

/// The text of the chip whose label is [label], e.g. 'Rise: ' -> '12:01'.
String? _chipValue(WidgetTester tester, String label) {
  final texts = tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .toList();
  final index = texts.indexOf(label);
  if (index < 0 || index + 1 >= texts.length) return null;
  return texts[index + 1];
}

Future<Map<String, String?>> _facesUnder(
  WidgetTester tester,
  String timezone,
) async {
  await tester.pumpWidget(
    ProviderScope(
      // Keyed by the zone so the second pump builds a FRESH scope: without it
      // Flutter updates the existing ProviderScope element in place and the
      // first timezone's already-resolved AppSettingsState survives, so both
      // pumps report the same face whatever the widget does — a test that can
      // only pass.
      key: ValueKey(timezone),
      overrides: [
        appSettingsProvider.overrideWith(() => _SiteSettingsNotifier(timezone)),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SingleChildScrollView(
            child: AltitudeChart(
              raHours: _raHours,
              decDegrees: _decDegrees,
              targetName: 'M92',
              nowOverride: () => DateTime(2026, 8, 2, 3, 0),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));

  return <String, String?>{
    'rise': _chipValue(tester, 'Rise: '),
    'transit': _chipValue(tester, 'Transit: '),
    'set': _chipValue(tester, 'Set: '),
  };
}

/// Minutes past midnight for an `HH:MM` face, so two faces can be compared
/// modulo the day they land on.
int _minutes(String hhmm) {
  final parts = hhmm.split(':');
  return int.parse(parts[0]) * 60 + int.parse(parts[1]);
}

void main() {
  testWidgets('the rise/transit/set faces follow the chosen site timezone',
      (tester) async {
    final utc = await _facesUnder(tester, 'UTC');
    expect(utc['rise'], isNotNull,
        reason: 'the fixture target must rise on this night');
    expect(utc['transit'], isNotNull);

    final plusNine = await _facesUnder(tester, 'UTC+09:00');

    for (final key in const ['rise', 'transit', 'set']) {
      final a = utc[key];
      final b = plusNine[key];
      if (a == null || b == null) continue;
      // Same instant, nine hours of offset apart: the underlying solve is
      // untouched, only the face the operator reads has moved.
      expect(
        (_minutes(b) - _minutes(a)) % (24 * 60),
        9 * 60,
        reason: '"$key" must render 9h later under UTC+09:00 '
            '(UTC $a vs UTC+09:00 $b)',
      );
    }
  });
}
