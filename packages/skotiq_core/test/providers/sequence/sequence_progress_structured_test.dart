import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  test('structured node progress does not clear legacy detail', () {
    final notifier = SequenceProgressNotifier();

    notifier.updateNodeProgress('exposure-1', 35, 'Frame 2/10');
    notifier.updateNodeStructuredProgress(
      'exposure-1',
      40,
      const ExposureInstructionProgressDetail(
        frame: 3,
        total: 10,
        durationSecs: 180,
      ),
    );

    expect(notifier.state.nodeProgressPercent['exposure-1'], 40);
    expect(notifier.state.nodeProgressDetail['exposure-1'], 'Frame 2/10');
    expect(
      notifier.state.nodeProgressStructuredDetail['exposure-1'],
      isA<ExposureInstructionProgressDetail>(),
    );
  });
}
