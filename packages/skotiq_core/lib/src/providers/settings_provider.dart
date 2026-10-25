import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend/network_backend.dart';
import '../models/backend/event_types.dart'
    show EventCategory, SkotiqEvent, settingsChangedEventType;
import 'database_provider.dart';
import 'backend_provider.dart';
import 'frame_watch_settings_provider.dart';
import '../services/scheduler/horizon_profile.dart' as scheduler;
import 'host_settings/host_settings_providers.dart';
import '../models/plate_solver.dart';
import '../services/plate_solve_service.dart';
import '../models/settings/app_settings.dart' as models;
import '../models/settings/app_settings.dart'
    show ObserverLocation, SafetyFailMode, kDefaultAccentColorHex;
import '../models/imaging/imaging_models.dart'
    show AutofocusSettings, FilterAutofocusConfig;
import '../models/focuser_backlash_calibration.dart'
    show FocuserBacklashCalibrationSettings;

// Section parts: AppSettingsNotifier is one notifier split across `part` files
// under `settings_sections/`, one per UI / domain section. `part` rather than
// separate notifiers because the underlying `app_settings` row is a single
// Drift record and the remote-sync subscription in `build()` applies per-field
// `settings.changed` events to one in-memory state; section files also share
// the notifier's private helpers (`_saveSetting`, `_patchState`, `_unset`)
// without leaking them to the public API.
//
// A new setting needs a setter in its section file, a field plus copyWith entry
// in `app_settings_state.dart`, and persistence / remote-sync mapping.
part 'settings_sections/general.dart';
part 'settings_sections/appearance.dart';
part 'settings_sections/location.dart';
part 'settings_sections/environment.dart';
part 'settings_sections/recovery.dart';
part 'settings_sections/image_grading.dart';
part 'settings_sections/adaptive_exposure.dart';
part 'settings_sections/preflight.dart';
part 'settings_sections/smart_night.dart';
part 'settings_sections/session_lifecycle.dart';
part 'settings_sections/autofocus.dart';
part 'settings_sections/equipment.dart';
part 'settings_sections/file_paths.dart';
part 'settings_sections/imaging.dart';
part 'settings_sections/notifications.dart';
part 'settings_sections/phd2.dart';
part 'settings_sections/plate_solve.dart';
part 'settings_sections/protocol.dart';
part 'settings_sections/remote_access.dart';
part 'settings_sections/sequencer.dart';
part 'settings_sections/app_settings_state.dart';
part 'settings_sections/app_settings_state_copy_with.dart';
part 'settings_sections/app_settings_remote_mapping.dart';
part 'settings_sections/app_settings_stored_snapshot_mapping.dart';
part 'settings_sections/app_settings_partial_persistence_mapping.dart';
part 'settings_sections/app_settings_notifier.dart';

@immutable
class AppSettingsWriteFailure {
  final String setting;
  final Object error;
  final DateTime occurredAt;

  const AppSettingsWriteFailure({
    required this.setting,
    required this.error,
    required this.occurredAt,
  });

  String get message =>
      'Could not save $setting. The displayed value may not match the host.';
}

/// Central error channel for settings controls whose async setter callback is
/// intentionally fire-and-forget (switches, sliders, and text fields).
final appSettingsWriteFailureProvider = StateProvider<AppSettingsWriteFailure?>(
  (ref) => null,
);

// Pre-flight strictness

/// Pre-flight validation strictness mode. Tunes how aggressively the
/// pre-flight dialog should warn (or block) on questionable conditions:
///
///   * [lax]     — only obvious hardware errors block. Missing darks, stale
///                 polar alignment, mild time drift all surface as `info`.
///                 Suitable for "experienced user, knows what they're doing".
///   * [normal]  — default. Missing darks / stale alignment / cooler ambient
///                 issues become `warning`. Sequence can still start.
///   * [strict]  — production / unattended imaging. Missing darks and stale
///                 polar alignment become `error` (sequence won't start).
///                 Time-sync drift > 30 s is always an error regardless of
///                 strictness (it would falsify FITS timestamps).
enum PreflightStrictness { lax, normal, strict }

