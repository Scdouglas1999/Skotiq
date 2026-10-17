/// Event model + evidence codecs for the Night Narrator.
///
/// The Narrator is the *stateful, temporal* sibling of [ScienceInsightsEngine]
/// (`science_insights_engine.dart`). Where the insights engine reports what is
/// true *right now*, the Narrator detects **changes, events, and records** over
/// the course of a session — trends, thresholds crossed, discoveries,
/// bests-of-night — and persists them as a session-long feed of timestamped
/// insight cards ("the story of your night").
///
/// This file holds the plain (no freezed) value types every layer agrees on:
///   * [NarratorCategory] / [NarratorSeverity] — render hints (icon + accent).
///   * [NarratorEvidence] — the typed micro-visualization payload, with a small
///     JSON codec (`toJson`/`fromJson` + validation) so the UI can render any
///     of the four shapes generically without knowing the detector.
///   * [NarratorEventDraft] — what a detector emits (no id/timestamp yet).
///   * [NarratorEvent] — a persisted, surfaced event (the draft + DB identity).
library;

import 'dart:convert';

/// Top-level grouping for an event. Drives the category icon at the UI layer
/// (discovery `sparkles`, milestone `trophy`, conditions `cloudMoon`,
/// equipment `wrench`, quality `gauge`).
enum NarratorCategory { discovery, milestone, conditions, equipment, quality }

/// Severity tier. Drives the subtle left-edge accent colour and, for
/// [NarratorSeverity.celebrate], a distinct emphasised treatment.
enum NarratorSeverity { celebrate, success, info, warning, critical }

/// Parse a [NarratorCategory] from its stable wire string; falls back to
/// [NarratorCategory.quality] for forward-compatibility with unknown values.
NarratorCategory narratorCategoryFromName(String name) {
  for (final value in NarratorCategory.values) {
    if (value.name == name) return value;
  }
  return NarratorCategory.quality;
}

/// Parse a [NarratorSeverity] from its stable wire string; falls back to
/// [NarratorSeverity.info] for unknown values.
NarratorSeverity narratorSeverityFromName(String name) {
  for (final value in NarratorSeverity.values) {
    if (value.name == name) return value;
  }
  return NarratorSeverity.info;
}

/// The shape of an [NarratorEvidence] payload. Mirrors the four `kind`
/// discriminators in the design spec — the UI renders each generically.
enum NarratorEvidenceKind {
  /// `{"kind":"sparkline","points":[..],"unit":"%","highlightLast":true}`
  sparkline,

  /// `{"kind":"delta","from":18.6,"to":19.2,"unit":"mag","direction":"up"}`
  delta,

  /// `{"kind":"vector","directionDeg":45,"magnitude":0.3,"label":"NE corner"}`
  vector,

  /// `{"kind":"scalar","value":1.8,"unit":"\"","context":"session best"}`
  scalar,
}

/// A typed micro-visualization payload attached to an event.
///
/// Exactly one of the four factory constructors is meaningful for a given
/// instance; [kind] tells the UI which fields to read. The codec round-trips
/// through [toJson]/[fromJsonString] and validates on the way back in so a
/// malformed `evidenceJson` row never crashes a feed render — it is dropped to
/// `null` instead.
class NarratorEvidence {
  final NarratorEvidenceKind kind;

  // sparkline
  final List<double>? points;
  final bool highlightLast;

  // delta
  final double? from;
  final double? to;

  /// `"up"` | `"down"` | `"flat"` — direction of a delta, or the dominant
  /// direction implied by a sparkline trend.
  final String? direction;

  // vector
  final double? directionDeg;
  final double? magnitude;
  final String? label;

  // scalar
  final double? value;
  final String? context;

  /// Unit suffix shared by sparkline / delta / scalar (`"%"`, `"mag"`, `"\""`).
  final String? unit;

  const NarratorEvidence._({
    required this.kind,
    this.points,
    this.highlightLast = false,
    this.from,
    this.to,
    this.direction,
    this.directionDeg,
    this.magnitude,
    this.label,
    this.value,
    this.context,
    this.unit,
  });

  /// A small time-series the UI draws as a sparkline. [highlightLast] dots the
  /// most recent point. [direction] optionally annotates the overall trend.
  factory NarratorEvidence.sparkline({
    required List<double> points,
    String? unit,
    bool highlightLast = true,
    String? direction,
  }) {
    return NarratorEvidence._(
      kind: NarratorEvidenceKind.sparkline,
      points: List<double>.unmodifiable(points),
      unit: unit,
      highlightLast: highlightLast,
      direction: direction,
    );
  }

  /// A before/after pair the UI draws as a labelled arrow.
  factory NarratorEvidence.delta({
    required double from,
    required double to,
    String? unit,
    String? direction,
  }) {
    return NarratorEvidence._(
      kind: NarratorEvidenceKind.delta,
      from: from,
      to: to,
      unit: unit,
      direction:
          direction ?? (to > from ? 'up' : (to < from ? 'down' : 'flat')),
    );
  }

  /// A direction + magnitude the UI draws as an arrow on a compass/field
  /// (e.g. a tilt toward the NE corner).
  factory NarratorEvidence.vector({
    required double directionDeg,
    required double magnitude,
    String? label,
  }) {
    return NarratorEvidence._(
      kind: NarratorEvidenceKind.vector,
      directionDeg: directionDeg,
      magnitude: magnitude,
      label: label,
    );
  }

