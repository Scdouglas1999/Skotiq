// The Tonight header: which controls each run phase shows, why a disabled
// one is disabled, what each control calls, and that it lays out without
// overflow at the owner's widths and at 1.3x text.
import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/header/night_header_bar.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/night_control_layout.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../fixtures/night_fixtures.dart';
import '../left/night_widget_test_support.dart';

Future<NightHarness> _pumpHeader(
  WidgetTester tester,
  NightRunPhase phase, {
  ManualActionId? pausedFor,
  double width = 1316,
  double textScale = 1,
  NightControlMode mode = NightControlMode.threeColumn,
  VoidCallback? openPlanDrawer,
  NightHeaderVm? header,
}) async {
  final board = switch (phase) {
    NightRunPhase.running ||
    NightRunPhase.pausedByUser ||
    NightRunPhase.pausedForAction ||
    NightRunPhase.stopping =>
      NightFixtures.running(),
    _ => NightFixtures.ready(),
  };
  final harness = NightHarness(
    board: board,
    header: header ?? headerFor(phase, pausedFor: pausedFor),
  );
  await harness.pump(
    tester,
    SizedBox(
      width: width,
      child: densityFor(
        mode,
        openPlanDrawer: openPlanDrawer,
        child: const NightHeaderBar(),
      ),
    ),
    size: Size(width, 400),
    textScale: textScale,
  );
  return harness;
}

Finder _button(String label) => find.widgetWithText(SkotiqButton, label);

void _expectButtons(List<String> shown, List<String> absent) {
  for (final label in shown) {
    expect(_button(label), findsOneWidget, reason: '$label should show');
  }
  for (final label in absent) {
    expect(_button(label), findsNothing, reason: '$label should not show');
  }
}

bool _enabled(WidgetTester tester, String label) =>
    tester.widget<SkotiqButton>(_button(label)).onPressed != null;

const _runControls = <String>['Pause', 'Resume', 'Skip step', 'Stop'];
const _readyControls = <String>['Edit plan', 'Start at dark', 'Start now'];