extension PreflightStrictnessLabel on PreflightStrictness {
  String get persistedName {
    switch (this) {
      case PreflightStrictness.lax:
        return 'lax';
      case PreflightStrictness.normal:
        return 'normal';
      case PreflightStrictness.strict:
        return 'strict';
    }
  }

  String get displayName {
    switch (this) {
      case PreflightStrictness.lax:
        return 'Lax';
      case PreflightStrictness.normal:
        return 'Normal';
      case PreflightStrictness.strict:
        return 'Strict';
    }
  }

  String get description {
    switch (this) {
      case PreflightStrictness.lax:
        return 'Soft warnings only. Missing darks and stale calibration surface as info.';
      case PreflightStrictness.normal:
        return 'Default. Missing darks and stale calibration are warnings; severe issues block.';
      case PreflightStrictness.strict:
        return 'Production / unattended. Missing darks and stale alignment block the start.';
    }
  }
}

PreflightStrictness _parsePreflightStrictness(String? value) {
  switch (value) {
    case 'lax':
      return PreflightStrictness.lax;
    case 'strict':
      return PreflightStrictness.strict;
    case 'normal':
    case null:
      return PreflightStrictness.normal;
    default:
      return PreflightStrictness.normal;
  }
}

// App settings

/// Sentinel used by `AppSettingsState.copyWith` to distinguish "no change"
/// from "explicitly clear the nullable field": Dart's `T?` parameter cannot
/// express both. Private to this library so callers go through `copyWith`.
const Object _unset = Object();

/// Main app settings provider
final appSettingsProvider =
    AsyncNotifierProvider<AppSettingsNotifier, AppSettingsState>(() {
      return AppSettingsNotifier();
    });

/// Effective horizon in degrees selected from [appSettingsProvider].
///
/// The same value is consumed by the Run Dashboard's "time-to-set"
/// statistic and by the planetarium target-card so both surfaces display
/// the same number to the second. Falls back to 0° (mathematical horizon)
/// before settings have loaded.
final effectiveHorizonDegProvider = Provider<double>((ref) {
  final settings = ref.watch(appSettingsProvider).valueOrNull;
  return settings?.effectiveHorizonDeg ?? 0.0;
});

/// Focused observer-location selector derived from [appSettingsProvider].
///
/// Watching this provider avoids rebuilding weather/suggestion chains when
/// unrelated settings change.
final appObserverLocationProvider = Provider<LocationSettings?>((ref) {
  final location = ref.watch(
    appSettingsProvider.select(
      (settingsAsync) => settingsAsync.valueOrNull == null
          ? null
          : (
              latitude: settingsAsync.valueOrNull!.latitude,
              longitude: settingsAsync.valueOrNull!.longitude,
              elevation: settingsAsync.valueOrNull!.elevation,
            ),
    ),
  );

  if (location == null) {
    return null;
  }
  // One rule, one home: [siteLocationIsSet] is the canonical not-set test.
  if (!siteLocationIsSet(location.latitude, location.longitude)) {
    return null;
  }

  return LocationSettings(
    latitude: location.latitude,
    longitude: location.longitude,
    elevation: location.elevation,
  );
});

// Autofocus settings provider (convenience)

/// Convenience provider that derives a typed [AutofocusSettings] from the
/// persisted [AppSettingsState] autofocus fields.
///
/// This avoids every consumer needing to manually pluck out individual
/// `af_*` fields and parse the filter settings JSON.
final autofocusSettingsProvider = Provider<AutofocusSettings>((ref) {
  final settingsAsync = ref.watch(appSettingsProvider);
  final settings = settingsAsync.valueOrNull;
  if (settings == null) {
    return const AutofocusSettings();
  }

  return AutofocusSettings(
    method: settings.afMethod,
    curveFitting: settings.afCurveFitting,
    stepSize: settings.afStepSize,
    exposureTime: settings.afExposureTime,
    initialOffsetSteps: settings.afInitialOffsetSteps,
    numberOfAttempts: settings.afNumberOfAttempts,
    useBrightestNStars: settings.afUseBrightestNStars,
    outerCropRatio: settings.afOuterCropRatio,
    innerCropRatio: settings.afInnerCropRatio,
    binning: settings.afBinning,
    rSquaredThreshold: settings.afRSquaredThreshold,
    failureHfrToleranceRatio: settings.afFailureHfrToleranceRatio,
    disableGuidingDuringAf: settings.afDisableGuidingDuringAf,
    focuserSettleTimeMs: settings.afFocuserSettleTimeMs,
    exposuresPerPoint: settings.afExposuresPerPoint,
    backlashCompMethod: settings.afBacklashCompMethod,
    backlashIn: settings.afBacklashIn,
    backlashOut: settings.afBacklashOut,
    autofocusFilterName: settings.afAutofocusFilterName,
    filterSettings: AutofocusSettings.parseFilterSettingsJson(
      settings.afFilterSettingsJson,
    ),
  );
});

