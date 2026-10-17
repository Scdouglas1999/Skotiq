import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/focus_model_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('focus-model-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return tempDir.path;
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('FocusModelService', () {
    test('import rebinds exported data to the destination profile', () async {
      final service = FocusModelService();
      await service.importData(
        'destination',
        jsonEncode({
          'profileId': 'source',
          'dataPoints': [
            {
              'timestamp': DateTime.utc(2026, 7, 15).toIso8601String(),
              'temperature': 8.0,
              'position': 12000,
              'hfr': 1.9,
              'filter': 'L',
            },
          ],
          'temperatureModel': null,
          'filterOffsets': <String, dynamic>{},
          'referenceFilter': null,
        }),
      );

      expect(service.getProfileData('source'), isNull);
      expect(service.getProfileData('destination')?.profileId, 'destination');

      final reloaded = FocusModelService();
      await reloaded.initialize();
      expect(reloaded.getProfileData('source'), isNull);
      expect(reloaded.getProfileData('destination')?.dataPoints, hasLength(1));
    });

    test(
      'a newly invalid regression clears the previously fitted model',
      () async {
        final service = FocusModelService();
        for (var i = 0; i < 5; i++) {
          await service.addDataPoint(
            profileId: 'profile-model-clear',
            temperatureCelsius: i.toDouble(),
            focusPosition: 10000 + (i * 50),
            hfr: 2,
          );
        }
        expect(
          service.getProfileData('profile-model-clear')?.temperatureModel,
          isNotNull,
        );

        await service.addDataPoint(
          profileId: 'profile-model-clear',
          temperatureCelsius: 5,
          focusPosition: 100000,
          hfr: 2,
        );

        expect(
          service.getProfileData('profile-model-clear')?.temperatureModel,
          isNull,
        );
      },
    );

    test(
      'does not build a temperature model when all temperatures are identical',
      () async {
        final service = FocusModelService();

        await service.addDataPoint(
          profileId: 'profile-a',
          temperatureCelsius: 12.0,
          focusPosition: 10000,
          hfr: 2.1,
        );
        await service.addDataPoint(
          profileId: 'profile-a',
          temperatureCelsius: 12.0,
          focusPosition: 10010,
          hfr: 2.0,
        );
        await service.addDataPoint(
          profileId: 'profile-a',
          temperatureCelsius: 12.0,
          focusPosition: 9990,
          hfr: 1.9,
        );

        final data = service.getProfileData('profile-a');
        expect(data, isNotNull);
        expect(data!.temperatureModel, isNull);
      },
    );

    test('rejects unrealistic slopes', () async {
      final service = FocusModelService();

      await service.addDataPoint(
        profileId: 'profile-b',
        temperatureCelsius: 10.0,
        focusPosition: 1000,
        hfr: 2.0,
      );
      await service.addDataPoint(
        profileId: 'profile-b',
        temperatureCelsius: 11.0,
        focusPosition: 2200,
        hfr: 1.9,
      );
      await service.addDataPoint(
        profileId: 'profile-b',
        temperatureCelsius: 12.0,
        focusPosition: 3400,
        hfr: 1.8,
      );

      final data = service.getProfileData('profile-b');
      expect(data, isNotNull);
      expect(data!.temperatureModel, isNull);
    });

    // The `slope.abs() > 500`
    // rejection threshold is now sourced from FocusModelConfig.
    test(
      'maxAcceptableSlopeStepsPerC override accepts what the default would reject',
      () async {
        // Slope ≈ 1200 steps/°C — rejected by the 500-step default.
        Future<void> seed(FocusModelService svc) async {
          await svc.addDataPoint(
            profileId: 'profile-c',
            temperatureCelsius: 10.0,
            focusPosition: 1000,
            hfr: 2.0,
          );
          await svc.addDataPoint(
            profileId: 'profile-c',
            temperatureCelsius: 11.0,
            focusPosition: 2200,
            hfr: 1.9,
          );
          await svc.addDataPoint(
            profileId: 'profile-c',
            temperatureCelsius: 12.0,
            focusPosition: 3400,
            hfr: 1.8,
          );
          await svc.addDataPoint(
            profileId: 'profile-c',
            temperatureCelsius: 13.0,
            focusPosition: 4600,
            hfr: 1.85,
          );
          await svc.addDataPoint(
            profileId: 'profile-c',
            temperatureCelsius: 14.0,
            focusPosition: 5800,
            hfr: 1.95,
          );
        }

        // Default config (500-step gate): the fit is rejected.
        final defaultSvc = FocusModelService();
        await seed(defaultSvc);
        expect(
          defaultSvc.getProfileData('profile-c')?.temperatureModel,
          isNull,
          reason: 'slope ≈ 1200 must be rejected at default 500-step gate',
        );

        // Permissive config (2000-step gate): same data yields a model.
        final permissiveSvc = FocusModelService(
          config: const FocusModelConfig(maxAcceptableSlopeStepsPerC: 2000),
        );
        await seed(permissiveSvc);
        final model = permissiveSvc
            .getProfileData('profile-c')
            ?.temperatureModel;
        expect(
          model,
          isNotNull,
          reason: 'raising maxAcceptableSlopeStepsPerC must accept the model',
        );
        expect(model!.slope.abs(), greaterThan(500));
      },
    );

    // `FocusModel.isReliable` was hardcoded to
    // `rSquared >= 0.7 && dataPointCount >= 5`. The new isReliableWith() takes
    // user-configurable thresholds.
    // Filter offsets used to mix temperature drift into the
    // reported per-filter shift. These tests pin the corrected behaviour.
    group('temperature-corrected filter offsets', () {
      // Helper: seed a service with synthetic samples whose underlying
      // physics is: position = baseAtRefTemp + slope * (T - refTemp) + offset
      Future<FocusModelService> seedService({
        required String profileId,
        required String referenceFilter,
        required List<({String filter, double temp, int position})> samples,
      }) async {
        final svc = FocusModelService();
        // Seed reference filter first so setReferenceFilter has data to work
        // on, then push the rest.
        for (final s in samples.where((s) => s.filter == referenceFilter)) {
          await svc.addDataPoint(
            profileId: profileId,
            temperatureCelsius: s.temp,
            focusPosition: s.position,
            hfr: 2.0,
            filterName: s.filter,
          );
        }
        await svc.setReferenceFilter(profileId, referenceFilter);
        for (final s in samples.where((s) => s.filter != referenceFilter)) {
          await svc.addDataPoint(
            profileId: profileId,
            temperatureCelsius: s.temp,
            focusPosition: s.position,
            hfr: 2.0,
            filterName: s.filter,
          );
        }
        return svc;
      }

      test('temperature drift is NOT reported as a filter offset when '
          'true offset is zero', () async {
        // Physics: slope = 50 steps/°C, no per-filter offset.
        // Reference filter L: sampled at cold temperatures (5°C).
        // Filter R: sampled at warm temperatures (15°C).
        // A raw per-filter average would report ~500 steps of pure
        // temperature drift; the corrected offset must be ~0.
        const slope = 50.0;
        const baseAtZero = 4750.0; // arbitrary
        int posAt(double t) => (baseAtZero + slope * t).round();
        final samples = <({String filter, double temp, int position})>[
          (filter: 'L', temp: 0.0, position: posAt(0.0)),
          (filter: 'L', temp: 2.0, position: posAt(2.0)),
          (filter: 'L', temp: 4.0, position: posAt(4.0)),
          (filter: 'L', temp: 6.0, position: posAt(6.0)),
          (filter: 'L', temp: 8.0, position: posAt(8.0)),
          (filter: 'R', temp: 12.0, position: posAt(12.0)),
          (filter: 'R', temp: 14.0, position: posAt(14.0)),
          (filter: 'R', temp: 16.0, position: posAt(16.0)),
          (filter: 'R', temp: 18.0, position: posAt(18.0)),
          (filter: 'R', temp: 20.0, position: posAt(20.0)),
        ];

        final svc = await seedService(
          profileId: 'profile-img-p1-2-a',
          referenceFilter: 'L',
          samples: samples,
        );

        final data = svc.getProfileData('profile-img-p1-2-a');
        expect(data, isNotNull);
        expect(
          data!.temperatureModel,
          isNotNull,
          reason: 'sample set should yield a temperature model',
        );
        expect(data.temperatureModel!.isReliable, isTrue);

        final rOffset = data.filterOffsets['R'];
        expect(rOffset, isNotNull);
        // A raw average would report 500 here; the corrected offset is ~0.
        expect(
          rOffset!.offsetSteps.abs(),
          lessThan(5),
          reason: 'pure temperature drift must NOT be reported as offset',
        );
        expect(rOffset.temperatureCorrected, isTrue);
        expect(rOffset.confidenceBand, FilterOffsetConfidence.high);
      });

      test('real per-filter offset on top of temperature drift is reported '
          'cleanly', () async {
        // Same drift physics, but filter R has a *true* 200-step offset.
        const slope = 50.0;
        const baseAtZero = 4750.0;
        const trueROffset = 200;
        int posL(double t) => (baseAtZero + slope * t).round();
        int posR(double t) => (baseAtZero + slope * t + trueROffset).round();
        final samples = <({String filter, double temp, int position})>[
          (filter: 'L', temp: 0.0, position: posL(0.0)),
          (filter: 'L', temp: 2.0, position: posL(2.0)),
          (filter: 'L', temp: 4.0, position: posL(4.0)),
          (filter: 'L', temp: 6.0, position: posL(6.0)),
          (filter: 'L', temp: 8.0, position: posL(8.0)),
          (filter: 'R', temp: 12.0, position: posR(12.0)),
          (filter: 'R', temp: 14.0, position: posR(14.0)),
          (filter: 'R', temp: 16.0, position: posR(16.0)),
          (filter: 'R', temp: 18.0, position: posR(18.0)),
          (filter: 'R', temp: 20.0, position: posR(20.0)),
        ];

        final svc = await seedService(
          profileId: 'profile-img-p1-2-b',
          referenceFilter: 'L',
          samples: samples,
        );

        final data = svc.getProfileData('profile-img-p1-2-b');
        expect(data!.temperatureModel!.isReliable, isTrue);

        final rOffset = data.filterOffsets['R']!;
        // A raw average would report 200 + 500 = 700; the correction must
        // isolate the true 200.
        expect(
          (rOffset.offsetSteps - trueROffset).abs(),
          lessThan(5),
          reason: 'true offset must survive temperature correction',
        );
        expect(rOffset.temperatureCorrected, isTrue);
        expect(rOffset.confidenceBand, FilterOffsetConfidence.high);
      });

      test('low-R² model falls back to raw average and reports low '
          'confidence', () async {
        // Inject noise large enough to drive R² well below 0.7 but keep the
        // slope inside the 500 steps/°C rejection gate.
        // Mean position differs by 300 between filters → raw average will
        // report ~300 offset. We assert this is what we get, AND that the
        // confidence band is "low" so the UI can warn.
        final samples = <({String filter, double temp, int position})>[
          (filter: 'L', temp: 5.0, position: 5000),
          (filter: 'L', temp: 6.0, position: 5400),
          (filter: 'L', temp: 7.0, position: 4700),
          (filter: 'L', temp: 8.0, position: 5300),
          (filter: 'L', temp: 9.0, position: 4600),
          (filter: 'L', temp: 10.0, position: 5500),
          (filter: 'R', temp: 5.0, position: 5300),
          (filter: 'R', temp: 6.0, position: 5700),
          (filter: 'R', temp: 7.0, position: 5000),
          (filter: 'R', temp: 8.0, position: 5600),
          (filter: 'R', temp: 9.0, position: 4900),
          (filter: 'R', temp: 10.0, position: 5800),
        ];

        final svc = await seedService(
          profileId: 'profile-img-p1-2-c',
          referenceFilter: 'L',
          samples: samples,
        );

        final data = svc.getProfileData('profile-img-p1-2-c')!;
        final model = data.temperatureModel;
        // We expect R² to be low; if it sneaks above 0.7 the test premise
        // is wrong and we should redesign the dataset.
        expect(model, isNotNull);
        expect(
          model!.rSquared,
          lessThan(0.7),
          reason:
              'test premise: dataset must yield low R² to exercise fallback',
        );

        final rOffset = data.filterOffsets['R'];
        expect(rOffset, isNotNull);
        expect(
          rOffset!.temperatureCorrected,
          isFalse,
          reason: 'low R² must trigger the raw-average fallback',
        );
        expect(rOffset.confidenceBand, FilterOffsetConfidence.low);
        expect(
          rOffset.confidenceReason,
          isNotEmpty,
          reason: 'fallback must explain itself',
        );
        expect(
          rOffset.confidence,
          lessThanOrEqualTo(0.3),
          reason: 'scalar confidence must be capped in low band',
        );
        // Raw average difference: 300 — the contaminated number.
        expect(rOffset.offsetSteps, inInclusiveRange(295, 305));
      });

      test('narrow temperature spread downgrades a corrected offset to '
          'medium confidence', () async {
        // Reliable slope, but all samples within a < 5°C window. The
        // correction is still applied, but with little leverage on the
        // slope, so we should down-grade the band.
        const slope = 50.0;
        const baseAtZero = 4750.0;
        const trueROffset = 100;
        int posL(double t) => (baseAtZero + slope * t).round();
        int posR(double t) => (baseAtZero + slope * t + trueROffset).round();
        final samples = <({String filter, double temp, int position})>[
          (filter: 'L', temp: 10.0, position: posL(10.0)),
          (filter: 'L', temp: 10.5, position: posL(10.5)),
          (filter: 'L', temp: 11.0, position: posL(11.0)),
          (filter: 'L', temp: 11.5, position: posL(11.5)),
          (filter: 'L', temp: 12.0, position: posL(12.0)),
          (filter: 'R', temp: 12.5, position: posR(12.5)),
          (filter: 'R', temp: 13.0, position: posR(13.0)),
          (filter: 'R', temp: 13.5, position: posR(13.5)),
          (filter: 'R', temp: 14.0, position: posR(14.0)),
          (filter: 'R', temp: 14.5, position: posR(14.5)),
        ];

        final svc = await seedService(
          profileId: 'profile-img-p1-2-d',
          referenceFilter: 'L',
          samples: samples,
        );

        final data = svc.getProfileData('profile-img-p1-2-d')!;
        expect(data.temperatureModel!.isReliable, isTrue);

        final rOffset = data.filterOffsets['R']!;
        expect(rOffset.temperatureCorrected, isTrue);
        expect(
          rOffset.confidenceBand,
          FilterOffsetConfidence.medium,
          reason: 'spread < 5°C must downgrade band to medium',
        );
        expect(
          rOffset.confidence,
          lessThanOrEqualTo(0.6),
          reason: 'scalar confidence must be capped in medium band',
        );
      });

      test('FilterOffset round-trips confidence ladder through JSON', () {
        final original = FilterOffset(
          filterName: 'R',
          referenceFilter: 'L',
          offsetSteps: 200,
          measurementCount: 5,
          confidence: 0.85,
          confidenceBand: FilterOffsetConfidence.high,
          confidenceReason: 'computed reason',
          temperatureCorrected: true,
        );
        final round = FilterOffset.fromJson(original.toJson());
        expect(round.confidenceBand, FilterOffsetConfidence.high);
        expect(round.confidenceReason, 'computed reason');
        expect(round.temperatureCorrected, isTrue);
      });

      test('legacy JSON without confidence-ladder fields decodes with '
          'low/false defaults', () {
        final legacy = FilterOffset.fromJson({
          'filterName': 'R',
          'referenceFilter': 'L',
          'offsetSteps': 200,
          'measurementCount': 5,
          'confidence': 0.85,
        });
        expect(
          legacy.confidenceBand,
          FilterOffsetConfidence.low,
          reason:
              'an earlier build offsets were raw averages; must not advertise high',
        );
        expect(legacy.temperatureCorrected, isFalse);
        expect(legacy.confidenceReason, isEmpty);
      });
    });

    test('isReliableWith honours the FocusModelConfig thresholds', () {
      final model = FocusModel(
        slope: 50,
        intercept: 0,
        rSquared: 0.6,
        dataPointCount: 4,
        lastUpdated: DateTime.now(),
      );

      // Default thresholds reject this model (rSquared=0.6 < 0.7, count=4 < 5).
      expect(model.isReliable, isFalse);
      expect(model.isReliableWith(const FocusModelConfig()), isFalse);

      // Lower the bars: now accepted.
      expect(
        model.isReliableWith(
          const FocusModelConfig(minRSquared: 0.5, minDataPointCount: 3),
        ),
        isTrue,
      );

      // Only lowering one bar still rejects.
      expect(
        model.isReliableWith(const FocusModelConfig(minRSquared: 0.5)),
        isFalse,
        reason: 'minDataPointCount default 5 still rejects 4 points',
      );
    });
  });
}
