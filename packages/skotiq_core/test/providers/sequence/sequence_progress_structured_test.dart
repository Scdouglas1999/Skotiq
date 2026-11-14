import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

void main() {
  test('structured node progress does not clear legacy detail', () {
    final notifier = RunRecordNotifier();

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

    expect(notifier.state.progress.nodeProgressPercent['exposure-1'], 40);
    expect(
      notifier.state.progress.nodeProgressDetail['exposure-1'],
      'Frame 2/10',
    );
    expect(
      notifier.state.progress.nodeProgressStructuredDetail['exposure-1'],
      isA<ExposureInstructionProgressDetail>(),
    );
  });

  // An autofocus reports "Point 4/9: pos 800" (free text) between the points
  // it measures; the panel reads the point, HFR and stars from the store.
  test('a step keeps its last reading across its free-text lines', () {
    final notifier = RunRecordNotifier();
    const measured = AutofocusInstructionProgressDetail(
      step: 3,
      totalSteps: 9,
      currentHfr: 3.1,
      starCount: 40,
    );

    notifier.updateNodeStructuredProgress('af', 30, measured);
    notifier.updateNodeStructuredProgress(
      'af',
      35,
      const UnknownInstructionProgressDetail(
        kind: kGenericProgressDetailKind,
        rawJson: {},
      ),
    );

    final progress = notifier.state.progress;
    expect(progress.nodeProgressStructuredDetail['af'], measured);
    expect(progress.nodeProgressPercent['af'], 35);
  });
}
