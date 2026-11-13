import '../../../database/database.dart' show PolarAlignmentHistoryEntry;

/// The polar alignments recorded in the imaging host's database, newest
/// first. A null profile id means every profile.
abstract interface class PolarAlignmentLog {
  Future<List<PolarAlignmentHistoryEntry>> getHistoryForProfile(
    int? profileId, {
    int limit = 20,
  });

  Future<PolarAlignmentHistoryEntry?> getLastAlignment(int? profileId);

  Stream<List<PolarAlignmentHistoryEntry>> watchHistory(
    int? profileId, {
    int limit = 20,
  });
}
