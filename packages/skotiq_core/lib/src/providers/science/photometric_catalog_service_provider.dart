import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/science/photometric_catalog_service.dart';

final photometricCatalogServiceProvider = Provider<PhotometricCatalogService>((
  ref,
) {
  return PhotometricCatalogService(ref);
});
