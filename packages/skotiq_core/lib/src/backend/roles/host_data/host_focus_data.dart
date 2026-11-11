
/// Filter focus offsets and the focus model of a linked imaging host.
abstract interface class HostFocusData {
  /// Get per-filter focus offsets
  Future<Map<String, dynamic>> getFilterFocusOffsets();

  /// Set per-filter focus offsets
  Future<void> setFilterFocusOffsets({
    required String referenceFilter,
    required Map<String, int> offsets,
  });

  /// Clear all focus data points
  Future<void> clearFocusModelData();

  /// Get current focus model
  Future<Map<String, dynamic>> getFocusModel();

  /// Get all focus data points
  Future<Map<String, dynamic>> getFocusModelData();
}
