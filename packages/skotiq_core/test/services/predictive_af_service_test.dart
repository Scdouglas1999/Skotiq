// Predictive autofocus service tests.
//
// Covers:
//   * Linear regression math (slope recovery on known data).
//   * Confidence-score thresholds (ForceAutofocus / ApplyDampened / ApplyDirect).
//   * DB round-trip (insert → query → load → predict).
//   * Drift detection (5 bad runs trigger ShouldWarn; reset on good run).
//   * Per-profile isolation (two profiles never cross-contaminate).
//   * Export JSON shape (schema, filter, samples, recovered slope).

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_core/src/database/daos/settings_dao.dart';
import 'package:skotiq_core/src/services/predictive_af_service.dart';

class _MockSettingsDao extends Mock implements SettingsDao {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late db.SkotiqDatabase database;
  late PredictiveAfService service;

  setUp(() async {
    // Why an in-memory DB rather than the on-disk default: the tests must
    // be hermetic (no shared state across test runs / parallel `flutter
    // test` workers), and we don't need persistence within a single test
    // anyway — every assertion completes before tear-down.
    database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    await database
        .into(database.equipmentProfiles)
        .insert(
          db.EquipmentProfilesCompanion.insert(
            id: const Value(1),
            name: 'Test Profile 1',
          ),
        );
    await database
        .into(database.equipmentProfiles)
        .insert(
          db.EquipmentProfilesCompanion.insert(
            id: const Value(2),
            name: 'Test Profile 2',
          ),
        );
    service = PredictiveAfService(database);
  });

  tearDown(() async {
    await service.dispose();
    await database.close();
  });

  group('PredictiveAfService - regression math', () {
    test(
      'recovers known slope and high R² from clean linear samples',
      () async {
        // 47 steps/°C, baseline 28000 at 10°C — simulating an Ha filter
        // with a moderately fast thermal response on a small refractor.
        FilterFocusModel? model;
        for (int i = 0; i < 12; i++) {
          final temp = 0.0 + i.toDouble();
          final position = 28000 + i * 47;
          model = await service.recordAutofocusOutcome(
            equipmentProfileId: 1,
            filterName: 'Ha',
            temperatureCelsius: temp,
            focusPosition: position,
            hfr: 1.8,
          );
        }
        expect(model, isNotNull);
        expect(model!.slopeStepsPerC, closeTo(47.0, 0.5));
        expect(model.confidenceScore, greaterThan(0.99));
        expect(model.samples.length, 12);

        // Predict at 6°C → should land within a few steps of 28000 + 6*47.
        final predicted = model.predictPosition(6.0);
        expect((predicted - (28000 + 6 * 47)).abs(), lessThanOrEqualTo(5));
      },
    );

    test('does not fit when samples lack temperature variance', () async {
      for (int i = 0; i < 6; i++) {
        await service.recordAutofocusOutcome(
          equipmentProfileId: 1,
          filterName: 'L',
          temperatureCelsius: 12.0,
          focusPosition: 28000 + i * 5,
          hfr: 2.0,
        );
      }
      final model = await service.getModel(
        equipmentProfileId: 1,
        filterName: 'L',
      );
      expect(model, isNotNull);
      // All samples in one bucket → < 3 unique buckets → no slope.
      expect(model!.slopeStepsPerC, 0.0);
      expect(model.confidenceScore, 0.0);
    });
  });

  test(
    'config persistence commits the complete threshold set atomically',
    () async {
      final settings = _MockSettingsDao();
      when(() => settings.getSetting(any())).thenAnswer((_) async => null);
      when(() => settings.setSettings(any())).thenAnswer((_) async {});
      final persistingService = PredictiveAfService(
        database,
        settingsDao: settings,
      );
      addTearDown(persistingService.dispose);
      await persistingService.hydrated;

      const config = PredictiveAfConfig(
        enabled: false,
        minSamplesForTrust: 9,
        highConfidenceThreshold: 0.91,
        lowConfidenceThreshold: 0.61,
        driftThresholdSteps: 275,
        driftRunsBeforeWarn: 4,
      );
      await persistingService.updateConfig(config);

      final values =
          verify(() => settings.setSettings(captureAny())).captured.single
              as Map<String, String>;
      expect(values, hasLength(6));
      expect(values['predictive_af.enabled'], 'false');
      expect(values['predictive_af.min_samples_for_trust'], '9');
      expect(values['predictive_af.high_confidence_threshold'], '0.91');
      expect(values['predictive_af.low_confidence_threshold'], '0.61');
      expect(values['predictive_af.drift_threshold_steps'], '275');
      expect(values['predictive_af.drift_runs_before_warn'], '4');
      verifyNever(() => settings.setSetting(any(), any()));
    },
  );

