// Dart-side mirror of the Rust `expressions::catalog` variable
// list. Drives the VariablePicker UI: rows are populated from this static
// list, and rendered example values come straight from `example`.
//
// SINGLE SOURCE OF TRUTH: This file MUST stay in lockstep with
// `native/skotiq_native/sequencer/src/expressions/catalog.rs`.
// A unit test (`interpolation_catalog_parity_test.dart`) asserts that
// every entry declared in the Rust JSON dump appears here and vice
// versa, so a drift between the two surfaces a test failure on the
// next CI run.

import 'package:flutter/foundation.dart';

/// Top-level grouping for the variable picker UI.
enum InterpolationVariableGroup {
  target('Target'),
  filter('Filter'),
  frame('Frame'),
  session('Session'),
  time('Time'),
  moon('Moon'),
  weather('Weather'),
  observer('Observer'),
  equipment('Equipment'),
  exposure('Exposure');

  final String label;
  const InterpolationVariableGroup(this.label);
}

/// One row in the variable picker.
@immutable
class InterpolationVariable {
  /// The dotted name a user types inside `${...}`.
  final String name;

  /// One-line human-readable description.
  final String description;

  /// Group used to bucket the entry in the picker UI.
  final InterpolationVariableGroup group;

  /// Example value the variable resolves to (rendered next to the name in
  /// the picker so users see what to expect).
  final String example;

  /// Whether the variable accepts a numeric format spec (`.Nf` / `0N`).
  final bool supportsFormat;

  const InterpolationVariable({
    required this.name,
    required this.description,
    required this.group,
    required this.example,
    required this.supportsFormat,
  });

  /// Rendered placeholder, e.g. `${target.name}`. Used by the picker to
  /// insert the variable into the bound text field at the cursor.
  String get placeholder => '\${$name}';
}

