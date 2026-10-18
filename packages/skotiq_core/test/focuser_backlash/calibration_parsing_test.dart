import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/focuser_backlash_calibration.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';

import 'fixtures.dart';

void main() {
  group('a measured outcome', () {
    test('carries the figure and everything it was derived from', () {
      final result = FocuserBacklashResult.tryParse(measuredOutcomeJson());

      expect(result, isNotNull);
      expect(result!.kind, FocuserBacklashOutcomeKind.measured);
      expect(result.refusal, isNull);
      expect(result.hasFigure, isTrue);

      final calibration = result.calibration!;
      expect(calibration.steps, 105);
      expect(calibration.vertexDifference, 105);
      expect(calibration.measurable, isTrue);
      expect(calibration.resolutionLimitSteps, 15.0);
      expect(calibration.measuredAtPosition, 6620);
      expect(calibration.clearanceSteps, 400);
      expect(calibration.reversalBudgetSteps, 760);
      expect(calibration.reversalBudgetAtVertexSteps, 580);
      expect(calibration.confidence, FocuserBacklashConfidence.high);
      expect(calibration.confidenceReason, contains('7.0x'));
      expect(calibration.focuserDeviceId, 'zwo-eaf-1');
      expect(calibration.temperatureCelsius, 14.5);
      expect(calibration.appVersion, '7.0.0+27');
      expect(calibration.takenAt.isUtc, isTrue);
      expect(calibration.takenAt, DateTime.utc(2026, 9, 14, 23, 11, 4));
    });

    test('keeps the two scans apart, each with its own vertex', () {
      final calibration = FocuserBacklashResult.tryParse(
        measuredOutcomeJson(),
      )!.calibration!;

      expect(calibration.below.approach, FocuserBacklashApproach.fromBelow);
      expect(calibration.below.optimumPosition, 6620);
      expect(calibration.below.rSquared, 0.99);
      expect(calibration.above.approach, FocuserBacklashApproach.fromAbove);
      expect(calibration.above.optimumPosition, 6515);
      expect(calibration.above.rSquared, 0.98);
      expect(
        calibration.below.optimumPosition - calibration.above.optimumPosition,
        calibration.steps,
      );
      expect(calibration.below.points.map((p) => p.position), [
        6440,
        6620,
        6800,
      ]);
      expect(calibration.below.points.first.hfr, 11.2);
    });

    test('a temperature the driver did not report stays absent', () {
      final calibration = FocuserBacklashResult.tryParse(
        measuredOutcomeJson(temperature: null),
      )!.calibration!;

      expect(calibration.temperatureCelsius, isNull);
    });
  });

  group('no measurable backlash', () {
    test('is not a refusal and is not nudged up to a positive figure', () {
      final result = FocuserBacklashResult.tryParse(
        noMeasurableBacklashOutcomeJson(),
      );

      expect(result, isNotNull);
      expect(result!.kind, FocuserBacklashOutcomeKind.noMeasurableBacklash);
      expect(result.refusal, isNull);
      expect(result.hasFigure, isFalse);
      expect(result.calibration!.steps, 0);
      expect(result.calibration!.measurable, isFalse);
      // The raw difference is kept: it is the measurement, while 0 steps is
      // the conclusion drawn from it.
      expect(result.calibration!.vertexDifference, 4);
      expect(result.calibration!.resolutionLimitSteps, 15.0);
    });

    test('still saves as a record, so it is not asked again', () {
      final calibration = FocuserBacklashResult.tryParse(
        noMeasurableBacklashOutcomeJson(),
      )!.calibration!;
      final record = calibration.toRecord();

      expect(record.steps, 0);
      expect(record.measurable, isFalse);
      expect(record.isUsable, isTrue);
      expect(record.measuredAtPosition, 6519);
    });
  });

  group('refusals', () {
    /// Every variant of the native `CalibrationRefusal`, with the fields it
    /// actually serialises. A refusal Dart cannot read is a refusal the
    /// operator never sees.
    final refusalsByCode = <String, Map<String, dynamic>>{
      'scan_abandoned_for_stars': {
        'code': 'scan_abandoned_for_stars',
        'direction': 'from_below',
        'low_points': 5,
        'total_points': 13,
        'star_floor': 10,
      },
      'not_enough_points': {
        'code': 'not_enough_points',
        'direction': 'from_above',
        'points': 2,
        'required': 5,
      },
      'too_few_stars_at_focus': {
        'code': 'too_few_stars_at_focus',
        'direction': 'from_below',
        'position': 6620,
        'stars': 3,
        'required': 10,
      },
      'too_few_measurable_points': {
        'code': 'too_few_measurable_points',
        'direction': 'from_above',
        'measurable': 3,
        'required': 5,
        'star_floor': 10,
      },
      'poor_fit': {
        'code': 'poor_fit',
        'direction': 'from_above',
        'r_squared': 0.41,
        'required': 0.9,
      },
      'vertex_outside_scan': {
        'code': 'vertex_outside_scan',
        'direction': 'from_below',
        'vertex': 6900,
        'span': [6440, 6800],
      },
      'exceeds_scan_range': {
        'code': 'exceeds_scan_range',
        'vertex_difference': 500,
        'scan_span': 360,
      },
      'exceeds_reversal_budget': {
        'code': 'exceeds_reversal_budget',
        'vertex_difference': 900,
        'reversal_budget_steps': 760,
        'clearance_steps': 400,
      },
      'negative_beyond_resolution': {
        'code': 'negative_beyond_resolution',
        'vertex_difference': -320,
        'resolution_limit_steps': 15.0,
      },
    };

    for (final entry in refusalsByCode.entries) {
      test('${entry.key} keeps native\'s own message and remedy', () {
        final message = 'Refusal message for ${entry.key}';
        final remedy = 'Remedy for ${entry.key}';
        final result = FocuserBacklashResult.tryParse(
          refusedOutcomeJson(
            refusal: entry.value,
            message: message,
            remedy: remedy,
          ),
        );

        expect(result, isNotNull);
        expect(result!.kind, FocuserBacklashOutcomeKind.refused);
        expect(result.calibration, isNull);
        expect(result.hasFigure, isFalse);
        expect(result.refusal!.code, entry.key);
        // Verbatim: rewording these in Dart would give the product two
        // explanations of one refusal.
        expect(result.refusal!.message, message);
        expect(result.refusal!.remedy, remedy);
      });
    }

    test('all nine native codes are covered', () {
      expect(refusalsByCode, hasLength(9));
    });
  });

  group('malformed payloads return null rather than throwing', () {
    final cases = <String, String>{
      'not JSON at all': 'this is not json',
      'a bare string': '"measured"',
      'an unknown outcome tag': jsonEncode({'outcome': 'exploded'}),
      'no outcome tag': jsonEncode({'calibration': {}}),
      'measured with no calibration': jsonEncode({'outcome': 'measured'}),
      'a truncated calibration': jsonEncode({
        'outcome': 'measured',
        'calibration': {'steps': 105},
      }),
      'a refusal with no remedy': jsonEncode({
        'outcome': 'refused',
        'refusal': {'code': 'poor_fit'},
        'message': 'poor fit',
      }),
      'a refusal with no code': jsonEncode({
        'outcome': 'refused',
        'refusal': {'direction': 'from_above'},
        'message': 'poor fit',
        'remedy': 'try again',
      }),
      'an unparseable timestamp': jsonEncode({
        'outcome': 'measured',
        'calibration': {
          ...measuredCalibrationJson(),
          'context': {
            'focuser_device_id': 'zwo-eaf-1',
            'taken_at': 'last Tuesday',
            'temperature_celsius': 14.5,
            'app_version': '7.0.0+27',
          },
        },
      }),
      'a confidence value we do not know': jsonEncode({
        'outcome': 'measured',
        'calibration': {...measuredCalibrationJson(), 'confidence': 'perfect'},
      }),
    };

    for (final entry in cases.entries) {
      test(entry.key, () {
        expect(FocuserBacklashResult.tryParse(entry.value), isNull);
      });
    }
  });

  group('the run plan', () {
    test('parses the cost of a run, duration included', () {
      final plan = FocuserBacklashCalibrationPlan.tryParse(
        jsonEncode({
          'points_per_scan': 13,
          'total_exposures': 52,
          'scan_low_position': 6440,
          'scan_high_position': 6800,
          'travel_low_position': 6040,
          'travel_high_position': 7200,
          'estimated_duration_secs': 330.0,
          'reversal_budget_steps': 760,
          'reversal_budget_at_vertex_steps': 580,
        }),
      );

      expect(plan, isNotNull);
      expect(plan!.pointsPerScan, 13);
      expect(plan.totalExposures, 52);
      expect(plan.scanLowPosition, 6440);
      expect(plan.scanHighPosition, 6800);
      // The travel is wider than the scan by the run-up either side — the
      // number that matters to anyone near a travel limit.
      expect(plan.travelLowPosition, 6040);
      expect(plan.travelHighPosition, 7200);
      expect(plan.estimatedDuration, const Duration(seconds: 330));
      // The ceiling on anything this run can report: a measured dead band
      // wider than the scan ever reversed the drive train is not a dead band.
      expect(plan.reversalBudgetSteps, 760);
      expect(plan.reversalBudgetAtVertexSteps, 580);
    });

    test('refuses a plan it cannot read', () {
      expect(FocuserBacklashCalibrationPlan.tryParse('{}'), isNull);
      expect(FocuserBacklashCalibrationPlan.tryParse('nonsense'), isNull);
      expect(
        FocuserBacklashCalibrationPlan.tryParse(
          jsonEncode({
            'points_per_scan': 13,
            'total_exposures': 52,
            'scan_low_position': 6440,
            'scan_high_position': 6800,
            'travel_low_position': 6040,
            'travel_high_position': 7200,
            'estimated_duration_secs': 'a few minutes',
            'reversal_budget_steps': 760,
            'reversal_budget_at_vertex_steps': 580,
          }),
        ),
        isNull,
      );
    });
  });

  group('the config sent to native', () {
    test('a null centre means "wherever the focuser is now"', () {
      final config =
          jsonDecode(
                focuserBacklashCalibrationConfigJson(
                  settings:
                      FocuserBacklashCalibrationSettings.seededFromAutofocus(
                        const AutofocusSettings(),
                      ),
                  appVersion: '7.0.0+27',
                ),
              )
              as Map<String, dynamic>;

      expect(config['center_position'], isNull);
      expect(config['app_version'], '7.0.0+27');
      // The operator's whole tuning goes on the wire under the snake_case
      // keys the native struct deserialises — nothing falls back to a
      // native default the operator never saw.
      expect(
        config.keys,
        unorderedEquals([
          'center_position',
          'app_version',
          'step_size',
          'steps_out',
          'clearance_steps',
          'exposure_duration',
          'exposures_per_point',
          'binning',
          'gain',
          'offset',
          'min_star_count',
          'r_squared_threshold',
          'outer_crop_ratio',
          'inner_crop_ratio',
          'use_brightest_n_stars',
          'focuser_settle_time_ms',
          'method',
          'outlier_rejection_sigma',
          'max_duration_secs',
        ]),
      );
    });

    test('an explicit centre is passed through', () {
      final config =
          jsonDecode(
                focuserBacklashCalibrationConfigJson(
                  settings:
                      FocuserBacklashCalibrationSettings.seededFromAutofocus(
                        const AutofocusSettings(),
                      ),
                  centerPosition: 6600,
                  appVersion: '7.0.0+27',
                ),
              )
              as Map<String, dynamic>;

      expect(config['center_position'], 6600);
    });

    test('every settings field is sent under its native key', () {
      const settings = FocuserBacklashCalibrationSettings(
        stepSize: 30,
        stepsOut: 6,
        clearanceSteps: 90,
        exposureDurationSecs: 2.5,
        exposuresPerPoint: 2,
        binning: 2,
        gain: 100,
        offset: 50,
        minStarCount: 12,
        rSquaredThreshold: 0.9,
        outerCropRatio: 0.9,
        innerCropRatio: 0.1,
        useBrightestNStars: 15,
        focuserSettleTimeMs: 800,
        method: 'Hyperbolic',
        outlierRejectionSigma: 2.5,
        maxDurationSecs: 900,
      );
      final config =
          jsonDecode(
                focuserBacklashCalibrationConfigJson(
                  settings: settings,
                  centerPosition: 6600,
                  appVersion: '7.0.0+27',
                ),
              )
              as Map<String, dynamic>;

      expect(config['step_size'], 30);
      expect(config['steps_out'], 6);
      expect(config['clearance_steps'], 90);
      expect(config['exposure_duration'], 2.5);
      expect(config['exposures_per_point'], 2);
      // The enums cross the wire as the variant names serde expects.
      expect(config['binning'], 'Two');
      expect(config['method'], 'Hyperbolic');
      expect(config['gain'], 100);
      expect(config['offset'], 50);
      expect(config['min_star_count'], 12);
      expect(config['r_squared_threshold'], 0.9);
      expect(config['outer_crop_ratio'], 0.9);
      expect(config['inner_crop_ratio'], 0.1);
      expect(config['use_brightest_n_stars'], 15);
      expect(config['focuser_settle_time_ms'], 800);
      expect(config['outlier_rejection_sigma'], 2.5);
      expect(config['max_duration_secs'], 900);
    });

    test(
      'unset camera fields are sent as null, the native "leave it" value',
      () {
        final config =
            jsonDecode(
                  focuserBacklashCalibrationConfigJson(
                    settings:
                        FocuserBacklashCalibrationSettings.seededFromAutofocus(
                          const AutofocusSettings(),
                        ),
                    appVersion: '7.0.0+27',
                  ),
                )
                as Map<String, dynamic>;

        expect(config.containsKey('gain'), isTrue);
        expect(config['gain'], isNull);
        expect(config['offset'], isNull);
      },
    );
  });
}
