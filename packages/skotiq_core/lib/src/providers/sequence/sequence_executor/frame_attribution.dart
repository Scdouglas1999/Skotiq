import '../../../models/imaging/imaging_models.dart' show FrameType;
import '../../../models/sequence/sequence_models.dart';

/// Which catalog target a graded frame belongs to and how long it was
/// actually exposed, derived from the producing node and the sequence tree.
///
/// This replaces the former frame-registration constants — `target_id=NULL`
/// and a hardcoded `exposureDuration: 1.0` — that quietly broke two things on
/// every imaging path:
///   * per-target integration-goal completion (the live scheduler counted
///     `WHERE target_id = ?`, always got 0, and imaged one target all night), and
///   * all integration-time accounting (every frame recorded as 1 second).
class FrameAttribution {
  /// DB `targets.id` of the enclosing [TargetHeaderNode], or `null` when the
  /// producing node has no target ancestor carrying a catalog id (e.g. an
  /// ad-hoc manual sequence). `null` is the honest result: no per-target
  /// goal tracking, rather than a wrong attribution.
  final int? targetId;

  /// Exposure length in seconds for this frame: the producing
  /// [ExposureNode]'s configured duration, or — for a [SmartExposureNode] —
  /// the duration of the per-filter plan matching the filter currently
  /// exposing. `null` when it cannot be determined (the caller should surface
  /// that rather than paper over it with a fabricated value).
  final double? exposureSecs;

  /// Images-DB `frame_type` string for this frame ('light', 'dark', 'flat',
  /// 'bias', 'darkflat', 'snapshot'), from the producing [ExposureNode]'s
  /// configured [FrameType]. Defaults to 'light' — correct for every
  /// producing node type that has no frame-type knob (SmartExposure plans
  /// and SciencePhotometry are light-only by construction).
  final String frameType;

  /// Sensor gain the frame was taken at, from the producing node's config.
  /// `null` when the node leaves gain to the camera's current value.
  ///
  /// Master-dark matching keys on gain, offset and binning, so a frame that
  /// does not carry them cannot be paired with its calibration frames.
  final int? gain;

  /// Sensor offset the frame was taken at. Same rationale as [gain].
  final int? offset;

  /// Binning factor actually used. Worth passing explicitly rather than
  /// leaning on the column default: `captured_images.bin_x/bin_y` are
  /// `NOT NULL DEFAULT 1`, so omitting them recorded every binned sequencer
  /// frame as 1x1 — a silently wrong value rather than a missing one.
  final int binX;
  final int binY;

  const FrameAttribution({
    this.targetId,
    this.exposureSecs,
    this.frameType = 'light',
    this.gain,
    this.offset,
    this.binX = 1,
    this.binY = 1,
  });
}

/// Square binning factor for [mode] (`BinningMode.two` -> 2).
int _binningFactor(BinningMode mode) => switch (mode) {
  BinningMode.one => 1,
  BinningMode.two => 2,
  BinningMode.three => 3,
  BinningMode.four => 4,
};

/// Images-DB string form of [FrameType] (lowercase, matching
/// `_frameTypeFromDbString` in imaging_provider.dart).
String _frameTypeToDbString(FrameType type) => switch (type) {
  FrameType.light => 'light',
  FrameType.dark => 'dark',
  FrameType.flat => 'flat',
  FrameType.bias => 'bias',
  FrameType.darkFlat => 'darkflat',
  FrameType.snapshot => 'snapshot',
};

/// Resolve the [FrameAttribution] for the frame produced by [nodeId] within
/// [sequence].
///
/// Walks the tree upward from the producing node through any intervening
/// containers (Loop / Sequential / Parallel) until it reaches the enclosing
/// [TargetHeaderNode] (see [enclosingTargetHeader]), reading its
/// [catalogTargetId]. The exposure length comes from the producing
/// [ExposureNode]'s configured duration.
FrameAttribution resolveFrameAttribution(
  Sequence sequence,
  String nodeId, {
  String? currentFilter,
}) {
  final producing = sequence.nodes[nodeId];
  double? exposureSecs;
  var frameType = 'light';
  int? gain;
  int? offset;
  var binX = 1;
  var binY = 1;
  if (producing is ExposureNode) {
    exposureSecs = producing.durationSecs;
    frameType = _frameTypeToDbString(producing.frameType);
    gain = producing.gain;
    offset = producing.offset;
    binX = _binningFactor(producing.binning);
    binY = binX;
  } else if (producing is SmartExposureNode && currentFilter != null) {
    // SmartExposure rotates per-filter plans; the duration of THIS sub is the
    // plan whose filter is currently exposing. (For adaptive/variable cases
    // the fully authoritative per-frame value would have to come from the
    // executor event — tracked separately.)
    for (final plan in producing.plans) {
      if (plan.filterName.toLowerCase() == currentFilter.toLowerCase()) {
        exposureSecs = plan.durationSecs;
        // The per-filter plan owns its own gain/offset/binning, so a
        // SmartExposure frame must be stamped from the matching plan rather
        // than from the node.
        gain = plan.gain;
        offset = plan.offset;
        binX = _binningFactor(plan.binning);
        binY = binX;
        break;
      }
    }
  }

  final header = enclosingTargetHeader(sequence, nodeId);

  return FrameAttribution(
    targetId: header?.catalogTargetId,
    exposureSecs: exposureSecs,
    frameType: frameType,
    gain: gain,
    offset: offset,
    binX: binX,
    binY: binY,
  );
}

/// The [TargetHeaderNode] that encloses [nodeId] in [sequence], or `null` when
/// the node sits outside any target.
///
/// Parent links are derived by inverting each node's `childIds` rather than
/// using `Sequence.parentOf` / `node.parentId`: scheduler-generated, in-memory
/// sequences (the path with the original `target_id=NULL` bug) populate
/// `childIds` but NOT `parentId`, so a `parentId`-based walk silently returns
/// null and never reaches the target. `childIds` is the model's documented
/// canonical source and is always present. A `visited` guard makes a malformed
/// (cyclic) tree terminate rather than spin.
TargetHeaderNode? enclosingTargetHeader(Sequence sequence, String nodeId) {
  final parentByChild = <String, String>{};
  for (final node in sequence.nodes.values) {
    for (final childId in node.childIds) {
      parentByChild[childId] = node.id;
    }
  }

  String? cursor = nodeId;
  final visited = <String>{};
  while (cursor != null && visited.add(cursor)) {
    final node = sequence.nodes[cursor];
    if (node is TargetHeaderNode) return node;
    cursor = parentByChild[cursor];
  }
  return null;
}
