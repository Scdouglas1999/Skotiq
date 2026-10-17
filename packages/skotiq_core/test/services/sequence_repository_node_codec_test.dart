// The DB sequence repository decodes every palette-reachable node type it
// encodes. Five of them (OpenCover / CloseCover / CalibratorOn / CalibratorOff /
// SciencePhotometry) without a matching decoder case make `_dbNodeToModel`
// return null and `loadSequence` throw a StateError, losing the ENTIRE saved
// sequence; the cover/calibrator config also has to survive the encode. This
// drives a real in-memory database through saveSequence -> loadSequence and
// asserts every field round-trips.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late SequenceRepository repo;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    repo = SequenceRepository(db.sequencesDao);
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'specialized nodes and recovery controls round-trip through the DB',
    () async {
      final root = InstructionSetNode(
        id: 'root',
        childIds: const [
          'open-cover',
          'calib-on',
          'science',
          'recovery',
          'autofocus',
          'calib-off',
          'close-cover',
        ],
      );
      final sequence = Sequence.create(
        id: 'seq-db-cover-science',
        name: 'DB cover + science round trip',
        rootNodeId: 'root',
        nodes: {
          'root': root,
          'open-cover': OpenCoverNode(
            id: 'open-cover',
            parentId: 'root',
            timeoutSecs: 90,
          ),
          'calib-on': CalibratorOnNode(
            id: 'calib-on',
            parentId: 'root',
            brightness: 200,
            timeoutSecs: 45,
          ),
          'science': SciencePhotometryNode(
            id: 'science',
            parentId: 'root',
            targetDesignation: 'V0376 Per',
            referenceStars: const ['ref-a', 'ref-b'],
            maxCadenceGapSecs: 1.5,
            filter: 'V',
            exposureSecs: 30,
            count: 120,
            reduceLive: false,
            applyDifferential: false,
            quality: const PhotometryQualityGates(
              minSnr: 75,
              maxFwhmArcsec: 3.5,
              requireAllRefsVisible: false,
              maxAirmass: 2.0,
            ),
            gain: 100,
            offset: 20,
            binning: BinningMode.two,
          ),
          'recovery': RecoveryNode(
            id: 'recovery',
            parentId: 'root',
            triggerType: TriggerType.cloudCoverThreshold,
            triggerEveryNFrames: 7,
            focusDriftWindowSize: 12,
            focusDriftMinIncreasingCount: 6,
            focusDriftMinTotalIncrease: 0.75,
            guidingFailedDurationSecs: 44,
            cloudMinutesBefore: 14,
            cloudCoverageThresholdPercent: 61,
            cloudOpeningMinDurationSecs: 420,
            cloudCoverMaxPercent: 73,
            cloudCoverDurationSecs: 88,
            transparencyBelowThreshold: 0.62,
            transparencyDurationSecs: 95,
          ),
          'autofocus': AutofocusNode(
            id: 'autofocus',
            parentId: 'root',
            exposuresPerPoint: 4,
          ),
          'calib-off': CalibratorOffNode(
            id: 'calib-off',
            parentId: 'root',
            timeoutSecs: 25,
          ),
          'close-cover': CloseCoverNode(
            id: 'close-cover',
            parentId: 'root',
            timeoutSecs: 75,
          ),
        },
      );

      final savedId = await repo.saveSequence(sequence);
      final loaded = await repo.loadSequence(savedId);

      expect(
        loaded,
        isNotNull,
        reason: 'loadSequence must not throw / drop the sequence',
      );
      expect(loaded!.nodes.length, 8);

      final reAutofocus = loaded.nodes['autofocus'];
      expect(reAutofocus, isA<AutofocusNode>());
      expect((reAutofocus as AutofocusNode).exposuresPerPoint, 4);

      final reOpen = loaded.nodes['open-cover'];
      expect(reOpen, isA<OpenCoverNode>());
      expect((reOpen as OpenCoverNode).timeoutSecs, 90);

      final reCalibOn = loaded.nodes['calib-on'];
      expect(reCalibOn, isA<CalibratorOnNode>());
      expect((reCalibOn as CalibratorOnNode).brightness, 200);
      expect(reCalibOn.timeoutSecs, 45);

      final reCalibOff = loaded.nodes['calib-off'];
      expect(reCalibOff, isA<CalibratorOffNode>());
      expect((reCalibOff as CalibratorOffNode).timeoutSecs, 25);

      final reClose = loaded.nodes['close-cover'];
      expect(reClose, isA<CloseCoverNode>());
      expect((reClose as CloseCoverNode).timeoutSecs, 75);

      final reSci = loaded.nodes['science'];
      expect(reSci, isA<SciencePhotometryNode>());
      final sci = reSci as SciencePhotometryNode;
      expect(sci.targetDesignation, 'V0376 Per');
      expect(sci.referenceStars, ['ref-a', 'ref-b']);
      expect(sci.maxCadenceGapSecs, 1.5);
      expect(sci.filter, 'V');
      expect(sci.exposureSecs, 30);
      expect(sci.count, 120);
      expect(sci.reduceLive, isFalse);
      expect(sci.applyDifferential, isFalse);
      expect(sci.gain, 100);
      expect(sci.offset, 20);
      expect(sci.binning, BinningMode.two);
      expect(sci.quality.minSnr, 75);
      expect(sci.quality.maxFwhmArcsec, 3.5);
      expect(sci.quality.requireAllRefsVisible, isFalse);
      expect(sci.quality.maxAirmass, 2.0);

      final recovery = loaded.nodes['recovery'] as RecoveryNode;
      expect(recovery.triggerType, TriggerType.cloudCoverThreshold);
      expect(recovery.triggerEveryNFrames, 7);
      expect(recovery.focusDriftWindowSize, 12);
      expect(recovery.focusDriftMinIncreasingCount, 6);
      expect(recovery.focusDriftMinTotalIncrease, 0.75);
      expect(recovery.guidingFailedDurationSecs, 44);
      expect(recovery.cloudMinutesBefore, 14);
      expect(recovery.cloudCoverageThresholdPercent, 61);
      expect(recovery.cloudOpeningMinDurationSecs, 420);
      expect(recovery.cloudCoverMaxPercent, 73);
      expect(recovery.cloudCoverDurationSecs, 88);
      expect(recovery.transparencyBelowThreshold, 0.62);
      expect(recovery.transparencyDurationSecs, 95);
    },
  );

  test(
    'database codec preserves frame, mosaic, and loop safety semantics',
    () async {
      final root = InstructionSetNode(
        id: 'root-codec',
        childIds: const ['target-codec', 'loop-codec', 'exposure-codec'],
      );
      final sequence = Sequence.create(
        id: 'seq-codec-parity',
        name: 'Codec parity',
        rootNodeId: root.id,
        nodes: {
          root.id: root,
          'target-codec': TargetHeaderNode(
            id: 'target-codec',
            parentId: root.id,
            targetName: 'M31 panel',
            raHours: 0.71,
            decDegrees: 41.27,
            mosaicPanel: const MosaicPanelInfo(
              mosaicName: 'M31 2x2',
              panelIndex: 2,
              totalPanels: 4,
              row: 0,
              column: 1,
            ),
          ),
          'loop-codec': LoopNode(
            id: 'loop-codec',
            parentId: root.id,
            conditionType: LoopConditionType.forever,
            maxSafetyIterations: 17,
          ),
          'exposure-codec': ExposureNode(
            id: 'exposure-codec',
            parentId: root.id,
            frameType: FrameType.darkFlat,
            count: 3,
          ),
        },
      );

      final id = await repo.saveSequence(sequence);
      final loaded = await repo.loadSequence(id);

      final target = loaded!.nodes['target-codec'] as TargetHeaderNode;
      expect(target.mosaicPanel?.mosaicName, 'M31 2x2');
      expect(target.mosaicPanel?.panelIndex, 2);
      final loop = loaded.nodes['loop-codec'] as LoopNode;
      expect(loop.maxSafetyIterations, 17);
      final exposure = loaded.nodes['exposure-codec'] as ExposureNode;
      expect(exposure.frameType, FrameType.darkFlat);
      expect(exposure.count, 3);
    },
  );
}
