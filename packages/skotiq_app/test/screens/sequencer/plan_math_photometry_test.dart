// A Science Photometry burst is capture like any other: the executor runs its
// `count` frames through the same TakeExposure pipeline. `plannedCaptureUnder`
// is the shared walk behind the target header card and the library card's
// preview, and it knew only about ExposureNode and SmartExposureNode — so a
// target whose only imager was a photometry burst reported "no exposures"
// while the node's own row read "60 frames".

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/plan_math.dart';
import 'package:skotiq_core/skotiq_core.dart';

Sequence _photometryUnderTarget({int count = 60, double exposureSecs = 60}) {
  final target = TargetHeaderNode(
    id: 'target1',
    targetName: 'V0376 Per',
    raHours: 4.0,
    decDegrees: 40.0,
    childIds: const ['phot1'],
  );
  return Sequence.create(
    name: 'Photometry',
    rootNodeId: 'target1',
    nodes: {
      'target1': target,
      'phot1': SciencePhotometryNode(
        id: 'phot1',
        targetDesignation: 'V0376 Per',
        filter: 'V',
        count: count,
        exposureSecs: exposureSecs,
        parentId: 'target1',
      ),
    },
  );
}

void main() {
  test('a photometry burst contributes its frames and integration', () {
    final planned = plannedCaptureUnder(_photometryUnderTarget(), 'target1');
    expect(planned.frames, 60);
    expect(planned.integrationSecs, 3600.0);
    expect(planned.isEmpty, isFalse);
  });

  test('the burst files its integration under its own filter band', () {
    final planned = plannedCaptureUnder(_photometryUnderTarget(), 'target1');
    expect(planned.integrationSecsByFilter, {'V': 3600.0});
  });

  test('a count loop multiplies the burst like any other exposure', () {
    final sequence = Sequence.create(
      name: 'Looped photometry',
      rootNodeId: 'loop1',
      nodes: {
        'loop1': LoopNode(
          id: 'loop1',
          conditionType: LoopConditionType.count,
          repeatCount: 3,
          childIds: const ['phot1'],
        ),
        'phot1': SciencePhotometryNode(
          id: 'phot1',
          filter: 'V',
          count: 10,
          exposureSecs: 30,
          parentId: 'loop1',
        ),
      },
    );
    final planned = plannedCaptureUnder(sequence, 'loop1');
    expect(planned.frames, 30);
    expect(planned.integrationSecs, 900.0);
  });

  test('a disabled burst plans nothing', () {
    final sequence = Sequence.create(
      name: 'Disabled',
      rootNodeId: 'target1',
      nodes: {
        'target1': TargetHeaderNode(
          id: 'target1',
          targetName: 'V0376 Per',
          raHours: 4.0,
          decDegrees: 40.0,
          childIds: const ['phot1'],
        ),
        'phot1': SciencePhotometryNode(
          id: 'phot1',
          count: 60,
          isEnabled: false,
          parentId: 'target1',
        ),
      },
    );
    final planned = plannedCaptureUnder(sequence, 'target1');
    expect(planned.frames, 0);
    expect(planned.isEmpty, isTrue);
  });
}
