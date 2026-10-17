// Every clock face on the Dashboard has to be in the same zone.
//
// Settings → Location → Timezone was wired into the status bar, the header
// chip, the night timeline and the moon card, but two cards on the same screen
// kept formatting twilight straight off the host clock: the Tonight card's
// "Twilight HH:MM" row and the cockpit sky panel's idle "astro dark HH:MM →
// HH:MM" summary. An operator running a rig five zones away therefore read
// "now 23:47" beside "Twilight 15:22", with nothing on screen saying the two
// numbers belonged to different places.
//
// The offset is derived from the HOST offset at run time, so the expected
// reading differs from host-local by a known five hours on any machine.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/cockpit_sky_context.dart';
import 'package:skotiq_app/screens/dashboard/widgets/tonight_card.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'package:skotiq_app/services/observing_site.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart' as planetarium;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// A `UTC±HH:MM` label five hours ahead of this host, so the expected reading
/// can never coincide with host-local time.
String _fiveHoursAheadOfHost() {
  final target = DateTime.now().timeZoneOffset + const Duration(hours: 5);
  final sign = target.isNegative ? '-' : '+';
  final abs = target.abs();
  final hh = abs.inHours.toString().padLeft(2, '0');
  final mm = (abs.inMinutes % 60).toString().padLeft(2, '0');
  return 'UTC$sign$hh:$mm';
}

class _ZoneSettings extends AppSettingsNotifier {
  _ZoneSettings({required this.useSystemTime, required this.timezone});

  final bool useSystemTime;
  final String timezone;

  @override
  Future<AppSettingsState> build() async => AppSettingsState(
        latitude: 40,
        longitude: -75,
        useSystemTime: useSystemTime,
        timezone: timezone,
      );
}

final _dusk = DateTime(2026, 8, 2, 15, 22);
final _dawn = DateTime(2026, 8, 3, 0, 50);

List<Override> _overrides({required bool useSystemTime}) => [
      appSettingsProvider.overrideWith(
        () => _ZoneSettings(
          useSystemTime: useSystemTime,
          timezone: _fiveHoursAheadOfHost(),
        ),
      ),
      smartNightExposureContextProvider.overrideWith((ref) async => null),
      tonightSuggestionsProvider.overrideWith((ref) async => const []),
      // Pinned so the test isolates the CARD's rendering rather than re-testing
      // astronomy. Twilight instants do not depend on the display zone.
      planetarium.twilightTimesProvider.overrideWithValue(
        planetarium.TwilightTimes(
            astronomicalDusk: _dusk, astronomicalDawn: _dawn),
      ),
      siteTwilightTimesProvider.overrideWithValue(
        planetarium.TwilightTimes(
            astronomicalDusk: _dusk, astronomicalDawn: _dawn),
      ),
      planetarium.moonInfoProvider.overrideWithValue(
        const planetarium.MoonTimes(illumination: 90, phaseName: 'Waning'),
      ),
      planetarium.observationTimeProvider.overrideWith(
        (ref) => planetarium.ObservationTimeNotifier()
          ..setTime(DateTime(2026, 8, 2, 12)),
      ),
      runDashboardActiveTargetProvider.overrideWithValue(null),
    ];

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget child, {
  required bool useSystemTime,
}) async {
  final handle = await pumpAppScreen(
    tester,
    child,
    settle: false,
    registerTearDown: false,
    extraOverrides: _overrides(useSystemTime: useSystemTime),
  );
  addTearDown(handle.database.close);
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return handle.container;
}

/// Must run INSIDE the test body: the observation-time notifier holds a 1 s
/// periodic timer and the pending-timer invariant is checked before teardown.
Future<void> _dispose(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(const SizedBox.shrink());
  container.dispose();
  await tester.pump(const Duration(milliseconds: 1));
}

/// [t] as the operator five hours east of the host would read it.
String _shifted(DateTime t, {required bool withSeconds}) {
  final shown = t.add(const Duration(hours: 5));
  final hh = shown.hour.toString().padLeft(2, '0');
  final mm = shown.minute.toString().padLeft(2, '0');
  if (!withSeconds) return '$hh:$mm';
  return '$hh:$mm:${shown.second.toString().padLeft(2, '0')}';
}

void main() {
  testWidgets('Tonight card twilight follows the chosen zone', (tester) async {
    final container = await _pump(
      tester,
      const TonightCard(colors: SkotiqColors.dark),
      useSystemTime: false,
    );

    expect(
      find.text(_shifted(_dusk, withSeconds: false)),
      findsOneWidget,
      reason: 'the card still prints host-local twilight next to a status bar '
          'and header clock that both moved to the site zone',
    );
    expect(find.text('15:22'), findsNothing);
    await _dispose(tester, container);
  });

  testWidgets('Tonight card is untouched on host time', (tester) async {
    final container = await _pump(
      tester,
      const TonightCard(colors: SkotiqColors.dark),
      useSystemTime: true,
    );

    expect(find.text('15:22'), findsOneWidget);
    await _dispose(tester, container);
  });

  testWidgets('idle sky-context astro-dark window follows the chosen zone', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      const CockpitSkyContext(),
      useSystemTime: false,
    );

    final expected =
        'No target — astro dark ${_shifted(_dusk, withSeconds: true)}'
        '→${_shifted(_dawn, withSeconds: true)} · Moon 90%';
    expect(find.text(expected), findsOneWidget);
    await _dispose(tester, container);
  });

  testWidgets('idle sky-context is untouched on host time', (tester) async {
    final container = await _pump(
      tester,
      const CockpitSkyContext(),
      useSystemTime: true,
    );

    expect(
      find.text('No target — astro dark 15:22:00→00:50:00 · Moon 90%'),
      findsOneWidget,
    );
    await _dispose(tester, container);
  });
}
