
/// One-shot reads and writes of the saved targets of a linked imaging host.
abstract interface class HostTargetRecords {
  /// Get all targets from the headless server
  /// Returns JSON maps that can be used to construct CelestialTarget objects
  Future<List<Map<String, dynamic>>> getAllTargets();

  /// Get a specific target by ID
  Future<Map<String, dynamic>?> getTargetById(int id);

  /// Search targets by query string
  Future<List<Map<String, dynamic>>> searchTargets(String query);

  /// Create a new target
  Future<int> createTarget(Map<String, dynamic> target);

  /// Update an existing target
  Future<void> updateTarget(int id, Map<String, dynamic> target);
}
