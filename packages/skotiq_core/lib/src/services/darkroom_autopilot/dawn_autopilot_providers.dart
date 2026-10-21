/// Riverpod wiring for the dawn autopilot.
///
/// Every collaborator is a constructor argument on the services themselves, so
/// a test assembles the pipeline with a scripted Darkroom seam, a recording
/// notifier and a fixed clock. These providers are the production assembly of
/// the same pieces, and they are what the run-completion coordinator and the
/// Phase C "process this session now" action read.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../../database/daos/images_dao.dart';
import '../../database/daos/integrated_masters_dao.dart';
import '../../database/daos/recipes_dao.dart';
import '../../database/daos/settings_dao.dart';
import '../../database/daos/targets_dao.dart';
import '../../database/daos/darkroom_jobs_dao.dart';
import '../../providers/database_provider.dart';
import '../../providers/settings_provider.dart';
import '../color_calibration_service.dart' show StarConeSearch;
import '../darkroom_delivery/delivery_providers.dart';
import '../logging_service.dart';
import '../notification_service.dart';
import 'darkroom_seam.dart';
import 'dawn_autopilot_service.dart';
import 'dawn_draft_builder.dart';
import 'dawn_master_resolver.dart';
import 'dawn_morning_notifier.dart';
import 'dawn_photometry.dart';

/// No directory is configured to write the night's drafts and report into.
///
/// The job fails with this rather than resolving a relative path against
/// whatever directory the process happens to have been started in: a draft
/// written into a service's working directory is a draft the operator never
/// finds.
class DawnOutputDirectoryException implements Exception {
  const DawnOutputDirectoryException();

  @override
  String toString() =>
      'No image output directory is configured, so there is nowhere to write '
      'the night\'s drafts and report. Set one in Settings.';
}

/// The five Darkroom FFI entry points.
final darkroomSeamProvider = Provider<DarkroomSeam>(
  (ref) => const BridgeDarkroomSeam(),
);

/// The catalogue cone search the Darkroom's photometry comes from.
///
/// Bound to the same on-disk catalogue `ColorCalibrationService` uses, so the
/// stars the Darkroom fits against are the stars the post-session colour gate
/// would have matched.
final dawnCatalogConeSearchProvider = Provider<StarConeSearch>((ref) {
  final catalog = HygStarCatalog();
  return catalog.getStarsNear;
});

/// Resolves the catalogue stars covering a master's field.
final dawnPhotometryResolverProvider = Provider<DawnPhotometryResolver>((ref) {
  return DawnPhotometryResolver(
    coneSearch: ref.watch(dawnCatalogConeSearchProvider),
  );
});

/// Composes first-draft recipes from the registry's own measurements.
final dawnDraftBuilderProvider = Provider<DawnDraftBuilder>((ref) {
  return DawnDraftBuilder(darkroom: ref.watch(darkroomSeamProvider));
});

/// Resolves the masters a session's frames were folded into.
final dawnMasterResolverProvider = Provider<DawnMasterResolver>((ref) {
  final db = ref.watch(databaseProvider);
  return DawnMasterResolver(
    images: ImagesDao(db),
    masters: IntegratedMastersDao(db),
    recipes: RecipesDao(db),
  );
});

/// The morning message, gated by the operator's own event flags.
final dawnMorningNotifierProvider = Provider<DawnMorningNotifier>((ref) {
  return NotificationServiceDawnNotifier(
    notifications: ref.watch(notificationServiceProvider),
    settings: () => ref.read(appSettingsProvider).valueOrNull,
  );
});

/// The dawn autopilot itself.
final dawnAutopilotServiceProvider = Provider<DawnAutopilotService>((ref) {
  final db = ref.watch(databaseProvider);
  return DawnAutopilotService(
    jobs: ref.watch(darkroomJobsDaoProvider),
    recipes: ref.watch(recipesDaoProvider),
    masters: IntegratedMastersDao(db),
    targets: TargetsDao(db),
    resolver: ref.watch(dawnMasterResolverProvider),
    drafts: ref.watch(dawnDraftBuilderProvider),
    darkroom: ref.watch(darkroomSeamProvider),
    photometry: ref.watch(dawnPhotometryResolverProvider),
    delivery: ref.watch(deliveryServiceProvider),
    notifier: ref.watch(dawnMorningNotifierProvider),
    outputDirectory: () => _resolveOutputDirectory(SettingsDao(db)),
    logger: ref.watch(loggingServiceProvider),
  );
});

/// The configured capture output directory, or a typed refusal.
Future<String> _resolveOutputDirectory(SettingsDao settings) async {
  final configured = (await settings.getImageOutputDirectory()).trim();
  if (configured.isEmpty) throw const DawnOutputDirectoryException();
  return configured;
}
