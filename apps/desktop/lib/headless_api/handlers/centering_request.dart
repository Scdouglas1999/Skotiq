import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../validation.dart';

/// The centering the host runs for a client's center request: the manual
/// centering of the host's own settings and active profile, with each field
/// the request names taking that field's place.
Future<({CenteringConfig config, PlateSolverConfig solver})>
    centeringForRequest(
  ProviderContainer container,
  Map<String, dynamic> payload,
) async {
  final manual = ManualCentering.of(
    await container.read(appSettingsProvider.future),
    container.read(activeEquipmentProfileProvider),
  );
  final defaults = manual.config;
  return (
    config: CenteringConfig(
      maxIterations: optionalInt(payload, 'maxIterations', min: 1, max: 20) ??
          defaults.maxIterations,
      toleranceArcsec:
          optionalDouble(payload, 'toleranceArcsec', min: 0.1, max: 3600) ??
              defaults.toleranceArcsec,
      exposureTime:
          optionalDouble(payload, 'exposureTime', min: 0.01, max: 600) ??
              defaults.exposureTime,
      binning:
          optionalInt(payload, 'binning', min: 1, max: 16) ?? defaults.binning,
      gain: optionalInt(payload, 'gain', min: 0) ?? defaults.gain,
      offset: optionalInt(payload, 'offset', min: 0) ?? defaults.offset,
      syncMount: optionalBool(payload, 'syncMount') ?? defaults.syncMount,
    ),
    solver: manual.solver,
  );
}
