import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/science/science_backend.dart';
import '../../services/science/default_science_backend.dart';
import '../backend_provider.dart';
import '../database_provider.dart';
import '../logging_service_provider.dart';
import '../plate_solve_service_provider.dart';
import '../settings_provider.dart';
import 'photometric_catalog_service_provider.dart';

final scienceBackendProvider = Provider<ScienceBackend>((ref) {
  return DefaultScienceBackend(
    backend: () => ref.read(imagingBackendProvider),
    logger: () => ref.read(loggingServiceProvider),
    appSettings: () => ref.read(appSettingsProvider).valueOrNull,
    plateSolver: () => ref.read(plateSolveServiceProvider),
    catalog: () => ref.read(photometricCatalogServiceProvider),
    imagesDao: () => ref.read(imagesDaoProvider),
    settingsDao: () => ref.read(settingsDaoProvider),
  );
});
