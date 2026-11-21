import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/format.dart';

import 'host_role.dart';
import '../models/backend/device_capabilities.dart';
import '../services/disk_space_guard.dart';
import '../services/disk_space_service.dart';
import 'capability_provider.dart';
import 'equipment_provider.dart';
import 'sequence_provider.dart';
import 'settings_provider.dart';
import 'logging_service_provider.dart';
import '../models/disk_space.dart';

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
) {
  return ref.watch(_captureDiskSamplesProvider)(ref);
});

Stream<T> _cancellablePollStream<T>({
  required Ref ref,
  required Duration interval,
  required Future<T> Function() sample,
}) {
  final controller = StreamController<T>();
  Timer? timer;
  var closed = false;
  var inFlight = false;

  void stop() {
    if (closed) return;
    closed = true;
    timer?.cancel();
    timer = null;
    if (!controller.isClosed) {
      unawaited(controller.close());
    }
  }

  Future<void> tick() async {
    if (closed || inFlight) return;
    inFlight = true;
    try {
      final value = await sample();
      if (!closed && !controller.isClosed) {
        controller.add(value);
      }
    } catch (e, st) {
      if (!closed && !controller.isClosed) {
        controller.addError(e, st);
      }
    } finally {
      inFlight = false;
      if (!closed) {
        timer = Timer(interval, () => unawaited(tick()));
      }
    }
  }

  controller.onListen = () => unawaited(tick());
  controller.onCancel = stop;
  ref.onDispose(stop);
  return controller.stream;
}

/// A sample now and one every 10 s after: of this machine's capture folder,
/// or the one the linked host reports for its own.
final _captureDiskSamplesProvider =
    hostRoleProvider<Stream<DiskSpaceInfo?> Function(Ref ref)>(
      here: (_) => (ref) {
        final controller = StreamController<DiskSpaceInfo?>();
        Timer? timer;
        var closed = false;
        var inFlight = false;

        void stop() {
          if (closed) return;
          closed = true;
          timer?.cancel();
          timer = null;
          if (!controller.isClosed) {
            unawaited(controller.close());
          }
        }

        Future<void> run() async {
          try {
            final settings = await ref.watch(appSettingsProvider.future);
            if (closed) return;
            final path = settings.imageOutputPath;
            if (path.isEmpty) {
              if (!controller.isClosed) controller.add(null);
              stop();
              return;
            }
            final guard = ref.watch(diskSpaceGuardProvider);
            Future<void> tick() async {
              if (closed || inFlight) return;
              inFlight = true;
              try {
                final info = await guard.sample(path);
                if (!closed && !controller.isClosed) {
                  controller.add(info);
                }
              } catch (e, st) {
                if (!closed && !controller.isClosed) {
                  controller.addError(e, st);
                }
              } finally {
                inFlight = false;
                if (!closed) {
                  timer = Timer(
                    const Duration(seconds: 10),
                    () => unawaited(tick()),
                  );
                }
              }
            }

            await tick();
          } catch (e, st) {
            if (!closed && !controller.isClosed) {
              controller.addError(e, st);
            }
          }
        }

        controller.onListen = () => unawaited(run());
        controller.onCancel = stop;
        ref.onDispose(stop);
        return controller.stream;
      },
      linked: (_, host) =>
          (ref) => _cancellablePollStream<DiskSpaceInfo?>(
            ref: ref,
            interval: const Duration(seconds: 10),
            sample: host.files.getHostCaptureDiskSpace,
          ),
    );

/// The capture folder's free space as shown ("252 GiB"), or null before the
/// first sample.
///
/// For `captureDirDiskSpaceProvider.select(freeSpaceText)`: the byte count
/// changes with every sample while the shown size rarely does.
String? freeSpaceText(AsyncValue<DiskSpaceInfo?> space) {
  final info = space.valueOrNull;
  return info == null ? null : ByteFormat.size(info.freeBytes);
}

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
      // The capture folder's free-space sample is the disk. A linked client
      // must not `df` the host's path. The host, which has no remote sample,
      // still queries.
      final sample = ref.watch(captureDirDiskSpaceProvider).valueOrNull;
      final linked = ref.watch(remoteHostProvider) != null;
      final usable = sample != null && diskSampleCoversPath(sample, path)
          ? sample
          : null;
      if (linked && usable == null) {
        return const SequenceDiskProjectionSnapshot(
          projection: null,
          capturePathConfigured: true,
        );
      }
      final cameraId =
          ref.watch(cameraStateProvider.select((c) => c.deviceId)) ?? '';
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
        diskSpace: usable,
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
  final sample = ref.read(captureDirDiskSpaceProvider).valueOrNull;
  final linked = ref.read(remoteHostProvider) != null;
  final usable = sample != null && diskSampleCoversPath(sample, path)
      ? sample
      : null;
  if (linked && usable == null) return null;
  final guard = ref.read(diskSpaceGuardProvider);
  return guard.projectSequence(
    capturePath: path,
    sequence: sequence,
    capabilities: capabilities,
    diskSpace: usable,
  );
}

/// Whether [sample] is the volume that holds [capturePath].
///
/// A Windows sample reports the drive root. A sample for another path is
/// not this capture folder's free space.
bool diskSampleCoversPath(DiskSpaceInfo sample, String capturePath) {
  String norm(String value) => value.replaceAll('\\', '/').toLowerCase();
  final have = norm(sample.path);
  final want = norm(capturePath);
  if (have.isEmpty || want.isEmpty) return false;
  if (have == want) return true;
  final root = have.endsWith('/') ? have : '$have/';
  return want.startsWith(root);
}
