// The producer side of the "one guided flow at a time" rule.
//
// The first-night walkthrough claims [guidedFlowActiveProvider] while it owns
// the user's attention. The subtlety worth a test: "Show me on the Sequencer
// screen" POPS this dialog to park the walkthrough on that screen, so releasing
// the claim on dispose would put the Sequencer's own tour nudge right back in
// the corner the moment the walkthrough sent the user there — the exact defect
// the flag exists to stop. Only Done, Skip forever and Close release it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/tutorial/first_night_wizard.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/pump_app_screen.dart';

/// Host that opens the wizard as a modal over a trivial screen, the way the
/// real route and the Settings → Help row both do.
class _WizardHost extends StatelessWidget {
  const _WizardHost();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => FirstNightWizard.show(context),
          child: const Text('open'),
        ),
      ),
    );
  }
}

Future<HarnessHandle> _open(WidgetTester tester) async {
  final handle = await pumpAppScreen(
    tester,
    const _WizardHost(),
    size: const Size(1200, 900),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return handle;
}

void main() {
  testWidgets('opening the walkthrough claims the guided flow', (tester) async {
    final handle = await _open(tester);
    expect(handle.container.read(guidedFlowActiveProvider), isTrue);
  });

  testWidgets('closing the walkthrough hands the screen back', (tester) async {
    final handle = await _open(tester);
    expect(handle.container.read(guidedFlowActiveProvider), isTrue);

    // Step 0's footer offers Close rather than Back.
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(handle.container.read(guidedFlowActiveProvider), isFalse);
  });

  testWidgets('"Skip forever" hands the screen back', (tester) async {
    final handle = await _open(tester);

    await tester.tap(find.text('Skip forever'));
    await tester.pumpAndSettle();

    expect(handle.container.read(guidedFlowActiveProvider), isFalse);
  });

  testWidgets('a bare pop keeps the claim, so a "Show me" deep link does too',
      (tester) async {
    // `_handleShowMe` saves progress, pops this dialog and then navigates —
    // it does NOT take a terminal action, because the walkthrough is being
    // parked on the target screen rather than finished. Popping without one of
    // the three terminal handlers is exactly that shape (driving the real
    // button needs a GoRouter this harness has no reason to own), and the
    // invariant is that teardown alone must not release the claim.
    final handle = await _open(tester);
    expect(handle.container.read(guidedFlowActiveProvider), isTrue);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.pop();
    await tester.pumpAndSettle();

    expect(find.byType(FirstNightWizard), findsNothing);
    expect(
      handle.container.read(guidedFlowActiveProvider),
      isTrue,
      reason: 'the walkthrough is parked on the target screen, not finished',
    );
  });
}
