// The frame stage: empty states, the frame pill, the activity pill and the
// strip selection, against the boards.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/center/frame_stage.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_header_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_run_phase_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../fixtures/night_fixtures.dart';
import 'center_test_support.dart';

void main() {
  group('exposure', exposureTests);

  testWidgets('before a run with no frame it says nothing is captured yet',
      (tester) async {
    await pumpCenter(
      tester,
      centerOverrides(NightFixtures.ready()),
      child: const FrameStage(),
    );
    expect(find.text('Nothing captured yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('during a run with no frame it waits for the first one',
      (tester) async {
    await pumpCenter(
      tester,
      centerOverrides(NightFixtures.running(), frames: const []),
      child: const FrameStage(),
    );
    expect(find.text('Waiting for the first frame'), findsOneWidget);
    expect(find.text('Nothing captured yet'), findsNothing);
  });

  testWidgets('a saved frame shows its number, filter, time and verdict',
      (tester) async {
    final board = NightFixtures.running();
    await pumpCenter(
      tester,
      centerOverrides(
        board,
        frames: stripWithPaths(board.frames),
        image: testFrame(),
        exposure: const NightExposureVm(elapsed: 72, total: 180),
      ),
      child: const FrameStage(),
    );
    expect(find.text('Nothing captured yet'), findsNothing);
    expect(find.textContaining('#43 · Ha 180 s'), findsOneWidget);
    expect(find.textContaining('23:49:12'), findsOneWidget);
    expect(find.textContaining('Accepted'), findsOneWidget);
    // The next frame of the run is exposing.
    expect(find.textContaining('#44 exposing'), findsOneWidget);
    expect(find.textContaining('72 / 180 s'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'^Latest frame: #43 · Ha 180 s')),
      findsOneWidget,
    );
  });

  testWidgets('a run exposure counts up from its start', (tester) async {
    final board = NightFixtures.running();
    await pumpCenter(
      tester,
      centerOverrides(
        board,
        frames: stripWithPaths(board.frames),
        image: testFrame(),
        exposure: NightExposureVm(
          startedAt: DateTime.now().toUtc().subtract(
                const Duration(seconds: 60, milliseconds: 300),
              ),
          total: 180,
        ),
      ),
      child: const FrameStage(),
    );
    expect(find.textContaining('#44 exposing'), findsOneWidget);
    expect(find.textContaining('60 / 180 s'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a rejected frame says so', (tester) async {
    final board = NightFixtures.running();
    final frames = stripWithPaths(board.frames);
    await pumpCenter(
      tester,
      centerOverrides(
        board,
        frames: frames,
        // #37 is the rejected frame on the board.
        image: testFrame(filePath: frames[5].filePath),
      ),
      child: const FrameStage(),
    );
    expect(find.textContaining('#37 · Ha 180 s'), findsOneWidget);
    expect(find.textContaining('Rejected'), findsOneWidget);
  });

  testWidgets('a running autofocus shows its point', (tester) async {
    final board = NightFixtures.autofocus();
    await pumpCenter(
      tester,
      centerOverrides(
        board,
        image: testFrame(filePath: '/tmp/af.fits', exposure: 3),
        autofocus: const NightAutofocusVm(point: 6, points: 9, hfr: 2.08),
      ),
      child: const FrameStage(),
    );
    expect(find.textContaining('Autofocus · point 6 of 9'), findsOneWidget);
    expect(find.textContaining('HFR 2.08'), findsOneWidget);
    expect(find.textContaining('exposing'), findsNothing);
  });

  testWidgets('the action pausing the run shows its message', (tester) async {
    final board = NightFixtures.running();
    await pumpCenter(
      tester,
      centerOverrides(
        board,
        image: testFrame(),
        exposure: const NightExposureVm(elapsed: 72, total: 180),
        actionState: const ManualActionState(
          phase: ManualActionPhase.pausingRun,
          active: ManualActionId.autofocus,
          message: NightText(
            'nightActPausingAfter',
            params: <String, String>{'frame': '44', 'seconds': '108'},
          ),
        ),
      ),
      child: const FrameStage(),
    );
    expect(find.textContaining('Pausing after #44 · 108 s'), findsOneWidget);
    expect(find.textContaining('#44 exposing'), findsNothing);
  });

  testWidgets('a snapshot before the run is marked not saved, with its solve',
      (tester) async {
    final image = testFrame(
      filePath: '/captures/liveview_ZWO_ASI1600MM.fits',
      filter: 'L',
      exposure: 5,
    );
    await pumpCenter(
      tester,
      centerOverrides(
        NightFixtures.ready(),
        image: image,
        solve: NightStageSolveVm(
          frameCapturedAt: image.capturedAt,
          raDegrees: (1 + 36 / 60 + 40 / 3600) * 15,
          decDegrees: 15 + 46 / 60 + 52 / 3600,
          rotationDeg: 0.4,
          pixelScaleArcsec: 1.2,
          offTargetArcmin: 0.4,
        ),
      ),
      child: const FrameStage(),
    );
    expect(find.textContaining('Snapshot · L 5 s'), findsOneWidget);
    expect(find.textContaining('not saved'), findsOneWidget);
    expect(find.textContaining('Solved 01h36m40s'), findsOneWidget);
    expect(find.textContaining('0.4′ off'), findsOneWidget);
  });

  testWidgets('view buttons sit over a frame and toggle the shared viewer',
      (tester) async {
    final container = await pumpCenter(
      tester,
      centerOverrides(NightFixtures.running(), image: testFrame()),
      child: const FrameStage(),
    );
    for (final label in <String>['Stretch', 'Stars', 'Annotate', 'Zoom 1:1']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('Stars'));
    await tester.pump();
    expect(
      container.read(imagingViewerStateProvider).showStarOverlay,
      isTrue,
    );
  });

  testWidgets('a frame picked in the strip replaces the live frame',
      (tester) async {
    final board = NightFixtures.running();
    final container = await pumpCenter(
      tester,
      centerOverrides(board, image: testFrame()),
      child: const FrameStage(),
    );
    container.read(nightStageSelectionProvider.notifier).state =
        board.frames[5].id;
    await tester.pump();
    expect(
        find.bySemanticsLabel(RegExp('Preview of frame #37')), findsOneWidget);
    expect(find.textContaining('Rejected'), findsOneWidget);
    await tester.tap(find.text('Back to latest'));
    await tester.pump();
    expect(container.read(nightStageSelectionProvider), isNull);
  });
}

void exposureTests() {
  test('a reported exposure reads as reported; a run exposure counts up', () {
    final now = DateTime.utc(2026, 10, 18, 4, 52);
    const manual = NightExposureVm(elapsed: 72, total: 180);
    expect(manual.elapsedAt(now), 72);
    expect(manual.fractionAt(now), 0.4);

    final run = NightExposureVm(
      startedAt: now.subtract(const Duration(seconds: 60)),
      total: 180,
    );
    expect(run.elapsedAt(now), 60);
    expect(run.fractionAt(now), closeTo(1 / 3, 1e-9));
    // Past its length it holds at the length rather than overrunning.
    expect(run.elapsedAt(now.add(const Duration(minutes: 5))), 180);

    final unknownLength = NightExposureVm(startedAt: now);
    expect(unknownLength.fractionAt(now), isNull);
  });

  test('the run exposing reads the camera, not the stale manual progress', () {
    final container = ProviderContainer(
      overrides: <Override>[
        nightRunPhaseProvider.overrideWithValue(NightRunPhase.running),
        nightHeaderProvider.overrideWithValue(
          NightFixtures.header(NightRunPhase.running),
        ),
        clockProvider.overrideWithValue(const SystemClock()),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(nightStageExposureProvider, (_, __) {});
    addTearDown(sub.close);
    expect(container.read(nightStageExposureProvider), isNull);

    // The last manual frame left its progress behind; the run now exposes.
    container.read(exposureProgressProvider.notifier)
      ..startExposure(5, 1, 1)
      ..startDownload();
    container.read(cameraStateProvider.notifier).setExposing(true);
    final exposure = container.read(nightStageExposureProvider);
    expect(exposure, isNotNull);
    expect(exposure!.elapsed, isNull);
    expect(exposure.startedAt, isNotNull);
    expect(exposure.total, 180);

    container.read(cameraStateProvider.notifier).setExposing(false);
    expect(container.read(nightStageExposureProvider), isNull);
  });
}
