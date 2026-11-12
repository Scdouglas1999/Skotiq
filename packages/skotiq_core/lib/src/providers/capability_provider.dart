import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/daos/settings_dao.dart';
import '../models/backend/device_capabilities.dart';
import '../models/equipment/equipment_models.dart';
import 'backend_provider.dart';
import 'database_provider.dart';
import 'equipment/camera_state_provider.dart';

/// Provider to fetch camera capabilities for a device
/// Returns null if the device is not connected or doesn't support capabilities
final cameraCapabilitiesProvider =
    FutureProvider.family<CameraCapabilities?, String>((ref, deviceId) async {
      if (deviceId.isEmpty) return null;
      // Read again when this camera finishes connecting. Before that a native
      // driver answers with a 0 x 0, 0-bit sensor rather than an error, and
      // the answer was kept for the life of the app: on the rig 2026-11-08 the
      // pre-flight check said "Connect a camera" with the camera connected and
      // the plan "needs 0 MB".
      ref.watch(
        cameraStateProvider.select(
          (state) =>
              state.deviceId == deviceId &&
              state.connectionState == DeviceConnectionState.connected,
        ),
      );
      final backend = ref.watch(deviceBackendProvider);
      final capabilities = await backend.getCameraCapabilities(deviceId);
      // Sensor geometry is a fixed property of the body, and this is the point
      // where the app learns it. Recording it here means framing and mosaic
      // planning still work once the rig is unplugged — the user does not have
      // to have visited a particular screen while connected for the app to
      // know how big the sensor is.
      if (capabilities != null) {
        final px = capabilities.pixelSizeX;
        final py = capabilities.pixelSizeY;
        if (px != null &&
            py != null &&
            capabilities.maxWidth > 0 &&
            capabilities.maxHeight > 0) {
          try {
            await ref
                .read(settingsDaoProvider)
                .rememberSensorSpec(
                  deviceId,
                  RememberedSensorSpec(
                    sensorWidth: capabilities.maxWidth,
                    sensorHeight: capabilities.maxHeight,
                    pixelSizeX: px,
                    pixelSizeY: py,
                    recordedAt: DateTime.now(),
                  ),
                );
          } catch (error, stack) {
            // Remembering is a convenience for a later, offline session. It
            // must never be able to fail the capability read that device
            // connection and every camera control depend on.
            developer.log(
              'Could not remember sensor geometry for $deviceId.',
              name: 'Capabilities',
              level: 900,
              error: error,
              stackTrace: stack,
            );
          }
        }
      }
      return capabilities;
    });

/// The exposure sensitivity of the connected imaging camera: the ISO speeds
/// of a DSLR or mirrorless body, or a gain range. With no camera connected,
/// or before its capabilities arrive, it reads as gain.
///
/// Every surface that offers or describes an exposure's gain reads this, so
/// connecting a DSLR turns each of them to ISO at once.
final cameraSensitivityProvider = Provider<ExposureSensitivity>((ref) {
  final deviceId = ref.watch(
    cameraStateProvider.select(
      (state) => state.connectionState == DeviceConnectionState.connected
          ? state.deviceId
          : null,
    ),
  );
  if (deviceId == null || deviceId.isEmpty) return const GainSensitivity();
  return ExposureSensitivity.of(
    ref.watch(cameraCapabilitiesProvider(deviceId)).valueOrNull,
  );
});

/// Provider to fetch mount capabilities for a device
/// Returns null if the device is not connected or doesn't support capabilities
final mountCapabilitiesProvider =
    FutureProvider.family<MountCapabilities?, String>((ref, deviceId) async {
      if (deviceId.isEmpty) return null;
      final backend = ref.watch(deviceBackendProvider);
      return backend.getMountCapabilities(deviceId);
    });

/// Safe binning option while capabilities are unavailable or unsupported.
///
/// Advertising 2x2–4x4 without a driver capability was a fabricated default:
/// selecting one could send an invalid command to cameras that only support
/// native 1x1. Unknown capability must fail closed.
const List<String> defaultBinningOptions = ['1x1'];

/// Generate binning options based on camera capabilities
///
/// If capabilities are null or canBin is false, returns default options.
/// Otherwise, generates options up to maxBinX/maxBinY.
/// If canAsymmetricBin is true, includes asymmetric options (e.g., 1x2, 2x1).
List<String> getBinningOptionsFromCapabilities(
  CameraCapabilities? capabilities,
) {
  // Unknown or explicitly unsupported binning must not fabricate controls.
  if (capabilities == null || !capabilities.canBin) {
    return defaultBinningOptions;
  }

  final maxBinX = capabilities.maxBinX;
  final maxBinY = capabilities.maxBinY;

  // Invalid driver ranges are capability-unknown, so retain only native 1x1.
  if (maxBinX < 1 || maxBinY < 1 || maxBinX > 8 || maxBinY > 8) {
    return defaultBinningOptions;
  }

  final options = <String>[];

  if (capabilities.canAsymmetricBin) {
    for (var x = 1; x <= maxBinX; x++) {
      for (var y = 1; y <= maxBinY; y++) {
        options.add('${x}x$y');
      }
    }
  } else {
    // Only symmetric binning (NxN)
    final maxBin = maxBinX < maxBinY ? maxBinX : maxBinY;
    for (var n = 1; n <= maxBin; n++) {
      options.add('${n}x$n');
    }
  }

  // Ensure at least 1x1 is present
  if (options.isEmpty) {
    options.add('1x1');
  }

  return options;
}

/// Provider to get available binning options for a camera
/// Watches camera capabilities and returns appropriate binning options
final cameraBinningOptionsProvider = Provider.family<List<String>, String>((
  ref,
  deviceId,
) {
  if (deviceId.isEmpty) return defaultBinningOptions;

  final capabilitiesAsync = ref.watch(cameraCapabilitiesProvider(deviceId));
  return capabilitiesAsync.when(
    data: (capabilities) => getBinningOptionsFromCapabilities(capabilities),
    loading: () => defaultBinningOptions,
    error: (_, __) => defaultBinningOptions,
  );
});