// Legacy providers, kept for backwards compatibility

/// Location settings for observer position
class LocationSettings {
  final double latitude;
  final double longitude;
  final double elevation;

  const LocationSettings({
    this.latitude = 0.0,
    this.longitude = 0.0,
    this.elevation = 0.0,
  });

  LocationSettings copyWith({
    double? latitude,
    double? longitude,
    double? elevation,
  }) {
    return LocationSettings(
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      elevation: elevation ?? this.elevation,
    );
  }
}

// Theme settings

/// Theme mode setting
class ThemeSettingsNotifier extends AsyncNotifier<String> {
  @override
  Future<String> build() async {
    final dao = ref.read(settingsDaoProvider);
    return await dao.getTheme();
  }

  Future<void> setTheme(String theme) async {
    final dao = ref.read(settingsDaoProvider);
    await dao.setTheme(theme);
    state = AsyncData(theme);
  }
}

// Auto-connect settings

/// Auto connect equipment setting
class AutoConnectSettingsNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final dao = ref.read(settingsDaoProvider);
    return await dao.getAutoConnectEquipment();
  }

  Future<void> setAutoConnect(bool enabled) async {
    final dao = ref.read(settingsDaoProvider);
    await dao.setAutoConnectEquipment(enabled);
    state = AsyncData(enabled);
  }
}

final autoConnectSettingsProvider =
    AsyncNotifierProvider<AutoConnectSettingsNotifier, bool>(() {
      return AutoConnectSettingsNotifier();
    });

// Horizon profile utilities

/// 8 compass directions for horizon profile definition
const List<String> horizonDirections = [
  'N',
  'NE',
  'E',
  'SE',
  'S',
  'SW',
  'W',
  'NW',
];

/// Azimuth angles corresponding to each compass direction
const List<double> horizonDirectionAzimuths = [
  0.0,
  45.0,
  90.0,
  135.0,
  180.0,
  225.0,
  270.0,
  315.0,
];

/// Bortle scale descriptions and limiting magnitudes
class BortleScale {
  static const Map<int, String> descriptions = {
    1: 'Excellent dark-sky site',
    2: 'Typical truly dark site',
    3: 'Rural sky',
    4: 'Rural/suburban transition',
    5: 'Suburban sky',
    6: 'Bright suburban sky',
    7: 'Suburban/urban transition',
    8: 'City sky',
    9: 'Inner-city sky',
  };

  static const Map<int, double> limitingMagnitudes = {
    1: 7.6,
    2: 7.1,
    3: 6.6,
    4: 6.2,
    5: 5.9,
    6: 5.5,
    7: 5.0,
    8: 4.5,
    9: 4.0,
  };

  /// Get limiting magnitude for a Bortle class (1-9)
  static double limitingMagnitude(int bortleClass) {
    return limitingMagnitudes[bortleClass.clamp(1, 9)] ?? 5.9;
  }

  /// Get description for a Bortle class (1-9)
  static String description(int bortleClass) {
    return descriptions[bortleClass.clamp(1, 9)] ?? 'Unknown';
  }
}

