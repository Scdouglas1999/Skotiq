part of '../sequence_models.dart';

/// Node types that point or move the mount, or that only mean anything with
/// the tube on the sky.
///
/// Anything NOT in this set runs identically with the mount parked at home:
/// a dark, bias, flat or dark-flat exposure, a filter change, a cooler ramp, a
/// delay, a cover/calibrator/dome command, a rotator move, a notification, a
/// script, or any of the pure container nodes.
const Set<String> _skyRequiringNodeTypes = {
  'SlewToTarget',
  'CenterTarget',
  'MeridianFlip',
  'PolarAlignment',
  'TargetScheduler',
  'Unpark',
  'StartGuiding',
  'Dither',
  // Captures that are lights by construction.
  'SmartExposure',
  'SciencePhotometry',
  'LiveStacking',
  // Autofocus runs on a real star through the imaging train.
  'Autofocus',
};

/// Frame types that need the tube pointed at something.
const Set<FrameType> _skyRequiringFrameTypes = {
  FrameType.light,
  FrameType.snapshot,
};

/// Whether anything in [sequence] needs the mount off its park.
///
/// This is the question the pre-start "Mount is Parked" dialog was not asking.
/// It offered — and, on the countdown expiring, performed — an automatic
/// unpark for a run of three DARK frames: the executor then took all three
/// without ever issuing a slew, because nothing about a dark depends on where
/// the tube points. The mount came off its park for no reason, and the dialog
/// told the operator that was what the sequence needed.
///
/// Deliberately conservative in one direction: a node is treated as needing
/// the sky unless it clearly does not, and a disabled node's children are NOT
/// walked away from — a light frame anywhere in the tree, enabled or reachable
/// only through a disabled parent, still counts. Wrongly unparking is the
/// behaviour that already shipped; wrongly REFUSING to unpark would strand a
/// real imaging run against a parked mount, which is far worse.
bool sequenceNeedsMountOffPark(Sequence sequence) {
  for (final node in sequence.nodes.values) {
    if (_skyRequiringNodeTypes.contains(node.nodeType)) return true;
    if (node is ExposureNode &&
        _skyRequiringFrameTypes.contains(node.frameType)) {
      return true;
    }
  }
  return false;
}

/// Whether [sequence] captures anything at all, and everything it captures is
/// a calibration frame.
///
/// Separate from [sequenceNeedsMountOffPark] because the two answer different
/// questions and the copy shown to the operator depends on this one: an empty
/// sequence, or one that only changes filters, is not "a calibration run".
bool sequenceIsCalibrationOnly(Sequence sequence) {
  var sawCapture = false;
  for (final node in sequence.nodes.values) {
    if (node is! ExposureNode) continue;
    sawCapture = true;
    if (_skyRequiringFrameTypes.contains(node.frameType)) return false;
  }
  return sawCapture && !sequenceNeedsMountOffPark(sequence);
}
