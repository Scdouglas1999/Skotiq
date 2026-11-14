import 'dart:convert';
import 'dart:math' as math;

import '../../services/scheduler/horizon_profile.dart' as scheduler;
import 'learned_obstruction.dart';

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
class SiteHorizonProfile {
  final Map<String, double> _altitudes;

  /// The imported skyline, sorted by ascending azimuth, or empty when this
  /// profile is only the 8-sector mask. Never fewer than 2 entries when set:
  /// one sample cannot be interpolated and is already a flat horizon.
  final List<({double azimuth, double altitude})> _samples;

  /// Obstructions a run met at this site. Each blocks a narrow band of
  /// azimuth up to just above where it was seen; the effective horizon is the
  /// higher of these and the profile above, which they never change.
  final List<LearnedObstructionPoint> _learned;

  SiteHorizonProfile(
    this._altitudes, {
    List<({double azimuth, double altitude})> samples = const [],
    List<LearnedObstructionPoint> learned = const [],
  }) : _samples = _normalizeSamples(samples),
       _learned = List.unmodifiable(learned);

  /// This profile with the obstructions learned at the site added.
  SiteHorizonProfile withLearnedObstructions(
    List<LearnedObstructionPoint> learned,
  ) => SiteHorizonProfile(_altitudes, samples: _samples, learned: learned);

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

  factory SiteHorizonProfile.fromJson(String json) {
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
      return SiteHorizonProfile(altitudes, samples: samples);
    } catch (_) {
      // Return flat horizon on parse failure - this is a data error,
      // not something we should silently swallow. Log it.
      return SiteHorizonProfile._default();
    }
  }

  factory SiteHorizonProfile._default() {
    final altitudes = <String, double>{};
    for (final dir in horizonDirections) {
      altitudes[dir] = 0.0;
    }
    return SiteHorizonProfile(altitudes);
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

  /// Whether the operator set a horizon of their own: a sector or an imported
  /// sample above 0°. Learned obstructions do not count.
  bool get hasOwnHorizon =>
      _altitudes.values.any((v) => v != 0.0) ||
      _samples.any((s) => s.altitude != 0.0);

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
  factory SiteHorizonProfile.fromSamples(
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
    return SiteHorizonProfile(altitudes, samples: samples);
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
  factory SiteHorizonProfile.parseHorizonText(String text) {
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
    return SiteHorizonProfile.fromSamples(samples);
  }
}