/// Utility for parsing and interpolating horizon profiles.
///
/// A horizon profile is stored as a JSON map with 8 compass direction keys
/// (N, NE, E, SE, S, SW, W, NW) mapped to altitude values in degrees — the
/// coarse mask the settings screen edits.
///
/// It ALSO carries the original samples when it came from an imported survey.
/// Every consumer asks for a per-azimuth altitude ([altitudeAtAzimuth]: the
/// planner's visibility filter, and the planetarium, which builds a 360-entry
/// table from it), and that answers from the samples when they are present, so
/// an imported 1°-resolution skyline reaches both at its own resolution rather
/// than as a 45°-sector maximum. The 8 compass fields remain the editor and the
/// summary; editing any of them writes a samples-less profile, an explicit
/// override by sector.
class HorizonProfile {
  final Map<String, double> _altitudes;

  /// The imported skyline, sorted by ascending azimuth, or empty when this
  /// profile is only the 8-sector mask. Never fewer than 2 entries when set:
  /// one sample cannot be interpolated and is already a flat horizon.
  final List<({double azimuth, double altitude})> _samples;

  /// Obstructions a run met at this site. Each blocks a narrow band of
  /// azimuth up to just above where it was seen; the effective horizon is the
  /// higher of these and the profile above, which they never change.
  final List<LearnedObstructionPoint> _learned;

  HorizonProfile(
    this._altitudes, {
    List<({double azimuth, double altitude})> samples = const [],
    List<LearnedObstructionPoint> learned = const [],
  }) : _samples = _normalizeSamples(samples),
       _learned = List.unmodifiable(learned);

  /// This profile with the obstructions learned at the site added.
  HorizonProfile withLearnedObstructions(
    List<LearnedObstructionPoint> learned,
  ) => HorizonProfile(_altitudes, samples: _samples, learned: learned);

  /// How many learned obstructions are merged into this profile.
  int get learnedObstructionCount => _learned.length;

  /// How many samples back this profile — 0 when it is the 8-sector mask
  /// alone. The import message reports this.
  int get sampleCount => _samples.length;

  /// Normalize to [0,360) azimuths with clamped altitudes, sorted ascending,
  /// dropping anything unusable. A profile that ends up with fewer than two
  /// usable samples carries none: [altitudeAtAzimuth] would have nothing to
  /// interpolate between and must fall back to the sector mask.
  static List<({double azimuth, double altitude})> _normalizeSamples(
    List<({double azimuth, double altitude})> samples,
  ) {
    final normalized = <({double azimuth, double altitude})>[];
    for (final s in samples) {
      if (!s.azimuth.isFinite || !s.altitude.isFinite) continue;
      var az = s.azimuth % 360.0;
      if (az < 0) az += 360.0;
      normalized.add((azimuth: az, altitude: s.altitude.clamp(0.0, 89.0)));
    }
    if (normalized.length < 2) return const [];
    normalized.sort((a, b) => a.azimuth.compareTo(b.azimuth));
    return List.unmodifiable(normalized);
  }

  /// Parse a horizon profile from JSON string.
  factory HorizonProfile.fromJson(String json) {
    try {
      final decoded = _decodeProfileJson(json);
      final altitudes = <String, double>{};
      for (final dir in horizonDirections) {
        final val = decoded[dir];
        if (val is num) {
          altitudes[dir] = val.toDouble().clamp(0.0, 89.0);
        } else {
          altitudes[dir] = 0.0;
        }
      }
      final rawSamples = decoded['samples'];
      final samples = <({double azimuth, double altitude})>[];
      if (rawSamples is List) {
        for (final entry in rawSamples) {
          if (entry is List && entry.length >= 2) {
            final az = entry[0];
            final alt = entry[1];
            if (az is num && alt is num) {
              samples.add((azimuth: az.toDouble(), altitude: alt.toDouble()));
            }
          }
        }
      }
      return HorizonProfile(altitudes, samples: samples);
    } catch (_) {
      // Return flat horizon on parse failure - this is a data error,
      // not something we should silently swallow. Log it.
      return HorizonProfile._default();
    }
  }

  factory HorizonProfile._default() {
    final altitudes = <String, double>{};
    for (final dir in horizonDirections) {
      altitudes[dir] = 0.0;
    }
    return HorizonProfile(altitudes);
  }

