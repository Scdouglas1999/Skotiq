// The guider card carries ONE status line. Stacking a green "Guider set to PHD2
// at localhost:4400" directly above a red "No response on localhost:4400" is
// self-contradictory, and a red line that outlives the choice it belongs to
// survives picking the built-in guider underneath — ending the step with a
// working native guider chosen and an error showing.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/onboarding/steps/guider_step.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockGuidingBackend extends Mock implements GuidingBackend {}

Future<ProviderContainer> _pumpStep(
  WidgetTester tester,
  GuidingBackend guiding,
  SkotiqDatabase db,
) async {
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
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late _MockGuidingBackend guiding;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    guiding = _MockGuidingBackend();
    when(() => guiding.isPhd2Running(
          host: any(named: 'host'),
          port: any(named: 'port'),
        )).thenAnswer((_) async => false);
  });

  testWidgets('a failed probe and a PHD2 selection are one line, not two',
      (tester) async {
    await _pumpStep(tester, guiding, db);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Test'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No response on'), findsOneWidget);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Use PHD2'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Guider set to PHD2 at localhost:4400, but nothing '
          'answered there yet'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Guider set to PHD2 at localhost:4400.'),
      findsNothing,
      reason: 'the unqualified success line must not sit above the failure',
    );
  });

  testWidgets('choosing another guider retires the PHD2 failure',
      (tester) async {
    final container = await _pumpStep(tester, guiding, db);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Test'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No response on'), findsOneWidget);

    // The native-guider picker is a device list this test has no devices for,
    // so the selection is made through the draft the picker writes to.
    await container
        .read(onboardingDraftProvider.notifier)
        .setGuider(id: 'native:multistar', name: 'Built-in Multi-Star Guider');
    await tester.pumpAndSettle();

    expect(
      find.textContaining('No response on'),
      findsNothing,
      reason: 'a PHD2 probe says nothing about the guider now on record',
    );
  });
}
