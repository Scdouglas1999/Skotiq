// Provider wiring for the captured-frame thumbnail sidecar service.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/logging_service.dart';
import '../services/thumbnail_sidecar_service.dart';

/// Override-point for the FFI thumbnail generator. Default points at the
/// Rust binding via `defaultGenerateFitsThumbnail`. Tests override this
/// provider to inject deterministic bytes without booting the bridge.
final fitsThumbnailBytesGeneratorProvider =
    Provider<FitsThumbnailBytesGenerator>((ref) {
      return defaultGenerateFitsThumbnail;
    });

/// Singleton [ThumbnailSidecarService] for the running app. Constructed
/// from the injected generator + logging service so production gets the
/// real FFI binding and tests get a controllable stub.
final thumbnailSidecarServiceProvider = Provider<ThumbnailSidecarService>((
  ref,
) {
  return ThumbnailSidecarService(
    generator: ref.watch(fitsThumbnailBytesGeneratorProvider),
    logger: ref.watch(loggingServiceProvider),
  );
});
