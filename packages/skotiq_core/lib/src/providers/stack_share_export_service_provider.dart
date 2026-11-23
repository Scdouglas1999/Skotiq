import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/stack_share_export_service.dart';
import 'database_provider.dart';
import 'logging_service_provider.dart';
import 'profiles_provider.dart';

/// Provider for the [StackShareExportService].
///
/// The service reads the results DAO, active equipment profile, and logging
/// providers at each call so it follows the same Drift instance and backend
/// as the rest of the app, and so test overrides flow through. The save
/// functions default to the native bridge; tests construct the service directly
/// with pure-Dart substitutes.
final stackShareExportServiceProvider = Provider<StackShareExportService>((
  ref,
) {
  return StackShareExportService(
    logger: () => ref.read(loggingServiceProvider),
    resultsDao: () => ref.read(stackedResultsDaoProvider),
    activeProfile: () => ref.read(activeEquipmentProfileProvider),
  );
});