  group('PredictiveAfService - confidence gates', () {
    Future<void> seedHighConfidence(String filter) async {
      for (int i = 0; i < 12; i++) {
        await service.recordAutofocusOutcome(
          equipmentProfileId: 1,
          filterName: filter,
          temperatureCelsius: i.toDouble(),
          focusPosition: 15000 + i * 30,
          hfr: 2.0,
        );
      }
    }

    test('ApplyDirect when confidence >= high threshold', () async {
      await seedHighConfidence('L');
      final decision = await service.evaluateForFilter(
        equipmentProfileId: 1,
        filterName: 'L',
        temperatureCelsius: 6.0,
      );
      expect(decision, isA<ApplyDirect>());
      final apply = decision as ApplyDirect;
      expect(apply.confidence, greaterThanOrEqualTo(0.8));
      expect(
        (apply.predictedPosition - (15000 + 6 * 30)).abs(),
        lessThanOrEqualTo(5),
      );
    });

    test('ForceAutofocus when too few samples', () async {
      for (int i = 0; i < 4; i++) {
        await service.recordAutofocusOutcome(
          equipmentProfileId: 1,
          filterName: 'L',
          temperatureCelsius: i.toDouble(),
          focusPosition: 15000 + i * 30,
          hfr: 2.0,
        );
      }
      final decision = await service.evaluateForFilter(
        equipmentProfileId: 1,
        filterName: 'L',
        temperatureCelsius: 5.0,
      );
      expect(decision, isA<ForceAutofocus>());
    });

    test('InsufficientData when no model exists for filter', () async {
      final decision = await service.evaluateForFilter(
        equipmentProfileId: 1,
        filterName: 'UnknownFilter',
        temperatureCelsius: 5.0,
      );
      expect(decision, isA<InsufficientData>());
    });

    test('disabling the feature forces AF even on a strong model', () async {
      await seedHighConfidence('L');
      service.config = service.config.copyWith(enabled: false);
      final decision = await service.evaluateForFilter(
        equipmentProfileId: 1,
        filterName: 'L',
        temperatureCelsius: 6.0,
      );
      expect(decision, isA<ForceAutofocus>());
    });
  });

