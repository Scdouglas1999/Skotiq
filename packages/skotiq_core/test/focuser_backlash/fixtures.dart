import 'dart:convert';

import 'package:skotiq_core/src/database/daos/settings_dao.dart';
import 'package:skotiq_core/src/models/focuser_backlash_calibration.dart';

/// A stored record matching the owner's real 2026-09-14 measurement.
FocuserBacklashCalibrationRecord recordFor({
  int steps = 105,
  bool measurable = true,
  int position = 6620,
  double? temperature = 14.5,
  DateTime? measuredAt,
  double resolutionLimit = 15.0,
  FocuserBacklashConfidence confidence = FocuserBacklashConfidence.high,
}) => FocuserBacklashCalibrationRecord(
  steps: steps,
  measurable: measurable,
  resolutionLimitSteps: resolutionLimit,
  measuredAtPosition: position,
  temperatureCelsius: temperature,
  measuredAt: measuredAt ?? DateTime.utc(2026, 9, 14, 23, 11, 4),
  confidence: confidence,
  confidenceReason: 'Both directions fitted well.',
  appVersion: '7.0.0+27',
);

/// The measurement the owner's ZWO EAF actually produced on 2026-09-14 near
/// position 6600: from-below optimum 6620, from-above 6515, 105 steps apart.
Map<String, dynamic> measuredCalibrationJson({
  int steps = 105,
  int vertexDifference = 105,
  bool measurable = true,
  double resolutionLimit = 15.0,
  int belowOptimum = 6620,
  int aboveOptimum = 6515,
  int measuredAtPosition = 6620,
  String focuserDeviceId = 'zwo-eaf-1',
  String takenAt = '2026-09-14T23:11:04Z',
  double? temperature = 14.5,
  String appVersion = '7.0.0+27',
}) => {
  'steps': steps,
  'vertex_difference': vertexDifference,
  'measurable': measurable,
  'resolution_limit_steps': resolutionLimit,
  'below': {
    'approach': 'from_below',
    'points': [
      {'position': 6440, 'hfr': 11.2, 'fwhm': null, 'star_count': 40},
      {'position': 6620, 'hfr': 3.0, 'fwhm': null, 'star_count': 44},
      {'position': 6800, 'hfr': 10.9, 'fwhm': null, 'star_count': 38},
    ],
    'optimum_position': belowOptimum,
    'r_squared': 0.99,
    'method': 'Quadratic',
  },
  'above': {
    'approach': 'from_above',
    'points': [
      {'position': 6800, 'hfr': 11.0, 'fwhm': null, 'star_count': 37},
      {'position': 6515, 'hfr': 3.1, 'fwhm': null, 'star_count': 45},
      {'position': 6440, 'hfr': 9.8, 'fwhm': null, 'star_count': 41},
    ],
    'optimum_position': aboveOptimum,
    'r_squared': 0.98,
    'method': 'Quadratic',
  },
  'measured_at_position': measuredAtPosition,
  'clearance_steps': 400,
  // clearance 400 + 12 gaps of 30 = 760 reversed across the whole scan, 580
  // by the middle of it where the vertex is set.
  'reversal_budget_steps': 760,
  'reversal_budget_at_vertex_steps': 580,
  'confidence': 'high',
  'confidence_reason':
      'Both directions fitted well (poorer of the two R² 0.980) and the 105 '
      'steps between their optima is 7.0x what these scans can resolve.',
  'context': {
    'focuser_device_id': focuserDeviceId,
    'taken_at': takenAt,
    'temperature_celsius': temperature,
    'app_version': appVersion,
  },
};

String measuredOutcomeJson({
  int steps = 105,
  int measuredAtPosition = 6620,
  String focuserDeviceId = 'zwo-eaf-1',
  String takenAt = '2026-09-14T23:11:04Z',
  double? temperature = 14.5,
}) => jsonEncode({
  'outcome': 'measured',
  'calibration': measuredCalibrationJson(
    steps: steps,
    vertexDifference: steps,
    measuredAtPosition: measuredAtPosition,
    focuserDeviceId: focuserDeviceId,
    takenAt: takenAt,
    temperature: temperature,
  ),
});

/// The two optima landed 4 steps apart with a 15-step resolution floor: no
/// backlash worth compensating, which is a result and not a failure.
String noMeasurableBacklashOutcomeJson() => jsonEncode({
  'outcome': 'no_measurable_backlash',
  'calibration': measuredCalibrationJson(
    steps: 0,
    vertexDifference: 4,
    measurable: false,
    belowOptimum: 6519,
    aboveOptimum: 6515,
    measuredAtPosition: 6519,
  ),
});

String refusedOutcomeJson({
  required Map<String, dynamic> refusal,
  required String message,
  required String remedy,
}) => jsonEncode({
  'outcome': 'refused',
  'refusal': refusal,
  'message': message,
  'remedy': remedy,
});
