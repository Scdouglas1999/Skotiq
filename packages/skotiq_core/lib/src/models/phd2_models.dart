import 'dart:typed_data';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'phd2_models.freezed.dart';
part 'phd2_models.g.dart';

/// The `AppState` PHD2 itself reports, as carried on `phd2StateProvider`.
///
/// Distinct from [Phd2GuidingState], which folds "not connected" into the same
/// enum for the guiding screen's state machine.
enum Phd2State {
  stopped,
  selected,
  calibrating,
  guiding,
  looping,
  settling,
  paused,
  lostLock,

  /// PHD2 reported a state string we do not recognise (new/unmapped AppState),
  /// or the process is in an indeterminate phase. Distinct from [stopped] so
  /// the UI never falsely offers "Start" over a possibly-live process — an
  /// unknown state is treated as potentially active (Stop is offered, Start is
  /// not). See `Phd2Controller._updateStateFromString`.
  unknown,
}

/// PHD2 guiding state — canonical home for the guiding-screen state machine.
/// `stopped` matches `Phd2State.stopped`: connected to PHD2 but not actively
/// looping/calibrating/guiding.
enum Phd2GuidingState {
  disconnected,
  stopped,
  calibrating,
  guiding,
  looping,
  paused,
  settling,
  lostLock,

  /// PHD2 is connected but reported a state we could not classify. Treated as
  /// possibly-live: the controls offer Stop, never an enabled Start. Mirrors
  /// [Phd2State.unknown].
  unknown,
}

/// Extension for Phd2GuidingState display
extension Phd2GuidingStateExtension on Phd2GuidingState {
  String get displayName {
    switch (this) {
      case Phd2GuidingState.disconnected:
        return 'Disconnected';
      case Phd2GuidingState.stopped:
        return 'Stopped';
      case Phd2GuidingState.calibrating:
        return 'Calibrating';
      case Phd2GuidingState.guiding:
        return 'Guiding';
      case Phd2GuidingState.looping:
        return 'Looping';
      case Phd2GuidingState.paused:
        return 'Paused';
      case Phd2GuidingState.settling:
        return 'Settling';
      case Phd2GuidingState.lostLock:
        return 'Lost Lock';
      case Phd2GuidingState.unknown:
        return 'Unknown';
    }
  }

  bool get isActive =>
      this == Phd2GuidingState.guiding ||
      this == Phd2GuidingState.calibrating ||
      this == Phd2GuidingState.looping ||
      this == Phd2GuidingState.settling;
}

/// Single source of truth for what a guider command surface may offer in each
/// state. Both the desktop and mobile guiding controls (which share
/// `GuideControlsPanel`) drive their enable/label logic from these getters so
/// the two surfaces can never disagree about, e.g., whether Start is legal.
///
/// Design rules:
///   * Start is legal ONLY from a truly idle-but-connected state ([stopped]).
///     Paused / calibrating / settling / looping / lost-lock / unknown are all
///     live or transitional and must NEVER offer an enabled Start.
///   * Stop is legal from every live/transitional/uncertain state — it is the
///     safe direction and must work from Paused and Lost Lock too.
///   * unknown is treated as possibly-live: Stop yes, Start no.
extension Phd2GuidingCapabilities on Phd2GuidingState {
  /// A guiding session (or looping) is running or transitioning.
  bool get isBusyPhase =>
      this == Phd2GuidingState.guiding ||
      this == Phd2GuidingState.calibrating ||
      this == Phd2GuidingState.looping ||
      this == Phd2GuidingState.settling ||
      this == Phd2GuidingState.paused ||
      this == Phd2GuidingState.lostLock ||
      this == Phd2GuidingState.unknown;

  /// Calibration or settle is in progress — a hand-off phase where issuing new
  /// commands (other than Stop) is unsafe.
  bool get isTransitional =>
      this == Phd2GuidingState.calibrating || this == Phd2GuidingState.settling;

  bool get canStart => this == Phd2GuidingState.stopped;

