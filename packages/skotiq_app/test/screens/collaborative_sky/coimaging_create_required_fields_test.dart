// Live finding: on the "Start co-imaging session" sheet, pressing the primary
// action with the form empty did nothing at all — no message, no field error,
// no tooltip, while the two coordinate-source buttons beside it both explain
// themselves on hover.
//
// The sheet DOES carry the right copy ('Enter a target name.', 'Enter the
// target center RA.', ...), gated on a `_submitted` flag. But the only place
// that set the flag was `_create`, and `_create` was only reachable once the
// form already validated, so those strings could never render. The button was
// disabled and the form stayed silent about why.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/collaborative_sky/coimaging_create_sheet.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _FixedMount extends MountStateNotifier {
  _FixedMount(super.ref, MountState fixed) {
    state = fixed;
  }
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        mountStateProvider
            .overrideWith((ref) => _FixedMount(ref, const MountState())),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showCoImagingCreateSheet(context),
                child: const Text('start'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('start'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the primary action is pressable on an incomplete form',
      (tester) async {
    await _openSheet(tester);

    expect(
      tester
          .widget<SkotiqButton>(
            find.widgetWithText(SkotiqButton, 'Start session'),
          )
          .onPressed,
      isNotNull,
      reason: 'a dead button leaves the operator with nothing to act on',
    );
  });

  testWidgets('pressing it on an empty form names every missing field',
      (tester) async {
    await _openSheet(tester);

    // Nothing is scolded before the operator has tried anything.
    expect(find.text('Enter a target name.'), findsNothing);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Start session'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a target name.'), findsOneWidget);
    expect(find.text('Enter the target center RA.'), findsOneWidget);
    expect(find.text('Enter the target center Dec.'), findsOneWidget);
    // The radius ships with a default, so it is the one field that is already
    // answered; it must NOT be flagged.
    expect(find.text('Enter a session radius.'), findsNothing);
  });

  testWidgets('a half-filled form flags only what is still missing',
      (tester) async {
    await _openSheet(tester);

    await tester.enterText(find.byType(TextField).first, 'NGC 7000');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(SkotiqButton, 'Start session'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a target name.'), findsNothing);
    expect(find.text('Enter the target center RA.'), findsOneWidget);
    expect(find.text('Enter the target center Dec.'), findsOneWidget);
  });
}
