import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/tonight_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    as planetarium;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// With no site set the observer providers fall back to 0°N 0°E, which yields a
/// complete equatorial dusk and a ~9h dark window — beside the card's own
/// "Location needed" row.
class _SiteSettings extends AppSettingsNotifier {
  _SiteSettings(this.latitude, this.longitude);

  final double latitude;
  final double longitude;

  @override
  Future<AppSettingsState> build() async =>
      AppSettingsState(latitude: latitude, longitude: longitude);
}

Future<ProviderContainer> _pumpCard(
  WidgetTester tester, {
  required double latitude,
  required double longitude,
}) async {
  final handle = await pumpAppScreen(
    tester,
    const TonightCard(colors: SkotiqColors.dark),
    settle: false,
    registerTearDown: false,
    extraOverrides: [
      appSettingsProvider
          .overrideWith(() => _SiteSettings(latitude, longitude)),
      smartNightExposureContextProvider.overrideWith((ref) async => null),
      tonightSuggestionsProvider.overrideWith((ref) async => const []),
      // The twilight provider is location-driven in production; pin it here so
      // the test isolates the CARD's gate rather than re-testing astronomy.
      planetarium.twilightTimesProvider
          .overrideWithValue(planetarium.TwilightTimes(
        astronomicalDusk: DateTime(2026, 8, 2, 15, 22),
        astronomicalDawn: DateTime(2026, 8, 3, 0, 50),
      )),
      planetarium.moonInfoProvider.overrideWithValue(
        const planetarium.MoonTimes(illumination: 90, phaseName: 'Waning'),
      ),
      planetarium.observationTimeProvider.overrideWith(
        (ref) => planetarium.ObservationTimeNotifier()
          ..setTime(DateTime(2026, 8, 2, 12)),
      ),
    ],
  );
  addTearDown(handle.database.close);
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return handle.container;
}

/// Must run INSIDE the test body: the observation-time notifier holds a 1s
/// periodic timer, and the pending-timer invariant is checked before teardown.
Future<void> _dispose(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(const SizedBox.shrink());
  container.dispose();
  // Tearing down the container closes drift's watch streams, and
  // StreamQueryStore.markAsClosed posts a zero-duration cleanup timer per
  // stream. Pump WITH a duration — a bare pump() does not elapse the fake
  // clock — so they fire inside the test instead of tripping the same
  // pending-timer invariant this helper exists to avoid.
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  testWidgets('no site: twilight and window render as placeholders',
      (tester) async {
    final container = await _pumpCard(tester, latitude: 0, longitude: 0);

    expect(find.text('15:22'), findsNothing);
    expect(find.text('9h 28m'), findsNothing);
    // 06 copy rules: an unknown value is an em dash. `--:--` was the old
    // placeholder and is now forbidden everywhere in the app.
    expect(find.text('--:--'), findsNothing);
    expect(find.text(kReadoutUnknown), findsNWidgets(2));
    expect(find.text('90%'), findsOneWidget,
        reason: 'moon illumination is a phase, not a site quantity');
    await _dispose(tester, container);
  });

  testWidgets('with a site: twilight and window render real numbers',
      (tester) async {
    final container = await _pumpCard(tester, latitude: 40, longitude: -75);

    expect(find.text('15:22'), findsOneWidget);
    expect(find.text('9h 28m'), findsOneWidget);
    await _dispose(tester, container);
  });
}
