/// One operator-run autofocus: the camera and focuser it drives and the sweep
/// and measurement settings it runs with.
///
/// The backends take it whole (`DeviceBackend.autofocusStart`): the FFI
/// backend maps it to the bridge's `AutofocusConfigApi`, the network backend
/// sends [toWireJson] as the body of `POST /api/focuser/autofocus/start`, and
/// the host's handler builds it back from that body.
class AutofocusRequest {
  const AutofocusRequest({
    required this.deviceId,
    required this.cameraId,
    required this.exposureTime,
    required this.stepSize,
    required this.stepsOut,
    this.method = 'VCurve',
    this.binning = 1,
    this.gain,
    this.offset,
    this.curveFitting = 'Hyperbolic',
    this.numberOfAttempts = 1,
    this.exposuresPerPoint = 1,
    this.rSquaredThreshold = 0.7,
    this.outerCropRatio = 1.0,
    this.innerCropRatio = 0.0,
    this.useBrightestNStars = 10,
    this.focuserSettleTimeMs = 500,
    this.backlashCompMethod = 'Overshoot',
    this.backlashIn = 350,
    this.backlashOut = 0,
    this.measuredBacklashIn,
  });

  /// The focuser.
  final String deviceId;
  final String cameraId;
  final double exposureTime;
  final int stepSize;
  final int stepsOut;

  /// The star metric the operator chose (`Star HFR`, ...). The native sweep
  /// measures HFR whatever this says; [curveFitting] picks the fit.
  final String method;
  final int binning;
  final int? gain;
  final int? offset;

  /// The curve-fitting label from the Autofocus settings (`Hyperbolic`,
  /// `Parabolic`, `Trend Lines`).
  final String curveFitting;
  final int numberOfAttempts;
  final int exposuresPerPoint;
  final double rSquaredThreshold;
  final double outerCropRatio;
  final double innerCropRatio;
  final int useBrightestNStars;
  final int focuserSettleTimeMs;
  final String backlashCompMethod;
  final int backlashIn;
  final int backlashOut;

  /// Backlash this app measured on [deviceId], from its stored calibration,
  /// or null when it has never been calibrated. Never overrides
  /// [backlashIn]: a figure the operator typed outranks a measured one.
  final int? measuredBacklashIn;

  /// The body of `POST /api/focuser/autofocus/start`.
  Map<String, Object> toWireJson() => {
    'deviceId': deviceId,
    'cameraId': cameraId,
    'exposureTime': exposureTime,
    'stepSize': stepSize,
    'stepsOut': stepsOut,
    'method': method,
    'binning': binning,
    if (gain case final gain?) 'gain': gain,
    if (offset case final offset?) 'offset': offset,
    'curveFitting': curveFitting,
    'numberOfAttempts': numberOfAttempts,
    'exposuresPerPoint': exposuresPerPoint,
    'rSquaredThreshold': rSquaredThreshold,
    'outerCropRatio': outerCropRatio,
    'innerCropRatio': innerCropRatio,
    'useBrightestNStars': useBrightestNStars,
    'focuserSettleTimeMs': focuserSettleTimeMs,
    'backlashCompMethod': backlashCompMethod,
    'backlashIn': backlashIn,
    'backlashOut': backlashOut,
    if (measuredBacklashIn case final measured?) 'measuredBacklashIn': measured,
  };
}
