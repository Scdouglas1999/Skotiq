// With no observing site configured, the framing Altitude card must not state
// an altitude.
//
// `_calculateData` bails out when lat/lon are both 0 (the "no site" sentinel),
// which left `_currentAltitude` at its `0` initial value. The chip then rendered
// a hard red "Alt: 0.0°" — a specific factual claim that the target is sitting
// on the horizon — directly above the panel that admits the app has no location
// ("Set location in Settings"). The Coordinates card immediately above already
// shows "--" in the same situation, so the two cards contradicted each other.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/altitude_chart.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// No observing site: latitude and longitude are both the 0 sentinel.
class _NoSiteSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

/// A real site, so the chart computes a genuine altitude.
class _ConfiguredSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(latitude: 40, longitude: -75);
}

void main() {
  /// Captured from the pumped tree so the assertions compare against the very
  /// same design-system palette the widget rendered with.
  SkotiqColors? paletteUnderTest;

  Future<List<String>> pumpChart(
    WidgetTester tester, {
    required AppSettingsNotifier Function() settings,
  }) async {
    paletteUnderTest = null;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appSettingsProvider.overrideWith(settings)],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: SingleChildScrollView(
              child: Builder(
                builder: (context) {
                  paletteUnderTest = SkotiqColors.of(context);
                  return AltitudeChart(
                    raHours: 5.5,
                    decDegrees: -5.4,
                    targetName: 'M42',
                    nowOverride: () => DateTime.utc(2026, 7, 29, 16, 17),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? '')
        .toList();
  }

  testWidgets('no site configured shows "--", never a red 0.0 degrees',
      (tester) async {
    final texts =
        await pumpChart(tester, settings: _NoSiteSettingsNotifier.new);

    // The honest admission is present…
    expect(texts, contains('Set location in Settings'));
    // …and there is no fabricated altitude beside it.
    expect(
      texts.where((t) => t.contains('0.0°')),
      isEmpty,
      reason: 'rendered a concrete altitude with no observing site: $texts',
    );
    expect(texts, contains('Alt: '));
    // The copy rules put ONE em dash behind an unknown value, everywhere
    // (03 §2): '--' was two hyphens pretending to be one.
    expect(texts.where((t) => t == kReadoutUnknown).length,
        greaterThanOrEqualTo(2),
        reason:
            'expected Alt and Airmass to both read an em dash, got: $texts');
  });

  testWidgets('the unknown-altitude chip carries no severity colour',
      (tester) async {
    await pumpChart(tester, settings: _NoSiteSettingsNotifier.new);

    final colors = paletteUnderTest!;
    final dashes = tester
        .widgetList<Text>(find.byType(Text))
        .where((text) => text.data == kReadoutUnknown)
        .toList();
    expect(dashes, isNotEmpty);
    for (final dash in dashes) {
      expect(
        dash.style?.color,
        colors.textMuted,
        reason: 'an unknown value must not be coloured as a severity',
      );
      expect(dash.style?.color, isNot(colors.error));
    }
  });

  testWidgets('a configured site still reports a real altitude',
      (tester) async {
    final texts = await pumpChart(
      tester,
      settings: _ConfiguredSettingsNotifier.new,
    );

    expect(texts, isNot(contains('Set location in Settings')));
    // Some concrete degree value is printed for Alt.
    expect(
      texts.any((t) => t.endsWith('°')),
      isTrue,
      reason: 'expected a real altitude readout, got: $texts',
    );
  });
}