  bool get canStop => isBusyPhase;

  bool get canPause => this == Phd2GuidingState.guiding;

  bool get canResume => this == Phd2GuidingState.paused;

  bool get canDither => this == Phd2GuidingState.guiding;

  bool get canLoop => this == Phd2GuidingState.stopped;
}

/// Thrown when a guiding command is rejected because another command is
/// already in flight. The per-controller command gate raises this so a rapid
/// double-tap (or a UI command racing a programmatic one) resolves to exactly
/// one native call plus a deterministic, surfaced rejection — never two
/// conflicting hardware commands.
class GuidingCommandBusyException implements Exception {
  const GuidingCommandBusyException(this.command);

  /// The command that was rejected (e.g. 'start', 'dither').
  final String command;

  @override
  String toString() =>
      'A guiding command is already in progress; "$command" was ignored. '
      'Wait for the current operation to finish, then try again.';
}

/// Star image data from PHD2's get_star_image API
@freezed
abstract class Phd2StarImage with _$Phd2StarImage {
  const factory Phd2StarImage({
    /// Frame number
    required int frame,

    /// Image width in pixels
    required int width,

    /// Image height in pixels
    required int height,

    /// Star centroid X position within the subframe
    required double starX,

    /// Star centroid Y position within the subframe
    required double starY,

    /// Raw pixel data (16-bit grayscale, row-major order)
    /// Note: This is stored as Uint8List but represents 16-bit values
    @Uint8ListConverter() required Uint8List pixels,
  }) = _Phd2StarImage;

  factory Phd2StarImage.fromJson(Map<String, dynamic> json) =>
      _$Phd2StarImageFromJson(json);

  /// Create an empty star image model
  factory Phd2StarImage.empty() => Phd2StarImage(
    frame: 0,
    width: 0,
    height: 0,
    starX: 0,
    starY: 0,
    pixels: Uint8List(0),
  );
}

/// PHD2 Brain algorithm parameter
@freezed
abstract class Phd2AlgoParam with _$Phd2AlgoParam {
  const factory Phd2AlgoParam({
    /// Parameter name (e.g., "Aggressiveness", "Hysteresis")
    required String name,

    /// Parameter value
    required double value,
  }) = _Phd2AlgoParam;

  factory Phd2AlgoParam.fromJson(Map<String, dynamic> json) =>
      _$Phd2AlgoParamFromJson(json);
}

/// Collection of PHD2 Brain parameters for both axes
@freezed
abstract class Phd2BrainParams with _$Phd2BrainParams {
  const factory Phd2BrainParams({
    /// RA axis parameter names
    required List<String> raParamNames,

    /// Dec axis parameter names
    required List<String> decParamNames,

    /// RA axis parameters (name -> value)
    required Map<String, double> raParams,

    /// Dec axis parameters (name -> value)
    required Map<String, double> decParams,
  }) = _Phd2BrainParams;

  factory Phd2BrainParams.fromJson(Map<String, dynamic> json) =>
      _$Phd2BrainParamsFromJson(json);

  /// Create empty brain params
  factory Phd2BrainParams.empty() => const Phd2BrainParams(
    raParamNames: [],
    decParamNames: [],
    raParams: {},
    decParams: {},
  );
}

/// Guide error point for target display history
///
/// Same unit contract as [Phd2GuideStats]: these come from the raw `GuideStep`
/// residuals, i.e. **guide-camera pixels**, and are converted for display only
/// where a pixel scale is known.
@freezed
abstract class GuideErrorPoint with _$GuideErrorPoint {
  const factory GuideErrorPoint({
    /// RA error (guide-camera pixels; see class docs)
    required double raError,

    /// Dec error (guide-camera pixels; see class docs)
    required double decError,

    /// Timestamp when this error was recorded
    required DateTime timestamp,
  }) = _GuideErrorPoint;

  factory GuideErrorPoint.fromJson(Map<String, dynamic> json) =>
      _$GuideErrorPointFromJson(json);
}

