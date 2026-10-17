part of '../polar_alignment_provider.dart';

/// Provider for polar alignment history from database.
///
/// On a remote client (`NetworkBackend`) the slave never runs the local
/// alignment loop, so its `polar_alignment_history` table is always empty.
/// We branch to the host's `GET /api/polar-alignment-history`
/// (`fetchPolarAlignmentHistory()`) and map each
/// [RemotePolarAlignmentHistoryEntry] onto the local entry shape. The local
/// DAO path is unchanged for the host backend.
final polarAlignmentHistoryProvider =
    FutureProvider.family<List<PolarAlignmentHistoryEntry>, int?>((
      ref,
      profileId,
    ) async {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        final entries = await _fetchRemotePolarHistory(backend, profileId);
        return entries.take(20).toList();
      }
      final db = ref.watch(databaseProvider);
      return db.polarAlignmentHistoryDao.getHistoryForProfile(
        profileId,
        limit: 20,
      );
    });

/// Provider for the last alignment result
final lastPolarAlignmentProvider =
    FutureProvider.family<PolarAlignmentHistoryEntry?, int?>((
      ref,
      profileId,
    ) async {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        final entries = await _fetchRemotePolarHistory(backend, profileId);
        return entries.isEmpty ? null : entries.first;
      }
      final db = ref.watch(databaseProvider);
      return db.polarAlignmentHistoryDao.getLastAlignment(profileId);
    });

/// Provider for watching history changes (stream)
final polarAlignmentHistoryStreamProvider =
    StreamProvider.family<List<PolarAlignmentHistoryEntry>, int?>((
      ref,
      profileId,
    ) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _pollRemotePolarHistory(backend, profileId);
      }
      final db = ref.watch(databaseProvider);
      return db.polarAlignmentHistoryDao.watchHistory(profileId);
    });

/// Polls the host's polar-alignment history, emitting only on change (mirrors
/// the `_pollRemote` change-guard in `database_provider.dart`).
Stream<List<PolarAlignmentHistoryEntry>> _pollRemotePolarHistory(
  NetworkBackend backend,
  int? profileId, {
  Duration interval = const Duration(seconds: 10),
}) => resilientDistinctPoll(
  fetch: () => _fetchRemotePolarHistory(backend, profileId),
  unchanged: listEquals,
  interval: interval,
  onRetainedError: (error, stackTrace) {
    developer.log(
      'Remote polar-history poll failed; retaining last value',
      name: 'PolarAlignmentStateNotifier',
      level: 900,
      error: error,
      stackTrace: stackTrace,
    );
  },
);

Future<List<PolarAlignmentHistoryEntry>> _fetchRemotePolarHistory(
  NetworkBackend backend,
  int? profileId,
) async {
  final page = await backend.fetchPolarAlignmentHistory(
    equipmentProfileId: profileId,
  );
  final mapped = page.items.map(_polarEntryFromRemote).toList()
    // Newest-first so `.first` is the most recent alignment.
    ..sort((a, b) => b.completedAt.compareTo(a.completedAt));
  return mapped;
}

PolarAlignmentHistoryEntry _polarEntryFromRemote(
  RemotePolarAlignmentHistoryEntry row,
) {
  return PolarAlignmentHistoryEntry(
    id: row.id,
    equipmentProfileId: row.equipmentProfileId,
    initialAzimuthError: row.initialAzimuthError ?? 0.0,
    initialAltitudeError: row.initialAltitudeError ?? 0.0,
    initialTotalError: row.initialTotalError ?? 0.0,
    finalAzimuthError: row.finalAzimuthError ?? 0.0,
    finalAltitudeError: row.finalAltitudeError ?? 0.0,
    finalTotalError: row.finalTotalError ?? 0.0,
    startedAt: row.startedAt,
    completedAt: row.completedAt,
    autoCompleted: row.autoCompleted,
    isNorth: row.isNorth,
    configJson: row.configJson ?? '{}',
  );
}