  /// Get the altitude at a specific compass direction
  double altitudeAt(String direction) => _altitudes[direction] ?? 0.0;

  /// Get interpolated horizon altitude at any azimuth (0-360 degrees).
  ///
  /// When an imported survey is on record this interpolates the real samples
  /// (linear, wrapping at 360°), which is the resolution the file had. Only a
  /// hand-edited 8-sector mask falls through to the smoothstep between compass
  /// points. Every visibility decision in the app funnels through here, so
  /// this is the one place that has to know the difference.
  double altitudeAtAzimuth(double azimuthDeg) {
    final base = _profileAltitudeAt(azimuthDeg);
    if (_learned.isEmpty) return base;
    final learned = learnedObstructionAltitudeAt(_learned, azimuthDeg);
    return learned == null ? base : math.max(base, learned);
  }

  /// The profile's own altitude at [azimuthDeg], without learned
  /// obstructions.
  double _profileAltitudeAt(double azimuthDeg) {
    // Normalize azimuth to 0-360
    var az = azimuthDeg % 360.0;
    if (az < 0) az += 360.0;

    if (_samples.length >= 2) return _interpolateSamples(az);

    // Find which two compass points we're between
    const segmentSize = 360.0 / 8.0; // 45 degrees per segment
    final segmentIndex = (az / segmentSize).floor() % 8;
    final nextIndex = (segmentIndex + 1) % 8;

    // Fraction within this segment (0.0 to 1.0)
    final fraction = (az - segmentIndex * segmentSize) / segmentSize;

    final alt1 = _altitudes[horizonDirections[segmentIndex]] ?? 0.0;
    final alt2 = _altitudes[horizonDirections[nextIndex]] ?? 0.0;

    // Smoothstep interpolation for natural-looking transitions
    final t = fraction * fraction * (3.0 - 2.0 * fraction);
    return alt1 + (alt2 - alt1) * t;
  }

  /// Linear interpolation between the two samples bracketing [az], wrapping
  /// across 360°. Linear, not smoothstep: a smoothstep between dense samples
  /// would round off the very ridge lines the survey was taken to record.
  ///
  /// Binary search, not a scan: the planetarium rebuilds a 360-entry terrain
  /// table from this on every sky-view build, and a 1°-resolution survey would
  /// otherwise make that ~65k comparisons per frame.
  double _interpolateSamples(double az) {
    final samples = _samples;
    // First index whose azimuth is >= az.
    var lo = 0;
    var hi = samples.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (samples[mid].azimuth < az) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }

    final ({double azimuth, double altitude}) lower;
    final ({double azimuth, double altitude}) upper;
    final double lowerAz;
    final double upperAz;
    if (lo == 0) {
      // Before the first sample: bracket backwards across the wrap.
      lower = samples.last;
      lowerAz = lower.azimuth - 360.0;
      upper = samples.first;
      upperAz = upper.azimuth;
    } else if (lo == samples.length) {
      // Past the last sample: bracket forwards across the wrap.
      lower = samples.last;
      lowerAz = lower.azimuth;
      upper = samples.first;
      upperAz = upper.azimuth + 360.0;
    } else {
      lower = samples[lo - 1];
      lowerAz = lower.azimuth;
      upper = samples[lo];
      upperAz = upper.azimuth;
    }

