import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'database_provider.dart';
import '../services/mosaic_project_service.dart';
import 'post_session_integration_service_provider.dart';
import 'post_session_seam_provider.dart';

/// Provider for [MosaicProjectService], wiring the v45 mosaic DAOs, the targets
/// DAO (per-panel capture targets), the images DAO, the integrated-masters DAO,
/// the post-session integration service, and the post-session seam (which
/// carries `stitchMosaic`).
final mosaicProjectServiceProvider = Provider<MosaicProjectService>((ref) {
  return MosaicProjectService(
    db: ref.watch(databaseProvider),
    projectsDao: ref.watch(mosaicProjectsDaoProvider),
    panelsDao: ref.watch(mosaicPanelsDaoProvider),
    targetsDao: ref.watch(targetsDaoProvider),
    imagesDao: ref.watch(imagesDaoProvider),
    mastersDao: ref.watch(integratedMastersDaoProvider),
    integrationService: ref.watch(postSessionIntegrationServiceProvider),
    seam: ref.watch(postSessionSeamProvider),
  );
});
