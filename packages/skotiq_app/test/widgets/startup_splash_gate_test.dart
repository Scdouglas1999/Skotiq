import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/skotiq_app.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The draw pass at the 96 px splash size is ~1.6 s. Pumping two seconds of
/// frames carries the mark's animation past completion in test time.
const _pastDraw = Duration(seconds: 2);

Widget _harness(
  ProviderContainer container, {
  required bool ready,
  String? statusText,
  bool reduced = false,
  Widget? child,
  int gateKey = 0,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: SkotiqSplashGate(
          key: ValueKey(gateKey),
          ready: ready,
          statusText: statusText,
          child: child ?? const Text('shell'),
        ),
      ),
    ),
  );
}

SkotiqMark _mark(WidgetTester tester) =>
    tester.widget<SkotiqMark>(find.byType(SkotiqMark));

void main() {
  setUp(SkotiqSplashGate.debugResetDrawClock);

  testWidgets('draw mark covers the shell while the app is not ready',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(_harness(container, ready: false));
    await tester.pump();

    expect(_mark(tester).motion, SkotiqMarkMotion.draw);
    // The shell is already in the tree underneath the cover.
    expect(find.text('shell'), findsOneWidget);
  });

  testWidgets('a ready app still waits for the draw to finish before fading',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(_harness(container, ready: true));
    await tester.pump();

    // Ready immediately, but the draw has not completed: the mark keeps
    // drawing and the splash is still up.
    expect(_mark(tester).motion, SkotiqMarkMotion.draw);
    expect(
      container.read(skotiqSplashPhaseProvider),
      SkotiqSplashPhase.drawing,
    );

    await tester.pump(_pastDraw);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(
      container.read(skotiqSplashPhaseProvider),
      SkotiqSplashPhase.done,
    );
    expect(find.byType(SkotiqMark), findsNothing);
    expect(find.text('shell'), findsOneWidget);
  });

  testWidgets('startup slower than the draw switches to loading with status',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      _harness(container, ready: false, statusText: 'Starting the mount…'),
    );
    await tester.pump(_pastDraw);
    await tester.pump();

    expect(_mark(tester).motion, SkotiqMarkMotion.loading);
    expect(find.text('Starting the mount…'), findsOneWidget);
  });

  testWidgets('the status line does not appear while the draw is playing',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      _harness(container, ready: false, statusText: 'Starting the mount…'),
    );
    await tester.pump();

    final text = tester.widget<Opacity>(
      find.ancestor(
        of: find.text('Starting the mount…'),
        matching: find.byType(Opacity),
      ),
    );
    expect(text.opacity, 0);
  });

  testWidgets('reduced motion shows the still mark and lifts promptly',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(_harness(container, ready: true, reduced: true));
    await tester.pump();

    // Reduced motion collapses the draw check instantly, so the mark may
    // already be gone; if it is still up it must be the still mark.
    final marks = find.byType(SkotiqMark);
    if (marks.evaluate().isNotEmpty) {
      expect(_mark(tester).motion, SkotiqMarkMotion.none);
    }

    await tester.pump();
    await tester.pump();
    expect(
      container.read(skotiqSplashPhaseProvider),
      SkotiqSplashPhase.done,
    );
    expect(find.text('shell'), findsOneWidget);
  });

  testWidgets('the cover stops absorbing input as soon as the app is ready',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    var taps = 0;
    await tester.pumpWidget(
      _harness(
        container,
        ready: true,
        child: GestureDetector(
          onTap: () => taps++,
          child: const SizedBox.expand(child: Text('shell')),
        ),
      ),
    );
    await tester.pump();
    // Mid-draw, mid-cover — but the app is ready, so taps reach the shell.
    await tester.tap(find.text('shell'));
    expect(taps, 1);
  });

  testWidgets('a gate mounted after the draw keeps the shared deadline',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(_harness(container, ready: false));
    await tester.pump();
    expect(_mark(tester).motion, SkotiqMarkMotion.draw);

    // Half the draw passes, then the first gate is swapped for a second (the
    // way the mobile app replaces its home). The new gate must not restart
    // the draw; it joins the same deadline in the loading motion.
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpWidget(
      _harness(container, ready: false, statusText: 'Connecting…', gateKey: 1),
    );
    await tester.pump();
    expect(_mark(tester).motion, SkotiqMarkMotion.loading);

    // After the shared deadline plus a fresh readiness the second gate
    // hands off normally.
    await tester.pumpWidget(
      _harness(container, ready: true, gateKey: 2),
    );
    await tester.pump(_pastDraw);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(
      container.read(skotiqSplashPhaseProvider),
      SkotiqSplashPhase.done,
    );
  });
}
