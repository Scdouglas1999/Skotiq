// Every rotator step button has to be on the card.
//
// Relative Move was one intrinsic-width Row inside a horizontal
// SingleChildScrollView. At the 320 px imaging side panel that put +5° hard
// against the card border and +15° entirely off-panel, with no fade, arrow or
// part-visible button to say the strip continued — so the largest step in
// either direction was, in practice, unreachable.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/rotator_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';

const _kDeviceId = 'simulator:rotator:0';

class _ConnectedRotatorNotifier extends RotatorStateNotifier {
  _ConnectedRotatorNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const RotatorState(
      connectionState: DeviceConnectionState.connected,
      deviceId: _kDeviceId,
      deviceName: 'Simulated Rotator',
      position: 0,
    );
  }
}

const _labels = ['-15°', '-5°', '-1°', '+1°', '+5°', '+15°'];

Future<void> _pumpAt(WidgetTester tester, double width) async {
  // Pin the panel to a real side-column width — the harness sizes the surface
  // itself, so the constraint has to come from the tree.
  await pumpAppScreen(
    tester,
    Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        child: const RotatorPanel(colors: SkotiqColors.dark),
      ),
    ),
    extraOverrides: [
      rotatorStateProvider.overrideWith(_ConnectedRotatorNotifier.new),
    ],
    settle: false,
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every relative-move step is inside the panel at 320 px',
      (tester) async {
    await _pumpAt(tester, 320);

    // The Relative Move card is the box the strip used to overflow.
    final card = tester.getRect(
      find
          .ancestor(
            of: find.text('-15°'),
            matching: find.byType(SkotiqCard),
          )
          .first,
    );

    for (final label in _labels) {
      final finder = find.text(label);
      expect(finder, findsOneWidget, reason: '$label must be rendered');
      final rect = tester.getRect(finder);
      expect(
        rect.left >= card.left && rect.right <= card.right,
        isTrue,
        reason: '$label is laid out outside its card '
            '(${rect.left}..${rect.right} vs ${card.left}..${card.right})',
      );
      // Laid out inside the card is not enough: it also has to be reachable,
      // which a clipped scroll view would deny.
      expect(finder.hitTestable(), findsOneWidget,
          reason: '$label must be tappable where it is drawn');
    }
  });

  testWidgets('the whole step button is tappable, not only its label',
      (tester) async {
    await _pumpAt(tester, 320);

    // Flexible cells make the box much wider than the glyphs; the extra width
    // is only a bigger target if it actually takes the tap.
    final button = find
        .ancestor(of: find.text('-15°'), matching: find.byType(GestureDetector))
        .first;
    final target = tester.renderObject(
      find.descendant(of: button, matching: find.byType(Listener)).first,
    );
    final box = tester.getRect(button);

    bool takesTap(Offset p) {
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(result, p, tester.view.viewId);
      return result.path.any((e) => identical(e.target, target));
    }

    expect(box.width, greaterThan(tester.getRect(find.text('-15°')).width),
        reason: 'the cell should be wider than the label');
    expect(takesTap(Offset(box.left + 3, box.center.dy)), isTrue,
        reason: 'the left inset of the button must take the tap');
    expect(takesTap(Offset(box.right - 3, box.center.dy)), isTrue,
        reason: 'the right inset of the button must take the tap');
    expect(takesTap(Offset(box.right + 5, box.center.dy)), isFalse,
        reason: 'sanity: the gap between buttons must not take the tap');
  });

  // Removing the horizontal scroll view made the cells flexible, so the labels
  // now have to survive the narrow end of the range the layout allows:
  // imaging_screen pins minPanelWidth to 250 and the tablet split in
  // adaptive_panel_layout clamps as low as 220. Left as a plain Text the label
  // word-wrapped at the hyphen below ~290 px — "-15°" rendered as a line
  // reading "-" over a line reading "15°".
  for (final width in <double>[250, 220]) {
    testWidgets('step labels stay on one line at ${width.toInt()} px',
        (tester) async {
      await _pumpAt(tester, width);
      expect(tester.takeException(), isNull);

      final card = tester.getRect(
        find
            .ancestor(
              of: find.text('-15°'),
              matching: find.byType(SkotiqCard),
            )
            .first,
      );

      for (final label in _labels) {
        final finder = find.text(label);
        expect(finder, findsOneWidget, reason: '$label must be rendered');
        final rect = tester.getRect(finder);
        expect(
          rect.height,
          lessThan(24),
          reason: '$label wrapped onto a second line at $width px '
              '(height ${rect.height})',
        );
        expect(
          rect.left >= card.left && rect.right <= card.right,
          isTrue,
          reason: '$label is laid out outside its card at $width px',
        );
        expect(finder.hitTestable(), findsOneWidget,
            reason: '$label must be tappable at $width px');
      }
    });
  }
}
