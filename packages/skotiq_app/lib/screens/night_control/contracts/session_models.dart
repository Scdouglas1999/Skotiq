// Center-column and right-panel view models.
part of '../night_control_contracts.dart';

// ---------------------------------------------------------------------------
// Center column
// ---------------------------------------------------------------------------

/// One thumbnail in the frame strip.
@immutable
class StripFrameVm {
  const StripFrameVm({
    required this.id,
    required this.capturedAt,
    required this.isNewest,
    this.frameNumber,
    this.filter,
    this.exposureSecs,
    this.hfr,
    this.starCount,
    this.accepted,
    this.exclusion,
    this.thumbnailPath,
    this.filePath,
  });

  /// The captured_images row id.
  final int id;

  /// The run's frame number ("#43"), when the file name or row carries it.
  final int? frameNumber;

  final DateTime capturedAt;
  final String? filter;
  final double? exposureSecs;
  final double? hfr;
  final int? starCount;

  /// True accepted, false rejected (dimmed, error-tone HFR), null when the
  /// frame was never graded.
  final bool? accepted;

  /// Why the run's frame watch took the frame out of the accepted set (off
  /// target, obstructed), or null.
  final FrameExclusionKind? exclusion;

  /// The thumbnail sidecar, when one was written.
  final String? thumbnailPath;

  /// The FITS file; null on a remote viewer without the file.
  final String? filePath;

  /// Ringed in the strip.
  final bool isNewest;

  @override
  bool operator ==(Object other) =>
      other is StripFrameVm &&
      other.id == id &&
      other.frameNumber == frameNumber &&
      other.capturedAt == capturedAt &&
      other.filter == filter &&
      other.exposureSecs == exposureSecs &&
      other.hfr == hfr &&
      other.starCount == starCount &&
      other.accepted == accepted &&
      other.exclusion == exclusion &&
      other.thumbnailPath == thumbnailPath &&
      other.filePath == filePath &&
      other.isNewest == isNewest;

  @override
  int get hashCode => Object.hash(
        id,
        frameNumber,
        capturedAt,
        filter,
        exposureSecs,
        hfr,
        starCount,
        accepted,
        exclusion,
        thumbnailPath,
        filePath,
        isNewest,
      );
}

enum SeriesMarkerKind { autofocus, dither, flip, reject }

/// A vertical event line on a session chart.
@immutable
class SeriesMarker {
  const SeriesMarker(this.t, this.kind);

  final DateTime t;
  final SeriesMarkerKind kind;

  @override
  bool operator ==(Object other) =>
      other is SeriesMarker && other.t == t && other.kind == kind;

  @override
  int get hashCode => Object.hash(t, kind);
}

/// Which quantity a series line is. The unit is fixed by the id, so the guide
/// lines are always pixels until PHD2's pixel scale is exposed (plan N4).
enum NightSeriesId {
  /// HFR in pixels.
  hfr,

  /// Detected stars, a count.
  stars,

  /// Guide error in pixels.
  guideRa,
  guideDec,

  /// Degrees Celsius.
  sensorTemp,
  focuserTemp,
  ambientTemp,

  /// Focuser steps.
  focuserPosition,
}

/// Line color role on a chart. Maps one to one onto the kit's
/// `SeriesChartTone`.
enum SeriesTone { primary, secondary, tertiary, muted, warning, error }

/// One line of a session chart.
@immutable
class SeriesLineVm {
  const SeriesLineVm({
    required this.id,
    required this.points,
    required this.tone,
    this.secondaryAxis = false,
    this.dashed = false,
    this.stepped = false,
  });

  final NightSeriesId id;

  /// Time ordered. Null-y points are gaps.
  final List<SeriesPoint> points;

  final SeriesTone tone;

  /// Drawn against the right axis (stars against HFR, focuser steps against
  /// temperature).
  final bool secondaryAxis;
  final bool dashed;

  /// Holds each value until the next one (focuser position).
  final bool stepped;

  @override
  bool operator ==(Object other) =>
      other is SeriesLineVm &&
      other.id == id &&
      listEquals(other.points, points) &&
      other.tone == tone &&
      other.secondaryAxis == secondaryAxis &&
      other.dashed == dashed &&
      other.stepped == stepped;

  @override
  int get hashCode => Object.hash(
        id,
        Object.hashAll(points),
        tone,
        secondaryAxis,
        dashed,
        stepped,
      );
}

