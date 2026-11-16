import '../../database/database.dart' show DbCapturedImage;
import '../../models/imaging/imaging_models.dart' show FrameType;
import '../darkroom_build_service.dart' show darkroomTemperatureGapC;
import '../frame_header.dart';

/// What a dark or bias frame's own header says about how it was taken,
/// beyond what its `captured_images` row records.
class CalibrationFrameFacts {
  const CalibrationFrameFacts({this.setPointC, this.readMode});

  /// The facts in [header]: the cooler set-point (`SET-TEMP`) and the read
  /// mode (`READOUTM`).
  factory CalibrationFrameFacts.fromHeader(FrameHeader header) =>
      CalibrationFrameFacts(
        setPointC: header.firstNumber(const ['SET-TEMP', 'SET_TEMP']),
        readMode: header.string('READOUTM'),
      );

  /// The cooler set-point the frame was taken at; null for a camera that was
  /// not cooling to one.
  final double? setPointC;
  final String? readMode;
}

/// The capture setting one master is built for: frame type, exposure (darks
/// only; bias is the camera's shortest), gain, offset, binning, read mode and
/// set-point.
class CalibrationFrameSetting {
  const CalibrationFrameSetting({
    required this.type,
    required this.exposureSecs,
    required this.gain,
    required this.offset,
    required this.binX,
    required this.binY,
    required this.readMode,
    required this.setPointC,
  });

  final FrameType type;
  final double exposureSecs;
  final int? gain;
  final int? offset;
  final int binX;
  final int binY;
  final String? readMode;

  /// Null for a camera that does not cool: its frames are split where the
  /// sensor temperature jumps instead.
  final double? setPointC;

  int get _exposureMs =>
      type == FrameType.bias ? 0 : (exposureSecs * 1000).round();
  int? get _setPointTenths =>
      setPointC == null ? null : (setPointC! * 10).round();

  @override
  bool operator ==(Object other) =>
      other is CalibrationFrameSetting &&
      other.type == type &&
      other._exposureMs == _exposureMs &&
      other.gain == gain &&
      other.offset == offset &&
      other.binX == binX &&
      other.binY == binY &&
      other.readMode == readMode &&
      other._setPointTenths == _setPointTenths;

  @override
  int get hashCode => Object.hash(
    type,
    _exposureMs,
    gain,
    offset,
    binX,
    binY,
    readMode,
    _setPointTenths,
  );
}

/// The frames one master is built from, and the frames of the same setting
/// that are left out of it.
class CalibrationFrameGroup {
  CalibrationFrameGroup({
    required this.setting,
    required this.frames,
    required this.offSetPoint,
  });

  final CalibrationFrameSetting setting;

  /// Oldest first.
  final List<DbCapturedImage> frames;

  /// Frames of this setting whose sensor read further than the tolerance from
  /// the set-point: taken off it, and never built into its master.
  final List<DbCapturedImage> offSetPoint;

  /// The temperature the master stands for: the set-point, or for a camera
  /// that does not cool the median sensor reading.
  double? get temperatureC {
    if (setting.setPointC != null) return setting.setPointC;
    final temps = [
      for (final f in frames)
        if (f.sensorTemp != null) f.sensorTemp!,
    ]..sort();
    return temps.isEmpty ? null : temps[temps.length ~/ 2];
  }
}

