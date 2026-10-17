// The guider step's PHD2 test result must not outlive the endpoint it probed.
//
// "PHD2 reachable. Selection saved." used to stay on screen after the host or
// port field was edited, while the draft guider (and the phd2Host/phd2Port
// settings the connect path actually reads) still pointed at the address that
// passed. The user saw a green tick next to an address nothing had contacted.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/onboarding/steps/guider_step.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockGuidingBackend extends Mock implements GuidingBackend {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'a passing PHD2 test names the endpoint and is retracted when '
      'the host is edited', (tester) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final guiding = _MockGuidingBackend();
    when(() => guiding.isPhd2Running(
          host: any(named: 'host'),
          port: any(named: 'port'),
        )).thenAnswer((_) async => true);

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
          guidingBackendProvider.overrideWithValue(guiding),
        ],
        child: Consumer(builder: (ctx, ref, _) {
          container = ProviderScope.containerOf(ctx);
          return MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(body: OnboardingGuiderStep()),
          );
        }),
      ),
    );
    await tester.pump();
    await container.read(onboardingDraftProvider.notifier).loaded;
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(guiderHostFieldKey),
      '192.168.1.50',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SkotiqButton, 'Test'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('PHD2 reachable at 192.168.1.50:4400'),
      findsOneWidget,
    );
    expect(
      container.read(onboardingDraftProvider).guiderId,
      'phd2:192.168.1.50:4400',
    );

    // Point the field at a different machine without re-testing. The saved
    // guider is unchanged, so the success line must go and the step must say
    // which endpoint is actually on record.
    await tester.enterText(
      find.byKey(guiderHostFieldKey),
      '192.168.1.60',
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('PHD2 reachable'), findsNothing);
    expect(
      find.textContaining('Saved guider is still PHD2 at 192.168.1.50:4400'),
      findsOneWidget,
    );
    expect(
      container.read(onboardingDraftProvider).guiderId,
      'phd2:192.168.1.50:4400',
      reason: 'editing the field does not silently re-point the saved guider',
    );

    // Re-testing the new address is what moves the saved guider.
    await tester.tap(find.widgetWithText(SkotiqButton, 'Test'));
    await tester.pumpAndSettle();
    expect(
      container.read(onboardingDraftProvider).guiderId,
      'phd2:192.168.1.60:4400',
    );
    expect(
      find.textContaining('PHD2 reachable at 192.168.1.60:4400'),
      findsOneWidget,
    );
  });

  testWidgets('a failed PHD2 test is cleared when the port changes',
      (tester) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final guiding = _MockGuidingBackend();
    when(() => guiding.isPhd2Running(
          host: any(named: 'host'),
          port: any(named: 'port'),
        )).thenAnswer((_) async => false);

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
          guidingBackendProvider.overrideWithValue(guiding),
        ],
        child: Consumer(builder: (ctx, ref, _) {
          container = ProviderScope.containerOf(ctx);
          return MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(body: OnboardingGuiderStep()),
          );
        }),
      ),
    );
    await tester.pump();
    await container.read(onboardingDraftProvider.notifier).loaded;
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(SkotiqButton, 'Test'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No response on'), findsOneWidget);

    await tester.enterText(
      find.byKey(guiderPortFieldKey),
      '4401',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('No response on'), findsNothing);
  });
}