/// One of the three session charts (HFR · stars, guiding, temperature ·
/// focus) with its legend values.
@immutable
class NightSeriesVm {
  const NightSeriesVm({
    required this.lines,
    this.markers = const <SeriesMarker>[],
    this.from,
    this.to,
    this.legend = const <MetricVm>[],
    this.sampleCount,
  });

  /// At most three.
  final List<SeriesLineVm> lines;
  final List<SeriesMarker> markers;

  /// The x range; null fits the data.
  final DateTime? from;
  final DateTime? to;

  /// Values under the chart ("HFR 2.13 (min 1.98)", "RA 0.31″", "SNR 42").
  final List<MetricVm> legend;

  /// "session, 87 frames": the frame count behind the chart, when per frame.
  final int? sampleCount;

  bool get isEmpty => lines.every((l) => l.points.isEmpty);

  @override
  bool operator ==(Object other) =>
      other is NightSeriesVm &&
      listEquals(other.lines, lines) &&
      listEquals(other.markers, markers) &&
      other.from == from &&
      other.to == to &&
      listEquals(other.legend, legend) &&
      other.sampleCount == sampleCount;

  @override
  int get hashCode => Object.hash(
        Object.hashAll(lines),
        Object.hashAll(markers),
        from,
        to,
        Object.hashAll(legend),
        sampleCount,
      );
}

// ---------------------------------------------------------------------------
// Right panel
// ---------------------------------------------------------------------------

/// One cell of a metric grid ("2.13 / HFR −0.04").
@immutable
class MetricVm {
  const MetricVm({
    required this.label,
    this.value,
    this.delta,
    this.deltaTone = MetricTone.neutral,
    this.valueTone = MetricTone.neutral,
  });

  final NightText label;

  /// Formatted with its unit ("3.4″", "639 GB"). Null renders a dash.
  final String? value;

  /// Signed and formatted ("−0.04"); null when there is nothing to compare.
  final String? delta;
  final MetricTone deltaTone;
  final MetricTone valueTone;

  @override
  bool operator ==(Object other) =>
      other is MetricVm &&
      other.label == label &&
      other.value == value &&
      other.delta == delta &&
      other.deltaTone == deltaTone &&
      other.valueTone == valueTone;

  @override
  int get hashCode => Object.hash(label, value, delta, deltaTone, valueTone);
}

/// Overview's "Last frame · #43" block.
@immutable
class NightLastFrameVm {
  const NightLastFrameVm({
    required this.metrics,
    this.frameNumber,
    this.histogram,
  });

  final int? frameNumber;

  /// HFR, FWHM, Ecc, Stars, Median, Bg σ, SNR, Solve, each with its delta
  /// against the night median when the night has that metric.
  final List<MetricVm> metrics;

  /// 256 bins; null hides the histogram.
  final List<int>? histogram;

  @override
  bool operator ==(Object other) =>
      other is NightLastFrameVm &&
      other.frameNumber == frameNumber &&
      listEquals(other.metrics, metrics) &&
      _nullableListEquals(other.histogram, histogram);

  @override
  int get hashCode => Object.hash(
        frameNumber,
        Object.hashAll(metrics),
        _nullableListHash(histogram),
      );
}

/// Overview's "Session · 87 frames · 4 h 21 m" block.
@immutable
class NightSessionVm {
  const NightSessionVm({
    required this.metrics,
    this.frameCount,
    this.elapsed,
  });

  final int? frameCount;
  final Duration? elapsed;

  /// Accepted, Rejected, Integration, Remaining, Autofocus, Dithers, Disk,
  /// Dropouts; a metric with no source is left out.
  final List<MetricVm> metrics;

  @override
  bool operator ==(Object other) =>
      other is NightSessionVm &&
      other.frameCount == frameCount &&
      other.elapsed == elapsed &&
      listEquals(other.metrics, metrics);

  @override
  int get hashCode => Object.hash(frameCount, elapsed, Object.hashAll(metrics));
}

enum EquipmentKind { camera, filterWheel, focuser, mount, guider, rotator }

/// The dot before an equipment row.
enum EquipmentStatus {
  /// Connected and doing what the run needs.
  ok,

  /// Connected but needs a look (guider not looping).
  attention,

  /// Errored or dropped.
  fault,

  /// Not configured in the profile, or not connected.
  absent,
}

