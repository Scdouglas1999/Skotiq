import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/focuser_backlash_calibration.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';

/// A settings instance that is valid under every rule
/// `validate_backlash_calibration_config` enforces, from which each test
/// perturbs one field.
const seeded = FocuserBacklashCalibrationSettings(
  stepSize: 30,
  stepsOut: 6,
  clearanceSteps: 90,
  exposureDurationSecs: 2.0,
  exposuresPerPoint: 2,
  binning: 1,
  minStarCount: 10,
  rSquaredThreshold: 0.9,
  outerCropRatio: 1.0,
  innerCropRatio: 0.0,
  useBrightestNStars: 10,
  focuserSettleTimeMs: 500,
  outlierRejectionSigma: 3.0,
  maxDurationSecs: 1200.0,
);

void main() {
  group('seeding from the autofocus settings', () {
    test('every field with an autofocus equivalent takes it', () {
      const autofocus = AutofocusSettings(
        stepSize: 40,
        exposureTime: 5.0,
        initialOffsetSteps: 8,
        useBrightestNStars: 20,
        outerCropRatio: 0.8,
        innerCropRatio: 0.05,
        binning: 2,
        rSquaredThreshold: 0.85,
        focuserSettleTimeMs: 750,
        exposuresPerPoint: 3,
      );

      final settings = FocuserBacklashCalibrationSettings.seededFromAutofocus(
        autofocus,
      );

      expect(settings.stepSize, 40);
      // The sweep's "steps out from centre" is the same quantity.
      expect(settings.stepsOut, 8);
      expect(settings.exposureDurationSecs, 5.0);
      expect(settings.exposuresPerPoint, 3);
      expect(settings.binning, 2);
      expect(settings.rSquaredThreshold, 0.85);
      expect(settings.outerCropRatio, 0.8);
      expect(settings.innerCropRatio, 0.05);
      expect(settings.useBrightestNStars, 20);
      expect(settings.focuserSettleTimeMs, 750);
      // No autofocus equivalents: the shared defaults carry through.
      expect(settings.minStarCount, 10);
      expect(settings.outlierRejectionSigma, 3.0);
      expect(settings.maxDurationSecs, 1200.0);
      expect(settings.isValid, isTrue);
    });

    test('the run-up is derived from the step size, and stays valid', () {
      // Autofocus has no run-up concept. The derivation has one job: satisfy
      // the validator's "run-up must exceed the step size" while giving the
      // scan a reversal budget of several times the step.
      final settings = FocuserBacklashCalibrationSettings.seededFromAutofocus(
        const AutofocusSettings(stepSize: 40),
      );

      expect(settings.clearanceSteps, 120);
      expect(settings.clearanceSteps, greaterThan(settings.stepSize));
    });

    test('the fit method stays a parabola regardless of the sweep\'s fit', () {
      // The sweep's curve-fitting option answers a different question (wide,
      // deeply defocused wings) and is a different enum; the narrow either-
      // side-of-focus scan is a parabola's job.
      final settings = FocuserBacklashCalibrationSettings.seededFromAutofocus(
        const AutofocusSettings(curveFitting: 'Trend Lines'),
      );

      expect(settings.method, 'Quadratic');
    });

    test('the active filter\'s overrides win where autofocus applies them', () {
      const autofocus = AutofocusSettings(
        exposureTime: 4.0,
        binning: 1,
        filterSettings: {
          'Ha': FilterAutofocusConfig(
            afExposureTime: 30.0,
            afFilterName: 'Ha',
            binning: 2,
            gain: 200,
            offset: 60,
          ),
        },
      );

      final settings = FocuserBacklashCalibrationSettings.seededFromAutofocus(
        autofocus,
        activeFilter: autofocus.filterSettings['Ha'],
      );

      expect(settings.exposureDurationSecs, 30.0);
      expect(settings.binning, 2);
      expect(settings.gain, 200);
      expect(settings.offset, 60);
    });

    test('a filter with no overrides leaves the autofocus values', () {
      const autofocus = AutofocusSettings(
        exposureTime: 4.0,
        binning: 3,
        filterSettings: {'L': FilterAutofocusConfig(afFilterName: 'L')},
      );

      final settings = FocuserBacklashCalibrationSettings.seededFromAutofocus(
        autofocus,
        activeFilter: autofocus.filterSettings['L'],
      );

      expect(settings.exposureDurationSecs, 4.0);
      // Binning is non-nullable on a filter config (1 when unstated), so a
      // stored filter always carries it — the same precedence
      // `activeFilterSettings?.binning ?? appSettings.afBinning` gives
      // autofocus itself.
      expect(settings.binning, 1);
      expect(settings.gain, isNull);
      expect(settings.offset, isNull);
    });

    test('out-of-range autofocus values are clamped into the valid window', () {
      // A corrupt store can carry an autofocus sweep outside the calibration
      // range; the seed bends it back rather than present settings the run
      // could never use.
      final settings = FocuserBacklashCalibrationSettings.seededFromAutofocus(
        const AutofocusSettings(initialOffsetSteps: 80, binning: 8),
      );

      expect(settings.stepsOut, 50);
      expect(settings.binning, 4);
      expect(settings.isValid, isTrue);
    });
  });

  group('the persisted blob', () {
    test('round-trips losslessly, nulls and all', () {
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
        method: 'VCurve',
        outlierRejectionSigma: 2.5,
        maxDurationSecs: 900,
      );

      final parsed = FocuserBacklashCalibrationSettings.tryParse(
        jsonEncode(settings.toJson()),
      );

      expect(parsed, settings);
    });

    test('a blob written before method existed parses with the seeded one', () {
      final blob = seeded.toJson()..remove('method');

      final parsed = FocuserBacklashCalibrationSettings.tryParse(
        jsonEncode(blob),
      );

      expect(parsed, isNotNull);
      expect(parsed!.method, 'Quadratic');
      expect(parsed, seeded);
    });

    test('garbage falls back rather than throwing', () {
      expect(FocuserBacklashCalibrationSettings.tryParse('nonsense'), isNull);
      expect(FocuserBacklashCalibrationSettings.tryParse('"hello"'), isNull);
      expect(FocuserBacklashCalibrationSettings.tryParse('[]'), isNull);
      expect(FocuserBacklashCalibrationSettings.tryParse(''), isNull);
    });

    test('a missing or mistyped field falls back', () {
      final missing = seeded.toJson()..remove('step_size');
      expect(
        FocuserBacklashCalibrationSettings.tryParse(jsonEncode(missing)),
        isNull,
      );

      final mistyped = seeded.toJson()..['exposure_duration'] = 'two';
      expect(
        FocuserBacklashCalibrationSettings.tryParse(jsonEncode(mistyped)),
        isNull,
      );

      final badBinning = seeded.toJson()..['binning'] = 'Five';
      expect(
        FocuserBacklashCalibrationSettings.tryParse(jsonEncode(badBinning)),
        isNull,
      );

      final badGain = seeded.toJson()..['gain'] = 'high';
      expect(
        FocuserBacklashCalibrationSettings.tryParse(jsonEncode(badGain)),
        isNull,
      );
    });

    test('a parseable-but-invalid blob is kept, problems and all', () {
      // The dialog's job is to show the offending values, so resolve must not
      // quietly substitute the seed for a store the operator can still fix.
      final resolved = FocuserBacklashCalibrationSettings.resolve(
        jsonEncode(
          seeded.copyWith(stepSize: 200, clearanceSteps: 100).toJson(),
        ),
        autofocus: const AutofocusSettings(),
      );

      expect(resolved.stepSize, 200);
      expect(resolved.clearanceSteps, 100);
      expect(resolved.isValid, isFalse);
      expect(resolved.problems.single, contains('must exceed the step size'));
    });

    test('an empty or corrupt store resolves to the autofocus seed', () {
      const autofocus = AutofocusSettings(stepSize: 40);

      expect(
        FocuserBacklashCalibrationSettings.resolve('', autofocus: autofocus),
        FocuserBacklashCalibrationSettings.seededFromAutofocus(autofocus),
      );
      expect(
        FocuserBacklashCalibrationSettings.resolve(
          '{truncated',
          autofocus: autofocus,
        ),
        FocuserBacklashCalibrationSettings.seededFromAutofocus(autofocus),
      );
    });
  });

  group('the same rules as the native validator', () {
    test('the seeded baseline is valid', () {
      expect(seeded.isValid, isTrue);
      expect(seeded.problems, isEmpty);
    });

    test('exposure duration must be positive', () {
      expect(
        seeded.copyWith(exposureDurationSecs: 0).problems,
        contains(contains('Exposure duration must be finite and positive')),
      );
      expect(seeded.copyWith(exposureDurationSecs: -1).isValid, isFalse);
    });

    test('maximum duration must be positive', () {
      expect(
        seeded.copyWith(maxDurationSecs: 0).problems,
        contains(contains('Maximum duration must be finite and positive')),
      );
    });

    test('step size must be positive', () {
      expect(
        seeded.copyWith(stepSize: 0).problems,
        contains(contains('Step size must be positive')),
      );
      expect(seeded.copyWith(stepSize: -5).isValid, isFalse);
    });

    test('points either side must be 3 to 50', () {
      for (final stepsOut in [0, 1, 2, 51, 100]) {
        expect(
          seeded.copyWith(stepsOut: stepsOut).problems,
          contains(contains('between 3 and 50')),
          reason: 'stepsOut $stepsOut',
        );
      }
      for (final stepsOut in [3, 50]) {
        expect(seeded.copyWith(stepsOut: stepsOut).isValid, isTrue);
      }
    });

    test('the run-up must be positive', () {
      expect(
        seeded.copyWith(clearanceSteps: 0).problems,
        contains(contains('Run-up must be positive')),
      );
    });

    test('the run-up must exceed the step size', () {
      // Equal is already too little: stepping to the next point would undo
      // the approach the run-up just made.
      expect(
        seeded.copyWith(stepSize: 90).problems,
        contains(contains('must exceed the step size')),
      );
      expect(
        seeded.copyWith(stepSize: 91).problems,
        contains(contains('must exceed the step size')),
      );
      expect(seeded.copyWith(stepSize: 89).isValid, isTrue);
    });

    test('exposures per point must be 1 to 20', () {
      expect(
        seeded.copyWith(exposuresPerPoint: 0).problems,
        contains(contains('Exposures per point must be between 1 and 20')),
      );
      expect(seeded.copyWith(exposuresPerPoint: 21).isValid, isFalse);
      expect(seeded.copyWith(exposuresPerPoint: 20).isValid, isTrue);
    });

    test('R² threshold must be between 0 and 1', () {
      expect(
        seeded.copyWith(rSquaredThreshold: -0.1).problems,
        contains(contains('R² threshold must be between 0 and 1')),
      );
      expect(seeded.copyWith(rSquaredThreshold: 1.5).isValid, isFalse);
      expect(seeded.copyWith(rSquaredThreshold: 0).isValid, isTrue);
      expect(seeded.copyWith(rSquaredThreshold: 1).isValid, isTrue);
    });

    test('crop ratios must satisfy 0 <= inner < outer <= 1', () {
      expect(
        seeded.copyWith(innerCropRatio: -0.1).problems,
        contains(contains('0 <= inner < outer <= 1')),
      );
      // Equal crops leave nothing to detect in.
      expect(
        seeded.copyWith(innerCropRatio: 1.0).problems,
        contains(contains('0 <= inner < outer <= 1')),
      );
      expect(seeded.copyWith(outerCropRatio: 1.5).isValid, isFalse);
      expect(seeded.copyWith(outerCropRatio: 0).isValid, isFalse);
      expect(
        seeded.copyWith(innerCropRatio: 0.5, outerCropRatio: 0.5).isValid,
        isFalse,
      );
    });

    test('focuser settle time cannot exceed 10000 ms', () {
      expect(
        seeded.copyWith(focuserSettleTimeMs: 10001).problems,
        contains(contains('settle time cannot exceed 10000 ms')),
      );
      expect(seeded.copyWith(focuserSettleTimeMs: 10000).isValid, isTrue);
    });

    test('gain and offset cannot be negative', () {
      expect(
        seeded.copyWith(gain: -1).problems,
        contains(contains('Gain and offset cannot be negative')),
      );
      expect(
        seeded.copyWith(offset: -10).problems,
        contains(contains('Gain and offset cannot be negative')),
      );
      // Null means "the camera's configured value" and is always allowed.
      expect(seeded.copyWith().isValid, isTrue);
    });

    test('several problems are all named, in the validator\'s order', () {
      final problems = seeded
          .copyWith(
            exposureDurationSecs: 0,
            // Larger than the seeded 90-step run-up, which trips the
            // run-up-must-exceed-step-size rule as well.
            stepSize: 200,
            exposuresPerPoint: 0,
          )
          .problems;

      expect(problems, hasLength(3));
      expect(problems[0], contains('Exposure duration'));
      expect(problems[1], contains('must exceed the step size'));
      expect(problems[2], contains('Exposures per point'));
    });
  });

  group('copyWith', () {
    test('can set and clear the nullable camera fields', () {
      expect(seeded.gain, isNull);
      final withGain = seeded.copyWith(gain: 120);
      expect(withGain.gain, 120);
      // Clearing back to null must not be mistaken for "leave it alone".
      expect(withGain.copyWith(gain: null).gain, isNull);
      expect(withGain.copyWith().gain, 120);
    });
  });
}
