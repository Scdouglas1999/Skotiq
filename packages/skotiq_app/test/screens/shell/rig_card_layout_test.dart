// The Rig card must not silently drop status information.
//
// The bottom status strip this card replaces dealt with a narrow window by
// scrolling a pill row — and failed that way once before, so the pin was a
// viewport assertion. The card answers differently: it lives in the sidebar,
// which has a FIXED width, so every row is always fully inside the card and
// nothing scrolls. The risk now is the other direction — a row dropped at a
// width, or text squeezed past the card's edge.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/widgets/rig_card.dart';

import '../../harness/pump_app_screen.dart';

Future<void> _pumpCard(WidgetTester tester, {double width = 220}) async {
  await pumpAppScreen(
    tester,
    SizedBox(
      width: width,
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [RigCard(isExpanded: true)],
      ),
    ),
    size: const Size(1400, 900),
    // The card probes the save path; settling waits on nothing that ticks.
    settle: false,
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _disposeCard(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  // Shedding the labels is not an option: rendering the state alone left
  // Camera, Mount and Guider reading the identical word "Disconnected",
  // distinguished only by a small monochrome glyph — three rows' worth of
  // width spent saying nothing. So an empty slot names the thing that is
  // missing.
  testWidgets('every device row names its own device', (tester) async {
    for (final width in const [176.0, 220.0]) {
      await _pumpCard(tester, width: width);

      for (final value in [
        'No camera',
        'No mount',
        'No guider',
        'No focuser',
      ]) {
        expect(
          find.descendant(
            of: find.byType(RigCard),
            matching: find.text(value),
          ),
          findsOneWidget,
          reason: '"$value" has to stay identifiable at ${width}px',
        );
      }
      expect(
        find.descendant(
          of: find.byType(RigCard),
          matching: find.text('Disconnected'),
        ),
        findsNothing,
        reason: 'the same word on three rows is width spent saying nothing',
      );
      expect(tester.takeException(), isNull);

      await _disposeCard(tester);
    }
  });

  testWidgets('the card carries the run state and the save path',
      (tester) async {
    await _pumpCard(tester);

    // The one run-state answer, once.
    expect(
      find.descendant(of: find.byType(RigCard), matching: find.text('Idle')),
      findsOneWidget,
    );
    // And where the images go.
    expect(
      find.descendant(
        of: find.byType(RigCard),
        matching: find.text('No save path'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await _disposeCard(tester);
  });

  testWidgets('every row lays out inside the card', (tester) async {
    await _pumpCard(tester, width: 220);

    final cardRect = tester.getRect(find.byType(RigCard));
    final texts = find.descendant(
      of: find.byType(RigCard),
      matching: find.byType(Text),
    );
    var checked = 0;
    for (var i = 0; i < texts.evaluate().length; i++) {
      final rect = tester.getRect(texts.at(i));
      checked++;
      expect(
        rect.right,
        lessThanOrEqualTo(cardRect.right + 0.5),
        reason:
            'readout "${(texts.at(i).evaluate().single.widget as Text).data}" '
            'is cut off at the card edge',
      );
      expect(rect.left, greaterThanOrEqualTo(cardRect.left - 0.5));
    }
    expect(checked, greaterThan(4), reason: 'too few rows were checked');
    expect(tester.takeException(), isNull);

    await _disposeCard(tester);
  });
}