/// One Equipment row ("Camera  −10.0 °C · 20% · g139 o21 · 1×1").
@immutable
class EquipmentRowVm {
  const EquipmentRowVm({
    required this.kind,
    required this.status,
    this.deviceName,
    this.details = const <NightText>[],
  });

  final EquipmentKind kind;
  final EquipmentStatus status;
  final String? deviceName;

  /// Joined with " · ". Empty with [EquipmentStatus.absent] renders "none".
  final List<NightText> details;

  @override
  bool operator ==(Object other) =>
      other is EquipmentRowVm &&
      other.kind == kind &&
      other.status == status &&
      other.deviceName == deviceName &&
      listEquals(other.details, details);

  @override
  int get hashCode =>
      Object.hash(kind, status, deviceName, Object.hashAll(details));
}

/// Where the Conditions block gets its numbers.
enum ConditionsSource {
  /// An ObservingConditions device.
  device,

  /// Only the Open-Meteo forecast; values are labeled "forecast".
  forecast,

  /// Nothing; the header reads "no weather source".
  none,
}

/// Overview's Conditions block.
@immutable
class NightConditionsVm {
  const NightConditionsVm({
    required this.source,
    this.safe,
    this.metrics = const <MetricVm>[],
    this.notes = const <NightText>[],
    this.skyOverride = NightSkyOverride.none,
  });

  final ConditionsSource source;

  /// The weather-safety verdict; null when no evaluator has one.
  final bool? safe;

  /// Seeing and SQM appear only when a device reports them.
  final List<MetricVm> metrics;

  /// What decides the verdict and what the run's own frames say, one line
  /// each.
  final List<NightText> notes;

  /// Whether the operator's "the sky is clear" override is offered or in
  /// force.
  final NightSkyOverride skyOverride;

  @override
  bool operator ==(Object other) =>
      other is NightConditionsVm &&
      other.source == source &&
      other.safe == safe &&
      listEquals(other.metrics, metrics) &&
      listEquals(other.notes, notes) &&
      other.skyOverride == skyOverride;

  @override
  int get hashCode => Object.hash(
        source,
        safe,
        Object.hashAll(metrics),
        Object.hashAll(notes),
        skyOverride,
      );
}

/// The operator's "the sky is clear" override on the Conditions block.
enum NightSkyOverride {
  /// Nothing to set aside.
  none,

  /// The weather verdict holds or warns and may be set aside.
  offer,

  /// The verdict is set aside; the override can be ended.
  active,
}

/// One Log line ("23:49  #43 Ha accepted · HFR 2.13").
@immutable
class NightLogEntryVm {
  const NightLogEntryVm({
    required this.at,
    required this.message,
    this.tone = MetricTone.neutral,
  });

  final DateTime at;
  final NightText message;

  /// [MetricTone.bad] for a rejection, [MetricTone.warning] for a lost star.
  final MetricTone tone;

  @override
  bool operator ==(Object other) =>
      other is NightLogEntryVm &&
      other.at == at &&
      other.message == message &&
      other.tone == tone;

  @override
  int get hashCode => Object.hash(at, message, tone);
}

/// The rows of "Before you start". The widget maps an id to its in-place
/// action (the guider's Loop) when [ChecklistItemVm.route] is null.
enum ChecklistItemId {
  camera,
  filterWheel,
  focuser,
  mount,
  guider,
  solver,
  disk,
  weather,
  dawn,
  site,
}

enum ChecklistItemState {
  /// Ready ("✓").
  ok,

  /// Will work but needs a look ("!").
  attention,

  /// Stops the run from starting.
  blocked,
}

/// One row of "Before you start".
@immutable
class ChecklistItemVm {
  const ChecklistItemVm({
    required this.id,
    required this.state,
    required this.title,
    this.detail,
    this.actionLabel,
    this.route,
  });

  final ChecklistItemId id;
  final ChecklistItemState state;
  final NightText title;

  /// "PHD2 connected, not looping". The dawn row states the configured
  /// safety policy exactly, including "off" and "no site".
  final NightText? detail;

  /// "Loop", "Add"; null shows no action.
  final NightText? actionLabel;

  /// Where the action goes, when it is a navigation.
  final String? route;

  @override
  bool operator ==(Object other) =>
      other is ChecklistItemVm &&
      other.id == id &&
      other.state == state &&
      other.title == title &&
      other.detail == detail &&
      other.actionLabel == actionLabel &&
      other.route == route;

  @override
  int get hashCode => Object.hash(id, state, title, detail, actionLabel, route);
}
