import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// Mirrors the persisted observer location into the planetarium provider and the
/// Rust backend. Settings is the single source of truth; this only fans changes
/// out. Uses `ref.listen` to avoid modifying providers during build.
///
/// This deliberately does **not** auto-detect a location on first launch. Free
/// IP services resolve to the ISP's egress point and disagree with each other
/// by a hundred kilometres or more, yet a persisted estimate is rendered
/// exactly like a site the user typed — twilight times, the astro-dark
/// countdown and the imaging window all quoted off it with no hint that
/// anything is approximate.
///
/// 0/0 is the designed "not set" sentinel and every location-driven surface has
/// an honest empty state for it. The estimate stays one click away: the
/// onboarding observing-site step offers it as a labelled suggestion, and
/// Settings → Location has the same affordance.
///
/// The Rust backend is the one consumer that must NOT receive the sentinel.
/// Its site is `Option<ObserverLocation>`, `None` is its only way to say "no
/// site", and every native consumer reads a `Some` as a site the user chose:
/// the simulated mount reported a parked altitude of −78° on a fresh install
/// because this provider had handed it 0/0/0 as a real site, and the Dashboard
/// printed that number beside a status bar that said `LST --:--`. So the
/// backend is given [AppSettingsState.observerSite] — null until the user sets
/// a site — while the planetarium provider below keeps receiving the raw
/// geometry, for the reason given at the initial-value push.
final locationSyncProvider = Provider<void>((ref) {
  // Use ref.listen to sync settings to planetarium provider and Rust backend whenever settings change
  // This defers the update until after the build phase, avoiding the Riverpod error
  ref.listen(appSettingsProvider, (previous, next) {
    next.whenData((settings) {
      // Schedule the update for after the current build phase
      Future.microtask(() async {
        // Update planetarium provider with settings location
        // This is a temporary update (doesn't persist) - only settings persists
        ref.read(observerLocationProvider.notifier).setLocation(
              latitude: settings.latitude,
              longitude: settings.longitude,
              elevation: settings.elevation,
            );

        // Bridge effectiveHorizonDeg into the planetarium
        // package. We can't make planetarium depend on skotiq_core
        // (core already depends on planetarium for catalog access), so the
        // app layer pumps the value across via this sync provider. The
        // altitude card and rise/set times in object_details_panel read
        // `effectiveHorizonDegProvider` from the planetarium package so
        // they automatically pick up the new value.
        ref.read(planetariumEffectiveHorizonDegProvider.notifier).state =
            settings.effectiveHorizonDeg;

        // Also sync to Rust backend for astronomical calculations. Null
        // until a site is set — see the provider doc.
        await _syncLocationToBackend(ref, settings.observerSite);
      });
    });
  });

  // Handle initial value if settings are already loaded.
  //
  // This pushes unconditionally, exactly as the listener above does. Gating it
  // on "not 0/0" made the planetarium observer depend on whether any settings
  // change had fired yet: before one, it held the package's Los Angeles
  // constructor default; after one, the 0/0 sentinel. Both are wrong for an
  // unconfigured site and neither is distinguishable from a real site, so the
  // two paths agree on one value instead.
  //
  // "Is there a site at all" is not this provider's question to answer —
  // `observerLocationProvider` is non-nullable geometry. Surfaces that must
  // not invent a night gate on `observingSiteProvider` /
  // `appObserverLocationProvider`, which return null at the 0/0 sentinel.
  final settingsAsync = ref.read(appSettingsProvider);
  settingsAsync.whenData((settings) {
    Future.microtask(() async {
      ref.read(observerLocationProvider.notifier).setLocation(
            latitude: settings.latitude,
            longitude: settings.longitude,
            elevation: settings.elevation,
          );
      ref.read(planetariumEffectiveHorizonDegProvider.notifier).state =
          settings.effectiveHorizonDeg;

      await _syncLocationToBackend(ref, settings.observerSite);
    });
  });
});

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
  if (ref.read(backendProvider) is NetworkBackend) return;
  try {
    final backend = ref.read(profileSettingsBackendProvider);
    developer.log(
        site == null
            ? 'Clearing observer location in Rust backend: no site is set'
            : 'Syncing observer location to Rust backend: '
                'lat=${site.latitude}, lon=${site.longitude}, '
                'elev=${site.elevation}',
        name: 'LocationSync');
    await backend.setLocation(site);
    developer.log('Observer location synced successfully to Rust backend',
        name: 'LocationSync');
  } catch (e, stackTrace) {
    developer.log('Failed to sync observer location to Rust backend: $e',
        name: 'LocationSync', error: e, stackTrace: stackTrace);
  }
}
