part of '../network_backend.dart';

/// The predictive autofocus settings and per-filter focus models of a linked
/// imaging host.
final class HostFocusModels {
  HostFocusModels(this._host);

  final NetworkBackend _host;

  /// Get the real per-filter predictive-AF config and models used by the host.
  Future<Map<String, dynamic>> getPredictiveAfSettings() async {
    return _host._get(FocusModelApi.getPredictiveSettings);
  }

  Future<void> updatePredictiveAfConfig(Map<String, dynamic> config) async {
    await _host._post(FocusModelApi.updatePredictiveConfig, body: config);
  }

  Future<void> clearPredictiveAfSamples(String filterName) async {
    await _host._post(
      FocusModelApi.clearPredictiveSamples,
      body: {'filter': filterName},
    );
  }

  Future<String?> exportPredictiveAfModel(String filterName) async {
    final response = await _host._get(
      FocusModelApi.exportPredictiveModel,
      query: {'filter': filterName},
    );
    return response['json'] as String?;
  }

  Future<void> clearFocusModelData() async {
    await _host._delete(FocusModelApi.clearFocusData);
  }

  Future<Map<String, dynamic>> getFocusModel() async {
    return await _host._get(FocusModelApi.getFocusModel);
  }

  Future<void> addFocusDataPoint({
    required double temperature,
    required int position,
    double? hfr,
    String? filter,
  }) async {
    await _host._post(
      FocusModelApi.addFocusPoint,
      body: {
        'temperature': temperature,
        'position': position,
        if (hfr != null) 'hfr': hfr,
        if (filter != null) 'filter': filter,
      },
    );
  }

  Future<Map<String, dynamic>> exportFocusModel() async {
    return await _host._get(FocusModelApi.exportFocusData);
  }

  Future<void> importFocusModel(Map<String, dynamic> data) async {
    await _host._post(FocusModelApi.importFocusData, body: data);
  }

  Future<Map<String, dynamic>> getFilterFocusOffsets() async {
    return await _host._get(FocusModelApi.getFilterOffsets);
  }

  Future<void> setFilterFocusOffsets({
    required String referenceFilter,
    required Map<String, int> offsets,
  }) async {
    await _host._post(
      FocusModelApi.setFilterOffsets,
      body: {'referenceFilter': referenceFilter, 'offsets': offsets},
    );
  }

  Future<Map<String, dynamic>> getFocusModelData() async {
    return await _host._get(FocusModelApi.getFocusData);
  }
}