    final span = upperAz - lowerAz;
    if (span <= 0) return lower.altitude;
    final t = ((az - lowerAz) / span).clamp(0.0, 1.0);
    return lower.altitude + (upper.altitude - lower.altitude) * t;
  }

  /// Check if a given altitude at a given azimuth is above the custom horizon
  bool isAboveHorizon(double altitudeDeg, double azimuthDeg) {
    return altitudeDeg >= altitudeAtAzimuth(azimuthDeg);
  }

  /// Encode back to JSON string.
  ///
  /// The eight compass keys come first and are unchanged, so a build that
  /// predates the `samples` array still reads a valid — merely coarser —
  /// mask out of the same stored string.
  String toJson() {
    final parts = <String>[];
    for (final dir in horizonDirections) {
      final val = _altitudes[dir] ?? 0.0;
      parts.add('"$dir":${val.toStringAsFixed(1)}');
    }
    if (_samples.isNotEmpty) {
      final encoded = _samples
          .map(
            (s) =>
                '[${s.azimuth.toStringAsFixed(2)},'
                '${s.altitude.toStringAsFixed(2)}]',
          )
          .join(',');
      parts.add('"samples":[$encoded]');
    }
    return '{${parts.join(',')}}';
  }

  /// Decode the stored blob. Uses a real JSON parser because the profile now
  /// carries a nested `samples` array; [_parseSimpleJson] only ever handled
  /// flat `string -> number` maps and silently dropped anything else, which
  /// would have thrown the imported skyline away on every reload.
  static Map<String, dynamic> _decodeProfileJson(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // Fall through to the tolerant parser below: a hand-edited or
      // truncated blob should still yield whatever compass values it has
      // rather than resetting the operator's mask to flat.
    }
    return _parseSimpleJson(json);
  }

  /// Simple JSON parser for flat string->number maps. Kept as the fallback
  /// for a blob [_decodeProfileJson] cannot parse as JSON.
  static Map<String, dynamic> _parseSimpleJson(String json) {
    final result = <String, dynamic>{};
    // Strip braces and split by comma
    var trimmed = json.trim();
    if (trimmed.startsWith('{')) trimmed = trimmed.substring(1);
    if (trimmed.endsWith('}')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    if (trimmed.isEmpty) return result;

    for (final pair in trimmed.split(',')) {
      final colonIdx = pair.indexOf(':');
      if (colonIdx < 0) continue;
      var key = pair.substring(0, colonIdx).trim();
      final value = pair.substring(colonIdx + 1).trim();
      // Strip quotes from key
      if (key.startsWith('"') && key.endsWith('"')) {
        key = key.substring(1, key.length - 1);
      }
      final numVal = double.tryParse(value);
      if (numVal != null) {
        result[key] = numVal;
      }
    }
    return result;
  }

  /// Whether this profile is all zeros (flat horizon) with no learned
  /// obstruction.
  bool get isFlat =>
      _learned.isEmpty && _altitudes.values.every((v) => v == 0.0);

  /// The effective horizon as (azimuth, altitude) samples every [stepDeg]
  /// degrees, plus both edges of every learned obstruction's band, so a
  /// consumer that interpolates linearly between samples keeps the bands'
  /// edges sharp.
  List<({double azimuth, double altitude})> denseSamples({
    double stepDeg = 1.0,
  }) {
    final azimuths = <double>{
      for (var az = 0.0; az < 360.0; az += stepDeg) az,
      for (final p in _learned) ...[
        for (final edge in [
          p.azimuthDeg - learnedObstructionHalfWidthDeg,
          p.azimuthDeg + learnedObstructionHalfWidthDeg,
        ]) ...[
          _wrapAz(edge),
          _wrapAz(edge + (edge < p.azimuthDeg ? -0.01 : 0.01)),
        ],
      ],
    }.toList()..sort();
    return [
      for (final az in azimuths) (azimuth: az, altitude: altitudeAtAzimuth(az)),
    ];
  }

  /// The effective horizon as the scheduler's samples-based profile, for
  /// plans that carry their own horizon (a Target Scheduler node).
  scheduler.HorizonProfile toSchedulerProfile({String name = 'Site horizon'}) =>
      scheduler.HorizonProfile(
        name: name,
        samples: [
          for (final s in denseSamples())
            scheduler.HorizonSample(s.azimuth, s.altitude),
        ],
      );

  static double _wrapAz(double az) {
    final v = az % 360.0;
    return v < 0 ? v + 360.0 : v;
  }

  /// Build a profile from arbitrary (azimuth, altitude) samples.
  ///
  /// The eight compass fields are the sector SUMMARY — each spans 45° centred
  /// on its azimuth (e.g. N covers 337.5°–22.5°) and takes the highest sampled
  /// altitude in it, so the number the settings screen shows never
  /// under-reports an obstruction. Sectors with no samples read 0° (open sky).
  ///
  /// The samples themselves are kept, and they are what [altitudeAtAzimuth]
  /// answers from — the summary is for the editor, not for the planner.
  factory HorizonProfile.fromSamples(
    List<({double azimuth, double altitude})> samples,
  ) {
    final altitudes = <String, double>{
      for (final dir in horizonDirections) dir: 0.0,
    };
    for (final s in samples) {
      var az = s.azimuth % 360.0;
      if (az < 0) az += 360.0;
      // Round to the nearest of the 8 directions (45° sectors, N straddles 0°).
      final index = (((az + 22.5) % 360.0) / 45.0).floor() % 8;
      final dir = horizonDirections[index];
      final alt = s.altitude.clamp(0.0, 89.0);
      if (alt > altitudes[dir]!) altitudes[dir] = alt;
    }
    return HorizonProfile(altitudes, samples: samples);
  }

  /// Parse a horizon dump (CSV or whitespace-separated "azimuth altitude"
  /// pairs, one per line) into a profile.
  ///
  /// Accepts the common Stellarium-style `.hor` format and plain CSV:
  ///   * comma OR whitespace separates the azimuth and altitude on each line;
  ///   * blank lines and comment lines (starting with `#`, `//`, or `;`) are
  ///     ignored;
  ///   * each data line must contain at least two numeric fields.
  ///
  /// Throws [FormatException] on a malformed line or if no samples are found.
  factory HorizonProfile.parseHorizonText(String text) {
    final samples = <({double azimuth, double altitude})>[];
    final lines = text.split(RegExp(r'[\r\n]+'));
    for (var i = 0; i < lines.length; i++) {
      final trimmed = lines[i].trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('#') ||
          trimmed.startsWith('//') ||
          trimmed.startsWith(';')) {
        continue;
      }
      final parts = trimmed
          .split(RegExp(r'[\s,]+'))
          .where((p) => p.isNotEmpty)
          .toList();
      if (parts.length < 2) {
        throw FormatException(
          'Horizon import line ${i + 1}: expected "azimuth altitude", '
          'got "$trimmed"',
        );
      }
      final az = double.tryParse(parts[0]);
      final alt = double.tryParse(parts[1]);
      if (az == null || alt == null) {
        throw FormatException(
          'Horizon import line ${i + 1}: non-numeric value in "$trimmed"',
        );
      }
      samples.add((azimuth: az, altitude: alt));
    }
    if (samples.isEmpty) {
      throw const FormatException(
        'Horizon import contained no usable azimuth/altitude pairs',
      );
    }
    return HorizonProfile.fromSamples(samples);
  }
}