/// The canonical Dart-side variable catalog. Mirrors the Rust list in
/// `expressions/catalog.rs::variable_catalog`.
const List<InterpolationVariable> interpolationCatalog = [
  // Target
  InterpolationVariable(
    name: 'target.name',
    description: 'Name of the active target (e.g. "M42")',
    group: InterpolationVariableGroup.target,
    example: 'M42',
    supportsFormat: false,
  ),
  InterpolationVariable(
    name: 'target.id',
    description: 'Stable internal identifier of the active target',
    group: InterpolationVariableGroup.target,
    example: 'tgt-7c3a',
    supportsFormat: false,
  ),
  InterpolationVariable(
    name: 'target.ra',
    description: 'Right ascension of the active target (hours)',
    group: InterpolationVariableGroup.target,
    example: '5.59',
    supportsFormat: true,
  ),
  InterpolationVariable(
    name: 'target.dec',
    description: 'Declination of the active target (degrees)',
    group: InterpolationVariableGroup.target,
    example: '-5.39',
    supportsFormat: true,
  ),
  InterpolationVariable(
    name: 'target.rotation',
    description: 'Position-angle rotation for the target (degrees)',
    group: InterpolationVariableGroup.target,
    example: '45.0',
    supportsFormat: true,
  ),
  InterpolationVariable(
    name: 'target.alt',
    description: 'Current altitude of the target (degrees)',
    group: InterpolationVariableGroup.target,
    example: '42.7',
    supportsFormat: true,
  ),
  InterpolationVariable(
    name: 'target.az',
    description: 'Current azimuth of the target (degrees)',
    group: InterpolationVariableGroup.target,
    example: '138.2',
    supportsFormat: true,
  ),
  // Filter
  InterpolationVariable(
    name: 'filter',
    description: 'Currently selected filter name',
    group: InterpolationVariableGroup.filter,
    example: 'Ha',
    supportsFormat: false,
  ),
  InterpolationVariable(
    name: 'filter.position',
    description: 'Filter-wheel position (1-based)',
    group: InterpolationVariableGroup.filter,
    example: '3',
    supportsFormat: true,
  ),
  // Frame counters
  InterpolationVariable(
    name: 'frame',
    description: 'Current frame number within the active burst',
    group: InterpolationVariableGroup.frame,
    example: '8',
    supportsFormat: true,
  ),
  InterpolationVariable(
    name: 'frame.total',
    description: 'Total frames requested in the active burst',
    group: InterpolationVariableGroup.frame,
    example: '30',
    supportsFormat: true,
  ),
  // Session
  InterpolationVariable(
    name: 'session.id',
    description: 'Unique identifier of the active imaging session',
    group: InterpolationVariableGroup.session,
    example: '5f9a-…-83b1',
    supportsFormat: false,
  ),
  InterpolationVariable(
    name: 'session.date',
    description: 'UTC date the session started (YYYY-MM-DD)',
    group: InterpolationVariableGroup.session,
    example: '2026-01-15',
    supportsFormat: false,
  ),
  InterpolationVariable(
    name: 'session.start',
    description: 'ISO-8601 UTC timestamp when the session started',
    group: InterpolationVariableGroup.session,
    example: '2026-01-15T22:14:33Z',
    supportsFormat: false,
  ),
  // Time
  InterpolationVariable(
    name: 'time.now',
    description: 'Current UTC timestamp (ISO-8601)',
    group: InterpolationVariableGroup.time,
    example: '2026-01-15T22:47:12Z',
    supportsFormat: false,
  ),
  InterpolationVariable(
    name: 'time.local',
    description: 'Current local timestamp (ISO-8601 with offset)',
    group: InterpolationVariableGroup.time,
    example: '2026-01-15 17:47:12 -05:00',
    supportsFormat: false,
  ),
  InterpolationVariable(
    name: 'time.date',
    description: 'Current UTC date (YYYY-MM-DD)',
    group: InterpolationVariableGroup.time,
    example: '2026-01-15',
    supportsFormat: false,
  ),
  // Moon
  InterpolationVariable(
    name: 'moon.phase',
    description: 'Moon illuminated fraction (0.0 – 1.0)',
    group: InterpolationVariableGroup.moon,
    example: '0.42',
    supportsFormat: true,
  ),
  InterpolationVariable(
    name: 'moon.separation',
    description: 'Angular separation between the moon and the target (degrees)',
    group: InterpolationVariableGroup.moon,
    example: '67.3',
    supportsFormat: true,
  ),
  // Weather
  InterpolationVariable(
    name: 'weather.temp_c',
    description: 'Ambient temperature (°C) from the active weather source',
    group: InterpolationVariableGroup.weather,
    example: '12.4',
    supportsFormat: true,
  ),
  InterpolationVariable(
    name: 'weather.humidity',
    description: 'Relative humidity percentage (0 – 100)',
    group: InterpolationVariableGroup.weather,
    example: '67',
    supportsFormat: true,
  ),
  InterpolationVariable(
    name: 'sqm',
    description: 'Sky-quality reading (mag / arcsec²) from the active sensor',
    group: InterpolationVariableGroup.weather,
    example: '21.2',
    supportsFormat: true,
  ),
  // Observer
  InterpolationVariable(
    name: 'observer.name',
    description: 'Observer name from app settings',
    group: InterpolationVariableGroup.observer,
    example: 'Alice',
    supportsFormat: false,
  ),
  InterpolationVariable(
    name: 'observer.lat',
    description: 'Observer latitude (degrees)',
    group: InterpolationVariableGroup.observer,
    example: '40.7128',
    supportsFormat: true,
  ),
  InterpolationVariable(
    name: 'observer.lon',
    description: 'Observer longitude (degrees)',
    group: InterpolationVariableGroup.observer,
    example: '-74.0060',
    supportsFormat: true,
  ),
  InterpolationVariable(
    name: 'observer.elevation',
    description: 'Observer elevation (metres)',
    group: InterpolationVariableGroup.observer,
    example: '150',
    supportsFormat: true,
  ),
  // Equipment
  InterpolationVariable(
    name: 'equipment.camera',
    description: 'Camera make + model from the active equipment profile',
    group: InterpolationVariableGroup.equipment,
    example: 'ZWO ASI2600MM',
    supportsFormat: false,
  ),
  InterpolationVariable(
    name: 'equipment.telescope',
    description: 'Telescope name from the active equipment profile',
    group: InterpolationVariableGroup.equipment,
    example: 'TS-Optics 130/910 APO',
    supportsFormat: false,
  ),
  InterpolationVariable(
    name: 'equipment.focal_length',
    description: 'Telescope focal length (mm)',
    group: InterpolationVariableGroup.equipment,
    example: '910',
    supportsFormat: true,
  ),
  InterpolationVariable(
    name: 'equipment.aperture',
    description: 'Telescope aperture (mm)',
    group: InterpolationVariableGroup.equipment,
    example: '130',
    supportsFormat: true,
  ),
  // Exposure
  InterpolationVariable(
    name: 'exposure.duration',
    description: 'Exposure duration of the active burst (seconds)',
    group: InterpolationVariableGroup.exposure,
    example: '180',
    supportsFormat: true,
  ),
  InterpolationVariable(
    name: 'exposure.gain',
    description: 'Camera gain of the active burst',
    group: InterpolationVariableGroup.exposure,
    example: '100',
    supportsFormat: true,
  ),
  InterpolationVariable(
    name: 'exposure.offset',
    description: 'Camera offset of the active burst',
    group: InterpolationVariableGroup.exposure,
    example: '10',
    supportsFormat: true,
  ),
  InterpolationVariable(
    name: 'exposure.binning',
    description: 'Binning of the active burst (e.g. "1x1")',
    group: InterpolationVariableGroup.exposure,
    example: '1x1',
    supportsFormat: false,
  ),
  InterpolationVariable(
    name: 'exposure.temp_c',
    description: 'Target cooler temperature (°C)',
    group: InterpolationVariableGroup.exposure,
    example: '-10',
    supportsFormat: true,
  ),
  InterpolationVariable(
    name: 'exposure.total',
    description:
        'Total burst integration time (minutes — duration_secs × count / 60)',
    group: InterpolationVariableGroup.exposure,
    example: '30',
    supportsFormat: true,
  ),
];

