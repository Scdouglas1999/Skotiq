import '../../models/calibration/calibration_library_models.dart';
import '../../models/imaging/imaging_models.dart' show FrameType;
import 'calibration_frame_groups.dart';

/// How long the library's calibration stands in for new frames.
///
/// A bias is the sensor's read-out pattern at one gain, offset, binning, read
/// mode and temperature; it does not change with time, so a bias master is
/// valid indefinitely. Darks and dark flats carry the dark current and hot
/// pixels, which drift as a sensor ages, so they are valid for [darkValidFor]
/// after they were taken.
class CalibrationReuse {
  const CalibrationReuse({
    required this.darkValidFor,
    required this.toleranceC,
  });

  final Duration darkValidFor;

  /// The dark library's temperature tolerance: how far a master's set-point
  /// may be from the one needed.
  final double toleranceC;
}

/// What the library holds for one calibration set a plan would take.
sealed class LibraryCover {
  const LibraryCover();
}

/// A master of the setting is in the library; nothing needs taking.
final class CoveredByMaster extends LibraryCover {
  const CoveredByMaster(this.master);

  final CalibrationMasterRecord master;
}

/// Frames of the setting are in the library without a master: build the
/// master from them instead of taking new ones.
final class CoveredByFrames extends LibraryCover {
  const CoveredByFrames(this.group);

  final CalibrationFrameGroup group;
}

/// The set has to be taken; [why] says what the library holds that does not
/// do, or is null when it holds nothing of the setting.
final class NotCovered extends LibraryCover {
  const NotCovered([this.why]);

  final String? why;
}

/// The one rule for whether the calibration library already covers [need],
/// which every planner of darks, bias and dark flats asks before planning a
/// block.
///
/// A master or a frame group covers [need] when it agrees on what
/// [groupCalibrationFrames] keys a master by: type (a dark flat is a dark),
/// exposure (not for bias), gain, offset, binning, read mode (compared when
/// both state one; light rows record none) and the set-point, within
/// [CalibrationReuse.toleranceC]. A master or frames without a set-point
/// stand at their recorded temperature; one without any temperature covers
/// only a need without a set-point. A dark is used only within
/// [CalibrationReuse.darkValidFor] of when it was taken; a bias always.
///
/// A local master that was not built off its set-point covers, the newest
/// first. With no master, the newest group of at least [frameCount] frames at
/// the set-point covers: its master is built rather than the frames retaken.
LibraryCover libraryCover(
  CalibrationFrameSetting need, {
  required Iterable<CalibrationMasterRecord> masters,
  required Iterable<CalibrationFrameGroup> frameGroups,
  required int frameCount,
  required CalibrationReuse reuse,
  required DateTime now,
}) {
  final type = need.type == FrameType.darkFlat ? FrameType.dark : need.type;
  final expires = type == FrameType.bias
      ? null
      : now.subtract(reuse.darkValidFor);

  bool agrees({
    required FrameType otherType,
    required double? exposureSecs,
    required int? gain,
    required int? offset,
    required int binX,
    required int binY,
    required String? readMode,
    required double? temperatureC,
  }) {
    if (otherType != type) return false;
    if (type != FrameType.bias &&
        (exposureSecs == null ||
            (exposureSecs * 1000).round() !=
                (need.exposureSecs * 1000).round())) {
      return false;
    }
    if (gain != need.gain || offset != need.offset) return false;
    if (binX != need.binX || binY != need.binY) return false;
    if (readMode != null &&
        need.readMode != null &&
        readMode != need.readMode) {
      return false;
    }
    final setPoint = need.setPointC;
    if (setPoint == null) return true;
    return temperatureC != null &&
        (temperatureC - setPoint).abs() <= reuse.toleranceC;
  }

  final matching = [
    for (final m in masters)
      if (m.isMaster &&
          !m.isRemote &&
          m.offSetPoint == null &&
          agrees(
            otherType: switch (m.type) {
              CalibrationMasterType.bias => FrameType.bias,
              CalibrationMasterType.dark => FrameType.dark,
              _ => FrameType.light,
            },
            exposureSecs: m.exposureSeconds,
            gain: m.gain,
            offset: m.offset,
            binX: m.binX,
            binY: m.binY,
            readMode: m.readoutMode,
            temperatureC: m.setPointC ?? m.temperature,
          ))
        m,
  ];
  final current = _newest([
    for (final m in matching)
      if (expires == null || !m.createdAt.isBefore(expires)) m,
  ]);
  if (current != null) return CoveredByMaster(current);

  final groups = [
    for (final g in frameGroups)
      if (g.frames.isNotEmpty &&
          agrees(
            otherType: g.setting.type,
            exposureSecs: g.setting.exposureSecs,
            gain: g.setting.gain,
            offset: g.setting.offset,
            binX: g.setting.binX,
            binY: g.setting.binY,
            readMode: g.setting.readMode,
            temperatureC: g.temperatureC,
          ))
        g,
  ];
  DateTime newestFrame(CalibrationFrameGroup g) => g.frames.last.capturedAt;
  final usable = [
    for (final g in groups)
      if (expires == null || !newestFrame(g).isBefore(expires)) g,
  ]..sort((a, b) => newestFrame(b).compareTo(newestFrame(a)));
  final enough = usable.where((g) => g.frames.length >= frameCount).firstOrNull;
  if (enough != null) return CoveredByFrames(enough);

  final stale = _newest(matching);
  if (stale != null) {
    return NotCovered(
      'the newest library master, from ${calibrationDate(stale.createdAt)}, '
      'is older than the ${reuse.darkValidFor.inDays} days a dark stays valid',
    );
  }
  if (usable.isNotEmpty) {
    return NotCovered(
      'the library holds ${usable.first.frames.length} such frames without a '
      'master, fewer than the $frameCount planned',
    );
  }
  if (groups.isNotEmpty) {
    final newest = groups
        .map(newestFrame)
        .reduce((a, b) => b.isAfter(a) ? b : a);
    return NotCovered(
      'the library\'s frames, from ${calibrationDate(newest)}, '
      'are older than the ${reuse.darkValidFor.inDays} days a dark stays valid',
    );
  }
  return const NotCovered();
}

CalibrationMasterRecord? _newest(Iterable<CalibrationMasterRecord> records) =>
    records.isEmpty
    ? null
    : records.reduce((a, b) => b.createdAt.isAfter(a.createdAt) ? b : a);

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "Nov 15", the day a library master or frame was taken, as a plan says it.
String calibrationDate(DateTime t) => '${_months[t.month - 1]} ${t.day}';