/// Focused provider for Bortle class.
final bortleClassProvider = Provider<int>((ref) {
  final settingsAsync = ref.watch(appSettingsProvider);
  return settingsAsync.valueOrNull?.bortleClass ?? 5;
});

/// Focused provider for parsed horizon profile.
///
/// The operator's profile with the obstructions the runs learned at the
/// current site merged in (see [userHorizonProfileProvider] for the profile
/// alone, which is what the horizon editor edits).
final horizonProfileProvider = Provider<HorizonProfile>((ref) {
  final profile = ref.watch(userHorizonProfileProvider);
  final site = ref.watch(appObserverLocationProvider);
  if (site == null) return profile;
  final learned =
      ref
          .watch(frameWatchSettingsProvider)
          .valueOrNull
          ?.pointsForSite(site.latitude, site.longitude) ??
      const <LearnedObstructionPoint>[];
  if (learned.isEmpty) return profile;
  return profile.withLearnedObstructions(learned);
});

/// The operator's own horizon profile, without learned obstructions.
final userHorizonProfileProvider = Provider<HorizonProfile>((ref) {
  final json = ref.watch(
    appSettingsProvider.select(
      (settingsAsync) =>
          settingsAsync.valueOrNull?.horizonProfileJson ??
          '{"N":0,"NE":0,"E":0,"SE":0,"S":0,"SW":0,"W":0,"NW":0}',
    ),
  );
  return HorizonProfile.fromJson(json);
});