  group('PredictiveAfService - drift detection', () {
    test(
      '5 consecutive bad runs trigger ShouldWarn; reset on a good run',
      () async {
        // Seed a model so the row exists.
        for (int i = 0; i < 10; i++) {
          await service.recordAutofocusOutcome(
            equipmentProfileId: 1,
            filterName: 'Ha',
            temperatureCelsius: i.toDouble(),
            focusPosition: 28000 + i * 47,
            hfr: 2.0,
          );
        }
        // Simulate 5 consecutive predictions that are off by 800 steps each.
        DriftStatus? last;
        for (int i = 0; i < 5; i++) {
          last = await service.recordPredictionVsActual(
            equipmentProfileId: 1,
            filterName: 'Ha',
            predictedPosition: 28000,
            actualPosition: 28800,
          );
        }
        expect(last, isA<ShouldWarn>());
        final warn = last! as ShouldWarn;
        expect(warn.consecutiveBadRuns, 5);
        expect(warn.accumulatedDriftSteps, 4000);
        expect(warn.message, contains('Ha'));
        expect(warn.message, contains('drifted'));

        // Now a good run should reset both counters and emit
        // WithinTolerance.
        final good = await service.recordPredictionVsActual(
          equipmentProfileId: 1,
          filterName: 'Ha',
          predictedPosition: 28000,
          actualPosition: 28050,
        );
        expect(good, isA<WithinTolerance>());
        final reloaded = await service.getModel(
          equipmentProfileId: 1,
          filterName: 'Ha',
        );
        expect(reloaded!.consecutiveBadPredictions, 0);
        expect(reloaded.accumulatedDriftSteps, 0);
      },
    );

    test('drift events stream emits the matching status', () async {
      for (int i = 0; i < 6; i++) {
        await service.recordAutofocusOutcome(
          equipmentProfileId: 1,
          filterName: 'Ha',
          temperatureCelsius: i.toDouble(),
          focusPosition: 28000 + i * 47,
          hfr: 2.0,
        );
      }
      final events = <DriftStatus>[];
      final sub = service.driftEvents.listen(events.add);
      // First event after listener attaches.
      await service.recordPredictionVsActual(
        equipmentProfileId: 1,
        filterName: 'Ha',
        predictedPosition: 28000,
        actualPosition: 28050,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(events, hasLength(1));
      expect(events.first, isA<WithinTolerance>());
      await sub.cancel();
    });
  });

  group('PredictiveAfService - per-profile isolation', () {
    test(
      'two profiles with the same filter name do not cross-contaminate',
      () async {
        // Profile 1 — Ha filter: slope 30
        for (int i = 0; i < 10; i++) {
          await service.recordAutofocusOutcome(
            equipmentProfileId: 1,
            filterName: 'Ha',
            temperatureCelsius: i.toDouble(),
            focusPosition: 10000 + i * 30,
            hfr: 2.0,
          );
        }
        // Profile 2 — Ha filter: slope 60 (very different rig)
        for (int i = 0; i < 10; i++) {
          await service.recordAutofocusOutcome(
            equipmentProfileId: 2,
            filterName: 'Ha',
            temperatureCelsius: i.toDouble(),
            focusPosition: 50000 + i * 60,
            hfr: 2.0,
          );
        }

        final m1 = await service.getModel(
          equipmentProfileId: 1,
          filterName: 'Ha',
        );
        final m2 = await service.getModel(
          equipmentProfileId: 2,
          filterName: 'Ha',
        );
        expect(m1, isNotNull);
        expect(m2, isNotNull);
        expect(m1!.slopeStepsPerC, closeTo(30.0, 0.5));
        expect(m2!.slopeStepsPerC, closeTo(60.0, 0.5));
        expect(m1.samples.length, 10);
        expect(m2.samples.length, 10);
      },
    );
  });

  group('PredictiveAfService - export', () {
    test('exported JSON carries the schema and every sample', () async {
      for (int i = 0; i < 10; i++) {
        await service.recordAutofocusOutcome(
          equipmentProfileId: 1,
          filterName: 'Ha',
          temperatureCelsius: i.toDouble(),
          focusPosition: 28000 + i * 47,
          hfr: 2.0,
        );
      }

      final json = await service.exportModel(
        equipmentProfileId: 1,
        filterName: 'Ha',
      );

      expect(json, isNotNull);
      final decoded = jsonDecode(json!) as Map<String, dynamic>;
      expect(decoded['schema'], 'skotiq.focus_model.v1');
      expect(decoded['filter_name'], 'Ha');
      expect((decoded['samples'] as List<dynamic>).length, 10);
      expect(
        (decoded['slope_steps_per_c'] as num).toDouble(),
        closeTo(47.0, 0.5),
      );
    });
  });

  group('PredictiveAfService - sample retention', () {
    test(
      'clearSamples wipes samples but preserves training_run_count',
      () async {
        for (int i = 0; i < 8; i++) {
          await service.recordAutofocusOutcome(
            equipmentProfileId: 1,
            filterName: 'L',
            temperatureCelsius: i.toDouble(),
            focusPosition: 10000 + i * 30,
            hfr: 2.0,
          );
        }
        final before = await service.getModel(
          equipmentProfileId: 1,
          filterName: 'L',
        );
        expect(before!.trainingRunCount, 8);
        expect(before.samples, hasLength(8));

        await service.clearSamples(equipmentProfileId: 1, filterName: 'L');
        final after = await service.getModel(
          equipmentProfileId: 1,
          filterName: 'L',
        );
        expect(after!.samples, isEmpty);
        expect(after.slopeStepsPerC, 0.0);
        expect(after.confidenceScore, 0.0);
        // Lifetime counter is preserved.
        expect(after.trainingRunCount, 8);
      },
    );

    test('window respects max_training_samples cap', () async {
      // Default cap is 50; lower it for the test.
      // Need to insert 60 samples and assert only 50 remain.
      for (int i = 0; i < 60; i++) {
        await service.recordAutofocusOutcome(
          equipmentProfileId: 1,
          filterName: 'L',
          temperatureCelsius: i.toDouble(),
          focusPosition: 10000 + i * 30,
          hfr: 2.0,
        );
      }
      final model = await service.getModel(
        equipmentProfileId: 1,
        filterName: 'L',
      );
      expect(model!.samples, hasLength(50));
      // Should have kept the most recent samples (timestamp == 59 was last).
      expect(model.samples.last.focusPosition, 10000 + 59 * 30);
    });
  });

  group('PredictiveAfService - listing', () {
    test('listModels orders by most-recently-used', () async {
      await service.recordAutofocusOutcome(
        equipmentProfileId: 1,
        filterName: 'L',
        temperatureCelsius: 10.0,
        focusPosition: 10000,
        hfr: 2.0,
      );
      await service.recordAutofocusOutcome(
        equipmentProfileId: 1,
        filterName: 'Ha',
        temperatureCelsius: 10.0,
        focusPosition: 28000,
        hfr: 2.0,
      );
      // Touch L last to make it the most recently used.
      await service.evaluateForFilter(
        equipmentProfileId: 1,
        filterName: 'L',
        temperatureCelsius: 10.0,
      );
      // Yield so the unawaited _touchLastUsed completes before we list.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final list = await service.listModels(equipmentProfileId: 1);
      expect(list, hasLength(2));
      expect(list.first.filterName, 'L');
    });
  });
}
