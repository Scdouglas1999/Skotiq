// Widget test for the onboarding camera-defaults step's cooling-seed seam.
//
// Enabling "Regulated cooling" with no value typed seeds a set-point. The
// seam prefers the selected camera's recommended set-point
// (CameraRecommendedSettings.recommendedCoolingSetpointC), but that field is
// None across every backend we bind today — so the seed must fall back to the
// built-in -10 C default. With no camera selected the device service is never
// touched and the same -10 default applies.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/camera_defaults_step.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

SkotiqDatabase _newDb() => SkotiqDatabase.forTesting(NativeDatabase.memory());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'enabling cooling with no camera seeds the -10 C default '
      'when no recommended set-point exists', (tester) async {
    final db = _newDb();
    addTearDown(db.close);

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          availableOnboardingDriversProvider.overrideWithValue({
            DriverType.native,
          }),
        ],
        child: Consumer(builder: (ctx, ref, _) {
          container = ProviderScope.containerOf(ctx);
          return MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(24),
                child: OnboardingCameraDefaultsStep(),
              ),
            ),
          );
        }),
      ),
    );
    await tester.pump();
    await container.read(onboardingDraftProvider.notifier).loaded;
    await tester.pumpAndSettle();

    // Fresh draft: cooling is off (no set-point), so the toggle is unchecked.
    expect(container.read(onboardingDraftProvider).defaultCoolingTempC, isNull);

    // Flip "Regulated cooling" on. No camera is selected, so the seam falls
    // straight through to the built-in default without querying any device.
    // Only the switch itself is interactive (the label is not), so tap it.
    await tester.tap(find.byType(SkotiqSwitch));
    await tester.pumpAndSettle();

    final draft = container.read(onboardingDraftProvider);
    expect(draft.defaultCoolingTempC, -10.0);

    // The cooling set-point field now shows the seeded value.
    expect(find.widgetWithText(TextField, '-10'), findsOneWidget);
  });
}
