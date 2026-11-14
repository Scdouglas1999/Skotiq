part of '../predictive_af_service.dart';

class PredictiveAfSettingsSnapshot {
  final PredictiveAfConfig config;
  final List<FilterFocusModel> models;

  const PredictiveAfSettingsSnapshot({
    required this.config,
    required this.models,
  });
}

/// Predictive autofocus settings and fitted models of whichever machine is
/// the imaging host.
abstract interface class PredictiveAfSettingsController {
  Future<PredictiveAfSettingsSnapshot> load({int? equipmentProfileId});

  Future<void> updateConfig(PredictiveAfConfig config);

  Future<void> clearSamples({
    required int? equipmentProfileId,
    required String filterName,
  });

  Future<String?> exportModel({
    required int? equipmentProfileId,
    required String filterName,
  });
}

final class LocalPredictiveAfSettings
    implements PredictiveAfSettingsController {
  LocalPredictiveAfSettings(this._service);

  final PredictiveAfService _service;

  @override
  Future<PredictiveAfSettingsSnapshot> load({int? equipmentProfileId}) async {
    await _service.hydrated;
    return PredictiveAfSettingsSnapshot(
      config: _service.config,
      models: await _service.listModels(equipmentProfileId: equipmentProfileId),
    );
  }

  @override
  Future<void> updateConfig(PredictiveAfConfig config) =>
      _service.updateConfig(config);

  @override
  Future<void> clearSamples({
    required int? equipmentProfileId,
    required String filterName,
  }) => _service.clearSamples(
    equipmentProfileId: equipmentProfileId,
    filterName: filterName,
  );

  @override
  Future<String?> exportModel({
    required int? equipmentProfileId,
    required String filterName,
  }) => _service.exportModel(
    equipmentProfileId: equipmentProfileId,
    filterName: filterName,
  );
}

/// The host keeps one set of models, for its active equipment profile.
final class HostPredictiveAfSettings implements PredictiveAfSettingsController {
  HostPredictiveAfSettings(this._host);

  final HostFocusModels _host;

  @override
  Future<PredictiveAfSettingsSnapshot> load({int? equipmentProfileId}) async {
    final response = await _host.getPredictiveAfSettings();
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
        Log.warning(
          'Skipping an unreadable predictive-AF model row from the host: '
          '$error',
          source: 'PredictiveAfService',
          error: error,
        );
      }
    }
    return PredictiveAfSettingsSnapshot(
      config: PredictiveAfConfig.fromJson(Map<String, dynamic>.from(configRaw)),
      models: models,
    );
  }

  @override
  Future<void> updateConfig(PredictiveAfConfig config) =>
      _host.updatePredictiveAfConfig(config.toJson());

  @override
  Future<void> clearSamples({
    required int? equipmentProfileId,
    required String filterName,
  }) => _host.clearPredictiveAfSamples(filterName);

  @override
  Future<String?> exportModel({
    required int? equipmentProfileId,
    required String filterName,
  }) => _host.exportPredictiveAfModel(filterName);
}
