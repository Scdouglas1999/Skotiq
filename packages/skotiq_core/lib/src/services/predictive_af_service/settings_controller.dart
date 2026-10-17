part of '../predictive_af_service.dart';

class PredictiveAfSettingsSnapshot {
  final PredictiveAfConfig config;
  final List<FilterFocusModel> models;

  const PredictiveAfSettingsSnapshot({
    required this.config,
    required this.models,
  });
}

/// Settings-facing facade that keeps predictive AF host-authoritative. A
/// remote companion never reads or mutates its private phone database.
class PredictiveAfSettingsController {
  final Ref _ref;
  final SkotiqBackend _backend;

  PredictiveAfSettingsController(this._ref, this._backend);

  Future<PredictiveAfSettingsSnapshot> load({int? equipmentProfileId}) async {
    final backend = _backend;
    if (backend is NetworkBackend) {
      final response = await backend.getPredictiveAfSettings();
      final configRaw = response['config'];
      final modelsRaw = response['models'];
      if (configRaw is! Map || modelsRaw is! List) {
        throw const FormatException('Invalid predictive AF response');
      }
      final models = <FilterFocusModel>[];
      for (final raw in modelsRaw) {
        if (raw is! Map) continue;
        try {
          models.add(
            FilterFocusModel.fromWireJson(Map<String, dynamic>.from(raw)),
          );
        } on Object catch (error) {
          // A single corrupted historic row must not hide every healthy model,
          // but the operator's model list is now short by one and nothing else
          // reports that — say so instead of letting the row vanish silently.
          developer.log(
            'Skipping an unreadable predictive-AF model row from the host: '
            '$error',
            name: 'PredictiveAfService',
            level: 900,
            error: error,
          );
        }
      }
      return PredictiveAfSettingsSnapshot(
        config: PredictiveAfConfig.fromJson(
          Map<String, dynamic>.from(configRaw),
        ),
        models: models,
      );
    }

    final service = _ref.read(predictiveAfServiceProvider);
    await service.hydrated;
    return PredictiveAfSettingsSnapshot(
      config: service.config,
      models: await service.listModels(equipmentProfileId: equipmentProfileId),
    );
  }

  Future<void> updateConfig(PredictiveAfConfig config) async {
    final backend = _backend;
    if (backend is NetworkBackend) {
      await backend.updatePredictiveAfConfig(config.toJson());
      return;
    }
    await _ref.read(predictiveAfServiceProvider).updateConfig(config);
  }

  Future<void> clearSamples({
    required int? equipmentProfileId,
    required String filterName,
  }) async {
    final backend = _backend;
    if (backend is NetworkBackend) {
      await backend.clearPredictiveAfSamples(filterName);
      return;
    }
    await _ref
        .read(predictiveAfServiceProvider)
        .clearSamples(
          equipmentProfileId: equipmentProfileId,
          filterName: filterName,
        );
  }

  Future<String?> exportModel({
    required int? equipmentProfileId,
    required String filterName,
  }) async {
    final backend = _backend;
    if (backend is NetworkBackend) {
      return backend.exportPredictiveAfModel(filterName);
    }
    return _ref
        .read(predictiveAfServiceProvider)
        .exportModel(
          equipmentProfileId: equipmentProfileId,
          filterName: filterName,
        );
  }
}

final predictiveAfSettingsControllerProvider =
    Provider<PredictiveAfSettingsController>((ref) {
      final backend = ref.watch(backendProvider);
      return PredictiveAfSettingsController(ref, backend);
    });

/// See [PredictiveAfStatus].
final lastPredictiveAfStatusProvider = StateProvider<PredictiveAfStatus?>(
  (ref) => null,
);
