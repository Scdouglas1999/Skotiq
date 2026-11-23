import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_core/utils.dart';

/// Pushes the persisted observer site to the Rust backend whenever settings
/// change. Settings are the one source of truth; the planetarium reads them
/// through [planetariumInputOverrides].
///
/// This deliberately does **not** auto-detect a location on first launch. Free
/// IP services resolve to the ISP's egress point and disagree with each other
/// by a hundred kilometers or more, yet a persisted estimate is rendered
/// exactly like a site the user typed. The estimate stays one click away: the
/// onboarding observing-site step offers it as a labeled suggestion, and
/// Settings → Location has the same affordance.
///
/// The backend must NOT receive the 0/0 sentinel. Its site is
/// `Option<ObserverLocation>`, `None` is its only way to say "no site", and
/// every native consumer reads a `Some` as a site the user chose (the
/// simulated mount reported a parked altitude of −78° when it was handed
/// 0/0/0). So the backend is given [AppSettingsState.observerSite], null until
/// the user sets a site.
final locationSyncProvider = Provider<void>((ref) {
  ref.listen(appSettingsProvider, (previous, next) {
    next.whenData((settings) {
      // Deferred to a microtask: Riverpod throws if a provider is modified during build.
      Future.microtask(
        () => _syncLocationToBackend(ref, settings.observerSite),
      );
    });
  });

  ref.read(appSettingsProvider).whenData((settings) {
    Future.microtask(() => _syncLocationToBackend(ref, settings.observerSite));
  });
});

/// The planetarium cannot depend on skotiq_core, so the app overrides the
/// planetarium's inputs with readers of core: the site from settings, the
/// site's altitude floor by azimuth, and the target scorer for Best Targets
/// Tonight (this process's, or the linked host's).
List<Override> planetariumInputOverrides() => [
      observerLocationProvider.overrideWith((ref) {
        final observer = PlanetariumObserverNotifier();
        final site = ref.watch(
          appSettingsProvider.select(
            (s) => s
                .whenData(
                  (s) => (
                    latitude: s.latitude,
                    longitude: s.longitude,
                    elevation: s.elevation,
                  ),
                )
                .valueOrNull,
          ),
        );
        if (site != null) {
          observer.setLocation(
            latitude: site.latitude,
            longitude: site.longitude,
            elevation: site.elevation,
          );
        }
        return observer;
      }),
      planetariumAltitudeFloorProvider
          .overrideWith((ref) => ref.watch(altitudeFloorProvider).asSamples()),
      planetariumNightScorerProvider
          .overrideWith((ref) => ref.watch(targetScorerProvider).scoreForNight),
    ];

/// Sync location to the Rust backend (for Provider ref).
///
/// [site] is null when the operator has not set one, and null is what the
/// backend must be told: it has no coordinate that means "unset".
///
/// Skipped for a linked client: its settings are the host's, mirrored, and the
/// host owns its site. Pushing them back would rewrite the host's settings and
/// could restore a site the host has since changed. A location edited on the
/// client reaches the host through the settings save.
Future<void> _syncLocationToBackend(Ref ref, ObserverLocation? site) async {
  if (ref.read(isRemoteModeProvider)) return;
  try {
    final backend = ref.read(profileSettingsBackendProvider);
    Log.debug(
      site == null
          ? 'Clearing observer location in Rust backend: no site is set'
          : 'Syncing observer location to Rust backend: '
              'lat=${site.latitude}, lon=${site.longitude}, '
              'elev=${site.elevation}',
      source: 'LocationSync',
    );
    await backend.setLocation(site);
    Log.debug(
      'Observer location synced successfully to Rust backend',
      source: 'LocationSync',
    );
  } catch (e, stackTrace) {
    Log.warning(
      'Failed to sync observer location to Rust backend: $e',
      source: 'LocationSync',
      error: e,
      stackTrace: stackTrace,
    );
  }
}
