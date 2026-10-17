// A run of calibration frames does not need the mount off its park.
//
// Live: a sequence of `Target M4 -> Take Exposures 3 x 2.0s DARK` under a
// parked simulated mount raised "Mount is Parked / Your mount is currently
// parked. The sequence will automatically unpark the mount and continue." and,
// when its 15-second countdown expired, performed the unpark. The executor
// then took all three darks without ever issuing a slew — the mount had come
// off its park for nothing, and the operator had been told that was what the
// sequence required.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

Sequence _sequenceOf(List<SequenceNode> nodes) => Sequence.create(
  name: 'Test Sequence',
  nodes: {for (final node in nodes) node.id: node},
);

ExposureNode _exposures(FrameType frameType) =>
    ExposureNode(durationSecs: 2.0, count: 3, frameType: frameType);

void main() {
  test('a darks-only run under a target does not need the mount moved', () {
    // Exactly the tree the live repro used: a TargetHeader (which stamps the
    // target for the FITS header) with nothing but dark frames under it.
    final sequence = _sequenceOf([
      TargetHeaderNode(
        targetName: 'M4',
        raHours: 16.3931,
        decDegrees: -26.5256,
      ),
      _exposures(FrameType.dark),
    ]);

    expect(sequenceNeedsMountOffPark(sequence), isFalse);
    expect(sequenceIsCalibrationOnly(sequence), isTrue);
  });

  test('every calibration frame type is treated the same way', () {
    for (final frameType in const [
      FrameType.dark,
      FrameType.bias,
      FrameType.flat,
      FrameType.darkFlat,
    ]) {
      final sequence = _sequenceOf([_exposures(frameType)]);
      expect(
        sequenceNeedsMountOffPark(sequence),
        isFalse,
        reason: '$frameType is taken with the shutter closed or on a panel',
      );
    }
  });

  test('one light frame anywhere makes the whole run need the sky', () {
    final sequence = _sequenceOf([
      TargetHeaderNode(
        targetName: 'M4',
        raHours: 16.3931,
        decDegrees: -26.5256,
      ),
      _exposures(FrameType.dark),
      _exposures(FrameType.light),
    ]);

    expect(sequenceNeedsMountOffPark(sequence), isTrue);
    expect(sequenceIsCalibrationOnly(sequence), isFalse);
  });

  test('a node that points or moves the mount needs the sky on its own', () {
    // A sky flat is a calibration frame taken with the tube pointed, and the
    // operator says so with a Slew node — which is what this must catch.
    final skyFlats = _sequenceOf([SlewNode(), _exposures(FrameType.flat)]);
    expect(sequenceNeedsMountOffPark(skyFlats), isTrue);
    expect(sequenceIsCalibrationOnly(skyFlats), isFalse);

    expect(sequenceNeedsMountOffPark(_sequenceOf([CenterNode()])), isTrue);
    expect(
      sequenceNeedsMountOffPark(_sequenceOf([StartGuidingNode()])),
      isTrue,
    );
    expect(sequenceNeedsMountOffPark(_sequenceOf([AutofocusNode()])), isTrue);
  });

  test('an empty sequence is not a calibration run', () {
    final empty = _sequenceOf(const []);
    expect(sequenceNeedsMountOffPark(empty), isFalse);
    expect(
      sequenceIsCalibrationOnly(empty),
      isFalse,
      reason: 'nothing is captured, so there is nothing to describe',
    );
  });
}
