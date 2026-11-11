
/// One-shot reads and writes of the saved sequences of a linked imaging host.
abstract interface class HostSequenceRecords {
  /// Create a new sequence
  Future<int> createSequence(Map<String, dynamic> sequence);

  /// Duplicate a sequence
  Future<int> duplicateSequence(int sourceId, String newName);

  /// Get all sequence templates
  Future<List<Map<String, dynamic>>> getSequenceTemplates();

  /// Get all sequences
  Future<List<Map<String, dynamic>>> getSequenceList();
}
