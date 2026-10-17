// Widget tests for the equipment-onboarding wizard (F4-ONBOARDING-WIZARD).
//
// We test each step body in isolation by wrapping it in a Scaffold with
// real Riverpod providers backed by an in-memory Drift database. This
// proves each step renders, accepts input, validates, and persists.
//
// The integration test at the bottom of the file walks the full happy
// path through OnboardingScreen end-to-end.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/onboarding/onboarding_screen.dart';
import 'package:skotiq_app/screens/onboarding/steps/capture_dir_step.dart';
import 'package:skotiq_app/screens/onboarding/steps/driver_step.dart';
import 'package:skotiq_app/screens/onboarding/steps/optical_train_step.dart';
import 'package:skotiq_app/screens/onboarding/steps/site_step.dart';
import 'package:skotiq_app/screens/onboarding/steps/summary_step.dart';
import 'package:skotiq_app/screens/onboarding/steps/welcome_step.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

SkotiqDatabase _newDb() => SkotiqDatabase.forTesting(NativeDatabase.memory());

Future<void> _pumpStep(
  WidgetTester tester, {
  required SkotiqDatabase db,
  required Widget step,
  Set<DriverType>? availableDrivers,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 900);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        // OnboardingWelcomeStep reads `allProfilesProvider`, which
        // transitively depends on `backendProvider`. Without an override
        // the default `BackendNotifier` is constructed, which spins up
        // FFI-bound recurring timers; widget tests then fail with
        // "A Timer is still pending even after the widget tree was
        // disposed" and the runner stalls until its 10-minute deadline.
        // Providing a synchronous empty stream short-circuits the chain.
        allProfilesProvider.overrideWith((ref) => const Stream.empty()),
        if (availableDrivers != null)
          availableOnboardingDriversProvider
              .overrideWithValue(availableDrivers),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: step,
          ),
        ),
      ),
    ),
  );
  // Allow the post-frame callbacks that read providers (e.g. seed
  // controllers from draft) to fire.
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Welcome step', () {
    testWidgets('renders the headline and bulleted summary', (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      await _pumpStep(tester, db: db, step: const OnboardingWelcomeStep());

      expect(find.text('Welcome to Skotiq'), findsOneWidget);
      expect(find.textContaining("WHAT WE'LL COVER"), findsOneWidget);
    });
  });

  group('Driver step', () {
    testWidgets('toggling a driver updates the draft', (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      late ProviderContainer container;
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            availableOnboardingDriversProvider.overrideWithValue({
              DriverType.native,
              DriverType.alpaca,
              DriverType.indi,
            }),
          ],
          child: Consumer(builder: (ctx, ref, _) {
            container = ProviderScope.containerOf(ctx);
            return MaterialApp(
              theme: SkotiqTheme.dark,
              home: const Scaffold(
                body: Padding(
                  padding: EdgeInsets.all(24),
                  child: OnboardingDriverStep(),
                ),
              ),
            );
          }),
        ),
      );
      await tester.pump();
      // Wait for the notifier to hydrate (defaults to all non-sim drivers
      // selected on a fresh load).
      await container.read(onboardingDraftProvider.notifier).loaded;
      await tester.pumpAndSettle();

      // Default selection includes all non-simulator drivers
      final draft = container.read(onboardingDraftProvider);
      expect(draft.selectedDrivers.contains(DriverType.native), isTrue);

      // Tap the Native row to toggle off
      await tester.tap(find.text('Native'));
      await tester.pumpAndSettle();
      final after = container.read(onboardingDraftProvider);
      expect(after.selectedDrivers.contains(DriverType.native), isFalse);
    });
  });

  group('Optical train step', () {
    testWidgets('telescope preset does not invalidate untouched camera input',
        (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      await _pumpStep(
        tester,
        db: db,
        step: const OnboardingOpticalTrainStep(),
      );

      await tester.tap(find.text('Choose from telescope library'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sky-Watcher Esprit 100ED'));
      await tester.pumpAndSettle();

      expect(
          find.text('Enter a positive pixel size in microns.'), findsNothing);
      expect(find.text('Enter a positive focal length in mm.'), findsNothing);
      expect(find.text('Enter a positive aperture in mm.'), findsNothing);
    });

    testWidgets('validates required fields and renders image scale',
        (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      late ProviderContainer container;
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: Consumer(builder: (ctx, ref, _) {
            container = ProviderScope.containerOf(ctx);
            return MaterialApp(
              theme: SkotiqTheme.dark,
              home: const Scaffold(
                body: SingleChildScrollView(
                  padding: EdgeInsets.all(24),
                  child: OnboardingOpticalTrainStep(),
                ),
              ),
            );
          }),
        ),
      );
      await container.read(onboardingDraftProvider.notifier).loaded;
      await tester.pumpAndSettle();

      // Initially nothing computed. Each of the three readouts (effective
      // focal length, focal ratio, image scale) shows an em dash — never a
      // "---" placeholder, and never a number the inputs do not support.
      expect(find.text('—'), findsNWidgets(3));

      // Enter realistic values: 1000mm, 80mm, 3.76µm, 1.0x reducer
      // -> image scale ≈ 0.78 "/px, f/12.5
      await tester.enterText(
          find.widgetWithText(TextField, '').first.evaluate().isEmpty
              ? find.byType(TextField).at(0)
              : find.byType(TextField).at(0),
          '1000');
      await tester.enterText(find.byType(TextField).at(1), '80');
      await tester.enterText(find.byType(TextField).at(2), '1.0');
      await tester.enterText(find.byType(TextField).at(3), '3.76');
      await tester.pumpAndSettle();

      final draft = container.read(onboardingDraftProvider);
      expect(draft.focalLengthMm, 1000);
      expect(draft.apertureMm, 80);
      expect(draft.pixelSizeMicrons, 3.76);
      expect(draft.reducerFactor, 1.0);
      expect(draft.imageScaleArcsecPerPixel, isNotNull);

      // The summary row should now show the computed image scale.
      expect(find.textContaining('"/px'), findsOneWidget);
      expect(find.textContaining('f/12.5'), findsOneWidget);
    });
  });

  group('Capture dir step', () {
    testWidgets('renders browse button and placeholder text', (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      await _pumpStep(tester, db: db, step: const OnboardingCaptureDirStep());

      expect(find.text('Where should we save captures?'), findsOneWidget);
      // The empty state is the editable box's hint, not a dead label: Browse
      // is one way in, typing or pasting a known path is the other.
      expect(
        find.text('Type or paste a folder, or use Browse'),
        findsOneWidget,
      );
      expect(find.text('Browse'), findsOneWidget);
    });
  });

  group('Site step', () {
    // Pump the site step alone. `approximateLocation` stands in for the IP
    // lookup; the default returns null so no suggestion card appears and the
    // test never touches the network.
    Future<ProviderContainer> pumpSiteStep(
      WidgetTester tester,
      SkotiqDatabase db, {
      ApproximateLocationLookup? approximateLocation,
      SiteLocator? locator,
      ({double latitude, double longitude, double elevation})? seed,
    }) async {
      late ProviderContainer container;
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      if (seed != null) {
        await SettingsDao(db).setSettings(<String, String>{
          'observer_latitude': '${seed.latitude}',
          'observer_longitude': '${seed.longitude}',
          'observer_elevation': '${seed.elevation}',
        });
      }

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            onboardingApproximateLocationProvider.overrideWithValue(
              approximateLocation ?? () async => null,
            ),
            onboardingSiteLocatorProvider.overrideWithValue(
              locator ??
                  ({
                    required bool allowWifiScan,
                    required bool allowIp,
                    bool mayEnableWifiRadio = false,
                    String? googleApiKey,
                  }) async =>
                      const PositioningAttempt(fix: null, outcomes: []),
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

    /// Ask for the IP estimate and accept the consent dialog. The step no
    /// longer fires the lookup by itself, so every suggestion-card assertion
    /// goes through here.
    Future<void> requestIpEstimate(WidgetTester tester) async {
      await tester.tap(find.text('Estimate from IP'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Detect location'));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'renders coordinate fields and persists a valid coordinate pair',
        (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      final container = await pumpSiteStep(tester, db);

      expect(find.text('Where do you observe?'), findsOneWidget);
      expect(find.text('Latitude'), findsOneWidget);
      expect(find.text('Longitude'), findsOneWidget);

      await tester.enterText(find.byType(TextField).at(0), '40.71');
      await tester.enterText(find.byType(TextField).at(1), '-74.01');
      await tester.pumpAndSettle();

      final settings = await container.read(appSettingsProvider.future);
      expect(settings.latitude, closeTo(40.71, 0.001));
      expect(settings.longitude, closeTo(-74.01, 0.001));
      expect(container.read(onboardingSiteEntryErrorProvider), isNull);
    });

    // Typing an out-of-range latitude transits the in-range prefixes "1" and
    // "10". Committing per keystroke persists those, so a rejected "100" leaves
    // 10 degrees North on record as the user's observing site while the field
    // shows 100 behind a red error. Nothing may persist.
    testWidgets('rejected latitude persists neither the value nor its prefixes',
        (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      final container = await pumpSiteStep(tester, db);

      // enterText replaces the whole field, so drive the digits one at a time
      // the way a keyboard does.
      for (final text in ['1', '10', '100']) {
        await tester.enterText(find.byType(TextField).at(0), text);
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pumpAndSettle();

      expect(find.text('Latitude must be between -90 and 90.'), findsOneWidget);
      final settings = await container.read(appSettingsProvider.future);
      expect(settings.latitude, 0.0,
          reason: 'no prefix of a rejected latitude may reach settings');
    });

    // The step publishes a blocking reason the shell reads: returning null
    // unconditionally lets Next advance with the red error still on screen.
    testWidgets('out-of-range entry publishes a blocking reason for the shell',
        (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      final container = await pumpSiteStep(tester, db);

      await tester.enterText(find.byType(TextField).at(1), '400');
      await tester.pumpAndSettle();

      expect(
        container.read(onboardingSiteEntryErrorProvider),
        'Longitude must be between -180 and 180.',
      );

      // Correcting it clears the block and persists.
      await tester.enterText(find.byType(TextField).at(0), '40.71');
      await tester.enterText(find.byType(TextField).at(1), '-74.01');
      await tester.pumpAndSettle();
      expect(container.read(onboardingSiteEntryErrorProvider), isNull);
    });

    // A latitude on its own would pair with longitude 0 and place the site on
    // the Greenwich meridian, so it is blocked rather than half-saved.
    testWidgets('half a coordinate pair is blocked and not persisted',
        (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      final container = await pumpSiteStep(tester, db);

      await tester.enterText(find.byType(TextField).at(0), '40.71');
      await tester.pumpAndSettle();

      expect(
        container.read(onboardingSiteEntryErrorProvider),
        'Enter both latitude and longitude, or clear both to skip this step.',
      );
      final settings = await container.read(appSettingsProvider.future);
      expect(settings.latitude, 0.0);
      expect(settings.longitude, 0.0);
    });

    // The flip side of the revert rule: an out-of-range edit must restore the
    // site the step opened with rather than wiping it.
    testWidgets('rejected edit restores an already-saved site', (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      final container = await pumpSiteStep(tester, db);

      await tester.enterText(find.byType(TextField).at(0), '45.5');
      await tester.enterText(find.byType(TextField).at(1), '-73.6');
      await tester.pumpAndSettle();
      expect((await container.read(appSettingsProvider.future)).latitude,
          closeTo(45.5, 0.001));

      // Re-enter the step so 45.5/-73.6 becomes the baseline, then break it.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      final reopened = await pumpSiteStep(tester, db);
      await tester.enterText(find.byType(TextField).at(0), '999');
      await tester.pumpAndSettle();

      expect(find.text('Latitude must be between -90 and 90.'), findsOneWidget);
      final settings = await reopened.read(appSettingsProvider.future);
      expect(settings.latitude, closeTo(45.5, 0.001),
          reason: 'a typo must not destroy the site already on record');
      expect(settings.longitude, closeTo(-73.6, 0.001));
    });

    testWidgets('clearing both fields returns the site to unset',
        (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      final container = await pumpSiteStep(tester, db);

      await tester.enterText(find.byType(TextField).at(0), '40.71');
      await tester.enterText(find.byType(TextField).at(1), '-74.01');
      await tester.pumpAndSettle();
      expect((await container.read(appSettingsProvider.future)).latitude,
          closeTo(40.71, 0.001));

      await tester.enterText(find.byType(TextField).at(0), '');
      await tester.enterText(find.byType(TextField).at(1), '');
      await tester.pumpAndSettle();

      final settings = await container.read(appSettingsProvider.future);
      expect(settings.latitude, 0.0);
      expect(settings.longitude, 0.0);
      expect(container.read(onboardingSiteEntryErrorProvider), isNull);
    });

    // First launch must not persist an IP-geolocation estimate as the observing
    // site before the user sees it. The estimate is a suggestion — visible,
    // labelled with its provenance, and inert until clicked.
    testWidgets('IP estimate is offered but never persisted on its own',
        (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      final container = await pumpSiteStep(
        tester,
        db,
        approximateLocation: () async =>
            (39.9817, -75.4072, 'West Chester, PA'),
      );

      await requestIpEstimate(tester);

      expect(find.textContaining('Approximate location from your IP address'),
          findsOneWidget);
      expect(
          find.textContaining('not where your telescope is'), findsOneWidget);

      var settings = await container.read(appSettingsProvider.future);
      expect(settings.latitude, 0.0,
          reason: 'an unconfirmed estimate must not reach settings');
      expect(settings.longitude, 0.0);

      await tester.tap(find.text('Use this'));
      await tester.pumpAndSettle();

      settings = await container.read(appSettingsProvider.future);
      expect(settings.latitude, closeTo(39.9817, 0.0001));
      expect(settings.longitude, closeTo(-75.4072, 0.0001));
    });

    testWidgets('no suggestion is shown when the lookup fails offline',
        (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      await pumpSiteStep(tester, db, approximateLocation: () async => null);

      expect(find.textContaining('Approximate location from your IP address'),
          findsNothing);
      expect(find.textContaining('Looking up an approximate'), findsNothing);
    });

    // The suggestion is a Row of wrapping prose next to a button, which is the
    // classic horizontal-overflow shape. Render it at phone width and let the
    // test fail on any RenderFlex overflow.
    testWidgets('suggestion card lays out without overflow at phone width',
        (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(400, 820);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            onboardingApproximateLocationProvider.overrideWithValue(
              () async => (39.9817, -75.4072, 'West Chester, Pennsylvania'),
            ),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(16),
                child: OnboardingSiteStep(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await requestIpEstimate(tester);

      expect(find.textContaining('Approximate location from your IP address'),
          findsOneWidget);
      expect(find.text('Use this'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // Arriving on this step used to post a frame callback that sent the
    // machine's public IP to a third-party geolocator (falling back to
    // plain-HTTP ip-api.com): the app's first outbound request, on its first
    // run, with no click and nothing on screen saying so.
    testWidgets('no lookup leaves the machine until the user asks',
        (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      var calls = 0;
      await pumpSiteStep(
        tester,
        db,
        approximateLocation: () async {
          calls++;
          return (39.9817, -75.4072, 'West Chester, PA');
        },
      );

      expect(calls, 0, reason: 'the step looked up a location on its own');
      expect(
          find.textContaining('Nothing is sent until you ask'), findsOneWidget);

      // Asking is not enough — the consent dialog has to be accepted.
      await tester.tap(find.text('Estimate from IP'));
      await tester.pumpAndSettle();
      expect(calls, 0, reason: 'the lookup ran before the user consented');
      expect(find.textContaining('ipinfo.io'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, 0, reason: 'a declined lookup still reached the network');

      await requestIpEstimate(tester);
      expect(calls, 1);
    });

    testWidgets('detecting a location asks first and drops a stale elevation',
        (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      var calls = 0;
      final container = await pumpSiteStep(
        tester,
        db,
        // Seattle, 1234 m: the site this run is moving away from.
        seed: (latitude: 47.6062, longitude: -122.3321, elevation: 1234.0),
        locator: ({
          required bool allowWifiScan,
          required bool allowIp,
          bool mayEnableWifiRadio = false,
          String? googleApiKey,
        }) async {
          calls++;
          return const PositioningAttempt(
            fix: PositioningResult(
              latitude: 39.9817,
              longitude: -75.4072,
              locationName: 'Newtown Square, PA',
              source: PositioningSource.ipAddress,
              provider: 'ipinfo.io',
            ),
            outcomes: [],
          );
        },
      );

      await tester.tap(find.text('Use my current location'));
      await tester.pumpAndSettle();
      expect(calls, 0, reason: 'the lookup ran before the user consented');

      await tester.tap(find.text('Detect location'));
      await tester.pumpAndSettle();
      expect(calls, 1);

      final settings = await container.read(appSettingsProvider.future);
      expect(settings.latitude, closeTo(39.9817, 0.0001));
      expect(
        settings.elevation,
        0.0,
        reason: 'a Pennsylvania fix kept the Seattle elevation',
      );
    });
  });

  group('Summary step', () {
    testWidgets('shows draft fields and lets the user edit the profile name',
        (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      late ProviderContainer container;

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: Consumer(builder: (ctx, ref, _) {
            container = ProviderScope.containerOf(ctx);
            return MaterialApp(
              theme: SkotiqTheme.dark,
              home: const Scaffold(
                body: SingleChildScrollView(
                  padding: EdgeInsets.all(24),
                  child: OnboardingSummaryStep(),
                ),
              ),
            );
          }),
        ),
      );
      await container.read(onboardingDraftProvider.notifier).loaded;
      // Seed the draft as if previous steps had completed.
      await container.read(onboardingDraftProvider.notifier).setCamera(
            id: 'native:zwo:0',
            name: 'ASI294MC Pro',
          );
      await container
          .read(onboardingDraftProvider.notifier)
          .setMount(id: 'ascom:EQMOD', name: 'EQ6-R');
      await container.read(onboardingDraftProvider.notifier).setOpticalTrain(
            focalLengthMm: 1000,
            apertureMm: 80,
            pixelSizeMicrons: 3.76,
            reducerFactor: 1.0,
          );
      await tester.pumpAndSettle();

      // Renders the device names and the computed image scale.
      expect(find.text('ASI294MC Pro'), findsOneWidget);
      expect(find.text('EQ6-R'), findsOneWidget);
      expect(find.textContaining('"/px'), findsOneWidget);

      // Profile name field is pre-filled. The TextField renders both
      // its current value ("My First Rig" from the controller) AND the
      // identical hint text ("My First Rig"), so `find.widgetWithText`
      // matches two TextField ancestors. The one we want is the
      // TextField whose controller value matches; locate it by type
      // (there is exactly one TextField in the Summary step) and
      // verify it has the expected starting text via the controller.
      final nameField = find.byType(TextField);
      expect(nameField, findsOneWidget);
      expect(
        tester.widget<TextField>(nameField).controller?.text,
        'My First Rig',
      );

      // Editing the name persists to the draft.
      await tester.enterText(nameField, 'Backyard Rig');
      await tester.pumpAndSettle();
      expect(
          container.read(onboardingDraftProvider).profileName, 'Backyard Rig');
    });
  });

  group('Integration: full wizard flow', () {
    testWidgets('end-to-end completion creates an equipment profile',
        (tester) async {
      final db = _newDb();
      addTearDown(db.close);
      late ProviderContainer container;

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      // OnboardingScreen calls `context.go('/dashboard')` after a
      // successful save. Without a GoRouter ancestor that throws and
      // the `await context.showSuccessSnackBar(...)` chain never
      // completes — `pump(5s)` then can't drain its display timer and
      // the test runner hits the 10-minute timeout. Spin up a tiny
      // GoRouter that registers both /dashboard (the navigation
      // target) and an /onboarding initial route hosting the
      // OnboardingScreen.
      final router = GoRouter(
        initialLocation: '/onboarding',
        routes: [
          GoRoute(
            path: '/onboarding',
            builder: (ctx, _) => const OnboardingScreen(),
          ),
          GoRoute(
            path: '/dashboard',
            builder: (ctx, _) =>
                const Scaffold(body: Text('dashboard stub for test')),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            // See `_pumpStep`: prevent the welcome step's profile-watch
            // from pulling in the default backend's recurring timers,
            // which would otherwise leak Timers past tear-down and
            // hit "A Timer is still pending after widget tree was
            // disposed" + the test's 10-minute timeout.
            allProfilesProvider.overrideWith((ref) => const Stream.empty()),
          ],
          child: Consumer(builder: (ctx, ref, _) {
            container = ProviderScope.containerOf(ctx);
            return MaterialApp.router(
              theme: SkotiqTheme.dark,
              routerConfig: router,
            );
          }),
        ),
      );
      // Let the notifier hydrate so the screen renders past its spinner.
      await container.read(onboardingDraftProvider.notifier).loaded;
      await tester.pumpAndSettle();

      // We bypass UI walking (driver scan is async + tests can't reach
      // real drivers) by mutating the notifier directly to the
      // pre-summary state. Then we drive the summary step through the
      // UI to prove the wizard actually persists the result.
      final notifier = container.read(onboardingDraftProvider.notifier);
      await notifier.toggleDriver(DriverType.simulator);
      await notifier.setCamera(
        id: 'sim:camera:0',
        name: 'Simulator Camera',
        pixelSizeMicrons: 3.76,
      );
      await notifier.setMount(id: 'sim:mount:0', name: 'Simulator Mount');
      await notifier.setOpticalTrain(
        focalLengthMm: 1000,
        apertureMm: 80,
        pixelSizeMicrons: 3.76,
        reducerFactor: 1.0,
      );
      await notifier.setCaptureDirectory('C:/sim_captures');
      await notifier.goToStep(OnboardingStep.summary);
      await tester.pumpAndSettle();

      expect(find.text('Review and save'), findsOneWidget);
      expect(find.text('Save profile'), findsOneWidget);

      // Trigger the save action.
      await tester.tap(find.text('Save profile'));
      // The save action awaits `complete()` and then calls
      // `context.go('/dashboard')` + a success snackbar. We need to
      // pump enough to drain (a) the await on complete() so the DAO
      // query below sees the inserted row and (b) the snackbar
      // display timer (default 4s) so it doesn't leak past tear-down.
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));

      final dao = container.read(equipmentProfilesDaoProvider);
      final profiles = await dao.getAllProfiles();
      expect(profiles.length, 1);
      expect(profiles.single.cameraId, 'sim:camera:0');
      expect(profiles.single.mountId, 'sim:mount:0');
      expect(profiles.single.focalLength, 1000);

      // Drift `StreamQueryStore.markAsClosed` queues a zero-duration
      // Timer that fires on stream cancel. With the default test
      // tear-down sequence (test body returns → ProviderScope
      // unmounts → StreamProviders dispose → markAsClosed enqueues a
      // Timer), those Timers are created AFTER the test body and the
      // runner reports "A Timer is still pending even after the
      // widget tree was disposed". Unmounting the ProviderScope here
      // — inside the test body — queues the Timers during this
      // pumpWidget, and the follow-up `pump(Duration(microseconds:1))`
      // advances the FakeAsync clock far enough to fire them.
      // Plain `pump()` defaults to Duration.zero which is NOT enough
      // — Timer(Duration.zero) is scheduled relative to NOW so a zero
      // advance leaves it pending.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(microseconds: 1));
    });

    testWidgets('step list ticks only the steps that captured a value',
        (tester) async {
      // The sidebar must not tick every step behind the cursor: a guider the
      // user tested, failed to reach and skipped would carry the same filled
      // tick as the camera they really configured, while the Review screen says
      // "— not set —" about that same guider.
      final db = _newDb();
      addTearDown(db.close);
      late ProviderContainer container;

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final router = GoRouter(
        initialLocation: '/onboarding',
        routes: [
          GoRoute(
            path: '/onboarding',
            builder: (ctx, _) => const OnboardingScreen(),
          ),
          GoRoute(
            path: '/dashboard',
            builder: (ctx, _) =>
                const Scaffold(body: Text('dashboard stub for test')),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            allProfilesProvider.overrideWith((ref) => const Stream.empty()),
          ],
          child: Consumer(builder: (ctx, ref, _) {
            container = ProviderScope.containerOf(ctx);
            return MaterialApp.router(
              theme: SkotiqTheme.dark,
              routerConfig: router,
            );
          }),
        ),
      );
      await container.read(onboardingDraftProvider.notifier).loaded;
      await tester.pumpAndSettle();

      // Configure the required gear only, then walk to Review. Focuser,
      // filter wheel, guider, capture defaults and site are all passed over
      // with nothing set — exactly the "I pressed Test, it failed, I picked
      // nothing, I pressed Next" case.
      final notifier = container.read(onboardingDraftProvider.notifier);
      await notifier.toggleDriver(DriverType.simulator);
      await notifier.setCamera(id: 'sim:camera:0', name: 'Simulator Camera');
      await notifier.setMount(id: 'sim:mount:0', name: 'Simulator Mount');
      await notifier.setOpticalTrain(
        focalLengthMm: 1000,
        apertureMm: 80,
        pixelSizeMicrons: 3.76,
        reducerFactor: 1.0,
      );
      await notifier.setCaptureDirectory('C:/sim_captures');
      await notifier.goToStep(OnboardingStep.summary);
      await tester.pumpAndSettle();

      // The rail states its verdict per step through the design system's own
      // tooltip, not Material's.
      Finder railState(String state) => find.byWidgetPredicate(
            (w) => w is SkotiqTooltip && w.message == state,
          );

      // Passed with a value: welcome, drivers, camera, mount, optical train,
      // capture folder.
      expect(railState('Configured'), findsNWidgets(6));
      // Passed with nothing on record: focuser, filter wheel, guider, camera
      // defaults, observing site.
      expect(railState('Skipped — nothing was set'), findsNWidgets(5));
      expect(railState('Current step'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(microseconds: 1));
    });
  });
}
