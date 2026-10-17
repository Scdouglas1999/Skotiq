// The `Frames` readout in Star statistics sits directly beside an SNR and a
// Star mass that update on every loop frame, so all three read as describing the
// same frames. `frameCount` counts guide STEPS and looping takes no corrections,
// so reporting it during a Loop Exposures run prints `0` under two live rows.
//
// While looping the row reports the loop's own frames, counting again from one
// for each new loop. The counting and per-loop reset are pinned at the provider
// in skotiq_core's guide_loop_frame_count_test.dart; this pins which number
// the screen puts on that row.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/guiding/guiding_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _TutorialsDisabledNotifier extends TutorialNotifier {
  _TutorialsDisabledNotifier() : super(_NoopTutorialProgressDao()) {
    // ignore: invalid_use_of_protected_member
    state = const TutorialProgress(tutorialsEnabled: false);
  }
}

class _NoopTutorialProgressDao implements TutorialProgressDao {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'NoopTutorialProgressDao.${invocation.memberName} called in test',
      );
}

class _GuiderConnected extends GuiderStateNotifier {
  _GuiderConnected(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const GuiderState(
      connectionState: DeviceConnectionState.connected,
      deviceId: builtinGuiderDeviceId,
      deviceName: 'Built-in Guider',
    );
  }
}

/// Twelve frames into a loop, and no guide step taken — the state the running
/// build showed as `Frame Count 0`.
class _LoopingStats extends GuideStatsNotifier {
  _LoopingStats(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const Phd2GuideStats(
      snr: 445.4,
      starMass: 206760,
      frameCount: 0,
      loopFrameCount: 12,
    );
  }
}

/// Guiding after that loop: 37 guide steps, and the finished loop's 12 frames
/// still on the record.
class _GuidingStats extends GuideStatsNotifier {
  _GuidingStats(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const Phd2GuideStats(
      rmsRa: 0.53,
      rmsDec: 0.57,
      rmsTotal: 0.78,
      snr: 445.4,
      starMass: 206760,
      frameCount: 37,
      loopFrameCount: 12,
    );
  }
}

Future<void> _drainAsyncFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

List<Override> _overrides(Phd2State phd2State, Override stats) => [
      tutorialProvider.overrideWith((ref) => _TutorialsDisabledNotifier()),
      guiderStateProvider.overrideWith(_GuiderConnected.new),
      phd2StateProvider.overrideWith((ref) => phd2State),
      stats,
    ];

/// The value carried by the `Frames` [Readout] in the Star statistics panel.
String _frameCountValue(WidgetTester tester) {
  final readouts = tester.widgetList<Readout>(find.byType(Readout));
  final frames = readouts.where((r) => r.label == 'Frames').toList();
  expect(frames, hasLength(1),
      reason: 'exactly one Frames readout must be mounted');
  return frames.single.value!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a running loop reports the loop\'s own frames', (tester) async {
    await pumpAppScreen(
      tester,
      const GuidingScreen(),
      size: const Size(1400, 900),
      settle: false,
      extraOverrides: _overrides(Phd2State.looping,
          guideStatsProvider.overrideWith(_LoopingStats.new)),
    );
    await _drainAsyncFrames(tester);

    expect(
      _frameCountValue(tester),
      '12',
      reason: 'looping showed 0 while SNR and Star Mass updated per frame',
    );
  });

  testWidgets('guiding reports guide steps, not the last loop\'s frames',
      (tester) async {
    await pumpAppScreen(
      tester,
      const GuidingScreen(),
      size: const Size(1400, 900),
      settle: false,
      extraOverrides: _overrides(Phd2State.guiding,
          guideStatsProvider.overrideWith(_GuidingStats.new)),
    );
    await _drainAsyncFrames(tester);

    expect(_frameCountValue(tester), '37');
  });

  testWidgets('a stopped guider reports guide steps', (tester) async {
    await pumpAppScreen(
      tester,
      const GuidingScreen(),
      size: const Size(1400, 900),
      settle: false,
      extraOverrides: _overrides(Phd2State.stopped,
          guideStatsProvider.overrideWith(_GuidingStats.new)),
    );
    await _drainAsyncFrames(tester);

    expect(_frameCountValue(tester), '37');
  });
}
