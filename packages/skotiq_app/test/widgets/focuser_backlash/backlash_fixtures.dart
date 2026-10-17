// Fixtures anchored to hardware truth.
//
// Every number here came off the owner's ZWO EAF on 2026-09-14: 105 steps near
// position 6620 at 14.5 °C, and 83 steps near 2506 from an earlier run. The
// two figures are the whole reason the UI must never print a bare number, so
// the regression is pinned to them rather than to round test values.
import 'package:skotiq_core/skotiq_core.dart';

const belowPoints6620 = <VCurvePoint>[
  VCurvePoint(position: 6480, hfr: 5.42),
  VCurvePoint(position: 6550, hfr: 3.61),
  VCurvePoint(position: 6620, hfr: 2.08),
  VCurvePoint(position: 6690, hfr: 3.74),
  VCurvePoint(position: 6760, hfr: 5.55),
];

const abovePoints6515 = <VCurvePoint>[
  VCurvePoint(position: 6760, hfr: 6.02),
  VCurvePoint(position: 6690, hfr: 4.31),
  VCurvePoint(position: 6620, hfr: 2.77),
  VCurvePoint(position: 6550, hfr: 2.19),
  VCurvePoint(position: 6480, hfr: 3.48),
];

final takenAt = DateTime.utc(2026, 9, 14, 21, 4);

/// 105 steps at position 6620, 14.5 °C — the measurement that explained the
/// donut stars.
FocuserBacklashCalibration measured105() => FocuserBacklashCalibration(
      steps: 105,
      vertexDifference: 105,
      measurable: true,
      resolutionLimitSteps: 15,
      below: const FocuserBacklashScan(
        approach: FocuserBacklashApproach.fromBelow,
        points: belowPoints6620,
        optimumPosition: 6620,
        rSquared: 0.987,
      ),
      above: const FocuserBacklashScan(
        approach: FocuserBacklashApproach.fromAbove,
        points: abovePoints6515,
        optimumPosition: 6515,
        rSquared: 0.971,
      ),
      measuredAtPosition: 6620,
      clearanceSteps: 250,
      reversalBudgetSteps: 560,
      reversalBudgetAtVertexSteps: 320,
      confidence: FocuserBacklashConfidence.high,
      confidenceReason:
          'Both fits are tight and the difference is seven times the '
          'resolution limit.',
      takenAt: takenAt,
      temperatureCelsius: 14.5,
      appVersion: '7.0.0+28',
      focuserDeviceId: 'ZWO EAF',
    );

/// 83 steps at position 2506 — the same focuser, lower down its travel. Proof
/// that a figure belongs to a position.
FocuserBacklashCalibration measured83() => FocuserBacklashCalibration(
      steps: 83,
      vertexDifference: 83,
      measurable: true,
      resolutionLimitSteps: 15,
      below: const FocuserBacklashScan(
        approach: FocuserBacklashApproach.fromBelow,
        points: [
          VCurvePoint(position: 2400, hfr: 4.9),
          VCurvePoint(position: 2506, hfr: 2.2),
          VCurvePoint(position: 2600, hfr: 4.6),
        ],
        optimumPosition: 2506,
        rSquared: 0.964,
      ),
      above: const FocuserBacklashScan(
        approach: FocuserBacklashApproach.fromAbove,
        points: [
          VCurvePoint(position: 2600, hfr: 5.1),
          VCurvePoint(position: 2506, hfr: 2.6),
          VCurvePoint(position: 2400, hfr: 3.2),
        ],
        optimumPosition: 2423,
        rSquared: 0.951,
      ),
      measuredAtPosition: 2506,
      clearanceSteps: 250,
      reversalBudgetSteps: 480,
      reversalBudgetAtVertexSteps: 280,
      confidence: FocuserBacklashConfidence.moderate,
      confidenceReason:
          'The from-above fit is noisier than the from-below one; a repeat '
          'would tighten this.',
      takenAt: DateTime.utc(2026, 9, 13, 23, 12),
      temperatureCelsius: 11.2,
      appVersion: '7.0.0+27',
      focuserDeviceId: 'ZWO EAF',
    );

/// A clean focuser: the two scans agreed to within their own resolution. A
/// successful measurement, not a failure.
FocuserBacklashCalibration noMeasurableBacklash() => FocuserBacklashCalibration(
      steps: 0,
      vertexDifference: 4,
      measurable: false,
      resolutionLimitSteps: 15,
      below: const FocuserBacklashScan(
        approach: FocuserBacklashApproach.fromBelow,
        points: belowPoints6620,
        optimumPosition: 6620,
        rSquared: 0.991,
      ),
      above: const FocuserBacklashScan(
        approach: FocuserBacklashApproach.fromAbove,
        points: abovePoints6515,
        optimumPosition: 6616,
        rSquared: 0.985,
      ),
      measuredAtPosition: 6620,
      clearanceSteps: 250,
      reversalBudgetSteps: 560,
      reversalBudgetAtVertexSteps: 320,
      confidence: FocuserBacklashConfidence.high,
      confidenceReason:
          'Both fits are tight and the two vertices landed four steps apart.',
      takenAt: takenAt,
      temperatureCelsius: 14.5,
      appVersion: '7.0.0+28',
      focuserDeviceId: 'ZWO EAF',
    );

FocuserBacklashResult measuredResult(FocuserBacklashCalibration calibration) =>
    FocuserBacklashResult(
      kind: FocuserBacklashOutcomeKind.measured,
      calibration: calibration,
    );

FocuserBacklashResult noBacklashResult() => FocuserBacklashResult(
      kind: FocuserBacklashOutcomeKind.noMeasurableBacklash,
      calibration: noMeasurableBacklash(),
    );

FocuserBacklashResult refusedResult({
  required String code,
  required String message,
  required String remedy,
}) =>
    FocuserBacklashResult(
      kind: FocuserBacklashOutcomeKind.refused,
      refusal: FocuserBacklashRefusal(
        code: code,
        message: message,
        remedy: remedy,
      ),
    );

const plan9Points = FocuserBacklashCalibrationPlan(
  pointsPerScan: 9,
  totalExposures: 18,
  scanLowPosition: 6340,
  scanHighPosition: 6900,
  travelLowPosition: 6090,
  travelHighPosition: 7150,
  reversalBudgetSteps: 560,
  reversalBudgetAtVertexSteps: 320,
  estimatedDuration: Duration(minutes: 4, seconds: 30),
);

FocuserBacklashCalibrationRecord record105() =>
    FocuserBacklashCalibrationRecord(
      steps: 105,
      measurable: true,
      resolutionLimitSteps: 15,
      measuredAtPosition: 6620,
      temperatureCelsius: 14.5,
      measuredAt: takenAt,
      confidence: FocuserBacklashConfidence.high,
      confidenceReason: 'Both fits are tight.',
      appVersion: '7.0.0+28',
    );
