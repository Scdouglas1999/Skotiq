import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

typedef InitialLocationLookup = Future<PositioningResult?> Function();

final initialLocationLookupProvider = Provider<InitialLocationLookup>(
  (ref) => GeolocationService.fetchInternetEstimate,
);

/// Saved sites are available immediately. A new host gets a background
/// internet estimate without waiting for a GPS, scanning Wi-Fi, or opening
/// permission dialogs. Explicit Detect location can refine it later.
final initialLocationProvider = FutureProvider<void>((ref) async {
  final backend = ref.watch(backendProvider);
  if (!backend.runsRigHere) return;
  final scope = ref.providerBackendScope();
  try {
    final settings = await ref.read(appSettingsProvider.future);
    if (scope.isStale || settings.hasObserverLocation) return;
    final notifier = ref.read(appSettingsProvider.notifier);
    final revision = notifier.locationEditRevision;
    final fix = await ref
        .read(initialLocationLookupProvider)()
        .timeout(const Duration(seconds: 7));
    if (scope.isStale || fix == null) return;
    final applied = await notifier.initializeLocation(
      latitude: fix.latitude,
      longitude: fix.longitude,
      expectedRevision: revision,
      isCurrent: () => scope.isCurrent,
    );
    if (!applied || scope.isStale) return;
    ref.read(uiNotificationProvider.notifier).showInfo(
          '${fix.explanation} You can refine this in Settings → Location.',
          title: 'Approximate location detected',
          duration: const Duration(seconds: 12),
        );
  } catch (error, stackTrace) {
    if (scope.isStale) return;
    Log.warning('Initial location lookup did not finish: $error',
        source: 'InitialLocation', error: error, stackTrace: stackTrace);
  }
});
