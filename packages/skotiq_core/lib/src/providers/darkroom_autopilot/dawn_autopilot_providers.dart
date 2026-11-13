/// Riverpod wiring for the dawn autopilot.
///
/// Every collaborator is a constructor argument on the services themselves, so
/// a test assembles the pipeline with a scripted Darkroom seam, a recording
/// notifier and a fixed clock. These providers are the production assembly of
/// the same pieces, and they are what the run-completion coordinator and the
/// Phase C "process this session now" action read.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

import '../../database/daos/images_dao.dart';
import '../../database/daos/integrated_masters_dao.dart';
import '../../database/daos/recipes_dao.dart';
import '../database_provider.dart';
import '../../database/daos/targets_dao.dart';
import '../settings_provider.dart';
import '../../services/color_calibration_service.dart' show StarConeSearch;
import '../darkroom_delivery/delivery_providers.dart';
import '../../services/darkroom_autopilot/darkroom_seam.dart';
import '../../services/darkroom_autopilot/dawn_autopilot_service.dart';
import '../../services/darkroom_autopilot/dawn_draft_builder.dart';
import '../../services/darkroom_autopilot/dawn_master_resolver.dart';
import '../../services/darkroom_autopilot/dawn_morning_notifier.dart';
import '../../services/darkroom_autopilot/dawn_photometry.dart';
import '../output_locations_provider.dart';
import '../darkroom_pass/pass_providers.dart' show passReporterProvider;
import '../logging_service_provider.dart';
import '../notification_service_provider.dart';
import '../science/photometric_catalog_service_provider.dart';

/// The five Darkroom FFI entry points.
final darkroomSeamProvider = Provider<DarkroomSeam>(
  (ref) => const BridgeDarkroomSeam(),
);

/// The catalogue cone search the Darkroom's photometry comes from.
///
/// Uses the same APASS cache and online preference as science photometry.
final dawnCatalogConeSearchProvider = Provider<StarConeSearch>((ref) {
  final catalog = ref.watch(photometricCatalogServiceProvider);
  return (center, radiusDegrees, {maxMagnitude}) async {
    final result = await catalog.coneSearch(
      raDegrees: center.raDegrees,
      decDegrees: center.dec,
      radiusDegrees: radiusDegrees,
      maxMagnitude: maxMagnitude ?? 17.0,
    );
    return [
      for (final star in result.stars)
        Star(
          id: '${star.raDegrees}:${star.decDegrees}',
          name: '',
          coordinates: CelestialCoordinate(
            ra: star.raDegrees / 15.0,
            dec: star.decDegrees,
          ),
          magnitude: star.magV,
          colorIndex: star.colorIndexBv,
        ),
    ];
  };
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
    darkroomDirectory: () async =>
        (await ref.read(outputLocationsProvider.future)).darkroom.path,
    logger: ref.watch(loggingServiceProvider),
    passReporter: ref.watch(passReporterProvider),
  );
});

