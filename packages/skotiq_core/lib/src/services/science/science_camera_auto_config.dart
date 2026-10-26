import 'dart:convert';
import 'dart:math' as math;

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
import '../sensor_specs/camera_sensor_entry.dart';
import '../sensor_specs/camera_sensor_specs.dart';
import '../sensor_specs/published_figure.dart';
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
/// The values themselves come from [resolveScienceCameraValues]: e⁻/ADU and
/// read noise at the driver gain in use (a flat-pair measurement for that
/// camera and gain, else the model's published gain chart), and a saturation
/// threshold just below the driver-reported pixel-container full scale
/// (`CameraStatus.maxAdu`). A camera with no chart and no measurement keeps
/// whatever e⁻/ADU and read noise were configured, and the source label says
/// so.
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

  /// JSON [ScienceGainMeasurement]: e⁻/ADU measured from flat pairs for one
  /// camera at one driver gain. Preferred over the published gain chart when
  /// the camera and gain match.
  static const gainMeasurementKey = 'science.camera.gain_measurement';

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
      final measurement = ScienceGainMeasurement.tryParse(
        await dao.getSetting(gainMeasurementKey),
      );
      if (!_isCurrent(generation)) return;
      final values = resolveScienceCameraValues(
        cameraName: identity.name,
        driverGain: identity.gain,
        maxAdu: maxAdu,
        adcBitDepth: bitDepth,
        entry: specs.databaseEntry,
        readNoiseOverride:
            specs.readNoiseE?.origin == SensorSpecOrigin.userOverride
            ? specs.readNoiseE!.value
            : null,
        measurement: measurement,
      );

      final updates = <String, String>{
        saturationKey: values.saturationAdu.toString(),
      };
      if (values.readNoiseE != null) {
        updates[readNoiseKey] = values.readNoiseE!.toStringAsFixed(2);
      }
      if (values.electronsPerAdu != null) {
        updates[gainKey] = values.electronsPerAdu!.toStringAsFixed(4);
      }
      final source = values.source;
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

/// e⁻/ADU measured from pairs of flat frames (photon transfer) for one camera
/// at one driver gain.
class ScienceGainMeasurement {
  const ScienceGainMeasurement({
    required this.cameraName,
    required this.driverGain,
    required this.electronsPerAdu,
    required this.pairCount,
    this.measuredAt,
  });

  final String cameraName;
  final int driverGain;
  final double electronsPerAdu;
  final int pairCount;
  final DateTime? measuredAt;

  Map<String, Object?> toJson() => {
    'camera': cameraName,
    'gain': driverGain,
    'ePerAdu': electronsPerAdu,
    'pairs': pairCount,
    if (measuredAt != null) 'measuredAt': measuredAt!.toUtc().toIso8601String(),
  };

  static ScienceGainMeasurement? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final camera = json['camera'];
      final gain = json['gain'];
      final ePerAdu = json['ePerAdu'];
      final pairs = json['pairs'];
      if (camera is! String || gain is! num || ePerAdu is! num) return null;
      if (!ePerAdu.isFinite || ePerAdu <= 0) return null;
      return ScienceGainMeasurement(
        cameraName: camera,
        driverGain: gain.round(),
        electronsPerAdu: ePerAdu.toDouble(),
        pairCount: pairs is num ? pairs.round() : 0,
        measuredAt: DateTime.tryParse('${json['measuredAt'] ?? ''}'),
      );
    } on FormatException {
      return null;
    }
  }
}

/// The science camera values for one camera at one driver gain, with a
/// sentence saying where each came from.
class ScienceCameraValues {
  const ScienceCameraValues({
    required this.saturationAdu,
    required this.electronsPerAdu,
    required this.readNoiseE,
    required this.source,
  });

  final int saturationAdu;

  /// Null when neither a measurement nor a gain chart covers this camera; the
  /// stored value is then left alone.
  final double? electronsPerAdu;

  /// Null when no figure is known at the gain in use.
  final double? readNoiseE;
  final String source;
}

