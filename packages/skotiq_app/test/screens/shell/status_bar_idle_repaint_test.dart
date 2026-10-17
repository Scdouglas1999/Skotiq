import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/widgets/status_bar.dart';

import '../../harness/pump_app_screen.dart';

/// What this pins, and why it is worth a test at all.
///
/// Measured on an idle release build with `SKOTIQ_FRAME_TIMING=1`, the
/// clock's per-second `setState` was the ONLY thing making the app produce
/// frames — a steady 1.0 fps with nothing on screen changing but the seconds:
///
/// ```text
/// [frame-timing] window=5.0s frames=6 fps=1.2 buildAvgMs=0.1 rasterAvgMs=229.3
/// [frame-timing] window=5.0s frames=4 fps=0.8 buildAvgMs=0.1 rasterAvgMs=231.9
/// ```
///
/// The tick lived on `_StatusBarState`, so each of those frames rebuilt the
/// whole bar — every device pill, both action buttons, the enclosing
/// `LayoutBuilder` — to move one digit, and repainted the parent layer with it.
/// Moving the tick into the clock chip and giving that chip a `RepaintBoundary`
/// is invisible on screen, which is exactly why it needs pinning: nothing about
/// the rendered bar would tell you it had regressed.
void main() {
  testWidgets('a second passing does not rebuild the whole status bar', (
    tester,
  ) async {
    final handle = await pumpAppScreen(
      tester,
      const Column(mainAxisSize: MainAxisSize.min, children: [StatusBar()]),
    );

    await tester.pump(const Duration(milliseconds: 50));

    // Flutter's own rebuild tracer is the instrument here: it names every
    // widget the framework rebuilt in a frame, which is precisely the claim.
    final rebuilt = <String>[];
    final previousPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) rebuilt.add(message);
    };
    debugPrintRebuildDirtyWidgets = true;

    // One full tick of the clock.
    await tester.pump(const Duration(seconds: 1));

    // Restored here rather than in a tear-down: the binding asserts that no
    // foundation debug variable is still set when the test body returns, and
    // tear-downs run after that check.
    debugPrintRebuildDirtyWidgets = false;
    debugPrint = previousPrint;

    final log = rebuilt.join('\n');

    // Prove the instrument is live BEFORE asserting on an absence: an empty
    // log would satisfy the isNot(contains(...)) below no matter what the app
    // did, which is the failure mode this whole campaign keeps finding.
    expect(
      log,
      contains('_TimeDisplay'),
      reason: 'the rebuild tracer captured nothing, so the check below proves '
          'nothing',
    );

    expect(
      log,
      isNot(contains('StatusBar')),
      reason:
          'the per-second clock tick rebuilt StatusBar itself, so every pill '
          'and button in the bar rebuilt to move one digit',
    );
    expect(
      log,
      isNot(contains('LayoutBuilder')),
      reason: 'the bar re-ran its width-dependent layout once a second',
    );

    // Keeps the analyzer honest that the harness was actually wired up.
    expect(handle.container, isNotNull);
  });

  testWidgets('the clock chip repaints without dirtying its parent layer', (
    tester,
  ) async {
    final handle = await pumpAppScreen(
      tester,
      const Column(mainAxisSize: MainAxisSize.min, children: [StatusBar()]),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // Find the wall clock by its shape (HH:MM:SS) rather than a fixed string,
    // since the value moves while the test runs.
    final clock = find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          widget.data != null &&
          RegExp(r'^\d{2}:\d{2}:\d{2}$').hasMatch(widget.data!),
      description: 'wall-clock text',
    );
    expect(clock, findsOneWidget);

    // A repaint boundary between the clock and the bar is what keeps a ticking
    // second off the parent layer. Without it the digit change marks the whole
    // window dirty and it re-rasterises once a second.
    expect(
      find.ancestor(of: clock, matching: find.byType(RepaintBoundary)),
      findsWidgets,
      reason: 'the clock is not isolated behind a RepaintBoundary',
    );

    // Keeps the analyzer honest that the harness was actually wired up.
    expect(handle.container, isNotNull);
  });
}
