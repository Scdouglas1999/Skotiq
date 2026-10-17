import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend.dart';
import '../models/backend/device_capabilities.dart';
import '../services/disk_space_guard.dart';
import '../services/disk_space_service.dart';
import '../services/logging_service.dart';
import 'backend_provider.dart';
import 'capability_provider.dart';
import 'equipment_provider.dart';
import 'sequence_provider.dart';
import 'settings_provider.dart';

/// Host-OS disk-space query backend.
///
/// Production singleton. Tests can override this provider with a fake to
/// avoid shelling out.
final diskSpaceServiceProvider = Provider<DiskSpaceService>((ref) {
  return DiskSpaceService(logger: ref.watch(loggingServiceProvider));
});

/// Combines the disk-space service with projection math and watchdog
/// management. Sequence executor / dashboards reach into this provider for
/// both pre-flight and live monitoring.
final diskSpaceGuardProvider = Provider<DiskSpaceGuardService>((ref) {
  final guard = DiskSpaceGuardService(
    diskService: ref.watch(diskSpaceServiceProvider),
    logger: ref.watch(loggingServiceProvider),
  );
  ref.onDispose(guard.dispose);
  return guard;
});

/// Polls free space on the configured capture directory every 10 seconds.
///
/// Used by the dashboard Storage tile. Returns null if the user has not
/// configured a capture directory yet; propagates [DiskSpaceException]
/// otherwise (we want errors visible in the AsyncValue, not silently swallowed).
final captureDirDiskSpaceProvider = StreamProvider.autoDispose<DiskSpaceInfo?>((
  ref,
) async* {
  // Remote host: the capture directory lives on the HOST filesystem, so ask
  // the host over the API. A local `df` against the host's path resolves on
  // the CLIENT filesystem and can only fail.
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    yield await backend.getHostCaptureDiskSpace();
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 10));
      yield await backend.getHostCaptureDiskSpace();
    }
  }

  final settings = await ref.watch(appSettingsProvider.future);
  final path = settings.imageOutputPath;
  if (path.isEmpty) {
    yield null;
    return;
  }
  final guard = ref.watch(diskSpaceGuardProvider);

  // Emit an initial sample immediately so the UI doesn't sit in a loading
  // state for 10s on first build, then keep polling.
  yield await guard.sample(path);
  while (true) {
    await Future<void>.delayed(const Duration(seconds: 10));
    yield await guard.sample(path);
  }
});

/// Snapshot returned by [sequenceDiskProjectionProvider] holding both the
/// projected byte count and the projection severity. `null` for `projection`
/// means there is no current sequence to project.
class SequenceDiskProjectionSnapshot {
  final DiskSpaceProjection? projection;
  final bool capturePathConfigured;

  const SequenceDiskProjectionSnapshot({
    required this.projection,
    required this.capturePathConfigured,
  });
}

/// Recomputes the disk-space projection for the currently-loaded sequence
/// whenever the sequence, camera capabilities, or capture path change.
///
/// Listeners (pre-flight dialog, Storage tile) subscribe via Riverpod's
/// usual `watch`. Recomputation is async because the disk query is async.
final sequenceDiskProjectionProvider =
    FutureProvider.autoDispose<SequenceDiskProjectionSnapshot>((ref) async {
      final sequence = ref.watch(currentSequenceProvider);
      final settings = await ref.watch(appSettingsProvider.future);
      final path = settings.imageOutputPath;
      if (path.isEmpty) {
        return const SequenceDiskProjectionSnapshot(
          projection: null,
          capturePathConfigured: false,
        );
      }
      if (sequence == null) {
        return const SequenceDiskProjectionSnapshot(
          projection: null,
          capturePathConfigured: true,
        );
      }

      // Look up camera capabilities from the connected camera (if any). Without
      // capabilities the projection still runs but the severity is "info"
      // (size unknown). The guard takes a nullable.
      final cameraState = ref.watch(cameraStateProvider);
      final cameraId = cameraState.deviceId ?? '';
      CameraCapabilities? capabilities;
      if (cameraId.isNotEmpty) {
        capabilities = await ref.watch(
          cameraCapabilitiesProvider(cameraId).future,
        );
      }

      final guard = ref.watch(diskSpaceGuardProvider);
      final projection = await guard.projectSequence(
        capturePath: path,
        sequence: sequence,
        capabilities: capabilities,
      );
      return SequenceDiskProjectionSnapshot(
        projection: projection,
        capturePathConfigured: true,
      );
    });

/// Synchronous helper that callers can use to obtain a projection on demand
/// from inside a non-Riverpod context (e.g. the pre-flight dialog's
/// async validator). Equivalent to manually composing the providers above,
/// but useful where the caller already has a `Ref`.
Future<DiskSpaceProjection?> projectCurrentSequence(Ref ref) async {
  final sequence = ref.read(currentSequenceProvider);
  if (sequence == null) return null;
  final settings = await ref.read(appSettingsProvider.future);
  final path = settings.imageOutputPath;
  if (path.isEmpty) return null;

  final cameraState = ref.read(cameraStateProvider);
  final cameraId = cameraState.deviceId ?? '';
  CameraCapabilities? capabilities;
  if (cameraId.isNotEmpty) {
    capabilities = await ref.read(cameraCapabilitiesProvider(cameraId).future);
  }
  final guard = ref.read(diskSpaceGuardProvider);
  return guard.projectSequence(
    capturePath: path,
    sequence: sequence,
    capabilities: capabilities,
  );
}