/// Resolve e⁻/ADU, read noise and the saturation threshold for [cameraName]
/// at [driverGain].
///
/// e⁻/ADU is a flat-pair [measurement] for this camera at this gain when one
/// exists, else the model's published gain chart scaled to the pixel
/// container, else unknown. Read noise is a user override, else the chart's
/// figure at this gain, else a published figure quoted at exactly this gain,
/// else unknown: a figure quoted at another gain is not used.
///
/// The saturation threshold is two ADC steps below [maxAdu]. Sensors often
/// stop one code short of the driver's full scale (an ASI1600 driver reports
/// 65520 and its frames top out at 65504), and the star detector counts a
/// star saturated only when its peak is above the threshold.
ScienceCameraValues resolveScienceCameraValues({
  required String cameraName,
  required int? driverGain,
  required int maxAdu,
  required int adcBitDepth,
  required CameraSensorEntry? entry,
  double? readNoiseOverride,
  ScienceGainMeasurement? measurement,
}) {
  final curve = entry?.gainCurve;
  final bits = curve?.adcBitDepth ?? adcBitDepth;
  final adcMax = (1 << bits) - 1;
  final step = maxAdu > adcMax ? (maxAdu / adcMax).round() : 1;
  final saturation = math.max(255, maxAdu - 2 * step);
  final model = entry?.model ?? cameraName;
  final gainLabel = driverGain == null ? 'unknown gain' : 'gain $driverGain';
  final parts = <String>[];

  double? ePerAdu;
  final reading = (curve != null && driverGain != null)
      ? curve.at(driverGain)
      : null;
  if (measurement != null &&
      driverGain != null &&
      measurement.driverGain == driverGain &&
      measurement.cameraName.trim().toLowerCase() ==
          cameraName.trim().toLowerCase()) {
    ePerAdu = measurement.electronsPerAdu;
    parts.add(
      'e⁻/ADU ${ePerAdu.toStringAsFixed(4)} measured from '
      '${measurement.pairCount} flat pairs at $gainLabel',
    );
  } else if (reading != null) {
    ePerAdu = reading.electronsPerContainerAdu(
      containerMaxAdu: maxAdu,
      adcBitDepth: bits,
    );
    parts.add(
      'e⁻/ADU ${ePerAdu.toStringAsFixed(4)} at $gainLabel '
      '${_chartPhrase(reading)}',
    );
  } else {
    parts.add(
      driverGain == null
          ? 'e⁻/ADU unchanged: the camera gain is unknown'
          : 'e⁻/ADU unchanged: no published gain chart for $model; enter '
                'it by hand',
    );
  }

  double? readNoise;
  if (readNoiseOverride != null) {
    readNoise = readNoiseOverride;
    parts.add('read noise ${readNoise.toStringAsFixed(2)} e⁻ entered by you');
  } else if (reading != null) {
    readNoise = reading.readNoiseE;
    parts.add(
      'read noise ${readNoise.toStringAsFixed(2)} e⁻ '
      '${_chartPhrase(reading)}',
    );
  } else {
    final atThisGain = entry?.readNoiseE.where(
      (f) =>
          f.kind == PublishedFigureKind.atDriverGain &&
          f.driverGain == driverGain,
    );
    if (atThisGain != null && atThisGain.isNotEmpty) {
      readNoise = atThisGain.first.low;
      parts.add(
        'read noise ${readNoise.toStringAsFixed(2)} e⁻ published at '
        '$gainLabel',
      );
    } else {
      parts.add('read noise unchanged: no published figure at $gainLabel');
    }
  }
  parts.add('saturation $saturation ADU ($bits-bit ADC, full scale $maxAdu)');
  return ScienceCameraValues(
    saturationAdu: saturation,
    electronsPerAdu: ePerAdu,
    readNoiseE: readNoise,
    source: '$model at $gainLabel: ${parts.join('; ')}',
  );
}

String _chartPhrase(SensorGainReading reading) {
  if (reading.isClamped) {
    return "from the published gain chart's nearest end (gain "
        '${reading.gain} is outside it)';
  }
  if (reading.isPublishedPoint) return 'from the published gain chart';
  return 'interpolated from the published gain chart';
}
