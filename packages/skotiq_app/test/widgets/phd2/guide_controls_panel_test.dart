// Widget tests for GuideControlsPanel — the shared desktop/mobile guiding
// controls. Covers the trust-hardening contract:
//   * paused / lost-lock / calibrating / settling / unknown NEVER show an
//     enabled Start; they show Stop,
//   * Stop is reachable from paused and other live states,
//   * a double-tap issues a single command (local busy lane),
//   * an async command failure surfaces inline instead of escaping.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/phd2/guide_controls_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _pumpPanel(
  WidgetTester tester, {
  required Phd2GuidingState state,
  bool isConnected = true,
  Future<void> Function()? onStartGuiding,
  Future<void> Function()? onStopGuiding,
  Future<void> Function()? onPauseGuiding,
  Future<void> Function()? onResumeGuiding,
  Future<void> Function()? onDither,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(420, 900);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: SizedBox(
          width: 360,
          height: 820,
          child: GuideControlsPanel(
            state: state,
            isConnected: isConnected,
            onStartGuiding: onStartGuiding,
            onStopGuiding: onStopGuiding,
            onPauseGuiding: onPauseGuiding,
            onResumeGuiding: onResumeGuiding,
            onDither: onDither,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('truthful primary control', () {
    testWidgets('Stopped shows an enabled Start', (tester) async {
      await _pumpPanel(tester, state: Phd2GuidingState.stopped);
      expect(find.text('Start'), findsOneWidget);
      expect(find.text('Stop'), findsNothing);
    });

    for (final state in const [
      Phd2GuidingState.paused,
      Phd2GuidingState.lostLock,
      Phd2GuidingState.calibrating,
      Phd2GuidingState.settling,
      Phd2GuidingState.looping,
      Phd2GuidingState.unknown,
    ]) {
      testWidgets('$state shows Stop and never Start', (tester) async {
        await _pumpPanel(tester, state: state);
        expect(find.text('Stop'), findsOneWidget, reason: '$state needs Stop');
        expect(find.text('Start'), findsNothing,
            reason: '$state must not offer Start');
      });
    }

    testWidgets('paused offers a Resume affordance', (tester) async {
      await _pumpPanel(tester, state: Phd2GuidingState.paused);
      expect(find.text('Resume'), findsOneWidget);
    });
  });

  group('command dispatch', () {
    testWidgets('Stop is dispatchable from paused', (tester) async {
      var stops = 0;
      await _pumpPanel(
        tester,
        state: Phd2GuidingState.paused,
        onStopGuiding: () async => stops++,
      );
      await tester.tap(find.text('Stop'));
      await tester.pump();
      expect(stops, 1);
    });

    testWidgets('a double-tap issues exactly one command', (tester) async {
      var starts = 0;
      final gate = Completer<void>();
      await _pumpPanel(
        tester,
        state: Phd2GuidingState.stopped,
        onStartGuiding: () {
          starts++;
          return gate.future;
        },
      );
      await tester.tap(find.text('Start'));
      await tester.pump();
      // Second tap while the first is still in flight must be swallowed.
      await tester.tap(find.text('Start'));
      await tester.pump();
      expect(starts, 1);

      gate.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('a disconnected Start is disabled (no command issued)',
        (tester) async {
      var starts = 0;
      await _pumpPanel(
        tester,
        state: Phd2GuidingState.disconnected,
        isConnected: false,
        onStartGuiding: () async => starts++,
      );
      expect(find.text('Start'), findsOneWidget);
      await tester.tap(find.text('Start'));
      await tester.pump();
      expect(starts, 0);
    });

    testWidgets('an async command failure surfaces inline', (tester) async {
      await _pumpPanel(
        tester,
        state: Phd2GuidingState.guiding,
        onStopGuiding: () async => throw StateError('driver said no'),
      );
      await tester.tap(find.text('Stop'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('driver said no'), findsOneWidget);
    });
  });
}
