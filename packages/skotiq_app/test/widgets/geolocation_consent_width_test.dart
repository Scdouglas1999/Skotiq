// The geolocation consent dialog must read like the rest of the app's dialogs.
//
// Found live (coverage closeout, never-claimed cluster B): on the 1600 px
// desktop window the dialog rendered ~1520 px wide — its body was one unbroken
// line of text running the full width of the app, because the AlertDialog had
// no width constraint at all. Every other dialog on the same screen
// (SequenceIssuesDialog, the unwritable-capture-folder confirm) is bounded by
// AdaptiveDialogConstraints at the 480 px design width.
//
// This is the consent gate for every outbound request the app makes about
// where it is — the names of the networks around the house as well as the
// operator's public IP address — so it is exactly the dialog that has to look
// deliberate and be easy to read.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/geolocation_consent.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the consent dialog is bounded on a wide desktop window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => confirmGeolocationLookup(
                  context,
                  outcome: kGeolocationOffersEstimateOutcome,
                ),
                child: const Text('ask'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();

    expect(find.text('Detect this site’s location?'), findsOneWidget);

    final body = find.textContaining('Skotiq will try these in order');
    expect(body, findsOneWidget);

    final width = tester.getSize(body).width;
    expect(
      width,
      lessThanOrEqualTo(480.0),
      reason: 'the body text ran $width px wide in a 1600 px window; the '
          'dialog must stay at the 480 px design width like every other one',
    );
  });
}
