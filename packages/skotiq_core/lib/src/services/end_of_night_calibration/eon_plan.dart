import '../../database/database.dart' show CapturedImage;
import '../../models/imaging/imaging_models.dart' show FrameType;
import '../../models/sequence/sequence_models.dart';

/// One light configuration of the night, and the darks it needs.
class EonDarkGroup {
  const EonDarkGroup({
    required this.exposureSecs,
    required this.gain,
    required this.offset,
    required this.binX,
    required this.binY,
    required this.setPointC,
    required this.lightCount,
  });

  final double exposureSecs;
  final int gain;
  final int offset;
  final int binX;
  final int binY;

  /// Sensor temperature the darks are taken at; null for a camera that does
  /// not cool, whose darks are taken at whatever the sensor reads.
  final double? setPointC;

  /// Light frames tonight that this group calibrates.
  final int lightCount;

  String get label {
    final temp = setPointC == null
        ? 'uncooled'
        : '${_formatNumber(setPointC!)} C';
    return '${_formatNumber(exposureSecs)} s, gain $gain, offset $offset, '
        'bin ${binX}x$binY, $temp';
  }

  @override
  bool operator ==(Object other) =>
      other is EonDarkGroup &&
      other.exposureSecs == exposureSecs &&
      other.gain == gain &&
      other.offset == offset &&
      other.binX == binX &&
      other.binY == binY &&
      other.setPointC == setPointC &&
      other.lightCount == lightCount;

  @override
  int get hashCode => Object.hash(
    exposureSecs,
    gain,
    offset,
    binX,
    binY,
    setPointC,
    lightCount,
  );

  @override
  String toString() => 'EonDarkGroup($label, $lightCount lights)';
}

/// The bias set for one gain/offset/binning, at one set-point.
class EonBiasGroup {
  const EonBiasGroup({
    required this.gain,
    required this.offset,
    required this.binX,
    required this.binY,
    required this.setPointC,
  });

  final int gain;
  final int offset;
  final int binX;
  final int binY;
  final double? setPointC;

  @override
  bool operator ==(Object other) =>
      other is EonBiasGroup &&
      other.gain == gain &&
      other.offset == offset &&
      other.binX == binX &&
      other.binY == binY &&
      other.setPointC == setPointC;

  @override
  int get hashCode => Object.hash(gain, offset, binX, binY, setPointC);
}

/// What the night's lights need.
class EonFrameNeeds {
  const EonFrameNeeds({required this.darks, required this.bias});

  final List<EonDarkGroup> darks;
  final List<EonBiasGroup> bias;

  bool get isEmpty => darks.isEmpty && bias.isEmpty;
}

/// A filter-wheel slot that blocks all light.
class EonDarkSlot {
  const EonDarkSlot({required this.name, required this.index});

  final String name;

  /// Zero-based wheel position.
  final int index;
}

String _formatNumber(double value) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  final text = value.toStringAsFixed(3);
  return text.replaceFirst(RegExp(r'0+$'), '');
}

/// The set-point a light was taken at: the camera's set-point when the night
/// was cooled to one, otherwise the light's sensor reading rounded to a whole
/// degree (a cooled sensor holds its set-point to well under a degree).
double? _setPointFor(CapturedImage light, double? cameraSetPointC) {
  final sensor = light.sensorTemp;
  if (cameraSetPointC != null &&
      (sensor == null || (sensor - cameraSetPointC).abs() <= 1.5)) {
    return cameraSetPointC;
  }
  return sensor?.roundToDouble();
}

/// Group the night's light frames into the dark and bias sets they need.
///
/// One dark group per exposure, gain, offset, binning and set-point actually
/// used; one bias group per gain, offset, binning and set-point. Exposures are
/// compared to the millisecond.
EonFrameNeeds planFrameNeeds(
  Iterable<CapturedImage> lights, {
  double? cameraSetPointC,
}) {
  final darkCounts = <(int, int, int, int, int, double?), int>{};
  for (final light in lights) {
    if (light.frameType.toLowerCase() != 'light') continue;
    if (light.exposureDuration <= 0) continue;
    final gain = light.gain;
    final offset = light.offset;
    if (gain == null || offset == null) {
      throw FormatException(
        'Cannot match calibration settings for ${light.fileName}: '
        'the recorded gain or offset is missing.',
      );
    }
    final key = (
      (light.exposureDuration * 1000).round(),
      gain,
      offset,
      light.binX,
      light.binY,
      _setPointFor(light, cameraSetPointC),
    );
    darkCounts[key] = (darkCounts[key] ?? 0) + 1;
  }
  final darks = [
    for (final entry in darkCounts.entries)
      EonDarkGroup(
        exposureSecs: entry.key.$1 / 1000,
        gain: entry.key.$2,
        offset: entry.key.$3,
        binX: entry.key.$4,
        binY: entry.key.$5,
        setPointC: entry.key.$6,
        lightCount: entry.value,
      ),
  ]..sort((a, b) => a.exposureSecs.compareTo(b.exposureSecs));
  final bias = <EonBiasGroup>{
    for (final d in darks)
      EonBiasGroup(
        gain: d.gain,
        offset: d.offset,
        binX: d.binX,
        binY: d.binY,
        setPointC: d.setPointC,
      ),
  }.toList();
  return EonFrameNeeds(darks: darks, bias: bias);
}

