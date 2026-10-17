// Three things the polar alignment wizard has to get right for someone
// standing at the mount:
//
//  * the completion headline speaks in arcminutes, not "1800.0 arcseconds";
//  * the settings column SAYS it is locked while a run holds it, instead of
//    silently swallowing every click;
//  * pressing Done and coming back opens the wizard, not last night's green
//    "Alignment Complete" screen.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/polar_alignment/polar_alignment_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

/// Drives the screen from a fixed alignment state without a backend round-trip.
class _FixedAlignmentNotifier extends PolarAlignmentStateNotifier {
  _FixedAlignmentNotifier(super.ref, PolarAlignmentState fixed) {
    // ignore: invalid_use_of_protected_member
    state = fixed;
  }
}

PolarAlignmentError _error(double total) => PolarAlignmentError(
      azimuthError: total,
      altitudeError: 0,
      totalError: total,
      currentRa: 0,
      currentDec: 89,
      targetRa: 0,
      targetDec: 90,
      timestamp: DateTime(2026, 8, 2, 10, 30),
    );

PolarAlignmentError _errorAt(double total, DateTime at) => PolarAlignmentError(
      azimuthError: total,
      altitudeError: 0,
      totalError: total,
      currentRa: 0,
      currentDec: 89,
      targetRa: 0,
      targetDec: 90,
      timestamp: at,
    );

const _config = PolarAlignmentConfig(autoCompleteThreshold: 30.0);

/// The live router, so the test can leave the wizard the way the operator does
/// (a pop) without depending on hit-testing a footer button that the contextual
/// tour nudge may overlay.
GoRouter? _activeRouter;

