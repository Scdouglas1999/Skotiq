import 'dart:convert';

import 'package:drift/drift.dart';

import '../../models/focuser_backlash_calibration.dart';
import '../database.dart';
import '../tables/settings.dart';

part 'settings_dao.g.dart';

/// Sensor geometry read off a camera the last time it was connected.
///
/// Sensor size is a fixed property of the hardware, but the app only ever
/// learned it from a live `getCameraStatus` / `getCameraCapabilities` call, so
/// framing and mosaic planning — the two things you do indoors, before a
/// session — required the rig to be powered up and connected. Remembering it
/// per camera id is what lets those surfaces work from the couch.
class RememberedSensorSpec {
  const RememberedSensorSpec({
    required this.sensorWidth,
    required this.sensorHeight,
    required this.pixelSizeX,
    required this.pixelSizeY,
    required this.recordedAt,
  });

  /// Sensor width in pixels.
  final int sensorWidth;

  /// Sensor height in pixels.
  final int sensorHeight;

  /// Pixel pitch across, in microns.
  final double pixelSizeX;

  /// Pixel pitch down, in microns.
  final double pixelSizeY;

  /// When these values were last read off the live camera.
  final DateTime recordedAt;

  /// Whether every value is usable for an FOV computation. Anything else is
  /// treated as "not remembered" rather than displayed as fact.
  bool get isUsable =>
      sensorWidth > 0 && sensorHeight > 0 && pixelSizeX > 0 && pixelSizeY > 0;

  Map<String, dynamic> toJson() => {
    'w': sensorWidth,
    'h': sensorHeight,
    'px': pixelSizeX,
    'py': pixelSizeY,
    'at': recordedAt.toUtc().toIso8601String(),
  };

  static RememberedSensorSpec? fromJson(Object? json) {
    if (json is! Map) return null;
    final w = json['w'];
    final h = json['h'];
    final px = json['px'];
    final py = json['py'];
    if (w is! num || h is! num || px is! num || py is! num) return null;
    final at = DateTime.tryParse(json['at'] as String? ?? '');
    final spec = RememberedSensorSpec(
      sensorWidth: w.toInt(),
      sensorHeight: h.toInt(),
      pixelSizeX: px.toDouble(),
      pixelSizeY: py.toDouble(),
      recordedAt: at ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
    return spec.isUsable ? spec : null;
  }

  @override
  bool operator ==(Object other) =>
      other is RememberedSensorSpec &&
      other.sensorWidth == sensorWidth &&
      other.sensorHeight == sensorHeight &&
      other.pixelSizeX == pixelSizeX &&
      other.pixelSizeY == pixelSizeY;

  @override
  int get hashCode =>
      Object.hash(sensorWidth, sensorHeight, pixelSizeX, pixelSizeY);
}

/// A focuser backlash figure this app measured, with the conditions it was
/// measured in.
///
/// Backlash varies along the travel — the owner's ZWO EAF measured 105 steps
/// near position 6600 and 83 near 2500 — so the position and temperature are
/// part of the record, not decoration. A bare number would claim more than the
/// measurement supports.
class FocuserBacklashCalibrationRecord {
  const FocuserBacklashCalibrationRecord({
    required this.steps,
    required this.measurable,
    required this.resolutionLimitSteps,
    required this.measuredAtPosition,
    required this.temperatureCelsius,
    required this.measuredAt,
    required this.confidence,
    required this.confidenceReason,
    required this.appVersion,
  });

  /// Backlash in focuser steps. 0 means the two scans agreed to within their
  /// own resolution: no backlash worth compensating, which is a result rather
  /// than a missing value.
  final int steps;

  /// False when [steps] is 0 because nothing larger than
  /// [resolutionLimitSteps] was detectable.
  final bool measurable;

  /// The smallest difference the scans behind this record could have told
  /// apart.
  final double resolutionLimitSteps;

  /// Where in the travel this was measured.
  final int measuredAtPosition;

  /// Focuser temperature at the time, when the driver reported one.
  final double? temperatureCelsius;

  final DateTime measuredAt;

  final FocuserBacklashConfidence confidence;

  /// Native's plain-language grounds for [confidence], displayed verbatim.
  final String confidenceReason;

  /// The build that took the measurement.
  final String appVersion;

