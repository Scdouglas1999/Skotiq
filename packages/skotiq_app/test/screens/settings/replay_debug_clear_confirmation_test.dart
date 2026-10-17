// "Clear all replay history" must not ask for consent to an unknown quantity: a
// confirmation naming a database table ("This deletes every row in the
// sequence_decisions table") without saying how much is there, and rendering its
// destructive action as plain text identical to Cancel, is weaker than the
// profile-delete dialog's filled red button.

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/replay_debug_settings.dart'
    as replay_ui;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _MockReplayController extends Mock
    implements ReplayDebugSettingsController {}

Finder _clearButton() =>
    find.widgetWithText(SkotiqButton, 'Clear all replay history');

Future<void> _openConfirmation(
  WidgetTester tester,
  _MockReplayController controller,
) async {
  await pumpAppScreen(
    tester,
    const replay_ui.ReplayDebugSettings(),
    extraOverrides: [
      replayDebugEnabledProvider.overrideWith((ref) async => true),
      replayDebugRetentionDaysProvider.overrideWith((ref) async => 90),
      replayDebugSettingsControllerProvider.overrideWithValue(controller),
    ],
  );
  await tester.tap(_clearButton());
  // Not pumpAndSettle: the Clear button spins while the dialog is up, and an
  // indeterminate spinner never settles.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the confirmation states how many decisions it will delete',
      (tester) async {
    final controller = _MockReplayController();
    when(() => controller.countAllHistory()).thenAnswer((_) async => 3);

    await _openConfirmation(tester, controller);

    expect(find.text('Clear all replay history?'), findsOneWidget);
    expect(
      find.textContaining('all 3 recorded decisions'),
      findsOneWidget,
      reason: 'consent to an unknown quantity is not consent',
    );
    expect(find.textContaining('sequence_decisions'), findsNothing);
  });

  testWidgets('the destructive action is styled as destructive',
      (tester) async {
    final controller = _MockReplayController();
    when(() => controller.countAllHistory()).thenAnswer((_) async => 3);

    await _openConfirmation(tester, controller);

    final confirm = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Clear history'),
    );
    expect(confirm.variant, ButtonVariant.destructive);
    final cancel = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Cancel'),
    );
    expect(cancel.variant, isNot(ButtonVariant.destructive));
  });

  testWidgets('an unknown count never claims a number', (tester) async {
    final controller = _MockReplayController();
    // Null is what an older imaging host (no unfiltered count endpoint) or a
    // failed read yields.
    when(() => controller.countAllHistory()).thenAnswer((_) async => null);

    await _openConfirmation(tester, controller);

    expect(find.text('Clear all replay history?'), findsOneWidget);
    expect(find.textContaining('recorded decisions'), findsNothing);
    expect(
      find.textContaining('every decision Skotiq has recorded'),
      findsOneWidget,
    );
  });
}
