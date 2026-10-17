// The guider step must be completable with PHD2 switched off.
//
// Selecting PHD2 used to happen only as a side effect of a *successful*
// socket probe, so anyone running the wizard indoors before launching PHD2
// could not record their guider at all: Next dropped the typed host/port and
// the summary step said "— not set —". "Use PHD2" is the explicit selection;
// Test stays as verification.

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

  testWidgets('PHD2 can be chosen while the probe is failing', (tester) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final guiding = _MockGuidingBackend();
    // PHD2 is not running — the state this whole fix exists for.
    when(() => guiding.isPhd2Running(
          host: any(named: 'host'),
          port: any(named: 'port'),
        )).thenAnswer((_) async => false);

    final container = await _pumpStep(tester, guiding, db);

    await tester.enterText(
      find.byKey(guiderHostFieldKey),
      '192.168.1.50',
    );
    await tester.pumpAndSettle();

    // The honest failure does not block the choice.
    await tester.tap(find.widgetWithText(SkotiqButton, 'Test'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No response on'), findsOneWidget);
    expect(container.read(onboardingDraftProvider).guiderId, isNull);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Use PHD2'));
    await tester.pumpAndSettle();

    expect(
      container.read(onboardingDraftProvider).guiderId,
      'phd2:192.168.1.50:4400',
    );
    expect(
      container.read(onboardingDraftProvider).guiderName,
      'PHD2 (192.168.1.50:4400)',
      reason: 'the summary step renders guiderName, not the id',
    );
    // The endpoint the connect path actually reads is persisted too.
    final settings = await container.read(appSettingsProvider.future);
    expect(settings.phd2Host, '192.168.1.50');
    expect(settings.phd2Port, 4400);

    expect(
      find.textContaining('Guider set to PHD2 at 192.168.1.50:4400'),
      findsOneWidget,
    );
  });

  testWidgets('Clear retires the PHD2 selection', (tester) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final guiding = _MockGuidingBackend();
    when(() => guiding.isPhd2Running(
          host: any(named: 'host'),
          port: any(named: 'port'),
        )).thenAnswer((_) async => false);

    final container = await _pumpStep(tester, guiding, db);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Use PHD2'));
    await tester.pumpAndSettle();
    expect(container.read(onboardingDraftProvider).guiderId, isNotNull);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Clear'));
    await tester.pumpAndSettle();
    expect(container.read(onboardingDraftProvider).guiderId, isNull);
    expect(find.widgetWithText(SkotiqButton, 'Use PHD2'), findsOneWidget);
  });
}
