// Settings → Location must not claim things it did not do.
//
// Three claims are pinned here:
//   1. "Sync from server" must not report a green "Location synced from server"
//      on a standalone desktop, where the read goes to this app's own settings
//      store and nothing is fetched from anywhere.
//   2. "Detect location" must ask before a lookup that can send the names of
//      the networks around the house, or the machine's public IP, to a third
//      party; must say which tier answered and inside what radius; must
//      prefer the precise tier over a coarse one whatever order they ran in;
//      and must not pass the OLD elevation through with new coordinates —
//      that yields a site that does not exist.
//   3. The Timezone picker must only offer values `clockProvider` can parse
//      (`UTC` / `UTC±HH:MM`); anything else silently falls back to the system
//      clock and the picker changes nothing at all.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/location_settings.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this.initial);

  final AppSettingsState initial;

  @override
  Future<AppSettingsState> build() async => initial;
}

Future<HarnessHandle> _pumpLocation(
  WidgetTester tester, {
  required AppSettingsState settings,
  bool isRemote = false,
  SiteLocator? locator,
  PlaceSearcher? searcher,
}) async {
  final handle = await pumpAppScreen(
    tester,
    const LocationSettingsPage(),
    size: const Size(1280, 1400),
    extraOverrides: [
      appSettingsProvider
          .overrideWith(() => _StubAppSettingsNotifier(settings)),
      isRemoteModeProvider.overrideWithValue(isRemote),
      if (locator != null) siteLocatorProvider.overrideWithValue(locator),
      if (searcher != null) placeSearchProvider.overrideWithValue(searcher),
    ],
  );
  await tester.pumpAndSettle();
  return handle;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Sync from server', () {
    testWidgets('is not offered on a standalone (local) session', (
      tester,
    ) async {
      await _pumpLocation(tester, settings: const AppSettingsState());
      expect(find.text('Sync from server'), findsNothing);
    });

    testWidgets('is offered when a host is actually connected', (tester) async {
      await _pumpLocation(
        tester,
        settings: const AppSettingsState(),
        isRemote: true,
      );
      expect(find.text('Sync from server'), findsOneWidget);
    });
  });

  group('Detect location', () {
    const seattle = AppSettingsState(
      latitude: 47.6062,
      longitude: -122.3321,
      elevation: 1234,
    );

    SiteLocator answering(PositioningAttempt attempt) => ({
          required bool allowWifiScan,
          required bool allowIp,
          bool mayEnableWifiRadio = false,
          String? googleApiKey,
        }) async =>
            attempt;

    Future<void> consentAndDetect(WidgetTester tester) async {
      await tester.tap(find.byIcon(LucideIcons.crosshair));
      await tester.pumpAndSettle();
      // The consent dialog's confirm button, not the row that opened it:
      // both read 'Detect location' now that the row title is sentence case.
      await tester.tap(
        find.widgetWithText(SkotiqButton, 'Detect location'),
      );
      await tester.pumpAndSettle();
    }

    const wifiFix = PositioningAttempt(
      fix: PositioningResult(
        latitude: 39.9817,
        longitude: -75.4072,
        accuracyMetres: 40,
        source: PositioningSource.wifiScan,
        provider: 'beaconDB',
        accessPointsUsed: 9,
      ),
      outcomes: [],
    );

    const ipFix = PositioningAttempt(
      fix: PositioningResult(
        latitude: 39.9817,
        longitude: -75.4072,
        source: PositioningSource.ipAddress,
        provider: 'ipinfo.io',
        locationName: 'Newtown Square, Pennsylvania',
      ),
      outcomes: [
        TierOutcome(
          tier: PositioningTier.wifiScan,
          succeeded: false,
          detail: 'Wi-Fi is switched off on this machine.',
        ),
      ],
      wifiRadioOff: true,
      wifiRadioCanBeEnabled: true,
    );

    testWidgets('is not labelled GPS', (tester) async {
      await _pumpLocation(tester, settings: seattle);
      expect(find.text('Get location from GPS'), findsNothing);
      expect(find.text('Detect location'), findsOneWidget);
    });

    testWidgets('asks before anything leaves the machine', (tester) async {
      var calls = 0;
      await _pumpLocation(
        tester,
        settings: seattle,
        locator: ({
          required bool allowWifiScan,
          required bool allowIp,
          bool mayEnableWifiRadio = false,
          String? googleApiKey,
        }) async {
          calls++;
          return ipFix;
        },
      );

      await tester.tap(find.byIcon(LucideIcons.crosshair));
      await tester.pumpAndSettle();

      expect(find.text('Detect this site’s location?'), findsOneWidget);
      // The dialog has to say what leaves the machine at each tier: the
      // nearby network names to beaconDB, and the public IP to ipinfo.io.
      expect(
          find.textContaining('beaconDB (an open positioning'), findsOneWidget);
      expect(
          find.textContaining('sent to ipinfo.io over HTTPS'), findsOneWidget);
      expect(find.textContaining('Your public IP address'), findsOneWidget);
      expect(calls, 0, reason: 'the lookup ran before the user consented');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, 0);
    });

    testWidgets('consent is asked once and then remembered for the session', (
      tester,
    ) async {
      await _pumpLocation(tester, settings: seattle, locator: answering(ipFix));

      await consentAndDetect(tester);
      expect(find.text('Detect this site’s location?'), findsNothing);

      await tester.tap(find.byIcon(LucideIcons.crosshair));
      await tester.pumpAndSettle();
      expect(
        find.text('Detect this site’s location?'),
        findsNothing,
        reason: 'the operator was asked the same question twice',
      );
    });

    testWidgets('a fix at another site clears the inherited elevation', (
      tester,
    ) async {
      final handle = await _pumpLocation(
        tester,
        settings: seattle,
        locator: answering(ipFix),
      );

      await consentAndDetect(tester);

      final settings = handle.container.read(appSettingsProvider).requireValue;
      expect(settings.latitude, closeTo(39.9817, 1e-6));
      // 1234 m came from Seattle; Pennsylvania's highest point is 979 m.
      expect(settings.elevation, 0);
      expect(find.textContaining('Elevation cleared to 0 m'), findsOneWidget);
    });

    testWidgets('a fix at the same site keeps the elevation', (tester) async {
      final handle = await _pumpLocation(
        tester,
        settings: seattle,
        // ~2 km from the stored position: the same observing site.
        locator: answering(
          const PositioningAttempt(
            fix: PositioningResult(
              latitude: 47.6242,
              longitude: -122.3321,
              accuracyMetres: 18,
              source: PositioningSource.platformService,
              provider: 'Windows Location Services',
            ),
            outcomes: [],
          ),
        ),
      );

      await consentAndDetect(tester);

      expect(
        handle.container.read(appSettingsProvider).requireValue.elevation,
        1234,
      );
      expect(find.textContaining('Elevation kept at 1234 m'), findsOneWidget);
    });

    testWidgets('a Wi-Fi fix names its radius and how many networks placed it',
        (tester) async {
      await _pumpLocation(tester,
          settings: seattle, locator: answering(wifiFix));

      await consentAndDetect(tester);

      expect(
        find.textContaining(
          'Located to within 40 m using 9 nearby Wi-Fi networks (beaconDB). ',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Refine on the map if it is off.'),
        findsOneWidget,
      );
      expect(find.textContaining('Approximate only'), findsNothing);
    });

    testWidgets(
        'an IP fix is written, named as approximate, and offers the '
        'precise tier', (tester) async {
      final handle = await _pumpLocation(
        tester,
        settings: seattle,
        locator: answering(ipFix),
      );

      await consentAndDetect(tester);

      expect(
        handle.container.read(appSettingsProvider).requireValue.latitude,
        closeTo(39.9817, 1e-6),
      );
      expect(
        find.textContaining(
          'Approximate only: from your internet address (ipinfo.io). City '
          'level — typically tens of kilometres.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Turn Wi-Fi on for a precise fix.'),
        findsWidgets,
        reason: 'a switched-off radio is the one cause the operator can fix',
      );
    });

    testWidgets(
        'the radio-off row appears only after a detect that hit it, '
        'and retries with the radio enabled', (tester) async {
      var sawRetryFlag = false;
      await _pumpLocation(
        tester,
        settings: seattle,
        locator: ({
          required bool allowWifiScan,
          required bool allowIp,
          bool mayEnableWifiRadio = false,
          String? googleApiKey,
        }) async {
          if (mayEnableWifiRadio) {
            sawRetryFlag = true;
            return wifiFix;
          }
          return ipFix;
        },
      );

      expect(
        find.text('Turn Wi-Fi on for a precise fix'),
        findsNothing,
        reason: 'the offer appeared before anything established Wi-Fi was off',
      );

      await consentAndDetect(tester);
      expect(find.text('Turn Wi-Fi on for a precise fix'), findsOneWidget);

      // Let the first confirmation expire: ScaffoldMessenger QUEUES snackbars,
      // so without this the second one never renders and the assertion below
      // would be reading the first message's text.
      await tester.pumpAndSettle(const Duration(seconds: 6));
      await tester.tap(find.widgetWithText(SkotiqButton, 'Scan'));
      await tester.pumpAndSettle();

      expect(sawRetryFlag, isTrue);
      expect(
        find.textContaining('Located to within 40 m'),
        findsOneWidget,
      );
      expect(
        find.text('Turn Wi-Fi on for a precise fix'),
        findsNothing,
        reason: 'the offer stayed up after the precise fix it asked for',
      );
    });

    testWidgets('a total failure names every tier’s reason', (tester) async {
      await _pumpLocation(
        tester,
        settings: seattle,
        locator: answering(
          const PositioningAttempt(
            fix: null,
            outcomes: [
              TierOutcome(
                tier: PositioningTier.platformService,
                succeeded: false,
                detail: 'This machine has no working location service.',
              ),
              TierOutcome(
                tier: PositioningTier.wifiScan,
                succeeded: false,
                detail: 'This machine has no Wi-Fi adapter.',
              ),
              TierOutcome(
                tier: PositioningTier.ipAddress,
                succeeded: false,
                detail: 'Neither ipinfo.io nor ipwho.is answered.',
              ),
            ],
          ),
        ),
      );

      await consentAndDetect(tester);

      expect(
        find.textContaining(
          'This machine has no working location service. This machine has no '
          'Wi-Fi adapter. Neither ipinfo.io nor ipwho.is answered.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the row leads with the tier that actually finds a yard', (
      tester,
    ) async {
      await _pumpLocation(tester, settings: seattle);
      expect(
        find.textContaining('Nearby Wi-Fi networks place you to within'),
        findsOneWidget,
      );
      expect(
        find.textContaining('search for a place by name instead'),
        findsNothing,
      );
    });
  });

  group('Advanced', () {
    testWidgets('the Google key field says what it is for, without a link', (
      tester,
    ) async {
      await _pumpLocation(tester, settings: const AppSettingsState());

      expect(find.text('Google Geolocation API key'), findsOneWidget);
      expect(
        find.textContaining('mapped by volunteers and has no coverage'),
        findsOneWidget,
      );
      expect(find.textContaining('http'), findsNothing);
    });

    testWidgets('a key entered here is what the lookup is given', (
      tester,
    ) async {
      String? seenKey;
      await _pumpLocation(
        tester,
        settings: const AppSettingsState(),
        locator: ({
          required bool allowWifiScan,
          required bool allowIp,
          bool mayEnableWifiRadio = false,
          String? googleApiKey,
        }) async {
          seenKey = googleApiKey;
          return const PositioningAttempt(fix: null, outcomes: []);
        },
      );

      await tester.enterText(
        find.widgetWithText(SkotiqTextField, 'Paste a key, or leave empty'),
        'AIza-test',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(LucideIcons.crosshair));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(SkotiqButton, 'Detect location'),
      );
      await tester.pumpAndSettle();

      expect(seenKey, 'AIza-test');
    });
  });

  group('Search place', () {
    testWidgets('choosing a hit writes the town and its elevation', (
      tester,
    ) async {
      final handle = await _pumpLocation(
        tester,
        settings: const AppSettingsState(elevation: 1234),
        searcher: (query) async {
          expect(query, 'Newtown Square');
          return const [
            PlaceSearchHit(
              latitude: 39.9868,
              longitude: -75.4010,
              elevation: 127,
              label: 'Newtown Square, Pennsylvania, United States',
            ),
          ];
        },
      );

      await tester.enterText(
        find.byType(SkotiqTextField).first,
        'Newtown Square',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      await tester.tap(
        find.textContaining('Newtown Square, Pennsylvania, United States'),
      );
      await tester.pumpAndSettle();

      final settings = handle.container.read(appSettingsProvider).requireValue;
      expect(settings.latitude, closeTo(39.9868, 1e-6));
      expect(settings.longitude, closeTo(-75.4010, 1e-6));
      expect(settings.elevation, 127);
      expect(
        find.textContaining('Elevation 127 m'),
        findsOneWidget,
      );
    });
  });

  group('Timezone', () {
    testWidgets('every offered value actually drives the clock', (
      tester,
    ) async {
      final handle = await _pumpLocation(
        tester,
        settings: const AppSettingsState(useSystemTime: false),
      );
      final container = handle.container;
      final notifier = container.read(appSettingsProvider.notifier);

      // Read the options off the rendered picker, not off the constant, so
      // re-populating the dropdown with labels the clock cannot parse fails
      // here rather than passing against a list nothing displays.
      final picker = tester.widget<SkotiqDropdown>(
        find.byType(SkotiqDropdown).last,
      );
      final offered = picker.items;
      expect(offered, isNotEmpty);

      final inert = <String>[];
      for (final item in offered) {
        await notifier.setTimezone(item);
        await tester.pump();
        if (container.read(clockProvider) is! FixedOffsetClock) {
          inert.add(item);
        }
      }
      expect(
        inert,
        isEmpty,
        reason: 'these picker entries fall back to the system clock, so '
            'choosing them changes nothing: $inert',
      );
    });

    testWidgets('choosing an offset in the UI shifts the app clock', (
      tester,
    ) async {
      final handle = await _pumpLocation(
        tester,
        settings: const AppSettingsState(useSystemTime: false),
      );

      // The Timezone row owns the last dropdown on the page (Bortle owns the
      // first). Driving the real control is the point: it proves the value the
      // picker emits is one the clock can honour.
      final picker = find.byType(SkotiqDropdown).last;
      await tester.ensureVisible(picker);
      await tester.pumpAndSettle();
      await tester.tap(picker);
      await tester.pumpAndSettle();

      final option = find.text('UTC+05:30').last;
      await tester.ensureVisible(option);
      await tester.pumpAndSettle();
      await tester.tap(option);
      await tester.pumpAndSettle();

      final clock = handle.container.read(clockProvider);
      expect(clock, isA<FixedOffsetClock>());
      expect(
        (clock as FixedOffsetClock).utcOffset,
        const Duration(hours: 5, minutes: 30),
      );
      expect(
        handle.container.read(appSettingsProvider).requireValue.timezone,
        'UTC+05:30',
      );
    });

    testWidgets('a stored IANA label is migrated so the choice takes effect', (
      tester,
    ) async {
      final handle = await _pumpLocation(
        tester,
        settings: const AppSettingsState(
          timezone: 'Asia/Tokyo',
          useSystemTime: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        handle.container.read(appSettingsProvider).requireValue.timezone,
        'UTC+09:00',
      );
      final clock = handle.container.read(clockProvider);
      expect(clock, isA<FixedOffsetClock>());
      expect((clock as FixedOffsetClock).utcOffset, const Duration(hours: 9));
    });

    testWidgets('the row reports the clock the app is really running on', (
      tester,
    ) async {
      await _pumpLocation(
        tester,
        settings: const AppSettingsState(
          timezone: 'UTC+05:00',
          useSystemTime: false,
        ),
      );

      // The row rendered a moment before this line runs; if the wall clock
      // ticked over a minute in between, the rendered time is one minute
      // behind the one computed here. Accept either — the row's claim is
      // about the offset, not sub-minute freshness.
      final after = DateTime.now().toUtc().add(const Duration(hours: 5));
      final candidates = [after, after.subtract(const Duration(minutes: 1))]
          .map(
            (t) => '${t.hour.toString().padLeft(2, '0')}:'
                '${t.minute.toString().padLeft(2, '0')}',
          )
          .toSet();
      expect(
        candidates.any(
          (hhmm) => find
              .textContaining('UTC+05:00 — now $hhmm')
              .evaluate()
              .isNotEmpty,
        ),
        isTrue,
        reason: 'the Timezone row must show the time the chosen offset '
            'produces, not the host time',
      );
    });

    testWidgets('with system time on, the row says the picker is ignored', (
      tester,
    ) async {
      await _pumpLocation(tester, settings: const AppSettingsState());
      expect(
        find.textContaining('Ignored while "Use system time" is on'),
        findsOneWidget,
      );
    });
  });
}
