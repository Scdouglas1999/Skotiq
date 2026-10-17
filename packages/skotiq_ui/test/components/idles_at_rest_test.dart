import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Cover for the "the app never idles" class of defect.
///
/// A repeating `AnimationController` re-schedules a frame on every vsync for as
/// long as it runs, whether or not anything it drives is on screen. One of them
/// anywhere in the tree is enough to stop the whole application from ever going
/// idle, which the operator experiences as every screen running at a degraded
/// framerate: a shell-mounted overlay pulsing an icon it only draws during an
/// autofocus run produces ~45 frames a second from launch to quit with a
/// 2%-busy GPU and nothing to draw.
///
/// These tests pin the invariant: the shared animated components in this
/// package come to rest when they are not being drawn.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('skotiq_ui animated components idle when off screen', () {
    testWidgets('ShimmerLoading animates while it is visible', (tester) async {
      await tester.pumpWidget(_host(const ShimmerLoading(child: _Box())));
      await tester.pump();

      expectAnimatingAtRest(tester, 'a visible ShimmerLoading');
    });

    testWidgets('ShimmerLoading stops when it is Offstage', (tester) async {
      await tester.pumpWidget(
        _host(const Offstage(child: ShimmerLoading(child: _Box()))),
      );

      await expectIdlesAtRest(tester, 'an Offstage ShimmerLoading');
    });

    testWidgets('indeterminate SkotiqProgressBar animates while visible', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const SkotiqProgressBar(value: 0, indeterminate: true)),
      );
      await tester.pump();

      expectAnimatingAtRest(
        tester,
        'a visible indeterminate SkotiqProgressBar',
      );
    });

    testWidgets('indeterminate SkotiqProgressBar stops when Offstage', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const Offstage(
            child: SkotiqProgressBar(value: 0, indeterminate: true),
          ),
        ),
      );

      await expectIdlesAtRest(
        tester,
        'an Offstage indeterminate SkotiqProgressBar',
      );
    });

    testWidgets('urgent StatusDot animates while it is visible', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const StatusDot(
            color: Color(0xFFFF0000),
            variant: StatusDotVariant.urgent,
          ),
        ),
      );
      await tester.pump();

      expectAnimatingAtRest(tester, 'a visible urgent StatusDot');
    });

    testWidgets('urgent StatusDot stops in an unselected IndexedStack branch', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const IndexedStack(
            index: 0,
            children: [
              _Box(),
              StatusDot(
                color: Color(0xFFFF0000),
                variant: StatusDotVariant.urgent,
              ),
            ],
          ),
        ),
      );

      await expectIdlesAtRest(
        tester,
        'an urgent StatusDot in an unselected IndexedStack branch',
      );
    });

    testWidgets('a static StatusDot never animates at all', (tester) async {
      await tester.pumpWidget(_host(const StatusDot(color: Color(0xFF00FF00))));

      await expectIdlesAtRest(tester, 'a static StatusDot');
    });

    testWidgets('the animation resumes when the widget comes back on screen', (
      tester,
    ) async {
      Widget build({required bool offstage}) => _host(
        Offstage(
          offstage: offstage,
          child: const SkotiqProgressBar(value: 0, indeterminate: true),
        ),
      );

      await tester.pumpWidget(build(offstage: true));
      await expectIdlesAtRest(
        tester,
        'an Offstage indeterminate SkotiqProgressBar',
      );

      await tester.pumpWidget(build(offstage: false));
      // The frames below must ADVANCE TIME. A zero-duration pump ticks the
      // controller without moving it, so nothing repaints, and the gate — which
      // decides on painting — correctly concludes the bar is still invisible.
      // This test used to pump zero-duration frames and pass anyway, because a
      // freshly built ThemeData put MaterialApp's own AnimatedTheme on screen:
      // the frame counter was reading Material's ticker, not this bar's.
      // One frame to paint, one post-frame callback to resume the controller.
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));

      expectAnimatingAtRest(
        tester,
        'an indeterminate SkotiqProgressBar brought back on screen',
      );

      // …and it is THIS bar that is animating: the indeterminate sweep moves.
      double sweepPosition() =>
          (tester
                      .widget<FractionallySizedBox>(
                        find.byType(FractionallySizedBox),
                      )
                      .alignment
                  as Alignment)
              .x;

      final before = sweepPosition();
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        sweepPosition(),
        isNot(before),
        reason:
            'the indeterminate sweep must actually move once the bar is back '
            'on screen — a running ticker elsewhere in the tree is not proof '
            'that this animation resumed',
      );
    });
  });

  group('OnScreenAnimationGate', () {
    testWidgets('leaves a one-shot animation it did not start alone', (
      tester,
    ) async {
      final controller = AnimationController(
        vsync: tester,
        duration: const Duration(milliseconds: 400),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _host(
          OnScreenAnimationGate(
            controller: controller,
            repeating: false,
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, _) => const _Box(),
            ),
          ),
        ),
      );

      unawaited(controller.forward());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        controller.isAnimating,
        isTrue,
        reason:
            'OnScreenAnimationGate must only ever stop a repeat it started '
            'itself. Stopping a caller-driven forward()/reverse() would break '
            'one-shot animations that share the same controller.',
      );

      // Deliberately still running, which the end-of-test ticker audit would
      // otherwise report as a leak.
      controller.stop();
    });

    testWidgets('does not leave a repeat running after it is unmounted', (
      tester,
    ) async {
      final controller = AnimationController(
        vsync: tester,
        duration: const Duration(milliseconds: 400),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _host(
          OnScreenAnimationGate(
            controller: controller,
            repeating: true,
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, _) => const _Box(),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(controller.isAnimating, isTrue);

      await tester.pumpWidget(_host(const _Box()));

      expect(
        controller.isAnimating,
        isFalse,
        reason:
            'The gate started this repeat, so it must stop it when it goes '
            'away. A repeat left running on a controller nothing is watching '
            'still schedules a frame every vsync and pins the app off idle.',
      );
    });
  });
}

