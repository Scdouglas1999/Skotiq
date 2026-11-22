import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/science/photometric_catalog_service.dart';
import '../database_provider.dart';
import '../logging_service_provider.dart';

final photometricCatalogServiceProvider = Provider<PhotometricCatalogService>((
  ref,
) {
  final service = PhotometricCatalogService(
    logger: () => ref.read(loggingServiceProvider),
    settingsDao: () => ref.read(settingsDaoProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});
