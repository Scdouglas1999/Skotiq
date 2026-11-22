import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../validation.dart';

/// The centering the host runs for a client's center request: the manual
/// centering of the host's own settings and active profile, with each field
/// the request names taking that field's place.
Future<CenteringConfig> centeringForRequest(
  ProviderContainer container,
  Map<String, dynamic> payload,
) async {
  final manual = ManualCentering.of(
    await container.read(appSettingsProvider.future),
    container.read(activeEquipmentProfileProvider),
  );
  final defaults = manual.config;
  return CenteringConfig(
    maxIterations:
        optionalInt(payload, 'maxIterations', min: 1, max: 20) ??
        defaults.maxIterations,
    toleranceArcsec:
        optionalDouble(payload, 'toleranceArcsec', min: 0.1, max: 3600) ??
        defaults.toleranceArcsec,
    exposureTime:
        optionalDouble(payload, 'exposureTime', min: 0.01, max: 600) ??
        defaults.exposureTime,
    syncMount: optionalBool(payload, 'syncMount') ?? defaults.syncMount,
  );
}

/// Whether the host shows a center request's run in its own window, as its
/// centering status and last result. A linked Skotiq client mirrors the run
/// it started, so a request without the flag publishes nothing; a caller
/// that does not mirror (the web dashboard) sends `publish: true`.
bool centeringPublishedFor(Map<String, dynamic> payload) =>
    optionalBool(payload, 'publish') == true;
