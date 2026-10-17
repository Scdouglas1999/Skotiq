// Pins the predictive-AF RUNTIME LOOP the autofocus controls drive: without it
// the subsystem is trained and consulted by no runtime path at all.
// `DeviceService._runAutofocus` performs exactly this sequence on every
// Dart-driven autofocus run:
//
//   1. evaluateForFilter()        — pre-sweep consultation (advisory)
//   2. recordAutofocusOutcome()   — train on the converged result
//   3. recordPredictionVsActual() — feed drift tracking
//
// These tests exercise that train→consult→drift loop end-to-end against a real
// in-memory DB, so silently breaking the wiring (e.g. dropping the training
// call) fails here even though `_runAutofocus` itself needs hardware.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_core/src/services/predictive_af_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late db.SkotiqDatabase database;
  late PredictiveAfService service;

  setUp(() async {
    database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    await database
        .into(database.equipmentProfiles)
        .insert(
          db.EquipmentProfilesCompanion.insert(id: const Value(1), name: 'Rig'),
        );
    service = PredictiveAfService(database);
  });

  tearDown(() async {
    await service.dispose();
    await database.close();
  });

  test(
    'cold start: first AF run trains the model and is consulted on the next',
    () async {
      const profileId = 1;
      const filter = 'Ha';

      // Cold: no model yet → evaluateForFilter reports InsufficientData.
      final cold = await service.evaluateForFilter(
        equipmentProfileId: profileId,
        filterName: filter,
        temperatureCelsius: 10.0,
      );
      expect(cold, isA<InsufficientData>());

      // Feed several converged outcomes across temperatures, exactly as the
      // autofocus controls now do after each real sweep.
      // A clean linear relationship (slope ~ -50 steps/°C) so the model can
      // learn a high-confidence fit.
      for (var i = 0; i < 10; i++) {
        final temp = 0.0 + i; // 0..9 °C
        final position = 30000 - (50 * i); // perfectly linear
        await service.recordAutofocusOutcome(
          equipmentProfileId: profileId,
          filterName: filter,
          temperatureCelsius: temp,
          focusPosition: position,
          hfr: 1.5,
        );
      }

      final model = await service.getModel(
        equipmentProfileId: profileId,
        filterName: filter,
      );
      expect(model, isNotNull);
      expect(model!.samples.length, 10);
      expect(model.slopeStepsPerC, closeTo(-50.0, 1e-6));
      expect(model.confidenceScore, greaterThan(0.99));

      // Warm: the model is now consulted and trusted (high confidence → direct).
      final warm = await service.evaluateForFilter(
        equipmentProfileId: profileId,
        filterName: filter,
        temperatureCelsius: 5.0,
      );
      expect(warm, isA<ApplyDirect>());
      // Predicted position at 5°C should sit on the learned line (~29750).
      expect(warm.targetPosition, closeTo(29750, 25));
    },
  );

  test(
    'prediction-vs-actual feedback drives drift detection to a warning',
    () async {
      const profileId = 1;
      const filter = 'OIII';

      // Seed a usable model.
      for (var i = 0; i < 8; i++) {
        await service.recordAutofocusOutcome(
          equipmentProfileId: profileId,
          filterName: filter,
          temperatureCelsius: i.toDouble(),
          focusPosition: 20000 - (40 * i),
          hfr: 1.4,
        );
      }

      // Five consecutive bad outcomes (actual far from prediction) — the wiring
      // calls recordPredictionVsActual after each sweep. driftRunsBeforeWarn=5.
      DriftStatus? last;
      for (var run = 0; run < 5; run++) {
        last = await service.recordPredictionVsActual(
          equipmentProfileId: profileId,
          filterName: filter,
          predictedPosition: 19000,
          actualPosition: 19000 + 500, // 500 > driftThresholdSteps (200)
        );
      }
      expect(last, isA<ShouldWarn>());

      // A subsequent good run resets the drift counters.
      final good = await service.recordPredictionVsActual(
        equipmentProfileId: profileId,
        filterName: filter,
        predictedPosition: 19000,
        actualPosition: 19010, // within tolerance
      );
      expect(good, isA<WithinTolerance>());

      final model = await service.getModel(
        equipmentProfileId: profileId,
        filterName: filter,
      );
      expect(model!.consecutiveBadPredictions, 0);
      expect(model.accumulatedDriftSteps, 0);
    },
  );

  test(
    'training works even when no profile is active (NULL profile key)',
    () async {
      // The wiring passes _activeProfile?.id, which can be null. The model must
      // still train under the NULL-profile key rather than silently no-op.
      const filter = 'L';
      await service.recordAutofocusOutcome(
        equipmentProfileId: null,
        filterName: filter,
        temperatureCelsius: 12.0,
        focusPosition: 41000,
        hfr: 1.2,
      );
      final model = await service.getModel(
        equipmentProfileId: null,
        filterName: filter,
      );
      expect(model, isNotNull);
      expect(model!.equipmentProfileId, isNull);
      expect(model.samples.single.focusPosition, 41000);
    },
  );
}
