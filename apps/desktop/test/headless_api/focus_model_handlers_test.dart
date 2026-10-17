import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_desktop/headless_api/handlers/focus_model_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  group('FocusModelHandlers', () {
    late Directory tempDir;
    late ProviderContainer container;
    late FocusModelHandlers handlers;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'focus-model-handler-test',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, (call) async {
            if (call.method == 'getApplicationDocumentsDirectory') {
              return tempDir.path;
            }
            return null;
          });
      container = ProviderContainer(
        overrides: [
          // No profile loaded: these tests assert the "no active profile"
          // bad-request guard without spinning up the real database provider.
          activeEquipmentProfileProvider.overrideWithValue(null),
        ],
      );
      handlers = FocusModelHandlers(container);
    });

    tearDown(() async {
      container.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'get focus data without active profile returns JSON bad request',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleGetFocusData(
            Request('GET', Uri.parse('http://localhost/api/focus-model/data')),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest);
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(
          body['error'],
          'No active equipment profile. Load a profile first.',
        );
      },
    );

    test('predict without active profile returns JSON bad request', () async {
      final response = await translateHandlerErrors(
        handlers.handlePredictFocus(
          Request('GET', Uri.parse('http://localhost/api/focus-model/predict')),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(
        body['error'],
        'No active equipment profile. Load a profile first.',
      );
    });

    test('import without active profile returns JSON bad request', () async {
      final response = await translateHandlerErrors(
        handlers.handleImportFocusData(
          Request(
            'POST',
            Uri.parse('http://localhost/api/focus-model/import'),
            body: '{',
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(
        body['error'],
        'No active equipment profile. Load a profile first.',
      );
    });

    test(
      'should-refocus rejects invalid numeric queries before profile work',
      () async {
        final cases = <String, String>{
          'lastFocusTemp=0': 'currentTemp',
          'currentTemp=NaN&lastFocusTemp=0': 'currentTemp',
          'currentTemp=0&lastFocusTemp=Infinity': 'lastFocusTemp',
          'currentTemp=0&lastFocusTemp=0&maxDriftSteps=nope': 'maxDriftSteps',
          'currentTemp=0&lastFocusTemp=0&maxDriftSteps=0': 'maxDriftSteps',
          'currentTemp=0&lastFocusTemp=0&maxDriftSteps=-1': 'maxDriftSteps',
          'currentTemp=0&lastFocusTemp=0&maxDriftSteps=2000.1': 'maxDriftSteps',
        };

        for (final entry in cases.entries) {
          final response = await translateHandlerErrors(
            handlers.handleShouldRefocus(
              Request(
                'GET',
                Uri.parse(
                  'http://localhost/api/focus-model/should-refocus?${entry.key}',
                ),
              ),
            ),
          );
          expect(response.statusCode, HttpStatus.badRequest, reason: entry.key);
          final body = jsonDecode(await response.readAsString()) as Map;
          expect(body['field'], entry.value, reason: entry.key);
        }
      },
    );

    test(
      'should-refocus accepts the 2000-step boundary before profile guard',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleShouldRefocus(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/focus-model/should-refocus'
                '?currentTemp=0&lastFocusTemp=0&maxDriftSteps=2000',
              ),
            ),
          ),
        );
        expect(response.statusCode, HttpStatus.badRequest);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(
          body['error'],
          'No active equipment profile. Load a profile first.',
        );
        expect(body.containsKey('field'), isFalse);
      },
    );
  });

  // Source-of-truth parity: /predict + /should-refocus must answer from the
  // SAME DB-backed PredictiveAfService model the live run consults, so the
  // HTTP answer a slave queries matches the host's in-run refocus decision.
  group('FocusModelHandlers predictive-AF source-of-truth', () {
    const profileId = 1;
    const filter = 'Ha';

    late db.SkotiqDatabase database;
    late ProviderContainer container;
    late FocusModelHandlers handlers;
    late PredictiveAfService runService;

    setUp(() async {
      database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
      await database
          .into(database.equipmentProfiles)
          .insert(
            db.EquipmentProfilesCompanion.insert(
              id: const Value(profileId),
              name: 'Rig',
            ),
          );
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          activeEquipmentProfileProvider.overrideWithValue(
            const EquipmentProfileModel(id: profileId, name: 'Rig'),
          ),
        ],
      );
      handlers = FocusModelHandlers(container);
      // The exact same service the RUN consults (via predictiveAfServiceProvider).
      runService = container.read(predictiveAfServiceProvider);
    });

    tearDown(() async {
      container.dispose();
      await database.close();
    });

    /// Seed a clean, high-confidence per-filter model: ~47 steps/°C around a
    /// 28000 baseline, 12 unique-temperature samples (≥ the default
    /// min_samples_for_trust of 8 and R² ≈ 1.0). This is what a warmed-up run
    /// would have learned for the filter.
    Future<void> seedTrustedModel() async {
      for (int i = 0; i < 12; i++) {
        await runService.recordAutofocusOutcome(
          equipmentProfileId: profileId,
          filterName: filter,
          temperatureCelsius: i.toDouble(),
          focusPosition: 28000 + i * 47,
          hfr: 1.8,
        );
      }
    }

    Future<Map<String, dynamic>> getJson(Future<Response> response) async {
      final r = await translateHandlerErrors(response);
      final text = await r.readAsString();
      expect(r.statusCode, HttpStatus.ok, reason: text);
      return jsonDecode(text) as Map<String, dynamic>;
    }

    // ── STEP 2: pin the run-time prediction as the target behaviour ─────────
    test(
      'predict returns the SAME position the run model (PredictiveAfService) '
      'uses for a representative temp/filter',
      () async {
        await seedTrustedModel();
        const temp = 6.0;

        // Target: what the live run would consult.
        final runDecision = await runService.evaluateForFilter(
          equipmentProfileId: profileId,
          filterName: filter,
          temperatureCelsius: temp,
        );
        expect(
          runDecision.targetPosition,
          isNotNull,
          reason: 'precondition: seeded model must be trusted by the run',
        );

        final body = await getJson(
          handlers.handlePredictFocus(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/focus-model/predict'
                '?temperature=$temp&filter=$filter',
              ),
            ),
          ),
        );

        expect(body['canPredict'], isTrue);
        final prediction = body['prediction'] as Map<String, dynamic>;
        // HTTP prediction must equal the run-model prediction exactly.
        expect(prediction['position'], runDecision.targetPosition);
        expect(
          (prediction['confidence'] as num).toDouble(),
          closeTo(runDecision.confidence ?? 0.0, 1e-9),
        );
        expect(prediction['basedOnTemperature'], temp);
      },
    );

    test(
      'predictive settings expose and persist the run-time model config',
      () async {
        await seedTrustedModel();
        final getResponse = await getJson(
          handlers.handleGetPredictiveSettings(
            Request(
              'GET',
              Uri.parse('http://localhost/api/focus-model/predictive'),
            ),
          ),
        );
        expect((getResponse['models'] as List), hasLength(1));
        expect((getResponse['models'] as List).single['filter_name'], filter);

        final config = runService.config.copyWith(
          minSamplesForTrust: 9,
          driftThresholdSteps: 300,
        );
        final update = await getJson(
          handlers.handleUpdatePredictiveConfig(
            Request(
              'POST',
              Uri.parse('http://localhost/api/focus-model/predictive/config'),
              body: jsonEncode(config.toJson()),
            ),
          ),
        );
        expect(update['status'], 'updated');
        expect(runService.config.minSamplesForTrust, 9);
        expect(
          await database.settingsDao.getSetting(
            'predictive_af.min_samples_for_trust',
          ),
          '9',
        );
      },
    );

    test('predictive config rejects crossed confidence thresholds', () async {
      final payload = runService.config
          .copyWith(highConfidenceThreshold: 0.6, lowConfidenceThreshold: 0.7)
          .toJson();
      final response = await translateHandlerErrors(
        handlers.handleUpdatePredictiveConfig(
          Request(
            'POST',
            Uri.parse('http://localhost/api/focus-model/predictive/config'),
            body: jsonEncode(payload),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.badRequest);
    });

    test('predict without a filter cannot key the per-filter model', () async {
      await seedTrustedModel();
      final body = await getJson(
        handlers.handlePredictFocus(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/focus-model/predict?temperature=6.0',
            ),
          ),
        ),
      );
      expect(body['canPredict'], isFalse);
    });

    // ── STEP 4: HTTP should-refocus == run-time decision for shared inputs ──
    test(
      'should-refocus equals the run-time gate (drift exceeds budget)',
      () async {
        await seedTrustedModel();
        // 20°C drift on a ~47 steps/°C model ⇒ ~940 steps expected drift,
        // well over a 50-step budget ⇒ the run would refocus.
        const currentTemp = 25.0;
        const lastFocusTemp = 5.0;
        const maxDrift = 50.0;

        final body = await getJson(
          handlers.handleShouldRefocus(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/focus-model/should-refocus'
                '?currentTemp=$currentTemp&lastFocusTemp=$lastFocusTemp'
                '&maxDriftSteps=$maxDrift&filter=$filter',
              ),
            ),
          ),
        );

        // Independently reproduce the run-time gate from the SAME model.
        final runModel = await runService.getModel(
          equipmentProfileId: profileId,
          filterName: filter,
        );
        final runDecision = await runService.evaluateForFilter(
          equipmentProfileId: profileId,
          filterName: filter,
          temperatureCelsius: currentTemp,
        );
        final runReliable = runDecision.targetPosition != null;
        final runExpectedDrift =
            (currentTemp - lastFocusTemp).abs() *
            runModel!.slopeStepsPerC.abs();
        final runShouldRefocus = runReliable && runExpectedDrift >= maxDrift;

        expect(body['hasModel'], isTrue);
        expect(body['modelIsReliable'], runReliable);
        expect(
          (body['expectedDrift'] as num).toDouble(),
          closeTo(runExpectedDrift, 1e-6),
        );
        expect(body['shouldRefocus'], runShouldRefocus);
        expect(body['shouldRefocus'], isTrue);
      },
    );

    test(
      'should-refocus equals the run-time gate (drift within budget)',
      () async {
        await seedTrustedModel();
        // 0.5°C drift ⇒ ~24 steps, under a 50-step budget ⇒ no refocus.
        const currentTemp = 6.0;
        const lastFocusTemp = 5.5;
        const maxDrift = 50.0;

        final body = await getJson(
          handlers.handleShouldRefocus(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/focus-model/should-refocus'
                '?currentTemp=$currentTemp&lastFocusTemp=$lastFocusTemp'
                '&maxDriftSteps=$maxDrift&filter=$filter',
              ),
            ),
          ),
        );

        final runModel = await runService.getModel(
          equipmentProfileId: profileId,
          filterName: filter,
        );
        final runExpectedDrift =
            (currentTemp - lastFocusTemp).abs() *
            runModel!.slopeStepsPerC.abs();

        expect(body['hasModel'], isTrue);
        expect(body['shouldRefocus'], isFalse);
        expect(
          (body['expectedDrift'] as num).toDouble(),
          closeTo(runExpectedDrift, 1e-6),
        );
        expect(runExpectedDrift, lessThan(maxDrift));
      },
    );

    test(
      'should-refocus reports no model when the run has not learned the filter',
      () async {
        // No seeding: the run has no per-filter model, so it would not skip a
        // sweep on a drift estimate.
        final body = await getJson(
          handlers.handleShouldRefocus(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/focus-model/should-refocus'
                '?currentTemp=25.0&lastFocusTemp=5.0&filter=$filter',
              ),
            ),
          ),
        );
        expect(body['hasModel'], isFalse);
        expect(body['modelIsReliable'], isFalse);
        expect(body['shouldRefocus'], isFalse);
      },
    );

    test('response JSON shape (contract) is unchanged', () async {
      await seedTrustedModel();
      final body = await getJson(
        handlers.handleShouldRefocus(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/focus-model/should-refocus'
              '?currentTemp=25.0&lastFocusTemp=5.0&filter=$filter',
            ),
          ),
        ),
      );
      // The slave (NetworkBackend.shouldRefocus) reads exactly these keys.
      expect(
        body.keys,
        containsAll(<String>[
          'profileId',
          'currentTemp',
          'lastFocusTemp',
          'tempDelta',
          'maxDriftSteps',
          'expectedDrift',
          'shouldRefocus',
          'hasModel',
          'modelIsReliable',
        ]),
      );
    });
  });
}