  /// Whether this record can be acted on. Anything else is treated as "never
  /// measured" rather than applied to a focuser: a bad figure here silently
  /// moves the drawtube on every future autofocus.
  bool get isUsable =>
      steps >= 0 &&
      measuredAtPosition >= 0 &&
      resolutionLimitSteps.isFinite &&
      resolutionLimitSteps >= 0 &&
      // A measurable backlash of zero steps is a contradiction, and so is an
      // unmeasurable one with a figure attached.
      measurable == (steps > 0) &&
      (temperatureCelsius == null || temperatureCelsius!.isFinite);

  Map<String, dynamic> toJson() => {
    's': steps,
    'm': measurable,
    'rl': resolutionLimitSteps,
    'p': measuredAtPosition,
    if (temperatureCelsius != null) 't': temperatureCelsius,
    'at': measuredAt.toUtc().toIso8601String(),
    'c': confidence.wireValue,
    'cr': confidenceReason,
    'v': appVersion,
  };

  static FocuserBacklashCalibrationRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    final steps = json['s'];
    final measurable = json['m'];
    final resolutionLimit = json['rl'];
    final position = json['p'];
    final temperature = json['t'];
    final confidence = FocuserBacklashConfidence.fromWire(json['c']);
    if (steps is! num ||
        measurable is! bool ||
        resolutionLimit is! num ||
        position is! num ||
        confidence == null ||
        (temperature != null && temperature is! num)) {
      return null;
    }
    final record = FocuserBacklashCalibrationRecord(
      steps: steps.toInt(),
      measurable: measurable,
      resolutionLimitSteps: resolutionLimit.toDouble(),
      measuredAtPosition: position.toInt(),
      temperatureCelsius: (temperature as num?)?.toDouble(),
      measuredAt:
          DateTime.tryParse(json['at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      confidence: confidence,
      confidenceReason: json['cr'] as String? ?? '',
      appVersion: json['v'] as String? ?? '',
    );
    return record.isUsable ? record : null;
  }

  @override
  bool operator ==(Object other) =>
      other is FocuserBacklashCalibrationRecord &&
      other.steps == steps &&
      other.measurable == measurable &&
      other.resolutionLimitSteps == resolutionLimitSteps &&
      other.measuredAtPosition == measuredAtPosition &&
      other.temperatureCelsius == temperatureCelsius &&
      other.measuredAt == measuredAt &&
      other.confidence == confidence &&
      other.confidenceReason == confidenceReason &&
      other.appVersion == appVersion;

  @override
  int get hashCode => Object.hash(
    steps,
    measurable,
    resolutionLimitSteps,
    measuredAtPosition,
    temperatureCelsius,
    measuredAt,
    confidence,
    confidenceReason,
    appVersion,
  );
}

@DriftAccessor(tables: [AppSettings])
class SettingsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$SettingsDaoMixin {
  SettingsDao(super.db);

  /// Get a setting by key
  Future<String?> getSetting(String key) async {
    final result = await (select(
      appSettings,
    )..where((s) => s.key.equals(key))).getSingleOrNull();
    return result?.value;
  }

  /// Watch a setting by key
  Stream<String?> watchSetting(String key) {
    return (select(appSettings)..where((s) => s.key.equals(key)))
        .watchSingleOrNull()
        .map((s) => s?.value);
  }

  /// Get all settings
  Future<Map<String, String>> getAllSettings() async {
    final settings = await select(appSettings).get();
    return {for (var s in settings) s.key: s.value};
  }

  /// Watch all settings
  Stream<Map<String, String>> watchAllSettings() {
    return select(appSettings).watch().map((settings) {
      return {for (var s in settings) s.key: s.value};
    });
  }

  /// Set a setting
  Future<void> setSetting(String key, String value) async {
    await into(appSettings).insert(
      AppSettingsCompanion.insert(key: key, value: value),
      onConflict: DoUpdate(
        (old) => AppSettingsCompanion(
          value: Value(value),
          updatedAt: Value(DateTime.now()),
        ),
        target: <Column<Object>>[appSettings.key],
      ),
    );
  }

  /// Set multiple settings at once
  Future<void> setSettings(Map<String, String> settings) async {
    await batch((batch) {
      for (final entry in settings.entries) {
        batch.insert(
          appSettings,
          AppSettingsCompanion.insert(key: entry.key, value: entry.value),
          onConflict: DoUpdate(
            (old) => AppSettingsCompanion(
              value: Value(entry.value),
              updatedAt: Value(DateTime.now()),
            ),
            target: [appSettings.key],
          ),
        );
      }
    });
  }