/// Best-effort client-side preview renderer.
///
/// Substitutes each `${name}` (with optional `:spec`) using the catalog's
/// `example` value. The real evaluator lives in Rust and consults the live
/// ExecutionContext; this preview is a UX affordance, not a source of
/// truth. The exact wire-format rules (zero-pad, `.Nf`) are mirrored so
/// the preview looks faithful.
///
/// Returns the rendered string. Unknown variables render as
/// `${name?}` so the user can spot a typo in the picker before the
/// sequence runs.
/// [catalog] defaults to the sequencer's expression catalog. A surface with a
/// different vocabulary (the live-stacking watermark, whose tokens are a flat
/// map owned by the broadcast service) passes its own, so the preview shows
/// what that surface will actually render rather than a sequencer example.
String previewInterpolation(
  String template, {
  List<InterpolationVariable> catalog = interpolationCatalog,
}) {
  // Map from name → example for O(1) lookup.
  final byName = {for (final v in catalog) v.name: v};
  final buf = StringBuffer();
  var i = 0;
  while (i < template.length) {
    // Doubled `$$` escapes `${`.
    if (i + 2 < template.length &&
        template[i] == r'$' &&
        template[i + 1] == r'$' &&
        template[i + 2] == '{') {
      buf.write(r'${');
      i += 3;
      continue;
    }
    if (i + 1 < template.length &&
        template[i] == r'$' &&
        template[i + 1] == '{') {
      final end = template.indexOf('}', i + 2);
      if (end < 0) {
        // Unterminated — render the remainder verbatim so the user can see
        // where they forgot the closing brace.
        buf.write(template.substring(i));
        return buf.toString();
      }
      final body = template.substring(i + 2, end).trim();
      final colonIdx = body.indexOf(':');
      final name = colonIdx < 0 ? body : body.substring(0, colonIdx).trim();
      final spec = colonIdx < 0 ? null : body.substring(colonIdx + 1).trim();
      final entry = byName[name];
      if (entry == null) {
        buf.write('\${$name?}');
      } else {
        buf.write(_renderExampleWithSpec(entry.example, spec));
      }
      i = end + 1;
      continue;
    }
    buf.write(template[i]);
    i += 1;
  }
  return buf.toString();
}

/// Apply a format spec to an example value (best-effort, for picker preview).
String _renderExampleWithSpec(String example, String? spec) {
  if (spec == null || spec.isEmpty) {
    return example;
  }
  // Integer zero-pad: `0N`.
  final zeroPad = RegExp(r'^0(\d+)$').firstMatch(spec);
  if (zeroPad != null) {
    final width = int.parse(zeroPad.group(1)!);
    final asInt = int.tryParse(example);
    if (asInt != null) {
      return asInt.toString().padLeft(width, '0');
    }
  }
  // Fixed-point: `.Nf`.
  final fixed = RegExp(r'^\.(\d+)f$').firstMatch(spec);
  if (fixed != null) {
    final precision = int.parse(fixed.group(1)!);
    final asDouble = double.tryParse(example);
    if (asDouble != null) {
      return asDouble.toStringAsFixed(precision);
    }
  }
  // Unknown / non-numeric → render with the spec suffix so the user sees
  // that something is happening but knows it's not a perfect preview.
  return '$example${spec.isEmpty ? '' : ' (:$spec)'}';
}
