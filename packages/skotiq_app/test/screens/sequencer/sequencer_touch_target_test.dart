// Focused touch-target regressions for the sequencer controls that were
// measurably under Android's 48dp rule on a phone.
//
// `test/screens/mobile_tap_target_test.dart` catches these at screen level, but
// only for whatever happens to be on screen with an empty mock backend — the
// target header card, for instance, never renders there because no sequence is
// loaded. These tests pump the controls directly so the invariant is pinned to
// the widget rather than to a screen's incidental contents.
//
// They measure the SEMANTICS rect, not a widget's box, because that is what
// Android's rule is actually about: `IconButton` wraps a 40dp visual button in
// a 48dp `_InputPadding` hit area, so measuring (say) the inner `Tooltip`
// reports 40x40 for a control that is in fact compliant — and measuring the
// visual button reports 40x40 for one that is not. Only the semantics rect
// tells the two apart.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_toolbar.dart';
import 'package:skotiq_app/screens/sequencer/widgets/target_header_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// Android's minimum touch-target edge, in logical pixels.
const double kMinTapTarget = 48.0;

/// The rect of the tappable semantics node whose label or tooltip is [name].
Rect _tapTargetRect(String name) {
  final matchingNodes = find.semantics.byPredicate((node) {
    final data = node.getSemanticsData();
    return data.hasAction(SemanticsAction.tap) &&
        !data.flagsCollection.isHidden &&
        (data.label == name || data.tooltip == name);
  }).evaluate();
  expect(
    matchingNodes,
    hasLength(1),
    reason: 'expected one tappable semantics node named "$name"',
  );
  return matchingNodes.single.rect;
}

void _expectMeetsTouchMinimum(String name) {
  final rect = _tapTargetRect(name);
  final reason = '"$name" is ${rect.width}x${rect.height}; '
      'Android requires ${kMinTapTarget}dp on both edges';
  expect(rect.width, greaterThanOrEqualTo(kMinTapTarget), reason: reason);
  expect(rect.height, greaterThanOrEqualTo(kMinTapTarget), reason: reason);
}

void main() {
  group('SequenceToolbar', () {
    // The phone toolbar was `height: 48` — the touch minimum exactly — while
    // also drawing a 1dp bottom border. `Container` folds the border's
    // dimensions into the child's padding, so the action row got 47dp and the
    // overflow menu rendered 48.0x47.0. One dp, invisible by eye, and a real
    // Android accessibility failure.
    testWidgets('overflow menu meets the touch minimum on a phone',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpAppScreen(
        tester,
        const SequenceToolbar(colors: SkotiqColors.dark),
        size: const Size(390, 844),
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 100));

      _expectMeetsTouchMinimum('More actions');
      handle.dispose();
      // Drain live validation's 500 ms debounce so the binding does not
      // fail the test on a pending timer.
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('bar height leaves a full touch target above its divider',
        (tester) async {
      await pumpAppScreen(
        tester,
        const SequenceToolbar(colors: SkotiqColors.dark),
        size: const Size(360, 640),
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 100));

      // Guards the mechanism, not just this one button: any control the phone
      // toolbar hosts has to fit in the row *after* the border is subtracted.
      final bar = tester.getSize(find.byType(SequenceToolbar));
      expect(
        bar.height,
        greaterThanOrEqualTo(kMinTapTarget + 1.0),
        reason: 'the phone toolbar draws a 1dp bottom border that comes out '
            'of its child row, so the bar must be the touch minimum PLUS that '
            'border or every control inside it is 1dp short',
      );
      // Drain live validation's 500 ms debounce so the binding does not
      // fail the test on a pending timer.
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('TargetHeaderCard', () {
    // These two live in a card that only appears once a sequence with targets
    // is loaded, which no screen-level test covers — they were 28x28 by
    // declaration, and `VisualDensity.compact` was independently shrinking the
    // hit area by 8dp underneath. Both had to go for the control to be legal.
    Widget card() => const Material(
          child: _CardHost(),
        );

    testWidgets('altitude-chart toggle meets the touch minimum on a phone',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpAppScreen(tester, card(),
          size: const Size(390, 844), settle: false);
      await tester.pump(const Duration(milliseconds: 100));

      _expectMeetsTouchMinimum('Show altitude chart');
      handle.dispose();
      // Drain live validation's 500 ms debounce so the binding does not
      // fail the test on a pending timer.
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('overflow menu meets the touch minimum on a phone',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpAppScreen(tester, card(),
          size: const Size(390, 844), settle: false);
      await tester.pump(const Duration(milliseconds: 100));

      _expectMeetsTouchMinimum('Show menu');
      handle.dispose();
      // Drain live validation's 500 ms debounce so the binding does not
      // fail the test on a pending timer.
      await tester.pump(const Duration(seconds: 1));
    });
  });
}

/// Hosts the card so the node can be built once per pump without a `const`
/// constructor complaint.
class _CardHost extends StatelessWidget {
  const _CardHost();

  @override
  Widget build(BuildContext context) {
    return TargetHeaderCard(
      node: TargetHeaderNode(
        targetName: 'M31',
        raHours: 0.712,
        decDegrees: 41.269,
      ),
      colors: SkotiqColors.dark,
      isMobile: true,
      onSelect: () {},
      onToggleEnabled: () {},
      onDelete: () {},
    );
  }
}
