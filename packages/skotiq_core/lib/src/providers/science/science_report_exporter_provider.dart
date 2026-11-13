import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app_version_provider.dart';
import '../database_provider.dart';
import '../../services/science/science_report_exporter.dart';

/// Riverpod provider — the exporter is stateless beyond its DAO refs, so
/// we can construct it on every read with no performance penalty.
final scienceReportExporterProvider = Provider<ScienceReportExporter>((ref) {
  return ScienceReportExporter(
    imagesDao: ref.watch(imagesDaoProvider),
    scienceDao: ref.watch(scienceDaoProvider),
    sessionsDao: ref.watch(sessionsDaoProvider),
    targetsDao: ref.watch(targetsDaoProvider),
    softwareLabel: ref.watch(appVersionLabelProvider),
  );
});
