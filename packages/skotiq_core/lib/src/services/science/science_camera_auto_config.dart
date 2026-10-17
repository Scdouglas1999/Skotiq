import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/skotiq_backend.dart';
import '../../backend/network_backend.dart';
import '../../database/daos/settings_dao.dart';
import '../../models/equipment/equipment_models.dart';
import '../../providers/backend_provider.dart';
import '../../providers/capability_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/equipment/camera_state_provider.dart';
import '../../providers/profiles_provider.dart';
import '../logging_service.dart';
import '../sensor_specs/camera_sensor_spec_resolver.dart';
import '../sensor_specs/camera_sensor_specs.dart';
import '../smart_night/hardware_specs_service.dart';

/// Keeps the `science.camera.*` settings (read noise, gain in e⁻/ADU,
/// saturation ADU) in sync with the hardware that is actually in use, so
/// photometric limiting magnitudes and saturation rejection work without
/// the user hand-typing sensor datasheets.
///
/// Sources, in priority order:
///   1. The connected camera (live device name + current driver gain).
///   2. The active equipment profile (camera name + default gain) when no
///      camera is connected.
///
/// Sensor values come from [CameraSensorSpecResolver] — the same resolution
/// chain (user entry, then the published specification database) that Smart
/// Night's exposure model uses, so the two features can never disagree about
/// the camera. Saturation and the e⁻/ADU conversion are derived from the
/// driver-reported PIXEL-CONTAINER full scale (`CameraStatus.maxAdu`):
///   maxAdu       = CameraStatus.maxAdu   (65535 when the camera is unreachable)
///   gain e⁻/ADU  = fullWell_e / maxAdu
///
/// It must NOT be `2^bitDepth − 1`: bit depth is ADC resolution, and 12/14-bit
/// astro CMOS drivers left-justify their samples into the 16-bit pixel word. On
/// a live ASI1600MM (bitDepth 12, frames measurably reaching 65504) the
/// bit-depth form wrote `saturation_adu = 4095` — so photometry treated every
/// real star as unsaturated — and inflated e⁻/ADU by 16x.
///
/// The sync is opt-out: `science.camera.auto_managed=false` (set when the
/// user manually edits any of the three fields) freezes the values, and
/// the Settings UI shows which camera/gain produced the current numbers
/// via `science.camera.auto_source`. In remote mode the appliance host
/// runs its own instance of this service against the real hardware, so the
/// client skips syncing entirely.
class ScienceCameraAutoConfig {
  static const autoManagedKey = 'science.camera.auto_managed';
  static const autoSourceKey = 'science.camera.auto_source';
  static const readNoiseKey = 'science.camera.read_noise_e';
  static const gainKey = 'science.camera.gain_e_per_adu';
  static const saturationKey = 'science.camera.saturation_adu';

  final Ref _ref;
  final SkotiqBackend _backend;

  int _syncGeneration = 0;
  bool _retired = false;

  /// Last (name, gain, maxAdu) tuple applied, to skip redundant writes. Keyed on
  /// the container full scale rather than bit depth because that is what the
  /// written values are actually derived from.
  (String, int?, int)? _lastApplied;

  ScienceCameraAutoConfig(this._ref, this._backend);

  LoggingService get _logger => _ref.read(loggingServiceProvider);

  /// Recompute and persist the science camera settings if auto-management
  /// is enabled and a camera identity can be resolved. Safe to call often;
  /// no-ops when nothing relevant changed.
  Future<void> maybeSync({
    String reason = 'unspecified',
    bool force = false,
  }) async {
    final generation = ++_syncGeneration;
    try {
      if (!_isCurrent(generation) || _backend is NetworkBackend) {
        return; // The appliance host owns the hardware and these settings.
      }
      final dao = _ref.read(settingsDaoProvider);
      final autoManaged = await dao.getSetting(autoManagedKey);
      if (!_isCurrent(generation)) return;
      if (autoManaged != null && autoManaged.toLowerCase() == 'false') {
        return;
      }

      final identity = _resolveCameraIdentity();
      if (identity == null) {
        return;
      }

      final bitDepth = await _resolveBitDepth(identity.deviceId);
      if (!_isCurrent(generation)) return;
      final maxAdu = await _resolveMaxAdu(identity.deviceId);
      if (!_isCurrent(generation)) return;
      if (!force && _lastApplied == (identity.name, identity.gain, maxAdu)) {
        return;
      }

      final specs = await _resolveSensorSpecs(dao, identity);
      if (!_isCurrent(generation)) return;
      final readNoise = specs.readNoiseE;
      final fullWell = specs.fullWellE;

      final updates = <String, String>{saturationKey: maxAdu.toString()};
      String source;
      if (readNoise != null && fullWell != null) {
        updates[readNoiseKey] = readNoise.value.toStringAsFixed(2);
        updates[gainKey] = (fullWell.value / maxAdu).toStringAsFixed(3);
        source =
            '${specs.databaseEntry?.model ?? identity.name} ($bitDepth-bit) — '
            'read noise ${readNoise.provenance}';
      } else {
        // Unknown sensor: the driver's full scale still gives a correct
        // saturation level, but read noise / e-/ADU would be guesses — leave
        // whatever the user (or a previous match) configured rather than
        // overwrite with fabricated values.
        source =
            '${identity.name} ($bitDepth-bit) — no published read noise or '
            'full well for this camera, read noise/gain unchanged';
      }
      updates[autoSourceKey] = source;

      final existing = await dao.getAllSettings();
      if (!_isCurrent(generation)) return;
      final changedUpdates = Map<String, String>.fromEntries(
        updates.entries.where((entry) => existing[entry.key] != entry.value),
      );
      if (changedUpdates.isNotEmpty) {
        await dao.setSettings(changedUpdates);
        if (!_isCurrent(generation)) return;
      }
      _lastApplied = (identity.name, identity.gain, maxAdu);
      if (changedUpdates.isNotEmpty) {
        _logger.info(
          'Science camera settings auto-updated ($reason): $source -> '
          '${updates.entries.where((e) => e.key != autoSourceKey).map((e) => '${e.key.split('.').last}=${e.value}').join(', ')}',
          source: 'ScienceCameraAutoConfig',
        );
      }
    } catch (error, stack) {
      if (!_isCurrent(generation)) return;
      _logger.warning(
        'Science camera auto-config sync failed ($reason): $error\n$stack',
        source: 'ScienceCameraAutoConfig',
      );
    }
  }

