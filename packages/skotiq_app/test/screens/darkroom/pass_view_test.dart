import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_controller.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_screen.dart';
import 'package:skotiq_app/screens/darkroom/pass_view/pass_view.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _t0 = 1800000000000;

/// One lane of five subs, the fifth rejected for matching no stars, ending
/// with the master written; [ended] closes the pass.
PassLog _log({bool ended = false}) {
  final e = <PassLogEntry>[];
  void at(num s, String kind, [Map<String, dynamic> d = const {}]) =>
      e.add(PassLogEntry(t: _t0 + (s * 1000).round(), kind: kind, detail: d));
  at(0, PassKinds.passPlanned, {
    'target': 'NGC 891',
    'sessionId': 71,
    'lanes': [
      {'lane': 'L', 'subs': 5, 'exposure': 90},
      {'lane': 'R', 'subs': 5, 'exposure': 120},
    ],
    'finishing': true,
  });
  at(0, PassKinds.runStarted, {
    'lane': 'L',
    'subs': 5,
    'names': ['a', 'b', 'c', 'd', 'e'],
    'exposures': [90, 90, 90, 90, 90],
    'calibration': {'cosmetic': true},
  });
  for (var i = 1; i <= 5; i++) {
    at(i, PassKinds.calibrated, {'index': i});
  }
  at(5, PassKinds.referenceChoosing);
  at(6, PassKinds.referenceChosen, {'index': 1});
  for (var i = 1; i <= 5; i++) {
    final bad = i == 5;
    at(6 + i, PassKinds.registered, {
      'index': i,
      'reference': i == 1,
      'accepted': !bad,
      'reason': bad
          ? 'registration failed: could not establish a consistent geometry: '
              'only 0 correspondences/inliers, need >= 6'
          : null,
      'stars': bad ? null : 900 + i * 10,
      'fwhm': bad ? null : 2.4 + i / 20,
      'eccentricity': bad ? null : 0.4,
      'background': bad ? null : 7000 - i * 100,
      'noise': bad ? null : 120.0,
      'rmsPx': bad ? null : (i == 1 ? 0.0 : 0.5),
      'transform': bad ? null : [1, 0, i * 2.0, 0, 1, i * 1.0, 0, 0, 1],
    });
  }
  at(11, PassKinds.weighted, {
    'weights': [
      for (var i = 1; i <= 4; i++) {'index': i, 'weight': 0.8 + i / 50},
    ],
  });
  for (var i = 1; i <= 4; i++) {
    at(11 + i, PassKinds.normalized, {'index': i});
    at(11 + i, PassKinds.runningPreview, {'subs': i, 'noise': 200 / i});
  }
  at(15, PassKinds.integrating, {'subs': 4});
  at(17, PassKinds.integrated, {'frames': 4, 'noise': 60.0});
  at(18, PassKinds.written, {});
  at(18, PassKinds.laneFinishing, {'lane': 'L'});
  at(20, PassKinds.laneFinished, {'lane': 'L', 'ok': true});
  if (ended) at(21, PassKinds.passEnded, {'ok': true});
  return PassLog(runId: 'post-session-71', entries: e);
}

Future<void> _pump(
  WidgetTester tester,
  PassSnapshot snapshot,
  Size size, {
  ThemeData? theme,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: theme ?? SkotiqTheme.dark,
    home: Scaffold(body: PassView(snapshot: snapshot, onStop: () {})),
  ));
}

void main() {
  final timeline = PassTimeline.fromLog(_log());

  for (final size in const [Size(1536, 864), Size(1000, 760), Size(360, 900)]) {
    testWidgets('lays out without overflow at ${size.width.toInt()} px', (
      tester,
    ) async {
      await _pump(tester,
          timeline.at(const Duration(seconds: 13, milliseconds: 500)), size);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Normalizing L'), findsOneWidget);
    });
  }

  testWidgets('a rejected sub states the whole reason, never cut short', (
    tester,
  ) async {
    await _pump(tester, timeline.at(const Duration(seconds: 13)),
        const Size(360, 1200));
    expect(
      find.textContaining(
          'no stars matched the reference (0 matched, 6 needed)'),
      findsWidgets,
    );
    final reason = tester.widget<Text>(find.byWidgetPredicate(
      (w) =>
          w is Text &&
          (w.textSpan?.toPlainText() ?? '').startsWith('Sub 5 rejected'),
    ));
    expect(reason.maxLines, isNull);
    expect(reason.overflow, isNot(TextOverflow.ellipsis));
  });

  testWidgets(
      'while running, the stages no pass has timed leave remaining '
      'as a lower bound', (tester) async {
    await _pump(tester, timeline.at(const Duration(seconds: 13)),
        const Size(1536, 864));
    expect(find.text('Remaining, at least'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
  });

  testWidgets('a finished pass reads as its record, with no Stop',
      (tester) async {
    final record = PassTimeline.fromLog(_log(ended: true));
    await _pump(
      tester,
      record.snapshot(now: DateTime.now()),
      const Size(1536, 864),
      theme: SkotiqTheme.light,
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Pass record'), findsOneWidget);
    expect(find.text('The pass finished'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);
    expect(find.text('Started'), findsOneWidget);
  });

  testWidgets('the Darkroom route opens a pass by its run id', (tester) async {
    tester.view.physicalSize = const Size(1536, 864);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        isRemoteClientProvider.overrideWithValue(false),
        darkroomPassTimelineProvider('post-session-71').overrideWith(
          (ref) => Stream<PassTimeline?>.value(
              PassTimeline.fromLog(_log(ended: true))),
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home:
            const DarkroomScreen(scope: DarkroomScope.pass('post-session-71')),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Pass record'), findsOneWidget);
    expect(find.textContaining('NGC 891'), findsWidgets);
  });
}
