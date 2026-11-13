import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import '../services/master_annotation_service.dart';

/// Provider for the [MasterAnnotationService]. Binds the real on-disk catalogs;
/// tests construct the service directly with in-memory cone-search stubs.
final masterAnnotationServiceProvider = Provider<MasterAnnotationService>((
  ref,
) {
  return MasterAnnotationService(
    dsoSearch: CatalogManager.instance.searchDsoNearby,
    starSearch: (center, radiusDegrees, {maxMagnitude}) => CatalogManager
        .instance
        .stars
        .getStarsNear(center, radiusDegrees, maxMagnitude: maxMagnitude),
  );
});