  bool _isCurrent(int generation) {
    return !_retired &&
        generation == _syncGeneration &&
        identical(_ref.read(backendProvider), _backend);
  }

  void retire() {
    _retired = true;
    _syncGeneration++;
  }

  ({String name, String? deviceId, int? gain})? _resolveCameraIdentity() {
    final camera = _ref.read(cameraStateProvider);
    if (camera.connectionState == DeviceConnectionState.connected) {
      final name = camera.deviceName ?? camera.deviceId;
      if (name != null && name.trim().isNotEmpty) {
        return (name: name, deviceId: camera.deviceId, gain: camera.gain);
      }
    }
    final profile = _ref.read(activeEquipmentProfileProvider);
    final profileCamera = profile?.cameraName ?? profile?.cameraId;
    if (profileCamera != null && profileCamera.trim().isNotEmpty) {
      return (
        name: profileCamera,
        deviceId: profile?.cameraId,
        gain: profile?.defaultGain,
      );
    }
    return null;
  }

  /// ADC resolution, for the human-readable `auto_source` label only.
  Future<int> _resolveBitDepth(String? deviceId) async {
    if (deviceId == null || deviceId.isEmpty) return 16;
    try {
      final caps = await _ref.read(cameraCapabilitiesProvider(deviceId).future);
      final bitDepth = caps?.bitDepth;
      if (bitDepth != null && bitDepth >= 8 && bitDepth <= 16) {
        return bitDepth;
      }
    } catch (_) {
      // Capabilities unavailable (camera offline): assume 16-bit output,
      // which matches how virtually all drivers scale sub-16-bit sensors.
    }
    return 16;
  }

  /// Pixel-container full scale — the value photometry compares real pixels
  /// against. Comes from the driver (`CameraStatus.maxAdu`).
  ///
  /// When the camera cannot be queried (offline, or only a profile name is
  /// known) we fall back to the 16-bit container rather than to
  /// `2^bitDepth - 1`, for the reason [_resolveBitDepth] already documents:
  /// virtually all drivers scale sub-16-bit sensors into the 16-bit pixel word.
  /// No frames are being measured in that state anyway.
  Future<int> _resolveMaxAdu(String? deviceId) async {
    if (deviceId != null && deviceId.isNotEmpty) {
      try {
        final status = await _backend.getCameraStatus(deviceId);
        if (status.maxAdu > 0) return status.maxAdu;
      } catch (_) {
        // Camera offline / status unavailable — fall through.
      }
    }
    return 65535;
  }

  Future<ResolvedCameraSensorSpecs> _resolveSensorSpecs(
    SettingsDao dao,
    ({String name, String? deviceId, int? gain}) identity,
  ) async {
    var overrides = UserSensorSpecOverrides.none;
    try {
      final raw = await dao.getSetting(
        HardwareSpecsService.cameraOverridesSettingKey,
      );
      if (raw != null && raw.trim().isNotEmpty) {
        overrides =
            HardwareSpecsService(
              cameraOverrides: HardwareSpecsService.cameraOverridesFromJson(
                jsonDecode(raw),
              ),
            ).overridesFor(
              cameraName: identity.name,
              cameraId: identity.deviceId,
              gain: identity.gain,
            );
      }
    } catch (error) {
      _logger.warning(
        'Ignoring malformed camera hardware overrides: \$error',
        source: 'ScienceCameraAutoConfig',
      );
    }
    // Geometry is irrelevant here: this service writes read noise and the
    // e-/ADU conversion, neither of which any driver reports.
    return CameraSensorSpecResolver().resolve(
      CameraSensorSpecInputs(
        cameraName: identity.name,
        cameraId: identity.deviceId,
        gain: identity.gain,
        overrides: overrides,
      ),
    );
  }
}

/// Watch this provider once at app startup (see `app.dart`) to activate the
/// sync. Listens only to the camera fields that matter — connection state,
/// identity, and gain — so per-exposure state churn does not re-trigger it.
final scienceCameraAutoConfigProvider = Provider<ScienceCameraAutoConfig>((
  ref,
) {
  final backend = ref.watch(backendProvider);
  final service = ScienceCameraAutoConfig(ref, backend);
  ref.onDispose(service.retire);
  ref.listen<(DeviceConnectionState, String?, String?, int?)>(
    cameraStateProvider.select(
      (s) => (s.connectionState, s.deviceName, s.deviceId, s.gain),
    ),
    (_, __) => service.maybeSync(reason: 'camera state changed'),
  );
  ref.listen(activeEquipmentProfileProvider, (_, __) {
    service.maybeSync(reason: 'active profile changed');
  });
  // Initial pass once the provider graph is up.
  Future.microtask(() => service.maybeSync(reason: 'startup'));
  return service;
});
