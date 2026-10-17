import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/onboarding_screen.dart';

import '../../harness/harness.dart';

/// Confirms at the WIDGET layer what the accessibility tree showed after the
/// 2026-08-10 fix: an onboarding driver row is one checkbox node carrying its
/// own label and checked state.
///
/// Written because the same drive produced a false lead (G11) from an
/// accessibility-tree reading that the widget layer contradicted. A fix
/// verified only through the harness is verified through an instrument that has
/// already been wrong once, so the ones that matter get a test here too.
void main() {
  testWidgets('a driver row is a named, checked checkbox', (tester) async {
    await pumpAppScreen(tester, const OnboardingScreen());
    await tester.pumpAndSettle();

    // Step 2 is the driver picker; get there from the welcome step.
    final next = find.text('Next');
    if (next.evaluate().isNotEmpty) {
      await tester.tap(next.first);
      await tester.pumpAndSettle();
    }

    final handle = tester.ensureSemantics();
    final native = find.textContaining('Direct SDK connection');
    expect(native, findsWidgets, reason: 'the driver list should be on screen');

    // The row's own node, not the inner checkbox: the semantics live on the
    // container with the child excluded, so the ancestor is what AT sees.
    final rowSemantics = tester.getSemantics(native.first);
    expect(rowSemantics.label, contains('Native'));
    expect(
      rowSemantics.label,
      contains('Direct SDK connection'),
      reason: 'the description is part of the accessible name, not a sibling',
    );
    handle.dispose();
  });
}
