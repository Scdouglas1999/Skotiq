import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/providers/sequence/rules/exposure_rules.dart';

/// A sequence whose only imaging node is a Science Photometry burst reported
/// "0 frames / 0m" in the header and "No exposure nodes found" in pre-flight,
/// while the node's own properties panel said 60 frames and the Rust executor
/// captured all 60. Three surfaces did not know SciencePhotometryNode exists.
void main() {
  Sequence photometryOnly({int count = 60, double exposureSecs = 60.0}) {
    return Sequence.create(
      name: 'Photometry',
      rootNodeId: 'target1',
      nodes: {
        'target1': TargetHeaderNode(
          id: 'target1',
          name: 'V0376 Per',
          targetName: 'V0376 Per',
          raHours: 4.0,
          decDegrees: 40.0,
          childIds: const ['phot1'],
        ),
        'phot1': SciencePhotometryNode(
          id: 'phot1',
          targetDesignation: 'V0376 Per',
          count: count,
          exposureSecs: exposureSecs,
          parentId: 'target1',
        ),
      },
    );
  }

  test('the header frame count includes a photometry burst', () {
    expect(photometryOnly(count: 60).totalExposures, 60);
  });

  test('a photometry burst contributes its integration time', () {
    expect(
      photometryOnly(count: 60, exposureSecs: 60.0).totalIntegrationSecs,
      3600.0,
    );
  });

  test('a count loop multiplies the photometry burst like any exposure', () {
    final sequence = Sequence.create(
      name: 'Looped photometry',
      rootNodeId: 'loop1',
      nodes: {
        'loop1': LoopNode(
          id: 'loop1',
          name: 'Repeat',
          conditionType: LoopConditionType.count,
          repeatCount: 3,
          childIds: const ['phot1'],
        ),
        'phot1': SciencePhotometryNode(
          id: 'phot1',
          count: 10,
          exposureSecs: 30.0,
          parentId: 'loop1',
        ),
      },
    );
    expect(sequence.totalExposures, 30);
  });

  test('a disabled photometry burst is not counted', () {
    final sequence = Sequence.create(
      name: 'Disabled',
      rootNodeId: 'target1',
      nodes: {
        'target1': TargetHeaderNode(
          id: 'target1',
          name: 'V0376 Per',
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
    expect(sequence.totalExposures, 0);
  });

  test(
    'pre-flight does not claim a photometry sequence captures no images',
    () {
      final issues = NoExposuresRule().validate(photometryOnly());
      expect(issues, isEmpty);
    },
  );

  test('pre-flight still warns when there really is no imaging node', () {
    final sequence = Sequence.create(
      name: 'No imaging',
      rootNodeId: 'target1',
      nodes: {
        'target1': TargetHeaderNode(
          id: 'target1',
          name: 'V0376 Per',
          targetName: 'V0376 Per',
          raHours: 4.0,
          decDegrees: 40.0,
        ),
      },
    );
    final issues = NoExposuresRule().validate(sequence);
    expect(issues, hasLength(1));
    expect(issues.single.title, 'No Exposures');
  });
}
