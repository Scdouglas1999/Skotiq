/// The captured-image rows of a linked imaging host.
abstract interface class HostImageRecords {
  Future<List<Map<String, dynamic>>> getAllImageRows();

  /// Fetch one captured-image row by id.
  Future<Map<String, dynamic>?> getCapturedImageById(int id);

  Future<List<Map<String, dynamic>>> getSessionImageRows(int sessionId);

  /// Images for a target.
  Future<List<Map<String, dynamic>>> getImagesForTarget(int targetId);
}