GoRouter _router() => GoRouter(
      initialLocation: '/imaging',
      routes: [
        GoRoute(
          path: '/imaging',
          builder: (context, __) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => context.push('/polar-alignment'),
                child: const Text('open wizard'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/polar-alignment',
          builder: (_, __) => const PolarAlignmentScreen(),
        ),
      ],
    );

Future<HarnessHandle> _pump(
  WidgetTester tester, {
  PolarAlignmentState? alignmentState,
  Size size = const Size(1400, 900),
}) async {
  final router = _router();
  _activeRouter = router;
  addTearDown(() => _activeRouter = null);
  final handle = await pumpAppScreen(
    tester,
    MaterialApp.router(
      theme: SkotiqTheme.dark,
      routerConfig: router,
    ),
    size: size,
    settle: false,
    extraOverrides: [
      if (alignmentState != null)
        polarAlignmentStateProvider.overrideWith(
          (ref) => _FixedAlignmentNotifier(ref, alignmentState),
        ),
    ],
  );
  await tester.pump(const Duration(milliseconds: 200));
  return handle;
}

Future<void> _openWizard(WidgetTester tester) async {
  // The push future completes when the route is POPPED, so it is deliberately
  // not awaited here.
  unawaited(_activeRouter!.push('/polar-alignment'));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('a run that reached its target reads in arcminutes',
      (tester) async {
    await _pump(
      tester,
      alignmentState: PolarAlignmentState(
        phase: PolarAlignPhase.complete,
        // A generous threshold so the panel takes its "Final error" branch.
        config: const PolarAlignmentConfig(autoCompleteThreshold: 3600),
        startedAt: DateTime(2026, 8, 2, 10),
        initialError: _error(7200),
        currentError: _error(1800),
      ),
    );
    await _openWizard(tester);

    expect(find.text('Final error: 1800.0 arcseconds'), findsNothing);
    expect(find.text("Final error: 30' 00\""), findsOneWidget);
  });

  testWidgets('a run that missed its target reads in arcminutes too',
      (tester) async {
    await _pump(
      tester,
      alignmentState: PolarAlignmentState(
        phase: PolarAlignPhase.complete,
        config: _config,
        startedAt: DateTime(2026, 8, 2, 10),
        initialError: _error(3600),
        currentError: _error(1800),
      ),
    );
    await _openWizard(tester);

    expect(find.textContaining('Still 1800.0"'), findsNothing);
    expect(find.textContaining("Still 30' 00\""), findsOneWidget);
  });

  testWidgets('the configuration column says why it is locked mid-run',
      (tester) async {
    await _pump(
      tester,
      alignmentState: PolarAlignmentState(
        phase: PolarAlignPhase.adjusting,
        config: _config,
        startedAt: DateTime(2026, 8, 2, 10),
        initialError: _error(300),
        currentError: _error(120),
      ),
    );
    await _openWizard(tester);

    expect(
      find.textContaining('Settings are locked while aligning'),
      findsOneWidget,
      reason: 'the refused clicks must have a stated reason on screen',
    );
  });

  testWidgets('an idle wizard does not claim its settings are locked',
      (tester) async {
    await _pump(tester);
    await _openWizard(tester);

    expect(find.textContaining('Settings are locked while aligning'),
        findsNothing);
  });

  testWidgets('History scrolls its panel into view', (tester) async {
    // The audit's own conditions: a short viewport with Common and Advanced
    // expanded, so the panel — appended below all three groups — genuinely
    // starts past the bottom of the configuration column.
    await _pump(tester, size: const Size(1400, 560));
    await _openWizard(tester);
    for (final section in const ['Common', 'Advanced']) {
      await tester.tap(find.text(section));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    expect(find.text('Alignment history'), findsNothing);

    await tester.tap(find.widgetWithText(SkotiqButton, 'History'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final panel = find.text('Alignment history');
    expect(panel, findsOneWidget);
    // Visible, not merely built: the defect was a header toggle whose only
    // effect was below the fold.
    final rect = tester.getRect(panel);
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(
      rect.top >= 0 && rect.bottom <= screen.height,
      isTrue,
      reason: 'History must land inside the viewport, not below the fold '
          '(panel at $rect, viewport height ${screen.height})',
    );
  });

  testWidgets('All-Sky states how long its drift baseline has run',
      (tester) async {
    final first = DateTime(2026, 8, 2, 22, 10, 0);
    final handle = await _pump(
      tester,
      alignmentState: PolarAlignmentState(
        phase: PolarAlignPhase.adjusting,
        config: _config,
        startedAt: DateTime(2026, 8, 2, 22, 9),
        initialError: _errorAt(90, first),
        currentError: _errorAt(90, first.add(const Duration(seconds: 252))),
      ),
    );
    // The drift baseline belongs to All-Sky, whose error is derived from that
    // interval. Set the mode through the provider: the header's mode selector
    // is (correctly) disabled while a run is in flight.
    await handle.container
        .read(polarAlignmentUiStateProvider.notifier)
        .setMode(PolarAlignmentMode.allSky);
    await _openWizard(tester);

    // A FLOOR, not a measurement: the true interval starts at the baseline
    // frame, which the wire does not timestamp, so the app can only see back to
    // the first drift solve.
    expect(find.text('Drift baseline: at least 4m 12s'), findsOneWidget);
  });

  testWidgets('the first All-Sky drift solve is not called a 0s baseline',
      (tester) async {
    // initialError and currentError are the SAME event here — that is exactly
    // what the notifier stores on the first error of the adjustment phase. The
    // reading is still derived over one cadence + exposure + solve since the
    // baseline frame, so "0s" would be a fresh untruth.
    final only = _errorAt(90, DateTime(2026, 8, 2, 22, 10, 0));
    final handle = await _pump(
      tester,
      alignmentState: PolarAlignmentState(
        phase: PolarAlignPhase.adjusting,
        config: _config,
        startedAt: DateTime(2026, 8, 2, 22, 9),
        initialError: only,
        currentError: only,
      ),
    );
    await handle.container
        .read(polarAlignmentUiStateProvider.notifier)
        .setMode(PolarAlignmentMode.allSky);
    await _openWizard(tester);

    expect(find.text('Drift baseline: 0s'), findsNothing);
    expect(find.text('Drift baseline: first drift solve'), findsOneWidget);
  });

  testWidgets('leaving a finished run reopens the wizard on idle',
      (tester) async {
    final handle = await _pump(
      tester,
      alignmentState: PolarAlignmentState(
        phase: PolarAlignPhase.complete,
        config: _config,
        startedAt: DateTime(2026, 8, 2, 10),
        initialError: _error(3600),
        currentError: _error(1800),
      ),
    );
    await _openWizard(tester);
    expect(find.text('Alignment stopped'), findsOneWidget);

    // Done pops back to Imaging.
    _activeRouter!.pop();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(
      handle.container.read(polarAlignmentStateProvider).phase,
      PolarAlignPhase.idle,
      reason: 'the finished run belongs in History, not on the entry screen',
    );

    await _openWizard(tester);
    expect(find.text('Alignment stopped'), findsNothing);
    expect(find.text('Alignment complete'), findsNothing);
  });
}
