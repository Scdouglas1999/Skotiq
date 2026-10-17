// The filter-wheel step must save the slots it shows.
//
// The slot editor only reached the draft when the user typed in it. A wheel
// whose real slot count could not be read (connect failed, or the step was
// re-entered after that failure) therefore displayed a column of named,
// apparently-saved slots and then created an equipment profile with NO filters
// — the sequencer's filter list came up empty on the first night.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/filter_wheel_step.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Draft standing in for a wheel picked on an earlier visit whose slot read
/// failed: the wheel is on record, the names are not.
class _WheelWithoutNamesNotifier extends OnboardingNotifier {
  _WheelWithoutNamesNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const OnboardingDraft(
      currentStep: OnboardingStep.filterWheel,
      filterWheelId: 'efw-1',
      filterWheelName: 'ZWO EFW',
    );
  }
}

class _NamedWheelNotifier extends OnboardingNotifier {
  _NamedWheelNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const OnboardingDraft(
      currentStep: OnboardingStep.filterWheel,
      filterWheelId: 'efw-1',
      filterWheelName: 'ZWO EFW',
      filterNames: ['Ha', 'OIII', 'SII'],
    );
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  OnboardingNotifier Function(Ref ref) notifier,
) async {
  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 1600);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  late ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        onboardingDraftProvider.overrideWith(notifier),
        // The step reads the connected wheel's position count to cap the slot
        // list, which builds the real filter-wheel notifier; that notifier
        // listens to the active profile, and an un-stubbed profile stream
        // leaves a drift query open past the end of the test.
        activeProfileProvider.overrideWith((ref) => Stream.value(null)),
        allProfilesProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      child: Consumer(builder: (ctx, ref, _) {
        container = ProviderScope.containerOf(ctx);
        return MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: OnboardingFilterWheelStep()),
        );
      }),
    ),
  );
  await tester.pump();
  await tester.pump();
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('displayed fallback slots are written to the draft', (
    tester,
  ) async {
    final container = await _pump(tester, _WheelWithoutNamesNotifier.new);

    final names = container.read(onboardingDraftProvider).filterNames;
    expect(names.length, 5, reason: 'the five slots on screen are the profile');
    expect(names.first, 'Filter 1');
    expect(names.last, 'Filter 5');
    // What is stored is what is rendered.
    for (final name in names) {
      expect(find.widgetWithText(TextField, name), findsOneWidget);
    }
  });

  testWidgets('names already on record are left exactly as they are', (
    tester,
  ) async {
    final container = await _pump(tester, _NamedWheelNotifier.new);

    expect(
      container.read(onboardingDraftProvider).filterNames,
      ['Ha', 'OIII', 'SII'],
      reason: 'placeholders must never overwrite real names',
    );
  });
}
