/// Frame-Failure Forensics: Riverpod wiring.
///
/// Exposes the [ForensicsService] singleton + a stream provider that
/// the dashboard panel listens to. The service is constructed lazily
/// from the global database; tests inject their own service via
/// `forensicsServiceProvider.overrideWith(...)`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/forensics/frame_forensics.dart';
import '../services/forensics_service.dart';
import 'database_provider.dart';

/// Singleton [ForensicsService] backed by the global database. Disposed
/// when the provider is disposed (closes the broadcast stream).
final forensicsServiceProvider = Provider<ForensicsService>((ref) {
  final db = ref.watch(databaseProvider);
  final service = ForensicsService(db);
  ref.onDispose(() => service.dispose());
  return service;
});

/// Live broadcast of new [FrameForensicsRecord]s persisted since
/// subscription. Used by the Run Dashboard's Forensics panel to append
/// new rows in real time. The panel uses
/// [forensicsRecordsForSessionProvider] for the initial backfill.
final forensicsStreamProvider = StreamProvider<FrameForensicsRecord>((ref) {
  final svc = ref.watch(forensicsServiceProvider);
  return svc.stream;
});

/// Backfill provider — fetches recent records for a given session.
/// Pass the active session id (or null when no session is selected to
/// get an empty list).
final forensicsRecordsForSessionProvider = FutureProvider.family
    .autoDispose<List<FrameForensicsRecord>, String?>((ref, sessionId) async {
      if (sessionId == null) return const <FrameForensicsRecord>[];
      final svc = ref.watch(forensicsServiceProvider);
      return svc.loadRecentForSession(sessionId);
    });