  /// A single highlighted number with a short context line (e.g. a session
  /// best). The UI draws it as a big-number chip.
  factory NarratorEvidence.scalar({
    required double value,
    String? unit,
    String? context,
  }) {
    return NarratorEvidence._(
      kind: NarratorEvidenceKind.scalar,
      value: value,
      unit: unit,
      context: context,
    );
  }

  Map<String, dynamic> toJson() {
    switch (kind) {
      case NarratorEvidenceKind.sparkline:
        return {
          'kind': 'sparkline',
          'points': points ?? const <double>[],
          if (unit != null) 'unit': unit,
          'highlightLast': highlightLast,
          if (direction != null) 'direction': direction,
        };
      case NarratorEvidenceKind.delta:
        return {
          'kind': 'delta',
          'from': from,
          'to': to,
          if (unit != null) 'unit': unit,
          if (direction != null) 'direction': direction,
        };
      case NarratorEvidenceKind.vector:
        return {
          'kind': 'vector',
          'directionDeg': directionDeg,
          'magnitude': magnitude,
          if (label != null) 'label': label,
        };
      case NarratorEvidenceKind.scalar:
        return {
          'kind': 'scalar',
          'value': value,
          if (unit != null) 'unit': unit,
          if (context != null) 'context': context,
        };
    }
  }

  String toJsonString() => jsonEncode(toJson());

  /// Parse from a decoded JSON map. Returns `null` when the payload is missing
  /// required fields for its declared `kind`, so a malformed row is dropped
  /// rather than throwing inside a feed render.
  static NarratorEvidence? fromJson(Map<String, dynamic> map) {
    final kind = map['kind'];
    switch (kind) {
      case 'sparkline':
        final rawPoints = map['points'];
        if (rawPoints is! List) return null;
        final points = <double>[];
        for (final p in rawPoints) {
          if (p is num && p.toDouble().isFinite) {
            points.add(p.toDouble());
          } else {
            return null;
          }
        }
        return NarratorEvidence.sparkline(
          points: points,
          unit: map['unit'] as String?,
          highlightLast: map['highlightLast'] == true,
          direction: map['direction'] as String?,
        );
      case 'delta':
        final from = map['from'];
        final to = map['to'];
        if (from is! num || to is! num) return null;
        if (!from.toDouble().isFinite || !to.toDouble().isFinite) return null;
        return NarratorEvidence.delta(
          from: from.toDouble(),
          to: to.toDouble(),
          unit: map['unit'] as String?,
          direction: map['direction'] as String?,
        );
      case 'vector':
        final dir = map['directionDeg'];
        final mag = map['magnitude'];
        if (dir is! num || mag is! num) return null;
        if (!dir.toDouble().isFinite || !mag.toDouble().isFinite) return null;
        return NarratorEvidence.vector(
          directionDeg: dir.toDouble(),
          magnitude: mag.toDouble(),
          label: map['label'] as String?,
        );
      case 'scalar':
        final value = map['value'];
        if (value is! num || !value.toDouble().isFinite) return null;
        return NarratorEvidence.scalar(
          value: value.toDouble(),
          unit: map['unit'] as String?,
          context: map['context'] as String?,
        );
      default:
        return null;
    }
  }

  /// Parse from a raw JSON string. Returns `null` on any decode error or an
  /// invalid payload (see [fromJson]).
  static NarratorEvidence? fromJsonString(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return fromJson(decoded);
    } catch (_) {
      return null;
    }
  }
}

/// What a detector emits when it fires. Carries everything except the
/// DB-assigned identity ([NarratorEvent.id]) and the persisted timestamp,
/// which the engine/service stamp from the injected clock.
class NarratorEventDraft {
  /// Stable id, e.g. `discovery.moving_object`. Used for per-eventType
  /// cooldowns and explainer lookup at the UI layer.
  final String eventType;

  final NarratorCategory category;
  final NarratorSeverity severity;

  /// One sentence, plain language, with concrete numbers from the data.
  final String headline;

  /// 1–2 sentences: what it means + what to do. Calm tone.
  final String? body;

  /// Typed micro-visualization payload, if the event has one.
  final NarratorEvidence? evidence;

  /// Engine-level dedupe / cooldown key. Two drafts with the same
  /// [dedupeKey] within a session are collapsed to one persisted event.
  final String dedupeKey;

  /// Discoveries pin to the top of feeds.
  final bool pinned;

  /// The frame that triggered this event, if any.
  final int? capturedImageId;

  const NarratorEventDraft({
    required this.eventType,
    required this.category,
    required this.severity,
    required this.headline,
    required this.dedupeKey,
    this.body,
    this.evidence,
    this.pinned = false,
    this.capturedImageId,
  });
}

/// A persisted, surfaced Narrator event — a draft plus DB identity and the
/// timestamp at which it was recorded.
class NarratorEvent {
  final int id;
  final int? sessionId;
  final int? capturedImageId;
  final DateTime timestamp;
  final String eventType;
  final NarratorCategory category;
  final NarratorSeverity severity;
  final String headline;
  final String? body;
  final NarratorEvidence? evidence;
  final String dedupeKey;
  final bool pinned;

  const NarratorEvent({
    required this.id,
    required this.timestamp,
    required this.eventType,
    required this.category,
    required this.severity,
    required this.headline,
    required this.dedupeKey,
    this.sessionId,
    this.capturedImageId,
    this.body,
    this.evidence,
    this.pinned = false,
  });
}
