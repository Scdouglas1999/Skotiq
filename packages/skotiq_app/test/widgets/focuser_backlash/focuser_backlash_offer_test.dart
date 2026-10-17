// The offer must never cost somebody a night.
//
// It appears only when the provider says a measurement is due; declining runs
// the focus operation immediately; and "Skip and focus now" and "Don't ask
// again" are different promises that are never conflated.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/focuser_backlash/focuser_backlash_offer.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';
import 'backlash_fixtures.dart';

/// Records what the UI decided, without persisting anything.
class _FakeOffers extends FocuserBacklashOfferNotifier {
  _FakeOffers(super.ref);

  final List<bool> declines = <bool>[];

  @override
  Future<void> declineOffer({required bool never}) async => declines.add(never);
}

class _NoopCalibration extends FocuserBacklashCalibrationNotifier {
  _NoopCalibration(super.ref);

  @override
  Future<void> loadPlan({int? centerPosition}) async {}

  @override
  void reset() {}
}

const _noFigure = EffectiveFocuserBacklash(
  steps: 0,
  origin: FocuserBacklashOrigin.none,
  provenance:
      'this focuser has not been measured and you have not entered a figure',
);

/// Pumps a button that launches a focus operation through the shared offer
/// interception, and reports whether the operation actually ran.
Future<({_FakeOffers offers, List<String> ran})> _pumpLauncher(
  WidgetTester tester, {
  required bool offerDue,
  EffectiveFocuserBacklash effective = _noFigure,
}) async {
  final ran = <String>[];
  final handle = await pumpAppScreen(
    tester,
    Consumer(
      builder: (context, ref, _) => Center(
        child: ElevatedButton(
          onPressed: () => runWithBacklashOffer(
            context,
            ref,
            proceed: () async => ran.add('autofocus'),
          ),
          child: const Text('FOCUS'),
        ),
      ),
    ),
    size: const Size(900, 1000),
    extraOverrides: [
      focuserBacklashOfferProvider.overrideWithValue(offerDue),
      effectiveFocuserBacklashProvider.overrideWithValue(effective),
      savedFocuserBacklashProvider.overrideWith((ref) => null),
      focuserBacklashOfferSessionProvider.overrideWith(_FakeOffers.new),
      focuserBacklashCalibrationProvider.overrideWith(_NoopCalibration.new),
    ],
  );
  // Read through the container rather than capturing from the override: the
  // provider is only built when the offer path actually asks for it.
  final offers = handle.container.read(
    focuserBacklashOfferSessionProvider.notifier,
  ) as _FakeOffers;
  return (offers: offers, ran: ran);
}

void main() {
  testWidgets('no offer, and the focus runs, when none is due', (tester) async {
    final harness = await _pumpLauncher(tester, offerDue: false);

    await tester.tap(find.text('FOCUS'));
    await tester.pumpAndSettle();

    expect(find.byType(FocuserBacklashOfferDialog), findsNothing);
    expect(harness.ran, ['autofocus']);
    expect(harness.offers.declines, isEmpty);
  });

  testWidgets('offers when one is due, and says what is in force now', (
    tester,
  ) async {
    await _pumpLauncher(tester, offerDue: true);

    await tester.tap(find.text('FOCUS'));
    await tester.pumpAndSettle();

    expect(find.byType(FocuserBacklashOfferDialog), findsOneWidget);
    expect(
      find.textContaining('A perfect-looking curve can still land on donuts'),
      findsOneWidget,
    );
    // Honest about the current state rather than silent about it.
    expect(
      find.textContaining('Backlash compensation is off'),
      findsOneWidget,
    );
    // The three exits, each labelled with the promise it keeps.
    expect(
      find.widgetWithText(SkotiqButton, 'Skip and focus now'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(SkotiqButton, "Don't ask again"),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(SkotiqButton, 'Measure first'),
      findsOneWidget,
    );
  });

  testWidgets('skipping proceeds with the focus and does not persist', (
    tester,
  ) async {
    final harness = await _pumpLauncher(tester, offerDue: true);

    await tester.tap(find.text('FOCUS'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Skip and focus now'),
    );
    await tester.pumpAndSettle();

    expect(harness.ran, ['autofocus']);
    expect(harness.offers.declines, [false]);
  });

  testWidgets("\"Don't ask again\" persists the opt-out and still focuses", (
    tester,
  ) async {
    final harness = await _pumpLauncher(tester, offerDue: true);

    await tester.tap(find.text('FOCUS'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SkotiqButton, "Don't ask again"));
    await tester.pumpAndSettle();

    expect(harness.offers.declines, [true]);
    // An opt-out is not a cancellation.
    expect(harness.ran, ['autofocus']);
  });

  testWidgets('dismissing the offer is the mild promise, not the permanent one',
      (tester) async {
    final harness = await _pumpLauncher(tester, offerDue: true);

    await tester.tap(find.text('FOCUS'));
    await tester.pumpAndSettle();
    // Tap the barrier.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(harness.offers.declines, [false]);
    expect(harness.ran, ['autofocus']);
  });

  testWidgets('measuring first opens the wizard, then focuses anyway', (
    tester,
  ) async {
    final harness = await _pumpLauncher(tester, offerDue: true);

    await tester.tap(find.text('FOCUS'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SkotiqButton, 'Measure first'));
    // The wizard's plan-loading state carries an indeterminate bar, so settle
    // is not available here.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Measure focuser backlash'), findsOneWidget);
    // The focus operation has not run yet — the operator chose to measure.
    expect(harness.ran, isEmpty);

    // Close the wizard without saving.
    await tester.tap(find.widgetWithText(SkotiqButton, 'Not now'));
    await tester.pumpAndSettle();

    // Nothing was saved, so the session stops asking — but the run the
    // operator originally wanted still happens.
    expect(harness.offers.declines, [false]);
    expect(harness.ran, ['autofocus']);
  });

  testWidgets('an existing figure is quoted with its provenance', (
    tester,
  ) async {
    await _pumpLauncher(
      tester,
      offerDue: true,
      effective: EffectiveFocuserBacklash(
        steps: 105,
        origin: FocuserBacklashOrigin.measured,
        provenance: 'measured on 2026-09-14 at position 6620, 14.5 °C',
        record: record105(),
      ),
    );

    await tester.tap(find.text('FOCUS'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        'compensates 105 steps, measured on 2026-09-14 at position 6620',
      ),
      findsOneWidget,
    );
  });
}