/// PHD2 guide statistics snapshot
///
/// UNITS — read before formatting any of these values:
/// `GuideStatsNotifier` computes the RMS/peak fields from the raw per-step
/// residuals carried on `GuideStep` events (`RADistanceRaw`/`DECDistanceRaw`
/// from PHD2, `ra_raw`/`dec_raw` from the built-in guider). Both report those
/// in **guide-camera pixels**, so these fields are pixels, NOT arcseconds —
/// they only become arcseconds after multiplying by [pixelScale], and
/// [pixelScale] is 0 (unknown) unless something populates it.
///
/// Do not relabel these as arcseconds to make a display read consistently: at
/// a 0.78"/px guide scale a 0.53 px residual is 0.41", so the suffix change
/// alone overstates the error by ~28%. Either convert with a real [pixelScale]
/// or say px.
@freezed
abstract class Phd2GuideStats with _$Phd2GuideStats {
  const factory Phd2GuideStats({
    /// RMS error in RA (guide-camera pixels; see class docs)
    @Default(0.0) double rmsRa,

    /// RMS error in Dec (guide-camera pixels; see class docs)
    @Default(0.0) double rmsDec,

    /// Total RMS error (guide-camera pixels; see class docs)
    @Default(0.0) double rmsTotal,

    /// Peak RA error (guide-camera pixels; see class docs)
    @Default(0.0) double peakRa,

    /// Peak Dec error (guide-camera pixels; see class docs)
    @Default(0.0) double peakDec,

    /// SNR of guide star
    @Default(0.0) double snr,

    /// Star mass (brightness)
    @Default(0.0) double starMass,

    /// HFD (Half Flux Diameter)
    @Default(0.0) double hfd,

    /// Guide star X position
    @Default(0.0) double starX,

    /// Guide star Y position
    @Default(0.0) double starY,

    /// Pixel scale (arcsec/pixel)
    @Default(0.0) double pixelScale,

    /// Number of guide STEPS measured — corrections, not exposures.
    ///
    /// Zero while Loop Exposures is running (looping takes no corrections), so
    /// this is also the gate the RMS/Peak readouts use to decide whether they
    /// have anything to report. See [loopFrameCount] for the loop's own count.
    @Default(0) int frameCount,

    /// Number of frames captured in the CURRENT Loop Exposures run.
    ///
    /// Looping exists so the operator can judge star quality and exposure
    /// length before picking a star, and `Frame Count` read `0` for the whole
    /// loop because [frameCount] counts guide steps and a loop takes none. A
    /// loop frame is not a guide correction, so it gets its own count, and each
    /// new loop starts that count again — the number answers "how many frames
    /// has THIS loop taken", not "how many since the guider connected".
    @Default(0) int loopFrameCount,
  }) = _Phd2GuideStats;

  factory Phd2GuideStats.fromJson(Map<String, dynamic> json) =>
      _$Phd2GuideStatsFromJson(json);
}

/// PHD2 calibration data
@freezed
abstract class Phd2CalibrationData with _$Phd2CalibrationData {
  const factory Phd2CalibrationData({
    /// Whether calibration is complete
    @Default(false) bool isCalibrated,

    /// Calibration timestamp
    DateTime? calibratedAt,

    /// RA calibration rate (pixels/ms)
    double? raRate,

    /// Dec calibration rate (pixels/ms)
    double? decRate,

    /// Camera rotation angle (degrees)
    double? rotationAngle,

    /// Dec guide mode ("Auto", "North", "South", "Off")
    String? decGuideMode,
  }) = _Phd2CalibrationData;

  factory Phd2CalibrationData.fromJson(Map<String, dynamic> json) =>
      _$Phd2CalibrationDataFromJson(json);
}

/// Custom JSON converter for Uint8List
class Uint8ListConverter implements JsonConverter<Uint8List, List<int>> {
  const Uint8ListConverter();

  @override
  Uint8List fromJson(List<int> json) => Uint8List.fromList(json);

  @override
  List<int> toJson(Uint8List object) => object.toList();
}