  /// Delete a setting
  Future<int> deleteSetting(String key) {
    return (delete(appSettings)..where((s) => s.key.equals(key))).go();
  }

  // Typed getters for common settings

  Future<String> getTheme() async {
    return await getSetting('theme') ?? 'dark';
  }

  Future<void> setTheme(String theme) => setSetting('theme', theme);

  Future<String> getDefaultImageDirectory() async {
    return getImageOutputDirectory();
  }

  Future<void> setDefaultImageDirectory(String path) =>
      setImageOutputDirectory(path);

  /// Canonical capture output path with a read-through for pre-migration DBs.
  Future<String> getImageOutputDirectory() async {
    final current = await getSetting('image_output_path');
    if (current != null && current.trim().isNotEmpty) return current;
    return await getSetting('default_image_directory') ?? '';
  }

  /// Write both keys during the compatibility window so all app versions and
  /// post-session services agree on where masters and captures belong.
  Future<void> setImageOutputDirectory(String path) =>
      setSettings({'image_output_path': path, 'default_image_directory': path});

  Future<bool> getAutoConnectEquipment() async {
    final value = await getSetting('auto_connect_equipment');
    return value == 'true';
  }

  Future<void> setAutoConnectEquipment(bool enabled) =>
      setSetting('auto_connect_equipment', enabled.toString());

  Future<double> getObserverLatitude() async {
    final value = await getSetting('observer_latitude');
    return double.tryParse(value ?? '0') ?? 0.0;
  }

  Future<void> setObserverLatitude(double lat) =>
      setSetting('observer_latitude', lat.toString());

  Future<double> getObserverLongitude() async {
    final value = await getSetting('observer_longitude');
    return double.tryParse(value ?? '0') ?? 0.0;
  }

  Future<void> setObserverLongitude(double lon) =>
      setSetting('observer_longitude', lon.toString());

  Future<double> getObserverElevation() async {
    final value = await getSetting('observer_elevation');
    return double.tryParse(value ?? '0') ?? 0.0;
  }

  Future<void> setObserverElevation(double elevation) =>
      setSetting('observer_elevation', elevation.toString());

  // Auto-stretch settings
  static const String _autoStretchKey = 'auto_stretch_settings';

  /// Get auto-stretch settings as JSON string
  Future<String?> getAutoStretchSettings() async {
    return await getSetting(_autoStretchKey);
  }

  /// Watch auto-stretch settings
  Stream<String?> watchAutoStretchSettings() {
    return watchSetting(_autoStretchKey);
  }

  /// Save auto-stretch settings as JSON string
  Future<void> setAutoStretchSettings(String jsonSettings) =>
      setSetting(_autoStretchKey, jsonSettings);

  // Remembered camera sensor geometry ---------------------------------------
  //
  // Stored as one JSON object keyed by camera device id rather than as columns
  // on `equipment_profiles`, because sensor size belongs to the CAMERA, not to
  // whichever profile happens to reference it: two profiles sharing one camera
  // (an OTA swap) must not each hold their own copy that can disagree.

  static const String _cameraSensorSpecsKey = 'camera_sensor_specs';

  /// How many cameras to remember. A user cycles through a handful of bodies at
  /// most; the cap keeps a long-lived install from accumulating a row of stale
  /// ids forever.
  static const int _maxRememberedSensorSpecs = 16;

  /// Every remembered camera's sensor geometry, keyed by device id.
  Future<Map<String, RememberedSensorSpec>> getRememberedSensorSpecs() async {
    final raw = await getSetting(_cameraSensorSpecsKey);
    if (raw == null || raw.trim().isEmpty) return const {};
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // Corrupt value: report nothing remembered rather than throwing on a
      // path that only ever improves a UI.
      return const {};
    }
    if (decoded is! Map) return const {};
    final result = <String, RememberedSensorSpec>{};
    decoded.forEach((key, value) {
      if (key is! String) return;
      final spec = RememberedSensorSpec.fromJson(value);
      if (spec != null) result[key] = spec;
    });
    return result;
  }

  /// The sensor geometry remembered for [cameraId], or null if this camera has
  /// never been seen connected.
  Future<RememberedSensorSpec?> getRememberedSensorSpec(String cameraId) async {
    if (cameraId.isEmpty) return null;
    return (await getRememberedSensorSpecs())[cameraId];
  }

