import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/stack_share_export_service.dart';

/// Provider for the [StackShareExportService].
///
/// Reads the results DAO, active equipment profile, and logging providers
/// lazily inside the service so it follows the same Drift instance and backend
/// as the rest of the app, and so test overrides flow through. The save
/// functions default to the native bridge; tests construct the service directly
/// with pure-Dart substitutes.
final stackShareExportServiceProvider = Provider<StackShareExportService>((
  ref,
) {
  return StackShareExportService(ref);
});
