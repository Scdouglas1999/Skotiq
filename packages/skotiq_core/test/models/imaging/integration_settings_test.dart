import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/imaging/integration_settings.dart';

void main() {
  group('IntegrationSettings defaults', () {
    test('balanced defaults match the documented PixInsight-spirit knobs', () {
      const s = IntegrationSettings.defaults;
      expect(s.model, TransformModel.affine);
      expect(s.resampler, Resampler.lanczos3);
      expect(s.ransacThresholdPx, 2.0);
      expect(s.maxRefStars, 60);
      expect(s.weightingEnabled, isTrue);
      expect(s.weighting, WeightFormula.snrSquared);
      expect(s.normalizationEnabled, isTrue);
      expect(s.normalization, NormalizationMode.global);
      expect(s.combine, CombineMode.mean);
      expect(s.reject, RejectAlgorithm.auto);
      expect(s.rejectLow, 3.0);
      expect(s.rejectHigh, 3.0);
      expect(s.generateRejectionMap, isTrue);
      expect(s.cosmeticCorrection, isTrue);
      expect(s.outputBitDepth, OutputBitDepth.f32);
      expect(s.autoCull, isTrue);
      expect(s.cullPercentile, closeTo(0.10, 1e-9));
      expect(s.sourcePreset, IntegrationPreset.balanced);
    });
  });

  group('presets', () {
    test('fast trades quality for speed', () {
      final s = IntegrationSettings.preset(IntegrationPreset.fast);
      expect(s.resampler, Resampler.bilinear);
      expect(s.weighting, WeightFormula.snr);
      expect(s.generateRejectionMap, isFalse);
      expect(s.cosmeticCorrection, isFalse);
      expect(s.sourcePreset, IntegrationPreset.fast);
    });

    test('maximumQuality keeps Lanczos + rejection map + f32', () {
      final s = IntegrationSettings.preset(IntegrationPreset.maximumQuality);
      expect(s.resampler, Resampler.lanczos3);
      expect(s.weighting, WeightFormula.snrSquared);
      expect(s.generateRejectionMap, isTrue);
      expect(s.outputBitDepth, OutputBitDepth.f32);
    });

    test('fewSubs uses percentile rejection with fractional thresholds', () {
      final s = IntegrationSettings.preset(IntegrationPreset.fewSubs);
      expect(s.reject, RejectAlgorithm.percentile);
      // Percentile thresholds are fractions in (0, 1), not sigma.
      expect(s.rejectLow, greaterThan(0.0));
      expect(s.rejectLow, lessThan(1.0));
      expect(s.rejectHigh, greaterThan(0.0));
      expect(s.rejectHigh, lessThan(1.0));
    });

    test('longNightGradient turns on local normalization', () {
      final s = IntegrationSettings.preset(IntegrationPreset.longNightGradient);
      expect(s.normalization, NormalizationMode.local);
    });
  });

  group('smartDefaults', () {
    test('keeps auto rejection and resolves to percentile for <8 subs', () {
      final s = IntegrationSettings.smartDefaults(subCount: 5);
      expect(s.reject, RejectAlgorithm.auto);
      expect(s.resolvedReject(5), RejectAlgorithm.percentile);
      // Percentile fractions substituted for the sigma defaults.
      expect(s.rejectLow, lessThan(1.0));
      expect(s.rejectHigh, lessThan(1.0));
      // A hand-tuned smart config is no longer tied to one preset.
      expect(s.sourcePreset, isNull);
    });

    test('resolves winsorizedSigma for the 8..24 band', () {
      final s = IntegrationSettings.smartDefaults(subCount: 15);
      expect(s.resolvedReject(15), RejectAlgorithm.winsorizedSigma);
      // Sigma thresholds retained (not substituted with fractions).
      expect(s.rejectLow, 3.0);
      expect(s.rejectHigh, 3.0);
    });

    test('resolves linearFit for >=25 subs', () {
      final s = IntegrationSettings.smartDefaults(subCount: 40);
      expect(s.resolvedReject(40), RejectAlgorithm.linearFit);
    });

    test('longNight enables local normalization', () {
      final s = IntegrationSettings.smartDefaults(
        subCount: 30,
        longNight: true,
      );
      expect(s.normalization, NormalizationMode.local);
    });

    test('preferSpeed drops to the bilinear resampler', () {
      final s = IntegrationSettings.smartDefaults(
        subCount: 200,
        preferSpeed: true,
      );
      expect(s.resampler, Resampler.bilinear);
    });

    test('resolvedReject is an identity for a non-auto algorithm', () {
      const s = IntegrationSettings(reject: RejectAlgorithm.sigmaClip);
      expect(s.resolvedReject(3), RejectAlgorithm.sigmaClip);
      expect(s.resolvedReject(100), RejectAlgorithm.sigmaClip);
    });
  });

  group('serialization', () {
    test('toJson / fromJson round-trips every knob', () {
      const s = IntegrationSettings(
        model: TransformModel.homography,
        resampler: Resampler.catmullRom,
        ransacThresholdPx: 1.5,
        maxRefStars: 120,
        weightingEnabled: false,
        weighting: WeightFormula.custom,
        snrPow: 2.5,
        fwhmPow: 0.5,
        eccPow: 1.5,
        normalizationEnabled: false,
        normalization: NormalizationMode.local,
        localRows: 12,
        localCols: 10,
        combine: CombineMode.median,
        reject: RejectAlgorithm.linearFit,
        rejectLow: 2.5,
        rejectHigh: 4.0,
        minMaxLow: 2,
        minMaxHigh: 3,
        generateRejectionMap: false,
        cosmeticCorrection: false,
        outputBitDepth: OutputBitDepth.u16,
        autoCull: false,
        cullPercentile: 0.25,
        sourcePreset: IntegrationPreset.maximumQuality,
      );
      final restored = IntegrationSettings.fromJson(s.toJson());
      expect(restored, s);
    });

    test('toJsonString / fromJsonStringOrDefault round-trips', () {
      final s = IntegrationSettings.preset(IntegrationPreset.longNightGradient);
      final restored = IntegrationSettings.fromJsonStringOrDefault(
        s.toJsonString(),
      );
      expect(restored, s);
    });

    test('toJson / fromJson round-trips every v42 finishing knob', () {
      // Drive every Smart-Morning-Report / algorithm-depth knob away from its
      // default so the v42 additions are actually exercised by the round-trip
      // (the broad round-trip above leaves them all at their defaults).
      const s = IntegrationSettings(
        drizzle: true,
        drizzleScale: 3.0,
        drizzlePixfrac: 0.7,
        drizzleKernel: DrizzleKernel.gaussian,
        bayerDrizzle: true,
        deconvolve: true,
        deconIterations: 50,
        deconRegularization: 0.05,
        psfKind: PsfKind.moffat,
        reduceStars: true,
        starReductionStrength: 0.8,
        starReduceMethod: StarReduceMethod.morphologicalErosion,
        extractBackground: true,
        backgroundPolyDegree: 6,
        backgroundPreserveMean: false,
        colorCalibrate: true,
        whiteRefBv: 0.4,
        narrowbandPalette: NarrowbandPalette.custom,
        customWeights: [
          [1.0, 0.0, 0.0],
          [0.0, 0.5, 0.5],
        ],
      );
      final restored = IntegrationSettings.fromJson(s.toJson());
      expect(restored, s);
      // Spot-check the custom narrowband weight table survived the trip.
      expect(restored.customWeights, [
        [1.0, 0.0, 0.0],
        [0.0, 0.5, 0.5],
      ]);
    });

    test('fromJsonStringOrDefault returns defaults for null/blank/corrupt', () {
      expect(
        IntegrationSettings.fromJsonStringOrDefault(null),
        IntegrationSettings.defaults,
      );
      expect(
        IntegrationSettings.fromJsonStringOrDefault('   '),
        IntegrationSettings.defaults,
      );
      expect(
        IntegrationSettings.fromJsonStringOrDefault('{not json'),
        IntegrationSettings.defaults,
      );
      // A JSON array (not an object) also falls back rather than throwing.
      expect(
        IntegrationSettings.fromJsonStringOrDefault('[1,2,3]'),
        IntegrationSettings.defaults,
      );
    });

    test('fromJson forward-migrates missing keys to defaults', () {
      // An older blob that predates several knobs.
      final restored = IntegrationSettings.fromJson({
        'model': 'similarity',
        'rejectLow': 2.0,
      });
      expect(restored.model, TransformModel.similarity);
      expect(restored.rejectLow, 2.0);
      // Everything unspecified falls back to the default value.
      expect(restored.resampler, IntegrationSettings.defaults.resampler);
      expect(restored.weighting, IntegrationSettings.defaults.weighting);
      expect(
        restored.outputBitDepth,
        IntegrationSettings.defaults.outputBitDepth,
      );
    });
  });

  group('toBridgeSettings', () {
    test(
      'emits the native IntegrationSettingsArgs shape with camelCase keys',
      () {
        const s = IntegrationSettings.defaults;
        final bridge = s.toBridgeSettings();
        expect(
          bridge.keys,
          containsAll(['align', 'weighting', 'normalization', 'integration']),
        );

        final align = bridge['align'] as Map<String, dynamic>;
        expect(align['model'], 'affine');
        expect(align['resampler'], 'lanczos3');
        expect(align['ransacThresholdPx'], 2.0);
        expect(align['maxRefStars'], 60);

        final weighting = bridge['weighting'] as Map<String, dynamic>;
        expect(weighting['enabled'], isTrue);
        expect(weighting['formula'], 'snrSquared');

        final norm = bridge['normalization'] as Map<String, dynamic>;
        expect(norm['enabled'], isTrue);
        expect(norm['mode'], 'global');

        final integ = bridge['integration'] as Map<String, dynamic>;
        expect(integ['combine'], 'mean');
        expect(integ['reject'], 'auto');
        expect(integ['rejectLow'], 3.0);
        expect(integ['generateRejectionMap'], isTrue);
        expect(integ['outputBitDepth'], 'f32');

        // cosmeticCorrection rides on the native calibration block, NOT here.
        expect(integ.containsKey('cosmeticCorrection'), isFalse);
        expect(weighting.containsKey('cosmeticCorrection'), isFalse);
      },
    );

    test('emits the v42 finishing block with camelCase native field names', () {
      const s = IntegrationSettings(
        drizzle: true,
        drizzleScale: 2.5,
        drizzlePixfrac: 0.8,
        drizzleKernel: DrizzleKernel.point,
        bayerDrizzle: true,
        deconvolve: true,
        deconIterations: 40,
        deconRegularization: 0.02,
        psfKind: PsfKind.gaussian,
        reduceStars: true,
        starReductionStrength: 0.6,
        starReduceMethod: StarReduceMethod.screenedResidual,
        extractBackground: true,
        backgroundPolyDegree: 5,
        backgroundPreserveMean: false,
        colorCalibrate: true,
        whiteRefBv: 0.55,
        narrowbandPalette: NarrowbandPalette.sho,
      );
      final finishing =
          s.toBridgeSettings()['finishing'] as Map<String, dynamic>;

      final drizzle = finishing['drizzle'] as Map<String, dynamic>;
      expect(drizzle['enabled'], isTrue);
      expect(drizzle['scale'], 2.5);
      expect(drizzle['pixfrac'], 0.8);
      expect(drizzle['kernel'], 'point');
      expect(drizzle['bayer'], isTrue);

      // Deconvolution mirrors native DeconvolvePreviewArgs: top-level
      // estimatePsf + nested psf.kind + nested config.{iterations,
      // regularization}. psfKind == gaussian is analytic, so estimatePsf
      // is false and the kind routes through psf.kind.
      final decon = finishing['deconvolution'] as Map<String, dynamic>;
      expect(decon['enabled'], isTrue);
      expect(decon['estimatePsf'], isFalse);
      expect((decon['psf'] as Map<String, dynamic>)['kind'], 'gaussian');
      final deconConfig = decon['config'] as Map<String, dynamic>;
      expect(deconConfig['iterations'], 40);
      expect(deconConfig['regularization'], 0.02);
      // The flat shape the native side never read must be gone.
      expect(decon.containsKey('psfKind'), isFalse);
      expect(decon.containsKey('iterations'), isFalse);

      final starReduction = finishing['starReduction'] as Map<String, dynamic>;
      expect(starReduction['enabled'], isTrue);
      expect(starReduction['strength'], 0.6);
      expect(starReduction['method'], 'screened_residual');

      final bg = finishing['backgroundExtraction'] as Map<String, dynamic>;
      expect(bg['enabled'], isTrue);
      expect(bg['polyDegree'], 5);
      expect(bg['preserveMean'], isFalse);

      final color = finishing['colorCalibration'] as Map<String, dynamic>;
      expect(color['enabled'], isTrue);
      expect(color['whiteRefBv'], 0.55);

      // sho is a named palette: the parser accepts it and weights are absent.
      final narrowband = finishing['narrowband'] as Map<String, dynamic>;
      expect(narrowband['palette'], 'sho');
      expect(narrowband.containsKey('weights'), isFalse);
    });

    test('deconvolution with empirical psfKind routes through the '
        'estimate-from-stars path', () {
      const s = IntegrationSettings(
        deconvolve: true,
        deconIterations: 25,
        deconRegularization: 0.03,
        // psfKind defaults to empirical.
      );
      final decon =
          (s.toBridgeSettings()['finishing']
                  as Map<String, dynamic>)['deconvolution']
              as Map<String, dynamic>;
      // Empirical is unreachable analytically, so it must request estimation.
      expect(decon['estimatePsf'], isTrue);
      expect((decon['psf'] as Map<String, dynamic>)['kind'], 'empirical');
      final config = decon['config'] as Map<String, dynamic>;
      expect(config['iterations'], 25);
      expect(config['regularization'], 0.03);
    });

    test('narrowband omits the palette key for none and custom', () {
      // none: the native parser rejects a 'none' token, so the combine step is
      // skipped entirely — no palette, no weights.
      const none = IntegrationSettings();
      final noneNb =
          (none.toBridgeSettings()['finishing']
                  as Map<String, dynamic>)['narrowband']
              as Map<String, dynamic>;
      expect(noneNb.containsKey('palette'), isFalse);
      expect(noneNb.containsKey('weights'), isFalse);

      // custom: the native two-mode contract requires palette ABSENT with a
      // non-empty weights table.
      const custom = IntegrationSettings(
        narrowbandPalette: NarrowbandPalette.custom,
        customWeights: [
          [1.0, 0.0, 0.0],
          [0.0, 1.0, 0.0],
          [0.0, 0.0, 1.0],
        ],
      );
      final customNb =
          (custom.toBridgeSettings()['finishing']
                  as Map<String, dynamic>)['narrowband']
              as Map<String, dynamic>;
      expect(customNb.containsKey('palette'), isFalse);
      final weights = customNb['weights'] as List;
      expect(weights, isNotEmpty);
      expect(weights.first, [1.0, 0.0, 0.0]);
    });

    test('narrowband hoo emits the hoo palette token', () {
      const s = IntegrationSettings(narrowbandPalette: NarrowbandPalette.hoo);
      final nb =
          (s.toBridgeSettings()['finishing']
                  as Map<String, dynamic>)['narrowband']
              as Map<String, dynamic>;
      expect(nb['palette'], 'hoo');
      expect(nb.containsKey('weights'), isFalse);
    });
  });

  group('RejectAlgorithm.resolveAuto', () {
    test('matches the documented native sub-count rule boundaries', () {
      expect(RejectAlgorithm.resolveAuto(1), RejectAlgorithm.percentile);
      expect(RejectAlgorithm.resolveAuto(7), RejectAlgorithm.percentile);
      expect(RejectAlgorithm.resolveAuto(8), RejectAlgorithm.winsorizedSigma);
      expect(RejectAlgorithm.resolveAuto(24), RejectAlgorithm.winsorizedSigma);
      expect(RejectAlgorithm.resolveAuto(25), RejectAlgorithm.linearFit);
      expect(RejectAlgorithm.resolveAuto(1000), RejectAlgorithm.linearFit);
    });
  });

  group('pristine master by default (non-destructive defaults)', () {
    bool destructive(IntegrationSettings s) =>
        s.extractBackground ||
        s.colorCalibrate ||
        s.deconvolve ||
        s.reduceStars ||
        s.drizzle ||
        s.narrowbandPalette != NarrowbandPalette.none;

    test('base defaults perform no destructive processing', () {
      expect(destructive(IntegrationSettings.defaults), isFalse);
      expect(destructive(const IntegrationSettings()), isFalse);
    });

    test('smartDefaults never enables destructive processing', () {
      for (final subCount in [3, 8, 24, 50, 200]) {
        for (final dithered in [false, true]) {
          for (final underSampled in [false, true]) {
            for (final longNight in [false, true]) {
              final s = IntegrationSettings.smartDefaults(
                subCount: subCount,
                dithered: dithered,
                underSampled: underSampled,
                longNight: longNight,
              );
              expect(
                destructive(s),
                isFalse,
                reason:
                    'smartDefaults(subCount=$subCount, dithered=$dithered, '
                    'underSampled=$underSampled, longNight=$longNight) must '
                    'leave every destructive post-stacking step OFF so the '
                    'default output is a pristine, unmodified linear master',
              );
            }
          }
        }
      }
    });

    test('no named preset silently enables destructive processing', () {
      for (final preset in IntegrationPreset.values) {
        expect(
          destructive(IntegrationSettings.preset(preset)),
          isFalse,
          reason:
              '$preset must not enable destructive finishing as a default; '
              'finishing steps are explicit opt-ins',
        );
      }
    });

    test('fromJsonStringOrDefault fallback is non-destructive', () {
      expect(
        destructive(IntegrationSettings.fromJsonStringOrDefault(null)),
        isFalse,
      );
      expect(
        destructive(IntegrationSettings.fromJsonStringOrDefault('')),
        isFalse,
      );
    });
  });
}
