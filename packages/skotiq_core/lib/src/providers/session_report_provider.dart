import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/session_report.dart';
import '../services/imaging_records_repository.dart';
import '../services/session_report_service.dart';
import 'database_provider.dart';
import 'sequence_stats_provider.dart';

/// Service provider for [SessionReportService].
///
/// Wires the three DAOs needed to derive the report from persisted Drift
/// rows (sessions / captured_images / sequence_runs / targets).
final sessionReportServiceProvider = Provider<SessionReportService>((ref) {
  return SessionReportService(
    records: ref.watch(imagingRecordsRepositoryProvider),
    sequenceRunsDao: ref.watch(sequenceRunsDaoProvider),
    targetsDao: ref.watch(targetsDaoProvider),
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
