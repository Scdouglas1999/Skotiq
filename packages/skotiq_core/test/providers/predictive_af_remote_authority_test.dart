import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  test(
    'predictive AF settings and model actions use the imaging host',
    () async {
      final backend = _MockNetworkBackend();
      const config = PredictiveAfConfig(
        minSamplesForTrust: 10,
        highConfidenceThreshold: 0.85,
      );
      final model = FilterFocusModel(
        uuid: 'model-1',
        equipmentProfileId: 7,
        filterName: 'Ha',
        filterIndex: 2,
        slopeStepsPerC: 47,
        focusOffsetRelativeToLum: 100,
        interceptAtReferenceTemp: 28000,
        referenceTempCelsius: 10,
        lastTrainedAt: DateTime.utc(2026, 7, 1),
        trainingRunCount: 12,
        confidenceScore: 0.98,
        lastUsedAt: DateTime.utc(2026, 7, 2),
        samples: const [
          FocusTrainingSample(
            timestampSecs: 1,
            temperatureCelsius: 10,
            focusPosition: 28000,
            hfr: 1.8,
          ),
        ],
        maxTrainingSamples: 50,
        consecutiveBadPredictions: 0,
        accumulatedDriftSteps: 0,
      );
      when(() => backend.getPredictiveAfSettings()).thenAnswer(
        (_) async => {
          'config': config.toJson(),
          'models': [model.toWireJson()],
        },
      );
      when(
        () => backend.updatePredictiveAfConfig(any()),
      ).thenAnswer((_) async {});
      when(
        () => backend.clearPredictiveAfSamples(any()),
      ).thenAnswer((_) async {});
      when(
        () => backend.exportPredictiveAfModel(any()),
      ).thenAnswer((_) async => '{"schema":"skotiq.focus_model.v1"}');
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(predictiveAfSettingsControllerProvider);

      final snapshot = await controller.load(equipmentProfileId: 999);
      expect(snapshot.config.minSamplesForTrust, 10);
      expect(snapshot.models.single.filterName, 'Ha');
      expect(snapshot.models.single.samples.single.focusPosition, 28000);

      final updated = snapshot.config.copyWith(enabled: false);
      await controller.updateConfig(updated);
      await controller.clearSamples(equipmentProfileId: 999, filterName: 'Ha');
      final exported = await controller.exportModel(
        equipmentProfileId: 999,
        filterName: 'Ha',
      );

      verify(
        () => backend.updatePredictiveAfConfig(updated.toJson()),
      ).called(1);
      verify(() => backend.clearPredictiveAfSamples('Ha')).called(1);
      verify(() => backend.exportPredictiveAfModel('Ha')).called(1);
      expect(exported, contains('skotiq.focus_model.v1'));
      expect(await database.select(database.focusModels).get(), isEmpty);
    },
  );

  test('invalid confidence ordering is rejected before persistence', () async {
    final service = PredictiveAfService(database);
    addTearDown(service.dispose);

    await expectLater(
      service.updateConfig(
        const PredictiveAfConfig(
          highConfidenceThreshold: 0.6,
          lowConfidenceThreshold: 0.7,
        ),
      ),
      throwsArgumentError,
    );
    expect(service.config, isA<PredictiveAfConfig>());
    expect(service.config.lowConfidenceThreshold, 0.5);
  });
}