void main() {
  group('controls by run phase', () {
    testWidgets('ready: Edit plan, Start at dark, Start now', (tester) async {
      await _pumpHeader(tester, NightRunPhase.ready);
      _expectButtons(_readyControls, _runControls);
      expect(_enabled(tester, 'Start now'), isTrue);
      expect(find.textContaining('Ready · not started'), findsOneWidget);
      expect(
        find.textContaining('2 targets · 12 steps · ≈7 h planned'),
        findsOneWidget,
      );
      expect(find.textContaining('dark in 1 h 12 m'), findsOneWidget);
    });

    testWidgets('a restored run says it waits for Start', (tester) async {
      final base = headerFor(NightRunPhase.ready);
      await _pumpHeader(
        tester,
        NightRunPhase.ready,
        header: NightHeaderVm(
          phase: base.phase,
          planName: base.planName,
          targetCount: base.targetCount,
          stepCount: base.stepCount,
          restoredFrames: 37,
          startNow: base.startNow,
          startAtDark: base.startAtDark,
        ),
      );
      expect(
        find.textContaining(
          'restored at 37 frames, nothing moves until you press Start',
        ),
        findsOneWidget,
      );
      expect(_enabled(tester, 'Start now'), isTrue);
    });

    testWidgets('armed: the start time with Cancel and the keep-open note',
        (tester) async {
      final harness = await _pumpHeader(tester, NightRunPhase.armed);
      _expectButtons(<String>[
        'Edit plan',
        'Start now',
        'Cancel'
      ], <String>[
        'Start at dark',
        ..._runControls,
      ]);
      expect(find.text('Starts at 19:48'), findsOneWidget);
      expect(find.textContaining('must stay open'), findsOneWidget);
      await tester.tap(_button('Cancel'));
      await tester.pump();
      expect(harness.api.calls, <String>['cancelArmed']);
    });

    testWidgets('running: Pause, Skip step, Stop and the ticking duration',
        (tester) async {
      await _pumpHeader(tester, NightRunPhase.running);
      _expectButtons(<String>[
        'Pause',
        'Skip step',
        'Stop'
      ], <String>[
        'Resume',
        ..._readyControls,
      ]);
      // Started 19:48, now 23:52.
      expect(find.textContaining('Running 4 h 04 m'), findsOneWidget);
      expect(
        find.textContaining('target 1 of 2 · step 7 of 12 · Ha 180 s · 44/60'),
        findsOneWidget,
      );
    });

    testWidgets('paused by the user: Resume', (tester) async {
      await _pumpHeader(tester, NightRunPhase.pausedByUser);
      _expectButtons(<String>[
        'Resume',
        'Skip step',
        'Stop'
      ], <String>[
        'Pause',
        ..._readyControls,
      ]);
      expect(_enabled(tester, 'Resume'), isTrue);
      expect(find.textContaining('Paused'), findsOneWidget);
    });

    testWidgets('paused for autofocus: Resume and Skip are the action\'s',
        (tester) async {
      await _pumpHeader(
        tester,
        NightRunPhase.pausedForAction,
        pausedFor: ManualActionId.autofocus,
      );
      _expectButtons(<String>['Resume', 'Skip step', 'Stop'], _readyControls);
      expect(find.textContaining('Paused for autofocus'), findsOneWidget);
      expect(_enabled(tester, 'Resume'), isFalse);
      expect(_enabled(tester, 'Skip step'), isFalse);
      final stop = tester.widget<HoldToConfirmButton>(
        find.byType(HoldToConfirmButton),
      );
      expect(stop.enabled, isTrue);
    });

    testWidgets('stopping: Pause and Skip disabled, Stop offered again',
        (tester) async {
      await _pumpHeader(tester, NightRunPhase.stopping);
      _expectButtons(<String>['Pause', 'Skip step', 'Stop'], _readyControls);
      expect(_enabled(tester, 'Pause'), isFalse);
      expect(_enabled(tester, 'Skip step'), isFalse);
      expect(find.textContaining('Stopping'), findsOneWidget);
    });

    testWidgets('finished: the ready controls again', (tester) async {
      await _pumpHeader(tester, NightRunPhase.finished);
      _expectButtons(_readyControls, _runControls);
      expect(find.textContaining('Finished'), findsOneWidget);
    });

    testWidgets('not set up: Start disabled, no plan named', (tester) async {
      await _pumpHeader(tester, NightRunPhase.notSetUp);
      _expectButtons(_readyControls, _runControls);
      expect(_enabled(tester, 'Start now'), isFalse);
      expect(_enabled(tester, 'Start at dark'), isFalse);
      expect(_enabled(tester, 'Edit plan'), isTrue);
      expect(find.textContaining('No plan loaded'), findsOneWidget);
    });
  });

  group('disabled reasons', () {
    testWidgets('a disabled control carries its reason in semantics',
        (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpHeader(
        tester,
        NightRunPhase.pausedForAction,
        pausedFor: ManualActionId.autofocus,
      );
      final resume = tester.getSemantics(_button('Resume'));
      // SkotiqButton merges its own Text into its label ("Resume\nResume"),
      // a kit behavior every button shares.
      expect(resume.label, startsWith('Resume'));
      expect(
        resume.hint,
        'The run resumes on its own when the manual action finishes',
      );
      expect(resume.flagsCollection.isEnabled, Tristate.isFalse);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is SkotiqTooltip &&
              w.message == 'Wait for the manual action to finish',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('a disabled Stop says why too', (tester) async {
      final handle = tester.ensureSemantics();
      final base = headerFor(NightRunPhase.stopping);
      await _pumpHeader(
        tester,
        NightRunPhase.stopping,
        header: NightHeaderVm(
          phase: base.phase,
          planName: base.planName,
          pauseResume: base.pauseResume,
          skipStep: base.skipStep,
          stop: const NightControlVm.disabled(NightText('ncPlanFinalizing')),
        ),
      );
      final node = tester.getSemantics(find.byType(HoldToConfirmButton));
      expect(node.hint, 'The run has stopped and is saving its results');
      expect(node.label, contains('Press and hold'));
      handle.dispose();
    });

    testWidgets('the run pill is a live region that names the state only',
        (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpHeader(tester, NightRunPhase.running);
      expect(
        find.bySemanticsLabel('Running'),
        findsOneWidget,
      );
      final node = tester.getSemantics(find.bySemanticsLabel('Running'));
      expect(node.flagsCollection.isLiveRegion, isTrue);
      handle.dispose();
    });
  });

  group('wiring', () {
    testWidgets('Pause and Skip go to the sequence service', (tester) async {
      final harness = await _pumpHeader(tester, NightRunPhase.running);
      await tester.tap(_button('Pause'));
      await tester.tap(_button('Skip step'));
      await tester.pump();
      expect(harness.actions!.calls, <String>['pause', 'skip']);
    });

    testWidgets('Resume goes to the sequence service', (tester) async {
      final harness = await _pumpHeader(tester, NightRunPhase.pausedByUser);
      await tester.tap(_button('Resume'));
      await tester.pump();
      expect(harness.actions!.calls, <String>['resume']);
    });

    testWidgets(
        'a tap on Stop does nothing; a hold stops, keeping the '
        'checkpoint', (tester) async {
      final harness = await _pumpHeader(tester, NightRunPhase.running);
      await tester.tap(find.byType(HoldToConfirmButton));
      await tester.pump(const Duration(seconds: 2));
      expect(harness.actions?.calls ?? const <String>[], isEmpty);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(HoldToConfirmButton)),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 1600));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(harness.actions!.calls, <String>['stop']);
      expect(harness.actions!.stopPreservedCheckpoint, isTrue);
    });

    testWidgets('Edit plan opens the Sequencer', (tester) async {
      final harness = await _pumpHeader(tester, NightRunPhase.ready);
      await tester.tap(_button('Edit plan'));
      await tester.pumpAndSettle();
      expect(
        harness.router.routerDelegate.currentConfiguration.uri.path,
        '/sequencer',
      );
    });

    testWidgets('Plan shows only when the layout has a drawer to open',
        (tester) async {
      var opened = 0;
      await _pumpHeader(
        tester,
        NightRunPhase.running,
        width: 1000,
        mode: NightControlMode.planDrawer,
        openPlanDrawer: () => opened++,
      );
      await tester.tap(_button('Plan'));
      expect(opened, 1);
    });

    testWidgets('no Plan button in three columns', (tester) async {
      await _pumpHeader(tester, NightRunPhase.running);
      expect(_button('Plan'), findsNothing);
    });
  });

  group('layout', () {
    const phases = <NightRunPhase>[
      NightRunPhase.ready,
      NightRunPhase.armed,
      NightRunPhase.running,
      NightRunPhase.pausedForAction,
      NightRunPhase.stopping,
    ];
    for (final (width, mode) in const <(double, NightControlMode)>[
      (1316, NightControlMode.threeColumn),
      (1000, NightControlMode.planDrawer),
      (744, NightControlMode.singleColumn),
      (390, NightControlMode.singleColumn),
    ]) {
      for (final scale in const <double>[1, 1.3]) {
        testWidgets('no overflow at $width px, ${scale}x text', (tester) async {
          for (final phase in phases) {
            await _pumpHeader(
              tester,
              phase,
              pausedFor: phase == NightRunPhase.pausedForAction
                  ? ManualActionId.autofocus
                  : null,
              width: width,
              textScale: scale,
              mode: mode,
              openPlanDrawer:
                  mode == NightControlMode.planDrawer ? () {} : null,
            );
            expect(tester.takeException(), isNull, reason: '$phase');
            expect(find.byType(NightTimelineStrip), findsOneWidget);
          }
        });
      }
    }

    testWidgets('one row at 1316 holds the strip at 360 px', (tester) async {
      await _pumpHeader(tester, NightRunPhase.running);
      expect(
        tester.getSize(find.byType(NightTimelineStrip)).width,
        NightHeaderBar.timelineWidth,
      );
      // The strip sits on the controls' row.
      expect(
        tester.getCenter(find.byType(NightTimelineStrip)).dy,
        closeTo(tester.getCenter(_button('Pause')).dy, 12),
      );
    });

    testWidgets('the strip takes its own row in one column', (tester) async {
      await _pumpHeader(
        tester,
        NightRunPhase.running,
        width: 744,
        mode: NightControlMode.singleColumn,
      );
      expect(
        tester.getTopLeft(find.byType(NightTimelineStrip)).dy,
        greaterThan(tester.getBottomLeft(_button('Pause')).dy),
      );
    });

    testWidgets('the strip names the night in one sentence', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpHeader(tester, NightRunPhase.running);
      expect(
        find.bySemanticsLabel(
          'Night from sunset 18:18 to sunrise 07:14, now 23:52; '
          'M74 until ≈03:40, then NGC 891 until ≈05:30',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  });
}
