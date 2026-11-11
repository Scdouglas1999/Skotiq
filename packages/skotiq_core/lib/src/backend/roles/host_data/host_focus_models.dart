


/// The predictive autofocus settings and per-filter focus models of a linked
/// imaging host.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostFocusModels {
  Future<Map<String, dynamic>> getPredictiveAfSettings();

  Future<void> updatePredictiveAfConfig(Map<String, dynamic> config);

  Future<void> clearPredictiveAfSamples(String filterName);

  Future<String?> exportPredictiveAfModel(String filterName);

  Future<void> clearFocusModelData();

  Future<Map<String, dynamic>> getFocusModel();

  Future<void> addFocusDataPoint({
    required double temperature,
    required int position,
    double? hfr,
    String? filter,
  });

  Future<Map<String, dynamic>> exportFocusModel();

  Future<void> importFocusModel(Map<String, dynamic> data);

  Future<Map<String, dynamic>> getFilterFocusOffsets();

  Future<void> setFilterFocusOffsets({
    required String referenceFilter,
    required Map<String, int> offsets,
  });

  Future<Map<String, dynamic>> getFocusModelData();
}
