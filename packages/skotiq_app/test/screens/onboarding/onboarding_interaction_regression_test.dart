import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/screens/onboarding/onboarding_screen.dart';
import 'package:skotiq_app/screens/onboarding/steps/device_picker_step.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _NoopDiscoveryNotifier extends UnifiedDiscoveryNotifier {
  _NoopDiscoveryNotifier(super.ref);

  @override
  Future<void> discoverAll({
    bool includeIndi = true,
    bool includeAlpaca = true,
  }) async {}
}

class _MountOnlyDiscoveryNotifier extends _NoopDiscoveryNotifier {
  _MountOnlyDiscoveryNotifier(super.ref) {
    state = const UnifiedDiscoveryState(
      backendStates: {
        DriverType.native: BackendDiscoveryState(
          backend: DriverType.native,
          status: DiscoveryStatus.completed,
          devices: [
            DeviceInfo(
              id: 'native-mount',
              name: 'Native mount',
              deviceType: DeviceType.mount,
              driverType: DriverType.native,
              description: '',
              driverVersion: '',
            ),
          ],
        ),
      },
    );
  }
}

SkotiqDatabase _newDb() =>
    SkotiqDatabase.forTesting(NativeDatabase.memory());

void main() {
  testWidgets('double-tapping Next cannot validate the following step',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final db = _newDb();
    addTearDown(db.close);
    late ProviderContainer container;
    final router = GoRouter(
      initialLocation: '/onboarding',
      routes: [
        GoRoute(
          path: '/onboarding',
          builder: (_, __) => const OnboardingScreen(),
        ),
        GoRoute(
          path: '/dashboard',
          builder: (_, __) => const Scaffold(body: Text('Dashboard')),
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
        child: Consumer(builder: (context, ref, _) {
          container = ProviderScope.containerOf(context);
          return MaterialApp.router(
            theme: SkotiqTheme.dark,
            routerConfig: router,
          );
        }),
      ),
    );
    await container.read(onboardingDraftProvider.notifier).loaded;
    await tester.pumpAndSettle();

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(container.read(onboardingDraftProvider).currentStep,
        OnboardingStep.drivers);
    // Let the previous step's input cooldown expire, so what the double tap
    // below exercises is the cooldown it starts — not the one it inherited.
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Next'));
    await tester.tap(find.text('Next'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(container.read(onboardingDraftProvider).currentStep,
        OnboardingStep.camera);
    expect(find.textContaining('Pick a camera to continue'), findsNothing);
  });

  testWidgets('backend chip counts only devices for the current picker',
      (tester) async {
    final db = _newDb();
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          unifiedDiscoveryProvider.overrideWith(
            _MountOnlyDiscoveryNotifier.new,
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: OnboardingDevicePickerBody(
              title: 'Choose camera',
              subtitle: 'Pick a camera',
              icon: LucideIcons.camera,
              deviceType: DeviceType.camera,
              selectedDeviceId: null,
              selectedDeviceName: null,
              onSelected: (_) {},
              onCleared: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Native (0)'), findsOneWidget);
    expect(find.text('Native (1)'), findsNothing);
    expect(find.textContaining('No devices found'), findsOneWidget);
  });
}
