// Observing-site step.
//
// After "Use my current location" fills the coordinate fields in, the banner
// directly above them must not still read "No site on record yet" and offer
// "Estimate from IP" — the screen denying what it has just done. An offer
// latched once at seed time and never re-derived does exactly that. The same
// detection must not write 39.9527237 / -75.1635262 into the fields either:
// seven decimals, about a centimetre, for a lookup the app's own consent dialog
// calls accurate to roughly 10 km.
//
// And the consent dialog must not render ~680 px tall for two short paragraphs,
// its body floating between ~230 px of empty space above and ~225 px below.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/site_step.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// What a desktop with no GPS receiver and a switched-off radio lands: the
/// IP estimate, to seven raw decimals, tagged with the host that supplied it,
/// and the note that the precise tier never ran.
const _philadelphia = PositioningAttempt(
  fix: PositioningResult(
    latitude: 39.9527237,
    longitude: -75.1635262,
    source: PositioningSource.ipAddress,
    provider: 'ipinfo.io',
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

/// What the Wi-Fi tier lands where a positioning service has coverage: the
/// same button, tens of metres, from the radios within earshot.
const _wifiFix = PositioningAttempt(
  fix: PositioningResult(
    latitude: 39.9527237,
    longitude: -75.1635262,
    accuracyMetres: 42,
    source: PositioningSource.wifiScan,
    provider: 'beaconDB',
    accessPointsUsed: 11,
  ),
  outcomes: [],
);

/// And what a machine that does have a receiver lands.
const _deviceFix = PositioningAttempt(
  fix: PositioningResult(
    latitude: 39.9527237,
    longitude: -75.1635262,
    accuracyMetres: 14,
    source: PositioningSource.platformService,
    provider: 'Windows Location Services',
  ),
  outcomes: [],
);

SiteLocator _answering(PositioningAttempt attempt) => ({
      required bool allowWifiScan,
      required bool allowIp,
      bool mayEnableWifiRadio = false,
      String? googleApiKey,
    }) async =>
        attempt;

Future<ProviderContainer> _pumpSiteStep(
  WidgetTester tester,
  SkotiqDatabase db, {
  SiteLocator? locator,
}) async {
  late ProviderContainer container;
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 720);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        onboardingApproximateLocationProvider
            .overrideWithValue(() async => null),
        onboardingSiteLocatorProvider.overrideWithValue(
          locator ??
              _answering(
                const PositioningAttempt(fix: null, outcomes: []),
              ),
        ),
      ],
      child: Consumer(builder: (ctx, ref, _) {
        container = ProviderScope.containerOf(ctx);
        return MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(24),
              child: OnboardingSiteStep(),
            ),
          ),
        );
      }),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
  });

  testWidgets('the "no site on record" offer retires once a site is detected',
      (tester) async {
    final container = await _pumpSiteStep(
      tester,
      db,
      locator: _answering(_philadelphia),
    );

    expect(find.textContaining('No site on record yet'), findsOneWidget);

    await tester.tap(find.text('Use my current location'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Detect location'));
    await tester.pumpAndSettle();

    expect(container.read(appSettingsProvider).valueOrNull?.latitude, 39.9527);
    expect(find.textContaining('No site on record yet'), findsNothing);
    expect(find.text('Estimate from IP'), findsNothing);
  });

  testWidgets('a detected coordinate is not printed to seven decimals',
      (tester) async {
    await _pumpSiteStep(
      tester,
      db,
      locator: _answering(_philadelphia),
    );

    await tester.tap(find.text('Use my current location'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Detect location'));
    await tester.pumpAndSettle();

    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(fields.first.controller?.text, '39.9527');
    expect(
      fields.elementAt(1).controller?.text,
      '-75.1635',
      reason: 'an estimate good to ~10 km must not claim centimetres',
    );
  });

  testWidgets('the consent dialog is sized to its two paragraphs',
      (tester) async {
    await _pumpSiteStep(tester, db);
    // A tall window is where the stretch showed: the dialog took 85% of it
    // whatever the body needed.
    tester.view.physicalSize = const Size(1280, 1000);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Use my current location'));
    await tester.pumpAndSettle();

    // AlertDialog's own box is the full-screen Align that centres the surface,
    // so the panel the operator sees is the Material inside it. What the
    // finding is about is the dead space around the body, not the body's own
    // height: the prose was floated in the middle of a card stretched to 85%
    // of the viewport, leaving ~230 px empty above it and ~225 px below.
    final surface = tester.getRect(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Material),
          )
          .first,
    );
    final body = tester.getRect(
      find.textContaining('Skotiq will try these in order'),
    );

    expect(
      body.top - surface.top,
      lessThan(130),
      reason: 'only the title belongs between the card edge and the body',
    );
    expect(
      surface.bottom - body.bottom,
      lessThan(160),
      reason: 'only the action row belongs below the body',
    );
  });

  // The consent dialog must say what leaves the machine at EACH tier — the
  // names of the networks around the house, and the public IP — because those
  // are two different disclosures and the Wi-Fi one is new.
  testWidgets('the consent dialog names both outbound tiers', (tester) async {
    await _pumpSiteStep(tester, db);

    await tester.tap(find.text('Use my current location'));
    await tester.pumpAndSettle();

    // The banner's "public IP" offer text is also on screen, so assert the
    // sentences only the dialog carries.
    expect(
      find.textContaining(
        'The names and signal strengths of nearby Wi-Fi networks, sent to '
        'beaconDB (an open positioning service)',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Your public IP address, sent to ipinfo.io over '
          'HTTPS (falling back to ipwho.is)'),
      findsOneWidget,
    );
  });

  // The Estimate-from-IP offer sends only the public IP. Consenting to it must
  // not carry over as permission to scan for Wi-Fi and put the names of the
  // networks around the house on the wire.
  testWidgets('the IP-estimate offer does not ask for the Wi-Fi tier',
      (tester) async {
    await _pumpSiteStep(tester, db);

    await tester.tap(find.text('Estimate from IP'));
    await tester.pumpAndSettle();

    expect(find.text('Detect this site’s location?'), findsOneWidget);
    expect(find.textContaining('nearby Wi-Fi networks'), findsNothing);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Detect location'));
    await tester.pumpAndSettle();

    // The narrower consent must not satisfy the wider one.
    await tester.tap(find.text('Use my current location'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('nearby Wi-Fi networks'),
      findsOneWidget,
      reason: 'IP consent was reused to authorise a Wi-Fi scan',
    );
  });

  // A desktop with no GPS still lands a site in one click — and the
  // confirmation names the internet path, because a ~10 km estimate is not
  // the same answer a receiver gives.
  testWidgets('an internet fix is written and named as approximate',
      (tester) async {
    final container = await _pumpSiteStep(
      tester,
      db,
      locator: _answering(_philadelphia),
    );

    await tester.tap(find.text('Use my current location'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Detect location'));
    await tester.pumpAndSettle();

    expect(
      container.read(appSettingsProvider).valueOrNull?.latitude,
      39.9527,
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
    );
  });

  // The whole point of the feature: where a positioning service has coverage,
  // one click puts the rig in its own yard and says by how much.
  testWidgets('a Wi-Fi fix names its radius and the networks that placed it',
      (tester) async {
    await _pumpSiteStep(tester, db, locator: _answering(_wifiFix));

    await tester.tap(find.text('Use my current location'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Detect location'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        'Located to within 42 m using 11 nearby Wi-Fi networks (beaconDB).',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Correct the coordinates below'),
      findsNothing,
      reason: 'a 42 m fix does not need correcting by hand',
    );
  });

  testWidgets(
      'a switched-off radio is offered as a one-click fix, and the '
      'retry asks for it', (tester) async {
    var sawRetryFlag = false;
    await _pumpSiteStep(
      tester,
      db,
      locator: ({
        required bool allowWifiScan,
        required bool allowIp,
        bool mayEnableWifiRadio = false,
        String? googleApiKey,
      }) async {
        if (mayEnableWifiRadio) {
          sawRetryFlag = true;
          return _wifiFix;
        }
        return _philadelphia;
      },
    );

    const bannerBody = 'will switch it on, scan for nearby networks';
    expect(find.textContaining(bannerBody), findsNothing);

    await tester.tap(find.text('Use my current location'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Detect location'));
    await tester.pumpAndSettle();

    expect(find.textContaining(bannerBody), findsOneWidget);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Scan'));
    await tester.pumpAndSettle();

    expect(sawRetryFlag, isTrue);
    expect(find.textContaining(bannerBody), findsNothing);
  });

  testWidgets('a platform-service fix names the service and its metres',
      (tester) async {
    final container = await _pumpSiteStep(
      tester,
      db,
      locator: _answering(_deviceFix),
    );

    await tester.tap(find.text('Use my current location'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Detect location'));
    await tester.pumpAndSettle();

    expect(
      container.read(appSettingsProvider).valueOrNull?.latitude,
      39.9527,
    );
    expect(
      find.textContaining(
        'Located to within 14 m by Windows Location Services.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Approximate only'), findsNothing);
  });
}
