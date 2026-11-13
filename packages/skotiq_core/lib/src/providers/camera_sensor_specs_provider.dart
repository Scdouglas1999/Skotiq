import 'host_role.dart';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/skotiq_backend.dart';
import '../database/daos/settings_dao.dart';
import '../models/equipment/equipment_models.dart';
import '../services/sensor_specs/camera_sensor_spec_resolver.dart';
import '../services/sensor_specs/camera_sensor_specs.dart';
import '../services/smart_night/hardware_specs_service.dart';
import 'backend_provider.dart';
import 'database_provider.dart';
import 'equipment/camera_state_provider.dart';
import 'profiles_provider.dart';
import '../services/logging_service.dart';

/// The rig's raw camera-spec settings: everything under `science.` and
/// `smart_night.`, from the host that owns the camera when paired.
///
/// One provider so the planner's exposure context and the sensor-spec chain
/// share a single fetch. They used to load it separately, which on a remote
/// client meant two `GET /api/smart-night/settings` round trips for every
/// planner rebuild.
///
/// Locally it rides the settings table's own stream rather than reading it
/// once, so a correction saved anywhere — the camera sensor specs dialog, the
/// headless API — reaches the planner without a manual invalidation somebody
/// has to remember. A one-shot read here left the Plan screen still warning
/// about a camera the user had just described.
final rigCameraSettingsProvider = FutureProvider<Map<String, String>>((
  ref,
) async {
  return ref.watch(_rigCameraSettingRowsProvider)(ref);
});

final _rigCameraSettingRowsProvider =
    hostRoleProvider<Future<Map<String, String>> Function(Ref ref)>(
      here: (_) =>
          (ref) => ref.watch(allSettingsProvider.future),
      linked: (_, host) => (_) async {
        final values = await Future.wait([
          host.rigSettings.getScienceSettings(),
          host.rigSettings.getSmartNightSettings(),
        ]);
        return {...values[0], ...values[1]};
      },
    );

/// The table that remembers camera geometry: this machine's, and none on a
/// linked client, whose host remembers it.
final _rememberedGeometryRowsProvider = hostRoleProvider<SettingsDao?>(
  here: (ref) => ref.watch(settingsDaoProvider),
  linked: (_, _) => null,
);

/// The resolver. Overridden in tests to pin a database.
final cameraSensorSpecResolverProvider = Provider<CameraSensorSpecResolver>(
  (_) => CameraSensorSpecResolver(),
);

/// The active camera's sensor specs, resolved through the whole chain, with
/// every value tagged by where it came from.
///
/// Every surface that needs pixel size, sensor dimensions, read noise, full
/// well or QE watches this, so the Plan screen, Framing and the science
/// pipeline cannot disagree about the same camera again.
///
/// Only the camera fields that change the answer are watched — connection
/// state, id, name and gain. Watching the whole camera snapshot would re-run
/// the `getCameraStatus` round trip on every sensor-temperature tick, which is
/// the mistake Framing's equipment card already had to be rescued from.
final activeCameraSensorSpecsProvider =
    FutureProvider<ResolvedCameraSensorSpecs>((ref) async {
      final profile = ref.watch(activeEquipmentProfileProvider);
      final (connectionState, deviceId, deviceName, driverGain) = ref.watch(
        cameraStateProvider.select(
          (state) => (
            state.connectionState,
            state.deviceId,
            state.deviceName,
            state.gain,
          ),
        ),
      );

      final cameraId = profile?.cameraId ?? deviceId;
      final connected =
          connectionState == DeviceConnectionState.connected &&
          cameraId != null &&
          cameraId.isNotEmpty;
      // On the wire the driver's own model string is the better identifier: the
      // profile's friendly name is free text the user may have typed for a
      // different body entirely.
      final cameraName = connected
          ? (deviceName ?? profile?.cameraName)
          : (profile?.cameraName ?? deviceName);

      final backend = ref.watch(backendProvider);
      final settingsDao = ref.watch(_rememberedGeometryRowsProvider);
      final gain = connected
          ? (driverGain ?? profile?.defaultGain)
          : profile?.defaultGain;

      final live = connected
          ? await _readLiveGeometry(backend, cameraId)
          : null;
      final remembered = live == null && cameraId != null
          ? await _readRememberedGeometry(settingsDao, cameraId)
          : null;
      final overrides = _readOverrides(
        await ref.watch(rigCameraSettingsProvider.future),
        cameraName: cameraName,
        cameraId: cameraId,
        gain: gain,
      );

      return ref
          .watch(cameraSensorSpecResolverProvider)
          .resolve(
            CameraSensorSpecInputs(
              cameraName: cameraName,
              cameraId: cameraId,
              gain: gain,
              overrides: overrides,
              liveReading: live,
              rememberedReading: remembered,
            ),
          );
    });

Future<SensorGeometryReading?> _readLiveGeometry(
  SkotiqBackend backend,
  String? cameraId,
) async {
  if (cameraId == null || cameraId.isEmpty) return null;
  try {
    final status = await backend.getCameraStatus(cameraId);
    final reading = SensorGeometryReading(
      widthPx: status.sensorWidth,
      heightPx: status.sensorHeight,
      pixelSizeXMicrons: status.pixelSizeX,
      pixelSizeYMicrons: status.pixelSizeY,
    );
    return reading.isUsable ? reading : null;
  } catch (error, stack) {
    // A camera that cannot answer right now is not a reason to withhold the
    // remembered or published values below it in the chain.
    Log.warning(
      'Could not read live sensor geometry for $cameraId.',
      source: 'SensorSpecs',
      error: error,
      stackTrace: stack,
    );
    return null;
  }
}

Future<SensorGeometryReading?> _readRememberedGeometry(
  SettingsDao? dao,
  String cameraId,
) async {
  if (dao == null) return null;
  try {
    final spec = await dao.getRememberedSensorSpec(cameraId);
    if (spec == null) return null;
    return SensorGeometryReading(
      widthPx: spec.sensorWidth,
      heightPx: spec.sensorHeight,
      pixelSizeXMicrons: spec.pixelSizeX,
      pixelSizeYMicrons: spec.pixelSizeY,
      readAt: spec.recordedAt,
    );
  } catch (error, stack) {
    Log.warning(
      'Could not read remembered sensor geometry for $cameraId.',
      source: 'SensorSpecs',
      error: error,
      stackTrace: stack,
    );
    return null;
  }
}

/// The user's own values for this camera, from the one store the camera sensor
/// specs dialog writes.
///
/// The key lives under the `smart_night.` prefix, which is what lets a paired
/// remote client read and write it on the host that owns the camera.
UserSensorSpecOverrides _readOverrides(
  Map<String, String> rigSettings, {
  required String? cameraName,
  required String? cameraId,
  required int? gain,
}) {
  final raw = rigSettings[HardwareSpecsService.cameraOverridesSettingKey];
  if (raw == null || raw.trim().isEmpty) return UserSensorSpecOverrides.none;
  try {
    final specs = HardwareSpecsService.cameraOverridesFromJson(jsonDecode(raw));
    return HardwareSpecsService(
      cameraOverrides: specs,
    ).overridesFor(cameraName: cameraName, cameraId: cameraId, gain: gain);
  } catch (error, stack) {
    // A malformed override blob must not take the published figures down with
    // it; the planner says so through its own caveat.
    Log.warning(
      'Could not read camera sensor overrides.',
      source: 'SensorSpecs',
      error: error,
      stackTrace: stack,
    );
    return UserSensorSpecOverrides.none;
  }
}
