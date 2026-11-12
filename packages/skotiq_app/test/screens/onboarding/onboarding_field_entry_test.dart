// Entering optics and site numbers the way people write them.
//
// Walk-2 F5: Next on an empty optical train said "Focal length is required."
// only in the band below the card while every field stayed unmarked, and a
// latitude typed as 40°42'46" N lost its marks to the input filter and became
// 404246, "Latitude must be between -90 and 90."
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/onboarding/onboarding_screen.dart';
import 'package:skotiq_app/screens/onboarding/steps/site_step.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

class _NoopDiscoveryNotifier extends UnifiedDiscoveryNotifier {
  _NoopDiscoveryNotifier(super.ref);

  @override
  Future<void> discoverAll({
    bool includeIndi = true,
    bool includeAlpaca = true,
  }) async {}
}

Future<ProviderContainer> _pumpWizardAt(
  WidgetTester tester,
  OnboardingStep step,
) async {
  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 1000);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

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
        unifiedDiscoveryProvider.overrideWith(_NoopDiscoveryNotifier.new),
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
  await notifier.goToStep(step);
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('Next on an empty optical train marks the fields that block it',
      (tester) async {
    await _pumpWizardAt(tester, OnboardingStep.opticalTrain);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Next'));
    await tester.pumpAndSettle();

    final focalError = find.text('Enter a positive focal length in mm.');
    expect(focalError, findsOneWidget);
    expect(find.text('Enter a positive aperture in mm.'), findsOneWidget);
    expect(find.text('Enter a positive pixel size in microns.'), findsOneWidget);
    // The error sits with its field, above the aperture label, not in the
    // band under the card.
    expect(
      tester.getRect(focalError).top,
      lessThan(tester.getRect(find.text('Aperture')).top),
    );
  });

  testWidgets('a latitude written in degrees, minutes, seconds is read',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const OnboardingSiteStep(),
      size: const Size(1000, 900),
    );
    await tester.pumpAndSettle();

    Finder input(Key key) =>
        find.descendant(of: find.byKey(key), matching: find.byType(TextField));
    await tester.enterText(input(onboardingSiteLatitudeKey), '40°42\'46" N');
    await tester.enterText(input(onboardingSiteLongitudeKey), '74 0 22 W');
    await tester.pumpAndSettle();

    expect(find.textContaining('must be between'), findsNothing);
    expect(handle.container.read(onboardingSiteEntryErrorProvider), isNull);
    final settings = handle.container.read(appSettingsProvider).value!;
    expect(settings.latitude, closeTo(40.7128, 0.0001));
    expect(settings.longitude, closeTo(-74.0061, 0.0001));
  });
}
