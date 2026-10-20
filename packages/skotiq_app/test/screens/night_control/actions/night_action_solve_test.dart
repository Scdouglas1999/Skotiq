// Solve (no sync) goes through the action controller like every other
// manual action, but it reads a file and moves nothing, so it never pauses
// the run. The centering the Solve tab describes is the one Center runs.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/actions/night_action_controller.dart';
import 'package:skotiq_app/screens/night_control/actions/night_rig_ops.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'night_action_test_support.dart';

const _path = '/data/Skotiq/M74/L/M74_L_0044.fits';

CapturedImageData _frame({String? path = _path}) => CapturedImageData(
      width: 4,
      height: 4,
      displayData: Uint8List(64),
      histogram: List<int>.filled(256, 0),
      stats: const ImageStats(
        hfr: 2.1,
        starCount: 80,
        median: 500,
        mean: 510,
        stdDev: 20,
        min: 0,
        max: 65535,
      ),
      capturedAt: DateTime.utc(2026, 10, 19, 4),
      settings: const ExposureSettings(exposureTime: 60, gain: 100, offset: 10),
      isColor: false,
      filePath: path,
    );

void main() {
  test('solve reads the frame on screen and leaves a running run alone',
      () async {
    final h = actionHarness(runState: SequenceExecutionState.running);
    addTearDown(h.container.dispose);
    h.container.read(currentImageProvider.notifier).state = _frame();

    await h.container.read(nightActionApiProvider).solve();

    expect(h.ops.calls, <String>['solveFile $_path'],
        reason: 'no pause, no resume, no sync');
    final state = h.container.read(nightActionStateProvider);
    expect(state.error, isNull);
    expect(state.lastSolveDuration, isNotNull,
        reason: 'the Solve tab shows how long the solve took');
    expect(
      h.container.read(sequenceExecutionStateProvider),
      SequenceExecutionState.running,
    );
  });

  test('a failed solve lands in the action error', () async {
    final h = actionHarness();
    addTearDown(h.container.dispose);
    h.container.read(currentImageProvider.notifier).state = _frame();
    h.ops.fileSolveSucceeds = false;

    await h.container.read(nightActionApiProvider).solve();

    final error = h.container.read(nightActionStateProvider).error;
    expect(error?.key, 'nightActErrSolve');
    expect(error?.params['detail'], 'No match');
  });

  test('no saved frame on screen: nothing to solve', () async {
    final h = actionHarness();
    addTearDown(h.container.dispose);
    h.container.read(currentImageProvider.notifier).state = _frame(path: null);

    final inputs = h.container.read(nightActionInputsProvider);
    expect(inputs.hasFrame, isFalse);
    await h.container.read(nightActionApiProvider).solve();
    expect(h.ops.calls, isEmpty);
  });

  test('solve opens the Solve tab', () {
    expect(ManualActionId.solve.panelTab, NightPanelTab.solve);
  });

  test('the centering config follows the settings and the profile', () async {
    final h = actionHarness(
      extra: [
        appSettingsProvider.overrideWith(
          () => _Settings(const AppSettingsState(centeringSyncMount: false)),
        ),
        activeEquipmentProfileProvider.overrideWithValue(null),
      ],
    );
    addTearDown(h.container.dispose);
    await h.container.read(appSettingsProvider.future);

    final config = h.container.read(nightCenteringConfigProvider);
    expect(config, isNotNull);
    expect(config!.maxIterations, 5);
    expect(config.toleranceArcsec, 30.0);
    expect(config.exposureTime, 5.0,
        reason: 'no profile: the centering dialog\'s 5 s, not the model\'s 3');
    expect(config.syncMount, isFalse);
  });
}

class _Settings extends AppSettingsNotifier {
  _Settings(this._value);
  final AppSettingsState _value;

  @override
  Future<AppSettingsState> build() async => _value;
}
