import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/panel/camera/camera_panel_vm.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../data/plan/plan_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Sequence smartPlan() {
    final smart = SmartExposureNode(
      id: 'smart',
      parentId: 'root',
      plans: const [
        FilterPlan(
          filterName: 'L',
          durationSecs: 30,
          gain: 100,
          offset: 10,
          binning: BinningMode.one,
        ),
        FilterPlan(
          filterName: 'Ha',
          durationSecs: 180,
          gain: 200,
          offset: 20,
          binning: BinningMode.two,
        ),
      ],
    );
    final root = InstructionSetNode(
      id: 'root',
      childIds: const ['smart'],
    );
    return Sequence.create(
      name: 'M74',
      rootNodeId: root.id,
      nodes: {root.id: root, smart.id: smart},
    );
  }

  NightCaptureValues? step(
    SequenceProgress progress, {
    int? wheelPosition,
  }) {
    final container = planContainer(
      now: DateTime.utc(2026, 11, 1, 2),
      sequence: smartPlan(),
      execution: SequenceExecutionState.running,
      progress: progress,
    );
    addTearDown(container.dispose);
    if (wheelPosition != null) {
      container.read(filterWheelStateProvider.notifier).state =
          FilterWheelState(
            connectionState: DeviceConnectionState.connected,
            filterNames: const ['L', 'Ha'],
            currentPosition: wheelPosition,
          );
    }
    return container.read(nightCameraPanelProvider).step;
  }

  test('the camera panel shows the Smart Exposure plan for the live filter', () {
    final ha = step(const SequenceProgress(
      currentNodeId: 'smart',
      currentFilter: 'Ha',
    ));
    expect(ha, isNotNull);
    expect(ha!.exposureSecs, 180);
    expect(ha.gain, 200);
    expect(ha.offset, 20);
    expect(ha.filter, 'Ha');
    expect(ha.binning, 2);
    expect(ha.frameType, FrameType.light);

    final luminance = step(
      const SequenceProgress(currentNodeId: 'smart'),
      wheelPosition: 0,
    );
    expect(luminance?.exposureSecs, 30);
    expect(luminance?.gain, 100);
    expect(luminance?.filter, 'L');

    final emptyFilter = step(
      const SequenceProgress(currentNodeId: 'smart', currentFilter: ''),
      wheelPosition: 0,
    );
    expect(emptyFilter?.exposureSecs, 30);
    expect(emptyFilter?.gain, 100);

    final missing = step(const SequenceProgress(
      currentNodeId: 'smart',
      currentFilter: 'OIII',
    ));
    expect(missing, isNull);
  });
}
