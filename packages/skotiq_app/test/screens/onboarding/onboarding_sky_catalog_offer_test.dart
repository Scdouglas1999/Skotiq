// First-run setup offers the sky catalogs, with their size, and does not
// download them unless asked.
//
// Walk-2 F8: thirteen steps never mentioned catalogs, and the planner the user
// landed on afterwards was empty until a 60 MB download found in Settings.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/onboarding/onboarding_screen.dart';
import 'package:skotiq_astro/skotiq_astro.dart' show SkyCatalog;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/models/equipment_profile.dart'
    as remote_profile;
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Profile activation writes through to the native store; there is none in a
/// widget test.
class _ProfileSettingsBackendFake implements ProfileSettingsBackend {
  @override
  Future<void> loadProfile(String id) async {}

  @override
  Future<void> saveProfile(remote_profile.EquipmentProfile profile) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<(ProviderContainer, List<SkyCatalog>)> _pumpReview(
  WidgetTester tester,
) async {
  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 1100);
  addTearDown(tester.view.reset);

  final installed = <SkyCatalog>[];
  late ProviderContainer container;
  final router = GoRouter(
    initialLocation: '/onboarding',
    routes: [
      GoRoute(
        path: '/onboarding',
        builder: (_, __) => const OnboardingScreen(),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        allProfilesProvider.overrideWith((ref) => const Stream.empty()),
        profileSettingsBackendProvider.overrideWithValue(
          _ProfileSettingsBackendFake(),
        ),
        skyCatalogInstallProvider.overrideWith(
          (ref) => SkyCatalogInstallNotifier(
            (catalog, {onProgress, isCancelled}) async {
              installed.add(catalog);
              return null;
            },
          ),
        ),
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
  final notifier = container.read(onboardingDraftProvider.notifier);
  await notifier.loaded;
  await notifier.setCamera(id: 'sim:camera:0', name: 'Simulator Camera');
  await notifier.setMount(id: 'sim:mount:0', name: 'Simulator Mount');
  await notifier.setOpticalTrain(
    focalLengthMm: 800,
    apertureMm: 100,
    pixelSizeMicrons: 3.76,
  );
  await notifier.setCaptureDirectory('/tmp/captures');
  await notifier.goToStep(OnboardingStep.summary);
  await tester.pumpAndSettle();
  return (container, installed);
}

void main() {
  testWidgets('the download is offered with its size and starts off',
      (tester) async {
    final (container, installed) = await _pumpReview(tester);

    final offer = find.widgetWithText(
      SkotiqSwitchRow,
      'Download the sky catalogs when I save',
    );
    expect(offer, findsOneWidget);
    expect(tester.widget<SkotiqSwitchRow>(offer).value, isFalse);
    expect(find.textContaining('about 60 MB'), findsOneWidget);

    await tester.tap(find.text('Save profile'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));

    expect(installed, isEmpty, reason: 'nothing is downloaded unasked');
    // The next step still offers it.
    expect(
      find.widgetWithText(SkotiqButton, 'Download catalogs (60 MB)'),
      findsOneWidget,
    );
    expect(
      container.read(onboardingDraftProvider).currentStep,
      OnboardingStep.nextSteps,
    );
    // Unmount inside the test so drift's zero-length close timers fire here.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(microseconds: 1));
  });

  testWidgets('saving with the download on starts it', (tester) async {
    final (container, installed) = await _pumpReview(tester);

    await container
        .read(onboardingDraftProvider.notifier)
        .setDownloadSkyCatalogs(true);
    await tester.pump();
    await tester.tap(find.text('Save profile'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));

    expect(installed, [SkyCatalog.stars, SkyCatalog.dso]);
    // Unmount inside the test so drift's zero-length close timers fire here.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(microseconds: 1));
  });
}
