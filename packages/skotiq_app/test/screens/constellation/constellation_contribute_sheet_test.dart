import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/constellation/constellation_contribute_sheet.dart';
import 'package:skotiq_app/screens/constellation/constellation_ui_providers.dart'
    as ui;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A [ConstellationService] that records the exact license, attribution, privacy
/// and radius the sheet ships, so a test can assert the sheet never sends a
/// stale or silently-fallen-back license. Everything else is unimplemented — the
/// sheet only ever calls [contributeTarget].
class _RecordingConstellationService implements ConstellationService {
  int calls = 0;
  ContributionLicense? sentLicense;
  bool? sentAttribution;
  ConstellationPrivacy? sentPrivacy;
  double? sentRadiusDeg;

  @override
  Future<ContributionOutcome> contributeTarget(
    int targetId, {
    DateTime? since,
    double radiusDeg = 1.5,
    String? instrumentFingerprint,
    String? solver,
    ConstellationPrivacy privacy = ConstellationPrivacy.sums,
    ContributionLicense license = ContributionLicense.ccBy,
    bool attributionConsent = true,
  }) async {
    calls++;
    sentLicense = license;
    sentAttribution = attributionConsent;
    sentPrivacy = privacy;
    sentRadiusDeg = radiusDeg;
    return const ContributionOutcome(accepted: {}, rejected: {});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An in-memory [SettingsDao] — the sheet persists the chosen privacy before
/// contributing.
class _RecordingSettingsDao implements SettingsDao {
  final Map<String, String> store = {};

  @override
  Future<void> setSetting(String key, String value) async {
    store[key] = value;
  }

  @override
  Future<String?> getSetting(String key) async => store[key];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const target = SharedTarget(
    targetId: 42,
    name: 'M31',
    raDeg: 10.68,
    decDeg: 41.27,
    integrationSeconds: 0,
    contributors: 1,
    activeTileId: null,
    radiusDeg: 2.0,
  );

  HubInfo hub({
    bool acceptsRawSubs = false,
    List<String> supportedLicenses = const <String>[],
  }) =>
      HubInfo(
        name: 'Test Hub',
        fingerprint: 'fp',
        version: '6.0',
        healpixOrder: 5,
        tilePixels: 512,
        selfHosted: true,
        acceptsRawSubs: acceptsRawSubs,
        supportedLicenses: supportedLicenses,
      );

  void sizeWindow(WidgetTester tester) {
    // Tall enough that the content-sized dialog renders fully — no scrolling, so
    // every consent row and the dropdown are hit-testable.
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> openSheet(
    WidgetTester tester, {
    required List<Override> overrides,
  }) async {
    sizeWindow(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: SkotiqButton(
                  label: 'open',
                  onPressed: () =>
                      showConstellationContributeSheet(context, target: target),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder contributeButton() => find.widgetWithText(SkotiqButton, 'Contribute');

  const baseConsent = 'consent to contributing it to this self-hosted';

  testWidgets(
    'capability loading fails closed until the hub license list resolves',
    (tester) async {
      final info = Completer<HubInfo>();
      await openSheet(
        tester,
        overrides: [
          ui.constellationHubInfoProvider.overrideWith((ref) => info.future),
          ui.constellationPrivacyProvider
              .overrideWith((ref) async => ui.ConstellationPrivacy.sums),
        ],
      );

      expect(find.textContaining('Checking the hub'), findsOneWidget);
      expect(find.byType(SkotiqDropdown), findsNothing);
      await tester.tap(find.textContaining(baseConsent));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SkotiqButton>(contributeButton()).onPressed,
        isNull,
      );

      info.complete(hub(supportedLicenses: const ['cc0']));
      await tester.pumpAndSettle();
      expect(find.byType(SkotiqDropdown), findsOneWidget);
      expect(
        tester.widget<SkotiqButton>(contributeButton()).onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'a non-empty but unsupported advertised license list fails closed with no '
    'dropdown and a disabled Contribute action',
    (tester) async {
      await openSheet(
        tester,
        overrides: [
          ui.constellationHubInfoProvider.overrideWith(
            (ref) async => hub(supportedLicenses: const ['unknown-license']),
          ),
          ui.constellationPrivacyProvider
              .overrideWith((ref) async => ui.ConstellationPrivacy.sums),
        ],
      );

      // Fail closed: no dropdown is built from an empty compatible set.
      expect(find.byType(SkotiqDropdown), findsNothing);
      expect(
        find.textContaining('does not advertise a compatible sharing'),
        findsOneWidget,
      );

      // Even after ticking consent, an incompatible hub can't be contributed to.
      await tester.tap(find.textContaining(baseConsent));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SkotiqButton>(contributeButton()).onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'an older hub with an empty advertised list keeps the all-shareable '
    'fallback',
    (tester) async {
      await openSheet(
        tester,
        overrides: [
          ui.constellationHubInfoProvider.overrideWith((ref) async => hub()),
          ui.constellationPrivacyProvider
              .overrideWith((ref) async => ui.ConstellationPrivacy.sums),
        ],
      );

      expect(find.byType(SkotiqDropdown), findsOneWidget);
      await tester.tap(find.byType(SkotiqDropdown));
      await tester.pumpAndSettle();
      // The full non-private set is offered — both ends of the permissiveness
      // range are present.
      expect(find.textContaining('CC0 —'), findsWidgets);
      expect(find.textContaining('CC BY-NC —'), findsWidgets);
    },
  );

  testWidgets(
    'a hub that excludes the default license ships the effective fallback, '
    'never a stale ccBy',
    (tester) async {
      final service = _RecordingConstellationService();
      await openSheet(
        tester,
        overrides: [
          ui.constellationHubInfoProvider.overrideWith(
            (ref) async => hub(supportedLicenses: const ['cc-by-sa', 'cc0']),
          ),
          ui.constellationPrivacyProvider
              .overrideWith((ref) async => ui.ConstellationPrivacy.sums),
          constellationServiceProvider.overrideWithValue(service),
          settingsDaoProvider.overrideWithValue(_RecordingSettingsDao()),
        ],
      );

      // Do NOT touch the dropdown — the user accepts the visually-selected
      // fallback. The default ccBy is not advertised, so the effective license
      // is the first advertised one (cc-by-sa), and that is what must ship.
      await tester.tap(find.textContaining(baseConsent));
      await tester.pumpAndSettle();
      await tester.tap(contributeButton());
      await tester.pumpAndSettle();

      expect(service.calls, 1);
      expect(service.sentLicense, ContributionLicense.ccBySa);
      expect(service.sentAttribution, isTrue);
      expect(service.sentPrivacy, ConstellationPrivacy.sums);
      expect(service.sentRadiusDeg, 2.0);
    },
  );

  testWidgets(
    'selecting a supported non-default license ships exactly that license',
    (tester) async {
      final service = _RecordingConstellationService();
      await openSheet(
        tester,
        overrides: [
          ui.constellationHubInfoProvider.overrideWith(
            (ref) async => hub(supportedLicenses: const ['cc-by-sa', 'cc0']),
          ),
          ui.constellationPrivacyProvider
              .overrideWith((ref) async => ui.ConstellationPrivacy.sums),
          constellationServiceProvider.overrideWithValue(service),
          settingsDaoProvider.overrideWithValue(_RecordingSettingsDao()),
        ],
      );

      await tester.tap(find.byType(SkotiqDropdown));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('CC0 —').last);
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining(baseConsent));
      await tester.pumpAndSettle();
      await tester.tap(contributeButton());
      await tester.pumpAndSettle();

      expect(service.calls, 1);
      expect(service.sentLicense, ContributionLicense.cc0);
    },
  );

  testWidgets(
    'checking consent locks the sheet so a late-resolving privacy preference '
    'cannot flip the represented sharing choice',
    (tester) async {
      final privacy = Completer<ui.ConstellationPrivacy>();
      await openSheet(
        tester,
        overrides: [
          ui.constellationHubInfoProvider
              .overrideWith((ref) async => hub(acceptsRawSubs: true)),
          ui.constellationPrivacyProvider.overrideWith((ref) => privacy.future),
        ],
      );

      // Loading: the default SUMS choice shows its reassurance banner.
      expect(find.textContaining('additive co-add sums'), findsOneWidget);

      // The user takes ownership of the sheet by consenting...
      await tester.tap(find.textContaining(baseConsent));
      await tester.pumpAndSettle();

      // ...then the persisted preference resolves LATE to the opposite choice.
      privacy.complete(ui.ConstellationPrivacy.subs);
      await tester.pumpAndSettle();

      // The represented sharing choice did not change under the user.
      expect(find.textContaining('additive co-add sums'), findsOneWidget);
      expect(find.textContaining('Raw subframes reveal'), findsNothing);
    },
  );

  testWidgets(
    'touching only the credit toggle also locks the late privacy seed',
    (tester) async {
      final privacy = Completer<ui.ConstellationPrivacy>();
      await openSheet(
        tester,
        overrides: [
          ui.constellationHubInfoProvider
              .overrideWith((ref) async => hub(acceptsRawSubs: true)),
          ui.constellationPrivacyProvider.overrideWith((ref) => privacy.future),
        ],
      );

      expect(find.textContaining('additive co-add sums'), findsOneWidget);

      // The credit toggle is a sharing choice too — interacting with it must
      // take ownership so the late seed cannot swap the privacy underneath.
      await tester.tap(find.textContaining('Credit me as a contributor'));
      await tester.pumpAndSettle();

      privacy.complete(ui.ConstellationPrivacy.subs);
      await tester.pumpAndSettle();

      expect(find.textContaining('additive co-add sums'), findsOneWidget);
      expect(find.textContaining('Raw subframes reveal'), findsNothing);
    },
  );
}