/// The one rule for which darks and bias make one master, shared by the
/// end-of-night calibration and Darkroom > Calibration.
///
/// Frames group by [CalibrationFrameSetting]: type, exposure, gain, offset,
/// binning, read mode and the set-point their header states. A frame whose
/// sensor read more than [toleranceC] (the dark library's temperature
/// tolerance) from its set-point is left out ([CalibrationFrameGroup.
/// offSetPoint]), so a master never stands for a temperature its frames were
/// not at. Frames of a camera that does not cool have no set-point and split
/// where the sorted sensor readings jump by more than
/// [darkroomTemperatureGapC]. Frames other than darks and bias are ignored.
List<CalibrationFrameGroup> groupCalibrationFrames(
  Iterable<(DbCapturedImage, CalibrationFrameFacts)> frames, {
  required double toleranceC,
}) {
  final bySetting = <CalibrationFrameSetting, List<DbCapturedImage>>{};
  for (final (frame, facts) in frames) {
    final type = FrameType.fromRecord(frame.frameType.trim().toLowerCase());
    if (type != FrameType.dark && type != FrameType.bias) continue;
    final setting = CalibrationFrameSetting(
      type: type!,
      exposureSecs: frame.exposureDuration,
      gain: frame.gain,
      offset: frame.offset,
      binX: frame.binX,
      binY: frame.binY,
      readMode: facts.readMode,
      setPointC: facts.setPointC,
    );
    (bySetting[setting] ??= []).add(frame);
  }
  final groups = <CalibrationFrameGroup>[];
  for (final MapEntry(key: setting, value: members) in bySetting.entries) {
    members.sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
    final setPoint = setting.setPointC;
    if (setPoint == null) {
      for (final cluster in _temperatureClusters(members)) {
        groups.add(
          CalibrationFrameGroup(
            setting: setting,
            frames: cluster,
            offSetPoint: const [],
          ),
        );
      }
      continue;
    }
    bool at(DbCapturedImage f) =>
        f.sensorTemp == null || (f.sensorTemp! - setPoint).abs() <= toleranceC;
    groups.add(
      CalibrationFrameGroup(
        setting: setting,
        frames: [...members.where(at)],
        offSetPoint: [...members.where((f) => !at(f))],
      ),
    );
  }
  return groups;
}

/// [frames] split where the sorted sensor readings jump; frames without a
/// reading join the largest part. Each part oldest first.
List<List<DbCapturedImage>> _temperatureClusters(List<DbCapturedImage> frames) {
  final known = frames.where((f) => f.sensorTemp != null).toList()
    ..sort((a, b) => a.sensorTemp!.compareTo(b.sensorTemp!));
  if (known.isEmpty) return [frames];
  final clusters = <List<DbCapturedImage>>[
    [known.first],
  ];
  for (final f in known.skip(1)) {
    if (f.sensorTemp! - clusters.last.last.sensorTemp! >
        darkroomTemperatureGapC) {
      clusters.add([f]);
    } else {
      clusters.last.add(f);
    }
  }
  clusters.sort((a, b) => b.length.compareTo(a.length));
  clusters.first.addAll(frames.where((f) => f.sensorTemp == null));
  for (final c in clusters) {
    c.sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
  }
  return clusters;
}

/// Why a dark or bias master's [header] shows frames that were not at its
/// set-point, or null when they were or the header cannot tell.
///
/// The master builder writes the mean sensor reading (`CCD-TEMP`), the
/// coldest and warmest (`CCDTMIN`, `CCDTMAX`) and the set-point
/// (`SET-TEMP`). A master is off its set-point when any reading it states is
/// more than [toleranceC] from it; a master written before the extremes were
/// recorded is judged by its mean. A master without a set-point (a camera
/// that does not cool) is never judged.
String? masterOffSetPoint(FrameHeader header, double toleranceC) {
  final setPoint = header.firstNumber(const ['SET-TEMP', 'SET_TEMP']);
  if (setPoint == null) return null;
  final mean = header.firstNumber(const ['CCD-TEMP', 'CCD_TEMP']);
  final coldest = header.number('CCDTMIN') ?? mean;
  final warmest = header.number('CCDTMAX') ?? mean;
  if (coldest == null || warmest == null) return null;
  final worst = [
    (coldest - setPoint).abs(),
    (warmest - setPoint).abs(),
  ].reduce((a, b) => a > b ? a : b);
  if (worst <= toleranceC) return null;
  final read = coldest == warmest
      ? '${_celsius(coldest)} on average'
      : '${_celsius(coldest)} to ${_celsius(warmest)}';
  return 'Built from frames that read $read at a ${_celsius(setPoint)} '
      'set-point, more than ${_celsius(toleranceC)} from it';
}

String _celsius(double value) {
  final rounded = (value * 10).round() / 10;
  final text = rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(1);
  return '$text °C';
}