final _darkSlotName = RegExp(
  r'^(dark|darks|blank|opaque|closed|shutter|cap|blocked)$',
  caseSensitive: false,
);

/// The filter-wheel slot that blocks light, by name: `Dark`, `Blank`,
/// `Opaque`, `Closed`, `Shutter`, `Cap` or `Blocked`, any case. Null when the
/// wheel has none (or there is no wheel).
EonDarkSlot? findDarkSlot(List<String>? filterNames) {
  if (filterNames == null) return null;
  for (var i = 0; i < filterNames.length; i++) {
    final name = filterNames[i].trim();
    if (_darkSlotName.hasMatch(name)) {
      return EonDarkSlot(name: filterNames[i], index: i);
    }
  }
  return null;
}

BinningMode _binning(int bin) => switch (bin) {
  2 => BinningMode.two,
  3 => BinningMode.three,
  4 => BinningMode.four,
  _ => BinningMode.one,
};

/// The calibration-only sequence that takes [needs].
///
/// It only cools and exposes: no target, slew, guiding, dither or focus, so
/// the native sequencer runs it with the light-frame triggers standing down.
/// Darks for each set-point follow a Cool Camera step to that set-point;
/// bias frames come last, at the shortest exposure the camera takes.
Sequence buildCalibrationSequence({
  required EonFrameNeeds needs,
  required int darkCount,
  required int biasCount,
  required double biasExposureSecs,
  required bool cameraCanCool,
  EonDarkSlot? darkSlot,
  String name = 'End-of-night calibration',
}) {
  const root = 'eon-root';
  final nodes = <String, SequenceNode>{};
  final order = <String>[];
  const noAdaptive = AdaptiveExposureConfig(enabled: false);

  void add(SequenceNode node) {
    nodes[node.id] = node;
    order.add(node.id);
  }

  final setPoints = <double?>{
    for (final d in needs.darks) d.setPointC,
    for (final b in needs.bias) b.setPointC,
  };
  var index = 0;
  for (final setPoint in setPoints) {
    if (cameraCanCool && setPoint != null) {
      add(
        CoolCameraNode(
          id: 'eon-cool-${index++}',
          name: 'Cool to ${_formatNumber(setPoint)} C',
          parentId: root,
          targetTemp: setPoint,
          durationMins: 15,
        ),
      );
    }
    for (final dark in needs.darks.where((d) => d.setPointC == setPoint)) {
      add(
        ExposureNode(
          id: 'eon-dark-${index++}',
          name: 'Darks ${dark.label}',
          parentId: root,
          durationSecs: dark.exposureSecs,
          count: darkCount,
          frameType: FrameType.dark,
          filter: darkSlot?.name,
          filterIndex: darkSlot?.index,
          gain: dark.gain,
          offset: dark.offset,
          binning: _binning(dark.binX),
          ditherEvery: 0,
          adaptiveExposure: noAdaptive,
        ),
      );
    }
    for (final bias in needs.bias.where((b) => b.setPointC == setPoint)) {
      add(
        ExposureNode(
          id: 'eon-bias-${index++}',
          name: 'Bias gain ${bias.gain}, offset ${bias.offset}',
          parentId: root,
          durationSecs: biasExposureSecs,
          count: biasCount,
          frameType: FrameType.bias,
          filter: darkSlot?.name,
          filterIndex: darkSlot?.index,
          gain: bias.gain,
          offset: bias.offset,
          binning: _binning(bias.binX),
          ditherEvery: 0,
          adaptiveExposure: noAdaptive,
        ),
      );
    }
  }
  final ordered = <String, SequenceNode>{
    root: InstructionSetNode(id: root, name: name, childIds: order),
    for (var i = 0; i < order.length; i++)
      order[i]: nodes[order[i]]!.copyWith(orderIndex: i),
  };
  return Sequence.create(name: name, nodes: ordered, rootNodeId: root);
}

/// Whether [sequence] only takes calibration frames and otherwise only cools,
/// warms, parks or homes. The native sequencer applies the same rule to keep
/// the light-frame triggers off such a run; the app uses it to keep weather
/// and dawn safing from pausing it.
bool isCalibrationOnlySequence(Sequence sequence) {
  var calibrationFrames = false;
  for (final node in sequence.nodes.values) {
    if (!node.isEnabled) continue;
    switch (node) {
      case ExposureNode(:final frameType):
        if (frameType == FrameType.light || frameType == FrameType.snapshot) {
          return false;
        }
        calibrationFrames = true;
      case InstructionSetNode() ||
          LoopNode() ||
          ParallelNode() ||
          RecoveryNode() ||
          StopGuidingNode() ||
          FilterChangeNode() ||
          CoolCameraNode() ||
          WarmCameraNode() ||
          ParkNode() ||
          HomeMountNode() ||
          WaitTimeNode() ||
          DelayNode() ||
          NotificationNode() ||
          CloseDomeNode() ||
          ParkDomeNode() ||
          CloseCoverNode() ||
          OpenCoverNode() ||
          CalibratorOnNode() ||
          CalibratorOffNode():
        break;
      default:
        return false;
    }
  }
  return calibrationFrames;
}
