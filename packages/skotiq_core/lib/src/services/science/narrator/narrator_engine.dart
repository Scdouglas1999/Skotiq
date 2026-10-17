/// The Night Narrator engine: owns the detector list and the two cross-cutting
/// gates every detector relies on — **dedupe** and **per-eventType cooldown**.
///
/// On each input update the service builds a [NarratorContext] and calls
/// [evaluate]. The engine runs every detector, then for each emitted draft:
///   1. **Dedupe** — a `dedupeKey` already accepted this session is dropped
///      (so the same discovery/record never lands twice).
///   2. **Cooldown** — a draft whose `eventType` fired more recently than that
///      type's cooldown window is dropped (so a noisy condition can't spam the
///      feed even if its dedupeKey legitimately changes).
///
/// Detectors own their own hysteresis (a trend fires once on crossing, closes
/// once on recovery); the engine never tries to second-guess that. The engine
/// is therefore the only place that needs the wall clock for accounting, and it
/// reads it from `ctx.now` so the whole pipeline stays deterministic in tests.
library;

import 'narrator_context.dart';
import 'narrator_detector.dart';
import 'narrator_event.dart';

class NarratorEngine {
  /// The detectors this engine runs, in evaluation order. Discovery first so a
  /// pinned discovery is recorded ahead of same-tick conditions noise.
  final List<NarratorDetector> detectors;

  /// Per-eventType cooldown windows. An eventType absent from the map has no
  /// cooldown (only dedupe gates it). Defaults cover the spec's "long cooldown"
  /// and "once per band" hints; callers may override per detector.
  final Map<String, Duration> cooldowns;

  /// dedupeKeys already accepted this session.
  final Set<String> _seenDedupeKeys = <String>{};

  /// Last-accepted timestamp per eventType, for cooldown accounting.
  final Map<String, DateTime> _lastAcceptedAt = <String, DateTime>{};

  NarratorEngine({required this.detectors, Map<String, Duration>? cooldowns})
    : cooldowns = cooldowns ?? const <String, Duration>{};

  /// Run all detectors against [ctx] and return the drafts that survive dedupe
  /// + cooldown, in the order detectors emitted them. Side-effect: records the
  /// accepted keys/timestamps so subsequent calls honour them.
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    final accepted = <NarratorEventDraft>[];
    for (final detector in detectors) {
      final List<NarratorEventDraft> drafts;
      try {
        drafts = detector.evaluate(ctx);
      } catch (_) {
        // A misbehaving detector must never stall the feed. Skip it this tick.
        continue;
      }
      for (final draft in drafts) {
        if (_seenDedupeKeys.contains(draft.dedupeKey)) continue;

        final cooldown = cooldowns[draft.eventType];
        if (cooldown != null) {
          final last = _lastAcceptedAt[draft.eventType];
          if (last != null && ctx.now.difference(last) < cooldown) {
            continue;
          }
        }

        _seenDedupeKeys.add(draft.dedupeKey);
        _lastAcceptedAt[draft.eventType] = ctx.now;
        accepted.add(draft);
      }
    }
    return accepted;
  }

  /// Whether a given dedupeKey has already been accepted this session.
  bool hasSeen(String dedupeKey) => _seenDedupeKeys.contains(dedupeKey);

  /// Pre-seed the accepted-dedupeKey set from durable storage (the DB) so a
  /// mid-session relaunch does not re-fire an ongoing condition as a duplicate
  /// card. Combined with episode-stable dedupeKeys and per-eventType cooldowns,
  /// this makes restart idempotent for in-flight episodes.
  void seedDedupeKeys(Iterable<String> keys) {
    _seenDedupeKeys.addAll(keys);
  }

  /// Reset all engine + detector state (between sessions / in tests).
  void reset() {
    _seenDedupeKeys.clear();
    _lastAcceptedAt.clear();
    for (final detector in detectors) {
      detector.reset();
    }
  }
}