/// Fails unless the tree has genuinely come to rest — nothing is animating and
/// nothing has asked for another frame.
Future<void> expectIdlesAtRest(WidgetTester tester, String what) async {
  const explanation =
      'This means a widget is animating at rest. A running Ticker schedules a '
      'frame on every vsync, so the app never idles and EVERY screen renders '
      'at a degraded framerate — find the running Ticker and gate it on real '
      'state (see OnScreenAnimationGate in skotiq_ui).';

  try {
    // Short simulated timeout: a genuine stuck animation should fail fast
    // rather than pumping for ten simulated minutes.
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 20),
    );
  } on FlutterError {
    fail('$what never stopped scheduling frames. $explanation');
  }

  expect(
    tester.binding.transientCallbackCount,
    0,
    reason:
        '$what left a frame callback registered after settling. '
        '$explanation',
  );
  expect(
    tester.binding.hasScheduledFrame,
    isFalse,
    reason: '$what still has a frame scheduled after settling. $explanation',
  );
}

/// The other half of the invariant: gating must not break the animation for the
/// case it exists to serve.
void expectAnimatingAtRest(WidgetTester tester, String what) {
  expect(
    tester.binding.transientCallbackCount,
    greaterThan(0),
    reason:
        '$what should be animating. Gating an animation on visibility must '
        'not stop it from running when it IS visible.',
  );
}

Widget _host(Widget child) => MaterialApp(
  theme: SkotiqTheme.dark,
  home: Scaffold(
    body: Center(child: SizedBox(width: 200, child: child)),
  ),
);

class _Box extends StatelessWidget {
  const _Box();

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 100,
    height: 20,
    child: ColoredBox(color: Color(0xFF123456)),
  );
}
