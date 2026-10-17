// An urgent dot pulses to draw the eye, then settles.
//
// Measured on the release bundle: a run that FAILED left the status bar's red
// dot (StatusDotVariant.urgent) repeating forever, and on the Linux embedder
// every tick is a full-window frame — 61 fps and 32.7% of a core on an app
// doing nothing, for as long as the failure stayed on screen. The pulse is
// bounded: after [StatusDot.urgentPulseWindow] the dot holds full opacity
// and stops asking for frames. It is still red; it still says "failed".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _host(StatusDotVariant variant) => MaterialApp(
  home: Center(
    child: StatusDot(color: Colors.red, variant: variant),
  ),
);

AnimationController _controllerOf(WidgetTester tester) {
  final state = tester.state(find.byType(StatusDot)) as dynamic;
  return state.debugControllerForTesting as AnimationController;
}

double _paintedAlpha(WidgetTester tester) {
  final container = tester.widget<Container>(
    find.descendant(
      of: find.byType(StatusDot),
      matching: find.byType(Container),
    ),
  );
  return (container.decoration! as BoxDecoration).color!.a;
}

void main() {
  testWidgets('an urgent dot pulses, then settles to a steady full dot', (
    tester,
  ) async {
    await tester.pumpWidget(_host(StatusDotVariant.urgent));
    await tester.pump();

    final controller = _controllerOf(tester);
    expect(
      controller.isAnimating,
      isTrue,
      reason: 'the pulse must run while the window is open',
    );

    // Halfway through the window it is still drawing attention.
    await tester.pump(StatusDot.urgentPulseWindow ~/ 2);
    expect(controller.isAnimating, isTrue);

    await tester.pump(
      StatusDot.urgentPulseWindow ~/ 2 + const Duration(milliseconds: 50),
    );
    await tester.pump();
    expect(
      controller.isAnimating,
      isFalse,
      reason: 'past the window the dot must stop asking for frames',
    );
    expect(controller.value, 1.0);
    expect(
      _paintedAlpha(tester),
      closeTo(1.0, 1e-6),
      reason: 'settled means steady at full opacity, not dimmed mid-pulse',
    );

    // Nothing restarts it while the state persists.
    await tester.pump(const Duration(seconds: 5));
    expect(controller.isAnimating, isFalse);
  });

  testWidgets('re-entering the urgent state opens a fresh window', (
    tester,
  ) async {
    await tester.pumpWidget(_host(StatusDotVariant.urgent));
    await tester.pump(
      StatusDot.urgentPulseWindow + const Duration(milliseconds: 50),
    );
    await tester.pump();
    expect(_controllerOf(tester).isAnimating, isFalse);

    // Recovered, then failed again: the new failure deserves its own pulse.
    await tester.pumpWidget(_host(StatusDotVariant.static));
    await tester.pump();
    await tester.pumpWidget(_host(StatusDotVariant.urgent));
    await tester.pump();
    expect(_controllerOf(tester).isAnimating, isTrue);

    await tester.pump(
      StatusDot.urgentPulseWindow + const Duration(milliseconds: 50),
    );
    await tester.pump();
    expect(_controllerOf(tester).isAnimating, isFalse);
  });

  testWidgets('a dot removed mid-window leaves no timer behind', (
    tester,
  ) async {
    await tester.pumpWidget(_host(StatusDotVariant.urgent));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    // The binding fails the test itself if a Timer outlives the widget.
  });
}
