import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'async_scope.dart';
import 'auto_stretch_provider.dart';
import 'backend_provider.dart';
import 'calibration_service_providers.dart';
import 'capability_provider.dart';
import 'dark_library_provider.dart';
import 'database_provider.dart';
import 'live_stacking_service_provider.dart';
import 'logging_service_provider.dart';
import '../services/stack_and_share_service.dart';
import '../services/stacking_engine_seam.dart';
import 'stack_light_selector_provider.dart';
import 'stack_share_export_service_provider.dart';

/// Provider for the [StackAndShareService].
///
/// The service reads the selector, calibration, dark-library, DAO, and
/// live-stacking providers when a run needs them, so it follows the same Drift
/// instance and backend as the rest of the app, and so test overrides flow
/// through.
final stackAndShareServiceProvider = Provider<StackAndShareService>((ref) {
  ref.watch(backendProvider);
  final exportService = ref.watch(stackShareExportServiceProvider);
  return stackAndShareServiceFor(
    ref,
    persistPreview: ({required result, required rgba}) {
      return exportService.persistViewerPreview(result: result, rgba: rgba);
    },
  );
});

/// A [StackAndShareService] for the backend that is current for [ref], reading
/// its collaborators through [ref]. It goes stale when the backend changes and
/// when [ref]'s provider is disposed or rebuilt.
StackAndShareService stackAndShareServiceFor(
  Ref ref, {
  StackingEngineSeam engine = const BridgeStackingEngineSeam(),
  StackResultPreviewPersister? persistPreview,
}) => StackAndShareService(
  host: ref.providerBackendScope(),
  logger: ref.read(loggingServiceProvider),
  selector: () => ref.read(stackLightSelectorProvider),
  calibration: () => ref.read(calibrationServiceProvider),
  darkLibrary: () => ref.read(darkLibraryServiceProvider),
  imagesDao: () => ref.read(imagesDaoProvider),
  sessionsDao: () => ref.read(sessionsDaoProvider),
  resultsDao: () => ref.read(stackedResultsDaoProvider),
  liveStacking: () => ref.read(liveStackingServiceProvider),
  calibrationSettings: () => ref.read(calibrationSettingsProvider),
  darkMatchTolerances: () => ref.read(darkLibraryMatchTolerancesProvider),
  connectedCameraId: () => ref.read(connectedCameraIdProvider),
  cameraCapabilities: (cameraId) =>
      ref.read(cameraCapabilitiesProvider(cameraId).future),
  engine: engine,
  persistPreview: persistPreview,
);
