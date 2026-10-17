// The glass capture bar MEASURES its natural width and scrolls only when it
// genuinely does not fit. No dp threshold can be right: with auto-stretch ON
// the trailing cluster grows by a method dropdown plus the advanced-settings
// icon button, and whether the intrinsically-sized children fit depends on
// runtime content (filter names, locale, text scale). Above a wrong threshold
// the fixed children overflow the Row and the advanced-settings button is
// hard-clipped to a sliver that still swallows clicks, with no scroll to
// recover it.
//
// This contract survived the Observatory relayout: the bar moved from a
// full-width banner under the preview to a content-sized glass pill over the
// frame, and at a 900 dp window with the side panel open it has LESS room than
// before, not more. The sweep below covers the widths that actually overflow.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_capture_bar.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _StretchOn extends AutoStretchSettingsNotifier {
  _StretchOn(super.ref) {
    state = state.copyWith(enabled: true);
  }
}

Future<void> _pumpBar(
  WidgetTester tester, {
  required double width,
  required bool stretchEnabled,
}) async {
  await pumpAppScreen(
    tester,
    // The real tree is Positioned(left/right) > Align > bar, so the bar gets
    // LOOSE constraints capped by the canvas and shrink-wraps inside them.
    Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        width: width,
        child: const Align(
          child: ImagingCaptureBar(
            isLooping: false,
            isSingleCapture: false,
            isSavingCapture: false,
            isStoppingCapture: false,
            onSnapshot: _noop,
            onToggleLoop: _noop,
          ),
        ),
      ),
    ),
    size: Size(width, 900),
    settle: false,
    extraOverrides: <Override>[
      if (stretchEnabled)
        autoStretchSettingsProvider.overrideWith(_StretchOn.new),
    ],
  );
  await tester.pump(_settleFrame);
}

void _noop() {}

Finder get _barScrollable => find
    .descendant(
      of: find.byType(ImagingCaptureBar),
      matching: find.byType(Scrollable),
    )
    .first;

/// One frame, long enough for the async provider overrides to land.
const Duration _settleFrame = Duration(milliseconds: 50);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The band the audit measured, plus its edges, plus the widths a narrow
  // desktop window actually leaves the canvas once the rail and the side
  // panel have taken theirs.
  for (final width in const [
    420.0,
    516.0,
    740.0,
    760.0,
    820.0,
    960.0,
    1216.0,
  ]) {
    for (final stretchEnabled in const [true, false]) {
      final label = stretchEnabled ? 'on' : 'off';
      testWidgets(
        'auto-stretch $label at ${width.toInt()} dp does not clip or overflow',
        (tester) async {
          await _pumpBar(
            tester,
            width: width,
            stretchEnabled: stretchEnabled,
          );

          expect(
            tester.takeException(),
            isNull,
            reason: 'the capture bar overflowed at $width dp with auto-stretch '
                '$label; a threshold-based fork is what made this '
                'width-dependent',
          );

          // Every trailing control must be inside the bar, reachable, at every
          // width — scrolling if need be, but never sliced by the edge.
          final trailing = find.descendant(
            of: find.byType(ImagingCaptureBar),
            matching: find.text('Stretch'),
          );
          expect(trailing, findsOneWidget);

          final scrollable = _barScrollable;
          if (scrollable.evaluate().isNotEmpty) {
            await tester.scrollUntilVisible(
              trailing,
              -120,
              scrollable: scrollable,
            );
            await tester.pump();
          }
          final bar = tester.getRect(find.byType(Glass));
          final rect = tester.getRect(trailing);
          expect(
            rect.left >= bar.left - 0.5 && rect.right <= bar.right + 0.5,
            isTrue,
            reason: 'trailing control clipped by the bar edge at $width dp '
                '(stretch $label): $rect vs $bar',
          );
        },
      );
    }
  }

  testWidgets('the bar shows that it scrolls when it does not fit',
      (tester) async {
    await _pumpBar(tester, width: 420, stretchEnabled: true);

    final position = tester.state<ScrollableState>(_barScrollable).position;
    expect(
      position.maxScrollExtent,
      greaterThan(0),
      reason: 'at 420 dp the bar does not fit, so it must offer scroll extent '
          'instead of laying controls out past its edge',
    );
    expect(position.axis, Axis.horizontal);

    // Reachable is not discoverable: a bar that scrolls silently reads as
    // "cut off with no affordance". The scrollbar is the affordance.
    expect(
      find.descendant(
        of: find.byType(ImagingCaptureBar),
        matching: find.byType(Scrollbar),
      ),
      findsOneWidget,
      reason: 'the capture bar must show that it scrolls',
    );
  });

  testWidgets('a wide canvas leaves the bar its content width', (tester) async {
    await _pumpBar(tester, width: 1216, stretchEnabled: false);

    // Measure the glass panel, not the box the test hands the bar: the bar
    // shrink-wraps INSIDE whatever room it is given, which on the real screen
    // is an Align over the canvas.
    final bar = tester.getRect(find.byType(Glass));
    expect(
      bar.width,
      lessThan(1216),
      reason: 'the mockup centres a content-sized pill over the frame; a bar '
          'that fills the canvas is a bar that stopped measuring',
    );
  });
}