  /// Record what a live camera reported, so framing still works once it is
  /// unplugged. Unusable values are dropped rather than overwriting good ones.
  Future<void> rememberSensorSpec(
    String cameraId,
    RememberedSensorSpec spec,
  ) async {
    if (cameraId.isEmpty || !spec.isUsable) return;
    final existing = Map<String, RememberedSensorSpec>.from(
      await getRememberedSensorSpecs(),
    );
    if (existing[cameraId] == spec) return; // no write for an unchanged sensor
    existing[cameraId] = spec;
    if (existing.length > _maxRememberedSensorSpecs) {
      final byAge = existing.entries.toList()
        ..sort((a, b) => b.value.recordedAt.compareTo(a.value.recordedAt));
      existing
        ..clear()
        ..addEntries(byAge.take(_maxRememberedSensorSpecs));
    }
    await setSetting(
      _cameraSensorSpecsKey,
      jsonEncode({
        for (final entry in existing.entries) entry.key: entry.value.toJson(),
      }),
    );
  }

  // Measured focuser backlash -----------------------------------------------
  //
  // Keyed by focuser device id, like the sensor specs above and for the same
  // reason: a dead band is a property of that drive train, not of whichever
  // profile references it. It matters more here than there, because the
  // existing `app_settings.backlash_compensation` / `af_backlash_in` values
  // are GLOBAL — swap focusers and the old one's figure silently follows you
  // onto the new gear train. Those fields keep their meaning; this store just
  // does not reproduce the fault.

  static const String _focuserBacklashCalibrationsKey =
      'focuser_backlash_calibrations.v1';

  /// How many focusers to remember. A rig has one, an owner of several OTAs
  /// maybe four; the cap stops a long-lived install hoarding stale ids.
  static const int _maxFocuserBacklashCalibrations = 8;

  /// Every focuser's stored backlash measurement, keyed by device id.
  Future<Map<String, FocuserBacklashCalibrationRecord>>
  getFocuserBacklashCalibrations() async {
    final raw = await getSetting(_focuserBacklashCalibrationsKey);
    if (raw == null || raw.trim().isEmpty) return const {};
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // Corrupt value: report nothing measured. The alternative is guessing at
      // a number that moves hardware.
      return const {};
    }
    if (decoded is! Map) return const {};
    final result = <String, FocuserBacklashCalibrationRecord>{};
    decoded.forEach((key, value) {
      if (key is! String) return;
      final record = FocuserBacklashCalibrationRecord.fromJson(value);
      if (record != null) result[key] = record;
    });
    return result;
  }

  /// The measurement stored for [focuserId], or null when this focuser has
  /// never been calibrated. Never falls back to another focuser's figure.
  Future<FocuserBacklashCalibrationRecord?> getFocuserBacklashCalibration(
    String focuserId,
  ) async {
    if (focuserId.isEmpty) return null;
    return (await getFocuserBacklashCalibrations())[focuserId];
  }

  /// Store what a calibration run measured. An unusable record is dropped
  /// rather than overwriting a good one.
  Future<void> saveFocuserBacklashCalibration(
    String focuserId,
    FocuserBacklashCalibrationRecord record,
  ) async {
    if (focuserId.isEmpty || !record.isUsable) return;
    final existing = Map<String, FocuserBacklashCalibrationRecord>.from(
      await getFocuserBacklashCalibrations(),
    );
    if (existing[focuserId] == record) return; // no write for an unchanged run
    existing[focuserId] = record;
    if (existing.length > _maxFocuserBacklashCalibrations) {
      final byAge = existing.entries.toList()
        ..sort((a, b) => b.value.measuredAt.compareTo(a.value.measuredAt));
      existing
        ..clear()
        ..addEntries(byAge.take(_maxFocuserBacklashCalibrations));
    }
    await _writeFocuserBacklashCalibrations(existing);
  }

  /// Forget [focuserId]'s measurement — after a gear or motor change, where
  /// the stored figure is worse than none.
  Future<void> clearFocuserBacklashCalibration(String focuserId) async {
    if (focuserId.isEmpty) return;
    final existing = Map<String, FocuserBacklashCalibrationRecord>.from(
      await getFocuserBacklashCalibrations(),
    );
    if (existing.remove(focuserId) == null) return;
    await _writeFocuserBacklashCalibrations(existing);
  }

  Future<void> _writeFocuserBacklashCalibrations(
    Map<String, FocuserBacklashCalibrationRecord> records,
  ) async {
    await setSetting(
      _focuserBacklashCalibrationsKey,
      jsonEncode({
        for (final entry in records.entries) entry.key: entry.value.toJson(),
      }),
    );
  }
}
