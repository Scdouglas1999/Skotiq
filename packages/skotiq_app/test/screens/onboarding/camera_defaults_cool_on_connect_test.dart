// The camera-defaults step must be able to ARM the cooler, not just name a
// temperature.
//
// Live finding: the wizard's "Regulated cooling" switch plus a −10 °C
// set-point produced a profile with cool_on_connect = 0. The camera sat at
// ambient every session and the only control that changed that was a checkbox
// buried in Equipment > Edit Profile > Camera Defaults, which a first-run user
// has no reason to open.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/camera_defaults_step.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _coolOnConnectLabel = 'Start cooling when the camera connects';

Future<ProviderContainer> _pumpStep(WidgetTester tester) async {
  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);

  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 1400);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  late ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        availableOnboardingDriversProvider
            .overrideWithValue({DriverType.native}),
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
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the wizard asks whether to cool on connect, and records the yes',
      (tester) async {
    final container = await _pumpStep(tester);

    // The question only exists for a cooled camera.
    expect(find.text(_coolOnConnectLabel), findsNothing);

    // Turn on "Regulated cooling" (the first switch on the step).
    await tester.tap(find.byType(SkotiqSwitch).first);
    await tester.pumpAndSettle();

    expect(container.read(onboardingDraftProvider).defaultCoolingTempC, -10.0);
    expect(
      find.text(_coolOnConnectLabel),
      findsOneWidget,
      reason: 'a set-point the app never acts on is decoration',
    );
    expect(
      container.read(onboardingDraftProvider).coolOnConnect,
      isFalse,
      reason: 'auto-cooling is opt-in — a noon setup must not run the TEC',
    );

    await tester.tap(find.byType(SkotiqSwitch).last);
    await tester.pumpAndSettle();

    expect(
      container.read(onboardingDraftProvider).coolOnConnect,
      isTrue,
      reason: 'the profile this wizard writes must carry the answer',
    );
  });

  testWidgets('turning regulated cooling off disarms cool-on-connect',
      (tester) async {
    final container = await _pumpStep(tester);

    await tester.tap(find.byType(SkotiqSwitch).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SkotiqSwitch).last);
    await tester.pumpAndSettle();
    expect(container.read(onboardingDraftProvider).coolOnConnect, isTrue);

    // Back off: no set-point, so nothing to cool to.
    await tester.tap(find.byType(SkotiqSwitch).first);
    await tester.pumpAndSettle();

    expect(container.read(onboardingDraftProvider).defaultCoolingTempC, isNull);
    expect(container.read(onboardingDraftProvider).coolOnConnect, isFalse);
  });
}
