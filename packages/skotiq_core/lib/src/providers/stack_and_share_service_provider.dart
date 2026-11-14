import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'backend_provider.dart';
import '../services/stack_and_share_service.dart';
import 'stack_share_export_service_provider.dart';

/// Provider for the [StackAndShareService].
///
/// Reads the selector, calibration, dark-library, DAO, and live-stacking
/// providers lazily inside the service so it follows the same Drift instance
/// and backend as the rest of the app, and so test overrides flow through.
final stackAndShareServiceProvider = Provider<StackAndShareService>((ref) {
  ref.watch(backendProvider);
  final exportService = ref.watch(stackShareExportServiceProvider);
  return StackAndShareService(
    ref,
    persistPreview: ({required result, required rgba}) {
      return exportService.persistViewerPreview(result: result, rgba: rgba);
    },
  );
});
