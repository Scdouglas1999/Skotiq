import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/session_report.dart';
import '../services/local_imaging_records.dart';
import '../services/session_report_service.dart';
import 'database_provider.dart';
import 'sequence_stats_provider.dart';

/// Service provider for [SessionReportService].
///
/// The report is derived from the imaging host's sessions, frames, runs and
/// targets.
final sessionReportServiceProvider = Provider<SessionReportService>((ref) {
  return SessionReportService(
    records: ref.watch(imagingRecordsProvider),
    runs: ref.watch(runHistoryProvider),
    targets: ref.watch(targetLibraryProvider),
    scienceDao: ref.watch(scienceDaoProvider),
  );
});

/// Builds a [SessionReport] for a specific session.
///
/// Family-keyed so multiple session reports can be cached concurrently from
/// the analytics screen (e.g. when opening a report dialog while a different
/// one is already on screen).
final sessionReportProvider = FutureProvider.autoDispose
    .family<SessionReport, int>((ref, sessionId) async {
      final service = ref.watch(sessionReportServiceProvider);
      return service.buildReport(sessionId);
    });
